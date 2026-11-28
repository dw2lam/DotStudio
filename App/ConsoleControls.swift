//  ConsoleControls.swift — the Console (Stitch) editor's controls: the parts of the owner's
//  Google Stitch editor that App/Console.swift doesn't already have.
//
//    • ConsoleKeyFace      — a keycap's face for things that aren't Buttons (a menu's label, a
//                            split key, a slider's or a switch's thumb).
//    • ConsoleInspectorRow — a parameter row: mono-caps legend on the left, its control in a
//                            fixed column on the right, a hairline under it. Stacks (legend
//                            above the control) at the sizes where every inspector row does.
//    • ScaledInsets         — @ScaledLength for a key's padding (grows with its legend).
//    • InspectorFader       — a fader: a recessed 8 pt track, a square keycap thumb, the value in
//                            mono beside it. A detent (a haptic tick) at the default. (A style's
//                            numeric settings are dials — ConsoleKnob in ConsoleDialGrid — so
//                            this is only the fallback for a range with no travel.)
//    • ConsoleDialGrid     — a bank of dials in balanced equal columns, up to four a row.
//    • InspectorSwitch       — an inset switch: a recessed well with a small key that slides over;
//                            orange while on.
//    • ConsoleMenuKeyLabel — a pop-up key's face (value + ⌃⌄), for a dropdown's label.
//    • ConsolePopupKey     — a pop-up key that opens its options as the Retro dropdown
//                            (ConsoleMenu.swift).
//    • ConsoleColorWell    — a colour swatch with its name; opens the system colour panel. Not
//                            an NSColorWell: no AppKit control inside the inspector's list.
//    • InspectorSegments     — a segmented choice as a row of keys (the chosen one latched, lit).
//    • ConsoleEqualGrid    — equal columns, as many as fit (theme swatches, segment keys).

import SwiftUI
import AppKit

extension TextRole {
    /// Small mono names that aren't legends (a theme's name under its swatch, a colour's name
    /// beside its well): 10 pt mono, tracked, NOT uppercased — the design's label-sm.
    static let consoleCaption = TextRole(style: .caption2, points: 11, tracking: 0, face: ConsoleFace.label, lowercase: true)
    /// A big key's legend (Add Effect, the destination keys): 12.5 pt mono caps (the design's label-lg, a half step up).
    static let consoleKeyLarge = TextRole(style: .callout, points: 13.5, tracking: 0.1, face: ConsoleFace.label, lowercase: true)
}

// MARK: - Scaled insets

/// `@ScaledLength` for a key's padding: four design lengths that follow the text size in
/// step with text of `relativeTo`, so a key's legend keeps its margins as it grows.
///     @ScaledInsets(relativeTo: .callout) private var padding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
@propertyWrapper
struct ScaledInsets: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let base: EdgeInsets
    private let style: Font.TextStyle

    init(wrappedValue: EdgeInsets, relativeTo style: Font.TextStyle = .body) {
        base = wrappedValue
        self.style = style
    }

    var wrappedValue: EdgeInsets {
        func s(_ v: CGFloat) -> CGFloat { TypeScale.length(v, relativeTo: style, typeSize) }
        return EdgeInsets(top: s(base.top), leading: s(base.leading), bottom: s(base.bottom), trailing: s(base.trailing))
    }
}

// MARK: - Key face

extension View {
    /// A keycap's face behind this content: the face colour, a faint top light, a 0.5 pt edge
    /// (orange while hovered), and the slim skirt under it — sunk into the skirt while
    /// `pressed`. Lit and shaded exactly as ConsoleKeycapStyle (ConsoleKeyLight).
    /// `latched`: held down as a state (a status key) — the face rests part way into the skirt.
    /// Only the face moves: the skirt's base (the key's footprint) and the layout size never
    /// change, so a sunk key's bottom edge lines up with its neighbours'.
    /// `reserve` keeps the skirt's room under the content (rows of keys don't overlap).
    func consoleKeyFace(_ tint: ConsoleKeycapStyle.Tint = .plain, pressed: Bool = false, latched: Bool = false,
                        hovering: Bool = false, cornerRadius: CGFloat = 4, skirt: CGFloat = ConsoleKeycapStyle.skirt,
                        reserve: Bool = true) -> some View {
        modifier(ConsoleKeyFaceModifier(tint: tint, pressed: pressed, latched: latched, hovering: hovering,
                                        cornerRadius: cornerRadius, skirt: skirt, reserve: reserve))
    }
}

struct ConsoleKeyFaceModifier: ViewModifier {
    var tint: ConsoleKeycapStyle.Tint = .plain
    var pressed = false
    var latched = false
    var hovering = false
    var cornerRadius: CGFloat = 4
    var skirt: CGFloat = ConsoleKeycapStyle.skirt
    var reserve = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        let hot = hovering && enabled
        // pressed: the full travel; latched: part way (as ConsoleKeycapStyle)
        let sink: CGFloat = pressed ? min(ConsoleKeycapStyle.travel, skirt * 0.75)
            : latched ? min(ConsoleKeycapStyle.latchedTravel, skirt * 0.5) : 0
        let down = sink > 0
        let shade = ConsoleKeyLight.shade(tint, dark: dark, down: down, hovering: hot)
        content
            .background {
                shape.fill(tint.face)
                    .overlay(shape.fill(ConsoleKeyLight.wash(tint, dark: dark)))
                    .overlay(shape.fill(Color.clear.shadow(.inner(color: ConsoleKeyLight.pressShade(dark: dark, down: down), radius: 1, y: 1))))
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
            // the skirt never moves: its base is the key's footprint in every state
            .background {
                shape.fill(tint.skirt)
                    .offset(y: skirt)
                    .shadow(color: shade.color, radius: shade.radius, y: shade.y)
            }
            .padding(.bottom, reserve ? skirt : 0)
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Row

/// A Console parameter row: the legend on the left, the control in a fixed column on the right
/// (the design's 176 pt, never more than 62 % of the row), a hairline under it. At the sizes
/// where the inspector's rows stack (`layout.prefersStacking`) the legend goes above a
/// full-width control. Decided by the text size and one Layout — nothing is swapped in and out.
struct ConsoleInspectorRow<Control: View>: View {
    let label: String
    var divider = true
    /// Always the legend above a full-width control (a row of segment keys needs the width).
    var stacked = false
    @ViewBuilder var control: Control
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption) private var controlWidth: CGFloat = 176

    var body: some View {
        ConsoleRowLayout(control: controlWidth, gap: Space.xs, stacked: stacked || layout.prefersStacking, stackGap: layout.labelGap) {
            Text(label)
                .textRole(.legend)
                .foregroundStyle(ConsoleInk.legend)
                .truncating(label, lines: 2)
                .fixedSize(horizontal: false, vertical: true)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xxs + 1)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(ConsoleInk.hairline).frame(height: 1).accessibilityHidden(true) }
        }
    }
}

/// Two children: a legend and a control (see `ConsoleInspectorRow`). Side by side, each
/// centred on the row's middle; or stacked.
struct ConsoleRowLayout: Layout {
    var control: CGFloat
    var gap: CGFloat
    var stacked: Bool
    var stackGap: CGFloat

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        if let w = proposal.width, w.isFinite { return w }
        return subviews[0].sizeThatFits(.unspecified).width + gap + control
    }

    private func controlWidth(_ w: CGFloat) -> CGFloat { stacked ? w : min(control, w * 0.62) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let w = width(proposal, subviews)
        if stacked {
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: w, height: nil))
            return CGSize(width: w, height: a.height + stackGap + b.height)
        }
        let c = controlWidth(w)
        let a = subviews[0].sizeThatFits(ProposedViewSize(width: max(w - c - gap, 0), height: nil))
        let b = subviews[1].sizeThatFits(ProposedViewSize(width: c, height: nil))
        return CGSize(width: w, height: max(a.height, b.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let w = bounds.width
        if stacked {
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: w, height: a.height))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: w, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + a.height + stackGap),
                              proposal: ProposedViewSize(width: w, height: b.height))
            return
        }
        let c = controlWidth(w)
        let lw = max(w - c - gap, 0)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: lw, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX - c, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: c, height: nil))
    }
}

// MARK: - Slider

/// The design's fader: a recessed track, a square keycap thumb, the value in mono beside it.
/// Click or drag anywhere on the track; arrow keys once focused (⌥ fine); double-click (or
/// VoiceOver's "Reset" action) for the default. The default has a detent with a tick, like
/// ConsoleKnob's, and what's being changed shows on the preview's tag (ConsoleTouch).
struct InspectorFader: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let defaultValue: Double
    let format: (Double) -> String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .caption) private var track: CGFloat = 9
    @ScaledLength(relativeTo: .caption) private var thumbWidth: CGFloat = 16
    @ScaledLength(relativeTo: .caption) private var thumbHeight: CGFloat = 22
    @ScaledLength(relativeTo: .caption) private var readout: CGFloat = 40
    @GestureState private var dragging = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var span: Double { max(range.upperBound - range.lowerBound, 1e-9) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        HStack(spacing: Space.xxs) {
            GeometryReader { geo in
                let travel = max(geo.size.width - thumbWidth, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.clear)
                        .frame(height: track)
                        .consoleWell(cornerRadius: 2)
                    thumb
                        .offset(x: travel * fraction)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, held, _ in held = true }
                    .onChanged { g in
                        guard isEnabled else { return }
                        let f = (g.location.x - thumbWidth / 2) / travel
                        set(range.lowerBound + Double(min(max(f, 0), 1)) * span, sweep: true)
                    }
                    .onEnded { _ in ConsoleTouch.shared.release() })
                .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            }
            .frame(height: thumbHeight + 4)
            .onHover { hovering = $0 }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                let up = press.key == .upArrow || press.key == .rightArrow
                nudge(up ? 1 : -1, fine: press.modifiers.contains(.option))
                return .handled
            }
            .onDeleteCommand { reset() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(format(value))
            .accessibilityAdjustableAction { nudge($0 == .increment ? 1 : -1, fine: false) }
            .accessibilityAction(named: "Reset to \(format(defaultValue))") { reset() }
            .help("\(label) — drag, or use the arrow keys (⌥ for fine). Double-click to reset to \(format(defaultValue)).")

            Text(format(value))
                .textRole(.consoleValue)
                .foregroundStyle(ConsoleInk.ink)
                .lineLimit(1)
                .frame(width: readout, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var thumb: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return Color.clear
            .frame(width: thumbWidth, height: thumbHeight - 2)
            .overlay(alignment: .center) {
                // the thumb's grip line
                Rectangle().fill(ConsoleInk.legend.opacity(0.6)).frame(width: 1, height: (thumbHeight - 2) * 0.45)
            }
            .consoleKeyFace(pressed: dragging, hovering: hovering || dragging, cornerRadius: 2, reserve: false)
            .overlay(shape.strokeBorder(focused ? ConsoleInk.signal : .clear, lineWidth: 1.5).offset(y: dragging ? ConsoleKeycapStyle.travel : 0))
            .offset(y: -1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: dragging)
    }

    private func nudge(_ dir: Double, fine: Bool) {
        guard isEnabled else { return }
        let s = step > 0 ? step : span / 100
        set(value + dir * (fine && step == 0 ? s / 10 : s), sweep: false)
        ConsoleTouch.shared.release()
    }

    private func reset() {
        guard isEnabled else { return }
        if value != defaultValue {
            value = defaultValue
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        ConsoleTouch.shared.touch(.init(label: label, value: format(defaultValue), colorIndex: 3))
        ConsoleTouch.shared.release()
    }

    /// Clamp, snap to the step, settle into the default's detent (a drag only; a key step
    /// that would jump over the default stops on it), tick on landing, show the touch.
    private func set(_ v: Double, sweep: Bool) {
        var n = min(max(v, range.lowerBound), range.upperBound)
        if step > 0 { n = min(max((n / step).rounded() * step, range.lowerBound), range.upperBound) }
        let noise = span * 1e-9
        if abs(n - defaultValue) <= noise { n = defaultValue }
        let from = value
        let fromDefault = abs(from - defaultValue) <= noise
        let across = !fromDefault && (from - defaultValue) * (n - defaultValue) < 0
        if sweep { if abs(n - defaultValue) < span * 0.015 { n = defaultValue } }
        else if across { n = defaultValue }
        if !fromDefault && n == defaultValue {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if n != from { value = n }
        ConsoleTouch.shared.touch(.init(label: label, value: format(n), colorIndex: 3))
    }
}

// MARK: - Dial grid

/// A bank of dials (ConsoleKnob) in equal columns: as many as fit up to `maxColumns`, with
/// the rows balanced (five dials go 3 + 2, not 4 + 1). A column is never narrower than a dial
/// can't do without at the chosen text size — its dial, readout and longest legend word (a
/// zero-width proposal: the parts that don't wrap) — so big text means fewer columns, never
/// smaller dials or split words. Each dial is centred at the top of its cell.
///
/// Measured inside one layout, so the dials — each with its own state, focus and scroll
/// catcher — keep their identity when the column count changes; a ViewThatFits would build
/// them again in the middle of the inspector list's layout (the pattern ColorWellsRow
/// documents as a crash).
struct ConsoleDialGrid: Layout {
    var maxColumns = 4
    var spacing: CGFloat
    var rowSpacing: CGFloat

    /// The narrowest a dial's column can be.
    private func need(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0
    }

    private func columns(_ width: CGFloat?, _ subviews: Subviews) -> Int {
        let n = subviews.count
        guard n > 0 else { return 1 }
        let most = min(maxColumns, n)
        guard let width, width.isFinite else { return most }
        let w = need(subviews)
        let fit = (1...most).reversed().first { CGFloat($0) * w + CGFloat($0 - 1) * spacing <= width + 0.5 } ?? 1
        let rows = (n + fit - 1) / fit
        return (n + rows - 1) / rows
    }

    private func cellWidth(_ width: CGFloat, cols: Int) -> CGFloat {
        max((width - CGFloat(cols - 1) * spacing) / CGFloat(cols), 0)
    }

    private func rowHeights(_ subviews: Subviews, cols: Int, cell: CGFloat?) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: cols).map { s in
            (s..<min(s + cols, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cols = columns(proposal.width, subviews)
        let width: CGFloat
        if let w = proposal.width, w.isFinite { width = w }
        else {
            let cell = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = CGFloat(cols) * cell + CGFloat(cols - 1) * spacing
        }
        let hs = rowHeights(subviews, cols: cols, cell: cellWidth(width, cols: cols))
        return CGSize(width: width, height: hs.reduce(0, +) + CGFloat(max(hs.count - 1, 0)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = columns(bounds.width, subviews)
        let cell = cellWidth(bounds.width, cols: cols)
        var y = bounds.minY
        for (r, h) in rowHeights(subviews, cols: cols, cell: cell).enumerated() {
            for c in 0..<cols {
                let i = r * cols + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (cell + spacing) + cell / 2, y: y),
                                  anchor: .top, proposal: ProposedViewSize(width: cell, height: nil))
            }
            y += h + rowSpacing
        }
    }
}

// MARK: - Switch

/// A switch's lit well: ON is green (orange before 2026-11-26 — orange is the primary action),
/// the fill a step deeper on the light body, a fine edge in its skirt colour and a soft green
/// glow around it. Shared by InspectorSwitch and ConsoleSwitch.
struct ConsoleSwitchLight<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        shape.fill(ConsoleInk.greenKey)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(ConsoleInk.greenSkirt.opacity(dark ? 0.8 : 0.55), lineWidth: 0.75))
            .shadow(color: ConsoleInk.greenKey.opacity(dark ? 0.3 : 0.22), radius: 8, y: 1)
    }
}

/// The design's inset switch: a recessed well with a small key in it; on, the well lights
/// green and the key slides right.
struct InspectorSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .caption) private var width: CGFloat = 46
    @ScaledLength(relativeTo: .caption) private var height: CGFloat = 24
    @ScaledLength(relativeTo: .caption) private var knob: CGFloat = 18

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isOn.toggle() }
        } label: {
            let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
            ZStack(alignment: isOn ? .trailing : .leading) {
                if isOn {
                    ConsoleSwitchLight(shape: shape)
                } else {
                    Color.clear.consoleWell(cornerRadius: 2)
                }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOn ? ConsoleInk.onGreen : ConsoleInk.legend)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(isOn ? 0.18 : 0.3), .clear], startPoint: .top, endPoint: .center), lineWidth: 0.75))
                    .shadow(color: .black.opacity(isOn ? 0.15 : 0.22), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .padding((height - knob) / 2)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .help("\(label): \(isOn ? "on" : "off")")
    }
}

// MARK: - Pop-up key

/// A pop-up key's face — the value in mono and the up-down chevrons — to be a dropdown's label
/// (ConsoleMenuButton: lit, as under the pointer, while its menu is open).
struct ConsoleMenuKeyLabel: View {
    let text: String
    var dim = false
    @State private var pointer = false
    @Environment(\.panelKeyHot) private var open
    @ScaledLength(relativeTo: .caption) private var minHeight: CGFloat = 30

    private var hovering: Bool { pointer || open }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(text)
                .textRole(.consoleValue)
                .foregroundStyle(dim ? ConsoleInk.legend : (hovering ? ConsoleInk.signalInk : ConsoleInk.ink))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .textRole(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(ConsoleInk.legend)
        }
        .padding(.horizontal, Space.xs)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .consoleKeyFace(hovering: hovering)
        .contentShape(Rectangle())
        .onHover { pointer = $0 }
    }
}

/// A pop-up key over the options as the Retro dropdown (the chosen one checked), as wide as
/// the key.
struct ConsolePopupKey<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        let current = options.first { $0.value == selection }?.title ?? ""
        ConsoleMenuButton(title: title) {
            MenuEntry.choices(options, selection: $selection)
        } label: {
            ConsoleMenuKeyLabel(text: current)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help("\(title): \(current)")
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

// MARK: - Colour well

/// The one system colour panel, aimed at whichever Console swatch opened it last.
final class ConsoleColorPanel: NSObject, ObservableObject {
    static let shared = ConsoleColorPanel()
    @Published private(set) var owner: UUID?
    private var apply: ((NSColor) -> Void)?
    private var closing: NSObjectProtocol?

    func open(_ id: UUID, color: NSColor, apply: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        self.apply = nil
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = color
        self.apply = apply
        owner = id
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        if closing == nil {
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                             queue: .main) { [weak self] _ in self?.forget() }
        }
        panel.orderFront(nil)
    }

    /// A swatch went away: the panel stops editing its colour.
    func release(_ id: UUID) {
        guard owner == id else { return }
        forget()
    }

    private func forget() {
        apply = nil
        owner = nil
        if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
    }

    @objc private func changed(_ sender: NSColorPanel) { apply?(sender.color) }
}

/// The design's colour well: a small swatch and its name. Click to edit it in the colour
/// panel; the swatch wears an orange edge while the panel is editing it.
///
/// The panel writes through the swatch's binding as of its latest render, never the one it
/// was opened with. A layer's binding comes from `ForEach($preset.effects)`, which addresses
/// the layer by its index at that moment: after the layers are reordered, a captured binding
/// would recolour whichever layer moved into that slot. The swatch's own identity (and so
/// this target) follows the layer's ID, so the panel keeps editing the layer it was opened on.
struct ConsoleColorWell: View {
    let title: String
    @Binding var color: Color
    @ObservedObject private var panel = ConsoleColorPanel.shared
    @State private var id = UUID()
    @State private var target = Target()
    @State private var hovering = false
    @ScaledLength(relativeTo: .caption2) private var swatchWidth: CGFloat = 24
    @ScaledLength(relativeTo: .caption2) private var swatchHeight: CGFloat = 16

    /// Where the panel's colour goes: refreshed with this swatch's binding on every render.
    /// (A plain reference, not observed: updating it never asks for another render.)
    private final class Target {
        var binding: Binding<Color>?
        func update(_ b: Binding<Color>) { binding = b }
    }

    var body: some View {
        let _ = target.update($color)
        let active = panel.owner == id
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        Button {
            let target = target
            panel.open(id, color: NSColor(color)) { target.binding?.wrappedValue = Color(nsColor: $0) }
        } label: {
            HStack(spacing: Space.xxs) {
                shape.fill(color)
                    .frame(width: swatchWidth, height: swatchHeight)
                    .overlay(shape.strokeBorder(active || hovering ? ConsoleInk.signal : ConsoleInk.hairline,
                                                lineWidth: active ? 1.5 : 1))
                Text(title)
                    .textRole(.consoleCaption)
                    .foregroundStyle(active ? ConsoleInk.ink : ConsoleInk.legend)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDisappear { panel.release(id) }
        .help("\(title) — click to change")
        .accessibilityLabel("\(title) colour")
        .accessibilityHint("Opens the colour panel")
    }
}

// MARK: - Segments

/// A segmented choice as keys: one per option, the chosen one latched and lit. As many keys
/// a row as fit at their full legend (all, then two, then one).
struct InspectorSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The keys' margins grow with their legends (consoleKey is a caption-relative role).
    @ScaledInsets(relativeTo: .caption) private var padding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    var body: some View {
        ConsoleEqualGrid(spacing: Space.xxs, rowSpacing: Space.xxs, allowed: [options.count, 2, 1]) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { selection = options[i].value }
                } label: {
                    Text(options[i].title)
                        .textRole(.consoleKey)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.keycap(on ? .blue : .plain, latched: on, padding: padding))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Equal columns as wide as the widest child, as many as fit (only counts in `allowed`, if
/// given); the cells stretch to fill the row. Measured inside one layout, so the children
/// keep their identity when the count changes.
struct ConsoleEqualGrid: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var allowed: [Int]? = nil

    private func columns(_ width: CGFloat?, _ subviews: Subviews) -> Int {
        let n = subviews.count
        guard n > 0 else { return 1 }
        guard let width, width.isFinite else { return n }
        let cell = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let tries = (allowed ?? Array((1...n).reversed())).map { min(max($0, 1), n) }
        return tries.first { CGFloat($0) * cell + CGFloat($0 - 1) * spacing <= width + 0.5 } ?? 1
    }

    private func rowHeights(_ subviews: Subviews, cols: Int, cell: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: cols).map { s in
            (s..<min(s + cols, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            }.max() ?? 0
        }
    }

    private func cellWidth(_ width: CGFloat, cols: Int) -> CGFloat {
        (width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cols = columns(proposal.width, subviews)
        let width: CGFloat
        if let w = proposal.width, w.isFinite { width = w }
        else {
            let cell = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = CGFloat(cols) * cell + CGFloat(cols - 1) * spacing
        }
        let hs = rowHeights(subviews, cols: cols, cell: cellWidth(width, cols: cols))
        return CGSize(width: width, height: hs.reduce(0, +) + CGFloat(max(hs.count - 1, 0)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = columns(bounds.width, subviews)
        let cell = cellWidth(bounds.width, cols: cols)
        let hs = rowHeights(subviews, cols: cols, cell: cell)
        var y = bounds.minY
        for (r, h) in hs.enumerated() {
            for c in 0..<cols {
                let i = r * cols + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (cell + spacing), y: y),
                                  proposal: ProposedViewSize(width: cell, height: h))
            }
            y += h + rowSpacing
        }
    }
}

// MARK: - Small buttons and fields

/// A small inspector button ("Choose Image…", "Remove"): a small stock button with a
/// role-sized title (Classic), or a small grey key with a mono-caps legend (Console).
struct InspectorSmallButton: View {
    let title: String
    var fixed = true
    let action: () -> Void
    @Environment(\.console) private var console
    @ScaledInsets(relativeTo: .caption) private var keyPadding = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)

    var body: some View {
        if console {
            Button(action: action) {
                Text(title).textRole(.consoleKey).lineLimit(1)
            }
            .buttonStyle(.keycap(padding: keyPadding))
            .fixedSize()
        } else if fixed {
            Button(action: action) { ScaledControlLabel(title: title, role: .inspectorSmallControl) }
                .adaptiveControlSize(.small)
                .fixedSize()
        } else {
            Button(action: action) { ScaledControlLabel(title: title, role: .inspectorSmallControl) }
                .adaptiveControlSize(.small)
        }
    }
}

/// A text field in the inspector: the stock rounded field (Classic), or plain text in a
/// recessed well with an orange edge while typing (Console).
struct InspectorTextFieldStyle: ViewModifier {
    @Environment(\.console) private var console
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if console {
            content
                .textFieldStyle(.plain)
                .textRole(.consoleBody)
                .focused($focused)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs + 1)
                .consoleWell(focused: focused)
        } else {
            content
                .textFieldStyle(.roundedBorder)
                .textRole(.body)
        }
    }
}

/// Console only: the legend ink (Classic keeps whatever the control draws).
struct ConsoleLegendInk: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console { content.foregroundStyle(ConsoleInk.legend) } else { content }
    }
}

// MARK: - Notes

/// A short note in the inspector (a hint under a control, the frame-rate sentence): the
/// caption (Classic) or the design's body-sm in the legend ink (Console).
struct InspectorNote: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console {
            content.textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend)
        } else {
            content.textRole(.caption).foregroundStyle(.secondary)
        }
    }
}
