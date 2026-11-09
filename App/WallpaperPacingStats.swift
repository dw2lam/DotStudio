//  WallpaperPacingStats.swift — debug-only frame pacing counters for one wallpaper display.
//
//  Two views of smoothness, summarised into the debug log every 10 s:
//    • ticks — display-link callback intervals (when frame work started), and
//    • shown — on-screen intervals from each drawable's presented handler (what the
//              user actually sees; 0 = a frame that never reached the glass).
//  A "late" interval is longer than 1.5 frame slots: a visible hitch.
//  Thread-safe: ticks arrive on the frame thread, presented times on a Metal thread.

import Foundation
import QuartzCore

final class WallpaperPacingStats {
    private let lock = NSLock()
    private var lastTick: CFTimeInterval = 0
    private var ticks: [Double] = []
    private var lastShown: CFTimeInterval = 0
    private var shown: [Double] = []
    private var dropped = 0

    /// A display-link frame began.
    func tick(_ now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock(); defer { lock.unlock() }
        if lastTick > 0, ticks.count < 4000 { ticks.append(now - lastTick) }
        lastTick = now
    }

    /// A display-link frame reached the screen at `time` (0 = dropped).
    func presented(_ time: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard time > 0 else { dropped += 1; return }
        if lastShown > 0, time > lastShown, shown.count < 4000 { shown.append(time - lastShown) }
        lastShown = time
    }

    /// The link paused: the next interval starts fresh (a pause is not a hitch).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        lastTick = 0
        lastShown = 0
    }

    /// "ticks mean/max late n/N, shown mean/max late n/N dropped d @Hz" since the last call.
    func take(slot: Double, refresh: Double) -> String {
        lock.lock()
        let t = ticks, s = shown, d = dropped
        ticks.removeAll(keepingCapacity: true)
        shown.removeAll(keepingCapacity: true)
        dropped = 0
        lock.unlock()
        func summary(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let mean = v.reduce(0, +) / Double(v.count)
            let limit = (slot > 0 ? slot : mean) * 1.5
            return String(format: "mean %.1fms max %.1fms late %d/%d", mean * 1000,
                          (v.max() ?? 0) * 1000, v.filter { $0 > limit }.count, v.count)
        }
        return "ticks \(summary(t)) | shown \(summary(s)) dropped \(d) @\(Int(refresh))Hz"
    }
}
