//  tools/gallery/ClockChecks.swift — the minute-boundary checks of `gallery --checks`: what a
//  clock shows at exactly hh:mm:00.000 and at hh:mm:59.999.
//
//  1. FXUniforms.clock (MetalRenderer.wallClock): floor() of hour, minute and second is the time
//     at both instants, for every minute of a day (a Float of h + 59.99999/60 used to round up to
//     the next hour: "1:59" at 12:59:59.999).
//  2. A Custom Scene (the metal engine's ctx.clock, runtime-compiled with fast math): floor(clock /
//     3600), floor(clock / 60) mod 60 and the second, read back from the GPU, for every minute
//     (clock.x · 3600 used to read hh:mm:00 as the minute before, ~4 % of the minutes).
//  3. The digital clock styles as stills (thumbnails, previews: FXUniforms.still): hh:mm:00 shows
//     the same figures as hh:mm:59.999, and not the minute before's — the changeover that starts
//     on the minute is settled in a still — across hour, noon and midnight boundaries.

import AppKit
import Metal

func clockBoundaryChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = NSTimeZone.default
    // A day with no DST change, in the Mac's time zone.
    func at(_ h: Int, _ m: Int, _ s: Double, day: Int = 21) -> Date {
        let d = cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: h, minute: m, second: 0))!
        return d.addingTimeInterval(s)
    }
    let ends: [Double] = [59.999, 59.9999]

    // 1. The uniforms.
    do {
        var bad: [String] = []
        for h in 0..<24 {
            for m in 0..<60 {
                for (s, want) in [(0.0, 0)] + ends.map({ ($0, 59) }) {
                    let (c, _) = MetalRenderer.wallClock(at(h, m, s))
                    if Int(floor(c.x)) != h || Int(floor(c.y)) != m || Int(floor(c.z)) != want {
                        if bad.count < 4 { bad.append(String(format: "%02d:%02d:%06.3f → %.7f %.7f %.5f", h, m, s, c.x, c.y, c.z)) }
                    }
                }
            }
        }
        check(bad.isEmpty, "clock: FXUniforms.clock's hour, minute and second floor to the time at hh:mm:00 and hh:mm:59.999, every minute of a day \(bad)")
    }

    // 2. A Custom Scene's ctx.clock, on the GPU.
    if ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil,
       let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ds-clockprobe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        // Each value v (0…59) as (4v + 2) / 255: the engine's ±½-step dither can't move it out of v.
        writePackage(dir, manifest: ["format": 1, "id": "clock-probe-0000c10c", "name": "Clock Probe", "engine": ["id": "metal"],
                                     "entry": "scene.metal"],
                     files: ["scene.metal": """
                     #include <DotStudio.h>
                     float4 dsScene(float2 uv, DSContext ctx) {
                         float h = floor(ctx.clock / 3600.0);
                         float m = fmod(floor(ctx.clock / 60.0), 60.0);
                         float s = floor(fmod(ctx.clock, 60.0));
                         return float4((float3(h, m, s) * 4.0 + 2.0) / 255.0, 1.0);
                     }
                     """])
        r.waitsForScenePipelines = true
        if let id = try? CustomScenes.install(packageAt: dir, into: store.baseDir),
           let man = CustomScenes.manifest(id: id, store: store.baseDir) {
            let p = Preset.customScene(man)
            defer { try? CustomScenes.remove(id: id, store: store.baseDir) }
            func probe(_ d: Date) -> (Int, Int, Int)? {
                r.clockOverride = d
                guard let img = r.renderThumbnail(preset: p, source: SourceSpec(), width: 4, height: 4, time: 1),
                      let data = img.dataProvider?.data, CFDataGetLength(data) >= 4 else { return nil }
                let b = CFDataGetBytePtr(data)!
                return (Int(b[2]) / 4, Int(b[1]) / 4, Int(b[0]) / 4)    // BGRA
            }
            var bad: [String] = [], n = 0
            for h in 0..<24 {
                for m in 0..<60 {
                    for (s, want) in [(0.0, 0), (59.999, 59)] {
                        n += 1
                        let got = probe(at(h, m, s))
                        if got == nil || got! != (h, m, want), bad.count < 4 {
                            bad.append(String(format: "%02d:%02d:%06.3f → ", h, m, s) + (got.map { "\($0.0):\($0.1):\($0.2)" } ?? "no image"))
                        }
                    }
                }
            }
            r.clockOverride = nil
            check(bad.isEmpty, "clock: a Custom Scene's ctx.clock reads the hour, minute and second on the GPU at hh:mm:00 and hh:mm:59.999 (\(n) instants) \(bad)")
        } else {
            check(false, "clock: the clock probe package installs")
        }
    } else {
        print("SKIP  clock: the Custom Scene probe (DOTSTUDIO_STORE_DIR isn't set)")
    }

    // 3. The digital clock styles as stills.
    do {
        // Every digital clock kind, at its defaults (seconds off: they'd differ across a minute).
        let kinds: [EffectKind] = [.minimalClock, .standbyClock, .flipClock, .typeClock]
        let styles = kinds.map { k -> Preset in
            var e = EffectInstance(k)
            e.params["seconds"] = e.params["seconds"].map { _ in 0 }
            return Preset(name: k.displayName, effects: [e])
        }
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { check(false, "clock: a renderer"); return ok }
        r.waitsForScenePipelines = true
        func still(_ p: Preset, _ d: Date) -> CGImage? {
            r.clockOverride = d
            return r.renderThumbnail(preset: p, source: SourceSpec(), width: 480, height: 300, time: 4)
        }
        func diff(_ a: CGImage?, _ b: CGImage?) -> Double {
            guard let a, let b, a.width == b.width, a.height == b.height,
                  let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return .infinity }
            let n = min(CFDataGetLength(da), CFDataGetLength(db)), pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
            var s = 0
            for i in 0..<n where i % 4 != 3 { s += abs(Int(pa[i]) - Int(pb[i])) }
            return Double(s) / Double(n / 4 * 3)
        }
        // (hour, minute) of the minute that starts at hh:mm:00 — hour, noon and midnight boundaries
        // (the date turns over too), and some ordinary minutes.
        let minutes = [(0, 0), (1, 0), (9, 59), (10, 0), (12, 0), (12, 34), (13, 0), (17, 41), (19, 9), (23, 59)]
        for p in styles {
            var bad: [String] = [], worst = 0.0, margin = Double.infinity
            for (h, m) in minutes {
                let start = still(p, at(h, m, 0))
                let end = still(p, at(h, m, 59.999))
                let prevEnd = still(p, at(h, m, 0).addingTimeInterval(-0.001))
                let same = diff(start, end), prev = diff(start, prevEnd)
                worst = max(worst, same); margin = min(margin, prev)
                // the minute's two ends match; the minute before differs, by far more
                if !(same * 4 < prev && prev > 0.3) {
                    bad.append(String(format: "%02d:%02d (Δ same minute %.2f, Δ minute before %.2f)", h, m, same, prev))
                }
            }
            check(bad.isEmpty, String(format: "clock: “%@” as a still shows hh:mm at hh:mm:00 and hh:mm:59.999, not the minute before (Δ ≤ %.2f vs ≥ %.2f) %@",
                                      p.name, worst, margin, bad.description))
        }
        r.clockOverride = nil
    }
    return ok
}
