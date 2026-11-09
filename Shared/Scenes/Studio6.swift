//  Studio6.swift — new-scene slot 6 (shader id 72): Dial Clock. See SceneCatalog.swift.
//
//  An analog clock as a lit object rather than a drawing: a watch dial seen square-on and
//  filling the screen, like a macro photograph. A sunray-brushed (or grained opaline) dial,
//  faceted applied batons, polished dauphine hands and a sweeping seconds hand, all lit by one
//  big soft key light whose direction follows the time of day, so the sunray's bow-tie of light
//  turns slowly from morning to evening and every part casts its own soft shadow.
//  The date sits in a framed window at 3 (its wheel rolls at midnight); the 24-hour option
//  prints 13–24 inside the batons. Day numbers and the 24-hour figures are SF Pro Light from
//  TextAtlas (shader id 72 is one of its users).
//  Shaders: Studio6_funcs.h (studio6_*), Studio6_cases.h.

import Foundation

extension SceneCatalog {
    /// Packed in order: p0 = (finish, hands, 24-hour, seconds), p1 = (date, size, shine, follow).
    static let studio6: [EffectKind: SceneSpec] = [
        .dialClock: SceneSpec(
            name: "Dial Clock",
            blurb: "A watch dial in soft studio light: sunray finish, polished hands, a sweeping seconds hand.",
            shaderID: 72,
            params: [ParamSpec(menu: "finish", "Dial", ["Sunray", "Grained"], def: 0),
                     ParamSpec(menu: "hands", "Hands", ["Steel", "Gold", "Blued"], def: 0),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("seconds", "Seconds", 0, 1, def: 1, toggle: true),
                     ParamSpec("date", "Date", 0, 1, def: 1, toggle: true),
                     ParamSpec("size", "Size", 0.7, 1.15, def: 1),
                     ParamSpec("shine", "Shine", 0, 1, def: 0.6),
                     ParamSpec("follow", "Follow the Sun", 0, 1, def: 1, toggle: true)],
            colorA: RGBA(0.035, 0.065, 0.15), colorB: RGBA(1.0, 0.47, 0.22),
            colorALabel: "Dial", colorBLabel: "Seconds Hand"),
    ]

    private static func dialFX(_ params: [String: Double], a: RGBA, b: RGBA) -> EffectInstance {
        var e = EffectInstance(.dialClock)
        for (k, v) in params { e.params[k] = v }
        e.colorA = a; e.colorB = b
        return e
    }

    /// Styles this scene adds to the default library.
    static var studio6Presets: [Preset] {
        [
            Preset(name: "Sunray",
                   effects: [dialFX(["finish": 0, "hands": 0, "h24": 0, "seconds": 1, "date": 1,
                                     "size": 1, "shine": 0.6, "follow": 1],
                                    a: RGBA(0.035, 0.065, 0.15), b: RGBA(1.0, 0.47, 0.22))]),
            Preset(name: "Opaline",
                   effects: [dialFX(["finish": 1, "hands": 2, "h24": 0, "seconds": 1, "date": 1,
                                     "size": 1, "shine": 0.6, "follow": 1],
                                    a: RGBA(0.93, 0.915, 0.88), b: RGBA(0.78, 0.20, 0.12))]),
        ]
    }
}
