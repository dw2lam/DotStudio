//  Clocks.swift — the Clocks scene pack (shader ids 50–53). See SceneCatalog.swift.
//  Type is real system typography: TextAtlas.swift bakes SF Pro / New York / SF Rounded into
//  signed distance fields that the shaders in Clocks_cases.h set at any size.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Clocks" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let clocks: [EffectKind: SceneSpec] = [
        .typeClock: SceneSpec(
            name: "Type Clock",
            blurb: "The time, set huge in SF Pro or New York, lit by a light that follows the sun.",
            shaderID: 50,
            params: [ParamSpec(menu: "style", "Style", ["Relief", "Glass", "Ink"], def: 0),
                     ParamSpec(menu: "face", "Typeface", ["Sans", "Serif", "Rounded"], def: 0),
                     ParamSpec("weight", "Weight", 0, 1, def: 0.5),
                     ParamSpec("size", "Size", 0.5, 1.3, def: 1),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("seconds", "Seconds", 0, 1, def: 0, toggle: true),
                     ParamSpec("date", "Date", 0, 1, def: 1, toggle: true),
                     ParamSpec("depth", "Depth", 0, 1, def: 0.5)],
            colorA: RGBA(0.86, 0.84, 0.80), colorB: RGBA(0.88, 0.86, 0.82),
            colorALabel: "Background", colorBLabel: "Numerals"),
        .flipClock: SceneSpec(
            name: "Flip Clock",
            blurb: "A split-flap clock whose flaps really fall, with light and shadow.",
            shaderID: 51,
            params: [ParamSpec(menu: "face", "Typeface", ["Grotesk", "Rounded", "Serif"], def: 0),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("seconds", "Seconds", 0, 1, def: 0, toggle: true),
                     ParamSpec("date", "Date", 0, 1, def: 1, toggle: true),
                     ParamSpec("size", "Size", 0.5, 1.25, def: 1)],
            colorA: RGBA(0.14, 0.14, 0.15), colorB: RGBA(0.93, 0.91, 0.87),
            colorALabel: "Cards", colorBLabel: "Numerals"),
        .wordClock: SceneSpec(
            name: "Word Clock",
            blurb: "Spells the time in a glowing letter grid: just after ten, nearly half past.",
            shaderID: 52,
            params: [ParamSpec(menu: "face", "Typeface", ["Sans", "Serif", "Rounded"], def: 0),
                     ParamSpec("weight", "Weight", 0, 1, def: 0.3),
                     ParamSpec("glow", "Glow", 0, 1, def: 0.6),
                     ParamSpec("unlit", "Unlit Letters", 0, 0.4, def: 0.12),
                     ParamSpec("period", "Time of Day", 0, 1, def: 1, toggle: true),
                     ParamSpec("size", "Size", 0.5, 1.15, def: 1)],
            colorA: RGBA(0.035, 0.035, 0.04), colorB: RGBA(1.0, 0.86, 0.66),
            colorALabel: "Panel", colorBLabel: "Lit Letters"),
        .windowLight: SceneSpec(
            name: "Window Light",
            blurb: "Sun through a window drifts across a quiet wall with the day, leaves swaying in it.",
            shaderID: 53,
            params: [ParamSpec(menu: "face", "Typeface", ["Serif", "Sans", "Rounded"], def: 0),
                     ParamSpec(menu: "layout", "Layout", ["Left", "Centered"], def: 0),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("date", "Date", 0, 1, def: 1, toggle: true),
                     ParamSpec("leaves", "Leaves", 0, 1, def: 0.6),
                     ParamSpec("follow", "Follow the Sun", 0, 1, def: 1, toggle: true),
                     ParamSpec("sway", "Breeze", 0, 2, def: 1),
                     ParamSpec("size", "Type Size", 0.6, 1.4, def: 1)],
            colorA: RGBA(0.80, 0.76, 0.70), colorB: RGBA(1.0, 0.88, 0.70),
            colorALabel: "Wall", colorBLabel: "Sunlight"),
    ]

    /// Styles this pack adds to the default library.
    static var clocksPresets: [Preset] {
        func fx(_ kind: EffectKind, _ params: [String: Double], a: RGBA, b: RGBA) -> EffectInstance {
            var e = EffectInstance(kind)
            for (k, v) in params { e.params[k] = v }
            e.colorA = a; e.colorB = b
            return e
        }
        return [
            Preset(name: "Glass Clock",
                   effects: [fx(.typeClock, ["style": 1, "face": 2, "weight": 0.55, "depth": 0.6],
                                a: RGBA(0.02, 0.03, 0.07), b: RGBA(0.35, 0.45, 1.0))]),
            Preset(name: "Plaster Clock",
                   effects: [fx(.typeClock, ["style": 0, "face": 0, "weight": 0.5, "depth": 0.6],
                                a: RGBA(0.86, 0.84, 0.80), b: RGBA(0.88, 0.86, 0.82))]),
            Preset(name: "Flip Clock",
                   effects: [fx(.flipClock, ["face": 0, "h24": 0, "seconds": 0, "date": 1],
                                a: RGBA(0.14, 0.14, 0.15), b: RGBA(0.93, 0.91, 0.87))],
                   fps: 60),                                    // the falling flaps want 60 fps
            Preset(name: "Ivory Flip",
                   effects: [fx(.flipClock, ["face": 0, "h24": 1, "seconds": 1, "date": 1],
                                a: RGBA(0.93, 0.91, 0.86), b: RGBA(0.13, 0.13, 0.14))],
                   fps: 60),
            Preset(name: "Word Clock",
                   effects: [fx(.wordClock, ["face": 0, "weight": 0.3, "glow": 0.6, "unlit": 0.12, "period": 1],
                                a: RGBA(0.035, 0.035, 0.04), b: RGBA(1.0, 0.86, 0.66))]),
            Preset(name: "Printed Words",
                   effects: [fx(.wordClock, ["face": 1, "weight": 0.45, "glow": 0.0, "unlit": 0.1, "period": 1],
                                a: RGBA(0.94, 0.93, 0.89), b: RGBA(0.12, 0.12, 0.13))]),
            Preset(name: "Window Light",
                   effects: [fx(.windowLight, ["face": 0, "layout": 0, "leaves": 0.6, "follow": 1, "sway": 1],
                                a: RGBA(0.80, 0.76, 0.70), b: RGBA(1.0, 0.88, 0.70))]),
        ]
    }
}
