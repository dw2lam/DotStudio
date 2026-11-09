//  Playback.swift — which style the screensaver shows, as a pure function of the library.
//
//  Shared by the saver (what to render) and the app (what the gallery says is playing),
//  so the two can never disagree. Precedence: music take-over > day/night schedule >
//  rotation > active.
//
//  Music take-over (Library.music.takeOver, opt-in): while music is visible (playing, or
//  paused within the linger window — MusicSnapshot.isVisible), the lineup collapses to the
//  library's Now Playing style. Callers pass `musicActive` from their own MusicFeed; the
//  default `false` is the plain lineup.

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
    static func pool(in lib: Library, night: Bool, musicActive: Bool = false) -> [Preset] {
        guard let first = lib.presets.first else { return [] }
        if musicTakesOver(lib, musicActive: musicActive) { return [musicPreset(in: lib)] }
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
    /// coordination. Requires a non-empty library.
    static func effectivePreset(in lib: Library, now: Date, musicActive: Bool = false) -> Preset {
        let night = (lib.schedule?.enabled ?? false) && isNight(lib)
        let pool = pool(in: lib, night: night, musicActive: musicActive)
        let fallback = lib.presets.first { $0.id == lib.activeID } ?? lib.presets.first!
        guard pool.count > 1, let rot = lib.rotation else { return pool.first ?? fallback }
        let interval = max(rot.intervalMinutes, 0.25) * 60
        let slot = Int(now.timeIntervalSince1970 / interval)
        let idx = rot.shuffle ? shuffledIndex(slot: slot, count: pool.count) : slot % pool.count
        return pool[idx]
    }

    /// Whether music take-over is on and decides what's on screen right now.
    static func musicTakesOver(_ lib: Library, musicActive: Bool) -> Bool {
        musicActive && lib.musicSettings.takesOver && !lib.presets.isEmpty
    }

    /// The style music take-over plays: the active style if it is a Now Playing style, else
    /// the library's first one, else the built-in "Now Playing" (with a fixed id, so the
    /// saver doesn't see a "new" style on every poll) for a library that has none.
    static func musicPreset(in lib: Library) -> Preset {
        if let active = lib.presets.first(where: { $0.id == lib.activeID }), active.isMusicScene { return active }
        if let p = lib.presets.first(where: { $0.isMusicScene }) { return p }
        return builtInMusicPreset
    }

    static let builtInMusicPreset: Preset = {
        var p = SceneCatalog.musicPresets.first ?? Preset(name: "Now Playing", effects: [EffectInstance(.nowPlaying)])
        p.id = UUID(uuidString: "6D757369-6300-4000-8000-000000000066")!
        p.effects = p.effects.map { e in
            var e = e
            e.id = UUID(uuidString: "6D757369-6300-4000-8000-000000000067")!
            return e
        }
        return p
    }()

    /// Seconds until the rotation (or nothing) next changes what's on screen; nil = static.
    static func secondsUntilNextSlot(in lib: Library, now: Date) -> TimeInterval? {
        guard let rot = lib.rotation, rot.enabled else { return nil }
        let interval = max(rot.intervalMinutes, 0.25) * 60
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
