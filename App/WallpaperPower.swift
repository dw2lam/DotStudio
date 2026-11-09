//  WallpaperPower.swift — the power side of the live wallpaper: persisted settings,
//  the system conditions that pause it, and frame pacing.
//
//  The wallpaper should look smooth and cost little. The levers:
//    • Pacing   — frames come from the display link at an exact divisor of the
//                 screen's refresh (30 fps by default; Smooth = the display's own rate,
//                 up to 120 Hz on ProMotion), so every frame
//                 lasts the same time; uneven rates like 20 on 60/120 Hz read as lag.
//                 Clocks tick once a second and only animate around a change.
//    • Scale    — rendering at reduced resolution (Balanced: 1.5 px/pt, 0.75 on Retina).
//    • Pausing  — no draws and no wake-ups at all while nobody can see it (covered,
//                 locked, display or system asleep, screensaver running), in Low Power
//                 Mode, or when paused from the menu bar.
//    • Stilling — a hot Mac (and battery, if opted in) holds the last frame; a clock
//                 still turns over once a minute so it never lies. On battery it plays
//                 at 30 fps.
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

    var enabled = false
    var presetID: UUID?
    var frameRate: FrameRate = .balanced
    var quality: Quality = .balanced
    /// On battery: freeze on a still frame (opt-in). Otherwise it plays at 30 fps.
    var freezeOnBattery = false
    /// "Match Screensaver": show whatever the screensaver would (Playback.effectivePreset —
    /// rotation, night style) on the shared wall-clock time base, instead
    /// of `presetID`. See WallpaperController.setFollowsScreensaver(_:).
    var followsScreensaver = false

    init() {}

    // Tolerant decoding: a field added later must not reset the user's choice.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        presetID = try? c.decode(UUID.self, forKey: .presetID)
        frameRate = (try? c.decode(FrameRate.self, forKey: .frameRate)) ?? .balanced
        quality = (try? c.decode(Quality.self, forKey: .quality)) ?? .balanced
        freezeOnBattery = (try? c.decode(Bool.self, forKey: .freezeOnBattery)) ?? false
        followsScreensaver = (try? c.decode(Bool.self, forKey: .followsScreensaver)) ?? false
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
        on(dist, .init("com.apple.screenIsLocked")) { $0.screenLocked = true }
        on(dist, .init("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        on(dist, .init("com.apple.screensaver.didstart")) { $0.screensaverRunning = true }
        on(dist, .init("com.apple.screensaver.didstop")) { $0.screensaverRunning = false }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        on(ws, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        on(ws, NSWorkspace.didWakeNotification) { s in
            s.systemAsleep = false
            s.displayAsleep = false      // a wake always lights the displays
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

    /// The exact divisor of `refresh` closest to `target` (30 on 60/120 Hz, 25 on 50 Hz,
    /// 36 on 144 Hz...), so every frame is held for the same number of refreshes.
    static func divisorRate(target: Double, refresh: Double) -> Double {
        guard refresh > 0 else { return target }
        let n = max((refresh / max(target, 1)).rounded(), 1)
        return refresh / n
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
