"""The passenger: an original chubby penguin in a suit, dozing on the end seat.

Design (ours, deliberately not Club Penguin's): a smooth dome head with no crest or peak; the eyes
sit straight in the teal feathers (no white mask around them); the white starts at the throat
below the bill and runs down the belly; soft rosy cheeks; a big, rounded two-part orange bill;
broad three-toed paddle feet. Charcoal herringbone suit, white shirt, red silk tie.

Rig (empties, animated by scene.py): root -> torso (breathing scale) -> neck (nod pitch) -> eye
lids (closure). Faces +y.
"""
import math

import bmesh
from mathutils import Vector

from dsfilm import materials as mt
from dsfilm.geometry import empty, from_bm, smooth_by_angle, smooth_tube, sphere


def _mats(color):
    m = {}
    m["body"] = mt.noise_bump(mt.principled("Feathers", color, 0.55,
                                            **{"Subsurface Weight": 0.10, "Subsurface Radius": (0.4, 0.6, 0.8),
                                               "Subsurface Scale": 0.02, "Sheen Weight": 0.6, "Sheen Roughness": 0.35,
                                               "Sheen Tint": (0.65, 0.88, 1.0)}),
                              scale=300, strength=0.06, stretch=(1, 1, 3.5), rough_var=0.08, distance=0.001)
    m["belly"] = mt.noise_bump(mt.principled("BellyFeathers", (0.86, 0.85, 0.80), 0.6,
                                             **{"Subsurface Weight": 0.2, "Subsurface Radius": (0.9, 0.8, 0.7),
                                                "Subsurface Scale": 0.02, "Sheen Weight": 0.5, "Sheen Roughness": 0.4}),
                               scale=300, strength=0.05, stretch=(1, 1, 3.5), distance=0.001)
    m["bill"] = mt.noise_bump(mt.principled("Bill", (0.95, 0.40, 0.03), 0.28,
                                            **{"Subsurface Weight": 0.3, "Subsurface Radius": (1.0, 0.4, 0.1),
                                               "Subsurface Scale": 0.01, "Coat Weight": 0.6, "Coat Roughness": 0.12}),
                              scale=90, strength=0.03, distance=0.001)
    m["feet"] = mt.noise_bump(mt.principled("Feet", (0.92, 0.38, 0.04), 0.45,
                                            **{"Subsurface Weight": 0.3, "Subsurface Radius": (1.0, 0.4, 0.1),
                                               "Subsurface Scale": 0.01}), scale=140, strength=0.1, distance=0.001)
    m["eye"] = mt.principled("EyeWhite", (0.90, 0.90, 0.88), 0.12, **{"Coat Weight": 1.0, "Coat Roughness": 0.02,
                                                                       "Subsurface Weight": 0.3})
    m["pupil"] = mt.principled("Pupil", (0.01, 0.012, 0.016), 0.08, **{"Coat Weight": 1.0, "Coat Roughness": 0.02})
    m["cheek"] = mt.principled("Cheek", (0.80, 0.34, 0.40), 0.6, **{"Sheen Weight": 0.5})
    m["suit"] = mt.ph_pbr("SuitWool", "poly_wool_herringbone", size_m=0.09, desat=True, tint=(0.075, 0.08, 0.095),
                          nor_strength=0.9, **{"Sheen Weight": 0.12, "Sheen Roughness": 0.6, "Sheen Tint": (0.5, 0.5, 0.55)})
    m["shirt"] = mt.noise_bump(mt.principled("Shirt", (0.86, 0.87, 0.88), 0.55, **{"Subsurface Weight": 0.1,
                                                                                     "Sheen Weight": 0.3}),
                               scale=700, strength=0.03, distance=0.0005)
    tie = mt.principled("TieSilk", (0.50, 0.04, 0.07), 0.3, **{"Sheen Weight": 0.6, "Sheen Roughness": 0.25,
                                                               "Anisotropic": 0.5, "Coat Weight": 0.15})
    nt, ln = tie.node_tree.nodes, tie.node_tree.links
    wv = nt.new("ShaderNodeTexWave")
    wv.wave_type, wv.bands_direction = "BANDS", "DIAGONAL"
    wv.inputs["Scale"].default_value = 9.0
    ln.new(nt.new("ShaderNodeTexCoord").outputs["Object"], wv.inputs["Vector"])
    ramp = nt.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position, ramp.color_ramp.elements[0].color = 0.80, (0.50, 0.04, 0.07, 1)
    ramp.color_ramp.elements[1].position, ramp.color_ramp.elements[1].color = 0.83, (0.72, 0.58, 0.28, 1)
    ln.new(wv.outputs["Fac"], ramp.inputs["Fac"])
    ln.new(ramp.outputs["Color"], nt.get("Principled BSDF").inputs["Base Color"])
    m["tie"] = tie
    m["button"] = mt.principled("Button", (0.02, 0.02, 0.02), 0.2, **{"Coat Weight": 0.8})
    return m


def _egg(rx, ry, rz, flat=0.0, segs=64, rings=48):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0)
    for v in bm.verts:
        x, y, z = v.co
        k = 1.0 + 0.10 * (-z)
        v.co = Vector((x * rx * k, y * ry * k, z * rz))
        lim = -rz * (1 - flat)
        if flat and v.co.z < lim:
            v.co.z = lim + (v.co.z - lim) * 0.25
    return bm


def _surface_y(x, z, rx, ry, rz):
    k = 1.0 + 0.10 * (-z / rz)
    q = 1 - (x / (rx * k)) ** 2 - (z / rz) ** 2
    return math.sqrt(max(q, 0.0)) * ry * k


def build(C, loc, yaw_deg=0.0, size=0.92, color=(0.0, 0.30, 0.47)):
    pm = _mats(color)
    root = empty("PenguinRoot", C, loc)
    root.rotation_euler = (0, 0, math.radians(yaw_deg))
    root.scale = (size,) * 3
    torso = empty("Torso", C, parent=root)
    rx, ry, rz = 0.30, 0.26, 0.38
    zc = rz * 0.90
    body = from_bm("Body", _egg(rx, ry, rz, 0.18), pm["body"], C, torso)
    body.location = (0, 0, zc)
    smooth_by_angle(body, 80)
    belly = from_bm("Belly", _egg(rx * 0.84, ry * 0.93, rz * 0.88, 0.2), pm["belly"], C, torso)
    belly.location = (0, 0.035, zc - 0.015)
    smooth_by_angle(belly, 80)

    # jacket shell, open in a V (shirt + tie inside) and below the button
    zb = -0.07
    bm = _egg(rx * 1.045, ry * 1.06, rz * 1.02, 0.18)
    kill = []
    for f in bm.faces:
        x, y, z = f.calc_center_median()
        if z > rz * 0.80 or z < -rz * 0.80:
            kill.append(f)
        elif y > 0 and z > zb and abs(x) < 0.035 + 0.42 * (z - zb):
            kill.append(f)
        elif y > 0 and z <= zb and abs(x) < 0.02 + 0.6 * (zb - z):
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    jacket = from_bm("Jacket", bm, pm["suit"], C, torso)
    jacket.location = (0, 0, zc)
    so = jacket.modifiers.new("thick", "SOLIDIFY")
    so.thickness, so.offset = 0.02, 1.0
    sub = jacket.modifiers.new("sub", "SUBSURF")
    sub.levels = sub.render_levels = 1
    smooth_by_angle(jacket, 80)
    # lapels along the V edges (wider toward the chest)
    for sx in (-1, 1):
        pts = []
        for i in range(8):
            z = zb + (i / 7) * (rz * 0.78 - zb)
            x = sx * (0.035 + 0.42 * (z - zb) + 0.018)
            pts.append((x, _surface_y(x, z, rx * 1.05, ry * 1.06, rz * 1.02) + 0.012, z + zc))
        lap = smooth_tube(f"Lapel{sx}", pts, 0.026, pm["suit"], C, parent=torso,
                          taper=[0.5 + 0.7 * i / 7 for i in range(8)])
        lap.scale = (1.0, 1.0, 1.0)
    # shirt front, collar, tie, button
    bm = _egg(rx * 1.008, ry * 1.025, rz * 1.0)
    keep = set(f for f in bm.faces if (lambda c: c.y > 0 and -0.25 < c.z < rz * 0.86 and
                                       abs(c.x) < 0.09 + 0.45 * max(c.z - zb, 0))(f.calc_center_median()))
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context="FACES")
    shirt = from_bm("Shirt", bm, pm["shirt"], C, torso)
    shirt.location = (0, 0, zc)
    smooth_by_angle(shirt, 80)
    neck_z = zc + rz * 0.84
    for sx in (-1, 1):
        smooth_tube(f"Collar{sx}", [(sx * 0.11, 0.08, neck_z + 0.02), (sx * 0.065, 0.155, neck_z - 0.02),
                                    (sx * 0.03, 0.19, neck_z - 0.07)], 0.017, pm["shirt"], C, parent=torso,
                    taper=[1.0, 1.0, 0.5])
    sphere("TieKnot", 0.03, (0, 0.188, neck_z - 0.055), pm["tie"], C, scale=(1.1, 0.8, 1.2), parent=torso)
    tie_pts = []
    for i in range(7):
        z = neck_z - 0.085 - (i / 6) * 0.30
        tie_pts.append((0.0, _surface_y(0, z - zc, rx * 1.008, ry * 1.025, rz) + 0.01, z))
    tie = smooth_tube("Tie", tie_pts, 0.032, pm["tie"], C, parent=torso, taper=[0.55, 0.8, 0.95, 1.05, 1.15, 1.2, 0.5])
    # flatten the tie against the shirt
    me = tie.data
    for v in me.vertices:
        sy = _surface_y(0, v.co.z - zc, rx * 1.008, ry * 1.025, rz) + 0.012
        v.co.y = sy + (v.co.y - sy) * 0.22
    sphere("Button", 0.013, (0, _surface_y(0, zb, rx * 1.045, ry * 1.06, rz * 1.02) + 0.02, zc + zb - 0.01), pm["button"], C,
           scale=(1, 0.5, 1), parent=torso)
    # folded arms: sleeves from the shoulders crossing over the belly; flipper tips peek out
    sh_z = zc + rz * 0.50
    for sx in (-1, 1):
        zz = zc - 0.10 + sx * 0.022           # one forearm over the other
        pts = [(sx * rx * 0.96, -0.02, sh_z), (sx * rx * 1.04, 0.04, zc - 0.02), (sx * rx * 0.86, 0.15, zz - 0.02),
               (sx * 0.12, ry * 1.12, zz), (-sx * 0.05, ry * 1.17, zz + 0.01)]
        smooth_tube(f"Sleeve{sx}", pts, 0.056, pm["suit"], C, parent=torso, taper=[1.15, 1.05, 1.0, 0.95, 0.85])
        cx, cy, cz = pts[-1]
        sphere(f"Cuff{sx}", 0.046, (cx - sx * 0.004, cy, cz), pm["shirt"], C, scale=(0.32, 1.0, 1.0), parent=torso)
        sphere(f"Flipper{sx}", 0.058, (cx - sx * 0.055, cy - 0.02, cz + 0.004), pm["body"], C, scale=(1.0, 0.40, 0.66),
               parent=torso, rot=(0, sx * math.radians(15), sx * math.radians(-12)))
    # feet on the seat front, toes toward the aisle
    for sx in (-1, 1):
        foot = empty(f"Foot{sx}", C, (sx * 0.13, ry * 0.70, 0.04), parent=root)
        foot.rotation_euler = (math.radians(-6), 0, sx * math.radians(-14))
        sphere(f"FootPad{sx}", 0.078, (0, 0.06, 0), pm["feet"], C, scale=(1.0, 1.25, 0.32), parent=foot)
        for t, ang in enumerate((-30, 0, 30)):
            a = math.radians(ang)
            sphere(f"Toe{sx}{t}", 0.042, (math.sin(a) * 0.075, 0.12 + math.cos(a) * 0.07, -0.004), pm["feet"], C,
                   scale=(0.85, 1.35, 0.55), parent=foot, rot=(0, 0, -a))
    # head on the neck pivot
    neck = empty("Neck", C, (0, 0.0, neck_z - 0.02), parent=torso)
    hr = 0.215
    hz = hr * 0.80
    head = sphere("Head", hr, (0, 0.03, hz), pm["body"], C, scale=(1.0, 0.96, 0.93), parent=neck, segs=64, rings=48)
    sphere("Throat", hr * 0.70, (0, 0.08, hr * 0.40), pm["belly"], C, scale=(1.0, 0.85, 0.60), parent=neck)
    lids = []
    for sx in (-1, 1):
        e = empty(f"Eye{sx}", C, (sx * 0.083, 0.03 + hr * 0.79, hz + 0.045), parent=neck)
        e.rotation_euler = (0, 0, sx * math.radians(-20))
        sphere(f"EyeWhite{sx}", 0.050, (0, 0, 0), pm["eye"], C, scale=(0.82, 0.55, 1.0), parent=e)
        sphere(f"Pupil{sx}", 0.031, (0, 0.021, -0.004), pm["pupil"], C, scale=(0.8, 0.5, 1.0), parent=e)
        lid = empty(f"Lid{sx}", C, parent=e)
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=40, v_segments=24, radius=0.057)
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -0.002], context="VERTS")
        bmesh.ops.scale(bm, vec=Vector((0.86, 0.62, 1.0)), verts=bm.verts)
        lo = from_bm(f"UpperLid{sx}", bm, pm["body"], C, lid)
        so = lo.modifiers.new("thick", "SOLIDIFY")
        so.thickness = 0.004
        smooth_by_angle(lo, 80)
        sphere(f"Cheek{sx}", 0.042, (sx * 0.135, 0.03 + hr * 0.63, hz - 0.035), pm["cheek"], C, scale=(1.0, 0.4, 0.62),
               parent=neck, rot=(0, 0, sx * math.radians(-40)))
        lids.append(lid)
    bill = empty("Bill", C, (0, 0.03 + hr * 0.85, hz - 0.035), parent=neck)
    bill.rotation_euler = (math.radians(-10), 0, 0)
    sphere("BillUpper", 0.088, (0, 0.06, 0.012), pm["bill"], C, scale=(0.95, 1.30, 0.48), parent=bill)
    sphere("BillLower", 0.074, (0, 0.045, -0.027), pm["bill"], C, scale=(0.82, 1.10, 0.36), parent=bill)
    for sx in (-1, 1):
        sphere(f"Nostril{sx}", 0.007, (sx * 0.022, 0.128, 0.040), pm["pupil"], C, scale=(1, 0.6, 0.5), parent=bill)
    return dict(root=root, torso=torso, neck=neck, lids=lids, head=head)
