//  MusicState.swift — CONTRACT between the app's MusicMonitor (writer) and every renderer
//  (screensaver, live wallpaper, in-app previews, thumbnails) that shows what's playing.
//
//  Data flows one way: the unsandboxed app watches Spotify / Apple Music and writes
//    <SharedStore.baseDir>/music.json            — this struct, atomically
//    <SharedStore.baseDir>/music/<artwork>       — the current track's artwork (JPEG/PNG)
//  The sandboxed saver can read (never write) that folder. Live track data must NEVER go in
//  library.json: the saver re-applies the playing style whenever that file's mtime changes.
//
//  Naming: "Now playing / Playing" already means *the style on screen* elsewhere in the app
//  (AppModel.nowPlayingID, GalleryState.nowPlaying). Music code uses the `Music` prefix.
//
//  Every field is optional so older/newer writers and readers never fail to decode.

import Foundation

/// Which player the state came from. Unknown values decode as `.unknown`.
enum MusicSource: String, Codable, Equatable {
    case spotify, music, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicSource(rawValue: raw) ?? .unknown
    }

    /// The player's name in DotStudio's own UI ("Apple Music" — under a "Music" section, the
    /// bare app name would read as the generic word).
    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Apple Music"
        case .unknown: return "Music"
        }
    }

    /// The name macOS lists the player under in System Settings › Privacy & Security ›
    /// Automation — only for lines that send the owner there.
    var automationName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music, .unknown: return "Music"
        }
    }

    var bundleID: String? {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        case .unknown: return nil
        }
    }
}

struct MusicState: Codable, Equatable {
    static let fileName = "music.json"
    static let artDirName = "music"

    var source: MusicSource?
    var title: String?
    var artist: String?
    var album: String?
    /// Track length in seconds (0/nil for streams).
    var duration: Double?
    /// Playback position in seconds, measured at `positionAt`.
    var position: Double?
    /// Unix epoch seconds when `position` was measured. Readers extrapolate while playing.
    var positionAt: Double?
    /// True when the position is estimated (e.g. Apple Music without Automation permission —
    /// its notifications carry no position, so it's counted from track start).
    var positionIsApproximate: Bool?
    var isPlaying: Bool?
    /// Unix epoch seconds when playback paused (for the paused linger); nil while playing.
    var pausedAt: Double?
    /// File name inside `music/` (e.g. "art-3f2a….jpg"); nil = no artwork (draw a placeholder).
    var artwork: String?
    /// 3–5 dominant artwork colours in sRGB, brightest-first. Used for backgrounds and tints.
    var palette: [RGBA]?
    /// Stable per-track id (Spotify URI / Music persistent id). Changes ⇒ new track.
    var trackID: String?
    /// Podcast/long-form heuristic (duration > 15 min) — show ±15 s style progress.
    var isPodcast: Bool?
    /// Unix epoch seconds of the last write.
    var updatedAt: Double?
    /// Seconds between the writer's keep-alive rewrites while playing (`updatedAt` refreshes
    /// at least this often). Present ⇒ readers may treat a playing state whose `updatedAt` is
    /// much older as stale (the app crashed or was force-quit without clearing). Absent (1.3
    /// writers) ⇒ no such promise, no such rule.
    var heartbeat: Double?
}

extension MusicState {
    var hasTrack: Bool { !(title ?? "").isEmpty }

    /// Position extrapolated to `now`, clamped to the duration.
    func elapsed(at now: Date = Date()) -> Double {
        var p = position ?? 0
        if isPlaying == true, let at = positionAt { p += max(0, now.timeIntervalSince1970 - at) }
        if let d = duration, d > 0 { p = min(p, d) }
        return max(0, p)
    }

    /// 0…1 progress, or nil when the duration is unknown (streams).
    func progress(at now: Date = Date()) -> Double? {
        guard let d = duration, d > 0 else { return nil }
        return min(1, elapsed(at: now) / d)
    }

    /// Whether renderers should show the track: playing, or paused within the linger window.
    /// Stale writes (app quit without clearing) older than the linger window also hide it.
    func isVisible(at now: Date = Date(), lingerMinutes: Double) -> Bool {
        guard hasTrack else { return false }
        let t = now.timeIntervalSince1970
        if isPlaying == true {
            // A playing state whose track should have ended long ago is stale (app/player died).
            if let d = duration, d > 0, let at = positionAt, t - at > (d - (position ?? 0)) + 120 { return false }
            // A stream never ends on its own: rely on the writer's heartbeat instead.
            if isHeartbeatStale(at: now) { return false }
            return true
        }
        guard let paused = pausedAt ?? updatedAt else { return false }
        return t - paused < max(0, lingerMinutes) * 60
    }

    /// A playing state from a writer that promised a heartbeat but missed about two of them
    /// (crash, force quit, kill -9 — nothing cleared music.json). Only for duration-less
    /// streams; a track with a length goes stale by the rule above.
    func isHeartbeatStale(at now: Date = Date()) -> Bool {
        guard isPlaying == true, (duration ?? 0) <= 0, let hb = heartbeat, hb > 0, let at = updatedAt else { return false }
        return now.timeIntervalSince1970 - at > 2 * hb + 30
    }

    /// "1:23" / "12:05" / "1:02:03".
    static func timeString(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
