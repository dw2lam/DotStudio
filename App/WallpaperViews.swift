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

    // Power saving, the way a laptop is used: what plays plugged in, what plays on battery,
    // and in both what happens while another app is focused. Each row acts out its current
    // choice in a little animated Mac (WallpaperDemos.swift).
    // Power saving the way Wallpaper Engine lays it out: a preset on top that sets everything,
    // then one frame rate for everything, then each situation as a row of option cards with a
    // slider under them.
    @ViewBuilder private var powerSections: some View {
        Section {
            PowerPresetPicker(current: PowerPreset.matching(wallpaper.settings, model.library)) { preset in
                preset.apply(wallpaper: wallpaper, model: model)
            }
        } header: {
            powerHeader("Preset", symbol: "slider.horizontal.3")
        }

        Section {
            FrameRateRow(fps: Binding(get: { model.library.frameRate ?? (wallpaper.settings.frameRate == .smooth ? 120 : 30) },
                                      set: { v in PowerPreset.setFrameRate(v, wallpaper: wallpaper, model: model) }))
        } header: {
            powerHeader("Frame Rate", symbol: "speedometer")
        } footer: {
            SettingsNote("One frame rate for the screensaver and the live wallpaper. On battery it's capped at 30 (20 when Efficient); Low Power Mode draws 15. Frame rate mode below lets the wallpaper ease off from it when you're plugged in or on battery.")
        }

        Section {
            fpsModeRow(\.fpsModePluggedIn, onBattery: false)
            otherAppRow(\.otherAppPluggedIn)
        } header: {
            powerHeader("When Plugged In", symbol: "powerplug")
        }

        Section {
            OptionCards(title: "Playback",
                        options: WallpaperSettings.BatteryMode.allCases.map {
                            .init(label: $0.title, value: $0, scene: .battery($0), explain: Self.batteryExplain($0))
                        },
                        selection: Binding(get: { wallpaper.settings.batteryMode },
                                           set: { v in wallpaper.update { $0.batteryMode = v } }))
            fpsModeRow(\.fpsModeOnBattery, onBattery: true)
            otherAppRow(\.otherAppOnBattery)
        } header: {
            powerHeader("On Battery", symbol: "battery.75percent")
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

    private static func batteryExplain(_ m: WallpaperSettings.BatteryMode) -> String {
        switch m {
        case .full: return "plays as when plugged in, up to 30 fps."
        case .efficient: return "20 fps at lower resolution — about a quarter of the work."
        case .still: return "holds one frame until you plug in."
        }
    }

    /// Frame Rate Mode per power source: Forced, Dynamic (the Mac's load) or Reactive (your
    /// input) — WallpaperSettings.FPSMode, WallpaperBudget.level.
    private func fpsModeRow(_ key: WritableKeyPath<WallpaperSettings, WallpaperSettings.FPSMode>, onBattery: Bool) -> some View {
        // this power source's real rates: its top, one step down, two
        let top = WallpaperBudget.fps(wallpaper.settings, presetFPS: 0, onBattery: onBattery,
                                      universal: model.library.frameRate ?? (wallpaper.settings.frameRate == .smooth ? 120 : 30))
        let one = WallpaperBudget.stepDown(top, 1), two = WallpaperBudget.stepDown(top, 2)
        func n(_ f: Double) -> String { "\(Int(f))" }
        let busy = two < one ? "\(n(top)) → \(n(one)), or \(n(two)) when very busy" : "\(n(top)) → \(n(one))"
        return OptionCards(title: "Frame rate mode",
                    options: WallpaperSettings.FPSMode.allCases.map { m in
                        .init(label: m.title, value: m, scene: .fpsMode(m, top: Int(top)), explain: {
                            switch m {
                            case .forced: return "always plays at \(n(top)) fps."
                            case .dynamic: return one < top ? "steps down while your Mac's CPU or GPU is busy (\(busy) fps) and back up when it settles."
                                                            : "would step down while your Mac is busy, but \(n(top)) fps is already the lowest rate."
                            case .reactive: return one < top ? "steps down while you type, click or scroll in another app (\(n(top)) → \(n(one)) fps) and comes back a few seconds after you stop."
                                                             : "would step down while you use another app, but \(n(top)) fps is already the lowest rate."
                            }
                        }())
                    },
                    selection: Binding(get: { wallpaper.settings[keyPath: key] },
                                       set: { v in wallpaper.update { $0[keyPath: key] = v } }))
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
    var summary: String {
        switch self {
        case .quality: return "60 fps, full resolution, always playing."
        case .balanced: return "30 fps, lighter on battery. The default."
        case .saver: return "24 fps, lower resolution, eases off when your Mac is busy; pauses whenever you're busy."
        }
    }

    private var fps: Int { self == .quality ? 60 : self == .balanced ? 30 : 24 }
    private var quality: WallpaperSettings.Quality { self == .quality ? .full : self == .balanced ? .balanced : .efficient }
    private var screensaverScale: Double? { self == .saver ? 0.5 : nil }
    private var battery: WallpaperSettings.BatteryMode { self == .quality ? .full : self == .balanced ? .efficient : .still }
    private var pluggedIn: WallpaperSettings.OtherAppMode { self == .saver ? .efficient : .keepPlaying }
    private var onBattery: WallpaperSettings.OtherAppMode { self == .saver ? .pause : .keepPlaying }
    private var fpsMode: WallpaperSettings.FPSMode { self == .saver ? .dynamic : .forced }

    static func matching(_ w: WallpaperSettings, _ lib: Library) -> PowerPreset? {
        allCases.first { p in
            (lib.frameRate ?? (w.frameRate == .smooth ? 120 : 30)) == p.fps && w.quality == p.quality && lib.renderScale == p.screensaverScale
                && w.batteryMode == p.battery && w.otherAppPluggedIn == p.pluggedIn && w.otherAppOnBattery == p.onBattery
                && w.fpsModePluggedIn == p.fpsMode && w.fpsModeOnBattery == p.fpsMode
        }
    }

    @MainActor func apply(wallpaper: WallpaperController, model: AppModel) {
        model.library.frameRate = fps
        model.library.renderScale = screensaverScale
        model.save()
        wallpaper.update {
            $0.quality = quality
            $0.frameRate = fps > 30 ? .smooth : .balanced
            $0.batteryMode = battery
            $0.otherAppPluggedIn = pluggedIn
            $0.otherAppOnBattery = onBattery
            $0.fpsModePluggedIn = fpsMode
            $0.fpsModeOnBattery = fpsMode
        }
    }

    /// The one frame rate (Library.frameRate), and the wallpaper's own setting in step with it
    /// (so a build without the shared rate keeps about the same).
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

    var body: some View {
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
                            .strokeBorder(current == p ? p.tint : Color.primary.opacity(0.08), lineWidth: current == p ? 2.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == p ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text(current == nil ? "Custom — you've changed settings below. Pick a preset to start over."
                                : "Sets everything below. Change anything to make it your own.")
                .textRole(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
    }
}

/// One frame rate for everything: a big picture playing at the chosen rate (exaggerated so the
/// steps read), the value in large type, and a slider with a stop per rate.
private struct FrameRateRow: View {
    @Binding var fps: Int
    static let stops = [15, 24, 30, 60, 120]

    private var index: Int { Self.stops.firstIndex(of: fps) ?? Self.stops.firstIndex { $0 >= fps } ?? 2 }

    private var explain: String {
        switch Self.stops[index] {
        case 15: return "Lightest. Slow scenes still look calm; fast motion steps."
        case 24: return "Film rate — gentle on battery."
        case 30: return "Smooth for most styles, half the work of 60."
        case 60: return "Fluid motion. Uses about twice the power of 30."
        default: return "Your display's full rate on ProMotion. Uses the most power."
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            WallpaperDemo(scene: .fps(Self.stops[index]))
                .frame(width: 200)
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("\(Self.stops[index])").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("fps").textRole(.bodyEmphasis).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(index) }, set: { fps = Self.stops[Int($0.rounded())] }),
                       in: 0...Double(Self.stops.count - 1), step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Frame rate")
                    .accessibilityValue("\(Self.stops[index]) frames per second")
                HStack {
                    ForEach(Self.stops.indices, id: \.self) { i in
                        Text("\(Self.stops[i])").textRole(.callout)
                            .foregroundStyle(i == index ? Color.accentColor : .secondary)
                        if i < Self.stops.count - 1 { Spacer(minLength: 0) }
                    }
                }
                Text(explain).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.xs)
    }
}
