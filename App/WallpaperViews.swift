//  WallpaperViews.swift — the live wallpaper's UI: its items in the DotStudio menu-bar menu
//  (MenuBarMenu.swift) and the Settings section.

import SwiftUI

// MARK: - Menu bar

/// The live wallpaper's items in the DotStudio menu: what's on the desktop, "Same as
/// Screensaver" (checked while it follows the screensaver), switch style, pause / resume, stop —
/// or, while it's off, "Set “X” as Wallpaper", "Same as Screensaver" (starts it in step with the
/// screensaver) and a style to start with. Same words as the rest of the app ("Set as
/// Wallpaper", "Same as Screensaver"), in both states.
struct WallpaperMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared
    @ObservedObject private var roster = DisplayRoster.shared

    var body: some View {
        let synced = wallpaper.isActive && wallpaper.followsScreensaver
        if wallpaper.isActive {
            let lines = perDisplay(synced: synced)
            if lines.isEmpty {
                Text("Wallpaper: \(menuName(shownName))")
            } else {
                // Some displays play a style of their own: one line per display.
                Text("Wallpaper")
                ForEach(lines, id: \.self) { Text($0) }
            }
            if let status = wallpaper.statusText {
                Text(status)
            }
            sameAsScreensaver(synced)
            MenuBarStylePicker(title: "Set as Wallpaper", presets: model.library.presets,
                               isChosen: { !synced && wallpaper.settings.presetID == $0 },
                               choose: { WallpaperSlot.shared.set($0) })
            Button(wallpaper.userPaused ? "Resume Wallpaper" : "Pause Wallpaper") { wallpaper.togglePause() }
            Button("Stop Wallpaper") { wallpaper.stop() }
        } else {
            Text("Wallpaper: Off")
            if let first = startStyle {
                Button("Set \u{201C}\(menuName(first.name, limit: 24))\u{201D} as Wallpaper") { WallpaperSlot.shared.set(first.id) }
                sameAsScreensaver(false)
                MenuBarStylePicker(title: "Set as Wallpaper", presets: model.library.presets,
                                   isChosen: { _ in false },
                                   choose: { WallpaperSlot.shared.set($0) })
            }
        }
    }

    /// "<display>: <style>" per connected display, when some display plays a style of its own
    /// (the wallpaper's own, or — synced — the screensaver's); empty otherwise.
    /// What the desktop shows: the shared pick — or, with every connected display on a style of
    /// its own (one display, pinned), that style.
    private var shownName: String {
        let lineup = DisplayLineup(model: model, displays: roster.displays, wallpaperShared: wallpaper.currentPreset?.id,
                                   wallpaperPins: wallpaper.settings.displayStyles,
                                   synced: wallpaper.isActive && wallpaper.followsScreensaver)
        return (lineup.wallpaperNow ?? wallpaper.currentPreset?.id).flatMap(model.preset)?.name ?? "—"
    }

    private func perDisplay(synced: Bool) -> [String] {
        guard roster.isMulti || roster.hasPin(synced ? model.screensaverPins : wallpaper.settings.displayStyles,
                                              alive: { model.preset($0) != nil }) else { return [] }
        let lineup = DisplayLineup(model: model, displays: roster.displays,
                                   wallpaperShared: wallpaper.currentPreset?.id,
                                   wallpaperPins: wallpaper.settings.displayStyles, synced: synced)
        guard !(synced ? lineup.screensaverPinned : lineup.wallpaperPinned).isEmpty else { return [] }
        return roster.displays.map { d in
            "\(menuName(d.name, limit: 24)): \(menuName(lineup.wallpaper[d.key].flatMap(model.preset)?.name ?? "—", limit: 26))"
        }
    }

    /// Checked while the desktop follows the screensaver. Choosing it while the wallpaper is
    /// off starts it, in step; unchecking keeps the style on screen as the wallpaper's own.
    private func sameAsScreensaver(_ on: Bool) -> some View {
        Toggle("Same as Screensaver", isOn: Binding(get: { on },
                                                    set: { wallpaper.setFollowsScreensaver($0) }))
    }

    /// What "Set “X” as Wallpaper" starts: the style it played last, else what the screensaver plays.
    private var startStyle: Preset? {
        wallpaper.settings.presetID.flatMap(model.preset)
            ?? model.library.activeID.flatMap(model.preset)
            ?? model.library.presets.first
    }
}

/// A style name short enough for a one-line menu item. Real menu items never wrap: a long
/// name would make the whole menu (or pop-up) as wide as the name. Keeps the start and the
/// end, which is where names differ ("… Remaster", "… 2026"). 32 characters keeps
/// "Wallpaper: <name>" on one line at the menu's own width.
func menuName(_ name: String, limit: Int = 32) -> String {
    guard name.count > limit else { return name }
    let headCount = limit * 5 / 8                 // 20 of 32: most of the name's start
    let head = name.prefix(headCount).trimmingCharacters(in: .whitespaces)
    let tail = name.suffix(limit - headCount - 1).trimmingCharacters(in: .whitespaces)
    return "\(head)…\(tail)"
}

// MARK: - Settings

struct WallpaperSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared
    @ScaledLength(relativeTo: .body) private var popUpMaxWidth: CGFloat = SettingsMetrics.popUpMaxWidth
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The Live Wallpaper pane (what plays) or the Power Saving pane (how it saves power).
    enum Part { case wallpaper, power }
    var part: Part = .wallpaper

    var body: some View {
        switch part {
        case .wallpaper: wallpaperSection
        case .power: powerSections
        }
    }

    private var wallpaperSection: some View {
        Section {
            Toggle("Use a style as your desktop wallpaper", isOn: Binding(
                get: { wallpaper.isActive },
                set: { wallpaper.setEnabled($0) }))
                .formSwitchSize()
            // The screensaver's lineup instead of a style of its own (turning it on starts the
            // wallpaper); persisted in wallpaper.json, with Library.syncTimeBase for the saver.
            Toggle("Same as Screensaver", isOn: Binding(
                get: { wallpaper.isActive && wallpaper.followsScreensaver },
                set: { wallpaper.setFollowsScreensaver($0) }))
                .formSwitchSize()
            LabeledContent("Style") {
                if wallpaper.followsScreensaver && wallpaper.isActive {
                    // What the desktop shows right now; it changes with the screensaver.
                    let now = wallpaper.currentPreset?.name ?? "—"
                    Text(menuName(now))
                        .textRole(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: popUpMaxWidth, alignment: .trailing)
                        .help("Same as Screensaver — now \(now)")
                } else {
                    stylePicker
                        .frame(maxWidth: popUpMaxWidth, alignment: .trailing)   // a long name truncates, never squeezes "Style"
                        .help(wallpaper.settings.presetID.flatMap(model.preset)?.name ?? "None")
                }
            }
            DemoSettingRow(title: "Quality", detail: qualityDetail, demo: .quality(wallpaper.settings.quality)) {
                ScaledSegmentedPicker(title: "Quality", selection: Binding(
                    get: { wallpaper.settings.quality },
                    set: { v in wallpaper.update { $0.quality = v } }),
                    options: WallpaperSettings.Quality.allCases.map { ($0.title, $0) },
                    fills: true)
            }
            // A still of the wallpaper as the desktop picture macOS shows when locked (LockScreenPicture).
            DemoSettingRow(title: "Lock & login screen picture",
                           detail: wallpaper.settings.lockScreen
                               ? "A still of your wallpaper shows when your Mac locks."
                               : "The lock screen keeps your own picture.",
                           demo: .lockScreen(on: wallpaper.settings.lockScreen), inlineControl: true) {
                Toggle("Use as lock & login screen picture", isOn: Binding(
                    get: { wallpaper.settings.lockScreen },
                    set: { wallpaper.setLockScreen($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .formSwitchSize()
            }
        } header: {
            SettingsHeader("Live Wallpaper")
        } footer: {
            SettingsNote("Plays while DotStudio is open — closing the window keeps it running from the menu bar. Same as Screensaver plays exactly what the screensaver shows, in step.")
        }

    }

    // Power saving, the way a laptop is used: what plays plugged in, what plays on battery,
    // and in both what happens while another app is focused. Each row acts out its current
    // choice in a little animated Mac (WallpaperDemos.swift).
    @ViewBuilder private var powerSections: some View {
        Section {
            DemoSettingRow(title: "Frame Rate", detail: frameRateDetail,
                           demo: .frameRate(wallpaper.settings.frameRate)) {
                ScaledSegmentedPicker(title: "Frame Rate", selection: Binding(
                    get: { wallpaper.settings.frameRate },
                    set: { v in wallpaper.update { $0.frameRate = v } }),
                    options: [("Balanced", .balanced), ("Smooth", .smooth)],
                    fills: true)
            }
            otherAppRow(\.otherAppPluggedIn)
        } header: {
            powerHeader("When Plugged In", symbol: "powerplug")
        }

        Section {
            DemoSettingRow(title: "Playback", detail: batteryDetail,
                           demo: .battery(wallpaper.settings.batteryMode)) {
                ScaledSegmentedPicker(title: "Playback on battery", selection: Binding(
                    get: { wallpaper.settings.batteryMode },
                    set: { v in wallpaper.update { $0.batteryMode = v } }),
                    options: WallpaperSettings.BatteryMode.allCases.map { ($0.title, $0) },
                    fills: true)
            }
            otherAppRow(\.otherAppOnBattery)
        } header: {
            powerHeader("On Battery", symbol: "battery.75percent")
        } footer: {
            SettingsNote("Always paused while a full-screen app or windows cover the desktop, the screen is locked or asleep, or the screensaver runs. Held still in Low Power Mode or when your Mac runs hot.")
        }
    }

    // One line each, describing the current choice (the demo beside it shows it).
    private var qualityDetail: String {
        switch wallpaper.settings.quality {
        case .full: return "Sharpest, at your display's full resolution."
        case .balanced: return "Three-quarter resolution — looks the same, costs less."
        case .efficient: return "Standard resolution — softest, lightest on the GPU."
        }
    }

    private var frameRateDetail: String {
        wallpaper.settings.frameRate == .balanced
            ? "30 frames a second — smooth enough, half the work."
            : "Your display's own rate, up to 120 fps — silkiest, uses more power."
    }

    private var batteryDetail: String {
        switch wallpaper.settings.batteryMode {
        case .full: return "Plays as when plugged in, up to 30 fps."
        case .efficient: return "20 fps at lower resolution — about a quarter of the work."
        case .still: return "Holds one frame until you plug in."
        }
    }

    /// Pause (hold the frame) while an app other than DotStudio or the Finder is in front —
    /// stored per power source as WallpaperSettings.OtherAppMode.
    private func otherAppRow(_ key: WritableKeyPath<WallpaperSettings, WallpaperSettings.OtherAppMode>) -> some View {
        let pauses = wallpaper.settings[keyPath: key] == .pause
        return DemoSettingRow(title: "Pause behind other apps",
                              detail: pauses ? "Holds the frame while you work in another app. Click the desktop to play again."
                                             : "Keeps playing behind other apps while some desktop shows.",
                              demo: .otherApp(pauses: pauses), inlineControl: true) {
            Toggle("Pause behind other apps", isOn: Binding(
                get: { pauses },
                set: { on in wallpaper.update { $0[keyPath: key] = on ? .pause : .keepPlaying } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .formSwitchSize()
        }
    }

    private func powerHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).textRole(.headline)
    }

    private var styleSelection: Binding<UUID?> {
        Binding(get: { wallpaper.settings.presetID },
                set: { newID in
                    guard let id = newID else { return }
                    if wallpaper.isActive { wallpaper.use(id) } else { wallpaper.update { $0.presetID = id } }
                })
    }

    @ViewBuilder private var styleChoices: some View {
        if wallpaper.settings.presetID.flatMap(model.preset) == nil { Text("None").tag(UUID?.none) }
        ForEach(model.library.presets) { p in Text(menuName(p.name)).tag(UUID?.some(p.id)) }
    }

    /// The stock pop-up while its 13-pt title matches the row labels; from .xxLarge (where the
    /// segmented pickers switch to role-sized titles too) a pull-down whose title follows the
    /// text size, with the same checkmarked list inside.
    @ViewBuilder private var stylePicker: some View {
        if typeSize < SettingsMetrics.scaledControlsFrom {
            Picker("Style", selection: styleSelection) { styleChoices }
                .labelsHidden()
        } else {
            Menu {
                Picker("Style", selection: styleSelection) { styleChoices }
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                Text(menuName(wallpaper.settings.presetID.flatMap(model.preset)?.name ?? "None"))
                    .textRole(.body)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
