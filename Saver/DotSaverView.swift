//  DotSaverView.swift — the universal screensaver. Renders whichever preset is
//  marked active in the shared library, and live-reloads when that changes.

import ScreenSaver
import MetalKit
import QuartzCore
import IOKit.ps

@objc(DotSaverView)
final class DotSaverView: ScreenSaverView {
    private let store = SharedStore(role: .saver)
    private var metalView: MTKView?
    private var renderer: MetalRenderer?
    private var activeID: UUID?
    private var lastModified: Date?
    private var frameTick = 0
    private var renderScale: CGFloat = 1   // Library.renderScale (1 = full Retina)
    private var presetFPS = 30             // active preset's fps, before power clamps
    private var lastFrameAt = CACurrentMediaTime()
    private var idleWatchdog: Timer?

    /// Every live instance in this host process. The host leaks instances (see
    /// teardownMetalStack), so each new activation sweeps the previous ones.
    private static var instances = NSHashTable<DotSaverView>.weakObjects()

    /// Short id for log attribution across leaked instances.
    private let logID = String(UUID().uuidString.prefix(4))

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // The System Settings thumbnail doesn't need full frame rate.
        animationTimeInterval = 1.0 / (isPreview ? 10.0 : 30.0)
        store.debug("=== [\(logID)] commonInit \(Date()) bounds=\(bounds) isPreview=\(isPreview) ===")

        // A new activation means every earlier instance is a dead husk the host
        // will never drive again (it neither stops nor releases them). Sweep their
        // GPU stacks now — this runs while the process is guaranteed awake, unlike
        // a timer, which App Nap suspends the moment the saver is dismissed.
        for old in DotSaverView.instances.allObjects where old !== self && old.isStale {
            store.debug("[\(logID)] sweeping stale instance [\(old.logID)]")
            old.teardownMetalStack()
        }
        DotSaverView.instances.add(self)

        buildMetalStack()
        // Last-resort cleanup for the final activation (no successor to sweep it).
        // App Nap may delay this timer, but it fires whenever the process next runs.
        idleWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.metalView != nil, self.isStale else { return }
            self.store.debug("[\(self.logID)] idle watchdog — no frames for 5s, tearing down")
            self.teardownMetalStack()
        }
    }

    /// True when the host has stopped driving this view. 2s ≈ two poll periods —
    /// a new activation always means the previous one stopped, so err eager.
    private var isStale: Bool { CACurrentMediaTime() - lastFrameAt > 2 }

    /// On dismissal the host detaches leaked views from their window (observed:
    /// teardown sees window=nil superview=nil) without ever calling stopAnimation.
    /// That detach is the reliable, immediate teardown signal — event-driven, so
    /// App Nap can't delay it the way it delays the watchdog timer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            store.debug("[\(logID)] detached from window — tearing down Metal stack")
            teardownMetalStack()
        }
    }

    /// Create the MTKView + renderer. Split out of commonInit because the whole
    /// stack is torn down in stopAnimation() and rebuilt in startAnimation() —
    /// see the host-leak note there.
    private func buildMetalStack() {
        guard metalView == nil else { return }
        let view = MTKView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = true
        // The screensaver host doesn't run MTKView's display link, so we drive
        // each frame manually from animateOneFrame().
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        // We size the drawable ourselves so Library.renderScale can trade
        // resolution for battery/VRAM (see syncDrawableSize()).
        view.autoResizeDrawable = false
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = true
        // Cap the CAMetalLayer drawable pool. Left uncapped it grew to ~13 in-flight
        // drawables (~33 MB each at 2× Retina ≈ 430 MB); the render loop only needs a
        // couple. 3 gives headroom for the frame WindowServer is compositing plus the
        // 2 we allow in flight (see MetalRenderer.inFlight), without over-allocating.
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 3
        }
        guard let r = MetalRenderer(pixelFormat: view.colorPixelFormat, store: store) else {
            store.debug("MetalRenderer init returned nil — black screen")
            return
        }
        view.device = r.device
        view.delegate = r
        renderer = r
        metalView = view
        addSubview(view)
        store.debug("renderer ready, store base=\(store.baseDir.path)")
        reload(force: true)
    }

    override func startAnimation() {
        super.startAnimation()
        buildMetalStack()   // rebuild after a stopAnimation() teardown
    }

    override func stopAnimation() {
        super.stopAnimation()
        // Belt-and-suspenders: observed macOS 15 never actually calls this on
        // dismissal (the idle watchdog is the reliable path), but if it ever does,
        // tear down immediately.
        store.debug("stopAnimation — tearing down Metal stack")
        teardownMetalStack()
    }

    /// Free everything GPU-sized. The legacyScreenSaver host on macOS 14+/15 leaks
    /// every DotSaverView it creates (one per display per activation) without
    /// stopping it — each pinned a CAMetalLayer drawable pool, two full-res
    /// ping-pong textures, and the planet textures (~200-560 MB per activation;
    /// observed 5 GB after two days). After teardown a leaked view is a hollow
    /// shell; buildMetalStack() restores everything in ~100 ms if we're revived.
    private func teardownMetalStack() {
        guard metalView != nil else { return }
        store.debug("[\(logID)] teardown: window=\(window == nil ? "nil" : "alive") superview=\(superview == nil ? "nil" : "alive")")
        metalView?.delegate = nil
        metalView?.releaseDrawables()      // force the CAMetalLayer pool free NOW
        metalView?.removeFromSuperview()
        metalView = nil
        renderer = nil
        activeID = nil
        lastModified = nil
        frameTick = 0
        // The leaked window is hidden, so nothing else commits our layer removal
        // to the render server — without a flush WindowServer keeps the drawable
        // IOSurfaces pinned in this process forever.
        CATransaction.flush()
    }

    private func reload(force: Bool) {
        let mod = store.libraryModified()
        let lib: Library
        switch store.loadLibrary() {
        case .loaded(let l) where !l.presets.isEmpty:
            lib = l
        case .corrupt:
            // A backup was made by loadLibrary(). Keep rendering the last-good
            // preset; only fall back to the gradient if nothing was ever applied.
            if activeID == nil {
                store.debug("reload: library CORRUPT with nothing applied — gradient fallback")
                renderer?.apply(Preset(name: "Default"), source: SourceSpec())
            }
            return
        default:   // .missing, or decoded but zero presets
            if force {
                store.debug("reload: library MISSING/empty at \(store.libraryURL.path) — gradient fallback")
                renderer?.apply(Preset(name: "Default"), source: SourceSpec())
            }
            return
        }
        renderScale = CGFloat(lib.renderScale ?? 1)   // picked up next frame by syncDrawableSize
        let target = DotSaverView.effectivePreset(in: lib, now: Date())
        let changed = force || target.id != activeID || mod != lastModified
        if force { store.debug("reload active=\(target.name) effects=\(target.effects.count) sourceKind=\(lib.source.kind.rawValue)") }
        if changed {
            // Crossfade on rotation/schedule-driven switches; hard cut on first load and edits.
            let automatic = (lib.rotation?.enabled ?? false) || (lib.schedule?.enabled ?? false)
            let fade = !force && target.id != activeID && automatic
            activeID = target.id
            lastModified = mod
            if let la = lib.locationLat, let lo = lib.locationLon {
                renderer?.location = (la, lo)
            }
            let fadeDuration = lib.rotation?.transitionSeconds ?? 1.5   // schedule-only flips get a default fade
            if fade, fadeDuration > 0 {
                renderer?.transition(to: target, source: lib.source, duration: fadeDuration)
            } else {
                renderer?.apply(target, source: lib.source)
            }
            presetFPS = target.fps
            animationTimeInterval = effectiveInterval()
        }
    }

    // MARK: Rotation

    /// Which preset belongs on screen right now. Precedence: day/night schedule >
    /// rotation slot > active preset. Pure function of (library, wall clock), so
    /// every display converges on the same answer with zero coordination.
    static func effectivePreset(in lib: Library, now: Date) -> Preset {
        let fallback = lib.presets.first { $0.id == lib.activeID } ?? lib.presets.first!
        if let sched = lib.schedule, sched.enabled {
            var loc: (lat: Double, lon: Double)?
            if let la = lib.locationLat, let lo = lib.locationLon { loc = (la, lo) }
            let night = MetalRenderer.solarElevation(location: loc) < (-0.833 * .pi / 180)
            if let id = night ? sched.nightPresetID : sched.dayPresetID,
               let preset = lib.presets.first(where: { $0.id == id }) {
                return preset
            }
        }
        guard let rot = lib.rotation, rot.enabled else { return fallback }
        var pool = lib.presets
        if let ids = rot.presetIDs, !ids.isEmpty {
            let allowed = Set(ids)
            let filtered = lib.presets.filter { allowed.contains($0.id) }
            if !filtered.isEmpty { pool = filtered }
        }
        guard pool.count > 1 else { return pool.first ?? fallback }
        let interval = max(rot.intervalMinutes, 0.25) * 60
        let slot = Int(now.timeIntervalSince1970 / interval)
        let idx = rot.shuffle ? shuffledIndex(slot: slot, count: pool.count) : slot % pool.count
        return pool[idx]
    }

    /// Deterministic shuffle: each round of `count` slots is a seeded Fisher–Yates
    /// permutation, so no preset repeats until all have shown — and displays agree.
    private static func shuffledIndex(slot: Int, count: Int) -> Int {
        let round = slot / count, pos = slot % count
        var order = Array(0..<count)
        var state = UInt64(bitPattern: Int64(round)) &* 2654435761 &+ 0x9E3779B97F4A7C15
        for i in stride(from: count - 1, to: 0, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            order.swapAt(i, Int(state % UInt64(i + 1)))
        }
        return order[pos]
    }

    // MARK: Frame pacing (preview + power aware)

    /// The preset's fps, clamped for the Settings thumbnail and for battery power.
    private func effectiveInterval() -> TimeInterval {
        var fps = max(presetFPS, 1)
        if isPreview {
            fps = min(fps, 10)                       // Settings thumbnail
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            fps = min(fps, 10)
        } else if DotSaverView.onBattery() {
            fps = min(fps, 15)
        }
        return 1.0 / Double(fps)
    }

    /// True when running on battery. Defensive: any failure reads as AC power.
    private static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    override func animateOneFrame() {
        // Pool the whole tick: the reload poll (file read + JSON decode) also
        // allocates autoreleased objects, and the host never drains for us.
        autoreleasepool {
            // The leaky host keeps driving detached views after dismissal. Never
            // render — and above all never REBUILD the Metal stack — without a
            // window, or every dismissed activation stays resident forever.
            guard window != nil else {
                teardownMetalStack()   // no-op if already down
                return
            }
            lastFrameAt = CACurrentMediaTime()
            if metalView == nil { buildMetalStack() }   // revive after a teardown
            guard let mv = metalView else { return }
            if mv.frame.size != bounds.size { mv.frame = bounds }   // catch up if we started 0×0
            syncDrawableSize()
            frameTick += 1
            if frameTick % 30 == 0 {
                reload(force: false)                                // poll for edits ~1×/sec
                animationTimeInterval = effectiveInterval()         // track battery/power changes
            }
            mv.draw()
        }
    }

    /// Manually size the drawable: native pixels × renderScale. With
    /// autoResizeDrawable off this is the single source of truth, and lets the
    /// Quality setting cut VRAM/bandwidth 4× at 0.5 on Retina displays.
    private func syncDrawableSize() {
        guard let mv = metalView, bounds.width > 0, bounds.height > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let target = CGSize(width: max((bounds.width * backing * renderScale).rounded(), 1),
                            height: max((bounds.height * backing * renderScale).rounded(), 1))
        if mv.drawableSize != target {
            mv.drawableSize = target
            if let layer = mv.layer as? CAMetalLayer {
                // Keep the dot aesthetic crisp when upscaling a reduced render.
                layer.magnificationFilter = renderScale < 1 ? .nearest : .linear
            }
        }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
