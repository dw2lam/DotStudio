//  Studio3.swift — PLEATS (new-scene slot 3, shader id 69). See SceneCatalog.swift.
//
//  A macro of accordion-pleated material — paper, satin, linen, or a paper lantern lit from
//  behind — raked by a warm key light, with a slow compression wave breathing through the
//  folds. Shaders: Shared/Scenes/Studio3_cases.h (+ Studio3_funcs.h). A 2D shader: the
//  pleat cross-section is shaded in closed form (Lambert key with attached and cast shadows,
//  sky fill, the warm bounce between facing facets, translucency, GGX and sheen), filtered
//  across the pixel and the depth-of-field blur, in linear light → ACES.

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`pleats`, on its own line in Effects.swift).
    static let studio3: [EffectKind: SceneSpec] = [
        .pleats: SceneSpec(
            name: "Pleats",
            blurb: "A macro of pleated paper, satin or linen under a raking light, or a lantern glowing at dusk.",
            shaderID: 69,
            params: [ParamSpec("pleats", "Pleats", 20, 120, step: 1, def: 32),
                     ParamSpec("depth", "Depth", 0, 1, def: 0.7),
                     ParamSpec("breathe", "Breathe", 0, 1, def: 0.5),
                     ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec(menu: "material", "Material", ["Paper", "Satin", "Linen", "Lantern"], def: 0),
                     ParamSpec("light", "Light Angle", -90, 90, def: -35),
                     ParamSpec("focus", "Depth of Field", 0, 1, def: 0.5),
                     // Live: the key light follows the real sun (azimuth from the hour, elevation
                     // and colour from the sky); after sunset a dim cool lamp takes over.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true)],
            colorA: RGBA(0.90, 0.86, 0.79), colorB: RGBA(1.0, 0.86, 0.68),
            colorALabel: "Material", colorBLabel: "Light"),
    ]

    /// Styles this scene adds to the default library.
    static var studio3Presets: [Preset] {
        func scene(_ name: String, _ params: [String: Double] = [:], a: RGBA? = nil, b: RGBA? = nil) -> Preset {
            var e = EffectInstance(.pleats)
            for (k, v) in params { e.params[k] = v }
            if let a { e.colorA = a }
            if let b { e.colorB = b }
            return Preset(name: name, effects: [e])
        }
        return [
            scene("Pleats", ["material": 0],
                  a: RGBA(0.90, 0.86, 0.79), b: RGBA(1.0, 0.86, 0.68)),
            scene("Graphite Satin", ["material": 1, "pleats": 46, "depth": 0.65, "light": 40, "focus": 0.4],
                  a: RGBA(0.15, 0.15, 0.16), b: RGBA(0.80, 0.88, 1.0)),
            scene("Paper Lantern", ["material": 3, "pleats": 30, "depth": 0.7, "breathe": 0.45, "light": -50, "focus": 0.35],
                  a: RGBA(0.95, 0.92, 0.86), b: RGBA(1.0, 0.82, 0.62)),
        ]
    }
}
