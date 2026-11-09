//  MusicSpec.swift — CONTRACT: the user's music settings, stored in library.json as
//  `Library.music` (optional, so older builds still decode the library). The saver reads them.
//  Accessors resolve defaults; the stored fields stay nil until the user changes something.
//
//  Music is a presentation over whatever screensaver is on screen, never a screensaver of its
//  own (owner, 2026-11-09): "Show music" is Off, Corner (the default) or Full Screen. Full
//  Screen draws the big Album layout over the style, with the artwork's living art behind it
//  (the default) or the style itself, blurred and dimmed. MusicPresentation turns these
//  settings plus the feed into what every renderer host shows.
//
//  Compatibility: `display` (1.4) is add-only. A library without it maps the fields older
//  builds wrote — `takeOver == true` ⇒ Full Screen (take-over was the explicit "show it full
//  screen" choice, so it wins over a card that was off); else `cardEnabled == false` ⇒ Off;
//  else Corner. Writes keep those legacy fields in step (`setDisplay`), so an older build
//  reading the same library behaves as close as it can.

import Foundation

struct MusicSpec: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case bottomLeft, bottomRight, topLeft, topRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Corner(rawValue: raw) ?? .bottomLeft
        }
    }

    enum SourcePreference: String, Codable, CaseIterable, Identifiable {
        case auto, spotify, music
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .spotify: return "Spotify"
            case .music: return "Apple Music"
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = SourcePreference(rawValue: raw) ?? .auto
        }
    }

    /// How big the corner presentation is. The screensaver is read from across a room, so
    /// even Small is larger than a desktop widget (MusicGeometry.Card has the proportions).
    enum CardSize: String, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = CardSize(rawValue: raw) ?? .medium
        }
    }

    /// "Show music": how what's playing appears over the screensaver.
    enum Display: String, Codable, CaseIterable, Identifiable {
        case off, corner, fullScreen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .corner: return "Corner"
            case .fullScreen: return "Full Screen"
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Display(rawValue: raw) ?? .corner
        }
    }

    /// "Behind the music" in Full Screen.
    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        /// The artwork as slowly moving colour fields (the Now Playing scene's Living Art).
        case albumArt
        /// The screensaver keeps playing behind, softly blurred and dimmed (the veil pass).
        case screensaver
        var id: String { rawValue }
        var label: String {
            switch self {
            case .albumArt: return "Album Art"
            case .screensaver: return "Your Screensaver"
            }
        }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Backdrop(rawValue: raw) ?? .albumArt
        }
    }

    /// Full Screen's arrangement. Cover (add-only: a build that predates it decodes it as
    /// Album) is the artwork itself filling the screen, type bottom-left — so it is its own
    /// background and ignores "Behind the music" (`usesBackdrop`).
    enum FullLayout: String, Codable, CaseIterable, Identifiable {
        case album, stage, cover
        var id: String { rawValue }
        var label: String {
            switch self {
            case .album: return "Album"
            case .stage: return "Stage"
            case .cover: return "Cover"
            }
        }
        var kind: MusicLayoutKind {
            switch self {
            case .album: return .album
            case .stage: return .stage
            case .cover: return .cover
            }
        }
        /// Whether "Behind the music" applies (Cover's artwork is the whole screen).
        var usesBackdrop: Bool { self != .cover }
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = FullLayout(rawValue: raw) ?? .album
        }
    }

    // Stored (legacy, 1.3): kept for older builds and the compatibility mapping.
    var cardEnabled: Bool?
    var cardCorner: Corner?
    var cardOnWallpaper: Bool?
    var takeOver: Bool?
    var source: SourcePreference?
    var lingerMinutes: Double?
    /// Added in 1.4 (optional: older builds ignore it and draw their own card size).
    var cardSize: CardSize?
    /// Added in 1.4: "Show music". nil = mapped from cardEnabled / takeOver.
    var display: Display?
    /// Added in 1.4: "Behind the music" (Full Screen). nil = Album Art.
    var fullBackdrop: Backdrop?
    /// Added in 1.4: Full Screen's layout. nil = Album.
    var fullLayout: FullLayout?

    // Resolved values (defaults applied).
    var displayMode: Display {
        if let display { return display }
        if takeOver == true { return .fullScreen }
        if cardEnabled == false { return .off }
        return .corner
    }
    var corner: Corner { cardCorner ?? .bottomLeft }
    var showsOnWallpaper: Bool { cardOnWallpaper ?? false }
    var sourcePreference: SourcePreference { source ?? .auto }
    var linger: Double { lingerMinutes ?? 5 }
    var cardSizePreference: CardSize { cardSize ?? .medium }
    var backdrop: Backdrop { fullBackdrop ?? .albumArt }
    var layout: FullLayout { fullLayout ?? .album }

    /// Full Screen's foreground options (the Now Playing scene's, minus the per-style knobs).
    var fullOptions: MusicSceneOptions {
        var o = MusicSceneOptions()
        o.layout = layout.kind
        return o
    }

    /// Music shows on the live wallpaper too: "Also on the live wallpaper" counts only while
    /// music shows at all (the stored flag is kept for when it comes back).
    var drawsOnWallpaper: Bool { displayMode != .off && showsOnWallpaper }

    /// True when any feature needs the app to watch players (and therefore keep running).
    /// A stored wallpaper flag under "Show music: Off" never does.
    var needsMonitoring: Bool { displayMode != .off }

    /// Set "Show music", keeping the legacy fields an older build reads in step with it.
    mutating func setDisplay(_ d: Display) {
        display = d
        switch d {
        case .off: cardEnabled = false; takeOver = nil
        case .corner: cardEnabled = nil; takeOver = nil
        case .fullScreen: cardEnabled = nil; takeOver = true
        }
    }
}

extension Library {
    /// The music settings with defaults applied (`music` stays nil until the user edits them).
    var musicSettings: MusicSpec { music ?? MusicSpec() }
}
