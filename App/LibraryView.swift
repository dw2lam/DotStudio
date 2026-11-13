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
//  sits `itemGap` above its tiles. The filter bar's frost spans the whole window. The page
//  scales with the window (`windowScaledType`): a big window gets bigger type, cards and
//  tiles rather than wider margins.

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @ObservedObject private var roster = DisplayRoster.shared
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
        .windowScaledType()
        .toolbar {
            if model.editingID == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    UpdateReadyButton()
                    newMenu
                    MCPToolbarButton()      // connect an AI assistant (AIConnect.swift)
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Transitions, performance, setup, updates (⌘,)")
                }
            }
        }
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

/// The scrolling page: destination cards, the pinned filter bar, the grid. Reads the
/// window-scaled `\.layout` (LibraryView applies `windowScaledType`).
private struct GalleryPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layout) private var layout
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

    private func gallery(_ state: GalleryState) -> some View {
        let matcher = StyleMatcher(filter: filter, query: query, playing: state.playingIDs)
        let sections = sections(matcher)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                DestinationRow(state: state)
                    .pageColumn(layout)
                    .padding(.top, topInset)
                    .padding(.bottom, layout.sectionGap - FilterBar.verticalInset)

                Section {
                    grid(sections, state: state, matcher: matcher)
                        .pageColumn(layout)
                        .padding(.top, layout.sectionGap - FilterBar.verticalInset)
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
        var id: Kind { kind }
    }

    private func sections(_ matcher: StyleMatcher) -> [GallerySection] {
        let all = model.library.presets
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
        return [GallerySection(kind: .results, title: title, subtitle: subtitle, presets: hits)]
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

    @ViewBuilder
    private func grid(_ sections: [GallerySection], state: GalleryState, matcher: StyleMatcher) -> some View {
        if sections.allSatisfy({ $0.presets.isEmpty }) && matcher.isFiltering {
            EmptyResults(filter: filter, query: query) {
                Motion.run { query = ""; filter = .all }
            }
            .transition(.lift(reduceMotion: reduceMotion))
        } else {
            // One grid for every section, so a tile glides to its new place when the filter
            // changes. Columns are added as the window widens (layout.tileColumns).
            LazyVGrid(columns: layout.tileColumns, alignment: .leading, spacing: layout.gridRowGap) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                    Section {
                        ForEach(section.presets) { preset in
                            StyleTile(model: model, preset: preset, badges: state.badges(for: preset.id),
                                      lineup: state.lineup)
                                .equatable()
                                .id(preset.id)
                                .transition(.lift(reduceMotion: reduceMotion))
                        }
                        switch section.kind {
                        case .scenes: NewSceneTile()
                        case .looks: NewTile(title: "New Look", symbol: "plus") { model.addPreset() }
                        case .results: EmptyView()
                        }
                    } header: {
                        SectionHeader(section: section)
                            // The grid puts gridRowGap around every row, header rows too. Re-space
                            // the header so it sits sectionGap below the previous tiles and only
                            // itemGap above its own (closer to what it titles than to what it ends).
                            .padding(.top, i == 0 ? 0 : max(layout.sectionGap - layout.gridRowGap, 0))
                            .padding(.bottom, layout.itemGap - layout.gridRowGap)
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
    let section: GalleryPage.GallerySection
    @State private var showSource = false

    var body: some View {
        let _ = Perf.body("SectionHeader")
        if section.kind == .looks {
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
private struct SourcePopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout

    var body: some View {
        let range = layout.popoverWidth
        SourceEditor(source: model.sourceBinding, model: model)
            .padding(layout.cardPadding)
            .frame(width: min(max(layout.scaled(320), range.lowerBound), range.upperBound))
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
    @Binding var filter: GalleryFilter
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    let counts: [GalleryFilter: Int]
    @Namespace private var chipNS
    @State private var chipsWidth: CGFloat = 0
    @State private var chipsViewport: CGFloat = 0
    @State private var chipFade = ChipEdgeFade()
    /// Coordinate space of the chips' own horizontal scroll view.
    private static let chipSpace = "filterChipsScroll"

    /// Narrower in compact windows, wider in wide ones; grows with the text.
    private var searchWidth: CGFloat { layout.scaled(layout.widthClass.pick(208, 240, 288)) }

    private var chips: some View {
        GlassGroup(spacing: layout.controlGap) {
            HStack(spacing: layout.controlGap) {
                ForEach(GalleryFilter.chips) { f in
                    let n = counts[f] ?? 0
                    if f.alwaysShown || n > 0 || filter == f {
                        FilterChip(filter: f, count: f == .all ? nil : n,
                                   selected: filter == f, ns: chipNS) {
                            Motion.run { filter = f }
                        }
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
        .pageColumn(layout)
        .padding(.vertical, Self.verticalInset)
        .background {
            // Once pinned, a soft frosted fade keeps the chips legible over the tiles
            // scrolling beneath. Driven by the bar's own position, so no parent re-render.
            // It spans the whole window, not just the page column.
            GeometryReader { g in
                let y = g.frame(in: .named(FilterBar.space)).minY
                let frost = min(max((150 - y) / 70, 0), 1)
                // Not there at all until it shows: no backdrop layer (or its blur) for the
                // window server to keep while the page scrolls under an invisible frost.
                if frost > 0 {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .black.opacity(0.8), location: 0.6),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(.top, -(Space.xxl + Space.s))   // up under the toolbar
                        .padding(.bottom, -Space.m)              // a soft tail over the first row
                        .opacity(frost)
                }
            }
            .allowsHitTesting(false)
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
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = GalleryControl.height
    let filter: GalleryFilter
    let count: Int?
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: layout.labelGap) {
                if let s = filter.symbol {
                    // Monochrome and an explicit colour: some symbols (leaf, camera.filters,
                    // scribble) otherwise draw their layers faintly over glass.
                    Image(systemName: s)
                        .symbolRenderingMode(.monochrome)
                        .scaledFont { .scaled(points: 10.5, $0, weight: .semibold) }
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                }
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
        .tintedGlassSurface(.regular, in: Capsule(), tint: selected ? Color.accentColor : nil, interactive: true)
        .glassID(filter.id, in: ns)
        .scaleEffect(hovering && !selected ? 1.04 : 1)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Empty state

private struct EmptyResults: View {
    @Environment(\.layout) private var layout
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

    var body: some View {
        VStack(spacing: layout.itemGap) {
            Image(systemName: query.isEmpty ? (filter.symbol ?? "square.grid.2x2") : "magnifyingglass")
                .scaledFont { .scaled(points: 30, $0, weight: .light) }
                .foregroundStyle(.secondary)
                .frame(width: iconCircle, height: iconCircle)
                .glassSurface(.regular, in: Circle())
            // Headline and message read as one block; icon and button an item step away.
            VStack(spacing: layout.labelGap) {
                Text(query.isEmpty ? "Nothing in \(filter.title) yet" : "No styles match “\(shownQuery)”")
                    .textRole(.headline)
                    .wrapping(.center)
                    .help(query)
                Text(query.isEmpty ? "Add Built-in Styles from the New menu, or make your own."
                                   : "Try a style name, an effect like “Dither”, or a pack like “Clocks”.")
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
    @ScaledLength(relativeTo: .body) private var circle: CGFloat = 40
    let title: String
    let symbol: String
    var hovering: Bool

    var body: some View {
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
