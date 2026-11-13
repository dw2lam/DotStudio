#!/usr/bin/env python3
"""Generates the carriage's posters, notices and route map: original artwork, fictional brands.

    python3 -I tools/film/scenes/commute/posters.py    # writes PNGs into <cache>/posters/

Blender's Python has no Pillow, so scene.prepare() runs this file with the system python3.

Needs Pillow (system python3) and the macOS Hiragino fonts. Deterministic (seeded).
"""
import math, os, random
try:  # Blender's Python has no Pillow; it only needs all_posters()
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    Image = None

CACHE = os.environ.get("DOTSTUDIO_FILM_CACHE", os.path.expanduser("~/Library/Caches/DotStudio-film"))
OUT = os.path.join(CACHE, "posters")
FONTS = "/System/Library/Fonts"
JP_BOLD = os.path.join(FONTS, "ヒラギノ角ゴシック W7.ttc")
JP_REG = os.path.join(FONTS, "ヒラギノ角ゴシック W4.ttc")
JP_ROUND = os.path.join(FONTS, "ヒラギノ丸ゴ ProN W4.ttc")
SANS = os.path.join(FONTS, "Avenir Next.ttc")


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.load_default(size)


def grad(w, h, top, bottom):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return im


def paper(im, seed):
    """Print grain + a faint sheen so it reads as a printed sheet, not a flat colour."""
    rnd = random.Random(seed)
    w, h = im.size
    noise = Image.effect_noise((w, h), 9).convert("RGB")
    im = Image.blend(im, noise, 0.035)
    return im


def tea(w=900, h=1200):
    im = grad(w, h, (214, 236, 228), (246, 250, 244))
    d = ImageDraw.Draw(im)
    # a glass bottle with a cloud label, drawn simply
    cx = int(w * 0.62)
    d.rounded_rectangle([cx - 120, 300, cx + 120, 1010], 70, fill=(176, 214, 196), outline=(120, 170, 150), width=6)
    d.rectangle([cx - 55, 210, cx + 55, 320], fill=(176, 214, 196))
    d.rounded_rectangle([cx - 62, 170, cx + 62, 222], 14, fill=(40, 110, 80))
    d.rectangle([cx - 120, 560, cx + 120, 800], fill=(250, 250, 244))
    for i, r in enumerate([46, 60, 42]):
        d.ellipse([cx - 80 + i * 50 - r // 2, 650 - r // 2, cx - 80 + i * 50 + r, 650 + r], fill=(122, 190, 160))
    d.text((cx, 750), "KUMO", font=font(SANS, 46, 1), fill=(40, 110, 80), anchor="mm")
    d.text((70, 140), "雲の\nお茶", font=font(JP_BOLD, 150), fill=(30, 84, 62), spacing=10)
    d.text((76, 520), "すっきり、\nやさしい。", font=font(JP_REG, 54), fill=(40, 90, 70), spacing=14)
    d.text((76, 1080), "KUMO GREEN TEA  500ml", font=font(SANS, 34, 0), fill=(60, 110, 90))
    return paper(im, 1)


def travel(w=1400, h=900):
    im = grad(w, h, (90, 160, 220), (250, 220, 180))
    d = ImageDraw.Draw(im)
    d.ellipse([980, 140, 1180, 340], fill=(255, 236, 190))
    pts = [(0, 620), (220, 380), (420, 560), (640, 300), (860, 540), (1080, 420), (1400, 620), (1400, 900), (0, 900)]
    d.polygon(pts, fill=(70, 100, 140))
    d.polygon([(560, 390), (640, 300), (720, 390), (680, 380), (640, 400), (600, 380)], fill=(240, 244, 250))
    d.rectangle([0, 700, w, h], fill=(40, 120, 170))
    for i in range(30):
        y = 720 + i * 6
        d.line([(0, y), (w, y)], fill=(70, 150, 200), width=1)
    d.text((80, 90), "海へ、ゆっくり。", font=font(JP_BOLD, 110), fill=(255, 255, 255))
    d.text((84, 240), "みなみ浜線  週末きっぷ  ¥2,400", font=font(JP_REG, 46), fill=(255, 255, 250))
    d.rounded_rectangle([80, 760, 520, 850], 16, fill=(255, 255, 255))
    d.text((300, 805), "Minami Coast Line", font=font(SANS, 40, 1), fill=(30, 90, 140), anchor="mm")
    return paper(im, 2)


def school(w=900, h=1200):
    im = Image.new("RGB", (w, h), (250, 196, 60))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 820, w, h], fill=(30, 40, 70))
    d.ellipse([500, 120, 1060, 680], fill=(255, 224, 120))
    d.text((60, 120), "話せる\n英語を、\n毎朝\n15分。", font=font(JP_BOLD, 120), fill=(30, 40, 70), spacing=16)
    d.text((60, 880), "POLARIS English", font=font(SANS, 70, 1), fill=(255, 255, 255))
    d.text((64, 990), "駅前教室  無料体験レッスン受付中", font=font(JP_REG, 40), fill=(250, 210, 90))
    d.text((64, 1060), "0120-000-000", font=font(SANS, 44, 0), fill=(255, 255, 255))
    return paper(im, 3)


def clinic(w=900, h=1200):
    im = Image.new("RGB", (w, h), (246, 248, 250))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w, 260], fill=(36, 120, 190))
    d.text((60, 70), "さくら台\n歯科クリニック", font=font(JP_BOLD, 76), fill=(255, 255, 255), spacing=8)
    d.text((60, 330), "駅から徒歩3分", font=font(JP_BOLD, 64), fill=(36, 120, 190))
    for i, line in enumerate(["平日  9:00 – 20:00", "土曜  9:00 – 17:00", "日祝  休診"]):
        d.text((60, 460 + i * 80), line, font=font(JP_REG, 52), fill=(50, 60, 70))
    d.rounded_rectangle([60, 760, 840, 1100], 30, fill=(228, 240, 250))
    d.ellipse([110, 820, 330, 1040], fill=(255, 255, 255), outline=(36, 120, 190), width=8)
    d.text((220, 930), "◎", font=font(JP_BOLD, 120), fill=(36, 120, 190), anchor="mm")
    d.text((380, 860), "やさしい治療を\nこころがけています", font=font(JP_REG, 44), fill=(50, 60, 70), spacing=14)
    return paper(im, 4)


def manners(w=1200, h=800):
    im = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w, 130], fill=(230, 120, 40))
    d.text((60, 65), "車内でのお願い", font=font(JP_BOLD, 72), fill=(255, 255, 255), anchor="lm")
    items = ["優先席付近では\n携帯電話の電源を\nお切りください", "リュックは\n前に抱えるか\n網棚へ", "ドアに\nもたれないで\nください"]
    for i, t in enumerate(items):
        x = 40 + i * 390
        d.rounded_rectangle([x, 170, x + 360, 760], 24, outline=(230, 120, 40), width=6)
        cx = x + 180
        d.ellipse([cx - 70, 210, cx + 70, 350], outline=(40, 40, 40), width=10)
        d.line([(cx - 50, 330), (cx + 50, 230)], fill=(220, 40, 40), width=12)
        d.text((cx, 560), t, font=font(JP_REG, 40), fill=(30, 30, 30), anchor="mm", align="center", spacing=12)
    return paper(im, 5)


def route_map(w=2400, h=360):
    im = Image.new("RGB", (w, h), (252, 252, 250))
    d = ImageDraw.Draw(im)
    names = ["北原", "青葉台", "川辺", "中央公園", "さくら台", "港町", "南浜", "海岸通"]
    d.rectangle([0, 0, w, 70], fill=(40, 150, 90))
    d.text((40, 35), "みどり線  各駅停車  Midori Line Local", font=font(JP_BOLD, 40), fill=(255, 255, 255), anchor="lm")
    y = 200
    d.line([(100, y), (w - 100, y)], fill=(40, 150, 90), width=22)
    for i, n in enumerate(names):
        x = 100 + i * (w - 200) / (len(names) - 1)
        d.ellipse([x - 22, y - 22, x + 22, y + 22], fill=(255, 255, 255), outline=(40, 150, 90), width=8)
        d.text((x, y - 70), n, font=font(JP_BOLD, 40), fill=(30, 30, 30), anchor="mm")
        d.text((x, y + 70), f"M{i + 1:02d}", font=font(SANS, 30, 1), fill=(40, 150, 90), anchor="mm")
    return paper(im, 6)


def priority(w=600, h=300):
    im = Image.new("RGB", (w, h), (250, 236, 60))
    d = ImageDraw.Draw(im)
    d.text((300, 90), "優先席", font=font(JP_BOLD, 90), fill=(30, 30, 30), anchor="mm")
    d.text((300, 200), "Priority Seat", font=font(SANS, 52, 1), fill=(30, 30, 30), anchor="mm")
    return im


def hanging(w=1400, h=500):
    """A drop poster (nakazuri) for the aisle: a fictional weekly magazine."""
    im = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 360, h], fill=(200, 30, 50))
    d.text((180, 150), "週刊\nまちかど", font=font(JP_BOLD, 80), fill=(255, 255, 255), anchor="mm", align="center")
    d.text((180, 380), "11月号", font=font(JP_BOLD, 60), fill=(255, 240, 200), anchor="mm")
    lines = ["秋の駅そば ベスト30", "週末は電車で温泉へ", "通勤時間で読める「小さな本」特集"]
    for i, t in enumerate(lines):
        d.text((400, 60 + i * 140), t, font=font(JP_BOLD, 68 if i == 0 else 54), fill=(20, 20, 20) if i else (200, 30, 50))
    return paper(im, 7)


def door_sticker(w=500, h=500):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse([10, 10, w - 10, h - 10], fill=(255, 210, 40, 255))
    d.text((w // 2, 190), "✋", font=font(JP_BOLD, 150), fill=(30, 30, 30, 255), anchor="mm")
    d.text((w // 2, 340), "手をはさまないよう\nご注意ください", font=font(JP_BOLD, 34), fill=(30, 30, 30, 255), anchor="mm", align="center")
    return im


def screen(w=1200, h=390):
    """The door-top info screen: next station, in the style of an LCD."""
    im = Image.new("RGB", (w, h), (8, 10, 14))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w, 90], fill=(40, 150, 90))
    d.text((30, 45), "各駅停車  海岸通 ゆき", font=font(JP_BOLD, 50), fill=(255, 255, 255), anchor="lm")
    d.text((40, 170), "つぎは", font=font(JP_BOLD, 52), fill=(255, 200, 60), anchor="lm")
    d.text((620, 220), "さくら台", font=font(JP_BOLD, 150), fill=(255, 255, 255), anchor="mm")
    d.text((620, 340), "Sakuradai", font=font(SANS, 56, 1), fill=(200, 220, 230), anchor="mm")
    return im


def all_posters():
    return {n: os.path.join(OUT, n + ".png") for n in ("tea", "travel", "school", "clinic", "manners", "route_map",
                                                       "priority", "hanging", "door_sticker", "screen")}


def generate(force=False):
    """Writes every poster PNG into the cache if missing (or force). Returns name -> path."""
    paths = all_posters()
    if force or not all(os.path.exists(p) for p in paths.values()):
        main()
    return paths


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [("tea", tea), ("travel", travel), ("school", school), ("clinic", clinic),
                     ("manners", manners), ("route_map", route_map), ("priority", priority),
                     ("hanging", hanging), ("door_sticker", door_sticker), ("screen", screen)]:
        fn().save(os.path.join(OUT, name + ".png"))
    print("ok:", OUT)


if __name__ == "__main__":
    main()
