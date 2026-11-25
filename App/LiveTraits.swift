//  LiveTraits.swift — which styles change with the real world: the time (clocks, scenes that
//  follow the real sun) and the live weather. Shown as small icons beside a tile's name, and
//  those styles lead their gallery section.

import Foundation

struct LiveTraits: Equatable {
    /// Its light follows the real sun and sky (a scene with Live on, Universe's real planets).
    var sky = false
    /// Follows the live weather.
    var weather = false
    /// Separate day and night videos switching at sunrise and sunset (a film of variant clips):
    /// fixed pictures, not a sky that moves — "Day & night", not "Live sky".
    var dayNight = false
    /// A clock (shows the time; no tag — that's plain to see — but it sorts after the live scenes).
    var clock = false
    var any: Bool { sky || weather || clock || dayNight }

    /// Gallery order: live weather first (Golden Hour leads), then live sky, then clocks.
    var rank: Int { weather ? 0 : (sky || dayNight) ? 1 : clock ? 2 : 3 }

    static func of(_ preset: Preset) -> LiveTraits {
        var t = LiveTraits()
        let on = preset.effects.filter(\.enabled)
        // Built-in film packages, read once up front: a style's own manifest is only known to
        // customUses after something has drawn it, so the gallery would miss them at first.
        let builtInWeather = on.contains { e in
            e.kind == .custom && CustomFilm.pinnedCondition(e) == nil && Self.builtInFilms[e.custom?.id ?? ""] == true
        }
        t.weather = WeatherLink.followsLive(preset) || builtInWeather
        t.clock = on.contains { clockKinds.contains($0.kind) }
        // Films: light layers are re-lit from the real sun (Live sky); variant clips only switch
        // between day and night videos (Day & night). Pinned to a time of day: neither.
        var layered = false, clips = false
        for e in on where e.kind == .custom && CustomFilm.timeMode(e) == 0 {
            guard let id = e.custom?.id,
                  let m = Self.builtInFilmManifests[id] ?? CustomScenes.knownManifest(id: id), m.engine.id == "film" else { continue }
            if m.layers != nil { layered = true } else { clips = true }
        }
        t.sky = on.contains { followsSky($0) } || layered
        t.dayNight = clips && !t.sky
        return t
    }

    /// Built-in film scenes (Shared/Films) by id → whether they follow the live weather (a rain
    /// clip, light layers, or "uses": weather). Every film follows the sun.
    private static let builtInFilmManifests: [String: CustomSceneManifest] = Dictionary(uniqueKeysWithValues:
        CustomScenes.builtInManifests().filter { $0.engine.id == "film" }.map { ($0.id, $0) })

    private static let builtInFilms: [String: Bool] = Dictionary(uniqueKeysWithValues:
        CustomScenes.builtInManifests().filter { $0.engine.id == "film" }.map { m in
            (m.id, m.usesSet.contains("weather") || m.layers != nil
                || (m.clips ?? []).contains { $0.variant.lowercased() == "rain" })
        })

    private static let clockKinds: Set<EffectKind> = Set(SceneCatalog.clocks.keys).union(SceneCatalog.standby.keys)

    /// A scene drawing the real sun (MetalRenderer.fillLiveSky's cases, with the same switches),
    /// or Universe (the planets' real positions).
    private static func followsSky(_ e: EffectInstance) -> Bool {
        switch e.kind {
        case .oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden: return (e.params["live"] ?? 0) > 0.5
        case .windowLight: return (e.params["follow"] ?? 1) > 0.5
        case .meadow: return (e.params["live"] ?? 1) > 0.5     // Time of Day: Live, not a fixed hour (Tall Grass)
        case .universe: return true
        default: return false
        }
    }
}
