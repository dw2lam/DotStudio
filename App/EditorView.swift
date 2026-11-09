//  EditorView.swift — edit one style: big live preview on the left, inspector on the right.

import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared
    let id: UUID
    @State private var tab: Tab = .effects
    @State private var confirmDelete = false

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
            Divider()
            inspector(binding)
                .frame(width: 340)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(preset.name)
        .navigationSubtitle(preset.isScene ? "Scene" : "Look")
        .toolbar { toolbar(preset) }
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: {
            Text("This can't be undone.")
        }
        .onChange(of: preset.isScene) { _, isScene in if isScene { tab = .effects } }
    }

    // MARK: Preview

    private func previewPane(_ preset: Preset) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            MetalPreview(preset: preset, source: model.library.source,
                         location: model.locationTuple, store: model.store)
                .aspectRatio(screenAspect, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            statusLine
            Spacer(minLength: 0)
        }
        .padding(28)
    }

    private var screenAspect: CGFloat {
        guard let f = NSScreen.main?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    @ViewBuilder private var statusLine: some View {
        let role = model.role(of: id)
        HStack(spacing: 10) {
            switch (model.playbackMode, role) {
            case (.single, .active):
                Label("This is your screensaver", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case (.rotate, .rotating):
                Label("In your screensaver rotation", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case (.dayNight, .day), (.dayNight, .night), (.dayNight, .dayAndNight):
                RoleBadge(role: role)
            default:
                Button { model.useAsScreensaver(id) } label: {
                    Label("Use as Screensaver", systemImage: "checkmark.circle")
                }
                .help(model.playbackMode == .single ? "Make this the style that plays"
                      : "Switch to One Style mode and play this")
            }
        }
        .font(.callout)
        .frame(height: 24)
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
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()

            if tab == .source && !isScene {
                ScrollView {
                    SourceEditor(source: model.sourceBinding, model: model)
                        .padding(16)
                }
            } else {
                EffectStackView(preset: binding, model: model)
            }
        }
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
                Button("Save Image…") { model.exportSelectedAsImage(id) }
                Button("Use as Wallpaper") { wallpaper.use(id) }
                    .disabled(wallpaper.isActive && wallpaper.settings.presetID == id)
                if wallpaper.isActive {
                    Button("Stop Wallpaper") { wallpaper.stop() }
                }
                Button("Set as Desktop Picture (Still)") { model.setSelectedAsWallpaper(id) }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Duplicate, export, or delete this style")
        }
    }
}
