//  StyleTile.swift — one style in the gallery: thumbnail (live on hover), state
//  badges, a glass action bar on hover, and the context menu.

import SwiftUI

/// Shared namespace for the tile → editor zoom (set by ContentView).
private struct HeroNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

extension View {
    /// The tile thumbnail and the editor preview share this id, so opening a style
    /// zooms its thumbnail into the editor (and closing flies it back).
    @ViewBuilder
    func heroGeometry(_ id: UUID, in ns: Namespace.ID?) -> some View {
        if let ns {
            self.matchedGeometryEffect(id: id, in: ns, properties: .frame, anchor: .center)
        } else {
            self
        }
    }
}

/// Everything a tile shows comes in as plain values (no observed model), and the tile is
/// Equatable: a model change — a selection, an edit in the editor, a slider tick — re-renders
/// only the tiles whose values changed, not every tile in the gallery. A still landing
/// repaints just its own thumbnail (Thumbnailer's per-style signal).
struct StyleTile: View, Equatable {
    /// Actions and the thumbnailer. A plain reference: the tile never observes it.
    let model: AppModel
    @Environment(\.heroNamespace) private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: Preset
    let badges: TileBadges
    let lineup: ScreensaverLineup
    let selected: Bool
    /// This style is open in the editor (its image lives there).
    let isOpen: Bool
    /// Some style is open in the editor (the gallery is behind it: no live previews).
    let editorOpen: Bool
    let source: SourceSpec
    let music: MusicSpec
    let location: GeoPoint?

    @State private var hovering: Bool
    /// The pointer is over the tile (hover effects wait while the gallery scrolls).
    @State private var pointerInside = false
    @State private var live = false
    @State private var confirmDelete = false
    /// The selection as of the last render (a ring appearing now was just selected: it
    /// animates in; one already selected when the tile appears just shows).
    @State private var wasSelected: Bool
    /// Deselected, its ring still fading out (SelectionRing removes itself when done).
    @State private var ringFading = false

    init(model: AppModel, preset: Preset, badges: TileBadges, lineup: ScreensaverLineup) {
        self.model = model
        self.preset = preset
        self.badges = badges
        self.lineup = lineup
        selected = model.selectedID == preset.id
        isOpen = model.editingID == preset.id
        editorOpen = model.editingID != nil
        source = model.library.source
        music = model.library.musicSettings
        location = model.locationTuple.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        _hovering = State(initialValue: DemoHooks.hoverName == preset.name)
        _wasSelected = State(initialValue: model.selectedID == preset.id)
    }

    static func == (a: StyleTile, b: StyleTile) -> Bool {
        a.model === b.model && a.preset == b.preset && a.badges == b.badges && a.lineup == b.lineup
            && a.selected == b.selected && a.isOpen == b.isOpen && a.editorOpen == b.editorOpen
            && a.source == b.source && a.music == b.music && a.location == b.location
    }

    private static let radius = Radius.tile

    var body: some View {
        let _ = Perf.body("StyleTile")
        VStack(alignment: .leading, spacing: TileLabel.gapAbove) {
            ZStack {
                // While this style is open in the editor, its image lives there.
                if !isOpen {
                    thumbnail
                        .heroGeometry(preset.id, in: hero)
                        .transition(.opacity)
                }
                overlays
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background {   // DEV harness only (ClickProbe)
                if TileProbe.enabled {
                    TileProbeReporter(id: preset.id, select: select, open: open,
                                      hover: { h in pointerInside = h; setHover(h) })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1))
            .overlay { selectionRing }
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14),
                    radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.025 : 1)
            .offset(y: hovering && !reduceMotion ? -2 : 0)

            TileLabel(title: preset.name, summary: summary)
        }
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: hovering)
        .onChange(of: selected) { _, now in
            if !now { ringFading = true }
            wasSelected = now
        }
        .onHover { h in
            pointerInside = h
            // While the gallery scrolls, tiles slide under a still pointer: no lift, no action
            // bar, no live preview spinning up per tile — they catch up when the scroll ends.
            if ScrollActivity.isScrolling && h { return }
            setHover(h)
        }
        .onReceive(ScrollActivity.changes) { scrolling in
            if scrolling {
                if hovering && DemoHooks.hoverName != preset.name { setHover(false) }
            } else if pointerInside != hovering {
                setHover(pointerInside)
            }
        }
        .onTapGesture(count: 2) { open() }
        .onTapGesture { select() }
        .contextMenu { TileMenu(model: model, preset: preset, lineup: lineup, confirmDelete: $confirmDelete) }
        .help("\(preset.name) — double-click to edit")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(preset.name), \(summary ?? (preset.isScene ? "Scene" : "Look"))"))
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Motion.run { model.delete(preset.id) } }
        } message: {
            Text("This can't be undone.")
        }
    }

    /// A click: select this style.
    private func select() { model.selectedID = preset.id }

    /// A double-click: open it in the editor.
    private func open() { model.edit(preset.id) }

    private func setHover(_ h: Bool) {
        hovering = h || DemoHooks.hoverName == preset.name
        // Animate the tile live after a short dwell; one live preview at a time.
        if h {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if hovering && !ScrollActivity.isScrolling && !DemoHooks.livePreviewsPaused { live = true }
            }
        } else {
            live = false
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            TileThumb(thumbnailer: model.thumbnailer, preset: preset, source: source, music: music)
            if live && !editorOpen {
                MetalPreview(preset: preset, source: source,
                             location: location.map { ($0.lat, $0.lon) }, store: model.store,
                             music: music)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            }
        }
    }

    /// Only while selected, or fading out after (SelectionRing: a Core Animation ring).
    @ViewBuilder private var selectionRing: some View {
        if selected || ringFading {
            SelectionRing(selected: selected, animatesIn: selected && !wasSelected, hovering: hovering,
                          reduceMotion: reduceMotion) { ringFading = false }
                // The ring sits Space.xxs outside the thumbnail; the view reaches further, for
                // its shadow.
                .padding(-(Space.xxs + SelectionRing.margin))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var overlays: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                TileBadgeCluster(badges: badges, rotates: lineup.rotates)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            if hovering {
                TileActionBar(preset: preset, badges: badges, lineup: lineup)
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .padding(Space.xs)
    }

    /// The line under the name, only when it says something the name and picture don't: a
    /// Look's effect stack, or what's layered on a scene ("Bloom"). A bare scene has none —
    /// the gallery's sections already say it's a scene.
    private var summary: String? {
        let names = preset.effects.filter(\.enabled).map(\.kind.displayName)
        if preset.isScene { return names.count > 1 ? names.dropFirst().joined(separator: " · ") : nil }
        return names.isEmpty ? "Source only" : names.joined(separator: " · ")
    }
}

// MARK: - Selection ring

/// The selected tile's ring: a 2.5-pt accent outline Space.xxs outside the thumbnail (its
/// radius grown by as much), under the tile's shadow. Drawn once by AppKit and moved by Core
/// Animation — selecting fades it in as it settles from 3% larger (Motion.snappy's spring),
/// deselecting fades it back out; under Reduce Motion it only fades. The animation runs in
/// the render server, so SwiftUI does nothing per frame: a SwiftUI-animated ring re-ran the
/// window's view graph for every frame of the spring (~0.3 s of main-thread time per
/// selection). Only the selected tile (and one fading out) has one.
struct SelectionRing: NSViewRepresentable {
    /// Room around the ring for its shadow.
    static let margin: CGFloat = 32
    static let lineWidth: CGFloat = 2.5
    static let startScale: CGFloat = 1.03

    let selected: Bool
    /// Just selected: grow in from the deselected pose (else it shows at rest).
    let animatesIn: Bool
    /// The tile is lifted (hovered): its shadow is the bigger one.
    let hovering: Bool
    let reduceMotion: Bool
    /// Faded out after a deselection: the tile can drop the view.
    let onFadedOut: () -> Void

    func makeNSView(context: Context) -> RingView {
        let v = RingView()
        v.hovering = hovering
        v.onFadedOut = onFadedOut
        // A ring made for a deselection (the tile was re-rendered without its ring first)
        // fades out from the selected pose; one made for a selection fades in, or just shows.
        v.begin(from: selected ? !animatesIn : true, to: selected, reduceMotion: reduceMotion)
        return v
    }

    func updateNSView(_ v: RingView, context: Context) {
        v.onFadedOut = onFadedOut
        if v.hovering != hovering {
            v.hovering = hovering
            v.needsDisplay = true
        }
        v.move(to: selected, reduceMotion: reduceMotion)
    }

    final class RingView: NSView {
        var hovering = false
        var onFadedOut: (() -> Void)?
        /// The pose it's in or heading for (true = selected: shown, at scale 1).
        private var target = true
        /// A move asked for before the view had a size (the scale is about its centre).
        private var pending: (from: Bool, reduceMotion: Bool)?
        private var observer: NSObjectProtocol?
        /// Bumped by every fade-out, so only the latest one reports.
        private var generation = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            // The accent colour changed in System Settings.
            observer = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.needsDisplay = true }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            if let p = pending, bounds.width > 0 {
                pending = nil
                animate(from: p.from, reduceMotion: p.reduceMotion)
            }
        }

        /// Shows the `from` pose, then animates to `to` (none when they're the same).
        func begin(from: Bool, to: Bool, reduceMotion: Bool) {
            target = to
            guard from != to else { return }
            if bounds.width > 0 { animate(from: from, reduceMotion: reduceMotion) } else { pending = (from, reduceMotion) }
        }

        func move(to selected: Bool, reduceMotion: Bool) {
            guard selected != target else { return }
            let from = target
            target = selected
            if bounds.width > 0 { animate(from: from, reduceMotion: reduceMotion) } else { pending = (from, reduceMotion) }
        }

        /// One spring (a fade under Reduce Motion) from where the ring is now — mid-move
        /// included — to `target`'s pose; reports a finished fade-out.
        private func animate(from: Bool, reduceMotion: Bool) {
            guard let layer else { return }
            let to = target
            let fromOpacity = layer.presentation()?.opacity ?? (from ? 1 : 0)
            let fromTransform = layer.presentation()?.transform ?? pose(from, reduceMotion: reduceMotion)
            let toTransform = pose(to, reduceMotion: reduceMotion)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = to ? 1 : 0
            layer.transform = toTransform
            var duration = 0.0
            for (key, a, b) in [("opacity", fromOpacity as Any, Float(to ? 1 : 0) as Any),
                                ("transform", NSValue(caTransform3D: fromTransform) as Any,
                                 NSValue(caTransform3D: toTransform) as Any)] {
                let anim: CABasicAnimation
                if reduceMotion {
                    anim = CABasicAnimation(keyPath: key)
                    anim.duration = 0.18 * Motion.slow
                    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                } else {
                    // Motion.snappy: response 0.28, damping 0.82.
                    let spring = CASpringAnimation(perceptualDuration: 0.28 * Motion.slow, bounce: 0.18)
                    spring.duration = spring.settlingDuration
                    anim = spring
                }
                anim.fromValue = a
                anim.toValue = b
                layer.add(anim, forKey: key)
                duration = anim.duration
            }
            CATransaction.commit()
            // Faded out: the tile drops the view. On the clock, not the animation's completion
            // (a window that isn't on screen never runs its animations to the end).
            if !to {
                generation += 1
                let g = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self, g == self.generation, !self.target, self.pending == nil else { return }
                    Perf.count("SelectionRing.fadedOut")
                    self.onFadedOut?()
                }
            }
        }

        /// The layer's transform for a pose: at rest, or 3% larger about the view's centre.
        private func pose(_ selected: Bool, reduceMotion: Bool) -> CATransform3D {
            guard !selected, !reduceMotion, let layer else { return CATransform3DIdentity }
            let s = SelectionRing.startScale
            // About the centre, whatever the layer's anchor point is.
            let dx = (0.5 - layer.anchorPoint.x) * bounds.width
            let dy = (0.5 - layer.anchorPoint.y) * bounds.height
            var t = CATransform3DMakeTranslation(dx, dy, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -dx, -dy, 0)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let m = SelectionRing.margin
            let lw = SelectionRing.lineWidth
            // strokeBorder: the outline inset by half the line, its radius by as much.
            let rect = bounds.insetBy(dx: m + lw / 2, dy: m + lw / 2)
            let radius = max(Radius.tile + Space.xxs - lw / 2, 0)
            let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
            ctx.saveGState()
            // The tile's shadow (StyleTile), which the ring sat under.
            ctx.setShadow(offset: CGSize(width: 0, height: -(hovering ? 10 : 3)), blur: hovering ? 18 : 6,
                          color: NSColor.black.withAlphaComponent(hovering ? 0.28 : 0.14).cgColor)
            ctx.addPath(path)
            ctx.setLineWidth(lw)
            ctx.setStrokeColor(NSColor(Color.accentColor).cgColor)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

// MARK: - Label

/// A tile's name and, when it adds something, a one-line summary under its thumbnail.
/// Shared by the style tiles and the New Look / New Scene tiles, so every label in the grid
/// starts on the thumbnail's leading edge (the section header's edge too) and uses the
/// same type. Tiles in a row are top-aligned, so thumbnails and names line up whether or
/// not a neighbour has a summary.
struct TileLabel: View {
    /// Thumbnail → label.
    static let gapAbove = Space.xs
    @Environment(\.layout) private var layout
    let title: String
    let summary: String?
    var dimmed = false

    var body: some View {
        let _ = Perf.body("TileLabel")
        VStack(alignment: .leading, spacing: layout.labelGap) {
            // Up to two lines, then "…" with the full name as a tooltip.
            Text(title)
                .textRole(.itemTitle)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .truncating(title, lines: 2)
            if let summary {
                Text(summary)
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .truncating(summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Badges

/// Subtle top-left state: on the screensaver (playing now), in the playlist, night,
/// wallpaper. Wraps onto a second line rather than running off a narrow tile.
struct TileBadgeCluster: View {
    let badges: TileBadges
    let rotates: Bool

    var body: some View {
        let _ = Perf.body("TileBadgeCluster")
        if !badges.isEmpty {
            FlowLayout(spacing: GlassBadge.spacing, lineSpacing: GlassBadge.spacing) {
                if badges.onScreensaver {
                    if rotates {
                        GlassBadge(text: badges.playingNow ? "Playing" : nil,
                                   symbol: badges.playingNow ? "play.fill" : "play.square.stack.fill")
                            .help(badges.playingNow ? "In the screensaver playlist — on screen now" : "In the screensaver playlist")
                    } else {
                        GlassBadge(text: "Screensaver", symbol: "play.fill")
                            .help("Plays as your screensaver")
                    }
                }
                if badges.night {
                    GlassBadge(text: badges.onScreensaver ? nil : "Night", symbol: "moon.fill")
                        .help("Plays at night")
                }
                if badges.wallpaper {
                    GlassBadge(text: badges.isOnlyWallpaper ? "Wallpaper" : nil, symbol: "photo.artframe")
                        .help("Playing as your wallpaper")
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
        }
    }
}

/// A small tinted glass capsule over imagery: an icon and an optional word, always white.
/// The tile badges and the Night/Day badge on the Screensaver card's preview.
struct GlassBadge: View {
    /// Between neighbouring badges (a half step: badges are small).
    static let spacing = Space.xxs + 2
    /// No token for a badge's height: 20 at the default text size, grown with caption text.
    @ScaledLength(relativeTo: .caption) private var height: CGFloat = 20
    let text: String?
    let symbol: String
    var tint: Color? = Color.accentColor.opacity(0.75)

    var body: some View {
        let _ = Perf.body("GlassBadge")
        HStack(spacing: Space.xxs) {
            Image(systemName: symbol)
            if let text { Text(text).lineLimit(1) }
        }
        .textRole(.badge)
        .foregroundStyle(.white)
        .padding(.horizontal, text == nil ? Space.xxs + 2 : Space.xs)
        .frame(minHeight: height)
        .fixedSize()
        .tintedGlassSurface(.regular, in: Capsule(), tint: tint)
    }
}

private extension TileBadges {
    var isOnlyWallpaper: Bool { wallpaper && !onScreensaver && !night }
}

// MARK: - Hover bar

private struct TileActionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @ScaledLength(relativeTo: .body) private var dividerHeight: CGFloat = 16
    let preset: Preset
    let badges: TileBadges
    let lineup: ScreensaverLineup

    private var isOnly: Bool { lineup.playlist == [preset.id] }

    var body: some View {
        let _ = Perf.body("TileActionBar")
        // Every action when the tile has room. On a narrow tile (or at large text sizes)
        // Preview and Edit fold into a "…" menu; narrower still, everything but Play does.
        ViewThatFits(in: .horizontal) {
            bar { destinationIcons; divider; styleIcons }
            bar { destinationIcons; divider; moreMenu(includeDestinations: false) }
            bar { playIcon; moreMenu(includeDestinations: true) }
        }
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        GlassGroup(spacing: Space.xs) {
            HStack(spacing: Space.xxs) { content() }
                .padding(Space.xxs)
                .glassSurface(.regular, in: Capsule())
        }
        .fixedSize()
    }

    private var divider: some View {
        Divider().frame(height: dividerHeight).padding(.horizontal, Space.xxs)
    }

    private var playIcon: some View {
        icon(isOnly ? "checkmark" : "play.fill",
             help: isOnly ? "Playing as your screensaver" : "Play as Screensaver") {
            Motion.run { model.playAsScreensaver(preset.id) }
        }
        .disabled(isOnly)
    }

    @ViewBuilder private var destinationIcons: some View {
        playIcon

        icon(badges.onScreensaver ? "minus" : "plus",
             help: badges.onScreensaver ? "Remove from Screensaver" : "Add to Screensaver") {
            Motion.run { model.togglePlaylist(preset.id) }
        }
        .disabled(isOnly)

        if wallpaper.isAvailable {
            icon(badges.wallpaper ? "photo.artframe.circle.fill" : "photo.artframe",
                 help: badges.wallpaper ? "Stop Wallpaper" : "Set as Wallpaper") {
                Motion.run { wallpaper.toggle(preset.id) }
            }
        }
    }

    @ViewBuilder private var styleIcons: some View {
        icon("arrow.up.left.and.arrow.down.right", help: "Preview Full Screen") { preview() }
        icon("slider.horizontal.3", help: "Edit") { model.edit(preset.id) }
    }

    /// "…": a SwiftUI button that pops up an AppKit menu. Not a SwiftUI `Menu`: that is an
    /// AppKit pop-up button, and the bar's ViewThatFits measures its variants — a measured
    /// AppKit control being created and dropped mid-layout is what crashed on macOS 26
    /// (see ColorWellsRow).
    private func moreMenu(includeDestinations: Bool) -> some View {
        Button { popUpMore(includeDestinations: includeDestinations) } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(ScaledIconButtonStyle())
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    private func popUpMore(includeDestinations: Bool) {
        var items: [ActionMenu.Item] = []
        if includeDestinations {
            let id = preset.id
            items.append(.init(badges.onScreensaver ? "Remove from Screensaver" : "Add to Screensaver",
                               enabled: !isOnly) { [model] in Motion.run { model.togglePlaylist(id) } })
            if wallpaper.isAvailable {
                items.append(.init(badges.wallpaper ? "Stop Wallpaper" : "Set as Wallpaper") { [wallpaper] in
                    Motion.run { wallpaper.toggle(id) }
                })
            }
            items.append(.separator)
        }
        items.append(.init("Preview Full Screen") { preview() })
        items.append(.init("Edit") { [model, id = preset.id] in model.edit(id) })
        ActionMenu.popUp(items)
    }

    private func preview() {
        ScreensaverPreviewController.shared.present(
            preset: preset, source: model.library.source, store: model.store)
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ScaledIconButtonStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

/// GlassIconButtonStyle (Glass.swift) with its size and glyph following the text size:
/// a plain, borderless round icon button for glass bars.
struct ScaledIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ScaledIconButton(configuration: configuration) }
}

private struct ScaledIconButton: View {
    let configuration: ButtonStyleConfiguration
    @ScaledLength(relativeTo: .body) private var size: CGFloat = 28
    @State private var hovering = false

    var body: some View {
        configuration.label
            .scaledFont { .scaled(points: 12.5, $0, weight: .semibold) }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Context menu

/// Grouped so new destinations slot in as one more section.
struct TileMenu: View {
    /// Actions only (a plain reference: the menu never observes the model).
    let model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    let preset: Preset
    let lineup: ScreensaverLineup
    @Binding var confirmDelete: Bool

    var body: some View {
        screensaverSection
        Divider()
        wallpaperSection
        Divider()
        styleSection
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = true }
    }

    @ViewBuilder private var screensaverSection: some View {
        let id = preset.id
        let inPlaylist = lineup.playlist.contains(id)
        Button("Play as Screensaver") { Motion.run { model.playAsScreensaver(id) } }
            .disabled(lineup.playlist == [id])
        if inPlaylist {
            Button("Remove from Screensaver") { Motion.run { model.removeFromPlaylist(id) } }
                .disabled(lineup.playlist.count == 1)
        } else {
            Button("Add to Screensaver") { Motion.run { model.addToPlaylist(id) } }
        }
        if lineup.night == id {
            Button("Stop Playing at Night") { Motion.run { model.setNight(nil) } }
        } else {
            Button("Play at Night") { Motion.run { model.setNight(id) } }
        }
    }

    @ViewBuilder private var wallpaperSection: some View {
        if wallpaper.isAvailable {
            if wallpaper.styleID == preset.id {
                Button("Stop Wallpaper") { Motion.run { wallpaper.stop() } }
            } else {
                Button("Set as Wallpaper") { Motion.run { wallpaper.set(preset.id) } }
            }
        }
    }

    @ViewBuilder private var styleSection: some View {
        let id = preset.id
        Button("Edit") { model.edit(id) }
        Button("Preview Full Screen") {
            ScreensaverPreviewController.shared.present(
                preset: preset, source: model.library.source, store: model.store)
        }
        Button("Duplicate") { Motion.run { _ = model.duplicate(id) } }
        Button("Export Style…") { model.exportPreset(id) }
        Button("Save Image…") { model.exportSelectedAsImage(id) }
    }
}

// MARK: - Thumbnail

/// A style's cached still (black until it renders) from plain values, no observed model: it
/// repaints when its own still lands (the Thumbnailer's per-style signal, read inside
/// `image(for:)`), or when its values change. The gallery tiles' thumbnail, and StyleThumb's.
struct TileThumb: View {
    let thumbnailer: Thumbnailer
    let preset: Preset
    let source: SourceSpec
    let music: MusicSpec
    /// Music presented on the still as the screensaver shows it (StyleThumb's `showsMusic`).
    var showsMusic = false

    var body: some View {
        // Takes exactly the size it's offered; the image fills it and is clipped.
        Color.black
            .overlay {
                if let img = thumbnailer.image(for: preset, source: source, music: music, showsMusic: showsMusic) {
                    Image(nsImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}

/// A location as a comparable value (tiles compare their inputs).
struct GeoPoint: Equatable {
    var lat: Double
    var lon: Double
}

/// An AppKit menu popped up at the pointer from a SwiftUI button (TileActionBar's "…").
enum ActionMenu {
    struct Item {
        let title: String
        var enabled = true
        let action: (() -> Void)?
        init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            self.title = title
            self.enabled = enabled
            self.action = action
        }
        private init() { title = ""; action = nil }
        static let separator = Item()
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func popUp(_ items: [Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var targets: [Target] = []
        for item in items {
            guard let action = item.action else { menu.addItem(.separator()); continue }
            let t = Target(action)
            targets.append(t)
            let mi = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            mi.target = t
            mi.isEnabled = item.enabled
            menu.addItem(mi)
        }
        // Screen coordinates (in: nil); the targets live until the menu closes.
        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}
