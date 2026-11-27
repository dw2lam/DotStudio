"""Prepares captured UI parts (capture.sh) for the theme-reel scene: takes the app apart.
Plain python3 + Pillow + numpy.

    python3 -I prep.py PARTS_DIR/<variant> WORK_DIR/<variant> [--debug]

The assembled object is the app as it shows: the window (UIShots' theme-layer-window) with the
editor's inspector (theme-layer-inspector) docked at its right. Each is a MODULE — a base that rests
on the field — and each module is taken apart into its visible ELEMENTS, found in the picture
itself, so every one sits exactly where it does in the app:

- level 1: what stands on the module's ground (the window's chassis, the inspector's panel): the
  toolbar keys, the Screensaver and Wallpaper cards, the sync key, the filter box, the Scenes box;
  the inspector's header, readouts, dials, swatch… — connected regions that differ from the ground;
- level 2: what stands on a level-1 element's own ground: a card's screen and its keys, the filter
  box's search field and chips, each style tile's picture… (text is not an element: its pixels are
  thin, so it stays printed on its parent).

Each element is cut out as its own picture (a rounded rectangle; the radius measured from its
corners), and where it sits its parent's picture gets a SOCKET — the parent's ground a step darker
— so an element that drops in fills its socket exactly. A partly hidden last row of tiles (the
window's capture is cut off at the bottom) is cut away, and the window ends below the last full row.

Retro's inspector dials are marked "dial" (with their cap colour): the scene builds them as real
machined knobs that seat in their sockets. The one signal-orange key is marked "press".

Writes WORK_DIR/<variant>/: module and element PNGs and parts.json:
    {"scale": 2, "size": [W, H],                                    # the assembly, points
     "modules": [{"name": "window", "png": "m-window.png", "rect": [x0, y0, x1, y1], "radius": 14,
                  "children": [{"png": "e-3.png", "rect": [...], "radius": 6, "kind": "card",
                                "children": [{"png": "e-3-1.png", "rect": [...], "radius": 3,
                                              "kind": "key" | "dial" | "press", "cap": [r, g, b]}]}]}]}
(rects in points, the assembly's origin top left). --debug also writes debug.png (the elements
outlined).
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

WINDOW_RADIUS_PT = 14
DOCK_GAP_PT = 28                 # the inspector's distance from the window's right edge


# ---------------------------------------------------------------- binary morphology (numpy only)

def _boxsum(m, k):
    """Sum of m over a k x k box centred on each pixel (zero outside)."""
    p = k // 2
    a = np.pad(m.astype(np.int32), ((p + 1, p), (p + 1, p)))
    c = a.cumsum(0).cumsum(1)
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def dilate(m, k):
    return _boxsum(m, k) > 0 if k > 1 else m


def erode(m, k):
    return _boxsum(m, k) == k * k if k > 1 else m


def label(m):
    """4-connected components by runs + union-find. Returns (labels, [(y0, y1, x0, x1, label)])."""
    H, W = m.shape
    parent = []

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    runs, prev = [], []
    for y in range(H):
        row = m[y]
        d = np.diff(np.concatenate(([0], row.view(np.int8), [0])))
        starts, ends = np.where(d == 1)[0], np.where(d == -1)[0]
        cur = []
        j = 0
        for s, e in zip(starts, ends):
            i = len(parent)
            parent.append(i)
            runs.append((y, s, e))
            while j < len(prev) and prev[j][2] <= s:
                j += 1
            k = j
            while k < len(prev) and prev[k][1] < e:
                a, b = find(i), find(prev[k][0])
                if a != b:
                    parent[max(a, b)] = min(a, b)
                k += 1
            cur.append((i, s, e))
        prev = cur
    lab = np.zeros((H, W), np.int32)
    boxes = {}
    for i, (y, s, e) in enumerate(runs):
        r = find(i) + 1
        lab[y, s:e] = r
        b = boxes.get(r)
        boxes[r] = (y, y + 1, s, e) if b is None else (b[0], y + 1, min(b[2], s), max(b[3], e))
    return lab, [(b[0], b[1], b[2], b[3], r) for r, b in boxes.items()]


def fill_holes(m):
    lab, boxes = label(~m)
    H, W = m.shape
    out = m.copy()
    for y0, y1, x0, x1, r in boxes:
        if y0 > 0 and x0 > 0 and y1 < H and x1 < W:
            out[y0:y1, x0:x1] |= lab[y0:y1, x0:x1] == r
    return out


def ground(px, region):
    """The most common colour in region (the ground an element stands on)."""
    a = px[region].reshape(-1, px.shape[-1])[:, :3]
    q = (a // 4).astype(np.int32)
    key = q[:, 0] * 4096 + q[:, 1] * 64 + q[:, 2]
    vals, counts = np.unique(key, return_counts=True)
    k = vals[np.argmax(counts)]
    return a[key == k].astype(np.float32).mean(axis=0)


def corner_radius(mask):
    """A rounded rectangle's radius from how much of its bbox corners are empty: the area missing
    from a corner is r^2 (1 - pi/4)."""
    h, w = mask.shape
    c = max(2, min(h, w) // 2)
    miss = []
    for ys, xs in ((slice(0, c), slice(0, c)), (slice(0, c), slice(w - c, w)),
                   (slice(h - c, h), slice(0, c)), (slice(h - c, h), slice(w - c, w))):
        miss.append((~mask[ys, xs]).sum())
    a = float(np.median(miss))
    return min(np.sqrt(a / (1 - np.pi / 4)), min(h, w) / 2)


def components(diff_mask, scale, min_side, min_fill, max_frac=0.92, close=1.0, parent_shape=None):
    k = max(1, int(close * scale)) | 1
    m = erode(dilate(diff_mask, k), k)
    m = fill_holes(m)
    lab, boxes = label(m)
    out = []
    for y0, y1, x0, x1, i in boxes:
        sl = (slice(y0, y1), slice(x0, x1))
        sub = lab[sl] == i
        h, w = sub.shape
        if min(h, w) < min_side * scale or sub.mean() < min_fill:
            continue
        if parent_shape and (h > max_frac * parent_shape[0] and w > max_frac * parent_shape[1]):
            continue
        out.append((sl, sub))
    return out


def rrect_mask(w, h, r, ss=4):
    im = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(im).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], radius=max(0, r * ss), fill=255)
    return np.asarray(im.resize((w, h), Image.LANCZOS)).astype(np.float32) / 255


def with_labels(found, diff, thr, scale, H):
    """A style tile (a thumbnail-shaped part inside a box) takes the name printed under it, so the
    picture and its label land together as one card (and no label sits over an empty socket)."""
    rects = [(sl[0].start, sl[0].stop, sl[1].start, sl[1].stop) for sl, _ in found]
    out = []
    for k, (sl, sub) in enumerate(found):
        y0, y1, x0, x1 = rects[k]
        w, h = x1 - x0, y1 - y0
        if 1.4 < w / h < 1.85 and w < 260 * scale:
            last, yy, limit = None, y1, min(H, y1 + int(30 * scale))
            while yy < limit:
                if (diff[yy, x0:x1] > thr).any():
                    last = yy
                elif last is not None and yy - last > 3 * scale:
                    break
                yy += 1
            if last is not None:
                y2 = min(H, last + 1 + int(5 * scale))
                if all(not (o[0] < y2 and o[1] > y1 and o[2] < x1 and o[3] > x0)
                       for j, o in enumerate(rects) if j != k):
                    sub2 = np.ones((y2 - y0, w), bool)
                    sub2[:h] = sub
                    sl, sub = (slice(y0, y2), slice(x0, x1)), sub2
        out.append((sl, sub))
    return out


def socket_colour(g):
    lum = (0.2126 * g[0] + 0.7152 * g[1] + 0.0722 * g[2]) / 255
    # a shallow recess, not a hole: an empty tile socket mustn't read as a black picture
    return g * (0.95 if lum > 0.35 else 0.80)


def take_apart(px, scale, name, theme, out_dir, offset, debug, depth=0, ground_rgb=None, prefix="e"):
    """Finds px's elements (level 1 on the module's ground, then each element's own), cuts them
    out, sockets them into px (in place). Returns the elements' manifest entries."""
    H, W = px.shape[:2]
    alpha = px[..., 3] > 8
    g = ground_rgb if ground_rgb is not None else ground(px, alpha)
    diff = np.abs(px[..., :3].astype(np.float32) - g).max(axis=-1)
    if depth == 0:
        thr, min_side, min_fill, close = (5.0 if theme == "classic" else 7.0), 15, 0.55, 1.5
    else:
        thr, min_side, min_fill, close = 14.0, 15, 0.6, 1.0
        # a picture (a style's thumbnail, a screen) has no parts of its own: little flat ground, or
        # a thumbnail's shape and size (StandBy's black is flat, but it's still a picture)
        thumb = 1.4 < W / H < 1.85 and W < 260 * scale
        if (diff[alpha] < thr).mean() < 0.25 or thumb:
            return []
    inner = erode(alpha, int(4 * scale) + 1)
    found = components((diff > thr) & inner, scale, min_side, min_fill, close=close, parent_shape=(H, W))
    found.sort(key=lambda c: (c[0][0].start // int(40 * scale), c[0][1].start))
    if depth == 1:
        found = with_labels(found, diff, thr, scale, H)
    entries = []
    orig = px.copy()
    for k, (sl, sub) in enumerate(found):
        y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
        h, w = y1 - y0, x1 - x0
        r = corner_radius(sub)
        if r > 0.42 * min(h, w):
            r = min(h, w) / 2                                   # pills and circles
        shape = rrect_mask(w, h, r)
        crop = orig[y0:y1, x0:x1].copy()
        crop[..., 3] = (shape * 255).astype(np.uint8)
        eid = f"{prefix}-{k}"
        e = {"png": eid + ".png", "radius": round(r / scale, 2),
             "rect": [round((offset[0] + x0) / scale, 2), round((offset[1] + y0) / scale, 2),
                      round((offset[0] + x1) / scale, 2), round((offset[1] + y1) / scale, 2)], "kind": "card" if depth == 0 else "key"}
        # Retro's dials: round, about a knob's size, in the inspector; the cap's colour from the centre
        if name == "inspector" and theme == "retro" and abs(w - h) < 0.15 * w and 26 * scale <= w <= 56 * scale \
                and 0.6 < sub.mean() < 0.9:
            cy, cx = h // 2, w // 2
            rr = int(0.22 * w)
            e["kind"] = "dial"
            e["cap"] = [round(float(v)) for v in np.median(crop[cy - rr:cy + rr, cx - rr:cx + rr, :3].reshape(-1, 3), axis=0)]
        if depth == 0 and e["kind"] != "dial":
            sub_px = crop.copy()
            sub_px[..., 3] = np.where(shape > 0.5, 255, 0).astype(np.uint8)
            e["children"] = take_apart(sub_px, scale, name, theme, out_dir, (offset[0] + x0, offset[1] + y0), debug,
                                       depth + 1, prefix=eid)
            crop[..., :3] = sub_px[..., :3]                     # the children's sockets
        Image.fromarray(crop).save(os.path.join(out_dir, eid + ".png"))
        # the socket in px: the ground a step darker, in the element's own shape
        s = shape[..., None]
        sc = socket_colour(g)
        region = px[y0:y1, x0:x1, :3].astype(np.float32)
        px[y0:y1, x0:x1, :3] = (region * (1 - s) + sc * s).astype(np.uint8)
        entries.append(e)
        if debug is not None:
            debug.rectangle([offset[0] + x0, offset[1] + y0, offset[0] + x1, offset[1] + y1],
                            outline=(255, 0, 255) if depth == 0 else (0, 200, 255), width=3)
    return entries


def mark_press(modules, work):
    """The key that presses during the hold: the small key with the most signal orange (Retro), or
    else the most accent blue (Classic's chosen chip)."""
    keys = []
    for m in modules:
        for c in m["children"]:
            for k in [c] + c.get("children", []):
                if k["kind"] in ("key", "card") and k["rect"][2] - k["rect"][0] < 140:
                    a = np.asarray(Image.open(os.path.join(work, k["png"])).convert("RGB")).astype(np.int32)
                    orange = ((a[..., 0] > 200) & (a[..., 1] > 70) & (a[..., 1] < 150) & (a[..., 2] < 80)).mean()
                    blue = ((a[..., 2] > 200) & (a[..., 0] < 90) & (a[..., 1] > 90) & (a[..., 1] < 170)).mean()
                    keys.append((k, orange, blue))
    for col in (1, 2):
        best = max(keys, key=lambda kv: kv[col], default=None)
        if best is not None and best[col] > 0.2:
            best[0]["kind"] = "press"
            return


def main(src, dst, debug=False):
    os.makedirs(dst, exist_ok=True)
    theme = os.path.basename(os.path.normpath(src)).split("-")[0]
    win = np.asarray(Image.open(os.path.join(src, "window.png")).convert("RGBA")).copy()
    scale = round(win.shape[1] / 1280)
    # the window's ground is its chassis: sampled in the left margin, under the title bar
    chassis = ground(win, (slice(int(70 * scale), int(600 * scale)), slice(int(3 * scale), int(12 * scale))))
    # the window: cut below the last full row of tiles (the capture runs off the bottom)
    probe = win.copy()
    probe_entries_dir = os.path.join(dst, ".probe")
    os.makedirs(probe_entries_dir, exist_ok=True)
    rows = take_apart(probe, scale, "window", theme, probe_entries_dir, (0, 0), None, ground_rgb=chassis)
    cut = win.shape[0]
    for card in rows:
        kids = card.get("children", [])
        low = [k for k in kids if k["rect"][3] * scale >= card["rect"][3] * scale - 2 * scale]
        if card["rect"][3] * scale >= win.shape[0] - 2 * scale:
            # walk up from the cut-off row to the first clean line of the ground around it (above a
            # chosen tile's ring, below the full row's labels): a box's own ground, or the chassis
            # when the cut-off element stands on it (Classic's tiles)
            if kids and not low:
                # the box runs off the bottom but its last row is whole: cut a margin below it
                cut = min(cut, int(max(k["rect"][3] for k in kids) * scale) + int(2 * scale))
                continue
            if low:
                x0, x1 = int(card["rect"][0] * scale) + 4 * scale, int(card["rect"][2] * scale) - 4 * scale
                y = int(min(k["rect"][1] for k in low) * scale) - 1
                cg = ground(win, (slice(y - 40 * scale, y), slice(x0, x1)))
            else:
                x0, x1 = 8 * scale, win.shape[1] - 8 * scale
                y = int(card["rect"][1] * scale) - 1
                cg = chassis
            while y > 0 and (np.abs(win[y, x0:x1, :3].astype(np.float32) - cg).max(axis=-1) > 12).mean() > 0.005:
                y -= 1
            cut = min(cut, y - scale)
    for f in os.listdir(probe_entries_dir):
        os.remove(os.path.join(probe_entries_dir, f))
    os.rmdir(probe_entries_dir)
    if cut < win.shape[0]:
        g = chassis
        pad = int(16 * scale)
        body = win[:cut]
        foot = np.zeros((pad, win.shape[1], 4), np.uint8)
        foot[..., :3] = g.astype(np.uint8)
        foot[..., 3] = 255
        # the cut boxes end in a margin of their own ground: repeat the row just above the cut
        win = np.concatenate([body, np.repeat(body[-2:-1], int(10 * scale), axis=0), foot], axis=0)
        # …but only inside the boxes: elsewhere that strip is the chassis
        strip = win[cut:cut + int(10 * scale)]
        is_chassis = np.abs(strip[..., :3].astype(np.float32) - g).max(axis=-1) < 7
        strip[is_chassis, :3] = g.astype(np.uint8)
    r = WINDOW_RADIUS_PT * scale
    shape = rrect_mask(win.shape[1], win.shape[0], r)
    win[..., 3] = (shape * 255).astype(np.uint8)

    ins = np.asarray(Image.open(os.path.join(src, "inspector.png")).convert("RGBA")).copy()
    a = ins[..., 3] > 8
    ys, xs = np.where(a)
    ins = ins[ys.min():ys.max() + 1, xs.min():xs.max() + 1].copy()
    ins_r = corner_radius(ins[..., 3] > 128)

    W = win.shape[1] + DOCK_GAP_PT * scale + ins.shape[1]
    Hh = max(win.shape[0], ins.shape[0])
    dbg_im = Image.new("RGBA", (W, Hh), (255, 255, 255, 255)) if debug else None
    dbg = ImageDraw.Draw(dbg_im) if debug else None
    ins_at = (win.shape[1] + DOCK_GAP_PT * scale, 0)
    modules = []
    for name, px, at, rad in (("window", win, (0, 0), WINDOW_RADIUS_PT), ("inspector", ins, ins_at, ins_r / scale)):
        if debug:
            dbg_im.alpha_composite(Image.fromarray(px), at)
        kids = take_apart(px, scale, name, theme, dst, at, None, prefix=("w" if name == "window" else "i"),
                          ground_rgb=chassis if name == "window" else None)
        Image.fromarray(px).save(os.path.join(dst, f"m-{name}.png"))
        modules.append({"name": name, "png": f"m-{name}.png", "radius": round(rad, 2), "children": kids,
                        "rect": [at[0] / scale, at[1] / scale, (at[0] + px.shape[1]) / scale, (at[1] + px.shape[0]) / scale]})
    mark_press(modules, dst)
    if debug:
        for m in modules:
            for c in m["children"]:
                dbg.rectangle([v * scale for v in c["rect"]], outline=(255, 0, 255), width=3)
                for k in c.get("children", []):
                    col = {"dial": (0, 160, 0), "press": (255, 120, 0)}.get(k["kind"], (0, 160, 255))
                    dbg.rectangle([v * scale for v in k["rect"]], outline=col, width=3)
        dbg_im.convert("RGB").save(os.path.join(dst, "debug.png"))
    with open(os.path.join(dst, "parts.json"), "w") as f:
        json.dump({"scale": scale, "size": [W / scale, Hh / scale], "modules": modules}, f, indent=1)
    n1 = sum(len(m["children"]) for m in modules)
    n2 = sum(len(c.get("children", [])) for m in modules for c in m["children"])
    print(json.dumps({"modules": len(modules), "level1": n1, "level2": n2,
                      "dials": sum(1 for m in modules for c in m["children"] for k in [c] + c.get("children", [])
                                   if k["kind"] == "dial"), "cut_pt": cut / scale}))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--debug"]
    main(args[0], args[1], debug="--debug" in sys.argv)
