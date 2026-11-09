//  Studio2.swift — Sand Garden (shader id 68). See SceneCatalog.swift.
//  Shader: Shared/Scenes/Studio2_cases.h (+ helpers in Studio2_funcs.h).
//
//  A chrome ball ploughs theta-rho patterns through a round kinetic sand table, seen from
//  above. Stateless — a pure function of the time, clock and date — so every display and
//  the wallpaper show the same pattern at the same moment, and it never repeats hourly.
//  Follow the Sun takes the light from the real sun (u.sun / u.sky, as Ocean Horizon does);
//  the renderer fills those only for scenes it knows to be live (MetalRenderer.fillLiveSky).

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the slot-2 line of EffectKind.
    static let studio2: [EffectKind: SceneSpec] = [
        .sandGarden: SceneSpec(
            name: "Sand Garden",
            blurb: "A chrome ball draws slow patterns through a kinetic sand table under a low, warm light.",
            shaderID: 68,
            // Packed in order: p0 = (speed, pattern, groove, framing), p1 = (relief, angle, height, live).
            params: [ParamSpec("speed", "Speed", 0, 3, def: 1),
                     ParamSpec(menu: "pattern", "Pattern", ["Surprise", "Rosette", "Twist", "Petals", "Spiral"], def: 0),
                     ParamSpec("groove", "Groove Width", 0.5, 2, def: 1),
                     ParamSpec(menu: "framing", "Framing", ["Fill", "Table"], def: 0),
                     ParamSpec("relief", "Relief", 0, 1, def: 0.6),
                     ParamSpec("angle", "Light Angle", 0, 360, def: 215),
                     ParamSpec("height", "Light Height", 5, 60, def: 18),
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true)],
            colorA: RGBA(0.22, 0.13, 0.08), colorB: RGBA(0.91, 0.86, 0.77),
            colorALabel: "Wood", colorBLabel: "Sand"),
    ]

    /// Styles this scene adds to the default library.
    static var studio2Presets: [Preset] {
        func scene(_ name: String, _ params: [String: Double] = [:], a: RGBA? = nil, b: RGBA? = nil) -> Preset {
            var e = EffectInstance(.sandGarden)
            for (k, v) in params { e.params[k] = v }
            if let a { e.colorA = a }
            if let b { e.colorB = b }
            return Preset(name: name, effects: [e])
        }
        return [
            scene("Sand Garden", ["framing": 0, "pattern": 0, "angle": 215, "height": 18],
                  a: RGBA(0.22, 0.13, 0.08), b: RGBA(0.91, 0.86, 0.77)),
            // Basalt sand on a dark table: evening-friendly, the chrome ball the only highlight.
            scene("Black Sand", ["framing": 1, "pattern": 1, "angle": 140, "height": 12, "relief": 0.75],
                  a: RGBA(0.07, 0.055, 0.045), b: RGBA(0.20, 0.19, 0.18)),
        ]
    }
}
