//  LibraryEdits.swift — pure library edits shared by the app (AppModel) and dotstudio-mcp.
//
//  The app runs these on its in-memory library (then saves and does its UI side effects:
//  selection, wallpaper, thumbnails); dotstudio-mcp runs the same functions on library.json
//  when the app isn't running. One implementation, so the AI's edits land exactly as a click
//  in the app would.

import Foundation

/// The screensaver's lineup (Destinations.swift): what plays by day, and an optional night style.
struct ScreensaverLineup: Equatable {
    /// What plays by day (or all day), in library order. Never empty for a non-empty library.
    var playlist: [UUID]
    /// A different single style after sunset; nil = the playlist plays all day.
    var night: UUID?

    var rotates: Bool { playlist.count > 1 }
    func contains(_ id: UUID) -> Bool { playlist.contains(id) || night == id }
}

extension Library {
    /// The screensaver's lineup, derived from the stored fields exactly as the saver reads them.
    var screensaverLineup: ScreensaverLineup {
        let day = Playback.pool(in: self, night: false).map(\.id)
        let nightPool = Playback.pool(in: self, night: true).map(\.id)
        // A night pool that equals the day pool is "no night style". A multi-style night
        // pool can't come out of any UI that ever shipped; show it as no night style.
        let night = (nightPool != day && nightPool.count == 1) ? nightPool.first : nil
        return ScreensaverLineup(playlist: day, night: night)
    }

    /// Write a lineup in canonical stored form. Interval, shuffle and crossfade are kept.
    mutating func applyLineup(_ lineup: ScreensaverLineup) {
        guard let first = presets.first?.id else { return }
        let wanted = Set(lineup.playlist)
        var day = presets.map(\.id).filter(wanted.contains)   // library order, no strays
        if day.isEmpty { day = [first] }

        var rot = rotation ?? RotationSpec()
        rot.presetIDs = day
        rot.enabled = day.count > 1
        rotation = rot
        if day.count == 1 || !(activeID.map(day.contains) ?? false) {
            activeID = day[0]
        }

        var sch = schedule ?? ScheduleSpec()
        sch.dayPresetID = nil   // by day, fall through to the playlist
        if let n = lineup.night, presets.contains(where: { $0.id == n }) {
            sch.enabled = true
            sch.nightPresetID = n
        } else {
            sch.enabled = false
        }
        schedule = sch
    }

    /// Remove a style and move every reference to it (active, rotation, schedule, lineup,
    /// per-display pins). False = no such style.
    @discardableResult
    mutating func removePreset(_ id: UUID) -> Bool {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return false }
        // Read the lineup before the style disappears, then write it back without it.
        let before = screensaverLineup
        presets.remove(at: idx)
        if activeID == id { activeID = presets.first?.id }
        rotation?.presetIDs?.removeAll { $0 == id }
        if schedule?.dayPresetID == id { schedule?.dayPresetID = nil }
        if schedule?.nightPresetID == id { schedule?.nightPresetID = nil }
        if before.contains(id), !presets.isEmpty {
            var after = before
            after.playlist.removeAll { $0 == id }
            if after.night == id { after.night = nil }
            applyLineup(after)
        }
        pruneDisplayStyles()
        return true
    }

    /// A name no style has yet: `base`, else "base 2", "base 3"…
    func uniqueName(_ base: String) -> String {
        let names = Set(presets.map(\.name) + unknownPresets.map(\.preset.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A copy of a style with fresh ids, inserted after it. Returns the copy.
    mutating func duplicatePreset(_ id: UUID, name: String? = nil) -> Preset? {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = presets[i]
        copy.id = UUID()
        copy.name = uniqueName(name ?? presets[i].name + " Copy")
        copy.effects = copy.effects.map { var e = $0; e.id = UUID(); return e }
        presets.insert(copy, at: i + 1)
        return copy
    }

    /// The screensaver plays only this style (the night pick stays unless it's this style).
    /// `onlyDisplay`: the single connected display's key — a style of its own there is cleared
    /// first (AppModel.playAsScreensaver).
    mutating func playAsScreensaver(_ id: UUID, onlyDisplay: String? = nil) {
        if let key = onlyDisplay, displayStyles?[key] != nil {
            displayStyles?[key] = nil
            if displayStyles?.isEmpty == true { displayStyles = nil }
        }
        var l = screensaverLineup
        l.playlist = [id]
        if l.night == id { l.night = nil }
        applyLineup(l)
    }
}
