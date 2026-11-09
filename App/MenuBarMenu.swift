//  MenuBarMenu.swift — the DotStudio menu-bar item: shown whenever menu-bar mode is on
//  (AppPresence) or a live wallpaper plays. One menu, top to bottom:
//
//      [music — MenuBarMusicSlot, MusicSlots.swift]
//      Screensaver: <what plays now>          Choose Screensaver ▸ (Scenes / Looks)
//      ───
//      Wallpaper: <style> | Off  (+ status)   Change / Choose Wallpaper ▸, Pause, Stop | Use as Wallpaper
//      ───
//      Open DotStudio · Settings… · Check for Updates…
//      ───
//      Quit DotStudio
//
//  Every action that shows a window goes through AppPresence, which brings the Dock icon
//  back and activates first.

import SwiftUI

struct DotStudioMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        MenuBarMusicSlot()      // MUSIC SLOT — renders nothing until the music stage fills it
        ScreensaverMenu()
        Divider()
        WallpaperMenu()
        Divider()
        Button("Open DotStudio") { AppPresence.shared.showMainWindow() }
        Button("Settings…") { AppPresence.shared.showSettings() }
            .keyboardShortcut(",")
        Button(updateTitle) { AppPresence.shared.checkForUpdates(updates) }
            .disabled(!updates.canCheck && !isUpdateReady)
        Divider()
        Button("Quit DotStudio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var isUpdateReady: Bool {
        if case .readyToInstall = updates.state { return true } else { return false }
    }

    private var updateTitle: String { isUpdateReady ? "Restart to Update" : "Check for Updates…" }
}

/// The screensaver's line: what plays right now, and quick picks that make one style the
/// whole lineup (the night style, if any, stays) — App/Destinations.swift.
struct ScreensaverMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let lineup = model.screensaverLineup
        let now = model.nowPlayingID.flatMap(model.preset)?.name ?? "—"
        Text("Screensaver: \(menuName(now))")
        if lineup.rotates {
            Text("Rotating \(lineup.playlist.count) styles")
        }
        if !model.library.presets.isEmpty {
            MenuBarStylePicker(title: "Choose Screensaver", presets: model.library.presets,
                               isChosen: { lineup.playlist.contains($0) },
                               choose: { model.playAsScreensaver($0) })
        }
    }
}

/// A submenu of styles: Scenes, then Looks, each under its own header, the chosen ones checked.
struct MenuBarStylePicker: View {
    let title: String
    let presets: [Preset]
    let isChosen: (UUID) -> Bool
    let choose: (UUID) -> Void

    var body: some View {
        Menu(title) {
            section("Scenes", presets.filter(\.isScene))
            section("Looks", presets.filter { !$0.isScene })
        }
    }

    @ViewBuilder private func section(_ header: String, _ list: [Preset]) -> some View {
        if !list.isEmpty {
            Section(header) {
                ForEach(list) { p in
                    Toggle(menuName(p.name), isOn: Binding(get: { isChosen(p.id) },
                                                           set: { _ in choose(p.id) }))
                }
            }
        }
    }
}

/// The menu-bar icon: DotStudio's dot grid as a template symbol — filled while a live
/// wallpaper is playing, outlined otherwise. Also hands AppPresence (and the wallpaper
/// controller) SwiftUI's openWindow / openSettings, so the menu can open windows after
/// the main window was closed or never opened (login launch).
struct DotStudioMenuLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var wallpaper = WallpaperController.shared

    var body: some View {
        let live = wallpaper.isActive && !wallpaper.userPaused
        Image(systemName: live ? "circle.grid.3x3.fill" : "circle.grid.3x3")
            .accessibilityLabel("DotStudio")
            .accessibilityValue(live ? "Live wallpaper playing" : "")
            .onAppear {
                let open = { openWindow(id: DotStudioApp.mainWindowID) }
                AppPresence.shared.register(openMainWindow: open, openSettings: { openSettings() })
                WallpaperController.shared.registerOpenMainWindow(open)
            }
    }
}
