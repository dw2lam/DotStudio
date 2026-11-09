//  MusicPlayers.swift — per-player knowledge: notification names, tolerant payload parsing,
//  and the handful of Apple Events DotStudio sends (reads + play/pause/next/previous).
//
//  Payloads (verified in Spotify 1.3.8 / Music 1.7.2 on macOS 27.2):
//    Spotify  com.spotify.client.PlaybackStateChanged
//             Name, Artist, Album, Duration (ms), Track ID (spotify:…), Playback Position (s),
//             Player State (Playing|Paused|Stopped)
//    Music    com.apple.Music.playerInfo (+ legacy com.apple.iTunes.playerInfo)
//             Name, Artist, Album, Total Time (ms), Player State, PersistentID (Int64),
//             Store URL (itms://…?i=<track id>), Location (local files) — and NO position.
//  Every field is optional and may arrive with the wrong type; parsing never fails.

import AppKit
import ScriptingBridge

enum MusicPlayState: String, Equatable {
    case playing, paused, stopped

    /// "Playing", "paused", "Fast Forwarding", … — nil when unrecognised.
    init?(text: String?) {
        guard let t = text?.lowercased() else { return nil }
        if t.contains("pause") { self = .paused }
        else if t.contains("stop") { self = .stopped }
        else if t.contains("play") || t.contains("forward") || t.contains("rewind") { self = .playing }
        else { return nil }
    }
}

/// One observation of a player, from a notification or an Apple Events read.
struct MusicReport: Equatable {
    enum Origin: Equatable { case notification, appleEvents }

    var source: MusicSource
    var origin: Origin = .notification
    var state: MusicPlayState?
    /// The payload carried track fields at all (a bare state change may not).
    var hasTrackFields = false
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds.
    var duration: Double?
    /// Seconds, measured when the report was made; nil = unknown (Music notifications).
    var position: Double?
    /// "spotify:track:…" / "music:<16-hex persistent id>".
    var trackID: String?
    /// Apple catalog ids parsed from Music's Store URL (`i=` track, `p=` album).
    var storeTrackID: String?
    var storeAlbumID: String?
    var isLocal = false
    var isAd = false
    var isEpisode = false

    var isEmptyTrack: Bool { (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum MusicCommand: String { case playPause, next, previous }

// MARK: - Tolerant value parsing

enum MusicPayload {
    /// Looks a key up ignoring case, spaces and underscores ("PersistentID" = "Persistent ID").
    static func value(_ info: [AnyHashable: Any], _ keys: String...) -> Any? {
        let wanted = Set(keys.map(normalize))
        for (k, v) in info {
            guard let ks = k as? String, wanted.contains(normalize(ks)) else { continue }
            if v is NSNull { return nil }
            return v
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" }
    }

    /// Text fields (Name/Artist/Album): strings only — a number where a title belongs is garbage.
    static func text(_ v: Any?) -> String? {
        (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        case let u as URL: return u.absoluteString
        default: return nil
        }
    }

    /// A finite, non-negative number from NSNumber or a numeric string.
    static func number(_ v: Any?) -> Double? {
        let d: Double?
        switch v {
        case let n as NSNumber:
            // Bools bridge to NSNumber too; a "true" duration is garbage.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            d = n.doubleValue
        case let s as String: d = Double(s.trimmingCharacters(in: .whitespaces))
        default: d = nil
        }
        guard let x = d, x.isFinite, x >= 0 else { return nil }
        return x
    }
}

// MARK: - Adapters

protocol MusicPlayerAdapter: Sendable {
    var source: MusicSource { get }
    var bundleID: String { get }
    /// Distributed notification names this player posts.
    var notificationNames: [String] { get }
    func parse(_ userInfo: [AnyHashable: Any]?) -> MusicReport

    // Apple Events — called on MusicAppleEvents.queue with a pid-addressed handle.
    /// Full state + track (~7 events). For launch/start and after permission is granted.
    func readSnapshot(_ app: SBApplication) -> MusicReport?
    /// Play state + position only (2 events) — the 1 Hz poll while a UI shows progress.
    func readPosition(_ app: SBApplication) -> (state: MusicPlayState?, position: Double?)
    /// The current track's artwork: bytes (Music) or a URL (Spotify). `expectedTrackID`
    /// guards against reading the NEXT track's art after a skip.
    func readArtwork(_ app: SBApplication, expectedTrackID: String?) -> MusicArtPayload?
    func send(_ command: MusicCommand, to app: SBApplication)
    func seek(to seconds: Double, in app: SBApplication)
}

enum MusicArtPayload: Sendable {
    case data(Data)
    case url(URL)
}

// MARK: Spotify

struct MusicSpotifyAdapter: MusicPlayerAdapter {
    let source = MusicSource.spotify
    let bundleID = "com.spotify.client"
    let notificationNames = ["com.spotify.client.PlaybackStateChanged"]

    func parse(_ userInfo: [AnyHashable: Any]?) -> MusicReport {
        var r = MusicReport(source: .spotify)
        guard let info = userInfo else { return r }
        r.state = MusicPlayState(text: MusicPayload.string(MusicPayload.value(info, "Player State", "PlayerState")))
        r.title = MusicPayload.text(MusicPayload.value(info, "Name"))
        r.artist = MusicPayload.text(MusicPayload.value(info, "Artist"))
        r.album = MusicPayload.text(MusicPayload.value(info, "Album"))
        if let ms = MusicPayload.number(MusicPayload.value(info, "Duration")), ms > 0 { r.duration = ms / 1000 }
        r.position = MusicPayload.number(MusicPayload.value(info, "Playback Position", "Player Position"))
        r.trackID = Self.normalizedURI(MusicPayload.text(MusicPayload.value(info, "Track ID", "TrackID", "Spotify URL")))
        r.hasTrackFields = r.title != nil || r.trackID != nil
        Self.classify(&r)
        return r
    }

    /// "spotify:track:ID", also accepting https://open.spotify.com/track/ID links.
    static func normalizedURI(_ raw: String?) -> String? {
        guard let s = raw, !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("spotify:") { return s }
        if let u = URLComponents(string: s), u.host?.hasSuffix("spotify.com") == true {
            let parts = u.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") }
            if parts.count >= 2 { return "spotify:\(parts[parts.count - 2]):\(parts[parts.count - 1])" }
        }
        return s
    }

    static func classify(_ r: inout MusicReport) {
        let id = (r.trackID ?? "").lowercased()
        r.isLocal = id.hasPrefix("spotify:local:")
        r.isAd = id.hasPrefix("spotify:ad:")
        r.isEpisode = id.hasPrefix("spotify:episode:")
        if r.isAd, r.isEmptyTrack { r.title = "Advertisement"; r.artist = r.artist ?? "Spotify" }
    }

    func readSnapshot(_ app: SBApplication) -> MusicReport? {
        let a = app as MusicSpotifyScriptable
        var r = MusicReport(source: .spotify, origin: .appleEvents)
        r.state = MusicPlayerStateCode.playState(a.playerState)
        guard r.state != nil else { return nil }   // the very first event failed: give up
        if r.state != .stopped, let t = a.currentTrack {
            r.hasTrackFields = true
            r.title = t.name
            r.artist = t.artist
            r.album = t.album
            if let ms = t.duration, ms > 0 { r.duration = Double(ms) / 1000 }
            r.trackID = Self.normalizedURI(t.id?())
            r.position = a.playerPosition
            Self.classify(&r)
        }
        return r
    }

    func readPosition(_ app: SBApplication) -> (state: MusicPlayState?, position: Double?) {
        let a = app as MusicSpotifyScriptable
        let state = MusicPlayerStateCode.playState(a.playerState)
        guard state != nil else { return (nil, nil) }
        return (state, a.playerPosition)
    }

    func readArtwork(_ app: SBApplication, expectedTrackID: String?) -> MusicArtPayload? {
        guard let t = (app as MusicSpotifyScriptable).currentTrack else { return nil }
        if let expected = expectedTrackID, let now = Self.normalizedURI(t.id?()), now != expected { return nil }
        guard let s = t.artworkUrl, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return nil }
        return .url(url)
    }

    func send(_ command: MusicCommand, to app: SBApplication) {
        let a = app as MusicSpotifyScriptable
        switch command {
        case .playPause: a.playpause?()
        case .next: a.nextTrack?()
        case .previous: a.previousTrack?()
        }
    }

    func seek(to seconds: Double, in app: SBApplication) {
        (app as MusicSpotifyScriptable).setPlayerPosition?(max(0, seconds))
    }
}

// MARK: Apple Music

struct MusicAppleMusicAdapter: MusicPlayerAdapter {
    let source = MusicSource.music
    let bundleID = "com.apple.Music"
    let notificationNames = ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]

    func parse(_ userInfo: [AnyHashable: Any]?) -> MusicReport {
        var r = MusicReport(source: .music)
        guard let info = userInfo else { return r }
        r.state = MusicPlayState(text: MusicPayload.string(MusicPayload.value(info, "Player State", "PlayerState")))
        r.title = MusicPayload.text(MusicPayload.value(info, "Name"))
        r.artist = MusicPayload.text(MusicPayload.value(info, "Artist"))
        r.album = MusicPayload.text(MusicPayload.value(info, "Album"))
        if let ms = MusicPayload.number(MusicPayload.value(info, "Total Time", "TotalTime")), ms > 0 { r.duration = ms / 1000 }
        // Not in today's payload; accepted if a future Music adds it.
        r.position = MusicPayload.number(MusicPayload.value(info, "Playback Position", "Player Position", "Elapsed Time"))
        if let pid = Self.persistentHex(MusicPayload.value(info, "PersistentID", "Persistent ID")) {
            r.trackID = "music:" + pid
        }
        let store = MusicPayload.string(MusicPayload.value(info, "Store URL", "StoreURL"))
        (r.storeTrackID, r.storeAlbumID) = Self.storeIDs(store)
        let location = MusicPayload.string(MusicPayload.value(info, "Location"))
        r.isLocal = r.storeTrackID == nil && r.storeAlbumID == nil
            && (location?.lowercased().hasPrefix("file:") ?? true)
        r.hasTrackFields = r.title != nil || r.trackID != nil
        return r
    }

    /// The payload's signed Int64 (or a string) → the same 16-digit uppercase hex that
    /// AppleScript's `persistent ID` returns, so both paths agree on the track id.
    static func persistentHex(_ v: Any?) -> String? {
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return String(format: "%016llX", UInt64(bitPattern: n.int64Value))
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if t.count == 16, t.allSatisfy(\.isHexDigit) { return t.uppercased() }
            if let i = Int64(t) { return String(format: "%016llX", UInt64(bitPattern: i)) }
            if let u = UInt64(t) { return String(format: "%016llX", u) }
            return t.uppercased()
        default: return nil
        }
    }

    /// itms://itunes.com/album?p=<album>&i=<track> or https://music.apple.com/…/<album>?i=<track>.
    static func storeIDs(_ raw: String?) -> (track: String?, album: String?) {
        guard let raw, let c = URLComponents(string: raw) else { return (nil, nil) }
        let items = c.queryItems ?? []
        func digits(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s.allSatisfy(\.isNumber), s != "0" else { return nil }
            return s
        }
        let track = digits(items.first { $0.name == "i" }?.value)
        var album = digits(items.first { $0.name == "p" }?.value)
        if album == nil, let last = c.path.split(separator: "/").last {
            let tail = last.hasPrefix("id") ? String(last.dropFirst(2)) : String(last)
            album = digits(tail)
        }
        return (track, album)
    }

    func readSnapshot(_ app: SBApplication) -> MusicReport? {
        let a = app as MusicAppleMusicScriptable
        var r = MusicReport(source: .music, origin: .appleEvents)
        r.state = MusicPlayerStateCode.playState(a.playerState)
        guard r.state != nil else { return nil }
        if r.state != .stopped, let t = a.currentTrack {
            r.hasTrackFields = true
            r.title = t.name
            r.artist = t.artist
            r.album = t.album
            if let d = t.duration, d > 0 { r.duration = d }
            if let pid = t.persistentID, !pid.isEmpty { r.trackID = "music:" + pid.uppercased() }
            r.position = a.playerPosition
        }
        return r
    }

    func readPosition(_ app: SBApplication) -> (state: MusicPlayState?, position: Double?) {
        let a = app as MusicAppleMusicScriptable
        let state = MusicPlayerStateCode.playState(a.playerState)
        guard state != nil else { return (nil, nil) }
        return (state, a.playerPosition)
    }

    func readArtwork(_ app: SBApplication, expectedTrackID: String?) -> MusicArtPayload? {
        let a = app as MusicAppleMusicScriptable
        guard let t = a.currentTrack else { return nil }
        let before = t.persistentID.map { "music:" + $0.uppercased() }
        if let expected = expectedTrackID, let before, before != expected { return nil }
        guard let arts = t.artworks?(), let first = arts.object(at: 0) as? SBObject else { return nil }
        let art = first as MusicAppleMusicArtworkScriptable
        var bytes: Data?
        switch art.rawData {
        case let d as Data: bytes = d
        case let desc as NSAppleEventDescriptor: bytes = desc.data
        default: break
        }
        if bytes == nil || bytes!.isEmpty, let image = art.data, image.isKind(of: NSImage.self) {
            bytes = image.tiffRepresentation
        }
        guard let data = bytes, !data.isEmpty else { return nil }
        // The art must still belong to the track we asked about (a skip mid-read).
        let after = a.currentTrack?.persistentID.map { "music:" + $0.uppercased() }
        if let before, let after, before != after { return nil }
        return .data(data)
    }

    func send(_ command: MusicCommand, to app: SBApplication) {
        let a = app as MusicAppleMusicScriptable
        switch command {
        case .playPause: a.playpause?()
        case .next: a.nextTrack?()
        case .previous: a.backTrack?()
        }
    }

    func seek(to seconds: Double, in app: SBApplication) {
        (app as MusicAppleMusicScriptable).setPlayerPosition?(max(0, seconds))
    }
}
