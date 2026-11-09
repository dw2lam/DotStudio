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

/// User-facing groups for the Add-effect picker. Scenes (generators that ignore the
/// source) come first; every other group restyles the shared source.
enum EffectCategory: String, CaseIterable {
    case scenes      = "Scenes"
    case print       = "Print & Halftone"
    case ditherPixel = "Dither & Pixel"
    case type        = "Type & Glyph"
    case retro       = "Retro Screens"
    case lines       = "Lines & Ink"
    case distort     = "Glass & Distort"
    case colorLight  = "Color & Light"

    /// SF Symbol for the group (picker headers, chips).
    var symbol: String {
        switch self {
        case .scenes:      return "sparkles"
        case .print:       return "circle.grid.3x3.fill"
        case .ditherPixel: return "checkerboard.rectangle"
        case .type:        return "textformat"
        case .retro:       return "tv"
        case .lines:       return "scribble.variable"
        case .distort:     return "drop"
        case .colorLight:  return "sun.max"
        }
    }

    /// One line describing the group.
    var blurb: String {
        switch self {
        case .scenes:      return "Generative pieces that play on their own — no source needed."
        case .print:       return "Ink on paper: halftone screens, riso overprints, engraving."
        case .ditherPixel: return "1-bit and low-bit dithering, pixels and mosaics."
        case .type:        return "Rebuild the image out of characters."
        case .retro:       return "CRTs, consoles, tape and signal glitches."
        case .lines:       return "Edges, contours and line work."
        case .distort:     return "Refract, mirror and warp the source."
        case .colorLight:  return "Grade, glow, grain and tone."
        }
    }

    /// True for the group whose effects ignore the source.
    var isScenes: Bool { self == .scenes }
}

enum EffectKind: String, Codable, CaseIterable {
    // grain.rad set
    case dither, halftone, dots, ascii, matrix, contour, pixelSort, blockify
    case threshold, edge, crosshatch, wave, noiseField, voronoi, vhs
    // extras
    case pixelate, posterize, phosphor, scanlines, grain, vignette
    // cool pack
    case kaleidoscope, chromaticShift, bloom, hexMosaic, mirror, glitchBlocks
    case gameboy, neonEdges, fisheye, swirl, ripple, toon, thermal, truchet, ledPanel, nes8bit, starfield, universe, blackhole
    // modern pack: scenes + looks
    case meshGradient, aurora, topography, liquidChrome, silk, risograph, grainWash, glass
    // Scene packs — metadata lives in Shared/Scenes/<Pack>.swift (SceneCatalog), shaders in
    // Shared/Scenes/<Pack>_cases.h. One line per pack; shader ids 50–53, 54–57, 58–61, 62–65, 66.
    case typeClock, flipClock, wordClock, windowLight         // Clocks   50–53

    case flowLines, lavaLamp, inkFluid, fireflies             // Flowing  54–57

    case rainGlass, oceanHorizon, nightSky, snowfall          // Nature   58–61

    case synthGrid, pipes, polyTrails, demoTunnel             // Retro    62–65

    case nowPlaying                                           // Music    66

    // — new-scene slot 1 (shader id 67); rename the case freely on this line —
    case shallows

    // — new-scene slot 2 (shader id 68); rename the case freely on this line —
    case sandGarden

    // — new-scene slot 3 (shader id 69); rename the case freely on this line —
    case pleats

    // — new-scene slot 4 (shader id 70); rename the case freely on this line —
    case dichroic

    // — new-scene slot 5 (shader id 71); rename the case freely on this line —
    case soapFilm

    // — new-scene slot 6 (shader id 72); rename the case freely on this line —
    case studio6

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
        case .noiseField: return "Liquify"
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
        case .nes8bit: return "NES 8-Bit"
        case .starfield: return "Starfield"
        case .universe: return "Universe"
        case .blackhole: return "Black Hole"
        case .meshGradient: return "Mesh Gradient"
        case .aurora: return "Aurora"
        case .topography: return "Topography"
        case .liquidChrome: return "Liquid Chrome"
        case .silk: return "Silk"
        case .risograph: return "Risograph"
        case .grainWash: return "Grain Wash"
        case .glass: return "Glass"
        default: return SceneCatalog.spec(self)?.name ?? rawValue
        }
    }

    /// One-line description for the Add-effect picker.
    var blurb: String {
        switch self {
        case .dither:    return "Ordered, blue-noise and error-diffusion dithering, 1-bit or color."
        case .halftone:  return "A rotated print screen of round ink dots."
        case .dots:      return "A plain grid of dots sized by brightness."
        case .ascii:     return "Redraws the image in monospace characters."
        case .matrix:    return "Falling code rain, optionally revealing the source."
        case .contour:   return "Iso-brightness bands with contour lines."
        case .pixelSort: return "Smears bright runs sideways, glitch-art style."
        case .blockify:  return "Chunky square blocks."
        case .threshold: return "Two-tone cut at a brightness level."
        case .edge:      return "Sobel edge lines on a flat ground."
        case .crosshatch:return "Engraved pen hatching that deepens with shadow."
        case .wave:      return "Horizontal lines displaced by brightness."
        case .noiseField:return "Slowly liquifies the source with drifting noise."
        case .voronoi:   return "Irregular cell mosaic."
        case .vhs:       return "Tape wobble, color bleed and a roll bar."
        case .pixelate:  return "Square pixels of any size."
        case .posterize: return "Reduces each channel to a few flat levels."
        case .phosphor:  return "Monochrome tint, like a single-color CRT."
        case .scanlines: return "CRT scanlines with a soft RGB mask."
        case .grain:     return "Animated film grain."
        case .vignette:  return "Darkens the corners."
        case .kaleidoscope: return "Mirrored wedges that slowly turn."
        case .chromaticShift: return "Pulls red and blue apart, lens-fringe style."
        case .bloom:     return "Soft glow around bright areas."
        case .hexMosaic: return "Hexagonal tile mosaic."
        case .mirror:    return "Mirrors the frame horizontally, vertically or both."
        case .glitchBlocks: return "Rows that jump sideways with channel splits."
        case .gameboy:   return "The four-green handheld palette, dithered."
        case .neonEdges: return "Glowing edges on black."
        case .fisheye:   return "Barrel lens bulge."
        case .swirl:     return "Twists the center."
        case .ripple:    return "Concentric water ripples."
        case .toon:      return "Flat cel shading with ink outlines."
        case .thermal:   return "Heat-camera false color."
        case .truchet:   return "Quarter-circle tile maze."
        case .ledPanel:  return "A wall of round LEDs."
        case .nes8bit:   return "Snaps to the NES palette with chunky pixels."
        case .starfield: return "Fly through an endless field of stars."
        case .universe:  return "The solar system in 3D, with Earth's real day and night."
        case .blackhole: return "A lensing black hole with a glowing accretion disk."
        case .meshGradient: return "Soft, grainy color fields drifting into each other."
        case .aurora:    return "Northern lights rippling above a dark ridge."
        case .topography: return "A living contour map with shaded relief."
        case .liquidChrome: return "Molten mirror metal, optionally iridescent."
        case .silk:      return "Draped satin rippling in a slow breeze, its sheen sliding down the folds."
        case .risograph: return "Two-ink riso print with grain and misregistration."
        case .grainWash: return "Dreamy soft focus with film grain and an optional color wash."
        case .glass:     return "Looks through fluted, tiled or liquid glass."
        default: return SceneCatalog.spec(self)?.blurb ?? ""
        }
    }

    var category: EffectCategory {
        switch self {
        case .starfield, .universe, .blackhole,
             .meshGradient, .aurora, .topography, .liquidChrome, .silk:   return .scenes
        case .halftone, .risograph, .crosshatch, .dots:                   return .print
        case .dither, .threshold, .pixelate, .blockify, .hexMosaic, .voronoi: return .ditherPixel
        case .ascii, .matrix:                                             return .type
        case .vhs, .scanlines, .phosphor, .gameboy, .nes8bit, .ledPanel,
             .glitchBlocks, .pixelSort, .chromaticShift:                  return .retro
        case .edge, .neonEdges, .contour, .wave, .truchet, .toon:         return .lines
        case .glass, .noiseField, .kaleidoscope, .mirror,
             .fisheye, .swirl, .ripple:                                   return .distort
        case .grainWash, .grain, .bloom, .posterize, .thermal, .vignette: return .colorLight
        default: return .scenes
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
        case .nes8bit:   return 36
        case .starfield: return 37
        case .universe:  return 39
        case .blackhole: return 40
        // 38 = dither-grid blit and 41 = preset crossfade are internal passes; never assign them.
        case .meshGradient: return 42
        case .aurora:    return 43
        case .topography: return 44
        case .liquidChrome: return 45
        case .silk:      return 46
        case .risograph: return 47
        case .grainWash: return 48
        case .glass:     return 49
        case .edge:      return 12
        case .crosshatch:return 13
        case .contour:   return 14
        case .wave:      return 15
        case .voronoi:   return 16
        case .vhs:       return 17
        case .ascii:     return 18
        case .matrix:    return 19
        case .pixelSort: return 20
        default: return SceneCatalog.spec(self)?.shaderID ?? 0
        }
    }

    var params: [ParamSpec] {
        switch self {
        case .pixelate:  return [ParamSpec("cell", "Pixel Size", 2, 120, def: 12)]
        case .blockify:  return [ParamSpec("cell", "Block Size", 8, 200, def: 32)]
        case .dither:    return [ParamSpec(menu: "algo", "Algorithm",
                                            ["Bayer 2×2", "Bayer 4×4", "Bayer 8×8", "Blue Noise",
                                             "Floyd–Steinberg", "Atkinson", "Jarvis-Judice-Ninke", "Stucki",
                                             "Burkes", "Sierra", "Sierra 2-Row", "Sierra Lite",
                                             "Fan", "Shiau-Fan", "Shiau-Fan 2", "Simple 2D", "Riemersma"], def: 1),
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
        case .nes8bit:   return [ParamSpec("cell", "Pixel Size", 2, 40, def: 6),
                                 ParamSpec("scan", "Scanlines", 0, 1, def: 0.25),
                                 ParamSpec("sat", "Saturation", 0, 2, def: 1.25)]
        case .starfield: return [ParamSpec("speed", "Speed", 0, 3, def: 1),
                                 ParamSpec("density", "Density", 4, 40, def: 12),
                                 ParamSpec("warp", "Warp", 0, 1, def: 0.3),
                                 ParamSpec("size", "Star Size", 0.3, 3, def: 1)]
        case .universe:  return [ParamSpec("scale", "Scale", 0.5, 1.6, def: 1.0),
                                 ParamSpec("speed", "Speed", 0, 3, def: 1),
                                 ParamSpec("stars", "Stars", 0, 2, def: 1),
                                 ParamSpec("planets", "Planet Speed", 0, 3, def: 1),
                                 ParamSpec("orbits", "Orbit Lines", 0, 1, def: 1, toggle: true),
                                 ParamSpec("tilt", "Camera Tilt", 8, 80, def: 24),
                                 ParamSpec("spin", "Camera Orbit", -2, 2, def: 1)]
        case .blackhole: return [ParamSpec("angle", "Angle", 0.05, 1.4, def: 0.22),
                                 ParamSpec("mass", "Mass", 0.15, 0.8, def: 0.4),
                                 ParamSpec("brightness", "Brightness", 1, 10, def: 5),
                                 ParamSpec("speed", "Speed", 0, 3, def: 1),
                                 ParamSpec("stars", "Stars", 0, 3, def: 1),
                                 ParamSpec("rot", "Rotation", -15, 15, def: -8.7),
                                 ParamSpec("disk", "Disk Size", 0.5, 1.6, def: 1)]
        case .meshGradient: return [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                                    ParamSpec("scale", "Softness", 0.5, 2, def: 1),
                                    ParamSpec("hue", "Hue Spread", 0, 1, def: 0.35),
                                    ParamSpec("grain", "Grain", 0, 0.3, def: 0.08)]
        case .aurora:    return [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                                 ParamSpec("intensity", "Glow", 0.3, 2, def: 1),
                                 ParamSpec("height", "Curtain Height", 0.4, 1.6, def: 1),
                                 ParamSpec("stars", "Stars", 0, 1, def: 0.6),
                                 ParamSpec("lake", "Lake Reflection", 0, 1, def: 1),
                                 ParamSpec("activity", "Activity", 0, 1, def: 0.5)]
        case .topography: return [ParamSpec("lines", "Lines", 8, 60, def: 30),
                                  ParamSpec("scale", "Terrain Scale", 0.5, 3, def: 1.2),
                                  ParamSpec("speed", "Speed", 0, 2, def: 0.5),
                                  ParamSpec("fill", "Relief Shading", 0, 1, def: 0.5)]
        case .liquidChrome: return [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                                    ParamSpec("scale", "Ripple Scale", 0.5, 3, def: 1.2),
                                    ParamSpec("iris", "Iridescence", 0, 1, def: 0.12),
                                    ParamSpec("ripple", "Fine Ripples", 0, 1, def: 0.35),
                                    ParamSpec("rough", "Roughness", 0, 1, def: 0.06),
                                    ParamSpec("aniso", "Brushed", 0, 1, def: 0),
                                    ParamSpec("film", "Film Tone", 0, 1, def: 0.5)]
        case .silk:      return [ParamSpec("speed", "Speed", 0, 2, def: 0.6),
                                 ParamSpec("scale", "Fold Size", 0.4, 2.5, def: 1),
                                 ParamSpec("sheen", "Sheen", 0, 1, def: 0.4)]
        case .risograph: return [ParamSpec(menu: "screen", "Screen", ["Grain", "Halftone"], def: 0),
                                 ParamSpec("cell", "Dot Size", 2, 16, def: 4),
                                 ParamSpec("misreg", "Misregistration", 0, 16, def: 5),
                                 ParamSpec("paper", "Paper Texture", 0, 1, def: 0.5)]
        case .grainWash: return [ParamSpec("soft", "Softness", 0, 1, def: 0.6),
                                 ParamSpec("grain", "Grain", 0, 0.5, def: 0.16),
                                 ParamSpec("tint", "Color Wash", 0, 1, def: 0),
                                 ParamSpec("halation", "Halation", 0, 1, def: 0),
                                 ParamSpec("paper", "Paper Texture", 0, 1, def: 0)]
        case .glass:     return [ParamSpec(menu: "style", "Glass", ["Fluted", "Tiles", "Liquid"], def: 0),
                                 ParamSpec("size", "Size", 10, 200, def: 44),
                                 ParamSpec("refract", "Refraction", 0, 1, def: 0.5),
                                 ParamSpec("frost", "Frost", 0, 1, def: 0.3)]
        default: return SceneCatalog.spec(self)?.params ?? []
        }
    }

    var defaultParams: [String: Double] {
        var d: [String: Double] = [:]
        for p in params { d[p.key] = p.def }
        return d
    }

    var defaultColorA: RGBA? {
        switch self {
        case .dither, .threshold, .dots, .wave, .edge, .ascii, .matrix, .neonEdges, .starfield, .universe, .blackhole: return .black
        case .halftone, .crosshatch: return .paper
        case .contour, .truchet: return .ink
        case .meshGradient: return RGBA(0.13, 0.07, 0.34)       // deep indigo
        case .aurora:       return RGBA(0.015, 0.03, 0.07)      // night sky
        case .topography:   return RGBA(0.05, 0.06, 0.07)       // ground
        case .liquidChrome: return RGBA(0.03, 0.03, 0.05)       // shadow
        case .silk:         return RGBA(0.03, 0.03, 0.06)       // shadow
        case .risograph:    return RGBA(1.0, 0.28, 0.53)        // fluorescent pink ink
        case .grainWash:    return RGBA(0.12, 0.08, 0.24)       // shadow wash
        default: return SceneCatalog.spec(self)?.colorA
        }
    }
    var defaultColorB: RGBA? {
        switch self {
        case .dither, .threshold, .dots, .starfield: return .white
        case .halftone, .crosshatch: return .ink
        case .contour: return .paper
        case .wave, .edge, .neonEdges, .truchet: return .cyan
        case .ascii, .matrix, .phosphor: return .crtGreen
        case .meshGradient: return RGBA(1.0, 0.56, 0.42)        // coral
        case .aurora:       return RGBA(0.32, 1.0, 0.50)        // oxygen green
        case .topography:   return RGBA(0.93, 0.90, 0.82)       // contour ink
        case .liquidChrome: return RGBA(0.92, 0.94, 1.0)        // highlight
        case .silk:         return RGBA(0.98, 0.78, 0.55)       // champagne satin
        case .risograph:    return RGBA(0.0, 0.47, 0.75)        // riso medium blue
        case .grainWash:    return RGBA(1.0, 0.80, 0.64)        // highlight wash
        default: return SceneCatalog.spec(self)?.colorB
        }
    }

    var usesColors: Bool { defaultColorA != nil || defaultColorB != nil }

    /// What palette slots A and B mean for this effect (labels for the color wells).
    var colorALabel: String {
        switch self {
        case .risograph: return "Ink 1"
        case .halftone, .crosshatch: return "Paper"
        case .meshGradient: return "Deep"
        case .aurora: return "Sky"
        case .topography: return "Ground"
        case .liquidChrome, .grainWash, .silk: return "Shadow"
        default: return SceneCatalog.spec(self)?.colorALabel ?? "Background"
        }
    }
    var colorBLabel: String {
        switch self {
        case .risograph: return "Ink 2"
        case .halftone, .crosshatch: return "Ink"
        case .meshGradient: return "Light"
        case .aurora: return "Aurora"
        case .topography: return "Lines"
        case .silk: return "Silk"
        case .liquidChrome, .grainWash: return "Highlight"
        default: return SceneCatalog.spec(self)?.colorBLabel ?? "Foreground"
        }
    }

    /// A self-contained generative piece that ignores the source (Universe, Black Hole…).
    /// Styles that start with one are "Scenes": ready to use, few knobs, no Source tab.
    var isScene: Bool {
        switch self {
        case .starfield, .universe, .blackhole,
             .meshGradient, .aurora, .topography, .liquidChrome, .silk: return true
        default: return SceneCatalog.spec(self) != nil
        }
    }

    /// Still decodable from old libraries/share files (and still renders), but no longer
    /// offered in the Add menu: duplicates or dated looks superseded by newer effects.
    var isRetired: Bool {
        switch self {
        case .blockify,                   // duplicate of Pixelate with a bigger range
             .dots,                       // superseded by Halftone / Risograph
             .voronoi,                    // edgeless, muddy mosaic; Hex Mosaic covers it
             .truchet,                    // novelty tile maze
             .toon,                       // dated cel-shade filter
             .fisheye, .swirl, .ripple:   // Photo Booth-era warps; Glass replaces them
            return true
        default: return false
        }
    }

    /// Add-menu entries for a group: live (non-retired) effects only, in catalog order.
    static func available(in category: EffectCategory) -> [EffectKind] {
        allCases.filter { $0.category == category && !$0.isRetired }
    }
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
        case .dither:    u.p0 = .init(g("cell"), g("levels"), g("mono"), g("algo"))
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
        case .nes8bit:   u.p0 = .init(g("cell"), g("scan"), g("sat"), 0)
        case .starfield: u.p0 = .init(g("speed"), g("density"), g("warp"), g("size"))
        case .universe:  u.p0 = .init(g("scale"), g("speed"), g("stars"), g("planets"))
                         // p1/p2 are filled per frame by the renderer (sun, location, orbits);
                         // Universe has no Foreground color well, so colorB carries the camera.
                         u.colorB = .init(g("tilt"), g("spin"), 0, 1)
        case .blackhole: u.p0 = .init(g("mass"), g("brightness"), g("rot"), g("disk"))
                         u.p1 = .init(g("speed"), g("stars"), g("angle"), 0)
        case .meshGradient: u.p0 = .init(g("speed"), g("scale"), g("hue"), g("grain"))
        case .aurora:    u.p0 = .init(g("speed"), g("intensity"), g("height"), g("stars"))
                         u.p1 = .init(g("lake"), g("activity"), 0, 0)
        case .topography: u.p0 = .init(g("lines"), g("scale"), g("speed"), g("fill"))
        case .liquidChrome: u.p0 = .init(g("speed"), g("scale"), g("iris"), g("ripple"))
                            u.p1 = .init(g("rough"), g("aniso"), g("film"), 0)
        case .silk:      u.p0 = .init(g("speed"), g("scale"), g("sheen"), 0)
        case .risograph: u.p0 = .init(g("screen"), g("cell"), g("misreg"), g("paper"))
        case .grainWash: u.p0 = .init(g("soft"), g("grain"), g("tint"), g("halation"))
                         u.p1 = .init(g("paper"), 0, 0, 0)
        case .glass:     u.p0 = .init(g("style"), g("size"), g("refract"), g("frost"))
        default:
            // Scene packs: params fill p0.xyzw, p1.xyzw, p2.xyzw in catalog order.
            var v = (kind.params.prefix(12).map { g($0.key) })
            while v.count < 12 { v.append(0) }
            u.p0 = .init(v[0], v[1], v[2], v[3])
            u.p1 = .init(v[4], v[5], v[6], v[7])
            u.p2 = .init(v[8], v[9], v[10], v[11])
        }
    }
}
