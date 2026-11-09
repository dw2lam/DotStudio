//  Studio4.swift — new-scene slot 4 (shader id 70): Dichroic. See SceneCatalog.swift.
//  Shader: Shared/Scenes/Studio4_cases.h (+ helpers in Studio4_funcs.h). Analytic ray tracing in
//  linear light: dichroic glass panes (a quarter-wave reflect band, 12 wavelengths) turning in a
//  plaster cove, throwing transmitted and reflected colour casts; tone-mapped once.

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`dichroic`, on its own line in Effects.swift).
    /// Params pack in order: p0 = (panes, speed, glass, shapes), p1 = (sun, dir, live, room).
    static let studio4: [EffectKind: SceneSpec] = [
        .dichroic: SceneSpec(
            name: "Dichroic",
            blurb: "Dichroic glass panes turn slowly in a sunlit gallery, throwing colour across the floor and wall.",
            shaderID: 70,
            params: [ParamSpec("panes", "Panes", 1, 5, step: 1, def: 3),
                     ParamSpec("speed", "Turn Speed", 0, 2, def: 1),
                     ParamSpec(menu: "glass", "Glass", ["Mixed", "Magenta/Green", "Cyan/Gold", "Blue/Amber"], def: 0),
                     ParamSpec(menu: "shape", "Shapes", ["Mixed", "Rectangles", "Discs", "Arches"], def: 0),
                     ParamSpec("sun", "Sun Height", 10, 70, def: 40),
                     ParamSpec("dir", "Sun Direction", -60, 60, def: -30),
                     // Live: the real sun for this place and time (Sun Height and Direction are
                     // then ignored); after sunset the room crossfades to the gallery spot.
                     ParamSpec("live", "Follow the Sun", 0, 1, def: 0, toggle: true),
                     ParamSpec(menu: "room", "Room", ["Gallery White", "Warm Concrete", "Black Box"], def: 0)],
            colorA: RGBA(0.93, 0.91, 0.87), colorB: RGBA(1.0, 0.96, 0.90),
            colorALabel: "Room", colorBLabel: "Sunlight"),
    ]

    /// Styles this scene adds to the default library.
    static var studio4Presets: [Preset] {
        func scene(_ name: String, _ params: [String: Double], a: RGBA, b: RGBA) -> Preset {
            var e = EffectInstance(.dichroic)
            for (k, v) in params { e.params[k] = v }
            e.colorA = a
            e.colorB = b
            return Preset(name: name, effects: [e])
        }
        return [
            scene("Dichroic", ["room": 0, "panes": 3, "glass": 0, "sun": 40, "dir": -30],
                  a: RGBA(0.93, 0.91, 0.87), b: RGBA(1.0, 0.96, 0.90)),
            scene("Black Box", ["room": 2, "panes": 4, "glass": 2],
                  a: RGBA(0.045, 0.043, 0.045), b: RGBA(1.0, 0.84, 0.64)),
        ]
    }
}
