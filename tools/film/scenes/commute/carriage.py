"""The carriage: a Japanese commuter car (longitudinal benches, rounded windows with a transom,
ad strip, luggage racks, strap rails, door pocket), modelled at real scale.

Coordinates: x along the car, y across (the far wall we look at is y = -HALF_W), z up from the
floor. The camera sits on the near (+y) side looking at -y, so screen-right is -x.
"""
import math

from dsfilm import materials as mt
from dsfilm.geometry import (box, empty, no_shadow, plane_uv, rrect, slab, smooth_by_angle, smooth_tube, sphere,
                             tube, to_mesh, link)

import bmesh
import bpy

HALF_W = 1.45
WALL_T = 0.10
WALL_TOP = 1.95
CEIL = 2.30
FLOOR_TO_RAIL = 1.18
CAR_X = (-7.5, 7.5)
SEAT_N = 7
SEAT_TOP = 0.435
SEAT_DEPTH = 0.54
WIN_Z = (0.98, 1.86)
TRANSOM_Z = 1.62
RAIL_Z = 1.98
BENCHES = [(-2.10, 1.20), (2.80, 6.10), (-6.90, -3.64)]
DOORS = [(1.36, 2.66), (-3.50, -2.20)]


def windows_for(b):
    x0, x1 = b
    mid = (x0 + x1) / 2
    return [(x0 + 0.10, mid - 0.06), (mid + 0.06, x1 - 0.18)]


WINDOWS = sum((windows_for(b) for b in BENCHES), [])


def seat_x(i, bench=BENCHES[0]):
    w = (bench[1] - bench[0]) / SEAT_N
    return bench[0] + w * (i + 0.5)


def make_materials(P, assets_tex):
    M = {}
    M["wall"] = mt.noise_bump(mt.principled("WallLaminate", (0.80, 0.79, 0.75), 0.36, **{"Specular IOR Level": 0.5}),
                              scale=180, strength=0.01, rough_var=0.07)
    M["wall_lower"] = mt.noise_bump(mt.principled("WallLower", (0.70, 0.70, 0.67), 0.4), scale=180, strength=0.01,
                                    rough_var=0.06)
    M["alu"] = mt.noise_bump(mt.principled("Aluminium", (0.82, 0.83, 0.84), 0.20, 1.0), scale=12, strength=0.01,
                             stretch=(1, 1, 60), rough_var=0.05)
    M["chrome"] = mt.noise_bump(mt.principled("Chrome", (0.88, 0.89, 0.90), 0.06, 1.0), scale=3, strength=0.0,
                                rough_var=0.04)
    M["steel"] = mt.noise_bump(mt.principled("BrushedSteel", (0.74, 0.74, 0.75), 0.26, 1.0, **{"Anisotropic": 0.6}),
                               scale=6, strength=0.01, stretch=(1, 1, 200), rough_var=0.08)
    M["ceiling"] = mt.noise_bump(mt.principled("Ceiling", (0.78, 0.78, 0.76), 0.45), scale=120, strength=0.005,
                                 rough_var=0.05)
    M["grille"] = mt.principled("Grille", (0.55, 0.56, 0.57), 0.5, 0.6)
    M["lamp"] = mt.emission("LampDiffuser", (1.0, 0.97, 0.93), P["cabin_lamp"])
    seat_kw = dict(size_m=0.16, desat=True, nor_strength=0.7, **{"Sheen Weight": 0.7, "Sheen Roughness": 0.35})
    M["seat"] = mt.ph_pbr("SeatMoquette", "velour_velvet", tint=(0.13, 0.33, 0.17), **seat_kw)
    M["seat_priority"] = mt.ph_pbr("SeatPriority", "velour_velvet", tint=(0.42, 0.20, 0.12), **seat_kw)
    M["seam"] = mt.ph_pbr("SeatSeam", "velour_velvet", tint=(0.04, 0.10, 0.05), **seat_kw)
    M["skirt"] = mt.noise_bump(mt.principled("SeatSkirt", (0.34, 0.35, 0.36), 0.4, 0.4), scale=80, strength=0.01,
                               rough_var=0.06)
    M["floor"] = mt.noise_bump(mt.principled("FloorVinyl", (0.30, 0.29, 0.27), 0.45), scale=420, strength=0.04,
                               rough_var=0.15, detail=6)
    M["strap"] = mt.noise_bump(mt.principled("StrapBand", (0.80, 0.80, 0.77), 0.5, **{"Subsurface Weight": 0.1}),
                               scale=300, strength=0.03, stretch=(8, 1, 1))
    M["strap_yellow"] = mt.principled("StrapYellow", (0.85, 0.62, 0.05), 0.45)
    M["ring"] = mt.principled("RingPlastic", (0.88, 0.88, 0.86), 0.22, **{"Subsurface Weight": 0.2, "Coat Weight": 0.3})
    M["ring_yellow"] = mt.principled("RingYellow", (0.90, 0.68, 0.06), 0.25, **{"Coat Weight": 0.3})
    M["frosted"] = mt.principled("Frosted", (0.88, 0.90, 0.90), 0.3, **{"Transmission Weight": 0.85})
    M["rubber"] = mt.principled("Rubber", (0.035, 0.035, 0.04), 0.6)
    M["black"] = mt.principled("BlackPlastic", (0.025, 0.025, 0.03), 0.25)
    M["exterior"] = mt.principled("CarExterior", (0.70, 0.71, 0.72), 0.3, 0.9)
    rain = P.get("rain", False)
    # UV-cut tinted glass as on Japanese EMUs: less light through, so the cabin shows in it by day too
    # EEVEE has no true reflections of the cabin in thin glass (its probes see the bright windows), so
    # the pane reflects less there and without smudge haze, to match the path-traced look
    g = mt.thin_glass("WindowGlass", tint=(0.70, 0.77, 0.74), refl=0.04 if P.get("eevee") else 0.12,
                      smudge=0.0 if P.get("eevee") else 0.06, rain=rain)
    M["glass"], M["rain_map"] = (g if rain else (g, None))
    return M


def build(C, M, posters):
    """C: the collection, M: materials, posters: dict name -> png path. Returns strap pivots."""
    for s in (-1, 1):
        _wall(C, M, s)
        _doors(C, M, s, posters)
        for i, b in enumerate(BENCHES):
            _bench(C, M, b, s, priority=(i == 2 and s < 0))
    _ceiling_floor(C, M)
    _ads(C, M, posters)
    piv = _straps(C, M, -0.72, 52, yellow=range(36, 52))
    piv += _straps(C, M, 0.72, 52)
    return piv


def _wall(C, M, s):
    yc = s * (HALF_W + WALL_T / 2)
    holes = [rrect(x0, WIN_Z[0], x1, WIN_Z[1], 0.085) for x0, x1 in WINDOWS]
    holes += [rrect(x0, -0.10, x1, 1.90, 0.04) for x0, x1 in DOORS]
    outer = [(CAR_X[0], -0.05), (CAR_X[1], -0.05), (CAR_X[1], WALL_TOP + 0.05), (CAR_X[0], WALL_TOP + 0.05)]
    # door holes run below the outline: clip them to it by making the outline start at -0.05
    w = slab(f"Wall{s}", [outer] + holes, WALL_T, [M["wall"], M["alu"]], C, side_mat=1)
    w.location = (0, yc, 0)
    y_in = s * HALF_W
    for i, (x0, x1) in enumerate(WINDOWS):
        ring = slab(f"WinFrame{s}_{i}", [rrect(x0 - 0.035, WIN_Z[0] - 0.035, x1 + 0.035, WIN_Z[1] + 0.035, 0.115),
                                          rrect(x0, WIN_Z[0], x1, WIN_Z[1], 0.085)], 0.02, [M["alu"]], C)
        ring.location = (0, y_in - s * 0.008, 0)
        bv = ring.modifiers.new("bev", "BEVEL")
        bv.width, bv.segments = 0.006, 2
        g = slab(f"Glass{s}_{i}", [rrect(x0, WIN_Z[0], x1, WIN_Z[1], 0.085)], 0.0, [M["glass"]], C)
        g.location = (0, yc + s * 0.012, 0)
        no_shadow(g)
        box(f"Transom{s}_{i}", (x1 - x0, 0.07, 0.035), ((x0 + x1) / 2, yc, TRANSOM_Z), M["alu"], C, bevel=0.006)
        gk = slab(f"Gasket{s}_{i}", [rrect(x0, WIN_Z[0], x1, WIN_Z[1], 0.085),
                                     rrect(x0 + 0.014, WIN_Z[0] + 0.014, x1 - 0.014, WIN_Z[1] - 0.014, 0.072)],
                  0.014, [M["rubber"]], C)
        gk.location = (0, yc + s * 0.012, 0)
        # a little aluminium sill under the window
        box(f"Sill{s}_{i}", (x1 - x0 + 0.06, 0.05, 0.018), ((x0 + x1) / 2, y_in - s * 0.02, WIN_Z[0] - 0.045), M["alu"], C,
            bevel=0.006)
    # stainless outer skin with the same openings, so the window reveals look like a real body
    skin = slab(f"Skin{s}", [outer] + holes, 0.004, [M["exterior"]], C)
    skin.location = (0, s * (HALF_W + WALL_T + 0.04), 0)


def _doors(C, M, s, posters):
    yc = s * (HALF_W + WALL_T * 0.70)
    for di, (x0, x1) in enumerate(DOORS):
        w = (x1 - x0) / 2
        for k in range(2):
            lx0 = x0 + k * w
            win = rrect(lx0 + 0.13, 1.00, lx0 + w - 0.13, 1.80, 0.07)
            slab(f"DoorLeaf{s}_{di}_{k}", [rrect(lx0 + 0.003, 0.0, lx0 + w - 0.003, 1.90, 0.01), win], 0.035,
                 [M["steel"], M["rubber"]], C, side_mat=1).location = (0, yc, 0)
            g = slab(f"DoorGlass{s}_{di}_{k}", [win], 0.0, [M["glass"]], C)
            g.location = (0, yc, 0)
            no_shadow(g)
            if s < 0:
                plane_uv(f"Sticker{di}_{k}", 0.12, 0.12, mt.image_mat(f"Sticker{di}{k}", posters["door_sticker"], alpha=True),
                         C, (lx0 + w / 2, yc - s * 0.019, 0.88), (math.radians(90), 0, math.pi))  # face +y (the camera), text unmirrored
        box(f"DoorSeal{s}_{di}", (0.024, 0.05, 1.88), (x0 + w, yc, 0.95), M["rubber"], C, bevel=0.008)
        box(f"Threshold{s}_{di}", (x1 - x0, 0.17, 0.012), ((x0 + x1) / 2, s * (HALF_W - 0.03), 0.006), M["steel"], C)
        # yellow edge line on the floor at the door
        box(f"DoorLine{s}_{di}", (x1 - x0, 0.05, 0.004), ((x0 + x1) / 2, s * (HALF_W - 0.15), 0.002),
            mt.principled(f"DoorLineMat{s}{di}", (0.80, 0.62, 0.08), 0.5), C)
        # door frame trim
        tube(f"DoorTrim{s}_{di}", [(x0, s * HALF_W, 0), (x0, s * HALF_W, 1.92), (x1, s * HALF_W, 1.92), (x1, s * HALF_W, 0)],
             0.016, M["alu"], C)


def _bench(C, M, b, s, priority=False):
    x0, x1 = b
    w = (x1 - x0) / SEAT_N
    mat = M["seat_priority"] if priority else M["seat"]
    yb = s * (HALF_W - 0.05)                 # back edge
    yf = yb - s * SEAT_DEPTH                 # front edge
    # one continuous seat cushion (as on real long benches) with sewn seat divisions
    box(f"Cushion{s}_{x0:.1f}", (x1 - x0 - 0.01, SEAT_DEPTH, 0.10), ((x0 + x1) / 2, (yb + yf) / 2, SEAT_TOP - 0.05),
        mat, C, bevel=0.04, segs=5, subsurf=1)
    box(f"Back{s}_{x0:.1f}", (x1 - x0 - 0.01, 0.09, 0.40), ((x0 + x1) / 2, s * (HALF_W - 0.085), SEAT_TOP + 0.27),
        mat, C, bevel=0.035, segs=5, subsurf=1, rot=(s * math.radians(-8), 0, 0))
    for i in range(1, SEAT_N):
        x = x0 + w * i
        tube(f"Seam{s}_{x:.2f}", [(x, yf + s * 0.03, SEAT_TOP + 0.002), (x, yb - s * 0.03, SEAT_TOP + 0.002)], 0.005,
             M["seam"], C)
        tube(f"BackSeam{s}_{x:.2f}", [(x, s * (HALF_W - 0.13), SEAT_TOP + 0.12), (x, s * (HALF_W - 0.075), SEAT_TOP + 0.46)],
             0.005, M["seam"], C)
    box(f"Skirt{s}_{x0:.1f}", (x1 - x0, 0.03, 0.27), ((x0 + x1) / 2, yf + s * 0.13, 0.19), M["skirt"], C, bevel=0.008)
    box(f"SeatBase{s}_{x0:.1f}", (x1 - x0, SEAT_DEPTH - 0.08, 0.03), ((x0 + x1) / 2, (yb + yf) / 2 + s * 0.03, SEAT_TOP - 0.115),
        M["skirt"], C)
    # mid stanchion between seats 3 and 4
    xm = x0 + w * 3
    tube(f"MidPole{s}_{x0:.1f}", [(xm, yf + s * 0.02, SEAT_TOP - 0.02), (xm, yf + s * 0.02, 1.62),
                                  (xm, s * (HALF_W - 0.30), 1.80)], 0.016, M["chrome"], C)
    # end partitions: lower laminate panel, frosted upper pane in a chrome tube frame, grab pole
    yi, yo = s * HALF_W, s * (HALF_W - 0.64)
    for xe, sgn in ((x0 - 0.03, -1), (x1 + 0.03, 1)):
        low = slab(f"Partition{s}_{xe:.1f}", [rrect(0.0, 0.03, 0.62, 0.98, 0.02)], 0.03, [M["wall_lower"]], C)
        low.rotation_euler = (math.radians(90), 0, math.radians(90 if s < 0 else -90))
        low.location = (xe, yi, 0)
        up = slab(f"PartGlass{s}_{xe:.1f}", [rrect(0.03, 1.0, 0.60, 1.78, 0.05)], 0.012, [M["frosted"]], C)
        up.rotation_euler = low.rotation_euler
        up.location = (xe, yi, 0)
        tube(f"PartFrame{s}_{xe:.1f}", [(xe, yi, 1.82), (xe, yo + s * 0.09, 1.82), (xe, yo, 1.73), (xe, yo, 0.0)],
             0.019, M["chrome"], C)
        tube(f"PartBar{s}_{xe:.1f}", [(xe, yi, 0.99), (xe, yo, 0.99)], 0.012, M["chrome"], C)
        tube(f"GrabPole{s}_{xe:.1f}", [(xe + sgn * 0.07, yo + s * 0.03, 0.0), (xe + sgn * 0.07, yo + s * 0.03, CEIL)],
             0.017, M["chrome"], C)
    # luggage rack
    yr0, yr1 = s * (HALF_W - 0.02), s * (HALF_W - 0.30)
    zr = 1.80
    for xb in (x0 + 0.03, (x0 + x1) / 2, x1 - 0.03):
        tube(f"RackArm{s}_{xb:.2f}", [(xb, yr0, zr + 0.16), (xb, yr1, zr), (xb, yr0, zr - 0.03)], 0.011, M["alu"], C)
    for k in range(6):
        yy = yr0 + (yr1 - yr0) * (k + 0.5) / 6
        tube(f"RackRod{s}_{x0:.1f}_{k}", [(x0 + 0.03, yy, zr), (x1 - 0.03, yy, zr)], 0.005, M["alu"], C)
    tube(f"RackEdge{s}_{x0:.1f}", [(x0 + 0.03, yr1, zr), (x1 - 0.03, yr1, zr)], 0.014, M["alu"], C)


def _ceiling_floor(C, M):
    prof = []
    for i in range(13):
        a = i / 12
        prof.append((-HALF_W + 0.30 * (1 - math.cos(a * math.pi / 2)), WALL_TOP + (CEIL - 0.04 - WALL_TOP) * math.sin(a * math.pi / 2)))
    prof += [(-0.42, CEIL - 0.04), (-0.40, CEIL), (0.40, CEIL), (0.42, CEIL - 0.04)]
    prof += [(-y, z) for (y, z) in reversed(prof[:13])]
    bm = bmesh.new()
    rows = [[bm.verts.new((x, y, z)) for (y, z) in prof] for x in CAR_X]
    for j in range(len(prof) - 1):
        bm.faces.new((rows[0][j], rows[1][j], rows[1][j + 1], rows[0][j + 1]))
    bm.normal_update()
    if sum(f.normal.z for f in bm.faces) > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    from dsfilm.geometry import from_bm
    ceil = from_bm("Ceiling", bm, M["ceiling"], C)
    sol = ceil.modifiers.new("thick", "SOLIDIFY")
    sol.thickness = 0.02
    smooth_by_angle(ceil, 40)
    for s in (-1, 1):
        box(f"LampHousing{s}", (CAR_X[1] - CAR_X[0], 0.20, 0.05), (0, s * 0.62, CEIL - 0.065), M["ceiling"], C, bevel=0.012)
        no_shadow(box(f"Lamp{s}", (CAR_X[1] - CAR_X[0], 0.13, 0.03), (0, s * 0.62, CEIL - 0.095), M["lamp"], C, bevel=0.01))
    box("ACPanel", (CAR_X[1] - CAR_X[0], 0.78, 0.02), (0, 0, CEIL - 0.01), M["ceiling"], C, bevel=0.005)
    for k in range(16):
        x = CAR_X[0] + 0.6 + k * 0.9
        box(f"ACVent{k}", (0.55, 0.30, 0.012), (x, 0, CEIL - 0.024), M["grille"], C, bevel=0.004)
    box("Roof", (CAR_X[1] - CAR_X[0] + 0.4, 2 * HALF_W + 0.5, 0.05), (0, 0, CEIL + 0.3), M["exterior"], C)
    box("Floor", (CAR_X[1] - CAR_X[0], 2 * HALF_W + 0.2, 0.05), (0, 0, -0.025), M["floor"], C)
    box("FloorUnder", (CAR_X[1] - CAR_X[0] + 0.4, 2 * HALF_W + 0.5, 0.05), (0, 0, -0.35), M["exterior"], C)
    for sx in (-1, 1):
        box(f"EndWall{sx}", (0.08, 2 * HALF_W + 0.2, CEIL + 0.1), (sx * (CAR_X[1] + 0.04), 0, CEIL / 2), M["wall"], C)


def _ads(C, M, posters):
    """Above-window ads as on many Japanese EMUs: a straight, vertical aluminium-framed ad board
    standing on the luggage rack's front rail, square to the carriage, three B3-ish sheets per bench.
    Hanging (nakazuri) posters hang flat from the ceiling on two wires, square to the car's axis."""
    order = ["tea", "school", "travel", "clinic", "manners", "travel", "tea", "school", "clinic"]
    zr, h_board = 1.815, 0.36                 # the rack's front rail, board height
    k = 0
    for s in (-1, 1):
        yb = s * (HALF_W - 0.31)              # just behind the rack's front edge
        rot = (math.radians(90), 0, math.pi) if s < 0 else (math.radians(90), 0, 0)   # face the aisle, unmirrored
        for (x0, x1) in BENCHES:
            # the board: a thin panel in an aluminium edge frame
            bw = x1 - x0 - 0.10
            cx0 = (x0 + x1) / 2
            box(f"AdBoard{s}_{x0:.1f}", (bw, 0.012, h_board), (cx0, yb + s * 0.010, zr + h_board / 2), M["wall_lower"], C)
            for zz in (zr + 0.008, zr + h_board - 0.008):
                box(f"AdRail{s}_{x0:.1f}_{zz:.2f}", (bw + 0.02, 0.03, 0.018), (cx0, yb, zz), M["alu"], C, bevel=0.004)
            for xx in (cx0 - bw / 2, cx0 + bw / 2):
                box(f"AdPost{s}_{xx:.2f}", (0.018, 0.03, h_board), (xx, yb, zr + h_board / 2), M["alu"], C, bevel=0.004)
            n = 3
            pw = bw / n
            for i in range(n):
                cx = cx0 - bw / 2 + pw * (i + 0.5)
                name = order[k % len(order)]
                k += 1
                im = bpy.data.images.load(posters[name], check_existing=True)
                aspect = im.size[0] / im.size[1]
                h = h_board - 0.05
                wdt = min(h * aspect, pw - 0.06)
                h = wdt / aspect if wdt < h * aspect else h
                plane_uv(f"Poster{k}", wdt, h, mt.image_mat(f"Poster{k}_{name}", posters[name], rough=0.3, coat=0.5),
                         C, (cx, yb - s * 0.002, zr + h_board / 2), rot)
                # a clear acrylic cover clip at the top of each sheet
                box(f"PosterClip{k}", (wdt * 0.9, 0.006, 0.012), (cx, yb - s * 0.006, zr + h_board / 2 + h / 2 - 0.004), M["alu"], C)
    for di, (x0, x1) in enumerate(DOORS):
        cx = (x0 + x1) / 2
        plane_uv(f"RouteMap{di}", 0.95, 0.142, mt.image_mat(f"RouteMat{di}", posters["route_map"], rough=0.3, coat=0.5),
                 C, (cx - 0.28, -HALF_W + 0.012, 2.05), (math.radians(90), 0, math.pi))
        box(f"ScreenBezel{di}", (0.44, 0.04, 0.17), (cx + 0.45, -HALF_W + 0.02, 2.05), M["black"], C, bevel=0.01)
        plane_uv(f"Screen{di}", 0.40, 0.13, mt.image_mat(f"ScreenMat{di}", posters["screen"], rough=0.08, coat=1.0, emit=1.2),
                 C, (cx + 0.45, -HALF_W + 0.041, 2.05), (math.radians(90), 0, math.pi))
    plane_uv("PrioritySign", 0.26, 0.13, mt.image_mat("PriorityMat", posters["priority"], rough=0.3, coat=0.3), C,
             ((BENCHES[2][0] + BENCHES[2][1]) / 2, -HALF_W + 0.012, 1.935), (math.radians(90), 0, math.pi))
    for k, x in enumerate((-4.6, 0.2, 5.0)):
        w, h, z = 0.80, 0.29, 2.08
        mat = mt.image_mat(f"DropMat{k}", posters["hanging"], rough=0.35, coat=0.2)
        plane_uv(f"DropA{k}", w, h, mat, C, (x + 0.001, 0.0, z), (math.radians(90), 0, math.radians(90)))
        plane_uv(f"DropB{k}", w, h, mat, C, (x - 0.001, 0.0, z), (math.radians(90), 0, math.radians(-90)))
        box(f"DropBar{k}", (0.012, w + 0.02, 0.016), (x, 0.0, z + h / 2 + 0.006), M["alu"], C, bevel=0.003)
        for yy in (-w / 2 + 0.03, w / 2 - 0.03):
            tube(f"DropWire{k}_{yy:.2f}", [(x, yy, z + h / 2 + 0.012), (x, yy, CEIL - 0.01)], 0.0018, M["alu"], C)


def _straps(C, M, row_y, n, yellow=()):
    tube(f"StrapRail{row_y}", [(CAR_X[0] + 0.3, row_y, RAIL_Z), (CAR_X[1] - 0.3, row_y, RAIL_Z)], 0.016, M["chrome"], C)
    for k in range(9):
        xb = CAR_X[0] + 0.8 + 1.7 * k
        tube(f"RailHanger{row_y}_{k}", [(xb, row_y, RAIL_Z), (xb, row_y * 0.92, CEIL - 0.01)], 0.011, M["chrome"], C)
    out = []
    for i in range(n):
        x = CAR_X[0] + 0.45 + (CAR_X[1] - CAR_X[0] - 0.9) * (i + 0.5) / n
        yl = i in yellow
        piv = empty(f"StrapPivot{row_y}_{i}", C, (x, row_y, RAIL_Z))
        L = 0.20 + (0.07 if i % 4 == 1 else 0.0)
        box(f"Band{row_y}_{i}", (0.026, 0.005, L), (0, 0, -L / 2 - 0.012), M["strap_yellow" if yl else "strap"], C,
            bevel=0.0015, segs=1, parent=piv)
        box(f"Clip{row_y}_{i}", (0.036, 0.036, 0.034), (0, 0, -0.006), M["ring"], C, bevel=0.008, parent=piv)
        _ring(f"Ring{row_y}_{i}", M["ring_yellow" if yl else "ring"], C, piv, -L - 0.072)
        out.append(piv)
    return out


def _ring(name, mat, C, parent, z):
    pts = []
    for i in range(48):
        a = math.tau * i / 48
        r = 0.066 * (1 + 0.09 * math.cos(3 * (a - math.pi / 2)))
        pts.append((r * math.cos(a), 0, r * math.sin(a) * 0.92))
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = 0.0105
    cu.bevel_resolution = 4
    sp = cu.splines.new("POLY")
    sp.points.add(len(pts) - 1)
    for p, q in zip(sp.points, pts):
        p.co = (*q, 1)
    sp.use_cyclic_u = True
    ob = bpy.data.objects.new(name, cu)
    link(ob, C)
    ob = to_mesh(ob)
    ob.data.materials.append(mat)
    ob.parent = parent
    ob.location = (0, 0, z)
    return ob
