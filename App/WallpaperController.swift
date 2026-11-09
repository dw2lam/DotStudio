//  WallpaperController.swift — "Use as Wallpaper": a live, animated desktop wallpaper.
//
//  One borderless window per display at the desktop window level — above the system
//  wallpaper, below Finder's desktop icons — on every Space, invisible to clicks,
//  Mission Control and the window cycle. Each hosts an MTKView driven by the shared
//  MetalRenderer, rendering the chosen style at reduced resolution.
//
//  Frames are paced by each display's own display link (macOS 14 NSView.displayLink)
//  at an exact divisor of that display's refresh rate, so every frame is held for the
//  same number of refreshes — smooth at 30. MTKView's internal loop stays paused.
//  Clocks idle on a one-shot timer aligned to the second and only switch the display
//  link on while a figure is changing. When no display can show a frame (covered,
//  locked, asleep, screensaver, Low Power, user pause) every link and timer is parked
//  and the process does no work at all; the last frame stays on screen, so resuming
//  never flashes or rebuilds anything.
//
//  Main thread only.

import AppKit
import Combine
import MetalKit
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
    var currentPreset: Preset? {
        guard let id = settings.presetID else { return nil }
        return model?.library.presets.first { $0.id == id }
    }

    private weak var model: AppModel?
    private var settingsURL: URL?
    private var hosts: [CGDirectDisplayID: WallpaperHost] = [:]
    private let power = WallpaperPowerMonitor()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var librarySub: AnyCancellable?
    private var applied: (preset: Preset, source: SourceSpec)?
    private var profile: WallpaperPacing.Profile = .still
    private var plan: WallpaperPacing.Plan = .none
    private var openMainWindowAction: (() -> Void)?

    // Debug counters (only reported when the store's debug log is enabled).
    private var framesDrawn = 0
    private var statsSince = CACurrentMediaTime()
    private var lastLoggedState = ""

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
    }

    /// Bring back the wallpaper the user left on (applicationDidFinishLaunching).
    func restore() {
        applyDevOverrides()
        if settings.enabled { start() }
    }

    /// The SwiftUI hook that opens the main window (captured from a view's environment).
    func registerOpenMainWindow(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    // MARK: Public actions

    func use(_ presetID: UUID) {
        update { $0.enabled = true; $0.presetID = presetID }
        userPaused = false
        start()
    }

    func stop() {
        update { $0.enabled = false }
        userPaused = false
        tearDown()
    }

    func setEnabled(_ on: Bool) {
        if on {
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
        guard s.enabled, !hosts.isEmpty else { return }
        if s.presetID != old.presetID { applyStyle() }
        if s.quality != old.quality {
            hosts.values.forEach { $0.syncDrawableSize(quality: s.quality) }
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

    var hasVisibleMainWindow: Bool { mainWindows.contains { $0.isVisible } }

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
        if hosts.isEmpty {
            power.onChange = { [weak self] state in
                self?.log("power \(state)")
                self?.reevaluate()
            }
            power.start()
            observe()
            log("start style=\(currentPreset?.name ?? "?") fps=\(settings.frameRate.rawValue) quality=\(settings.quality.rawValue)")
        }
        rebuildHosts(store: model.store)
        applyStyle()
        reevaluate(forceDraw: true)
    }

    private func tearDown() {
        guard !hosts.isEmpty || timer != nil else { return }
        log("stop")
        timer?.cancel(); timer = nil
        for h in hosts.values { h.close() }
        hosts.removeAll()
        applied = nil
        plan = .none
        mediaPaused = false
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
            guard let self, let model = self.model else { return }
            self.log("screens changed (\(NSScreen.screens.count))")
            self.rebuildHosts(store: model.store)
            self.applyStyle()
            self.reevaluate(forceDraw: true)
        })
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self, let win = note.object as? WallpaperWindow else { return }
            if let h = self.hosts.values.first(where: { $0.window === win }) {
                self.log("display \(h.displayID) occlusion visible=\(win.occlusionState.contains(.visible))")
            }
            self.reevaluate()
        })
    }

    /// One host per connected display; existing ones follow moves and resolution changes.
    private func rebuildHosts(store: SharedStore) {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let h = hosts[id] {
                h.follow(screen, quality: settings.quality)
            } else if let h = WallpaperHost(screen: screen, displayID: id, store: store, quality: settings.quality) {
                hosts[id] = h
                h.onFrame = { [weak self, weak h] in
                    guard let self, let h else { return }
                    self.linkFired(h)
                }
                if let model {
                    h.renderer.location = model.locationTuple
                    h.renderer.measuresGPUTime = model.store.debugEnabled
                }
            }
        }
        for (id, h) in hosts where !seen.contains(id) {
            h.close()
            hosts.removeValue(forKey: id)
        }
        applied = nil   // new hosts need the style
    }

    // MARK: Style

    private func libraryChanged() {
        guard settings.enabled, !hosts.isEmpty else { return }
        guard currentPreset != nil else {
            log("style deleted — stopping")
            stop()
            return
        }
        applyStyle()
    }

    /// Push the current style + shared source to every display (only when it changed).
    private func applyStyle() {
        guard let model, let preset = currentPreset else { return }
        let source = model.library.source
        if let a = applied, a.preset == preset, a.source == source { return }
        let styleChanged = applied?.preset.id != preset.id
        for h in hosts.values {
            h.renderer.location = model.locationTuple
            h.renderer.apply(preset, source: source)
        }
        applied = (preset, source)
        profile = WallpaperPacing.profile(for: preset, source: source)
        if styleChanged { log("style \(preset.name) profile=\(profile)") }
        reevaluate(forceDraw: true)   // an edit shows even when holding a still
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

    /// Holds: keep the last frame (a clock still turns over once a minute).
    private var stillReason: String? {
        let s = power.state
        if s.thermalHot { return "Still — Mac is running hot" }
        if s.onBattery && settings.freezeOnBattery { return "Still — on battery" }
        return nil
    }

    /// Frames per second asked of the display links: 30 (Balanced, or anything on
    /// battery; less only if the style itself asks for fewer) or each display's own
    /// refresh (Smooth: 120 on ProMotion, 60 on most externals — divisorRate clamps it).
    private var targetFPS: Double {
        if settings.frameRate == .smooth && !power.state.onBattery { return 120 }
        var fps = 30.0
        if let p = currentPreset, p.fps > 0, p.fps < 30 { fps = Double(p.fps) }
        return fps
    }

    private func isVisible(_ h: WallpaperHost) -> Bool {
        ignoreOcclusion || h.window.occlusionState.contains(.visible)
    }

    /// Re-decide what runs: which displays draw, and how the next frames are paced.
    private func reevaluate(forceDraw: Bool = false) {
        guard settings.enabled, !hosts.isEmpty else { return }
        let hard = hardPauseReason
        let anyVisible = hosts.values.contains(where: isVisible)
        let still = stillReason

        var status: String?
        if let hard { status = hard }
        else if !anyVisible { status = "Paused — desktop covered" }
        else if let still { status = still }
        else if power.state.onBattery && settings.frameRate == .smooth { status = "30 fps — on battery" }
        if status != statusText { statusText = status }

        let visibleCount = hosts.values.filter(isVisible).count
        let stateLine = "hard=\(hard ?? "-") visible=\(visibleCount)/\(hosts.count) still=\(still ?? "-") fps=\(targetFPS)"
        if stateLine != lastLoggedState { lastLoggedState = stateLine; log("state \(stateLine)") }

        guard hard == nil, anyVisible else {
            apply(.none)
            return
        }
        // A fresh frame now when something changed or we're resuming from a hold;
        // a running display link just keeps going.
        let running: Bool
        switch plan { case .continuous, .after: running = true; case .none: running = false }
        if forceDraw || !running { drawVisible() }
        apply(currentPlan())
    }

    private func currentPlan() -> WallpaperPacing.Plan {
        WallpaperPacing.plan(profile, fps: targetFPS, still: stillReason != nil)
    }

    /// Start/stop the display links and the clock timer to match `p`.
    private func apply(_ p: WallpaperPacing.Plan) {
        plan = p
        let canDraw = hardPauseReason == nil
        for h in hosts.values {
            if case .continuous(let fps) = p, canDraw, isVisible(h) {
                h.runLink(at: WallpaperPacing.divisorRate(target: fps, refresh: h.refreshRate))
            } else {
                h.pauseLink()
            }
        }
        if case .after(let delay) = p, canDraw {
            arm(after: delay)
        } else {
            timer?.schedule(deadline: .distantFuture, repeating: .never)
        }
        switch p {
        case .continuous: setMediaPaused(!canDraw)
        default: setMediaPaused(true)
        }
    }

    // MARK: Frames

    /// One display link frame.
    private func linkFired(_ h: WallpaperHost) {
        guard isVisible(h), hardPauseReason == nil else { h.pauseLink(); return }
        h.draw()
        noteFrames(1)
        // A clock only animates around a change; hand back to the 1 Hz timer after.
        if case .clock = profile {
            let next = currentPlan()
            if next != plan { apply(next) }
        }
    }

    private func drawVisible() {
        var n = 0
        // A new display draws its first frame even before its occlusion state settles,
        // so it can fade in over the system wallpaper with real content.
        for h in hosts.values where isVisible(h) || !h.hasDrawn {
            h.draw()
            n += 1
        }
        noteFrames(n)
    }

    /// Clock tick from the timer.
    private func timerFired() {
        guard hardPauseReason == nil else { apply(.none); return }
        drawVisible()
        apply(currentPlan())
    }

    private func arm(after delay: TimeInterval) {
        let t = timer ?? makeTimer()
        // Clocks keep the leeway tight so the second turns over on time.
        t.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(5))
    }

    private func makeTimer() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in autoreleasepool { self?.timerFired() } }
        t.resume()
        timer = t
        return t
    }

    /// A video source keeps decoding on its own clock; stop it with the frame loop.
    private var mediaPaused = false
    private func setMediaPaused(_ paused: Bool) {
        guard paused != mediaPaused else { return }
        mediaPaused = paused
        for h in hosts.values { h.renderer.setMediaPaused(paused) }
    }

    private func noteFrames(_ n: Int) {
        framesDrawn += n
        let now = CACurrentMediaTime()
        guard now - statsSince >= 10, model?.store.debugEnabled == true else { return }
        let gpu = hosts.values.reduce(0) { $0 + $1.renderer.gpuSeconds }
        hosts.values.forEach { $0.renderer.gpuSeconds = 0 }
        let pacing = hosts.values.map { $0.takeIntervalStats() }.joined(separator: " ")
        let span = now - statsSince
        log(String(format: "stats %.1f fps, GPU busy %.2f%% (%.2f ms/frame) over %.0fs, intervals %@ (profile=%@)",
                   Double(framesDrawn) / span, gpu / span * 100,
                   framesDrawn > 0 ? gpu / Double(framesDrawn) * 1000 : 0, span, pacing, "\(profile)"))
        framesDrawn = 0
        statsSince = now
    }

    // MARK: Dev hooks + logging

    /// DOTSTUDIO_DEMO_WALLPAPER=<style name> turns the wallpaper on at launch;
    /// DOTSTUDIO_WALLPAPER_FPS=30|120 (120 = Smooth), DOTSTUDIO_WALLPAPER_QUALITY=efficient|balanced|full
    /// and DOTSTUDIO_WALLPAPER_FREEZE_ON_BATTERY=0|1 override settings (persisted, so
    /// pair them with DOTSTUDIO_STORE_DIR).
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
            update { $0.freezeOnBattery = (b == "1") }
        }
    }

    private func log(_ message: String) {
        model?.store.debug("[wallpaper \(String(format: "%.3f", CACurrentMediaTime()))] \(message)")
    }
}

// MARK: - One display

/// The window, view, renderer and display link for one display.
final class WallpaperHost {
    let displayID: CGDirectDisplayID
    let window: WallpaperWindow
    let view: MTKView
    let renderer: MetalRenderer
    var onFrame: (() -> Void)?
    private(set) var hasDrawn = false

    private var link: CADisplayLink?
    private var linkRate: Double = 0
    private var lastFrameAt: CFTimeInterval = 0
    private var intervals: [Double] = []

    init?(screen: NSScreen, displayID: CGDirectDisplayID, store: SharedStore, quality: WallpaperSettings.Quality) {
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { return nil }
        self.displayID = displayID
        renderer = r

        let v = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: r.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.isPaused = true                 // MTKView's own loop off — our display link drives draw()
        v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = false      // we size the drawable for the Quality setting
        v.autoresizingMask = [.width, .height]
        v.delegate = r
        if let layer = v.layer as? CAMetalLayer {
            layer.isOpaque = true
            // Leak-guard learned in the saver: cap the drawable pool (it otherwise grows).
            layer.maximumDrawableCount = 3
        }
        view = v

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
        w.contentView = v
        w.setFrame(screen.frame, display: false)
        window = w

        syncDrawableSize(quality: quality)
        // Ordered in transparent; the first draw fades it in over the system wallpaper,
        // so it never pops in or flashes black.
        w.alphaValue = 0
        w.orderFront(nil)
    }

    /// The display's refresh rate (120 on ProMotion, 60 on most externals).
    var refreshRate: Double {
        Double((window.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
    }

    func follow(_ screen: NSScreen, quality: WallpaperSettings.Quality) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        syncDrawableSize(quality: quality)
    }

    /// Drawable = display points × Quality's pixel density; the compositor upscales it.
    func syncDrawableSize(quality: WallpaperSettings.Quality) {
        let backing = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let ppp = quality.pixelsPerPoint(backing: backing)
        let size = window.frame.size
        let target = CGSize(width: max((size.width * ppp).rounded(), 1),
                            height: max((size.height * ppp).rounded(), 1))
        if view.drawableSize != target { view.drawableSize = target }
        if let layer = view.layer as? CAMetalLayer {
            // Whole-number upscales stay crisp with nearest; fractional ones need linear.
            let factor = backing / ppp
            layer.magnificationFilter = abs(factor - factor.rounded()) < 0.01 ? .nearest : .linear
        }
    }

    // MARK: Display link

    func runLink(at fps: Double) {
        if link == nil {
            // NSView.displayLink (macOS 14) follows the window's display and its refresh.
            let l = view.displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.fire(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        if fps != linkRate, let link {
            let r = Float(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: r, maximum: r, preferred: r)
            linkRate = fps
        }
        if link?.isPaused == true { lastFrameAt = 0 }
        link?.isPaused = false
    }

    func pauseLink() {
        guard let link, !link.isPaused else { return }
        link.isPaused = true
        lastFrameAt = 0
    }

    fileprivate func linkFired() {
        let now = CACurrentMediaTime()
        if lastFrameAt > 0, intervals.count < 4000 { intervals.append(now - lastFrameAt) }
        lastFrameAt = now
        onFrame?()
    }

    /// "mean/max ms" of display-link frame intervals since the last call (debug stats).
    func takeIntervalStats() -> String {
        defer { intervals.removeAll(keepingCapacity: true) }
        guard !intervals.isEmpty else { return "-" }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        // "late" = frames held for longer than one frame slot (a visible stutter).
        let slot = linkRate > 0 ? 1 / linkRate : mean
        let late = intervals.filter { $0 > slot * 1.5 }.count
        return String(format: "mean %.1fms max %.1fms late %d/%d @%.0fHz", mean * 1000,
                      (intervals.max() ?? 0) * 1000, late, intervals.count, refreshRate)
    }

    func draw() {
        view.draw()
        guard !hasDrawn else { return }
        hasDrawn = true
        let w = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {   // let the GPU land the frame
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.6
                w.animator().alphaValue = 1
            }
        }
    }

    func close() {
        link?.invalidate()
        link = nil
        view.delegate = nil
        view.releaseDrawables()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// CADisplayLink retains its target; this weak trampoline keeps the host free to go.
private final class LinkTarget: NSObject {
    weak var host: WallpaperHost?
    init(_ host: WallpaperHost) { self.host = host }
    @objc func fire(_ link: CADisplayLink) {
        autoreleasepool { host?.linkFired() }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
