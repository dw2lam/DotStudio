"""Shows the layer stacking: each light layer alone, the stack building up, and a day-cycle
time-lapse mixed from the same layers. Writes OUT/stack/*.png and OUT/cycle/####.png (960x600).
  Blender -b --factory-startup --python stack.py -- OUT
"""
import math
import os
import sys

import bpy
import numpy as np

OUT = os.path.abspath(sys.argv[sys.argv.index("--") + 1])


def load(name):
    im = bpy.data.images.load(os.path.join(OUT, name + ".exr"))
    w, h = im.size
    px = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(px)
    a = px.reshape(h, w, 4)[..., :3]
    return a.reshape(h // 2, 2, w // 2, 2, 3).mean(axis=(1, 3))        # half size: 960x600


L = {k: load(k) for k in ("sun", "sun_low", "sky", "cabin", "mask")}
H, W, _ = L["sun"].shape
scene = bpy.context.scene
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_depth = "8"


def save(path, lin, ev):
    scene.view_settings.exposure = ev
    im = bpy.data.images.new("x", W, H, float_buffer=True, alpha=False)
    im.colorspace_settings.name = "Linear Rec.709"
    im.pixels.foreach_set(np.concatenate([lin, np.ones((H, W, 1), np.float32)], 2).astype(np.float32).ravel())
    im.save_render(path, scene=scene)
    bpy.data.images.remove(im)


os.makedirs(os.path.join(OUT, "stack"), exist_ok=True)
# 1) each layer alone, at the day exposure (its true share) and auto-exposed (to see what it lights)
for k in ("sun", "sun_low", "sky", "cabin"):
    save(os.path.join(OUT, "stack", f"alone-{k}.png"), L[k], 1.5)
    lum = float((L[k] @ np.array([0.2126, 0.7152, 0.0722])).mean())
    save(os.path.join(OUT, "stack", f"seen-{k}.png"), L[k], 1.5 + math.log2(max(0.08 / max(lum, 1e-5), 1e-3)))
# 2) stacking up to the day look
acc = np.zeros_like(L["sun"])
for i, k in enumerate(("cabin", "sky", "sun")):
    acc = acc + L[k]
    save(os.path.join(OUT, "stack", f"stack-{i + 1}-{k}.png"), acc, 1.5)
save(os.path.join(OUT, "stack", "mask.png"), L["mask"], 0.0)

# 3) a day cycle from the same four layers: (sun height, weather) -> weights, ~10 s
os.makedirs(os.path.join(OUT, "cycle"), exist_ok=True)
N = 240


def smooth(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


meta = []
for f in range(N):
    p = f / N
    elev = 60 * math.sin(math.tau * (p - 0.25)) - 5          # midnight -> noon -> midnight
    rain = smooth(0.40, 0.46, p) * (1 - smooth(0.56, 0.62, p))  # a shower in the early afternoon
    up = smooth(-6, 4, elev)                                   # any daylight
    low = smooth(-2, 6, elev) * (1 - smooth(10, 22, elev))     # the low sun near sunrise/sunset
    high = smooth(8, 20, elev)
    clear = 1 - rain
    warm = np.array([1.0, 0.80, 0.60]) * low + np.array([1, 1, 1]) * (1 - low)
    sky = (0.08 * np.array([0.75, 0.85, 1.0]) * (1 - up) + up * warm * (0.4 + 0.6 * high)) * (1 - 0.68 * rain)
    sun = high * clear
    sun_low = low * clear
    cabin = 1.0 + 1.2 * rain
    ev = 3.2 * (1 - up) + up * (1.5 + 0.1 * low) + 0.45 * rain
    lin = L["sun"] * sun + L["sun_low"] * sun_low + L["sky"] * sky + L["cabin"] * cabin
    save(os.path.join(OUT, "cycle", f"{f + 1:04d}.png"), lin.astype(np.float32), ev)
    meta.append(f"{f + 1} {elev:.1f} {rain:.2f} {up:.2f} {low:.2f}")
open(os.path.join(OUT, "cycle", "weights.txt"), "w").write("\n".join(meta))
print("STACKED", flush=True)
