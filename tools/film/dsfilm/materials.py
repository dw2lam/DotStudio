"""Physically based materials, written for both Cycles and EEVEE.

All image textures are placed at real-world scale with box projection on object coordinates, so a
mesh needs no UVs: ``pbr(name, diff, nor, rough, size_m=0.5)`` tiles the image every 0.5 m. Keep
object scale applied (1,1,1) or the texture scales with the object.

    principled(name, color, rough, metal, **principled_inputs)
    pbr(name, diff, nor=None, rough=None, size_m=1, tint=None, desat=False, ...)
    ph_pbr(name, polyhaven_id, size_m, **kw)       # Poly Haven texture set from the cache
    acg_pbr(name, ambientcg_id, size_m, **kw)      # ambientCG set (adds Emission if present)
    noise_bump(mat, scale, strength, rough_var)    # micro-surface: bump + roughness wobble
    emission(name, color, strength)
    image_mat(name, path, ...)                     # UV-mapped printed sheet (posters, signs)
    thin_glass(name, refl=0.08, rain=, haze=)      # window pane: see-through + Fresnel reflection; rain on it
    facade_grid(name, wall, pitch, floor_h, ...)   # procedural building wall with windows (lit at night)
"""
import math
import os

import bpy

from . import assets


def _nodes(mat):
    if hasattr(mat, "use_nodes") and not mat.node_tree:
        mat.use_nodes = True
    return mat.node_tree.nodes, mat.node_tree.links


def _set(sock, v):
    if sock.type == "RGBA" and len(v) == 3:
        v = (*v, 1.0)
    sock.default_value = v


def principled(name, color=(0.8, 0.8, 0.8), rough=0.5, metal=0.0, **inputs):
    """Principled BSDF. Extra keyword args are Principled input names with spaces as given, e.g.
    principled("Bill", (1, .4, 0), .3, **{"Coat Weight": .5})."""
    mat = bpy.data.materials.new(name)
    nt, _ = _nodes(mat)
    b = nt.get("Principled BSDF")
    _set(b.inputs["Base Color"], color)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    for k, v in inputs.items():
        _set(b.inputs[k], v)
    return mat


def load_image(path, colorspace="sRGB"):
    im = bpy.data.images.load(path, check_existing=True)
    im.colorspace_settings.name = colorspace
    return im


def _tex(nt, ln, path, colorspace, vec, proj="BOX", blend=0.25):
    n = nt.new("ShaderNodeTexImage")
    n.image = load_image(path, colorspace)
    n.projection = proj
    if proj == "BOX":
        n.projection_blend = blend
    if vec is not None:
        ln.new(vec, n.inputs["Vector"])
    return n


def _mapping(nt, ln, size_m, coords="Object", rot=(0, 0, 0)):
    tc = nt.new("ShaderNodeTexCoord")
    mp = nt.new("ShaderNodeMapping")
    s = size_m if isinstance(size_m, (tuple, list)) else (size_m,) * 3
    mp.inputs["Scale"].default_value = tuple(1 / v for v in s)
    mp.inputs["Rotation"].default_value = rot
    ln.new(tc.outputs[coords], mp.inputs["Vector"])
    return mp.outputs["Vector"]


def pbr(name, diff, nor=None, rough=None, size_m=1.0, tint=None, desat=False, value=1.0, rough_mul=1.0,
        rough_add=0.0, nor_strength=1.0, coords="Object", proj="BOX", rot=(0, 0, 0), emission_map=None,
        emission_strength=0.0, **inputs):
    """Image-based PBR at real-world scale. `desat` greys the albedo (then `tint` multiplies), so a
    red fabric scan can become any colour while keeping its weave."""
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    b = nt.get("Principled BSDF")
    vec = _mapping(nt, ln, size_m, coords, rot)
    col = _tex(nt, ln, diff, "sRGB", vec, proj).outputs["Color"]
    if desat or value != 1.0:
        hs = nt.new("ShaderNodeHueSaturation")
        hs.inputs["Saturation"].default_value = 0.0 if desat else 1.0
        hs.inputs["Value"].default_value = (1.6 if desat else 1.0) * value
        ln.new(col, hs.inputs["Color"])
        col = hs.outputs["Color"]
    if tint:
        mx = nt.new("ShaderNodeMix")
        mx.data_type = "RGBA"
        mx.blend_type = "MULTIPLY"
        mx.inputs[0].default_value = 1.0          # Mix sockets by index: names repeat per data type
        ln.new(col, mx.inputs[6])                  # colour A
        _set(mx.inputs[7], tint)                  # colour B
        col = mx.outputs[2]
    ln.new(col, b.inputs["Base Color"])
    if rough and os.path.exists(rough):
        r = _tex(nt, ln, rough, "Non-Color", vec, proj)
        m = nt.new("ShaderNodeMath")
        m.operation = "MULTIPLY_ADD"
        m.inputs[1].default_value = rough_mul
        m.inputs[2].default_value = rough_add
        m.use_clamp = True
        ln.new(r.outputs["Color"], m.inputs[0])
        ln.new(m.outputs[0], b.inputs["Roughness"])
    if nor and os.path.exists(nor):
        n = _tex(nt, ln, nor, "Non-Color", vec, proj)
        nm = nt.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = nor_strength
        ln.new(n.outputs["Color"], nm.inputs["Color"])
        ln.new(nm.outputs["Normal"], b.inputs["Normal"])
    if emission_map and os.path.exists(emission_map):
        e = _tex(nt, ln, emission_map, "sRGB", vec, proj)
        ln.new(e.outputs["Color"], b.inputs["Emission Color"])
        b.inputs["Emission Strength"].default_value = emission_strength
    for k, v in inputs.items():
        _set(b.inputs[k], v)
    return mat


def ph_pbr(name, aid, size_m=1.0, res="2k", **kw):
    return pbr(name, assets.tex(aid, "diff", res), assets.tex(aid, "nor_gl", res), assets.tex(aid, "rough", res),
               size_m=size_m, **kw)


def acg_pbr(name, aid, size_m=1.0, res="2K", **kw):
    em = assets.acg(aid, "Emission", res)
    return pbr(name, assets.acg(aid, "Color", res), assets.acg(aid, "NormalGL", res), assets.acg(aid, "Roughness", res),
               size_m=size_m, emission_map=em if os.path.exists(em) else None, **kw)


def noise_bump(mat, scale=40.0, strength=0.05, detail=4.0, rough_var=0.0, stretch=None, distance=0.002):
    """Adds procedural micro-surface to a Principled material: a noise bump (chained after any
    existing normal map) and, if `rough_var`, a slow roughness wobble (smudges, wear)."""
    nt, ln = mat.node_tree.nodes, mat.node_tree.links
    b = nt.get("Principled BSDF")
    src = nt.new("ShaderNodeTexCoord").outputs["Object"]
    if stretch:
        mp = nt.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = stretch
        ln.new(src, mp.inputs["Vector"])
        src = mp.outputs["Vector"]
    nz = nt.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = scale
    nz.inputs["Detail"].default_value = detail
    ln.new(src, nz.inputs["Vector"])
    bump = nt.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    bump.inputs["Distance"].default_value = distance
    ln.new(nz.outputs["Fac"], bump.inputs["Height"])
    if b.inputs["Normal"].is_linked:
        ln.new(b.inputs["Normal"].links[0].from_socket, bump.inputs["Normal"])
    ln.new(bump.outputs["Normal"], b.inputs["Normal"])
    if rough_var and not b.inputs["Roughness"].is_linked:
        base = b.inputs["Roughness"].default_value
        mr = nt.new("ShaderNodeMapRange")
        mr.inputs["To Min"].default_value = max(base - rough_var, 0.02)
        mr.inputs["To Max"].default_value = min(base + rough_var, 1.0)
        nz2 = nt.new("ShaderNodeTexNoise")
        nz2.inputs["Scale"].default_value = max(scale * 0.06, 0.5)
        ln.new(src, nz2.inputs["Vector"])
        ln.new(nz2.outputs["Fac"], mr.inputs["Value"])
        ln.new(mr.outputs["Result"], b.inputs["Roughness"])
    return mat


def emission(name, color, strength):
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    nt.remove(nt.get("Principled BSDF"))
    em = nt.new("ShaderNodeEmission")
    _set(em.inputs["Color"], color)
    em.inputs["Strength"].default_value = strength
    ln.new(em.outputs[0], nt.get("Material Output").inputs["Surface"])
    return mat


def image_mat(name, path, rough=0.35, coat=0.0, emit=0.0, alpha=False):
    """A printed sheet on a UV-mapped plane (geometry.plane_uv): posters, signs, screens."""
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    b = nt.get("Principled BSDF")
    t = nt.new("ShaderNodeTexImage")
    t.image = load_image(path)
    t.extension = "CLIP"
    ln.new(t.outputs["Color"], b.inputs["Base Color"])
    if alpha:
        ln.new(t.outputs["Alpha"], b.inputs["Alpha"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Coat Weight"].default_value = coat
    if emit:
        ln.new(t.outputs["Color"], b.inputs["Emission Color"])
        b.inputs["Emission Strength"].default_value = emit
    return mat


def thin_glass(name, tint=(0.93, 0.97, 0.95), refl=0.08, rough=0.0, rain=False, smudge=0.0, up="Y",
               flow=(-1.0, -0.22), haze=0.0):
    """A thin pane: Transparent (no refraction offset, as a real thin pane) mixed with a Fresnel
    glossy reflection. Objects using it should also get ``visible_shadow = False`` (geometry.no_shadow)
    so sunlight passes.

    rain=True adds water on the glass and returns (mat, RainDriver): beads (static) and runnels
    that slide along `flow` (in the pane's own (along, up) axes — on a moving train the airflow
    pushes them back and a little down). Water darkens and distorts what's behind it, catches
    reflections, and clears little windows in the condensation (`haze`, heavier low on the pane).
    `up` is the pane's object-space up axis ("Y" for geometry.slab panes, "Z" otherwise).
    Call driver.set(phase) every frame with phase = t / loop (0..1) and keyframe driver.sockets;
    the runnels use two cross-faded layers so the motion loops seamlessly."""
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    nt.remove(nt.get("Principled BSDF"))
    out = nt.get("Material Output")
    tr = nt.new("ShaderNodeBsdfTransparent")
    _set(tr.inputs["Color"], tint)
    gl = nt.new("ShaderNodeBsdfGlossy")
    gl.inputs["Roughness"].default_value = rough
    if smudge:   # faint wipe marks: the reflection blurs a little in patches
        nz = nt.new("ShaderNodeTexNoise")
        nz.inputs["Scale"].default_value = 3.0
        nz.inputs["Detail"].default_value = 6.0
        ln.new(nt.new("ShaderNodeTexCoord").outputs["Object"], nz.inputs["Vector"])
        mr = nt.new("ShaderNodeMapRange")
        mr.inputs["From Min"].default_value = 0.45
        mr.inputs["From Max"].default_value = 0.75
        mr.inputs["To Min"].default_value = rough
        mr.inputs["To Max"].default_value = rough + smudge
        ln.new(nz.outputs["Fac"], mr.inputs["Value"])
        ln.new(mr.outputs["Result"], gl.inputs["Roughness"])
    fr = nt.new("ShaderNodeFresnel")
    fr.inputs["IOR"].default_value = 1.52
    mf = nt.new("ShaderNodeMath")
    mf.operation = "MULTIPLY_ADD"
    mf.inputs[1].default_value = 1.0
    mf.inputs[2].default_value = refl
    mf.use_clamp = True
    ln.new(fr.outputs[0], mf.inputs[0])
    see = tr.outputs[0]
    driver = None
    if rain:
        driver, water, v = _rain(nt, ln, gl, fr, up, flow)
        # what's behind a drop is refracted: darker, a little cooler
        dk = nt.new("ShaderNodeMix")
        dk.data_type = "RGBA"
        ln.new(water, dk.inputs[0])
        _set(dk.inputs[6], tint)
        _set(dk.inputs[7], tuple(c * 0.42 for c in tint))
        ln.new(dk.outputs[2], tr.inputs["Color"])
        # water catches much more reflection
        wr = nt.new("ShaderNodeMath")
        wr.operation = "MULTIPLY_ADD"
        wr.inputs[1].default_value = 0.55
        ln.new(water, wr.inputs[0])
        ln.new(fr.outputs[0], wr.inputs[2])
        ln.new(wr.outputs[0], mf.inputs[0])
        if haze:
            # condensation: a soft milky film, heavier toward the bottom of the pane, cleared by drops
            low = nt.new("ShaderNodeMapRange")
            low.inputs["From Min"].default_value = 1.45
            low.inputs["From Max"].default_value = 1.0
            low.inputs["To Min"].default_value = haze * 0.45
            low.inputs["To Max"].default_value = haze
            ln.new(v, low.inputs["Value"])
            clear = nt.new("ShaderNodeMath")
            clear.operation = "MULTIPLY"
            inv = nt.new("ShaderNodeMath")
            inv.operation = "SUBTRACT"
            inv.inputs[0].default_value = 1.0
            ln.new(water, inv.inputs[1])
            ln.new(low.outputs["Result"], clear.inputs[0])
            ln.new(inv.outputs[0], clear.inputs[1])
            fog = nt.new("ShaderNodeBsdfDiffuse")
            _set(fog.inputs["Color"], (0.62, 0.65, 0.66))
            fm = nt.new("ShaderNodeMixShader")
            ln.new(clear.outputs[0], fm.inputs["Fac"])
            ln.new(tr.outputs[0], fm.inputs[1])
            ln.new(fog.outputs[0], fm.inputs[2])
            see = fm.outputs[0]
    mx = nt.new("ShaderNodeMixShader")
    ln.new(mf.outputs[0], mx.inputs["Fac"])
    ln.new(see, mx.inputs[1])
    ln.new(gl.outputs[0], mx.inputs[2])
    ln.new(mx.outputs[0], out.inputs["Surface"])
    try:
        mat.surface_render_method = "BLENDED"
    except Exception:
        pass
    return (mat, driver) if rain else mat


class RainDriver:
    """Animates a rain pane's runnels: two layers slide along the flow and cross-fade, each jumping
    back while invisible, so phase 0 and phase 1 look identical (a seamless loop)."""

    def __init__(self, off_a, off_b, w_a, cycles=6, travel=2.6):
        self.off_a, self.off_b, self.w_a = off_a, off_b, w_a
        self.cycles, self.travel = cycles, travel
        self.sockets = [(off_a, "default_value"), (off_b, "default_value"), (w_a, "default_value")]

    def set(self, phase):
        pa = (phase * self.cycles) % 1.0
        pb = (pa + 0.5) % 1.0
        self.off_a.default_value = pa * self.travel
        self.off_b.default_value = pb * self.travel + 17.3        # a different patch of the pattern
        self.w_a.default_value = 1.0 - abs(2.0 * pa - 1.0)


def _rain(nt, ln, gl, fr, up, flow):
    """Returns (driver, water mask socket, pane-up coordinate socket)."""
    def m(op, a, b=None, c=None):
        n = nt.new("ShaderNodeMath")
        n.operation = op
        for i, v in enumerate((a, b, c)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                ln.new(v, n.inputs[i])
        return n.outputs[0]

    def value(v=0.0):
        n = nt.new("ShaderNodeValue")
        n.outputs[0].default_value = v
        return n.outputs[0]

    tc = nt.new("ShaderNodeTexCoord")
    sep = nt.new("ShaderNodeSeparateXYZ")
    ln.new(tc.outputs["Object"], sep.inputs[0])
    u, v = sep.outputs["X"], sep.outputs["Y" if up == "Y" else "Z"]

    def vor(x, y, scale):
        cb = nt.new("ShaderNodeCombineXYZ")
        ln.new(x, cb.inputs[0])
        ln.new(y, cb.inputs[1])
        vo = nt.new("ShaderNodeTexVoronoi")
        vo.inputs["Scale"].default_value = scale
        ln.new(cb.outputs[0], vo.inputs["Vector"])
        return vo

    def drops(vo, radius, keep):
        """Round water where the cell's random value passes `keep`, sized by that value."""
        r = m("MULTIPLY", m("MULTIPLY_ADD", vo.outputs["Color"], 0.7, 0.5), radius)    # rgb -> its average-ish
        prof = m("SUBTRACT", 1.0, m("DIVIDE", vo.outputs["Distance"], r))
        prof = m("MAXIMUM", prof, 0.0)
        dome = m("POWER", prof, 0.5)
        gate = m("GREATER_THAN", vo.outputs["Color"], keep)
        return m("MULTIPLY", dome, gate)

    # beads: static drops of a few sizes (about 6-14 mm on a 1.4 m pane at scale 34)
    beads = m("MAXIMUM", drops(vor(u, v, 26.0), 0.34, 0.40), drops(vor(m("ADD", u, 3.1), v, 55.0), 0.30, 0.50))
    # runnels: drops stretched along the flow, sliding (two layers, cross-faded)
    fx, fy = flow
    nrm = math.hypot(fx, fy) or 1.0
    fx, fy = fx / nrm, fy / nrm
    along = m("ADD", m("MULTIPLY", u, fx), m("MULTIPLY", v, fy))      # distance along the flow
    across = m("SUBTRACT", m("MULTIPLY", v, fx), m("MULTIPLY", u, fy))
    off_a, off_b, w_a = value(0.0), value(17.3), value(0.0)
    layers = []
    for off in (off_a, off_b):
        s = m("SUBTRACT", along, off)
        vo = vor(m("MULTIPLY", s, 0.10), across, 24.0)               # cells ~42 mm across, ~0.42 m long
        layers.append(drops(vo, 0.36, 0.60))
    w_b = m("SUBTRACT", 1.0, w_a)
    runs = m("ADD", m("MULTIPLY", layers[0], w_a), m("MULTIPLY", layers[1], w_b))
    water = m("MINIMUM", m("MAXIMUM", beads, runs), 1.0)
    bump = nt.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = 0.004
    ln.new(water, bump.inputs["Height"])
    ln.new(bump.outputs["Normal"], gl.inputs["Normal"])
    ln.new(bump.outputs["Normal"], fr.inputs["Normal"])
    return RainDriver(off_a.node.outputs[0], off_b.node.outputs[0], w_a.node.outputs[0]), water, v


def facade_grid(name, wall=(0.82, 0.80, 0.76), glass=(0.05, 0.06, 0.07), pitch=3.2, floor_h=3.0, win_w=0.55,
                win_h=0.50, sill=0.32, curtain=(0.78, 0.74, 0.66), curtain_prob=0.35, lit=0.0, lit_prob=0.45,
                lit_color=(1.0, 0.78, 0.52), wall_rough=0.8, x_offset=0.0):
    """A procedural window grid for building walls: no textures, any colour, real-world pitch.
    Windows repeat every `pitch` m along the wall (object x + y, so any axis-aligned box works) and
    every `floor_h` m up; `win_w`/`win_h` are fractions of the cell, `sill` where the window starts
    in it. Each window independently gets curtains (by day) or a lit room (`lit` > 0, at night) by a
    per-cell hash, and is recessed with a bump. Keep object scale 1."""
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    b = nt.get("Principled BSDF")
    tc = nt.new("ShaderNodeTexCoord")
    sep = nt.new("ShaderNodeSeparateXYZ")
    ln.new(tc.outputs["Object"], sep.inputs[0])

    def m(op, a, bb=None, c=None):
        n = nt.new("ShaderNodeMath")
        n.operation = op
        for i, v in enumerate((a, bb, c)):
            if v is None:
                continue
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                ln.new(v, n.inputs[i])
        return n.outputs[0]

    u = m("DIVIDE", m("ADD", m("ADD", sep.outputs["X"], sep.outputs["Y"]), x_offset), pitch)
    v = m("DIVIDE", sep.outputs["Z"], floor_h)
    fu, fv = m("FRACT", u), m("FRACT", v)
    inu = m("LESS_THAN", m("ABSOLUTE", m("SUBTRACT", fu, 0.5)), win_w / 2)
    inv = m("LESS_THAN", m("ABSOLUTE", m("SUBTRACT", fv, sill + win_h / 2)), win_h / 2)
    mask = m("MULTIPLY", inu, inv)
    comb = nt.new("ShaderNodeCombineXYZ")
    ln.new(m("FLOOR", u), comb.inputs[0])
    ln.new(m("FLOOR", v), comb.inputs[1])
    wn = nt.new("ShaderNodeTexWhiteNoise")
    wn.noise_dimensions = "3D"
    ln.new(comb.outputs[0], wn.inputs["Vector"])
    rnd = wn.outputs["Value"]
    gmix = nt.new("ShaderNodeMix")                       # glass, sometimes with curtains behind it
    gmix.data_type = "RGBA"
    ln.new(m("GREATER_THAN", rnd, 1.0 - curtain_prob), gmix.inputs[0])
    _set(gmix.inputs[6], glass)
    _set(gmix.inputs[7], tuple(c * 0.55 for c in curtain))
    nz = nt.new("ShaderNodeTexNoise")                    # weathering on the wall
    nz.inputs["Scale"].default_value = 0.35
    ln.new(tc.outputs["Object"], nz.inputs["Vector"])
    wmix = nt.new("ShaderNodeMix")
    wmix.data_type = "RGBA"
    wmix.blend_type = "MULTIPLY"
    wmix.inputs[0].default_value = 0.35
    _set(wmix.inputs[6], wall)
    ln.new(nz.outputs["Color"], wmix.inputs[7])
    col = nt.new("ShaderNodeMix")
    col.data_type = "RGBA"
    ln.new(mask, col.inputs[0])
    ln.new(wmix.outputs[2], col.inputs[6])
    ln.new(gmix.outputs[2], col.inputs[7])
    ln.new(col.outputs[2], b.inputs["Base Color"])
    rr = nt.new("ShaderNodeMapRange")
    rr.inputs["To Min"].default_value = wall_rough
    rr.inputs["To Max"].default_value = 0.06
    ln.new(mask, rr.inputs["Value"])
    ln.new(rr.outputs["Result"], b.inputs["Roughness"])
    bump = nt.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.6
    bump.inputs["Distance"].default_value = 0.08
    bump.invert = True
    ln.new(mask, bump.inputs["Height"])
    ln.new(bump.outputs["Normal"], b.inputs["Normal"])
    if lit:
        on = m("MULTIPLY", mask, m("GREATER_THAN", m("FRACT", m("MULTIPLY", rnd, 7.31)), 1.0 - lit_prob))
        k = m("MULTIPLY", on, m("MULTIPLY_ADD", rnd, 0.6, 0.4))
        ln.new(m("MULTIPLY", k, lit), b.inputs["Emission Strength"])
        _set(b.inputs["Emission Color"], lit_color)
    return mat
