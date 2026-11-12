"""Scene specs: a JSON file names a scene module and how to render it; run.py turns it into a .blend,
stills and/or a frame sequence. A scene module (tools/film/scenes/<name>/scene.py) provides:

    ASSETS   = ["ph:hdri:...", "ph:tex:...", "acg:...", ...]   # fetched before building
    VARIANTS = ["day", "golden", ...]                           # lighting presets it supports
    CAMERAS  = ["wide", "close", ...]
    def prepare():            # optional, plain-python pre-steps (e.g. generate textures)
    def build(ctx) -> dict    # builds everything; returns {"cameras": {name: camera_obj}}

`ctx` (Ctx below) carries the bpy scene, the Loop, the variant's lighting params, the spec's
"params" dict, a seeded RNG and helpers for collections.

Spec keys (all optional except "scene"):
    {
      "scene": "commute",
      "variant": "day",
      "loop": {"seconds": 48, "fps": 24},
      "params": {...},                                   # scene-specific knobs
      "render": {"engine": "cycles", "res": [1600, 1000], "samples": 384, "exposure": 0.0,
                 "motion_blur": true},
      "stills": [{"name": "day_wide", "camera": "wide", "frame": 1, "variant": "day"}, ...],
      "animation": {"camera": "wide", "engine": "eevee", "res": [2560, 1600], "samples": 64}
    }
"""
import importlib.util
import json
import os
import random
import sys
from types import SimpleNamespace

import bpy

from . import lighting, render
from .loop import Loop

FILM_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(path):
    with open(path) as f:
        return json.load(f)


def scene_module(name):
    path = os.path.join(FILM_ROOT, "scenes", name, "scene.py")
    d = os.path.dirname(path)
    if d not in sys.path:
        sys.path.insert(0, d)
    spec = importlib.util.spec_from_file_location(f"dsfilm_scene_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Ctx(SimpleNamespace):
    def coll(self, name, parent=None):
        c = bpy.data.collections.new(name)
        (parent or self.scene.collection).children.link(c)
        return c


def build(spec, variant=None, engine=None, res=None, samples=None):
    variant = variant or spec.get("variant", "day")
    mod = scene_module(spec["scene"])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    lp = Loop(**spec.get("loop", {}))
    lp.apply_scene(scene)
    params = dict(spec.get("params", {}))
    light = lighting.preset(variant, **params.get("lighting", {}).get(variant, {}))
    ctx = Ctx(scene=scene, loop=lp, variant=variant, light=light, params=params,
              rng=random.Random(params.get("seed", 7)), engine=engine)
    out = mod.build(ctx) or {}
    rs = dict(spec.get("render", {}))
    render.setup(scene, engine=engine or rs.get("engine", "cycles"), res=tuple(res or rs.get("res", (1600, 1000))),
                 samples=samples or rs.get("samples"), exposure=rs.get("exposure", 0.0) + light.get("exposure", 0.0),
                 motion_blur=rs.get("motion_blur", True))
    return ctx, out
