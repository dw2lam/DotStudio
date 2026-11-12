//  WallpaperPower.swift — the power side of the live wallpaper: persisted settings,
//  the system conditions that pause it, and frame pacing.
//
//  The wallpaper should look smooth and cost little. The levers:
//    • Pacing   — frames come from the display link at an exact divisor of the
//                 screen's refresh (30 fps by default; Smooth = the display's own rate,
//                 up to 120 Hz on ProMotion), so every frame
//                 lasts the same time; a rate that isn't a divisor (24 on 60 Hz) reads
//                 as judder. Clocks tick once a second and only animate around a change.
//    • Scale    — rendering at reduced resolution (Balanced: 1.5 px/pt, 0.75 on Retina).
//    • Battery  — Settings › On Battery (BatteryMode): Efficient, the default, plays
//                 motion at 20 fps (an exact divisor of 60/120 Hz) at 0.6× the pixels per
//                 point Quality picks; Full plays as on power but at most 30 fps; Still
//                 holds a frame. See WallpaperBudget.
//    • Pausing  — no draws and no wake-ups at all while nobody can see it (covered,
//                 locked, display or system asleep, screensaver running), in Low Power
//                 Mode, or when paused from the menu bar.
//    • Stilling — a hot Mac (and battery, set to Still) holds the last frame; a clock
//                 still turns over once a minute so it never lies.
//    • Threads  — every frame is built off the main thread, on a render thread at
//                 user-initiated QoS while animating, utility for clock ticks and idle
//                 (see WallpaperRenderLoop), on the GPU that
//                 drives each display, with coalescable clock-timer wake-ups.

import AppKit
import IOKit.ps

// MARK: - Settings

/// What the user picked for the live wallpaper. App-only (the saver never reads it);
/// stored as wallpaper.json next to library.json, so a dev/test run with
/// DOTSTUDIO_STORE_DIR never touches the real app's choice.
struct WallpaperSettings: Codable, Equatable {
    enum FrameRate: Int, Codable, CaseIterable, Identifiable {
        /// 30 fps — an exact divisor of 60 and 120 Hz, so it's even on every common display.
        case balanced = 30
        /// The display's own refresh: 120 on ProMotion, 60 on most externals.
        case smooth = 120
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .balanced: return "Balanced · 30 fps"
            case .smooth: return "Smooth · display rate"
            }
        }
    }

    enum Quality: String, Codable, CaseIterable, Identifiable {
        case full, balanced, efficient          // same order as the screensaver's Quality picker
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Rendered pixels per point, capped at the display's own density. Efficient is
        /// standard (non-Retina) resolution: a quarter of the pixels on a Retina display.
        func pixelsPerPoint(backing: CGFloat) -> CGFloat {
            switch self {
            case .efficient: return min(1.0, backing)
            case .balanced: return min(1.5, backing)
            case .full: return backing
            }
        }
    }

    /// What the wallpaper does while the Mac runs on battery (Settings › Live Wallpaper › On Battery).
    enum BatteryMode: String, Codable, CaseIterable, Identifiable {
        /// As on power, but never above 30 fps.
        case full
        /// 20 fps (or the style's own lower rate) at 0.6× the resolution Quality picks.
        case efficient
        /// Hold a still frame; a clock still turns over each minute.
        case still
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var enabled = false
    var presetID: UUID?
    var frameRate: FrameRate = .balanced
    var quality: Quality = .balanced
    /// On battery: Efficient unless the user picks Full or Still.
    var batteryMode: BatteryMode = .efficient
    /// "Match Screensaver": show whatever the screensaver would (Playback.effectivePreset —
    /// rotation, night style) on the shared wall-clock time base, instead
    /// of `presetID`. See WallpaperController.setFollowsScreensaver(_:).
    var followsScreensaver = false
    /// "Use as lock & login screen picture" (opt-in): a still of the wallpaper becomes the
    /// desktop picture macOS shows there (LockScreenPicture).
    var lockScreen = false
    /// Each screen's own desktop picture from before DotStudio set one (keyed by display UUID),
    /// put back when the lock-screen picture turns off or the wallpaper stops. Empty while
    /// nothing of DotStudio's is set.
    var savedDesktopPictures: [String: SavedDesktopPicture] = [:]
    /// A style of its own on some displays (keyed by display UUID — Shared/DisplayPins.swift);
    /// the rest play `presetID`. Ignored while following the screensaver, where each display
    /// plays the screensaver's pick for that display (WallpaperPick).
    var displayStyles: [String: DisplayPin] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, presetID, frameRate, quality, batteryMode, followsScreensaver
        case lockScreen, savedDesktopPictures, displayStyles
        /// The 1.4 on/off "Freeze on battery": read when `batteryMode` is missing (on → Still,
        /// off → Efficient), and still written (on ⇔ Still) so an older build reading this
        /// file keeps holding a frame for someone who asked for that.
        case freezeOnBattery
    }

    // Tolerant decoding: a field added later must not reset the user's choice.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        presetID = try? c.decode(UUID.self, forKey: .presetID)
        frameRate = (try? c.decode(FrameRate.self, forKey: .frameRate)) ?? .balanced
        quality = (try? c.decode(Quality.self, forKey: .quality)) ?? .balanced
        if let mode = try? c.decode(BatteryMode.self, forKey: .batteryMode) {
            batteryMode = mode
        } else {
            let froze = (try? c.decode(Bool.self, forKey: .freezeOnBattery)) ?? false
            batteryMode = froze ? .still : .efficient
        }
        followsScreensaver = (try? c.decode(Bool.self, forKey: .followsScreensaver)) ?? false
        lockScreen = (try? c.decode(Bool.self, forKey: .lockScreen)) ?? false
        savedDesktopPictures = (try? c.decode([String: SavedDesktopPicture].self, forKey: .savedDesktopPictures)) ?? [:]
        displayStyles = (try? c.decode([String: DisplayPin].self, forKey: .displayStyles)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(presetID, forKey: .presetID)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(quality, forKey: .quality)
        try c.encode(batteryMode, forKey: .batteryMode)
        try c.encode(batteryMode == .still, forKey: .freezeOnBattery)
        try c.encode(followsScreensaver, forKey: .followsScreensaver)
        try c.encode(lockScreen, forKey: .lockScreen)
        if !savedDesktopPictures.isEmpty { try c.encode(savedDesktopPictures, forKey: .savedDesktopPictures) }
        if !displayStyles.isEmpty { try c.encode(displayStyles, forKey: .displayStyles) }
    }

    static func load(from url: URL) -> WallpaperSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(WallpaperSettings.self, from: data) else { return WallpaperSettings() }
        return s
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// What the live wallpaper shows, per display — pure functions of (settings, library, clock),
/// shared by WallpaperController and the self-tests.
enum WallpaperPick {
    /// The shared pick (every display without a style of its own): the chosen style — or, while
    /// following the screensaver, what the screensaver's lineup shows now. nil = none (no pick,
    /// or the pick was deleted).
    static func shared(_ settings: WallpaperSettings, _ lib: Library, now: Date = Date()) -> Preset? {
        if settings.followsScreensaver {
            return lib.presets.isEmpty ? nil : Playback.effectivePreset(in: lib, now: now)
        }
        guard let id = settings.presetID else { return nil }
        return lib.presets.first { $0.id == id }
    }

    /// One display's style. Following the screensaver: exactly what the screensaver shows on
    /// that display (its own screensaver style, else the lineup) — the wallpaper's own pins are
    /// kept but unused. Otherwise the display's own wallpaper style while it still exists, else
    /// the shared pick. nil = the wallpaper has nothing to show.
    static func preset(display: String?, _ settings: WallpaperSettings, _ lib: Library, now: Date = Date()) -> Preset? {
        if settings.followsScreensaver {
            return lib.presets.isEmpty ? nil : Playback.effectivePreset(in: lib, now: now, display: display)
        }
        if let display, let id = settings.displayStyles[display]?.presetID,
           let p = lib.presets.first(where: { $0.id == id }) {
            return p
        }
        return shared(settings, lib, now: now)
    }

    /// The pins whose style still exists (a deleted style's pin is dropped on the next save).
    static func pruned(_ settings: WallpaperSettings, _ lib: Library) -> WallpaperSettings {
        var s = settings
        let ids = Set(lib.presets.map(\.id))
        s.displayStyles = s.displayStyles.filter { ids.contains($0.value.presetID) }
        return s
    }
}

/// A screen's desktop picture as macOS had it (NSWorkspace.desktopImageURL + desktopImageOptions).
struct SavedDesktopPicture: Codable, Equatable {
    /// The file URL (absoluteString).
    var url: String
    /// NSImageScaling raw value.
    var scaling: Int?
    var allowClipping: Bool?
    /// sRGB red, green, blue, alpha.
    var fillColor: [Double]?
}

// MARK: - System conditions

/// Watches everything outside the app that should pause or slow the wallpaper.
/// Main thread only; `onChange` fires on the main queue whenever `state` changes.
final class WallpaperPowerMonitor {
    struct State: Equatable {
        var screenLocked = false
        var displayAsleep = false
        var systemAsleep = false
        var screensaverRunning = false
        var lowPowerMode = false
        var thermalHot = false          // .serious or .critical
        var onBattery = false
    }

    private(set) var state = State()
    var onChange: ((State) -> Void)?

    /// DEV: DOTSTUDIO_WALLPAPER_FORCE=battery,lowpower,thermal forces those conditions
    /// on, to verify the policy on a Mac that can't be unplugged or heated on demand;
    /// `ac` forces mains power (to measure the plugged-in default on a laptop on battery).
    private let forced: Set<String> = Set(
        (ProcessInfo.processInfo.environment["DOTSTUDIO_WALLPAPER_FORCE"] ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    func start() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        let local = NotificationCenter.default

        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (inout State) -> Void) {
            let t = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update(change)
            }
            tokens.append((center, t))
        }
        // Lock and screensaver each clear only on their own end notification — and those can be
        // missed (a sleep while the saver runs, a lock screen that ends it without didstop). A
        // wake or an unlock re-reads both, so the wallpaper never stays paused for a state that's
        // already over.
        on(dist, .init("com.apple.screenIsLocked")) { $0.screenLocked = true }
        on(dist, .init("com.apple.screenIsUnlocked")) { s in
            s.screenLocked = false
            s.screensaverRunning = Self.screensaverActive()
        }
        on(dist, .init("com.apple.screensaver.didstart")) { $0.screensaverRunning = true }
        on(dist, .init("com.apple.screensaver.didstop")) { $0.screensaverRunning = false }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { s in
            s.displayAsleep = false
            Self.resync(&s)
        }
        on(ws, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        on(ws, NSWorkspace.didWakeNotification) { s in
            s.systemAsleep = false
            s.displayAsleep = false      // a wake always lights the displays
            Self.resync(&s)
        }
        on(local, .NSProcessInfoPowerStateDidChange) { [weak self] s in
            s.lowPowerMode = self?.readLowPower() ?? false
        }
        on(local, ProcessInfo.thermalStateDidChangeNotification) { [weak self] s in
            s.thermalHot = self?.readThermal() ?? false
        }

        // Battery ↔ AC: IOKit's power-source run-loop notification (no polling).
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<WallpaperPowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.update { $0.onBattery = me.readBattery() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }

        state = State(screenLocked: Self.sessionLocked(),
                      screensaverRunning: Self.screensaverActive(),
                      lowPowerMode: readLowPower(),
                      thermalHot: readThermal(),
                      onBattery: readBattery())
    }

    func stop() {
        for (center, t) in tokens { center.removeObserver(t) }
        tokens.removeAll()
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        powerSource = nil
    }

    deinit { stop() }

    private func update(_ change: (inout State) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        onChange?(s)
    }

    private func readLowPower() -> Bool {
        forced.contains("lowpower") || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func readThermal() -> Bool {
        if forced.contains("thermal") { return true }
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical
    }

    private func readBattery() -> Bool {
        if forced.contains("battery") { return true }
        if forced.contains("ac") { return false }
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }

    /// After a wake: the lock and screensaver as they are now, not as the last notification said.
    private static func resync(_ s: inout State) {
        s.screenLocked = sessionLocked()
        s.screensaverRunning = screensaverActive()
    }

    /// Whether the screensaver is up right now: its engine process is running.
    private static func screensaverActive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
    }

    /// Whether the login session is locked right now (the notifications only report changes).
    private static func sessionLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}

// MARK: - Pacing

/// When a style needs frames. Pure functions of (style, settings, wall clock).
enum WallpaperPacing {
    enum Profile: Equatable {
        /// Nothing in the style changes over time: one frame, redrawn only on edits.
        case still
        /// Continuous motion.
        case motion
        /// A clock: one frame per second, plus smooth animation for `burst` seconds after
        /// every `period` boundary (60 = each minute, 1 = each second).
        case clock(period: Double, burst: Double)
    }

    /// What the frame loop should do next.
    enum Plan: Equatable {
        case none                          // hold the last frame; no wake-ups
        case continuous(fps: Double)       // display-link paced
        case after(TimeInterval)           // one frame after this delay (clock ticks)

        /// Frames follow each other continuously (a crossfade can play out).
        var isContinuous: Bool { if case .continuous = self { return true } else { return false } }
    }

    static func profile(for preset: Preset, source: SourceSpec) -> Profile {
        let enabled = preset.effects.filter(\.enabled)
        guard let first = enabled.first else { return .motion }
        func on(_ key: String) -> Bool { (first.params[key] ?? 0) > 0.5 }
        switch first.kind {
        case .flipClock:  return .clock(period: on("seconds") ? 1 : 60, burst: 0.8)   // flaps fall for 0.75 s
        case .typeClock:  return .clock(period: on("seconds") ? 1 : 60, burst: on("seconds") ? 0.45 : 0.65)
        case .wordClock:  return .clock(period: 60, burst: 0)                     // no transition animation
        // the seconds hand sweeps; without it the hands and the light creep slowly enough for 1 fps
        case .dialClock:  return on("seconds") ? .motion : .clock(period: 1, burst: 0)
        // StandBy: a changing figure rolls for 0.6 s (eased out: done to the eye by ~0.45 s); its
        // seconds line eases for 0.35 s each second. The burn-in drift is slow enough for 1 fps.
        case .standbyClock: return .clock(period: on("seconds") ? 1 : 60, burst: on("seconds") ? 0.45 : 0.65)
        // Minimal: the minute cross-fades for 1.1 s; small seconds fade for 0.35 s
        case .minimalClock: return .clock(period: on("seconds") ? 1 : 60, burst: on("seconds") ? 0.4 : 1.15)
        // Chronometer: the seconds hand sweeps (Seconds: 0 Sweep, 1 Off); without it, 1 fps
        case .watchClock: return (first.params["seconds"] ?? 0) < 0.5 ? .motion : .clock(period: 1, burst: 0)
        default: break
        }
        if first.kind.isScene { return .motion }
        // A Look on a still photo with time-free effects never changes: draw once.
        if source.kind == .image, !enabled.contains(where: \.kind.isTimeDriven) { return .still }
        return .motion
    }

    /// - fps: the target rate (settings, preset cap and battery already applied).
    /// - still: hot Mac / battery freeze. Motion stops; a clock turns over once a minute.
    static func plan(_ profile: Profile, fps: Double, still: Bool, now: Date = Date()) -> Plan {
        let wall = now.timeIntervalSince1970
        func untilBoundary(_ period: Double) -> TimeInterval {
            period - wall.truncatingRemainder(dividingBy: period) + 0.004   // just after it
        }
        switch profile {
        case .still:
            return .none
        case .motion:
            return still ? .none : .continuous(fps: fps)
        case .clock(let period, let burst):
            if still { return .after(untilBoundary(period >= 60 ? 60 : 1)) }
            if burst > 0, wall.truncatingRemainder(dividingBy: period) < burst { return .continuous(fps: fps) }
            return .after(untilBoundary(1))
        }
    }

    /// Whether a still of the style goes stale with the time of day: a clock, the live weather,
    /// or a scene following the real sun (MetalRenderer.fillLiveSky). The lock-screen picture
    /// re-renders these every 15 minutes; anything else only when it changes.
    static func changesWithTimeOfDay(_ preset: Preset) -> Bool {
        if WeatherLink.followsLive(preset) { return true }
        return preset.effects.contains { inst in
            guard inst.enabled else { return false }
            switch inst.kind {
            case .flipClock, .typeClock, .wordClock, .dialClock, .standbyClock, .minimalClock, .watchClock:
                return true
            case .oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden:
                return (inst.params["live"] ?? 0) > 0.5
            case .windowLight:
                return (inst.params["follow"] ?? 1) > 0.5
            case .meadow:
                return (inst.params["live"] ?? 1) > 0.5
            default:
                return false
            }
        }
    }

    /// The rate a style steps its own time at, whatever rate it is drawn at (Bloom keeps a
    /// 24 fps film cadence: Bloom_funcs.h), else nil. See `rate(target:step:refresh:)`.
    static func steppedFPS(_ preset: Preset) -> Double? {
        guard let first = preset.effects.first(where: \.enabled) else { return nil }
        return first.kind == .flowerBloom ? 24 : nil
    }

    /// The display-link rate for `target` fps on a `refresh` Hz display. A style that steps its
    /// own time at `step` fps, when the budget allows that many, draws at the slowest exact
    /// divisor of the refresh at or above it — 24 on 120 Hz, 30 on 60 Hz, 25 on 50 Hz — so no
    /// step is ever skipped (20 on 60 Hz would drop one in six) and none is drawn twice over
    /// for nothing (Smooth's 120). Anything else: `divisorRate`.
    static func rate(target: Double, step: Double?, refresh: Double) -> Double {
        guard let step, step > 0, refresh > 0, target >= step - 0.01 else {
            return divisorRate(target: target, refresh: refresh)
        }
        return refresh / max((refresh / step + 1e-6).rounded(.down), 1)
    }

    /// The exact divisor of `refresh` closest to `target` (30 on 60/120 Hz, 25 on 50 Hz,
    /// 36 on 144 Hz...), so every frame is held for the same number of refreshes.
    static func divisorRate(target: Double, refresh: Double) -> Double {
        guard refresh > 0 else { return target }
        let n = max((refresh / max(target, 1)).rounded(), 1)
        return refresh / n
    }
}

// MARK: - Battery budget

/// What power allows the frame loop, beyond the hard pauses: frame rate, resolution and
/// whether motion holds. Pure functions of (settings, power, style), so tools/perf measures
/// exactly the policy the controller runs.
enum WallpaperBudget {
    /// Efficient on battery: frames per second for continuous motion — an exact divisor of
    /// 60 and 120 Hz (every frame held for 3 or 6 refreshes), two-thirds of Balanced's 30.
    static let efficientFPS = 20.0
    /// Efficient on battery: the fraction of Quality's pixels per point drawn (0.36× the
    /// pixels). The compositor upscales it; the dot styles size their patterns by frame
    /// height, so nothing changes scale — it only softens.
    static let efficientScale: CGFloat = 0.6
    /// Full on battery: never above this, whatever Frame Rate says.
    static let batteryMaxFPS = 30.0

    /// Frames per second asked of the display links: Balanced 30, Smooth each display's own
    /// refresh (120 on ProMotion, 60 on most externals — divisorRate clamps it); on battery 30
    /// (Full) or 20 (Efficient). Less only if the style itself asks for fewer.
    static func fps(_ settings: WallpaperSettings, presetFPS: Int, onBattery: Bool) -> Double {
        if !onBattery, settings.frameRate == .smooth { return 120 }
        var fps = onBattery && settings.batteryMode == .efficient ? efficientFPS
                : onBattery ? batteryMaxFPS : 30
        if presetFPS > 0 { fps = min(fps, Double(presetFPS)) }
        return fps
    }

    /// Multiplier on Quality's pixels per point. Below 1 only for Efficient on battery, and only
    /// while the style moves continuously: a clock that draws once a second keeps crisp
    /// figures (its few frames cost next to nothing either way).
    static func renderScale(_ settings: WallpaperSettings, onBattery: Bool, profile: WallpaperPacing.Profile) -> CGFloat {
        guard onBattery, settings.batteryMode == .efficient, profile == .motion else { return 1 }
        return efficientScale
    }

    /// Why motion holds on its last frame (a clock still turns over once a minute).
    static func stillReason(_ settings: WallpaperSettings, _ s: WallpaperPowerMonitor.State) -> String? {
        if s.thermalHot { return "Still — Mac is running hot" }
        if s.onBattery && settings.batteryMode == .still { return "Still — on battery" }
        return nil
    }

    /// A note for the menu and the Wallpaper card while it plays reduced on battery.
    static func batteryStatus(_ settings: WallpaperSettings, onBattery: Bool) -> String? {
        guard onBattery else { return nil }
        switch settings.batteryMode {
        case .efficient: return "Efficient — on battery"
        case .full: return settings.frameRate == .smooth ? "30 fps — on battery" : nil
        case .still: return nil      // stillReason says it
        }
    }
}

extension EffectKind {
    /// Effects whose output changes with time even on a still source (grain, glitches,
    /// scanline roll…). Conservative: anything not known to be static counts as moving.
    var isTimeDriven: Bool {
        switch self {
        // Audited against Shaders.metal: these cases never read the time uniform.
        case .pixelate, .blockify, .dither, .halftone, .dots, .threshold, .posterize, .phosphor,
             .scanlines, .vignette, .edge, .crosshatch, .contour, .voronoi, .ascii, .pixelSort,
             .chromaticShift, .bloom, .hexMosaic, .mirror, .gameboy, .neonEdges, .fisheye,
             .toon, .thermal, .truchet, .ledPanel, .nes8bit:
            return false
        default:
            return true
        }
    }
}
