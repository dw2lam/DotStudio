//  Studio1.swift — new-scene slot 1 (shader id 67): Shallows. See SceneCatalog.swift for how
//  packs work. Shader: studio1_shallows in Shared/Scenes/Studio1_funcs.h (case in Studio1_cases.h).

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`shallows` on its own line in Effects.swift).
    static let studio1: [EffectKind: SceneSpec] = [
        .shallows: SceneSpec(
            name: "Shallows",
            blurb: "Clear knee-deep water over rippled sand, netted with sunlight.",
            shaderID: 67,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("depth", "Depth", 0, 1, def: 0.5),
                     ParamSpec("sea", "Sea State", 0, 1, def: 0.55),
                     ParamSpec("clarity", "Clarity", 0, 1, def: 0.75),
                     ParamSpec("sun", "Sun Height", 5, 85, def: 40),
                     // Live: the real sun (and at night the moon) for this place and time; Sun
                     // Height is then ignored. Time Lapse = minutes per simulated day, 0 = real time.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true),
                     ParamSpec("lapse", "Time Lapse", 0, 60, step: 1, def: 0),
                     ParamSpec("clouds", "Clouds", 0, 1, def: 0.3),
                     // Live = the real weather here (Shared/Weather), or a fixed condition.
                     ParamSpec(menu: "weather", "Weather", WeatherMix.menu, def: 0)],
            colorA: RGBA(0.92, 0.85, 0.73), colorB: RGBA(1.0, 0.96, 0.90),
            colorALabel: "Sand", colorBLabel: "Sunlight"),
    ]

    /// Styles this scene adds to the default library.
    static var studio1Presets: [Preset] {
        func scene(_ name: String, _ params: [String: Double], a: RGBA, b: RGBA) -> Preset {
            var e = EffectInstance(.shallows)
            for (k, v) in params { e.params[k] = v }
            e.colorA = a
            e.colorB = b
            return Preset(name: name, effects: [e])
        }
        return [
            scene("Shallows", ["sun": 40, "depth": 0.5, "sea": 0.55, "clarity": 0.8, "clouds": 0.3, "weather": 1],
                  a: RGBA(0.92, 0.85, 0.73), b: RGBA(1.0, 0.96, 0.90)),
            // Follow the Sun: the warm Sunlight shows at a low sun (nature_liveTint relaxes it
            // toward white daylight as the sun climbs).
            scene("Low Tide", ["live": 1, "sea": 0.3, "depth": 0.35, "clarity": 0.9, "clouds": 0.15, "weather": 0],
                  a: RGBA(0.88, 0.81, 0.70), b: RGBA(1.0, 0.80, 0.56)),
        ]
    }
}
