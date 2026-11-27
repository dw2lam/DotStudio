"""Theme reel: Settings › General › Theme's films — the app assembling itself, shot like a hardware
maker's product film: one object, centred, sharp, on a plain seamless field.

The object is the app as it shows — the window, with the editor's inspector docked at its right —
taken apart by prep.py into every visible element (found in the real UI captured offscreen by
capture.sh): the toolbar keys, the Screensaver and Wallpaper cards with their screens and keys, the
sync key, the filter box with its search field and chips, the Scenes box with each style tile, the
inspector's header, readouts and swatch — and, on Retro, the inspector's dials as real machined
aluminium knobs (knurled body, spun face, coloured cap, engraved index). Each element is its
picture on a slab with rounded corners and a little thickness; under it, its parent shows a socket.

The film: the empty chassis (window and inspector, their sockets bare) rests on the field; one by
one, evenly, every element drops in from above and seats with a small press and spring, like a
keycap (the dials seat, then turn); the assembled app holds (dials turn, a key presses); then the
elements lift out in reverse, last in first out, and the chassis is empty again — a seamless loop.

Modes (params.mode):
    loop    the 8 s film above (Settings' Theme films); the camera sways a few degrees
    scroll  ONE-WAY, for the site (6 s, 180 frames, played as a video): empty -> assembled, no
            lift-out. It opens on a close-up of the bare chassis — low and near, the window's top
            left corner (its title bar and the empty Screensaver socket) filling the frame — and
            pulls back in one slow eased move (dolly out, rise, swing round) that opens out into
            the 3/4 view by 88 %; the last 12 % hold the 3D frame, the same as the 3D hero still
            (SCROLL_FILL). The elements land as the camera reveals them, nearest the close-up
            first, each on a short drop while it fades in. A little depth of field at the
            close-up only, gone by the middle of the move
    flat    the assembled app straight from above, orthographic (the flat product shot)

The shot (tools/film/README.md's rules apply; see render-all.sh):
- a long lens (near-orthographic), a 3/4 view from above, the object centred with generous
  negative space; the frame is fitted to the object (distance + lens shift), not hand-placed;
- crisp: no depth of field;
- the field is composited, not lit: the render is transparent over a shadow catcher, and the
  compositor lays it over the field's exact colour — light grey #e3e3e1 in light, black in dark
  (with a faint pool of light under the object) — so the films sit seamlessly on the site's bands;
- light: soft, large overhead light on grey; on black a low-key rig (a strip rim from behind, a
  key from the side) so edges and knurls catch the light and the UI glows.

Params (the spec's "params"; render-all.sh writes one spec per variant):
    theme  "classic" | "retro"
    tone   "light" | "dark"
    parts  folder with prep.py's output (m-window.png, e-*.png, parts.json)
    mode   "loop" (default) | "scroll" | "flat"
    font   unused (kept for older specs)
    cycles_device  Cycles' GPU backend off a Mac (OPTIX, CUDA, HIP…)
    view   the view transform (default Standard: the UI's own colours)
    cutout true: no field — a transparent RGBA picture with the shadow in its alpha
    fstop  optional depth of field (default none: the shot is sharp)
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


def lin(hex_or_rgb):
    """sRGB (hex int or 0–1 tuple) -> linear."""
    if isinstance(hex_or_rgb, int):
        c = [((hex_or_rgb >> s) & 0xFF) / 255 for s in (16, 8, 0)]
    else:
        c = list(hex_or_rgb)
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


# Per variant: the field (composited), the studio (world: what glossy parts reflect, and a soft
# fill), the light rig, and the slabs' sides. "pool": dark only — a faint lift of the black field
# under the object (its centre colour).
LOOKS = {
    "retro-light": dict(field=0xE3E3E1, world=0xE3E3E1, world_k=0.45, rig="soft", light_k=1.0,
                        side=0xDDDDD6, window_side=0xD0D0C9, ui_emit=0.30, coat=0.10, ui_rough=0.55,
                        metal=(0.80, 0.80, 0.79)),
    "retro-dark": dict(field=0x000000, pool=0x161618, world=0x0A0A0B, world_k=0.25, rig="dramatic", light_k=1.0,
                       side=0x232326, window_side=0x1A1A1D, ui_emit=0.55, coat=0.10, ui_rough=0.55,
                       metal=(0.66, 0.66, 0.65)),
    "classic-light": dict(field=0xE3E3E1, world=0xE6E7EA, world_k=0.45, rig="soft", light_k=1.0,
                          side=0xE9EAEE, window_side=0xDADCE0, ui_emit=0.30, coat=0.40, ui_rough=0.35,
                          glass=0xF4F7FC),
    "classic-dark": dict(field=0x000000, pool=0x15161A, world=0x0A0B0E, world_k=0.25, rig="dramatic", light_k=1.0,
                         side=0x2A2B30, window_side=0x222327, ui_emit=0.55, coat=0.40, ui_rough=0.35,
                         glass=0x5A6070),
}

# Thickness (Blender units): a module's base (rests on the field), a level-1 element, a level-2
# element; an element sits SEAT deep in its parent's top (its socket).
BASE = {"window": 0.30, "inspector": 0.26}
THICK = (0.08, 0.055)
SEAT = 0.015
DROP = 16.0                 # how far above its seat an element starts its fall (out of frame)
# the scroll sequence: the camera starts straight above, so a long fall would come at the lens —
# there an element arrives in screen space instead: a short drop onto its seat while it fades in
SCROLL_DROP = 0.5
PARK = -40.0                # where an element waits (under the floor) before it falls / after it lifts out

# The camera: a long lens, 3/4 from the front-right and above; the object fills FILL of the frame's
# width (or HEIGHT_FILL of its height), centred by lens shift.
LENS = 135.0
AZIMUTH = 20.0
ELEVATION = 47.0
SWAY = 3.0                  # loop only: degrees of azimuth, one slow sine over the loop
FILL = 0.72                 # the films (Settings): generous negative space
HEIGHT_FILL = 0.74
# the site's pictures, closer (owner: "more zoomed in"): the scroll sequence, the flat and 3D stills
SCROLL_FILL = 0.88
SCROLL_HEIGHT_FILL = 0.90
FLAT_FILL = SCROLL_FILL
# the scroll sequence's camera (owner: "start from a very close-up shot of the blank thing and then
# slowly expand into the parts going onto it … dramatically"): a close-up of the empty chassis's
# top left corner (CLOSE_AT, in assembly points: the title bar and the Screensaver socket's corner),
# low (CLOSE_EL) from the front left (CLOSE_AZ), CLOSE_WIDTH units of the board across the frame;
# then one eased pull-back to the 3/4 frame, done at MOVE_END of the sequence. The distance moves
# in log space (an even "expansion"); the look point and the lens shift follow so the close-up's
# corner slides steadily from the frame's centre to its place in the final frame.
CLOSE_AT = (60.0, 75.0)
CLOSE_AZ = -68.0
CLOSE_EL = 22.0
CLOSE_WIDTH = 2.2
MOVE_END = 0.88
CLOSE_FSTOP = 4.0           # the close-up's depth of field (none from the middle of the move)


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


# ---------------------------------------------------------------- the field (compositor)

def field_compositor(scene, L):
    """Lays the transparent render over the field: out = render + field x (1 - alpha) (the render is
    premultiplied; the shadow catcher's shadow is in its alpha). The field is the exact colour (in
    linear light; the Standard view gives the sRGB value back); in dark, a faint pool of light under
    the object (a soft ellipse) falls off to pure black at the edges."""
    ng = bpy.data.node_groups.new("Field", "CompositorNodeTree")
    ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    rl = ng.nodes.new("CompositorNodeRLayers")
    out = ng.nodes.new("NodeGroupOutput")
    field = (*lin(L["field"]), 1.0)
    bg = None
    if L.get("pool") is not None:
        # the pool as a picture made once (a soft elliptical falloff, smoothstep), not a per-frame
        # blur: a 400 px blur in the compositor costs seconds a frame
        node = ng.nodes.new("CompositorNodeImage")
        node.name = "Pool"
        bg = node.outputs["Image"]
    inv = ng.nodes.new("ShaderNodeMath")
    inv.operation = "SUBTRACT"
    inv.inputs[0].default_value = 1.0
    ng.links.new(rl.outputs["Alpha"], inv.inputs[1])
    mul = ng.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs[0].default_value = 1.0
    if bg is not None:
        ng.links.new(bg, mul.inputs[6])
    else:
        mul.inputs[6].default_value = field
    ng.links.new(inv.outputs[0], mul.inputs[7])
    add = ng.nodes.new("ShaderNodeMix")
    add.data_type = "RGBA"
    add.blend_type = "ADD"
    add.inputs[0].default_value = 1.0
    ng.links.new(mul.outputs[2], add.inputs[6])
    ng.links.new(rl.outputs["Image"], add.inputs[7])
    ng.links.new(add.outputs[2], out.inputs[0])
    return ng


def pool_image(ng, L, w, h):
    """Fills the compositor's Pool node with the dark field's pool at the render's size (made once
    per size, at render time: the size is only final then)."""
    node = ng.nodes.get("Pool")
    if node is None or (node.image is not None and tuple(node.image.size) == (w, h)):
        return
    import numpy as np
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((x + 0.5) / w - 0.5) ** 2 / 0.48 ** 2 + ((y + 0.5) / h - 0.47) ** 2 / 0.42 ** 2)
    k = np.clip(1.0 - d, 0.0, 1.0)
    k = k * k * (3 - 2 * k)
    pool, f0 = np.array(lin(L["pool"]), np.float32), np.array(lin(L["field"]), np.float32)
    px = np.empty((h, w, 4), np.float32)
    px[..., :3] = f0 + (pool - f0) * k[..., None]
    px[..., 3] = 1.0
    im = bpy.data.images.new(f"Pool{w}x{h}", w, h, alpha=False, float_buffer=True)
    im.colorspace_settings.name = "Linear Rec.709"
    im.pixels.foreach_set(px[::-1].ravel())         # Blender's rows run bottom-up
    node.image = im



# ---------------------------------------------------------------- the close-up (site hero)

def closeup(scene, coll, L):
    """params.mode "closeup": the site's hero still — Retro's hardware huge and close, on black.
    A dark anodised panel with a row of four machined dials (blue, green, white, orange caps,
    knurled aluminium, pointers, printed scale dots), three smaller dials behind, and a row of slim
    keycaps in front (one orange); a low camera on a long lens, the row cropping off the frame's
    edges; a strip rim from behind, a warm key from the left falling off to black, a cool kicker.
    (No printed scale dots: at this angle they read as debris.)
    Render 16:9 (e.g. --res 3840x2160). Returns the camera."""
    top = 0.3
    panel = rounded_slab("CPanel", 7.6, 4.8, top, 0.12, flat("CPanelMat", lin(0x111113), 0.55,
                                                              **{"Coat Weight": 0.12, "Coat Roughness": 0.25}),
                         coll, bevel=0.02)
    panel.location = (0, 0.25, top)
    alu = aluminium("CAlu", L.get("metal", (0.7, 0.7, 0.69)))
    tick = flat("CTick", lin(0x77757A), 0.5)

    def dial(name, x, y, scale, cap, ptr, angle, dots=True):
        root = G.empty(name, coll, (x, y, top))
        root.scale = (scale,) * 3
        root.rotation_euler = (0, 0, math.radians(angle))
        knob(name, 0.33, 0.30, lin(cap), ptr, alu, coll, root)
        R = 0.33 * scale
        for k in range(11 if dots else 0):      # the printed scale: 11 dots over 270°
            a = math.radians(225 - 27 * k)
            d = ring_mesh(f"{name}Tick{k}", [(0.02 * scale, 0.0), (0.02 * scale, 0.004)], tick, coll)
            d.location = (x + 1.45 * R * math.cos(a), y + 1.45 * R * math.sin(a), top)

    for i, (cap, ptr, ang) in enumerate(((0x0088E8, (1, 1, 1), 40), (0x00BD5F, (0.01, 0.02, 0.01), -35),
                                         (0xF4F4EF, (0.02, 0.02, 0.02), 75), (0xFF7300, (0.02, 0.01, 0.0), -60))):
        # no printed scale here: from this low angle the arcs are mostly hidden behind the knobs and
        # what's left reads as loose dots between them (owner: neat arcs or nothing)
        dial(f"CD{i}", -1.95 + 1.3 * i, 0.35, 1.35, cap, ptr, ang, dots=False)
    for i, (cap, ang) in enumerate(((0xF4F4EF, 20), (0x3A3A3E, -50), (0x3A3A3E, 65))):
        dial(f"CB{i}", -1.3 + 1.3 * i, 1.75, 0.85, cap, (0.02, 0.02, 0.02) if cap != 0x3A3A3E else (0.9, 0.9, 0.9), ang, dots=False)
    graphite = M.principled("CKey", lin(0x2A2A2D), 0.42, **{"Coat Weight": 0.35, "Coat Roughness": 0.2})
    orange = M.principled("CKeyOrange", lin(0xFF7300), 0.38, **{"Coat Weight": 0.35, "Coat Roughness": 0.2})
    for i, x in enumerate((-1.6, -0.55, 0.5, 1.55)):
        k = rounded_slab(f"CKey{i}", 0.84, 0.36, 0.16, 0.07, orange if i == 2 else graphite, coll, bevel=0.035)
        k.location = (x, -1.05, top + 0.14)

    def area(name, size, size_y, energy, color, loc, target, spread=None):
        ld = bpy.data.lights.new(name, "AREA")
        ld.shape = "RECTANGLE"
        ld.size, ld.size_y = size, size_y
        ld.energy, ld.color = energy, color
        if spread:
            ld.spread = math.radians(spread)
        ob = bpy.data.objects.new(name, ld)
        coll.objects.link(ob)
        ob.location = loc
        G.look_at(ob, loc, target)

    aim = Vector((0.1, 0.3, 0.6))
    area("CRim", 10.0, 0.6, 220, (1.0, 1.0, 1.0), (0.0, 7.0, 3.2), aim)
    area("CKeyLight", 2.5, 2.5, 140, (1.0, 0.95, 0.88), (-6.5, -3.0, 3.2), aim + Vector((-1.2, 0, 0)), spread=32)
    area("CKick", 0.6, 6.0, 45, (0.85, 0.92, 1.0), (6.5, 1.0, 1.8), aim)
    area("CTop", 8.0, 8.0, 2, (1.0, 1.0, 1.0), (0.0, 0.0, 10.0), aim)

    cd = bpy.data.cameras.new("Closeup")
    cd.lens = 180
    cd.sensor_width = 36
    cd.sensor_fit = "HORIZONTAL"
    cd.clip_start, cd.clip_end = 1.0, 500.0
    cd.dof.use_dof = True
    cd.dof.aperture_fstop = 2.4
    cam = bpy.data.objects.new("Closeup", cd)
    coll.objects.link(cam)
    target = Vector((0.15, 0.1, 0.55))
    el, az = math.radians(17), math.radians(-18)
    pos = target + 22.0 * Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    cam.location = pos
    G.look_at(cam, pos, target)
    cd.dof.focus_distance = (pos - Vector((0.0, 0.35, 0.6))).length       # the front dial row
    scene.camera = cam
    return cam


# ---------------------------------------------------------------- the set

def build(ctx):
    P = ctx.params
    theme, tone = P.get("theme", "retro"), P.get("tone", "light")
    L = LOOKS[f"{theme}-{tone}"]
    classic = theme == "classic"
    cutout = bool(P.get("cutout"))
    mode = P.get("mode", "loop")
    parts_dir = P["parts"]
    with open(os.path.join(parts_dir, "parts.json")) as f:
        man = json.load(f)
    ctx.light["exposure"] = 0.0      # the field is composited at its exact value: no view exposure
    lp = ctx.loop
    S = lp.seconds
    coll = ctx.coll("Reel")
    scene = ctx.scene
    AW, AH = man["size"]

    def xy(px, py):                  # assembly points (origin top left, y down) -> Blender x, y
        return (px - AW / 2) * PT, (AH / 2 - py) * PT

    # world: the studio — what glossy parts reflect, and a soft fill
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

    # the floor: a shadow catcher (the field itself is composited)
    floor = G.plane_uv("Floor", 400, 400, flat("FloorMat", (0.8, 0.8, 0.8), 0.9), coll, (0, 0, 0))
    floor.is_shadow_catcher = True

    if mode == "closeup":
        return output(scene, P, L, cutout, closeup(scene, coll, L))

    wside = flat("WindowSide", lin(L["window_side"]), 0.5)
    if classic:      # Classic's cards stand on clear glass: their edges catch the light
        side1 = flat("Side1", lin(L["glass"]), 0.15, **{"Transmission Weight": 1.0, "IOR": 1.45})
        _glassy(side1)
    else:
        side1 = flat("Side1", lin(L["side"]), 0.45, **{"Coat Weight": 0.2})
    side2 = flat("Side2", lin(L["side"]), 0.4, **{"Coat Weight": 0.25})
    alu = aluminium("Aluminium", L.get("metal", (0.8, 0.8, 0.79)))

    extent = []
    half = {}           # element root's name -> its half width, half height (the scroll's reveal)

    def element(e, name, depth_t, seat_top, side):
        """One element: an empty at its seat (the top of its slab), its slab and its picture."""
        x0, y0, x1, y1 = e["rect"]
        w, h = (x1 - x0) * PT, (y1 - y0) * PT
        cx, cy = xy((x0 + x1) / 2, (y0 + y1) / 2)
        top = seat_top + depth_t
        root = G.empty("El_" + name, coll, (cx, cy, top))
        half[root.name] = (w / 2, h / 2)
        r = min(e["radius"] * PT, 0.5 * min(w, h) - 1e-4)
        s = rounded_slab("Slab_" + name, w - 0.002, h - 0.002, depth_t + SEAT, r, side, coll,
                         bevel=min(0.012, depth_t * 0.4))
        s.parent = root
        pic = G.plane_uv("Pic_" + name, w, h, ui_mat("UI_" + name, os.path.join(parts_dir, e["png"]), L, False),
                         coll, (0, 0, 0.0015))
        pic.parent = root
        for sx in (-1, 1):
            for sy in (-1, 1):
                extent.append(Vector((cx + sx * w / 2, cy + sy * h / 2, top)))
        return root, top

    def dial(e, name, seat_top):
        """A Retro dial: the machined knob, scaled to the dial's size, seated in its socket."""
        x0, y0, x1, y1 = e["rect"]
        cx, cy = xy((x0 + x1) / 2, (y0 + y1) / 2)
        R = 0.5 * (x1 - x0) * PT * 0.94
        root = G.empty("Dial_" + name, coll, (cx, cy, seat_top))
        half[root.name] = (R, R)
        root.scale = (R / 0.33,) * 3
        cap = [v / 255 for v in e.get("cap", (240, 240, 236))]
        bright = 0.2126 * cap[0] + 0.7152 * cap[1] + 0.0722 * cap[2]
        blueish = cap[2] > cap[0] + 0.25
        ptr = (1, 1, 1) if blueish else (0.02, 0.02, 0.02)
        knob("Knob_" + name, 0.33, 0.30, lin(tuple(cap)), ptr, alu, coll, root)
        for sx in (-1, 1):
            for sy in (-1, 1):
                extent.append(Vector((cx + sx * R, cy + sy * R, seat_top + 0.36 * R / 0.33)))
        return root

    # the chassis: each module's base rests on the field
    items = []          # (root, rest z, kind, level) in landing order
    parent = []         # per item: the index of the item it sits on (None: on the chassis)
    for m in man["modules"]:
        d = BASE.get(m["name"], 0.12)
        base, mtop = element(m, "M_" + m["name"], d - SEAT, 0.0, wside)
        for i, c in enumerate(m["children"]):
            nm = f"{m['name'][0]}{i}"
            if c["kind"] == "dial":
                if classic:
                    continue
                items.append((dial(c, nm, mtop), mtop, "dial", 1))
                parent.append(None)
                continue
            root, ctop = element(c, nm, THICK[0], mtop - SEAT, side1)
            items.append((root, ctop, c["kind"], 1))
            parent.append(None)
            pi = len(items) - 1
            for j, k in enumerate(c.get("children", [])):
                if k["kind"] == "dial":
                    items.append((dial(k, f"{nm}_{j}", ctop), ctop, "dial", 2))
                    parent.append(pi)
                    continue
                kr, ktop = element(k, f"{nm}_{j}", THICK[1], ctop - SEAT, side2)
                items.append((kr, ktop, k["kind"], 2))
                parent.append(pi)
    N = len(items)
    print(f"REEL elements: {N} ({sum(1 for it in items if it[2] == 'dial')} dials)", flush=True)

    # ---------------------------------------------------------------- light
    def area(name, size, energy, color, loc, target, size_y=None, spread=None):
        ld = bpy.data.lights.new(name, "AREA")
        ld.shape = "RECTANGLE"
        ld.size = size
        ld.size_y = size_y or size
        ld.energy = energy * L["light_k"]
        ld.color = color
        if spread:
            ld.spread = math.radians(spread)
        ob = bpy.data.objects.new(name, ld)
        coll.objects.link(ob)
        ob.location = loc
        G.look_at(ob, loc, target)
        return ob

    centre = sum(extent, Vector()) / len(extent)
    c0 = Vector((centre.x, centre.y, 0.3))
    if L["rig"] == "soft":
        # one big soft source overhead (a little behind), a gentle soft key from the front-left for
        # shape, and a faint kicker from behind so edges hold a line on the grey
        area("Top", 30.0, 2000, (1.0, 1.0, 1.0), (c0.x - 2.0, c0.y + 4.0, 26.0), c0, size_y=20.0)
        area("Key", 8.0, 1100, (1.0, 0.985, 0.96), (c0.x - 14.0, c0.y + 6.0, 13.0), c0)
        area("Kick", 18.0, 240, (1.0, 1.0, 1.0), (c0.x + 2.0, c0.y + 18.0, 5.0), c0, size_y=2.5)
    else:
        # low key on black: a long strip rim from behind and above, a smaller key from the left with
        # a limited spread (its light falls off across the object), a cool strip kicker on the
        # right, and a dim overhead so the UI's own light reads as light
        area("Rim", 28.0, 2200, (1.0, 1.0, 1.0), (c0.x, c0.y + 15.0, 7.5), c0, size_y=1.4)
        area("Key", 4.0, 900, (1.0, 0.97, 0.93), (c0.x - 14.0, c0.y - 6.0, 11.0), c0, spread=70)
        area("Kick", 1.6, 420, (0.86, 0.92, 1.0), (c0.x + 15.0, c0.y + 1.0, 4.5), c0, size_y=12.0)
        area("Top", 30.0, 520, (1.0, 1.0, 1.0), (c0.x, c0.y + 2.0, 26.0), c0, size_y=20.0)

    # ---------------------------------------------------------------- camera
    cd = bpy.data.cameras.new("Hero")
    cd.sensor_width = 36
    cd.sensor_fit = "HORIZONTAL"
    cd.clip_start = 1.0
    cd.clip_end = 3000.0
    if P.get("fstop"):
        cd.dof.use_dof = True
        cd.dof.aperture_fstop = P["fstop"]
    cam = bpy.data.objects.new("Hero", cd)
    coll.objects.link(cam)
    scene.camera = cam
    aspect = 1.6                              # the films and stills are 16:10

    def direction(az, el):
        az, el = math.radians(az), math.radians(el)
        return Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))

    if mode == "flat":
        # straight down, orthographic: the flat app as a product shot
        cd.type = "ORTHO"
        xs, ys = [p.x for p in extent], [p.y for p in extent]
        cd.ortho_scale = max((max(xs) - min(xs)) / FLAT_FILL, (max(ys) - min(ys)) * aspect / FLAT_FILL)
        cam.location = ((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, 80.0)
        cam.rotation_euler = (0, 0, 0)
        dist, dvec = None, None
    else:
        cd.lens = LENS

        def project(pos, look, pts):
            f = (look - pos).normalized()
            r = f.cross(Vector((0, 0, 1))).normalized()
            u = r.cross(f)
            k = LENS / 18
            return [((p - pos).dot(r) / (p - pos).dot(f) * k, (p - pos).dot(u) / (p - pos).dot(f) * k * aspect)
                    for p in pts]

        fw, fh = (FILL, HEIGHT_FILL) if mode == "loop" else (SCROLL_FILL, SCROLL_HEIGHT_FILL)

        def fit(az, el, loosen=0.0):
            """The distance that makes the assembled object fill fw of the width (or fh of the
            height) from this direction, and the lens shift that centres its projected bounds."""
            dv = direction(az, el)
            d = 80.0
            for _ in range(7):
                pr = project(centre + d * dv, centre, extent)
                xs, ys = [p[0] for p in pr], [p[1] for p in pr]
                d *= max((max(xs) - min(xs)) / (2 * (fw - loosen)), (max(ys) - min(ys)) / (2 * (fh - loosen)))
            pr = project(centre + d * dv, centre, extent)
            xs, ys = [p[0] for p in pr], [p[1] for p in pr]
            return d, dv, (max(xs) + min(xs)) / 4, (max(ys) + min(ys)) / 4 / aspect

        dist, dvec, cd.shift_x, cd.shift_y = fit(AZIMUTH, ELEVATION)
        print(f"REEL camera: distance {dist:.1f}, shift {cd.shift_x:.3f} {cd.shift_y:.3f}", flush=True)

        if mode == "scroll":
            # the close-up -> the 3/4 frame (see CLOSE_AT): one eased move (cosine ease in and
            # out); distance in log space; the look point goes from the close-up's corner to the
            # centre and the shift from 0 to the final one so that the corner's place on screen
            # moves linearly with the ease (w = s * d / dist keeps its offset ∝ s); no roll
            sx1, sy1 = cd.shift_x, cd.shift_y
            fx, fy = xy(*CLOSE_AT)
            focus = Vector((fx, fy, BASE["window"] - SEAT))
            d0 = CLOSE_WIDTH * LENS / 36.0
            cd.dof.use_dof = True

            def scroll_cam(t):
                x = min(max(t / (MOVE_END * S), 0.0), 1.0)
                s = 0.5 - 0.5 * math.cos(math.pi * x)
                d = d0 * (dist / d0) ** s
                w = s * d / dist
                look = focus.lerp(centre, w)
                pos = look + d * direction(CLOSE_AZ + (AZIMUTH - CLOSE_AZ) * s,
                                           CLOSE_EL + (ELEVATION - CLOSE_EL) * s)
                # depth of field: CLOSE_FSTOP at the close-up, opening to none (f/128) by s = 0.5
                k = min(s / 0.5, 1.0)
                fstop = CLOSE_FSTOP * (128.0 / CLOSE_FSTOP) ** (k * k * (3 - 2 * k))
                return pos, look, sx1 * s, sy1 * s, fstop

            def on_screen(t, p):
                """p's place in the frame at t (±1 = the frame's edges)."""
                pos, look, sx, sy, _ = scroll_cam(t)
                (u, v), = project(pos, look, [p])
                return u - 2 * sx, v - 2 * sy * aspect

    # ---------------------------------------------------------------- motion
    # landing times: evenly spaced, in landing order (each card, then what sits on it)
    if mode == "loop":
        T0, T1, FALL = 0.45, 4.5, 0.40
        LIFT0, LIFT1, RISE = 6.4, 7.25, 0.30
    else:                       # scroll: one way; flat: everything seated from the start
        T0, T1, FALL = 0.30, 0.72 * S, 0.30       # assembled well before the camera settles
        LIFT0 = LIFT1 = RISE = None
    land = [T0 + (T1 - T0) * i / max(N - 1, 1) for i in range(N)]
    if mode == "flat":
        land = [-10.0] * N
    if mode == "scroll":
        # in the order the camera reveals them: an element lands a beat after its centre comes
        # well into the frame (nearest the close-up first), at least GAP after the one before
        # and after what it sits on; all seated (with their spring) before the hold
        # (revealed: its centre, or an eighth of it, inside the frame's inner 80 %)
        # — but never more than MAXGAP after the one before (the next ones then land at the
        # frame's edge as it opens out, instead of a pause)
        T0, GAP, LAG, AFTER, MAXGAP = 0.9, 0.045, 0.12, 0.14, 0.3
        LAST = MOVE_END * S - 0.5
        frames = [lp.t(f) for f in range(1, lp.frames + 1)]

        def reveal(i):
            root = items[i][0]
            c, (hw, hh) = Vector(root.location), half[root.name]
            pts = [c + Vector((hw * a / 2.5, hh * b / 2.5, 0)) for a in range(-2, 3) for b in range(-2, 3)]
            for t in frames:
                inside = [abs(u) < 0.8 and abs(v) < 0.8 for u, v in (on_screen(t, p) for p in pts)]
                if inside[12] or sum(inside) >= 3:
                    return t
            return frames[-1]

        rv = [reveal(i) for i in range(N)]
        rv = [rv[i] if parent[i] is None else max(rv[i], rv[parent[i]]) for i in range(N)]
        fx, fy = focus.x, focus.y
        order = sorted(range(N), key=lambda i: (rv[i], items[i][3], (items[i][0].location.x - fx) ** 2
                                                + (items[i][0].location.y - fy) ** 2))
        land = [0.0] * N
        prev = T0 - GAP
        for i in order:
            land[i] = min(max(T0, rv[i] + LAG, prev + GAP,
                              land[parent[i]] + AFTER if parent[i] is not None else 0.0), prev + MAXGAP)
            prev = land[i]
        hi = max(land)
        if hi > LAST:          # too late for the hold: squeeze the schedule (order kept)
            land = [T0 + (l - T0) * (LAST - T0) / (hi - T0) for l in land]
        print("REEL landing: " + " ".join(f"{land[i]:.2f}" for i in order), flush=True)
    lift = None if LIFT0 is None else [LIFT0 + (LIFT1 - LIFT0) * (N - 1 - i) / max(N - 1, 1) for i in range(N)]

    def bounce(s, kind):
        """The seat: a small press below rest and a damped spring back (a keycap seating)."""
        if s < 0 or s > 0.4:
            return 0.0
        depth = 0.022 if kind in ("dial", "key", "press") else 0.03
        return -depth * math.exp(-s / 0.06) * math.sin(math.pi * s / 0.075)

    def zpos(i, t):
        """(z offset above rest, visible) of item i at t."""
        L0 = land[i]
        if t < L0 - FALL:
            return PARK, False
        if t < L0:
            p = (t - (L0 - FALL)) / FALL
            return (SCROLL_DROP if mode == "scroll" else DROP) * (1 - p * p), True
        if lift is not None and t >= lift[i]:
            q = (t - lift[i]) / RISE
            return (DROP * q * q, True) if q < 1 else (PARK, False)
        return bounce(t - L0, items[i][2]), True

    press_i = next((i for i, it in enumerate(items) if it[2] == "press"), None)
    dial_i = [i for i, it in enumerate(items) if it[2] == "dial"]
    a_start = [math.radians(v) for v in (40, -25, 70, -60, 15, -80, 55, -10, 30)]

    def dial_angle(k, i, t):
        a = a_start[k % len(a_start)]
        a += math.radians(-75) * smoothstep(land[i] + 0.15, land[i] + 0.75, t)       # seats, then turns
        if mode == "loop":                                                          # the hold: turn again
            t0 = 4.9 + 0.12 * k
            a += math.radians(60 if k % 2 else -50) * smoothstep(t0, t0 + 0.6, t)
        return a

    def pose(t):
        if mode == "loop":
            sway = SWAY * math.sin(math.tau * t / S)
            pos = centre + dist * direction(AZIMUTH + sway, ELEVATION)
            cam.location = pos
            G.look_at(cam, pos, centre)
        elif mode == "scroll":
            pos, look, sx, sy, fstop = scroll_cam(t)
            cam.location = pos
            G.look_at(cam, pos, look)
            cd.shift_x, cd.shift_y = sx, sy
            cd.dof.focus_distance = (look - pos).length
            cd.dof.aperture_fstop = fstop
        for i, (root, rest, kind, lvl) in enumerate(items):
            dz, vis = zpos(i, t)
            if i == press_i and mode == "loop":
                dz -= 0.03 * (smoothstep(5.55, 5.62, t) - smoothstep(5.78, 5.93, t))
            # parked: under the floor (the shadow catcher hides it from the camera, the lights and
            # every reflection) — never hidden or scaled to nothing: changing what's visible makes
            # Cycles rebuild the scene, seconds a frame
            root.location.z = rest + dz if vis else PARK
            if kind == "dial":
                root.rotation_euler = (0, 0, dial_angle(dial_i.index(i), i, t))
            if mode == "scroll":     # fades in over the first 60 % of its short drop
                f = smoothstep(land[i] - FALL, land[i] - 0.4 * FALL, t)
                for ob in fading[i]:
                    ob["fade"] = f

    ids = ([cam] if dvec is not None else []) + [it[0] for it in items]
    fading = [[ob for ob in it[0].children_recursive if ob.type == "MESH"] for it in items]
    if mode == "scroll":
        ids += [(cd, "shift_x"), (cd, "shift_y"), (cd, "dof.focus_distance"), (cd, "dof.aperture_fstop")]
        add_fade(scene, exclude=("FloorMat",))
        ids += [(ob, '["fade"]') for obs in fading for ob in obs]
    lp.bake(ids, pose, props=("location", "rotation_euler"))
    return output(scene, P, L, cutout, cam)


def add_fade(scene, exclude=()):
    """Every material's alpha times the object's "fade" property (an object attribute, 1 unless
    keyed), and every mesh object gets fade = 1: the scroll sequence fades elements in."""
    for ob in scene.objects:
        if ob.type == "MESH":
            ob["fade"] = 1.0
    for mat in bpy.data.materials:
        if mat.name in exclude or not mat.node_tree:
            continue
        nt, ln = mat.node_tree.nodes, mat.node_tree.links
        b = nt.get("Principled BSDF")
        if b is None:
            continue
        at = nt.new("ShaderNodeAttribute")
        at.attribute_type = "OBJECT"
        at.attribute_name = "fade"
        alpha = b.inputs["Alpha"]
        if alpha.is_linked:
            src = alpha.links[0].from_socket
            mul = nt.new("ShaderNodeMath")
            mul.operation = "MULTIPLY"
            ln.new(src, mul.inputs[0])
            ln.new(at.outputs["Fac"], mul.inputs[1])
            ln.new(mul.outputs[0], alpha)
        else:
            mul = nt.new("ShaderNodeMath")
            mul.operation = "MULTIPLY"
            mul.inputs[0].default_value = alpha.default_value
            ln.new(at.outputs["Fac"], mul.inputs[1])
            ln.new(mul.outputs[0], alpha)
        _cutout(mat)


# ---------------------------------------------------------------- output

def output(scene, P, L, cutout, cam):
    """The render's colour, device and compositor (the field), set at render time."""
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
            for dv in prefs.devices:
                dv.use = dv.type != "CPU"
        except Exception as e:
            print("cycles device:", e)
    comp = None if cutout else field_compositor(scene, L)

    def put(owner, attr, value):
        # only when it changes: writing a render setting (even the same value) makes Cycles drop
        # its persistent data, and every frame would reload all the UI pictures
        if getattr(owner, attr) != value:
            setattr(owner, attr, value)

    def _out(sc, *_):
        put(sc.view_settings, "view_transform", view)
        try:
            put(sc.view_settings, "look", "None")
        except TypeError:
            pass
        put(sc.view_settings, "exposure", 0.0)
        put(sc.render, "film_transparent", True)
        put(sc.render, "use_persistent_data", True)           # ~60 UI pictures: load them once
        put(sc.render.image_settings, "color_depth", "8")    # dithered (render.dither_intensity)
        put(sc.render.image_settings, "color_mode", "RGBA" if cutout else "RGB")
        if comp is not None:
            pool_image(comp, L, sc.render.resolution_x * sc.render.resolution_percentage // 100,
                       sc.render.resolution_y * sc.render.resolution_percentage // 100)
            if sc.compositing_node_group != comp:
                sc.compositing_node_group = comp
            put(sc.render, "use_compositing", True)
        else:
            put(sc.render, "use_compositing", False)
        if sc.render.engine == "CYCLES":
            if device:
                put(sc.cycles, "device", "GPU")
            put(sc.cycles, "adaptive_threshold", 0.005)
            # one tile (dsfilm tiles at 1024 px for a 24 GB Mac; a GPU box doesn't need it): a hang
            # on stallion came right after a frame's second tile; and on NVIDIA, OptiX's own
            # denoiser on the GPU instead of OIDN
            put(sc.cycles, "use_auto_tile", False)
            if device == "OPTIX":
                put(sc.cycles, "denoiser", "OPTIX")
            put(sc.cycles, "texture_limit_render", "OFF")    # the UI pictures stay sharp
            put(sc.cycles, "blur_glossy", 0.5)
    bpy.app.handlers.render_pre.append(_out)
    return {"cameras": {"hero": cam}}
