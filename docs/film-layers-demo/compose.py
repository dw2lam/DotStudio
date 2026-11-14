"""Relight test, phase 2: mix the light layers (linear EXRs from passes.py) into each condition,
add an approximation of the film look (bloom, halation, vignette), tone-map with the scene's AgX
view at that condition's exposure -> OUT/relit-<name>.png. Also writes OUT/mask.png and prints how
well sun+sky+cabin reproduces the all-lights render (the linearity check).
  Blender -b --factory-startup --python compose.py -- OUT
"""
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
    return px.reshape(h, w, 4)[..., :3].copy()


P = {k: load(k) for k in ("full", "sun", "sun_low", "sky", "cabin", "mask")}
H, W, _ = P["full"].shape
summed = P["sun"] + P["sky"] + P["cabin"]
inside = P["mask"][..., 0] < 0.5
err = np.abs(summed - P["full"])[inside].mean() / max(P["full"][inside].mean(), 1e-6)
print(f"LINEARITY sun+sky+cabin vs full: mean abs error {100 * err:.2f}% of mean radiance", flush=True)

# conditions: weights per layer (rgb), EEVEE exposure (preset exposure + the spec's -0.3)
G_SUN = np.array([1.0, 0.52 / 0.96, 0.22 / 0.90]) * 3.2 / 4.0
C = {
    "day":      dict(sun=1.0, sky=1.0, cabin=1.0, ev=1.5),
    "golden":   dict(sun=0.0, sun_low=1.0, sky=1.25 * np.array([1.0, 0.80, 0.60]), cabin=1.0, ev=1.6),
    "night":    dict(sun=0.0, sky=0.10 * np.array([0.75, 0.85, 1.0]), cabin=1.0, ev=3.2),
    "rain":     dict(sun=0.0, sky=0.32 * np.array([0.80, 0.86, 0.94]), cabin=2.2, ev=1.95),
    # conditions that were never rendered
    "overcast": dict(sun=0.0, sky=0.55 * np.array([0.92, 0.95, 1.0]), cabin=1.3, ev=1.75),
    "hazy-sun": dict(sun=0.45, sky=0.75, cabin=1.0, ev=1.6),
    "blue-hour": dict(sun=0.0, sky=0.22 * np.array([0.55, 0.68, 1.0]), cabin=1.0, ev=2.6),
}


def blur(a, r, n=3):
    """Separable box blur, n passes (~gaussian), on a half-res copy."""
    s = a[::2, ::2]
    r = max(1, r // 2)
    for _ in range(n):
        for ax in (0, 1):
            c = np.cumsum(np.pad(s, [(r + 1, r) if i == ax else (0, 0) for i in range(3)], mode="edge"), axis=ax)
            hi = np.take(c, np.arange(2 * r + 1, c.shape[ax]), axis=ax)
            lo = np.take(c, np.arange(0, c.shape[ax] - 2 * r - 1), axis=ax)
            s = (hi - lo) / (2 * r + 1)
    return np.repeat(np.repeat(s, 2, 0), 2, 1)[:a.shape[0], :a.shape[1]]


yy, xx = np.mgrid[0:H, 0:W]
rr = np.sqrt(((xx / W - 0.5) / 0.625) ** 2 + ((yy / H - 0.5) / 0.625) ** 2)
mask_v = 1 - np.clip((rr - 0.82) / 0.36, 0, 1) ** 2
vig = (1 - 0.22 * (1 - mask_v))[..., None]


def look(x):
    hal = blur(np.maximum(x - 2.0, 0), int(0.012 * W)) * np.array([1.0, 0.32, 0.10])
    blo = blur(np.maximum(x - 3.0, 0), int(0.03 * W))
    return (x + 0.35 * hal + 0.08 * blo * 4) * vig


scene = bpy.context.scene
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_depth = "8"


def save(name, lin, ev):
    scene.view_settings.exposure = ev
    im = bpy.data.images.new(name, W, H, float_buffer=True, alpha=False)
    im.colorspace_settings.name = "Linear Rec.709"
    rgba = np.concatenate([lin, np.ones((H, W, 1), np.float32)], axis=2).astype(np.float32)
    im.pixels.foreach_set(rgba.ravel())
    im.save_render(os.path.join(OUT, name + ".png"), scene=scene)
    bpy.data.images.remove(im)


for name, c in C.items():
    lin = (P["sun"] * np.asarray(c["sun"]) + P["sun_low"] * np.asarray(c.get("sun_low", 0.0)) + P["sky"] * np.asarray(c["sky"]) + P["cabin"] * np.asarray(c["cabin"]))
    save(f"relit-{name}", look(lin.astype(np.float32)), c["ev"])
save("check-full", look(P["full"]), 1.5)

scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
save("mask", P["mask"], 0.0)
print("COMPOSED", list(C), flush=True)
