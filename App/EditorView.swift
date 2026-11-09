//  EditorView.swift — edit one style: a big live preview floating over the style's own
//  ambient wash, and a glass inspector on the right.

import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.heroNamespace) private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layout) private var layout
    let id: UUID
    @State private var tab: Tab = .effects
    @State private var confirmDelete = false
    /// The live Metal view fades in once the zoom from the tile has landed.
    @State private var live = false

    enum Tab: String, CaseIterable, Identifiable {
        case effects = "Effects", source = "Source"
        var id: String { rawValue }
    }

    var body: some View {
        let binding = model.presetBinding(id)
        let preset = binding.wrappedValue
        // One margin on every side and between the two panes (20 · 32 · 48 by width).
        HStack(spacing: layout.pagePadding) {
            previewPane(preset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            inspector(binding, name: preset.name)
                .frame(width: layout.inspectorWidth)
                .frame(maxHeight: .infinity)
                .glassCard(cornerRadius: Radius.card)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
        .padding(layout.pagePadding)
        .toolbar { toolbar(preset) }
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: {
            Text("This can't be undone.")
        }
        .onChange(of: preset.isScene) { _, isScene in if isScene { tab = .effects } }
        .onAppear {
            if reduceMotion { live = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * Motion.slow) {
                withAnimation(.easeIn(duration: 0.3)) { live = true }
            }
        }
    }

    // MARK: Preview

    private func previewPane(_ preset: Preset) -> some View {
        VStack(spacing: layout.sectionGap) {
            Spacer(minLength: 0)
            ZStack {
                StyleThumb(preset: preset)
                    .heroGeometry(id, in: hero)
                if live && !DemoHooks.stillPreviews {
                    MetalPreview(preset: preset, source: model.library.source,
                                 location: model.locationTuple, store: model.store)
                        .transition(.opacity)
                }
            }
            .aspectRatio(screenAspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(.white.opacity(0.12)))
            // Layered shadow: a tight contact shadow plus a wide, soft lift.
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.30), radius: 34, y: 18)
            .onTapGesture(count: 2) {
                ScreensaverPreviewController.shared.present(
                    preset: preset, source: model.library.source, store: model.store)
            }
            .help("Double-click for a full-screen preview")

            DestinationBar(id: id)
            Spacer(minLength: 0)
        }
    }

    private var screenAspect: CGFloat {
        guard let f = NSScreen.main?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ binding: Binding<Preset>, name: String) -> some View {
        let isScene = binding.wrappedValue.isScene
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: layout.itemGap) {
                // A long name wraps (up to 3 lines) instead of running off the card.
                TextField("Name", text: binding.name, axis: .vertical)
                    .textFieldStyle(.plain)
                    .textRole(.inspectorTitle)
                    .lineLimit(1...3)
                    .help(name)
                // Scenes have no Source tab. Their note takes the tab bar's slot, which
                // keeps the tabs' height, so the list below starts at the same y for every
                // style. The note is one line (full text in the tooltip): a wrapped note
                // would outgrow the slot at large text sizes and push a scene's list down.
                ZStack(alignment: .leading) {
                    SegmentedChoice(title: "Section",
                                    selection: $tab.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion)),
                                    options: Tab.allCases.map { ($0.rawValue, $0) })
                    .opacity(isScene ? 0 : 1)
                    .disabled(isScene)
                    .accessibilityHidden(isScene)
                    if isScene {
                        Text("Scenes don't use the shared source.")
                            .textRole(.caption).foregroundStyle(.secondary)
                            .truncating("Scenes draw themselves — the shared source isn't used.")
                    }
                }
            }
            .padding([.horizontal, .top], layout.cardPadding)
            .padding(.bottom, layout.itemGap)
            Divider().opacity(0.6)
                .padding(.horizontal, layout.cardPadding)

            ZStack {
                if tab == .source && !isScene {
                    // Same edges as the Effects list: content on edge A, and its first line
                    // as far below the divider as the list's first row, so switching tabs
                    // doesn't shift anything. The inspector's own metrics (not a new root),
                    // so both tabs share one set of gaps.
                    ScrollView {
                        SourceEditor(source: model.sourceBinding, model: model, isLayoutRoot: false)
                            .padding(.horizontal, layout.cardPadding)
                            .padding(.top, EffectStackView.listTopInset + layout.labelGap)
                            .padding(.bottom, layout.cardPadding)
                    }
                    .transition(.opacity)
                } else {
                    EffectStackView(preset: binding, model: model)
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ preset: Preset) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.closeEditor() } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to all styles (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                ScreensaverPreviewController.shared.present(
                    preset: preset, source: model.library.source, store: model.store)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .help("Full-screen preview — move the mouse or press any key to exit")

            Menu {
                Button("Duplicate") { model.duplicate(id).map { model.edit($0) } }
                Button("Export Style…") { model.exportPreset(id) }
                Divider()
                if wallpaper.isAvailable {
                    if wallpaper.styleID == id {
                        Button("Stop Wallpaper") { wallpaper.stop() }
                    } else {
                        Button("Set as Wallpaper") { wallpaper.set(id) }
                    }
                }
                Button("Save Image…") { model.exportSelectedAsImage(id) }
                Button("Set as Desktop Picture (Still)") { model.setSelectedAsWallpaper(id) }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Duplicate, export, or delete this style")
        }
    }
}

extension TextRole {
    /// The style's name at the top of the inspector (macOS .title3, 15 pt semibold).
    /// Layout.swift has no title3 role; this one is local to the editor.
    static let inspectorTitle = TextRole(style: .title3, weight: .semibold)
}

/// Under the editor preview: where this style plays, as glass buttons. They wrap onto a
/// second centred line when the preview column is too narrow, instead of truncating.
/// Every title is role-sized (`ScaledControlLabel`), so the editor's main actions grow with
/// the text like everything around them; `.adaptiveControlSize` steps the bezels.
private struct DestinationBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.layout) private var layout
    let id: UUID

    var body: some View {
        let lineup = model.screensaverLineup
        let only = lineup.playlist == [id]
        let inPlaylist = lineup.playlist.contains(id)
        let playlistLabel = inPlaylist ? "In Playlist" : "Add to Screensaver"
        let wallpaperLabel = wallpaper.styleID == id ? "Stop Wallpaper" : "Set as Wallpaper"
        GlassGroup(spacing: layout.controlGap) {
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .center) {
                if only {
                    DestinationPill(title: "Your Screensaver", systemImage: "checkmark.circle.fill")
                } else {
                    Button { Motion.run { model.playAsScreensaver(id) } } label: {
                        ScaledControlLabel(title: "Play as Screensaver", systemImage: "play.fill")
                    }
                    .glassButton(.prominent)
                    .help("Play as Screensaver — make this the only style your screensaver shows")
                    Button { Motion.run { model.togglePlaylist(id) } } label: {
                        ScaledControlLabel(title: playlistLabel, systemImage: inPlaylist ? "checkmark" : "plus")
                    }
                    .glassButton()
                    .help(inPlaylist ? "In Playlist — click to remove it from the screensaver playlist"
                                     : "Add to Screensaver — rotate this with the other styles in the playlist")
                }
                if lineup.night == id {
                    DestinationPill(title: "At Night", systemImage: "moon.fill")
                }
                if wallpaper.isAvailable {
                    Button { Motion.run { wallpaper.toggle(id) } } label: {
                        ScaledControlLabel(title: wallpaperLabel, systemImage: "photo.artframe")
                    }
                    .glassButton()
                    .help(wallpaperLabel)
                }
            }
            .adaptiveControlSize(.large)
        }
        .motion(Motion.smooth, value: lineup)
    }
}

/// A status capsule among the destination buttons ("Your Screensaver", "At Night"). It is
/// sized by an invisible glass button with the same label, so at every control size and
/// text size a pill is exactly as tall, padded and round as the buttons beside it; the
/// visible capsule is plain (non-interactive) glass with a medium-weight title.
private struct DestinationPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Button {} label: { label }
            .glassButton()
            .hidden()
            .overlay {
                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassSurface(.regular, in: Capsule())
            }
            .help(title)
            .accessibilityElement(children: .combine)
    }

    private var label: some View {
        ScaledControlLabel(title: title, systemImage: systemImage, role: .bodyEmphasis)
            .lineLimit(1)
    }
}
