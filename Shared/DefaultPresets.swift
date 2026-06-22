//  DefaultPresets.swift — the screensavers that ship out of the box.

import Foundation

enum DefaultPresets {
    private static func gradient(_ a: RGBA, _ b: RGBA, angle: Double = 1.1) -> SourceSpec {
        var s = SourceSpec(); s.kind = .gradient; s.colorA = a; s.colorB = b; s.gradientAngle = angle; return s
    }
    private static func fx(_ kind: EffectKind, _ params: [String: Double] = [:], a: RGBA? = nil, b: RGBA? = nil) -> EffectInstance {
        var e = EffectInstance(kind)
        for (k, v) in params { e.params[k] = v }
        if let a = a { e.colorA = a }
        if let b = b { e.colorB = b }
        return e
    }

    static func makeLibrary() -> Library {
        let presets: [Preset] = [
            Preset(name: "Green Phosphor",
                   effects: [fx(.dither, ["cell": 3, "mono": 1], a: .black, b: .crtGreen),
                             fx(.scanlines, ["intensity": 0.35])]),

            Preset(name: "Halftone",
                   effects: [fx(.halftone, ["cell": 9, "angle": 0.5], a: .paper, b: .ink)]),

            Preset(name: "Matrix Rain",
                   effects: [fx(.matrix, ["cell": 14, "speed": 1.1, "reveal": 1], a: .black, b: .crtGreen)]),

            Preset(name: "ASCII",
                   effects: [fx(.ascii, ["cell": 12, "color": 1], a: .black, b: .crtGreen)]),

            Preset(name: "Voronoi",
                   effects: [fx(.voronoi, ["scale": 30]),
                             fx(.posterize, ["levels": 6])]),

            Preset(name: "VHS",
                   effects: [fx(.vhs, ["amount": 1.1]),
                             fx(.scanlines, ["intensity": 0.25])]),

            Preset(name: "Blueprint",
                   effects: [fx(.edge, ["gain": 3], a: RGBA(0.04, 0.1, 0.25), b: .cyan),
                             fx(.contour, ["bands": 10], a: RGBA(0.04, 0.1, 0.25), b: .cyan)]),

            Preset(name: "Threshold",
                   effects: [fx(.threshold, ["thr": 0.5], a: .ink, b: .amber)]),

            Preset(name: "Crosshatch",
                   effects: [fx(.crosshatch, ["spacing": 6], a: .paper, b: .ink)]),

            Preset(name: "Floyd–Steinberg",
                   effects: [fx(.dither, ["algo": 4, "cell": 2, "mono": 1], a: .paper, b: .ink)]),

            Preset(name: "Atkinson",
                   effects: [fx(.dither, ["algo": 5, "cell": 2, "mono": 1], a: .black, b: .crtGreen)]),

            Preset(name: "Riemersma",
                   effects: [fx(.dither, ["algo": 16, "cell": 2, "mono": 1], a: .navy, b: .amber)]),

            Preset(name: "Blue Noise",
                   effects: [fx(.dither, ["algo": 3, "cell": 1, "mono": 1], a: .black, b: .cyan)]),
        ]
        var lib = Library()
        // A textured default source so dither/halftone styles have structure to chew on.
        lib.source = gradient(.navy, .cyan, angle: 0.9)
        lib.presets = presets + coolPack()
        lib.activeID = presets.first?.id
        return lib
    }

    /// A pack of demo screensavers showcasing the "cool" effects. Also appendable
    /// to an existing library via AppModel.addDemoPack().
    static func coolPack() -> [Preset] {
        [
            Preset(name: "Kaleidoscope",
                   effects: [fx(.noiseField, ["warp": 0.12, "scale": 5]),
                             fx(.kaleidoscope, ["seg": 8, "spin": 1])]),
            Preset(name: "Chromatic Bloom",
                   effects: [fx(.bloom, ["thr": 0.5, "inten": 1.2, "rad": 4]),
                             fx(.chromaticShift, ["amount": 3])]),
            Preset(name: "Hex Grid",
                   effects: [fx(.hexMosaic, ["size": 28]), fx(.posterize, ["levels": 5])]),
            Preset(name: "Data Glitch",
                   effects: [fx(.glitchBlocks, ["amount": 0.7]),
                             fx(.chromaticShift, ["amount": 2]),
                             fx(.scanlines, ["intensity": 0.3])]),
            Preset(name: "Game Boy",
                   effects: [fx(.gameboy, ["dither": 2])]),
            Preset(name: "Neon Wire",
                   effects: [fx(.noiseField, ["warp": 0.12, "scale": 5]),
                             fx(.neonEdges, ["gain": 4], a: .black, b: .cyan)]),
            Preset(name: "Fisheye Dots",
                   effects: [fx(.fisheye, ["amount": 0.8]), fx(.dots, ["cell": 16])]),
            Preset(name: "Liquid Swirl",
                   effects: [fx(.noiseField, ["warp": 0.15, "scale": 4]),
                             fx(.swirl, ["amount": 7, "spin": 1])]),
            Preset(name: "Ripples",
                   effects: [fx(.ripple, ["amp": 2, "freq": 40, "speed": 2]),
                             fx(.dither, ["mode": 1, "cell": 2, "mono": 1], a: .navy, b: .cyan)]),
            Preset(name: "Toon",
                   effects: [fx(.toon, ["bands": 4, "edge": 2])]),
            Preset(name: "Thermal Cam",
                   effects: [fx(.noiseField, ["warp": 0.15, "scale": 4]),
                             fx(.thermal, ["gain": 1.1])]),
            Preset(name: "Truchet Maze",
                   effects: [fx(.noiseField, ["warp": 0.1, "scale": 5]),
                             fx(.truchet, ["size": 26], a: .ink, b: .crtGreen)]),
            Preset(name: "LED Wall",
                   effects: [fx(.ledPanel, ["cell": 16, "gap": 0.08])]),
            Preset(name: "Psychedelia",
                   effects: [fx(.kaleidoscope, ["seg": 6, "spin": 1.2]),
                             fx(.thermal, ["gain": 1]),
                             fx(.swirl, ["amount": 4, "spin": 0.6])]),
            Preset(name: "Super NES",
                   effects: [fx(.nes8bit, ["cell": 6, "scan": 0.3, "sat": 1.35])]),
            Preset(name: "Starfield",
                   effects: [fx(.starfield, ["speed": 1, "density": 12, "warp": 0.35, "size": 1],
                                a: .black, b: .white)]),
            Preset(name: "Hyperspace",
                   effects: [fx(.starfield, ["speed": 2.2, "density": 16, "warp": 0.9, "size": 1.2],
                                a: RGBA(0.02, 0.03, 0.08), b: .cyan)]),
            Preset(name: "Universe",
                   effects: [fx(.universe, ["earth": 0.27, "spin": 0.5, "stars": 10, "planets": 1],
                                a: .black)]),
        ]
    }
}
