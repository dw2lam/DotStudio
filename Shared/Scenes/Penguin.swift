//  Penguin.swift — the Penguin pack (shader id 80). See SceneCatalog.swift. Tagged Retro.
//
//  Penguin (80)  a little penguin living on an LED panel: a chubby, round penguin of our own
//               (blue back and head, a white bib, big eyes, a small yellow bill, rosy cheeks and a
//               tuft on top) drawn procedurally and shown as round LED dots with a soft bloom
//               (LED Dots), rounded cells (Pixels) or tiny glyphs (Glyphs), at 24 fps.
//               It breathes and blinks, waddles across the panel and turns around, looks about,
//               waves, belly-slides, hops a little dance, shakes itself off, and now and then
//               sits down and dozes (Zz). The screen's bottom edge is the floor.
//               Backdrop (dimmer, in the same cells): Snowy Night — drifts, two pines, an igloo
//               it passes behind or dozes beside, distant peaks, a crescent moon, stars — or Day
//               (a pale sky and the sun); None. Snow comes and goes.
//               Follow the Clock: Night or Day by the local time; it dozes more at night and the
//               panel dims.
//               Custom character: the user's own image (Inspector, the same section as Bounce's
//               logo: EffectInstance.logoKind / logoFile; trimmed to what shows, as tall as the
//               penguin, each cell an average of its area) becomes the dot-matrix character and
//               does the same things as a whole sprite — bobbing, squashing, waddling, hopping.
//  (The effect's internal names say waddle: EffectKind.waddle, WaddleRig, waddle_* shaders.)
//
//  Everything that moves is a pure function of the scene time t (saver, wallpaper, previews,
//  thumbnails and synced screens agree), worked out on the CPU once a frame (WaddleRig.prepare,
//  from MetalRenderer.encodePasses, like Bounce's pose): time runs in 20-second episodes, each
//  walking from one hashed spot on the ground to the next, playing one behaviour and then
//  fidgeting (glances, a hop, a flap, a chirp…); the behaviours are shuffled in blocks of eight,
//  so one comes back a minute later at the soonest and about every two and a half on average.
//  Shaders: Penguin_funcs.h (waddle_*, on CellKit_funcs.h), Penguin_cases.h.
//
//  FXUniforms.scene for 80:
//    [0] (feet x px from the screen centre, ground y px (y down), penguin height px, cell px)
//    [1] (yaw −1 left … 0 the viewer … +1 right, lean rad (+ = top to the right), squash x, y)
//    [2] (hop (heights), belly slide 0…1, flipper angle left, right (rad from hanging down))
//    [3] (eyes open 0…1+, look x, look y, happy 0/1)
//    [4] (foot lift left, right (heights), head tilt rad, seconds into the Zz (< 0 none))
//    [5] (snow 0…1, brightness, tuft sway, bill open 0…1)
//    [6] (custom character 0/1, its half width, height (heights), mip level)
//    [7] (its texture's clear margin in uv (x, y), slide direction ±1, snow spray 0…1)
//    [8] (igloo x px from the centre, its radius px, behind it 0/1, night 0 day … 1 night)
//    [9] (camera px (the penguin's [0].x is already on screen), burst age s (< 0 none), its seed, 0)

import Foundation
import Metal
import simd

extension SceneCatalog {
    /// Packed in order into p0.xyzw, p1.xyzw.
    static let penguinPack: [EffectKind: SceneSpec] = [
        // p0 = (render, cell size, glow, energy), p1 = (snow, size, follow the clock, backdrop)
        .waddle: SceneSpec(
            name: "Penguin",
            blurb: "A little penguin on an LED panel: it waddles, waves, belly-slides, dances and dozes.",
            shaderID: 80,
            params: [ParamSpec(menu: "render", "Render", ["LED Dots", "Pixels", "Glyphs"], def: 0),
                     ParamSpec("cell", "Cell Size", 8, 22, def: 13),
                     ParamSpec("glow", "Glow", 0, 1, def: 0.9),
                     ParamSpec("energy", "Energy", 0, 1, def: 0.5),
                     ParamSpec("snow", "Snow", 0, 1, def: 1, toggle: true),
                     ParamSpec("size", "Size", 0.6, 1.3, def: 1),
                     ParamSpec("night", "Follow the Clock", 0, 1, def: 1, toggle: true),
                     ParamSpec(menu: "backdrop", "Backdrop", ["None", "Snowy Night", "Day"], def: 1)],
            colorA: RGBA(0.16, 0.44, 1.0), colorB: RGBA(0.010, 0.012, 0.020),
            colorALabel: "Penguin", colorBLabel: "Background"),
    ]

    /// Styles this pack adds to the default library. 24 fps, like Bloom: an LED panel's cadence.
    static var penguinPresets: [Preset] {
        var e = EffectInstance(.waddle)
        e.params = EffectKind.waddle.defaultParams
        return [Preset(name: "Penguin", effects: [e], fps: 24)]
    }
}

/// Penguin's behaviour: where the penguin is and what it is doing at scene time t.
enum WaddleRig {
    /// The 24 fps cadence (FramePacing.steppedFPS asks the hosts for it).
    static let stepFPS = 24.0
    /// Seconds per episode: walk to the next spot, do one thing, then fidget until the next.
    static let episode = 20.0

    enum Act: Int, CaseIterable { case stroll, wave, slide, dance, doze, look, edge, shake }

    struct Pose: Equatable {
        var x = 0.0                      // feet, penguin heights from the screen centre (+ right)
        var hop = 0.0                    // heights above the ground
        var yaw = 0.0                    // −1 facing left … 0 the viewer … +1 right
        var lean = 0.0                   // rad, + = the top to the right (about the feet)
        var sx = 1.0, sy = 1.0           // squash
        var slide = 0.0, slideDir = 1.0  // lying on its belly 0…1, head toward ±x
        var flipL = 0.28, flipR = 0.28   // rad from hanging straight down (+ = out / up)
        var eyeOpen = 1.0
        var lookX = 0.0, lookY = 0.0
        var happy = 0.0                  // ^ ^ eyes
        var footL = 0.0, footR = 0.0     // lift, heights
        var headTilt = 0.0
        var zz = -1.0                    // seconds into a doze's Zz (< 0 none)
        var beak = 0.0                   // bill open 0…1
        var tuft = 0.0
        var spray = 0.0                  // snow kicked up behind a belly slide
        var behind = false               // passing behind the igloo (it hides what it covers)
        var burst = -1.0, burstSeed = 0.0 // seconds into a burst of hearts and stars (< 0 none)
        var act = Act.stroll
        /// What part of the episode this is: 0 rest, 1 turn, 2 walk, 3 run, 4 dive, 5 glide,
        /// 6 getting up, 7 peering over the edge, 8 the behaviour, 9 a fidget.
        var phase = 0
    }

    /// Screen geometry (px): the penguin's height, the cell, where the ground is (the bottom
    /// edge: the screen's floor), and how far either side of the centre its feet may go (in
    /// penguin heights). With a backdrop, the igloo: where it stands (heights from the centre),
    /// and whether the penguin plays round it (room for it on the screen).
    struct Stage: Equatable {
        var hp = 0.0, cellPx = 0.0, groundY = 0.0, range = 0.0
        var iglooX = 0.0
        var igloo: Double? { range >= 1.0 ? iglooX : nil }
    }
    /// The igloo's radius, in penguin heights (a little lower than the penguin is tall).
    static let iglooR = 0.55

    static func stage(width W: Double, height H: Double, size: Double, cell: Double) -> Stage {
        let unit = min(H, 1.3 * W)                 // portrait: the penguin keeps its dot count
        let hp = 0.40 * min(max(size, 0.3), 2) * unit
        let cellPx = max(min(max(cell, 4), 40) * unit / 1000, 3)
        let range = max((0.5 * W - 0.66 * hp) / max(hp, 1), 0)
        // off to the left: inside the penguin's ground on a wide enough screen, else at the edge
        let iglooX = range >= 1.0 ? -(0.55 * range + 0.15) : -(range + 0.75)
        return Stage(hp: hp, cellPx: cellPx, groundY: H, range: range, iglooX: iglooX)
    }

    // MARK: Hashes

    /// A stable hash of (a, b) in 0..<1 (splitmix64): the same on every Mac and every run.
    static func hash(_ a: Int, _ b: Int = 0) -> Double {
        var z = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15 &+ UInt64(bitPattern: Int64(b)) &* 0xD1B54A32D192ED03
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Where the penguin stands between episodes k − 1 and k, in −range…range (the middle at
    /// t = 0, where a preview or a thumbnail starts), never in front of the igloo (it stops on
    /// the screen's side of it).
    static func home(_ k: Int, range: Double, igloo: Double? = nil) -> Double {
        var x = k == 0 ? 0 : range * (2 * hash(k, 101) - 1)
        if let ig = igloo, abs(x - ig) < clear { x = min(ig + clear + 0.3 * abs(x - ig), range) }
        return x
    }
    /// How far from the igloo's middle the penguin's feet must be to stand clear of it.
    static let clear = 0.95

    /// Block b's order of the eight behaviours (a shuffle by hash).
    static func order(_ b: Int) -> [Act] {
        let keys = Act.allCases.map { (hash(b, 200 + $0.rawValue), $0) }
        return keys.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Episode k's behaviour: each block of eight plays every behaviour once, and a behaviour
    /// that closed the last block waits at least three episodes (a minute) to come back: the
    /// block's first five are reordered (stably) so the last block's final three come late.
    /// (Only the first five move, so the final three stay what the next block reads.)
    static func act(_ k: Int) -> Act {
        let n = Act.allCases.count
        let b = Int((Double(k) / Double(n)).rounded(.down)), j = k - b * n
        var o = order(b)
        let tail = Set(order(b - 1)[5...])
        let head = o[0..<5]
        o.replaceSubrange(0..<5, with: head.filter { !tail.contains($0) } + head.filter { tail.contains($0) })
        return o[j]
    }

    /// How deep in the night local hour `h` is: 1 from 21:00 to 5:30, easing over an hour.
    static func nightFactor(hour h: Double) -> Double {
        func ss(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }
        let x = h.truncatingRemainder(dividingBy: 24)
        return x >= 12 ? ss(20.0, 21.0, x) : 1 - ss(5.5, 6.5, x)
    }

    // MARK: Episodes

    private enum Seg {
        case idle
        case turn(Double, Double)                // yaw from, to
        case walk(Double, Double, Double)        // x from, to; speed (heights / s)
        case run(Double, Double)                 // x from, to: quick steps into a dive
        case dive(Double, Double)
        case glide(Double, Double)               // decelerating on the belly
        case getUp
        case peer(Double)                        // at the edge, looking over (direction)
        case act(Act)
        case fidget(Int)                         // a little thing between behaviours (fidgetPose)
    }

    /// The fidgets: a glance, a look up at the snow, a hop, a flap, a tilt of the head, a chirp,
    /// a shuffle of the feet.
    static let fidgetCount = 7
    private static func fidgetDur(_ f: Int) -> Double { [1.6, 1.8, 0.7, 0.9, 1.4, 1.0, 1.2][f] }

    private struct Step { var t0: Double; var dur: Double; var seg: Seg }

    /// Episode k's script: (steps, its behaviour, the night's pull, the dozing time).
    private static func script(_ k: Int, range R: Double, energy e: Double, night nf: Double,
                               igloo ig: Double?) -> ([Step], Act) {
        var a = act(k)
        // low energy: the boisterous behaviours turn into gentler ones now and then
        if e < 0.3, a == .slide || a == .dance || a == .shake, hash(k, 11) < (0.3 - e) * 2.6 {
            a = hash(k, 12) < 0.5 ? .stroll : .look
        }
        if nf > 0, hash(k, 9) < 0.65 * nf { a = .doze }
        let x0 = home(k, range: R, igloo: ig), x1 = home(k + 1, range: R, igloo: ig)
        let v = (0.42 + 0.38 * e) * (1 - 0.25 * nf)
        let face = 0.85
        var steps: [Step] = []
        var t = 0.0
        func add(_ s: Seg, _ d: Double) { if d > 0 { steps.append(Step(t0: t, dur: d, seg: s)); t += d } }
        func walk(_ from: Double, _ to: Double, yaw: inout Double, end: Double?) {
            let dx = to - from
            if abs(dx) > 0.04 {
                let y = dx > 0 ? face : -face
                if abs(y - yaw) > 0.01 { add(.turn(yaw, y), 0.32 * abs(y - yaw) / face) }
                yaw = y
                add(.walk(from, to, v), abs(dx) / v)
            }
            if let end, abs(end - yaw) > 0.01 { add(.turn(yaw, end), 0.32 * abs(end - yaw) / face); yaw = end }
        }
        var yaw = 0.0
        add(.idle, (0.5 + 1.5 * hash(k, 13)) * (1.4 - 0.8 * e))
        switch a {
        case .slide:
            // a run, a dive, and a long glide toward the far side; up, shake off, walk back
            let dir: Double = x0 > 0 ? -1 : 1
            let xg = dir * R                                          // (the glide's end)
            let span = abs(xg - x0), lead = min(span * 0.45, 0.7)     // run + dive, then glide
            let xr = x0 + dir * lead * 0.43, xd = x0 + dir * lead
            add(.turn(0, dir * face), 0.32); yaw = dir * face
            add(.run(x0, xr), 0.5)
            add(.dive(xr, xd), 0.36)
            add(.glide(xd, xg), 2 * abs(xg - xd) / 1.9)
            add(.getUp, 0.5)
            add(.act(.shake), 1.1)
            walk(xg, x1, yaw: &yaw, end: 0)
        case .edge:
            // across the panel to the far edge, a look over it, turn around, back to the spot
            let dir: Double = x0 > 0 ? -1 : 1
            let xe = dir * R
            walk(x0, xe, yaw: &yaw, end: nil)
            if abs(yaw - dir * face) > 0.01 { add(.turn(yaw, dir * face), 0.32); yaw = dir * face }
            add(.peer(dir), 1.5)
            add(.turn(yaw, -yaw), 0.75); yaw = -yaw
            walk(xe, x1, yaw: &yaw, end: 0)
        case .doze where ig != nil && hash(k, 15) < 0.6:
            // over to the igloo, a doze beside it, then on to the next spot
            let xs = ig! + 0.8
            walk(x0, xs, yaw: &yaw, end: 0)
            add(.act(.doze), 11 + 3 * nf)
            add(.idle, 0.6)
            walk(xs, x1, yaw: &yaw, end: 0)
        default:
            walk(x0, x1, yaw: &yaw, end: 0)
            let d: Double
            switch a {
            case .wave: d = 2.6 + 0.8 * e
            case .dance: d = 3.2 + 1.8 * e
            case .doze: d = 11 + 3 * nf
            case .look: d = 3.8
            case .shake: d = 1.4
            default: d = 2.4                                     // stroll: a glance about
            }
            add(.act(a), d)
        }
        // everything must fit the episode (a very wide screen walks further): speed it all up
        let room = episode - 0.6
        // the rest of it: little things, a pause or two apart (fewer at night, none after a doze
        // at night: it's sleepy)
        if !(a == .doze && nf > 0.5) {
            for slot in 0..<6 {
                let gap = (0.8 + 1.5 * hash(k, 60 + slot)) * (1.3 - 0.6 * e) * (1 + 1.2 * nf)
                let f = min(Int(hash(k, 80 + slot) * Double(fidgetCount)), fidgetCount - 1)
                if t + gap + fidgetDur(f) > room { break }
                add(.idle, gap)
                add(.fidget(f), fidgetDur(f))
            }
        }
        if t > room {
            let f = room / t
            for i in steps.indices { steps[i].t0 *= f; steps[i].dur *= f }
        }
        return (steps, a)
    }

    /// The episode's script, kept while frames stay in it (a frame's pose then allocates
    /// nothing): the last one worked out, shared by every renderer.
    private struct ScriptKey: Equatable { var k: Int; var range, energy, night, igloo: Double }
    private static let scriptLock = NSLock()
    private static var lastScript: (key: ScriptKey, steps: [Step], act: Act)?

    private static func cachedScript(_ k: Int, range R: Double, energy e: Double, night nf: Double,
                                     igloo ig: Double?) -> ([Step], Act) {
        let key = ScriptKey(k: k, range: R, energy: e, night: nf, igloo: ig ?? .infinity)
        scriptLock.lock()
        if let l = lastScript, l.key == key { scriptLock.unlock(); return (l.steps, l.act) }
        scriptLock.unlock()
        let (steps, a) = script(k, range: R, energy: e, night: nf, igloo: ig)
        scriptLock.lock()
        lastScript = (key, steps, a)
        scriptLock.unlock()
        return (steps, a)
    }

    private static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
    private static func bump(_ x: Double) -> Double { x <= 0 || x >= 1 ? 0 : sin(.pi * x) }

    /// The pose at stepped time `ts` for a stage `range` heights either side of the centre (and
    /// an igloo at `igloo`, if it plays round one).
    static func pose(at ts: Double, range R: Double, energy e: Double, night nf: Double,
                     igloo ig: Double? = nil) -> Pose {
        let k = Int((ts / episode).rounded(.down))
        let tau = ts - Double(k) * episode
        let (steps, a) = cachedScript(k, range: R, energy: e, night: nf, igloo: ig)
        var p = Pose()
        p.act = a
        // now and then its way passes behind the igloo (never a slide, nor a doze beside it)
        p.behind = ig != nil && a != .slide && a != .doze && hash(k, 16) < 0.45
        p.x = home(k, range: R, igloo: ig)
        var dozing = false

        // the step tau falls in (past the last: resting at the next spot)
        var cur: Step?
        for s in steps where tau >= s.t0 && tau < s.t0 + s.dur { cur = s; break }
        if cur == nil, tau >= (steps.last.map { $0.t0 + $0.dur } ?? 0) { p.x = home(k + 1, range: R, igloo: ig) }
        // x and yaw where each earlier step left them
        for s in steps where s.t0 + s.dur <= tau {
            switch s.seg {
            case .walk(_, let b, _), .run(_, let b), .dive(_, let b), .glide(_, let b): p.x = b
            case .turn(_, let b): p.yaw = b
            default: break
            }
        }
        if let s = cur {
            let l = tau - s.t0, u = l / s.dur
            switch s.seg {
            case .idle: p.phase = 0
            case .turn: p.phase = 1
            case .walk: p.phase = 2
            case .run: p.phase = 3
            case .dive: p.phase = 4
            case .glide: p.phase = 5
            case .getUp: p.phase = 6
            case .peer: p.phase = 7
            case .act: p.phase = 8
            case .fidget: p.phase = 9
            }
            switch s.seg {
            case .idle:
                // a glance to one side now and then
                let g = hash(k, 31) * 2 - 1
                p.lookX = 0.7 * g * bump(u)
                p.yaw += 0.12 * g * bump(u)
            case .turn(let y0, let y1):
                p.yaw = y0 + (y1 - y0) * smooth(u)
                p.hop = 0.025 * bump(u)
            case .walk(let a0, let b, let v):
                p.x = a0 + (b - a0) * u
                let ph = 2 * .pi * (2.1 * (v / 0.6).squareRoot()) * l
                let env = smooth(l / 0.2) * smooth((s.dur - l) / 0.2)
                p.lean = 0.085 * sin(ph) * env
                p.hop = 0.022 * abs(sin(ph)) * env
                p.footL = 0.06 * max(sin(ph), 0) * env
                p.footR = 0.06 * max(-sin(ph), 0) * env
                p.flipL = 0.42 + 0.12 * sin(ph); p.flipR = 0.42 - 0.12 * sin(ph)
            case .run(let a0, let b):
                p.x = a0 + (b - a0) * u
                let ph = 2 * .pi * 4.2 * l, dir = b > a0 ? 1.0 : -1.0
                p.lean = dir * 0.16 * smooth(u * 2) + 0.07 * sin(ph)
                p.hop = 0.03 * abs(sin(ph))
                p.footL = 0.06 * max(sin(ph), 0); p.footR = 0.06 * max(-sin(ph), 0)
                p.flipL = 0.9; p.flipR = 0.9
            case .dive(let a0, let b):
                let dir = b > a0 ? 1.0 : -1.0
                p.x = a0 + (b - a0) * u
                p.slide = smooth(u); p.slideDir = dir
                p.headTilt = -dir * 0.30 * p.slide                   // head up, looking ahead
                p.hop = 0.14 * bump(u)
                p.flipL = 0.9; p.flipR = 0.9
                p.happy = 1
                p.spray = 0.7 * smooth(u)
            case .glide(let a0, let b):
                let dir = b > a0 ? 1.0 : -1.0
                p.x = a0 + (b - a0) * (1 - (1 - u) * (1 - u))
                p.slide = 1; p.slideDir = dir
                p.headTilt = -dir * 0.30
                p.hop = 0.008 * sin(2 * .pi * 3 * l)
                p.flipL = 1.25; p.flipR = 1.25                       // swept back, off its back
                p.footL = 0.02 * max(sin(2 * .pi * 5 * l), 0); p.footR = 0.02 * max(-sin(2 * .pi * 5 * l), 0)
                p.lookX = dir; p.eyeOpen = 1.15
                p.spray = 1 - u * u
            case .getUp:
                p.slide = 1 - smooth(u)
                p.slideDir = p.yaw >= 0 ? 1 : -1
                p.headTilt = -p.slideDir * 0.30 * p.slide
                p.hop = 0.08 * bump(u)
                p.flipL = 1.0; p.flipR = 1.0
            case .peer(let dir):
                let env = smooth(u / 0.25) * smooth((1 - u) / 0.25)
                p.lean = dir * 0.24 * env
                p.lookY = -0.8 * env
                p.lookX = dir * 0.5 * env
                p.flipL = 0.28 + 0.7 * env; p.flipR = 0.28 + 0.7 * env
                p.headTilt = -dir * 0.12 * env
            case .act(let b):
                actPose(&p, b, l: l, dur: s.dur, k: k, e: e, nf: nf, dozing: &dozing)
            case .fidget(let f):
                fidgetPose(&p, f, l: l, dur: s.dur, seed: Int(s.t0 * 1000) &+ k &* 7919)
            }
        }

        // breathing, blinks, the tuft's sway: always
        let breathP = dozing ? 4.6 : 3.1, breathA = dozing ? 0.032 : 0.016
        let br = sin(2 * .pi * ts / breathP)
        p.sy *= 1 + breathA * br
        p.sx *= 1 - 0.5 * breathA * br
        if !dozing {
            let slot = (ts / 3.7).rounded(.down), si = Int(slot)
            let at = slot * 3.7 + 0.3 + 2.9 * hash(si, 41)
            var d = abs(ts - at)
            if hash(si, 42) > 0.72 { d = min(d, abs(ts - at - 0.28)) }        // a double blink
            p.eyeOpen *= smooth((d - 0.03) / 0.07)
        }
        p.tuft = -1.6 * p.lean + 0.18 * sin(ts * 1.3) + 3 * p.hop
        return p
    }

    /// The behaviours played in place (l seconds into one lasting dur).
    private static func actPose(_ p: inout Pose, _ a: Act, l: Double, dur: Double, k: Int, e: Double, nf: Double,
                                dozing: inout Bool) {
        let u = l / dur
        let env = smooth(l / 0.3) * smooth((dur - l) / 0.3)
        switch a {
        case .stroll:
            // a glance to one side, then the other
            let s = hash(k, 51) < 0.5 ? -1.0 : 1.0
            let w = u < 0.5 ? bump(u * 2) : -bump(u * 2 - 1) * 0.7
            p.yaw = s * 0.35 * w
            p.lookX = s * 0.9 * w
            p.headTilt = s * 0.08 * w
        case .wave:
            // a flipper up and waving, happy eyes, a chirp
            let s = hash(k, 52) < 0.5 ? -1.0 : 1.0
            let up = smooth(l / 0.3) * smooth((dur - l) / 0.3)
            let wv = 0.38 * sin(2 * .pi * (2.6 + 0.8 * e) * max(l - 0.3, 0)) * up
            let ang = 0.28 + (2.35 - 0.28) * up + wv
            if s < 0 { p.flipL = ang } else { p.flipR = ang }
            p.lean = -s * 0.05 * up
            p.yaw = s * 0.12 * up
            p.happy = up > 0.5 ? 1 : 0
            p.beak = bump(min(l / 0.5, 1)) * 0.9
            for (i, b) in [0.35, 1.55].enumerated() where l >= b { p.burst = l - b; p.burstSeed = Double(k * 31 + i) }
            p.headTilt = -s * 0.1 * up
        case .dance:
            // little hops, side to side, flippers out
            let f = 1.8 + 0.6 * e
            let hp = max(l - 0.15, 0) * f
            let n = Int(hp), fr = hp - Double(n)
            let live = l > 0.15 && l < dur - 0.25 ? 1.0 : 0.0
            let side = n.isMultiple(of: 2) ? 1.0 : -1.0
            p.hop = live * (0.07 + 0.06 * e) * bump(fr)
            let land = live * exp(-pow(min(fr, 1 - fr) / 0.09, 2))
            p.sy *= 1 - 0.11 * land
            p.sx *= 1 + 0.07 * land
            p.lean = live * side * 0.11 * bump(fr)
            p.yaw = live * side * 0.22 * bump(fr)
            let fl = 1.25 + 0.45 * sin(2 * .pi * hp)
            p.flipL = 0.28 + (fl - 0.28) * env; p.flipR = 0.28 + (fl - 0.28) * env
            p.happy = env > 0.5 ? 1 : 0
            p.beak = live * (n % 3 == 1 ? bump(fr) : 0)
            if l > 0.3 && l < dur - 0.3 {                    // a burst every other hop
                let b = ((l - 0.3) / 1.1).rounded(.down)
                p.burst = l - 0.3 - b * 1.1; p.burstSeed = Double(k * 31 + 5 + Int(b))
            }
        case .doze:
            // sit, droop, Zz…, wake with a start
            let sit = smooth(l / 0.6) * smooth((dur - l) / 0.5)
            p.sy *= 1 - 0.09 * sit
            p.sx *= 1 + 0.05 * sit
            let wake = dur - 1.3
            if l < wake {
                p.eyeOpen = l < 0.6 ? 1 : l < 1.2 ? 1 - 0.55 * smooth((l - 0.6) / 0.6)
                          : l < 1.9 ? 0.45 : 0.45 * (1 - smooth((l - 1.9) / 0.4))
                dozing = l > 1.9
                if l > 2.4 { p.zz = l - 2.4 }
                p.headTilt = l > 1.9 ? 0.07 * sin(2 * .pi * (l - 1.9) / 4.6) + 0.04 : 0
                p.lookY = -0.4 * smooth((l - 0.6) / 1.2)
            } else {
                let w = l - wake
                p.eyeOpen = w < 0.08 ? smooth(w / 0.08) * 1.2 : 1.2 - 0.2 * smooth((w - 0.2) / 0.6)
                p.hop = 0.10 * bump(w / 0.4)
                p.flipL = 0.28 + 0.9 * bump(min(w / 0.7, 1)); p.flipR = p.flipL
                p.beak = 0.6 * bump(min(w / 0.5, 1))
            }
        case .look:
            // left, right, a tilt of the head, then leaning in toward the viewer
            let s = hash(k, 53) < 0.5 ? -1.0 : 1.0
            var y = 0.0
            if l < 0.4 { y = -s * 0.6 * smooth(l / 0.4) }
            else if l < 1.2 { y = -s * 0.6 }
            else if l < 1.8 { y = -s * 0.6 + s * 1.2 * smooth((l - 1.2) / 0.6) }
            else if l < 2.6 { y = s * 0.6 }
            else if l < 3.0 { y = s * 0.6 * (1 - smooth((l - 2.6) / 0.4)) }
            p.yaw = y
            p.lookX = y * 1.4
            p.headTilt = (l > 0.5 && l < 1.2 ? -s * 0.13 : l > 1.9 && l < 2.6 ? s * 0.13 : 0)
            let lean = bump(max(l - 2.9, 0) / max(dur - 2.9, 0.1))
            p.sx *= 1 + 0.06 * lean; p.sy *= 1 + 0.06 * lean
            p.eyeOpen = 1 + 0.15 * lean
        case .shake:
            // shaking the snow off: a quick wiggle and flapping
            let dec = 1 - smooth(u)
            p.lean = 0.13 * sin(2 * .pi * 6.5 * l) * dec * smooth(l / 0.1)
            let fl = 0.9 + 0.6 * sin(2 * .pi * 7 * l)
            p.flipL = 0.28 + (fl - 0.28) * env; p.flipR = p.flipL
            p.happy = 1
            p.hop = 0.05 * bump((u - 0.75) / 0.25)
        case .slide, .edge:
            break
        }
    }

    /// The fidgets (l seconds into one lasting dur; `seed` picks its side).
    private static func fidgetPose(_ p: inout Pose, _ f: Int, l: Double, dur: Double, seed: Int) {
        let u = l / dur, w = bump(u)
        let s = hash(seed, 90) < 0.5 ? -1.0 : 1.0
        switch f {
        case 0:                                                  // a glance
            p.yaw = s * 0.3 * w; p.lookX = s * w; p.headTilt = s * 0.06 * w
        case 1:                                                  // up at the snow
            p.lookY = 0.9 * w; p.headTilt = s * 0.10 * w; p.lean = -s * 0.03 * w
        case 2:                                                  // a little hop
            let crouch = bump(min(u / 0.3, 1)), air = bump((u - 0.25) / 0.6)
            p.hop = 0.07 * air
            p.sy *= 1 - 0.08 * crouch + 0.04 * air; p.sx *= 1 + 0.05 * crouch
            p.flipL = 0.28 + 0.5 * air; p.flipR = p.flipL
        case 3:                                                  // a flap
            let fl = abs(sin(2 * .pi * 2.2 * l)) * w
            p.flipL = 0.28 + 1.0 * fl; p.flipR = p.flipL
            p.eyeOpen = 1 - 0.3 * w
        case 4:                                                  // a curious tilt
            p.headTilt = s * 0.17 * w; p.eyeOpen = 1 + 0.12 * w; p.lookX = s * 0.3 * w
        case 5:                                                  // a chirp
            p.beak = abs(sin(2 * .pi * 2 * l)) * w; p.happy = w > 0.3 ? 1 : 0
            p.hop = 0.015 * w
        default:                                                 // a shuffle of the feet
            let ph = 2 * .pi * 2.5 * l
            p.footL = 0.05 * max(sin(ph), 0) * w; p.footR = 0.05 * max(-sin(ph), 0) * w
            p.lean = 0.05 * sin(ph) * w
        }
    }

    // MARK: The frame

    /// Snow 0…1 at time ts: it comes and goes over minutes.
    static func snow(at ts: Double) -> Double {
        let v = 0.5 + 0.35 * sin(2 * .pi * ts / 410 + 1.3) + 0.25 * sin(2 * .pi * ts / 157 + 0.4)
        return smooth((v - 0.3) / 0.3)
    }

    /// Fills u.scene for this frame (u.p0 = render, cell, glow, energy; u.p1 = snow, size,
    /// follow the clock) and returns the custom character's texture (slot 6), or nil for the
    /// penguin.
    static func prepare(_ u: inout FXUniforms, inst: EffectInstance, mediaDir: URL, device: MTLDevice) -> MTLTexture? {
        let W = Double(u.resolution.x), H = Double(u.resolution.y)
        guard W > 0, H > 0 else { return nil }
        func fin(_ x: Float, _ d: Double) -> Double { x.isFinite ? Double(x) : d }
        let energy = min(max(fin(u.p0.w, 0.5), 0), 1)
        let st = stage(width: W, height: H, size: fin(u.p1.y, 1), cell: fin(u.p0.y, 13))
        let ts = (fin(u.time, 0) * stepFPS).rounded(.down) / stepFPS
        let follow = u.p1.z > 0.5
        let nf = follow ? nightFactor(hour: Double(u.clock.x)) : 0
        let backdrop = Int(min(max(fin(u.p1.w, 1), 0), 2).rounded())
        let ig = backdrop > 0 ? st.igloo : nil
        let p = pose(at: ts, range: st.range, energy: energy, night: nf, igloo: ig)
        // the backdrop's night: the clock's when following it, else the one picked
        let sky = follow ? nf : (backdrop == 1 ? 1 : 0)
        // with a backdrop the camera follows the penguin a little, lagging (where it was over
        // the last ¾ s), and the backdrop's layers move by their own shares of it: parallax
        var cam = 0.0
        if backdrop > 0 {
            let x1 = pose(at: ts - 0.35, range: st.range, energy: energy, night: nf, igloo: ig).x
            let x2 = pose(at: ts - 0.7, range: st.range, energy: energy, night: nf, igloo: ig).x
            cam = 0.3 * (p.x + x1 + x2) / 3
        }
        let snowAmt = u.p1.x > 0.5 ? snow(at: ts) : 0

        var tex: MTLTexture?
        var custom = SIMD4<Float>(0, 0, 0, 0), margin = SIMD2<Float>(0, 0)
        if inst.logoKind == .image, inst.logoFile != nil,
           let e = BounceLogo.entry(for: inst, mediaDir: mediaDir, device: device), !e.fallback {
            // the sprite: a penguin's height tall, at most 1.6 heights wide
            let a = max(e.aspect, 0.05)
            let h = a > 1.6 ? 1.6 / a : 1.0
            let texelsPerCell = Double(e.height) / max(h * st.hp / st.cellPx, 1)
            custom = SIMD4(1, Float(0.5 * h * a), Float(h), Float(max(log2(max(texelsPerCell, 1)), 0)))
            margin = e.inset
            tex = e.tex
        }
        func f(_ x: Double) -> Float { Float(x) }
        u.scene.0 = SIMD4(f((p.x - cam) * st.hp), f(st.groundY), f(st.hp), f(st.cellPx))
        u.scene.1 = SIMD4(f(p.yaw), f(p.lean), f(p.sx), f(p.sy))
        u.scene.2 = SIMD4(f(p.hop), f(p.slide), f(p.flipL), f(p.flipR))
        u.scene.3 = SIMD4(f(p.eyeOpen), f(p.lookX), f(p.lookY), f(p.happy))
        u.scene.4 = SIMD4(f(p.footL), f(p.footR), f(p.headTilt), f(p.zz))
        u.scene.5 = SIMD4(f(snowAmt), f(1 - 0.3 * nf), f(p.tuft), f(p.beak))
        u.scene.6 = custom
        u.scene.7 = SIMD4(margin.x, margin.y, f(p.slideDir), f(p.spray))
        u.scene.8 = SIMD4(f(st.iglooX * st.hp), f(iglooR * st.hp), p.behind ? 1 : 0, f(sky))
        u.scene.9 = SIMD4(f(cam * st.hp), f(p.burst), f(p.burstSeed), 0)
        return tex
    }
}
