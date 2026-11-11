//  WallpaperController.swift — "Use as Wallpaper": a live, animated desktop wallpaper.
//
//  One borderless window per display at the desktop window level — above the system
//  wallpaper, below Finder's desktop icons — on every Space, invisible to clicks,
//  Mission Control and the window cycle. Each hosts a CAMetalLayer that the shared
//  MetalRenderer draws the chosen style into, at reduced resolution.
//
//  Frames are paced by each display's own display link (macOS 14 NSView.displayLink)
//  at an exact divisor of that display's refresh rate, so every frame is held for the
//  same number of refreshes — smooth at 30. Clocks idle on a one-shot timer aligned to
//  the second and only switch the display link on while a figure is changing. When no
//  display can show a frame (covered, locked, asleep, screensaver, Low Power, user
//  pause) every link and timer is parked and the process does no work at all; the last
//  frame stays on screen, so resuming never flashes or rebuilds anything.
//
//  Threads: this controller, the windows and the policy live on the main thread. All
//  per-frame work — display links, uniforms, encoding, drawables, media decode and
//  upload — runs on WallpaperRenderLoop's own thread (user-initiated while animating,
//  utility for clock ticks and idle). The main thread hands it immutable snapshots and
//  never waits on it.

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A desktop-level window that never takes focus or clicks.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperController: ObservableObject {
    static let shared = WallpaperController()

    @Published private(set) var settings: WallpaperSettings = WallpaperSettings()
    /// Paused from the menu bar (not persisted: a relaunch always resumes).
    @Published private(set) var userPaused = false
    /// Why it isn't animating normally right now, for the menu bar ("Paused — screen locked").
    @Published private(set) var statusText: String?

    /// The wallpaper is on and its style still exists.
    var isActive: Bool { settings.enabled && currentPreset != nil }
    /// The style on the desktop: the chosen one, or — while matching the screensaver —
    /// exactly what the screensaver would show now (rotation slot, night style).
    var currentPreset: Preset? {
        guard let lib = model?.library else { return nil }
        if settings.followsScreensaver {
            return lib.presets.isEmpty ? nil : Playback.effectivePreset(in: lib, now: Date())
        }
        guard let id = settings.presetID else { return nil }
        return lib.presets.first { $0.id == id }
    }

    // Music: the shared feed (MusicFeedHub), followed only while something on the desktop
    // depends on it and someone can see it. Overlays tick on the main thread at 1 Hz on
    // their own; the Metal pacing never has to speed up for them (except while the Album
    // Art backdrop moves behind Full Screen music).
    private var musicToken: MusicFeedHub.Token?
    private var musicSubscribing = false
    private var musicSnapshot = MusicSnapshot.empty
    private var musicVisible = false
    /// What MusicPresentation last said for the desktop (the renderer's backdrop follows it).
    private var musicPresentation = MusicPresentation.none
    /// Re-evaluates the followed lineup at rotation slot boundaries (and each minute for the
    /// night schedule) while matching the screensaver.
    private var slotTimer: Timer?

    private weak var model: AppModel?
    private var settingsURL: URL?
    private var hosts: [CGDirectDisplayID: WallpaperHost] = [:]
    private let power = WallpaperPowerMonitor()
    private var observers: [NSObjectProtocol] = []
    /// A wallpaper session is up: the power monitor, the screen/occlusion observers and the
    /// slot timer belong to it. Tracked apart from `hosts`, which can be empty while running
    /// (no GPU for a display yet, every surface failed) — tearDown must still end the session.
    private var running = false
    private var librarySub: AnyCancellable?
    private var applied: (preset: Preset, source: SourceSpec, location: (lat: Double, lon: Double)?)?
    private var profile: WallpaperPacing.Profile = .still
    private var openMainWindowAction: (() -> Void)?
    private var nextToken: UInt64 = 0
    private var lastLoggedState = ""
    /// The multiplier on Quality's pixels per point the drawables are sized with
    /// (WallpaperBudget.renderScale; reevaluate resizes them when it changes).
    private var renderScale: CGFloat = 1

    /// The render thread, started the first time a wallpaper turns on, then kept
    /// (an idle run loop costs nothing).
    private var renderLoop: WallpaperRenderLoop?

    /// DEV: treat every display as visible, to measure render cost on a desktop that is
    /// covered by windows (DOTSTUDIO_WALLPAPER_IGNORE_OCCLUSION=1).
    private let ignoreOcclusion = ProcessInfo.processInfo.environment["DOTSTUDIO_WALLPAPER_IGNORE_OCCLUSION"] == "1"

    // MARK: Lifecycle

    /// Called once at launch, before the app finishes launching.
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        settingsURL = model.store.baseDir.appendingPathComponent("wallpaper.json")
        settings = WallpaperSettings.load(from: settingsURL!)
        librarySub = model.$library
            .receive(on: DispatchQueue.main)        // $library fires in willSet; read it after
            .sink { [weak self] _ in self?.libraryChanged() }
        // The gallery (tiles, Wallpaper card, editor) talks to WallpaperSlot; plug in.
        if DemoHooks.wallpaperStub == nil {
            WallpaperSlot.shared.connect(.init(
                styleID: { [weak self] in self?.isActive == true ? self?.currentPreset?.id : nil },
                set: { [weak self] in self?.use($0) },
                stop: { [weak self] in self?.stop() },
                changes: objectWillChange.map { _ in }.eraseToAnyPublisher()))
        }
    }

    /// The style wallpaper.json picks (nil: none, or no wallpaper.json yet). For migrations.
    static func pickedPresetID(storeDir: URL) -> UUID? {
        let url = storeDir.appendingPathComponent("wallpaper.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return WallpaperSettings.load(from: url).presetID
    }

    /// 1.4.2 retirement (DefaultPresets.retireUntouched, run by AppModel.migrate before `attach`):
    /// a wallpaper showing a removed style moves to its replacement. Rewrites wallpaper.json in
    /// `storeDir` only when its pick was removed; returns that move.
    @discardableResult
    static func followRetirement(storeDir: URL, _ replacements: [UUID: UUID?]) -> (old: UUID, new: UUID?)? {
        let url = storeDir.appendingPathComponent("wallpaper.json")
        guard !replacements.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return nil }
        var s = WallpaperSettings.load(from: url)
        guard let old = s.presetID, let new = replacements[old] else { return nil }
        s.presetID = new
        s.save(to: url)
        return (old, new)
    }

    /// Bring back the wallpaper the user left on (applicationDidFinishLaunching).
    func restore() {
        applyDevOverrides()
        syncLibraryTimeBase()
        if settings.enabled { start() }
        // A lock-screen picture left set (or left to restore) by the last run.
        syncLockPicture("launch", after: 3)
    }

    /// The SwiftUI hook that opens the main window (captured from a view's environment).
    func registerOpenMainWindow(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    // MARK: Public actions

    /// Show one chosen style (stops matching the screensaver).
    func use(_ presetID: UUID) {
        update { $0.enabled = true; $0.presetID = presetID; $0.followsScreensaver = false }
        userPaused = false
        start()
    }

    /// "Match Screensaver": the wallpaper shows what the screensaver would show right now
    /// (Playback.effectivePreset), re-evaluated at rotation
    /// slot boundaries with the rotation's crossfade, on the shared wall-clock time base —
    /// and `Library.syncTimeBase` is set so the screensaver uses that time base too, starting
    /// on exactly the frame the desktop shows. Off: back to `presetID` (adopting the style on
    /// screen when none was ever picked), per-instance time. Turns the wallpaper on when
    /// switching on.
    func setFollowsScreensaver(_ on: Bool) {
        let keep = on ? nil : styleToKeep()
        update {
            $0.followsScreensaver = on
            if on { $0.enabled = true }
            if let keep { $0.presetID = keep }
        }
        if on {
            userPaused = false
            start()
        }
    }

    var followsScreensaver: Bool { settings.followsScreensaver }

    /// Leaving Match Screensaver: keep the chosen style if it still exists, else the style
    /// the desktop shows now (when it's a library style), else the active one.
    private func styleToKeep() -> UUID? {
        guard let lib = model?.library else { return nil }
        func exists(_ id: UUID?) -> UUID? { id.flatMap { id in lib.presets.contains { $0.id == id } ? id : nil } }
        if exists(settings.presetID) != nil { return nil }
        return exists(applied?.preset.id) ?? exists(lib.activeID) ?? lib.presets.first?.id
    }

    /// `Library.syncTimeBase` mirrors "a wallpaper is matching the screensaver": the saver uses
    /// the wall-clock time base exactly while one is (so a lone saver keeps per-instance time).
    private func syncLibraryTimeBase() {
        guard let model else { return }
        let want: Bool? = (settings.enabled && settings.followsScreensaver) ? true : nil
        guard model.library.syncTimeBase != want else { return }
        model.library.syncTimeBase = want
        model.save()
    }

    func stop() {
        update { $0.enabled = false }
        userPaused = false
        tearDown()
    }

    func setEnabled(_ on: Bool) {
        if on, settings.followsScreensaver {
            update { $0.enabled = true }
            userPaused = false
            start()
        } else if on {
            let id = settings.presetID.flatMap { id in model?.preset(id)?.id }
                ?? model?.library.activeID ?? model?.library.presets.first?.id
            if let id { use(id) }
        } else {
            stop()
        }
    }

    func togglePause() {
        userPaused.toggle()
        log("user \(userPaused ? "paused" : "resumed")")
        reevaluate()
    }

    func update(_ change: (inout WallpaperSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        if let url = settingsURL { s.save(to: url) }
        syncLibraryTimeBase()
        if s.lockScreen != old.lockScreen || s.enabled != old.enabled || s.presetID != old.presetID
            || s.followsScreensaver != old.followsScreensaver {
            syncLockPicture("settings", after: s.lockScreen != old.lockScreen || !s.enabled ? 0 : 1)
        }
        guard s.enabled, !hosts.isEmpty else { return }
        if s.followsScreensaver != old.followsScreensaver {
            applyTimeBase()
            scheduleSlotTimer()
        }
        if s.presetID != old.presetID || s.followsScreensaver != old.followsScreensaver { applyStyle() }
        if s.quality != old.quality {
            hosts.values.forEach { configure($0) }
            reevaluate(forceDraw: true)
        } else {
            reevaluate()
        }
    }

    /// Open (or bring forward) the main DotStudio window.
    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = mainWindows.first {
            win.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { w in
            !(w is WallpaperWindow) && w.styleMask.contains(.titled)
                && !(w.identifier?.rawValue.contains("Settings") ?? false)
        }
    }

    /// Quit-time cleanup: drop the windows so the desktop picture shows immediately.
    func shutdown() {
        tearDown()
    }

    // MARK: Start / stop

    private func start() {
        guard let model, settings.enabled, currentPreset != nil else { tearDown(); return }
        if !running {
            running = true
            power.onChange = { [weak self] state in
                guard let self else { return }
                self.log("power \(state)")
                let locking = state.screenLocked && !self.wasLocked
                self.wasLocked = state.screenLocked
                self.reevaluate()
                if locking { self.syncLockPicture("lock") }
            }
            power.start()
            wasLocked = power.state.screenLocked
            observe()
            log("start style=\(currentPreset?.name ?? "?") fps=\(settings.frameRate.rawValue) quality=\(settings.quality.rawValue)")
        }
        rebuildHosts(store: model.store)
        applyTimeBase()
        // Hand the render thread the current music before the first frame (Now Playing, and
        // Full Screen music's backdrop — already in, not easing in, on a fresh desktop).
        let snap = MusicFeedHub.shared.snapshot(store: model.store)
        musicSnapshot = snap
        renderLoop?.setMusic(snap, lingerMinutes: model.library.musicSettings.linger)
        musicPresentation = MusicPresentation.resolve(settings: model.library.musicSettings, music: snap,
                                                      preset: currentPreset, surface: .wallpaper)
        musicVisible = snap.isVisible(settings: model.library.musicSettings)
        renderLoop?.setMusicBackdrop(musicPresentation.backdrop, animated: false)
        applyStyle()
        scheduleSlotTimer()
        reevaluate(forceDraw: true)
    }

    private func tearDown() {
        guard running || !hosts.isEmpty else { return }
        running = false
        log("stop")
        renderLoop?.removeAll()
        for h in hosts.values { h.close() }
        hosts.removeAll(); hiddenSince.removeAll()
        applied = nil
        musicToken = nil
        musicSnapshot = .empty
        musicPresentation = .none
        slotTimer?.invalidate()
        slotTimer = nil
        power.stop()
        power.onChange = nil
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        statusText = nil
        CATransaction.flush()
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            // Only while a wallpaper is meant to be up: a change must never bring one back.
            guard let self, self.running, self.settings.enabled, let model = self.model else { return }
            self.log("screens changed (\(NSScreen.screens.count))")
            self.rebuildHosts(store: model.store)
            self.applyStyle()
            self.reevaluate(forceDraw: true)
            self.syncLockPicture("screens", after: 1)
        })
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self, let win = note.object as? WallpaperWindow else { return }
            if let h = self.hosts.values.first(where: { $0.window === win }) {
                let visible = win.occlusionState.contains(.visible)
                self.log("display \(h.displayID) occlusion visible=\(visible)")
                if visible {
                    self.hiddenSince[h.displayID] = nil
                } else if self.hiddenSince[h.displayID] == nil {
                    // Switching Spaces reports the desktop hidden for 0.1–1 s; keep drawing
                    // through that and only pause once it has stayed covered.
                    self.hiddenSince[h.displayID] = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverGrace + 0.05) { [weak self] in
                        self?.reevaluate()
                    }
                }
            }
            self.reevaluate()
        })
    }

    private func makeRenderLoop(store: SharedStore) -> WallpaperRenderLoop {
        if let renderLoop { return renderLoop }
        let loop = WallpaperRenderLoop(store: store)
        loop.onFirstFrame = { [weak self] id, token in
            guard let h = self?.hosts[id], h.token == token else { return }
            h.fadeIn()
        }
        loop.onSurfaceFailed = { [weak self] id, token in
            guard let self, let h = self.hosts[id], h.token == token else { return }
            self.log("display \(id): no renderer")
            h.close()
            self.hosts.removeValue(forKey: id)
        }
        renderLoop = loop
        return loop
    }

    /// One host per connected display; existing ones follow moves and resolution changes.
    private func rebuildHosts(store: SharedStore) {
        let loop = makeRenderLoop(store: store)
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let h = hosts[id] {
                h.follow(screen)
                configure(h)
                continue
            }
            guard let device = WallpaperGPU.device(for: id) else { continue }
            nextToken += 1
            let h = WallpaperHost(screen: screen, displayID: id, device: device, token: nextToken)
            hosts[id] = h
            let link = h.view.displayLink(target: WallpaperRenderLoop.linkTarget(loop, display: id),
                                          selector: WallpaperRenderLoop.linkSelector)
            loop.addDisplay(id, token: h.token, layer: h.metalLayer, link: link, device: device,
                            config: h.surfaceConfig(quality: settings.quality, scale: renderScale))
        }
        for (id, h) in hosts where !seen.contains(id) {
            loop.removeDisplay(id)
            h.close()
            hosts.removeValue(forKey: id)
        }
        applied = nil   // new hosts need the style
    }

    /// Hand a display's current drawable size and refresh rate to the render thread.
    private func configure(_ h: WallpaperHost) {
        renderLoop?.configure(h.displayID, h.surfaceConfig(quality: settings.quality, scale: renderScale))
    }

    // MARK: Style

    private func libraryChanged() {
        guard settings.enabled, running else { return }
        guard currentPreset != nil else {
            log("style deleted — stopping")
            stop()
            return
        }
        // Music settings (Show music, corner, backdrop, linger) and the rotation live in the library too.
        renderLoop?.setMusic(musicSnapshot, lingerMinutes: model?.library.musicSettings.linger ?? MusicSpec().linger)
        applyStyle()
        scheduleSlotTimer()
        updateMusicOverlays(animated: true)
        updateMusicSubscription()
    }

    /// Push the current style + shared source to every display (only when it changed).
    /// - fade: a lineup-driven switch while matching the screensaver (rotation slot, night)
    ///   crossfades like the saver — when both styles animate continuously (a held frame
    ///   can't play a crossfade); edits and manual picks cut.
    private func applyStyle(fade: Bool = false) {
        guard let model, let preset = currentPreset else { return }
        let source = model.library.source
        let location = model.locationTuple
        // The location matters too (live sky, Universe marker): it is refreshed about daily.
        if let a = applied, a.preset == preset, a.source == source,
           a.location?.lat == location?.lat, a.location?.lon == location?.lon { return }
        let styleChanged = applied?.preset.id != preset.id
        let newProfile = pacingProfile(preset, source: source)
        var seconds = 0.0
        if fade, styleChanged, applied != nil, profile == .motion, newProfile == .motion, stillReason == nil {
            seconds = model.library.rotation?.transitionSeconds ?? 1.5
        }
        renderLoop?.setStyle(preset, source: source, location: location, fade: seconds)
        applied = (preset, source, location)
        profile = newProfile
        if styleChanged { log("style \(preset.name) profile=\(profile)\(seconds > 0 ? " fade=\(seconds)" : "")") }
        syncLockPicture("style", after: 2)    // edits come in bursts: the last one wins
        reevaluate(forceDraw: true)   // an edit shows even when holding a still
        updateMusicOverlays(animated: true)
    }

    private func applyTimeBase() {
        renderLoop?.setTimeBase(settings.followsScreensaver ? .wallClock : .instance)
    }

    /// While matching the screensaver with a rotation or night schedule: re-evaluate just
    /// after each slot boundary (the saver's own slots are the same wall-clock slots), and at
    /// least once a minute when a night schedule can flip at sunset.
    private func scheduleSlotTimer() {
        slotTimer?.invalidate()
        slotTimer = nil
        guard settings.enabled, settings.followsScreensaver, !hosts.isEmpty, let lib = model?.library else { return }
        let rotating = Playback.secondsUntilNextSlot(in: lib, now: Date())
        let scheduled = lib.schedule?.enabled ?? false
        guard rotating != nil || scheduled else { return }
        let delay = min(rotating ?? 60, scheduled ? 60 : .infinity) + 0.02
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.applyStyle(fade: true)
            self?.scheduleSlotTimer()
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        slotTimer = t
    }

    // MARK: Music

    /// Whether anything on the desktop depends on what's playing.
    private var needsMusic: Bool {
        guard settings.enabled, !hosts.isEmpty, let lib = model?.library else { return false }
        return (currentPreset?.isMusicScene ?? false) || lib.musicSettings.drawsOnWallpaper
    }

    /// The display-link pacing for a style — continuous while the Album Art backdrop (living
    /// art) is up behind Full Screen music, whatever the style itself needs.
    private func pacingProfile(_ preset: Preset, source: SourceSpec) -> WallpaperPacing.Profile {
        if case .albumArt = musicPresentation.backdrop { return .motion }
        return WallpaperPacing.profile(for: preset, source: source)
    }

    /// Follow the feed only while it matters and someone can see the desktop: covered,
    /// locked or paused costs nothing (the overlays keep their last state).
    private func updateMusicSubscription() {
        let run = needsMusic && hardPauseReason == nil && hosts.values.contains(where: isVisible)
        if run, musicToken == nil, !musicSubscribing, let store = model?.store {
            musicSubscribing = true
            musicToken = MusicFeedHub.shared.subscribe(store: store) { [weak self] snap, changed in
                self?.musicTick(snap, changed: changed)
            }
            musicSubscribing = false
        } else if !run, musicToken != nil {
            musicToken = nil
        }
    }

    private func musicTick(_ snap: MusicSnapshot, changed: Bool) {
        guard let lib = model?.library else { return }
        let ms = lib.musicSettings
        musicSnapshot = snap
        if changed { renderLoop?.setMusic(snap, lingerMinutes: ms.linger) }
        let visible = snap.isVisible(settings: ms)
        let flipped = visible != musicVisible
        musicVisible = visible
        // A new cover — or music starting, or the paused linger running out — shows even
        // while the background holds a frame (that forced frame is drawn settled).
        let artBehind: Bool = { if case .albumArt = musicPresentation.backdrop { return true }; return false }()
        if changed || flipped, currentPreset?.isMusicScene == true || artBehind { reevaluate(forceDraw: true) }
        updateMusicOverlays(animated: true)
    }

    /// What MusicPresentation says for the desktop (Show music, "Also on the live wallpaper",
    /// a legacy Now Playing style's own foreground): the overlays' mode, and the renderer's
    /// Full Screen backdrop — which eases in and out while frames run, and shows its end
    /// state on a held frame.
    private func updateMusicOverlays(animated: Bool) {
        guard let lib = model?.library else { return }
        let ms = lib.musicSettings
        let p = settings.enabled
            ? MusicPresentation.resolve(settings: ms, music: musicSnapshot, preset: currentPreset, surface: .wallpaper)
            : .none
        if p.backdrop != musicPresentation.backdrop {
            musicPresentation = p
            renderLoop?.setMusicBackdrop(p.backdrop, animated: animated)
            if let a = applied { profile = pacingProfile(a.preset, source: a.source) }
            log("music backdrop \(p.backdrop)")
            reevaluate(forceDraw: true)
        }
        musicPresentation = p
        for h in hosts.values { h.setMusic(mode: p.overlay, music: musicSnapshot, settings: ms, animated: animated) }
    }

    // MARK: Policy

    /// Full pauses: nobody can see it (or Low Power asked us to stop) — no work at all.
    private var hardPauseReason: String? {
        let s = power.state
        if userPaused { return "Paused" }
        if s.systemAsleep { return "Paused — Mac asleep" }
        if s.displayAsleep { return "Paused — display asleep" }
        if s.screenLocked { return "Paused — screen locked" }
        if s.screensaverRunning { return "Paused — screensaver running" }
        if s.lowPowerMode { return "Paused — Low Power Mode" }
        return nil
    }

    /// Holds: keep the last frame (a clock still turns over once a minute) — hot Mac, or
    /// On Battery: Still.
    private var stillReason: String? { WallpaperBudget.stillReason(settings, power.state) }

    /// Frames per second asked of the display links (WallpaperBudget.fps: 30, Smooth's display
    /// rate, 30 / 20 on battery; less only if the style itself asks for fewer).
    private var targetFPS: Double {
        WallpaperBudget.fps(settings, presetFPS: currentPreset?.fps ?? 0, onBattery: power.state.onBattery)
    }

    /// How long a desktop must stay covered before the wallpaper pauses: Space switches and
    /// Mission Control report it hidden for well under this, and pausing for them shows as a
    /// cut-out mid-swipe. A real cover (a full-screen app, a maximised window) pauses after it.
    static let coverGrace: TimeInterval = 1.5
    /// When each display's wallpaper window last went from visible to hidden.
    private var hiddenSince: [CGDirectDisplayID: Date] = [:]

    private func isVisible(_ h: WallpaperHost) -> Bool {
        if ignoreOcclusion || h.window.occlusionState.contains(.visible) { return true }
        guard let since = hiddenSince[h.displayID] else { return false }
        return Date().timeIntervalSince(since) < Self.coverGrace
    }

    /// Re-decide what runs, and hand the decision to the render thread as one snapshot.
    private func reevaluate(forceDraw: Bool = false) {
        guard settings.enabled, !hosts.isEmpty else { return }
        let hard = hardPauseReason
        let visible = Set(hosts.values.filter(isVisible).map(\.displayID))
        let still = stillReason
        let onBattery = power.state.onBattery

        var status: String?
        if let hard { status = hard }
        else if visible.isEmpty { status = "Paused — desktop covered" }
        else if let still { status = still }
        else { status = WallpaperBudget.batteryStatus(settings, onBattery: onBattery) }
        if status != statusText { statusText = status }

        // Efficient on battery draws fewer pixels: resize the drawables (the next frame — forced,
        // so a held frame redraws at the new size too — fills them).
        var force = forceDraw
        let scale = WallpaperBudget.renderScale(settings, onBattery: onBattery, profile: profile)
        if scale != renderScale {
            renderScale = scale
            hosts.values.forEach { configure($0) }
            force = true
        }

        let stateLine = "hard=\(hard ?? "-") visible=\(visible.count)/\(hosts.count) still=\(still ?? "-") fps=\(targetFPS) scale=\(renderScale)"
        if stateLine != lastLoggedState { lastLoggedState = stateLine; log("state \(stateLine)") }

        renderLoop?.update(WallpaperFrameState(canDraw: hard == nil, visible: visible, profile: profile,
                                               fps: targetFPS, still: still != nil,
                                               stepFPS: applied.flatMap { WallpaperPacing.steppedFPS($0.preset) }),
                           forceDraw: force)
        updateMusicSubscription()
    }

    // MARK: Lock screen picture

    /// "Use as lock & login screen picture": a still of the wallpaper as each screen's desktop
    /// picture (LockScreenPicture), refreshed when the Mac locks, when the style changes, on screen
    /// changes, and every 15 minutes for a style that follows the time of day. Never while the
    /// display sleeps; one render each time (≈ a few hundred ms of work, off the main thread).
    /// Turning it off, or stopping the wallpaper, puts the user's own pictures back.
    func setLockScreen(_ on: Bool) {
        update { $0.lockScreen = on }
    }

    private lazy var lockPicture = LockScreenPicture(
        dir: (model?.store.baseDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("lockscreen"),
        desktop: WorkspaceDesktopPictures())
    private let lockQueue = DispatchQueue(label: "DotStudio Lock Screen Picture", qos: .utility)
    private var lockWork: DispatchWorkItem?
    private var lockTimer: Timer?
    /// Bumped by every render and every restore: a render that finishes after either is dropped.
    private var lockGeneration = 0
    /// The power monitor's last lock state (a lock refreshes the picture once, as it starts).
    private var wasLocked = false
    /// Offscreen renders and demos never touch the real desktop picture.
    private static let lockPictureAllowed = !DemoHooks.isActive && !OffscreenCapture.isActive
        && ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] == nil

    /// Bring the lock-screen picture in line with the settings, now or after `delay` (coalescing
    /// bursts: a later call replaces a pending one).
    private func syncLockPicture(_ reason: String, after delay: TimeInterval = 0) {
        guard Self.lockPictureAllowed, model != nil else { return }
        lockWork?.cancel()
        lockWork = nil
        guard delay > 0 else { lockPictureNow(reason); return }
        let w = DispatchWorkItem { [weak self] in
            self?.lockWork = nil
            self?.lockPictureNow(reason)
        }
        lockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func lockPictureNow(_ reason: String) {
        guard let model else { return }
        let pic = lockPicture
        guard settings.lockScreen, settings.enabled, let preset = currentPreset else {
            lockTimer?.invalidate()
            lockTimer = nil
            lockGeneration += 1
            guard !settings.savedDesktopPictures.isEmpty else { return }
            var saved = settings.savedDesktopPictures
            pic.restore(&saved)
            log("lock picture: restored (\(reason))" + (saved.isEmpty ? "" : "; \(saved.count) screen(s) not connected, later"))
            update { $0.savedDesktopPictures = saved }
            return
        }
        scheduleLockTimer(preset)
        let s = power.state
        if running, s.displayAsleep || s.systemAsleep { log("lock picture: skipped (\(reason)) — display asleep"); return }
        // Low Power Mode: still one frame at each lock and change, but no clock-driven refreshes.
        if reason == "timer", s.lowPowerMode { return }
        var saved = settings.savedDesktopPictures
        if pic.saveOriginals(into: &saved) { update { $0.savedDesktopPictures = saved } }
        // Only screens whose own picture is on record: one that can't be put back is never replaced.
        let screens = pic.desktop.screens().filter { saved[$0.key] != nil }
        guard !screens.isEmpty else { log("lock picture: no screen with a picture on record"); return }
        lockGeneration += 1
        let gen = lockGeneration
        let library = model.library, store = model.store
        let time = Float(MetalRenderer.wallPhase(Date().timeIntervalSince1970))   // the shared wall-clock frame
        let t0 = CACurrentMediaTime()
        lockQueue.async { [weak self] in
            let prepared = autoreleasepool {
                pic.prepare(screens: screens) { w, h in
                    Exporter.renderImage(preset: preset, library: library, store: store, width: w, height: h, time: time)
                }
            }
            DispatchQueue.main.async {
                guard let self, gen == self.lockGeneration, self.settings.lockScreen, self.settings.enabled else { return }
                let done = pic.set(prepared)
                self.log(String(format: "lock picture: %@ — %@ on %d screen(s) in %.0f ms", reason, preset.name,
                                done.count, (CACurrentMediaTime() - t0) * 1000))
            }
        }
    }

    /// Every 15 minutes while the style follows the time of day (a clock, the live weather, the
    /// real sun); no timer otherwise.
    private func scheduleLockTimer(_ preset: Preset) {
        guard WallpaperPacing.changesWithTimeOfDay(preset) else {
            lockTimer?.invalidate()
            lockTimer = nil
            return
        }
        guard lockTimer == nil else { return }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self, !self.power.state.screenLocked else { return }   // the lock already drew it
            self.syncLockPicture("timer")
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        lockTimer = t
    }

    // MARK: Dev hooks + logging

    /// DOTSTUDIO_DEMO_WALLPAPER=<style name> turns the wallpaper on at launch;
    /// DOTSTUDIO_WALLPAPER_FPS=30|120 (120 = Smooth), DOTSTUDIO_WALLPAPER_QUALITY=efficient|balanced|full
    /// and DOTSTUDIO_WALLPAPER_ON_BATTERY=full|efficient|still override settings (persisted, so
    /// pair them with DOTSTUDIO_STORE_DIR); the old DOTSTUDIO_WALLPAPER_FREEZE_ON_BATTERY=1|0
    /// still works (Still / Efficient). Power itself: DOTSTUDIO_WALLPAPER_FORCE (WallpaperPowerMonitor).
    private func applyDevOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let name = env["DOTSTUDIO_DEMO_WALLPAPER"],
           let p = model?.library.presets.first(where: { $0.name == name }) {
            update { $0.enabled = true; $0.presetID = p.id }
        }
        if let f = env["DOTSTUDIO_WALLPAPER_FPS"].flatMap(Int.init) {
            update { $0.frameRate = f > 30 ? .smooth : .balanced }
        }
        if let q = env["DOTSTUDIO_WALLPAPER_QUALITY"].flatMap(WallpaperSettings.Quality.init) {
            update { $0.quality = q }
        }
        if let b = env["DOTSTUDIO_WALLPAPER_FREEZE_ON_BATTERY"] {
            update { $0.batteryMode = b == "1" ? .still : .efficient }
        }
        if let m = env["DOTSTUDIO_WALLPAPER_ON_BATTERY"].flatMap(WallpaperSettings.BatteryMode.init) {
            update { $0.batteryMode = m }
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        model?.store.debug("wallpaper", message())
    }
}

// MARK: - One display

/// Draws into its CAMetalLayer from the render thread; AppKit never asks it to draw.
final class WallpaperMetalView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { true }
}

/// The window and Metal layer for one display (main thread). The render thread owns
/// the drawing into `metalLayer`; this side only places the window and sizes things.
final class WallpaperHost {
    let displayID: CGDirectDisplayID
    let token: UInt64
    let device: MTLDevice
    let window: WallpaperWindow
    let view: WallpaperMetalView
    let metalLayer: CAMetalLayer
    /// The window's content: the Metal view, plus the music overlay above it while shown.
    private let container: NSView
    private var overlay: MusicOverlayView?
    private var overlayRemovalPending = false

    init(screen: NSScreen, displayID: CGDirectDisplayID, device: MTLDevice, token: UInt64) {
        self.displayID = displayID
        self.device = device
        self.token = token

        let v = WallpaperMetalView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.autoresizingMask = [.width, .height]
        let layer = v.metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)   // as MTKView tagged it
        layer.framebufferOnly = true              // never read back: the cheapest drawables
        layer.isOpaque = true
        layer.displaySyncEnabled = true           // present on vsync, no tearing
        layer.presentsWithTransaction = false     // present straight from the render thread
        // Leak-guard learned in the saver: cap the drawable pool (it otherwise grows).
        // 3 = one on screen + the renderer's two in flight.
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        view = v
        metalLayer = layer

        let w = WallpaperWindow(contentRect: screen.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.canHide = false                 // ⌘H hides DotStudio's windows, not the desktop
        w.hidesOnDeactivate = false
        w.isExcludedFromWindowsMenu = true
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.animationBehavior = .none
        w.tabbingMode = .disallowed
        w.title = "DotStudio Wallpaper"
        let c = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        c.wantsLayer = true
        c.autoresizingMask = [.width, .height]
        c.addSubview(v)
        container = c
        w.contentView = c
        w.setFrame(screen.frame, display: false)
        window = w

        // Ordered in transparent; the first frame fades it in over the system wallpaper,
        // so it never pops in or flashes black.
        w.alphaValue = 0
        w.orderFront(nil)
    }

    /// The display's refresh rate (120 on ProMotion, 60 on most externals).
    var refreshRate: Double {
        Double((window.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
    }

    func follow(_ screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        overlay?.overlay.safeInsets = Self.insets(screen)
    }

    /// Show what's playing above the Metal view (`.hidden` removes the overlay entirely).
    /// The wallpaper's overlay has no ambient motion: no equalizer bounce, no gliding bar,
    /// so WindowServer recomposites it once a second at most.
    func setMusic(mode: MusicOverlayLayer.Mode, music: MusicSnapshot, settings: MusicSpec, animated: Bool) {
        if mode == .hidden {
            guard let ov = overlay else { return }
            if animated, ov.overlay.isShowing {
                // Let it fade out (in step with the backdrop), then drop the view.
                ov.overlay.update(mode: .hidden, music: music, settings: settings, animated: true)
                overlayRemovalPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + MusicOverlayLayer.fullFadeSeconds + 0.2) { [weak self, weak ov] in
                    guard let self else { return }
                    self.overlayRemovalPending = false
                    guard let ov, self.overlay === ov, !ov.overlay.isShowing else { return }
                    ov.removeFromSuperview()
                    self.overlay = nil
                }
            } else if !overlayRemovalPending {
                ov.removeFromSuperview()
                overlay = nil
            }
            return
        }
        let existed = overlay != nil
        let ov: MusicOverlayView
        if let o = overlay {
            ov = o
        } else {
            ov = MusicOverlayView(frame: container.bounds)
            ov.overlay.ambientMotion = false
            if let screen = window.screen { ov.overlay.safeInsets = Self.insets(screen) }
            container.addSubview(ov, positioned: .above, relativeTo: view)
            overlay = ov
        }
        ov.overlay.update(mode: mode, music: music, settings: settings, animated: animated && existed)
    }

    /// The menu bar and Dock, as insets from the screen edges (points).
    private static func insets(_ screen: NSScreen) -> MusicOverlayLayer.Insets {
        let f = screen.frame, v = screen.visibleFrame
        return MusicOverlayLayer.Insets(top: max(f.maxY - v.maxY, 0), left: max(v.minX - f.minX, 0),
                                        bottom: max(v.minY - f.minY, 0), right: max(f.maxX - v.maxX, 0))
    }

    /// Drawable = display points × Quality's pixel density × `scale` (WallpaperBudget.renderScale:
    /// 0.6 for Efficient on battery); the compositor upscales it.
    /// Also sets the layer's upscale filter (a compositing property, owned here).
    func surfaceConfig(quality: WallpaperSettings.Quality, scale: CGFloat = 1) -> WallpaperSurfaceConfig {
        let backing = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let ppp = quality.pixelsPerPoint(backing: backing) * scale
        let size = window.frame.size
        let target = CGSize(width: max((size.width * ppp).rounded(), 1),
                            height: max((size.height * ppp).rounded(), 1))
        // Whole-number upscales stay crisp with nearest; fractional ones need linear.
        let factor = backing / ppp
        let filter: CALayerContentsFilter = abs(factor - factor.rounded()) < 0.01 ? .nearest : .linear
        if metalLayer.magnificationFilter != filter { metalLayer.magnificationFilter = filter }
        return WallpaperSurfaceConfig(drawableSize: target, refreshRate: refreshRate)
    }

    func fadeIn() {
        guard window.alphaValue < 1 else { return }
        let w = window
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            w.animator().alphaValue = 1
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
