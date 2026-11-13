"""The passenger: an original chubby cartoon penguin in a suit, dozing on the end seat.

Design (generic penguin-cartoon vocabulary, our own character):
  * one continuous egg/pear body — head and body flow together, slightly narrower at the top,
    a rounded crown (no pointed peak, no separate ball head)
  * saturated teal, a big white belly that stops at the chest (the eyes sit straight in the teal:
    no white face mask around them, and the bill sits on teal, not on a white patch)
  * big friendly cartoon eyes (white, black pupils, a glint) with teal lids for dozing
  * a wide, flat-ish, cheerful bright-orange bill with upturned corners
  * short flipper wings out at the sides, chunky flat orange feet
  * charcoal herringbone suit jacket (open over the belly), collar, red silk tie

Rig: root (empty) -> torso (empty, breathing scale) -> armature "PenguinRig" with bones body/head.
The body and the clothes deform with the head bone by height (a smooth neck band), so a nod bends
the top of the egg; eyes, lids, bill and cheeks ride on the head bone. Faces +y.
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector

from dsfilm import materials as mt
from dsfilm.geometry import empty, from_bm, smooth_by_angle, smooth_tube, sphere

# body profile: (height, radius) from the seat up; depth is DEPTH x radius
PROFILE = [(0.000, 0.00), (0.004, 0.20), (0.020, 0.29), (0.060, 0.345), (0.140, 0.372), (0.260, 0.378),
           (0.380, 0.362), (0.500, 0.332), (0.600, 0.302), (0.700, 0.281), (0.800, 0.262), (0.880, 0.232),
           (0.950, 0.186), (1.000, 0.118), (1.022, 0.050), (1.030, 0.000)]
DEPTH = 0.86
NECK = (0.55, 0.76)          # head-bone weight ramps over this height band
BELLY = dict(cx=0.0, cz=0.33, a=0.255, b=0.37)   # white belly ellipse (front)


def radius_at(z):
    for (z0, r0), (z1, r1) in zip(PROFILE, PROFILE[1:]):
        if z0 <= z <= z1:
            t = (z - z0) / max(z1 - z0, 1e-6)
            t = t * t * (3 - 2 * t) if 0 < z0 and z1 < 1.03 else t
            return r0 + (r1 - r0) * t
    return 0.0


def surface_y(x, z, grow=1.0):
    r = radius_at(z) * grow
    if abs(x) >= r:
        return 0.0
    belly = 1.0 + 0.06 * max(0.0, 1 - abs(z - 0.30) / 0.30)
    return math.sqrt(r * r - x * x) * DEPTH * belly


def _body_bm(grow=1.0, segs=64):
    bm = bmesh.new()
    rings = []
    for z, r in PROFILE[1:-1]:
        ring = []
        for i in range(segs):
            a = math.tau * i / segs
            x, y = math.sin(a) * r * grow, math.cos(a) * r * grow * DEPTH
            if y > 0:
                y *= 1.0 + 0.06 * max(0.0, 1 - abs(z - 0.30) / 0.30)
            ring.append(bm.verts.new((x, y, z)))
        rings.append(ring)
    bot = bm.verts.new((0, 0, 0.0))
    top = bm.verts.new((0, 0, PROFILE[-1][0] * (1 + (grow - 1) * 0.5)))
    for ra, rb in zip(rings, rings[1:]):
        for i in range(segs):
            bm.faces.new((ra[i], ra[(i + 1) % segs], rb[(i + 1) % segs], rb[i]))
    for i in range(segs):
        bm.faces.new((rings[0][(i + 1) % segs], rings[0][i], bot))
        bm.faces.new((rings[-1][i], rings[-1][(i + 1) % segs], top))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def _feather_mat(color):
    """Teal feathers with the white belly as a soft-edged ellipse on the front (object space)."""
    mat = bpy.data.materials.new("PenguinBody")
    nt, ln = mat.node_tree.nodes, mat.node_tree.links
    out = nt.get("Material Output")
    teal = nt.get("Principled BSDF")
    white = nt.new("ShaderNodeBsdfPrincipled")
    for b, c, sub in ((teal, color, (0.35, 0.6, 0.8)), (white, (0.88, 0.87, 0.83), (0.9, 0.8, 0.7))):
        b.inputs["Base Color"].default_value = (*c, 1)
        b.inputs["Roughness"].default_value = 0.55
        b.inputs["Subsurface Weight"].default_value = 0.12
        b.inputs["Subsurface Radius"].default_value = sub
        b.inputs["Subsurface Scale"].default_value = 0.02
        b.inputs["Sheen Weight"].default_value = 0.55
        b.inputs["Sheen Roughness"].default_value = 0.4
    teal.inputs["Sheen Tint"].default_value = (0.65, 0.88, 1.0, 1)
    tc = nt.new("ShaderNodeTexCoord")
    sep = nt.new("ShaderNodeSeparateXYZ")
    ln.new(tc.outputs["Object"], sep.inputs[0])

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

    qx = m("POWER", m("DIVIDE", sep.outputs["X"], BELLY["a"]), 2.0)
    qz = m("POWER", m("DIVIDE", m("SUBTRACT", sep.outputs["Z"], BELLY["cz"]), BELLY["b"]), 2.0)
    q = m("ADD", qx, qz)
    ell = nt.new("ShaderNodeMapRange")
    ell.inputs["From Min"].default_value = 1.0
    ell.inputs["From Max"].default_value = 0.93
    ln.new(q, ell.inputs["Value"])
    front = nt.new("ShaderNodeMapRange")
    front.inputs["From Min"].default_value = 0.04
    front.inputs["From Max"].default_value = 0.10
    ln.new(sep.outputs["Y"], front.inputs["Value"])
    mask = m("MULTIPLY", ell.outputs["Result"], front.outputs["Result"])
    mix = nt.new("ShaderNodeMixShader")
    ln.new(mask, mix.inputs["Fac"])
    ln.new(teal.outputs[0], mix.inputs[1])
    ln.new(white.outputs[0], mix.inputs[2])
    ln.new(mix.outputs[0], out.inputs["Surface"])
    # feather texture: a fine stretched noise bump shared by both
    nz = nt.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 300.0
    mp = nt.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1, 1, 3.5)
    ln.new(tc.outputs["Object"], mp.inputs["Vector"])
    ln.new(mp.outputs["Vector"], nz.inputs["Vector"])
    bump = nt.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.06
    bump.inputs["Distance"].default_value = 0.001
    ln.new(nz.outputs["Fac"], bump.inputs["Height"])
    ln.new(bump.outputs["Normal"], teal.inputs["Normal"])
    ln.new(bump.outputs["Normal"], white.inputs["Normal"])
    return mat


def _mats(color):
    m = {"body": _feather_mat(color)}
    # the same feathers without the belly patch (flippers, eyelids), so they match the body exactly
    teal = m["body"].copy()
    teal.name = "PenguinTeal"
    mix = next(n for n in teal.node_tree.nodes if n.type == "MIX_SHADER")
    for l in list(mix.inputs["Fac"].links):
        teal.node_tree.links.remove(l)
    mix.inputs["Fac"].default_value = 0.0
    m["teal"] = teal
    # eyelids: the same feathers but opaque (no subsurface), so a shut lid never glows with the pupil
    # and catch-light behind it in strong sun
    lidm = teal.copy()
    lidm.name = "PenguinLid"
    for n in lidm.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            n.inputs["Subsurface Weight"].default_value = 0.0
    m["lid"] = lidm
    m["bill"] = mt.noise_bump(mt.principled("Bill", (0.98, 0.46, 0.02), 0.25,
                                            **{"Subsurface Weight": 0.3, "Subsurface Radius": (1.0, 0.4, 0.1),
                                               "Subsurface Scale": 0.01, "Coat Weight": 0.6, "Coat Roughness": 0.1}),
                              scale=90, strength=0.02, distance=0.001)
    m["feet"] = mt.noise_bump(mt.principled("Feet", (0.97, 0.44, 0.03), 0.42,
                                            **{"Subsurface Weight": 0.3, "Subsurface Radius": (1.0, 0.4, 0.1),
                                               "Subsurface Scale": 0.01}), scale=140, strength=0.08, distance=0.001)
    m["eye"] = mt.principled("EyeWhite", (0.92, 0.92, 0.90), 0.1, **{"Coat Weight": 1.0, "Coat Roughness": 0.02,
                                                                      "Subsurface Weight": 0.25})
    m["pupil"] = mt.principled("Pupil", (0.012, 0.016, 0.024), 0.3, **{"Coat Weight": 0.5, "Coat Roughness": 0.15})
    m["glint"] = mt.principled("Glint", (1, 1, 1), 0.3, **{"Emission Color": (1, 1, 1), "Emission Strength": 0.25})
    m["lash"] = mt.principled("Lash", (0.0, 0.16, 0.22), 0.5)
    m["cheek"] = mt.principled("Cheek", (0.85, 0.40, 0.45), 0.6, **{"Sheen Weight": 0.5})
    # dark wool: very rough, little specular (a dielectric's 4% at full roughness reads as grey haze
    # under direct sun), a faint sheen tinted near the cloth's own colour
    m["suit"] = mt.ph_pbr("SuitWool", "poly_wool_herringbone", size_m=0.09, desat=True, tint=(0.020, 0.021, 0.026),
                          nor_strength=0.9, rough_mul=0.2, rough_add=0.78,
                          **{"Specular IOR Level": 0.18, "Sheen Weight": 0.12, "Sheen Roughness": 0.5,
                             "Sheen Tint": (0.16, 0.16, 0.18)})
    m["shirt"] = mt.noise_bump(mt.principled("Shirt", (0.88, 0.89, 0.90), 0.55, **{"Subsurface Weight": 0.1,
                                                                                     "Sheen Weight": 0.3}),
                               scale=700, strength=0.03, distance=0.0005)
    tie = mt.principled("TieSilk", (0.52, 0.04, 0.07), 0.3, **{"Sheen Weight": 0.6, "Sheen Roughness": 0.25,
                                                               "Anisotropic": 0.5, "Coat Weight": 0.15})
    nt, ln = tie.node_tree.nodes, tie.node_tree.links
    wv = nt.new("ShaderNodeTexWave")
    wv.wave_type, wv.bands_direction = "BANDS", "DIAGONAL"
    wv.inputs["Scale"].default_value = 9.0
    ln.new(nt.new("ShaderNodeTexCoord").outputs["Object"], wv.inputs["Vector"])
    ramp = nt.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position, ramp.color_ramp.elements[0].color = 0.80, (0.52, 0.04, 0.07, 1)
    ramp.color_ramp.elements[1].position, ramp.color_ramp.elements[1].color = 0.83, (0.72, 0.58, 0.28, 1)
    ln.new(wv.outputs["Fac"], ramp.inputs["Fac"])
    ln.new(ramp.outputs["Color"], nt.get("Principled BSDF").inputs["Base Color"])
    m["tie"] = tie
    m["button"] = mt.principled("Button", (0.02, 0.02, 0.02), 0.2, **{"Coat Weight": 0.8})
    return m


def _neck_weight(z):
    t = min(max((z - NECK[0]) / (NECK[1] - NECK[0]), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def _skin(ob, arm, local_z=None):
    """Armature-deform `ob` by height: body bone below the neck band, head bone above."""
    vb = ob.vertex_groups.new(name="body")
    vh = ob.vertex_groups.new(name="head")
    for v in ob.data.vertices:
        z = local_z(v.co) if local_z else v.co.z
        w = _neck_weight(z)
        if w < 1:
            vb.add([v.index], 1 - w, "REPLACE")
        if w > 0:
            vh.add([v.index], w, "REPLACE")
    md = ob.modifiers.new("rig", "ARMATURE")    # added first: subdivision then smooths the deformed shape
    md.object = arm
    return ob


def _on_bone(ob, arm, bone):
    """Parents `ob` rigidly to `bone`, keeping its current (penguin-space) transform."""
    bpy.context.view_layer.update()
    mw = ob.matrix_world.copy()
    ob.parent = arm
    ob.parent_type = "BONE"
    ob.parent_bone = bone
    bpy.context.view_layer.update()
    ob.matrix_world = mw
    return ob


def _folds(ob, scale=0.07, strength=0.007):
    """Cloth folds: a soft marble displacement after subdivision (wrinkles and drape, cheaply)."""
    tex = bpy.data.textures.new(f"Folds_{ob.name}", "MARBLE")
    tex.marble_type = "SOFT"
    tex.noise_basis_2 = "SIN"
    tex.noise_scale = scale
    tex.turbulence = 4.0
    tex.noise_depth = 2
    md = ob.modifiers.new("folds", "DISPLACE")
    md.texture = tex
    md.texture_coords = "LOCAL"
    md.strength = strength
    md.mid_level = 0.5
    return ob


def build(C, loc, yaw_deg=0.0, size=1.0, color=(0.0, 0.42, 0.56)):
    pm = _mats(color)
    root = empty("PenguinRoot", C, loc)
    root.rotation_euler = (0, 0, math.radians(yaw_deg))
    root.scale = (size,) * 3
    torso = empty("Torso", C, parent=root)

    # armature (built at the origin, then parented under the torso)
    ad = bpy.data.armatures.new("PenguinRig")
    arm = bpy.data.objects.new("PenguinRig", ad)
    C.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    b = ad.edit_bones.new("body")
    b.head, b.tail = (0, -0.03, 0.0), (0, -0.03, 0.58)
    h = ad.edit_bones.new("head")
    h.head, h.tail = (0, -0.03, 0.58), (0, -0.03, 1.0)
    h.parent = b
    bpy.ops.object.mode_set(mode="OBJECT")
    arm.parent = torso
    head_pb = arm.pose.bones["head"]
    head_pb.rotation_mode = "XYZ"

    # the body: one continuous egg
    body = from_bm("Body", _body_bm(), pm["body"], C, arm)
    _skin(body, arm)
    sub = body.modifiers.new("sub", "SUBSURF")
    sub.levels = sub.render_levels = 2
    smooth_by_angle(body, 80)

    # jacket: a shell over the lower body, open in a V over the belly
    zb = 0.36                                     # the button
    bm = _body_bm(grow=1.045)
    kill = []
    for f in bm.faces:
        x, y, z = f.calc_center_median()
        if z > 0.64 or z < 0.08:
            kill.append(f)
        elif y > 0 and z >= zb and abs(x) < 0.05 + 0.42 * (z - zb):
            kill.append(f)
        elif y > 0 and z < zb and abs(x) < 0.05 + 0.75 * (zb - z):
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    jacket = from_bm("Jacket", bm, pm["suit"], C, arm)
    _skin(jacket, arm)
    so = jacket.modifiers.new("thick", "SOLIDIFY")
    so.thickness, so.offset = 0.02, 1.0
    sub = jacket.modifiers.new("sub", "SUBSURF")
    sub.levels = sub.render_levels = 2
    _folds(jacket, 0.08, 0.014)
    smooth_by_angle(jacket, 80)
    # lapels along the V
    for sx in (-1, 1):
        pts = []
        for i in range(8):
            z = zb + (i / 7) * (0.63 - zb)
            x = sx * (0.05 + 0.42 * (z - zb) + 0.02)
            pts.append((x, surface_y(x, z, 1.05) + 0.012, z))
        lap = smooth_tube(f"Lapel{sx}", pts, 0.028, pm["suit"], C, parent=arm, taper=[0.45 + 0.75 * i / 7 for i in range(8)])
        _skin(lap, arm)
    # collar points, knot and tie over the white chest
    for sx in (-1, 1):
        c = smooth_tube(f"Collar{sx}", [(sx * 0.15, surface_y(0.15, 0.66) - 0.01, 0.665), (sx * 0.085, surface_y(0.085, 0.64) + 0.012, 0.635),
                                        (sx * 0.035, surface_y(0.035, 0.60) + 0.016, 0.585)], 0.017, pm["shirt"], C, parent=arm,
                        taper=[1.0, 1.0, 0.5])
        _skin(c, arm)
    knot = sphere("TieKnot", 0.032, (0, surface_y(0, 0.605) + 0.02, 0.605), pm["tie"], C, scale=(1.1, 0.75, 1.2), parent=arm)
    _skin(knot, arm)
    tie_pts = [(0.0, surface_y(0, z) + 0.012, z) for z in (0.585, 0.54, 0.49, 0.44, 0.40, 0.37, 0.35)]
    tie = smooth_tube("Tie", tie_pts, 0.034, pm["tie"], C, parent=arm, taper=[0.55, 0.85, 1.0, 1.1, 1.2, 1.2, 0.5])
    for v in tie.data.vertices:          # flatten against the chest
        sy = surface_y(0, v.co.z) + 0.012
        v.co.y = sy + (v.co.y - sy) * 0.22
    _skin(tie, arm)
    for k, z in enumerate((zb - 0.005, zb - 0.09)):
        sphere(f"Button{k}", 0.012, (0.07 + 0.75 * (zb - z) + 0.02, surface_y(0.09, z, 1.05) + 0.02, z), pm["button"], C,
               scale=(1, 0.5, 1), parent=arm)

    # short flipper wings out at the sides, the upper half in suit sleeves
    for sx in (-1, 1):
        sh = (sx * 0.26, -0.01, 0.60)
        el = (sx * 0.38, 0.03, 0.40)
        sl = smooth_tube(f"Sleeve{sx}", [sh, (sx * 0.33, 0.01, 0.51), el], 0.068, pm["suit"], C, parent=arm,
                         taper=[1.15, 1.05, 0.95])
        _skin(sl, arm)
        _folds(sl, 0.03, 0.005)
        sphere(f"Cuff{sx}", 0.06, el, pm["shirt"], C, scale=(1.0, 1.0, 0.32), parent=arm,
               rot=(0, sx * math.radians(-32), 0))
        sphere(f"Flipper{sx}", 0.075, (sx * 0.425, 0.04, 0.30), pm["teal"], C, scale=(0.55, 1.0, 1.7), parent=arm,
               rot=(0, sx * math.radians(-28), 0))

    # chunky flat feet on the seat front
    for sx in (-1, 1):
        foot = empty(f"Foot{sx}", C, (sx * 0.135, 0.27, 0.035), parent=torso)
        foot.rotation_euler = (math.radians(-4), 0, sx * math.radians(-12))
        sphere(f"FootPad{sx}", 0.09, (0, 0.04, 0), pm["feet"], C, scale=(1.0, 1.25, 0.34), parent=foot)
        for t, ang in enumerate((-32, 0, 32)):
            a = math.radians(ang)
            sphere(f"Toe{sx}{t}", 0.046, (math.sin(a) * 0.085, 0.12 + math.cos(a) * 0.07, -0.004), pm["feet"], C,
                   scale=(0.9, 1.3, 0.6), parent=foot, rot=(0, 0, -a))

    # face: eyes, lids, bill, cheeks — rigid on the head bone
    bpy.context.view_layer.update()
    lids = []
    # gentle eyes: small, set deep so only a shallow cap shows (lids stay flush when shut), big dark
    # pupils filling most of the cap, a soft catch-light, a thin dark-teal lash line, no brows
    ez, ex, er = 0.885, 0.084, 0.050
    for sx in (-1, 1):
        sy = surface_y(ex, ez)
        yaw = math.atan2(ex, sy) * 0.8
        eye = empty(f"Eye{sx}", C, (sx * ex, sy - er * 0.72, ez), parent=arm)
        # lid edges tilt with the inner corners up: a soft, sleepy face rather than a frown
        eye.rotation_euler = (math.radians(-6), sx * math.radians(14), sx * -yaw)
        sphere(f"EyeWhite{sx}", er, (0, 0, 0), pm["eye"], C, parent=eye)
        sphere(f"Pupil{sx}", er * 0.60, (0.0, er * 0.80, -0.003), pm["pupil"], C, scale=(1.0, 0.36, 1.08), parent=eye)
        sphere(f"Glint{sx}", 0.0065, (sx * -0.006 - 0.007, er * 0.995, 0.012), pm["glint"], C, scale=(1, 0.4, 1), parent=eye)
        sphere(f"Glint2{sx}", 0.003, (sx * -0.006 + 0.008, er * 0.99, -0.010), pm["glint"], C, scale=(1, 0.4, 1), parent=eye)
        lid = empty(f"Lid{sx}", C, parent=eye)
        lb = bmesh.new()
        bmesh.ops.create_uvsphere(lb, u_segments=40, v_segments=24, radius=er * 1.12)   # clears the catch-light, which then hides under a shut lid
        bmesh.ops.delete(lb, geom=[v for v in lb.verts if v.co.z < -0.001], context="VERTS")
        lo = from_bm(f"UpperLid{sx}", lb, pm["lid"], C, lid)
        so = lo.modifiers.new("thick", "SOLIDIFY")
        so.thickness = 0.0045
        smooth_by_angle(lo, 80)
        # lash line along the lid's front rim: the closed-eye curve when shut, the lid edge when open
        rim = [(er * 1.12 * math.cos(a), er * 1.12 * math.sin(a), 0.0) for a in [math.pi * (0.12 + 0.76 * k / 16) for k in range(17)]]
        smooth_tube(f"Lash{sx}", rim, 0.0014, pm["lash"], C, parent=lid)   # a fine line, not a pupil-like crescent
        # the closed-eye line: a soft ∪ drawn on the lid's surface where it faces forward-down when shut
        # (lid space = shut space rotated: shut (X, Y, Z) is lid (X, -Z, Y)); open, it folds up as a crease
        R = er * 1.12
        arc = []
        for k in range(15):
            X = R * 0.72 * (2 * k / 14 - 1)
            Z = -0.16 * R - 0.20 * R * (1 - (X / (0.72 * R)) ** 2)
            Y = math.sqrt(max(R * R - X * X - Z * Z, 0.0)) + 0.0006
            arc.append((X, -Z, Y))
        smooth_tube(f"ShutLine{sx}", arc, 0.0016, pm["lash"], C, parent=lid)
        _on_bone(eye, arm, "head")
        lids.append(lid)
        ch = sphere(f"Cheek{sx}", 0.045, (sx * 0.16, surface_y(0.16, 0.775) - 0.012, 0.775), pm["cheek"], C,
                    scale=(1.0, 0.35, 0.6), parent=arm, rot=(0, 0, sx * math.radians(-38)))
        _on_bone(ch, arm, "head")
    # the bill: wide at the base, tapering to a rounded tip, corners turned up in a smile
    by = surface_y(0, 0.775)
    for name, w, l, hgt, z, yo in (("BillUpper", 0.088, 0.112, 0.048, 0.770, 0.046), ("BillLower", 0.070, 0.088, 0.030, 0.741, 0.034)):
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=24, radius=1.0)
        for v in bm.verts:
            x, y, zz = v.co
            x *= 1.0 - 0.66 * max(y, 0.0)               # taper toward a rounded tip
            v.co = Vector((x * w, y * l, zz * hgt))
            v.co.z += 1.1 * hgt * (v.co.x / w) ** 2 * max(-y, 0.0) * 0.5   # a slight smile at the corners
            v.co.y -= 0.03 * (v.co.x / w) ** 2                               # corners follow the face
        ob = from_bm(name, bm, pm["bill"], C, arm)
        ob.location = (0, by + yo, z)
        ob.rotation_euler = (math.radians(-8), 0, 0)
        ob.data.polygons.foreach_set("use_smooth", [True] * len(ob.data.polygons))
        _on_bone(ob, arm, "head")
    for sx in (-1, 1):
        n = sphere(f"Nostril{sx}", 0.006, (sx * 0.020, by + 0.100, 0.792), pm["pupil"], C, scale=(1.2, 0.6, 0.5), parent=arm)
        _on_bone(n, arm, "head")
    return dict(root=root, torso=torso, arm=arm, head=head_pb, lids=lids, body=body)
