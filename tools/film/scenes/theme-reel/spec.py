"""One variant's spec for the theme reel (plain python3):

    python3 -I spec.py theme-reel.json classic-dark PARTS_DIR OUT.json [--engine cycles]
                       [--samples N] [--device OPTIX|CUDA|METAL|…] [--cutout]
                       [--mode loop|scroll|flat]

PARTS_DIR is the variant's prepared folder (prep.py) as the rendering machine sees it; the font
copy in it is used for the Retro legends. --engine/--samples set the animation's engine and
samples; --device picks Cycles' GPU backend (the scene sets it, as dsfilm.render assumes Metal);
--cutout renders no field: a transparent picture with the shadow in its alpha (for the site);
--mode picks the scene's mode (scene.py): the looping film, the one-way scroll assembly (150
frames) or the flat top-down shot.
"""
import json
import os
import sys

a = sys.argv[1:]


def opt(name):
    if name in a:
        i = a.index(name)
        v = a[i + 1]
        del a[i:i + 2]
        return v
    return None


engine, samples, device, mode = opt("--engine"), opt("--samples"), opt("--device"), opt("--mode")
cutout = "--cutout" in a
if cutout:
    a.remove("--cutout")
src, variant, parts, out = a[:4]
spec = json.load(open(src))
theme, tone = variant.split("-")
spec["params"].update(theme=theme, tone=tone, parts=parts,
                      font=os.path.join(parts, "HankenGrotesk-Medium.ttf"))
if engine:
    spec["render"]["engine"] = spec["animation"]["engine"] = engine
if samples:
    spec["render"]["samples"] = spec["animation"]["samples"] = int(samples)
if device:
    spec["params"]["cycles_device"] = device
if cutout:
    spec["params"]["cutout"] = True
if mode:
    spec["params"]["mode"] = mode
    if mode == "scroll":         # the one-way assembly: 150 frames (5 s at 30 fps)
        spec["loop"] = {"seconds": 5, "fps": 30}
with open(out, "w") as f:
    json.dump(spec, f, indent=1)
