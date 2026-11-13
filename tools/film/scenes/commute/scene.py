"""Commute — inside a Japanese commuter train on a bright day; the city slides past the windows
and a penguin in a suit dozes on the end seat. The first dsfilm scene.

Loop: 48 s at 24 fps (1152 frames). The scenery strip is 650 m (26 rails of 25 m), so the train
runs at 650/48 = 13.5 m/s (~49 km/h); rail-joint bumps, carriage sway, strap swing, the sun's
bearing (the line curving), breathing and the dozing cycle are all periodic in the loop.

Params (spec "params"): penguin_color [r,g,b], penguin (bool), sway (0..2), cabin (lamp scale),
lighting {variant: {preset overrides}}.
"""
import math
import os
import subprocess
import sys

import bpy
from mathutils import Vector

from dsfilm import geometry as geo, lighting
from dsfilm.loop import Loop, bump, smoothstep

import carriage as car
import city
import penguin as peng
import posters

import json

# the CC0 assets (plain JSON so tools/film/fetch.py can read it without Blender)
with open(os.path.join(os.path.dirname(__file__), "assets.json")) as _f:
    ASSETS = json.load(_f)
VARIANTS = ["day", "golden", "night", "rain"]
CAMERAS = ["wide", "close", "aisle"]

PERIOD = 650.0
JOINT = 25.0
PENGUIN_SEAT = 0          # the end seat of the far bench, by the partition (screen right)


def prepare():
    """Posters are drawn with Pillow, which Blender's Python lacks: use the system python3."""
    paths = posters.all_posters()
    if not all(os.path.exists(p) for p in paths.values()):
        subprocess.run(["python3", "-I", os.path.join(os.path.dirname(__file__), "posters.py")], check=True)


def build(ctx):
    P = dict(ctx.light)
    # physical units: the diffusers glow at ~1.5 (sky ~0.3-3) and light the cabin to a few hundred lux,
    # which the sun swamps by day; the variant exposure (lighting presets) brings the interior up.
    P["cabin_lamp"] = 0.9 * P.get("cabin", 1.0) * ctx.params.get("cabin", 1.0)
    lp = ctx.loop
    speed = PERIOD / lp.seconds

    C_CAR = ctx.coll("Carriage")
    C_PEN = ctx.coll("Penguin")
    C_OUT = ctx.coll("Outside")
    tile = bpy.data.collections.new("SceneryTile")      # instanced only
    lib = bpy.data.collections.new("AssetLibrary")      # instanced only

    M = car.make_materials(P, None)
    pivots = car.build(C_CAR, M, posters.all_posters())
    # cabin lamps also need a real light source shape for Cycles' sampling: area lights along strips
    for s in (-1, 1):
        for k in range(6):
            ld = bpy.data.lights.new(f"CabinLight{s}{k}", "AREA")
            ld.shape = "RECTANGLE"
            ld.size, ld.size_y = 2.2, 0.12
            ld.energy = P["cabin_lamp"] * 0.6
            ld.color = (1.0, 0.97, 0.92)
            lo = bpy.data.objects.new(f"CabinLight{s}{k}", ld)
            C_CAR.objects.link(lo)
            lo.location = (car.CAR_X[0] + 1.25 + k * 2.5, s * 0.62, car.CEIL - 0.115)
            try:
                lo.visible_camera = False
                lo.visible_glossy = False
            except Exception:
                pass

    city.build_tile(tile, lib, P, PERIOD)
    root = geo.empty("SceneryRoot", C_OUT)
    Loop.strip(tile, C_OUT, PERIOD, root, copies=(-1, 0, 1, 2), mirror_y=True, x_offset=PERIOD * 0.37,
               mirror_scale_z=ctx.params.get("sun_side_height", 0.55))
    lp.scroll(root, -PERIOD)

    pen = None
    if ctx.params.get("penguin", True):
        pen = peng.build(C_PEN, (car.seat_x(PENGUIN_SEAT) + 0.04, -car.HALF_W + 0.05 + 0.36, car.SEAT_TOP - 0.025),
                         yaw_deg=-12, color=tuple(ctx.params.get("penguin_color", (0.0, 0.42, 0.56))))

    rig = lighting.setup(ctx.scene, C_OUT, ctx.variant, **ctx.params.get("lighting", {}).get(ctx.variant, {}))
    cams = _cameras(C_CAR)

    # ---------------------------------------------------------------- motion (periodic in the loop)
    sway_amp = ctx.params.get("sway", 1.0)
    jt = lp.fit(JOINT / speed)                     # rail-joint period, whole joints per loop

    def bumps(t):
        def hit(ph):
            return math.exp(-ph * 20) * math.sin(ph * 64)
        offs = (0.0, 2.1 / speed, 13.8 / speed, 15.9 / speed)
        return lp.pulse_train(t, jt, hit, offs)

    def sway(t):
        lat = 0.6 * lp.wave(t, 5, 0.3) + 0.35 * lp.wave(t, 9, 1.7) + 0.2 * lp.wave(t, 23, 0.2)
        roll = 0.5 * lp.wave(t, 5, 0.8) + 0.3 * lp.wave(t, 13, 2.2) + 0.15 * lp.wave(t, 31, 1.0)
        return lat * sway_amp, roll * sway_amp

    rigs = {name: (c.parent, c.parent.location.copy(), c.parent.rotation_euler.copy()) for name, c in cams.items()}
    base_el, base_az = P["sun_elev"], P["sun_az"]

    def frame(t):
        lat, roll = sway(t)
        b = bumps(t)
        for r, loc, rot in rigs.values():
            r.location = loc + Vector((0, lat * 0.006, b * 0.0015 + 0.002 * lp.wave(t, 17)))
            r.rotation_euler = (rot[0] + math.radians(b * 0.05), rot[1] + math.radians(roll * 0.22), rot[2] + math.radians(lat * 0.07))
        rig.sun.rotation_euler = lighting.sun_euler(base_el + 0.6 * lp.wave(t, 2, 0.4),
                                                    base_az + 4.0 * lp.wave(t, 1) + 1.5 * lp.wave(t, 3, 1.0))
        for i, p in enumerate(pivots):
            ph = i * 0.37
            lat2, _ = sway(t - 0.35 - 0.02 * (i % 5))
            p.rotation_euler = (math.radians(lat2 * 3.0 + b * 0.5 + 0.5 * lp.wave(t, 29, ph)),
                                math.radians(0.8 * lp.wave(t, 7, ph * 1.3)), 0)
        if pen:
            br = breathing(lp, t)
            pen["torso"].scale = (1 + 0.010 * br, 1 + 0.018 * br, 1 + 0.006 * br)
            pen["torso"].rotation_euler = (math.radians(-0.6 * br), math.radians(lat * 0.9), 0)
            pitch, lid = dozing(lp, t)
            pitch += lat * 1.2 + b * 0.6
            # head bone: x = nod (chin down is negative), y = turn (bone axis), z = lean (world -y)
            pen["head"].rotation_euler = (math.radians(-0.65 * pitch), math.radians(roll * 1.5), math.radians(-lat * 2.0))
            for l in pen["lids"]:
                l.rotation_euler = (math.radians(80 - 170 * lid), 0, 0)  # dome back = open, forward = shut
        if M.get("rain_map") is not None:
            M["rain_map"].inputs["Location"].default_value = (0.0, 0.0, 6.0 * t / lp.seconds)

    ids = [r for r, _, _ in rigs.values()] + [rig.sun] + pivots
    if pen:
        ids += [pen["torso"], (pen["head"], "rotation_euler")] + pen["lids"]
    if not ctx.params.get("static", False):
        lp.bake(ids, frame, props=("location", "rotation_euler", "scale"))
    else:
        frame(0.0)
    return {"cameras": cams, "penguin": pen, "rig": rig}


def breathing(lp, t):
    n = round(lp.seconds / 4.4)           # ~4.4 s per breath, whole breaths per loop
    ph = math.tau * n * t / lp.seconds
    return math.sin(ph) + 0.25 * math.sin(2 * ph - 0.6)


def dozing(lp, t):
    """Head pitch in degrees (+ = chin down) and lid closure (1 = shut) — one dozing cycle per loop:
    drift off, stir awake at 17 s (sleepy half-lids, a slow blink), drift again, a heavy nod at 33 s,
    settle."""
    t = lp.wrap(t)
    p = 14.0 + 14.0 * smoothstep(0.0, 17.0, t) * (1 - smoothstep(17.15, 17.55, t))
    p -= 9.0 * smoothstep(17.15, 17.55, t) * (1 - smoothstep(17.55, 20.5, t))     # a gentle start, not a jolt
    p += 16.0 * smoothstep(21.0, 32.5, t) * (1 - smoothstep(33.6, 35.0, t))
    p += 6.0 * bump(t, 33.6, 0.45)
    # lids: 1 = shut; awake he only gets as far as sleepy half-lids (0.45), with a slow blink
    lid = 1.0 - 0.55 * smoothstep(17.2, 17.6, t) * (1 - smoothstep(20.2, 21.8, t))
    lid += bump(t, 19.3, 0.12) * (1 - lid)
    lid -= 0.25 * bump(t, 34.2, 0.5)
    return p, min(max(lid, 0.0), 1.0)


def _cameras(C):
    out = {}
    specs = {
        # seated opposite, a little toward the car centre, looking across at the bench and windows
        "wide": dict(frm=(0.0, 1.06, 1.17), to=(-1.15, -1.45, 1.17), lens=26, fstop=5.6, focus=(car.seat_x(0), -1.0, 0.95),
                     shift_y=0.055),   # level camera, lens shift up: verticals stay straight, ad boards in frame
        # closer on the penguin, longer lens, shallow focus
        "close": dict(frm=(-1.05, 0.55, 1.16), to=(car.seat_x(0) - 0.05, -1.10, 1.10), lens=50, fstop=2.2,
                      focus=(car.seat_x(0) + 0.04, -0.75, 1.22)),
        # standing in the aisle looking down the car
        "aisle": dict(frm=(1.6, 0.35, 1.55), to=(-3.0, -0.9, 1.05), lens=24, fstop=5.6, focus=(car.seat_x(0), -1.0, 1.0)),
    }
    for name, s in specs.items():
        cd = bpy.data.cameras.new(f"Cam_{name}")
        cd.lens = s["lens"]
        cd.sensor_width = 36
        cd.sensor_fit = "HORIZONTAL"
        cd.dof.use_dof = True
        cd.dof.aperture_fstop = s["fstop"]
        cd.shift_y = s.get("shift_y", 0.0)
        cd.dof.focus_distance = (Vector(s["focus"]) - Vector(s["frm"])).length
        rig = geo.empty(f"CamRig_{name}", C, s["frm"])
        geo.look_at(rig, s["frm"], s["to"])
        cam = bpy.data.objects.new(f"Cam_{name}", cd)
        C.objects.link(cam)
        cam.parent = rig
        out[name] = cam
    return out
