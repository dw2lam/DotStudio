"""The city outside: the line runs on a viaduct over a low-rise neighbourhood, with mid-rise blocks
and a skyline beyond. One PERIOD-metre tile of scenery (x in [0, PERIOD)) is built once and
instanced along the track on both sides (the near side mirrored and offset), then the whole strip
scrolls one period per loop — so the loop is seamless by construction.

Everything is in carriage coordinates: floor z = 0, railhead z = -FLOOR_TO_RAIL, street level
z = GROUND. The far side is y < 0.
"""
import math
import random

from dsfilm import assets, geometry as geo, materials as mt
from dsfilm.geometry import box, tube

import bmesh

from carriage import FLOOR_TO_RAIL

GROUND = -FLOOR_TO_RAIL - 7.5
RAIL = -FLOOR_TO_RAIL

FACADES_DAY = [("Facade001", 24), ("Facade005", 22), ("Facade006", 30), ("Facade013", 60), ("Facade018A", 20)]
FACADES_NIGHT = [("Facade009", 30), ("Facade017", 30)]


def build_tile(tile, lib, P, period, seed=11):
    night = P.get("night", False)
    r = random.Random(seed)
    # each facade in a few tints so neighbouring blocks don't read as copies; emission (lit offices)
    # only at night, in physical-ish units (the night exposure lifts it ~11x)
    mats = {}
    tints = [(1.0, 1.0, 1.0), (1.08, 1.02, 0.92), (0.86, 0.90, 0.96), (0.72, 0.72, 0.72)]
    for name, size in FACADES_DAY + FACADES_NIGHT:
        mats[name] = [mt.acg_pbr(f"F_{name}_{i}", name, size_m=size * r.uniform(0.9, 1.15), nor_strength=0.4, tint=tn,
                                 emission_strength=(0.25 if night else 0.0)) for i, tn in enumerate(tints)]
    roof = mt.acg_pbr("RoofTiles", "RoofingTiles006", size_m=3.0, desat=True, tint=(0.32, 0.36, 0.42))
    house_mats = []
    for i, col in enumerate([(0.86, 0.84, 0.78), (0.78, 0.74, 0.66), (0.92, 0.90, 0.86), (0.66, 0.62, 0.56),
                             (0.84, 0.82, 0.82)]):
        house_mats.append(mt.ph_pbr(f"HouseWall{i}", "concrete_wall_008", size_m=4.0, desat=True,
                                    tint=tuple(c * 0.8 for c in col)))
    win_dark = mt.principled("HouseWindow", (0.04, 0.05, 0.06), 0.06, **{"Specular IOR Level": 0.8})
    win_lit = mt.emission("HouseWindowLit", (1.0, 0.76, 0.48), 0.5)
    grass = mt.acg_pbr("Grass", "Grass004", size_m=3.0)
    gravel = mt.acg_pbr("Ballast", "Gravel022", size_m=1.5)
    road = mt.ph_pbr("Road", "asphalt_02", size_m=5.0)
    concrete = mt.ph_pbr("ViaductConcrete", "concrete_wall_008", size_m=3.0, desat=True, tint=(0.62, 0.62, 0.60))
    pole_mat = mt.noise_bump(mt.principled("PoleConcrete", (0.55, 0.55, 0.52), 0.7), scale=30, strength=0.1)
    steel = mt.principled("MastSteel", (0.45, 0.46, 0.47), 0.45, 0.8)
    wire = mt.principled("Wire", (0.04, 0.04, 0.04), 0.4, 0.5)
    roof_flat = mt.noise_bump(mt.principled("RoofFlat", (0.40, 0.40, 0.38), 0.85), scale=10, strength=0.1)
    lamp = mt.emission("StreetLamp", (1.0, 0.85, 0.6), 4.0 if night else 0.0)

    L = period + 0.5
    # viaduct deck, parapet and ballast (the near half comes from the mirrored tile)
    box("Deck", (L, 5.2, 0.8), (period / 2, -2.6, RAIL - 0.75), concrete, tile)
    box("Ballast", (L, 4.4, 0.3), (period / 2, -2.2, RAIL - 0.25), gravel, tile)
    box("Parapet", (L, 0.2, 1.1), (period / 2, -5.1, RAIL - 0.2), concrete, tile)
    for k in range(int(period / 20)):
        box(f"Pier{k}", (1.4, 4.0, -GROUND + RAIL - 0.8), (k * 20 + 6, -2.4, (GROUND + RAIL - 1.1) / 2), concrete, tile)
    box("Ground", (L, 900, 0.2), (period / 2, -450 - 4.0, GROUND - 0.1), grass, tile)
    box("Street", (L, 7.0, 0.06), (period / 2, -10.5, GROUND + 0.03), road, tile)
    # catenary masts (every 50 m) and the overhead wires of both tracks
    for k in range(int(period / 50)):
        x = k * 50 + 12
        tube(f"Mast{k}", [(x, -4.6, RAIL - 0.2), (x, -4.6, RAIL + 6.4)], 0.13, steel, tile)
        tube(f"MastBeam{k}", [(x, -4.6, RAIL + 6.1), (x, 0.0, RAIL + 6.1)], 0.07, steel, tile)
        tube(f"MastStay{k}", [(x, -4.6, RAIL + 5.6), (x, -2.6, RAIL + 6.1)], 0.03, steel, tile)
        for yw in (-0.0, -3.9):
            tube(f"Drop{k}{yw}", [(x, yw, RAIL + 6.1), (x, yw, RAIL + 5.0)], 0.02, steel, tile)
    for zw, yw in ((5.0, 0.0), (5.9, 0.0), (5.0, -3.9), (5.9, -3.9)):
        tube(f"Catenary{zw}{yw}", [(-1, yw, RAIL + zw), (period + 1, yw, RAIL + zw)], 0.007, wire, tile, caps=False)
    # utility poles along the street with sagging wires
    n_poles = 20
    dx = period / n_poles
    for k in range(n_poles):
        x = k * dx + 5
        tube(f"UPole{k}", [(x, -14.0, GROUND), (x, -14.0, GROUND + 11.0)], 0.17, pole_mat, tile)
        for zc in (9.0, 10.1):
            tube(f"UArm{k}_{zc}", [(x, -15.1, GROUND + zc), (x, -12.9, GROUND + zc)], 0.05, steel, tile)
        if k % 3 == 0:
            tube(f"UTrans{k}", [(x + 0.38, -14.0, GROUND + 7.4), (x + 0.38, -14.0, GROUND + 8.5)], 0.26, steel, tile)
        tube(f"ULampArm{k}", [(x, -14.0, GROUND + 6.0), (x, -12.6, GROUND + 6.3)], 0.03, steel, tile)
        geo.no_shadow(box(f"ULamp{k}", (0.45, 0.2, 0.08), (x, -12.5, GROUND + 6.25), lamp, tile))
    for wy, wz in ((-15.0, 9.0), (-13.0, 9.0), (-14.4, 10.1), (-13.6, 10.1), (-14.0, 7.2)):
        pts = []
        for k in range(n_poles + 1):
            for j in range(6):
                u = j / 6
                pts.append((k * dx + 5 + u * dx, wy, GROUND + wz - 0.6 * 4 * u * (1 - u)))
        tube(f"UWire{wy}{wz}", pts, 0.011, wire, tile, caps=False)
    # houses: two rows of two-storey houses with tiled gable roofs
    for row, (ymin, ymax) in enumerate(((-22, -18), (-36, -30), (-48, -42))):
        x = r.uniform(0, 5)
        while x < period - 12:
            w, d = r.uniform(7, 11), r.uniform(7, 9)
            h = r.choice((5.6, 6.0, 6.4)) if r.random() < 0.85 else 3.2
            y = r.uniform(ymin, ymax) - d / 2
            box(f"House{row}_{x:.0f}", (w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(house_mats), tile)
            bm = bmesh.new()
            rh, ov = r.uniform(1.6, 2.4), 0.45
            vs = [bm.verts.new(v) for v in ((-w / 2 - ov, -d / 2 - ov, 0), (w / 2 + ov, -d / 2 - ov, 0), (w / 2 + ov, d / 2 + ov, 0),
                                              (-w / 2 - ov, d / 2 + ov, 0), (-w / 2 - ov, 0, rh), (w / 2 + ov, 0, rh))]
            for f in ((0, 1, 5, 4), (2, 3, 4, 5), (0, 4, 3), (1, 2, 5), (0, 3, 2, 1)):
                bm.faces.new([vs[i] for i in f])
            geo.from_bm(f"Roof{row}_{x:.0f}", bm, roof, tile).location = (x + w / 2, y, GROUND + h)
            for fl in range(int(h // 2.8)):
                for wx in range(int(w // 2.6)):
                    lit = night and r.random() < 0.5
                    box(f"HWin{row}_{x:.0f}_{fl}_{wx}", (1.3, 0.08, 1.1), (x + 1.5 + wx * 2.6, y + d / 2 + 0.02, GROUND + 1.5 + fl * 2.8),
                        win_lit if lit else win_dark, tile)
            x += w + r.uniform(1.5, 4.0)
    # mid-rises and the skyline: facade-textured blocks, taller with distance
    for band, (ymin, ymax, hmin, hmax, wmin, wmax, gap) in enumerate((
            (-95, -65, 10, 22, 14, 30, 14), (-190, -120, 16, 42, 18, 40, 16), (-520, -280, 40, 120, 22, 55, 22))):
        x = r.uniform(0, 10)
        while x < period - wmin:
            w = min(r.uniform(wmin, wmax), period - x - 1)
            d, h, y = r.uniform(14, 30), r.uniform(hmin, hmax), r.uniform(ymin, ymax)
            if night:
                names = ["Facade009", "Facade017", "Facade018A"]
            else:
                names = ["Facade001", "Facade005", "Facade006", "Facade018A"]
            box(f"Block{band}_{x:.0f}", (w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(mats[r.choice(names)]), tile)
            box(f"BlockRoof{band}_{x:.0f}", (w - 1, d - 1, 1.2), (x + w / 2, y, GROUND + h + 0.6), roof_flat, tile)
            # rooftop clutter: plant rooms, water tanks, AC units, a sign frame now and then
            for k in range(r.randint(1, 4)):
                cw, cd, ch = r.uniform(1.5, w * 0.35), r.uniform(1.5, d * 0.35), r.uniform(1.0, 3.5)
                box(f"Clutter{band}_{x:.0f}_{k}", (cw, cd, ch),
                    (x + r.uniform(cw / 2 + 0.5, w - cw / 2 - 0.5), y + r.uniform(-d / 2 + cd / 2 + 0.5, d / 2 - cd / 2 - 0.5),
                     GROUND + h + 1.2 + ch / 2), roof_flat, tile)
            if band == 0 and r.random() < 0.35:
                tube(f"Rail{band}_{x:.0f}", [(x + 0.3, y + d / 2 - 0.3, GROUND + h + 2.2), (x + w - 0.3, y + d / 2 - 0.3, GROUND + h + 2.2)],
                     0.04, steel, tile)
            x += w + r.uniform(gap * 0.3, gap)
    # trees and shrubs (Poly Haven), instanced
    tree = geo.append_collection(assets.model("jacaranda_tree"), "jacaranda_tree_LOD1")
    shrubs = [geo.append_collection(assets.model(n), f"{n}_LOD1") for n in ("shrub_02", "shrub_04")]
    for c in [tree] + shrubs:
        lib.children.link(c)
    x = 3
    while x < period - 6:
        s = r.uniform(0.32, 0.5)
        geo.instance(f"Tree{x:.0f}", tree, tile, (x, r.choice((r.uniform(-9, -7.5), r.uniform(-28, -25))), GROUND),
                     (0, 0, r.uniform(0, math.tau)), (s, s, s))
        x += r.uniform(14, 36)
    x = 1
    while x < period - 3:
        s = r.uniform(1.4, 2.6)
        geo.instance(f"Shrub{x:.0f}", r.choice(shrubs), tile, (x, r.uniform(-8.5, -6.5), GROUND), (0, 0, r.uniform(0, math.tau)),
                     (s, s, s))
        x += r.uniform(3, 8)
