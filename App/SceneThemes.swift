//  SceneThemes.swift — one-click colour themes for a scene (the editor's Themes strip).
//
//  Every scene has a background colour (A) and a main colour (B). A theme re-tints both to a new
//  hue and colourfulness in OKLab while keeping each colour's lightness, so a dark liquid stays
//  dark and a bright wax stays bright — the scene keeps its look in any theme, and one set of
//  themes fits every scene without hand-tuning each. Some scenes add a theme of their own that
//  turns on a param (Lava Lamp's Multicolour).

import SwiftUI

struct SceneTheme: Identifiable {
    let id: String
    let name: String
    let colorA: RGBA?
    let colorB: RGBA?
    /// Params this theme sets (others are left as the user has them).
    var params: [String: Double] = [:]
}

enum SceneThemes {
    /// A re-tint: hue in degrees and chroma (0 = grey) for the background and the main colour.
    private struct Tint {
        let id: String, name: String
        let hueA: Double, chromaA: Double
        let hueB: Double, chromaB: Double
        /// Lift the main colour's lightness (neon glows).
        var liftB: Double = 0
    }

    private static let tints: [Tint] = [
        Tint(id: "blue", name: "Blue", hueA: 255, chromaA: 0.05, hueB: 245, chromaB: 0.14),
        Tint(id: "neon", name: "Neon", hueA: 300, chromaA: 0.07, hueB: 335, chromaB: 0.26, liftB: 0.08),
        Tint(id: "sunset", name: "Sunset", hueA: 15, chromaA: 0.05, hueB: 50, chromaB: 0.16),
        Tint(id: "forest", name: "Forest", hueA: 165, chromaA: 0.04, hueB: 140, chromaB: 0.13),
        Tint(id: "mono", name: "Monochrome", hueA: 0, chromaA: 0, hueB: 0, chromaB: 0),
    ]

    /// The scene's themes: Original (its own colours) first, then the re-tints, then any of its
    /// own. Empty for a layer without colours.
    static func themes(for effect: EffectInstance) -> [SceneTheme] {
        let a = effect.defaultColorAValue, b = effect.defaultColorBValue
        guard a != nil || b != nil else { return [] }
        let keys = Set(effect.paramSpecs.map(\.key))
        // Turning a theme on turns off any scene-specific one (Multicolour) the user had picked.
        let off: [String: Double] = keys.contains("rainbow") ? ["rainbow": 0] : [:]
        var out = [SceneTheme(id: "original", name: "Original", colorA: a, colorB: b, params: off)]
        for t in tints {
            out.append(SceneTheme(id: t.id, name: t.name,
                                  colorA: a.map { retint($0, hue: t.hueA, chroma: t.chromaA, lift: 0) },
                                  colorB: b.map { retint($0, hue: t.hueB, chroma: t.chromaB, lift: t.liftB) },
                                  params: off))
        }
        if keys.contains("rainbow") {
            out.insert(SceneTheme(id: "multicolour", name: "Multicolour", colorA: a, colorB: b, params: ["rainbow": 1]), at: 1)
        }
        return out
    }

    /// Whether `effect` is wearing `theme` now (its colours and the params the theme sets).
    static func isCurrent(_ theme: SceneTheme, _ effect: EffectInstance) -> Bool {
        close(effect.colorA ?? effect.defaultColorAValue, theme.colorA)
            && close(effect.colorB ?? effect.defaultColorBValue, theme.colorB)
            && theme.params.allSatisfy { k, v in abs((effect.params[k] ?? 0) - v) < 0.01 }
    }

    static func apply(_ theme: SceneTheme, to effect: inout EffectInstance) {
        effect.colorA = theme.colorA
        effect.colorB = theme.colorB
        for (k, v) in theme.params { effect.params[k] = v }
    }

    private static func close(_ x: RGBA?, _ y: RGBA?) -> Bool {
        guard let x, let y else { return x == nil && y == nil }
        return abs(x.r - y.r) < 0.01 && abs(x.g - y.g) < 0.01 && abs(x.b - y.b) < 0.01
    }

    // MARK: OKLab

    private static func retint(_ c: RGBA, hue: Double, chroma: Double, lift: Double) -> RGBA {
        let lab = oklab(c)
        let l = min(lab.l + lift, 0.97)
        // a near-black or near-white colour can't carry much chroma: scale it down at the ends
        let room = min(1, min(l, 1 - l) * 4)
        let h = hue * .pi / 180
        return srgb(l: l, a: chroma * room * cos(h), b: chroma * room * sin(h), alpha: c.a)
    }

    private static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func toSRGB(_ v: Double) -> Double {
        let c = max(0, min(1, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func oklab(_ c: RGBA) -> (l: Double, a: Double, b: Double) {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func srgb(l L: Double, a A: Double, b B: Double, alpha: Double) -> RGBA {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        return RGBA(toSRGB(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                    toSRGB(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                    toSRGB(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha)
    }
}

/// The editor's Themes strip for a scene: a swatch per theme (its background and main colour),
/// the one it's wearing ringed. Click to apply; the colour wells below stay editable.
struct SceneThemeStrip: View {
    @Binding var effect: EffectInstance
    @Environment(\.layout) private var layout

    var body: some View {
        let themes = SceneThemes.themes(for: effect)
        if themes.count > 1 {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text("Theme").textRole(.callout).foregroundStyle(.secondary)
                FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                    ForEach(themes) { t in
                        let on = SceneThemes.isCurrent(t, effect)
                        Button { SceneThemes.apply(t, to: &effect) } label: {
                            VStack(spacing: 3) {
                                swatch(t)
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.15),
                                                                   lineWidth: on ? 2.5 : 1))
                                Text(t.name).textRole(.caption)
                                    .foregroundStyle(on ? .primary : .secondary)
                                    .lineLimit(1).fixedSize()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(t.name) theme")
                        .accessibilityLabel("\(t.name) theme")
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    /// Background colour below, main colour above; Multicolour shows a spectrum.
    @ViewBuilder private func swatch(_ t: SceneTheme) -> some View {
        if t.id == "multicolour" {
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
        } else {
            Circle().fill(LinearGradient(colors: [Color(t.colorB ?? .white), Color(t.colorA ?? .black)],
                                         startPoint: .top, endPoint: .bottom))
        }
    }
}
