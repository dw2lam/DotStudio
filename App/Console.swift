//  Console.swift — the "Console" appearance (issue #6, experimental): DotStudio as a small,
//  precise instrument. Since 2026-11-26 it follows the owner's own Google Stitch redesign: a
//  warm off-white / graphite body, keys with travel (a slim 2 pt skirt the face sinks into),
//  recessed wells, one orange signal, and three bundled SIL OFL faces (App/Fonts, registered
//  through ATSApplicationFontsPath): Wix Madefor Display for titles, Instrument Sans for text,
//  Source Code Pro for legends and readouts.
//
//  What it is made of:
//    • Appearance  — Settings › General › Appearance: Classic (default) / Console. Read with
//                    @Environment(\.console); ContentView publishes it.
//    • ConsoleInk  — the colour tokens: chassis (warm grey; graphite in Dark Mode), panel,
//                    hairline, ink, legend, one signal orange, and four knob colours.
//    • Legends     — tiny mono caps (`TextRole.legend`) and readouts (`TextRole.readout`).
//    • ConsoleLED  — a small status light (colour + its legend, never colour alone).
//    • ConsoleKnob — a real control: a rotary knob that acts as a slider (drag up/down, scroll,
//                    arrow keys, ⌥ for fine steps, double-click or ⌫ to reset, click the readout
//                    to type a value), with a detent at its default.
//    • ConsoleTouch — what's being turned right now, for the preview's coloured tag.
//
//  Guardrails (issue #6): every knob changes the output; legends only where they help; Dynamic
//  Type through TextRole; VoiceOver sees knobs as adjustable sliders; Reduce Motion respected.

import SwiftUI
import AppKit

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case classic, console
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic" : "Retro" }
    static let key = "appearance"
    /// DEV / offscreen renders: DOTSTUDIO_APPEARANCE=console|classic wins over the saved choice
    /// (UIShots never writes the user's own preference).
    static let forced: Appearance? = ProcessInfo.processInfo.environment["DOTSTUDIO_APPEARANCE"].flatMap(Appearance.init)
}

/// Light or dark for the app's own windows (Settings › General › Mode), in either appearance.
/// Auto follows macOS. Never applied in a headless run (renders set their own).
enum ColorMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .auto: "Auto"; case .light: "Light"; case .dark: "Dark" } }
    static let key = "colorMode"
    static var saved: ColorMode {
        UserDefaults.standard.string(forKey: key).flatMap(ColorMode.init) ?? .auto
    }
    @MainActor static func apply(_ mode: ColorMode = saved) {
        guard !Appearance.isHeadlessRun, DemoHooks.appearance == nil else { return }
        switch mode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct ConsoleKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The Console appearance is on (Settings › General › Appearance).
    var console: Bool {
        get { self[ConsoleKey.self] }
        set { self[ConsoleKey.self] = newValue }
    }
}

// MARK: - Colour

/// Console's colour tokens. Each adapts to Light / Dark (a graphite chassis).
enum ConsoleInk {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // The Stitch palette (2026-11-26, the owner's Google Stitch redesign): a warm off-white /
    // graphite body, surfaces stepped by depth, one orange signal, a blue for "playing behind
    // your windows", green and amber for status. Names follow depth, not use.

    /// The body (window background): #EAEAE5 / #131316.
    static let chassis = dynamic(rgb(0xEAEAE5), rgb(0x131316))
    /// A raised panel on it (the deck around each screen, tiles, the inspector): #F3F3EE / #1B1B1E.
    static let panel = dynamic(rgb(0xF3F3EE), rgb(0x1B1B1E))
    /// A recessed well (search field, a screen's surround, sliders' tracks): #FFFFFF / #0E0E11.
    static let well = dynamic(rgb(0xFFFFFF), rgb(0x0E0E11))
    /// A key's face: #D8D8D1 / #2A2A2D.
    static let keyFace = dynamic(rgb(0xD8D8D1), rgb(0x2A2A2D))
    /// A key's skirt (the 2 pt side you see under its face until it's pressed).
    static let keySkirt = dynamic(rgb(0xB8B8B0), rgb(0x070709))
    /// The middle surface (sidebar, inset groups): #E2E2DC / #1F1F22.
    static let surface = dynamic(rgb(0xE2E2DC), rgb(0x1F1F22))
    /// The highest surface (a hovered row, a tag's fill): #CECEC6 / #353438.
    static let surfaceHigh = dynamic(rgb(0xCECEC6), rgb(0x353438))
    /// Hairline edges (outline-variant): #C8C8C0 / #353438.
    static let hairline = dynamic(rgb(0xC8C8C0), rgb(0x353438))
    /// A stronger edge (outline): #7A7A7E / #78767A.
    static let outline = dynamic(rgb(0x7A7A7E), rgb(0x78767A))
    /// Main text: #141416 / #E4E1E6.
    static let ink = dynamic(rgb(0x141416), rgb(0xE4E1E6))
    /// Legends: tiny printed labels (on-surface-variant): #525257 / #ACAAAE.
    static let legend = dynamic(rgb(0x525257), rgb(0xACAAAE))
    /// The one signal colour: live / active / selected. #FF7300 in both.
    static let signal = dynamic(rgb(0xFF7300), rgb(0xFF7300))
    /// The signal's skirt (an orange key's side): #B34B00 / #8C3D00.
    static let signalSkirt = dynamic(rgb(0xCC5A00), rgb(0xA34800))
    /// Text ON a signal (orange) key: near-black, like the design (#1F0B00).
    static let onSignal = Color(nsColor: rgb(0x1F0B00))
    /// The signal colour as TEXT or a thin edge on the light body: dark enough for WCAG AA
    /// (#B34B00 ≈ 4.6:1 on #EAEAE5) — the bright signal is for fills and lights.
    static let signalInk = dynamic(rgb(0xB34B00), rgb(0xFFB780))
    /// The wallpaper's blue (its channel light, the Play key): #0088E8 / #0095F8.
    static let blue = dynamic(rgb(0x0088E8), rgb(0x0095F8))
    /// The blue key's skirt.
    static let blueSkirt = dynamic(rgb(0x1670C4), rgb(0x0B5A9C))
    /// Blue as text/edge on the body: #005FA1 / #9FCAFF.
    static let blueInk = dynamic(rgb(0x005FA1), rgb(0x9FCAFF))
    /// Status green (a range that's on, a source that's fine): #00D26A.
    static let green = Color(nsColor: rgb(0x00D26A))
    /// Status amber (live weather, a warning): #FFB800.
    static let amber = Color(nsColor: rgb(0xFFB800))

    // More signals, each with one job (2026-11-26, "a variety of vibrant colours… green for
    // the toggles"): green = ON (switches, what's playing), yellow = a Look / live weather,
    // pink = a pack tag / day & night. Orange stays the primary action and the screensaver;
    // blue the wallpaper and a chosen segment. Each has a key face, a skirt, the ink printed
    // on its face and an ink for text on the body (≥ 4.5:1 on the light chassis).

    /// A switch that's on, a green key: #00BD5F on the light body (a step deeper, so the
    /// near-black thumb and the fill both hold an edge on off-white), #00D26A on graphite.
    static let greenKey = dynamic(rgb(0x00BD5F), rgb(0x00D26A))
    static let greenSkirt = dynamic(rgb(0x00994D), rgb(0x007A3C))
    /// Text on a green key / a green switch's thumb: near-black green (≈ 8:1 on the fill).
    static let onGreen = Color(nsColor: rgb(0x00170A))
    /// Green as text/edge on the body: #00753A (≈ 4.8:1) / #5CF0A0.
    static let greenInk = dynamic(rgb(0x00753A), rgb(0x5CF0A0))
    /// A yellow key (Looks, live weather): #FFC400.
    static let yellow = Color(nsColor: rgb(0xFFC400))
    static let yellowSkirt = dynamic(rgb(0xC79A00), rgb(0x9C7800))
    static let onYellow = Color(nsColor: rgb(0x1F1700))
    /// Yellow as text on the body: #7A5A00 (≈ 5.3:1) / #FFD54D.
    static let yellowInk = dynamic(rgb(0x7A5A00), rgb(0xFFD54D))
    /// A pink key (a pack tag: Clocks, Nature…): #FF4D94.
    static let pink = Color(nsColor: rgb(0xFF4D94))
    static let pinkSkirt = dynamic(rgb(0xD13A78), rgb(0xA82A5E))
    static let onPink = Color(nsColor: rgb(0x2A0014))
    /// Pink as text on the body: #C2185B (≈ 4.8:1) / #FF8FBF.
    static let pinkInk = dynamic(rgb(0xC2185B), rgb(0xFF8FBF))

    /// The four knob caps, in order (a style's dials cycle through them): the Stitch palette's
    /// own colours — the wallpaper blue, status green, a white cap, the signal orange.
    static let knobs: [Color] = [
        dynamic(rgb(0x0088E8), rgb(0x0095F8)),     // blue
        dynamic(rgb(0x00BD5F), rgb(0x00D26A)),     // green
        dynamic(rgb(0xFBFBF7), rgb(0xE4E1E6)),     // white
        dynamic(rgb(0xFF7300), rgb(0xFF7300)),     // orange
    ]
    static let knobNames = ["blue", "green", "white", "orange"]
    /// Each cap's pointer line: white on the blue cap, the near-black of text on a signal key
    /// on the brighter ones.
    static let knobPointers: [Color] = [
        Color.white.opacity(0.95),
        Color(nsColor: rgb(0x00170A, 0.82)),
        Color(nsColor: rgb(0x141416, 0.8)),
        Color(nsColor: rgb(0x1F0B00, 0.85)),
    ]
    /// The default's dot printed beside each knob: the cap's colour, except the white cap's,
    /// which prints in ink (a white dot would vanish on the light panel).
    static let knobMarks: [Color] = [knobs[0], knobs[1], ink, knobs[3]]

    /// The white knob's rim. On the light panel a near-white cap has no edge of its own, so it
    /// gets a printed grey one (≥ 3:1 against the panel and the strip's well); on the graphite
    /// chassis it already stands out and keeps the other caps' faint dark rim.
    static let whiteKnobRim = dynamic(rgb(0x78756E), rgb(0x000000, 0.18))
    /// The white knob's value arc: legend grey at the weight of the coloured arcs (about 3.4:1
    /// on the light strip, 4.9:1 on the dark one — the blue arc's contrast), not a heavier ink.
    static let whiteKnobArc = legend.opacity(0.8)
    /// A knob's printed scale: the tick dots the value hasn't reached, and those it has.
    static let knobTick = dynamic(rgb(0x7A7A7E, 0.45), rgb(0x78767A, 0.55))
    static let knobTickLit = dynamic(rgb(0x525257), rgb(0xACAAAE))
}

// MARK: - Type

/// The bundled faces, by PostScript name (App/Fonts).
enum ConsoleFace {
    static let display = "WixMadeforDisplay-SemiBold"
    static let displayMedium = "WixMadeforDisplay-Medium"
    static let text = "InstrumentSans-Regular"
    static let textMedium = "InstrumentSans-Medium"
    static let textSemibold = "InstrumentSans-SemiBold"
    static let mono = "SourceCodePro-Medium"
    static let monoSemibold = "SourceCodePro-SemiBold"
    static let monoBold = "SourceCodePro-Bold"
}

extension TextRole {
    // The Stitch type scale (sizes at the default text size; all scale with it).
    /// A screen's big title ("Commute" on the Screensaver deck; the editor's style name): 18 pt display.
    static let consoleHeadline = TextRole(style: .title3, points: 18, face: ConsoleFace.display)
    /// A page header ("Scenes"): 24 pt display.
    static let consoleSection = TextRole(style: .title2, points: 24, face: ConsoleFace.display)
    /// A name on a tile, a sidebar row, a card's title: 14 pt Instrument Sans semibold.
    static let consoleTitle = TextRole(style: .body, points: 14, face: ConsoleFace.textSemibold)
    /// Body text: 13 pt Instrument Sans.
    static let consoleBody = TextRole(style: .body, points: 13, face: ConsoleFace.text)
    /// Small body (a deck's one-line "what it is", hints): 12 pt.
    static let consoleBodySmall = TextRole(style: .callout, points: 12, face: ConsoleFace.text)
    /// A key's legend: 12 pt mono caps, tracked (11 pt before 2026-11-26 — the owner found the
    /// keys a touch small).
    static let consoleKey = TextRole(style: .caption, points: 12, tracking: 0.5, uppercase: true, face: ConsoleFace.monoSemibold)
    /// A small key's legend (Customize, Preview, the hover bar's keys — HubKeyLabel): 11.5 pt
    /// mono caps, a step over the printed legends so a key reads as something to press.
    static let consoleKeySmall = TextRole(style: .caption, points: 11.5, tracking: 0.6, uppercase: true, face: ConsoleFace.monoSemibold)
    /// A row's value in mono, not uppercased ("1 style", "Same on all"): 12 pt.
    static let consoleValue = TextRole(style: .caption, points: 12, monospacedDigits: true, face: ConsoleFace.mono)
    /// A deck's name ("Screensaver", "Wallpaper"): 22 pt display — the tile's own title.
    static let consoleTileTitle = TextRole(style: .title2, points: 22, face: ConsoleFace.display)
    /// What a deck plays now ("Liquid Chrome"): 15 pt Instrument Sans medium, a step under the title.
    static let consoleNowPlaying = TextRole(style: .body, points: 15, face: ConsoleFace.textMedium)

    /// Tiny printed legends: 10 pt mono caps, tracked 0.8.
    static let legend = TextRole(style: .caption2, points: 10, tracking: 0.8, uppercase: true, face: ConsoleFace.monoSemibold)
    /// A pad's number ("07").
    static let padNumber = TextRole(style: .caption, points: 10.5, monospacedDigits: true, face: ConsoleFace.monoSemibold)
    /// Numeric readouts (slider values, fps).
    static let readout = TextRole(style: .callout, points: 11.5, monospacedDigits: true, face: ConsoleFace.mono)
    /// A big numeric readout ("40–120" fps): 24 pt display.
    static let readoutLarge = TextRole(style: .title2, points: 24, face: ConsoleFace.displayMedium)
    /// A pad's name: Instrument Sans semibold, as the design (not mono caps).
    static let padName = TextRole(style: .body, points: 14, face: ConsoleFace.textSemibold)
}

// MARK: - Surfaces

extension View {
    /// A Console panel (a deck, a tile, the inspector): panel colour, a hairline edge, 8 pt
    /// corners, no glass and no big shadow.
    func consolePanel(cornerRadius: CGFloat = 8) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(ConsoleInk.panel))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(ConsoleInk.hairline, lineWidth: 1))
    }

    /// A recessed well (search field, slider track, a screen's surround): the well colour with
    /// an inner shadow from the top and a 1 pt light lip under it, a hairline edge.
    func consoleWell(cornerRadius: CGFloat = 4, focused: Bool = false) -> some View {
        modifier(ConsoleWell(cornerRadius: cornerRadius, focused: focused))
    }
}

private struct ConsoleWell: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat
    let focused: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background(shape.fill(ConsoleInk.well
                .shadow(.inner(color: .black.opacity(dark ? 0.8 : 0.16), radius: dark ? 3.5 : 2.5, y: dark ? 3 : 2))))
            .overlay(shape.strokeBorder(focused ? ConsoleInk.signal : ConsoleInk.hairline, lineWidth: 1))
            // the lip: a hair of light under the well's bottom edge
            .background(shape.offset(y: 1).fill(Color.white.opacity(dark ? 0.06 : 0.8)))
    }
}

// MARK: - Keys

/// A Console keycap (the Stitch key, refined 2026-11-26): a face on a slim 2 pt skirt that the
/// face sinks into when pressed (80 ms, ease-out), a hairline edge, a faint top light, a short
/// contact shadow — and on a coloured key a soft, wide glow in its own colour (a lit key, not
/// a drop shadow). A haptic tick on press.
///  • `.plain`  — the grey key (icon keys, filter keys, Customize).
///  • `.signal` — the orange key (Preview, Done, the primary action, ALL).
///  • `.blue`   — the wallpaper's blue (Play while the wallpaper plays, a chosen segment).
///  • `.green` / `.yellow` / `.pink` — a filter key's own colour while it's chosen (Playing,
///    Looks, a pack tag); green is also ON.
/// `latched` draws a key that's held down (a selected segment): its face rests 1 pt down in
/// its skirt (a press takes it 1.5 pt). Only the face moves: the skirt's base — the key's
/// footprint — and the layout size are the same in every state, so a latched key's bottom
/// edge lines up with its neighbours'.
struct ConsoleKeycapStyle: ButtonStyle {
    enum Tint { case plain, signal, blue, green, yellow, pink }
    /// The skirt: how much of the key's side shows under its face (4 pt before 2026-11-26 —
    /// the owner found the keys too thick). The faces' padding grew by what the skirt gave
    /// up, so a key's footprint is as tall as before.
    static let skirt: CGFloat = 2
    /// A press sinks the face this far into its skirt; a latched key rests at `latchedTravel`.
    static let travel: CGFloat = 1.5
    static let latchedTravel: CGFloat = 1
    /// A group of keys in a well (segments, transport): room around the keys inside the well
    /// and between them (2 pt each before 2026-11-26 — the owner wanted the box roomier).
    /// The bottom inset is smaller: the keys' skirts already sit there.
    static let wellInset: CGFloat = 4
    static let wellBottomInset: CGFloat = 3
    static let wellSpacing: CGFloat = 3
    var tint: Tint = .plain
    var latched = false
    var cornerRadius: CGFloat = 4
    /// Inner padding; nil = the label sets its own size (icon keys use a fixed frame).
    var padding: EdgeInsets? = ConsoleKeycapStyle.standardPadding
    /// A standard key's padding: 9 × 14 around its legend (8 × 14 over a 4 pt skirt, 6 × 12
    /// before that), so a one-line key's face is about 32 pt tall, plus its skirt.
    static let standardPadding = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)

    func makeBody(configuration: Configuration) -> some View {
        ConsoleKeycapBody(configuration: configuration, tint: tint, latched: latched,
                       cornerRadius: cornerRadius, padding: padding)
    }
}

extension ConsoleKeycapStyle.Tint {
    /// The key's face.
    var face: Color {
        switch self {
        case .plain: ConsoleInk.keyFace
        case .signal: ConsoleInk.signal
        case .blue: ConsoleInk.blue
        case .green: ConsoleInk.greenKey
        case .yellow: ConsoleInk.yellow
        case .pink: ConsoleInk.pink
        }
    }
    /// Its side, under the face.
    var skirt: Color {
        switch self {
        case .plain: ConsoleInk.keySkirt
        case .signal: ConsoleInk.signalSkirt
        case .blue: ConsoleInk.blueSkirt
        case .green: ConsoleInk.greenSkirt
        case .yellow: ConsoleInk.yellowSkirt
        case .pink: ConsoleInk.pinkSkirt
        }
    }
    /// What prints on the face: dark ink on the bright keys, white on blue.
    var ink: Color {
        switch self {
        case .plain: ConsoleInk.ink
        case .signal: ConsoleInk.onSignal
        case .blue: .white
        case .green: ConsoleInk.onGreen
        case .yellow: ConsoleInk.onYellow
        case .pink: ConsoleInk.onPink
        }
    }
    var isPlain: Bool { self == .plain }
}

/// The keys' light and shade, shared by every key-like part (ConsoleKeycapStyle,
/// consoleKeyFace, the Settings cards, the switches' thumbs) so they read as one family.
enum ConsoleKeyLight {
    /// The face's wash, top to bottom: a faint light falling off to a hair of shade.
    static func wash(_ tint: ConsoleKeycapStyle.Tint, dark: Bool) -> LinearGradient {
        let top = tint.isPlain ? (dark ? 0.035 : 0.3) : 0.08
        let bottom = tint.isPlain ? (dark ? 0.08 : 0.025) : 0.03
        return LinearGradient(colors: [.white.opacity(top), .black.opacity(bottom)], startPoint: .top, endPoint: .bottom)
    }
    /// The lit top edge (gone while the key is down), drawn at `highlightWidth`.
    static func highlight(_ tint: ConsoleKeycapStyle.Tint, dark: Bool, down: Bool) -> LinearGradient {
        let o = down ? 0 : (tint.isPlain ? (dark ? 0.09 : 0.55) : 0.28)
        return LinearGradient(colors: [.white.opacity(o), .clear], startPoint: .top, endPoint: .center)
    }
    static let highlightWidth: CGFloat = 0.75
    /// A grey key's edge: a 0.5 pt line (1 pt hairline before 2026-11-26); orange and 1 pt
    /// under the pointer. Coloured keys carry their edge in their skirt.
    static let edgeWidth: CGFloat = 0.5
    static let hoverEdgeWidth: CGFloat = 1
    static func edge(hovering: Bool, dark: Bool) -> Color {
        hovering ? ConsoleInk.signal.opacity(0.85) : ConsoleInk.outline.opacity(dark ? 0.45 : 0.35)
    }
    /// A press's shade inside the face.
    static func pressShade(dark: Bool, down: Bool) -> Color { .black.opacity(down ? (dark ? 0.4 : 0.12) : 0) }

    /// The shadow under the skirt. A grey key: a short contact shadow (a 6 pt drop before
    /// 2026-11-26). A coloured key — or a grey one under the pointer — a soft glow in its
    /// colour: wide (12 pt), low (0.2; 0.3 on graphite, where a light should read as lit),
    /// a little brighter under the pointer, mostly gone while pressed.
    struct Shade { let color: Color; let radius: CGFloat; let y: CGFloat }
    static func shade(_ tint: ConsoleKeycapStyle.Tint, dark: Bool, down: Bool, hovering: Bool) -> Shade {
        if tint.isPlain {
            if hovering && !down {
                return Shade(color: ConsoleInk.signal.opacity(dark ? 0.2 : 0.14), radius: 8, y: 1)
            }
            return Shade(color: .black.opacity(down ? 0 : (dark ? 0.32 : 0.07)), radius: down ? 0 : 1.5, y: 1)
        }
        // Softer again (owner, 2026-11-26: "even softer — the green switch is right, the blue
        // isn't"): wide and faint like the switch's light, blue a step fainter still (a
        // saturated blue reads louder than green at the same opacity).
        let k: Double = tint == .blue ? 0.7 : 1
        let o = (down ? (dark ? 0.08 : 0.05) : (dark ? 0.2 : 0.13) + (hovering ? 0.05 : 0)) * k
        return Shade(color: tint.face.opacity(o), radius: down ? 6 : 14, y: down ? 0.5 : 1)
    }
}

private struct ConsoleKeycapBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: ConsoleKeycapStyle.Tint
    let latched: Bool
    let cornerRadius: CGFloat
    let padding: EdgeInsets?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let skirtH = ConsoleKeycapStyle.skirt
        let sink: CGFloat = configuration.isPressed ? ConsoleKeycapStyle.travel : latched ? ConsoleKeycapStyle.latchedTravel : 0
        let down = sink > 0
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        let hot = hovering && enabled
        let ink: Color = tint.isPlain ? (hot ? ConsoleInk.signalInk : ConsoleInk.ink) : tint.ink
        let shade = ConsoleKeyLight.shade(tint, dark: dark, down: down, hovering: hot)

        configuration.label
            .foregroundStyle(ink)
            .padding(padding ?? EdgeInsets())
            .background {
                shape.fill(tint.face)
                    .overlay(shape.fill(ConsoleKeyLight.wash(tint, dark: dark)))
                    // pressed: a shade inside the face from the top
                    .overlay(shape.fill(Color.clear.shadow(.inner(color: ConsoleKeyLight.pressShade(dark: dark, down: down), radius: 1, y: 1))))
                    // the top light
                    .overlay(alignment: .top) {
                        shape.strokeBorder(ConsoleKeyLight.highlight(tint, dark: dark, down: down), lineWidth: ConsoleKeyLight.highlightWidth)
                    }
            }
            .overlay {
                if tint.isPlain {
                    shape.strokeBorder(ConsoleKeyLight.edge(hovering: hot, dark: dark),
                                       lineWidth: hot ? ConsoleKeyLight.hoverEdgeWidth : ConsoleKeyLight.edgeWidth)
                }
            }
            .offset(y: sink)
            // the skirt, then its shadow or glow under everything. The skirt never moves: its
            // base is the key's footprint, level with its neighbours' whether the key is up,
            // latched or pressed — the face sinks into it.
            .background {
                shape.fill(tint.skirt)
                    .offset(y: skirtH)
                    .shadow(color: shade.color, radius: shade.radius, y: shade.y)
            }
            .padding(.bottom, skirtH)          // reserve the skirt's room so keys don't overlap rows
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: sink)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hot)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
    }
}

extension ButtonStyle where Self == ConsoleKeycapStyle {
    /// A grey Console key.
    static var keycap: ConsoleKeycapStyle { ConsoleKeycapStyle() }
    /// A Console key: tint, latched, corner radius, padding.
    static func keycap(_ tint: ConsoleKeycapStyle.Tint = .plain, latched: Bool = false, cornerRadius: CGFloat = 4,
                           padding: EdgeInsets? = ConsoleKeycapStyle.standardPadding) -> ConsoleKeycapStyle {
        ConsoleKeycapStyle(tint: tint, latched: latched, cornerRadius: cornerRadius, padding: padding)
    }
    /// A square icon key: no padding, its label sets the size (the editor's header keys).
    static var iconKeycap: ConsoleKeycapStyle { ConsoleKeycapStyle(padding: EdgeInsets()) }
}

// MARK: - Small parts

/// A small tag: mono caps on a high surface with a hairline (the "SCENE" beside a name, the
/// header's status readout).
struct ConsoleTag: View {
    let text: String
    /// A filled tag (orange "SCREENSAVER" on a tile); nil = the plain grey tag.
    var fill: Color? = nil
    var body: some View {
        Text(text).textRole(.legend)
            .foregroundStyle(fill == nil ? ConsoleInk.legend : ConsoleInk.onSignal)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(fill ?? ConsoleInk.keyFace))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(fill == nil ? ConsoleInk.hairline : .clear))
    }
}

/// A legend row: mono-caps legend (with an optional SF Symbol) on the left, its value or control
/// on the right, a hairline under it — the decks' Playlist / Night / … rows and the inspector's.
struct ConsoleRow<Value: View>: View {
    let legend: String
    var symbol: String? = nil
    var divider = true
    @ViewBuilder let value: () -> Value
    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ConsoleInk.legend).frame(width: 14)
            }
            Text(legend).textRole(.legend).foregroundStyle(ConsoleInk.legend)
            Spacer(minLength: 8)
            value()
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(ConsoleInk.hairline).frame(height: 1) } }
    }
}

// MARK: - LED

/// A small status light with its legend: lit (colour + a soft halo) or dark. The legend always
/// says what it is, so colour is never the only signal. Without a legend the LED is decoration
/// on a control that states its own state (a filter key's selected trait), so VoiceOver skips
/// it rather than prefixing that control's name with "On"/"Off".
struct ConsoleLED: View {
    let on: Bool
    var color: Color = ConsoleInk.signal
    var label: String? = nil
    /// The dot grows with the legend beside it (Dynamic Type).
    @ScaledLength(relativeTo: .caption2) private var dot: CGFloat = 6
    @ScaledLength(relativeTo: .caption2) private var gap: CGFloat = 4

    var body: some View {
        HStack(spacing: gap) {
            Circle()
                .fill(on ? color : ConsoleInk.hairline)
                .overlay(Circle().strokeBorder(ConsoleInk.hairline, lineWidth: 0.5))
                .frame(width: dot, height: dot)
                // The glow is a flat radial fill behind the dot, not a shadow: a blur is an
                // offscreen pass per lit LED on every frame the gallery scrolls.
                .background {
                    if on {
                        Circle()
                            .fill(RadialGradient(colors: [color.opacity(0.55), color.opacity(0)], center: .center,
                                                 startRadius: dot * 0.3, endRadius: dot))
                            .frame(width: dot * 2, height: dot * 2)
                            .allowsHitTesting(false)
                    }
                }
            if let label {
                Text(label).textRole(.legend).foregroundStyle(on ? ConsoleInk.ink : ConsoleInk.legend)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "\($0), \(on ? "on" : "off")" } ?? "")
        .accessibilityHidden(label == nil)
    }
}

// MARK: - What's being turned

/// The knob being turned right now (its legend, colour and readout), so the editor's preview
/// can show a coloured tag of what's changing. Cleared a moment after the hand lets go.
final class ConsoleTouch: ObservableObject {
    static let shared = ConsoleTouch()
    struct Touch: Equatable { let label: String; let value: String; let colorIndex: Int }
    @Published private(set) var current: Touch?
    private var clear: DispatchWorkItem?

    /// DEV / offscreen renders: DOTSTUDIO_DEMO_TOUCH="Label|Value|colourIndex" holds a touch.
    private init() {
        if let d = ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_TOUCH"] {
            let p = d.split(separator: "|").map(String.init)
            if p.count == 3, let i = Int(p[2]) { current = Touch(label: p[0], value: p[1], colorIndex: i) }
        }
    }

    func touch(_ t: Touch) {
        clear?.cancel()
        if current != t { current = t }
    }

    func release() {
        clear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.current = nil }
        clear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }
}

// MARK: - Knob

/// A rotary knob that is a slider (a hardware encoder): 270° of travel printed as a scale of
/// 11 tick dots (those the value has passed darken), a coloured dot at the default, a
/// keycap-like cap — its colour, a lit top edge and a skirt under it, as the Stitch keys —
/// with a pointer line; the value in mono above (click to type an exact value) and the
/// legend in mono caps below.
///
/// Turn it by dragging up/down (the full range in 180 pt; ⌥ for a tenth of that, which can be
/// pressed or let go mid-drag), by scrolling over it, or with the arrow keys once focused
/// (⌥ fine). Double-click, ⌫ or VoiceOver's "Reset to default" action resets it.
///
/// The trackpad ticks (`.alignment`) each time the value crosses a twelfth of its range, like
/// an encoder's detents. The default has a detent of its own: a drag or a trackpad swipe
/// settles into it and has to push through to leave; a discrete step (arrow key, VoiceOver, a
/// mouse-wheel notch) is never held there, but one that would jump over the default stops on
/// it once. Typed values and resets are exact. The trackpad gives a firmer tick
/// (`.levelChange`) as the value lands on the default or a fast turn passes it, never while
/// it sits there.
struct ConsoleKnob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let defaultValue: Double
    /// Index into ConsoleInk.knobs.
    let colorIndex: Int
    let format: (Double) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    /// The dial's square (scale, cap and pointer): 64 pt at the default text size.
    @ScaledLength(relativeTo: .body) private var size: CGFloat = 64
    @ScaledLength(relativeTo: .callout) private var fieldWidth: CGFloat = 110
    /// The hand is on the knob (a drag in progress). Resets itself if the drag is cancelled.
    @GestureState private var dragging = false
    /// A drag's running value before the detent and the step, so slow and ⌥-fine moves add up.
    @State private var dragRaw: Double?
    @State private var dragLastY: CGFloat = 0
    /// A trackpad swipe's running value since it began over the knob (momentum included).
    @State private var swipeRaw: Double?
    @State private var hovering = false
    @State private var editing = false
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var cap: Int { colorIndex % ConsoleInk.knobs.count }
    private var color: Color { ConsoleInk.knobs[cap] }
    private var isWhite: Bool { cap == 2 }
    private var span: Double { max(range.upperBound - range.lowerBound, 1e-9) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }
    private static let sweep = 270.0
    /// The printed scale's dots, start to end.
    private static let ticks = 11
    /// Haptic detents per full turn (one each twelfth of the range).
    private static let detents = 12.0

    var body: some View {
        VStack(spacing: Space.xxs) {
            readout

            dial
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(drag)
                .onTapGesture(count: 2) { reset() }
                // Scroll: an AppKit view over the dial that only ever takes scroll events.
                .overlay(KnobScroll(enabled: isEnabled, engaged: dragging, turn: scrolled).accessibilityHidden(true))
                .onHover { hovering = $0 }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                    let up = press.key == .upArrow || press.key == .rightArrow
                    nudge(up ? 1 : -1, fine: press.modifiers.contains(.option))
                    return .handled
                }
                .onDeleteCommand { reset() }   // ⌫ / ⌦ while focused (⌘⌫ stays the menu's)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
                .accessibilityAdjustableAction { dir in nudge(dir == .increment ? 1 : -1, fine: false) }
                .accessibilityAction(named: "Reset to \(format(defaultValue))") { reset() }
                .help("\(label) — drag up or down, scroll, or use the arrow keys (⌥ for fine). Double-click or ⌫ to reset.")

            // The legend gets the knob's whole column and wraps onto a second line at a space
            // (CURTAIN HEIGHT), at the user's text size — never shrunk below it. Its longest
            // word sets the knob's minimum width, so a word is never split: the dial grid
            // (ConsoleDialGrid) takes fewer columns rather than break BRIGHTNESS or MISREGISTRATION.
            ZStack {
                Text(longestWord).textRole(.legend).fixedSize().hidden().accessibilityHidden(true)
                Text(label)
                    .textRole(.legend)
                    .foregroundStyle(ConsoleInk.legend)
                    .multilineTextAlignment(.center)
                    .truncating(label, lines: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: dragging) { _, held in if !held { endDrag() } }
        .onDisappear { endDrag() }
    }

    private var longestWord: String {
        label.components(separatedBy: " ").max { $0.count < $1.count } ?? label
    }

    private var readout: some View {
        Button { typed = format(value); editing = true } label: {
            Text(format(value))
                .textRole(.readout)
                .foregroundStyle(ConsoleInk.ink)
                .lineLimit(1)
                .padding(.horizontal, Space.xxs + 2).padding(.vertical, 1)
                .frame(minWidth: size * 0.8)
                .consoleWell(cornerRadius: 2)
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .help("Type an exact value")
        .accessibilityLabel("Type a value for \(label)")
        .accessibilityValue(format(value))
        .popover(isPresented: $editing, arrowEdge: .top) {
            TextField(label, text: $typed)
                .textRole(.readout)
                .textFieldStyle(.roundedBorder)
                .frame(width: fieldWidth)
                .padding(Space.s)
                // a number it can't read keeps the field open instead of dropping the entry
                .onSubmit { if commitTyped() { editing = false } }
        }
    }

    // MARK: Drawing

    /// The dial, all drawn in its `size` square around one centre: the printed scale (11 dots
    /// on a 270° arc, open at the bottom), the default's coloured dot on it, and the cap — a
    /// round key on a skirt with a pointer line. Angles: 0° points straight up; the scale runs
    /// from −135° (the minimum) to +135° (the maximum).
    private var dial: some View {
        let def = min(max((defaultValue - range.lowerBound) / span, 0), 1)
        let angle = { (f: Double) in Angle.degrees(-Self.sweep / 2 + Self.sweep * f) }
        let ring = size / 2 - size * 0.045           // the scale's radius
        let dot = max(size * 0.04, 2)                 // a tick dot
        let capD = size * 0.62                        // the cap's diameter
        let skirt = max(size * 0.045, 2)              // how much of its side shows under it
        let lit = hovering || dragging || focused
        return ZStack {
            // the printed scale: dots the value has passed darken
            ForEach(0..<Self.ticks, id: \.self) { i in
                let f = Double(i) / Double(Self.ticks - 1)
                Circle()
                    .fill(f <= fraction + 1e-6 ? ConsoleInk.knobTickLit : ConsoleInk.knobTick)
                    .frame(width: dot, height: dot)
                    .offset(y: -ring)
                    .rotationEffect(angle(f))
            }
            // the default's dot, a size up, in the cap's colour (with a hairline so the white
            // and the bright caps' dots hold an edge on either panel)
            Circle()
                .fill(ConsoleInk.knobMarks[cap])
                .overlay(Circle().strokeBorder(ConsoleInk.panel.opacity(0.9), lineWidth: 0.75))
                .frame(width: dot * 2.1, height: dot * 2.1)
                .offset(y: -ring)
                .rotationEffect(angle(def))
                .accessibilityHidden(true)

            // the cap's skirt: its side, a shade under the cap, and the soft drop shadow
            Circle()
                .fill(color)
                .overlay(Circle().fill(Color.black.opacity(isWhite ? 0.22 : 0.32)))
                .frame(width: capD, height: capD)
                .offset(y: dragging ? skirt * 0.5 : skirt)
                .shadow(color: .black.opacity(dragging ? 0.16 : 0.22), radius: dragging ? 2 : 4, y: dragging ? 1 : 3)
            // the cap's face: its colour lit from above like the keys' (a top light that fades
            // to clear in the cap's own colour, so the white cap isn't veiled grey), a lit top
            // edge, a shallow dished centre and a rim — orange while the hand is on it, as a
            // key's edge on hover
            Circle()
                .fill(color)
                .overlay(Circle().fill(LinearGradient(stops: [
                    .init(color: .white.opacity(isWhite ? 0.6 : 0.28), location: 0),
                    .init(color: .white.opacity(0), location: 0.55),
                    .init(color: .black.opacity(isWhite ? 0.04 : 0.08), location: 1),
                ], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(isWhite ? 0.95 : 0.55), .clear],
                                                              startPoint: .top, endPoint: .center), lineWidth: 1))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth: 1).padding(capD * 0.17))
                .overlay(Circle().strokeBorder(lit && isEnabled ? ConsoleInk.signal
                                                                : (isWhite ? ConsoleInk.whiteKnobRim : Color.black.opacity(0.2)),
                                               lineWidth: lit && isEnabled ? 1.25 : (isWhite ? 1 : 0.75)))
                .frame(width: capD, height: capD)
                .offset(y: dragging ? skirt * 0.5 : 0)
            // the pointer: a line from near the centre to near the rim
            Capsule()
                .fill(ConsoleInk.knobPointers[cap])
                .frame(width: max(size * 0.045, 2), height: capD * 0.34)
                .offset(y: -capD * 0.27)
                .rotationEffect(angle(fraction))
                .offset(y: dragging ? skirt * 0.5 : 0)
            if focused {
                Circle().strokeBorder(ConsoleInk.signal, lineWidth: 1.5)
                    .frame(width: capD + 6, height: capD + 6)
            }
        }
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: dragging)
        .animation(Motion.pick(Motion.brief, reduceMotion: reduceMotion), value: lit)
    }

    // MARK: Turning

    /// How a change arrives — it decides what the default's detent does with it.
    private enum Turn {
        /// Accumulating motion (a drag, a trackpad swipe): the detent is a sticky band around
        /// the default that the running value settles into and has to push through to leave.
        case sweep
        /// One discrete step (arrow key, VoiceOver, a mouse-wheel notch): never held at the
        /// default, but a step that would jump over it stops on it, once.
        case step
        /// An exact value (typed, a reset): written as given, on the step grid.
        case exact
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragging) { _, held, _ in held = true }
            .onChanged { g in
                if dragRaw == nil { dragRaw = value; dragLastY = 0 }
                // Each event's own movement at the sensitivity of the moment: pressing or
                // letting go of ⌥ mid-drag changes the speed from here on, never the value.
                let dy = g.translation.height - dragLastY
                dragLastY = g.translation.height
                let fine = NSEvent.modifierFlags.contains(.option)
                // clamped like a real end stop: turning back moves it at once, coarse or fine
                let raw = min(max((dragRaw ?? value) - Double(dy) * span / (fine ? 1800 : 180),
                                  range.lowerBound), range.upperBound)
                dragRaw = raw
                set(raw, .sweep)
            }
            .onEnded { _ in endDrag() }
    }

    /// The hand let go (or the drag was cancelled, or the knob went away mid-drag).
    private func endDrag() {
        guard dragRaw != nil else { return }
        dragRaw = nil
        dragLastY = 0
        ConsoleTouch.shared.release()
    }

    private func nudge(_ dir: Double, fine: Bool) {
        guard isEnabled else { return }
        let s = step > 0 ? step : span / 100
        set(value + dir * (fine && step == 0 ? s / 10 : s), .step)
        ConsoleTouch.shared.release()
    }

    private func reset() {
        guard isEnabled else { return }
        // the pointer swings back (a cut under Reduce Motion)
        withAnimation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion)) { set(defaultValue, .exact) }
        ConsoleTouch.shared.release()   // show it, then let go
    }

    /// From the scroll view over the dial. Every handled event touches and then releases,
    /// so the preview's tag stays up while the scroll goes on and clears 0.9 s after the last
    /// event, however the scroll ends.
    private func scrolled(_ e: KnobScroll.Event) {
        switch e {
        case .begin:
            swipeRaw = value
            return
        case let .swipe(d, fine):
            let raw = min(max((swipeRaw ?? value) + d * span / (fine ? 2400 : 240), range.lowerBound), range.upperBound)
            swipeRaw = raw
            set(raw, .sweep)
        case let .notch(d, fine):
            set(value + d * span / (fine ? 2400 : 240), .step)
        }
        ConsoleTouch.shared.release()
    }

    /// Clamp, snap to the step, apply the default's detent for this kind of turn, tick on
    /// landing, publish the touch.
    private func set(_ v: Double, _ turn: Turn) {
        var n = min(max(v, range.lowerBound), range.upperBound)
        if step > 0 { n = min(max((n / step).rounded() * step, range.lowerBound), range.upperBound) }
        // a hair off the default is on it (1% steps add up to 0.5000000000000001, not 0.5)
        let noise = span * 1e-9
        if abs(n - defaultValue) <= noise { n = defaultValue }
        let from = value
        let fromDefault = abs(from - defaultValue) <= noise
        let across = !fromDefault && (from - defaultValue) * (n - defaultValue) < 0   // one side to the other
        switch turn {
        case .sweep: if abs(n - defaultValue) < span * 0.015 { n = defaultValue }
        case .step: if across { n = defaultValue }
        case .exact: break
        }
        // the default's detent: a firm tick once as the value lands on it — slowly or not — or
        // as a fast turn passes straight over it; never again while it sits there. Otherwise a
        // light tick each time the value crosses into another twelfth of the range.
        if (!fromDefault && n == defaultValue) || (turn == .sweep && across && n != defaultValue) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } else if turn != .exact, detent(from) != detent(n) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if n != from { value = n }
        ConsoleTouch.shared.touch(.init(label: label, value: format(n), colorIndex: colorIndex))
    }

    /// Which twelfth of the range `v` is in (the top end counts with the last one).
    private func detent(_ v: Double) -> Int {
        min(Int(((v - range.lowerBound) / span * Self.detents).rounded(.down)), Int(Self.detents) - 1)
    }

    /// The typed value, read in the unit the readout shows: on a "40%" readout a bare 25 is
    /// 25 %, on a "13°" readout it is 25°, otherwise the setting's own number. An explicit % or
    /// ° says so itself. Exact — no detent. Return on the untouched readout changes nothing.
    /// False when the text isn't a number.
    private func commitTyped() -> Bool {
        let shown = format(value)
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != shown else { return true }
        let percent = text.hasSuffix("%") || (!text.hasSuffix("°") && shown.hasSuffix("%"))
        let degrees = !percent && (text.hasSuffix("°") || shown.hasSuffix("°"))
        let number = text.trimmingCharacters(in: CharacterSet(charactersIn: "%°").union(.whitespaces))
        guard var n = Double(number) ?? Self.localNumber.number(from: number)?.doubleValue else { return false }
        if percent { n /= 100 } else if degrees { n = n * .pi / 180 }
        set(n, .exact)
        ConsoleTouch.shared.release()
        return true
    }

    /// "0,5" where the decimal separator is a comma.
    private static let localNumber: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

// MARK: - Knob scrolling

/// Scrolling over a knob turns it. An AppKit view laid over the dial that answers hit-testing
/// only while a scroll event is being delivered, so clicks, drags, hover and tooltips all reach
/// the SwiftUI knob underneath.
///
/// A scroll is the knob's only when it starts there on purpose: the pointer has moved over the
/// dial (or the hand is on it), and a trackpad swipe began over it. Everything else goes on up
/// the responder chain to the inspector's list, which scrolls as usual: a swipe that began
/// elsewhere and its momentum, a knob that the list's own scroll slid under a still pointer,
/// and any knob of a disabled (hidden) effect.
private struct KnobScroll: NSViewRepresentable {
    enum Event {
        /// A trackpad swipe began over the knob.
        case begin
        /// Part of that swipe or its momentum, in points (up = more).
        case swipe(Double, fine: Bool)
        /// A mouse wheel's notch (or a device without gestures): one discrete step, in points.
        case notch(Double, fine: Bool)
    }

    var enabled: Bool
    /// The hand is on the knob (a drag), so the pointer is where the user put it.
    var engaged: Bool
    var turn: (Event) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ v: Catcher, context: Context) {
        v.turn = turn
        v.enabled = enabled
        if engaged { v.arm() }
    }

    static func dismantleNSView(_ v: Catcher, coordinator: ()) { v.turn = nil }

    final class Catcher: NSView {
        var turn: ((Event) -> Void)?
        var enabled = true { didSet { if !enabled { forget() } } }
        /// The pointer was moved onto the dial (not the dial scrolled under a resting pointer).
        private var armed = false
        /// Where the pointer was when the dial came under it.
        private var entry: NSPoint?
        /// A trackpad swipe that began over this knob is in progress…
        private var swiping = false
        /// …and its momentum is still coming.
        private var coasting = false
        private var tracking: NSTrackingArea?

        func arm() { armed = true }

        private func forget() { armed = false; entry = nil; swiping = false; coasting = false }

        /// Tracks the dial's own square. Not `.inVisibleRect`: views don't clip to their bounds
        /// since macOS 14, so this view's visibleRect is its whole list row. Replaced only when
        /// the dial's size changes (a new area would re-enter and disarm).
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            let r = bounds
            guard tracking?.rect != r else { return }
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: r, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        // The tracking area is this view's own: it tells "the pointer moved onto the dial" from
        // "the dial scrolled under the pointer" (the pointer's place in the window didn't change).
        override func mouseEntered(with event: NSEvent) { entry = event.locationInWindow; armed = false }

        override func mouseMoved(with event: NSEvent) {
            let p = event.locationInWindow
            if let entry { if p != entry { armed = true } } else { entry = p }
        }

        override func mouseExited(with event: NSEvent) { forget() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { forget() } else { updateTrackingAreas() }
        }

        override func scrollWheel(with e: NSEvent) {
            guard enabled, let turn else { return pass(e) }
            // a scroll somewhere else on the dial than where it came under the pointer: the
            // pointer has moved since
            if !armed, let entry, e.locationInWindow != entry { armed = true }
            let fine = e.modifierFlags.contains(.option)
            let dy = Double(e.scrollingDeltaY)

            // A mouse wheel's notch: no phases, one step at a time.
            if e.phase.isEmpty && e.momentumPhase.isEmpty {
                guard armed, dy != 0 else { return pass(e) }
                turn(.notch(e.hasPreciseScrollingDeltas ? dy : dy * 8, fine: fine))
                return
            }

            // Momentum: only a swipe of ours carries on.
            if !e.momentumPhase.isEmpty {
                if e.momentumPhase.contains(.began) { coasting = swiping }
                guard coasting else { return pass(e) }
                if dy != 0 { turn(.swipe(dy, fine: fine)) }
                if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) {
                    coasting = false; swiping = false
                }
                return
            }

            // A swipe: ours only if it begins here, after the pointer was moved onto the dial.
            if e.phase.contains(.mayBegin) || e.phase.contains(.began) {
                coasting = false
                swiping = armed
                if swiping { turn(.begin) }
            }
            guard swiping else { return pass(e) }
            if dy != 0 { turn(.swipe(dy, fine: fine)) }
            if e.phase.contains(.cancelled) { swiping = false }
            // (.ended keeps `swiping`, so the momentum that may follow is still the knob's)
        }

        /// Not the knob's: on to the list it sits in.
        private func pass(_ e: NSEvent) { nextResponder?.scrollWheel(with: e) }
    }
}
