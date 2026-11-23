//  LiveTraits.swift — which styles change with the real world: the time (clocks, scenes that
//  follow the real sun) and the live weather. Shown as small icons beside a tile's name, and
//  those styles lead their gallery section.

import Foundation

struct LiveTraits: Equatable {
    var time = false
    var weather = false
    var any: Bool { time || weather }

    static func of(_ preset: Preset) -> LiveTraits {
        var t = LiveTraits()
        t.weather = WeatherLink.followsLive(preset)
        t.time = preset.effects.contains { $0.enabled && followsTime($0) }
        return t
    }

    private static let clockKinds: Set<EffectKind> = Set(SceneCatalog.clocks.keys).union(SceneCatalog.standby.keys)

    /// A clock, or a scene drawing the real sun (MetalRenderer.fillLiveSky's cases, with the
    /// same switches), or Universe (the planets' real positions).
    private static func followsTime(_ e: EffectInstance) -> Bool {
        if clockKinds.contains(e.kind) { return true }
        switch e.kind {
        case .oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden: return (e.params["live"] ?? 0) > 0.5
        case .windowLight: return (e.params["follow"] ?? 1) > 0.5
        case .meadow, .universe: return true
        default: return false
        }
    }
}
