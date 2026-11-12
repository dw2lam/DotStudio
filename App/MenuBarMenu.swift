//  MenuBarMenu.swift — the DotStudio menu-bar item: shown whenever menu-bar mode is on
//  (AppPresence) or a live wallpaper plays. One menu, top to bottom:
//
//      [music — MenuBarMusicSlot, MusicSlots.swift]
//      Screensaver: <what plays now>          Play as Screensaver ▸ (Scenes / Looks)
//        (several displays, some with a style of their own: "<display>: <style>" per display)
//        | Screensaver: Not installed / Not selected   Set Up Screensaver… (the main window)
//      ───
//      Wallpaper: <style> | Off  (+ status)   ✓ Same as Screensaver, Set as Wallpaper ▸, Pause, Stop
//                                             | Set “X” as Wallpaper, Same as Screensaver, Set as Wallpaper ▸
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
        let _ = Perf.body("DotStudioMenu")
        MenuBarMusicSlot()      // the track + Play/Pause, Previous, Next while a song shows (MusicSlots.swift)
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

/// The screensaver's line: what plays right now, and quick picks that — like "Play as
/// Screensaver" everywhere in the app — make one style the whole lineup (the night style, if
/// any, stays; App/Destinations.swift). So the check marks the style that plays alone; while
/// several rotate none is checked, and the submenu says a pick replaces the rotation.
/// While the screensaver isn't installed or chosen in System Settings, the line says so and
/// leads to the main window's setup strip instead (picking a style there would seem to do nothing).
struct ScreensaverMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var roster = DisplayRoster.shared

    var body: some View {
        let _ = Perf.body("ScreensaverMenu")
        switch model.setupStatus {
        case .ready:
            let lineup = model.screensaverLineup
            let now = model.nowPlayingID.flatMap(model.preset)?.name ?? "—"
            let pins = model.screensaverPins
            if roster.displays.contains(where: { pins[$0.key] != nil }) {
                // Some displays play a style of their own: one line per display.
                Text("Screensaver")
                ForEach(roster.displays) { d in
                    let style = pins[d.key].flatMap { model.preset($0.presetID) }?.name ?? now
                    Text("\(menuName(d.name, limit: 24)): \(menuName(style, limit: 26))")
                }
            } else {
                Text("Screensaver: \(menuName(now))")
            }
            if lineup.rotates {
                Text("Rotating \(lineup.playlist.count) styles")
            }
            if !model.library.presets.isEmpty {
                MenuBarStylePicker(title: "Play as Screensaver", presets: model.library.presets,
                                   note: lineup.rotates ? "Plays only the style you pick, instead of rotating" : nil,
                                   isChosen: { !lineup.rotates && lineup.playlist.first == $0 },
                                   choose: { model.playAsScreensaver($0) })
            }
        case .notInstalled, .notChosen:
            Text(model.setupStatus == .notInstalled ? "Screensaver: Not installed" : "Screensaver: Not selected")
            Button("Set Up Screensaver\u{2026}") { AppPresence.shared.showMainWindow() }
        }
    }
}

/// A submenu of styles: an optional note, then Scenes and Looks, each under its own header,
/// the chosen one checked.
struct MenuBarStylePicker: View {
    let title: String
    let presets: [Preset]
    var note: String? = nil
    let isChosen: (UUID) -> Bool
    let choose: (UUID) -> Void

    var body: some View {
        Menu(title) {
            if let note { Text(note) }
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
        let _ = Perf.body("DotStudioMenuLabel")
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
