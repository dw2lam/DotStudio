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

// ScreensaverLineup and the pure lineup read/write live in Shared/AI/LibraryEdits.swift, so
// dotstudio-mcp edits a library exactly as these do.

extension AppModel {
    /// The screensaver's lineup, derived from the stored fields exactly as the saver reads them.
    var screensaverLineup: ScreensaverLineup { library.screensaverLineup }

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
        guard !library.presets.isEmpty else { return }
        library.applyLineup(lineup)
        if persist { save() }
    }

    /// Play only this style (the night pick, if any, stays).
    func playAsScreensaver(_ id: UUID) {
        // One display connected, with a style of its own: playing a style means there.
        let roster = DisplayRoster.shared.displays
        Breadcrumbs.note("screensaver lineup: \(crumbName(id))")
        library.playAsScreensaver(id, onlyDisplay: roster.count == 1 ? roster[0].key : nil)
        save()
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
