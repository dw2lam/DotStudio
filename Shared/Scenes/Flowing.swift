//  Flowing.swift — the Flowing scene pack (shader ids 54–57). See SceneCatalog.swift.
//
//  Calm, all-day generative pieces lit in linear light:
//    Currents   — thousands of luminous streamlines in four depth layers, with depth of field.
//    Lava Lamp  — glossy, backlit wax metaballs rising and sinking behind curved glass.
//    Ink Bloom  — ink drops blooming and curling through still water (Beer–Lambert absorption).
//    Fireflies  — fireflies over a dusk meadow, photographed with a shallow depth of field.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Flowing" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let flowing: [EffectKind: SceneSpec] = [
        .flowLines: SceneSpec(
            name: "Currents",
            blurb: "Thousands of luminous streamlines drifting in deep space.",
            shaderID: 54,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                     ParamSpec("density", "Density", 0.3, 2, def: 1.0),
                     ParamSpec("depth", "Depth of Field", 0, 1.5, def: 0.8),
                     ParamSpec("glow", "Glow", 0, 2, def: 1.0),
                     ParamSpec("hue", "Hue Spread", 0, 1, def: 0.35),
                     ParamSpec("pulse", "Pulses", 0, 1, def: 0.6)],
            colorA: RGBA(0.012, 0.016, 0.035), colorB: RGBA(0.45, 0.78, 1.0),
            colorALabel: "Background", colorBLabel: "Light"),
        .lavaLamp: SceneSpec(
            name: "Lava Lamp",
            blurb: "Glossy wax rising and falling through warm, backlit liquid.",
            shaderID: 55,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                     ParamSpec("blobs", "Blobs", 3, 10, step: 1, def: 7),
                     ParamSpec("size", "Size", 0.5, 1.6, def: 1.0),
                     ParamSpec("gloss", "Gloss", 0, 1, def: 0.7),
                     ParamSpec("heat", "Lamp Glow", 0, 2, def: 1.0),
                     ParamSpec("glass", "Glass", 0, 1, def: 1, toggle: true)],
            colorA: RGBA(0.10, 0.02, 0.08), colorB: RGBA(1.0, 0.36, 0.16),
            colorALabel: "Liquid", colorBLabel: "Wax"),
        .inkFluid: SceneSpec(
            name: "Ink Bloom",
            blurb: "Drops of ink blooming and curling through still water.",
            shaderID: 56,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                     ParamSpec("scale", "Scale", 0.5, 2, def: 1.0),
                     ParamSpec("curl", "Turbulence", 0, 1.5, def: 0.8),
                     ParamSpec("density", "Ink", 0.2, 2, def: 1.0),
                     ParamSpec("second", "Second Ink", 0, 1, def: 0.5)],
            colorA: RGBA(0.95, 0.93, 0.89), colorB: RGBA(0.06, 0.20, 0.62),
            colorALabel: "Water", colorBLabel: "Ink"),
        .fireflies: SceneSpec(
            name: "Fireflies",
            blurb: "Fireflies drifting over a dusk meadow, softly out of focus.",
            shaderID: 57,
            params: [ParamSpec("count", "Fireflies", 0.2, 2, def: 1.0),
                     ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                     ParamSpec("focus", "Focus", 0, 1, def: 0.35),
                     ParamSpec("blur", "Aperture", 0, 1.5, def: 0.9),
                     ParamSpec("size", "Glow", 0.5, 2, def: 1.0),
                     ParamSpec("meadow", "Meadow", 0, 1, def: 1, toggle: true)],
            colorA: RGBA(0.04, 0.06, 0.16), colorB: RGBA(1.0, 0.86, 0.38),
            colorALabel: "Dusk", colorBLabel: "Glow"),
    ]

    private static func flowingFX(_ kind: EffectKind, _ params: [String: Double],
                                  a: RGBA, b: RGBA) -> EffectInstance {
        var e = EffectInstance(kind)
        for (k, v) in params { e.params[k] = v }
        e.colorA = a; e.colorB = b
        return e
    }

    /// Styles this pack adds to the default library.
    static var flowingPresets: [Preset] {
        [
            Preset(name: "Currents",
                   effects: [flowingFX(.flowLines, ["speed": 0.6, "density": 1.0, "depth": 0.8, "glow": 1.0,
                                                    "hue": 0.35, "pulse": 0.6],
                                       a: RGBA(0.012, 0.016, 0.035), b: RGBA(0.45, 0.78, 1.0))]),
            Preset(name: "Solar Wind",
                   effects: [flowingFX(.flowLines, ["speed": 0.5, "density": 0.85, "depth": 1.0, "glow": 1.2,
                                                    "hue": 0.45, "pulse": 0.7],
                                       a: RGBA(0.025, 0.008, 0.012), b: RGBA(1.0, 0.58, 0.28))]),
            Preset(name: "Lava Lamp",
                   effects: [flowingFX(.lavaLamp, ["speed": 0.6, "blobs": 7, "size": 1.0, "gloss": 0.7,
                                                   "heat": 1.0, "glass": 1],
                                       a: RGBA(0.10, 0.02, 0.08), b: RGBA(1.0, 0.36, 0.16))]),
            Preset(name: "Ultraviolet Lamp",
                   effects: [flowingFX(.lavaLamp, ["speed": 0.5, "blobs": 6, "size": 1.15, "gloss": 0.8,
                                                   "heat": 1.1, "glass": 1],
                                       a: RGBA(0.07, 0.03, 0.20), b: RGBA(1.0, 0.30, 0.62))]),
            Preset(name: "Ink Bloom",
                   effects: [flowingFX(.inkFluid, ["speed": 0.6, "scale": 1.0, "curl": 0.8, "density": 1.0,
                                                   "second": 0.5],
                                       a: RGBA(0.95, 0.93, 0.89), b: RGBA(0.06, 0.20, 0.62))]),
            Preset(name: "Sumi",
                   effects: [flowingFX(.inkFluid, ["speed": 0.5, "scale": 1.15, "curl": 0.9, "density": 1.1,
                                                   "second": 0],
                                       a: RGBA(0.94, 0.92, 0.87), b: RGBA(0.09, 0.10, 0.13))]),
            Preset(name: "Fireflies",
                   effects: [flowingFX(.fireflies, ["count": 1.0, "speed": 0.6, "focus": 0.35, "blur": 0.9,
                                                    "size": 1.0, "meadow": 1],
                                       a: RGBA(0.04, 0.06, 0.16), b: RGBA(1.0, 0.86, 0.38))]),
            Preset(name: "Blue Hour",
                   effects: [flowingFX(.fireflies, ["count": 1.2, "speed": 0.5, "focus": 0.6, "blur": 1.1,
                                                    "size": 1.0, "meadow": 1],
                                       a: RGBA(0.02, 0.07, 0.15), b: RGBA(0.78, 1.0, 0.42))]),
        ]
    }
}
