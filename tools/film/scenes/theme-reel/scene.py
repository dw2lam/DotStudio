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
    scroll  ONE-WAY, for the site (10 s, 240 frames at 24 fps, scrubbed by the page's scroll): empty -> assembled, no
            lift-out. It opens on a close-up of the bare chassis — low and near, the window's top
            left corner (its title bar and the empty Screensaver socket) filling the frame — and
            pulls back in one slow eased move (dolly out, rise, swing round); half way it carries
            on rising, without a break, into the flat view straight from above (framed like the
            flat still, SCROLL_FILL), reached at 88 %; the last 12 % hold it. The elements land as
            the camera reveals them, nearest the close-up first, each lowered onto its seat while it
            fades in (what sits on a card after the card); seated, it sits nearly flush (SEATED_PROUD). As the camera settles into the
            flat view (the last UNLIT_SECONDS of the move) the light dims away while the UI turns
            to its own unlit colours, the shadows fade, the parts sink flush and the lens lengthens
            to near-orthographic: the held frame is the app itself, a straight screenshot (window
            and editor) on the field. A little depth of field at the close-up only, gone by the middle of the move
    flat    the assembled app straight from above, orthographic (the flat product shot)
    3d      the assembled app in the 3/4 view (the 3D product shot)

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
    cycles_hybrid  true: Cycles renders on the CPU alongside the GPU (benchmarks; off by default)
    denoiser  Cycles' denoiser for every machine (OPENIMAGEDENOISE, on the GPU), so the halves of a
           render split across a Mac and an NVIDIA box match (default: OIDN; OptiX's on OPTIX)
    frame_parts  another variant's prepared folder whose layout frames the shot: its size, its
           modules' rects and its camera fit (so Retro light's final frame lines up pixel for pixel
           with Retro dark's: their captures differ by a few points)
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
# the site's pictures (scroll, flat, 3d): a seated element sinks into its socket so only this share
# of its thickness stands proud — nearly flush, as the app looks (it keeps its full thickness while
# it drops in)
SEATED_PROUD = 1 / 3
MIN_PROUD = 0.0006          # scroll: a shown part's top never comes closer than this to what it sits on
DROP = 16.0                 # how far above its seat an element starts its fall (out of frame)
# the scroll sequence: the camera starts straight above, so a long fall would come at the lens —
# there an element arrives in screen space instead: a drop onto its seat while it fades in — slow
# enough to see each layer come down (owner, 2026-11-27: "elements slap onto the UI too fast …
# you can't even see the layering down"): it fades in high, is lowered (eased in and out) over
# SCROLL_FALL seconds and seats with a soft press; what sits on a card starts down only once the
# card is nearly seated
SCROLL_DROP = 1.1
SCROLL_FALL = 1.1
# …one feature at a time (owner: "as we scroll … highlights the new features … so you can demo each
# one on the website"): the parts come in by FEATURE, in this order, each feature in a stretch of
# its own (FEATURE_BASE + FEATURE_PER part seconds, its parts spread over it); the site names the
# feature while its stretch plays (REEL features prints the stretches, in frames)
FEATURES = ["screensaver", "keys", "gallery", "clocks", "wallpaper", "dials"]
FEATURE_START = 0.8
FEATURE_BASE, FEATURE_PER = 1.1, 0.07


def feature_of(module, own, card):
    """Which of FEATURES a part shows, from where it sits (assembly points)."""
    if module != "window":
        return "dials"
    cx, cy = (card[0] + card[2]) / 2, (card[1] + card[3]) / 2
    ox, oy = (own[0] + own[2]) / 2, (own[1] + own[3]) / 2
    if 60 < cy < 345 and card[2] - card[0] > 300:
        return "screensaver" if cx < 640 else "wallpaper"
    if cy > 415:                                   # the Scenes box: its last three are the clocks
        return "clocks" if (ox > 520 and oy > 660 and own != card) else "gallery"
    return "keys"                                  # the toolbar, sync, the filter keys
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
CLOSE_WIDTH = 3.0
MOVE_END = 0.92
REVEAL = 0.95               # a part counts as in view inside this share of the frame (±1 = its edges)
CLOSE_FSTOP = 4.0           # the close-up's depth of field (none from the middle of the move)
# the end of the scroll sequence: over the last UNLIT_SECONDS of the move, the lights and the world
# dim to nothing, every UI picture cross-fades to its captured colours unlit (emission 1 under the
# Standard view = the same sRGB), the shadows fade out of the field (compositor), the parts sink to
# UNLIT_PROUD and the knobs give way to their pictures, and the lens goes to UNLIT_LENS (the
# distance with it: the same framing, near-orthographic) — the final frame reads as a screenshot
UNLIT_SECONDS = 1.4
UNLIT_PROUD = 0.003
UNLIT_LENS = 700.0
# …and each window (the main window, the editor) keeps a soft macOS-like window shadow on the field,
# blended in as the lit shadows fade: a decal under it (two blurred copies of its outline, the
# wide one dropped a little), alpha WINDOW_SHADOW[tone] at its densest
WINDOW_SHADOW = {"dark": 0.75, "light": 0.42}
SHADOW_DROP = 0.10          # units the wide shadow sits below the window (~14 px at 2560)
SHADOW_BLUR = (0.04, 0.24)  # sigma of the contact and the wide shadow, units
SHADOW_MIX = (0.35, 0.65)   # their shares
# half way through the pull-back (s = BRANCH), the camera leaves it and carries on — position,
# speed and acceleration continuous (a quintic per channel) — into the flat view from above
BRANCH = 0.5
# the pull-back's pace: (share of the move, share of the zoom-out) keys, eased through monotonically —
# it leaves the close-up promptly once the Screensaver card is in, then opens out so each feature
# comes into view as its stretch begins (FEATURES), and settles slowly into the flat view
PACE = [(0.0, 0.0), (0.06, 0.02), (0.22, 0.5), (0.4, 0.68), (0.55, 0.8), (0.7, 0.9), (0.85, 0.97), (1.0, 1.0)]
FLAT_ELEVATION = 89.5       # straight down (a hair off 90°, so "up" stays the window's top)


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
    t.interpolation = "Linear"     # (Cycles' Cubic is a smoothing B-spline: soft UI text)
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
    # the unlit branch: the picture's own colour as emission (alpha x the object's fade), mixed in
    # by scene["unlit"] (0 unless the scroll's end keys it)
    out = next(n for n in nt if n.bl_idname == "ShaderNodeOutputMaterial")
    un = nt.new("ShaderNodeAttribute"); un.attribute_type = "VIEW_LAYER"; un.attribute_name = "unlit"
    fd = nt.new("ShaderNodeAttribute"); fd.attribute_type = "OBJECT"; fd.attribute_name = "fade"
    am = nt.new("ShaderNodeMath"); am.operation = "MULTIPLY"
    ln.new(t.outputs["Alpha"], am.inputs[0]); ln.new(fd.outputs["Fac"], am.inputs[1])
    em = nt.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 1.0
    ln.new(t.outputs["Color"], em.inputs["Color"])
    tr = nt.new("ShaderNodeBsdfTransparent")
    cut_ = nt.new("ShaderNodeMixShader")
    ln.new(am.outputs[0], cut_.inputs[0]); ln.new(tr.outputs[0], cut_.inputs[1]); ln.new(em.outputs[0], cut_.inputs[2])
    mx = nt.new("ShaderNodeMixShader")
    ln.new(un.outputs["Fac"], mx.inputs[0]); ln.new(b.outputs[0], mx.inputs[1]); ln.new(cut_.outputs[0], mx.inputs[2])
    ln.new(mx.outputs[0], out.inputs["Surface"])
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
    field_term = mul.outputs[2]
    if rl.outputs.get("Shadow Catcher") is not None:
        # the shadows as their own multiplier on the field, faded by the unlit end ("Unlit",
        # set each frame from scene["unlit"])
        unl = ng.nodes.new("ShaderNodeMath")
        unl.name, unl.operation = "Unlit", "ADD"
        unl.inputs[0].default_value = unl.inputs[1].default_value = 0.0
        sh = ng.nodes.new("ShaderNodeMix")
        sh.data_type = "RGBA"
        ng.links.new(unl.outputs[0], sh.inputs[0])
        ng.links.new(rl.outputs["Shadow Catcher"], sh.inputs[6])
        sh.inputs[7].default_value = (1.0, 1.0, 1.0, 1.0)
        m2 = ng.nodes.new("ShaderNodeMix")
        m2.data_type, m2.blend_type = "RGBA", "MULTIPLY"
        m2.inputs[0].default_value = 1.0
        ng.links.new(mul.outputs[2], m2.inputs[6])
        ng.links.new(sh.outputs[2], m2.inputs[7])
        field_term = m2.outputs[2]
    ng.links.new(field_term, add.inputs[6])
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
    ref = None
    if P.get("frame_parts"):
        with open(os.path.join(P["frame_parts"], "parts.json")) as f:
            ref = json.load(f)
        for m in man["modules"]:
            for rm in ref["modules"]:
                if rm["name"] == m["name"]:
                    m["rect"], m["radius"] = rm["rect"], rm["radius"]
    AW, AH = (ref or man)["size"]

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
    dial_pics = {}      # a dial root's name -> its captured picture (the scroll's unlit end)
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
        if mode == "scroll" and e.get("png"):
            w, h = (x1 - x0) * PT, (y1 - y0) * PT
            pic = G.plane_uv("DialPic_" + name, w, h,
                             ui_mat("UI_Dial_" + name, os.path.join(parts_dir, e["png"]), L, False),
                             coll, (cx, cy, seat_top + 0.002))
            dial_pics[root.name] = pic
        for sx in (-1, 1):
            for sy in (-1, 1):
                extent.append(Vector((cx + sx * R, cy + sy * R, seat_top + 0.36 * R / 0.33)))
        return root

    # the chassis: each module's base rests on the field
    items = []          # (root, rest z, kind, level) in landing order
    where = []          # per item: (module name, its own rect, its card's rect), points
    parent = []         # per item: the index of the item it sits on (None: on the chassis)
    seat_on = []        # per item: the top of the module it stands in
    for m in man["modules"]:
        d = BASE.get(m["name"], 0.12)
        base, mtop = element(m, "M_" + m["name"], d - SEAT, 0.0, wside)
        for i, c in enumerate(m["children"]):
            nm = f"{m['name'][0]}{i}"
            if c["kind"] == "dial":
                if classic:
                    continue
                items.append((dial(c, nm, mtop), mtop, "dial", 1))
                where.append((m["name"], c["rect"], c["rect"]))
                parent.append(None)
                seat_on.append(mtop)
                continue
            root, ctop = element(c, nm, THICK[0], mtop - SEAT, side1)
            items.append((root, ctop, c["kind"], 1))
            where.append((m["name"], c["rect"], c["rect"]))
            parent.append(None)
            seat_on.append(mtop)
            pi = len(items) - 1
            for j, k in enumerate(c.get("children", [])):
                if k["kind"] == "dial":
                    items.append((dial(k, f"{nm}_{j}", ctop), ctop, "dial", 2))
                    where.append((m["name"], k["rect"], c["rect"]))
                    parent.append(pi)
                    seat_on.append(mtop)
                    continue
                kr, ktop = element(k, f"{nm}_{j}", THICK[1], ctop - SEAT, side2)
                items.append((kr, ktop, k["kind"], 2))
                where.append((m["name"], k["rect"], c["rect"]))
                parent.append(pi)
                seat_on.append(mtop)
    N = len(items)
    print(f"REEL elements: {N} ({sum(1 for it in items if it[2] == 'dial')} dials)", flush=True)
    if mode in ("scroll", "flat", "3d"):
        sink = []
        for i, (root, rest, kind, lvl) in enumerate(items):
            own = 0.0 if kind == "dial" else (1 - SEATED_PROUD) * THICK[lvl - 1]
            sink.append(own + (sink[parent[i]] if parent[i] is not None else 0.0))
        items = [(root, rest - k, kind, lvl) for (root, rest, kind, lvl), k in zip(items, sink)]
        for root, rest, _, _ in items:
            root.location.z = rest
    if ref is not None:
        extent = frame_points(ref, classic, xy)

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
        lights.append(ob)
        return ob

    lights = []
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

            # the pull-back's pace (owner: "zoom out really slowly"): PACE, in log distance
            px_ = [k[0] for k in PACE]
            py_ = [k[1] for k in PACE]
            dl_ = [(py_[j + 1] - py_[j]) / (px_[j + 1] - px_[j]) for j in range(len(PACE) - 1)]
            m_ = [0.0] * len(PACE)
            for j in range(1, len(PACE) - 1):
                if dl_[j - 1] * dl_[j] > 0:
                    h0, h1 = px_[j] - px_[j - 1], px_[j + 1] - px_[j]
                    w1, w2 = 2 * h1 + h0, h1 + 2 * h0
                    m_[j] = (w1 + w2) / (w1 / dl_[j - 1] + w2 / dl_[j])

            def ramp(x):
                """PACE, eased through monotonically (still at both ends)."""
                x = min(max(x, 0.0), 1.0)
                j = min(max(i for i in range(len(PACE) - 1) if px_[i] <= x), len(PACE) - 2)
                h = px_[j + 1] - px_[j]
                u = (x - px_[j]) / h
                return ((2 * u ** 3 - 3 * u * u + 1) * py_[j] + (u ** 3 - 2 * u * u + u) * h * m_[j]
                        + (-2 * u ** 3 + 3 * u * u) * py_[j + 1] + (u ** 3 - u * u) * h * m_[j + 1])

            def ramp_inv(s_):
                lo, hi = 0.0, 1.0
                for _ in range(50):
                    mid = (lo + hi) / 2
                    lo, hi = (mid, hi) if ramp(mid) < s_ else (lo, mid)
                return (lo + hi) / 2

            def pull(t):
                """The pull-back towards the 3/4 frame as channels: az, el, ln d, look xyz, shift."""
                x = min(max(t / (MOVE_END * S), 0.0), 1.0)
                s = ramp(x)
                d = d0 * (dist / d0) ** s
                w = s                                # the view drifts on towards the middle as it opens
                look = focus.lerp(centre, w)
                return [CLOSE_AZ + (AZIMUTH - CLOSE_AZ) * s, CLOSE_EL + (ELEVATION - CLOSE_EL) * s,
                        math.log(d), look.x, look.y, look.z, sx1 * s, sy1 * s], s

            # the branch: where the pull-back is at s = BRANCH, with its speed and acceleration
            tb = MOVE_END * S * ramp_inv(BRANCH)
            te, h = MOVE_END * S, 1e-3
            c0_, c1_, c2_ = pull(tb - h)[0], pull(tb)[0], pull(tb + h)[0]
            vel = [(b - a) / (2 * h) for a, b in zip(c0_, c2_)]
            acc = [(a - 2 * m + b) / (h * h) for a, m, b in zip(c0_, c1_, c2_)]
            dfl, _, sxf, syf = fit(0.0, FLAT_ELEVATION)
            end = [0.0, FLAT_ELEVATION, math.log(dfl), centre.x, centre.y, centre.z, sxf, syf]
            print(f"REEL branch at {tb:.2f} s; flat: distance {dfl:.1f}, shift {sxf:.3f} {syf:.3f}", flush=True)

            def scroll_cam(t):
                if t <= tb:
                    ch, s = pull(max(t, 0.0))
                else:
                    T = te - tb
                    u = min((t - tb) / T, 1.0)
                    u3, u4, u5 = u ** 3, u ** 4, u ** 5
                    h0 = 1 - 10 * u3 + 15 * u4 - 6 * u5
                    h1 = u - 6 * u3 + 8 * u4 - 3 * u5
                    h2 = 0.5 * u * u - 1.5 * u3 + 1.5 * u4 - 0.5 * u5
                    h5 = 10 * u3 - 15 * u4 + 6 * u5
                    ch = [h0 * p0 + h1 * v * T + h2 * a * T * T + h5 * p1
                          for p0, v, a, p1 in zip(c1_, vel, acc, end)]
                    s = 1.0
                az, el, ld, lx, ly, lz, sx, sy = ch
                look = Vector((lx, ly, lz))
                pos = look + math.exp(ld) * direction(az, el)
                # depth of field: CLOSE_FSTOP at the close-up, opening to none (f/128) by s = 0.5
                k = min(s / 0.5, 1.0)
                fstop = CLOSE_FSTOP * (128.0 / CLOSE_FSTOP) ** (k * k * (3 - 2 * k))
                return pos, look, sx, sy, fstop

            def on_screen(t, p):
                """p's place in the frame at t (±1 = the frame's edges)."""
                pos, look, sx, sy, _ = scroll_cam(t)
                (u, v), = project(pos, look, [p])
                return u - 2 * sx, v - 2 * sy * aspect

    if mode == "scroll":
        u0, u1 = MOVE_END * S - UNLIT_SECONDS, MOVE_END * S
        lit = [(ob.data, ob.data.energy) for ob in lights]
        world_k = bg.inputs["Strength"].default_value
        flush = []           # how far each part sinks at the end (with what it sits on)
        for i, (root, rest, kind, lvl) in enumerate(items):
            # (a seated part stands THICK x SEATED_PROUD - SEAT above what it sits on)
            own = 0.0 if kind == "dial" else max(SEATED_PROUD * THICK[lvl - 1] - SEAT - UNLIT_PROUD, 0.0)
            flush.append(own + (flush[parent[i]] if parent[i] is not None else 0.0))
        scene["unlit"] = 0.0
        for m in man["modules"]:
            x0_, y0_, x1_, y1_ = m["rect"]
            cx_, cy_ = xy((x0_ + x1_) / 2, (y0_ + y1_) / 2)
            window_shadow("Shadow_" + m["name"], cx_, cy_, (x1_ - x0_) * PT, (y1_ - y0_) * PT,
                          m.get("radius", 10) * PT, coll, tone)
        try:                 # the shadows as a pass of their own (the compositor fades them)
            scene.view_layers[0].cycles.use_pass_shadow_catcher = True
        except Exception as e:
            print("shadow catcher pass:", e)

        def unlit_k(t):
            return smoothstep(u0, u1, t)

        def unlit_pose(t, look):
            k = unlit_k(t)
            scene["unlit"] = k
            for ld, e in lit:
                ld.energy = e * (1 - k)
            bg.inputs["Strength"].default_value = world_k * (1 - k)
            lens = LENS * (UNLIT_LENS / LENS) ** k
            cam.location = look + (cam.location - look) * (lens / LENS)
            cd.lens = lens
            # focus where the camera now is (it was set before this move: the whole unlit end
            # came out of focus), and the same physical aperture as the lens lengthens
            cd.dof.focus_distance = (look - cam.location).length
            cd.dof.aperture_fstop = cd.dof.aperture_fstop * (lens / LENS)

    # ---------------------------------------------------------------- motion
    # landing times: evenly spaced, in landing order (each card, then what sits on it)
    if mode == "loop":
        T0, T1, FALL = 0.45, 4.5, 0.40
        LIFT0, LIFT1, RISE = 6.4, 7.25, 0.30
    else:                       # scroll: one way; flat: everything seated from the start
        T0, T1, FALL = 0.30, 0.72 * S, (SCROLL_FALL if mode == "scroll" else 0.30)
        LIFT0 = LIFT1 = RISE = None
    land = [T0 + (T1 - T0) * i / max(N - 1, 1) for i in range(N)]
    if mode in ("flat", "3d"):
        land = [-10.0] * N
    if mode == "scroll":
        # by feature (FEATURES), each in its stretch: its parts spread over it, cards before what
        # sits on them (AFTER), nearest the close-up first; never before the camera has the part
        # in view (LAG after it's revealed: its centre, or an eighth of it, inside the frame's
        # inner 80 %)
        GAP, LAG, AFTER = 0.08, 0.2, 0.6
        LAST = MOVE_END * S - UNLIT_SECONDS - 0.3   # all seated before the lights start to dim
        frames = [lp.t(f) for f in range(1, lp.frames + 1)]

        def reveal(i):
            root = items[i][0]
            c, (hw, hh) = Vector(root.location), half[root.name]
            pts = [c + Vector((hw * a / 2.5, hh * b / 2.5, 0)) for a in range(-2, 3) for b in range(-2, 3)]
            for t in frames:
                inside = [abs(u) < REVEAL and abs(v) < REVEAL for u, v in (on_screen(t, p) for p in pts)]
                if inside[12] or sum(inside) >= 3:
                    return t
            return frames[-1]

        rv = [reveal(i) for i in range(N)]
        rv = [rv[i] if parent[i] is None else max(rv[i], rv[parent[i]]) for i in range(N)]
        fx, fy = focus.x, focus.y
        feat = [feature_of(*where[i]) for i in range(N)]
        for name in FEATURES:
            r_ = sorted(rv[i] for i in range(N) if feat[i] == name)
            if r_:
                print(f"REEL reveal {name}: {len(r_)} parts, {r_[0]:.2f}..{r_[len(r_) // 2]:.2f}..{r_[-1]:.2f} s", flush=True)
        land = [0.0] * N
        t0 = FEATURE_START
        stretches = []
        # the features in the order the camera brings them in (by when most of each is in view)
        med = {n: sorted(rv[i] for i in range(N) if feat[i] == n) for n in FEATURES}
        seq = sorted((n for n in FEATURES if med[n]), key=lambda n: (n != FEATURES[0], med[n][len(med[n]) // 2]))
        for name in seq:
            mine = [i for i in range(N) if feat[i] == name]
            if not mine:
                continue
            mine.sort(key=lambda i: (rv[i], items[i][3], (items[i][0].location.x - fx) ** 2 + (items[i][0].location.y - fy) ** 2))
            span = FEATURE_BASE + FEATURE_PER * len(mine)
            step = max(span - FALL, 0.0) / max(len(mine) - 1, 1)
            first = None
            prev = -9.0
            for k, i in enumerate(mine):
                land[i] = max(t0 + FALL + step * k, rv[i] + LAG, prev + GAP,
                              land[parent[i]] + AFTER if parent[i] is not None else 0.0)
                prev = land[i]
                first = land[i] - FALL if first is None else min(first, land[i] - FALL)
            # the stretch is the plan; a part the camera hasn't reached yet (the toolbar's keys)
            # lands when it has, without holding up the next feature
            stretches.append([name, first, t0 + span])
            t0 = t0 + span
        hi = max(land)
        T0 = min(land) - FALL
        if hi > LAST:          # too late for the hold: squeeze the schedule (order kept)
            print(f"REEL squeeze {hi:.2f} -> {LAST:.2f}", flush=True)
            k = (LAST - T0) / (hi - T0)
            land = [T0 + (l - T0) * k for l in land]
            stretches = [[n, T0 + (a - T0) * k, T0 + (b - T0) * k] for n, a, b in stretches]
        fps = lp.frames / S
        print("REEL features: " + " ".join(f"{n}:{a:.2f}-{b:.2f}s/f{int(a * fps) + 1}-{int(b * fps) + 1}"
                                           for n, a, b in stretches), flush=True)
        order = sorted(range(N), key=lambda i: land[i])
        print("REEL landing: " + " ".join(f"{land[i]:.2f}" for i in order), flush=True)
    lift = None if LIFT0 is None else [LIFT0 + (LIFT1 - LIFT0) * (N - 1 - i) / max(N - 1, 1) for i in range(N)]

    def bounce(s, kind):
        """The seat: a small press below rest and a damped spring back (a keycap seating)."""
        if s < 0 or s > 0.4:
            return 0.0
        depth = 0.022 if kind in ("dial", "key", "press") else 0.03
        if mode == "scroll":     # lowered, not dropped: a softer press
            depth *= 0.5
        return -depth * math.exp(-s / 0.06) * math.sin(math.pi * s / 0.075)

    def zpos(i, t):
        """(z offset above rest, visible) of item i at t."""
        L0 = land[i]
        if t < L0 - FALL:
            return PARK, False
        if t < L0:
            p = (t - (L0 - FALL)) / FALL
            if mode == "scroll":     # lowered: eased in and out, so it settles rather than slaps
                return SCROLL_DROP * (1 - p) * (1 - p) * (1 + 2 * p), True
            return DROP * (1 - p * p), True
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
        elif mode == "3d":
            pos = centre + dist * dvec
            cam.location = pos
            G.look_at(cam, pos, centre)
        elif mode == "scroll":
            pos, look, sx, sy, fstop = scroll_cam(t)
            cam.location = pos
            G.look_at(cam, pos, look)
            cd.shift_x, cd.shift_y = sx, sy
            cd.dof.focus_distance = (look - pos).length
            cd.dof.aperture_fstop = fstop
            unlit_pose(t, look)
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
            if mode == "scroll":     # fades in over the first half of its drop
                f = smoothstep(land[i] - FALL, land[i] - 0.5 * FALL, t)
                k = unlit_k(t)
                if kind == "dial":   # the unlit end: the knob gives way to its picture
                    f *= 1 - k
                    if root.name in dial_pics:
                        dial_pics[root.name]["fade"] = k
                elif vis:            # …and the parts sink flush
                    root.location.z -= k * flush[i]
                if vis and kind != "dial":
                    # never into what it sits on: a seated part stands only ~1 cm proud, less than
                    # its press and its parent's spring, which would hide it for a frame or two
                    under = items[parent[i]][0].location.z if parent[i] is not None else seat_on[i]
                    if root.location.z < under + MIN_PROUD:
                        root.location.z = under + MIN_PROUD
                for ob in fading[i]:
                    ob["fade"] = f

    ids = ([cam] if dvec is not None else []) + [it[0] for it in items]
    fading = [[ob for ob in it[0].children_recursive if ob.type == "MESH"] for it in items]
    if mode == "scroll":
        ids += [(cd, "shift_x"), (cd, "shift_y"), (cd, "dof.focus_distance"), (cd, "dof.aperture_fstop")]
        ids += [(cd, "lens"), (scene, '["unlit"]'), (bg.inputs["Strength"], "default_value")]
        ids += [(ob.data, "energy") for ob in lights] + [(ob, '["fade"]') for ob in dial_pics.values()]
        add_fade(scene, exclude=("FloorMat",))
        ids += [(ob, '["fade"]') for obs in fading for ob in obs]
    lp.bake(ids, pose, props=("location", "rotation_euler"))
    return output(scene, P, L, cutout, cam)


def frame_points(man, classic, xy):
    """The points build() fits the camera to (each element's top corners, each dial's top), from
    a manifest alone — for params.frame_parts."""
    pts = []

    def rect(e, top):
        x0, y0, x1, y1 = e["rect"]
        w, h = (x1 - x0) * PT, (y1 - y0) * PT
        cx, cy = xy((x0 + x1) / 2, (y0 + y1) / 2)
        pts.extend(Vector((cx + sx * w / 2, cy + sy * h / 2, top)) for sx in (-1, 1) for sy in (-1, 1))

    def knob(e, seat):
        x0, y0, x1, y1 = e["rect"]
        cx, cy = xy((x0 + x1) / 2, (y0 + y1) / 2)
        R = 0.5 * (x1 - x0) * PT * 0.94
        pts.extend(Vector((cx + sx * R, cy + sy * R, seat + 0.36 * R / 0.33)) for sx in (-1, 1) for sy in (-1, 1))

    for m in man["modules"]:
        mtop = BASE.get(m["name"], 0.12) - SEAT
        rect(m, mtop)
        for c in m["children"]:
            if c["kind"] == "dial":
                if not classic:
                    knob(c, mtop)
                continue
            ctop = mtop - SEAT + THICK[0]
            rect(c, ctop)
            for k in c.get("children", []):
                if k["kind"] == "dial":
                    knob(k, ctop)
                else:
                    rect(k, ctop - SEAT + THICK[1])
    return pts


def window_shadow(name, cx, cy, w, h, r, coll, tone):
    """The unlit end's window shadow (see WINDOW_SHADOW): a plane on the floor under a window, its
    alpha a soft shadow of the window's rounded outline made here with numpy, black, shown by
    scene["unlit"]; seen by the camera only. Returns the object."""
    import numpy as np
    ppu, margin = 100, 1.0
    W, H = int(round((w + 2 * margin) * ppu)), int(round((h + 2 * margin) * ppu))
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    px, py = (xx + 0.5) / ppu - (w / 2 + margin), (H - yy - 0.5) / ppu - (h / 2 + margin)   # y up

    def outline(dy):
        qx = np.maximum(np.abs(px) - (w / 2 - r), 0)
        qy = np.maximum(np.abs(py - dy) - (h / 2 - r), 0)
        return (np.sqrt(qx * qx + qy * qy) <= r).astype(np.float32)

    def blur(a, sigma):
        k = max(1, int(round(np.sqrt(12 * (sigma * ppu) ** 2 / 3 + 1))) | 1)
        for _ in range(3):                         # three box passes ~ a gaussian
            for ax in (0, 1):
                pad = [(k // 2 + 1, k // 2) if i == ax else (0, 0) for i in range(2)]
                c = np.cumsum(np.pad(a, pad, mode="edge"), axis=ax)
                a = (np.take(c, range(k, c.shape[ax]), axis=ax) - np.take(c, range(0, c.shape[ax] - k), axis=ax)) / k
        return a

    alpha = SHADOW_MIX[0] * blur(outline(0.0), SHADOW_BLUR[0]) + SHADOW_MIX[1] * blur(outline(-SHADOW_DROP), SHADOW_BLUR[1])
    alpha = np.clip(alpha * WINDOW_SHADOW[tone], 0, 1)
    px_ = np.zeros((H, W, 4), np.float32)
    px_[..., 3] = alpha
    im = bpy.data.images.new(name + "Img", W, H, alpha=True, float_buffer=True)
    im.colorspace_settings.name = "Non-Color"
    im.pixels.foreach_set(px_[::-1].ravel())       # rows bottom-up
    im.pack()
    mat = bpy.data.materials.new(name + "Mat")
    mat.use_nodes = True
    nt, ln = mat.node_tree.nodes, mat.node_tree.links
    for n in list(nt):
        nt.remove(n)
    tx = nt.new("ShaderNodeTexImage"); tx.image = im; tx.extension = "CLIP"; tx.interpolation = "Linear"
    un = nt.new("ShaderNodeAttribute"); un.attribute_type = "VIEW_LAYER"; un.attribute_name = "unlit"
    mu = nt.new("ShaderNodeMath"); mu.operation = "MULTIPLY"
    ln.new(tx.outputs["Alpha"], mu.inputs[0]); ln.new(un.outputs["Fac"], mu.inputs[1])
    em = nt.new("ShaderNodeEmission"); em.inputs["Color"].default_value = (0, 0, 0, 1); em.inputs["Strength"].default_value = 0.0
    tr = nt.new("ShaderNodeBsdfTransparent")
    mx = nt.new("ShaderNodeMixShader")
    ln.new(mu.outputs[0], mx.inputs[0]); ln.new(tr.outputs[0], mx.inputs[1]); ln.new(em.outputs[0], mx.inputs[2])
    out = nt.new("ShaderNodeOutputMaterial")
    ln.new(mx.outputs[0], out.inputs["Surface"])
    _cutout(mat)
    ob = G.plane_uv(name, W / ppu, H / ppu, mat, coll, (cx, cy, 0.0008))
    for k in ("visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter", "visible_shadow"):
        try:
            setattr(ob, k, False)
        except Exception:
            pass
    return ob


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
                dv.use = dv.type != "CPU" or bool(P.get("cycles_hybrid"))   # hybrid: the CPU too
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
            un = comp.nodes.get("Unlit")
            if un is not None:
                un.inputs[0].default_value = float(sc.get("unlit", 0.0))
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
            if P.get("denoiser"):           # e.g. OPENIMAGEDENOISE on every machine of a split render
                put(sc.cycles, "denoiser", P["denoiser"])
                put(sc.cycles, "denoising_use_gpu", True)
            elif device == "OPTIX":
                put(sc.cycles, "denoiser", "OPTIX")
            put(sc.cycles, "texture_limit_render", "OFF")    # the UI pictures stay sharp
            # sharpness: Cycles' default pixel filter (1.5 px Blackman-Harris) and the denoiser both
            # soften the UI's text; filter_width narrows the one, denoise: false drops the other
            if P.get("filter_width") is not None:
                put(sc.cycles, "filter_width", float(P["filter_width"]))
            if P.get("denoise") is False:
                put(sc.cycles, "use_denoising", False)
            put(sc.cycles, "blur_glossy", 0.5)
    bpy.app.handlers.render_pre.append(_out)
    return {"cameras": {"hero": cam}}
