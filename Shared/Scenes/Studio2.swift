//  Studio2.swift — Zen Garden (shader id 68). See SceneCatalog.swift.
//  Shader: Shared/Scenes/Studio2_cases.h (+ helpers in Studio2_funcs.h).
//
//  A karesansui seen from above: a bed of pale raked gravel in a low dark-wood frame, three
//  groups of stones (two on cushions of moss), and a little rake cart that slowly re-rakes
//  the whole garden, one composition after another — long parallel lines, waves, or ripples
//  spreading from the stones — always finishing with a pass round the frame and rings round
//  every group. Stateless: which composition is on the bed and where the cart is follow from
//  the time, clock and date alone, so every display and the wallpaper show the same garden.
//  The cart's path is planned and traced here (SandGarden), once a composition, and handed
//  to the shader as a data texture; per frame only the cart moves on.

import Foundation
import Metal
import simd

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the slot-2 line of EffectKind.
    static let studio2: [EffectKind: SceneSpec] = [
        .sandGarden: SceneSpec(
            name: "Zen Garden",
            blurb: "A little rake cart slowly re-rakes a dry garden of pale gravel, stones and moss: lines, waves and ripples.",
            shaderID: 68,
            // Packed in order: p0 = (speed, pattern, rake width, framing), p1 = (relief, angle, height, live).
            params: [ParamSpec("speed", "Speed", 0, 3, def: 1),
                     ParamSpec(menu: "pattern", "Pattern", ["Surprise", "Lines", "Waves", "Ripples"], def: 0),
                     ParamSpec("groove", "Rake Width", 0.6, 1.6, def: 1),
                     ParamSpec(menu: "framing", "Framing", ["Fill", "Garden"], def: 0),
                     ParamSpec("relief", "Relief", 0, 1, def: 0.6),
                     ParamSpec("angle", "Light Angle", 0, 360, def: 215),
                     ParamSpec("height", "Light Height", 8, 60, def: 26),
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true)],
            colorA: RGBA(0.20, 0.14, 0.10), colorB: RGBA(0.80, 0.79, 0.76),
            colorALabel: "Wood", colorBLabel: "Gravel"),
    ]

    /// Styles this scene adds to the default library.
    static var studio2Presets: [Preset] {
        func scene(_ name: String, _ params: [String: Double] = [:], a: RGBA? = nil, b: RGBA? = nil) -> Preset {
            var e = EffectInstance(.sandGarden)
            for (k, v) in params { e.params[k] = v }
            if let a { e.colorA = a }
            if let b { e.colorB = b }
            return Preset(name: name, effects: [e])
        }
        return [
            scene("Zen Garden", ["framing": 0, "pattern": 0, "angle": 215, "height": 26],
                  a: RGBA(0.20, 0.14, 0.10), b: RGBA(0.80, 0.79, 0.76)),
            // Dark basalt gravel in a pale cedar frame: evening-friendly.
            scene("Black Sand", ["framing": 1, "pattern": 3, "angle": 140, "height": 20, "relief": 0.7],
                  a: RGBA(0.52, 0.40, 0.29), b: RGBA(0.36, 0.355, 0.35)),
        ]
    }
}

/// The garden and its cart. A composition is planned as the path a rake cart drives — the
/// field (parallel lines at some angle, waves, or ripples round each group, each only where
/// the stones' rings won't go), then once round the frame, then rings round every group,
/// inside out — with the rake down (drawing) or lifted (turning, crossing what's done, going
/// round a stone). The path is traced as a polyline, and the shader is handed it in a data
/// texture (slot 6) with a coarse grid over the bed: each cell lists the newest raked
/// segments whose footprint reaches it, newest first, so a pixel composites only the passes
/// near it, newest on top — the rake replaces whatever was under it.
///
/// Texture layout (RGBA32Float, 1024 wide; rows of 4096 floats):
///   row 0       cell c's insert count, float c of the row (4 cells a texel)
///   rows 1…256  cell c's ring of its 32 newest raked segments, two texels each: (ax, ay, bx, by)
///               in cm, then (s at a, s at b, cut, 0) — s the arc length along the visible track
///               (the last composition, then this one), cut: 1 = the rake dropped at a, 2 = lifted
///               at b. Entry 32c + (count mod 32) is the next to write.
///   row 257     stone k's shape at texel k: (angle, elongation, moss, seed); at texel 8 + k its radius
///   rows 258…297 the stones' shadows and contact darkening on the gravel, baked for the light:
///               a grid of samples (sun visibility, ambient), two a texel, row-major
/// The cart, the head of the track, the grid's placement, the stones' places and the light
/// go in u.scene (see Cache.prepare): [0] the rake (tine tips' middle = the track's head, and
/// its heading), [5] the cart's body (centre, heading).
enum SandGarden {
    static let texW = 1024
    static let countRow = 0, ringRow = 1, stoneRow = 257, shadowRow = 258, shadowRows = 40, texH = 298
    static let ringK = 32
    /// The count row and the rings hold exactly this many cells (STUDIO2_CELLS in the shader).
    static let maxCells = 4096
    /// The grid over a bed (half-extents bx × by, cm): the cell, ~2 cm, larger on a wide bed so
    /// the grid stays within `maxCells` — the per-axis ceilings, not just the area, must fit
    /// (2560×1080's area alone asks for 100 × 41 = 4100) — and its columns × rows.
    static func grid(bx: Double, by: Double) -> (cell: Float, n: SIMD2<Int>) {
        func dims(_ c: Float) -> SIMD2<Int> {
            SIMD2(Int((2 * bx / Double(c)).rounded(.up)), Int((2 * by / Double(c)).rounded(.up)))
        }
        var c = Float(max(2.0, (4 * bx * by / 4000).squareRoot()))
        var n = dims(c)
        while n.x * n.y > maxCells { c *= 1.005; n = dims(c) }
        return (c, n)
    }
    static let maxVerts = 120_000
    static let compositionsPerHour: Float = 5        // at Speed 1×: twelve minutes a composition
    /// The cart's size: 1 at the default rake (and wider ones); a narrower rake gets a smaller
    /// cart, so its wheels stay on the raked band (and off the frame on the pass round it).
    /// As the shader's studio2_cartScale.
    static func cartScale(_ wr: Float) -> Float { min(1, (0.5 * wr - 0.1) / 3.37) }
    /// From the tine tips to the body's centre, cm at scale 1 (STUDIO2_TOW in the shader).
    static let tow: Float = 6.5

    // MARK: hashing

    static func hash(_ v: UInt64) -> UInt64 {          // splitmix64 finaliser
        var z = v &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    struct RNG {
        var s: UInt64
        init(_ seed: UInt64) { s = SandGarden.hash(seed) }
        mutating func next() -> Double { s = SandGarden.hash(s); return Double(s >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
        mutating func pick<T>(_ xs: [T]) -> T { xs[min(Int(next() * Double(xs.count)), xs.count - 1)] }
        mutating func sign() -> Double { next() < 0.5 ? -1 : 1 }
    }

    // MARK: the garden

    struct Stone {
        var c: SIMD2<Double>
        var r, h, ang, elong, moss, seed: Double
        var group: Int
        /// The outline's harmonics (as the shader works them out from the seed), and the
        /// radius the stone fits inside.
        var harmonics: (Double, Double, Double) {
            let sd = seed.rounded(.down)
            func fr(_ x: Double) -> Double { x - x.rounded(.down) }
            return (0.08 + 0.07 * fr(sd * 0.37), 0.05 + 0.05 * fr(sd * 0.61), 0.03 + 0.03 * fr(sd * 0.83))
        }
        var bound: Double { let h = harmonics; return r * elong * (1 + h.0 + h.1 + h.2) }
        /// The stone and its moss fit inside this radius.
        var excl: Double { bound + moss }

        /// Roughly how far p is outside the stone's outline (its own radial measure), cm.
        func outside(_ p: SIMD2<Double>) -> Double {
            let (a2, a3, a4) = harmonics
            let v = p - c
            let l = SIMD2(cos(ang) * v.x + sin(ang) * v.y, -sin(ang) * v.x + cos(ang) * v.y) / SIMD2(elong, 1)
            let rr = simd_length(l)
            let e = l / max(rr, 1e-6)
            let c2 = e.x * e.x - e.y * e.y, s2 = 2 * e.x * e.y
            let c3 = e.x * (4 * e.x * e.x - 3), s3 = e.y * (3 - 4 * e.y * e.y)
            let c4 = c2 * c2 - s2 * s2, s4 = 2 * c2 * s2
            let R = r * (1 + a2 * (0.6 * c2 + 0.8 * s2) + a3 * (0.8 * c3 - 0.6 * s3) + a4 * (0.28 * c4 + 0.96 * s4))
            // back to world cm along this direction (the elongation stretched it)
            let stretch = simd_length(SIMD2(e.x * elong, e.y))
            return (rr - R) * stretch
        }

        /// As the shader's studio2_stoneT / studio2_stoneH (smooth): how far out (1 at the
        /// outline), and the height at p.
        func t(_ p: SIMD2<Float>) -> Float {
            let ca = Float(cos(ang)), sa = Float(sin(ang)), (a2, a3, a4) = harmonics
            let v = p - SIMD2<Float>(c)
            let l = SIMD2(ca * v.x + sa * v.y, -sa * v.x + ca * v.y) / SIMD2(Float(elong), 1)
            let rr = simd_length(l)
            let e = l / max(rr, 1e-5)
            let c2 = e.x * e.x - e.y * e.y, s2 = 2 * e.x * e.y
            let c3 = e.x * (4 * e.x * e.x - 3), s3 = e.y * (3 - 4 * e.y * e.y)
            let c4 = c2 * c2 - s2 * s2, s4 = 2 * c2 * s2
            let R = Float(r) * (1 + Float(a2) * (0.6 * c2 + 0.8 * s2) + Float(a3) * (0.8 * c3 - 0.6 * s3) + Float(a4) * (0.28 * c4 + 0.96 * s4))
            return rr / R
        }
        func height(_ p: SIMD2<Float>) -> Float {
            let tt = t(p)
            if tt >= 1 { return 0 }
            let q = 1 - tt * tt
            let v = (p - SIMD2<Float>(c)) / Float(r)
            let fa = 1.05 - 0.55 * simd_dot(v, SIMD2(0.82, 0.57)), fb = 1.08 + 0.5 * simd_dot(v, SIMD2(0.31, -0.95))
            let fc = 1.12 - 0.45 * simd_dot(v, SIMD2(-0.9, 0.42))
            let sq = q.squareRoot()
            return Float(h) * min(sq * (1 - 0.12 * q), min(fa, min(fb, fc)) * (0.35 + 0.65 * sq))
        }
    }

    /// The bed (sand half-extents bx × by, cm), the rake and the stones. The bed takes the
    /// screen's shape (so Fill frames it exactly); the stones keep their sizes in cm and sit
    /// in three groups, asymmetrically: a tall three-stone group with moss on the left, a pair
    /// on moss lower right, a lone stone above.
    struct Garden {
        var bx: Double, by: Double, wr: Double
        var stones: [Stone] = []
        var groups: [[Int]] = []

        init(aspect: Float, groove: Float) {
            by = 46
            bx = max(50 * Double(min(max(aspect, 0.5), 3)) - 4, 30)
            wr = 8 * Double(min(max(groove, 0.6), 1.6))
            let wide = min(bx / 76, 1.4)
            // (anchor x, anchor y as fractions of the bed; stones: dx, dy cm, radius, height, moss)
            let layout: [(Double, Double, [(Double, Double, Double, Double, Double)])] = [
                (-0.52, 0.04, [(0, 5, 8.5, 15, 4.5), (10, -6, 5.0, 8, 4.5), (-8.5, -8, 3.6, 4.5, 4.5)]),
                (0.46, -0.24, [(0, 0, 6.6, 10, 3.5), (9, 7, 3.8, 5, 3.5)]),
                (0.10 * wide, 0.36, [(0, 0, 4.4, 6.5, 0)]),
            ]
            var r = RNG(0x5A4D_17)
            for (gi, (ax, ay, ss)) in layout.enumerated() {
                var ids: [Int] = []
                for (dx, dy, rad, h, moss) in ss {
                    let s = Stone(c: SIMD2(ax * bx + dx, ay * by + dy), r: rad, h: h, ang: r.range(0, .pi),
                                  elong: r.range(1.05, 1.35), moss: moss, seed: r.range(0, 100), group: gi)
                    ids.append(stones.count)
                    stones.append(s)
                }
                groups.append(ids)
            }
        }

        /// Distance from p to group g's stones-and-moss (≤ 0 inside one): from each stone's
        /// own outline, less a typical width of its moss.
        func f(_ g: Int, _ p: SIMD2<Double>) -> Double {
            var d = 1e9
            for i in groups[g] { d = min(d, stones[i].outside(p) - stones[i].moss * 0.8) }
            return d
        }
        func centroid(_ g: Int) -> SIMD2<Double> {
            groups[g].reduce(SIMD2<Double>(0, 0)) { $0 + stones[$1].c } / Double(groups[g].count)
        }
        /// Where the cart may drive: on the sand, clear of every stone and its moss. Pushes p there.
        func drivable(_ p: SIMD2<Double>) -> SIMD2<Double> {
            var q = SIMD2(min(max(p.x, -bx + 3), bx - 3), min(max(p.y, -by + 3), by - 3))
            for _ in 0..<2 {
                for s in stones {
                    let v = q - s.c, l = simd_length(v), m = s.excl + 3.5
                    if l < m { q = s.c + (l > 1e-6 ? v / l : SIMD2(1, 0)) * m }
                }
            }
            return q
        }
        /// The contour at distance `level` round group g: closed, counter-clockwise, from angle a0.
        func contour(_ g: Int, level: Double, from a0: Double) -> [SIMD2<Double>] {
            let c = centroid(g)
            let n = max(Int(2 * .pi * (level + 20) / 0.6), 120)
            var pts: [SIMD2<Double>] = []
            pts.reserveCapacity(n + 1)
            for j in 0...n {
                let a = a0 + 2 * .pi * Double(j) / Double(n)
                let e = SIMD2(cos(a), sin(a))
                var lo = 0.0, hi = level + 60
                for _ in 0..<26 { let m = 0.5 * (lo + hi); if f(g, c + e * m) < level { lo = m } else { hi = m } }
                pts.append(c + e * (0.5 * (lo + hi)))
            }
            return pts
        }
    }

    // MARK: compositions

    enum Kind: Int, CaseIterable { case lines, waves, ripples }

    /// The kind composition g is: the menu's, or under Surprise a shuffled run of each.
    static func kind(_ g: Int, menu: Int) -> Kind {
        if menu >= 1 && menu <= Kind.allCases.count { return Kind(rawValue: menu - 1)! }
        let n = Kind.allCases.count
        func perm(_ b: Int) -> [Int] {
            var r = RNG(UInt64(bitPattern: Int64(b)) &* 0x2545_F491_4F6C_DD1D &+ 77)
            var p = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { p.swapAt(i, Int(r.next() * Double(i + 1)) % (i + 1)) }
            return p
        }
        let b = g >= 0 ? g / n : (g - n + 1) / n, j = g - b * n
        var p = perm(b)
        if p[0] == perm(b - 1)[n - 1] { p.swapAt(0, 1) }
        return Kind(rawValue: p[j])!
    }

    /// A path being planned: points, and whether the rake is down on the way to each.
    struct Path {
        var pts: [SIMD2<Double>] = []
        var down: [Bool] = []                   // down[i]: the segment into pts[i] is raked
        var last: SIMD2<Double> { pts.last ?? .zero }
        mutating func add(_ p: SIMD2<Double>, _ d: Bool) {
            if let l = pts.last, simd_length(p - l) < 1e-4 { return }
            pts.append(p); down.append(pts.count > 1 ? d : false)
        }
        /// The rake lifted, straight to `to` (round any stone in the way).
        mutating func travel(to: SIMD2<Double>, _ G: Garden) {
            let a = last, l = simd_length(to - a), n = max(Int(l / 1.0), 1)
            for i in 1...n { add(G.drivable(a + (to - a) * (Double(i) / Double(n))), false) }
        }
        /// Adds a stroke sampled densely, raked where `rake` says (the cart driving it all, its
        /// lifted runs replaced by a straight hop round the stones).
        mutating func stroke(_ s: [SIMD2<Double>], _ G: Garden, rake: (SIMD2<Double>) -> Bool) {
            var i = 0
            while i < s.count {
                if rake(s[i]) {
                    if pts.isEmpty { add(s[i], false) } else if !(down.last ?? false) || simd_length(s[i] - last) > 1.5 {
                        travel(to: s[i], G)
                    }
                    while i < s.count && rake(s[i]) { add(s[i], true); i += 1 }
                } else { i += 1 }
            }
        }
    }

    /// The whole plan for composition g, starting wherever the cart is (`from`, nil: the first).
    static func plan(_ g: Int, menu: Int, garden G: Garden, from: SIMD2<Double>?) -> Path {
        var r = RNG(UInt64(bitPattern: Int64(g)) &* 0x9E37_79B9 &+ 0x51ED_27)
        let k = kind(g, menu: menu)
        let wr = G.wr
        // rings round each group this time (as many as fit inside the frame's pass)
        var rings: [Int] = []
        for gi in G.groups.indices {
            var room = 1e9
            for i in G.groups[gi] {
                let s = G.stones[i]
                room = min(room, G.bx - wr - abs(s.c.x) - s.excl, G.by - wr - abs(s.c.y) - s.excl)
            }
            let base = gi == 2 ? 2 : 3
            rings.append(max(1, min(base + Int(r.range(-1, 2).rounded(.down)), Int((room - 0.2) / wr))))
        }
        func level(_ j: Int) -> Double { wr * 0.5 - 1.4 + Double(j) * wr }
        let outer = G.groups.indices.map { level(rings[$0] - 1) }
        var P = Path()
        if let from { P.add(from, false) }
        let inset = 0.5 * wr
        func inField(_ p: SIMD2<Double>) -> Bool { abs(p.x) <= G.bx - inset && abs(p.y) <= G.by - inset }
        func clearOfRings(_ p: SIMD2<Double>) -> Bool {
            for gi in G.groups.indices where G.f(gi, p) < outer[gi] { return false }
            return true
        }

        switch k {
        case .lines, .waves:
            // Parallel passes, boustrophedon, at an angle (lines: across, along, or a diagonal;
            // waves: across, gently undulating), each only where the rings won't go.
            var ang = 0.0, amp = 0.0, lam = 1.0, ph = 0.0
            if k == .lines { ang = r.pick([0.0, 0, .pi / 2, .pi / 6, -.pi / 6, .pi / 4]) }
            else {
                ang = r.pick([0.0, 0, .pi / 2])
                amp = r.range(2.0, 3.6) * wr / 8; lam = r.range(36, 54); ph = r.range(0, 2 * .pi)
            }
            if r.next() < 0.5 { ang += .pi }
            let d = SIMD2(cos(ang), sin(ang)), n = SIMD2(-d.y, d.x)
            let ext = abs(d.x) * G.bx + abs(d.y) * G.by + 10          // half-length along d
            let wid = abs(n.x) * G.bx + abs(n.y) * G.by                // half-width across
            // (from just inside the frame's pass on one side to just inside it on the other: the
            // pass round the frame, laid afterwards, covers their ends)
            var o = -wid + 0.5 * wr - amp, dir = 1.0
            while o < wid - 0.5 * wr + amp + 1e-6 {
                var s: [SIMD2<Double>] = []
                var t = -ext
                while t <= ext { let a = t * dir; s.append(n * (o + amp * sin(2 * .pi * a / lam + ph)) + d * a); t += 0.5 }
                P.stroke(s, G) { inField($0) && clearOfRings($0) }
                o += wr; dir = -dir
            }
        case .ripples:
            // Rings spreading from every group until they meet another group's (each a little
            // past the seam, so the seams overlap): a pond with three stones. Each time the
            // groups get their own weight, so the seams — and the whole drawing — move.
            let order = r.next() < 0.5 ? [0, 1, 2] : [2, 1, 0]
            let bias = G.groups.indices.map { _ in r.range(-1.6, 1.6) * wr }
            func own(_ gi: Int, _ p: SIMD2<Double>, slack: Double) -> Bool {
                let fg = G.f(gi, p) + bias[gi]
                return G.groups.indices.allSatisfy { $0 == gi || fg <= G.f($0, p) + bias[$0] + slack }
            }
            for gi in order {
                let c = G.centroid(gi)
                var far = 0.0
                var y = -G.by
                while y <= G.by {
                    var x = -G.bx
                    while x <= G.bx {
                        let p = SIMD2(x, y)
                        if own(gi, p, slack: 0) { far = max(far, G.f(gi, p)) }
                        x += 4
                    }
                    y += 4
                }
                let n = Int((far - level(0)) / wr) + 2
                // (the first group starts facing the bed's centre, so the plan's end never
                // depends on where the cart came from)
                let v = gi == order[0] ? -c : P.last - c
                let a0 = atan2(v.y, v.x)
                for j in 0..<n {
                    var s = G.contour(gi, level: level(j), from: a0)
                    s += Array(s.prefix(Int(wr / 0.6)))            // overlap the start
                    P.stroke(s, G) { p in inField(p) && own(gi, p, slack: 0.5 * wr) }
                }
            }
        }

        // Once round the frame, from the corner nearest the cart, overlapping where it began.
        let cx = G.bx - 0.5 * wr, cy = G.by - 0.5 * wr
        var corners = [SIMD2(cx, cy), SIMD2(-cx, cy), SIMD2(-cx, -cy), SIMD2(cx, -cy)]
        if r.next() < 0.5 { corners.reverse() }
        let here = P.pts.isEmpty ? SIMD2<Double>(cx, cy) : P.last
        let i0 = corners.indices.min { simd_length(corners[$0] - here) < simd_length(corners[$1] - here) }!
        var loop: [SIMD2<Double>] = []
        for j in 0...4 {
            let a = corners[(i0 + j) % 4], b = corners[(i0 + j + 1) % 4]
            let l = simd_length(b - a), m = Int(l / 1.0)
            let upto = j == 4 ? Int(wr) : m
            for i in 0..<max(upto, 1) { loop.append(a + (b - a) * (Double(i) / Double(m))) }
        }
        P.stroke(loop, G) { _ in true }

        // Rings round every group, inside out, nearest group first (ripples have theirs).
        var left = k == .ripples ? [] : Array(G.groups.indices)
        while !left.isEmpty {
            let here = P.last
            let gi = left.min { simd_length(G.centroid($0) - here) < simd_length(G.centroid($1) - here) }!
            left.removeAll { $0 == gi }
            let c = G.centroid(gi), v = here - c
            let a0 = atan2(v.y, v.x)
            for j in 0..<rings[gi] {
                var s = G.contour(gi, level: level(j), from: a0)
                s += Array(s.prefix(Int(wr / 0.6)))
                P.stroke(s, G) { _ in true }
            }
        }
        return P
    }

    /// Simplifies a planned path to the polyline the shader draws: a vertex every ~2.5 cm on
    /// a straight raked run (6 lifted), closer where it turns (≤ 4° a segment), and at every
    /// lift and drop of the rake.
    static func trace(_ P: Path) -> (pts: [SIMD2<Float>], down: [Bool]) {
        var out: [SIMD2<Float>] = [], dn: [Bool] = []
        guard let first = P.pts.first else { return (out, dn) }
        out.append(SIMD2<Float>(first)); dn.append(false)
        var acc = 0.0, turn = 0.0, dirPrev = SIMD2<Double>(0, 0)
        for i in 1..<P.pts.count {
            let d = P.pts[i] - P.pts[i - 1], l = simd_length(d)
            if l < 1e-9 { continue }
            let dir = d / l
            if dirPrev != .zero { turn += abs(atan2(dirPrev.x * dir.y - dirPrev.y * dir.x, simd_dot(dirPrev, dir))) }
            dirPrev = dir; acc += l
            let penChange = i + 1 < P.pts.count && P.down[i + 1] != P.down[i]
            let lmax = P.down[i] ? 10.0 : 10.0
            if acc >= lmax || turn >= 0.11 || penChange || i == P.pts.count - 1 {
                out.append(SIMD2<Float>(P.pts[i])); dn.append(P.down[i]); acc = 0; turn = 0
            }
        }
        return (out, dn)
    }

    // MARK: the light

    /// The light, the same for every pixel (so worked out here): Light Angle in screen degrees
    /// (y down: 215 = upper left) and Light Height; or, following the sun, its hour angle
    /// swinging it from the left (morning) over the top (noon) to the right, its elevation held
    /// to 8°…30° so the raking reads, warm when low; past −4° handing over to a dim warm lamp,
    /// low on the upper right. Exposure meters a pale gravel down a touch and a dark one up.
    /// Returns (Lh.x, Lh.y, tan el, sin el), (sun colour, brightness), (fill colour, flat-lit
    /// irradiance), (cos el, el, night, 0).
    static func light(_ u: FXUniforms) -> (simd_float4, simd_float4, simd_float4, simd_float4) {
        func ss(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let live = u.p1.w > 0.5 && u.sky.y > 0.5
        var azd = u.p1.y, el = min(max(u.p1.z, 8), 60) * 0.0174533, wN: Float = 0
        if live {
            let se = u.sun.x
            wN = ss(-0.035, -0.105, se)
            var dAz = 270 + u.sun.y * 57.29578 - 300
            dAz -= 360 * (dAz / 360 + 0.5).rounded(.down)
            azd = 300 + dAz * (1 - wN)
            el = min(max(se, 0.1396), 0.52) + (0.24 - min(max(se, 0.1396), 0.52)) * wN
        }
        let az = azd * 0.0174533
        let Lh = SIMD2<Float>(cos(az), -sin(az))
        var sun = mix3(SIMD3(1, 0.86, 0.70), SIMD3(1, 0.95, 0.90), ss(0.25, 0.8, el))
        var sky = SIMD3<Float>(0.84, 0.93, 1.10)
        var bright: Float = 1
        if live {
            let se = u.sun.x
            let tint = mix3(SIMD3(1, 0.76, 0.52), SIMD3(1, 0.93, 0.84), ss(0.06, 0.5, se))
            sun = mix3(tint, SIMD3(1, 0.72, 0.45), wN)
            sky = mix3(sky, SIMD3(0.50, 0.58, 0.80), wN)
            let day = 0.65 + 0.35 * ss(-0.07, 0.07, se)
            bright = day + (0.5 - day) * wN
        }
        func lin(_ c: Float) -> Float { c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878) }
        let sandY = 0.2126 * lin(u.colorB.x) + 0.7152 * lin(u.colorB.y) + 0.0722 * lin(u.colorB.z)
        bright *= min(max(pow(0.42 / max(sandY, 1e-3), 0.45), 0.85), 2.1)
        let sel = sin(el), cel = cos(el)
        return (simd_float4(Lh.x, Lh.y, sel / cel, sel), simd_float4(sun.x, sun.y, sun.z, bright),
                simd_float4(sky.x, sky.y, sky.z, 0.62 / (0.785 * sel)), simd_float4(cel, el, wN, 0))
    }

    // MARK: per-renderer state

    /// The garden's state for one configuration: the last composition and this one as one
    /// polyline, the grid, and a few textures to upload into in turn (frames in flight read
    /// the others).
    final class State {
        var gi = Int.min, phase: Float = -1
        var garden: Garden?
        var plans: [Int: (pts: [SIMD2<Float>], down: [Bool])] = [:]
        var data: [Float]
        var verts: [Float] = []                         // (x, y, s, pen) per vertex, pen: bit 0 = the
                                                        // segment from it is raked, bit 1 = the one into it
        var vertCount = 0, inserted = 0, start = 0      // `start`: this composition's first vertex
        var time: [Float] = []                          // drive time to each vertex of this composition
        var heading: [Double] = [], headingInt: [Double] = []   // see rebuild
        var gridN = SIMD2<Int>(1, 1), origin = SIMD2<Float>(0, 0), cell: Float = 2
        var hw: Float = 4.5, solid: Float = 3.5
        var rowVer: [Int], ver = 1
        var texs: [(MTLTexture, [Int])] = []
        var current = -1
        var shadowKey = SIMD3<Float>(9, 9, 9), shadowRes: Float = 0.5, shadowNX = 1

        /// Bakes the stones' shadows (a march toward the light, soft with distance) and the
        /// gravel's contact darkening round them (negative near a stone: the shader looks for
        /// stones and moss only there), for the light (Lh, tan el), on a grid of
        /// samples ~0.5 cm apart over the bed. Again only when the light has moved ~½°.
        func bakeShadows(Lh: SIMD2<Float>, tanEl: Float) {
            let key = SIMD3(atan2(Lh.y, Lh.x), atan(tanEl), 0)
            if abs(key.x - shadowKey.x) < 0.008 && abs(key.y - shadowKey.y) < 0.005 { return }
            shadowKey = key
            let G = garden!
            let bx = Float(G.bx), by = Float(G.by)
            let cap = SandGarden.shadowRows * 4096 / 2
            shadowRes = max(0.5, (4 * bx * by / Float(cap)).squareRoot() * 1.02)
            let nx = Int(ceil(2 * bx / shadowRes)) + 1, ny = Int(ceil(2 * by / shadowRes)) + 1
            shadowNX = nx
            let stones = Array(G.stones.prefix(6))
            data.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress! + SandGarden.shadowRow * 4096
                for j in 0..<ny {
                    for i in 0..<nx {
                        let p = SIMD2(-bx + Float(i) * shadowRes, -by + Float(j) * shadowRes)
                        var vis: Float = 1, ao: Float = 1, near = false
                        for s in stones {
                            // near enough that the pixel's ray may meet the stone (it leans out from
                            // the screen's centre by up to |p|·h/(Hc − h), Hc ≥ 300) or its moss
                            let reach = Float(s.bound) + max(Float(s.moss), simd_length(p) * Float(s.h) / (300 - Float(s.h))) + 1.5
                            if simd_length(p - SIMD2<Float>(s.c)) < reach { near = true }
                            let ext = Float(s.bound), tmax = Float(s.h) / tanEl
                            let v = p - SIMD2<Float>(s.c)
                            let along = -simd_dot(v, Lh), pr = abs(v.x * Lh.y - v.y * Lh.x)
                            let dd = simd_length(v)
                            if dd > ext * 0.6 { ao *= 1 - 0.45 * exp(-max(dd - ext * 0.85, 0) * 0.45) }
                            if along < -ext || along > tmax + ext || pr > ext { continue }
                            let t0 = max(along - ext, 0), t1 = min(along + ext, tmax)
                            for k in 0..<10 {
                                let tt = t0 + (t1 - t0) * (Float(k) + 0.5) / 10
                                let hh = s.height(p + Lh * tt)
                                let pn = 0.2 + 0.04 * tt
                                let x = min(max((tt * tanEl - hh + pn) / (2 * pn), 0), 1)
                                vis = min(vis, x * x * (3 - 2 * x))
                            }
                        }
                        let k = j * nx + i
                        base[k * 2] = vis; base[k * 2 + 1] = near ? -ao : ao
                    }
                }
            }
            ver += 1
            for r in SandGarden.shadowRow..<(SandGarden.shadowRow + SandGarden.shadowRows) { rowVer[r] = ver }
        }

        init() {
            data = [Float](repeating: 0, count: SandGarden.texW * SandGarden.texH * 4)
            rowVer = [Int](repeating: 1, count: SandGarden.texH)
        }

        func plan(_ g: Int, menu: Int) -> (pts: [SIMD2<Float>], down: [Bool]) {
            if let p = plans[g] { return p }
            let G = garden!
            // where the cart finished the composition before (its end doesn't depend on its start)
            let prevEnd: SIMD2<Double>? = {
                if let p = plans[g - 1], let l = p.pts.last { return SIMD2<Double>(l) }
                return SandGarden.plan(g - 1, menu: menu, garden: G, from: nil).pts.last
            }()
            let t = SandGarden.trace(SandGarden.plan(g, menu: menu, garden: G, from: prevEnd))
            plans[g] = t
            return t
        }

        func rebuild(gi: Int, menu: Int) {
            let a = plan(gi - 1, menu: menu), b = plan(gi, menu: menu)
            plans = plans.filter { $0.key >= gi - 1 }
            let G = garden!
            (cell, gridN) = SandGarden.grid(bx: G.bx, by: G.by)
            origin = SIMD2(Float(-G.bx), Float(-G.by))
            data.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                (base + SandGarden.countRow * 4096).update(repeating: 0, count: (SandGarden.stoneRow - SandGarden.countRow) * 4096)
            }
            verts = [Float](repeating: 0, count: (a.pts.count + b.pts.count + 2) * 4)
            verts.withUnsafeMutableBufferPointer { vb in
                let base = vb.baseAddress!
                var v = 0, s: Float = 0
                var last = SIMD2<Float>(0, 0)
                func put(_ p: SIMD2<Float>, _ downIn: Bool, _ downOut: Bool) {
                    if v > 0 { s += simd_length(p - last) }
                    base[v * 4] = p.x; base[v * 4 + 1] = p.y; base[v * 4 + 2] = s
                    base[v * 4 + 3] = Float((downOut ? 1 : 0) + (downIn ? 2 : 0))
                    last = p; v += 1
                }
                let cap = SandGarden.maxVerts
                // the last composition (its first point is where the one before ended), then
                // this one, joined at the point where one ends and the next begins
                let na = min(a.pts.count, cap / 2)
                let skipA = a.pts.count - na
                for i in skipA..<a.pts.count {
                    let dIn = i > skipA && a.down[i]
                    let dOut = i + 1 < a.pts.count ? a.down[i + 1] : (b.down.count > 1 && b.down[1])
                    put(a.pts[i], dIn, dOut)
                }
                start = v - 1
                let nb = min(b.pts.count, cap - v + 1)
                for i in 1..<max(nb, 1) {
                    let dIn = b.down[i]
                    let dOut = i + 1 < b.pts.count ? b.down[i + 1] : false
                    put(b.pts[i], dIn, dOut)
                }
                vertCount = v
            }
            data.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                for (k, st) in G.stones.prefix(6).enumerated() {
                    let o = SandGarden.stoneRow * 4096 + k * 4
                    base[o] = Float(st.ang); base[o + 1] = Float(st.elong); base[o + 2] = Float(st.moss); base[o + 3] = Float(st.seed)
                    base[o + 32] = Float(st.r)
                }
            }
            // drive time: lifted runs go at 1.8×
            time = [0]
            time.reserveCapacity(vertCount - start)
            for i in (start + 1)..<max(vertCount, start + 1) {
                let p = vert(i), q = vert(i - 1)
                let l = simd_length(SIMD2(p.x - q.x, p.y - q.y))
                time.append(time.last! + l / (pen(i - 1) & 1 == 1 ? 1 : 1.8))
            }
            // the track's heading, unwound (each segment's turn from the last added on, so it
            // never wraps), and its running integral over s, for headings averaged along it
            heading = [Double](repeating: 0, count: max(vertCount, 1))
            headingInt = [Double](repeating: 0, count: max(vertCount, 1))
            var prev = SIMD2<Double>(1, 0)
            for k in 0..<max(vertCount - 1, 0) {
                let p = vert(k), q = vert(k + 1)
                var d = SIMD2<Double>(Double(q.x - p.x), Double(q.y - p.y))
                let l = simd_length(d)
                d = l > 1e-9 ? d / l : prev
                heading[k] = k == 0 ? atan2(d.y, d.x) : heading[k - 1] + atan2(prev.x * d.y - prev.y * d.x, simd_dot(prev, d))
                headingInt[k + 1] = headingInt[k] + heading[k] * Double(q.z - p.z)
                prev = d
            }
            if vertCount > 1 { heading[vertCount - 1] = heading[vertCount - 2] }
            inserted = 0
            // the last composition is all on the table already
            while inserted < start { insertIfRaked(inserted); inserted += 1 }
            self.gi = gi
            ver += 1
            for r in rowVer.indices { rowVer[r] = ver }
        }

        @inline(__always) func vert(_ i: Int) -> SIMD3<Float> {
            SIMD3(verts[i * 4], verts[i * 4 + 1], verts[i * 4 + 2])
        }
        @inline(__always) func pen(_ i: Int) -> Int { Int(verts[i * 4 + 3]) }

        /// Adds segment i (vertex i → i + 1), if raked, to every cell its footprint reaches. A
        /// cell the pass now covers solidly (every corner well inside it, on this segment or
        /// the few before it in the same pass) can never show anything older again: its list
        /// starts afresh with just those segments, so a pixel there finds its pass at once.
        func insertIfRaked(_ i: Int) {
            guard pen(i) & 1 == 1 else { return }
            let a = vert(i), b = vert(i + 1)
            let r = hw + 0.05, inv = 1 / cell
            let x0 = max(Int((min(a.x, b.x) - r - origin.x) * inv), 0), x1 = min(Int((max(a.x, b.x) + r - origin.x) * inv), gridN.x - 1)
            let y0 = max(Int((min(a.y, b.y) - r - origin.y) * inv), 0), y1 = min(Int((max(a.y, b.y) + r - origin.y) * inv), gridN.y - 1)
            if x0 > x1 || y0 > y1 { return }
            // the chain: this segment and the raked ones just before it, back ~2 cells
            var chain = [i]
            var back: Float = simd_length(SIMD2(b.x - a.x, b.y - a.y))
            while chain.count < 8, let f = chain.first, f >= 1, pen(f - 1) & 1 == 1, back < 2.5 * cell + 2 * hw {
                let p = vert(f - 1), q = vert(f)
                back += simd_length(SIMD2(q.x - p.x, q.y - p.y))
                chain.insert(f - 1, at: 0)
            }
            let segs = chain.map { (k: Int) -> (SIMD2<Float>, SIMD2<Float>) in
                let p = vert(k), q = vert(k + 1); return (SIMD2(p.x, p.y), SIMD2(q.x, q.y)) }
            let s2 = solid * solid
            func covered(_ c: SIMD2<Float>) -> Bool {
                var best: Float = .infinity, bh: Float = 0, bk = 0
                for (k, (p, q)) in segs.enumerated() {
                    let ba = q - p, pa = c - p
                    let l2 = simd_dot(ba, ba)
                    let h = l2 > 1e-10 ? simd_dot(pa, ba) / l2 : 0
                    let v = pa - ba * min(max(h, 0), 1)
                    let d2 = simd_dot(v, v)
                    if d2 < best { best = d2; bh = h; bk = k }
                }
                if best >= s2 { return false }
                if bk == 0 && bh <= 0 { return false }                 // off the chain's start
                if bk == segs.count - 1 && bh >= 1 { return false }    // past its end
                return true
            }
            let cRow = SandGarden.countRow * 4096, rRow = SandGarden.ringRow * 4096, K = SandGarden.ringK
            let n = gridN.x
            data.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                for cy in y0...y1 {
                    for cx in x0...x1 {
                        let c = cy * n + cx
                        guard c < SandGarden.maxCells else { continue }   // never past the rings
                        let o = origin + SIMD2(Float(cx), Float(cy)) * cell
                        let solidHere = covered(o) && covered(o + SIMD2(cell, 0)) && covered(o + SIMD2(0, cell))
                            && covered(o + SIMD2(cell, cell))
                        var cnt = Int(base[cRow + c])
                        let list = solidHere ? chain : [i]
                        if solidHere { cnt = 0 }
                        for k in list {
                            let e = c * K + cnt % K
                            let pa = vert(k), pb = vert(k + 1)
                            let o = rRow + e * 8
                            base[o] = pa.x; base[o + 1] = pa.y; base[o + 2] = pb.x; base[o + 3] = pb.y
                            base[o + 4] = pa.z; base[o + 5] = pb.z
                            base[o + 6] = Float((pen(k) & 2 == 0 ? 1 : 0) + (pen(k + 1) & 1 == 0 ? 2 : 0))
                            cnt += 1
                            rowVer[SandGarden.ringRow + (e >> 9)] = ver
                        }
                        base[cRow + c] = Float(cnt)
                    }
                }
            }
            rowVer[SandGarden.countRow] = ver
        }

        /// The texture to draw with: the next one in turn, brought up to date (or the current
        /// one again, when nothing changed).
        func texture(_ device: MTLDevice) -> MTLTexture? {
            if texs.isEmpty {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: SandGarden.texW,
                                                                 height: SandGarden.texH, mipmapped: false)
                d.usage = .shaderRead
                d.storageMode = device.hasUnifiedMemory ? .shared : .managed
                for _ in 0..<4 {
                    guard let t = device.makeTexture(descriptor: d) else { return nil }
                    texs.append((t, [Int](repeating: 0, count: SandGarden.texH)))
                }
            }
            if current >= 0 && texs[current].1 == rowVer { return texs[current].0 }
            current = (current + 1) % texs.count
            let (tex, have) = texs[current]
            func skip(_ r: Int) -> Bool { have[r] == rowVer[r] }
            data.withUnsafeBytes { raw in
                var r = 0
                while r < SandGarden.texH {
                    if skip(r) { r += 1; continue }
                    var e = r + 1
                    while e < SandGarden.texH && !skip(e) { e += 1 }
                    tex.replace(region: MTLRegionMake2D(0, r, SandGarden.texW, e - r), mipmapLevel: 0,
                                withBytes: raw.baseAddress! + r * 4096 * 4, bytesPerRow: SandGarden.texW * 16)
                    r = e
                }
            }
            texs[current].1 = rowVer
            return tex
        }

        /// ∫ heading ds from the track's start to s, looking for s's segment from vertex i.
        func headingIntegral(_ s: Double, near i: Int) -> Double {
            let (k, sc) = segment(s, near: i)
            return headingInt[k] + heading[k] * (sc - Double(vert(k).z))
        }
        /// The segment s lies on (looked for from vertex i), and s clamped to the track.
        func segment(_ s: Double, near i: Int) -> (Int, Double) {
            let n = max(vertCount - 1, 1)
            let sc = min(max(s, Double(vert(0).z)), Double(vert(vertCount - 1).z))
            var k = min(max(i, 0), n - 1)
            while k > 0 && Double(vert(k).z) > sc { k -= 1 }
            while k + 1 < n && Double(vert(k + 1).z) <= sc { k += 1 }
            return (k, sc)
        }
        /// The track's mean heading (unwound) over [s0, s1].
        func meanHeading(_ s0: Double, _ s1: Double, near i: Int) -> Double {
            let (k0, a) = segment(s0, near: i), (_, b) = segment(s1, near: i)
            if b - a < 1e-4 { return heading[k0] }
            return (headingIntegral(b, near: i) - headingIntegral(a, near: i)) / (b - a)
        }

        /// The headings (unwound angles) with the rake at vertex i + fraction f: the rake's,
        /// and the track's ahead (its mean over the next `tow` cm — where the body would sit
        /// on it; on a bend, the chord). The rake pivots on the end of the cart's tow pole and
        /// its tines, in the gravel, keep it along the track: the bar stays square across the
        /// furrows it draws, so they start right at its tines; round a bend it turns with the
        /// track's mean over ~2.4 cm (the furrows' round join), but at each end of a stroke
        /// it holds the stroke's own heading (the cut there: SandGarden's pass ends are square
        /// to their segment). Lifted, it hangs back along the cart, swinging round from the
        /// heading it lifted with over ~4 cm, and round to the one it drops with over the ~4 cm
        /// before. All in unwound angles, so nothing ever flips round.
        func headings(_ i: Int, _ f: Float, tow: Float) -> (rake: Double, ahead: Double) {
            func ss(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
            let a = vert(i), b = vert(min(i + 1, vertCount - 1))
            let s = Double(a.z + (b.z - a.z) * f)
            let ahead = meanHeading(s, s + Double(tow), near: i)
            if pen(i) & 1 == 1 {
                var w = 1.2
                var j = i
                while j > 0 && pen(j - 1) & 1 == 1 && s - Double(vert(j).z) < w { j -= 1 }
                if j == 0 || pen(j - 1) & 1 == 0 { w = min(w, s - Double(vert(j).z)) }
                var k = i + 1
                while k < vertCount - 1 && pen(k) & 1 == 1 && Double(vert(k).z) - s < w { k += 1 }
                if k >= vertCount - 1 || pen(k) & 1 == 0 { w = min(w, Double(vert(k).z) - s) }
                return (w > 1e-3 ? meanHeading(s - w, s + w, near: i) : heading[i], ahead)
            }
            var r = ahead
            var j = i
            while j > 0 && pen(j - 1) & 1 == 0 && s - Double(vert(j).z) < 4 { j -= 1 }
            if j > 0 && pen(j - 1) & 1 == 1 { r = heading[j - 1] + (r - heading[j - 1]) * ss((s - Double(vert(j).z)) / 4) }
            var k = i + 1
            while k < vertCount - 1 && pen(k) & 1 == 0 && Double(vert(k).z) - s < 4 { k += 1 }
            if k < vertCount - 1 && pen(k) & 1 == 1 { r += (heading[k] - r) * ss(1 - (Double(vert(k).z) - s) / 4) }
            return (r, ahead)
        }
    }

    /// Per renderer: a State per Zen Garden configuration on screen (two during a crossfade).
    final class Cache {
        private let lock = NSLock()
        private var states: [[Int]: State] = [:]
        private var order: [[Int]] = []

        /// Works out this frame's composition and cart from u.p0 (speed, pattern, rake width),
        /// u.resolution and u.time at the wall-clock instant `wall`; fills u.scene; returns the
        /// data texture.
        func prepare(_ u: inout FXUniforms, wall: Date = Date(), device: MTLDevice) -> MTLTexture? {
            // (a NaN param — never from the app, but a hand-made file — would carry into the plan)
            let speed = u.p0.x.isNaN ? 0 : max(u.p0.x, 0)
            let menu = Int(saturating: u.p0.y + 0.5, .down)
            let groove = u.p0.z.isNaN ? 1 : min(max(u.p0.z, 0.6), 1.6)
            let aspect = u.resolution.y > 0 ? u.resolution.x / u.resolution.y : 1.6
            let t = u.time
            let epoch = wall.timeIntervalSince1970
            // Which composition, and how far along: a global index from the hour the t origin
            // falls on — epoch hours, rounded to the nearest, so it holds steady in any time zone
            // (+5:45 too) and runs on across the hourly wrap (the outgoing frame at t ≥ 3600 with
            // the new hour finds the same index) — and never repeats.
            let hourIx = Int(saturating: (epoch - Double(t)) / 3600, .toNearestOrAwayFromZero)
            var gi: Int, phase: Float
            var n = 0                                       // compositions an hour (0: still)
            if speed < 0.02 {
                // still: today's garden, finished (local days, counted on: no jump at New Year)
                let local = epoch + Double(TimeZone.current.secondsFromGMT(for: wall))
                gi = Int(saturating: local / 86400, .down) &* 5 &+ 1; phase = 0.9999
            } else {
                n = min(max(Int(saturating: SandGarden.compositionsPerHour * speed, .toNearestOrAwayFromZero), 1), 15)
                let tp = t * Float(n) / 3600
                gi = hourIx &* n &+ Int(saturating: tp, .down); phase = tp - tp.rounded(.down)
            }
            // (speeds that run the same compositions share a state; two that don't — both
            // chains of a crossfade — each keep their own rather than rebuilding every frame)
            let key = [menu, Int(groove.bitPattern), Int(saturating: aspect * 100, .toNearestOrAwayFromZero), n]
            lock.lock(); defer { lock.unlock() }
            let st: State
            if let s = states[key] { st = s; order.removeAll { $0 == key } }
            else {
                st = State()
                st.garden = Garden(aspect: aspect, groove: groove)
                st.hw = Float(0.5 * st.garden!.wr) * 1.14 + 0.1        // the footprint and its feather
                st.solid = Float(0.5 * st.garden!.wr) * 0.94
                states[key] = st
                if order.count >= 3 { states[order.removeFirst()] = nil }
            }
            order.append(key)
            if st.gi != gi || phase < st.phase - 1e-5 { st.rebuild(gi: gi, menu: menu) }
            st.phase = phase
            guard st.vertCount > st.start + 1 else { return nil }
            // the rake: drive time → vertex
            let T = st.time.last! * phase
            var lo = 0, hi = st.time.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if st.time[m] <= T { lo = m } else { hi = m } }
            let i = st.start + lo
            let f = st.time[hi] > st.time[lo] ? (T - st.time[lo]) / (st.time[hi] - st.time[lo]) : 0
            if st.inserted < i {
                st.ver += 1                                     // a new version for the rows these touch
                while st.inserted < i { st.insertIfRaked(st.inserted); st.inserted += 1 }
            }
            let h = st.vert(i), nx = st.vert(min(i + 1, st.vertCount - 1))
            let rake = SIMD2(h.x, h.y) + (SIMD2(nx.x, nx.y) - SIMD2(h.x, h.y)) * f
            let sRake = h.z + (nx.z - h.z) * f
            let down = st.pen(i) & 1 == 1 && i + 1 < st.vertCount
            let G = st.garden!
            let cs = SandGarden.cartScale(Float(G.wr)), tow = SandGarden.tow * cs
            func ss(_ x: Float) -> Float { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
            // Room for the body straight on ahead of the rake at p, heading d: to the frame
            // along the heading, past its nose, and from the stones (0…1).
            func room(_ p: SIMD2<Float>, _ d: SIMD2<Float>) -> Float {
                let ext = p + d * tow, bx = Float(G.bx), by = Float(G.by)
                var tf: Float = .infinity
                if abs(d.x) > 1e-4 { tf = min(tf, ((d.x > 0 ? bx : -bx) - ext.x) / d.x) }
                if abs(d.y) > 1e-4 { tf = min(tf, ((d.y > 0 ? by : -by) - ext.y) / d.y) }
                var r = ss((tf - 3.2 * cs) / 4)
                for s in G.stones { r *= ss((simd_length(ext - SIMD2<Float>(s.c)) - Float(s.excl) - 4 * cs) / 3) }
                return r
            }
            // How far back the rake lifted, and how far on it drops (each looked for only so
            // far), and the room the body had there
            var sinceLift: Float = .infinity, untilDrop: Float = .infinity, roomL: Float = 0, roomD: Float = 0
            if !down {
                var j = i
                while j > 0 && st.pen(j - 1) & 1 == 0 && sRake - st.vert(j).z < 12 { j -= 1 }
                if j > 0 && st.pen(j - 1) & 1 == 1 {
                    let v = st.vert(j)
                    sinceLift = sRake - v.z
                    roomL = room(SIMD2(v.x, v.y), SIMD2(Float(cos(st.heading[j - 1])), Float(sin(st.heading[j - 1]))))
                }
                var k = i + 1
                while k < st.vertCount - 1 && st.pen(k) & 1 == 0 && st.vert(k).z - sRake < 12 { k += 1 }
                if k < st.vertCount - 1 && st.pen(k) & 1 == 1 {
                    let v = st.vert(k)
                    untilDrop = max(v.z - sRake, 0)
                    roomD = room(SIMD2(v.x, v.y), SIMD2(Float(cos(st.heading[k])), Float(sin(st.heading[k]))))
                }
            }
            // the rake rises over ~1.5 cm once it's lifted, and comes down over the ~1.5 cm
            // before it drops (its tines touch just where the furrows begin)
            let lift: Float = down ? 0 : min(1, sinceLift / 1.5, untilDrop / 1.5)
            // The cart: its body `tow` cm ahead of the rake. Raking, it runs straight on ahead
            // of it (the rake trails behind on its pole, square to its furrows) — where the
            // bed has room ahead for it, before the frame or a stone; otherwise, and once the
            // rake is up (easing over ~6 cm), its wheels keep to the track (its heading the
            // track's over the next `tow` cm: on a bend, the chord). While raking it never
            // turns more than ~75° from the rake — the pole can't swing round further — and that
            // eases over ~12 cm either side of a lift. Rigid, rolling, never pushed aside;
            // unwound angles, so it never flips round.
            let hd = st.headings(i, f, tow: tow)
            let rakeDir = SIMD2<Float>(Float(cos(hd.rake)), Float(sin(hd.rake)))
            let align: Float = down ? room(rake, rakeDir)
                : max((1 - ss(sinceLift / 6)) * roomL, (1 - ss(untilDrop / 6)) * roomD)
            let held: Float = down ? 1 : max(1 - ss(sinceLift / 12), 1 - ss(untilDrop / 12))
            let lim = 1.31 + (Double.pi - 1.31) * Double(1 - held)
            let turn = min(max((hd.ahead - hd.rake) * Double(1 - align), -lim), lim)
            let dir = SIMD2<Float>(Float(cos(hd.rake + turn)), Float(sin(hd.rake + turn)))
            let body = rake + dir * tow
            let L = SandGarden.light(u)
            st.bakeShadows(Lh: SIMD2(L.0.x, L.0.y), tanEl: L.0.z)
            withUnsafeMutablePointer(to: &u.scene) {
                $0.withMemoryRebound(to: simd_float4.self, capacity: 16) { p in
                    p[0] = simd_float4(rake.x, rake.y, rakeDir.x, rakeDir.y)
                    p[1] = simd_float4(h.x, h.y, h.z, sRake)
                    p[2] = simd_float4(st.vert(st.start).z, down ? 1 : 0, 1, lift)
                    p[3] = simd_float4(st.origin.x, st.origin.y, st.cell, Float(st.gridN.x))
                    p[4] = simd_float4(Float(G.bx), Float(G.by), Float(G.wr), Float(min(G.stones.count, 6)))
                    p[5] = simd_float4(body.x, body.y, dir.x, dir.y)
                    // the stones: (x, y, the radius they fit in, height); their shapes are in the texture
                    for (k, st) in G.stones.prefix(6).enumerated() {
                        p[6 + k] = simd_float4(Float(st.c.x), Float(st.c.y), Float(st.bound), Float(st.h))
                    }
                    p[12] = L.0; p[13] = L.1; p[14] = L.2
                    p[15] = simd_float4(L.3.x, st.shadowRes, Float(st.shadowNX), Float(st.gridN.y))
                }
            }
            return st.texture(device)
        }
    }
}
