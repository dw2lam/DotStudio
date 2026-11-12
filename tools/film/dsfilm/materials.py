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
    thin_glass(name, refl=0.08)                    # window pane: see-through + Fresnel reflection
"""
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
        mx.inputs["Factor"].default_value = 1.0
        ln.new(col, mx.inputs["A"])
        _set(mx.inputs["B"], tint)
        col = mx.outputs["Result"]
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


def thin_glass(name, tint=(0.93, 0.97, 0.95), refl=0.08, rough=0.0, rain=False):
    """A thin pane: Transparent (no refraction offset, as a real thin pane) mixed with a Fresnel
    glossy reflection. Objects using it should also get ``visible_shadow = False`` (geometry.no_shadow)
    so sunlight passes. With rain=True a drop-and-runnel normal is added; returns (mat, mapping) where
    keyframing the mapping's Location z scrolls the runnels (periodic if it moves whole cells)."""
    mat = bpy.data.materials.new(name)
    nt, ln = _nodes(mat)
    nt.remove(nt.get("Principled BSDF"))
    out = nt.get("Material Output")
    tr = nt.new("ShaderNodeBsdfTransparent")
    _set(tr.inputs["Color"], tint)
    gl = nt.new("ShaderNodeBsdfGlossy")
    gl.inputs["Roughness"].default_value = rough
    fr = nt.new("ShaderNodeFresnel")
    fr.inputs["IOR"].default_value = 1.52
    mf = nt.new("ShaderNodeMath")
    mf.operation = "MULTIPLY_ADD"
    mf.inputs[1].default_value = 1.0
    mf.inputs[2].default_value = refl
    mf.use_clamp = True
    ln.new(fr.outputs[0], mf.inputs[0])
    mx = nt.new("ShaderNodeMixShader")
    ln.new(mf.outputs[0], mx.inputs["Fac"])
    ln.new(tr.outputs[0], mx.inputs[1])
    ln.new(gl.outputs[0], mx.inputs[2])
    ln.new(mx.outputs[0], out.inputs["Surface"])
    try:
        mat.surface_render_method = "BLENDED"
    except Exception:
        pass
    mapping = None
    if rain:
        mapping = _rain(nt, ln, gl, fr, mf)
    return (mat, mapping) if rain else mat


def _rain(nt, ln, gl, fr, mf):
    tc = nt.new("ShaderNodeTexCoord")
    mp = nt.new("ShaderNodeMapping")
    ln.new(tc.outputs["Object"], mp.inputs["Vector"])
    beads = nt.new("ShaderNodeTexVoronoi")
    beads.inputs["Scale"].default_value = 45.0
    ln.new(tc.outputs["Object"], beads.inputs["Vector"])
    runs = nt.new("ShaderNodeTexVoronoi")
    runs.inputs["Scale"].default_value = 14.0
    sc = nt.new("ShaderNodeMapping")
    sc.inputs["Scale"].default_value = (1.0, 1.0, 0.18)
    ln.new(mp.outputs["Vector"], sc.inputs["Vector"])
    ln.new(sc.outputs["Vector"], runs.inputs["Vector"])
    hs = []
    for v, gate_at, r in ((beads, 0.55, 0.20), (runs, 0.85, 0.12)):
        mr = nt.new("ShaderNodeMapRange")
        mr.inputs["From Max"].default_value = r
        mr.inputs["To Min"].default_value = 1.0
        mr.inputs["To Max"].default_value = 0.0
        ln.new(v.outputs["Distance"], mr.inputs["Value"])
        gate = nt.new("ShaderNodeMath")
        gate.operation = "GREATER_THAN"
        gate.inputs[1].default_value = gate_at
        ln.new(v.outputs["Color"], gate.inputs[0])
        m = nt.new("ShaderNodeMath")
        m.operation = "MULTIPLY"
        ln.new(mr.outputs["Result"], m.inputs[0])
        ln.new(gate.outputs[0], m.inputs[1])
        hs.append(m)
    add = nt.new("ShaderNodeMath")
    add.operation = "MAXIMUM"
    ln.new(hs[0].outputs[0], add.inputs[0])
    ln.new(hs[1].outputs[0], add.inputs[1])
    bump = nt.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = 0.003
    ln.new(add.outputs[0], bump.inputs["Height"])
    ln.new(bump.outputs["Normal"], gl.inputs["Normal"])
    ln.new(bump.outputs["Normal"], fr.inputs["Normal"])
    # water catches more reflection
    mm = nt.new("ShaderNodeMath")
    mm.operation = "MULTIPLY_ADD"
    mm.inputs[1].default_value = 0.25
    ln.new(add.outputs[0], mm.inputs[0])
    ln.new(fr.outputs[0], mm.inputs[2])
    ln.new(mm.outputs[0], mf.inputs[0])
    return mp
