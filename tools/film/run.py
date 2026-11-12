"""Builds and renders a film scene from a spec. Run headless (never opens the Blender UI):

    Blender -b --factory-startup --python tools/film/run.py -- SPEC.json [options]

    --variant NAME        lighting variant (default: the spec's)
    --stills DIR          render every still in the spec whose variant matches -> DIR/<name>.png
    --still FILE          render one still (with --camera, --frame)
    --camera NAME         camera for --still / --anim (default: first in the scene's CAMERAS)
    --frame N             frame for --still (default 1)
    --anim DIR            render frames DIR/####.png (resumable; see --frames)
    --frames A-B          range for --anim (default: whole loop, 1..N)
    --engine cycles|eevee, --res WxH, --samples N    override the spec's render block
    --save FILE.blend     save the built scene (open it later with Blender -b FILE --python ...)

Prints RENDER/ANIM timing lines for budgeting.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dsfilm import assets, render, spec  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name, default=None):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1]
    return default


sp = spec.load(argv[0])
mod = spec.scene_module(sp["scene"])
miss = assets.missing(getattr(mod, "ASSETS", []))
if miss:
    print("fetching", miss, flush=True)
    assets.fetch_all(miss)
if hasattr(mod, "prepare"):
    mod.prepare()
res = tuple(int(v) for v in opt("--res").split("x")) if opt("--res") else None
samples = int(opt("--samples")) if opt("--samples") else None
variant = opt("--variant")
anim = sp.get("animation", {})
engine = opt("--engine") or (anim.get("engine") if opt("--anim") else None)
ctx, out = spec.build(sp, variant=variant, engine=engine,
                      res=res or (tuple(anim["res"]) if opt("--anim") and "res" in anim else None),
                      samples=samples or (anim.get("samples") if opt("--anim") else None))
cams = out.get("cameras", {})
cam_name = opt("--camera") or (anim.get("camera") if opt("--anim") else None) or next(iter(cams), None)
if opt("--save"):
    import bpy
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(opt("--save")))
if opt("--still"):
    render.still(ctx.scene, opt("--still"), int(opt("--frame", 1)), cams.get(cam_name))
if opt("--stills"):
    os.makedirs(opt("--stills"), exist_ok=True)
    for st in sp.get("stills", []):
        if st.get("variant", sp.get("variant", "day")) != ctx.variant:
            continue
        render.still(ctx.scene, os.path.join(opt("--stills"), st["name"] + ".png"), st.get("frame", 1),
                     cams.get(st.get("camera", cam_name)))
if opt("--anim"):
    a, b = (opt("--frames") or f"1-{ctx.loop.frames}").split("-")
    render.frames(ctx.scene, opt("--anim"), int(a), int(b), cams.get(cam_name))
