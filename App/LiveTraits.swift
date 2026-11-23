//  LiveTraits.swift — which styles change with the real world: the time (clocks, scenes that
//  follow the real sun) and the live weather. Shown as small icons beside a tile's name, and
//  those styles lead their gallery section.

import Foundation

struct LiveTraits: Equatable {
    /// Its light follows the real sun and sky (a scene with Live on, Universe's real planets).
    var sky = false
    /// Follows the live weather.
    var weather = false
    /// A clock (shows the time; no tag — that's plain to see — but it sorts after the live scenes).
    var clock = false
    var any: Bool { sky || weather || clock }

    /// Gallery order: live weather first (Golden Hour leads), then live sky, then clocks.
    var rank: Int { weather ? 0 : sky ? 1 : clock ? 2 : 3 }

    static func of(_ preset: Preset) -> LiveTraits {
        var t = LiveTraits()
        t.weather = WeatherLink.followsLive(preset)
        let on = preset.effects.filter(\.enabled)
        t.clock = on.contains { clockKinds.contains($0.kind) }
        t.sky = on.contains { followsSky($0) }
        return t
    }

    private static let clockKinds: Set<EffectKind> = Set(SceneCatalog.clocks.keys).union(SceneCatalog.standby.keys)

    /// A scene drawing the real sun (MetalRenderer.fillLiveSky's cases, with the same switches),
    /// or Universe (the planets' real positions).
    private static func followsSky(_ e: EffectInstance) -> Bool {
        switch e.kind {
        case .oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden: return (e.params["live"] ?? 0) > 0.5
        case .windowLight: return (e.params["follow"] ?? 1) > 0.5
        case .meadow, .universe: return true
        default: return false
        }
    }
}
