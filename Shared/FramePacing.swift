//  FramePacing.swift — frame-rate rules shared by the screensaver (Saver/DotSaverView) and the
//  live wallpaper (App/WallpaperPower's WallpaperPacing forwards here), and StepClock: the time a
//  style that steps its own time (Bloom's 24 fps cadence) is drawn at.

import Foundation

enum FramePacing {
    /// The rate a style steps its own time at, whatever rate it is drawn at (Bloom keeps a
    /// 24 fps film cadence: Bloom_funcs.h), else nil. See `rate(target:step:refresh:)`.
    static func steppedFPS(_ preset: Preset) -> Double? {
        guard let first = preset.effects.first(where: \.enabled) else { return nil }
        if first.kind == .custom, let id = first.custom?.id {
            return CustomScenes.knownManifest(id: id)?.steppedFPS      // "stepped": true in its manifest
        }
        return first.kind == .flowerBloom ? 24 : nil
    }

    /// The draw rate for `target` fps on a `refresh` Hz display.
    ///
    /// A style that steps its own time at `step` fps:
    /// - when the budget allows that many (`target ≥ step`), the slowest exact divisor of the
    ///   refresh at or above it — 24 on 120 Hz, 30 on 60 Hz, 25 on 50 Hz — so no step is ever
    ///   skipped (20 on 60 Hz would drop one in six) and none is drawn twice over for nothing
    ///   (Smooth's 120);
    /// - below that (Low Power, the battery's Efficient), the fastest rate that is both an exact
    ///   divisor of the refresh and a whole fraction of the step rate, within the budget — 12 for
    ///   24 fps steps on 60, 120 or 144 Hz: every draw then advances exactly two steps (the film
    ///   cadence "on twos"). 15 (the Low Power budget) would advance 1.6 steps a draw, dropping
    ///   steps irregularly (2, 1, 2, 2, 1…), a visible stutter. With no such rate (24 fps steps on
    ///   50 Hz) the plain divisor rule applies.
    /// Anything else: `divisorRate`.
    static func rate(target: Double, step: Double?, refresh: Double) -> Double {
        guard let step, step > 0, refresh > 0, target > 0 else {
            return divisorRate(target: target, refresh: refresh)
        }
        if target >= step - 0.01 {
            return refresh / max((refresh / step + 1e-6).rounded(.down), 1)
        }
        // step / k for k = 2, 3…: the first within the budget that divides the refresh (and
        // not below half the budget: past that, uneven steps beat a slide show)
        var k = max((step / target - 1e-6).rounded(.up), 2)
        while step / k >= target * 0.5 - 1e-6 {
            let r = step / k, n = refresh / r
            if abs(n - n.rounded()) < 1e-6 { return r }
            k += 1
        }
        return divisorRate(target: target, refresh: refresh)
    }

    /// The exact divisor of `refresh` closest to `target` (30 on 60/120 Hz, 25 on 50 Hz,
    /// 36 on 144 Hz...), so every frame is held for the same number of refreshes.
    static func divisorRate(target: Double, refresh: Double) -> Double {
        guard refresh > 0 else { return target }
        let n = max((refresh / max(target, 1)).rounded(), 1)
        return refresh / n
    }
}

/// The scene time a stepped style (FramePacing.steppedFPS) is drawn at, so its steps land evenly
/// on the draws.
///
/// The shader shows step ⌊t·rate⌋. Drawn at exactly the step rate (24 a second on 120 Hz, the
/// saver's 24 on battery) or a whole fraction of it (12 in Low Power), a draw whose time falls
/// near a step boundary shows the step before or after it depending on a millisecond of jitter
/// in when it was encoded: a step drawn twice, then one skipped. So each draw is placed mid-step:
/// the clock keeps a phase (in steps, within ±½) and, while draws arrive a whole number of steps
/// apart (their cadence, smoothed over the last few, within 0.1 of it) and one lands within 0.2
/// of a boundary, moves the phase so it lands in the middle — without changing the step that
/// draw shows. Draws at any other cadence (30 on 60 Hz: 0.8 steps apart) never move it, and
/// can't skip a step: they advance less than one. The time handed to the shader is the middle
/// of the step, which a Float t resolves exactly however long the scene has run.
///
/// Hosts pass the frame's presentation time where they know it (the wallpaper: its display
/// link's targetTimestamp), which removes the jitter outright; the saver, driven by the host's
/// timer, passes the time it encodes at, and the phase lock absorbs the jitter.
struct StepClock {
    /// Steps added to t·rate before flooring, in (−½, ½].
    private(set) var phase: Double = 0
    private var lastAt: Double?
    /// Steps between draws, smoothed (nil until two draws).
    private var cadence: Double?

    /// Forget the draw cadence (a new style, a pause): the next draws don't move the phase.
    mutating func reset() { lastAt = nil; cadence = nil }

    /// The scene time to draw: the middle of the step `t` (scene seconds) falls in, for a draw
    /// presented at host time `at` (seconds).
    mutating func time(_ t: Double, rate: Double, at: Double) -> Double {
        guard rate > 0, t.isFinite else { return t }
        let x = t * rate + phase
        let n = x.rounded(.down)
        if let last = lastAt {
            let apart = (at - last) * rate                 // steps between this draw and the last
            let c = cadence.map { abs(apart - $0) > 0.5 ? apart : $0 + 0.25 * (apart - $0) } ?? apart
            cadence = c
            let whole = c.rounded(), f = x - n
            if whole >= 1, abs(c - whole) < 0.1, f < 0.2 || f > 0.8 {
                phase += 0.5 - f                           // this draw mid-step (still step n)
                if phase > 0.5 { phase -= 1 } else if phase <= -0.5 { phase += 1 }
            }
        }
        lastAt = at
        return (n + 0.5) / rate
    }
}
