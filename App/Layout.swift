//  Layout.swift — DotStudio's one layout system: spacing, radii, grid and card metrics,
//  and text roles. Views read these instead of hard-coding numbers, so gaps stay even
//  and everything scales together — with the window AND with the text size.
//
//  Cheat sheet
//  ───────────
//    @Environment(\.layout) private var layout            // window-aware metrics
//    .padding(.horizontal, layout.pagePadding)             // page edges
//    VStack(spacing: layout.itemGap) { … }                 // rows inside a card
//    .padding(layout.cardPadding).glassCard(cornerRadius: Radius.card)
//    LazyVGrid(columns: layout.tileColumns, spacing: layout.gridRowGap)
//    .frame(width: layout.sideCardWidth)                   // flexible range, never a fixed text width
//    Text(title).textRole(.sectionTitle)                   // scales with text size
//    Text(name).textRole(.itemTitle).truncating(name)      // 1 line, "…", full name as tooltip
//    Text(blurb).textRole(.callout).wrapping()             // every line shown, grows downward
//    ReflowStack { buttons }                               // one row if it fits, else a column
//    AdaptiveStack { hero; details }                       // side by side unless compact / huge text
//    FlowLayout { chips }                                  // wraps onto as many lines as needed
//    @ScaledLength(relativeTo: .body) private var column: CGFloat = 92   // macOS-safe @ScaledMetric
//
//  The three axes
//  ──────────────
//   • Width → `WidthClass`: .compact (< 1000 pt) · .regular · .wide (> 1600 pt), measured
//     once per window / sheet / popover root by `.adaptiveLayout()` and published as
//     `\.layout`. Wired: ContentView (main window), the onboarding sheet, Settings. A
//     popover that wants its own class adds `.adaptiveLayout()` to its content.
//     Views never measure the window themselves.
//   • Text size → `\.dynamicTypeSize`. On macOS, SwiftUI's text styles AND @ScaledMetric
//     IGNORE it (verified on the macOS 27 SDK: `.body` is 13 pt and a @ScaledMetric of
//     100 stays 100 at every size, .xSmall … .accessibility5). So text goes through
//     `.textRole(_:)` / `Font.scaled(…)` and fixed design numbers through `@ScaledLength`,
//     which do follow it. At the default size (.large) a role IS the stock SwiftUI text
//     style, so adopting roles changes nothing until the size changes. Stock controls
//     (Button, Toggle, Picker labels) never scale on macOS — use `.adaptiveControlSize()`.
//   • The 4-pt grid (`Space`). Page-level spacing follows the width class only;
//     component spacing (inside cards and rows) also grows gently with the text size.

import SwiftUI
import AppKit

// MARK: - Spacing

/// The 4-pt spacing scale. Every padding and stack spacing comes from here or from a
/// `LayoutMetrics` semantic alias; `Space.grid(n)` covers the rare in-between step.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// `n` steps of the 4-pt grid (5 → 20).
    static func grid(_ n: Int) -> CGFloat { CGFloat(n) * 4 }

    /// Puts a computed length back on the grid: 4-pt steps from 8 up, 2-pt below, so a
    /// 4-pt gap doesn't jump straight to 8 at the first larger text size.
    static func snap(_ v: CGFloat) -> CGFloat {
        guard v > 0 else { return 0 }
        let step: CGFloat = v >= 8 ? 4 : 2
        return max(step, (v / step).rounded() * step)
    }
}

// MARK: - Radii

/// Corner radii, smallest to largest (all `.continuous`). A shape nested inside another
/// should be concentric: inset by `p` inside radius `r` → `Radius.concentric(r, inset: p)`.
enum Radius {
    /// Tiny inline swatches (menu thumbnails, the Source button's swatch).
    static let xs: CGFloat = 4
    /// Small thumbnails: playlist chips, effect swatches, picker cells.
    static let s: CGFloat = 8
    /// Inset panels and groups, small previews (wallpaper card preview, setup rows).
    static let m: CGFloat = 12
    /// Gallery tiles and the screensaver card's live preview.
    static let tile: CGFloat = 14
    /// The editor's big preview.
    static let l: CGFloat = 16
    /// Glass cards and the inspector.
    static let card: CGFloat = 24

    static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, xs) }
}

// MARK: - Width class

/// How much room the window (or sheet / popover) gives its content.
enum WidthClass: Int, Comparable, CaseIterable, CustomStringConvertible {
    /// < 1000 pt: the minimum 880-wide window, sheets, popovers. Stack and tighten.
    case compact
    /// 1000–1600 pt: a typical window.
    case regular
    /// > 1600 pt: a big or full-screen window. Breathe; don't just stretch.
    case wide

    static let compactBelow: CGFloat = 1000
    static let wideAbove: CGFloat = 1600

    init(width: CGFloat) {
        self = width < Self.compactBelow ? .compact : width > Self.wideAbove ? .wide : .regular
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var description: String {
        switch self {
        case .compact: return "compact"
        case .regular: return "regular"
        case .wide: return "wide"
        }
    }

    /// Picks a value per class.
    func pick<T>(_ compact: T, _ regular: T, _ wide: T) -> T {
        switch self {
        case .compact: return compact
        case .regular: return regular
        case .wide: return wide
        }
    }
}

// MARK: - Metrics

/// Semantic spacing and sizes for the current window width and text size. Read it with
/// `@Environment(\.layout) private var layout`; it changes only when the width class or
/// the text size does, so reading it is cheap.
struct LayoutMetrics: Equatable {
    var widthClass: WidthClass
    var typeSize: DynamicTypeSize

    init(widthClass: WidthClass = .regular, typeSize: DynamicTypeSize = .large) {
        self.widthClass = widthClass
        self.typeSize = typeSize
    }

    var isCompact: Bool { widthClass == .compact }
    var isWide: Bool { widthClass == .wide }

    /// Text is big enough that side-by-side groups should stack: any accessibility size,
    /// or a compact window at the largest standard sizes.
    var prefersStacking: Bool {
        typeSize.isAccessibilitySize || (widthClass == .compact && typeSize >= .xxxLarge)
    }

    /// How much component spacing grows with the text: half the text's own growth.
    var spaceScale: CGFloat { 1 + (TypeScale.factor(typeSize) - 1) / 2 }

    /// `v` grown with the text size and snapped to the 4-pt grid.
    func scaled(_ v: CGFloat) -> CGFloat { Space.snap(v * spaceScale) }

    // MARK: Page level (width only)

    /// Left/right (and top) inset of a page's content from the window edge.
    var pagePadding: CGFloat { widthClass.pick(Space.grid(5), Space.xl, Space.xxl) }          // 20 · 32 · 48
    /// Between major blocks of a page (destination cards ↔ filter bar ↔ grid sections).
    var sectionGap: CGFloat { widthClass.pick(Space.l, Space.xl, Space.grid(10)) }            // 24 · 32 · 40
    /// Widest a page's content gets before it centres with growing side margins.
    var contentMaxWidth: CGFloat { widthClass.pick(.infinity, 1400, 1760) }
    /// Widest a paragraph should run (comfortable line length), grown with the text.
    var readableWidth: CGFloat { scaled(widthClass.pick(520, 600, 640)) }

    // MARK: Component level (width + text size)

    /// Inside a card or panel, edge to content.
    var cardPadding: CGFloat { scaled(widthClass.pick(Space.m, Space.grid(5), Space.l)) }    // 16 · 20 · 24
    /// Between rows / groups inside a card.
    var itemGap: CGFloat { scaled(widthClass.pick(Space.s, Space.s, Space.m)) }              // 12 · 12 · 16
    /// Between neighbouring controls in a row (buttons, chips, pickers).
    var controlGap: CGFloat { scaled(widthClass.pick(Space.xs, Space.xs, Space.s)) }         // 8 · 8 · 12
    /// Between a label and its sublabel / caption (title ↔ subtitle).
    var labelGap: CGFloat { scaled(Space.xxs) }                                               // 4
    /// Between an icon and its text.
    var iconGap: CGFloat { scaled(Space.xs) }                                                 // 8

    // MARK: Grids

    /// Horizontal gap between grid tiles.
    var gridColumnGap: CGFloat { scaled(widthClass.pick(Space.m, Space.grid(5), Space.l)) } // 16 · 20 · 24
    /// Vertical gap between grid rows: a step more than the columns, since each tile
    /// already carries its label under the thumbnail.
    var gridRowGap: CGFloat { gridColumnGap + Space.xxs }
    /// Tile width range for the style gallery (thumbnail + name). Grows with the text so a
    /// name keeps roughly the same number of characters per line.
    var tileWidth: ClosedRange<CGFloat> {
        let r: ClosedRange<CGFloat> = widthClass.pick(200...280, 224...320, 264...360)
        return scaled(r.lowerBound)...scaled(r.upperBound)
    }
    /// The gallery grid's columns.
    var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: tileWidth.lowerBound, maximum: tileWidth.upperBound),
                  spacing: gridColumnGap, alignment: .top)]
    }
    /// Adaptive columns for smaller grids (picker cells, playlist editor). `minimum` is
    /// at the default text size and grows with it — instead of a fixed column count.
    func columns(minimum: CGFloat, maximum: CGFloat = .infinity, spacing: CGFloat? = nil) -> [GridItem] {
        let lo = scaled(minimum)
        return [GridItem(.adaptive(minimum: lo, maximum: max(lo, maximum)),
                         spacing: spacing ?? controlGap, alignment: .top)]
    }

    // MARK: Cards and panels — flexible ranges, never fixed widths for text containers

    /// A secondary card beside a primary one (the Wallpaper card next to the Screensaver card).
    var sideCardWidth: ClosedRange<CGFloat> {
        let r: ClosedRange<CGFloat> = widthClass.pick(248...288, 280...320, 300...360)
        return scaled(r.lowerBound)...scaled(r.upperBound)
    }
    /// The editor's inspector panel.
    var inspectorWidth: ClosedRange<CGFloat> {
        let r: ClosedRange<CGFloat> = widthClass.pick(296...320, 320...360, 344...400)
        return scaled(r.lowerBound)...scaled(r.upperBound)
    }
    /// A live preview inside a card (the Screensaver card's hero), 16:10.
    var heroWidth: ClosedRange<CGFloat> { widthClass.pick(CGFloat(200)...248, 240...300, 280...360) }
    /// Leading label column in parameter rows (slider label · slider · value).
    var formLabelWidth: CGFloat { scaled(92) }
    /// Popover content width for small editors (Source, playlist).
    var popoverWidth: ClosedRange<CGFloat> { scaled(300)...scaled(440) }
}

private struct LayoutMetricsKey: EnvironmentKey {
    static let defaultValue = LayoutMetrics()
}

extension EnvironmentValues {
    /// Window-aware layout metrics, published by `.adaptiveLayout()` at each root.
    var layout: LayoutMetrics {
        get { self[LayoutMetricsKey.self] }
        set { self[LayoutMetricsKey.self] = newValue }
    }
}

extension View {
    /// Measures this root's width and publishes `LayoutMetrics` (width class + text size)
    /// to everything inside. Apply once per window, sheet or popover root. Only a change of
    /// width CLASS re-renders readers — not every pixel of a live resize.
    func adaptiveLayout() -> some View { modifier(AdaptiveLayoutRoot()) }
}

private struct AdaptiveLayoutRoot: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var widthClass: WidthClass?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: WidthClass.self) { WidthClass(width: $0.size.width) } action: { widthClass = $0 }
            .environment(\.layout, LayoutMetrics(widthClass: widthClass ?? .regular, typeSize: typeSize))
    }
}

// MARK: - Text sizes

/// The text-size curve. macOS doesn't scale SwiftUI text styles with Dynamic Type, so the
/// app does it here, once.
enum TypeScale {
    /// Growth of body-size text at each size, relative to the default (.large): roughly
    /// iOS's Dynamic Type curve, gentler at the accessibility end (a Mac window has less
    /// room to give than a phone's scrolling column).
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.85
        case .small: return 0.9
        case .medium: return 0.95
        case .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        case .accessibility1: return 1.5
        case .accessibility2: return 1.75
        case .accessibility3: return 2
        case .accessibility4: return 2.25
        case .accessibility5: return 2.5
        @unknown default: return 1
        }
    }

    /// Growth for text whose default size is `points`: small text grows a little more,
    /// big titles much less — as Dynamic Type does — so the hierarchy holds at every size.
    static func factor(_ size: DynamicTypeSize, forPointSize points: CGFloat) -> CGFloat {
        let damping: CGFloat
        switch points {
        case ..<11.5: damping = 1.1
        case ..<14.5: damping = 1
        case ..<17.5: damping = 0.85
        case ..<22.5: damping = 0.7
        default: damping = 0.55
        }
        return max(0.5, 1 + (factor(size) - 1) * damping)
    }

    /// A font size of `points` (at the default text size) at `size`, to the half point.
    static func scaled(_ points: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
        (points * factor(size, forPointSize: points) * 2).rounded() / 2
    }

    /// A non-text length (icon box, label column, thumbnail) that tracks text of `style`.
    static func length(_ base: CGFloat, relativeTo style: Font.TextStyle, _ size: DynamicTypeSize) -> CGFloat {
        (base * factor(size, forPointSize: pointSize(style)) * 2).rounded() / 2
    }

    /// macOS's own size for a text style (13 for .body, 26 for .largeTitle, …).
    static func pointSize(_ style: Font.TextStyle) -> CGFloat { nsFont(style).pointSize }

    /// macOS's own weight for a text style (.headline is bold on the Mac).
    static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        nsFont(style).fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular
    }

    private static var fonts: [Font.TextStyle: NSFont] = [:]

    private static func nsFont(_ style: Font.TextStyle) -> NSFont {
        if let f = fonts[style] { return f }
        let ns: NSFont.TextStyle
        switch style {
        case .largeTitle: ns = .largeTitle
        case .title: ns = .title1
        case .title2: ns = .title2
        case .title3: ns = .title3
        case .headline: ns = .headline
        case .subheadline: ns = .subheadline
        case .body: ns = .body
        case .callout: ns = .callout
        case .footnote: ns = .footnote
        case .caption: ns = .caption1
        case .caption2: ns = .caption2
        default: ns = .body
        }
        let f = NSFont.preferredFont(forTextStyle: ns)
        fonts[style] = f
        return f
    }
}

extension Font {
    /// `style` at `size`. At the default size this IS the SwiftUI text style (identical
    /// rendering); otherwise the system font at the scaled point size.
    static func scaled(_ style: Font.TextStyle, _ size: DynamicTypeSize,
                       weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        if size == .large { return .system(style, design: design, weight: weight) }
        return .system(size: TypeScale.scaled(TypeScale.pointSize(style), size),
                       weight: weight ?? TypeScale.defaultWeight(style), design: design)
    }

    /// A fixed design size (pt at the default text size) that still follows the text size.
    /// Use only where a design truly needs a specific size (glyph badges, hero numbers).
    static func scaled(points: CGFloat, _ size: DynamicTypeSize,
                       weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        .system(size: TypeScale.scaled(points, size), weight: weight, design: design)
    }
}

/// A named role for a piece of text: a SwiftUI text style plus weight/tracking/case.
/// Apply with `.textRole(_:)`; it follows `\.dynamicTypeSize` (see the header note).
struct TextRole: Equatable {
    var style: Font.TextStyle
    var weight: Font.Weight? = nil
    var design: Font.Design? = nil
    /// A fixed design size (pt at the default text size) instead of the style's own size.
    /// It still scales. Prefer a style; use this only where the design needs it.
    var points: CGFloat? = nil
    var tracking: CGFloat = 0
    var uppercase = false
    var monospacedDigits = false

    /// The font at a given text size.
    func font(_ size: DynamicTypeSize) -> Font {
        var f: Font
        if let points {
            f = .scaled(points: points, size, weight: weight ?? .regular, design: design)
        } else {
            f = .scaled(style, size, weight: weight, design: design)
        }
        if monospacedDigits { f = f.monospacedDigit() }
        return f
    }

    func weight(_ w: Font.Weight) -> TextRole { var r = self; r.weight = w; return r }

    // Page structure
    /// Big page headers (onboarding steps). macOS .largeTitle = 26 pt.
    static let pageTitle = TextRole(style: .largeTitle, weight: .bold)
    /// The line under a page title.
    static let pageSubtitle = TextRole(style: .title3)
    /// Section headers in the gallery ("Scenes", "Looks", results).
    static let sectionTitle = TextRole(style: .title2, weight: .semibold)
    /// The main name inside a card ("what's playing" on the Screensaver card).
    static let cardTitle = TextRole(style: .title2, weight: .semibold)
    /// Small all-caps label over a card ("SCREENSAVER", "WALLPAPER").
    static let eyebrow = TextRole(style: .caption, weight: .semibold, tracking: 0.8, uppercase: true)
    /// Titles of panels, rows and empty states.
    static let headline = TextRole(style: .headline)
    /// A tile's or list item's name (13 pt semibold on the Mac).
    static let itemTitle = TextRole(style: .body, weight: .semibold)

    // Running text
    static let body = TextRole(style: .body)
    static let bodyEmphasis = TextRole(style: .body, weight: .medium)
    /// Secondary lines, subtitles, descriptions (12 pt).
    static let callout = TextRole(style: .callout)
    static let calloutEmphasis = TextRole(style: .callout, weight: .semibold)
    /// Help text under controls, metadata (10 pt).
    static let caption = TextRole(style: .caption)
    static let captionEmphasis = TextRole(style: .caption, weight: .semibold)
    static let caption2 = TextRole(style: .caption2)

    // Controls
    /// Chip and compact-control labels (12 pt medium).
    static let control = TextRole(style: .callout, weight: .medium)
    /// Badges over imagery (tile state badges).
    static let badge = TextRole(style: .caption, weight: .semibold)
    /// Numeric readouts beside sliders.
    static let value = TextRole(style: .caption, monospacedDigits: true)
}

extension View {
    /// Sets the font (and tracking/case) for a text role at the current text size.
    func textRole(_ role: TextRole) -> some View { modifier(TextRoleModifier(role: role)) }

    /// `font` built for the current text size — for one-off fonts:
    /// `.scaledFont { .scaled(points: 30, $0, weight: .light) }`.
    func scaledFont(_ make: @escaping (DynamicTypeSize) -> Font) -> some View {
        modifier(ScaledFontModifier(make: make))
    }

    /// Bumps stock controls a size step at larger text sizes (macOS never scales control
    /// labels itself): +1 from .xxLarge, +2 at accessibility sizes.
    func adaptiveControlSize(_ base: ControlSize = .regular) -> some View {
        modifier(AdaptiveControlSize(base: base))
    }
}

private struct TextRoleModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let role: TextRole

    func body(content: Content) -> some View {
        content
            .font(role.font(typeSize))
            .tracking(role.tracking)
            .textCase(role.uppercase ? .uppercase : nil)
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let make: (DynamicTypeSize) -> Font
    func body(content: Content) -> some View { content.font(make(typeSize)) }
}

private struct AdaptiveControlSize: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let base: ControlSize

    func body(content: Content) -> some View {
        let order: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        let steps = typeSize.isAccessibilitySize ? 2 : typeSize >= .xxLarge ? 1 : 0
        let i = order.firstIndex(of: base) ?? 2
        return content.controlSize(order[min(i + steps, order.count - 1)])
    }
}

/// `@ScaledMetric` for macOS: a design length that follows `\.dynamicTypeSize` in step
/// with text of `relativeTo` (`@ScaledMetric` itself never changes on the Mac).
///     @ScaledLength(relativeTo: .caption) private var badgeHeight: CGFloat = 21
@propertyWrapper
struct ScaledLength: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let base: CGFloat
    private let style: Font.TextStyle

    init(wrappedValue: CGFloat, relativeTo style: Font.TextStyle = .body) {
        base = wrappedValue
        self.style = style
    }

    var wrappedValue: CGFloat { TypeScale.length(base, relativeTo: style, typeSize) }
}

// MARK: - Text that wraps or truncates on purpose

extension View {
    /// Text that must be read in full: wraps onto as many lines as it needs and grows its
    /// container DOWNWARD (it never truncates, and never pushes siblings sideways).
    func wrapping(_ alignment: TextAlignment = .leading) -> some View {
        lineLimit(nil)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A label that may run out of room: at most `lines` lines, then an ellipsis — with
    /// the full text as a tooltip. `reservesSpace` keeps the height of `lines` lines even
    /// when the text is shorter, so neighbouring tiles' rows line up.
    /// Use `.middle` for file names, `.tail` for names and sentences.
    func truncating(_ fullText: String, lines: Int = 1, mode: Text.TruncationMode = .tail,
                    reservesSpace: Bool = false) -> some View {
        lineLimit(lines, reservesSpace: reservesSpace)
            .truncationMode(mode)
            .help(fullText)
    }

    /// A flexible width range: shrinks to `range.lowerBound`, grows to `upperBound`.
    func frame(width range: ClosedRange<CGFloat>, alignment: Alignment = .center) -> some View {
        frame(minWidth: range.lowerBound, idealWidth: range.upperBound,
              maxWidth: range.upperBound, alignment: alignment)
    }

    /// Caps a paragraph (or a column of them) at the comfortable reading width.
    func readableWidth(_ layout: LayoutMetrics, alignment: Alignment = .leading) -> some View {
        frame(maxWidth: layout.readableWidth, alignment: alignment)
    }
}

// MARK: - Reflow

/// One horizontal row when everything fits at its natural size; otherwise a column.
/// Decides by measuring (ViewThatFits), so it reacts to the real width and text size.
/// Note: the two arrangements are separate view trees — keep @State out of `content`
/// (pass bindings in) or it resets when the arrangement flips. For state-keeping
/// switching by width class, use `AdaptiveStack`.
struct ReflowStack<Content: View>: View {
    var rowAlignment: VerticalAlignment
    var columnAlignment: HorizontalAlignment
    var spacing: CGFloat?
    var content: Content

    init(rowAlignment: VerticalAlignment = .center, columnAlignment: HorizontalAlignment = .leading,
         spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.rowAlignment = rowAlignment
        self.columnAlignment = columnAlignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: rowAlignment, spacing: spacing) { content }
            VStack(alignment: columnAlignment, spacing: spacing) { content }
        }
    }
}

/// Side by side normally; stacked when `stack(layout)` says so (by default: compact
/// window at the largest text sizes, or any accessibility size). Children keep their
/// identity and @State when it switches.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.layout) private var layout
    var rowAlignment: VerticalAlignment
    var columnAlignment: HorizontalAlignment
    var spacing: CGFloat?
    var stack: (LayoutMetrics) -> Bool
    var content: Content

    init(rowAlignment: VerticalAlignment = .center, columnAlignment: HorizontalAlignment = .leading,
         spacing: CGFloat? = nil, stackWhen stack: @escaping (LayoutMetrics) -> Bool = { $0.prefersStacking },
         @ViewBuilder content: () -> Content) {
        self.rowAlignment = rowAlignment
        self.columnAlignment = columnAlignment
        self.spacing = spacing
        self.stack = stack
        self.content = content()
    }

    var body: some View {
        let arrangement = stack(layout)
            ? AnyLayout(VStackLayout(alignment: columnAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: rowAlignment, spacing: spacing))
        arrangement { content }
    }
}

/// Lays children out left to right and wraps onto new lines, like words in a paragraph
/// (chips, badges, a row of buttons). Each line is as tall as its tallest child; a child
/// wider than the whole width is offered the full width (so its text wraps inside it).
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.xs
    var lineSpacing: CGFloat = Space.xs
    /// .leading, .center or .trailing placement of each line.
    var alignment: HorizontalAlignment = .leading

    private struct Line { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func lines(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Line] {
        var out: [Line] = []
        var line = Line()
        for (i, sv) in subviews.enumerated() {
            var size = sv.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = sv.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let next = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty && next > maxWidth {
                out.append(line)
                line = Line(items: [(i, size)], width: size.width, height: size.height)
            } else {
                line.items.append((i, size))
                line.width = next
                line.height = max(line.height, size.height)
            }
        }
        if !line.items.isEmpty { out.append(line) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let ls = lines(maxWidth, subviews)
        let width = ls.map(\.width).max() ?? 0
        let height = ls.map(\.height).reduce(0, +) + CGFloat(max(ls.count - 1, 0)) * lineSpacing
        let fill = alignment != .leading && maxWidth.isFinite
        return CGSize(width: fill ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            var x = bounds.minX
            if alignment == .center { x += (bounds.width - line.width) / 2 }
            else if alignment == .trailing { x += bounds.width - line.width }
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                                           anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
