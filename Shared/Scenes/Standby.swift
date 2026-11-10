//  Standby.swift — the StandBy pack: three quiet clocks (shader ids 75–77), shown with the
//  Clocks (StyleFilter tags them so). See SceneCatalog.swift.
//
//  StandBy (75)     huge rounded figures on black, the way a phone on its side shows the time;
//                   deep red after sunset (the live sun: MetalRenderer.fillLiveSky).
//  Minimal (76)     thin SF Pro Light time with the weekday and date in small tracked capitals,
//                   lots of room around it, on black, paper or a soft gradient.
//  Chronometer (77) a wristwatch dial filling the screen: sunburst-brushed dial, applied
//                   faceted batons, dauphine hands, a sweeping seconds hand, a date window at 3,
//                   lume that glows after dark. No maker's name or mark — just the watch.
//
//  All three are stateless (a pure function of the wall clock: saver, wallpaper, preview and
//  thumbnail agree) and drift a few pixels over the hour against burn-in (clockkit_drift).
//  Type is TextAtlas SDF type: StandBy sets SF Pro Rounded Heavy (face 4), Minimal and the
//  Chronometer's date SF Pro Light (face 0).
//  Shaders: Standby_funcs.h (standby_*), Standby_cases.h; shared pieces in ClockKit_funcs.h.

import Foundation

extension SceneCatalog {
    /// Packed in order into p0.xyzw, p1.xyzw.
    static let standby: [EffectKind: SceneSpec] = [
        // p0 = (style, night mode, 24-hour, seconds), p1.x = size
        .standbyClock: SceneSpec(
            name: "StandBy",
            blurb: "The time in huge rounded figures on black; it turns a deep red after sunset.",
            shaderID: 75,
            params: [ParamSpec(menu: "style", "Style", ["Solid", "Outline", "Gradient"], def: 0),
                     ParamSpec(menu: "night", "Night Mode", ["Auto", "On", "Off"], def: 0),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("seconds", "Seconds", 0, 1, def: 0, toggle: true),
                     ParamSpec("size", "Size", 0.6, 1, def: 1)],
            colorA: RGBA(0.96, 0.96, 0.97), colorB: RGBA(0.44, 0.50, 0.62),
            colorALabel: "Figures", colorBLabel: "Gradient"),
        // p0 = (background, size, date, 24-hour), p1 = (seconds, alignment)
        .minimalClock: SceneSpec(
            name: "Minimal",
            blurb: "Thin, quiet time with the day and date beneath it, and room to breathe.",
            shaderID: 76,
            params: [ParamSpec(menu: "background", "Background", ["Black", "Paper", "Soft Gradient"], def: 0),
                     ParamSpec("size", "Time Size", 0.6, 1.5, def: 1),
                     ParamSpec("date", "Date", 0, 1, def: 1, toggle: true),
                     ParamSpec("h24", "24-Hour", 0, 1, def: 0, toggle: true),
                     ParamSpec("seconds", "Seconds", 0, 1, def: 0, toggle: true),
                     ParamSpec(menu: "align", "Alignment", ["Center", "Lower Left"], def: 0)],
            colorA: RGBA(0.93, 0.92, 0.90), colorB: RGBA(0.20, 0.26, 0.38),
            colorALabel: "Text", colorBLabel: "Gradient"),
        // p0 = (dial, date window, seconds, lume)
        .watchClock: SceneSpec(
            name: "Chronometer",
            blurb: "A fine wristwatch dial: sunburst finish, polished hands, a sweeping seconds hand.",
            shaderID: 77,
            params: [ParamSpec(menu: "dial", "Dial", ["Black", "Blue", "Silver", "Green", "Champagne"], def: 1),
                     ParamSpec("date", "Date Window", 0, 1, def: 1, toggle: true),
                     ParamSpec(menu: "seconds", "Seconds", ["Sweep", "Off"], def: 0),
                     ParamSpec(menu: "lume", "Lume", ["Glow at Night", "Off"], def: 0)]),
    ]

    /// Styles this pack adds to the default library (in the Clocks).
    static var standbyPresets: [Preset] {
        func fx(_ kind: EffectKind, _ params: [String: Double], a: RGBA? = nil, b: RGBA? = nil) -> EffectInstance {
            var e = EffectInstance(kind)
            for (k, v) in params { e.params[k] = v }
            if let a { e.colorA = a }
            if let b { e.colorB = b }
            return e
        }
        return [
            Preset(name: "StandBy",
                   effects: [fx(.standbyClock, ["style": 0, "night": 0, "h24": 0, "seconds": 0, "size": 1],
                                a: RGBA(0.96, 0.96, 0.97), b: RGBA(0.44, 0.50, 0.62))]),
            Preset(name: "Minimal",
                   effects: [fx(.minimalClock, ["background": 0, "size": 1, "date": 1, "h24": 0,
                                                "seconds": 0, "align": 0],
                                a: RGBA(0.93, 0.92, 0.90), b: RGBA(0.20, 0.26, 0.38))]),
            Preset(name: "Chronometer",
                   effects: [fx(.watchClock, ["dial": 1, "date": 1, "seconds": 0, "lume": 0])]),
        ]
    }
}
