//  DefaultPresets.swift — the screensavers that ship out of the box.
//
//  Two kinds of style:
//   • Scenes — self-contained generative pieces (first effect isScene); ignore the source.
//   • Looks  — effect stacks that restyle the one shared source (slideshow / photo / video / gradient).

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

    // Shared palette
    private static let indigo   = RGBA(0.13, 0.07, 0.34)
    private static let coral    = RGBA(1.0, 0.56, 0.42)
    private static let nightSky = RGBA(0.015, 0.03, 0.07)
    private static let risoPink = RGBA(1.0, 0.28, 0.53)
    private static let risoBlue = RGBA(0.0, 0.47, 0.75)
    private static let risoRed  = RGBA(0.96, 0.24, 0.26)
    private static let prussian = RGBA(0.05, 0.19, 0.42)
    private static let cream    = RGBA(0.95, 0.93, 0.87)

    /// Ready-made generative scenes.
    static func scenes() -> [Preset] {
        [
            Preset(name: "Universe",
                   effects: [fx(.universe, ["scale": 1.0, "speed": 1, "stars": 1, "planets": 1, "orbits": 1,
                                             "tilt": 24, "spin": 1],
                                a: .black)]),
            Preset(name: "Black Hole",
                   effects: [fx(.blackhole, ["angle": 0.22, "mass": 0.4, "brightness": 5, "speed": 1, "stars": 1, "rot": -8.7, "disk": 1],
                                a: .black),
                             fx(.bloom, ["thr": 0.4, "inten": 1.0, "rad": 4.5])]),
            Preset(name: "Aurora",
                   effects: [fx(.aurora, ["speed": 0.6, "intensity": 1.0, "height": 1.0, "stars": 0.6,
                                         "lake": 1, "activity": 0.5],
                                a: nightSky, b: RGBA(0.32, 1.0, 0.50))]),
            Preset(name: "Afterglow",
                   effects: [fx(.meshGradient, ["speed": 0.6, "scale": 1.0, "hue": 0.35, "grain": 0.08],
                                a: indigo, b: coral)]),
            Preset(name: "Topography",
                   effects: [fx(.topography, ["lines": 30, "scale": 1.2, "speed": 0.5, "fill": 0.5],
                                a: RGBA(0.05, 0.06, 0.07), b: RGBA(0.93, 0.90, 0.82))]),
            Preset(name: "Liquid Chrome",
                   effects: [fx(.liquidChrome, ["speed": 0.6, "scale": 1.2, "iris": 0.12],
                                a: RGBA(0.03, 0.03, 0.05), b: RGBA(0.92, 0.94, 1.0))]),
            Preset(name: "Silk",
                   effects: [fx(.silk, ["speed": 0.6, "scale": 1.0, "sheen": 0.4],
                                a: RGBA(0.03, 0.03, 0.06), b: RGBA(0.98, 0.78, 0.55))]),
            Preset(name: "Hyperspace",
                   effects: [fx(.starfield, ["speed": 1.5, "density": 12, "warp": 0.9, "size": 0.8],
                                a: RGBA(0.01, 0.015, 0.04), b: RGBA(0.75, 0.88, 1.0))]),
        ] + SceneCatalog.presets
    }

    /// Looks that restyle the shared source. Tuned on the built-in photo slideshow
    /// (Shared/Photos): render with `tools/gallery/render.sh <dir> --looks --slides`.
    static func looks() -> [Preset] {
        [
            Preset(name: "Film",
                   effects: [fx(.grainWash, ["soft": 0.0, "grain": 0.09, "tint": 0.22],
                                a: RGBA(0.06, 0.10, 0.16), b: RGBA(1.0, 0.90, 0.76)),
                             fx(.vignette, ["amount": 0.45, "radius": 0.95])]),
            Preset(name: "Riso Duotone",
                   effects: [fx(.risograph, ["screen": 0, "cell": 2, "misreg": 5, "paper": 0.5],
                                a: risoPink, b: risoBlue)]),
            Preset(name: "Cyanotype",
                   effects: [fx(.grainWash, ["soft": 0.12, "grain": 0.12, "tint": 1],
                                a: prussian, b: cream)]),
            Preset(name: "Floyd–Steinberg",
                   effects: [fx(.dither, ["algo": 4, "cell": 2, "mono": 1], a: .ink, b: .paper)]),
            Preset(name: "Atkinson",
                   effects: [fx(.dither, ["algo": 5, "cell": 2, "mono": 1], a: .black, b: .crtGreen)]),
            // Typewriter ink on paper: dark-ground ASCII drops every shadow to empty space,
            // which blacks out night and low-key photos.
            Preset(name: "ASCII",
                   effects: [fx(.ascii, ["cell": 10, "color": 0], a: .paper, b: .ink)]),
            Preset(name: "Amber CRT",
                   effects: [fx(.phosphor, ["amount": 1, "gain": 1.45], b: .amber),
                             fx(.scanlines, ["spacing": 3, "intensity": 0.55]),
                             fx(.bloom, ["thr": 0.45, "inten": 0.9, "rad": 3]),
                             fx(.vignette, ["amount": 0.7, "radius": 0.85])]),
            Preset(name: "Riso Halftone",
                   effects: [fx(.risograph, ["screen": 1, "cell": 6, "misreg": 7, "paper": 0.6],
                                a: risoRed, b: risoBlue)]),
            Preset(name: "Soft Focus",
                   effects: [fx(.grainWash, ["soft": 0.55, "grain": 0.08, "tint": 0.3],
                                a: RGBA(0.12, 0.08, 0.26), b: RGBA(1.0, 0.82, 0.66))]),
            Preset(name: "Fluted Glass",
                   effects: [fx(.glass, ["style": 0, "size": 40, "refract": 0.4, "frost": 0.6])]),
            Preset(name: "Liquid Glass",
                   effects: [fx(.glass, ["style": 2, "size": 140, "refract": 0.5, "frost": 0.1])]),
        ]
    }

    /// Earlier default canvases (gradients). A library still on one, untouched, moves to
    /// the built-in photos (AppModel.migrate).
    static var legacyDefaultSources: [SourceSpec] {
        [gradient(RGBA(0.10, 0.07, 0.28), RGBA(1.0, 0.71, 0.50), angle: 0.9),   // dusk (1.1–1.3)
         gradient(.navy, .cyan, angle: 0.9),
         SourceSpec()]
    }

    static func makeLibrary() -> Library {
        let sc = scenes(), lk = looks()
        var lib = Library()
        // The built-in photo slideshow: real subjects, texture and a full tonal range for
        // every Look to chew on (a flat gradient made most of them read as noise).
        lib.source = .builtInPhotos
        lib.presets = sc + lk
        lib.activeID = sc.first(where: { $0.name == "Aurora" })?.id ?? sc.first?.id
        return lib
    }

    /// Extra screensavers: the classic effects and a few more variations. Appendable
    /// to an existing library via AppModel.addDemoPack() (deduplicated by name).
    static func coolPack() -> [Preset] {
        [
            Preset(name: "Matrix Rain",
                   effects: [fx(.matrix, ["cell": 14, "speed": 1.1, "reveal": 1], a: .black, b: .crtGreen)]),
            Preset(name: "Halftone",
                   effects: [fx(.halftone, ["cell": 9, "angle": 0.5], a: .paper, b: .ink)]),
            Preset(name: "Riemersma",
                   effects: [fx(.dither, ["algo": 16, "cell": 2, "mono": 1], a: .navy, b: .amber)]),
            Preset(name: "Blue Noise",
                   effects: [fx(.dither, ["algo": 3, "cell": 1, "mono": 1], a: .black, b: .cyan)]),
            Preset(name: "Paper Contours",
                   effects: [fx(.topography, ["lines": 36, "scale": 1.5, "speed": 0.4, "fill": 0.25],
                                a: RGBA(0.95, 0.93, 0.88), b: RGBA(0.80, 0.30, 0.16))]),
            Preset(name: "Holographic",
                   effects: [fx(.liquidChrome, ["speed": 0.5, "scale": 1.0, "iris": 0.6],
                                a: RGBA(0.10, 0.10, 0.14), b: RGBA(0.96, 0.96, 1.0))]),
            Preset(name: "Lagoon",
                   effects: [fx(.meshGradient, ["speed": 0.5, "scale": 1.2, "hue": 0.3, "grain": 0.07],
                                a: RGBA(0.02, 0.09, 0.19), b: RGBA(0.55, 0.90, 0.95))]),
            Preset(name: "Orchid",
                   effects: [fx(.meshGradient, ["speed": 0.5, "scale": 1.1, "hue": 0.25, "grain": 0.09],
                                a: RGBA(0.24, 0.05, 0.22), b: RGBA(0.98, 0.70, 0.86))]),
            Preset(name: "Polar Night",
                   effects: [fx(.aurora, ["speed": 0.4, "intensity": 0.8, "height": 1.3, "stars": 1],
                                a: RGBA(0.01, 0.01, 0.03), b: RGBA(0.45, 0.65, 1.0))]),
            Preset(name: "Glass Tiles",
                   effects: [fx(.glass, ["style": 1, "size": 70, "refract": 0.55, "frost": 0.2])]),
            Preset(name: "Starfield",
                   effects: [fx(.starfield, ["speed": 1, "density": 12, "warp": 0.35, "size": 1],
                                a: .black, b: .white)]),
            Preset(name: "VHS",
                   effects: [fx(.vhs, ["amount": 1.1]),
                             fx(.scanlines, ["intensity": 0.25])]),
            Preset(name: "Data Glitch",
                   effects: [fx(.glitchBlocks, ["amount": 0.7]),
                             fx(.chromaticShift, ["amount": 2]),
                             fx(.scanlines, ["intensity": 0.3])]),
            Preset(name: "Game Boy",
                   effects: [fx(.gameboy, ["dither": 2])]),
            Preset(name: "Super NES",
                   effects: [fx(.nes8bit, ["cell": 6, "scan": 0.3, "sat": 1.35])]),
            Preset(name: "LED Wall",
                   effects: [fx(.ledPanel, ["cell": 16, "gap": 0.08])]),
            Preset(name: "Neon Wire",
                   effects: [fx(.noiseField, ["warp": 0.12, "scale": 5]),
                             fx(.neonEdges, ["gain": 4], a: .black, b: .cyan)]),
            Preset(name: "Kaleidoscope",
                   effects: [fx(.noiseField, ["warp": 0.12, "scale": 5]),
                             fx(.kaleidoscope, ["seg": 8, "spin": 1])]),
            Preset(name: "Thermal Cam",
                   effects: [fx(.noiseField, ["warp": 0.15, "scale": 4]),
                             fx(.thermal, ["gain": 1.1])]),
        ]
    }
}
