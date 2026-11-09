//  Studio5.swift — new-scene slot 5 (shader id 71): Soap Film. See SceneCatalog.swift.
//
//  A macro of a vertical soap film against black velvet, lit only by a big soft panel
//  behind the camera, so every colour is thin-film interference: black film at the top,
//  then the Newton / Michel-Lévy sequence (silver, straw, gold, magenta, peacock, emerald…)
//  washing to silvery white where the film is thick. The thickness is a drainage profile
//  carried by a slow incompressible flow (backward-advected over a fixed window, so it is
//  continuous in time), with thin plumes breaking off the bottom margin. Colour is spectral:
//  the two-beam Airy reflectance integrated against the CIE 1931 observer (tabulated over
//  optical path), damped over each pixel's thickness footprint so steep high orders wash
//  to white instead of aliasing.
//  Film = Oil: a thin oil layer (n 1.50) on dark water (1.33), drifting with a current.
//  Shaders: Studio5_funcs.h (studio5_*), Studio5_cases.h.

import Foundation

extension SceneCatalog {
    /// Packed in order: p0 = (speed, swirl, drain, plumes), p1 = (film, scale, panel).
    static let studio5: [EffectKind: SceneSpec] = [
        .soapFilm: SceneSpec(
            name: "Soap Film",
            blurb: "A draining soap film in soft light: real interference colour, folded by slow eddies.",
            shaderID: 71,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("swirl", "Turbulence", 0, 1, def: 0.55),
                     ParamSpec("drain", "Drainage", 0, 1, def: 0.5),
                     ParamSpec("plumes", "Plumes", 0, 1, def: 0.5),
                     ParamSpec(menu: "film", "Film", ["Soap", "Oil"], def: 0),
                     ParamSpec("scale", "Scale", 0.5, 2, def: 1),
                     ParamSpec("panel", "Light Size", 0, 1, def: 0.6)],
            colorA: RGBA(0.006, 0.006, 0.008), colorB: RGBA(1.0, 0.98, 0.95),
            colorALabel: "Ground", colorBLabel: "Light"),
    ]

    private static func soapFX(_ params: [String: Double], a: RGBA, b: RGBA) -> EffectInstance {
        var e = EffectInstance(.soapFilm)
        for (k, v) in params { e.params[k] = v }
        e.colorA = a; e.colorB = b
        return e
    }

    /// Styles this scene adds to the default library.
    static var studio5Presets: [Preset] {
        [
            Preset(name: "Soap Film",
                   effects: [soapFX(["speed": 1, "swirl": 0.55, "drain": 0.5, "plumes": 0.5, "film": 0,
                                     "scale": 1, "panel": 0.6],
                                    a: RGBA(0.006, 0.006, 0.008), b: RGBA(1.0, 0.98, 0.95))]),
            Preset(name: "Oil Slick",
                   effects: [soapFX(["speed": 1, "swirl": 0.4, "drain": 0.5, "plumes": 0.2, "film": 1,
                                     "scale": 1.3, "panel": 0.6],
                                    a: RGBA(0.015, 0.02, 0.025), b: RGBA(0.80, 0.84, 0.90))]),
        ]
    }
}
