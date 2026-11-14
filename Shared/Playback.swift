//  Playback.swift — which style the screensaver shows, as a pure function of the library.
//
//  Shared by the saver (what to render) and the app (what the gallery says is playing),
//  so the two can never disagree. Precedence: a display's own style (Library.displayStyles) >
//  the active When rule (Library.rules, decided by the app and leased in signal-values.json —
//  Shared/Signals) > day/night schedule > rotation > active.
//
//  `live` (the SignalState every host reads; the app passes its own) is deliberately NOT
//  defaulted, so every caller says where its rule decision comes from — nil = no rules (a
//  thumbnail, a preview, a tool that never looks at them).
//
//  Music never changes the lineup: it is a presentation over whatever style plays here
//  (MusicPresentation), and the style keeps playing behind it.

import Foundation

enum Playback {
    /// True after civil sunset at the library's location (or the default location).
    static func isNight(_ lib: Library) -> Bool {
        var loc: (lat: Double, lon: Double)?
        if let la = lib.locationLat, let lo = lib.locationLon { loc = (la, lo) }
        return MetalRenderer.solarElevation(location: loc) < (-0.833 * .pi / 180)
    }

    /// The styles eligible to play at one time of day, before a rotation slot is picked.
    /// One element = that style plays; several = they rotate. Empty only for an empty library.
    static func pool(in lib: Library, night: Bool) -> [Preset] {
        guard let first = lib.presets.first else { return [] }
        let fallback = lib.presets.first { $0.id == lib.activeID } ?? first
        if let sched = lib.schedule, sched.enabled,
           let id = night ? sched.nightPresetID : sched.dayPresetID,
           let preset = lib.presets.first(where: { $0.id == id }) {
            return [preset]
        }
        guard let rot = lib.rotation, rot.enabled else { return [fallback] }
        if let ids = rot.presetIDs, !ids.isEmpty {
            let allowed = Set(ids)
            let filtered = lib.presets.filter { allowed.contains($0.id) }
            if !filtered.isEmpty { return filtered }
        }
        return lib.presets
    }

    /// The style on screen at `now`. Every display computes the same answer with no
    /// coordination. An empty library (every style deleted, or only styles a newer build
    /// made) plays an empty style — black — rather than crashing the screensaver host.
    static func effectivePreset(in lib: Library, now: Date, live: SignalState?) -> Preset {
        // A When rule playing now (its lease unexpired, the rule enabled, its styles here) wins
        // over the lineup; several styles rotate with the playlist's interval and shuffle.
        if let active = lib.activeRule(live: live, now: now) {
            let pool = active.styles
            guard pool.count > 1 else { return pool[0] }
            let interval = max(lib.rotation?.intervalMinutes ?? RotationSpec().intervalMinutes, 0.25) * 60
            let slot = Int(saturating: now.timeIntervalSince1970 / interval)
            let idx = (lib.rotation?.shuffle ?? false) ? shuffledIndex(slot: slot, count: pool.count) : slot % pool.count
            return pool[idx]
        }
        let night = (lib.schedule?.enabled ?? false) && isNight(lib)
        let pool = pool(in: lib, night: night)
        let fallback = lib.presets.first { $0.id == lib.activeID } ?? lib.presets.first ?? Preset(name: "Empty")
        guard pool.count > 1, let rot = lib.rotation else { return pool.first ?? fallback }
        let interval = max(rot.intervalMinutes, 0.25) * 60
        let slot = Int(saturating: now.timeIntervalSince1970 / interval)
        let idx = rot.shuffle ? shuffledIndex(slot: slot, count: pool.count) : slot % pool.count
        return pool[idx]
    }

    /// The style on screen at `now` on one display (DisplayIdentity.key): its own style when
    /// it has one that still exists (Library.displayStyles), else the lineup's, as above. nil
    /// (a display not known yet, the System Settings thumbnail) = the lineup's.
    static func effectivePreset(in lib: Library, now: Date, display: String?, live: SignalState?) -> Preset {
        lib.pinnedPreset(display: display) ?? effectivePreset(in: lib, now: now, live: live)
    }

    /// Seconds until the rotation (or nothing) next changes what's on screen; nil = static.
    static func secondsUntilNextSlot(in lib: Library, now: Date, live: SignalState?) -> TimeInterval? {
        let ruleRotates = (lib.activeRule(live: live, now: now)?.styles.count ?? 0) > 1
        guard ruleRotates || (lib.rotation?.enabled ?? false) else { return nil }
        let interval = max(lib.rotation?.intervalMinutes ?? RotationSpec().intervalMinutes, 0.25) * 60
        let t = now.timeIntervalSince1970
        return interval - t.truncatingRemainder(dividingBy: interval)
    }

    /// Deterministic shuffle: each round of `count` slots is a seeded Fisher–Yates
    /// permutation, so no preset repeats until all have shown — and displays agree.
    static func shuffledIndex(slot: Int, count: Int) -> Int {
        let round = slot / count, pos = slot % count
        var order = Array(0..<count)
        var state = UInt64(bitPattern: Int64(round)) &* 2654435761 &+ 0x9E3779B97F4A7C15
        for i in stride(from: count - 1, to: 0, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            order.swapAt(i, Int(state % UInt64(i + 1)))
        }
        return order[pos]
    }
}
