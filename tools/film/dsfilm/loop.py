"""Seamless-loop helpers. A loop is LOOP seconds at FPS; frames 1..N are rendered and frame N+1
equals frame 1. Anything that moves must be periodic in LOOP:

    lp = Loop(seconds=48, fps=24)
    lp.t(frame)                         # seconds at a frame (frame 1 -> 0.0)
    lp.wave(t, k, phase)                # sin with exactly k cycles per loop (k integer)
    lp.pulse_train(t, period, fn)       # sum of fn(phase) for events every `period` s; period must
                                        #   divide the loop (lp.fit(period) rounds it to one that does)
    lp.wrap(t)                          # t mod LOOP
    lp.bake(objs_props, fn)             # fn(t) sets properties; keyframes every frame 1..N+1, linear
    lp.scroll(obj, axis, distance)      # move `distance` per loop, linear + extrapolated (motion blur)
    lp.strip(tile_coll, coll, period, copies=(-1,0,1,2), mirror_y=False)
                                        # instance a scenery tile along X so a scroll of `period`
                                        #   per loop is seamless

Smooth one-shot events inside the loop (a jerk awake at 17 s) are fine as long as the curve returns
to its start value before LOOP: build them from smoothstep()/bump() and check f(0) == f(LOOP).
"""
import math

import bpy

TAU = math.tau


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def bump(x, centre, width):
    """A Gaussian bump (event) — 1 at centre."""
    return math.exp(-((x - centre) / width) ** 2)


def fcurves(ob):
    ad = ob.animation_data
    if not ad or not ad.action:
        return []
    a = ad.action
    if hasattr(a, "fcurves") and not hasattr(a, "layers"):
        return list(a.fcurves)
    out = []
    for layer in getattr(a, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                out += list(cb.fcurves)
    if not out and hasattr(a, "fcurves"):
        out = list(a.fcurves)
    return out


def _all_fcurves(id_data):
    ad = getattr(id_data, "animation_data", None)
    if not ad or not ad.action:
        return []
    return fcurves(id_data)


class Loop:
    def __init__(self, seconds=48.0, fps=24):
        self.seconds = float(seconds)
        self.fps = int(fps)
        self.frames = int(round(self.seconds * self.fps))

    def t(self, frame):
        return (frame - 1) / self.fps

    def wrap(self, t):
        return t % self.seconds

    def wave(self, t, k, phase=0.0):
        return math.sin(TAU * k * t / self.seconds + phase)

    def fit(self, period):
        """The nearest period that divides the loop a whole number of times."""
        n = max(round(self.seconds / period), 1)
        return self.seconds / n

    def pulse_train(self, t, period, fn, offsets=(0.0,)):
        out = 0.0
        for o in offsets:
            out += fn((t - o) % period)
        return out

    def apply_scene(self, scene):
        scene.render.fps = self.fps
        scene.frame_start, scene.frame_end = 1, self.frames

    def bake(self, ids, fn, props=("location", "rotation_euler", "scale")):
        """Calls fn(t) for every frame 1..N+1 and keyframes `props` on each id in `ids` (objects,
        or (datablock, data_path) pairs). Interpolation is linear so the sampled curve is exact."""
        for f in range(1, self.frames + 2):
            fn(self.t(f))
            for item in ids:
                if isinstance(item, tuple):
                    owner, path = item
                    owner.keyframe_insert(path, frame=f)
                else:
                    for p in props:
                        item.keyframe_insert(p, frame=f)
        for item in ids:
            owner = item[0] if isinstance(item, tuple) else item
            idd = getattr(owner, "id_data", owner)
            for fc in _all_fcurves(idd):
                for kp in fc.keyframe_points:
                    kp.interpolation = "LINEAR"

    def scroll(self, ob, distance, axis=0):
        """Moves `ob` by `distance` along `axis` over the loop, linearly, extrapolated both ways."""
        start = ob.location[axis]
        ob.keyframe_insert("location", index=axis, frame=1)
        ob.location[axis] = start + distance
        ob.keyframe_insert("location", index=axis, frame=self.frames + 1)
        ob.location[axis] = start
        for fc in fcurves(ob):
            fc.extrapolation = "LINEAR"
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"

    @staticmethod
    def strip(tile, coll, period, root, copies=(-1, 0, 1, 2), mirror_y=False, x_offset=0.0, name="Tile", mirror_scale_z=1.0):
        """Instances `tile` (a collection holding one period of scenery, x in [0, period)) along X
        under `root`. With mirror_y it is also placed on the other side of the track (y -> -y),
        shifted by x_offset so the two sides don't match. mirror_scale_z squashes that mirrored side
        (e.g. 0.6) when it is only seen in reflections and shadows: a low-rise sun side lets low
        sunlight in, with poles and roofs still sweeping shadows across the interior."""
        out = []
        for k in copies:
            for side in ((1, -1) if mirror_y else (1,)):
                e = bpy.data.objects.new(f"{name}{k}{'m' if side < 0 else ''}", None)
                e.instance_type = "COLLECTION"
                e.instance_collection = tile
                e.location = (k * period + (x_offset if side < 0 else 0.0), 0, 0)
                e.scale = (1, side, 1 if side > 0 else mirror_scale_z)
                e.parent = root
                coll.objects.link(e)
                out.append(e)
        return out


def seam_check(lp, fn, tol=1e-6):
    """True if fn(0) == fn(LOOP) (fn returns a number or tuple)."""
    a, b = fn(0.0), fn(lp.seconds)
    a = a if isinstance(a, (tuple, list)) else (a,)
    b = b if isinstance(b, (tuple, list)) else (b,)
    return all(abs(x - y) <= tol for x, y in zip(a, b))
