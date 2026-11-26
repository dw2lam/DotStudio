//  LibraryView.swift — the gallery: where styles play (destination cards), a pinned
//  glass filter bar, and every style as a tile.
//
//  Styles split into two kinds:
//    • Scenes — self-contained generative pieces (Universe, Black Hole…). Pick and go.
//    • Looks  — effect stacks that restyle the shared source (slideshow/photo/video/gradient).
//
//  Layout (all from Layout.swift): one page column — `pagePadding` from the window edges,
//  capped at `contentMaxWidth` and centred — shared by the cards, the filter bar and the
//  grid, so the cards' glass edges, the search field, the section titles and the tiles all
//  start (and end) on the same two lines. Blocks are `sectionGap` apart; a section header
//  sits `itemGap` above its tiles. The pinned filter bar's backing spans the whole window. A
//  big window gets more tiles, not bigger type.

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @ObservedObject private var roster = DisplayRoster.shared
    @Environment(\.console) private var console
    @State private var filter: GalleryFilter = DemoHooks.filter ?? .all
    @State private var query = DemoHooks.search ?? ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = Perf.body("LibraryView")
        // Re-read once a minute so "playing now" follows the rotation and the sun. (Music never
        // changes what plays: it's presented over the style.)
        TimelineView(.everyMinute) { _ in
            GalleryPage(state: GalleryState(model: model, wallpaperID: wallpaper.styleID,
                                            displays: DisplayLineup(model: model, displays: roster.displays,
                                                                    wallpaperShared: wallpaper.styleID,
                                                                    wallpaperPins: wallpaper.pins,
                                                                    synced: wallpaper.follows)),
                        filter: $filter, query: $query, searchFocused: $searchFocused)
        }
        .toolbar {
            if model.editingID == nil && console {
                consoleToolbar
            } else if model.editingID == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    UpdateReadyButton()
                    newMenu
                    MCPToolbarButton()      // connect an AI assistant (AIConnect.swift)
                    Button { model.openSettings() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings (⌘,)")
                }
            }
        }
        .modifier(HubToolbarBackground(console: console))
        .background {
            // ⌘F jumps to search; Esc in the field clears it.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0).allowsHitTesting(false)
                .disabled(model.editingID != nil)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var found = false
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                found = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "dotstudiopreset" else { return }
                    DispatchQueue.main.async { model.importPresets(from: [url]) }
                }
            }
            return found
        }
    }

    // MARK: Toolbar

    /// Console (the Stitch header strip): a hairline after the traffic lights, the orange
    /// light, "DotStudio" and the app's version on a tag; on the right, New / MCP / Settings as
    /// 32 pt square keys (no toolbar glass behind them). The window's own title is hidden while
    /// this shows (ContentView), so the name isn't printed twice.
    @ToolbarContentBuilder
    private var consoleToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HubWordmark()
        }
        .hubBareToolbarItem()
        // With the window's title hidden nothing pushes the keys right: a flexible space does.
        HubToolbarSpace()
        ToolbarItem(placement: .primaryAction) {
            HubUpdateKey()
        }
        .hubBareToolbarItem()
        ToolbarItem(placement: .primaryAction) {
            newMenu
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .hubHeaderKey()
        }
        .hubBareToolbarItem()
        ToolbarItem(placement: .primaryAction) {
            MCPToolbarButton()
                .hubHeaderKey()
        }
        .hubBareToolbarItem()
        ToolbarItem(placement: .primaryAction) {
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
            .hubHeaderKey()
        }
        .hubBareToolbarItem()
    }

    private var newMenu: some View {
        Menu {
            Button("New Look") { model.addPreset() }
            Menu("New Scene") {
                ForEach(EffectKind.allCases.filter { $0.isScene && !$0.isRetired }, id: \.self) { kind in
                    Button(kind.displayName) { model.addScene(kind) }
                }
            }
            Divider()
            Button("Add Built-in Styles") { model.addDemoPack() }
            Button("Import Style…") { model.importPresetsViaPanel() }
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("New Look or Scene, or import a style")
    }
}

/// The scrolling page: destination cards, the pinned filter bar, the grid.
private struct GalleryPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    let state: GalleryState
    @Binding var filter: GalleryFilter
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        let _ = Perf.body("GalleryPage")
        gallery(state)
    }

    /// Space above the cards, under the toolbar.
    private var topInset: CGFloat { layout.widthClass.pick(Space.m, Space.m, Space.l) }
    /// Between the page's blocks. Console's boxes sit close (owner: "keep sections closer"):
    /// each box carries its own padding, so a small gap is enough to separate them.
    private var blockGap: CGFloat { console ? layout.widthClass.pick(Space.s, Space.s, Space.m) : layout.sectionGap }

    private func gallery(_ state: GalleryState) -> some View {
        let matcher = StyleMatcher(filter: filter, query: query, playing: state.playingIDs)
        let ordered = displayOrder()
        let sections = sections(matcher, ordered: ordered)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                DestinationRow(state: state)
                    .pageColumn(layout)
                    .padding(.top, topInset)
                    .padding(.bottom, blockGap - FilterBar.verticalInset)

                Section {
                    grid(sections, state: state, matcher: matcher)
                        .pageColumn(layout)
                        .padding(.top, blockGap - FilterBar.verticalInset)
                        .padding(.bottom, Space.xxl)
                } header: {
                    FilterBar(filter: $filter, query: $query, searchFocused: searchFocused,
                              counts: counts(state))
                }
            }
        }
        .onAppear {
            // DOTSTUDIO_DEMO_SCROLL=<style name>: scroll that tile to the top (pinned-bar review).
            guard let name = ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_SCROLL"],
                  let id = model.library.presets.first(where: { $0.name == name })?.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        // Every first still renders in the background now, not on the main thread when a
        // scroll brings its tile into view (styles added later: when they arrive).
        .onAppear { prewarmStills() }
        .onChange(of: model.library.presets.count) { prewarmStills() }
        .coordinateSpace(name: FilterBar.space)
        .softScrollEdges()
        .motion(Motion.smooth, value: filter)
        .motion(Motion.smooth, value: query)
    }

    private func prewarmStills() {
        model.thumbnailer.prewarm(model.library.presets, source: model.library.source,
                                  music: model.library.musicSettings)
    }

    // MARK: Sections

    struct GallerySection: Identifiable {
        enum Kind { case scenes, looks, results }
        let kind: Kind
        let title: String
        let subtitle: String
        let presets: [Preset]
        /// The search a results section matched (Console prints it beside the count).
        var query = ""
        var id: Kind { kind }
    }

    /// Every style in gallery order: live styles lead (live weather, Golden Hour first, then
    /// live sky, then clocks), library order within a rank.
    private func displayOrder() -> [Preset] {
        let lib = model.library.presets
        let ranks = Dictionary(uniqueKeysWithValues: lib.map { ($0.id, LiveTraits.of($0).rank) })
        return lib.enumerated().sorted { a, b in
            let ra = ranks[a.element.id] ?? 3, rb = ranks[b.element.id] ?? 3
            return ra != rb ? ra < rb : a.offset < b.offset    // stable: library order within a rank
        }.map(\.element)
    }

    private func sections(_ matcher: StyleMatcher, ordered all: [Preset]) -> [GallerySection] {
        guard matcher.isFiltering else {
            return [
                GallerySection(kind: .scenes, title: "Scenes", subtitle: "",
                               presets: all.filter(\.isScene)),
                GallerySection(kind: .looks, title: "Looks", subtitle: "",
                               presets: all.filter { !$0.isScene }),
            ]
        }
        let hits = all.filter(matcher.matches)
        let noun = hits.count == 1 ? "style" : "styles"
        var title = filter == .all ? "Results" : filter.title
        if filter == .playing { title = "Playing" }
        let q = query.trimmingCharacters(in: .whitespaces)
        let subtitle = q.isEmpty ? "\(hits.count) \(noun)" : "\(hits.count) \(noun) matching “\(q)”"
        return [GallerySection(kind: .results, title: title, subtitle: subtitle, presets: hits, query: q)]
    }

    private func counts(_ state: GalleryState) -> [GalleryFilter: Int] {
        // Counts reflect the search, so chips say what you'd get.
        var out: [GalleryFilter: Int] = [:]
        for f in GalleryFilter.chips {
            let m = StyleMatcher(filter: f, query: query, playing: state.playingIDs)
            out[f] = model.library.presets.filter(m.matches).count
        }
        return out
    }

    /// Between grid rows. Console's pads are closed boxes (their labels inside), so rows sit
    /// one column gutter apart — a square grid; Classic tiles hang their label under the
    /// picture and take a step more (layout.gridRowGap).
    private var rowGap: CGFloat { console ? layout.gridColumnGap : layout.gridRowGap }

    @ViewBuilder
    private func grid(_ sections: [GallerySection], state: GalleryState, matcher: StyleMatcher) -> some View {
        if console {
            consoleModules(sections, state: state, matcher: matcher)
        } else {
            classicGrid(sections, state: state, matcher: matcher)
        }
    }

    /// Console: the page as a stack of boxed modules under the filter box — each section (its
    /// header at the top, its tiles under it) in its own panel, `sectionGap` apart, as the
    /// destination cards and the filter row are. The pads inside drop their own panel: the box
    /// is the surface, a pad only shows its edge under the pointer or when selected. The grid
    /// reaches a pad's inset (Space.xs) into the box's padding, so the pictures start on the
    /// same line as the header, the search well and the cards' contents (`cardPadding` in).
    @ViewBuilder
    private func consoleModules(_ sections: [GallerySection], state: GalleryState, matcher: StyleMatcher) -> some View {
        VStack(alignment: .leading, spacing: blockGap) {
            if sections.allSatisfy({ $0.presets.isEmpty }) && matcher.isFiltering {
                EmptyResults(filter: filter, query: query) {
                    Motion.run { query = ""; filter = .all }
                }
                .padding(layout.cardPadding)
                .consolePanel(cornerRadius: HubMetrics.panelRadius)
                .transition(.lift(reduceMotion: reduceMotion))
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        SectionHeader(section: section)
                        LazyVGrid(columns: consoleColumns, alignment: .leading, spacing: consolePadGap) {
                            tiles(section, state: state)
                        }
                        .padding(.horizontal, -Space.xs)
                        .padding(.bottom, -Space.xs)
                    }
                    .padding(layout.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .consolePanel(cornerRadius: HubMetrics.panelRadius)
                    .transition(.lift(reduceMotion: reduceMotion))
                }
            }
        }
    }

    /// Console pads carry a Space.xs inset of their own (their edge sits that far outside the
    /// picture), so the grid's gutter is the column gap less two insets: pictures stay one
    /// column gap apart, and two neighbouring edges never touch.
    private var consolePadGap: CGFloat { max(layout.gridColumnGap - 2 * Space.xs, Space.xxs) }

    private var consoleColumns: [GridItem] {
        [GridItem(.adaptive(minimum: layout.tileMinWidth), spacing: consolePadGap, alignment: .top)]
    }

    @ViewBuilder
    private func tiles(_ section: GallerySection, state: GalleryState) -> some View {
        ForEach(section.presets) { preset in
            StyleTile(model: model, preset: preset,
                      badges: state.badges(for: preset.id), lineup: state.lineup)
                .equatable()
                .id(preset.id)
                .transition(.lift(reduceMotion: reduceMotion))
        }
        switch section.kind {
        case .scenes: NewSceneTile()
        case .looks: NewTile(title: "New Look", symbol: "plus") { model.addPreset() }
        case .results: EmptyView()
        }
    }

    @ViewBuilder
    private func classicGrid(_ sections: [GallerySection], state: GalleryState, matcher: StyleMatcher) -> some View {
        if sections.allSatisfy({ $0.presets.isEmpty }) && matcher.isFiltering {
            EmptyResults(filter: filter, query: query) {
                Motion.run { query = ""; filter = .all }
            }
            .transition(.lift(reduceMotion: reduceMotion))
        } else {
            // One grid for every section, so a tile glides to its new place when the filter
            // changes. Columns are added as the window widens (layout.tileColumns).
            LazyVGrid(columns: layout.tileColumns, alignment: .leading, spacing: rowGap) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                    Section {
                        tiles(section, state: state)
                    } header: {
                        SectionHeader(section: section)
                            // The grid puts its row gap around every row, header rows too. Re-space
                            // the header so it sits sectionGap below the previous tiles and only
                            // itemGap above its own (closer to what it titles than to what it ends).
                            .padding(.top, i == 0 ? 0 : max(layout.sectionGap - rowGap, 0))
                            .padding(.bottom, layout.itemGap - rowGap)
                    }
                }
            }
        }
    }
}

private extension View {
    /// The page's content column: inset `pagePadding` from the window edges, at most
    /// `contentMaxWidth` wide, centred in wider windows.
    func pageColumn(_ layout: LayoutMetrics) -> some View {
        frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, layout.pagePadding)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .body) private var swatchWidth: CGFloat = 32
    @ScaledLength(relativeTo: .body) private var swatchHeight: CGFloat = 20
    @Environment(\.console) private var console
    let section: GalleryPage.GallerySection
    @State private var showSource = false

    /// Console (the Stitch "Scenes" header): the title in the display face, its real count in
    /// a mono legend beside it (and what a search matched), the Looks' Source key at the right.
    private var consoleHeader: some View {
        let n = section.presets.count
        let q = section.query.isEmpty ? nil : "matching \u{201C}\(section.query)\u{201D}"
        let titles = HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(section.title)
                .textRole(.consoleHeadline)
                .foregroundStyle(ConsoleInk.ink)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Text("\(n) \(n == 1 ? "style" : "styles")")
                .textRole(.legend)
                .foregroundStyle(ConsoleInk.legend)
                .fixedSize()
                .contentTransition(.numericText())
            if let q {
                Text(q)
                    .textRole(.consoleValue)
                    .foregroundStyle(ConsoleInk.legend)
                    .truncating(q)
            }
        }
        return Group {
            if section.kind == .looks {
                // The Source key sits at the line's end when it fits, else under the title.
                ReflowStack(rowAlignment: .center, columnAlignment: .leading,
                            spacing: layout.itemGap, columnSpacing: layout.labelGap, spread: true) {
                    titles
                    consoleSourceButton
                }
            } else {
                titles.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var consoleSourceButton: some View {
        Button { showSource.toggle() } label: {
            HStack(spacing: Space.xs) {
                SourceSwatch(source: model.library.source)
                    .frame(width: swatchWidth * 0.75, height: swatchHeight * 0.7)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(ConsoleInk.hairline))
                HubKeyLabel(text: "Source: \(model.library.source.displayName)", trailingSymbol: "chevron.down")
            }
        }
        .buttonStyle(.keycap(padding: HubMetrics.smallKey))
        .fixedSize()
        .help("The slideshow, photo, video or gradient every Look restyles")
        .popover(isPresented: $showSource, arrowEdge: .bottom) {
            SourcePopover()
                .adaptiveLayout()   // the popover is its own root
        }
    }

    var body: some View {
        let _ = Perf.body("SectionHeader")
        if console {
            consoleHeader
        } else if section.kind == .looks {
            // The Source button sits on the title's line when it fits, else under the text.
            ReflowStack(rowAlignment: .firstTextBaseline, columnAlignment: .leading,
                        spacing: layout.controlGap * 2 + layout.itemGap, columnSpacing: layout.itemGap,
                        spread: true) {
                titles
                sourceButton
            }
        } else {
            titles
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: layout.labelGap) {
            Text(section.title)
                .textRole(.sectionTitle)
                .wrapping()
            if !section.subtitle.isEmpty {   // only search/filter results carry one (a count)
                Text(section.subtitle)
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
                    .contentTransition(.numericText())
            }
        }
        .readableWidth(layout)
    }

    private var sourceButton: some View {
        Button { showSource.toggle() } label: {
            HStack(spacing: layout.iconGap) {
                SourceSwatch(source: model.library.source)
                    .frame(width: swatchWidth, height: swatchHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                Text("Source: \(model.library.source.displayName)")
                    .textRole(.body)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .scaledFont { .scaled(.caption2, $0, weight: .semibold) }
                    .foregroundStyle(.secondary)
            }
        }
        .glassButton()
        .adaptiveControlSize()
        .fixedSize()
        .help("The slideshow, photo, video or gradient every Look restyles")
        .popover(isPresented: $showSource, arrowEdge: .bottom) {
            SourcePopover()
                .adaptiveLayout()   // the popover is its own root
        }
    }
}

/// The Source editor in a popover: card padding, and a width that grows with the text.
/// Console: on the panel colour (as the MCP popover), not the popover's material.
private struct SourcePopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console

    var body: some View {
        let range = layout.popoverWidth
        let editor = SourceEditor(source: model.sourceBinding, model: model)
            .padding(layout.cardPadding)
            .frame(width: min(max(layout.scaled(320), range.lowerBound), range.upperBound))
        if console {
            editor
                .background(ConsoleInk.panel)
                .presentationBackground(ConsoleInk.panel)
                .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
        } else {
            editor
        }
    }
}

// MARK: - Filter bar

/// Pinned under the toolbar: search + glass chips on ONE line. When the chips don't fit
/// beside the search field they scroll sideways, fading out at the edge that has more —
/// never wrapping onto a second, ragged row. At accessibility sizes the search field sits
/// over the chips. Tiles scroll beneath it.
private struct FilterBar: View {
    /// Coordinate space of the gallery's scroll viewport.
    static let space = "galleryScroll"
    /// Above and below the bar's content (part of the gap to the cards and to the grid).
    static let verticalInset = Space.xs
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @Binding var filter: GalleryFilter
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    let counts: [GalleryFilter: Int]
    @State private var chipsWidth: CGFloat = 0
    @State private var chipsViewport: CGFloat = 0
    @State private var chipFade = ChipEdgeFade()
    /// Coordinate space of the chips' own horizontal scroll view.
    private static let chipSpace = "filterChipsScroll"

    /// Narrower in compact windows, wider in wide ones; grows with the text.
    private var searchWidth: CGFloat {
        // Console: a step wider for its larger mono text (12 pt since 2026-11-26).
        layout.scaled(console ? layout.widthClass.pick(216, 264, 304) : layout.widthClass.pick(208, 240, 288))
    }

    private var chips: some View {
        HStack(spacing: layout.controlGap) {
            ForEach(GalleryFilter.chips) { f in
                let n = counts[f] ?? 0
                if f.alwaysShown || n > 0 || filter == f {
                    FilterChip(filter: f, count: f == .all ? nil : n,
                               selected: filter == f) {
                        Motion.run { filter = f }
                    }
                }
            }
        }
    }

    var body: some View {
        let _ = Perf.body("FilterBar")
        AdaptiveStack(rowAlignment: .top, columnAlignment: .leading, spacing: layout.itemGap) {
            // The full prompt where it fits; a compact field says less rather than clip it.
            SearchField(text: $query, prompt: layout.isCompact && !layout.prefersStacking
                            ? "Search styles" : "Search styles, effects, packs",
                        focus: searchFocused)
                // Over the chips (large text), it can be as wide as a comfortable line.
                .frame(width: layout.prefersStacking ? layout.readableWidth : searchWidth)
                .onExitCommand { query = ""; searchFocused.wrappedValue = false }
            // Always the same scroll view (never swapped in and out by measuring — see
            // ReflowStack); it only scrolls, and fades its edge, when the chips overflow.
            let overflows = chipsWidth > chipsViewport + 0.5
            ScrollView(.horizontal, showsIndicators: false) {
                chips
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsWidth = $0 }
                    .padding(.vertical, Self.verticalInset)            // room for the hover lift
                    .padding(.trailing, overflows ? ChipEdgeFade.width : 0)   // the last chip clears the fade
                    // Where the row is scrolled to, as the two fades' strengths (quantized, so a
                    // scroll through the middle changes nothing and re-renders nothing).
                    .onGeometryChange(for: ChipEdgeFade.self) { g in
                        ChipEdgeFade(offset: -g.frame(in: .named(Self.chipSpace)).minX, content: g.size.width,
                                     viewport: g.bounds(of: .named(Self.chipSpace))?.width ?? g.size.width)
                    } action: { chipFade = $0 }
            }
            .coordinateSpace(.named(Self.chipSpace))
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsViewport = $0 }
            .padding(.vertical, -Self.verticalInset)
            .noScrollEdgeEffects()
            .mask(chipFade.mask)
        }
        // Console: the filter row is a box of its own — a panel with the destination cards'
        // corners and inset, the search well `cardPadding` in (on the cards' content line).
        .modifier(ConsoleFilterBox(enabled: console, layout: layout))
        .pageColumn(layout)
        .padding(.vertical, Self.verticalInset)
        .background {
            // Once pinned, an opaque strip of the window's own colour (and a hairline under it)
            // keeps the chips legible over the tiles scrolling beneath — no blur, so nothing
            // is re-sampled per scroll frame. Driven by the bar's own position, so no parent
            // re-render. It spans the whole window, not just the page column.
            GeometryReader { g in
                let y = g.frame(in: .named(FilterBar.space)).minY
                let pinned = min(max((150 - y) / 70, 0), 1)   // fully there once under the toolbar
                if pinned > 0 {
                    (console ? ConsoleInk.chassis : Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .bottom) {
                            if console { Rectangle().fill(ConsoleInk.hairline).frame(height: 1) } else { Divider() }
                        }
                        .padding(.top, -(Space.xxl + Space.s))   // up under the toolbar
                        .opacity(pinned)
                }
            }
            .allowsHitTesting(false)
        }
    }

}

/// Console: the filter row's box. Classic passes the row through untouched.
private struct ConsoleFilterBox: ViewModifier {
    let enabled: Bool
    let layout: LayoutMetrics

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, layout.cardPadding)
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .consolePanel(cornerRadius: HubMetrics.panelRadius)
        } else {
            content
        }
    }
}

/// The filter chips' edge fades when the row overflows: a fixed width — the row's end
/// clearance, so the last chip sits just clear of it — each as strong as there is content
/// scrolled past its edge: none at the start on the leading side, none at the end on the
/// trailing one (the last chip is never left faded), ramping over the fade's own width in
/// between. Quantized to 1/16 steps, so scrolling through the middle changes nothing.
private struct ChipEdgeFade: Equatable {
    static let width: CGFloat = Space.l
    static let steps: CGFloat = 16
    /// 0 (a hard edge) … 1 (fully faded out at the edge).
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    init() {}

    /// `offset` how far the row is scrolled; `content` its width (end clearance included);
    /// `viewport` the scroll view's.
    init(offset: CGFloat, content: CGFloat, viewport: CGFloat) {
        let travel = max(content - viewport, 0)
        let scrolled = min(max(offset, 0), travel)          // a rubber-band overscroll counts as the end
        leading = Self.strength(scrolled)
        trailing = Self.strength(travel - scrolled)
    }

    /// The fade's strength for `beyond` points of content past an edge (0 within ¾ pt).
    static func strength(_ beyond: CGFloat) -> CGFloat {
        (min(max(beyond / width, 0), 1) * steps).rounded() / steps
    }

    var mask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(1 - leading), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .black.opacity(1 - trailing)], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
        }
    }
}

private struct FilterChip: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = GalleryControl.height
    @ScaledLength(relativeTo: .callout) private var consoleHeight: CGFloat = GalleryControl.consoleHeight
    let filter: GalleryFilter
    let count: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if console { key } else { chip }
    }

    /// Console (the Stitch filter keys): a keycap printing the filter and its count in mono
    /// caps — the selected one an orange key. VoiceOver hears the filter and its
    /// count; the selected trait says which is on.
    private var key: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Text(filter.title)
                if let count {
                    Text("\(count)")
                        .opacity(0.75)
                        .contentTransition(.numericText())
                }
            }
            .textRole(.consoleKey)
            .lineLimit(1)
            .frame(minHeight: consoleHeight - HubMetrics.keySkirt)
            .fixedSize()
        }
        .buttonStyle(.keycap(selected ? .signal : .plain,
                             padding: EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)))
        .accessibilityLabel(count.map { "\(filter.title), \($0)" } ?? filter.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var chip: some View {
        Button(action: action) {
            HStack(spacing: layout.labelGap) {
                Text(filter.title)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .textRole(selected ? TextRole.control.weight(.semibold) : .control)
            .lineLimit(1)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, layout.controlGap + Space.xxs)
            .frame(minHeight: height)
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Flat capsules: the selected one in the accent colour, the rest a quiet wash that
        // deepens under the pointer. No glass (it re-samples the page on every scroll frame).
        .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.05))))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Empty state

private struct EmptyResults: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .title3) private var iconCircle: CGFloat = 64
    let filter: GalleryFilter
    let query: String
    let reset: () -> Void

    /// Echoes a long query shortened in the middle; the full text is in the tooltip.
    private var shownQuery: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count > 40 else { return q }
        return "\(q.prefix(26))…\(q.suffix(13))"
    }

    private var symbol: String { query.isEmpty ? (filter.symbol ?? "square.grid.2x2") : "magnifyingglass" }
    private var headline: String { query.isEmpty ? "Nothing in \(filter.title) yet" : "No styles match “\(shownQuery)”" }
    private var message: String {
        query.isEmpty ? "Add Built-in Styles from the New menu, or make your own."
                      : "Try a style name, an effect like “Dither”, or a pack like “Clocks”."
    }

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console: the glyph in a recessed well, the words in the hub's faces, an orange key.
    private var consoleBody: some View {
        VStack(spacing: layout.itemGap) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 24, $0, weight: .light) }
                .foregroundStyle(ConsoleInk.legend)
                .frame(width: iconCircle, height: iconCircle)
                .consoleWell(cornerRadius: HubMetrics.panelRadius)
            VStack(spacing: layout.labelGap) {
                Text(headline)
                    .textRole(.consoleHeadline)
                    .foregroundStyle(ConsoleInk.ink)
                    .wrapping(.center)
                    .help(query)
                Text(message)
                    .textRole(.consoleBodySmall)
                    .foregroundStyle(ConsoleInk.legend)
                    .wrapping(.center)
            }
            Button(action: reset) { HubKeyLabel(text: "Show All Styles") }
                .buttonStyle(.keycap(.signal))
                .padding(.top, Space.xxs)
        }
        .readableWidth(layout, alignment: .center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl)   // inside its box, which adds cardPadding
    }

    private var classicBody: some View {
        VStack(spacing: layout.itemGap) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 30, $0, weight: .light) }
                .foregroundStyle(.secondary)
                .frame(width: iconCircle, height: iconCircle)
                .glassSurface(.regular, in: Circle())
            // Headline and message read as one block; icon and button an item step away.
            VStack(spacing: layout.labelGap) {
                Text(headline)
                    .textRole(.headline)
                    .wrapping(.center)
                    .help(query)
                Text(message)
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping(.center)
            }
            Button(action: reset) { Text("Show All Styles").textRole(.body) }
                .glassButton()
                .adaptiveControlSize()
                .padding(.top, Space.xxs)
        }
        .readableWidth(layout, alignment: .center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl + Space.l)
    }
}

// MARK: - New tiles

struct NewTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NewTileFace(title: title, symbol: symbol, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct NewTileFace: View {
    @Environment(\.console) private var console
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .body) private var circle: CGFloat = 40
    let title: String
    let symbol: String
    var hovering: Bool

    var body: some View {
        if console { pad } else { classic }
    }

    /// Console: an empty pad, built like StyleTile's — the same panel, radii and inset — with
    /// a dashed well the picture's size, a "+" in it and the title where a pad prints its
    /// name. Under the pointer its edge, well and "+" turn signal, as a pad's edge does.
    private var pad: some View {
        let shape = RoundedRectangle(cornerRadius: HubMetrics.panelRadius, style: .continuous)
        let well = RoundedRectangle(cornerRadius: HubMetrics.wellRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: Space.xs) {
            well
                .fill(ConsoleInk.well.opacity(hovering ? 0.9 : 0.6))
                .overlay(well.strokeBorder(hovering ? ConsoleInk.signalInk : ConsoleInk.legend.opacity(0.55),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .overlay(Image(systemName: "plus")
                    .scaledFont { .scaled(points: 16, $0, weight: .semibold) }
                    .foregroundStyle(hovering ? ConsoleInk.signalInk : ConsoleInk.legend))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
            Text(title)
                .textRole(.padName)
                .foregroundStyle(hovering ? ConsoleInk.ink : ConsoleInk.legend)
                .truncating(title)
                .padding(.horizontal, Space.xxs / 2)
        }
        .padding(Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
        // In its section's box, like a pad: no panel or edge at rest.
        .background(shape.fill(hovering ? ConsoleInk.chassis : Color.clear))
        .overlay(shape.strokeBorder(hovering ? ConsoleInk.signal.opacity(0.55) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: TileLabel.gapAbove) {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [5, 5]))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.025)))
                .overlay(
                    Image(systemName: symbol)
                        .scaledFont { .scaled(points: 16, $0, weight: .semibold) }
                        .foregroundStyle(hovering ? Color.accentColor : .secondary)
                        .frame(width: circle, height: circle)
                        .glassSurface(.regular, in: Circle())
                        .scaleEffect(hovering ? 1.08 : 1))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
            TileLabel(title: title, summary: nil, dimmed: true)
        }
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: hovering)
    }
}

struct NewSceneTile: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            NewTileFace(title: "New Scene", symbol: "sparkles", hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                            include: { $0.isScene }, prompt: "Search scenes") { kind in
                picking = false
                model.addScene(kind)
            }
        }
    }
}

// MARK: - Source swatch

/// Tiny visual of the shared source for buttons and headers.
struct SourceSwatch: View {
    @EnvironmentObject var model: AppModel
    let source: SourceSpec
    /// Fixed id so the thumbnail cache reuses one slot for the raw-source image.
    static let sourceOnly = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-00000000D07E")!, name: "Source")

    var body: some View {
        let _ = Perf.body("SourceSwatch")
        switch source.kind {
        case .gradient:
            LinearGradient(colors: [Color(source.colorA), Color(source.colorB)],
                           startPoint: .leading, endPoint: .trailing)
        case .image, .video, .collection:
            if let img = model.thumbnailer.image(for: SourceSwatch.sourceOnly, source: source) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.3)
            }
        }
    }
}

extension SourceSpec {
    var displayName: String {
        switch kind {
        case .collection: return (mediaFilenames ?? []).isEmpty ? "Built-in Photos" : "Your Photos"
        case .gradient: return "Gradient"
        case .image: return mediaFilename == nil ? "Photo (none)" : "Photo"
        case .video: return mediaFilename == nil ? "Video (none)" : "Video"
        }
    }
}

// MARK: - Console header

/// Console (the Stitch header strip): a hairline after the traffic lights, the orange light,
/// the name, and the app's real version on a small tag.
private struct HubWordmark: View {
    @ScaledLength(relativeTo: .body) private var rule: CGFloat = 16
    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    var body: some View {
        HStack(spacing: Space.xs) {
            Rectangle().fill(ConsoleInk.hairline).frame(width: 1, height: rule)
                .padding(.trailing, Space.xxs)
            Circle().fill(ConsoleInk.signal).frame(width: 8, height: 8)
            Text("DotStudio")
                .textRole(.consoleTitle)
                .foregroundStyle(ConsoleInk.ink)
            if let v = Self.version {
                ConsoleTag(text: "v\(v)")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.version.map { "DotStudio, version \($0)" } ?? "DotStudio")
    }
}

/// A header key's glyph: 20 pt square, so every key is the same 36 pt square (the keycap's
/// 8 pt padding around it; 32 pt before 2026-11-26).
private struct HubIconLabelStyle: LabelStyle {
    @ScaledLength(relativeTo: .body) private var box: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .scaledFont { .scaled(points: 15, $0, weight: .medium) }
            .frame(width: box, height: box)
    }
}

private extension View {
    /// A Console header key: a 36 pt square keycap around the item's icon.
    func hubHeaderKey() -> some View {
        labelStyle(HubIconLabelStyle())
            .buttonStyle(.keycap(padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)))
            .padding(.horizontal, Space.xxs / 2)   // the Stitch header's 4 pt between keys
    }
}

/// The flexible space between the wordmark and the keys, so the keys sit flush right with the
/// window's title hidden. macOS 26: a ToolbarSpacer. Before it: a Spacer as a primary-action
/// item (a macOS toolbar turns a bare Spacer into its flexible space), declared first among
/// the primary actions so it always lands between the wordmark and the keys — whether or not
/// that toolbar already puts its own flexible space there (two just share the gap).
private struct HubToolbarSpace: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .primaryAction) { Spacer() }
        }
    }
}

/// Before macOS 26 (no per-item glass there, so `hubBareToolbarItem` has nothing to hide): the
/// unified title bar draws its own grey material behind the header strip. Console paints it the
/// chassis instead, so the strip reads as one surface with the window. macOS 26 keeps its own
/// scroll-edge treatment.
private struct HubToolbarBackground: ViewModifier {
    let console: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else if console {
            content
                .toolbarBackground(ConsoleInk.chassis, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Console: "Update to 1.6.9" as an orange key in the header (the stock capsule button is
/// Classic's). Only while an update is downloaded and waiting, like UpdateReadyButton.
private struct HubUpdateKey: View {
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        if case .readyToInstall(let v) = updates.state {
            Button { updates.primaryAction() } label: {
                HubKeyLabel(text: "Update to \(v)", symbol: "arrow.down.circle.fill")
                    .padding(.vertical, 2)
            }
            .buttonStyle(.keycap(.signal))
            .help("DotStudio \(v) is downloaded — click to restart and finish updating (or it installs when you quit)")
            .accessibilityLabel("Update to \(v)")
        }
    }
}

private extension ToolbarContent {
    /// No toolbar glass behind a Console header item: the keys are the surface (macOS 26).
    @ToolbarContentBuilder
    func hubBareToolbarItem() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
