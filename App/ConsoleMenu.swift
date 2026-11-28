//  ConsoleMenu.swift — Retro's dropdown: every pop-up / pull-down menu a Retro user opens
//  (the decks' Playlist, Night, When, Music, Style and Displays keys, the header's New, the
//  editor's •••, the hover bar's "…", the inspector's pop-up keys, the rule editor, Settings)
//  drawn in the Retro language instead of as a stock AppKit menu (owner, 2026-11-27: "any
//  dropdown should be a custom dropdown not the native macOS one").
//
//  One list, two renderings. A menu's items are built ONCE, as data (`MenuEntry`, written
//  with `@MenuBuilder` like a ViewBuilder), and shown either
//    • natively — `NativeMenuItems` turns them back into the SwiftUI Buttons / Toggles /
//      Sections / Menus Classic always had (`ActionMenu` into an NSMenu), so Classic's menus
//      are exactly what they were; or
//    • as Retro's dropdown — `ConsoleMenuButton` (or `DropdownMenu`, which picks by
//      `\.console`) opens a panel under its control: the panel colour with a hairline edge,
//      the console text roles, section legends and hairline dividers, the checked row's mark
//      in signal orange, and a keycap-like face under the pointer / keyboard highlight.
//
//  How it runs (ConsoleMenuSession): like NSMenu, a modal tracking loop. The panel never
//  becomes key, so the window — or the popover — it opened from keeps its key status and
//  focus, and a transient popover (the When rules editor) doesn't close when a row is
//  clicked; every input event goes through the loop, so a click outside dismisses the menu
//  (and is swallowed, as a native menu does), ↑/↓ move, → / ← open and close a submenu,
//  ↩ / space choose, esc dismisses, typing selects by title, ⌘-shortcuts close it and then
//  run. The chosen item's action runs after the panel is gone — the same action as Classic.
//
//  Accessibility: the panel is an AXMenu of AXMenuItems (titles, enabled, the highlighted
//  item as selected, ✓ as the mark character, submenus as children), pressable from
//  VoiceOver. Text follows the app's text size (TextRole / @ScaledLength); light and dark
//  follow the window it opened from; Reduce Motion drops the fade-in.

import SwiftUI
import AppKit
import Combine

// MARK: - Items

/// One item of a menu, as data: a button (optionally checked, with a leading symbol, disabled
/// or destructive, with a key equivalent), a toggle, one choice of a picker, a submenu, a
/// titled section, a divider or a line of text.
struct MenuEntry {
    enum Kind {
        case action(() -> Void)
        /// Natively a Toggle (a checkmark item).
        case toggle(isOn: Bool, set: (Bool) -> Void)
        /// One option of a pop-up's picker (natively a checkmark item, like a Picker's).
        case choice(selected: Bool, pick: () -> Void)
        case submenu([MenuEntry])
        case section(title: String?, [MenuEntry])
        case divider
        /// A line of text (natively a disabled item).
        case note
    }

    var title: String
    var kind: Kind
    /// `.action` drawn checked (Classic: a checkmark Label, as the menus always drew it).
    var checked = false
    /// `.action`: the item's symbol while it isn't checked (Classic: the Label's image).
    var symbol: String? = nil
    var enabled = true
    var destructive = false
    var shortcut: KeyboardShortcut? = nil

    static func button(_ title: String, checked: Bool = false, symbol: String? = nil, enabled: Bool = true,
                       destructive: Bool = false, shortcut: KeyboardShortcut? = nil,
                       _ action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, kind: .action(action), checked: checked, symbol: symbol, enabled: enabled,
                  destructive: destructive, shortcut: shortcut)
    }
    static func toggle(_ title: String, isOn: Bool, enabled: Bool = true, _ set: @escaping (Bool) -> Void) -> MenuEntry {
        MenuEntry(title: title, kind: .toggle(isOn: isOn, set: set), enabled: enabled)
    }
    static func choice(_ title: String, selected: Bool, enabled: Bool = true, _ pick: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, kind: .choice(selected: selected, pick: pick), enabled: enabled)
    }
    static func submenu(_ title: String, enabled: Bool = true, @MenuBuilder _ items: () -> [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(items()), enabled: enabled)
    }
    static func submenu(_ title: String, items: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(items))
    }
    static func section(_ title: String? = nil, @MenuBuilder _ items: () -> [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title ?? "", kind: .section(title: title, items()))
    }
    static var divider: MenuEntry { MenuEntry(title: "", kind: .divider) }
    static func note(_ text: String) -> MenuEntry { MenuEntry(title: text, kind: .note, enabled: false) }

    /// Shown with a check (a checked button, a toggle that's on, the chosen option).
    var isChecked: Bool {
        switch kind {
        case .action: return checked
        case .toggle(let on, _): return on
        case .choice(let on, _): return on
        default: return false
        }
    }

    var isSubmenu: Bool { if case .submenu = kind { return true } else { return false } }

    /// The options of a pop-up, as choices (the chosen one checked).
    static func choices<Value: Hashable>(_ options: [(title: String, value: Value)], selection: Binding<Value>) -> [MenuEntry] {
        options.map { o in .choice(o.title, selected: o.value == selection.wrappedValue) { selection.wrappedValue = o.value } }
    }
}

/// Writes `[MenuEntry]` like a ViewBuilder: items, `if`, `if/else`, `for`, and lists.
@resultBuilder
enum MenuBuilder {
    static func buildExpression(_ e: MenuEntry) -> [MenuEntry] { [e] }
    static func buildExpression(_ e: [MenuEntry]) -> [MenuEntry] { e }
    static func buildBlock(_ parts: [MenuEntry]...) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [MenuEntry]?) -> [MenuEntry] { part ?? [] }
    static func buildEither(first: [MenuEntry]) -> [MenuEntry] { first }
    static func buildEither(second: [MenuEntry]) -> [MenuEntry] { second }
    static func buildArray(_ parts: [[MenuEntry]]) -> [MenuEntry] { parts.flatMap { $0 } }
    static func buildLimitedAvailability(_ part: [MenuEntry]) -> [MenuEntry] { part }
}

// MARK: - Native (Classic)

/// The entries as the SwiftUI menu items Classic always had: Buttons (a checkmark Label while
/// checked), Toggles, Sections, submenus, Dividers and Text — inside any Menu or context menu.
struct NativeMenuItems: View {
    let entries: [MenuEntry]
    init(_ entries: [MenuEntry]) { self.entries = entries }
    init(@MenuBuilder _ build: () -> [MenuEntry]) { entries = build() }

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in NativeMenuEntry(entry: e) }
    }
}

private struct NativeMenuEntry: View {
    let entry: MenuEntry

    var body: some View {
        switch entry.kind {
        case .action(let run):
            Button(role: entry.destructive ? .destructive : nil, action: run) { label }
                .disabled(!entry.enabled)
                .keyboardShortcut(entry.shortcut)
        case .toggle(let on, let set):
            Toggle(entry.title, isOn: Binding(get: { on }, set: set))
                .disabled(!entry.enabled)
        case .choice(let on, let pick):
            Toggle(entry.title, isOn: Binding(get: { on }, set: { _ in pick() }))
                .disabled(!entry.enabled)
        case .submenu(let items):
            Menu(entry.title) { NativeMenuItems(items) }
                .disabled(!entry.enabled)
        case .section(let title, let items):
            if let title {
                Section(title) { NativeMenuItems(items) }
            } else {
                Section { NativeMenuItems(items) }
            }
        case .divider:
            Divider()
        case .note:
            Text(entry.title)
        }
    }

    @ViewBuilder private var label: some View {
        if entry.checked {
            Label(entry.title, systemImage: "checkmark")
        } else if let symbol = entry.symbol {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }
}

// MARK: - Triggers

/// A menu in either look: Classic, a SwiftUI `Menu` over the entries (the stock menu, styled
/// by the call site's `.menuStyle` / `.buttonStyle`); Retro, a Button (the same button style)
/// that opens the Retro dropdown under itself. The items are written once, as `MenuEntry`s.
///     DropdownMenu { .button("Edit…") { … }; .divider; … } label: { PanelKeyLabel(…) }
struct DropdownMenu<Label: View>: View {
    @Environment(\.console) private var console
    var title: String?
    var edge: HorizontalEdge
    let entries: () -> [MenuEntry]
    let label: () -> Label

    init(title: String? = nil, edge: HorizontalEdge = .leading, @MenuBuilder entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping () -> Label) {
        self.title = title
        self.edge = edge
        self.entries = entries
        self.label = label
    }

    var body: some View {
        if console {
            ConsoleMenuButton(title: title, edge: edge, entries: entries, label: label)
        } else {
            Menu { NativeMenuItems(entries()) } label: { label() }
        }
    }
}

/// Retro: a Button that opens the dropdown under itself (aligned to its `edge`, at least as
/// wide as it). Its look is the call site's button style. While its menu is open the label
/// reads as hot (`\.panelKeyHot`: a deck key's value prints in signal).
struct ConsoleMenuButton<Label: View>: View {
    var title: String? = nil
    var edge: HorizontalEdge = .leading
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: () -> Label
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var anchor = MenuAnchor()

    init(title: String? = nil, edge: HorizontalEdge = .leading, @MenuBuilder entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping () -> Label) {
        self.title = title
        self.edge = edge
        self.entries = entries
        self.label = label
    }

    var body: some View {
        Button {
            ConsoleMenu.present(entries(), title: title, from: anchor, edge: edge, typeSize: typeSize)
        } label: {
            label().transformEnvironment(\.panelKeyHot) { if anchor.isOpen { $0 = true } }
        }
        .background(MenuAnchorView(anchor: anchor).accessibilityHidden(true))
        .accessibilityHint("Opens a menu")
    }
}

/// Where a dropdown hangs from: the control's view (its frame on screen), and whether its menu
/// is open now.
final class MenuAnchor: ObservableObject {
    weak var view: NSView?
    @Published var isOpen = false
}

/// A plain, click-through NSView behind a control, so the dropdown can find the control's frame
/// on screen (toolbar items and popovers are their own hosting views: SwiftUI's global
/// coordinates aren't the window's there). Never an AppKit control — nothing is measured.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    func makeNSView(context: Context) -> Spot {
        let v = Spot()
        anchor.view = v
        return v
    }

    func updateNSView(_ v: Spot, context: Context) { anchor.view = v }
}

// MARK: - The panel's model

/// A row of the panel: an item, a section's legend, a hairline, or a line of text.
enum ConsoleMenuRow {
    case item(MenuEntry)
    case header(String)
    case divider
    case note(String)

    var isDivider: Bool { if case .divider = self { return true } else { return false } }
    var entry: MenuEntry? { if case .item(let e) = self { return e } else { return nil } }
    var text: String {
        switch self {
        case .item(let e): return e.title
        case .header(let t), .note(let t): return t
        case .divider: return ""
        }
    }
}

/// One open menu (the root, or a submenu): its rows and what's highlighted. Keyboard
/// navigation and type-select live here (pure, so the self-test checks them headless).
@MainActor
final class ConsoleMenuState: ObservableObject {
    let title: String?
    let rows: [ConsoleMenuRow]
    @Published var highlighted: Int?
    @Published var pressed: Int?
    @Published var openSubmenu: Int?
    /// The highlighted row to scroll to (keyboard moves in a long list).
    @Published var scrollTarget: Int?
    /// Each row's frame and the panel's body, in its hosting view's coordinates (top-left).
    var rowFrames: [Int: CGRect] = [:]
    var bodyFrame: CGRect = .zero

    init(entries: [MenuEntry], title: String? = nil) {
        self.title = title
        rows = Self.flatten(entries)
    }

    /// Sections become their legend between hairlines; dividers never lead, trail or double;
    /// an empty section shows nothing.
    nonisolated static func flatten(_ entries: [MenuEntry]) -> [ConsoleMenuRow] {
        var out: [ConsoleMenuRow] = []
        func add(_ es: [MenuEntry]) {
            for e in es {
                switch e.kind {
                case .section(let title, let items):
                    let inner = flatten(items)
                    guard !inner.isEmpty else { continue }
                    out.append(.divider)
                    if let title, !title.isEmpty { out.append(.header(title)) }
                    out.append(contentsOf: inner)
                    out.append(.divider)
                case .divider: out.append(.divider)
                case .note: out.append(.note(e.title))
                default: out.append(.item(e))
                }
            }
        }
        add(entries)
        var rows: [ConsoleMenuRow] = []
        for r in out {
            if r.isDivider, rows.isEmpty || rows.last?.isDivider == true { continue }
            rows.append(r)
        }
        while rows.last?.isDivider == true { rows.removeLast() }
        return rows
    }

    func isSelectable(_ i: Int) -> Bool {
        guard rows.indices.contains(i), let e = rows[i].entry else { return false }
        return e.enabled
    }

    /// The first checked row (where a keyboard-opened pop-up starts, as a native one does).
    var checkedRow: Int? { rows.indices.first { isSelectable($0) && rows[$0].entry?.isChecked == true } }

    /// Highlight the next / previous selectable row, wrapping around (as a native menu).
    func move(_ step: Int) {
        guard rows.contains(where: { $0.entry?.enabled == true }) else { highlighted = nil; return }
        var i = highlighted ?? (step > 0 ? -1 : rows.count)
        for _ in 0..<rows.count {
            i = (i + step + rows.count) % rows.count
            if isSelectable(i) { highlighted = i; scrollTarget = i; return }
        }
    }

    func highlightFirst() { highlighted = nil; move(1) }
    func highlightLast() { highlighted = nil; move(-1) }

    /// Type-select: the first selectable row whose title starts with `prefix` (any case), from
    /// the highlighted one on. False when nothing matches.
    @discardableResult
    func typeSelect(_ prefix: String) -> Bool {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return false }
        let start = highlighted ?? 0
        // A new single letter moves past the current match; a longer prefix keeps it.
        let from = p.count == 1 ? start + 1 : start
        for k in 0..<rows.count {
            let i = (from + k) % rows.count
            if isSelectable(i), rows[i].text.lowercased().hasPrefix(p) { highlighted = i; scrollTarget = i; return true }
        }
        return false
    }
}

// MARK: - The panel's look

enum ConsoleMenuMetrics {
    /// Room around the panel for its shadow (the panel window is this much bigger).
    static let margin: CGFloat = 14
    static let radius: CGFloat = HubMetrics.panelRadius
    /// Between the control and the panel's edge.
    static let gap: CGFloat = 4
    /// The widest a panel gets at the default text size (titles truncate past it).
    static let maxWidth: CGFloat = 380
}

enum ConsoleMenuInk {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light })
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    /// The checked row's mark: the signal orange — its deeper ink on the light panel (≥ 4.5:1
    /// on #F3F3EE), the bright signal on graphite.
    static let check = dynamic(rgb(0xB34B00), rgb(0xFF7300))
    /// A destructive item's title (Delete…, Remove): a red that holds ≥ 4.5:1 on either panel.
    static let destructive = dynamic(rgb(0xC0281B), rgb(0xFF7A6E))
}

/// One open menu, drawn: rows on the panel colour inside a hairline edge, with a soft shadow in
/// the margin around it. The rows (and the body) report their frames to the state, so the
/// tracking loop can hit-test them and VoiceOver can find them.
struct ConsoleMenuView: View {
    @ObservedObject var state: ConsoleMenuState
    /// The body's width (nil: its natural width, at least `minWidth`).
    var width: CGFloat? = nil
    var minWidth: CGFloat? = nil
    /// UIShots: the widest it gets (titles truncate past it), as a session caps it.
    var maxWidth: CGFloat? = nil
    /// Rows taller than this scroll.
    var maxBodyHeight: CGFloat? = nil
    /// UIShots: the row a submenu hangs from (aligned with `.consoleMenuRow`).
    var alignRow: Int? = nil
    /// UIShots: align this panel's first item with `.consoleMenuRow`.
    var alignFirstItem = false
    @Environment(\.colorScheme) private var scheme
    @ScaledLength(relativeTo: .body) private var inset: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ConsoleMenuMetrics.radius, style: .continuous)
        let dark = scheme == .dark
        Group {
            if let maxBodyHeight {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .frame(height: maxBodyHeight)
                        .onChange(of: state.scrollTarget) { _, t in if let t { proxy.scrollTo(t) } }
                }
            } else {
                rows
            }
        }
        .frame(minWidth: minWidth, maxWidth: maxWidth)
        .frame(width: width)
        .background(shape.fill(ConsoleInk.panel))
        .overlay(shape.strokeBorder(ConsoleInk.hairline, lineWidth: 1))
        .clipShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.bodyFrame = $0 }
        // a short contact shadow and a wide soft one: a sheet lifted off the chassis, not glass
        .shadow(color: .black.opacity(dark ? 0.45 : 0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(dark ? 0.5 : 0.16), radius: 9, y: 4)
        .padding(ConsoleMenuMetrics.margin)
        .accessibilityHidden(true)   // VoiceOver reads the panel's AXMenu (ConsoleMenuAXView)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.rows.indices, id: \.self) { i in
                row(i)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.rowFrames[i] = $0 }
                    .modifier(ConsoleMenuRowGuide(on: alignRow == i || (alignFirstItem && i == firstItem)))
                    .id(i)
            }
        }
        .padding(.vertical, inset)
    }

    private var firstItem: Int? { state.rows.firstIndex { $0.entry != nil } }

    @ViewBuilder private func row(_ i: Int) -> some View {
        switch state.rows[i] {
        case .item(let e):
            ConsoleMenuItemRow(entry: e, highlighted: state.highlighted == i, pressed: state.pressed == i,
                               submenuOpen: state.openSubmenu == i)
        case .header(let t):
            ConsoleMenuTextRow(text: t, header: true)
        case .note(let t):
            ConsoleMenuTextRow(text: t, header: false)
        case .divider:
            ConsoleHairline()
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
        }
    }
}

/// Sets `.consoleMenuRow` on the one row it's `on` for (a stack takes an explicit guide from
/// its children, so the others mustn't set one).
private struct ConsoleMenuRowGuide: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.alignmentGuide(.consoleMenuRow) { $0[.top] } } else { content }
    }
}

extension VerticalAlignment {
    private enum ConsoleMenuRowAlignment: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }
    /// UIShots: a submenu's first item level with the row it opened from.
    static let consoleMenuRow = VerticalAlignment(ConsoleMenuRowAlignment.self)
}

/// The check column and the title's leading edge, shared by items, legends and notes.
private enum ConsoleMenuRowMetrics {
    static let outerInset: CGFloat = 4     // a row's highlight inside the panel
    static let leading: CGFloat = 6        // inside the highlight, before the check column
    static let checkGap: CGFloat = 6
}

private struct ConsoleMenuItemRow: View {
    let entry: MenuEntry
    let highlighted: Bool
    let pressed: Bool
    let submenuOpen: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .body) private var height: CGFloat = 26
    @ScaledLength(relativeTo: .body) private var checkColumn: CGFloat = 14
    @ScaledLength(relativeTo: .body) private var glyph: CGFloat = 10.5

    var body: some View {
        let hot = (highlighted || submenuOpen) && entry.enabled
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let checked = entry.isChecked
        HStack(spacing: ConsoleMenuRowMetrics.checkGap) {
            ZStack {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: glyph, weight: .bold))
                        .foregroundStyle(ConsoleMenuInk.check)
                } else if let symbol = entry.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: glyph, weight: .medium))
                        .foregroundStyle(ConsoleInk.legend)
                }
            }
            .frame(width: checkColumn)
            Text(entry.title)
                .textRole(checked ? .consoleMenuChecked : .consoleBody)
                .foregroundStyle(entry.destructive ? ConsoleMenuInk.destructive : hot ? ConsoleInk.signalInk : ConsoleInk.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.m)
            if let s = entry.shortcut {
                Text(s.menuGlyphs)
                    .textRole(.consoleCaption)
                    .foregroundStyle(ConsoleInk.legend)
                    .fixedSize()
            }
            if entry.isSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: glyph - 1, weight: .semibold))
                    .foregroundStyle(hot ? ConsoleInk.signalInk : ConsoleInk.legend)
            }
        }
        .padding(.leading, ConsoleMenuRowMetrics.leading)
        .padding(.trailing, Space.xs + 2)
        .frame(minHeight: height)
        .offset(y: pressed && !reduceMotion ? 0.75 : 0)
        .background {
            if hot {
                // the keycap's face under the pointer (ConsoleKeyLight): grey face, its wash,
                // the orange hover edge; pressed, the shade inside it
                shape.fill(ConsoleInk.keyFace)
                    .overlay(shape.fill(ConsoleKeyLight.wash(.plain, dark: dark)))
                    .overlay(shape.fill(Color.clear.shadow(.inner(color: ConsoleKeyLight.pressShade(dark: dark, down: pressed), radius: 1, y: 1))))
                    .overlay(shape.strokeBorder(ConsoleKeyLight.edge(hovering: true, dark: dark), lineWidth: ConsoleKeyLight.hoverEdgeWidth))
            } else if checked {
                // the chosen row: a faint wash of the signal
                shape.fill(ConsoleInk.signal.opacity(dark ? 0.12 : 0.09))
            }
        }
        .padding(.horizontal, ConsoleMenuRowMetrics.outerInset)
        .opacity(entry.enabled ? 1 : 0.42)
        .contentShape(Rectangle())
    }
}

/// A section's legend (mono-caps, as the decks' row legends) or a line of text.
private struct ConsoleMenuTextRow: View {
    let text: String
    let header: Bool
    @ScaledLength(relativeTo: .body) private var checkColumn: CGFloat = 14

    var body: some View {
        Text(text)
            .textRole(header ? .legend : .consoleBodySmall)
            .foregroundStyle(ConsoleInk.legend)
            .lineLimit(header ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, ConsoleMenuRowMetrics.outerInset + ConsoleMenuRowMetrics.leading + checkColumn
                     + ConsoleMenuRowMetrics.checkGap)
            .padding(.trailing, Space.s)
            .padding(.top, header ? Space.xxs + 2 : Space.xxs)
            .padding(.bottom, header ? 3 : Space.xxs)
    }
}

extension TextRole {
    /// The chosen item's title in a Retro dropdown: the body face a step heavier.
    static let consoleMenuChecked = TextRole(style: .body, points: 13, face: ConsoleFace.textMedium)
}

extension KeyboardShortcut {
    /// "⇧⌘N", as a menu prints its key equivalent.
    var menuGlyphs: String {
        var s = ""
        if modifiers.contains(.control) { s += "\u{2303}" }
        if modifiers.contains(.option) { s += "\u{2325}" }
        if modifiers.contains(.shift) { s += "\u{21E7}" }
        if modifiers.contains(.command) { s += "\u{2318}" }
        switch key.character {
        case "\r": s += "\u{21A9}"
        case "\u{1B}": s += "\u{238B}"
        case "\t": s += "\u{21E5}"
        case " ": s += "Space"
        case "\u{7F}", "\u{8}": s += "\u{232B}"
        default: s += String(key.character).uppercased()
        }
        return s
    }
}

/// UIShots: a dropdown as it opens — at least `minWidth` wide (its control's width), a row
/// highlighted as under the pointer, and optionally one submenu open beside it.
struct ConsoleMenuPreview: View {
    let entries: [MenuEntry]
    var minWidth: CGFloat = 0
    var highlight: Int? = nil
    /// The root row whose submenu is open (it shows highlighted), and the submenu's highlight.
    var submenu: Int? = nil
    var submenuHighlight: Int? = nil
    @ScaledLength(relativeTo: .body) private var cap: CGFloat = ConsoleMenuMetrics.maxWidth

    var body: some View {
        let root = ConsoleMenuState(entries: entries)
        root.highlighted = submenu ?? highlight
        root.openSubmenu = submenu
        let child: ConsoleMenuState? = submenu.flatMap { i in
            guard case .submenu(let items)? = root.rows[i].entry?.kind else { return nil }
            let s = ConsoleMenuState(entries: items)
            s.highlighted = submenuHighlight
            return s
        }
        return HStack(alignment: .consoleMenuRow, spacing: -2 * ConsoleMenuMetrics.margin + 2) {
            ConsoleMenuView(state: root, minWidth: minWidth, maxWidth: max(cap, minWidth), alignRow: submenu)
                .fixedSize()
            if let child {
                ConsoleMenuView(state: child, maxWidth: cap, alignFirstItem: true).fixedSize()
            }
        }
        .environment(\.console, true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Presenting

@MainActor
enum ConsoleMenu {
    /// The session on screen (one at a time).
    private(set) static var current: ConsoleMenuSession?

    /// Opens `entries` under the anchor's control (at the pointer without one). Starts on the
    /// next turn of the run loop, out of the Button's action.
    static func present(_ entries: [MenuEntry], title: String? = nil, from anchor: MenuAnchor?,
                        edge: HorizontalEdge = .leading, typeSize: DynamicTypeSize) {
        guard current == nil, !entries.isEmpty else { return }
        let window = anchor?.view?.window
        var rect = CGRect(origin: NSEvent.mouseLocation, size: .zero)
        if let v = anchor?.view, let window {
            rect = window.convertToScreen(v.convert(v.bounds, to: nil))
        }
        let keyboard = NSApp.currentEvent?.type == .keyDown
        let session = ConsoleMenuSession(entries: entries, title: title, anchorRect: rect, edge: edge,
                                         typeSize: typeSize,
                                         appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance,
                                         screen: window?.screen ?? NSScreen.main, keyboard: keyboard)
        session.anchor = anchor
        current = session
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated {
                session.prepare()
                session.runLoop()
                session.finish()
                current = nil
            }
        }
    }
}

/// One open dropdown: its panels (the root and any submenu), run as a modal tracking loop
/// like NSMenu's — see the file's header.
@MainActor
final class ConsoleMenuSession {
    struct Level {
        let state: ConsoleMenuState
        let panel: ConsoleMenuPanel
        let host: NSHostingView<AnyView>
        let ax: ConsoleMenuAXView
        var watch: AnyCancellable?
    }

    let rootEntries: [MenuEntry]
    let title: String?
    let anchorRect: CGRect
    let edge: HorizontalEdge
    let typeSize: DynamicTypeSize
    let appearance: NSAppearance?
    let screen: NSScreen?
    /// Self-test: panels are laid out but never ordered in.
    var headless = false
    weak var anchor: MenuAnchor?
    private(set) var levels: [Level] = []
    private(set) var done = false
    /// The chosen item's action, run once the panels are gone.
    private var chosen: (() -> Void)?
    /// A ⌘-key that closed the menu, re-posted for the app afterwards.
    private var repost: NSEvent?
    private var keyboard: Bool
    private var typed = ""
    private var typedAt = Date.distantPast
    private var pendingOpen: (level: Int, row: Int, at: Date)?
    private var pendingTrim: (level: Int, at: Date)?
    private var lastPoint: CGPoint?
    private static let wakeSubtype: Int16 = 0x4D45

    init(entries: [MenuEntry], title: String?, anchorRect: CGRect, edge: HorizontalEdge, typeSize: DynamicTypeSize,
         appearance: NSAppearance?, screen: NSScreen?, keyboard: Bool) {
        rootEntries = entries
        self.title = title
        self.anchorRect = anchorRect
        self.edge = edge
        self.typeSize = typeSize
        self.appearance = appearance
        self.screen = screen
        self.keyboard = keyboard
    }

    // MARK: Open / close

    /// Builds and shows the root panel under the control.
    func prepare() {
        anchor?.isOpen = true
        let level = makeLevel(rootEntries, title: title)
        let vis = visibleFrame
        let m = ConsoleMenuMetrics.margin
        let natural = level.host.fittingSize
        let maxW = TypeScale.length(ConsoleMenuMetrics.maxWidth, relativeTo: .body, typeSize)
        let bodyW = min(max(natural.width - 2 * m, anchorRect.width), maxW, vis.width)
        size(level, bodyWidth: bodyW, maxBodyHeight: nil)
        var bodyH = level.host.fittingSize.height - 2 * m
        let gap = ConsoleMenuMetrics.gap
        let below = anchorRect.minY - gap - vis.minY
        let above = vis.maxY - (anchorRect.maxY + gap)
        let up = bodyH > below && above > below
        let room = up ? above : below
        if bodyH > room {
            size(level, bodyWidth: bodyW, maxBodyHeight: max(room - 2 * rowsInset, 60))
            bodyH = level.host.fittingSize.height - 2 * m
        }
        var x = edge == .leading ? anchorRect.minX : anchorRect.maxX - bodyW
        x = min(max(x, vis.minX), vis.maxX - bodyW)
        let top = up ? anchorRect.maxY + gap + bodyH : anchorRect.minY - gap
        place(level, body: CGRect(x: x, y: top - bodyH, width: bodyW, height: bodyH))
        levels = [level]
        if keyboard { level.state.highlighted = level.state.checkedRow; if level.state.highlighted == nil { level.state.highlightFirst() } }
        show(level)
        NSAccessibility.post(element: level.ax, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))
        if !headless { NSCursor.arrow.set() }
    }

    /// Closes every panel, then runs the chosen action (and any ⌘-key that closed the menu).
    func finish() {
        for l in levels.reversed() { close(l) }
        levels = []
        anchor?.isOpen = false
        if let repost { NSApp.postEvent(repost, atStart: true) }
        let run = chosen
        chosen = nil
        run?()
    }

    private var visibleFrame: CGRect {
        if let s = screen, !headless { return s.visibleFrame }
        return anchorRect.insetBy(dx: -4000, dy: -4000)
    }

    private var rowsInset: CGFloat { TypeScale.length(4, relativeTo: .body, typeSize) }

    private func makeLevel(_ entries: [MenuEntry], title: String?) -> Level {
        let state = ConsoleMenuState(entries: entries, title: title)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let ax = ConsoleMenuAXView(frame: .zero)
        let panel = ConsoleMenuPanel(contentRect: CGRect(x: anchorRect.minX, y: anchorRect.minY - 100, width: 100, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = appearance
        panel.contentView = ax
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityElement(false)
        ax.addSubview(host)
        ax.session = self
        ax.state = state
        var level = Level(state: state, panel: panel, host: host, ax: ax)
        size(level, bodyWidth: nil, maxBodyHeight: nil)
        let notify = ax
        level.watch = state.$highlighted.dropFirst().removeDuplicates().sink { [weak notify] i in
            guard let notify else { return }
            DispatchQueue.main.async { notify.highlightChanged(to: i) }
        }
        return level
    }

    private func size(_ level: Level, bodyWidth: CGFloat?, maxBodyHeight: CGFloat?) {
        level.host.rootView = AnyView(
            ConsoleMenuView(state: level.state, width: bodyWidth, maxBodyHeight: maxBodyHeight)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.console, true))
    }

    /// The panel's frame for a body rect (the margin around it holds the shadow).
    private func place(_ level: Level, body: CGRect) {
        let frame = body.insetBy(dx: -ConsoleMenuMetrics.margin, dy: -ConsoleMenuMetrics.margin).integral
        level.panel.setFrame(frame, display: false)
        level.ax.frame = CGRect(origin: .zero, size: frame.size)
        level.host.frame = level.ax.bounds
        level.host.layoutSubtreeIfNeeded()
    }

    private func show(_ level: Level) {
        guard !headless else {
            // laid out (row frames reported) without ever ordering a window in
            level.host.layoutSubtreeIfNeeded()
            level.host.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return
        }
        let fade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        level.panel.alphaValue = fade ? 0 : 1
        level.panel.orderFrontRegardless()
        level.host.layoutSubtreeIfNeeded()
        if fade {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.09
                level.panel.animator().alphaValue = 1
            }
        }
    }

    private func close(_ level: Level) {
        level.panel.orderOut(nil)
        level.panel.contentView = nil
        NSAccessibility.post(element: level.ax, notification: NSAccessibility.Notification(rawValue: "AXMenuClosed"))
    }

    // MARK: Submenus

    func openSubmenu(level li: Int, row: Int, highlightFirst: Bool) {
        guard levels.indices.contains(li), case .submenu(let items)? = levels[li].state.rows[row].entry?.kind,
              levels[li].state.isSelectable(row) else { return }
        trim(to: li + 1)
        let parent = levels[li]
        parent.state.highlighted = row
        parent.state.openSubmenu = row
        let level = makeLevel(items, title: parent.state.rows[row].text)
        let vis = visibleFrame
        let m = ConsoleMenuMetrics.margin
        let natural = level.host.fittingSize
        let maxW = TypeScale.length(ConsoleMenuMetrics.maxWidth, relativeTo: .body, typeSize)
        let bodyW = min(natural.width - 2 * m, maxW, vis.width)
        size(level, bodyWidth: bodyW, maxBodyHeight: nil)
        var bodyH = level.host.fittingSize.height - 2 * m
        if bodyH > vis.height {
            size(level, bodyWidth: bodyW, maxBodyHeight: vis.height - 2 * rowsInset)
            bodyH = level.host.fittingSize.height - 2 * m
        }
        let parentBody = screenRect(parent.state.bodyFrame, in: parent)
        let rowRect = screenRect(parent.state.rowFrames[row] ?? .zero, in: parent)
        var x = parentBody.maxX + 1
        if x + bodyW > vis.maxX { x = parentBody.minX - bodyW - 1 }
        x = min(max(x, vis.minX), vis.maxX - bodyW)
        var top = rowRect.maxY + rowsInset
        top = min(max(top, vis.minY + bodyH), vis.maxY)
        place(level, body: CGRect(x: x, y: top - bodyH, width: bodyW, height: bodyH))
        levels.append(level)
        if highlightFirst { level.state.highlightFirst() }
        show(level)
        NSAccessibility.post(element: level.ax, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))
    }

    /// Keep the first `n` levels (closing the submenus past them).
    func trim(to n: Int) {
        guard n >= 1 else { return }
        while levels.count > n { close(levels.removeLast()) }
        levels[n - 1].state.openSubmenu = nil
    }

    // MARK: Geometry

    /// A rect in a level's hosting view (SwiftUI's global, top-left space) on screen.
    func screenRect(_ r: CGRect, in level: Level) -> CGRect {
        let h = level.host
        let local = h.isFlipped ? r : CGRect(x: r.minX, y: h.bounds.height - r.maxY, width: r.width, height: r.height)
        return level.panel.convertToScreen(h.convert(local, to: nil))
    }

    func rowScreenRect(level li: Int, row: Int) -> CGRect? {
        guard levels.indices.contains(li), let r = levels[li].state.rowFrames[row] else { return nil }
        return screenRect(r, in: levels[li])
    }

    /// The deepest level whose body holds `p`.
    private func level(at p: CGPoint) -> Int? {
        levels.indices.reversed().first { screenRect(levels[$0].state.bodyFrame, in: levels[$0]).contains(p) }
    }

    /// The row under `p` in level `li` (any kind), inside the body's visible part.
    private func row(at p: CGPoint, level li: Int) -> Int? {
        let l = levels[li]
        guard screenRect(l.state.bodyFrame, in: l).contains(p) else { return nil }
        return l.state.rows.indices.first { i in l.state.rowFrames[i].map { screenRect($0, in: l).contains(p) } ?? false }
    }

    // MARK: The loop

    /// Every input event goes through here until the menu closes.
    func runLoop() {
        while !done {
            let deadline = [pendingOpen?.at, pendingTrim?.at].compactMap { $0 }.min() ?? .distantFuture
            if let e = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                if ProcessInfo.processInfo.environment["DOTSTUDIO_MENU_TRACE"] != nil { print("event", e.type.rawValue, e.description.prefix(160)) }
                handle(e)
            }
            fireTimers(Date())
            if levels.isEmpty { done = true }
        }
    }

    func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let p = screenPoint(e)
            if let li = level(at: p) {
                if let r = row(at: p, level: li), levels[li].state.isSelectable(r) {
                    keyboard = false
                    trimForPointer(in: li, row: r)
                    levels[li].state.highlighted = r
                    if levels[li].state.rows[r].entry?.isSubmenu == true { openSubmenu(level: li, row: r, highlightFirst: false) }
                }
            } else {
                done = true   // outside: dismiss, and swallow the click (as a native menu)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let p = screenPoint(e)
            if let li = level(at: p), let r = row(at: p, level: li), levels[li].state.isSelectable(r),
               levels[li].state.rows[r].entry?.isSubmenu == false {
                activate(level: li, row: r)
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            hover(screenPoint(e))
        case .scrollWheel:
            let p = screenPoint(e)
            if let li = level(at: p) {
                levels[li].panel.sendEvent(e)
                hover(p)
            }
        case .keyDown:
            key(e)
        case .keyUp, .flagsChanged, .mouseEntered, .mouseExited, .cursorUpdate, .magnify, .swipe, .rotate,
             .beginGesture, .endGesture, .smartMagnify, .pressure, .directTouch, .gesture, .tabletPoint, .tabletProximity:
            break   // swallowed while the menu is up
        case .appKitDefined:
            if e.subtype == .applicationDeactivated { done = true }
            NSApp.sendEvent(e)
        case .applicationDefined where e.subtype.rawValue == Self.wakeSubtype:
            break
        default:
            NSApp.sendEvent(e)
        }
    }

    private func screenPoint(_ e: NSEvent) -> CGPoint {
        if let w = e.window { return w.convertPoint(toScreen: e.locationInWindow) }
        return e.locationInWindow
    }

    private func hover(_ p: CGPoint) {
        lastPoint = p
        guard let li = level(at: p) else {
            // outside: the deepest menu lets go of its highlight (parents keep the open row)
            if let last = levels.last, last.state.openSubmenu == nil, !keyboard { last.state.highlighted = nil }
            pendingOpen = nil
            return
        }
        keyboard = false
        if let t = pendingTrim, li > t.level { pendingTrim = nil }
        let st = levels[li].state
        let r = row(at: p, level: li).flatMap { st.isSelectable($0) ? $0 : nil }
        if levels.count > li + 1 {
            // a submenu is open from this menu: keep it a moment while the pointer crosses
            // other rows on its way there
            if r == st.openSubmenu { pendingTrim = nil } else if pendingTrim == nil { pendingTrim = (li, Date().addingTimeInterval(0.3)) }
            return
        }
        st.highlighted = r
        if let r, st.rows[r].entry?.isSubmenu == true {
            if pendingOpen?.row != r || pendingOpen?.level != li { pendingOpen = (li, r, Date().addingTimeInterval(0.15)) }
        } else {
            pendingOpen = nil
        }
    }

    /// A click in level `li` closes any submenu that isn't the clicked row's.
    private func trimForPointer(in li: Int, row: Int) {
        pendingTrim = nil
        if levels.count > li + 1, levels[li].state.openSubmenu != row { trim(to: li + 1) }
    }

    private func fireTimers(_ now: Date) {
        if let t = pendingTrim, now >= t.at {
            pendingTrim = nil
            if levels.count > t.level + 1 { trim(to: t.level + 1) }
            if let p = lastPoint { hover(p) }
        }
        if let o = pendingOpen, now >= o.at {
            pendingOpen = nil
            if levels.indices.contains(o.level), levels[o.level].state.highlighted == o.row, levels.count == o.level + 1 {
                openSubmenu(level: o.level, row: o.row, highlightFirst: false)
            }
        }
    }

    private func key(_ e: NSEvent) {
        guard let li = levels.indices.last else { done = true; return }
        let st = levels[li].state
        keyboard = true
        pendingOpen = nil
        pendingTrim = nil
        let mods = e.modifierFlags.intersection([.command, .control])
        if !mods.isEmpty {
            // a shortcut: close the menu, then let the app have it
            done = true
            if e.modifierFlags.contains(.command) { repost = e }
            return
        }
        switch e.keyCode {
        case 125: st.move(1)                                   // ↓
        case 126: st.move(-1)                                  // ↑
        case 115, 116: st.highlightFirst()                     // home, page up
        case 119, 121: st.highlightLast()                      // end, page down
        case 124:                                              // →
            if let h = st.highlighted, st.rows[h].entry?.isSubmenu == true { openSubmenu(level: li, row: h, highlightFirst: true) }
        case 123:                                              // ←
            if li > 0 { trim(to: li) }
        case 53:                                               // esc
            done = true
        case 36, 76:                                           // return, enter
            if let h = st.highlighted { activate(level: li, row: h) }
        case 49 where typed.isEmpty || Date().timeIntervalSince(typedAt) > 1:   // space
            if let h = st.highlighted { activate(level: li, row: h) }
        case 48:                                               // tab: nothing
            break
        default:
            guard let chars = e.charactersIgnoringModifiers, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return }
            if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
            typed += chars
            typedAt = Date()
            st.typeSelect(typed)
        }
    }

    /// Chooses row `row` of level `li`: a submenu opens; anything else closes the menu and runs.
    func activate(level li: Int, row: Int) {
        guard levels.indices.contains(li), levels[li].state.isSelectable(row),
              let e = levels[li].state.rows[row].entry else { return }
        let run: () -> Void
        switch e.kind {
        case .submenu:
            openSubmenu(level: li, row: row, highlightFirst: keyboard)
            return
        case .action(let a): run = a
        case .toggle(let on, let set): run = { set(!on) }
        case .choice(_, let pick): run = pick
        default: return
        }
        let st = levels[li].state
        st.highlighted = row
        st.pressed = row
        if !headless {
            // the row blinks down, as a native menu's does, before the menu goes
            let until = Date().addingTimeInterval(0.07)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
        }
        chosen = run
        done = true
    }

    /// VoiceOver pressed an item (outside any event): act, and wake the loop.
    func accessibilityPress(level li: Int, row: Int) -> Bool {
        guard levels.indices.contains(li), levels[li].state.isSelectable(row) else { return false }
        keyboard = true
        activate(level: li, row: row)
        wake()
        return true
    }

    func cancel() { done = true; wake() }

    func levelIndex(of ax: ConsoleMenuAXView) -> Int? { levels.firstIndex { $0.ax === ax } }

    private func wake() {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: Self.wakeSubtype, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Self-test: the AX view of each open level.
    var accessibilityMenus: [ConsoleMenuAXView] { levels.map(\.ax) }
}

/// The dropdown's window: borderless, transparent, above the app's windows and popovers,
/// never key or main (the loop does the input), out of the window cycle.
final class ConsoleMenuPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Accessibility

/// The panel's content view: an AXMenu whose children are its items (the SwiftUI drawing
/// under it is hidden from VoiceOver).
final class ConsoleMenuAXView: NSView {
    weak var session: ConsoleMenuSession?
    var state: ConsoleMenuState? { didSet { rebuild() } }
    private(set) var items: [ConsoleMenuItemAX] = []

    private func rebuild() {
        guard let state else { items = []; return }
        items = state.rows.indices.compactMap { i in
            if case .divider = state.rows[i] { return nil }
            return ConsoleMenuItemAX(owner: self, row: i)
        }
    }

    var levelIndex: Int? { session?.levelIndex(of: self) }

    func highlightChanged(to row: Int?) {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if let row, let item = items.first(where: { $0.row == row }) {
            NSAccessibility.post(element: item, notification: NSAccessibility.Notification(rawValue: "AXMenuItemSelected"))
            NSAccessibility.post(element: item, notification: .focusedUIElementChanged)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }
    override func accessibilityLabel() -> String? { state?.title }
    override func accessibilityChildren() -> [Any]? { items }
    override func accessibilityVisibleChildren() -> [Any]? { items }
    override func accessibilitySelectedChildren() -> [Any]? {
        guard let h = state?.highlighted else { return [] }
        return items.filter { $0.row == h }
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        items.first { $0.accessibilityFrame().contains(point) } ?? self
    }
    override func accessibilityPerformCancel() -> Bool { session?.cancel(); return true }
}

/// One item (or a section's legend, or a line of text — disabled items) in the AXMenu.
final class ConsoleMenuItemAX: NSAccessibilityElement {
    private weak var owner: ConsoleMenuAXView?
    let row: Int

    init(owner: ConsoleMenuAXView, row: Int) {
        self.owner = owner
        self.row = row
        super.init()
    }

    /// AppKit asks on the main thread; the menu's state lives there.
    private func main<T>(_ body: @MainActor () -> T) -> T { MainActor.assumeIsolated(body) }

    private var rowValue: ConsoleMenuRow? {
        main {
            guard let s = owner?.state, s.rows.indices.contains(row) else { return nil }
            return s.rows[row]
        }
    }
    var entry: MenuEntry? { rowValue?.entry }

    static let markChar = NSAccessibility.Attribute(rawValue: "AXMenuItemMarkChar")
    static let cmdChar = NSAccessibility.Attribute(rawValue: "AXMenuItemCmdChar")

    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityTitle() -> String? { rowValue?.text }
    override func accessibilityLabel() -> String? { rowValue?.text }
    override func isAccessibilityEnabled() -> Bool { main { owner?.state?.isSelectable(row) ?? false } }
    override func isAccessibilitySelected() -> Bool { main { owner?.state?.highlighted == row } }
    override func isAccessibilityFocused() -> Bool { main { owner?.state?.highlighted == row } }
    override func accessibilityParent() -> Any? { owner }
    override func accessibilityFrame() -> NSRect {
        main {
            guard let owner, let li = owner.levelIndex, let r = owner.session?.rowScreenRect(level: li, row: row) else { return .zero }
            return r
        }
    }
    /// A checked item says so (VoiceOver also reads AXMenuItemMarkChar, below).
    override func accessibilityValue() -> Any? { entry?.isChecked == true ? "checked" : nil }
    override func accessibilityHelp() -> String? {
        guard let e = entry else { return nil }
        if e.isSubmenu { return "Submenu" }
        return e.shortcut?.menuGlyphs
    }
    override func accessibilityChildren() -> [Any]? {
        // an open submenu is this item's child, as a native menu's
        main {
            guard let owner, let li = owner.levelIndex, owner.state?.openSubmenu == row,
                  let menus = owner.session?.accessibilityMenus, menus.count > li + 1 else { return nil }
            return [menus[li + 1]]
        }
    }
    override func accessibilityPerformPress() -> Bool {
        main {
            guard let owner, let li = owner.levelIndex else { return false }
            return owner.session?.accessibilityPress(level: li, row: row) ?? false
        }
    }
    override func accessibilityPerformPick() -> Bool { accessibilityPerformPress() }
    override func accessibilityPerformCancel() -> Bool { main { owner?.session?.cancel() }; return true }

    /// The mark character (✓) and command character, as AppKit's own menu items expose them.
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case Self.markChar: return entry?.isChecked == true ? "\u{2713}" : nil
        case Self.cmdChar: return entry?.shortcut.map { String($0.key.character).uppercased() }
        default: return super.accessibilityAttributeValue(attribute)
        }
    }
}

// MARK: - Self-test

/// DOTSTUDIO_MENU_SELFTEST=1 (with DOTSTUDIO_STORE_DIR): the dropdown's rows, keyboard,
/// type-select, mouse, submenus, dismissal and accessibility, driven headless — every panel
/// laid out offscreen and never ordered in; events are posted to the app's own queue. Exits.
enum ConsoleMenuSelfTest {
    nonisolated static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["DOTSTUDIO_MENU_SELFTEST"] != nil else { return }
        MainActor.assumeIsolated { run() }
    }

    @MainActor private static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        var log: [String] = []
        func entries() -> [MenuEntry] {
            [
                .button("Edit Playlist\u{2026}") { log.append("edit") },
                .section("Change Every") {
                    MenuEntry.button("Minute") { log.append("1") }
                    MenuEntry.button("5 min", checked: true) { log.append("5") }
                    MenuEntry.button("Hour", enabled: false) { log.append("60") }
                },
                .toggle("Shuffle", isOn: false) { log.append("shuffle=\($0)") },
                .divider,
                .submenu("New Scene") {
                    MenuEntry.button("Aurora") { log.append("aurora") }
                    MenuEntry.button("Bubbles") { log.append("bubbles") }
                },
                .note("Add styles to rotate between them"),
                .divider,
                .button("Delete\u{2026}", destructive: true, shortcut: KeyboardShortcut(.delete, modifiers: .command)) { log.append("delete") },
            ]
        }

        // Rows
        let s = ConsoleMenuState(entries: entries())
        let kinds = s.rows.map { r -> String in
            switch r { case .item(let e): return "i:\(e.title)"; case .header(let t): return "h:\(t)"; case .divider: return "-"; case .note: return "n" }
        }
        check(kinds == ["i:Edit Playlist\u{2026}", "-", "h:Change Every", "i:Minute", "i:5 min", "i:Hour", "-", "i:Shuffle", "-",
                        "i:New Scene", "n", "-", "i:Delete\u{2026}"], "rows: sections become legends between hairlines, no double dividers (\(kinds))")
        check(ConsoleMenuState.flatten([.divider, .section("Empty") { [MenuEntry]() }, .button("A") {}, .divider, .divider]).count == 1,
              "leading / trailing / doubled dividers and empty sections drop")
        check(s.checkedRow == 4, "the checked row is found (5 min)")
        s.move(1); check(s.highlighted == 0, "↓ from nothing: the first item")
        s.move(1); check(s.highlighted == 3, "↓ skips the divider and the legend")
        s.move(1); s.move(1); check(s.highlighted == 7, "↓ skips a disabled item (Hour)")
        s.move(1); s.move(1); check(s.highlighted == 12, "↓ skips the note")
        s.move(1); check(s.highlighted == 0, "↓ wraps to the top")
        s.move(-1); check(s.highlighted == 12, "↑ wraps to the bottom")
        s.highlighted = 0
        check(s.typeSelect("n") && s.highlighted == 9, "type-select: n → New Scene")
        check(s.typeSelect("sh") && s.highlighted == 7, "type-select: sh → Shuffle")
        check(!s.typeSelect("zz"), "type-select: no match leaves it")
        check(KeyboardShortcut("n", modifiers: [.shift, .command]).menuGlyphs == "\u{21E7}\u{2318}N", "key equivalent glyphs")

        // Sessions, headless
        let anchor = CGRect(x: -30000, y: -30000, width: 220, height: 28)
        func session(keyboard: Bool = false) -> ConsoleMenuSession {
            let x = ConsoleMenuSession(entries: entries(), title: "Playlist", anchorRect: anchor, edge: .leading,
                                       typeSize: .large, appearance: NSAppearance(named: .darkAqua), screen: nil,
                                       keyboard: keyboard)
            x.headless = true
            return x
        }
        func key(_ code: UInt16, _ chars: String = "", mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        func mouse(_ type: NSEvent.EventType, _ x: ConsoleMenuSession, level: Int, row: Int) -> NSEvent? {
            guard let r = x.rowScreenRect(level: level, row: row) else { return nil }
            return NSEvent.mouseEvent(with: type, location: CGPoint(x: r.midX, y: r.midY), modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func drive(_ x: ConsoleMenuSession, _ events: [NSEvent]) {
            for e in events { x.handle(e); if x.done { break } }
            x.finish()
        }

        var x = session()
        x.prepare()
        let body = x.levels.first.map { x.screenRect($0.state.bodyFrame, in: $0) } ?? .zero
        check(body.width >= anchor.width - 0.5 && abs(body.minX - anchor.minX) < 1, "the panel is at least as wide as its control, under its leading edge (\(body))")
        check(abs(body.maxY - (anchor.minY - ConsoleMenuMetrics.gap)) < 1.5, "the panel hangs just under the control")
        check(x.rowScreenRect(level: 0, row: 0).map { body.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false, "row frames land inside the panel")
        let ax = x.accessibilityMenus.first
        check(ax?.accessibilityRole() == .menu && ax?.accessibilityLabel() == "Playlist", "VoiceOver: the panel is an AXMenu named for its control")
        let axItems = ax?.items ?? []
        check(axItems.count == 9 && axItems.allSatisfy { $0.accessibilityRole() == .menuItem }, "VoiceOver: items, legends and the note are AXMenuItems (\(axItems.count))")
        check(axItems.first { $0.row == 4 }?.accessibilityAttributeValue(ConsoleMenuItemAX.markChar) as? String == "\u{2713}", "VoiceOver: the checked item carries ✓")
        check(axItems.first { $0.row == 5 }?.isAccessibilityEnabled() == false, "VoiceOver: a disabled item reads disabled")
        drive(x, [key(125), key(125), key(125), key(36)])
        check(log == ["5"], "keyboard: ↓↓↓ ↩ chooses 5 min (\(log))")

        log = []; x = session(keyboard: true); x.prepare()
        check(x.levels.first?.state.highlighted == 4, "opened from the keyboard: starts on the checked item")
        drive(x, [key(53)])
        check(log.isEmpty && x.levels.isEmpty, "esc closes without choosing")

        log = []; x = session(); x.prepare()
        drive(x, [key(1, "s"), key(36)])
        check(log == ["shuffle=true"], "type-select then ↩ toggles Shuffle (\(log))")
        log = []; x = session(); x.prepare()
        drive(x, [key(125), key(49, " ")])
        check(log == ["edit"], "space chooses the highlighted item (\(log))")

        log = []; x = session(); x.prepare()
        drive(x, [key(45, "n"), key(124), key(125), key(36)])
        check(log == ["bubbles"], "→ opens the submenu, ↓ ↩ chooses in it (\(log))")

        x = session(); x.prepare()
        var evs: [NSEvent] = [key(45, "n"), key(124)]
        for e in evs { x.handle(e) }
        check(x.levels.count == 2 && x.accessibilityMenus.count == 2, "a submenu is a second panel (and a second AXMenu)")
        check((x.accessibilityMenus[0].items.first { $0.row == 9 }?.accessibilityChildren()?.first as? ConsoleMenuAXView) === x.accessibilityMenus[1],
              "VoiceOver: the open submenu is its item's child")
        x.handle(key(123))
        check(x.levels.count == 1, "← closes the submenu")
        x.handle(key(53)); x.finish()

        log = []; x = session(); x.prepare()
        evs = [mouse(.mouseMoved, x, level: 0, row: 3), mouse(.leftMouseDown, x, level: 0, row: 3), mouse(.leftMouseUp, x, level: 0, row: 3)].compactMap { $0 }
        check(evs.count == 3, "mouse events built")
        x.handle(evs[0])
        check(x.levels.first?.state.highlighted == 3, "the pointer highlights the row under it")
        drive(x, Array(evs.dropFirst()))
        check(log == ["1"], "a click chooses Minute (\(log))")

        log = []; x = session(); x.prepare()
        if let d = mouse(.leftMouseDown, x, level: 0, row: 5), let u = mouse(.leftMouseUp, x, level: 0, row: 5) {
            x.handle(d); x.handle(u)
        }
        check(log.isEmpty && !x.done, "a click on a disabled item does nothing (the menu stays)")
        if let d = mouse(.leftMouseDown, x, level: 0, row: 9) { x.handle(d) }
        check(x.levels.count == 2, "a click on a submenu row opens it")
        if let d = mouse(.leftMouseDown, x, level: 1, row: 0), let u = mouse(.leftMouseUp, x, level: 1, row: 0) {
            drive(x, [d, u])
        }
        check(log == ["aurora"], "a click in the submenu chooses (\(log))")

        log = []; x = session(); x.prepare()
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: anchor.minX - 500, y: anchor.minY + 400), modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        drive(x, [outside])
        check(log.isEmpty && x.levels.isEmpty, "a click outside dismisses without choosing")

        log = []; x = session(); x.prepare()
        x.levels.first?.state.highlighted = 12
        check(x.accessibilityPress(level: 0, row: 12), "VoiceOver can press an item")
        x.finish()
        check(log == ["delete"], "…and it runs (\(log))")

        log = []; x = session(); x.prepare()
        drive(x, [key(51, "\u{7F}", mods: .command)])
        check(log.isEmpty && x.levels.isEmpty, "a ⌘-shortcut closes the menu")
        let next = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true)
        check(next?.keyCode == 51 && next?.modifierFlags.contains(.command) == true, "…and is re-posted for the app")

        // Real loop: events posted to the queue, the loop drains them and ends.
        log = []; x = session(); x.prepare()
        for e in [key(125), key(36)] { NSApp.postEvent(e, atStart: false) }
        x.runLoop(); x.finish()
        check(log == ["edit"], "the tracking loop takes posted events (\(log))")

        print(failures == 0 ? "menu self-test: PASS" : "menu self-test: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
