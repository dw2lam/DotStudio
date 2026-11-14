"""Light layers: one render per light source, which the app mixes live (docs/film-layers.md).

Light adds up, so a scene rendered once per light source can be relit to any time of day and any
weather by mixing those renders with weights. This module renders the tiles of a layered film
package; dsfilm.layerpack packs them into the 3x2 `clips/layers.mov` and the manifest block.

    sun      the scene's day sun only               city     the outside's night emitters only
    sun_low  a second, low sun only (white)         mask     glass = 1, everything else 0 (a matte)
    sky      the world (HDRI) only
    cabin    the scene's own lamps and emitters

Each light tile is rendered with every other source off and EEVEE's probes re-baked for it; the
camera, motion, frame numbers and motion blur are the same for every tile; no film look (the app
draws it live). Output is scene-linear half-float EXR, before any exposure.

The scene declares its light groups: built with spec.build(..., layers=True), its build() returns

    "layers": {
      "groups": {"sun": {"lights": [sun_obj]}, "sun_low": {"lights": [low_sun_obj]},
                 "sky": {"world": True}, "cabin": {}, "city": {"emitters": [materials]}},
      "other": "cabin",                  # where every lamp/emitter not listed goes
      "glass": ["WindowGlass"],          # material names the mask marks as glass
      "tint": {"sun_low": [1, .52, .22]} # colours of suns rendered white (manifest "tint")
    }

Emitters are switched through their emission-strength socket (an Emission node's Strength or a
Principled BSDF's Emission Strength; when that is driven by a Math MULTIPLY with a constant — e.g.
materials.facade_grid's lit windows — the constant). Lamps through energy + hide_render; the
world through its Background strength.

    rig = layers.Rig(scene, out["layers"])
    rig.prepare(scene)                    # EXR output, no post, exposure 0
    for tile in rig.tiles: rig.use(tile); rig.render(path, frame)
"""
import os
import time

import bpy

TILES = ("sun", "sun_low", "sky", "cabin", "city", "mask")
LIGHT_TILES = TILES[:5]
# the all-lights reference used by the additivity check (sun_low is an alternative sun, not added)
FULL = ("sun", "sky", "cabin", "city")
# Per-tile EEVEE samples, as a fraction of the render's samples (floor MIN_SAMPLES), or a fixed
# count for the mask. Measured on Commute, 1600x1000, frame 1 (README "Light layers"), as the error
# a tile adds to the mixed image in 8-bit display levels (mean / 99th pct) vs. all tiles at 64,
# against the noise floor (the sky at 64 vs 128 samples: 0.27 / 2.3 by day):
#   sun @32  0.09 / 0.9 by day        city @16  0.06 / 1.3 at night      -> half / quarter
#   sky @32  0.43 / 3.7 by day        cabin @32 0.57 / 4.1 at night      -> full samples
# The mask is flat emission (no lights, GI or shadows): 8 samples cover AA, DOF and motion blur
# (4 differ from 32 by 0.0015 mean). A scene can override any of these with "samples" in its
# layers declaration ({tile: fraction <= 1 or a count > 1}).
SAMPLE_SCALE = {"sun": 0.5, "sun_low": 0.5, "sky": 1.0, "cabin": 1.0, "city": 0.25}
SAMPLES = {"mask": 8}
MIN_SAMPLES = 8


def tile_samples(tile, base, decl=None):
    """EEVEE samples for a tile given the render's samples (see SAMPLE_SCALE)."""
    v = ((decl or {}).get("samples") or {}).get(tile)
    if v is None:
        if tile in SAMPLES:
            return min(SAMPLES[tile], base)
        v = SAMPLE_SCALE.get(tile, 1.0)
    if v > 1:
        return int(v)
    return max(min(MIN_SAMPLES, base), int(round(base * v)))


def emission_controls(mat):
    """The sockets that scale a material's light output (see the module docstring)."""
    out = []
    if not mat or not mat.node_tree:
        return out
    for n in mat.node_tree.nodes:
        if n.type == "EMISSION":
            s = n.inputs.get("Strength")
        elif n.type == "BSDF_PRINCIPLED":
            s = n.inputs.get("Emission Strength")
        else:
            continue
        if s is None:
            continue
        if s.is_linked:
            src = s.links[0].from_node
            if src.type == "MATH" and src.operation == "MULTIPLY":
                c = next((i for i in list(src.inputs)[:2] if not i.is_linked), None)
                if c is not None and c.default_value > 0:
                    out.append(c)
                    continue
            print(f"layers: {mat.name}: emission strength driven by {src.bl_idname}; can't switch it", flush=True)
            continue
        if s.default_value > 0:
            out.append(s)
    return out


class Rig:
    """The scene's light sources, grouped per tile, with switches."""

    def __init__(self, scene, decl):
        if not decl or not decl.get("groups"):
            raise ValueError("the scene declares no light layers (build() must return \"layers\" when "
                             "ctx.layers is set; see dsfilm.layers)")
        self.scene = scene
        self.decl = decl
        groups = decl["groups"]
        other = decl.get("other", "cabin")
        self.tiles = [t for t in TILES if t in groups or t == "mask"]
        self.lights, self.sockets, self.world = [], [], []
        claimed = {}
        for g, d in groups.items():
            for o in d.get("lights", []) or []:
                if o is not None:
                    claimed[o.name] = g
        for o in bpy.data.objects:
            if o.type == "LIGHT":
                self.lights.append((o, claimed.get(o.name, other), o.data.energy, o.hide_render))
        mats = {}
        for g, d in groups.items():
            for m in d.get("emitters", []) or []:
                mats[m.name] = g
        for m in bpy.data.materials:
            for s in emission_controls(m):
                self.sockets.append((s, mats.get(m.name, other), s.default_value))
        wg = next((g for g, d in groups.items() if d.get("world")), None)
        if scene.world and scene.world.node_tree:
            for n in scene.world.node_tree.nodes:
                if n.type == "BACKGROUND":
                    self.world.append((n.inputs["Strength"], wg, n.inputs["Strength"].default_value))
        self.glass = set(decl.get("glass", []))
        self.probes = any(o.type == "LIGHT_PROBE" for o in scene.objects)
        self._saved_slots = None
        self._eevee = None
        self.current = None
        self.samples = scene.eevee.taa_render_samples
        per = {}
        for _, g, _, _ in self.lights:
            per.setdefault(g, [0, 0])[0] += 1
        for _, g, _ in self.sockets:
            per.setdefault(g, [0, 0])[1] += 1
        print("LAYERS groups (lamps, emitters): " + ", ".join(f"{g} {a}/{b}" for g, (a, b) in sorted(per.items())),
              flush=True)

    # ------------------------------------------------------------------ switching
    def lights_on(self, on):
        """Turns on exactly the light groups in `on` (a set of tile names)."""
        for o, g, energy, hidden in self.lights:
            o.data.energy = energy if g in on else 0.0
            o.hide_render = hidden or g not in on
        for s, g, v in self.sockets:
            s.default_value = v if g in on else 0.0
        for s, g, v in self.world:
            s.default_value = v if g in on else 0.0

    def rebake(self):
        """EEVEE's volume/sphere probes hold indirect light: re-bake them for each light set."""
        if not self.probes or self.scene.render.engine != "BLENDER_EEVEE":
            return 0.0
        t = time.time()
        with bpy.context.temp_override(scene=self.scene):
            bpy.ops.object.lightprobe_cache_bake(subset="ALL")
        dt = time.time() - t
        print(f"LAYERS probes re-baked in {dt:.1f}s", flush=True)
        return dt

    def samples_for(self, tile):
        """The tile's default EEVEE samples ("full" renders at the render's own samples)."""
        return self.samples if tile == "full" else tile_samples(tile, self.samples, self.decl)

    def use(self, tile, samples=None):
        """Sets the scene up for one tile ("full" = every light but sun_low, for checks). Returns the
        bake time."""
        self._unmask()
        e = self.scene.eevee
        if tile == "mask":
            self.lights_on(set())
            self._mask()
            e.taa_render_samples = samples or self.samples_for(tile)
            self.current = tile
            return 0.0
        self.lights_on(set(FULL) if tile == "full" else {tile})
        e.taa_render_samples = samples or self.samples_for(tile)
        self.current = tile
        return self.rebake()

    # ------------------------------------------------------------------ the glass matte
    @staticmethod
    def _flat(name, v):
        """A pure emission material (no BSDF: it reflects nothing)."""
        m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        nt = m.node_tree.nodes
        if not nt.get("LayersEmit"):
            for n in list(nt):
                if n.type != "OUTPUT_MATERIAL":
                    nt.remove(n)
            em = nt.new("ShaderNodeEmission")
            em.name = "LayersEmit"
            em.inputs["Color"].default_value = (v, v, v, 1)
            em.inputs["Strength"].default_value = 1.0
            m.node_tree.links.new(em.outputs[0], nt.get("Material Output").inputs["Surface"])
        return m

    def _mask(self):
        # Glass -> white emission, EVERY other slot -> black emission. Merely switching the lights off
        # isn't enough: glossy surfaces (poles, rings, the penguin) reflect the white panes through
        # EEVEE's auto-updated sphere probes (measured: 0.005-0.02 on ~1/3 of the frame).
        white, black = self._flat("LayersMaskGlass", 1.0), self._flat("LayersMaskBlack", 0.0)
        saved = []
        for ob in bpy.data.objects:
            for i, slot in enumerate(getattr(ob, "material_slots", [])):
                if slot.material is None:
                    continue
                saved.append((ob, i, slot.link, slot.material if slot.link == "OBJECT" else None))
                is_glass = slot.material.name in self.glass
                slot.link = "OBJECT"
                slot.material = white if is_glass else black
        self._saved_slots = saved
        # flat emission only: AA, depth of field and motion blur matter, so no ray tracing, GI or shadows
        e = self.scene.eevee
        self._eevee = (e.use_raytracing, e.use_fast_gi, e.use_shadows, e.taa_render_samples)
        e.use_raytracing = e.use_fast_gi = e.use_shadows = False

    def _unmask(self):
        if self._saved_slots is None:
            return
        for ob, i, link, mat in self._saved_slots:
            slot = ob.material_slots[i]
            if link == "OBJECT":
                slot.material = mat
            else:
                slot.material = None
                slot.link = link
        self._saved_slots = None
        e = self.scene.eevee
        e.use_raytracing, e.use_fast_gi, e.use_shadows, e.taa_render_samples = self._eevee

    # ------------------------------------------------------------------ output
    @staticmethod
    def prepare(scene):
        """Half-float EXR, scene-linear, no compositor (no film look), view exposure 0."""
        rs = scene.render
        rs.use_compositing = False
        im = rs.image_settings
        im.file_format = "OPEN_EXR"
        im.color_depth = "16"
        im.exr_codec = "ZIP"
        im.color_mode = "RGB"
        scene.view_settings.exposure = 0.0
        rs.use_overwrite = True

    def render(self, path, frame):
        sc = self.scene
        sc.render.image_settings.color_mode = "RGB"     # the mask too: ffmpeg can't read 1-channel EXRs
        sc.frame_set(frame)
        sc.render.filepath = os.path.abspath(path)
        t = time.time()
        bpy.ops.render.render(write_still=True)
        dt = time.time() - t
        print(f"LAYERS {self.current} frame={frame} {dt:.1f}s", flush=True)
        return dt


def manifest_info(spec, decl, engine="eevee"):
    """The manifest numbers the toolkit knows at render time: the exposures the scene was balanced
    at (EV: the day and night presets + the spec's render exposure (+ eevee_exposure)), and tints."""
    from . import lighting
    rs = spec.get("render", {})
    over = spec.get("params", {}).get("lighting", {})
    extra = rs.get("exposure", 0.0) + (rs.get("eevee_exposure", 0.0) if engine == "eevee" else 0.0)
    exp = {k: round(lighting.preset(k, **over.get(k, {}))["exposure"] + extra, 3) for k in ("day", "night")}
    return {"exposure": exp, "tint": {k: [round(float(c), 4) for c in v] for k, v in (decl.get("tint") or {}).items()}}
