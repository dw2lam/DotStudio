//  LibraryView.swift — the gallery: where styles play (destination cards), a pinned
//  glass filter bar, and every style as a tile.
//
//  Styles split into two kinds:
//    • Scenes — self-contained generative pieces (Universe, Black Hole…). Pick and go.
//    • Looks  — effect stacks that restyle the shared source (slideshow/photo/video/gradient).

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: GalleryFilter = DemoHooks.filter ?? .all
    @State private var query = DemoHooks.search ?? ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Re-read once a minute so "playing now" follows the rotation and the sun.
        TimelineView(.everyMinute) { _ in
            gallery(GalleryState(model: model, wallpaperID: wallpaper.styleID))
        }
        .toolbar {
            if model.editingID == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    UpdateReadyButton()
                    newMenu
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

    private func gallery(_ state: GalleryState) -> some View {
        let matcher = StyleMatcher(filter: filter, query: query, playing: state.playingIDs)
        let sections = sections(matcher)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                DestinationRow(state: state)
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 22)

                Section {
                    grid(sections, state: state, matcher: matcher)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                } header: {
                    FilterBar(filter: $filter, query: $query, searchFocused: $searchFocused,
                              counts: counts(state))
                }
            }
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // DOTSTUDIO_DEMO_SCROLL=<style name>: scroll that tile to the top (pinned-bar review).
            guard let name = ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_SCROLL"],
                  let id = model.library.presets.first(where: { $0.name == name })?.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .coordinateSpace(name: FilterBar.space)
        .softScrollEdges()
        .motion(Motion.smooth, value: filter)
        .motion(Motion.smooth, value: query)
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
                GallerySection(kind: .scenes, title: "Scenes",
                               subtitle: "Ready-made generative pieces. Nothing to set up.",
                               presets: all.filter(\.isScene)),
                GallerySection(kind: .looks, title: "Looks",
                               subtitle: "Effects that restyle your source — a photo slideshow, a photo, a video or a gradient.",
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

    private static let columns = [GridItem(.adaptive(minimum: 228, maximum: 340), spacing: 22, alignment: .top)]

    @ViewBuilder
    private func grid(_ sections: [GallerySection], state: GalleryState, matcher: StyleMatcher) -> some View {
        if sections.allSatisfy({ $0.presets.isEmpty }) && matcher.isFiltering {
            EmptyResults(filter: filter, query: query) {
                Motion.run { query = ""; filter = .all }
            }
            .transition(.lift(reduceMotion: reduceMotion))
        } else {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 26) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.presets) { preset in
                            StyleTile(preset: preset, badges: state.badges(for: preset.id), lineup: state.lineup)
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
                    }
                }
            }
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

// MARK: - Section header

private struct SectionHeader: View {
    @EnvironmentObject var model: AppModel
    let section: LibraryView.GallerySection
    @State private var showSource = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if section.kind == .looks { sourceButton }
        }
        .padding(.top, section.kind == .looks ? 22 : 6)
        .padding(.bottom, 2)
    }

    private var sourceButton: some View {
        Button { showSource.toggle() } label: {
            HStack(spacing: 8) {
                SourceSwatch(source: model.library.source)
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                Text("Source: \(model.library.source.displayName)")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .glassButton()
        .help("The slideshow, photo, video or gradient every Look restyles")
        .popover(isPresented: $showSource, arrowEdge: .bottom) {
            SourceEditor(source: model.sourceBinding, model: model)
                .padding(16)
                .frame(width: 320)
        }
    }
}

// MARK: - Filter bar

/// Pinned under the toolbar: search + glass chips. Tiles scroll beneath it.
private struct FilterBar: View {
    /// Coordinate space of the gallery's scroll viewport.
    static let space = "galleryScroll"
    @Binding var filter: GalleryFilter
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    let counts: [GalleryFilter: Int]
    @Namespace private var chipNS

    var body: some View {
        HStack(spacing: 12) {
            SearchField(text: $query, prompt: "Search styles, effects, packs", focus: searchFocused)
                .frame(width: 236)
                .onExitCommand { query = ""; searchFocused.wrappedValue = false }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
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
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .scrollClipDisabledCompat()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Once pinned, a soft frosted fade keeps the chips legible over the tiles
            // scrolling beneath. Driven by the bar's own position, so no parent re-render.
            GeometryReader { g in
                let y = g.frame(in: .named(FilterBar.space)).minY
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black.opacity(0.8), location: 0.6),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.top, -60)
                    .padding(.bottom, -16)
                    .opacity(min(max((150 - y) / 70, 0), 1))
            }
            .allowsHitTesting(false)
        }
    }
}

private struct FilterChip: View {
    let filter: GalleryFilter
    let count: Int?
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let s = filter.symbol {
                    Image(systemName: s).font(.system(size: 10.5, weight: .semibold))
                }
                Text(filter.title)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(.regular, in: Capsule(), tint: selected ? Color.accentColor : nil, interactive: true)
        .glassID(filter.id, in: ns)
        .scaleEffect(hovering && !selected ? 1.04 : 1)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder func scrollClipDisabledCompat() -> some View {
        if #available(macOS 14, *) { self.scrollClipDisabled() } else { self }
    }
}

// MARK: - Empty state

private struct EmptyResults: View {
    let filter: GalleryFilter
    let query: String
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? (filter.symbol ?? "square.grid.2x2") : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .glassSurface(.regular, in: Circle())
            Text(query.isEmpty ? "Nothing in \(filter.title) yet" : "No styles match “\(query)”")
                .font(.title3.weight(.semibold))
            Text(query.isEmpty ? "Add Built-in Styles from the New menu, or make your own."
                               : "Try a style name, an effect like “Dither”, or a pack like “Clocks”.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show All Styles", action: reset)
                .glassButton()
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
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
    let title: String
    let symbol: String
    var hovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [5, 5]))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.025)))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hovering ? Color.accentColor : .secondary)
                        .frame(width: 40, height: 40)
                        .glassSurface(.regular, in: Circle())
                        .scaleEffect(hovering ? 1.08 : 1))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text(" ").font(.caption)   // keep baseline with sibling tiles
            }
            .padding(.horizontal, 3)
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
