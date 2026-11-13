"""The city outside: the line runs on a viaduct through a dense Japanese neighbourhood — a street
with utility poles along the viaduct, blocks of two- and three-storey houses with tiled roofs and
small mixed-use buildings with signs, then packed mid-rise apartments (balconies) and offices,
then a skyline. One PERIOD-metre tile of scenery (x in [0, PERIOD)) is built once (merged per
material with geometry.Batch) and instanced along the track on both sides (the near side mirrored,
offset and squashed — it is only seen in reflections and shadows), then the strip scrolls one period
per loop, so the loop is seamless by construction.

Carriage coordinates: floor z = 0, railhead z = -FLOOR_TO_RAIL, street level z = GROUND; far side
is y < 0.
"""
import math
import random

from dsfilm import assets, geometry as geo, materials as mt
from dsfilm.geometry import Batch, box, tube

from carriage import FLOOR_TO_RAIL

GROUND = -FLOOR_TO_RAIL - 7.5
RAIL = -FLOOR_TO_RAIL

# ambientCG facades (id, metres per texture repeat) and their lit-at-night counterparts
OFFICE = [("Facade018A", 20), ("Facade019A", 20), ("Facade020A", 20), ("Facade012", 34), ("Facade006", 30)]
TOWER = [("Facade001", 24), ("Facade005", 22), ("Facade006", 30), ("Facade012", 34), ("Facade014", 40), ("Facade019A", 22)]
NIGHT = {"Facade018A": "Facade018C", "Facade019A": "Facade019C", "Facade020A": "Facade020C", "Facade012": "Facade015",
         "Facade006": "Facade009", "Facade001": "Facade009", "Facade005": "Facade016", "Facade014": "Facade016"}

# real-world albedos: even "white" tile and render sit around 0.6
HOUSE_WALLS = [(0.66, 0.64, 0.59), (0.60, 0.56, 0.50), (0.68, 0.67, 0.64), (0.52, 0.49, 0.44), (0.50, 0.53, 0.55),
               (0.63, 0.60, 0.52)]
APARTMENT_WALLS = [(0.68, 0.66, 0.62), (0.62, 0.57, 0.50), (0.55, 0.54, 0.52), (0.64, 0.61, 0.55), (0.47, 0.42, 0.38)]
ROOF_TINTS = [(0.30, 0.33, 0.38), (0.16, 0.17, 0.20), (0.40, 0.26, 0.18), (0.22, 0.32, 0.48), (0.42, 0.40, 0.38),
              (0.55, 0.30, 0.20), (0.26, 0.22, 0.20)]
CAR_COLORS = [(0.80, 0.80, 0.78)] * 4 + [(0.55, 0.56, 0.58)] * 3 + [(0.03, 0.03, 0.035)] * 2 + [(0.45, 0.05, 0.05), (0.08, 0.15, 0.35), (0.55, 0.50, 0.40)]
SIGN_COLORS = [(0.85, 0.12, 0.10), (0.95, 0.75, 0.10), (0.10, 0.35, 0.75), (0.95, 0.95, 0.92), (0.10, 0.55, 0.30),
               (0.90, 0.45, 0.10)]


def build_tile(tile, lib, P, period, seed=11):
    night = P.get("night", False)
    r = random.Random(seed)
    lit = 0.35 if night else 0.0

    # ------------------------------------------------------------------ materials
    def acg(name, size):
        n = NIGHT.get(name, name) if night else name
        return mt.acg_pbr(f"F_{n}_{r.random():.4f}", n, size_m=size * r.uniform(0.9, 1.1), nor_strength=0.4,
                          tint=r.choice([(1, 1, 1), (1.05, 1.0, 0.92), (0.88, 0.92, 0.98), (0.8, 0.8, 0.8)]),
                          emission_strength=(0.35 if night else 0.0))
    office = [acg(n, s) for n, s in OFFICE]
    towers = [acg(n, s) for n, s in TOWER]
    houses = [mt.facade_grid(f"HouseWall{i}", wall=c, pitch=r.uniform(2.3, 2.9), floor_h=2.9, win_w=0.42, win_h=0.44,
                             sill=0.30, lit=lit, lit_prob=0.5, x_offset=r.uniform(0, 3)) for i, c in enumerate(HOUSE_WALLS)]
    flats = [mt.facade_grid(f"Apartment{i}", wall=c, pitch=r.choice((3.4, 3.8, 4.2)), floor_h=2.95, win_w=0.62,
                            win_h=0.62, sill=0.22, lit=lit, lit_prob=0.55, x_offset=r.uniform(0, 3))
             for i, c in enumerate(APARTMENT_WALLS)]
    shops = [mt.facade_grid(f"MixedUse{i}", wall=c, pitch=3.0, floor_h=3.2, win_w=0.75, win_h=0.55, sill=0.25,
                            curtain_prob=0.15, lit=lit * 1.3, lit_prob=0.7) for i, c in enumerate(HOUSE_WALLS[:4])]
    roofs = [mt.acg_pbr(f"RoofTiles{i}", "RoofingTiles006", size_m=3.0, desat=True, tint=t) for i, t in enumerate(ROOF_TINTS)]
    roof_flat = mt.noise_bump(mt.principled("RoofFlat", (0.42, 0.42, 0.40), 0.85), scale=10, strength=0.1, rough_var=0.1)
    balcony = mt.noise_bump(mt.principled("BalconySlab", (0.62, 0.61, 0.58), 0.7), scale=20, strength=0.05)
    balcony_panel = mt.principled("BalconyPanel", (0.70, 0.72, 0.74), 0.25, **{"Transmission Weight": 0.3})
    steel = mt.principled("Steel", (0.45, 0.46, 0.47), 0.45, 0.8)
    tank = mt.principled("Tank", (0.72, 0.74, 0.70), 0.5, 0.2)
    wire = mt.principled("Wire", (0.04, 0.04, 0.04), 0.4, 0.5)
    signs = [mt.principled(f"Sign{i}", c, 0.35, **({"Emission Color": c, "Emission Strength": 0.8} if night else {}))
             for i, c in enumerate(SIGN_COLORS)]
    concrete = mt.ph_pbr("ViaductConcrete", "concrete_wall_008", size_m=3.0, desat=True, tint=(0.62, 0.62, 0.60))
    gravel = mt.acg_pbr("Ballast", "Gravel022", size_m=1.5)
    road = mt.ph_pbr("Road", "asphalt_02", size_m=5.0)
    lot = mt.ph_pbr("Lot", "asphalt_02", size_m=7.0, desat=True, tint=(0.50, 0.49, 0.47))
    grass = mt.acg_pbr("Grass", "Grass004", size_m=3.0)
    pole_mat = mt.noise_bump(mt.principled("PoleConcrete", (0.55, 0.55, 0.52), 0.7), scale=30, strength=0.1)
    lamp = mt.emission("StreetLamp", (1.0, 0.85, 0.6), 4.0 if night else 0.0)
    car_paint = [mt.principled(f"CarPaint{i}", c, 0.25, 0.5, **{"Coat Weight": 1.0, "Coat Roughness": 0.05})
                 for i, c in enumerate(CAR_COLORS)]
    car_glass = mt.principled("CarGlass", (0.02, 0.025, 0.03), 0.05, **{"Coat Weight": 1.0})
    tyre = mt.principled("Tyre", (0.02, 0.02, 0.02), 0.8)
    shop_front = mt.principled("ShopFront", (0.05, 0.05, 0.06), 0.15, **{"Specular IOR Level": 0.8,
                               **({"Emission Color": (1.0, 0.85, 0.65), "Emission Strength": 0.25} if night else {})})

    B = Batch("City", tile)
    L = period + 0.5

    # ------------------------------------------------------------------ viaduct, street, ground
    B.box((L, 5.2, 0.8), (period / 2, -2.6, RAIL - 0.75), concrete)
    B.box((L, 4.4, 0.3), (period / 2, -2.2, RAIL - 0.25), gravel)
    B.box((L, 0.2, 1.1), (period / 2, -5.1, RAIL - 0.2), concrete)
    for k in range(int(period / 20)):
        B.box((1.4, 4.0, -GROUND + RAIL - 0.8), (k * 20 + 6, -2.4, (GROUND + RAIL - 1.1) / 2), concrete)
    B.box((L, 900, 0.2), (period / 2, -450 - 4.0, GROUND - 0.12), lot)
    B.box((L, 7.0, 0.06), (period / 2, -10.5, GROUND + 0.03), road)
    # catenary
    for k in range(int(period / 50)):
        x = k * 50 + 12
        tube(f"Mast{k}", [(x, -4.6, RAIL - 0.2), (x, -4.6, RAIL + 6.4)], 0.13, steel, tile)
        tube(f"MastBeam{k}", [(x, -4.6, RAIL + 6.1), (x, 0.0, RAIL + 6.1)], 0.07, steel, tile)
        tube(f"MastStay{k}", [(x, -4.6, RAIL + 5.6), (x, -2.6, RAIL + 6.1)], 0.03, steel, tile)
        for yw in (0.0, -3.9):
            tube(f"Drop{k}{yw}", [(x, yw, RAIL + 6.1), (x, yw, RAIL + 5.0)], 0.02, steel, tile)
    for zw, yw in ((5.0, 0.0), (5.9, 0.0), (5.0, -3.9), (5.9, -3.9)):
        tube(f"Catenary{zw}{yw}", [(-1, yw, RAIL + zw), (period + 1, yw, RAIL + zw)], 0.007, wire, tile, caps=False)
    # utility poles and their sagging bundles of wires
    n_poles = 20
    dx = period / n_poles
    for k in range(n_poles):
        x = k * dx + 5
        tube(f"UPole{k}", [(x, -14.0, GROUND), (x, -14.0, GROUND + 11.0)], 0.17, pole_mat, tile)
        for zc in (9.0, 10.1):
            tube(f"UArm{k}_{zc}", [(x, -15.1, GROUND + zc), (x, -12.9, GROUND + zc)], 0.05, steel, tile)
        if k % 3 == 0:
            B.cylinder(0.26, 1.1, (x + 0.38, -14.0, GROUND + 7.9), steel)
        tube(f"ULampArm{k}", [(x, -14.0, GROUND + 6.0), (x, -12.6, GROUND + 6.3)], 0.03, steel, tile)
        geo.no_shadow(box(f"ULamp{k}", (0.45, 0.2, 0.08), (x, -12.5, GROUND + 6.25), lamp, tile))
    for wy, wz, sag in ((-15.0, 9.0, 0.6), (-13.0, 9.0, 0.6), (-14.4, 10.1, 0.5), (-13.6, 10.1, 0.5), (-14.0, 7.2, 0.7),
                        (-14.2, 8.2, 0.65)):
        pts = []
        for k in range(n_poles + 1):
            for j in range(6):
                u = j / 6
                pts.append((k * dx + 5 + u * dx, wy, GROUND + wz - sag * 4 * u * (1 - u)))
        tube(f"UWire{wy}{wz}", pts, 0.011, wire, tile, caps=False)

    # ------------------------------------------------------------------ houses and small buildings
    def gable(w, d, rh, ov=0.45):
        v = [(-w / 2 - ov, -d / 2 - ov, 0), (w / 2 + ov, -d / 2 - ov, 0), (w / 2 + ov, d / 2 + ov, 0), (-w / 2 - ov, d / 2 + ov, 0),
             (-w / 2 - ov, 0, rh), (w / 2 + ov, 0, rh)]
        return v, [(0, 1, 5, 4), (2, 3, 4, 5), (0, 4, 3), (1, 2, 5), (0, 3, 2, 1)]

    def rooftop(x, y, w, d, top):
        for k in range(r.randint(1, 4)):
            cw, cd, ch = r.uniform(1.0, max(w * 0.3, 1.2)), r.uniform(1.0, max(d * 0.3, 1.2)), r.uniform(0.8, 3.0)
            B.box((cw, cd, ch), (x + r.uniform(-w / 2 + cw, w / 2 - cw), y + r.uniform(-d / 2 + cd, d / 2 - cd), top + ch / 2), roof_flat)
        if r.random() < 0.5:
            B.cylinder(r.uniform(0.9, 1.6), r.uniform(1.6, 2.6), (x + r.uniform(-w / 4, w / 4), y, top + 1.6), tank)
        if r.random() < 0.3:
            tube(f"Antenna{x:.0f}{y:.0f}", [(x, y, top), (x, y, top + r.uniform(3, 8))], 0.05, steel, tile)

    def sign(x, y_face, z, w=0.9, h=3.5):
        B.box((w, 0.25, h), (x, y_face + 0.4, z), r.choice(signs))
        B.box((0.08, 0.5, 0.08), (x, y_face + 0.2, z + h / 2 - 0.2), steel)

    rows = [(-19.0, 9.0), (-31.0, 9.0), (-43.0, 9.0), (-55.0, 9.0), (-67.0, 9.0)]
    greenery = []
    for ri, (yc, depth) in enumerate(rows):
        x = r.uniform(0, 4)
        next_street = r.uniform(50, 90)
        while x < period - 8:
            if x > next_street:                     # a cross street
                x += r.uniform(5, 7)
                next_street = x + r.uniform(50, 90)
                continue
            w = r.uniform(6.0, 9.5)
            d = r.uniform(7.0, depth)
            y = yc - r.uniform(0, 1.5)
            if ri == 0 and r.random() < 0.45 or r.random() < 0.10:   # a small mixed-use building
                floors = r.randint(3, 7)
                h = floors * 3.2
                B.box((w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(shops))
                B.box((w + 0.1, d + 0.1, 0.5), (x + w / 2, y, GROUND + h + 0.25), roof_flat)
                rooftop(x + w / 2, y, w, d, GROUND + h + 0.5)
                if r.random() < 0.7:
                    sign(x + r.uniform(0.8, w - 0.8), y + d / 2, GROUND + h * r.uniform(0.45, 0.7), h=min(h * 0.45, 6))
                # ground-floor shop front: a dark band with an awning
                B.box((w - 0.4, 0.1, 2.6), (x + w / 2, y + d / 2 + 0.03, GROUND + 1.4), shop_front)
                B.box((w - 0.2, 1.0, 0.12), (x + w / 2, y + d / 2 + 0.5, GROUND + 3.0), r.choice(signs))
            else:
                q = r.random()
                h = r.choice((5.8, 6.1, 6.4)) if q < 0.58 else r.choice((8.8, 9.3)) if q < 0.9 else 3.3
                B.box((w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(houses))
                if r.random() < 0.82:
                    v, f = gable(w, d, r.uniform(1.6, 2.4))
                    B.poly(v, f, r.choice(roofs), loc=(x + w / 2, y, GROUND + h))
                else:
                    B.box((w + 0.1, d + 0.1, 0.4), (x + w / 2, y, GROUND + h + 0.2), roof_flat)
                    rooftop(x + w / 2, y, w, d, GROUND + h + 0.4)
                if r.random() < 0.4:                # a little balcony or carport roof
                    B.box((w * 0.6, 0.9, 0.12), (x + w / 2, y + d / 2 + 0.45, GROUND + 2.9), balcony)
            gap = r.uniform(0.8, 2.6)
            if gap > 1.6 and r.random() < 0.45:      # a garden tree or hedge in the gap
                greenery.append((x + w + gap / 2, y + r.uniform(-d / 3, d / 3)))
            x += w + gap

    # parked cars: along both kerbs of the viaduct street and in small lots between the rows
    def car(x, y, rot_z=0.0):
        paint = r.choice(car_paint)
        L, W = r.uniform(3.6, 4.7), r.uniform(1.55, 1.8)
        B.box((L, W, 0.62), (x, y, GROUND + 0.52), paint, rot_z)
        B.box((L * r.uniform(0.5, 0.6), W * 0.9, 0.5), (x - L * 0.05, y, GROUND + 1.07), car_glass, rot_z)
        B.box((L * r.uniform(0.42, 0.52), W * 0.92, 0.06), (x - L * 0.05, y, GROUND + 1.34), paint, rot_z)
        for dxw in (-L * 0.32, L * 0.32):
            B.box((0.62, W + 0.02, 0.62), (x + dxw * math.cos(rot_z), y + dxw * math.sin(rot_z), GROUND + 0.31), tyre, rot_z)
    x = r.uniform(2, 10)
    while x < period - 6:
        if r.random() < 0.55:
            car(x, r.choice((-8.3, -12.7)))
        x += r.uniform(5.0, 14.0)
    for k in range(int(period / 60)):
        lx, ly = r.uniform(10, period - 20), r.choice((-25.0, -37.0, -49.0))
        for j in range(r.randint(2, 5)):
            car(lx + j * 2.6, ly, math.pi / 2)

    # ------------------------------------------------------------------ mid-rise blocks
    for ri, (yc, hmin, hmax) in enumerate(((-84, 12, 26), (-108, 14, 34), (-134, 16, 42), (-162, 18, 48), (-195, 20, 55))):
        x = r.uniform(0, 8)
        while x < period - 10:
            w = min(r.uniform(10, 26), period - x - 1)
            d = r.uniform(10, 18)
            h = r.uniform(hmin, hmax)
            y = yc - r.uniform(0, 6)
            if r.random() < 0.55:                   # apartment block ("mansion") with balconies
                floors = int(h / 2.95)
                h = floors * 2.95
                B.box((w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(flats))
                if r.random() < 0.8:
                    for fl in range(1, floors):
                        z = GROUND + fl * 2.95
                        B.box((w - 0.6, 1.2, 0.16), (x + w / 2, y + d / 2 + 0.6, z), balcony)
                        B.box((w - 0.6, 0.07, 1.05), (x + w / 2, y + d / 2 + 1.17, z + 0.6), balcony_panel)
            else:
                B.box((w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(office))
            B.box((w + 0.2, d + 0.2, 0.8), (x + w / 2, y, GROUND + h + 0.4), roof_flat)
            rooftop(x + w / 2, y, w, d, GROUND + h + 0.8)
            if ri < 2 and r.random() < 0.3:
                sign(x + r.uniform(1, w - 1), y + d / 2, GROUND + h * 0.6, w=1.4, h=min(8, h * 0.4))
            x += w + r.uniform(1.0, 4.0)

    # ------------------------------------------------------------------ skyline
    for ri, (y0, y1, hmin, hmax) in enumerate(((-240, -320, 35, 90), (-340, -460, 50, 150), (-480, -650, 60, 180))):
        x = r.uniform(0, 15)
        while x < period - 20:
            w = min(r.uniform(22, 50), period - x - 1)
            d = r.uniform(20, 40)
            h = r.uniform(hmin, hmax)
            y = r.uniform(y1, y0)
            B.box((w, d, h), (x + w / 2, y, GROUND + h / 2), r.choice(towers))
            B.box((w * 0.92, d * 0.92, 2.5), (x + w / 2, y, GROUND + h + 1.25), roof_flat)
            if r.random() < 0.4:
                B.box((w * 0.5, d * 0.5, r.uniform(4, 10)), (x + w / 2, y, GROUND + h + 4), r.choice(towers))
            x += w + r.uniform(4, 16)

    # ------------------------------------------------------------------ greenery (Poly Haven), instanced
    tree = geo.append_collection(assets.model("jacaranda_tree"), "jacaranda_tree_LOD1")
    shrubs = [geo.append_collection(assets.model(n), f"{n}_LOD1") for n in ("shrub_02", "shrub_04")]
    for c in [tree] + shrubs:
        lib.children.link(c)
    x = 4
    while x < period - 4:      # street trees along the viaduct road
        s = r.uniform(2.6, 3.6)
        geo.instance(f"StreetTree{x:.0f}", r.choice(shrubs), tile, (x, -7.6, GROUND), (0, 0, r.uniform(0, math.tau)), (s, s, s))
        x += r.uniform(9, 16)
    x = 10
    while x < period - 10:     # a few big garden / park trees
        s = r.uniform(0.3, 0.45)
        geo.instance(f"Tree{x:.0f}", tree, tile, (x, r.choice((-25.5, -37.5, -49.5, -61.5)), GROUND), (0, 0, r.uniform(0, math.tau)),
                     (s, s, s))
        x += r.uniform(30, 70)
    for gx, gy in greenery:     # garden trees between houses
        s_ = r.uniform(1.6, 2.8)
        geo.instance(f"Garden{gx:.0f}{gy:.0f}", r.choice(shrubs), tile, (gx, gy, GROUND), (0, 0, r.uniform(0, math.tau)), (s_, s_, s_))
    # a pocket park now and then
    for k in range(3):
        px = r.uniform(40, period - 60)
        B.box((26, 20, 0.1), (px, -48, GROUND + 0.02), grass)
    B.finish()

