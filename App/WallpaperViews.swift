//  WallpaperViews.swift — the live wallpaper's UI: the menu bar item (shown only
//  while a wallpaper is on, since the wallpaper lives as long as the app does) and
//  the Settings section.

import SwiftUI
import ServiceManagement

// MARK: - Menu bar

struct WallpaperMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared

    private var scenes: [Preset] { model.library.presets.filter(\.isScene) }
    private var looks: [Preset] { model.library.presets.filter { !$0.isScene } }

    var body: some View {
        Text("Wallpaper: \(wallpaper.currentPreset?.name ?? "—")")
        if let status = wallpaper.statusText {
            Text(status)
        }
        Divider()
        styleMenu("Scenes", scenes)
        if !looks.isEmpty { styleMenu("Looks", looks) }
        Button(wallpaper.userPaused ? "Resume" : "Pause") { wallpaper.togglePause() }
        Divider()
        Button("Open DotStudio") { wallpaper.openMainWindow() }
        Button("Stop Wallpaper") { wallpaper.stop() }
        Divider()
        Button("Quit DotStudio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func styleMenu(_ title: String, _ presets: [Preset]) -> some View {
        Menu(title) {
            ForEach(presets) { p in
                Toggle(p.name, isOn: Binding(get: { wallpaper.settings.presetID == p.id },
                                             set: { if $0 { wallpaper.use(p.id) } }))
            }
        }
    }
}

/// Menu bar icon. Also hands the controller SwiftUI's openWindow, so "Open DotStudio"
/// works after the main window was closed.
struct WallpaperMenuLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "circle.grid.3x3.fill")
            .onAppear {
                WallpaperController.shared.registerOpenMainWindow { openWindow(id: DotStudioApp.mainWindowID) }
            }
    }
}

// MARK: - Settings

struct WallpaperSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Section("Live Wallpaper") {
            Toggle("Use a style as your desktop wallpaper", isOn: Binding(
                get: { wallpaper.isActive },
                set: { wallpaper.setEnabled($0) }))
            Picker("Style", selection: Binding(
                get: { wallpaper.settings.presetID },
                set: { newID in
                    guard let id = newID else { return }
                    if wallpaper.isActive { wallpaper.use(id) } else { wallpaper.update { $0.presetID = id } }
                })) {
                if wallpaper.settings.presetID.flatMap(model.preset) == nil { Text("None").tag(UUID?.none) }
                ForEach(model.library.presets) { p in Text(p.name).tag(UUID?.some(p.id)) }
            }
            Picker("Frame Rate", selection: Binding(
                get: { wallpaper.settings.frameRate },
                set: { v in wallpaper.update { $0.frameRate = v } })) {
                ForEach(WallpaperSettings.FrameRate.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            Picker("Quality", selection: Binding(
                get: { wallpaper.settings.quality },
                set: { v in wallpaper.update { $0.quality = v } })) {
                ForEach(WallpaperSettings.Quality.allCases) { q in Text(q.title).tag(q) }
            }
            .pickerStyle(.segmented)
            Toggle("Freeze on battery", isOn: Binding(
                get: { wallpaper.settings.freezeOnBattery },
                set: { v in wallpaper.update { $0.freezeOnBattery = v } }))
            Toggle("Open DotStudio at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setOpenAtLogin))
            if loginStatus == .requiresApproval {
                Text("Allow DotStudio in System Settings › General › Login Items.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.orange)
            }
            Text("The wallpaper plays while DotStudio is open — closing the window keeps it running from the menu bar. It pauses whenever windows cover the desktop, the screen locks or sleeps, the screensaver starts, or Low Power Mode is on, and holds still when your Mac runs hot. On battery it plays at 30 fps, or holds a still frame if Freeze on battery is on. Balanced quality renders at three-quarter resolution on Retina displays.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
