//  Nature.swift — the Nature scene pack (shader ids 58–61). See SceneCatalog.swift.
//  Shaders: Shared/Scenes/Nature_cases.h (+ helpers in Nature_funcs.h). All four render in
//  linear light and tone-map once, so glows, reflections and fog add up like real light.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Nature" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let nature: [EffectKind: SceneSpec] = [
        .rainGlass: SceneSpec(
            name: "Rain on Glass",
            blurb: "Raindrops bead and run down a window over a blurred city at night.",
            shaderID: 58,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("rain", "Rain", 0, 1, def: 0.6),
                     ParamSpec("fog", "Condensation", 0, 1, def: 0.6),
                     ParamSpec("blur", "City Blur", 0, 1, def: 0.7)],
            colorA: RGBA(0.05, 0.07, 0.12), colorB: RGBA(1.0, 0.70, 0.40),
            colorALabel: "Night", colorBLabel: "City Lights"),
        .oceanHorizon: SceneSpec(
            name: "Ocean Horizon",
            blurb: "Open sea at golden hour, or live: the real sun, moon and weather crossing the day.",
            shaderID: 59,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("sun", "Sun Height", -2, 12, def: 4),
                     ParamSpec("waves", "Sea State", 0, 1, def: 0.45),
                     ParamSpec("clouds", "Clouds", 0, 1, def: 0.55),
                     ParamSpec("haze", "Haze", 0, 1, def: 0.55),
                     // Live: the real sun and moon for this place and time (Sun Height is
                     // then ignored). Time Lapse = minutes per simulated day, 0 = real time.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true),
                     ParamSpec("lapse", "Time Lapse", 0, 60, step: 1, def: 0),
                     // Weather: Live = the real weather here (Shared/Weather, fetched by the
                     // app), or a fixed condition. Lightning: storms flash (rare, soft).
                     ParamSpec(menu: "weather", "Weather", WeatherMix.menu, def: 0),
                     ParamSpec("lightning", "Lightning", 0, 1, def: 1, toggle: true)],
            colorA: RGBA(0.02, 0.09, 0.13), colorB: RGBA(1.0, 0.85, 0.62),
            colorALabel: "Deep Water", colorBLabel: "Sunlight"),
        .nightSky: SceneSpec(
            name: "Night Sky",
            blurb: "The Milky Way wheeling over a ridge, with tonight's moon phase.",
            shaderID: 60,
            params: [ParamSpec("speed", "Rotation", 0, 4, def: 1),
                     ParamSpec("milky", "Milky Way", 0, 1.5, def: 1),
                     ParamSpec("stars", "Stars", 0, 1.5, def: 1),
                     ParamSpec("moon", "Moon", 0, 1, def: 1),
                     ParamSpec("meteors", "Meteors", 0, 1, def: 0.4)],
            colorA: RGBA(0.025, 0.04, 0.085), colorB: RGBA(1.0, 0.62, 0.36),
            colorALabel: "Night Sky", colorBLabel: "Horizon Glow"),
        .snowfall: SceneSpec(
            name: "Snowfall",
            blurb: "Snow drifting through lamplight at the edge of a quiet forest.",
            shaderID: 61,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("amount", "Snow", 0, 1, def: 0.6),
                     ParamSpec("wind", "Wind", -1, 1, def: 0.25),
                     ParamSpec("light", "Lamp", 0, 1.5, def: 1),
                     ParamSpec("focus", "Depth of Field", 0, 1, def: 0.6)],
            colorA: RGBA(0.10, 0.14, 0.24), colorB: RGBA(1.0, 0.72, 0.42),
            colorALabel: "Dusk", colorBLabel: "Lamplight"),
    ]

    /// Styles this pack adds to the default library.
    static var naturePresets: [Preset] {
        func scene(_ name: String, _ kind: EffectKind, _ params: [String: Double] = [:],
                   a: RGBA? = nil, b: RGBA? = nil) -> Preset {
            var e = EffectInstance(kind)
            for (k, v) in params { e.params[k] = v }
            if let a { e.colorA = a }
            if let b { e.colorB = b }
            return Preset(name: name, effects: [e])
        }
        return [
            // Golden Hour keeps its low gold sun whatever the sky does; the live weather
            // changes the clouds, light and sea around it. Afterlight stays clear.
            scene("Golden Hour", .oceanHorizon, ["weather": 0]),
            scene("Tidewater", .oceanHorizon, ["live": 1, "weather": 0]),
            scene("Afterlight", .oceanHorizon, ["sun": -1.2, "waves": 0.3, "clouds": 0.75, "haze": 0.5, "weather": 1],
                  a: RGBA(0.02, 0.06, 0.12), b: RGBA(1.0, 0.70, 0.62)),
            scene("Night Sky", .nightSky),
            scene("Rainy Window", .rainGlass),
            scene("First Snow", .snowfall),
        ]
    }
}
