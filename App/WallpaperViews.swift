//  WallpaperViews.swift — the live wallpaper's UI: its items in the DotStudio menu-bar menu
//  (MenuBarMenu.swift) and the Settings section.

import SwiftUI

// MARK: - Menu bar

/// The live wallpaper's items in the DotStudio menu: what's on the desktop, switch style,
/// pause / resume, stop — or, while it's off, "Use as Wallpaper" and a style to start with.
struct WallpaperMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperController.shared

    var body: some View {
        if wallpaper.isActive {
            Text("Wallpaper: \(menuName(wallpaper.currentPreset?.name ?? "—"))")
            if let status = wallpaper.statusText {
                Text(status)
            }
            MenuBarStylePicker(title: "Change Wallpaper", presets: model.library.presets,
                               isChosen: { wallpaper.settings.presetID == $0 },
                               choose: { wallpaper.use($0) })
            Button(wallpaper.userPaused ? "Resume Wallpaper" : "Pause Wallpaper") { wallpaper.togglePause() }
            Button("Stop Wallpaper") { wallpaper.stop() }
        } else {
            Text("Wallpaper: Off")
            if let first = startStyle {
                Button("Use \u{201C}\(menuName(first.name, limit: 24))\u{201D} as Wallpaper") { wallpaper.use(first.id) }
                MenuBarStylePicker(title: "Choose Wallpaper", presets: model.library.presets,
                                   isChosen: { _ in false },
                                   choose: { wallpaper.use($0) })
            }
        }
    }

    /// What "Use as Wallpaper" starts: the style it played last, else what the screensaver plays.
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
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth
    @ScaledLength(relativeTo: .body) private var popUpMaxWidth: CGFloat = SettingsMetrics.popUpMaxWidth
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section {
            Toggle("Use a style as your desktop wallpaper", isOn: Binding(
                get: { wallpaper.isActive },
                set: { wallpaper.setEnabled($0) }))
                .formSwitchSize()
            LabeledContent("Style") {
                stylePicker
                    .frame(maxWidth: popUpMaxWidth, alignment: .trailing)   // a long name truncates, never squeezes "Style"
                    .help(wallpaper.settings.presetID.flatMap(model.preset)?.name ?? "None")
            }
            // Segmented pickers share one width so their leading edges line up.
            SettingsValueRow("Frame Rate", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Frame Rate", selection: Binding(
                    get: { wallpaper.settings.frameRate },
                    set: { v in wallpaper.update { $0.frameRate = v } }),
                    options: WallpaperSettings.FrameRate.allCases.map { ($0.title, $0) },
                    fills: true)
            }
            SettingsValueRow("Quality", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Quality", selection: Binding(
                    get: { wallpaper.settings.quality },
                    set: { v in wallpaper.update { $0.quality = v } }),
                    options: WallpaperSettings.Quality.allCases.map { ($0.title, $0) },
                    fills: true)
            }
            Toggle("Freeze on battery", isOn: Binding(
                get: { wallpaper.settings.freezeOnBattery },
                set: { v in wallpaper.update { $0.freezeOnBattery = v } }))
                .formSwitchSize()
        } header: {
            SettingsHeader("Live Wallpaper")
        } footer: {
            // Under the card rather than a row in it; two short paragraphs, not one wall.
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("The wallpaper plays while DotStudio is open — closing the window keeps it running from the menu bar. On battery it plays at 30 fps, or holds a still frame if Freeze on battery is on.")
                SettingsNote("It pauses whenever windows cover the desktop, the screen locks or sleeps, the screensaver starts, or Low Power Mode is on, and holds still when your Mac runs hot. Balanced quality renders at three-quarter resolution on Retina displays.")
            }
        }
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
