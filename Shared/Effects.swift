//  Effects.swift — catalog of effects: UI metadata + uniform packing.

import Foundation
import simd

struct ParamSpec: Identifiable {
    let key: String
    let label: String
    let min: Double
    let max: Double
    let step: Double
    let def: Double
    let isToggle: Bool
    let options: [String]?      // when set, render as a menu; value = selected index
    var id: String { key }
    init(_ key: String, _ label: String, _ min: Double, _ max: Double, step: Double = 0, def: Double, toggle: Bool = false) {
        self.key = key; self.label = label; self.min = min; self.max = max
        self.step = step; self.def = def; self.isToggle = toggle; self.options = nil
    }
    init(menu key: String, _ label: String, _ options: [String], def: Double) {
        self.key = key; self.label = label; self.min = 0; self.max = Double(options.count - 1)
        self.step = 1; self.def = def; self.isToggle = false; self.options = options
    }
}

enum EffectCategory: String, CaseIterable { case dotsDither = "Dots & Dither", lines = "Lines & Edges", glyphs = "Glyphs", glitch = "Glitch", color = "Color", warp = "Warp & Mirror", generative = "Generative" }

enum EffectKind: String, Codable, CaseIterable {
    // grain.rad set
    case dither, halftone, dots, ascii, matrix, contour, pixelSort, blockify
    case threshold, edge, crosshatch, wave, noiseField, voronoi, vhs
    // extras
    case pixelate, posterize, phosphor, scanlines, grain, vignette
    // cool pack
    case kaleidoscope, chromaticShift, bloom, hexMosaic, mirror, glitchBlocks
    case gameboy, neonEdges, fisheye, swirl, ripple, toon, thermal, truchet, ledPanel

    var displayName: String {
        switch self {
        case .dither: return "Dithering"
        case .halftone: return "Halftone"
        case .dots: return "Dots"
        case .ascii: return "ASCII"
        case .matrix: return "Matrix Rain"
        case .contour: return "Contour"
        case .pixelSort: return "Pixel Sort"
        case .blockify: return "Blockify"
        case .threshold: return "Threshold"
        case .edge: return "Edge Detection"
        case .crosshatch: return "Crosshatch"
        case .wave: return "Wave Lines"
        case .noiseField: return "Noise Field"
        case .voronoi: return "Voronoi"
        case .vhs: return "VHS"
        case .pixelate: return "Pixelate"
        case .posterize: return "Posterize"
        case .phosphor: return "Phosphor"
        case .scanlines: return "Scanlines"
        case .grain: return "Grain"
        case .vignette: return "Vignette"
        case .kaleidoscope: return "Kaleidoscope"
        case .chromaticShift: return "Chromatic Shift"
        case .bloom: return "Bloom"
        case .hexMosaic: return "Hex Mosaic"
        case .mirror: return "Mirror"
        case .glitchBlocks: return "Glitch Blocks"
        case .gameboy: return "Game Boy"
        case .neonEdges: return "Neon Edges"
        case .fisheye: return "Fisheye"
        case .swirl: return "Swirl"
        case .ripple: return "Ripple"
        case .toon: return "Toon"
        case .thermal: return "Thermal"
        case .truchet: return "Truchet"
        case .ledPanel: return "LED Panel"
        }
    }

    var category: EffectCategory {
        switch self {
        case .dither, .halftone, .dots, .pixelate, .blockify: return .dotsDither
        case .ascii, .matrix: return .glyphs
        case .contour, .edge, .crosshatch, .wave: return .lines
        case .vhs, .scanlines, .grain, .pixelSort: return .glitch
        case .threshold, .posterize, .phosphor, .vignette: return .color
        case .noiseField, .voronoi: return .generative
        case .hexMosaic, .ledPanel, .truchet: return .dotsDither
        case .gameboy, .bloom, .thermal, .toon: return .color
        case .neonEdges: return .lines
        case .chromaticShift, .glitchBlocks: return .glitch
        case .kaleidoscope, .mirror, .fisheye, .swirl, .ripple: return .warp
        }
    }

    /// id used by the switch in Shaders.metal
    var shaderID: Int32 {
        switch self {
        case .pixelate, .blockify: return 2
        case .dither:    return 3
        case .halftone:  return 4
        case .dots:      return 5
        case .threshold: return 6
        case .posterize: return 7
        case .phosphor:  return 8
        case .noiseField, .grain: return 9
        case .scanlines: return 10
        case .vignette:  return 11
        case .kaleidoscope: return 21
        case .chromaticShift: return 22
        case .bloom:     return 23
        case .hexMosaic: return 24
        case .mirror:    return 25
        case .glitchBlocks: return 26
        case .gameboy:   return 27
        case .neonEdges: return 28
        case .fisheye:   return 29
        case .swirl:     return 30
        case .ripple:    return 31
        case .toon:      return 32
        case .thermal:   return 33
        case .truchet:   return 34
        case .ledPanel:  return 35
        case .edge:      return 12
        case .crosshatch:return 13
        case .contour:   return 14
        case .wave:      return 15
        case .voronoi:   return 16
        case .vhs:       return 17
        case .ascii:     return 18
        case .matrix:    return 19
        case .pixelSort: return 20
        }
    }

    var params: [ParamSpec] {
        switch self {
        case .pixelate:  return [ParamSpec("cell", "Pixel Size", 2, 120, def: 12)]
        case .blockify:  return [ParamSpec("cell", "Block Size", 8, 200, def: 32)]
        case .dither:    return [ParamSpec(menu: "mode", "Algorithm",
                                            ["Bayer 2×2", "Bayer 4×4", "Bayer 8×8", "Clustered", "Noise"], def: 1),
                                 ParamSpec("cell", "Pixel Size", 1, 16, step: 1, def: 2),
                                 ParamSpec("levels", "Levels", 2, 8, step: 1, def: 2),
                                 ParamSpec("mono", "Monochrome", 0, 1, def: 1, toggle: true)]
        case .halftone:  return [ParamSpec("cell", "Cell Size", 3, 48, def: 10),
                                 ParamSpec("angle", "Screen Angle", 0, 1.57, def: 0.4)]
        case .dots:      return [ParamSpec("cell", "Grid Size", 4, 64, def: 14),
                                 ParamSpec("blend", "Keep Color", 0, 1, def: 0)]
        case .ascii:     return [ParamSpec("cell", "Cell Size", 6, 40, def: 12),
                                 ParamSpec("color", "Use Source Color", 0, 1, def: 0, toggle: true)]
        case .matrix:    return [ParamSpec("cell", "Cell Size", 8, 30, def: 14),
                                 ParamSpec("speed", "Speed", 0.2, 3, def: 1),
                                 ParamSpec("reveal", "Reveal Source", 0, 1, def: 0, toggle: true)]
        case .contour:   return [ParamSpec("bands", "Bands", 3, 24, step: 1, def: 8)]
        case .pixelSort: return [ParamSpec("thr", "Threshold", 0, 1, def: 0.5),
                                 ParamSpec("len", "Max Length", 4, 120, def: 48)]
        case .threshold: return [ParamSpec("thr", "Level", 0, 1, def: 0.5),
                                 ParamSpec("soft", "Softness", 0, 0.3, def: 0.02)]
        case .edge:      return [ParamSpec("thick", "Thickness", 1, 3, def: 1),
                                 ParamSpec("gain", "Gain", 0.5, 8, def: 2)]
        case .crosshatch:return [ParamSpec("spacing", "Spacing", 3, 18, def: 6)]
        case .wave:      return [ParamSpec("spacing", "Spacing", 3, 36, def: 10),
                                 ParamSpec("amp", "Amplitude", 0, 80, def: 18),
                                 ParamSpec("speed", "Speed", 0, 4, def: 1.2)]
        case .noiseField:return [ParamSpec("warp", "Warp", 0, 0.3, def: 0.08),
                                 ParamSpec("scale", "Scale", 1, 24, def: 6),
                                 ParamSpec("grain", "Grain", 0, 0.4, def: 0.06)]
        case .voronoi:   return [ParamSpec("scale", "Density", 6, 90, def: 28)]
        case .vhs:       return [ParamSpec("amount", "Amount", 0, 2, def: 1)]
        case .posterize: return [ParamSpec("levels", "Levels", 2, 12, step: 1, def: 4)]
        case .phosphor:  return [ParamSpec("amount", "Amount", 0, 1, def: 1),
                                 ParamSpec("gain", "Gain", 0.5, 2.5, def: 1.3)]
        case .scanlines: return [ParamSpec("spacing", "Spacing", 2, 16, def: 4),
                                 ParamSpec("intensity", "Intensity", 0, 1, def: 0.5)]
        case .grain:     return [ParamSpec("amount", "Amount", 0, 0.6, def: 0.15)]
        case .vignette:  return [ParamSpec("amount", "Amount", 0, 1, def: 0.6),
                                 ParamSpec("radius", "Radius", 0.4, 1.1, def: 0.8)]
        case .kaleidoscope: return [ParamSpec("seg", "Segments", 2, 16, step: 1, def: 6),
                                    ParamSpec("spin", "Spin", 0, 3, def: 1)]
        case .chromaticShift: return [ParamSpec("amount", "Amount", 0, 8, def: 2),
                                      ParamSpec("angle", "Angle", 0, 6.28, def: 0)]
        case .bloom:     return [ParamSpec("thr", "Threshold", 0, 1, def: 0.6),
                                 ParamSpec("inten", "Intensity", 0, 2, def: 0.8),
                                 ParamSpec("rad", "Radius", 1, 6, def: 3)]
        case .hexMosaic: return [ParamSpec("size", "Cell Size", 6, 80, def: 24)]
        case .mirror:    return [ParamSpec(menu: "mode", "Mode", ["Horizontal", "Vertical", "Quad"], def: 2)]
        case .glitchBlocks: return [ParamSpec("amount", "Amount", 0, 1, def: 0.5)]
        case .gameboy:   return [ParamSpec("dither", "Dither", 1, 6, def: 2)]
        case .neonEdges: return [ParamSpec("gain", "Glow", 1, 8, def: 3),
                                 ParamSpec("thick", "Thickness", 1, 3, def: 1)]
        case .fisheye:   return [ParamSpec("amount", "Amount", -1, 1.5, def: 0.6)]
        case .swirl:     return [ParamSpec("amount", "Amount", 0, 12, def: 5),
                                 ParamSpec("spin", "Spin", 0, 3, def: 0.5)]
        case .ripple:    return [ParamSpec("amp", "Amplitude", 0, 5, def: 1.5),
                                 ParamSpec("freq", "Frequency", 5, 80, def: 30),
                                 ParamSpec("speed", "Speed", 0, 6, def: 2)]
        case .toon:      return [ParamSpec("bands", "Bands", 2, 10, step: 1, def: 4),
                                 ParamSpec("edge", "Edge", 0.5, 6, def: 2)]
        case .thermal:   return [ParamSpec("gain", "Gain", 0.5, 2, def: 1)]
        case .truchet:   return [ParamSpec("size", "Tile Size", 8, 60, def: 24)]
        case .ledPanel:  return [ParamSpec("cell", "Cell Size", 6, 40, def: 16),
                                 ParamSpec("gap", "Gap", 0, 0.3, def: 0.08)]
        }
    }

    var defaultParams: [String: Double] {
        var d: [String: Double] = [:]
        for p in params { d[p.key] = p.def }
        return d
    }

    var defaultColorA: RGBA? {
        switch self {
        case .dither, .threshold, .dots, .wave, .edge, .ascii, .matrix, .neonEdges: return .black
        case .halftone, .crosshatch: return .paper
        case .contour, .truchet: return .ink
        default: return nil
        }
    }
    var defaultColorB: RGBA? {
        switch self {
        case .dither, .threshold, .dots: return .white
        case .halftone, .crosshatch: return .ink
        case .contour: return .paper
        case .wave, .edge, .neonEdges, .truchet: return .cyan
        case .ascii, .matrix, .phosphor: return .crtGreen
        default: return nil
        }
    }

    var usesColors: Bool { defaultColorA != nil || defaultColorB != nil }
}

// MARK: - Uniform packing

extension EffectInstance {
    func g(_ key: String) -> Float {
        Float(params[key] ?? kind.params.first(where: { $0.key == key })?.def ?? 0)
    }

    func pack(into u: inout FXUniforms) {
        u.effect = kind.shaderID
        u.p0 = .init(0, 0, 0, 0); u.p1 = .init(0, 0, 0, 0); u.p2 = .init(0, 0, 0, 0)
        u.colorA = (colorA ?? kind.defaultColorA ?? .black).simd
        u.colorB = (colorB ?? kind.defaultColorB ?? .white).simd

        switch kind {
        case .pixelate, .blockify: u.p0.x = g("cell")
        case .dither:    u.p0 = .init(g("cell"), g("levels"), g("mono"), g("mode"))
        case .halftone:  u.p0 = .init(g("cell"), g("angle"), 0, 0)
        case .dots:      u.p0 = .init(g("cell"), 0, g("blend"), 0)
        case .ascii:     u.p0 = .init(g("cell"), 0, g("color"), 0)
        case .matrix:    u.p0 = .init(g("cell"), g("speed"), g("reveal"), 0)
        case .contour:   u.p0.x = g("bands")
        case .pixelSort: u.p0 = .init(g("thr"), g("len"), 0, 0)
        case .threshold: u.p0 = .init(g("thr"), g("soft"), 0, 0)
        case .edge:      u.p0 = .init(g("thick"), g("gain"), 0, 0)
        case .crosshatch:u.p0.x = g("spacing")
        case .wave:      u.p0 = .init(g("spacing"), g("amp"), g("speed"), 0)
        case .noiseField:u.p0 = .init(g("warp"), g("scale"), g("grain"), 0)
        case .grain:     u.p0 = .init(0, 1, g("amount"), 0)
        case .voronoi:   u.p0.x = g("scale")
        case .vhs:       u.p0.x = g("amount")
        case .posterize: u.p0.x = g("levels")
        case .phosphor:  u.p0 = .init(g("amount"), g("gain"), 0, 0)
        case .scanlines: u.p0 = .init(g("spacing"), g("intensity"), 0, 0)
        case .vignette:  u.p0 = .init(g("amount"), g("radius"), 0, 0)
        case .kaleidoscope: u.p0 = .init(g("seg"), g("spin"), 0, 0)
        case .chromaticShift: u.p0 = .init(g("amount"), g("angle"), 0, 0)
        case .bloom:     u.p0 = .init(g("thr"), g("inten"), g("rad"), 0)
        case .hexMosaic: u.p0.x = g("size")
        case .mirror:    u.p0.x = g("mode")
        case .glitchBlocks: u.p0.x = g("amount")
        case .gameboy:   u.p0.x = g("dither")
        case .neonEdges: u.p0 = .init(g("gain"), g("thick"), 0, 0)
        case .fisheye:   u.p0.x = g("amount")
        case .swirl:     u.p0 = .init(g("amount"), g("spin"), 0, 0)
        case .ripple:    u.p0 = .init(g("amp"), g("freq"), g("speed"), 0)
        case .toon:      u.p0 = .init(g("bands"), g("edge"), 0, 0)
        case .thermal:   u.p0.x = g("gain")
        case .truchet:   u.p0.x = g("size")
        case .ledPanel:  u.p0 = .init(g("cell"), g("gap"), 0, 0)
        }
    }
}
