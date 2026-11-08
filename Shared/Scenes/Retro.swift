//  Retro.swift — the Retro scene pack (shader ids 62–65). See SceneCatalog.swift.
//
//  Classic screensaver genres, re-rendered: a neon horizon drive, glossy pipes growing
//  through a dark room, luminous polygon ribbons, and a demoscene light tunnel.
//  Shaders: Retro_funcs.h (helpers) + Retro_cases.h (ids 62–65).

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Retro" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let retro: [EffectKind: SceneSpec] = [
        .synthGrid: SceneSpec(
            name: "Neon Horizon",
            blurb: "An endless neon grid racing toward a striped sunset over glowing ridges.",
            shaderID: 62,
            params: [ParamSpec("speed", "Speed", 0, 3, def: 1),
                     ParamSpec("grid", "Grid Density", 0.5, 2.5, def: 1),
                     ParamSpec("mountains", "Mountains", 0, 1.5, def: 1),
                     ParamSpec("sun", "Sun Size", 0.5, 1.5, def: 1),
                     ParamSpec("haze", "Haze", 0, 1.5, def: 0.8),
                     ParamSpec("stars", "Stars", 0, 1, def: 0.7)],
            colorA: RGBA(1.0, 0.18, 0.78), colorB: RGBA(1.0, 0.72, 0.22),
            colorALabel: "Neon", colorBLabel: "Sun"),
        .pipes: SceneSpec(
            name: "Pipeworks",
            blurb: "Glossy lacquered pipes grow through a dark room, ray-traced with reflections.",
            shaderID: 63,
            params: [ParamSpec("speed", "Growth Speed", 0.3, 3, def: 1),
                     ParamSpec("count", "Pipes", 2, 6, step: 1, def: 4),
                     ParamSpec("thick", "Thickness", 0.4, 1, def: 0.95),
                     ParamSpec(menu: "joints", "Joints", ["Rounded", "Ball"], def: 0),
                     ParamSpec("gloss", "Gloss", 0, 1, def: 0.8),
                     ParamSpec("orbit", "Camera Drift", 0, 1.5, def: 0.6),
                     ParamSpec(menu: "finish", "Finish", ["Lacquer", "Metal"], def: 0)],
            colorA: RGBA(0.98, 0.33, 0.24), colorB: RGBA(0.20, 0.55, 1.0),
            colorALabel: "First Pipe", colorBLabel: "Last Pipe"),
        .polyTrails: SceneSpec(
            name: "Light Ribbons",
            blurb: "Bouncing polygons paint translucent ribbons of light behind them.",
            shaderID: 64,
            params: [ParamSpec("speed", "Speed", 0, 2, def: 1),
                     ParamSpec("shapes", "Shapes", 1, 2, step: 1, def: 2),
                     ParamSpec("sides", "Sides", 3, 6, step: 1, def: 4),
                     ParamSpec("trail", "Trail Length", 0.2, 1, def: 0.7),
                     ParamSpec("echoes", "Echo Lines", 0, 1, def: 0.6),
                     ParamSpec("glow", "Glow", 0, 2, def: 1)],
            colorA: RGBA(0.30, 0.95, 1.0), colorB: RGBA(0.75, 0.25, 1.0),
            colorALabel: "Leading Edge", colorBLabel: "Trail"),
        .demoTunnel: SceneSpec(
            name: "Light Tunnel",
            blurb: "A demoscene tunnel of brushed-metal panels and racing neon, with real reflections.",
            shaderID: 65,
            params: [ParamSpec("speed", "Speed", 0, 3, def: 1),
                     ParamSpec(menu: "shape", "Shape", ["Round", "Square", "Hexagon"], def: 0),
                     ParamSpec("twist", "Twist", 0, 2, def: 0.7),
                     ParamSpec("panels", "Panel Size", 0.5, 2, def: 1),
                     ParamSpec("lights", "Light Rings", 0, 2, def: 1),
                     ParamSpec("gloss", "Gloss", 0, 1, def: 0.75)],
            colorA: RGBA(0.62, 0.66, 0.74), colorB: RGBA(0.20, 0.85, 1.0),
            colorALabel: "Metal", colorBLabel: "Neon"),
    ]

    private static func retroFx(_ kind: EffectKind, _ params: [String: Double],
                                a: RGBA, b: RGBA) -> EffectInstance {
        var e = EffectInstance(kind)
        for (k, v) in params { e.params[k] = v }
        e.colorA = a; e.colorB = b
        return e
    }

    /// Styles this pack adds to the default library.
    static var retroPresets: [Preset] {
        [
            Preset(name: "Neon Horizon",
                   effects: [retroFx(.synthGrid, ["speed": 1, "grid": 1, "mountains": 1, "sun": 1, "haze": 0.8, "stars": 0.7],
                                     a: RGBA(1.0, 0.18, 0.78), b: RGBA(1.0, 0.72, 0.22))]),
            Preset(name: "Night Drive",
                   effects: [retroFx(.synthGrid, ["speed": 1.6, "grid": 1.4, "mountains": 1.2, "sun": 0.8, "haze": 1.1, "stars": 1],
                                     a: RGBA(0.15, 0.85, 1.0), b: RGBA(1.0, 0.36, 0.55))]),
            Preset(name: "Pipeworks",
                   effects: [retroFx(.pipes, ["speed": 1, "count": 4, "thick": 0.95, "joints": 0, "gloss": 0.8, "orbit": 0.6, "finish": 0],
                                     a: RGBA(0.98, 0.33, 0.24), b: RGBA(0.20, 0.55, 1.0))]),
            Preset(name: "Brass Pipes",
                   effects: [retroFx(.pipes, ["speed": 0.8, "count": 3, "thick": 0.9, "joints": 1, "gloss": 1, "orbit": 0.4, "finish": 1],
                                     a: RGBA(0.95, 0.72, 0.35), b: RGBA(0.75, 0.42, 0.22))]),
            Preset(name: "Light Ribbons",
                   effects: [retroFx(.polyTrails, ["speed": 1, "shapes": 2, "sides": 4, "trail": 0.7, "echoes": 0.6, "glow": 1],
                                     a: RGBA(0.30, 0.95, 1.0), b: RGBA(0.75, 0.25, 1.0))]),
            Preset(name: "Ember Ribbons",
                   effects: [retroFx(.polyTrails, ["speed": 0.7, "shapes": 1, "sides": 3, "trail": 1, "echoes": 0.3, "glow": 1.3],
                                     a: RGBA(1.0, 0.85, 0.45), b: RGBA(1.0, 0.18, 0.12))]),
            Preset(name: "Light Tunnel",
                   effects: [retroFx(.demoTunnel, ["speed": 1, "shape": 0, "twist": 0.7, "panels": 1, "lights": 1, "gloss": 0.75],
                                     a: RGBA(0.62, 0.66, 0.74), b: RGBA(0.20, 0.85, 1.0))]),
            Preset(name: "Hex Tunnel",
                   effects: [retroFx(.demoTunnel, ["speed": 1.4, "shape": 2, "twist": 1.2, "panels": 1.2, "lights": 1.3, "gloss": 0.9],
                                     a: RGBA(0.45, 0.41, 0.50), b: RGBA(1.0, 0.30, 0.62))]),
        ]
    }
}
