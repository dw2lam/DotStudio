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
import ImageIO

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
    /// A regular stock segmented control's height at the default text size; the
    /// role-sized segments keep that proportion to their titles.
    static let segmentHeight: CGFloat = Space.grid(6)   // 24
}

extension LayoutMetrics {
    /// Between parameter rows. When a row stacks (label above its control, `labelGap`
    /// apart), rows sit a full item gap apart so each label reads with its own control.
    var inspectorRowGap: CGFloat { prefersStacking ? itemGap : controlGap }
}

extension TextRole {
    /// Section headers inside the inspector list ("Effects", "Motion"): 11 pt semibold,
    /// the size macOS gives inset-list headers.
    static let inspectorSection = TextRole(style: .subheadline, weight: .semibold)
    /// The small outlined "SCENE" tag after a scene layer's name.
    static let inspectorTag = TextRole(style: .caption2, weight: .bold, tracking: 0.6, uppercase: true)
    /// A small (`.small` control size) button's title: 11 pt, the stock small-control font.
    static let inspectorSmallControl = TextRole(style: .subheadline)
}

/// A button title (and symbol) that follows the text size. On macOS a stock control keeps
/// its own 13-pt title (11 pt small) at every text size, and `adaptiveControlSize` only
/// grows the bezel; but a Label/Text that carries its own font is drawn at that font, and
/// the bezel grows to fit. At the default size the role IS the stock font, so nothing
/// changes there. `role`: `.body` for regular and larger controls, `.inspectorSmallControl`
/// for small ones.
struct ScaledControlLabel: View {
    let title: String
    var systemImage: String? = nil
    var role: TextRole = .body

    var body: some View {
        if let systemImage {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .textRole(role)
        } else {
            Text(title).textRole(role)
        }
    }
}

/// The inspector's one rule for a segmented choice (Effects | Source tabs, the source
/// kind, media scaling): it spans its column and never runs past it, and stacked choices
/// share one height.
///
/// (Until 1.4.3 the stock control was used where it fits; now always the drawn one, below.)
/// On the macOS 26/27 SDK its segments are each as wide as the widest title and it never
/// shrinks (the 4-way Kind control is 342 pt, 294 pt even when small, against a 288-pt
/// column), so otherwise — and from .xxLarge at every width, since a stock control keeps
/// 13-pt titles while `adaptiveControlSize` grows its bezel and the text around it is 1.2×
/// and up — it draws `RoleSegments`: the same track, at the same height, with `.body`-role
/// titles; equal segments, then title-sized ones, then a column, so a title never shrinks,
/// truncates or breaks mid-word.
struct SegmentedChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Always the drawn control. Measuring the stock one against it (a ViewThatFits that
        // could swap an AppKit segmented control in and out as the width settled) is the
        // pattern that crashed on macOS 26 inside the inspector's list — see ColorWellsRow.
        RoleSegments(title: title, selection: $selection, options: options)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `SegmentedChoice`'s drawn control: a segmented track drawn here, because a stock
/// control's titles can't take a font and its segments can't be sized to their titles.
/// At the default size it matches a regular stock control (24 pt, 13-pt titles); its fills
/// match the stock control's in light and dark.
private struct RoleSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @ScaledLength(relativeTo: .body) private var height: CGFloat = InspectorMetrics.segmentHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var trackFill: Color { Color.primary.opacity(0.078) }
    private static var selectedFill: Color { Color.primary.opacity(0.13) }
    private static var separatorFill: Color { Color.primary.opacity(0.15) }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: height / 2, style: .continuous) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            SegmentRowLayout(equal: true) { segments(.horizontal) }
            SegmentRowLayout(equal: false) { segments(.horizontal) }
            VStack(spacing: 0) { segments(.vertical) }
        }
        .background(shape.fill(Self.trackFill))
        .animation(reduceMotion ? Motion.reduced : .easeOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segments(_ axis: Axis) -> some View {
        ForEach(options.indices, id: \.self) { i in segment(i, axis: axis) }
    }

    private func segment(_ i: Int, axis: Axis) -> some View {
        let isOn = options[i].value == selection
        // The stock control draws a hairline between two unselected neighbours.
        let separates = i > 0 && !isOn && options[i - 1].value != selection
        return Button { selection = options[i].value } label: {
            Text(options[i].title)
                .textRole(.body)
                .foregroundStyle(.primary)
                .lineLimit(axis == .horizontal ? 1 : nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, height / 2)
                .padding(.vertical, Space.xxs)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(shape.fill(Self.selectedFill).opacity(isOn ? 1 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: axis == .horizontal ? .leading : .top) {
            if separates {
                Rectangle()
                    .fill(Self.separatorFill)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .horizontal ? height / 2 : 1)
                    .padding(.horizontal, axis == .vertical ? height / 2 : 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Segments in one row across the proposed width: `equal` gives each the widest title's
/// width (ideally `count × widest`), otherwise each gets its own title's width plus an
/// equal share of the spare room. Its ideal width is what `ViewThatFits` compares with the
/// column, so a row is only chosen when no title would truncate.
private struct SegmentRowLayout: Layout {
    var equal: Bool

    private func widths(_ subviews: Subviews, total: CGFloat?) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let n = CGFloat(subviews.count)
        if equal {
            let each = max(ideal.max() ?? 0, (total ?? 0) / n)
            return Array(repeating: each, count: subviews.count)
        }
        let spare = max(0, (total ?? 0) - ideal.reduce(0, +)) / n
        return ideal.map { $0 + spare }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let total = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let ws = widths(subviews, total: total)
        let height = zip(subviews, ws)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: ws.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (sv, w) in zip(subviews, widths(subviews, total: bounds.width)) {
            sv.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
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
            // Row or column by the text size (AdaptiveStack), never by measuring: the wells are
            // AppKit color wells, and a ViewThatFits flipping between two copies of them inside
            // the inspector's list re-created them in the middle of the window's layout, round
            // and round — on macOS 26 that ended in AppKit's display-cycle exception (a crash on
            // opening any style with colours).
            AdaptiveStack(rowAlignment: .wellCenter, columnAlignment: .leading, spacing: layout.controlGap) {
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
    /// The open effects. Starts with the first one open (its main knobs right there) — set
    /// here, before the List exists, never from its onAppear: opening a row as the List
    /// appears changes row heights in the middle of the window's layout, and the table's
    /// constraint passes then never settle within one display cycle. macOS 27 logs that and
    /// moves on; macOS 26 throws ("…more Update Constraints in Window passes than there are
    /// views in the window") and the app crashed on opening any style (1.4.1–1.4.3).
    @State private var expanded: Set<UUID>
    @State private var showAdd = false

    init(preset: Binding<Preset>, model: AppModel) {
        _preset = preset
        self.model = model
        let effects = preset.wrappedValue.effects
        _expanded = State(initialValue: DemoHooks.expandAllEffects ? Set(effects.map(\.id))
                                        : Set(effects.prefix(1).map(\.id)))
    }

    /// The inset List draws its rows this far in from its own edge on macOS (measured on
    /// the macOS 26 SDK). Row insets make up the rest, so every row's content lands
    /// exactly on the panel's content edge, `cardPadding`.
    private static let listMargin: CGFloat = 16
    /// …and its first row this far below its top (measured the same way). The Source tab
    /// starts its content at the same depth.
    static let listTopInset: CGFloat = 10

    // Section titles, the Add Effect footer and the Motion group are ordinary rows, not
    // List section headers/footers: macOS gives a section header one fixed line of height
    // (a wrapped title or reorder hint would be clipped) and ignores its row insets. As
    // rows they grow with their text, and the vertical rhythm is all on the token scale.
    var body: some View {
        let _ = Perf.body("EffectStackView")
        List {
            effectsHeader
                .listRowInsets(rowInsets(vertical: layout.labelGap))
                .listRowSeparator(.hidden)

            ForEach($preset.effects) { $effect in
                EffectRow(effect: $effect,
                          isExpanded: expandedBinding(effect.id),
                          isFirst: preset.effects.first?.id == effect.id,
                          onDuplicate: { duplicate(effect.id) },
                          onRemove: { remove(effect.id) },
                          model: model)
                    .listRowInsets(rowInsets(vertical: layout.labelGap))
                    // The separator under each effect spans the content edges, edge A to
                    // edge A, like the header divider above the list.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
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
                    ScaledControlLabel(title: "Add Effect", systemImage: "plus")
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
                    InspectorMenu(title: "Frame rate", selection: $preset.fps,
                                  options: fpsOptions.map { ("\($0) fps", $0) })
                }
                // One sentence per line, each short enough for the narrowest inspector at
                // the default size, so the caption breaks on the sentence, not mid-phrase.
                Text(preset.fps > 60
                     ? "120 fps needs a ProMotion display.\nIt uses more GPU and battery."
                     : "Lower frame rates save battery.\nMost styles look the same at 30 fps.")
                    .textRole(.caption).foregroundStyle(.secondary)
                    .wrapping()
            }
            .padding(.leading, eyeColumn + layout.iconGap)
            .listRowInsets(rowInsets(vertical: layout.labelGap))
            .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        // Rows hug their content. (Any minimum above 0: AppKit rejects a 0 row height
        // with a logged error on every layout.)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background {   // DEV harness only (ClickProbe): open and close rows as a click does
            if TileProbe.enabled {
                Color.clear.onAppear {
                    TileProbe.toggleEffects = {
                        guard let first = preset.effects.first?.id else { return }
                        if expanded.contains(first) { expanded.remove(first) } else { expanded.insert(first) }
                    }
                }
            }
        }
    }

    /// "Effects" (or "Scene & Layers"). How to reorder is in its tooltip, not on screen.
    private var effectsHeader: some View {
        Text(preset.isScene ? "Scene & Layers" : "Effects")
            .textRole(.inspectorSection)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(preset.effects.count > 1 ? "Drag effects to reorder them — the top one runs first" : "")
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
    /// For a Bounce layer's Logo section (importing an image into the shared media folder).
    var model: AppModel? = nil
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .body) private var eyeColumn: CGFloat = InspectorMetrics.eyeColumn
    @ScaledLength(relativeTo: .body) private var glyphColumn: CGFloat = InspectorMetrics.glyphColumn

    var body: some View {
        let _ = Perf.body("EffectRow")
        VStack(alignment: .leading, spacing: layout.controlGap) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
                    ForEach(effect.kind.params) { spec in
                        ParamRow(spec: spec, value: paramBinding(spec))
                    }
                    if effect.kind.usesColors {
                        ColorWellsRow(wells: wells)
                    }
                    if effect.kind == .bounce, let model {
                        BounceLogoSection(effect: $effect, model: model)
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
            .accessibilityLabel(effect.enabled ? "Hide \(name)" : "Show \(name)")

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
            .accessibilityLabel("\(name) options")

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
            && effect.logoKind == nil && effect.logoText == nil && effect.logoFile == nil
    }

    private func reset() {
        effect.params = effect.kind.defaultParams
        effect.colorA = effect.kind.defaultColorA
        effect.colorB = effect.kind.defaultColorB
        effect.logoKind = nil; effect.logoText = nil; effect.logoFile = nil
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

/// Bounce's logo: the built-in DotStudio mark, a word the user types (their name), or an image
/// of theirs — copied into the shared media folder, where the sandboxed screensaver can read it.
/// The choice lives on the effect (EffectInstance.logoKind / logoText / logoFile); the word and
/// the image are both kept while another kind is picked, so switching back restores them.
struct BounceLogoSection: View {
    @Binding var effect: EffectInstance
    @ObservedObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var thumbHeight: CGFloat = 64
    @State private var choosing = false
    @State private var thumb: NSImage?

    private var kind: BounceLogoKind { effect.logoKind ?? .builtIn }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
            InspectorRow(label: "Logo") {
                SegmentedChoice(title: "Logo",
                                selection: Binding(get: { kind }, set: { effect.logoKind = $0 == .builtIn ? nil : $0 }),
                                options: [("Built-in", .builtIn), ("Text", .text), ("Image", .image)])
            }
            switch kind {
            case .builtIn:
                note("The DotStudio mark.")
            case .text:
                InspectorRow(label: "Text") {
                    TextField("Your name", text: Binding(get: { effect.logoText ?? "" },
                                                         set: { effect.logoText = $0.isEmpty ? nil : String($0.prefix(48)) }))
                        .textFieldStyle(.roundedBorder)
                        .textRole(.body)
                        .accessibilityLabel("Logo text")
                }
                if (effect.logoText ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    note("Type a word — until then the DotStudio mark bounces.")
                }
            case .image:
                imageControls
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .heic, .svg, .pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            if let name = model.importLogo(url) {
                effect.logoFile = name
                effect.logoKind = .image
            }
        }
        .task(id: effect.logoFile) { await loadThumb() }
    }

    private var imageControls: some View {
        let has = effect.logoFile != nil
        return VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
            InspectorRow(label: "Image") {
                // The thumbnail beside its buttons; at large text sizes the buttons go under
                // it instead. Chosen by the text size, not by measuring (no ViewThatFits): the
                // buttons are AppKit controls inside the inspector's list — see ColorWellsRow.
                if layout.prefersStacking || layout.typeSize >= .xxLarge {
                    VStack(alignment: .leading, spacing: layout.labelGap) {
                        thumbnail(has)
                        HStack(spacing: layout.controlGap) { imageButtons(has) }
                    }
                } else {
                    HStack(spacing: layout.controlGap) {
                        thumbnail(has)
                        VStack(alignment: .leading, spacing: layout.labelGap) { imageButtons(has) }
                    }
                }
            }
            note(has ? "Transparent images bounce off their visible edges; opaque ones show as a card."
                     : "Choose an image — until then the DotStudio mark bounces.")
        }
    }

    private func thumbnail(_ has: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        return ZStack {
            shape.fill(Color.primary.opacity(0.06))
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Space.xs)
            } else {
                Image(systemName: "photo")
                    .textRole(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbHeight * 1.4, height: thumbHeight)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityLabel(has ? "Logo image" : "No logo image")
    }

    @ViewBuilder private func imageButtons(_ has: Bool) -> some View {
        Button { choosing = true } label: {
            ScaledControlLabel(title: has ? "Replace…" : "Choose Image…", role: .inspectorSmallControl)
        }
        .help("Choose a logo image (PNG with transparency works best, or JPEG, HEIC, SVG, PDF)")
        .adaptiveControlSize(.small)
        .fixedSize()
        if has {
            Button { effect.logoFile = nil } label: {
                ScaledControlLabel(title: "Remove", role: .inspectorSmallControl)
            }
            .help("Remove the image (the DotStudio mark bounces until you choose another)")
            .adaptiveControlSize(.small)
            .fixedSize()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textRole(.caption).foregroundStyle(.secondary)
            .wrapping()
    }

    /// The chosen image, small, off the main thread.
    private func loadThumb() async {
        guard let name = effect.logoFile,
              let url = BounceLogo.fileURL(name, mediaDir: model.store.mediaDir) else { thumb = nil; return }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
            else { return NSImage(contentsOf: url) }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if effect.logoFile == name { thumb = img }
    }
}

/// The inspector's pop-up: the same capsule track as `SegmentedChoice` (fills, height, `.body`
/// title that follows the text size), spanning the control column, with the up-down chevrons
/// of a pop-up — so a Frame rate or a Layout menu sits in the panel like its other controls
/// rather than as a stock white box. The menu itself is the stock checkmarked list.
struct InspectorMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @ScaledLength(relativeTo: .body) private var height: CGFloat = InspectorMetrics.segmentHeight

    var body: some View {
        let current = options.first { $0.value == selection }?.title ?? ""
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Space.xs) {
                Text(current)
                    .textRole(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .textRole(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, height / 2)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(shape.fill(Color.primary.opacity(0.078)))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help("\(title): \(current)")
        .accessibilityLabel(title)
        .accessibilityValue(current)
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
        let _ = Perf.body("ParamRow")
        InspectorRow(label: spec.label) {
            if let options = spec.options {
                InspectorMenu(title: spec.label,
                              selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) }),
                              options: options.enumerated().map { ($0.element, $0.offset) })
            } else if spec.isToggle {
                Toggle(spec.label, isOn: Binding(get: { value > 0.5 }, set: { value = $0 ? 1 : 0 }))
                    .labelsHidden()
                    .adaptiveControlSize(.small)
            } else {
                HStack(spacing: layout.controlGap) {
                    Group {
                        if spec.step > 0 {
                            Slider(value: $value, in: spec.min...spec.max, step: spec.step)
                        } else {
                            Slider(value: $value, in: spec.min...spec.max)
                        }
                    }
                    // The row's label is a separate Text: name the slider and speak its readout.
                    .accessibilityLabel(spec.label)
                    .accessibilityValue(formatted)
                    HStack(spacing: layout.labelGap) {
                        Text(formatted)
                            .textRole(.value).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: valueColumn, alignment: .trailing)
                        // Every slider row has its reset in the same slot, so the value column
                        // and the row's right edge line up whatever has been changed; at the
                        // default it is a faint, disabled glyph.
                        let isDefault = abs(value - spec.def) <= 1e-6
                        Button { value = spec.def } label: {
                            Image(systemName: "arrow.counterclockwise").textRole(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .opacity(isDefault ? 0.3 : 1)
                        .disabled(isDefault)
                        .help(isDefault ? "At its default (\(format(spec.def)))" : "Reset to \(format(spec.def))")
                        .accessibilityLabel("Reset \(spec.label)")
                        .accessibilityValue(isDefault ? "At its default" : "Default \(format(spec.def))")
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

    /// Narrowest a picker cell gets (at the default text size) before the grid drops a
    /// column: three columns in the 430-pt popover, and still two in the onboarding canvas
    /// at accessibility sizes.
    private static let cellMinWidth: CGFloat = 104

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
                                // A small grid: cells an item gap apart both ways, so a
                                // category's rows sit clearly closer than the categories
                                // (sectionGap) — the gallery's grid gaps are for big tiles.
                                LazyVGrid(columns: layout.columns(minimum: Self.cellMinWidth, spacing: layout.itemGap),
                                          alignment: .leading, spacing: layout.itemGap) {
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

/// The one source every Look restyles. Used in the editor's Source tab, the library's
/// Source popover and onboarding.
///
/// `isLayoutRoot`: a popover or canvas column is narrow whatever the window's width class
/// is, so by default the editor measures its own width (`.adaptiveLayout()`) and lays out
/// for that — its rows stack and its gaps tighten like any narrow column's. The editor's
/// Source tab passes false to share the inspector's metrics with the Effects tab.
struct SourceEditor: View {
    @Binding var source: SourceSpec
    @ObservedObject var model: AppModel
    var isLayoutRoot = true

    var body: some View {
        if isLayoutRoot {
            SourceEditorContent(source: $source, model: model).adaptiveLayout()
        } else {
            SourceEditorContent(source: $source, model: model)
        }
    }
}

private struct SourceEditorContent: View {
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

            SegmentedChoice(title: "Kind", selection: $source.kind,
                            options: [("Slideshow", .collection), ("Photo", .image),
                                      ("Video", .video), ("Gradient", .gradient)])

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
                // Always the column's full width at 16:10 (fixed vertically, so a host that
                // runs short of height never shrinks it into a narrower thumbnail).
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .fixedSize(horizontal: false, vertical: true)
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
            VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
                ParamRow(spec: ParamSpec("hold", "Seconds Each", 6, 120, def: SourceSpec.defaultSlideSeconds),
                         value: Binding(get: { source.slideInterval }, set: { source.slideSeconds = $0 }))
                ParamRow(spec: ParamSpec("motion", "Pan & Zoom", 0, 1, def: SourceSpec.defaultMotion),
                         value: Binding(get: { source.motionAmount }, set: { source.motion = $0 }))
            }
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
                Button { importing = true } label: {
                    ScaledControlLabel(title: choose, role: .inspectorSmallControl)
                }
                .help(choose)
                if own {
                    Button { model.useBuiltInPhotos() } label: {
                        ScaledControlLabel(title: "Use Built-in Photos", role: .inspectorSmallControl)
                    }
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
        VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
            ColorWellsRow(wells: [.init(title: "From", color: colorBinding(\.colorA)),
                                  .init(title: "To", color: colorBinding(\.colorB))]) {
                Button {
                    let a = source.colorA; source.colorA = source.colorB; source.colorB = a
                } label: {
                    Image(systemName: "arrow.left.arrow.right").textRole(.callout)
                }
                .buttonStyle(.borderless)
                .help("Swap colors")
                .accessibilityLabel("Swap colors")
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
                SegmentedChoice(title: "Scaling", selection: $source.fillMode,
                                options: [("Fill", 1), ("Fit", 0), ("Stretch", 2)])
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
