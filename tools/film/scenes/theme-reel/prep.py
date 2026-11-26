"""Prepares captured UI parts (capture.sh) for the theme-reel scene. Plain python3 + Pillow + numpy.

    python3 -I prep.py PARTS_DIR/<variant> WORK_DIR/<variant>

- window.png: the window as captured is square-cornered and opaque; it gets macOS's rounded
  corners (alpha) so it reads as a window floating in the set.
- every part: its bodies (cards, boxes, keys: split into columns where a transparent gap runs
  top to bottom) as rectangles in points, so the scene can give each body a real slab of
  thickness under its picture; "glass" marks a see-through body (Classic's glass cards).
  Written to WORK_DIR/<variant>/parts.json:
      {"scale": 2, "parts": {"deck": {"size": [w, h], "bodies": [{"rect": [x0, y0, x1, y1],
                                                                   "glass": false}, ...]}, ...}}
  (points, origin top left).
"""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw

PARTS = ["window", "deck", "tiles", "inspector", "keys"]
WINDOW_RADIUS_PT = 14


def bodies(alpha, scale):
    solid = alpha > 4                      # Classic's glass cards are a flat ~3 % fill
    cols = solid.sum(axis=0) >= 20 * scale
    out, x = [], 0
    w = len(cols)
    while x < w:
        if not cols[x]:
            x += 1
            continue
        x0 = x
        while x < w and cols[x]:
            x += 1
        rows = np.where(solid[:, x0:x].any(axis=1))[0]
        if (x - x0) >= 20 * scale and len(rows):
            inside = alpha[rows[0]:rows[-1] + 1, x0:x]
            out.append({"rect": [x0 / scale, rows[0] / scale, x / scale, (rows[-1] + 1) / scale],
                        "glass": bool(np.median(inside) < 200)})
    return out


def main(src, dst):
    os.makedirs(dst, exist_ok=True)
    scale = None
    manifest = {}
    for name in PARTS:
        im = Image.open(os.path.join(src, name + ".png")).convert("RGBA")
        if scale is None:
            # the window is captured at 1280 pt wide: its pixel width says the display's scale
            scale = round(Image.open(os.path.join(src, "window.png")).width / 1280)
        if name == "window":
            r = WINDOW_RADIUS_PT * scale
            mask = Image.new("L", im.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], radius=r, fill=255)
            a = np.minimum(np.asarray(im.getchannel("A")), np.asarray(mask))
            im.putalpha(Image.fromarray(a.astype(np.uint8)))
        im.save(os.path.join(dst, name + ".png"))
        a = np.asarray(im.getchannel("A"))
        manifest[name] = {"size": [im.width / scale, im.height / scale], "bodies": bodies(a, scale)}
    with open(os.path.join(dst, "parts.json"), "w") as f:
        json.dump({"scale": scale, "parts": manifest}, f, indent=1)
    print(json.dumps({k: len(v["bodies"]) for k, v in manifest.items()}))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
