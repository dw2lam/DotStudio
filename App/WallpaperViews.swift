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
        Text("Wallpaper: \(menuName(wallpaper.currentPreset?.name ?? "—"))")
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
                Toggle(menuName(p.name), isOn: Binding(get: { wallpaper.settings.presetID == p.id },
                                             set: { if $0 { wallpaper.use(p.id) } }))
            }
        }
    }
}

/// A style name short enough for a one-line menu item. Real menu items never wrap: a long
/// name would make the whole menu (or pop-up) as wide as the name. Keeps the start and the
/// end, which is where names differ ("… Remaster", "… 2026"). 32 characters keeps
/// "Wallpaper: <name>" on one line at the menu's own width.
private func menuName(_ name: String, limit: Int = 32) -> String {
    guard name.count > limit else { return name }
    let headCount = limit * 5 / 8                 // 20 of 32: most of the name's start
    let head = name.prefix(headCount).trimmingCharacters(in: .whitespaces)
    let tail = name.suffix(limit - headCount - 1).trimmingCharacters(in: .whitespaces)
    return "\(head)…\(tail)"
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
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth
    @ScaledLength(relativeTo: .body) private var popUpMaxWidth: CGFloat = SettingsMetrics.popUpMaxWidth
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("Use a style as your desktop wallpaper", isOn: Binding(
                get: { wallpaper.isActive },
                set: { wallpaper.setEnabled($0) }))
            LabeledContent("Style") {
                Picker("Style", selection: Binding(
                    get: { wallpaper.settings.presetID },
                    set: { newID in
                        guard let id = newID else { return }
                        if wallpaper.isActive { wallpaper.use(id) } else { wallpaper.update { $0.presetID = id } }
                    })) {
                    if wallpaper.settings.presetID.flatMap(model.preset) == nil { Text("None").tag(UUID?.none) }
                    ForEach(model.library.presets) { p in Text(menuName(p.name)).tag(UUID?.some(p.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: popUpMaxWidth, alignment: .trailing)   // a long name truncates, never squeezes "Style"
                .help(wallpaper.settings.presetID.flatMap(model.preset)?.name ?? "None")
            }
            // Segmented pickers share one width so their leading edges line up.
            LabeledContent("Frame Rate") {
                Picker("Frame Rate", selection: Binding(
                    get: { wallpaper.settings.frameRate },
                    set: { v in wallpaper.update { $0.frameRate = v } })) {
                    ForEach(WallpaperSettings.FrameRate.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fillingSegments(width: segmentWidth)
            }
            LabeledContent("Quality") {
                Picker("Quality", selection: Binding(
                    get: { wallpaper.settings.quality },
                    set: { v in wallpaper.update { $0.quality = v } })) {
                    ForEach(WallpaperSettings.Quality.allCases) { q in Text(q.title).tag(q) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fillingSegments(width: segmentWidth)
            }
            Toggle("Freeze on battery", isOn: Binding(
                get: { wallpaper.settings.freezeOnBattery },
                set: { v in wallpaper.update { $0.freezeOnBattery = v } }))
            Toggle("Open DotStudio at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: setOpenAtLogin))
            if loginStatus == .requiresApproval {
                Text("Allow DotStudio in System Settings › General › Login Items.")
                    .textRole(.caption).foregroundStyle(.orange).wrapping()
            } else if let loginError {
                Text(loginError).textRole(.caption).foregroundStyle(.orange).wrapping()
            }
        } header: {
            SettingsHeader("Live Wallpaper")
        } footer: {
            // Under the card rather than a row in it; two short paragraphs, not one wall.
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("The wallpaper plays while DotStudio is open — closing the window keeps it running from the menu bar. On battery it plays at 30 fps, or holds a still frame if Freeze on battery is on.")
                SettingsNote("It pauses whenever windows cover the desktop, the screen locks or sleeps, the screensaver starts, or Low Power Mode is on, and holds still when your Mac runs hot. Balanced quality renders at three-quarter resolution on Retina displays.")
            }
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
