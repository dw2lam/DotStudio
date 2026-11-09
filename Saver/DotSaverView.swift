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

    // Music: what's playing (music.json, written by the app), drawn by MusicOverlayView at
    // native resolution above the Metal view — the Now Playing scene's foreground, or the
    // corner card over any style. Built and torn down with the Metal stack.
    private var musicFeed: MusicFeed?
    private var musicOverlay: MusicOverlayView?
    private var musicSettings = MusicSpec()
    private var musicActive = false            // visible (playing / paused within the linger)
    private var lastMusicTick: CFTimeInterval = 0
    private var shownPreset: Preset?           // what reload() last applied (overlay mode)

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
        idleWatchdog?.tolerance = 1   // a housekeeping check: let macOS coalesce its wake-ups
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
        // The music foreground sits above the (often reduced-resolution) Metal view so its
        // type stays crisp. The feed is polled ~1 Hz from animateOneFrame (a stat, plus a
        // decode only when music.json changes).
        let feed = MusicFeed(baseDir: store.baseDir)
        feed.poll()
        musicFeed = feed
        musicActive = false
        r.reduceMotion = MusicOverlayLayer.systemReduceMotion
        r.setMusic(feed.snapshot)
        let ov = MusicOverlayView(frame: bounds)
        addSubview(ov, positioned: .above, relativeTo: view)
        musicOverlay = ov
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
        // The overlay holds artwork bitmaps and the feed a decoded cover: a leaked husk keeps neither.
        musicOverlay?.removeFromSuperview()
        musicOverlay = nil
        musicFeed = nil
        MusicArtwork.purge()           // process-wide scaled-cover cache (the host outlives us)
        musicActive = false
        shownPreset = nil
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
        musicSettings = lib.musicSettings
        renderer?.musicLingerMinutes = musicSettings.linger
        if let feed = musicFeed { musicActive = feed.isVisible(settings: musicSettings) }
        // Match Screensaver: the same wall-clock time base as a wallpaper that follows us.
        renderer?.timeBase = lib.rendererTimeBase
        let target = DotSaverView.effectivePreset(in: lib, now: Date(), musicActive: musicActive)
        let changed = force || target.id != activeID || mod != lastModified
        if force { store.debug("reload active=\(target.name) effects=\(target.effects.count) sourceKind=\(lib.source.kind.rawValue)") }
        if changed {
            // Crossfade on rotation/schedule/music-driven switches; hard cut on first load and edits.
            let automatic = (lib.rotation?.enabled ?? false) || (lib.schedule?.enabled ?? false)
                || musicSettings.takesOver
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
            shownPreset = target
            updateMusicOverlay(animated: !force)
        }
    }

    // MARK: Rotation

    /// Which preset belongs on screen right now (see Shared/Playback.swift, which the
    /// app also uses so the gallery always shows what the saver will play).
    static func effectivePreset(in lib: Library, now: Date, musicActive: Bool = false) -> Preset {
        Playback.effectivePreset(in: lib, now: now, musicActive: musicActive)
    }

    // MARK: Music

    /// ~1 Hz: re-read music.json if it changed, hand new artwork to the renderer, follow
    /// take-over, and tick the overlay (progress, times, linger expiry).
    private func musicTick() {
        guard let feed = musicFeed else { return }
        if feed.poll() { renderer?.setMusic(feed.snapshot) }
        let active = feed.isVisible(settings: musicSettings)
        if active != musicActive {
            musicActive = active
            if musicSettings.takesOver { reload(force: false) }   // the lineup changes with it
        }
        updateMusicOverlay(animated: true)
    }

    /// The Now Playing scene's foreground when that's the style on screen; otherwise the
    /// corner card (when enabled — it shows only while music is visible).
    private func updateMusicOverlay(animated: Bool) {
        guard let ov = musicOverlay?.overlay, let feed = musicFeed else { return }
        let mode: MusicOverlayLayer.Mode
        if let inst = shownPreset?.musicScene {
            mode = .full(MusicSceneOptions(inst))
        } else if musicSettings.isCardEnabled {
            mode = .card(musicSettings.corner)
        } else {
            mode = .hidden
        }
        ov.update(mode: mode, music: feed.snapshot, settings: musicSettings, animated: animated)
    }

    // MARK: Frame pacing (preview + power aware)

    /// The preset's fps, clamped for the Settings thumbnail and for battery power.
    private func effectiveInterval() -> TimeInterval {
        var fps = max(presetFPS, 1)
        if isPreview {
            fps = min(fps, 10)                       // Settings thumbnail
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            fps = min(fps, 15)
        } else if DotSaverView.onBattery() {
            fps = min(fps, 30)                       // 15 read as laggy; 30 stays smooth
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
            if let ov = musicOverlay, ov.frame.size != bounds.size { ov.frame = bounds }
            syncDrawableSize()
            frameTick += 1
            if lastFrameAt - lastMusicTick >= 1 {
                lastMusicTick = lastFrameAt
                musicTick()                                         // music.json ~1×/sec (a stat)
            }
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
