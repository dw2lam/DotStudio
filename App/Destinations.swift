//  Destinations.swift — the "where it plays" control model.
//
//  The gallery talks about destinations, not modes:
//    • Screensaver — a playlist of styles (one = a single style, several = they rotate),
//      plus an optional, different style at night.
//    • Wallpaper — off, or one style (WallpaperSlot.swift).
//
//  The saver still reads the same library.json, so the lineup is a VIEW over the stored
//  fields, never a new format:
//    playlist == [id]        → activeID = id, rotation.enabled = false (presetIDs = [id])
//    playlist.count >= 2     → rotation.enabled = true, rotation.presetIDs = playlist
//    night == id             → schedule.enabled = true, nightPresetID = id, dayPresetID = nil
//                              (by day the saver falls through to the playlist)
//    night == nil            → schedule.enabled = false (nightPresetID kept for next time)
//
//  Reading goes through Playback.pool — the exact function the saver uses — so ANY
//  existing library (old One Style / Rotate / Day & Night states included) reads
//  truthfully, and nothing is rewritten until the user changes something.

import Foundation

struct ScreensaverLineup: Equatable {
    /// What plays by day (or all day), in library order. Never empty for a non-empty library.
    var playlist: [UUID]
    /// A different single style after sunset; nil = the playlist plays all day.
    var night: UUID?

    var rotates: Bool { playlist.count > 1 }
    func contains(_ id: UUID) -> Bool { playlist.contains(id) || night == id }
}

extension AppModel {
    /// The screensaver's lineup, derived from the stored fields exactly as the saver reads them.
    var screensaverLineup: ScreensaverLineup {
        let day = Playback.pool(in: library, night: false).map(\.id)
        let nightPool = Playback.pool(in: library, night: true).map(\.id)
        // A night pool that equals the day pool is "no night style". A multi-style night
        // pool can't come out of any UI that ever shipped; show it as no night style.
        let night = (nightPool != day && nightPool.count == 1) ? nightPool.first : nil
        return ScreensaverLineup(playlist: day, night: night)
    }

    /// What the screensaver would show this very moment (same answer as the saver; music is
    /// presented over it, never instead of it).
    /// With every connected display on a style of its own (one display, pinned), that style
    /// (Playback.shownPreset).
    var nowPlayingID: UUID? {
        library.presets.isEmpty ? nil
            : Playback.shownPreset(in: library, now: Date(), displays: DisplayRoster.shared.displays.map(\.key)).id
    }

    var isNightNow: Bool { Playback.isNight(library) }

    // MARK: Writes

    /// Write a lineup in canonical stored form. Interval, shuffle and crossfade are kept.
    func applyLineup(_ lineup: ScreensaverLineup, persist: Bool = true) {
        Breadcrumbs.note("screensaver lineup: \(lineup.playlist.map { crumbName($0) }.joined(separator: ", "))"
                         + (lineup.night.map { " · night \(crumbName($0))" } ?? ""))
        guard let first = library.presets.first?.id else { return }
        let wanted = Set(lineup.playlist)
        var day = library.presets.map(\.id).filter(wanted.contains)   // library order, no strays
        if day.isEmpty { day = [first] }

        var rot = rotation
        rot.presetIDs = day
        rot.enabled = day.count > 1
        library.rotation = rot
        if day.count == 1 || !(library.activeID.map(day.contains) ?? false) {
            library.activeID = day[0]
        }

        var sch = schedule
        sch.dayPresetID = nil   // by day, fall through to the playlist
        if let n = lineup.night, library.presets.contains(where: { $0.id == n }) {
            sch.enabled = true
            sch.nightPresetID = n
        } else {
            sch.enabled = false
        }
        library.schedule = sch
        if persist { save() }
    }

    /// Play only this style (the night pick, if any, stays).
    func playAsScreensaver(_ id: UUID) {
        // One display connected, with a style of its own: playing a style means there.
        let roster = DisplayRoster.shared.displays
        if roster.count == 1, library.displayStyles?[roster[0].key] != nil {
            library.displayStyles?[roster[0].key] = nil
            if library.displayStyles?.isEmpty == true { library.displayStyles = nil }
        }
        var l = screensaverLineup
        l.playlist = [id]
        if l.night == id { l.night = nil }
        applyLineup(l)
    }

    func isInPlaylist(_ id: UUID) -> Bool { screensaverLineup.playlist.contains(id) }

    func addToPlaylist(_ id: UUID) {
        var l = screensaverLineup
        guard !l.playlist.contains(id) else { return }
        l.playlist.append(id)
        applyLineup(l)
    }

    /// Removing the last style isn't allowed — something always plays.
    func removeFromPlaylist(_ id: UUID) {
        var l = screensaverLineup
        guard l.playlist.count > 1, let i = l.playlist.firstIndex(of: id) else { return }
        l.playlist.remove(at: i)
        applyLineup(l)
    }

    func togglePlaylist(_ id: UUID) {
        isInPlaylist(id) ? removeFromPlaylist(id) : addToPlaylist(id)
    }

    /// Turn the night style on (remembered or suggested pick) or off.
    func setNightEnabled(_ on: Bool) {
        var l = screensaverLineup
        l.night = on ? (rememberedNightID ?? suggestedNightID(excluding: l.playlist)) : nil
        applyLineup(l)
    }

    func setNight(_ id: UUID?) {
        var l = screensaverLineup
        l.night = id
        applyLineup(l)
    }

    func setRotationInterval(_ minutes: Double) { updateRotation { $0.intervalMinutes = minutes } }
    func setShuffle(_ on: Bool) { updateRotation { $0.shuffle = on } }

    /// The night pick from the last time night was on, if that style still exists.
    private var rememberedNightID: UUID? {
        guard let id = library.schedule?.nightPresetID, preset(id) != nil else { return nil }
        return id
    }

    /// A dark, calm scene for the evening — or the first scene that isn't already playing.
    private func suggestedNightID(excluding: [UUID]) -> UUID? {
        let nightKinds: [EffectKind] = [.nightSky, .universe, .starfield, .blackhole, .aurora]
        let candidates = library.presets.filter { !excluding.contains($0.id) }
        for kind in nightKinds {
            if let p = candidates.first(where: { $0.leadKind == kind }) { return p.id }
        }
        return candidates.first(where: \.isScene)?.id ?? candidates.first?.id ?? library.presets.first?.id
    }
}

extension Preset {
    /// The effect that defines the style (the first enabled one).
    var leadKind: EffectKind? { (effects.first(where: \.enabled) ?? effects.first)?.kind }
}
