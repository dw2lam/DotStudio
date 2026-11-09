//  MusicSpec.swift — CONTRACT: the user's music settings, stored in library.json as
//  `Library.music` (optional, so older builds still decode the library). The saver reads them.
//  Accessors resolve defaults; the stored fields stay nil until the user changes something.
//
//  Defaults (owner decisions 2026-11-09): the music card shows on every screensaver style while
//  music plays; take-over is opt-in; card on the live wallpaper is opt-in; 5-minute paused linger;
//  Medium card size.

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

    /// How big the corner card is. The screensaver is read from across a room, so even Small
    /// is larger than a desktop widget (MusicGeometry.Card has the proportions).
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

    var cardEnabled: Bool?
    var cardCorner: Corner?
    var cardOnWallpaper: Bool?
    var takeOver: Bool?
    var source: SourcePreference?
    var lingerMinutes: Double?
    /// Added in 1.4 (optional: older builds ignore it and draw their own card size).
    var cardSize: CardSize?

    // Resolved values (defaults applied).
    var isCardEnabled: Bool { cardEnabled ?? true }
    var corner: Corner { cardCorner ?? .bottomLeft }
    var showsCardOnWallpaper: Bool { cardOnWallpaper ?? false }
    var takesOver: Bool { takeOver ?? false }
    var sourcePreference: SourcePreference { source ?? .auto }
    var linger: Double { lingerMinutes ?? 5 }
    var cardSizePreference: CardSize { cardSize ?? .medium }

    /// The card is drawn on the live wallpaper: "also on the live wallpaper" is part of the
    /// card, so it counts only while the card itself is on (the stored flag is kept for when
    /// the card comes back).
    var drawsCardOnWallpaper: Bool { isCardEnabled && showsCardOnWallpaper }

    /// True when any feature needs the app to watch players (and therefore keep running).
    /// Exactly what can show the result: the card (on the screensaver, and on the wallpaper
    /// only with it) or take-over — a stored wallpaper flag under a card that's off never does.
    var needsMonitoring: Bool { isCardEnabled || takesOver }
}

extension Library {
    /// The music settings with defaults applied (`music` stays nil until the user edits them).
    var musicSettings: MusicSpec { music ?? MusicSpec() }
}
