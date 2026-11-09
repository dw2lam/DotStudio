//  Studio2.swift — Sand Garden (shader id 68). See SceneCatalog.swift.
//  Shader: Shared/Scenes/Studio2_cases.h (+ helpers in Studio2_funcs.h).
//
//  A chrome ball ploughs theta-rho patterns through a round kinetic sand table, seen from
//  above. Stateless — a pure function of the time, clock and date — so every display and
//  the wallpaper show the same pattern at the same moment, and it never repeats hourly.
//  Which sweeps are on the table, their designs and where the ball is are worked out once a
//  frame here (SandGarden.fill, called from MetalRenderer.fillLiveSky) and handed to the shader
//  in u.scene, rather than by every pixel. Follow the Sun takes the light from the real sun
//  (u.sun / u.sky, as Ocean Horizon does).

import Foundation
import simd

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the slot-2 line of EffectKind.
    static let studio2: [EffectKind: SceneSpec] = [
        .sandGarden: SceneSpec(
            name: "Sand Garden",
            blurb: "A chrome ball draws slow patterns through a kinetic sand table under a low, warm light.",
            shaderID: 68,
            // Packed in order: p0 = (speed, pattern, groove, framing), p1 = (relief, angle, height, live).
            params: [ParamSpec("speed", "Speed", 0, 3, def: 1),
                     ParamSpec(menu: "pattern", "Pattern", ["Surprise", "Rosette", "Twist", "Petals", "Spiral"], def: 0),
                     ParamSpec("groove", "Groove Width", 0.5, 2, def: 1),
                     ParamSpec(menu: "framing", "Framing", ["Fill", "Table"], def: 0),
                     ParamSpec("relief", "Relief", 0, 1, def: 0.6),
                     ParamSpec("angle", "Light Angle", 0, 360, def: 215),
                     ParamSpec("height", "Light Height", 5, 60, def: 18),
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true)],
            colorA: RGBA(0.28, 0.17, 0.10), colorB: RGBA(0.91, 0.86, 0.77),
            colorALabel: "Wood", colorBLabel: "Sand"),
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
            scene("Sand Garden", ["framing": 0, "pattern": 0, "angle": 215, "height": 18],
                  a: RGBA(0.28, 0.17, 0.10), b: RGBA(0.91, 0.86, 0.77)),
            // Basalt sand on a dark table: evening-friendly, the chrome ball the only highlight.
            scene("Black Sand", ["framing": 1, "pattern": 1, "angle": 140, "height": 16, "relief": 0.75],
                  a: RGBA(0.13, 0.095, 0.075), b: RGBA(0.30, 0.29, 0.28)),
        ]
    }
}

/// Sand Garden's per-frame data: the sweep in progress, the two before it and the ball, as
/// the shader's u.scene (see Studio2_funcs.h for the model: each sweep a spiral of lobed turns,
/// ρ = C(u) + A(u)·w(ψ), with C and A piecewise linear in the turn count u). Everything here
/// depends only on the uniforms, so it is done once a frame instead of once a pixel.
enum SandGarden {
    static let tau: Float = 6.28318531
    static let itau: Float = 0.159154943

    struct Geo {
        var g, pt, ipt, rs, R0, Ns, cpP: Float
        init(groove: Float) {
            g = min(max(groove, 0.5), 2)
            pt = 1.67 * g; ipt = 1 / pt; rs = 0.5 * pt
            R0 = 40 - 1.1 - 1.3 * g
            Ns = max(((2 * (R0 - rs) * ipt).rounded()) * 0.5, 3)
            cpP = (R0 - rs) / (Ns - SandGarden.itau)
        }
    }

    struct Sweep {
        var chi: Float = 1, k: Float = 1, a: Float = 0, X: Float = 0
        var wave = 0, q = 1
        var phi0: Float = 0
        var cp: Float = 0, C0: Float = 0, Cs: Float = 0, Cg: Float = 0
        var ug: Float = 0, N: Float = 0, fC: Float = 0
        var thf: Float = 0, rej: Float = 0, w: Float = 1
        var Th: Float { SandGarden.tau * (1 + N) }
    }

    static func hash(_ v: UInt32) -> UInt32 {
        var x = v
        x ^= x >> 16; x &*= 0x7feb352d; x ^= x >> 15; x &*= 0x846ca68b; x ^= x >> 16
        return x
    }
    static func sweepHash(_ g: Int32) -> UInt32 { hash(UInt32(bitPattern: g) &* 0x9E37_79B9 &+ 0x51ED27) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
    private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    /// The design sweep g draws. Pattern menu: 0 Surprise, 1 Rosette, 2 Twist, 3 Petals,
    /// 4 Spiral, 5 Star. Even sweeps run outward, odd ones inward.
    static func params(_ g: Int32, _ ha: UInt32, _ hp: UInt32, menu: Int, _ G: Geo) -> Sweep {
        var s = Sweep()
        s.chi = g & 1 == 0 ? 1 : -1
        var hb = (ha ^ (ha >> 13)) &* 0x2C1B_3C6D                     // a second word
        hb ^= hb >> 16
        let k8: Float = 1 / 256
        let h0 = Float(ha & 0xff) * k8, h1 = Float((ha >> 8) & 0xff) * k8, h5 = Float(ha >> 16) / 65536
        let h2 = Float(hb & 0xff) * k8, h3 = Float((hb >> 8) & 0xff) * k8, h4 = Float((hb >> 16) & 0xff) * k8
        let h6 = Float(hb >> 24) * k8
        // 0 rosette, 1 twist, 2 petals, 3 spiral, 4 star
        var type = menu - 1
        if menu <= 0 || menu > 5 {
            // Surprise: stars, rosettes, galaxies and interlaced petals, and now and then a
            // plain spiral "erase" as a palate cleanser (never twice running)
            let erase = h0 < 0.10 && Float(hp & 0xff) * k8 >= 0.10
            type = erase ? 3 : (h1 < 0.27 ? 4 : (h1 < 0.53 ? 0 : (h1 < 0.77 ? 1 : 2)))
        }
        s.phi0 = h5 * tau
        var M: Float = 1, dens: Float = 1.1    // the lobes' steepest outward lean; tip spacing in pitches
        switch type {
        case 0:                              // rosette: 5…9 round lobes, sometimes petal-shaped
            s.k = 5 + (h2 * 4.999).rounded(.down)
            s.a = mix(0.17, 0.27, h3) * (s.k > 7.5 ? 0.85 : 1)
            s.wave = h6 < 0.4 ? 2 : 0
        case 4:                              // star: 3…7 sharp points
            s.k = 3 + (h2 * 4.999).rounded(.down)
            s.a = mix(0.36, 0.45, h3) - 0.02 * (s.k - 3)
            s.wave = 1
        case 1:                              // twist: 1…4 lobes leaning into spiral arms (1: a nautilus)
            s.k = 1 + (h2 * 3.999).rounded(.down)
            s.a = s.k < 1.5 ? mix(0.34, 0.42, h3) : mix(0.2, 0.3, h3)
            // turns stay in order (dρ/du > 0) while a·√(1 + X²) < 1: keep it ≤ ~0.55
            let Xm = max((0.65 / s.a) * (0.65 / s.a) - 1, 0).squareRoot()
            s.X = (h6 > 0.5 ? 1 : -1) * mix(0.6, 0.8, h4) * Xm
            M = (1 + s.X * s.X).squareRoot()
        case 2:                              // petals: half-integer lobes, so alternate turns interlace
            s.k = 1.5 + (h2 * 2.999).rounded(.down)
            s.a = mix(0.2, 0.3, h3)
            s.q = 2
            dens = 0.9                       // two families: keep the gaps between them small
        default: break                       // the plain spiral
        }
        // The centre line grows cp a turn (lobe tips — and the twist's lean — at ≤ dens
        // pitches); the lobes rise once one spans ~4 grooves (C = Cs: no tangle of tight tips
        // round the hub) and their tips reach the rim at C = Cg; the fill then lifts the
        // hollows by 2·fC a turn (≤ 1.1 pitches), the turn count staying ≡ Ns (mod 1) so that
        // every sweep ends at the same point on the rim.
        s.cp = dens * G.pt / (1 + s.a * M)
        s.C0 = G.rs - s.cp * itau
        s.Cs = 0.36 * s.k * G.g + 1.4 * G.g
        s.Cg = (G.R0 + s.a * s.Cs) / (1 + s.a)
        s.ug = (s.Cg - s.C0) * (1 + s.a * M) * G.ipt / dens
        let Ag = s.a * (s.Cg - s.Cs)
        if s.a <= 0 {                        // the plain spiral: Ns turns at the plain pitch
            s.N = G.Ns
            s.cp = G.cpP
            s.C0 = G.rs - s.cp * itau
            s.Cs = G.R0; s.Cg = G.R0
            s.ug = s.N
        } else {
            let nf = Ag * (2 / 1.1) * G.ipt
            s.N = G.Ns + (s.ug + nf - G.Ns - 0.01).rounded(.up)
        }
        s.fC = s.N > s.ug + 1e-3 ? Ag / (s.N - s.ug) : 0
        s.thf = s.chi > 0 ? s.Th : 0
        return s
    }

    /// Centre line and amplitude at u ≥ 0 turns past the hub loop: (C, dC/du, A, dA/du).
    static func env(_ s: Sweep, _ G: Geo, _ u: Float) -> SIMD4<Float> {
        if u >= s.ug {
            let f = u - s.ug
            return SIMD4(s.Cg + s.fC * f, s.fC, s.a * (s.Cg - s.Cs) - s.fC * f, -s.fC)
        }
        let x = tau * u
        let C: Float, dC: Float
        if x >= 2 { C = s.C0 + s.cp * u; dC = s.cp } else { C = G.rs + s.cp * itau * x * x * 0.25; dC = s.cp * x * 0.5 }
        return C > s.Cs ? SIMD4(C, dC, s.a * (C - s.Cs), s.a * dC) : SIMD4(C, dC, 0, 0)
    }
    static func wave(_ wave: Int, _ sn: Float, _ c: Float) -> SIMD2<Float> {
        if wave == 1 { let p = 1 + sn; return SIMD2(0.5 * p * p - 1, p * c) }
        if wave == 2 { let p = 1 - sn; return SIMD2(1 - 0.5 * p * p, p * c) }
        return SIMD2(sn, c)
    }
    static func twist(_ s: Sweep, _ r: Float) -> SIMD2<Float> {
        let rc = min(max(r, s.Cs), s.Cg)
        return SIMD2(s.X * Foundation.log(rc / s.Cg), (r > s.Cs && r < s.Cg) ? s.X / r : 0)
    }

    /// θ a fraction f of the way along the sweep's path by arc length: the length per turn,
    /// 2π·√(C² + κA²), taken as piecewise linear between the envelope's breakpoints, so the arc
    /// length is piecewise quadratic and inverts in closed form. The ball runs at a steady speed
    /// on average over each turn (quicker along the lobes' flanks, slower round the tips).
    static func thAt(_ s: Sweep, _ G: Geo, _ f: Float) -> Float {
        let kap: Float = s.wave == 0 ? 0.5 + 0.5 * s.k * s.k : 0.594 + 0.625 * s.k * s.k
        let us = min(max((s.Cs - s.C0) / s.cp, 0), s.ug)
        let Ag = s.a * (s.Cg - s.Cs)
        let Lh = tau * G.rs, Ls = tau * min(s.Cs, s.Cg)
        let Lg = tau * (s.Cg * s.Cg + kap * Ag * Ag).squareRoot(), LN = tau * G.R0
        let S1 = Lh + us * 0.5 * (Lh + Ls)
        let S2 = S1 + (s.ug - us) * 0.5 * (Ls + Lg)
        let S3 = S2 + (s.N - s.ug) * 0.5 * (Lg + LN)
        let st = f * S3
        if st <= Lh { return tau * st / Lh }
        let (S0, u0, La, Lb, du): (Float, Float, Float, Float, Float) =
            st <= S1 ? (Lh, 0, Lh, Ls, us) : (st <= S2 ? (S1, us, Ls, Lg, s.ug - us) : (S2, s.ug, Lg, LN, s.N - s.ug))
        let ds = st - S0, m = (Lb - La) / max(du, 1e-4)
        let v = 2 * ds / (La + max(La * La + 2 * m * ds, 0).squareRoot())
        return tau * (1 + u0 + min(v, du))
    }

    /// Track position at θ, and the unit tangent along increasing θ. (With a twist the radius
    /// is implicit — ρ = C + A·w(ψ + T(ρ)) — and found by a few fixed-point steps.)
    static func pos(_ s: Sweep, _ G: Geo, _ th: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        let u = th * itau - 1
        var rho = G.rs, rt: Float = 0
        if u >= 0 {
            let m = (th * itau).rounded(.down)
            let pb = s.k * (th - tau * m) + s.phi0 + tau * fract(s.k * m)
            let e = env(s, G, u)
            rho = e.x
            var Dr: Float = 1, ww = SIMD2<Float>(0, 1)
            for _ in 0..<(s.X != 0 ? 4 : 1) {
                let tw = s.X != 0 ? twist(s, rho) : .zero
                ww = wave(s.wave, Foundation.sin(pb + tw.x), Foundation.cos(pb + tw.x))
                rho = e.x + e.z * ww.x
                Dr = 1 - e.z * ww.y * tw.y
            }
            rt = ((e.y + e.w * ww.x) * itau + e.z * ww.y * s.k) / Dr
        }
        let ph = s.chi * th
        let er = SIMD2<Float>(Foundation.cos(ph), Foundation.sin(ph)), ep = SIMD2<Float>(-er.y, er.x)
        return (rho * er, simd_normalize(rt * er + s.chi * rho * ep))
    }

    /// Nothing of a sweep in progress reaches past its front turn's tips (out) or inside its
    /// hollows (in) — they only grow with u — plus the footprint's furthest radial reach.
    static func setReject(_ s: inout Sweep, _ G: Geo) {
        let uf = s.thf * itau - 1
        let e = env(s, G, max(uf, 0))
        let reachM = (1.3 * G.g) * (1.1 + s.a * (s.k + 0.5 + abs(s.X)) * (s.wave == 0 ? 1.82 : 2.37)) + 0.1
        s.rej = s.chi > 0 ? (uf < s.N ? e.x + e.z + reachM : 1e9) : (uf < s.N ? e.x - e.z - reachM : -1e9)
    }

    /// Fills u.scene from u.p0 (speed, pattern, groove), u.clock, u.date and u.time:
    /// scene[4i…4i+3] = sweep i (0 in progress, 1 and 2 finished) as (chi, k, a, X),
    /// (wave + 4·(q − 1), φ0, cp, Cs), (Cg, ug, N, fC), (thf, rej, w, C0); scene[12] = the ball
    /// (position, tangent).
    static func fill(_ u: inout FXUniforms) {
        let speed = max(u.p0.x, 0)
        let menu = Int((u.p0.y + 0.5).rounded(.down))
        let G = Geo(groove: u.p0.z)
        let t = u.time
        // Which sweep, and how far along: a global index from the date and the hour the t
        // origin falls in, so the sequence runs on across the hourly wrap (the outgoing frame
        // at t ≥ 3600 with the new hour finds the same index) and never repeats hourly. Speed
        // sets sweeps per hour (2 at 1×: half an hour a sweep, dividing the hour).
        let day = Int32(u.date.x) * 366 + Int32(u.date.w)
        let hourIx = day * 24 + Int32(((u.clock.x * 3600 - t) / 3600 + 0.25).rounded(.down))
        var gi: Int32, phase: Float
        if speed < 0.02 {
            gi = day * 72 + 1; phase = 0.62
        } else if speed * 2 >= 0.5 {
            let n = Int32(min(max((speed * 2).rounded(), 1), 6))
            let tp = t * Float(n) / 3600
            gi = hourIx * n + Int32(tp.rounded(.down)); phase = fract(tp)
        } else {
            let m = Int32(min(max((1 / (2 * speed)).rounded(), 2), 24))
            let hh = hourIx + Int32((t / 3600).rounded(.down))
            gi = hh / m
            phase = (Float(hh - gi * m) + fract(t / 3600)) / Float(m)
        }
        let hNow = sweepHash(gi), hPrev = sweepHash(gi - 1), hOld = sweepHash(gi - 2)
        var s0 = params(gi, hNow, hPrev, menu: menu, G)
        s0.thf = thAt(s0, G, s0.chi > 0 ? phase : 1 - phase)        // the ball: out on even sweeps
        setReject(&s0, G)
        var s1 = params(gi - 1, hPrev, hOld, menu: menu, G)
        setReject(&s1, G)
        var s2 = params(gi - 2, hOld, sweepHash(gi - 3), menu: menu, G)
        s2.w = 1 - smoothstep(0.45, 1, phase)                         // the sweep before last settles flat
        setReject(&s2, G)
        let (pb, tb) = pos(s0, G, s0.thf)
        withUnsafeMutablePointer(to: &u.scene) {
            $0.withMemoryRebound(to: simd_float4.self, capacity: 16) { p in
                for (i, s) in [s0, s1, s2].enumerated() {
                    p[4 * i] = simd_float4(s.chi, s.k, s.a, s.X)
                    p[4 * i + 1] = simd_float4(Float(s.wave + 4 * (s.q - 1)), s.phi0, s.cp, s.Cs)
                    p[4 * i + 2] = simd_float4(s.Cg, s.ug, s.N, s.fC)
                    p[4 * i + 3] = simd_float4(s.thf, s.rej, s.w, s.C0)
                }
                p[12] = simd_float4(pb.x, pb.y, tb.x, tb.y)
            }
        }
    }
}
