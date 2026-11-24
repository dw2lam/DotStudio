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
//                 locked, display or system asleep, screensaver running), or when
//                 paused from the menu bar.
//    • Adaptive — per power source, Frame Rate Mode (FPSMode): Forced keeps the set rate;
//                 Dynamic steps down the divisor ladder (120 → 60 → 40) while the Mac's
//                 CPU or GPU is busy; Reactive steps down while you're typing or clicking in
//                 another app and comes back when you stop (ActivitySampler, LoadGovernor).
//    • Stilling — Low Power Mode, a hot Mac (and battery, set to Still) hold a frame —
//                 drawn first if there isn't one yet, so it still sets the desktop; a clock
//                 still turns over once a minute so it never lies.
//    • Threads  — every frame is built off the main thread, on a render thread at
//                 user-initiated QoS while animating, utility for clock ticks and idle
//                 (see WallpaperRenderLoop), on the GPU that
//                 drives each display, with coalescable clock-timer wake-ups.

import AppKit
import IOKit
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
        var title: String { self == .still ? "Pause" : rawValue.capitalized }
    }

    /// While another app is in front (not full screen — a covered desktop always pauses):
    /// keep playing, or hold the frame (Settings › Live Wallpaper › Power Saving).
    enum OtherAppMode: String, Codable, CaseIterable, Identifiable {
        /// Plays as usual. `efficient`: slows to Efficient's 20 fps at lower resolution
        /// (like On Battery › Efficient). `pause`: holds the frame.
        case keepPlaying, efficient, pause
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keepPlaying: return "Keep Playing"
            case .efficient: return "Slow Down"
            case .pause: return "Pause"
            }
        }
    }

    /// How the frame rate behaves on one power source (Settings › Power Saving).
    enum FPSMode: String, Codable, CaseIterable, Identifiable {
        /// Always the frame rate set above.
        case forced
        /// Follows how hard the Mac is working (CPU and GPU): a step down while it's moderately
        /// busy (120 → 60), two while it's very busy (→ 40), back up when it settles.
        case dynamic
        /// Follows you: a step down while you type, click or scroll in another app (two if the
        /// Mac is also very busy), full rate again a few seconds after you stop.
        case reactive
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var enabled = false
    var presetID: UUID?
    var frameRate: FrameRate = .balanced
    var quality: Quality = .balanced
    /// On battery: Efficient unless the user picks Full or Still.
    var batteryMode: BatteryMode = .efficient
    /// Another app in front, plugged in / on battery: keep playing unless the user picks Pause.
    var otherAppPluggedIn: OtherAppMode = .keepPlaying
    var otherAppOnBattery: OtherAppMode = .keepPlaying
    /// Frame Rate Mode, plugged in / on battery: Forced (the set rate) unless the user picks
    /// Dynamic or Reactive.
    var fpsModePluggedIn: FPSMode = .forced
    var fpsModeOnBattery: FPSMode = .forced
    func fpsMode(onBattery: Bool) -> FPSMode { onBattery ? fpsModeOnBattery : fpsModePluggedIn }
    /// Dynamic or Reactive on either power source: the activity sampler has to run.
    var adaptsFrameRate: Bool { fpsModePluggedIn != .forced || fpsModeOnBattery != .forced }
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
        case otherAppPluggedIn, otherAppOnBattery, fpsModePluggedIn, fpsModeOnBattery
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
        otherAppPluggedIn = (try? c.decode(OtherAppMode.self, forKey: .otherAppPluggedIn)) ?? .keepPlaying
        otherAppOnBattery = (try? c.decode(OtherAppMode.self, forKey: .otherAppOnBattery)) ?? .keepPlaying
        fpsModePluggedIn = (try? c.decode(FPSMode.self, forKey: .fpsModePluggedIn)) ?? .forced
        fpsModeOnBattery = (try? c.decode(FPSMode.self, forKey: .fpsModeOnBattery)) ?? .forced
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
        try c.encode(otherAppPluggedIn, forKey: .otherAppPluggedIn)
        try c.encode(otherAppOnBattery, forKey: .otherAppOnBattery)
        try c.encode(fpsModePluggedIn, forKey: .fpsModePluggedIn)
        try c.encode(fpsModeOnBattery, forKey: .fpsModeOnBattery)
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

extension WallpaperSettings {
    /// The fields an assistant's requests and a style's deletion change (Shared/AI/LibraryOps.swift
    /// decides them, for the app and dotstudio-mcp alike).
    var choice: WallpaperChoice {
        get { WallpaperChoice(enabled: enabled, presetID: presetID, followsScreensaver: followsScreensaver, displayStyles: displayStyles) }
        set {
            enabled = newValue.enabled
            presetID = newValue.presetID
            followsScreensaver = newValue.followsScreensaver
            displayStyles = newValue.displayStyles
        }
    }
}

/// What the live wallpaper shows, per display — pure functions of (settings, library, clock),
/// shared by WallpaperController and the self-tests. The picks an edit makes are
/// WallpaperChoice's (Shared/AI/LibraryOps.swift), so dotstudio-mcp makes the same ones.
enum WallpaperPick {
    /// The shared pick (every display without a style of its own): the chosen style — or, while
    /// following the screensaver, what the screensaver's lineup shows now. nil = none (no pick,
    /// or the pick was deleted).
    static func shared(_ settings: WallpaperSettings, _ lib: Library, now: Date = Date(), live: SignalState?) -> Preset? {
        settings.choice.sharedPick(lib, now: now, live: live)
    }

    /// One display's style. Following the screensaver: exactly what the screensaver shows on
    /// that display (its own screensaver style, else the lineup) — the wallpaper's own pins are
    /// kept but unused. Otherwise the display's own wallpaper style while it still exists, else
    /// the shared pick. nil = the wallpaper has nothing to show.
    static func preset(display: String?, _ settings: WallpaperSettings, _ lib: Library, now: Date = Date(), live: SignalState?) -> Preset? {
        if settings.followsScreensaver {
            return lib.presets.isEmpty ? nil : Playback.effectivePreset(in: lib, now: now, display: display, live: live)
        }
        if let display, let id = settings.displayStyles[display]?.presetID,
           let p = lib.presets.first(where: { $0.id == id }) {
            return p
        }
        return shared(settings, lib, now: now, live: live)
    }

    /// Leaving "Same as Screensaver" by giving one display a wallpaper of its own: nothing else on
    /// screen changes. The shared pick becomes what the lineup shows now, every display whose
    /// screensaver has a style of its own keeps it as its wallpaper (replacing wallpaper pins left
    /// from before syncing, which weren't on screen), and then `display` gets `pin`. Pure.
    static func leavingSync(_ settings: WallpaperSettings, _ lib: Library, now: Date = Date(), live: SignalState?,
                            pin: DisplayPin, display: String) -> WallpaperSettings {
        var s = settings
        s.choice = settings.choice.leavingSync(lib, now: now, live: live, pin: pin, display: display)
        return s
    }

    /// The shared pick was just deleted (`lib`: after the delete). While a connected display still
    /// plays a wallpaper of its own, the others move to the screensaver's active style (else to
    /// that surviving style) rather than the whole wallpaper stopping. nil = nothing survives:
    /// stop, as before. Pure.
    static func sharedReplacement(pins: [String: DisplayPin], _ lib: Library, connected: [String]) -> UUID? {
        WallpaperChoice.sharedReplacement(pins: pins, lib, connected: connected)
    }

    /// The pins whose style still exists (WallpaperController drops a deleted style's pins with
    /// it: forgetDisplayStyles).
    static func pruned(_ settings: WallpaperSettings, _ lib: Library) -> WallpaperSettings {
        var s = settings
        s.choice = settings.choice.pruned(lib)
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
        /// A regular app other than DotStudio or Finder is frontmost (the desktop may still
        /// show around its windows; a full-screen app or covered desktop pauses regardless).
        var otherAppFront = false
        /// How busy the Mac's CPU and GPU are (LoadGovernor) — sampled only while a Frame Rate
        /// Mode is Dynamic or Reactive, else always quiet.
        var load: ActivityLevel = .quiet
        /// Typing, clicking or scrolling in another app in the last few seconds (Reactive).
        var userActive = false
    }

    private(set) var state = State()
    var onChange: ((State) -> Void)?

    /// DEV: DOTSTUDIO_WALLPAPER_FORCE=battery,lowpower,thermal,otherapp,moderate,busy,active forces those conditions
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
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] s in
            s.otherAppFront = self?.readOtherAppFront(was: s.otherAppFront) ?? false
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
                      onBattery: readBattery(),
                      otherAppFront: readOtherAppFront(was: false))
    }

    func stop() {
        samplesActivity = false
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

    // MARK: Activity (Dynamic / Reactive)

    /// Sample load and input once a second — only while a Frame Rate Mode needs it (the
    /// controller turns it on and off with the setting). Off, `load` and `userActive` rest.
    var samplesActivity = false {
        didSet {
            guard samplesActivity != oldValue else { return }
            sampleTimer?.invalidate(); sampleTimer = nil
            sampler = ActivitySampler()
            governor = LoadGovernor()
            if samplesActivity {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
                t.tolerance = 0.3
                RunLoop.main.add(t, forMode: .common)
                sampleTimer = t
                sample()
            } else {
                update { $0.load = .quiet; $0.userActive = false }
            }
        }
    }
    private var sampleTimer: Timer?
    private var sampler = ActivitySampler()
    private var governor = LoadGovernor()

    private func sample() {
        let reading = sampler.read()
        var load = governor.feed(cpu: reading.cpu, gpu: reading.gpu, now: Date())
        if forced.contains("busy") { load = .busy } else if forced.contains("moderate") { load = max(load, .moderate) }
        let active = forced.contains("active") || (reading.idleSeconds < ActivitySampler.activeWindow && state.otherAppFront)
        update { $0.load = load; $0.userActive = active }
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

    /// Finder (the desktop itself) and DotStudio count as the desktop. A menu-bar or panel app
    /// (Spotlight, Raycast, a menu extra) coming forward changes nothing: it covers next to
    /// nothing and leaves in a moment — the answer stays what the last regular app made it.
    private func readOtherAppFront(was: Bool) -> Bool {
        if forced.contains("otherapp") { return true }
        guard let app = NSWorkspace.shared.frontmostApplication else { return was }
        guard app.activationPolicy == .regular else { return was }
        return app.bundleIdentifier != "com.apple.finder"
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
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
            case .waddle:
                return (inst.params["night"] ?? 1) > 0.5
            default:
                return false
            }
        }
    }

    /// The rate a style steps its own time at (Shared/FramePacing.swift, which the saver uses too).
    static func steppedFPS(_ preset: Preset) -> Double? { FramePacing.steppedFPS(preset) }

    /// The display-link rate for `target` fps on a `refresh` Hz display: FramePacing.rate, the
    /// rule the screensaver follows too (a stepped style drawn so its steps land evenly).
    static func rate(target: Double, step: Double?, refresh: Double) -> Double {
        FramePacing.rate(target: target, step: step, refresh: refresh)
    }

    /// The exact divisor of `refresh` closest to `target` (FramePacing.divisorRate).
    static func divisorRate(target: Double, refresh: Double) -> Double {
        FramePacing.divisorRate(target: target, refresh: refresh)
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
    /// `slowed`: another app is in front and set to Slow Down (WallpaperBudget.slowed) —
    /// Efficient's rate and resolution, plugged in or not.
    /// `universal`: Power Saving's one frame rate (Library.frameRate) — replaces the style's own
    /// and Balanced / Smooth; battery and Slow Down still cap it.
    /// `level`: Frame Rate Mode's steps down the ladder (WallpaperBudget.level) — 0 for Forced.
    static func fps(_ settings: WallpaperSettings, presetFPS: Int, onBattery: Bool, slowed: Bool = false,
                    universal: Int? = nil, level: ActivityLevel = .quiet) -> Double {
        stepDown(ceilingFPS(settings, presetFPS: presetFPS, onBattery: onBattery, slowed: slowed, universal: universal),
                 level.rawValue)
    }

    private static func ceilingFPS(_ settings: WallpaperSettings, presetFPS: Int, onBattery: Bool, slowed: Bool,
                                   universal: Int?) -> Double {
        if let u = universal, u > 0 {
            var f = Double(u)
            if onBattery { f = min(f, settings.batteryMode == .efficient ? efficientFPS : batteryMaxFPS) }
            if slowed { f = min(f, efficientFPS) }
            return f
        }
        if slowed { return presetFPS > 0 ? min(efficientFPS, Double(presetFPS)) : efficientFPS }
        if !onBattery, settings.frameRate == .smooth { return 120 }
        var fps = onBattery && settings.batteryMode == .efficient ? efficientFPS
                : onBattery ? batteryMaxFPS : 30
        if presetFPS > 0 { fps = min(fps, Double(presetFPS)) }
        return fps
    }

    /// The rates Dynamic and Reactive step through: every exact divisor of 120 Hz from 120 down
    /// to 15 (on 60 Hz, divisorRate lands each on 60 / 30 / 20 / 15). 90 isn't one — on a
    /// 120 Hz screen it would hold frames for 1, 1, 2 refreshes, a visible judder — so a
    /// step down from 120 is 60, two is 40.
    static let ladder: [Double] = [120, 60, 40, 30, 24, 20, 15]

    /// `f` moved `steps` rungs down the ladder (never below 15, never above `f`); a rate under
    /// 15 (a clock's 1 fps) stays as it is.
    static func stepDown(_ f: Double, _ steps: Int) -> Double {
        guard steps > 0, let i = ladder.firstIndex(where: { $0 <= f + 0.01 }) else { return f }
        // off the ladder (a style's own 50): the rung under it is already one step down
        let on = abs(ladder[i] - f) < 0.01
        return min(f, ladder[min(i + steps - (on ? 0 : 1), ladder.count - 1)])
    }

    /// How far this power source's Frame Rate Mode steps down right now: Forced never;
    /// Dynamic by the Mac's load; Reactive one step while you're using another app (two if the
    /// Mac is also very busy), none while you're not.
    static func level(_ settings: WallpaperSettings, _ s: WallpaperPowerMonitor.State) -> ActivityLevel {
        switch settings.fpsMode(onBattery: s.onBattery) {
        case .forced: return .quiet
        case .dynamic: return s.load
        case .reactive: return s.userActive ? max(.moderate, s.load) : .quiet
        }
    }

    /// A note for the menu and the Wallpaper card while Dynamic or Reactive has stepped down.
    static func adaptiveStatus(_ settings: WallpaperSettings, _ s: WallpaperPowerMonitor.State) -> String? {
        guard level(settings, s) != .quiet else { return nil }
        return settings.fpsMode(onBattery: s.onBattery) == .reactive ? "Reactive — you're using another app"
                                                                    : "Dynamic — your Mac is busy"
    }

    /// Multiplier on Quality's pixels per point. Below 1 only for Efficient on battery, and only
    /// while the style moves continuously: a clock that draws once a second keeps crisp
    /// figures (its few frames cost next to nothing either way).
    static func renderScale(_ settings: WallpaperSettings, onBattery: Bool, profile: WallpaperPacing.Profile,
                            slowed: Bool = false) -> CGFloat {
        guard profile == .motion, slowed || (onBattery && settings.batteryMode == .efficient) else { return 1 }
        return efficientScale
    }

    /// Another app is in front and this power source's Another App Focused is Slow Down.
    static func slowed(_ settings: WallpaperSettings, _ s: WallpaperPowerMonitor.State) -> Bool {
        s.otherAppFront && (s.onBattery ? settings.otherAppOnBattery : settings.otherAppPluggedIn) == .efficient
    }

    /// Why motion holds on its last frame (a clock still turns over once a minute).
    static func stillReason(_ settings: WallpaperSettings, _ s: WallpaperPowerMonitor.State) -> String? {
        if s.lowPowerMode { return "Still — Low Power Mode" }
        if s.thermalHot { return "Still — Mac is running hot" }
        if s.onBattery && settings.batteryMode == .still { return "Paused — on battery" }
        if s.otherAppFront, (s.onBattery ? settings.otherAppOnBattery : settings.otherAppPluggedIn) == .pause {
            return "Paused — another app in front"
        }
        return nil
    }

    /// A note for the menu and the Wallpaper card while it plays reduced on battery.
    static func batteryStatus(_ settings: WallpaperSettings, onBattery: Bool, slowed: Bool = false) -> String? {
        if slowed { return "Slowed — another app in front" }
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

// MARK: - Activity (Frame Rate Mode)

/// How busy things are, as steps down the frame-rate ladder.
enum ActivityLevel: Int, Comparable, CustomStringConvertible {
    case quiet, moderate, busy
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var description: String { ["quiet", "moderate", "busy"][rawValue] }
}

/// One reading a second: CPU busy fraction across all cores (since the last reading), the
/// busiest GPU's utilisation (IOAccelerator's PerformanceStatistics — no permission needed),
/// and seconds since the last keyboard, mouse or scroll input anywhere in the session.
struct ActivitySampler {
    /// Input within this many seconds counts as "using your Mac" (Reactive).
    static let activeWindow: Double = 3

    private var lastTicks: (busy: UInt64, total: UInt64)?

    mutating func read() -> (cpu: Double, gpu: Double, idleSeconds: Double) {
        (cpuBusy(), Self.gpuBusy(), Self.idleSeconds())
    }

    private mutating func cpuBusy() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy &- last.busy) / Double(total - last.total)
    }

    private static func gpuBusy() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var best = 0.0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let pct = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best, pct / 100)
        }
        return best
    }

    private static func idleSeconds() -> Double {
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                                    .mouseMoved, .leftMouseDragged]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

/// Turns the once-a-second load readings into a steady level for Dynamic: quick to step down
/// (two readings over a threshold), slow to come back (five readings clearly under it), and
/// stubborn if it keeps bouncing — the wallpaper's own GPU work falls when it steps down, which
/// alone could make it step straight back up and down again. A level it had to return to
/// within 20 s of leaving is held for a minute.
struct LoadGovernor {
    /// Moderate from 30 % CPU or 45 % GPU; busy from 60 % CPU or 75 % GPU.
    static let moderate = (cpu: 0.30, gpu: 0.45)
    static let busy = (cpu: 0.60, gpu: 0.75)
    /// How far under a threshold a reading must be to step back up.
    static let margin = 0.10

    private(set) var level: ActivityLevel = .quiet
    private var cpu = 0.0, gpu = 0.0, primed = false
    private var over = 0, under = 0
    private var lastEased: Date?
    private var holdUntil = Date.distantPast

    mutating func feed(cpu c: Double, gpu g: Double, now: Date) -> ActivityLevel {
        // smoothed, so a one-second spike (an app launching) doesn't count
        if primed { cpu += (c - cpu) * 0.5; gpu += (g - gpu) * 0.5 } else { cpu = c; gpu = g; primed = true }
        let up = Self.target(cpu, gpu, slack: 0), down = Self.target(cpu, gpu, slack: Self.margin)
        if up > level {
            under = 0; over += 1
            if over >= 2 {
                if let e = lastEased, now.timeIntervalSince(e) < 20 { holdUntil = now.addingTimeInterval(60) }
                level = up; over = 0
            }
        } else if down < level {
            over = 0; under += 1
            if under >= 5, now >= holdUntil { level = down; under = 0; lastEased = now }
        } else {
            over = 0; under = 0
        }
        return level
    }

    /// The level these readings call for; `slack` lowers the thresholds (stepping back up has
    /// to clear them by that much).
    static func target(_ cpu: Double, _ gpu: Double, slack: Double) -> ActivityLevel {
        if cpu >= busy.cpu - slack || gpu >= busy.gpu - slack { return .busy }
        if cpu >= moderate.cpu - slack || gpu >= moderate.gpu - slack { return .moderate }
        return .quiet
    }
}
