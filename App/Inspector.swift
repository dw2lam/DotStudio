//  Inspector.swift — the editor's right-hand panel: effect stack + shared source.
//
//  Layout grid (all from Layout.swift tokens; see `InspectorMetrics` for the few fixed
//  design lengths this panel adds):
//    edge A  the panel's content inset (layout.cardPadding): section headers, eye toggles,
//            the Add Effect button, the Source tab.
//    edge B  A + eye column + iconGap: effect names, and every parameter label under them
//            (and the Motion rows, so all parameter controls share one column).
//    Every parameter row — slider, switch, menu, colors, frame rate — is the same two
//    columns: a label column that grows with the text, then the control. At accessibility
//    sizes (layout.prefersStacking) the label moves above a full-width control.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared metrics

/// Fixed design lengths the inspector rows share, at the default text size. Each view
/// reads them through `@ScaledLength`, so they grow with the text. (Layout.swift has no
/// per-row inspector tokens; these are on the 4-pt grid and live here.)
enum InspectorMetrics {
    /// The eye toggle's column; also the indent of an effect's parameters (+ iconGap),
    /// so parameter labels line up with the effect's name.
    static let eyeColumn: CGFloat = 20
    /// Parameter labels ("Lake Reflection" is 87 pt at 12 pt). `layout.formLabelWidth`
    /// grows at only half the text rate, which is too slow for a text column.
    static let labelColumn: CGFloat = 92
    /// Slider value readouts ("100%" is 27 pt at 10 pt).
    static let valueColumn: CGFloat = 40
    /// One color well plus its caption underneath.
    static let wellColumn: CGFloat = 64
    /// Disclosure chevron and "…" menu glyph boxes at the end of an effect row.
    static let glyphColumn: CGFloat = 16
}

extension TextRole {
    /// Section headers inside the inspector list ("Effects", "Motion"): 11 pt semibold,
    /// the size macOS gives inset-list headers.
    static let inspectorSection = TextRole(style: .subheadline, weight: .semibold)
    /// The small outlined "SCENE" tag after a scene layer's name.
    static let inspectorTag = TextRole(style: .caption2, weight: .bold, tracking: 0.6, uppercase: true)
}

/// The inspector's one rule for a segmented choice (Effects | Source tabs, the source
/// kind, media scaling): it spans its column, segments sharing it equally. On the macOS 26
/// SDK segments are equal-width (each as wide as the widest label) and never shrink below
/// that, so when the column is too narrow the choice steps down to small segments, then
/// to a pop-up menu — it never runs past the column. `picker` is a Picker with its label
/// hidden and no style.
struct SegmentedChoice<Content: View>: View {
    @ViewBuilder var picker: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).adaptiveControlSize().fillsColumn()
            picker.pickerStyle(.segmented).controlSize(.small).fillsColumn()
            picker.pickerStyle(.menu).adaptiveControlSize().fixedSize()
            picker.pickerStyle(.menu).adaptiveControlSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// Equal segments stretched across the column (macOS 26); natural width on the
    /// leading edge before that.
    @ViewBuilder
    func fillsColumn() -> some View {
        if #available(macOS 26, *) {
            buttonSizing(.flexible).frame(maxWidth: .infinity)
        } else {
            fixedSize().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension VerticalAlignment {
    /// The vertical centre of a color well, so a row's label lines up with the wells
    /// rather than with the wells + captions underneath them.
    private enum WellCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let wellCenter = VerticalAlignment(WellCenter.self)
}

/// The inspector's form row: a label column, then the control. Stacks (label above a
/// full-width control) when the text is big enough that the two can't share a line.
struct InspectorRow<Control: View>: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var labelColumn: CGFloat = InspectorMetrics.labelColumn
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var control: Control

    var body: some View {
        let stacked = layout.prefersStacking
        AdaptiveStack(rowAlignment: alignment, columnAlignment: .leading,
                      spacing: stacked ? layout.labelGap : layout.controlGap) {
            Text(label)
                .textRole(.callout)
                .truncating(label, lines: 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: stacked ? nil : labelColumn, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Color wells in a row, each with its caption underneath, in fixed scaled columns so the
/// wells line up from one Colors row to the next. Shared by effect rows and the gradient
/// source. `accessory` sits after the wells (the gradient's swap button).
struct ColorWellsRow<Accessory: View>: View {
    struct Well {
        let title: String
        let color: Binding<Color>
    }

    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption2) private var wellColumn: CGFloat = InspectorMetrics.wellColumn
    var label = "Colors"
    let wells: [Well]
    @ViewBuilder var accessory: Accessory

    var body: some View {
        InspectorRow(label: label, alignment: .wellCenter) {
            ReflowStack(rowAlignment: .wellCenter, columnAlignment: .leading, spacing: layout.controlGap) {
                ForEach(wells.indices, id: \.self) { i in
                    let well = wells[i]
                    VStack(alignment: .leading, spacing: layout.labelGap) {
                        ColorPicker(well.title, selection: well.color)
                            .labelsHidden()
                            .adaptiveControlSize()
                            .alignmentGuide(.wellCenter) { $0[VerticalAlignment.center] }
                        Text(well.title)
                            .textRole(.caption2)
                            .foregroundStyle(.secondary)
                            .truncating(well.title, lines: 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: wellColumn, alignment: .leading)
                    .help(well.title)
                }
                accessory
            }
        }
    }
}

extension ColorWellsRow where Accessory == EmptyView {
    init(label: String = "Colors", wells: [Well]) {
        self.init(label: label, wells: wells) { EmptyView() }
    }
}

// MARK: - Effect stack

struct EffectStackView: View {
    @Binding var preset: Preset
    @ObservedObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .body) private var eyeColumn: CGFloat = InspectorMetrics.eyeColumn
    @State private var expanded: Set<UUID> = []
    @State private var showAdd = false

    /// The inset List draws its rows this far in from its own edge on macOS (measured on
    /// the macOS 26 SDK). Row insets make up the rest, so every row's content lands
    /// exactly on the panel's content edge, `cardPadding`.
    private static let listMargin: CGFloat = 16

    // Section titles, the Add Effect footer and the Motion group are ordinary rows, not
    // List section headers/footers: macOS gives a section header one fixed line of height
    // (a wrapped title or reorder hint would be clipped) and ignores its row insets. As
    // rows they grow with their text, and the vertical rhythm is all on the token scale.
    var body: some View {
        List {
            effectsHeader
                .listRowInsets(rowInsets(vertical: layout.labelGap))
                .listRowSeparator(.hidden)

            ForEach($preset.effects) { $effect in
                EffectRow(effect: $effect,
                          isExpanded: expandedBinding(effect.id),
                          isFirst: preset.effects.first?.id == effect.id,
                          onDuplicate: { duplicate(effect.id) },
                          onRemove: { remove(effect.id) })
                    .listRowInsets(rowInsets(vertical: layout.labelGap))
                    // The separator under each effect ends on the content edge too.
                    .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            }
            .onMove { preset.effects.move(fromOffsets: $0, toOffset: $1) }

            VStack(alignment: .leading, spacing: layout.itemGap) {
                if preset.effects.isEmpty {
                    Text("No effects yet — this style shows the source as-is.")
                        .textRole(.caption).foregroundStyle(.secondary)
                        .wrapping()
                }
                Button { showAdd = true } label: {
                    Label("Add Effect", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveControlSize(.large)
                .help("Add an effect to the top of this style's stack")
                .popover(isPresented: $showAdd, arrowEdge: .leading) {
                    AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                                    include: { !$0.isScene }) { kind in
                        let e = EffectInstance(kind)
                        preset.effects.append(e)
                        expanded = [e.id]
                        showAdd = false
                    }
                }
            }
            .padding(.top, layout.controlGap)
            .listRowInsets(rowInsets(vertical: layout.labelGap))
            .listRowSeparator(.hidden)

            // Motion: a new group, a section gap below Add Effect. (Uneven spacing goes in
            // padding: the List centres a row's content between its vertical insets.)
            Text("Motion")
                .textRole(.inspectorSection)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, max(layout.sectionGap - 2 * layout.labelGap, 0))
                .listRowInsets(rowInsets(vertical: layout.labelGap))
                .listRowSeparator(.hidden)

            VStack(alignment: .leading, spacing: layout.labelGap) {
                InspectorRow(label: "Frame rate") {
                    FittingPicker {
                        Picker("Frame rate", selection: $preset.fps) {
                            ForEach(fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden()
                    }
                    .adaptiveControlSize()
                }
                Text(preset.fps > 60
                     ? "120 fps needs a ProMotion display; elsewhere it plays at the screen's rate. It costs more GPU and battery."
                     : "Lower frame rates save battery. Most styles look the same at 30 fps.")
                    .textRole(.caption).foregroundStyle(.secondary)
                    .wrapping()
            }
            .padding(.leading, eyeColumn + layout.iconGap)
            .listRowInsets(rowInsets(vertical: layout.labelGap))
            .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .onAppear {
            // Open the first effect so the main knobs are right there.
            if expanded.isEmpty, let first = preset.effects.first { expanded = [first.id] }
            if DemoHooks.expandAllEffects { expanded = Set(preset.effects.map(\.id)) }   // UI shots / design review
        }
    }

    /// "Effects" (or "Scene & Layers") with the reorder hint beside it, or under it when
    /// the two can't share a line. The hint only shows when there's something to reorder.
    private var effectsHeader: some View {
        let title = Text(preset.isScene ? "Scene & Layers" : "Effects").textRole(.inspectorSection)
        let hint = Text("Drag to reorder · top runs first")
            .textRole(.caption2).foregroundStyle(.tertiary)
        return Group {
            if preset.effects.count > 1 {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: layout.controlGap) {
                        title
                        Spacer(minLength: layout.controlGap)
                        hint.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: layout.labelGap) {
                        title
                        hint.wrapping()
                    }
                }
            } else {
                title
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row insets that put list content on the panel's content edge (`cardPadding`).
    private func rowInsets(vertical: CGFloat) -> EdgeInsets {
        let side = max(layout.cardPadding - Self.listMargin, 0)
        return EdgeInsets(top: vertical, leading: side, bottom: vertical, trailing: side)
    }

    private var fpsOptions: [Int] {
        var opts = [15, 24, 30, 60, 120]
        if !opts.contains(preset.fps) { opts.append(preset.fps); opts.sort() }
        return opts
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func duplicate(_ id: UUID) {
        guard let i = preset.effects.firstIndex(where: { $0.id == id }) else { return }
        var copy = preset.effects[i]
        copy.id = UUID()
        preset.effects.insert(copy, at: i + 1)
        expanded.insert(copy.id)
    }

    private func remove(_ id: UUID) {
        preset.effects.removeAll { $0.id == id }
        expanded.remove(id)
    }
}

/// One effect in the stack: eye toggle, name, "…" menu and disclosure chevron, then (when
/// open) its parameters, indented so their labels line up with the name.
struct EffectRow: View {
    @Binding var effect: EffectInstance
    @Binding var isExpanded: Bool
    let isFirst: Bool
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .body) private var eyeColumn: CGFloat = InspectorMetrics.eyeColumn
    @ScaledLength(relativeTo: .body) private var glyphColumn: CGFloat = InspectorMetrics.glyphColumn

    var body: some View {
        VStack(alignment: .leading, spacing: layout.controlGap) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: layout.controlGap) {
                    ForEach(effect.kind.params) { spec in
                        ParamRow(spec: spec, value: paramBinding(spec))
                    }
                    if effect.kind.usesColors {
                        ColorWellsRow(wells: wells)
                    }
                }
                .padding(.leading, eyeColumn + layout.iconGap)
                .padding(.vertical, layout.labelGap)
                .disabled(!effect.enabled)
                .opacity(effect.enabled ? 1 : 0.45)
            }
        }
        .contextMenu {
            Button("Reset to Defaults") { reset() }.disabled(isDefault)
            Button("Duplicate") { onDuplicate() }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }

    private var header: some View {
        let name = effect.kind.displayName
        return HStack(spacing: layout.iconGap) {
            Button { effect.enabled.toggle() } label: {
                Image(systemName: effect.enabled ? "eye" : "eye.slash")
                    .textRole(.body)
                    .foregroundStyle(effect.enabled ? Color.primary : Color.secondary)
                    .frame(width: eyeColumn)
            }
            .buttonStyle(.borderless)
            .help(effect.enabled ? "Hide this effect" : "Show this effect")

            HStack(alignment: .firstTextBaseline, spacing: layout.controlGap) {
                Text(name)
                    .textRole(.bodyEmphasis)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(effect.enabled ? .primary : .secondary)
                    .help("\(name) — \(effect.kind.blurb)")
                if effect.kind.isScene {
                    Text("Scene")
                        .textRole(.inspectorTag)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.horizontal, Space.xxs)
                        .padding(.vertical, Space.snap(2))
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            Menu {
                Button("Reset to Defaults") { reset() }
                    .disabled(isDefault)
                Button("Duplicate") { onDuplicate() }
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            } label: {
                // A plain-styled menu draws its own label, so the glyph follows the text
                // size (a borderless-button menu keeps a fixed 13 pt glyph).
                Image(systemName: "ellipsis")
                    .textRole(.body)
                    .foregroundStyle(.primary)
                    .frame(width: glyphColumn, height: glyphColumn)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reset, duplicate or remove \(name)")

            Button { toggleExpanded() } label: {
                Image(systemName: "chevron.right")
                    .textRole(.captionEmphasis)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: glyphColumn)
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide \(name)'s settings" : "Show \(name)'s settings")
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
    }

    private var wells: [ColorWellsRow<EmptyView>.Well] {
        var out: [ColorWellsRow<EmptyView>.Well] = []
        if effect.kind.defaultColorA != nil { out.append(.init(title: effect.kind.colorALabel, color: colorBinding(isA: true))) }
        if effect.kind.defaultColorB != nil { out.append(.init(title: effect.kind.colorBLabel, color: colorBinding(isA: false))) }
        return out
    }

    private var isDefault: Bool {
        effect.params == effect.kind.defaultParams
            && effect.colorA == effect.kind.defaultColorA
            && effect.colorB == effect.kind.defaultColorB
    }

    private func reset() {
        effect.params = effect.kind.defaultParams
        effect.colorA = effect.kind.defaultColorA
        effect.colorB = effect.kind.defaultColorB
    }

    private func paramBinding(_ spec: ParamSpec) -> Binding<Double> {
        Binding(get: { effect.params[spec.key] ?? spec.def },
                set: { effect.params[spec.key] = $0 })
    }

    private func colorBinding(isA: Bool) -> Binding<Color> {
        Binding(
            get: {
                let c = isA ? (effect.colorA ?? effect.kind.defaultColorA) : (effect.colorB ?? effect.kind.defaultColorB)
                return Color(c ?? .black)
            },
            set: { if isA { effect.colorA = RGBA($0) } else { effect.colorB = RGBA($0) } })
    }
}

/// A menu picker at its natural width when it fits, otherwise squeezed (macOS then
/// truncates the selected title) instead of running past the panel.
private struct FittingPicker<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize()
            content
        }
    }
}

/// One parameter: menu, switch, or labeled slider with a readable value and reset —
/// all in the same label column + control column.
struct ParamRow: View {
    let spec: ParamSpec
    @Binding var value: Double
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption) private var valueColumn: CGFloat = InspectorMetrics.valueColumn

    var body: some View {
        InspectorRow(label: spec.label) {
            if let options = spec.options {
                FittingPicker {
                    Picker(spec.label, selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) })) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                    }
                    .labelsHidden()
                }
                .adaptiveControlSize()
            } else if spec.isToggle {
                Toggle(spec.label, isOn: Binding(get: { value > 0.5 }, set: { value = $0 ? 1 : 0 }))
                    .labelsHidden()
                    .adaptiveControlSize(.small)
            } else {
                HStack(spacing: layout.controlGap) {
                    if spec.step > 0 {
                        Slider(value: $value, in: spec.min...spec.max, step: spec.step)
                    } else {
                        Slider(value: $value, in: spec.min...spec.max)
                    }
                    HStack(spacing: layout.labelGap) {
                        Text(formatted)
                            .textRole(.value).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: valueColumn, alignment: .trailing)
                        Button { value = spec.def } label: {
                            Image(systemName: "arrow.counterclockwise").textRole(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .opacity(abs(value - spec.def) > 1e-6 ? 1 : 0)
                        .disabled(abs(value - spec.def) <= 1e-6)
                        .help("Reset to \(format(spec.def))")
                    }
                }
                .adaptiveControlSize(.small)
            }
        }
    }

    private var formatted: String { format(value) }

    private func format(_ v: Double) -> String {
        let key = spec.key.lowercased()
        if key == "angle" || spec.label.lowercased().contains("angle") {
            return String(format: "%.0f°", v * 180 / .pi)
        }
        if spec.step >= 1 || spec.max - spec.min >= 20 { return String(format: "%.0f", v) }
        if spec.max <= 1.0 && spec.min >= 0 { return String(format: "%.0f%%", v * 100) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Add effect picker

struct AddEffectPicker: View {
    let source: SourceSpec
    let thumbnailer: Thumbnailer
    var include: (EffectKind) -> Bool = { _ in true }
    var prompt = "Search effects"
    /// Highlights one cell (onboarding's creator); nil in the editor's add-popover.
    var selected: EffectKind? = nil
    /// Popover size at the default text size (it grows with the text); nil lets the
    /// picker fill its container.
    var size: CGSize? = CGSize(width: 430, height: 500)
    /// List Looks before Scenes (onboarding starts people on a Look).
    var scenesLast = false
    let onPick: (EffectKind) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Its own layout root: a popover (or the onboarding canvas) is narrow whatever
        // the main window's width class is.
        let content = AddEffectGrid(source: source, thumbnailer: thumbnailer, include: include,
                                    prompt: prompt, selected: selected, scenesLast: scenesLast,
                                    onPick: onPick)
            .adaptiveLayout()
        if let size {
            // Ideal size grows with the text (what a popover opens at); a host that fixes
            // the size still gets a picker that fills it.
            let grow = LayoutMetrics(widthClass: .compact, typeSize: typeSize)
            content.frame(minWidth: min(size.width, grow.scaled(size.width)), idealWidth: grow.scaled(size.width),
                          maxWidth: max(size.width, grow.scaled(size.width)),
                          minHeight: min(size.height, grow.scaled(size.height)), idealHeight: grow.scaled(size.height),
                          maxHeight: max(size.height, grow.scaled(size.height)))
        } else {
            content
        }
    }
}

private struct AddEffectGrid: View {
    let source: SourceSpec
    let thumbnailer: Thumbnailer
    let include: (EffectKind) -> Bool
    let prompt: String
    let selected: EffectKind?
    let scenesLast: Bool
    let onPick: (EffectKind) -> Void
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption) private var iconColumn: CGFloat = 16
    @State private var query = ""

    /// Narrowest a picker cell gets (at the default text size) before the grid drops a column.
    private static let cellMinWidth: CGFloat = 112

    private var groups: [(EffectCategory, [EffectKind])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cats = scenesLast
            ? EffectCategory.allCases.filter { !$0.isScenes } + EffectCategory.allCases.filter(\.isScenes)
            : EffectCategory.allCases
        return cats.compactMap { cat in
            let kinds = EffectKind.allCases.filter {
                $0.category == cat && !$0.isRetired && include($0) &&
                (q.isEmpty || $0.displayName.lowercased().contains(q) || cat.rawValue.lowercased().contains(q)
                 || $0.blurb.lowercased().contains(q))
            }
            return kinds.isEmpty ? nil : (cat, kinds)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .textRole(.body)
                .padding(layout.cardPadding)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: layout.sectionGap) {
                        ForEach(groups, id: \.0) { cat, kinds in
                            VStack(alignment: .leading, spacing: layout.controlGap) {
                                HStack(spacing: layout.iconGap) {
                                    Image(systemName: cat.symbol)
                                        .frame(width: iconColumn)
                                    Text(cat.rawValue)
                                        .truncating(cat.rawValue)
                                }
                                .textRole(.captionEmphasis)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                                LazyVGrid(columns: layout.columns(minimum: Self.cellMinWidth, spacing: layout.gridColumnGap),
                                          alignment: .leading, spacing: layout.gridRowGap) {
                                    ForEach(kinds, id: \.self) { kind in
                                        Button { onPick(kind) } label: { cell(kind) }
                                            .buttonStyle(.plain)
                                            .help("\(kind.displayName) — \(kind.blurb)")
                                            .id(kind)
                                    }
                                }
                            }
                        }
                        if groups.isEmpty {
                            let message = "No effects match “\(query)”."
                            Text(message)
                                .textRole(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .truncating(message, lines: 3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Space.xl)
                        }
                    }
                    .padding(layout.cardPadding)
                }
                .onAppear {
                    // Show the current pick, not the top of the list.
                    guard let selected else { return }
                    DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
    }

    private func cell(_ kind: EffectKind) -> some View {
        let isSelected = kind == selected
        let name = kind.displayName
        return VStack(alignment: .leading, spacing: layout.labelGap) {
            swatch(kind)
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .textRole(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(Space.xxs)
                    }
                }
            // The semibold copy (hidden) sets the size for every cell, so selecting one
            // doesn't widen its name into a truncation.
            ZStack(alignment: .topLeading) {
                Text(name).textRole(.captionEmphasis).lineLimit(2).hidden()
                Text(name).textRole(isSelected ? .captionEmphasis : .caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }

    private func swatch(_ kind: EffectKind) -> some View {
        Group {
            if let img = thumbnailer.effectImage(kind, source: source) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }
}

// MARK: - Source

/// The one source every Look restyles. Used in the editor's Source tab and the
/// library's Source popover.
struct SourceEditor: View {
    @Binding var source: SourceSpec
    @ObservedObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var dropMinHeight: CGFloat = 112
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            Text("Every Look restyles this. Scenes don't use it.")
                .textRole(.caption).foregroundStyle(.secondary)
                .wrapping()

            SegmentedChoice {
                Picker("Kind", selection: $source.kind) {
                    Text("Slideshow").tag(SourceKind.collection)
                    Text("Photo").tag(SourceKind.image)
                    Text("Video").tag(SourceKind.video)
                    Text("Gradient").tag(SourceKind.gradient)
                }
                .labelsHidden()
            }

            switch source.kind {
            case .collection: slideshowControls
            case .gradient: gradientControls
            case .image, .video: mediaControls
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: source.kind == .video ? [.movie, .mpeg4Movie, .quickTimeMovie] : [.image],
                      allowsMultipleSelection: source.kind == .collection) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if source.kind == .collection { model.importSlideshowPhotos(urls) }
            else if let url = urls.first { importFile(url, kind: source.kind) }
        }
    }

    /// Built-in photos (or the user's own), slowly panning and cross-fading.
    private var slideshowControls: some View {
        let own = !(source.mediaFilenames ?? []).isEmpty
        let choose = own ? "Choose Other Photos…" : "Use Your Own Photos…"
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(SourceSwatch(source: source))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        loadDroppedImages(providers) { urls in model.importSlideshowPhotos(urls) }
                        return true
                    }
                Text(own ? "Your photos · \(source.mediaFilenames?.count ?? 0)"
                         : "Built-in photos · curated, public domain")
                    .textRole(.caption).foregroundStyle(.secondary)
                    .wrapping()
            }
            VStack(alignment: .leading, spacing: layout.controlGap) {
                ParamRow(spec: ParamSpec("hold", "Seconds Each", 6, 120, def: SourceSpec.defaultSlideSeconds),
                         value: Binding(get: { source.slideInterval }, set: { source.slideSeconds = $0 }))
                ParamRow(spec: ParamSpec("motion", "Pan & Zoom", 0, 1, def: SourceSpec.defaultMotion),
                         value: Binding(get: { source.motionAmount }, set: { source.motion = $0 }))
            }
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
                Button(choose) { importing = true }
                    .help(choose)
                if own {
                    Button("Use Built-in Photos") { model.useBuiltInPhotos() }
                        .help("Use Built-in Photos")
                }
            }
            .adaptiveControlSize(.small)
        }
    }

    /// Image files among dropped items, delivered together on the main queue.
    private func loadDroppedImages(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
    }

    private var gradientControls: some View {
        VStack(alignment: .leading, spacing: layout.controlGap) {
            ColorWellsRow(wells: [.init(title: "From", color: colorBinding(\.colorA)),
                                  .init(title: "To", color: colorBinding(\.colorB))]) {
                Button {
                    let a = source.colorA; source.colorA = source.colorB; source.colorB = a
                } label: {
                    Image(systemName: "arrow.left.arrow.right").textRole(.callout)
                }
                .buttonStyle(.borderless)
                .help("Swap colors")
            }
            ParamRow(spec: ParamSpec("angle", "Angle", 0, 6.28, def: 1.1), value: $source.gradientAngle)
            ParamRow(spec: ParamSpec("drift", "Drift", 0, 3, def: 1.0), value: $source.gradientDrift)
        }
    }

    private var mediaControls: some View {
        let zone = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            Button { importing = true } label: {
                VStack(spacing: layout.controlGap) {
                    if let filename = source.mediaFilename {
                        SourceSwatch(source: source)
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.concentric(Radius.m, inset: Space.s),
                                                        style: .continuous))
                        Text(filename)
                            .textRole(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .truncating(filename, lines: 2, mode: .middle)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: source.kind == .video ? "film" : "photo")
                            .scaledFont { .scaled(.title, $0) }
                            .foregroundStyle(.secondary)
                        Text("Drop a \(source.kind == .video ? "video" : "photo") here, or click to choose")
                            .textRole(.callout).foregroundStyle(.secondary)
                            .wrapping(.center)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: dropMinHeight)
                .padding(Space.s)
                .background(zone.fill(Color.primary.opacity(dropTargeted ? 0.08 : 0.03)))
                .overlay(zone
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
                .contentShape(zone)
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension) else { return }
                    let kind: SourceKind? = type.conforms(to: .movie) ? .video : type.conforms(to: .image) ? .image : nil
                    if let kind { DispatchQueue.main.async { importFile(url, kind: kind) } }
                }
                return true
            }

            InspectorRow(label: "Scaling") {
                SegmentedChoice {
                    Picker("Scaling", selection: $source.fillMode) {
                        Text("Fill").tag(1); Text("Fit").tag(0); Text("Stretch").tag(2)
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private func importFile(_ url: URL, kind: SourceKind) {
        let ok = url.startAccessingSecurityScopedResource()
        model.importMedia(url, kind: kind)
        if ok { url.stopAccessingSecurityScopedResource() }
    }

    private func colorBinding(_ kp: WritableKeyPath<SourceSpec, RGBA>) -> Binding<Color> {
        Binding(get: { Color(source[keyPath: kp]) }, set: { source[keyPath: kp] = RGBA($0) })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
