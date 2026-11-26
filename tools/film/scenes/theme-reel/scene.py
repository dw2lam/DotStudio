"""Theme reel: Settings › General › Theme's films — one theme's real UI as an exploded, floating
stack in depth, shot like a product film.

The parts are the app's own UI, captured offscreen by UIShots (capture.sh) and prepared by prep.py:
the window is the base of the stack; the Screensaver & Wallpaper deck, a row of style tiles, the
editor's inspector and a row of keys float above it, each a picture on a real slab with rounded
corners and a little thickness (Classic's glass cards are frosted glass that refracts what's
behind). At the front, built as real geometry, each theme's hero: Retro's panel of machined
aluminium dials with coloured caps (knurled edges, a spun face, printed scale and legends) that
turn; Classic's switch and slider on a frosted glass plate (the switch flips on and off, its track
turning accent blue; the slider moves). The shot racks focus from the hero to the deck and back.

Params (the spec's "params"; render-all.sh writes one spec per variant):
    theme  "classic" | "retro"
    tone   "light" | "dark"
    parts  folder with prep.py's output (window.png, deck.png, …, parts.json)
    font   the legends' font file (default: the repo's App/Fonts/HankenGrotesk-Medium.ttf)
    cycles_device  Cycles' GPU backend off a Mac (OPTIX, CUDA, HIP…)
    fstop, view    the lens (default 0.08) and the view transform (default Standard)

Everything that moves is periodic in the loop (8 s): the camera's orbit, dolly and roll, the
parts' float, the key light's drift, the rack focus (front, to the back, and front again), the
dials' turns and the switch and slider (eased moves that come back to where they started).
"""
import json
import math
import os

import bmesh
import bpy
from mathutils import Vector

from dsfilm import geometry as G
from dsfilm import materials as M
from dsfilm.loop import smoothstep

ASSETS = []                 # nothing to fetch: the UI is captured, the set is built here
VARIANTS = ["day"]          # the lighting preset is unused (the look comes from theme + tone)
CAMERAS = ["hero"]

PT = 0.01                   # one point of UI = 0.01 Blender units (the window is 12.8 wide)
# the Retro legends' type (Hanken Grotesk, the app's own); params.font overrides (a copy travels with
# the work folder when Blender runs on another Mac)
FONT = os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "App", "Fonts", "HankenGrotesk-Medium.ttf")


def lin(hex_or_rgb):
    """sRGB (hex int or 0–1 tuple) -> linear."""
    if isinstance(hex_or_rgb, int):
        c = [((hex_or_rgb >> s) & 0xFF) / 255 for s in (16, 8, 0)]
    else:
        c = list(hex_or_rgb)
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


# Per variant: the set's colours and light. Sides are the slabs' edges (the panel colour, a step
# down); "rim" is the theme's accent light from behind.
LOOKS = {
    "retro-light": dict(backdrop=0xC9C9C3, world=0xE4E4DE, world_k=0.35, side=0xE6E6E0, window_side=0xD6D6D0,
                        rim=(1.0, 0.42, 0.04), rim_k=1.0, key_k=1.0, key_tint=(1.0, 0.97, 0.92), ui_emit=0.30,
                        coat=0.12, ui_rough=0.55, panel=0xF3F3EE, legend=0x525257, tick=0x7A7A7E,
                        metal=(0.80, 0.80, 0.79), exposure=0.0),
    "retro-dark": dict(backdrop=0x0C0C0E, world=0x18181B, world_k=0.35, side=0x232326, window_side=0x1A1A1D,
                       rim=(1.0, 0.40, 0.02), rim_k=1.8, key_k=0.8, key_tint=(0.92, 0.95, 1.0), ui_emit=0.55,
                       coat=0.12, ui_rough=0.55, panel=0x1B1B1E, legend=0xACAAAE, tick=0x78767A,
                       metal=(0.62, 0.62, 0.61), exposure=0.3),
    "classic-light": dict(backdrop=0xBFCADB, world=0xE8EEF7, world_k=0.35, side=0xF2F3F6, window_side=0xE4E6EA,
                          rim=(0.25, 0.55, 1.0), rim_k=1.2, key_k=1.0, key_tint=(0.97, 0.98, 1.0), ui_emit=0.30,
                          coat=0.5, ui_rough=0.35, frost=0xEEF2F8, glass=0xF4F7FC, exposure=0.0),
    "classic-dark": dict(backdrop=0x090B12, world=0x121624, world_k=0.4, side=0x2A2B30, window_side=0x222327,
                         rim=(0.20, 0.50, 1.0), rim_k=2.2, key_k=0.8, key_tint=(0.92, 0.95, 1.0), ui_emit=0.55,
                         coat=0.5, ui_rough=0.35, frost=0x34363E, glass=0x5A6070, exposure=0.3),
}

# Where each part floats: centre (x, y) and height z above the window, in Blender units. The
# deck and tiles sit over where they live in the window, lifted; the inspector hangs off the
# window's right edge; the keys (and Retro's dials) float nearest the camera.
STACK = {
    "window": (0.0, 0.0, 0.0),
    "deck": (-0.3, 2.9, 0.8),
    "tiles": (0.4, -1.2, 1.6),
    "inspector": (4.7, 0.3, 2.5),
    "keys": (-2.7, -4.0, 3.0),
}
# The hero at the front, where the shot opens in focus: Retro's dial panel; Classic's switch and
# slider on a frosted glass plate.
DIALS_AT = (2.4, -4.8, 4.2)
DIALS_SCALE = 0.85
CORNER = {"retro": {"window": 14, "default": 6},
          "classic": {"window": 14, "deck": 24, "tiles": 14, "inspector": 12, "keys": 12, "default": 10}}
FOCUS_BACK = (0.0, 2.4, 0.8)    # the rack focus: from the front part (dials / keys) to the deck


# ---------------------------------------------------------------- materials

def ui_mat(name, path, L, classic):
    """The captured UI as a picture: its colours, lit a little and lifted by emission so it stays
    true; a clear coat for a sheen. Classic's see-through glass (a flat low-alpha fill) becomes
    frosted glass that refracts what's under it."""
    mat = bpy.data.materials.new(name)
    nt, ln = M._nodes(mat)
    b = nt.get("Principled BSDF")
    t = nt.new("ShaderNodeTexImage")
    t.image = M.load_image(path)
    t.extension = "CLIP"
    t.interpolation = "Cubic"
    ln.new(t.outputs["Color"], b.inputs["Base Color"])
    ln.new(t.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = L["ui_emit"]
    b.inputs["Roughness"].default_value = L["ui_rough"]
    b.inputs["Coat Weight"].default_value = L["coat"]
    b.inputs["Coat Roughness"].default_value = 0.08
    b.inputs["Specular IOR Level"].default_value = 0.35
    if classic:
        # glass = alpha in (0.015, 0.5): opaque to the shader, transmissive, frosted
        gt = nt.new("ShaderNodeMath"); gt.operation = "GREATER_THAN"; gt.inputs[1].default_value = 0.015
        ln.new(t.outputs["Alpha"], gt.inputs[0])
        mr = nt.new("ShaderNodeMapRange"); mr.clamp = True
        mr.inputs["From Min"].default_value, mr.inputs["From Max"].default_value = 0.12, 0.6
        mr.inputs["To Min"].default_value, mr.inputs["To Max"].default_value = 1.0, 0.0
        ln.new(t.outputs["Alpha"], mr.inputs["Value"])
        g = nt.new("ShaderNodeMath"); g.operation = "MULTIPLY"
        ln.new(gt.outputs[0], g.inputs[0]); ln.new(mr.outputs[0], g.inputs[1])
        a = nt.new("ShaderNodeMath"); a.operation = "MAXIMUM"
        ln.new(t.outputs["Alpha"], a.inputs[0]); ln.new(g.outputs[0], a.inputs[1])
        ln.new(a.outputs[0], b.inputs["Alpha"])
        ln.new(g.outputs[0], b.inputs["Transmission Weight"])
        # the glass's tint: white-ish frost, not the near-transparent fill colour
        mix = nt.new("ShaderNodeMix"); mix.data_type = "RGBA"
        ln.new(g.outputs[0], mix.inputs[0])
        ln.new(t.outputs["Color"], mix.inputs[6])
        mix.inputs[7].default_value = (*lin(L["frost"]), 1.0)
        ln.new(mix.outputs[2], b.inputs["Base Color"])
        ln.new(mix.outputs[2], b.inputs["Emission Color"])     # lit acrylic: the frost glows a little
        _glassy(mat)
    else:
        ln.new(t.outputs["Alpha"], b.inputs["Alpha"])
    _cutout(mat)
    return mat


def _cutout(mat):
    for k, v in (("surface_render_method", "DITHERED"), ("use_transparent_shadow", True)):
        try:
            setattr(mat, k, v)
        except Exception:
            pass


def _glassy(mat):
    for k, v in (("use_raytrace_refraction", True), ("thickness_mode", "SLAB")):
        try:
            setattr(mat, k, v)
        except Exception:
            pass


def flat(name, rgb, rough=0.5, **kw):
    return M.principled(name, rgb, rough, **kw)


def aluminium(name, tint):
    """Machined aluminium, spun: anisotropic with the grain running round the knob's axis."""
    mat = M.principled(name, tint, 0.26, 1.0, **{"Anisotropic": 0.75})
    nt, ln = M._nodes(mat)
    tg = nt.new("ShaderNodeTangent")
    tg.direction_type = "RADIAL"
    tg.axis = "Z"
    ln.new(tg.outputs["Tangent"], nt.get("Principled BSDF").inputs["Tangent"])
    return mat


# ---------------------------------------------------------------- geometry

def rounded_slab(name, w, h, depth, r, mat, coll, bevel=0.012):
    """A rounded rectangle w x h (centred), from z=-depth to 0, its edges eased by a bevel."""
    bm = bmesh.new()
    pts = G.rrect(-w / 2, -h / 2, w / 2, h / 2, r, seg=10)
    vs = [bm.verts.new((x, y, -depth)) for x, y in pts]
    f = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    top = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, 0, depth), verts=top)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = G.from_bm(name, bm, mat, coll)
    if bevel:
        b = ob.modifiers.new("bevel", "BEVEL")
        b.width = min(bevel, depth * 0.45)
        b.segments = 3
        b.limit_method = "ANGLE"
    return G.smooth_by_angle(ob, 40)


def ring_mesh(name, rings, mat, coll, cap=True):
    """A lathe: rings [(radius_fn(i, n) or radius, z)], n verts each, joined by quads; the last
    ring closed by an n-gon."""
    n = 192
    bm = bmesh.new()
    loops = []
    for r, z in rings:
        loop = []
        for i in range(n):
            a = math.tau * i / n
            rr = r(i) if callable(r) else r
            loop.append(bm.verts.new((rr * math.cos(a), rr * math.sin(a), z)))
        loops.append(loop)
    for a, b in zip(loops, loops[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap:
        bm.faces.new(loops[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return G.from_bm(name, bm, mat, coll)


def knob(name, R, H, cap_rgb, pointer_rgb, alu, coll, root):
    """The Retro dial as hardware: a knurled aluminium body with a chamfered, spun top, a
    coloured cap set into it with the pointer on top, and an engraved index on the metal."""
    knurl = lambda i: R * (1.0 if i % 2 == 0 else 0.972)       # 96 ridges
    body = ring_mesh(name + "Body", [(R * 0.97, 0.0), (knurl, 0.012), (knurl, H * 0.80), (R * 0.985, H * 0.86),
                                     (R * 0.93, H * 0.97), (R * 0.90, H)], alu, coll)
    body.parent = root
    G.smooth_by_angle(body, 50)
    rc = R * 0.70
    capm = M.principled(name + "CapMat", cap_rgb, 0.42, **{"Coat Weight": 0.3, "Coat Roughness": 0.2})
    cap = ring_mesh(name + "Cap", [(rc, H - 0.02), (rc, H + 0.045), (rc * 0.985, H + 0.058), (rc * 0.95, H + 0.064)],
                    capm, coll)
    cap.parent = root
    G.smooth_by_angle(cap, 50)
    pm = M.principled(name + "PointerMat", pointer_rgb, 0.4)
    p = G.box(name + "Pointer", (0.034, rc * 0.62, 0.008), (0, rc * 0.50, H + 0.066), pm, coll)
    p.parent = root
    ix = G.box(name + "Index", (0.022, (R * 0.90 - rc) * 0.8, 0.006), (0, (R * 0.90 + rc) / 2, H + 0.001),
               M.principled(name + "IndexMat", (0.02, 0.02, 0.02), 0.6), coll)
    ix.parent = root
    return root


def text(name, s, size, mat, coll, loc, parent, font=FONT):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = s
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    if font and os.path.exists(font):
        cu.font = bpy.data.fonts.load(os.path.abspath(font), check_existing=True)
    ob = bpy.data.objects.new(name, cu)
    coll.objects.link(ob)
    ob.data.materials.append(mat)
    ob.location = loc
    ob.parent = parent
    return ob


# ---------------------------------------------------------------- the set

def build(ctx):
    P = ctx.params
    theme, tone = P.get("theme", "retro"), P.get("tone", "light")
    key = f"{theme}-{tone}"
    L = LOOKS[key]
    classic = theme == "classic"
    parts_dir = P["parts"]
    with open(os.path.join(parts_dir, "parts.json")) as f:
        manifest = json.load(f)["parts"]
    ctx.light["exposure"] = L["exposure"]        # no daylight preset here: the set's own exposure
    lp = ctx.loop
    S = lp.seconds
    coll = ctx.coll("Reel")
    scene = ctx.scene

    # world: a soft ambient in the set's colour
    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (*lin(L["world"]), 1)
    bg.inputs["Strength"].default_value = L["world_k"]
    try:
        world.use_sun_shadow = False
    except Exception:
        pass

    # backdrop: a seamless floor under the stack (no horizon: the camera looks down on it)
    bd = G.plane_uv("Backdrop", 120, 120, flat("Backdrop", lin(L["backdrop"]), 0.85), coll, (0, 0, -1.4))

    if classic:
        # Classic's cards stand on clear glass: their edges catch the light and refract what's under
        side = flat("Side", lin(L["glass"]), 0.12, **{"Transmission Weight": 1.0, "IOR": 1.45})
        _glassy(side)
    else:
        side = flat("Side", lin(L["side"]), 0.45, **{"Coat Weight": 0.2})
    wside = flat("WindowSide", lin(L["window_side"]), 0.5)
    corner = CORNER[theme]
    roots = {}
    for name, (x, y, z) in STACK.items():
        info = manifest[name]
        w, h = info["size"][0] * PT, info["size"][1] * PT
        root = G.empty("Part_" + name, coll, (x, y, z))
        roots[name] = root
        pic = G.plane_uv("Pic_" + name, w, h, ui_mat("UI_" + name, os.path.join(parts_dir, name + ".png"), L, classic),
                         coll, (0, 0, 0.002))
        pic.parent = root
        rad = corner.get(name, corner["default"]) * PT
        depth = 0.16 if name == "window" else 0.07
        for i, body in enumerate(info["bodies"]):
            if body["glass"]:
                continue                       # frosted in the picture's own material
            x0, y0, x1, y1 = [v * PT for v in body["rect"]]
            inset = 0.6 * PT
            bw, bh = x1 - x0 - 2 * inset, y1 - y0 - 2 * inset
            r = min(rad, 0.5 * min(bw, bh)) if (x1 - x0) > 1.0 else min(4 * PT * 1.5, 0.5 * min(bw, bh))
            s = rounded_slab(f"Slab_{name}_{i}", bw, bh, depth, r, wside if name == "window" else side, coll)
            s.location = ((x0 + x1) / 2 - w / 2, h / 2 - (y0 + y1) / 2, 0.0)
            s.parent = root

    # Retro: the dials, real
    dial_roots = []
    if not classic:
        droot = G.empty("Dials", coll, DIALS_AT)
        droot.scale = (DIALS_SCALE,) * 3
        roots["dials"] = droot
        panel = rounded_slab("DialPanel", 5.0, 1.95, 0.14, 0.09, flat("DialPanelMat", lin(L["panel"]), 0.55,
                                                                       **{"Coat Weight": 0.15}), coll)
        panel.parent = droot
        alu = aluminium("Aluminium", L["metal"])
        caps = [(0x0088E8, (1, 1, 1)), (0x00BD5F, (0.01, 0.02, 0.01)), (0xFBFBF7, (0.02, 0.02, 0.02)),
                (0xFF7300, (0.02, 0.01, 0.0))]
        legends = ["speed", "glow", "size", "level"]
        legend_mat = flat("Legend", lin(L["legend"]), 0.6)
        tick_mat = flat("Tick", lin(L["tick"]), 0.6)
        R, H = 0.33, 0.34
        for i, ((capc, ptr), lg) in enumerate(zip(caps, legends)):
            cx = -1.8 + 1.2 * i
            kr = G.empty(f"Knob{i}", coll, (cx, 0.14, 0.0), parent=droot)
            knob(f"Knob{i}", R, H, lin(capc) if capc != 0xFBFBF7 else lin(0xF4F4EF), ptr, alu, coll, kr)
            dial_roots.append(kr)
            for k in range(11):        # the printed scale: 11 dots over 270°
                a = math.radians(225 - 27 * k)
                d = G.box(f"Tick{i}_{k}", (0.03, 0.03, 0.004),
                          (cx + 0.48 * math.cos(a), 0.14 + 0.48 * math.sin(a), 0.002), tick_mat, coll)
                d.parent = droot
            text(f"Legend{i}", lg, 0.15, legend_mat, coll, (cx, -0.62, 0.003), droot, P.get("font", FONT))

    # Classic: its controls, real — a switch and a slider on a frosted glass plate
    controls = None
    if classic:
        croot = G.empty("Controls", coll, DIALS_AT)
        croot.scale = (DIALS_SCALE,) * 3
        roots["dials"] = croot
        plate = M.principled("GlassPlate", lin(L["glass"]), 0.32, **{"Transmission Weight": 1.0, "IOR": 1.45,
                                                                     "Coat Weight": 0.6, "Coat Roughness": 0.05})
        _glassy(plate)
        rounded_slab("Plate", 4.6, 1.6, 0.12, 0.42, plate, coll, bevel=0.03).parent = croot
        accent = lin(0x0A84FF if tone == "dark" else 0x007AFF)
        groove = lin(0x48484C if tone == "dark" else 0xD6D6DB)
        white = M.principled("KnobWhite", lin(0xFBFBFD), 0.3, **{"Coat Weight": 0.6, "Coat Roughness": 0.1})
        # the switch: a capsule track whose colour runs grey -> accent as it turns on, a white knob
        track_mat = M.principled("SwitchTrack", groove, 0.35, **{"Coat Weight": 0.5, "Coat Roughness": 0.08})
        nt, ln = M._nodes(track_mat)
        mix = nt.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.inputs[6].default_value = (*groove, 1)
        mix.inputs[7].default_value = (*accent, 1)
        ln.new(mix.outputs[2], nt.get("Principled BSDF").inputs["Base Color"])
        sx = -1.2
        track = rounded_slab("SwitchTrack", 1.3, 0.74, 0.06, 0.37, track_mat, coll, bevel=0.02)
        track.location = (sx, 0, 0.06)
        track.parent = croot
        sknob = ring_mesh("SwitchKnob", [(0.3, 0.0), (0.31, 0.04), (0.30, 0.07), (0.26, 0.088)], white, coll)
        G.smooth_by_angle(sknob, 60)
        sknob.parent = croot
        # the slider: a groove, an accent fill from its left end, a white knob
        rx0, rlen = 0.0, 1.9
        rail = rounded_slab("SliderRail", rlen, 0.11, 0.03, 0.055, M.principled("Rail", groove, 0.4), coll, bevel=0.01)
        rail.location = (rx0 + rlen / 2, 0, 0.03)
        rail.parent = croot
        froot = G.empty("SliderFillRoot", coll, (rx0, 0, 0.032), parent=croot)
        fill = rounded_slab("SliderFill", 1.0, 0.11, 0.032, 0.05, M.principled("Fill", accent, 0.3), coll, bevel=0.0)
        fill.location = (0.5, 0, 0)
        fill.parent = froot
        lknob = ring_mesh("SliderKnob", [(0.19, 0.0), (0.2, 0.03), (0.19, 0.055), (0.16, 0.068)], white, coll)
        G.smooth_by_angle(lknob, 60)
        lknob.parent = croot
        controls = dict(mix=mix.inputs[0], sknob=sknob, sx=sx, froot=froot, lknob=lknob, rx0=rx0, rlen=rlen)

    # ---------------------------------------------------------------- light
    def area(name, size, energy, color, loc, target, shape="RECTANGLE", size_y=None):
        ld = bpy.data.lights.new(name, "AREA")
        ld.shape = shape
        ld.size = size
        if size_y:
            ld.size_y = size_y
        ld.energy = energy
        ld.color = color
        try:
            ld.use_shadow_jitter = True
        except Exception:
            pass
        ob = bpy.data.objects.new(name, ld)
        coll.objects.link(ob)
        ob.location = loc
        G.look_at(ob, loc, target)
        return ob

    tgt = Vector((0.8, -1.3, 1.8))
    key_l = area("Key", 9.0, 1500 * L["key_k"], L["key_tint"], (-7.5, 6.0, 15.0), tgt, size_y=6.0)
    area("Fill", 14.0, 400 * L["key_k"], (1, 1, 1), (10.0, -12.0, 9.0), tgt)
    area("Rim", 12.0, 900 * L["rim_k"], L["rim"], (2.0, 16.0, 3.5), (0.0, 0.0, 1.0), size_y=3.0)

    # ---------------------------------------------------------------- camera
    cd = bpy.data.cameras.new("Hero")
    cd.lens = 50
    cd.sensor_width = 36
    cd.dof.use_dof = True
    cd.dof.aperture_fstop = P.get("fstop", 0.08)
    cd.dof.aperture_blades = 0
    cam = bpy.data.objects.new("Hero", cd)
    coll.objects.link(cam)
    scene.camera = cam

    front = Vector(DIALS_AT)
    back = Vector(FOCUS_BACK)

    def cam_at(t):
        u = math.tau * t / S
        az = math.radians(26 + 5.0 * math.sin(u))
        el = math.radians(49 + 3.0 * math.sin(u + 1.3))
        dist = 18.0 - 0.5 * math.cos(u)
        look = tgt + Vector((0.25 * math.sin(u), 0.15 * math.cos(u), 0))
        pos = look + dist * Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
        return pos, look, 1.2 * math.sin(u + 0.6)

    def rack(t):
        # front -> back (2.2–3.5 s), hold, back -> front (5.9–7.2 s)
        return smoothstep(2.2, 3.5, t) - smoothstep(5.9, 7.2, t)

    float_ph = {"window": 0.0, "deck": 0.9, "tiles": 2.1, "inspector": 3.3, "keys": 4.4, "dials": 5.3}
    base = {n: Vector(r.location) for n, r in roots.items()}

    # the dials' turns: (time, value 0..1) keys, eased between; the last value equals the first
    turns = [
        [(0.0, 0.30), (0.9, 0.30), (1.7, 0.78), (4.4, 0.78), (5.2, 0.22), (7.1, 0.22), (7.8, 0.30)],
        [(0.0, 0.55), (1.6, 0.55), (2.4, 0.18), (5.0, 0.18), (5.9, 0.85), (7.3, 0.85), (8.0, 0.55)],
        [(0.0, 0.70), (2.7, 0.70), (3.5, 0.40), (6.0, 0.40), (6.8, 0.70), (8.0, 0.70)],
        [(0.0, 0.20), (0.4, 0.20), (1.3, 0.62), (3.9, 0.62), (4.7, 0.95), (6.4, 0.95), (7.4, 0.20), (8.0, 0.20)],
    ]

    # Classic's slider: the same kind of eased moves
    slide = [(0.0, 0.25), (1.6, 0.25), (2.5, 0.82), (4.3, 0.82), (5.1, 0.45), (6.5, 0.45), (7.5, 0.25), (8.0, 0.25)]

    def value(keys, t):
        t = t % S
        for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
            if t0 <= t <= t1:
                return v0 + (v1 - v0) * smoothstep(t0, t1, t)
        return keys[-1][1]

    def pose(t):
        pos, look, roll = cam_at(t)
        cam.location = pos
        G.look_at(cam, pos, look, roll=roll)
        f = rack(t)
        cd.dof.focus_distance = (pos - front).length * (1 - f) + (pos - back).length * f
        u = math.tau * t / S
        for n, r in roots.items():
            ph = float_ph.get(n, 0.0)
            amp = 0.0 if n == "window" else 0.07
            r.location = base[n] + Vector((0, 0, amp * math.sin(u + ph)))
            tilt = 0.0 if n == "window" else math.radians(0.8)
            r.rotation_euler = (tilt * math.sin(u + ph + 0.7), tilt * math.cos(u + ph), 0)
        for kr, keys in zip(dial_roots, turns):
            kr.rotation_euler = (0, 0, math.radians(135 - 270 * value(keys, t)))
        if controls:
            c = controls
            on = smoothstep(0.9, 1.25, t) - smoothstep(4.9, 5.25, t)       # the switch: on, then off
            c["mix"].default_value = on
            c["sknob"].location = (c["sx"] + 0.28 * (2 * on - 1), 0, 0.06 + 0.06)
            sv = value(slide, t)
            c["froot"].scale = (max(sv * c["rlen"], 0.06), 1, 1)
            c["lknob"].location = (c["rx0"] + sv * c["rlen"], 0, 0.06)
        # the key light drifts, so the sheen moves across the glossy parts
        key_l.location = Vector((-7.5 + 2.5 * math.sin(u + 0.4), 6.0 + 1.5 * math.cos(u), 15.0))
        G.look_at(key_l, key_l.location, tgt)

    ids = [cam, (cd, "dof.focus_distance"), key_l] + list(roots.values()) + dial_roots
    if controls:
        ids += [controls["sknob"], controls["lknob"], (controls["froot"], "scale"), (controls["mix"], "default_value")]
    lp.bake(ids, pose, props=("location", "rotation_euler"))

    # colour: the UI's own colours, unbent (the toolkit's AgX look is for photoreal scenes)
    view = P.get("view", "Standard")
    # Cycles on another machine (params.cycles_device: OPTIX, CUDA, HIP…): dsfilm.render asks for
    # Metal, which fails off a Mac and leaves the CPU; pick the GPU backend here (render.setup's
    # Metal attempt then fails and leaves this one), and the GPU itself at render time.
    device = P.get("cycles_device")
    if device:
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            prefs.compute_device_type = device
            prefs.get_devices()
            for d in prefs.devices:
                d.use = d.type != "CPU"
        except Exception as e:
            print("cycles device:", e)

    def _view(sc, *_):
        sc.view_settings.view_transform = view
        try:
            sc.view_settings.look = "None"
        except TypeError:
            pass
        if device and sc.render.engine == "CYCLES":
            sc.cycles.device = "GPU"
    bpy.app.handlers.render_pre.append(_view)
    try:
        scene.eevee.use_bokeh_jittered = True
        scene.eevee.bokeh_max_size = 200
    except Exception:
        pass
    return {"cameras": {"hero": cam}}
