//  Bloom.swift — the Bloom pack (shader id 79). See SceneCatalog.swift. Tagged Nature.
//
//  Bloom (79)  one flower, drawn procedurally and set in a grid of cells: tiny glyphs coloured
//              by the flower (Glyphs), rounded LED cells with gaps and a soft glow (Pixels), or a
//              round dot matrix (Dots).
//              Only the flower is celled; the sky behind it stays a smooth gradient. It sways
//              in a light breeze, slowly turns and nods, and now and then a petal flutters —
//              at 24 frames a second (the time is stepped in the shader, the styles ask 24 fps).
//              Flowers: Blue Poppy (Himalayan, Meconopsis), Baby's Breath (a gypsophila sprig),
//              White Anemone.
//  Shaders: Bloom_funcs.h (bloom_*), Bloom_cases.h. Captions (off by default) are TextAtlas
//  type, SF Pro Light (face 0); the atlas is only built while they are on.

import Foundation

extension SceneCatalog {
    /// Packed in order into p0.xyzw, p1.xyzw.
    static let bloomPack: [EffectKind: SceneSpec] = [
        // p0 = (flower, render, cell size, breeze), p1 = (sky gradient, glow, captions, size)
        .flowerBloom: SceneSpec(
            name: "Bloom",
            blurb: "A single flower swaying in a light breeze, set in tiny glyphs or glowing cells.",
            shaderID: 79,
            params: [ParamSpec(menu: "flower", "Flower", ["Blue Poppy", "Baby's Breath", "White Anemone"], def: 0),
                     ParamSpec(menu: "render", "Render", ["Glyphs", "Pixels", "Dots"], def: 0),
                     ParamSpec("cell", "Cell Size", 7, 24, def: 11),
                     ParamSpec("breeze", "Breeze", 0, 1, def: 0.5),
                     ParamSpec("gradient", "Sky Gradient", 0, 1, def: 1),
                     ParamSpec("glow", "Glow", 0, 1, def: 0.6),
                     ParamSpec("captions", "Captions", 0, 1, def: 0, toggle: true),
                     ParamSpec("size", "Size", 0.7, 1.25, def: 1)],
            colorA: RGBA(0.129, 0.278, 0.522), colorB: RGBA(0.16, 0.45, 0.86),
            colorALabel: "Sky", colorBLabel: "Petals"),
    ]

    /// Styles this pack adds to the default library. 24 fps: the filmic cadence they're made for.
    static var bloomPresets: [Preset] {
        func fx(_ params: [String: Double], a: RGBA, b: RGBA) -> EffectInstance {
            var e = EffectInstance(.flowerBloom)
            for (k, v) in params { e.params[k] = v }
            e.colorA = a
            e.colorB = b
            return e
        }
        return [
            // the blue the owner fell for: #214785 at the top to #72a3da at the bottom
            Preset(name: "Blue Bloom",
                   effects: [fx(["flower": 0, "render": 0, "cell": 11, "breeze": 0.5, "gradient": 1,
                                 "glow": 0.6, "captions": 0, "size": 1],
                                a: RGBA(0.129, 0.278, 0.522), b: RGBA(0.16, 0.45, 0.86))],
                   fps: 24),
            // warm dark grey #372e27, white clusters in glowing LED cells
            Preset(name: "Baby's Breath",
                   effects: [fx(["flower": 1, "render": 1, "cell": 11, "breeze": 0.45, "gradient": 0,
                                 "glow": 0.7, "captions": 0, "size": 1],
                                a: RGBA(0.216, 0.180, 0.153), b: RGBA(0.97, 0.96, 0.93))],
                   fps: 24),
            // a white anemone with its dark eye, in glowing cells, against a deeper evening blue
            Preset(name: "White Anemone",
                   effects: [fx(["flower": 2, "render": 1, "cell": 11, "breeze": 0.55, "gradient": 0.75,
                                 "glow": 0.55, "captions": 0, "size": 1],
                                a: RGBA(0.106, 0.169, 0.318), b: RGBA(0.95, 0.95, 0.97))],
                   fps: 24),
        ]
    }
}
