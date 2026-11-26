//  ConsoleSettingsKit.swift — the Console appearance's Settings (the owner's Google Stitch
//  "Settings & Power Saving" screen): the parts every pane is built from when \.console is on.
//
//    • settingsText(_:)       — a Settings text role, swapped for its Console face when Console
//                               is on (Instrument Sans body, mono legends and readouts).
//    • settingsForm()         — a pane's Form: Classic's grouped Form, or Console's sections —
//                               a mono-caps legend over a ruled list of rows (or a module), the
//                               plain sentence under it — with Console switches, keys and rows.
//    • ConsoleSwitch          — the design's square switch: a well that lights green when on.
//    • ConsoleSegments        — a choice of keycaps in a well; the chosen one blue.
//    • ConsoleCardStyle       — a big key (a preset card, an option card) with travel.
//    • ConsoleModule / ConsoleModuleHeader / ConsoleIconSquare — the power source's block.
//    • ConsoleSlider          — a continuous slider: a well, a green span, a keycap thumb.
//
//  Classic never reaches any of this (every entry point checks \.console).

import SwiftUI
import AppKit

// MARK: - Text

extension TextRole {
    /// Console's counterpart of a role Settings uses (the system roles → the bundled faces).
    var consoleCounterpart: TextRole {
        switch self {
        case .body, .bodyLarge: return .consoleBody
        case .bodyEmphasis, .headline, .itemTitle, .rowTitle: return .consoleTitle
        case .calloutEmphasis, .captionEmphasis: return .consoleBodySmallEmphasis
        case .callout, .caption, .caption2: return .consoleBodySmall
        case .value: return .readout
        case .keycap, .eyebrow: return .legend
        default: return self
        }
    }

    /// Small body, semibold (a chosen option's name in a sentence).
    static let consoleBodySmallEmphasis = TextRole(style: .callout, points: 12, face: ConsoleFace.textSemibold)
    /// A mono line in mixed case ("40–120 fps · Dynamic", a slider's stops): 10.5 pt.
    static let consoleMono = TextRole(style: .caption2, points: 10.5, tracking: 0.2, monospacedDigits: true, face: ConsoleFace.mono)
    /// The same, semibold (a stop inside the range).
    static let consoleMonoStrong = TextRole(style: .caption2, points: 10.5, tracking: 0.2, monospacedDigits: true, face: ConsoleFace.monoBold)
}

extension View {
    /// A Settings text role: `role` in Classic, its Console face in Console.
    func settingsText(_ role: TextRole) -> some View { modifier(SettingsTextRole(role: role)) }

    /// A Settings pane's Form, in the current appearance (see the file comment).
    func settingsForm() -> some View { modifier(SettingsFormLook()) }

    /// Console: this Section's content is one module that draws its own block (power), so it
    /// isn't ruled into rows. Nothing in Classic.
    func consoleModuleSection() -> some View { modifier(ConsoleModuleMark()) }

    /// A Link in a Settings pane: Console prints it as a link (not a key) in the signal ink.
    func settingsLink() -> some View { modifier(SettingsLinkLook()) }
}

private struct SettingsLinkLook: ViewModifier {
    @Environment(\.consoleSettings) private var console
    func body(content: Content) -> some View {
        if console {
            content.buttonStyle(.plain).foregroundStyle(ConsoleInk.signalInk).underline()
        } else {
            content
        }
    }
}

/// A pop-up choice as a Console key: the chosen title and a chevron on a grey key, the same
/// checkmarked list inside (a Menu, so it stays an AppKit menu — no measuring around it).
/// For Settings rows that would otherwise show a stock pop-up (macOS 26 draws those as glass
/// outside a grouped Form).
struct ConsoleMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Space.xs) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .textRole(.consoleBody)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ConsoleInk.legend)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.keycap)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

private struct SettingsTextRole: ViewModifier {
    @Environment(\.consoleSettings) private var console
    let role: TextRole
    func body(content: Content) -> some View { content.textRole(console ? role.consoleCounterpart : role) }
}

// MARK: - The Form

private struct ConsoleSettingsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside a Console Settings pane (settingsForm). Shared pieces that onboarding uses too
    /// (Button(scaled:), ScaledSegmentedPicker) take their Console form only here.
    var consoleSettings: Bool {
        get { self[ConsoleSettingsKey.self] }
        set { self[ConsoleSettingsKey.self] = newValue }
    }
}

private struct SettingsFormLook: ViewModifier {
    @Environment(\.console) private var console

    func body(content: Content) -> some View {
        if console {
            content
                .environment(\.consoleSettings, true)
                .formStyle(ConsoleFormStyle())
                .toggleStyle(ConsoleSwitchStyle())
                .labeledContentStyle(ConsoleLabeledContentStyle())
                .buttonStyle(.keycap)
                .textRole(.consoleBody)
                .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)   // `.secondary` is the legend grey
        } else {
            content
                .formStyle(.grouped)
                .textRole(.body)          // row labels follow the text size (macOS never scales them itself)
                .formControlSize()        // stock sizes at standard text; a step up per text bump after
        }
    }
}

@available(macOS 15.0, *)
extension ContainerValues {
    /// A Section whose content is one self-drawn module (ConsoleModule), not rows.
    @Entry var consoleModule: Bool = false
}

private struct ConsoleModuleMark: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.containerValue(\.consoleModule, true) } else { content }
    }
}

/// Console's Form: a scrolling page of sections on the panel, 24 pt from its edges.
struct ConsoleFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            ConsoleFormSections(content: configuration.content)
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConsoleFormSections<Content: View>: View {
    let content: Content
    var body: some View {
        if #available(macOS 15.0, *) {
            VStack(alignment: .leading, spacing: Space.xl) {
                ForEach(sections: content) { section in ConsoleFormSection(section: section) }
            }
        } else {
            // macOS 14: no section decomposition — the sections' parts in order.
            VStack(alignment: .leading, spacing: Space.s) { content }
        }
    }
}

/// One section: its legend, then its rows between hairlines (the design's General list) — or
/// a module as it is — then its sentence.
@available(macOS 15.0, *)
private struct ConsoleFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !section.header.isEmpty {
                section.header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            if section.containerValues.consoleModule {
                section.content
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subviews: section.content) { row in
                        row
                            .padding(.vertical, Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { ConsoleHairline() }
                    }
                }
                .overlay(alignment: .top) { ConsoleHairline() }
            }
            if !section.footer.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) { section.footer }
            }
        }
    }
}

/// A 1 pt rule in the hairline colour.
struct ConsoleHairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(ConsoleInk.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// A labelled row: the label (and any line under it) on the left, the value on the right; from
/// .xxxLarge text the value goes under the label (chosen from the text size, never measured).
struct ConsoleLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View { ConsoleLabeledRow(configuration: configuration) }
}

private struct ConsoleLabeledRow: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize >= .xxxLarge
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.m))
        layout {
            VStack(alignment: .leading, spacing: 2) { configuration.label }
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Console switch row: the label, then the switch at the row's end.
struct ConsoleSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Space.s) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            ConsoleSwitch(isOn: configuration.$isOn)
                .accessibilityHidden(true)
        }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The design's switch: a square well with a key in it; on, the well lights green and the key
/// (near-black) slides right. A haptic tick when it flips.
struct ConsoleSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .body) private var width: CGFloat = 46
    @ScaledLength(relativeTo: .body) private var height: CGFloat = 24

    var body: some View {
        let inset: CGFloat = 3
        let key = height - inset * 2
        Button {
            isOn.toggle()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Color.clear
                    .consoleWell(cornerRadius: 3)
                    .overlay {
                        ConsoleSwitchLight(shape: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .opacity(isOn ? 1 : 0)
                    }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOn ? ConsoleInk.onGreen : ConsoleInk.keyFace)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : ConsoleInk.outline.opacity(0.5), lineWidth: 0.75))
                    .shadow(color: .black.opacity(isOn ? 0 : 0.18), radius: 1, y: 0.5)
                    .frame(width: key, height: key)
                    .padding(inset)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
        .accessibilityElement()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Segments

/// A choice as keycaps in a well (the design's FORCED / DYNAMIC / REACTIVE): the chosen key is
/// blue. `fills` shares the given width; else they hug their legends. At accessibility text
/// sizes the keys stack into a column (picked from the text size, never measured).
struct ConsoleSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var fills = false
    var tint: ConsoleKeycapStyle.Tint = .blue
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let gap = ConsoleKeycapStyle.wellSpacing
        let layout = stacked ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
        layout {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].title)
                        .textRole(.consoleKey)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: fills || stacked ? .infinity : nil)
                }
                .buttonStyle(.keycap(on ? tint : .plain, padding: EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(EdgeInsets(top: ConsoleKeycapStyle.wellInset, leading: ConsoleKeycapStyle.wellInset,
                            bottom: ConsoleKeycapStyle.wellBottomInset, trailing: ConsoleKeycapStyle.wellInset))
        .consoleWell(cornerRadius: 5)
        .fixedSize(horizontal: !(fills || stacked), vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Cards

/// A big key: a face of `face` colour over the keys' slim 2 pt skirt it sinks into when
/// pressed, a fine edge (orange when hovered; a firmer orange with a soft orange glow when
/// `selected`), a haptic tick on press.
struct ConsoleCardStyle: ButtonStyle {
    var face: Color = ConsoleInk.surface
    var selected = false
    /// A card that only states something (disabled on purpose) keeps full strength.
    var dimsWhenDisabled = true
    var cornerRadius: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        ConsoleCardBody(configuration: configuration, face: face, selected: selected,
                        dims: dimsWhenDisabled, cornerRadius: cornerRadius)
    }
}

private struct ConsoleCardBody: View {
    let configuration: ButtonStyleConfiguration
    let face: Color
    let selected: Bool
    let dims: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let down = configuration.isPressed && enabled
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let hot = hovering && enabled
        let skirt = ConsoleKeycapStyle.skirt
        let edge: Color = selected ? ConsoleInk.signal : hot ? ConsoleInk.signal.opacity(0.6) : ConsoleInk.hairline
        // the selected card glows softly in signal; a hovered one a breath of it
        let glow: Color = down ? .clear
            : selected ? ConsoleInk.signal.opacity(dark ? 0.26 : 0.18)
            : hot ? ConsoleInk.signal.opacity(dark ? 0.16 : 0.1)
            : .black.opacity(dark ? 0.3 : 0.06)
        configuration.label
            .background {
                shape.fill(face)
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.03 : 0.25), .black.opacity(dark ? 0.08 : 0.02)],
                                                       startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.fill(Color.clear.shadow(.inner(color: ConsoleKeyLight.pressShade(dark: dark, down: down), radius: 1.5, y: 1))))
                    .overlay(alignment: .top) {
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(down ? 0 : (dark ? 0.08 : 0.5)), .clear],
                                                          startPoint: .top, endPoint: .center), lineWidth: ConsoleKeyLight.highlightWidth)
                    }
            }
            .overlay(shape.strokeBorder(edge, lineWidth: selected ? 1.25 : (hot ? 1 : 0.75)))
            .offset(y: down ? ConsoleKeycapStyle.travel : 0)
            .background {
                shape.fill(ConsoleInk.keySkirt)
                    .offset(y: skirt)
                    .shadow(color: glow, radius: selected || hot ? 12 : 1.5, y: selected || hot ? 2 : 1)
            }
            .padding(.bottom, skirt)
            .opacity(enabled || !dims ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: down)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && enabled { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
    }
}

// MARK: - Modules

/// A block on the surface colour with a hairline edge (the design's "When Plugged In" module).
struct ConsoleModule<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) { content() }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ConsoleInk.hairline, lineWidth: 1))
    }
}

/// A small coloured square with a glyph (a preset's, a power source's).
struct ConsoleIconSquare: View {
    let symbol: String
    let fill: Color
    var glyph: Color = ConsoleInk.onSignal
    @ScaledLength(relativeTo: .body) private var side: CGFloat = 28
    @ScaledLength(relativeTo: .body) private var glyphSize: CGFloat = 14

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(glyph)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(fill))
            .accessibilityHidden(true)
    }
}

/// A module's head: its icon square, title and a mono line saying what it's set to now, with a
/// control at the end (under the title from .xxxLarge text).
struct ConsoleModuleHeader<Trailing: View>: View {
    let symbol: String
    let fill: Color
    let title: String
    let summary: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stacked = typeSize >= .xxxLarge
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: Space.s))
        layout {
            HStack(alignment: .center, spacing: Space.xs) {
                ConsoleIconSquare(symbol: symbol, fill: fill)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).textRole(.consoleTitle).foregroundStyle(ConsoleInk.ink).wrapping()
                    Text(summary).textRole(.consoleMono).foregroundStyle(ConsoleInk.legend).wrapping()
                        .contentTransition(.numericText())
                        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            trailing()
        }
    }
}

// MARK: - Slider

/// A continuous Console slider: a recessed well with the value's span lit (green), a keycap
/// thumb, the readout beside it. Snaps to `step`, with a tick at each `detent` it lands on;
/// arrow keys / VoiceOver adjust by a step.
struct ConsoleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    /// Values that tick as the thumb lands on them (Off, whole seconds).
    var detents: [Double] = []
    var fill: Color = ConsoleInk.green
    let readout: (Double) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var dragging = false
    @ScaledLength(relativeTo: .body) private var thumbHeight: CGFloat = 24
    @ScaledLength(relativeTo: .caption) private var readoutWidth: CGFloat = 44

    private let thumbWidth: CGFloat = 16
    private let track: CGFloat = 10
    private var span: Double { max(range.upperBound - range.lowerBound, 1e-9) }
    private var fraction: CGFloat { CGFloat(min(max((value - range.lowerBound) / span, 0), 1)) }

    var body: some View {
        HStack(spacing: Space.s) {
            GeometryReader { geo in
                let w = max(geo.size.width - thumbWidth, 1)
                let x = thumbWidth / 2 + w * fraction
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: track).consoleWell(cornerRadius: 2)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(fill)
                        .frame(width: max(x, 0), height: track)
                        .opacity(value > range.lowerBound + step / 2 ? 1 : 0)
                    ConsoleThumb(pressed: dragging)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .position(x: x, y: thumbHeight / 2)
                }
                .frame(height: thumbHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        set(range.lowerBound + Double((g.location.x - thumbWidth / 2) / w) * span)
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: thumbHeight)
            Text(readout(value))
                .textRole(.readout)
                .foregroundStyle(ConsoleInk.ink)
                .frame(minWidth: readoutWidth, alignment: .trailing)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(readout(value))
        .accessibilityAdjustableAction { dir in set(value + (dir == .increment ? step : -step)) }
        .animation(reduceMotion || dragging ? nil : Motion.snappy, value: value)
    }

    private func set(_ v: Double) {
        var n = min(max(v, range.lowerBound), range.upperBound)
        if step > 0 { n = (n / step).rounded() * step }
        n = min(max(n, range.lowerBound), range.upperBound)
        guard abs(n - value) > step / 100 else { return }
        if detents.contains(where: { abs($0 - n) < step / 2 }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        value = n
    }
}

/// A slider's thumb: a small key (high surface, an outline edge, a skirt) that sinks while held.
struct ConsoleThumb: View {
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        shape.fill(ConsoleInk.surfaceHigh)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.05 : 0.3), .clear],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(ConsoleInk.outline.opacity(0.8), lineWidth: 0.75))
            .overlay(Rectangle().fill(ConsoleInk.legend.opacity(0.6)).frame(width: 1).padding(.vertical, 5))   // the grip
            .offset(y: pressed ? 1 : 0)
            .background(shape.fill(ConsoleInk.keySkirt).offset(y: pressed ? 0.5 : 1.5))
            .shadow(color: .black.opacity(pressed ? 0.06 : (scheme == .dark ? 0.35 : 0.1)), radius: 1.5, y: 1)
            .scaleEffect(pressed ? 1.06 : 1)
    }
}
