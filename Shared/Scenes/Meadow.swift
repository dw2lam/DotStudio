//  Meadow.swift — the Meadow pack: one dreamy pastoral scene (shader id 78), shown with Nature.
//  See SceneCatalog.swift.
//
//  Meadow (78)  summer hills in the wind, after the owner's references: vivid green rolling hills
//               form-shaded against a deep blue sky, big bright cumulus, wildflowers on tall stems
//               at the lens, backlit golden-hour grass, a film finish (halation, grain, a fine
//               dither). Four landscapes (the Landscape menu), one preset each:
//                 Meadow         a flowery foreground before rolling hills (cypresses on the ridge);
//                 Rolling Hills  smooth velvet domes overlapping into the distance, seen from above;
//                 Tall Grass     low in long grass at golden hour;
//                 Hillside       a steep wind-swept slope above the sea, a towering cloud.
//               By day the view faces away from the sun (hills modelled in side light, the sky
//               deepest blue ahead); as the sun gets low it swings round to face it (backlit gold),
//               and faces the moon's arc by night.
//  Cost (tools/gallery --gpubench, M5 Pro, 5120×2880, clear): Meadow ~5.9 ms, Rolling Hills ~3.2,
//  Tall Grass ~7.0, Hillside ~3.2 (Tidewater 4.7); 1920×1080 (the wallpaper's Balanced scale on a
//  5K display) 0.4–1.0. Each landscape is its own pipeline, clear and weather (Weather_fragment.h).
//  Weather adds ~60–75 % (Tall Grass under heavy snow ~16 ms at 5K), so the screensaver caps its
//  drawable to keep a frame near 6 ms of GPU (WeatherLink.costNsPerPixel → MetalRenderer.costCapScale).
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
                     ParamSpec("flowers", "Wildflowers", 0, 1, def: 0.7),
                     ParamSpec("clouds", "Clouds", 0, 1, def: 0.5),
                     // Follow the Sun: the real sun and moon for this place and time (Time of Day
                     // is then ignored). Time Lapse = minutes per simulated day, 0 = real time.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 1, toggle: true),
                     ParamSpec("hour", "Time of Day", 0, 24, step: 0.25, def: 15.5),
                     ParamSpec("lapse", "Time Lapse", 0, 60, step: 1, def: 0),
                     // Weather: Live = the real weather here, or a fixed condition.
                     ParamSpec(menu: "weather", "Weather", WeatherMix.menu, def: 0),
                     ParamSpec(menu: "landscape", "Landscape", ["Meadow", "Rolling Hills", "Tall Grass", "Hillside"], def: 0),
                     ParamSpec("glow", "Glow", 0, 1, def: 0.5),
                     ParamSpec("dither", "Dither", 0, 1, def: 0.5)],
            colorA: RGBA(0.50, 0.70, 0.16), colorB: RGBA(1.0, 0.82, 0.58),
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
            scene("Meadow", ["live": 1, "weather": 0, "landscape": 0, "flowers": 0.8]),
            // Smooth green hills in the mid-morning light, under whatever the sky is doing here.
            scene("Rolling Hills", ["live": 0, "hour": 10.5, "weather": 0, "landscape": 1, "flowers": 0.2,
                                    "clouds": 0.45, "wind": 0.6]),
            // Low in tall grass at golden hour, always clear.
            scene("Tall Grass", ["live": 0, "hour": 18.9, "weather": 1, "landscape": 2, "wind": 0.6,
                                 "flowers": 0.35, "clouds": 0.4, "glow": 0.7]),
            // A wind-swept slope above the sea, a towering cloud building: a summer afternoon.
            scene("Hillside", ["live": 0, "hour": 15.0, "weather": 0, "landscape": 3, "wind": 0.85,
                               "flowers": 0, "clouds": 0.55, "glow": 0.55]),
        ]
    }
}
