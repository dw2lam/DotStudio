//  SetupGuide.swift — the guided screensaver setup's state: what's set up on this Mac (read
//  live, ~1 s, only while a guide is on screen), the "Open at login" choice, the floating guide
//  panel (Help ▸ Set Up Screensaver…, the Screensaver card, Settings › General), and the
//  one-time "start at login" nudge.
//
//  Views: SetupGuideWalkthrough.swift (the animated System Settings illustration) and
//  SetupGuideChecklist.swift (the live checklist, and the guide laid out for the onboarding
//  step and the panel). Parsers: SetupGuideStore.swift.
//
//  Read-only toward the system: it reads the wallpaper store, the screensaver and power prefs
//  and the login-item status. The only things it changes are DotStudio's own login item (when
//  the user continues with "Open at login" ticked) and the installed .saver (Install).

import SwiftUI
import Combine
import ServiceManagement

// MARK: - What's set up

/// One reading of everything the checklist shows.
struct SetupSnapshot: Equatable {
    enum Choice: Equatable {
        /// The wallpaper store couldn't be read.
        case unknown
        /// DotStudio is the screensaver on `on` of `of` connected displays.
        case chosen(on: Int, of: Int)
    }

    enum Login: Equatable {
        case enabled
        case off
        /// Registered, but the user has to allow it in System Settings › General › Login Items.
        case requiresApproval
    }

    var installed: Bool
    var choice: Choice
    /// Lock Screen › "Start Screen Saver when inactive", in seconds; 0 = Never; nil = never set
    /// (macOS's default, `SetupSnapshot.defaultIdle`).
    var idleSeconds: Int?
    /// Display-off timers per power source (nil: couldn't read pmset).
    var displaySleep: DisplaySleepTimers?
    var login: Login

    /// macOS starts the screensaver after 20 minutes until the user picks another time.
    static let defaultIdle = 1200

    var isChosen: Bool { if case .chosen(let on, _) = choice { return on > 0 } else { return false } }
    var chosenEverywhere: Bool { if case .chosen(let on, let of) = choice { return on > 0 && on >= of } else { return false } }

    /// The same three states the rest of the app shows (Installer.Status).
    var status: Installer.Status {
        guard installed else { return .notInstalled }
        if case .unknown = choice { return .ready }   // can't tell: don't nag
        return isChosen ? .ready : .notChosen
    }

    var effectiveIdle: Int { idleSeconds ?? Self.defaultIdle }
    var startsWhenInactive: Bool { effectiveIdle > 0 }

    /// Power sources whose display turns off before (or as) the screensaver would start.
    var displaySleepConflicts: [(source: String, minutes: Int)] {
        guard startsWhenInactive, let t = displaySleep else { return [] }
        var out: [(String, Int)] = []
        if let b = t.battery, b > 0, b * 60 <= effectiveIdle { out.append(("battery", b)) }
        if let a = t.ac, a > 0, a * 60 <= effectiveIdle { out.append(("power adapter", a)) }
        return out
    }
}

/// Reads a SetupSnapshot from the system. Safe off the main thread; read-only.
enum SetupProbe {
    static func read() -> SetupSnapshot {
        SetupSnapshot(installed: Installer.isInstalled,
                      choice: Installer.screensaverChoice(),
                      idleSeconds: idleSeconds(),
                      displaySleep: displaySleep(),
                      login: LoginItem.status())
    }

    /// `defaults -currentHost read com.apple.screensaver idleTime`, without a process.
    static func idleSeconds() -> Int? {
        let app = "com.apple.screensaver" as CFString
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let v = CFPreferencesCopyValue("idleTime" as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (v as? NSNumber)?.intValue
    }

    private static let pmsetLock = NSLock()
    private static var pmsetCache: (at: Date, value: DisplaySleepTimers?)?

    /// `pmset -g custom` (read-only), at most every 5 s — it changes only in System Settings.
    static func displaySleep() -> DisplaySleepTimers? {
        pmsetLock.lock(); defer { pmsetLock.unlock() }
        if let c = pmsetCache, Date().timeIntervalSince(c.at) < 5 { return c.value }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var value: DisplaySleepTimers?
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let t = DisplaySleepTimers.parse(pmsetCustom: String(decoding: data, as: UTF8.self))
            value = t.ac == nil && t.battery == nil && t.ups == nil ? nil : t
        }
        pmsetCache = (Date(), value)
        return value
    }
}

// MARK: - Login item

/// DotStudio's own login item (SMAppService.mainApp). Status reads are pinned in UI shots;
/// register / unregister never run there.
enum LoginItem {
    /// UI shots: the status every reader sees.
    static var demoStatus: SetupSnapshot.Login?
    /// The user unticked "Open at login" (guide or Settings): the guide stops pre-ticking it.
    static let declinedKey = "setupGuide.loginDeclined"

    private static var isRenderingShots: Bool { OffscreenCapture.isActive }

    static func status() -> SetupSnapshot.Login {
        if let demoStatus { return demoStatus }
        if isRenderingShots { return .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    /// Registers or unregisters, and remembers a "no". Returns an error message on failure.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        AppPrefs.shared.set(!on, declinedKey)
        guard !isRenderingShots, demoStatus == nil else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        guard !isRenderingShots else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    static var wasDeclined: Bool { AppPrefs.shared.bool(declinedKey, default: false) }
}

// MARK: - System Settings links

enum SystemSettingsLink {
    /// Lock Screen: "Start Screen Saver when inactive" and the display-off timers (macOS 13+).
    static func openLockScreen() {
        guard !OffscreenCapture.isActive,
              let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - The guide's state

/// What every on-screen guide shows: the latest snapshot (polled ~1 s while one is visible)
/// and the "Open at login" choice, committed when the user continues.
@MainActor
final class SetupGuideModel: ObservableObject {
    static let shared = SetupGuideModel()

    @Published private(set) var snapshot: SetupSnapshot
    /// "Open DotStudio at login" in the guide — ticked by default; applied by `commit()`.
    @Published var wantsLogin: Bool { didSet { if wantsLogin != oldValue { loginTouched = true } } }
    @Published private(set) var loginError: String?
    /// Pinned (UI shots): never polls, never commits.
    let isDemo: Bool

    private var loginTouched = false
    private var watchers = 0
    private var poll: Task<Void, Never>?
    /// Told when the installed / chosen state changes, so the gallery's card catches up.
    var onStatusChange: ((Installer.Status) -> Void)?

    init(demo: SetupSnapshot? = nil, wantsLogin: Bool? = nil) {
        isDemo = demo != nil
        let s = demo ?? SetupSnapshot(installed: Installer.isInstalled, choice: .unknown, idleSeconds: nil,
                                      displaySleep: nil, login: LoginItem.status())
        snapshot = s
        self.wantsLogin = wantsLogin ?? (s.login != .off || !LoginItem.wasDeclined)
    }

    /// A guide appeared: poll while at least one is on screen.
    func begin() {
        guard !isDemo, !OffscreenCapture.isActive else { return }
        watchers += 1
        guard poll == nil else { return }
        if snapshot.login == .off && !loginTouched { wantsLogin = !LoginItem.wasDeclined }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let s = await Task.detached(priority: .utility) { SetupProbe.read() }.value
                guard let self, !Task.isCancelled else { return }
                self.apply(s)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func end() {
        guard !isDemo, watchers > 0 else { return }
        watchers -= 1
        if watchers == 0 { poll?.cancel(); poll = nil }
    }

    /// Re-read now (after Install), without waiting for the next tick.
    func refresh() {
        guard !isDemo, !OffscreenCapture.isActive else { return }
        Task { [weak self] in
            let s = await Task.detached(priority: .userInitiated) { SetupProbe.read() }.value
            self?.apply(s)
        }
    }

    private func apply(_ s: SetupSnapshot) {
        let oldStatus = snapshot.status
        if s != snapshot { snapshot = s }
        if s.status != oldStatus { onStatusChange?(s.status) }
        // Allowed in System Settings meanwhile: nothing left to apply.
        if s.login == .enabled { loginError = nil }
    }

    /// The user continued: apply "Open at login". Registers when ticked and not yet on;
    /// unregisters only when the user unticked it here.
    func commit() {
        guard !isDemo else { return }
        let on = snapshot.login != .off
        if wantsLogin && !on {
            loginError = LoginItem.set(true)
        } else if !wantsLogin && on && loginTouched {
            loginError = LoginItem.set(false)
        } else if !wantsLogin && loginTouched {
            AppPrefs.shared.set(true, LoginItem.declinedKey)
        }
        loginTouched = false
        refresh()
    }

    /// Opens Wallpaper settings; the floating guide (when it's the one asking) moves beside it.
    func openSystemSettings() {
        guard !OffscreenCapture.isActive else { return }
        Installer.openScreenSaverSettings()
    }
}

// MARK: - The floating guide panel

/// Help ▸ Set Up Screensaver…, the Screensaver card's "Show Me How" and Settings › General's
/// "Run Setup Again": the guide in a small panel that floats, so it stays visible beside
/// System Settings while the user follows it.
@MainActor
final class SetupGuidePanel: NSObject, NSWindowDelegate {
    static let shared = SetupGuidePanel()
    private weak var model: AppModel?
    private var panel: NSPanel?

    /// The panel's content size at the default text size (it grows with the text).
    static let size = CGSize(width: 440, height: 680)

    func attach(model: AppModel) { self.model = model }

    func show(model: AppModel? = nil) {
        guard !OffscreenCapture.isActive else { return }
        if let model { self.model = model }
        guard let model = self.model else { return }
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let guide = SetupGuideModel.shared
        guide.onStatusChange = { [weak model] _ in model?.refreshSetupStatus() }
        let root = SetupGuidePanelView(guide: guide,
                                       onOpenSettings: { [weak self] in self?.moveBesideSettings() },
                                       onDone: { [weak self] in self?.close() })
            .environmentObject(model)
            .adaptiveLayout()
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Set Up Screensaver"
        p.isFloatingPanel = true            // stays above System Settings while the user follows it
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        p.contentViewController = NSHostingController(rootView: root)
        p.setContentSize(Self.size)
        p.contentMinSize = CGSize(width: 380, height: 520)
        p.delegate = self
        p.center()
        // Small displays: never taller than the visible area (the guide scrolls inside), so
        // Done at its foot stays reachable.
        if let vf = (p.screen ?? NSScreen.main)?.visibleFrame {
            p.setFrame(clamped(p.frame, in: vf, minimum: minimumFrameSize(p)), display: false)
        }
        panel = p
        let coach = SetupCoach.shared
        coach.log = { [weak model] in model?.store.debug("coach", $0) }
        coach.install = { [weak model] in model?.installScreensaver() }
        coach.onSettingsFrame = { [weak self] in self?.dock(besideSettingsAX: $0) }
        // A target under this panel shows the picture instead of a ring nobody can click.
        coach.panelFrame = { [weak self] in
            guard let p = self?.panel, p.isVisible, !p.isMiniaturized else { return nil }
            return p.frame
        }
        docked = false
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var docked = false

    /// The smallest the panel's frame gets (its content minimum plus the title bar).
    private func minimumFrameSize(_ panel: NSPanel) -> CGSize {
        panel.frameRect(forContentRect: CGRect(origin: .zero, size: panel.contentMinSize)).size
    }

    /// Never taller than the screen's visible area (the content scrolls inside); on screen.
    private func clamped(_ f: CGRect, in vf: CGRect, minimum: CGSize) -> CGRect {
        var f = f
        f.size.height = max(min(f.height, vf.height), min(minimum.height, vf.height))
        f.size.width = min(f.width, vf.width)
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        return f
    }

    /// The coach found the Settings window (AX global frame): put the guide beside it so it
    /// never covers what the user has to click ("Screen Saver…" and Done are on the window's
    /// right). Tries its current width right then left of the window, then its narrowest width,
    /// and with no room either side, the screen's LEFT edge (over the sidebar, away from those
    /// buttons). Always within the screen's visible height. After the first time, only when the
    /// two overlap — a guide the user moved stays put.
    private func dock(besideSettingsAX ax: CGRect) {
        guard let panel, let main = NSScreen.screens.first else { return }
        let s = CoachGeometry.flip(ax, mainHeight: main.frame.height)
        if docked && !panel.frame.intersects(s) { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: s.midX, y: s.midY)) } ?? panel.screen ?? main
        let vf = screen.visibleFrame
        let minimum = minimumFrameSize(panel)
        let gap = Space.s
        var f = panel.frame
        var placed = false
        for width in [f.width, minimum.width] where !placed {
            if s.maxX + gap + width <= vf.maxX {
                f.size.width = width; f.origin.x = s.maxX + gap; placed = true
            } else if s.minX - gap - width >= vf.minX {
                f.size.width = width; f.origin.x = s.minX - gap - width; placed = true
            }
        }
        if !placed {
            f.size.width = minimum.width
            f.origin.x = vf.minX
        }
        // Top aligned with the Settings window, clamped to the visible area.
        f.origin.y = s.maxY - f.height
        f = clamped(f, in: vf, minimum: minimum)
        docked = true
        guard !f.equalTo(panel.frame) else { return }
        if Motion.reduceMotion { panel.setFrame(f, display: true) } else { panel.animator().setFrame(f, display: true) }
    }

    /// "Open System Settings" without the coach: System Settings opens near the middle of the
    /// screen, its buttons on the right — park the guide, narrowest, at the left edge.
    private func moveBesideSettings() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let minimum = minimumFrameSize(panel)
        var f = panel.frame
        f.size.width = minimum.width
        f.origin = CGPoint(x: vf.minX + Space.s, y: vf.maxY - f.height - Space.s)
        f = clamped(f, in: vf, minimum: minimum)
        if Motion.reduceMotion { panel.setFrame(f, display: true) } else { panel.animator().setFrame(f, display: true) }
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // The coach reads System Settings only while this guide is open.
        SetupCoach.shared.stop()
        SetupGuideModel.shared.commit()
        panel?.contentViewController = nil
        panel = nil
        model?.refreshSetupStatus()
    }
}

// MARK: - Login nudge

/// Turning on the live wallpaper or the music display while DotStudio doesn't open at login:
/// once, an inline suggestion to start it at login (both stop after a restart otherwise).
@MainActor
final class LoginNudge: ObservableObject {
    static let shared = LoginNudge()
    enum Kind: Equatable { case wallpaper, music }

    @Published private(set) var pending: Kind?
    static let answeredKey = "loginNudgeAnswered"

    private weak var model: AppModel?
    private var subs: Set<AnyCancellable> = []
    private var wallpaperOn = false
    private var musicOn = false

    func attach(model: AppModel) { self.model = model }

    /// After launch-time restores, so restoring a wallpaper never counts as turning it on.
    func start() {
        guard !OffscreenCapture.isActive, subs.isEmpty, let model else { return }
        wallpaperOn = WallpaperController.shared.isActive
        musicOn = model.library.musicSettings.displayMode != .off
        let changes = WallpaperController.shared.objectWillChange.map { _ in () }
            .merge(with: model.objectWillChange.map { _ in () })
        changes
            .receive(on: DispatchQueue.main)   // objectWillChange fires before the change
            .sink { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
            .store(in: &subs)
        // Music is on by default (Corner), so it's never "turned on": suggest it instead the
        // first time a song is actually playing for the screensaver / wallpaper to show.
        MusicMonitor.shared.$state
            .map { $0.hasTrack && ($0.isPlaying ?? false) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in MainActor.assumeIsolated { if playing { self?.songShown() } } }
            .store(in: &subs)
    }

    /// Once ever: the first song shown while music is on and DotStudio doesn't open at login.
    static let songSeenKey = "loginNudgeMusicSongSeen"

    private func songShown() {
        guard let model, model.library.musicSettings.displayMode != .off,
              !AppPrefs.shared.bool(Self.songSeenKey, default: false) else { return }
        AppPrefs.shared.set(true, Self.songSeenKey)
        guard pending == nil, !AppPrefs.shared.bool(Self.answeredKey, default: false),
              LoginItem.status() == .off else { return }
        pending = .music
    }

    /// UI shots (main thread): show the suggestion for `kind`.
    nonisolated func setDemo(_ kind: Kind?) {
        MainActor.assumeIsolated { pending = kind }
    }

    private func evaluate() {
        guard let model else { return }
        let wp = WallpaperController.shared.isActive
        let music = model.library.musicSettings.displayMode != .off
        defer { wallpaperOn = wp; musicOn = music }
        if !wp && pending == .wallpaper { pending = nil }
        if !music && pending == .music { pending = nil }
        let turnedOn: Kind? = wp && !wallpaperOn ? .wallpaper : music && !musicOn ? .music : nil
        guard let turnedOn, pending == nil,
              !AppPrefs.shared.bool(Self.answeredKey, default: false),
              LoginItem.status() == .off else { return }
        pending = turnedOn
    }

    func turnOn() {
        AppPrefs.shared.set(true, Self.answeredKey)
        LoginItem.set(true)
        pending = nil
    }

    func notNow() {
        AppPrefs.shared.set(true, Self.answeredKey)
        pending = nil
    }
}

/// The nudge, inline: in the card (or Settings section) where the user just turned it on.
struct LoginNudgeBanner: View {
    @ObservedObject private var nudge = LoginNudge.shared
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only for this kind; nil: either.
    var kind: LoginNudge.Kind?
    /// Space above it when it shows (the card's banner slot has none of its own).
    var topPadding: CGFloat?

    var body: some View {
        Group {
            if let pending = nudge.pending, kind == nil || kind == pending {
                content(pending)
                    .padding(.top, topPadding ?? layout.itemGap)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: nudge.pending)
    }

    private func content(_ pending: LoginNudge.Kind) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        let what = pending == .wallpaper ? "your live wallpaper keeps playing" : "music keeps showing on your screensaver"
        return ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .center, spacing: layout.itemGap) {
                Image(systemName: "power.circle.fill")
                    .scaledFont { .scaled(points: 20, $0) }
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Start DotStudio at login so \(what) after a restart.")
                    .textRole(.callout)
                    .wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: layout.controlGap) {
                Button { nudge.notNow() } label: { Text("Not Now").textRole(.body) }
                    .buttonStyle(.link)
                Button { nudge.turnOn() } label: { Text("Turn On").textRole(.body) }
                    .glassButton(.prominent)
                    .adaptiveControlSize()
                    .accessibilityHint("Opens DotStudio quietly in the menu bar when you log in")
            }
            .fixedSize()
        }
        .padding(layout.itemGap)
        .background(shape.fill(Color.accentColor.opacity(0.10)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.22)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion: start DotStudio at login")
    }
}
