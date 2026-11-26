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
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth
    @ScaledLength(relativeTo: .body) private var popUpMaxWidth: CGFloat = SettingsMetrics.popUpMaxWidth
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.consoleSettings) private var console

    /// The Live Wallpaper pane (what plays) or the Power Saving pane (how it saves power).
    enum Part { case wallpaper, power }
    var part: Part = .wallpaper

    var body: some View {
        switch part {
        case .wallpaper: wallpaperSection
        case .power:
            if console { consolePowerSections } else { powerSections }
        }
    }

    // MARK: Console power

    // The owner's Stitch design: PRESET over three big keys (CUSTOM ACTIVE when nothing
    // matches), then each power source as a module — its icon square, name and a mono line of
    // what it's set to, the Forced / Dynamic / Reactive keys, the big fps readout, the range in
    // a well, the sentence, and the "another app is focused" cards — and the automatic pauses.
    // Same settings, words and demos as Classic; both power sources (the design drew only one).
    @ViewBuilder private var consolePowerSections: some View {
        let current = PowerPreset.matching(wallpaper.settings, model.library)
        Section {
            PowerPresetPicker(current: current) { preset in
                preset.apply(wallpaper: wallpaper, model: model)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                SettingsHeader("Preset")
                Spacer(minLength: Space.s)
                if current == nil {
                    Text("Custom active").textRole(.legend).foregroundStyle(ConsoleInk.signalInk)
                }
            }
        }
        .consoleModuleSection()

        Section {
            ConsoleModule {
                ConsoleModuleHeader(symbol: PowerSource.pluggedIn.symbol, fill: PowerSource.pluggedIn.consoleTint,
                                    title: PowerSource.pluggedIn.title, summary: sourceSummary(onBattery: false)) {
                    FrameRateControl.modeKeys(source: .pluggedIn, mode: setting(\.fpsModePluggedIn))
                }
                FrameRateControl(source: .pluggedIn,
                                 mode: setting(\.fpsModePluggedIn),
                                 limit: Binding(get: { model.library.frameRate ?? 120 },
                                                set: { v in PowerPreset.setFrameRate(v, wallpaper: wallpaper, model: model) }),
                                 floor: setting(\.fpsFloorPluggedIn))
                ConsoleHairline()
                otherAppRow(\.otherAppPluggedIn)
            }
        } footer: {
            SettingsNote("The plugged-in limit is the screensaver's too. Each style plays at its own frame rate (Customize › Frame rate) up to the limit — Auto plays at the limit.")
        }
        .consoleModuleSection()

        Section {
            ConsoleModule {
                let still = wallpaper.settings.batteryMode == .still
                ConsoleModuleHeader(symbol: PowerSource.battery.symbol, fill: PowerSource.battery.consoleTint,
                                    title: PowerSource.battery.title, summary: sourceSummary(onBattery: true)) {
                    if !still { FrameRateControl.modeKeys(source: .battery, mode: setting(\.fpsModeOnBattery)) }
                }
                OptionCards(title: "Playback",
                            options: WallpaperSettings.BatteryMode.allCases.map {
                                .init(label: $0.title, value: $0, scene: .battery($0), explain: Self.batteryExplain($0))
                            },
                            selection: Binding(get: { wallpaper.settings.batteryMode },
                                               set: { v in wallpaper.update { $0.batteryMode = v } }))
                if !still {
                    FrameRateControl(source: .battery,
                                     mode: setting(\.fpsModeOnBattery),
                                     limit: Binding(get: { wallpaper.settings.batteryTopFPS },
                                                    set: { v in wallpaper.update { $0.batteryFPS = v } }),
                                     floor: setting(\.fpsFloorOnBattery))
                        .transition(.opacity)
                }
                ConsoleHairline()
                otherAppRow(\.otherAppOnBattery)
            }
        } footer: {
            SettingsNote("The screensaver keeps its own battery saving: at most 24 fps at lower resolution.")
        }
        .consoleModuleSection()

        Section {
            ConsoleModule {
                OptionCards(title: "Always", options: [
                                .init(label: "Full-screen app", value: 0, scene: .covered),
                                .init(label: "Low Power Mode", value: 1, scene: .lowPower)],
                            selection: .constant(0), fixed: true)
            }
        } header: {
            SettingsHeader("Automatically")
        } footer: {
            SettingsNote("Pauses when a full-screen app or windows cover the desktop, the screen locks or sleeps, or the screensaver runs. Holds still in Low Power Mode or when your Mac runs hot. A paused clock still turns over each minute.")
        }
        .consoleModuleSection()
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
                        .settingsText(.body)
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
            SettingsValueRow("Quality", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Quality", selection: Binding(
                    get: { wallpaper.settings.quality },
                    set: { v in wallpaper.update { $0.quality = v } }),
                    options: WallpaperSettings.Quality.allCases.map { ($0.title, $0) },
                    fills: true)
            }
            // A still of the wallpaper as the desktop picture macOS shows when locked (LockScreenPicture).
            Toggle("Use as lock & login screen picture", isOn: Binding(
                get: { wallpaper.settings.lockScreen },
                set: { wallpaper.setLockScreen($0) }))
                .formSwitchSize()
        } header: {
            SettingsHeader("Live Wallpaper")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("Plays while DotStudio is open — closing the window keeps it running from the menu bar. Same as Screensaver plays exactly what the screensaver shows, in step.")
                SettingsNote("Balanced quality draws at three-quarter resolution on Retina displays. The lock-screen picture updates when your Mac locks; turning it off restores your own picture.")
            }
        }

    }

    // Power saving the way Wallpaper Engine lays it out: a preset on top that sets everything,
    // then each power source in its own section (a coloured header tells them apart) with its
    // frame rate — a limit, and for Dynamic / Reactive the lowest it eases to, dragged on one
    // range — and its situations as rows of option cards.
    @ViewBuilder private var powerSections: some View {
        Section {
            PowerPresetPicker(current: PowerPreset.matching(wallpaper.settings, model.library)) { preset in
                preset.apply(wallpaper: wallpaper, model: model)
            }
        } header: {
            powerHeader("Preset", symbol: "slider.horizontal.3")
        }

        Section {
            FrameRateControl(source: .pluggedIn,
                             mode: setting(\.fpsModePluggedIn),
                             limit: Binding(get: { model.library.frameRate ?? 120 },
                                            set: { v in PowerPreset.setFrameRate(v, wallpaper: wallpaper, model: model) }),
                             floor: setting(\.fpsFloorPluggedIn))
            otherAppRow(\.otherAppPluggedIn)
        } header: {
            PowerSourceHeader(source: .pluggedIn, summary: sourceSummary(onBattery: false))
        } footer: {
            SettingsNote("The plugged-in limit is the screensaver's too. Each style plays at its own frame rate (Customize › Frame rate) up to the limit — Auto plays at the limit.")
        }

        Section {
            OptionCards(title: "Playback",
                        options: WallpaperSettings.BatteryMode.allCases.map {
                            .init(label: $0.title, value: $0, scene: .battery($0), explain: Self.batteryExplain($0))
                        },
                        selection: Binding(get: { wallpaper.settings.batteryMode },
                                           set: { v in wallpaper.update { $0.batteryMode = v } }))
            if wallpaper.settings.batteryMode != .still {
                FrameRateControl(source: .battery,
                                 mode: setting(\.fpsModeOnBattery),
                                 limit: Binding(get: { wallpaper.settings.batteryTopFPS },
                                                set: { v in wallpaper.update { $0.batteryFPS = v } }),
                                 floor: setting(\.fpsFloorOnBattery))
                    .transition(.opacity)
            }
            otherAppRow(\.otherAppOnBattery)
        } header: {
            PowerSourceHeader(source: .battery, summary: sourceSummary(onBattery: true))
        } footer: {
            SettingsNote("The screensaver keeps its own battery saving: at most 24 fps at lower resolution.")
        }

        Section {
            OptionCards(title: "Always", options: [
                            .init(label: "Full-screen app", value: 0, scene: .covered),
                            .init(label: "Low Power Mode", value: 1, scene: .lowPower)],
                        selection: .constant(0), fixed: true)
        } header: {
            powerHeader("Automatically", symbol: "leaf")
        } footer: {
            SettingsNote("Pauses when a full-screen app or windows cover the desktop, the screen locks or sleeps, or the screensaver runs. Holds still in Low Power Mode or when your Mac runs hot. A paused clock still turns over each minute.")
        }
    }

    /// A wallpaper setting as a binding (writes go through WallpaperController.update).
    private func setting<T>(_ key: WritableKeyPath<WallpaperSettings, T>) -> Binding<T> {
        Binding(get: { wallpaper.settings[keyPath: key] }, set: { v in wallpaper.update { $0[keyPath: key] = v } })
    }

    /// The header's one line: "Up to 120 fps · Dynamic" (on battery, "Paused" when it is).
    private func sourceSummary(onBattery: Bool) -> String {
        let w = wallpaper.settings
        if onBattery && w.batteryMode == .still { return "Paused" }
        let limit = onBattery ? w.batteryTopFPS : (model.library.frameRate ?? 120)
        let mode = w.fpsMode(onBattery: onBattery)
        let low = Int(WallpaperBudget.adapt(Double(limit), level: .busy, floor: w.fpsFloor(onBattery: onBattery).map(Double.init)))
        let rate = mode == .forced || low >= limit ? "\(limit) fps" : "\(low)–\(limit) fps"
        return "\(rate) · \(mode.title)" + (onBattery && w.batteryMode == .efficient ? " · lower resolution" : "")
    }

    private static func batteryExplain(_ m: WallpaperSettings.BatteryMode) -> String {
        switch m {
        case .full: return "plays at full resolution, at the frame rate below."
        case .efficient: return "draws at lower resolution — about a third of the pixels — at the frame rate below."
        case .still: return "holds one frame until you plug in."
        }
    }

    /// Another app in front (not full screen): keep playing, slow down, or pause — per power
    /// source, as WallpaperSettings.OtherAppMode.
    private func otherAppRow(_ key: WritableKeyPath<WallpaperSettings, WallpaperSettings.OtherAppMode>) -> some View {
        OptionCards(title: "Another app is focused",
                    options: WallpaperSettings.OtherAppMode.allCases.map { m in
                        .init(label: m.title, value: m, scene: .otherApp(m), explain: {
                            switch m {
                            case .keepPlaying: return "the wallpaper plays on behind your windows."
                            case .efficient: return "drops to 20 fps at lower resolution until you click the desktop."
                            case .pause: return "holds the frame until you click the desktop or come back to DotStudio."
                            }
                        }())
                    },
                    selection: Binding(get: { wallpaper.settings[keyPath: key] },
                                       set: { v in wallpaper.update { $0[keyPath: key] = v } }))
    }

    private func powerHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).settingsText(.headline)
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
        if console {
            // Console: a key showing the style, the same checkmarked list inside.
            Menu {
                Picker("Style", selection: styleSelection) { styleChoices }
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                HStack(spacing: Space.xs) {
                    Text(menuName(wallpaper.settings.presetID.flatMap(model.preset)?.name ?? "None"))
                        .textRole(.consoleBody)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ConsoleInk.legend)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.keycap)
            .menuIndicator(.hidden)
            .fixedSize()
        } else if typeSize < SettingsMetrics.scaledControlsFrom {
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


// MARK: - Power presets

/// One-click Power Saving setups. Each sets the frame rate, quality and every situation below;
/// changing any of them by hand makes it Custom (no preset ringed).
enum PowerPreset: String, CaseIterable, Identifiable {
    case quality, balanced, saver
    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return "Best Quality"
        case .balanced: return "Balanced"
        case .saver: return "Battery Saver"
        }
    }
    var symbol: String {
        switch self {
        case .quality: return "sparkles"
        case .balanced: return "circle.lefthalf.filled"
        case .saver: return "leaf.fill"
        }
    }
    var tint: Color {
        switch self {
        case .quality: return .purple
        case .balanced: return .blue
        case .saver: return .green
        }
    }
    /// Its square's colour in Console (the design: orange, blue, green).
    var consoleTint: Color {
        switch self {
        case .quality: return ConsoleInk.signal
        case .balanced: return ConsoleInk.blue
        case .saver: return ConsoleInk.green
        }
    }
    var summary: String {
        switch self {
        case .quality: return "120 fps at full resolution, always; 60 on battery."
        case .balanced: return "Up to 120 fps, easing off while your Mac is busy; 30 on battery."
        case .saver: return "Up to 60 fps, easing off while you work; pauses on battery."
        }
    }

    private var fps: Int { self == .saver ? 60 : 120 }
    private var mode: WallpaperSettings.FPSMode { self == .quality ? .forced : self == .balanced ? .dynamic : .reactive }
    private var batteryFPS: Int { self == .quality ? 60 : self == .balanced ? 30 : 15 }
    private var batteryMode: WallpaperSettings.FPSMode { self == .quality ? .forced : .dynamic }
    private var quality: WallpaperSettings.Quality { self == .quality ? .full : self == .balanced ? .balanced : .efficient }
    private var screensaverScale: Double? { self == .saver ? 0.5 : nil }
    private var battery: WallpaperSettings.BatteryMode { self == .quality ? .full : self == .balanced ? .efficient : .still }
    private var pluggedIn: WallpaperSettings.OtherAppMode { self == .saver ? .efficient : .keepPlaying }
    private var onBattery: WallpaperSettings.OtherAppMode { self == .saver ? .pause : .keepPlaying }

    static func matching(_ w: WallpaperSettings, _ lib: Library) -> PowerPreset? {
        allCases.first { p in
            (lib.frameRate ?? 120) == p.fps && w.fpsModePluggedIn == p.mode && w.fpsFloorPluggedIn == nil
                && w.batteryTopFPS == p.batteryFPS && w.fpsModeOnBattery == p.batteryMode && w.fpsFloorOnBattery == nil
                && w.quality == p.quality && lib.renderScale == p.screensaverScale
                && w.batteryMode == p.battery && w.otherAppPluggedIn == p.pluggedIn && w.otherAppOnBattery == p.onBattery
        }
    }

    @MainActor func apply(wallpaper: WallpaperController, model: AppModel) {
        model.library.frameRate = fps
        model.library.renderScale = screensaverScale
        model.save()
        wallpaper.update {
            $0.quality = quality
            $0.frameRate = fps > 30 ? .smooth : .balanced
            $0.fpsModePluggedIn = mode
            $0.fpsFloorPluggedIn = nil
            $0.batteryMode = battery
            $0.batteryFPS = batteryFPS
            $0.fpsModeOnBattery = batteryMode
            $0.fpsFloorOnBattery = nil
            $0.otherAppPluggedIn = pluggedIn
            $0.otherAppOnBattery = onBattery
        }
    }

    /// The plugged-in limit (Library.frameRate — the screensaver's too), and the wallpaper's
    /// old setting in step with it (so a build without the shared rate keeps about the same).
    @MainActor static func setFrameRate(_ v: Int, wallpaper: WallpaperController, model: AppModel) {
        model.library.frameRate = v
        model.save()
        wallpaper.update { $0.frameRate = v > 30 ? .smooth : .balanced }
    }
}

/// The presets as three big cards; the matching one is ringed, none when it's Custom.
private struct PowerPresetPicker: View {
    let current: PowerPreset?
    let choose: (PowerPreset) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.consoleSettings) private var console
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hovered: PowerPreset?

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console: three big keys (icon square, title, the one-line summary) side by side — a
    /// column at accessibility text sizes — the chosen one sunk with an orange edge; the plain
    /// sentence under them.
    private var consoleBody: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: Space.s)) : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s))
        return VStack(alignment: .leading, spacing: Space.s) {
            layout {
                ForEach(PowerPreset.allCases) { p in
                    Button { choose(p) } label: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(alignment: .top) {
                                ConsoleIconSquare(symbol: p.symbol, fill: p.consoleTint)
                                Spacer(minLength: 0)
                                if current == p { ConsoleLED(on: true) }
                            }
                            Text(p.title).textRole(.consoleTitle).foregroundStyle(ConsoleInk.ink)
                            Text(p.summary).textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(Space.s)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .buttonStyle(ConsoleCardStyle(face: ConsoleInk.surface, selected: current == p))
                    .accessibilityAddTraits(current == p ? [.isButton, .isSelected] : .isButton)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(current == nil ? "Custom — you've changed settings below. Pick a preset to start over."
                                : "Sets everything below. Change anything to make it your own.")
                .textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend)
                .contentTransition(.opacity)
        }
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: current)
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                ForEach(PowerPreset.allCases) { p in
                    Button { choose(p) } label: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Image(systemName: p.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(p.title).textRole(.bodyEmphasis)
                            Text(p.summary).textRole(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .fill(current == p ? p.tint.opacity(0.12) : Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .strokeBorder(current == p ? p.tint : Color.primary.opacity(hovered == p ? 0.2 : 0.08),
                                          lineWidth: current == p ? 2.5 : 1))
                        .scaleEffect(hovered == p && current != p ? 1.015 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
                    .accessibilityAddTraits(current == p ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text(current == nil ? "Custom — you've changed settings below. Pick a preset to start over."
                                : "Sets everything below. Change anything to make it your own.")
                .textRole(.callout).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.vertical, Space.xs)
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: current)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: hovered)
    }
}

/// Which power source a section is about: its symbol and colour, so the two read apart.
enum PowerSource {
    case pluggedIn, battery
    var title: String { self == .pluggedIn ? "When Plugged In" : "On Battery" }
    var symbol: String { self == .pluggedIn ? "powerplug.fill" : "battery.75percent" }
    var tint: Color { self == .pluggedIn ? .green : .orange }
    /// Console: status green plugged in, amber on battery.
    var consoleTint: Color { self == .pluggedIn ? ConsoleInk.green : ConsoleInk.amber }
}

/// A power source's section header: its symbol on a tile in its colour, the name, and a line
/// saying what it's set to now ("40–120 fps · Dynamic").
struct PowerSourceHeader: View {
    let source: PowerSource
    let summary: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: source.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(source.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(source.title).textRole(.headline).foregroundStyle(.primary)
                Text(summary).textRole(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: summary)
            }
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// A power source's frame rate: Forced / Dynamic / Reactive, and one range to drag — the limit
/// on the right handle; for Dynamic and Reactive the lowest it eases to on the left, with the
/// span between filled. The figure above says the range and how far it can drop, as a share.
struct FrameRateControl: View {
    let source: PowerSource
    @Binding var mode: WallpaperSettings.FPSMode
    @Binding var limit: Int
    /// nil: the default, two rungs under the limit (it follows the limit until dragged).
    @Binding var floor: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stops = WallpaperBudget.ladder.reversed().map { Int($0) }     // 15 … 120

    private var adaptive: Bool { mode != .forced }
    private var upper: Int { Self.index(limit) }
    private var lower: Int {
        let f = floor ?? Int(WallpaperBudget.defaultFloor(Double(limit)))
        return min(Self.index(f), max(upper - 1, 0))
    }
    private var low: Int { Self.stops[lower] }
    private var mid: Int { Int(WallpaperBudget.adapt(Double(limit), level: .moderate, floor: Double(low))) }

    static func index(_ fps: Int) -> Int { stops.lastIndex { $0 <= fps } ?? 0 }

    private var explain: String {
        switch mode {
        case .forced:
            return "Always \(limit) fps — or less, if a style asks for less."
        case .dynamic:
            return mid > low ? "\(limit) fps while your Mac is quiet, \(mid) while it's busy, \(low) when it's very busy."
                             : "\(limit) fps while your Mac is quiet, \(low) while it's busy."
        case .reactive:
            return "\(limit) fps while you're watching, \(mid) while you work in another app\(mid > low ? ", \(low) if your Mac is also very busy" : "")."
        }
    }

    @Environment(\.consoleSettings) private var console

    /// Console: Forced / Dynamic / Reactive as keys (in the module's header, as the design).
    static func modeKeys(source: PowerSource, mode: Binding<WallpaperSettings.FPSMode>) -> some View {
        ModeKeys(source: source, mode: mode)
    }

    private struct ModeKeys: View {
        let source: PowerSource
        @Binding var mode: WallpaperSettings.FPSMode
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            ConsoleSegments(title: "\(source.title) frame rate mode",
                            selection: $mode.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion)),
                            options: WallpaperSettings.FPSMode.allCases.map { ($0.title, $0) })
        }
    }

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console: the big readout ("40–120 fps", how far it eases down), the range in a well,
    /// the sentence. The mode keys sit in the module's header.
    private var consoleBody: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                Text(adaptive ? "\(low)–\(limit)" : "\(limit)")
                    .textRole(.readoutLarge).monospacedDigit()
                    .foregroundStyle(ConsoleInk.ink)
                    .contentTransition(.numericText())
                Text("fps").textRole(.consoleValue).foregroundStyle(ConsoleInk.legend)
                Spacer(minLength: Space.s)
                if adaptive {
                    Text("eases down to \(Int((Double(low) / Double(limit) * 100).rounded()))%")
                        .textRole(.legend).foregroundStyle(ConsoleInk.legend)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            RateRangeSlider(count: Self.stops.count, labels: Self.stops.map(String.init), tint: ConsoleInk.green,
                            upper: Binding(get: { upper }, set: { i in
                                limit = Self.stops[i]
                                if let f = floor, Self.index(f) >= i { floor = i > 0 ? Self.stops[i - 1] : nil }
                            }),
                            lower: adaptive ? Binding(get: { lower }, set: { floor = Self.stops[$0] }) : nil)
                .accessibilityLabel("\(source.title) frame rate")
            Text(explain).textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: limit)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: floor)
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: mode)
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center) {
                Text("Frame rate").textRole(.bodyEmphasis)
                Spacer(minLength: Space.m)
                Picker("Frame rate mode", selection: $mode.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion))) {
                    ForEach(WallpaperSettings.FPSMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(adaptive ? "\(low)–\(limit)" : "\(limit)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("fps").textRole(.bodyEmphasis).foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                if adaptive {
                    Text("eases down to \(Int((Double(low) / Double(limit) * 100).rounded()))%")
                        .textRole(.callout).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            RateRangeSlider(count: Self.stops.count, labels: Self.stops.map(String.init), tint: source.tint,
                            upper: Binding(get: { upper }, set: { i in
                                limit = Self.stops[i]
                                // an explicit floor never sits at or above the limit
                                if let f = floor, Self.index(f) >= i { floor = i > 0 ? Self.stops[i - 1] : nil }
                            }),
                            lower: adaptive ? Binding(get: { lower }, set: { floor = Self.stops[$0] }) : nil)
                .accessibilityLabel("\(source.title) frame rate")
            Text(explain).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(.vertical, Space.xs)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: limit)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: floor)
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: mode)
    }
}

/// A stepped slider with one or two handles (`lower` nil: one). Stops are evenly spaced, the
/// span between the handles (or up to the one) is filled in `tint`, and each stop's label sits
/// under it. Drag a handle, or click the track to move the nearer one; arrow keys / VoiceOver
/// adjust each handle. A trackpad tick marks each stop passed.
struct RateRangeSlider: View {
    let count: Int
    let labels: [String]
    let tint: Color
    @Binding var upper: Int
    var lower: Binding<Int>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.consoleSettings) private var console
    @Environment(\.colorScheme) private var scheme
    @State private var dragging: Handle?
    enum Handle { case lower, upper }

    /// Console: a 14 pt-wide keycap thumb, a 10 pt well (the design's stepped hardware track).
    private var knob: CGFloat { console ? 14 : 20 }
    private var knobHeight: CGFloat { console ? 20 : 20 }
    private var track: CGFloat { console ? 10 : 5 }
    @ScaledLength(relativeTo: .caption2) private var labelHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: Space.xs) {
            GeometryReader { geo in
                let w = geo.size.width - knob
                let x = { (i: Int) -> CGFloat in knob / 2 + w * CGFloat(i) / CGFloat(max(count - 1, 1)) }
                let lo = lower?.wrappedValue
                ZStack(alignment: .leading) {
                    if console {
                        // the well, its stops as notches, the range lit green from edge to edge
                        Color.clear.frame(height: track).consoleWell(cornerRadius: 2)
                        ForEach(0..<count, id: \.self) { i in
                            Rectangle().fill(ConsoleInk.hairline).frame(width: 1, height: track - 4)
                                .position(x: x(i), y: knobHeight / 2)
                        }
                        let from = lo == nil ? 0 : x(lo!), to = x(upper)
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint)
                            .frame(width: max(to - from, track), height: track)
                            .offset(x: from)
                    } else {
                    Capsule().fill(Color.primary.opacity(0.1))
                        .frame(height: track)
                        .padding(.horizontal, knob / 2)
                    ForEach(0..<count, id: \.self) { i in
                        Circle().fill(Color.primary.opacity(0.25)).frame(width: 3, height: 3)
                            .position(x: x(i), y: knob / 2)
                    }
                    let from = x(lo ?? 0), to = x(upper)
                    Capsule().fill(tint.gradient)
                        .frame(width: max(to - from, track), height: track)
                        .offset(x: from - (lo == nil ? knob / 2 : 0))
                        .padding(.leading, lo == nil ? knob / 2 : 0)
                    }
                    if let lo { thumb(.lower).position(x: x(lo), y: knobHeight / 2) }
                    thumb(.upper).position(x: x(upper), y: knobHeight / 2)
                }
                .frame(height: knobHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let i = Int(((g.location.x - knob / 2) / max(w, 1) * CGFloat(count - 1)).rounded())
                        let idx = min(max(i, 0), count - 1)
                        if dragging == nil {
                            // the handle nearer the press (ties: the one that can move that way)
                            if let lo, abs(idx - lo) < abs(idx - upper) || (idx < lo) { dragging = .lower }
                            else { dragging = .upper }
                        }
                        move(dragging!, to: idx)
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: knobHeight)
            GeometryReader { geo in
                let w = geo.size.width - knob
                ForEach(0..<count, id: \.self) { i in
                    let on = i == upper || i == lower?.wrappedValue
                    let inside = i <= upper && i >= (lower?.wrappedValue ?? i)
                    if console {
                        // The design's stops: mono; inside the range green on graphite, bold
                        // ink on the light body (green text there is too faint to read).
                        let lit = inside && (lower != nil || on)
                        Text(labels[i]).textRole(lit ? .consoleMonoStrong : .consoleMono)
                            .foregroundStyle(lit ? (scheme == .dark ? ConsoleInk.green : ConsoleInk.ink) : ConsoleInk.legend)
                            .fixedSize()
                            .position(x: knob / 2 + w * CGFloat(i) / CGFloat(max(count - 1, 1)), y: labelHeight / 2)
                    } else {
                    Text(labels[i]).textRole(.callout)
                        .foregroundStyle(on ? AnyShapeStyle(tint) : inside && lower != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fontWeight(on ? .semibold : .regular)
                        .fixedSize()
                        .position(x: knob / 2 + w * CGFloat(i) / CGFloat(max(count - 1, 1)), y: 8)
                    }
                }
            }
            .frame(height: console ? labelHeight : 16)
        }
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: upper)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: lower?.wrappedValue)
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: lower == nil)
    }

    @ViewBuilder private func thumbFace(_ h: Handle) -> some View {
        if console {
            ConsoleThumb(pressed: dragging == h)
                .frame(width: knob, height: knobHeight)
        } else {
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: dragging == h ? 4 : 2, y: 1)
                .frame(width: knob, height: knob)
                .scaleEffect(dragging == h ? 1.12 : 1)
        }
    }

    private func thumb(_ h: Handle) -> some View {
        thumbFace(h)
            .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: dragging)
            .accessibilityElement()
            .accessibilityLabel(h == .upper ? (lower == nil ? "Frame rate" : "Highest") : "Lowest")
            .accessibilityValue("\(labels[h == .upper ? upper : (lower?.wrappedValue ?? 0)]) frames per second")
            .accessibilityAdjustableAction { dir in
                let cur = h == .upper ? upper : (lower?.wrappedValue ?? 0)
                move(h, to: dir == .increment ? cur + 1 : cur - 1)
            }
            .transition(.scale.combined(with: .opacity))
    }

    /// Move a handle, keeping lower < upper: the limit pushes the floor down ahead of it; the
    /// floor stops one under the limit.
    private func move(_ h: Handle, to i: Int) {
        switch h {
        case .upper:
            let lowest = lower == nil ? 0 : 1
            let v = min(max(i, lowest), count - 1)
            guard v != upper else { return }
            upper = v
            tick()
        case .lower:
            guard let lower else { return }
            let v = min(max(i, 0), upper - 1)
            guard v != lower.wrappedValue else { return }
            lower.wrappedValue = v
            tick()
        }
    }

    private func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}
