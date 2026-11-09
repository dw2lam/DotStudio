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
//  upload — runs on WallpaperRenderLoop's own utility-QoS thread (efficiency cores on
//  Apple Silicon). The main thread hands it immutable snapshots and never waits on it.

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
    var currentPreset: Preset? {
        guard let id = settings.presetID else { return nil }
        return model?.library.presets.first { $0.id == id }
    }

    private weak var model: AppModel?
    private var settingsURL: URL?
    private var hosts: [CGDirectDisplayID: WallpaperHost] = [:]
    private let power = WallpaperPowerMonitor()
    private var observers: [NSObjectProtocol] = []
    private var librarySub: AnyCancellable?
    private var applied: (preset: Preset, source: SourceSpec)?
    private var profile: WallpaperPacing.Profile = .still
    private var openMainWindowAction: (() -> Void)?
    private var nextToken: UInt64 = 0
    private var lastLoggedState = ""

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
                styleID: { [weak self] in self?.isActive == true ? self?.settings.presetID : nil },
                set: { [weak self] in self?.use($0) },
                stop: { [weak self] in self?.stop() },
                changes: objectWillChange.map { _ in }.eraseToAnyPublisher()))
        }
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
        guard !hosts.isEmpty else { return }
        log("stop")
        renderLoop?.removeAll()
        for h in hosts.values { h.close() }
        hosts.removeAll()
        applied = nil
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
        var device: MTLDevice?
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let h = hosts[id] {
                h.follow(screen)
                configure(h)
                continue
            }
            if device == nil { device = hosts.values.first?.device ?? WallpaperGPU.preferred() }
            guard let device else { continue }
            nextToken += 1
            let h = WallpaperHost(screen: screen, displayID: id, device: device, token: nextToken)
            hosts[id] = h
            let link = h.view.displayLink(target: WallpaperRenderLoop.linkTarget(loop, display: id),
                                          selector: WallpaperRenderLoop.linkSelector)
            loop.addDisplay(id, token: h.token, layer: h.metalLayer, link: link, device: device,
                            config: h.surfaceConfig(quality: settings.quality))
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
        renderLoop?.configure(h.displayID, h.surfaceConfig(quality: settings.quality))
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
        renderLoop?.setStyle(preset, source: source, location: model.locationTuple)
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

    /// Re-decide what runs, and hand the decision to the render thread as one snapshot.
    private func reevaluate(forceDraw: Bool = false) {
        guard settings.enabled, !hosts.isEmpty else { return }
        let hard = hardPauseReason
        let visible = Set(hosts.values.filter(isVisible).map(\.displayID))
        let still = stillReason

        var status: String?
        if let hard { status = hard }
        else if visible.isEmpty { status = "Paused — desktop covered" }
        else if let still { status = still }
        else if power.state.onBattery && settings.frameRate == .smooth { status = "30 fps — on battery" }
        if status != statusText { statusText = status }

        let stateLine = "hard=\(hard ?? "-") visible=\(visible.count)/\(hosts.count) still=\(still ?? "-") fps=\(targetFPS)"
        if stateLine != lastLoggedState { lastLoggedState = stateLine; log("state \(stateLine)") }

        renderLoop?.update(WallpaperFrameState(canDraw: hard == nil, visible: visible, profile: profile,
                                               fps: targetFPS, still: still != nil),
                           forceDraw: forceDraw)
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
        w.contentView = v
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
    }

    /// Drawable = display points × Quality's pixel density; the compositor upscales it.
    /// Also sets the layer's upscale filter (a compositing property, owned here).
    func surfaceConfig(quality: WallpaperSettings.Quality) -> WallpaperSurfaceConfig {
        let backing = window.screen?.backingScaleFactor ?? window.backingScaleFactor
        let ppp = quality.pixelsPerPoint(backing: backing)
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
