//  ContentView.swift — sidebar + live preview + inspector.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmInstall = false
    @State private var installAlert = false
    @State private var installOK = false
    @State private var installMsg = ""
    @State private var installedTick = 0   // bump to re-read install status

    private var isInstalled: Bool { _ = installedTick; return Installer.isInstalled }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar { toolbarContent }
        .confirmationDialog("Install the DotStudio screensaver?", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button(isInstalled ? "Reinstall" : "Install") { doInstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies the screensaver into your Screen Savers folder. You'll then pick “DotStudio” once in Wallpaper settings; after that you switch screensavers right here.")
        }
        .alert(installOK ? "Screensaver Installed" : "Install Failed", isPresented: $installAlert) {
            if installOK {
                Button("Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
                Button("Done", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { Text(installMsg) }
    }

    private func doInstall() {
        switch Installer.install() {
        case .success:
            installOK = true
            installMsg = "“DotStudio” is ready. Open Wallpaper settings and choose it under Screen Saver. After that, switch styles anytime from the sidebar — no Settings needed."
        case .failure(let e):
            installOK = false
            installMsg = "Couldn't install the screensaver: \(e.localizedDescription)"
        }
        installedTick += 1
        // Let the confirmation dialog finish dismissing before presenting the alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { installAlert = true }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedID) {
            Section("Screensavers") {
                ForEach(model.library.presets) { preset in
                    sidebarRow(preset)
                        .tag(preset.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 264)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Button { model.addPreset() } label: { Image(systemName: "plus") }
                    .help("New style")
                Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Save selected style as a copy")
                    .disabled(model.selectedID == nil)
                Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete style")
                    .disabled(model.selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func sidebarRow(_ preset: Preset) -> some View {
        let isActive = preset.id == model.library.activeID
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = model.thumbnailer.image(for: preset, source: model.library.source) {
                        Image(nsImage: img).resizable()
                    } else {
                        Color.black
                    }
                }
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isActive ? Color.accentColor : Color.black.opacity(0.25), lineWidth: isActive ? 2 : 1))

                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(5)
                }
            }
            HStack(spacing: 5) {
                Text(preset.name).font(.system(.body, weight: .medium)).lineLimit(1)
                Spacer()
            }
            Text(effectSummary(preset)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func effectSummary(_ preset: Preset) -> String {
        let names = preset.effects.filter { $0.enabled }.map { $0.kind.displayName }
        return names.isEmpty ? "Source only" : names.joined(separator: " · ")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = model.selectedID, model.library.presets.contains(where: { $0.id == id }) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MetalPreview(preset: model.presetBinding(id).wrappedValue,
                                 source: model.library.source,
                                 store: model.store)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(16)
                    previewBar(id: id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
                InspectorView(preset: model.presetBinding(id), source: model.sourceBinding, model: model)
                    .frame(width: 340)
            }
        } else {
            ContentUnavailableView("No Screensaver Selected", systemImage: "sparkles.tv")
        }
    }

    private func previewBar(id: UUID) -> some View {
        let binding = model.presetBinding(id)
        return HStack(spacing: 14) {
            TextField("Name", text: binding.name).textFieldStyle(.roundedBorder).frame(width: 200)
            Button {
                ScreensaverPreviewController.shared.present(
                    preset: binding.wrappedValue, source: model.library.source, store: model.store)
            } label: { Label("Preview", systemImage: "play.rectangle.fill") }
                .help("Full-screen preview — move the mouse or press any key to exit")
            if id == model.library.activeID {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { model.setActive(id) } label: { Label("Use as Screensaver", systemImage: "play.circle") }
            }
            Spacer()
            Stepper(value: binding.fps, in: 15...60, step: 5) {
                Text("\(binding.wrappedValue.fps) fps").monospacedDigit().font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Toolbar + banner

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isInstalled {
                Label("Installed", systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                    .help("DotStudio is installed in your Screen Savers folder")
                    .padding(.trailing, 12)
            }
            Button {
                confirmInstall = true
            } label: {
                Label(isInstalled ? "Reinstall Screensaver" : "Install Screensaver",
                      systemImage: "square.and.arrow.down")
            }
            .padding(.leading, 6)

            Button { Installer.openScreenSaverSettings() } label: {
                Label("Wallpaper Settings", systemImage: "gearshape")
            }
        }
    }
}
