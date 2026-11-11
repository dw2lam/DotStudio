//  Meadow.swift — the Meadow pack: one dreamy pastoral scene (shader id 78), shown with Nature.
//  See SceneCatalog.swift.
//
//  Meadow (78)  hazy, sun-drenched summer fields under a big sky: grass and wildflowers bending in
//               gusts that roll across the field, Tidewater's clouds drifting over and their
//               shadows sliding over the hills, bloom and halation, a fine film-like dither over it
//               all. Three landscapes (the Landscape menu): the open meadow, a low rise with a
//               cluster of trees, tall grass.
//
//  Time of day: Follow the Sun = the real sun and moon here (MetalRenderer.fillLiveSky, as
//  Tidewater); off, the Time of Day slider picks an hour of a midsummer day (fillLiveSky works out
//  that sun and a waxing moon). Time Lapse runs either clock forward. Weather: Live = the real
//  weather (Shared/Weather, fetched by the app), or a fixed condition; the wind also sets how
//  hard the grass blows.
//  Shaders: Meadow_funcs.h (meadow_*, reusing Tidewater's sky, sun, moon and stars and the
//  weather's rain, snow, fog and lightning), Meadow_cases.h.

import Foundation

extension SceneCatalog {
    /// Packed in order into p0.xyzw, p1.xyzw, p2.xyzw.
    // p0 = (speed, wind, flowers, clouds)  p1 = (follow the sun, time of day h, time lapse, weather)
    // p2 = (landscape, glow, dither)
    static let meadow: [EffectKind: SceneSpec] = [
        .meadow: SceneSpec(
            name: "Meadow",
            blurb: "Rolling summer fields in the wind under a big sky; can follow the real sun, moon and weather.",
            shaderID: 78,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("wind", "Wind", 0, 1, def: 0.5),
                     ParamSpec("flowers", "Wildflowers", 0, 1, def: 0.6),
                     ParamSpec("clouds", "Clouds", 0, 1, def: 0.5),
                     // Follow the Sun: the real sun and moon for this place and time (Time of Day
                     // is then ignored). Time Lapse = minutes per simulated day, 0 = real time.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 1, toggle: true),
                     ParamSpec("hour", "Time of Day", 0, 24, step: 0.25, def: 15.5),
                     ParamSpec("lapse", "Time Lapse", 0, 60, step: 1, def: 0),
                     // Weather: Live = the real weather here, or a fixed condition.
                     ParamSpec(menu: "weather", "Weather", WeatherMix.menu, def: 0),
                     ParamSpec(menu: "landscape", "Landscape", ["Meadow", "Lone Tree", "Tall Grass"], def: 0),
                     ParamSpec("glow", "Glow", 0, 1, def: 0.5),
                     ParamSpec("dither", "Dither", 0, 1, def: 0.5)],
            colorA: RGBA(0.50, 0.62, 0.25), colorB: RGBA(1.0, 0.80, 0.56),
            colorALabel: "Grass", colorBLabel: "Sunlight"),
    ]

    /// Styles this pack adds to the default library.
    static var meadowPresets: [Preset] {
        func scene(_ name: String, _ params: [String: Double]) -> Preset {
            var e = EffectInstance(.meadow)
            for (k, v) in params { e.params[k] = v }
            return Preset(name: name, effects: [e])
        }
        return [
            // The real day and the real weather over the open meadow.
            scene("Meadow", ["live": 1, "weather": 0, "landscape": 0]),
            // A summer afternoon by the trees on the rise, under whatever the sky is doing here.
            scene("Lone Tree", ["live": 0, "hour": 16.25, "weather": 0, "landscape": 1, "flowers": 0.45,
                                "clouds": 0.6]),
            // Low in tall grass at golden hour, always clear.
            scene("Tall Grass", ["live": 0, "hour": 18.9, "weather": 1, "landscape": 2, "wind": 0.6,
                                 "flowers": 0.35, "clouds": 0.4, "glow": 0.7]),
        ]
    }
}
