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
    private static let radius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
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

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 3)
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
        .help("Double-click to edit")
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
                             location: model.locationTuple, store: model.store)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            }
        }
    }

    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: Self.radius + 4, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .padding(-4)
            .opacity(selected ? 1 : 0)
            .scaleEffect(selected || reduceMotion ? 1 : 1.03)
    }

    private var overlays: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                TileBadgeCluster(badges: badges, rotates: lineup.rotates)
                Spacer()
            }
            Spacer(minLength: 0)
            if hovering {
                TileActionBar(preset: preset, badges: badges, lineup: lineup)
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .padding(8)
    }

    private var summary: String {
        let names = preset.effects.filter(\.enabled).map(\.kind.displayName)
        if preset.isScene { return names.count > 1 ? "Scene · " + names.dropFirst().joined(separator: " · ") : "Scene" }
        return names.isEmpty ? "Source only" : names.joined(separator: " · ")
    }
}

// MARK: - Badges

/// Subtle top-left state: on the screensaver (playing now), in the playlist, night, wallpaper.
struct TileBadgeCluster: View {
    let badges: TileBadges
    let rotates: Bool

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 6) {
                if badges.onScreensaver {
                    if rotates {
                        badge(badges.playingNow ? "Playing" : nil,
                              badges.playingNow ? "play.fill" : "play.square.stack.fill",
                              help: badges.playingNow ? "In the screensaver playlist — on screen now" : "In the screensaver playlist")
                    } else {
                        badge("Screensaver", "play.fill", help: "Plays as your screensaver")
                    }
                }
                if badges.night { badge(badges.onScreensaver ? nil : "Night", "moon.fill", help: "Plays at night") }
                if badges.wallpaper { badge(badges.isOnlyWallpaper ? "Wallpaper" : nil, "photo.artframe",
                                            help: "Playing as your wallpaper") }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
        }
    }

    private func badge(_ text: String?, _ symbol: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, text == nil ? 6 : 8)
        .frame(height: 21)
        .glassSurface(.regular, in: Capsule(), tint: Color.accentColor.opacity(0.75))
        .help(help)
    }
}

private extension TileBadges {
    var isOnlyWallpaper: Bool { wallpaper && !onScreensaver && !night }
}

// MARK: - Hover bar

private struct TileActionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    let preset: Preset
    let badges: TileBadges
    let lineup: ScreensaverLineup

    private var isOnly: Bool { lineup.playlist == [preset.id] }

    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 2) {
                icon(isOnly ? "checkmark" : "play.fill",
                     help: isOnly ? "Playing as your screensaver" : "Play as Screensaver") {
                    Motion.run { model.playAsScreensaver(preset.id) }
                }
                .disabled(isOnly)

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

                Divider().frame(height: 16).padding(.horizontal, 3)

                icon("arrow.up.left.and.arrow.down.right", help: "Preview Full Screen") {
                    ScreensaverPreviewController.shared.present(
                        preset: preset, source: model.library.source, store: model.store)
                }
                icon("slider.horizontal.3", help: "Edit") { model.edit(preset.id) }
            }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .glassSurface(.regular, in: Capsule())
        }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(GlassIconButtonStyle())
            .help(help)
            .accessibilityLabel(help)
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
