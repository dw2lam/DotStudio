//  Console.swift — the "Console" appearance (issue #6, experimental): DotStudio as a small,
//  precise instrument. Inspired by hardware mixers and synths, never copied: our own colours,
//  shapes and type (the system's SF Mono for legends — no third-party fonts).
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
    var title: String { self == .classic ? "Classic" : "Console (experimental)" }
    static let key = "appearance"
    /// DEV / offscreen renders: DOTSTUDIO_APPEARANCE=console|classic wins over the saved choice
    /// (UIShots never writes the user's own preference).
    static let forced: Appearance? = ProcessInfo.processInfo.environment["DOTSTUDIO_APPEARANCE"].flatMap(Appearance.init)
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

    /// The body: warm light grey / graphite.
    static let chassis = dynamic(rgb(0xE4E2DD), rgb(0x1C1D1F))
    /// A raised panel on it (pads, the channel strip).
    static let panel = dynamic(rgb(0xEEECE8), rgb(0x25272A))
    /// A recessed well (a screen, a key's face when pressed).
    static let well = dynamic(rgb(0xD6D3CD), rgb(0x141516))
    /// Hairline edges.
    static let hairline = dynamic(rgb(0x000000, 0.12), rgb(0xFFFFFF, 0.10))
    /// Main text.
    static let ink = dynamic(rgb(0x1A1A1A), rgb(0xEDEBE6))
    /// Legends: tiny printed labels. Dark enough for WCAG AA at caption size on the panel.
    static let legend = dynamic(rgb(0x5E5B55), rgb(0xA9A69F))
    /// The one signal colour: live / active / selected.
    static let signal = dynamic(rgb(0xF2551D), rgb(0xFF6A2B))
    /// The signal colour as TEXT or a thin edge on the light panel/chassis: dark enough for
    /// WCAG AA (≥ 4.5:1 text, ≥ 3:1 edges) — the bright signal is for fills and lights.
    static let signalInk = dynamic(rgb(0xA33609), rgb(0xFF7A3D))

    /// The four knob colours, in order (the editor's first four parameters).
    static let knobs: [Color] = [
        dynamic(rgb(0x2E6BF0), rgb(0x4C84FF)),     // blue
        dynamic(rgb(0x1FA35B), rgb(0x2FC774)),     // green
        dynamic(rgb(0xF7F6F2), rgb(0xE9E7E1)),     // white
        dynamic(rgb(0xF2551D), rgb(0xFF6A2B)),     // orange
    ]
    static let knobNames = ["blue", "green", "white", "orange"]

    /// The white knob's rim. On the light panel a near-white cap has no edge of its own, so it
    /// gets a printed grey one (≥ 3:1 against the panel and the strip's well); on the graphite
    /// chassis it already stands out and keeps the other caps' faint dark rim.
    static let whiteKnobRim = dynamic(rgb(0x78756E), rgb(0x000000, 0.18))
    /// The white knob's value arc: legend grey at the weight of the coloured arcs (about 3.4:1
    /// on the light strip, 4.9:1 on the dark one — the blue arc's contrast), not a heavier ink.
    static let whiteKnobArc = legend.opacity(0.8)
}

// MARK: - Type

extension TextRole {
    /// Tiny printed legends: mono caps, tracked.
    static let legend = TextRole(style: .caption2, weight: .semibold, design: .monospaced, tracking: 0.6, uppercase: true)
    /// A pad's number ("07").
    static let padNumber = TextRole(style: .caption, weight: .bold, design: .monospaced, monospacedDigits: true)
    /// Numeric readouts over knobs and on screens.
    static let readout = TextRole(style: .callout, weight: .medium, design: .monospaced, monospacedDigits: true)
    /// A pad's name: small mono caps.
    static let padName = TextRole(style: .caption, weight: .semibold, design: .monospaced, tracking: 0.4, uppercase: true)
}

// MARK: - Surfaces

extension View {
    /// A flat Console panel: panel colour, a hairline edge, no glass and no big shadow.
    func consolePanel(cornerRadius: CGFloat = Radius.m) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(ConsoleInk.panel))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(ConsoleInk.hairline, lineWidth: 1))
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

/// A rotary knob that is a slider: 270° of travel, a coloured cap with a pointer, the value's
/// arc lit in the knob's colour, a readout above (click to type an exact value) and the
/// legend below.
///
/// Turn it by dragging up/down (the full range in 180 pt; ⌥ for a tenth of that, which can be
/// pressed or let go mid-drag), by scrolling over it, or with the arrow keys once focused
/// (⌥ fine). Double-click, ⌫ or VoiceOver's "Reset to default" action resets it.
///
/// The default has a detent. A drag or a trackpad swipe settles into it and has to push
/// through to leave; a discrete step (arrow key, VoiceOver, a mouse-wheel notch) is never held
/// there, but one that would jump over the default stops on it once. Typed values and resets
/// are exact. The trackpad ticks once as the value lands on the default (or a fast turn passes
/// it), never while it sits there.
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
    @ScaledLength(relativeTo: .body) private var size: CGFloat = 46
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

    private var color: Color { ConsoleInk.knobs[colorIndex % ConsoleInk.knobs.count] }
    private var isWhite: Bool { colorIndex % ConsoleInk.knobs.count == 2 }
    private var span: Double { max(range.upperBound - range.lowerBound, 1e-9) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }
    private static let sweep = 270.0

    var body: some View {
        VStack(spacing: 6) {
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
            // word sets the knob's minimum width, so a word is never split: the channel strip
            // (KnobStripLayout) goes 2×2 rather than break BRIGHTNESS or MISREGISTRATION.
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
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(minWidth: size + 8)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.well))
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

    private var dial: some View {
        let start = Angle.degrees(135), end = Angle.degrees(135 + Self.sweep * fraction)
        let def = min(max((defaultValue - range.lowerBound) / span, 0), 1)
        return ZStack {
            // the track and the value's arc
            Circle().trim(from: 0, to: Self.sweep / 360)
                .rotation(.degrees(135))
                .stroke(ConsoleInk.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ArcShape(start: start, end: end)
                .stroke(isWhite ? ConsoleInk.whiteKnobArc : color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // the default's tick, printed on the chassis
            Capsule().fill(ConsoleInk.legend)
                .frame(width: 1.5, height: 4)
                .offset(y: -size / 2 - 1)
                .rotationEffect(.degrees(-135 + Self.sweep * def))
            // the cap: slight shading, a light top and a darker foot. Each half fades to clear
            // in its own colour — a white→black gradient would lay a grey veil over the middle
            // that sinks the white cap into the light panel.
            Circle()
                .fill(color)
                .shadow(color: .black.opacity(dragging ? 0.30 : 0.18), radius: dragging ? 3 : 1.5, y: 1)
                .overlay(Circle().fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .black.opacity(0), location: 0.5),
                    .init(color: .black.opacity(isWhite ? 0.05 : 0.10), location: 1),
                ], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(isWhite ? ConsoleInk.whiteKnobRim : Color.black.opacity(0.18),
                                               lineWidth: isWhite ? 1 : 0.75))
                .padding(7)
            // the pointer
            Capsule()
                .fill(isWhite ? Color.black.opacity(0.7) : Color.white.opacity(0.95))
                .frame(width: 2.5, height: size * 0.2)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(-135 + Self.sweep * fraction))
            if focused {
                Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2).padding(-3)
            }
        }
        .scaleEffect(hovering || dragging ? 1.04 : 1)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: dragging)
    }

    private struct ArcShape: Shape {
        var start: Angle, end: Angle
        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(start.degrees, end.degrees) }
            set { start = .degrees(newValue.first); end = .degrees(newValue.second) }
        }
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
                     startAngle: start, endAngle: end, clockwise: false)
            return p
        }
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
        set(defaultValue, .exact)
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
        // the detent's tick: once as the value lands on the default — slowly or not — or as a
        // fast turn passes straight over it; never again while it sits there
        if (!fromDefault && n == defaultValue) || (turn == .sweep && across && n != defaultValue) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if n != from { value = n }
        ConsoleTouch.shared.touch(.init(label: label, value: format(n), colorIndex: colorIndex))
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
