//  EditorView.swift — edit one style: a big live preview floating over the style's own
//  ambient wash, and a glass inspector on the right.

import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.heroNamespace) private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        HStack(spacing: 0) {
            previewPane(preset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            inspector(binding)
                .frame(width: 344)
                .glassCard(cornerRadius: 24)
                .padding(.vertical, 14)
                .padding(.trailing, 14)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
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
        VStack(spacing: 20) {
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
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
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
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
    }

    private var screenAspect: CGFloat {
        guard let f = NSScreen.main?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ binding: Binding<Preset>) -> some View {
        let isScene = binding.wrappedValue.isScene
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: binding.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                if isScene {
                    Text("Scenes draw themselves — the shared source isn't used.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Section", selection: $tab.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion))) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider().opacity(0.6)

            ZStack {
                if tab == .source && !isScene {
                    ScrollView {
                        SourceEditor(source: model.sourceBinding, model: model)
                            .padding(16)
                    }
                    .transition(.opacity)
                } else {
                    EffectStackView(preset: binding, model: model)
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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

/// Under the editor preview: where this style plays, as glass buttons.
private struct DestinationBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    let id: UUID

    var body: some View {
        let lineup = model.screensaverLineup
        let only = lineup.playlist == [id]
        let inPlaylist = lineup.playlist.contains(id)
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if only {
                    Label("Your Screensaver", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).frame(height: 30)
                        .glassSurface(.regular, in: Capsule())
                } else {
                    Button { Motion.run { model.playAsScreensaver(id) } } label: {
                        Label("Play as Screensaver", systemImage: "play.fill")
                    }
                    .glassButton(.prominent)
                    Button { Motion.run { model.togglePlaylist(id) } } label: {
                        Label(inPlaylist ? "In Playlist" : "Add to Screensaver",
                              systemImage: inPlaylist ? "checkmark" : "plus")
                    }
                    .glassButton()
                    .help(inPlaylist ? "Remove from the screensaver playlist" : "Rotate this with the other styles in the playlist")
                }
                if lineup.night == id {
                    Label("At Night", systemImage: "moon.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).frame(height: 30)
                        .glassSurface(.regular, in: Capsule())
                }
                if wallpaper.isAvailable {
                    Button { Motion.run { wallpaper.toggle(id) } } label: {
                        Label(wallpaper.styleID == id ? "Stop Wallpaper" : "Set as Wallpaper",
                              systemImage: "photo.artframe")
                    }
                    .glassButton()
                }
            }
            .controlSize(.large)
        }
        .motion(Motion.smooth, value: lineup)
    }
}
