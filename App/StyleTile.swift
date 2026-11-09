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

struct StyleTile: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.heroNamespace) private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preset: Preset
    let badges: TileBadges
    let lineup: ScreensaverLineup

    @State private var hovering: Bool
    @State private var live = false
    @State private var confirmDelete = false

    init(preset: Preset, badges: TileBadges, lineup: ScreensaverLineup) {
        self.preset = preset
        self.badges = badges
        self.lineup = lineup
        _hovering = State(initialValue: DemoHooks.hoverName == preset.name)
    }

    private var selected: Bool { model.selectedID == preset.id }
    private var isOpen: Bool { model.editingID == preset.id }
    private static let radius = Radius.tile

    var body: some View {
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
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1))
            .overlay(selectionRing)
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14),
                    radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .scaleEffect(hovering && !reduceMotion ? 1.025 : 1)
            .offset(y: hovering && !reduceMotion ? -2 : 0)

            TileLabel(title: preset.name, summary: summary)
        }
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: hovering)
        .motion(Motion.snappy, value: selected)
        .onHover { h in
            hovering = h || DemoHooks.hoverName == preset.name
            // Animate the tile live after a short dwell; one live preview at a time.
            if h {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if hovering { live = true } }
            } else {
                live = false
            }
        }
        .onTapGesture(count: 2) { model.edit(preset.id) }
        .onTapGesture { model.selectedID = preset.id }
        .contextMenu { TileMenu(preset: preset, lineup: lineup, confirmDelete: $confirmDelete) }
        .help("\(preset.name) — double-click to edit")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(preset.name), \(summary)"))
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Motion.run { model.delete(preset.id) } }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            StyleThumb(preset: preset)
            if live && model.editingID == nil {
                MetalPreview(preset: preset, source: model.library.source,
                             location: model.locationTuple, store: model.store,
                             music: model.library.musicSettings)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            }
        }
    }

    private var selectionRing: some View {
        // Sits Space.xxs outside the thumbnail, so its radius grows by the same amount.
        RoundedRectangle(cornerRadius: Self.radius + Space.xxs, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .padding(-Space.xxs)
            .opacity(selected ? 1 : 0)
            .scaleEffect(selected || reduceMotion ? 1 : 1.03)
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

    private var summary: String {
        let names = preset.effects.filter(\.enabled).map(\.kind.displayName)
        if preset.isScene { return names.count > 1 ? "Scene · " + names.dropFirst().joined(separator: " · ") : "Scene" }
        return names.isEmpty ? "Source only" : names.joined(separator: " · ")
    }
}

// MARK: - Label

/// A tile's name and one-line summary under its thumbnail. Shared by the style tiles and
/// the New Look / New Scene tiles, so every label in the grid starts on the thumbnail's
/// leading edge (the section header's edge too) and uses the same type.
struct TileLabel: View {
    /// Thumbnail → label.
    static let gapAbove = Space.xs
    @Environment(\.layout) private var layout
    let title: String
    /// nil keeps an empty summary line, so a New tile is as tall as its neighbours.
    let summary: String?
    var dimmed = false

    var body: some View {
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
            } else {
                Text(" ").textRole(.caption).accessibilityHidden(true)
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

    private func moreMenu(includeDestinations: Bool) -> some View {
        Menu {
            if includeDestinations {
                Button(badges.onScreensaver ? "Remove from Screensaver" : "Add to Screensaver") {
                    Motion.run { model.togglePlaylist(preset.id) }
                }
                .disabled(isOnly)
                if wallpaper.isAvailable {
                    Button(badges.wallpaper ? "Stop Wallpaper" : "Set as Wallpaper") {
                        Motion.run { wallpaper.toggle(preset.id) }
                    }
                }
                Divider()
            }
            Button("Preview Full Screen") { preview() }
            Button("Edit") { model.edit(preset.id) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ScaledIconButtonStyle())
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
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
    @EnvironmentObject var model: AppModel
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
