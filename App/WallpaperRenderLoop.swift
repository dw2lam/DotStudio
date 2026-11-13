//  WallpaperRenderLoop.swift — the live wallpaper's frame work, off the main thread.
//
//  One dedicated thread owns everything a frame touches: each display's MetalRenderer,
//  its CAMetalLayer's drawables, the display links (attached to this thread's run
//  loop), the clock timer, the pacing plan and the media decoders. While any display is
//  animating it runs at .userInitiated; for the 1 Hz clock ticks and idle it drops to
//  .utility. (Measured 2026-11-09 on an M5 Pro — no efficiency cores — under load:
//  utility let frames slip even at 30 fps, up to ~9% late with 292 ms gaps, and the
//  owner had already flagged lag; user-initiated matched the old main-thread loop. The
//  wins that remain: the main thread is idle during playback, ~10–14% less CPU per
//  frame, the right GPU per display, and zero work while paused.)
//
//  The main thread keeps the windows and the policy. It decides *what* may run (hard
//  pauses, which displays are visible, fps, still, style) and posts immutable snapshots
//  here with `async`; it never reads render state back and never waits on this thread.
//  The only traffic the other way is a first-frame note (fade the window in) and a
//  failed-surface note, both dispatched to the main queue.
//
//  Threading contract: every member below `// MARK: Render thread only` is touched from
//  the render thread alone; the public methods are the main thread's only way in.

import AppKit
import Metal
import QuartzCore

/// What the main thread's policy allows right now: an immutable snapshot.
struct WallpaperFrameState: Equatable {
    /// How one display's style wants its frames (each display can play its own style).
    struct Pacing: Equatable {
        var profile: WallpaperPacing.Profile = .still
        /// Target frames per second (settings, preset cap and battery already applied).
        var fps: Double = 30
        /// The rate the style steps its own time at (WallpaperPacing.steppedFPS), if it does.
        var stepFPS: Double? = nil
    }

    /// No hard pause (user pause, lock, sleep, screensaver).
    var canDraw = false
    /// Displays whose wallpaper someone can see.
    var visible: Set<CGDirectDisplayID> = []
    /// Hot Mac / battery freeze: motion holds; a clock turns over once a minute.
    var still = false
    /// Each display's pacing; a display not listed uses `fallback`.
    var displays: [CGDirectDisplayID: Pacing] = [:]
    var fallback = Pacing()

    func pacing(_ id: CGDirectDisplayID) -> Pacing { displays[id] ?? fallback }
}

extension WallpaperFrameState {
    /// Every display paced alike (one style everywhere: tools/perf).
    init(canDraw: Bool, visible: Set<CGDirectDisplayID>, profile: WallpaperPacing.Profile, fps: Double,
         still: Bool, stepFPS: Double? = nil) {
        self.init(canDraw: canDraw, visible: visible, still: still,
                  fallback: Pacing(profile: profile, fps: fps, stepFPS: stepFPS))
    }
}

/// Per-display geometry, measured on the main thread.
struct WallpaperSurfaceConfig: Equatable {
    var drawableSize: CGSize
    var refreshRate: Double
}

/// The GPU a display's wallpaper draws on.
enum WallpaperGPU {
    /// The GPU currently driving `display`, so a finished frame never has to be copied
    /// across GPUs to reach the screen (Mac Pro / eGPU setups, external displays wired
    /// to the discrete GPU). On Apple Silicon that is the one GPU. Not a power choice: on
    /// a dual-GPU Intel Mac the app's previews already hold the system default (discrete)
    /// device, and that GPU then drives the built-in display too.
    static func device(for display: CGDirectDisplayID) -> MTLDevice? {
        CGDirectDisplayCopyCurrentMetalDevice(display) ?? MTLCreateSystemDefaultDevice()
    }
}

final class WallpaperRenderLoop {
    /// Main queue: a display drew its first frame (fade its window in). Carries the
    /// surface token handed to `addDisplay`, so a replaced host isn't faded early.
    var onFirstFrame: ((CGDirectDisplayID, UInt64) -> Void)?
    /// Main queue: a display's renderer couldn't be created.
    var onSurfaceFailed: ((CGDirectDisplayID, UInt64) -> Void)?

    private let thread = RenderThread()
    private let store: SharedStore
    /// Accessibility Reduce Motion, read on the main thread at creation.
    private let reduceMotion: Bool

    init(store: SharedStore) {
        self.store = store
        reduceMotion = MusicOverlayLayer.systemReduceMotion
        thread.name = "DotStudio Wallpaper Render"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: Main thread → render thread (all asynchronous)

    /// A new display: its layer (configured, not yet drawn), the display link made from
    /// its view (not yet scheduled; this thread adopts it) and the GPU to draw on.
    func addDisplay(_ id: CGDirectDisplayID, token: UInt64, layer: CAMetalLayer, link: CADisplayLink,
                    device: MTLDevice, config: WallpaperSurfaceConfig) {
        surfaceIDs.insert(id)
        thread.async { [self] in
            addSurface(id, token: token, layer: layer, link: link, device: device, config: config)
        }
    }

    func configure(_ id: CGDirectDisplayID, _ config: WallpaperSurfaceConfig) {
        thread.async { [self] in configureSurface(id, config) }
    }

    func removeDisplay(_ id: CGDirectDisplayID) {
        surfaceIDs.remove(id)
        thread.async { [self] in removeSurface(id) }
    }

    func removeAll() {
        surfaceIDs.removeAll()
        thread.async { [self] in
            for id in Array(surfaces.keys) { removeSurface(id) }
            state = WallpaperFrameState()
            setPlans()
            style = nil
            styles = [:]
            music = nil            // drop the cover; the controller re-sends it on restart
            musicBackdrop = .none
            musicBackdrops = [:]
        }
    }

    /// What's playing, for a Now Playing style (an immutable snapshot polled on the main
    /// thread; the CGImage is shared read-only, each renderer uploads its own texture).
    func setMusic(_ snapshot: MusicSnapshot, lingerMinutes: Double) {
        thread.async { [self] in
            music = (snapshot, lingerMinutes)
            for s in surfaces.values {
                s.renderer.musicLingerMinutes = lingerMinutes
                s.renderer.setMusic(snapshot)
            }
        }
    }

    /// Full Screen music's backdrop (MusicPresentation, decided on the main thread) — per
    /// display, as a legacy Now Playing style on one display draws none. Each renderer eases it
    /// in or out over the frames it draws; a held frame shows the end state.
    func setMusicBackdrops(_ backdrops: [CGDirectDisplayID: MusicBackdrop], fallback: MusicBackdrop, animated: Bool) {
        thread.async { [self] in
            musicBackdrop = fallback
            musicBackdrops = backdrops
            for s in surfaces.values {
                let b = backdrops[s.id] ?? fallback
                guard b != s.backdrop else { continue }
                s.backdrop = b
                s.renderer.setMusicBackdrop(b, animated: animated)
            }
        }
    }

    /// One backdrop on every display.
    func setMusicBackdrop(_ backdrop: MusicBackdrop, animated: Bool) {
        setMusicBackdrops([:], fallback: backdrop, animated: animated)
    }

    /// The animation time base (wall clock while the wallpaper matches the screensaver).
    func setTimeBase(_ base: MetalRenderer.TimeBase) {
        thread.async { [self] in
            timeBase = base
            for s in surfaces.values { s.renderer.timeBase = base }
        }
    }

    /// The style each display draws (value types: copied across, nothing shared): `styles`
    /// for the displays listed, `fallback` for the rest (and for displays added later until
    /// the next call). Only displays whose style, source or location changed are touched.
    /// - fades: crossfade seconds per display (only meaningful while its frames run
    ///   continuously); missing or 0 = cut.
    func setStyles(_ styles: [CGDirectDisplayID: Preset], fallback: Preset, source: SourceSpec,
                   location: (lat: Double, lon: Double)?, fades: [CGDirectDisplayID: Double] = [:]) {
        thread.async { [self] in
            style = (fallback, source)
            self.styles = styles
            self.location = location
            boosted {
                for s in surfaces.values {
                    let preset = styles[s.id] ?? fallback
                    let moved = s.location?.lat != location?.lat || s.location?.lon != location?.lon
                    guard s.preset != preset || s.source != source || moved else { continue }
                    s.renderer.location = location
                    s.location = location
                    let fade = fades[s.id] ?? 0
                    if fade > 0.05, s.preset != nil {
                        s.renderer.transition(to: preset, source: source, duration: fade)
                    } else {
                        s.renderer.apply(preset, source: source)   // may load an image/video
                    }
                    s.preset = preset
                    s.source = source
                    // A freshly loaded video starts playing; hold it if frames are held.
                    s.renderer.setMediaPaused(s.mediaPaused)
                    s.warming = true
                }
            }
        }
    }

    /// One style on every display.
    func setStyle(_ preset: Preset, source: SourceSpec, location: (lat: Double, lon: Double)?,
                  fade: Double = 0) {
        setStyles([:], fallback: preset, source: source, location: location,
                  fades: fade > 0 ? Dictionary(uniqueKeysWithValues: surfaceIDs.map { ($0, fade) }) : [:])
    }

    /// The displays added (main thread only: setStyle's fades).
    private var surfaceIDs: Set<CGDirectDisplayID> = []

    /// Re-decide what runs. `forceDraw` draws a fresh frame now even if the plan is
    /// already running (an edit, a new drawable size).
    func update(_ state: WallpaperFrameState, forceDraw: Bool) {
        thread.async { [self] in apply(state, forceDraw: forceDraw) }
    }

    // MARK: Render thread only

    private final class Surface {
        let id: CGDirectDisplayID
        let token: UInt64
        let layer: CAMetalLayer
        let link: CADisplayLink
        let renderer: MetalRenderer
        var config: WallpaperSurfaceConfig
        var linkRate: Double = 0
        var hasDrawn = false
        /// The next frame is the first of a style: it may build lazy assets.
        var warming = true
        let pacing = WallpaperPacingStats()
        /// What this display was last handed (setStyles skips displays whose style didn't change).
        var preset: Preset?
        var source: SourceSpec?
        var location: (lat: Double, lon: Double)?
        var backdrop: MusicBackdrop = .none
        /// What its frames do now (setPlans), and when its next clock frame is due (`.after`).
        var plan: WallpaperPacing.Plan = .none
        var due: Date = .distantFuture
        /// Whether its media decoders are held (a video source keeps decoding on its own clock).
        var mediaPaused = false

        init(id: CGDirectDisplayID, token: UInt64, layer: CAMetalLayer, link: CADisplayLink,
             renderer: MetalRenderer, config: WallpaperSurfaceConfig) {
            self.id = id; self.token = token; self.layer = layer; self.link = link
            self.renderer = renderer; self.config = config
        }
    }

    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var state = WallpaperFrameState()
    /// The fallback style (displays without one of their own) and the per-display ones.
    private var style: (Preset, SourceSpec)?
    private var styles: [CGDirectDisplayID: Preset] = [:]
    private var location: (lat: Double, lon: Double)?
    private var music: (snapshot: MusicSnapshot, linger: Double)?
    private var musicBackdrop: MusicBackdrop = .none
    private var musicBackdrops: [CGDirectDisplayID: MusicBackdrop] = [:]
    private var timeBase: MetalRenderer.TimeBase = .instance
    private var clockTimer: Timer?
    private var activity: NSObjectProtocol?
    private var framesDrawn = 0
    /// Frames drawn since creation (tools/perf reads it; never reset).
    private(set) var framesDrawnTotal = 0
    /// …per display, only under tools/perf (its two-display check; written on the render thread,
    /// read after the loop has gone quiet).
    private(set) var framesDrawnPerDisplay: [CGDirectDisplayID: Int] = [:]
#if DOTSTUDIO_PERF
    private let debugCounts = true
#else
    private let debugCounts = false
#endif
    private var statsSince = CACurrentMediaTime()
    private var loggedThread = false
    private var clockTicks = 0
    private var clockTickLatest: Double = 0   // seconds past the second boundary, worst case
    private var debug: Bool { store.debugEnabled }
    /// DEV: DOTSTUDIO_WALLPAPER_NO_ACTIVITY=1 skips the App Nap activity, to measure
    /// whether the drawing window alone keeps frames and clock ticks on time.
    private static let noActivity = ProcessInfo.processInfo.environment["DOTSTUDIO_WALLPAPER_NO_ACTIVITY"] == "1"

    private func addSurface(_ id: CGDirectDisplayID, token: UInt64, layer: CAMetalLayer, link: CADisplayLink,
                            device: MTLDevice, config: WallpaperSurfaceConfig) {
        if surfaces[id] != nil { removeSurface(id) }
        let made: MetalRenderer? = boosted {   // shader pipeline, atlases, the style's media
            guard let r = MetalRenderer(pixelFormat: layer.pixelFormat, store: store, device: device) else { return nil }
            r.measuresGPUTime = debug
            r.location = location
            r.timeBase = timeBase
            r.reduceMotion = reduceMotion
            if let music {
                r.musicLingerMinutes = music.linger
                r.setMusic(music.snapshot)
            }
            r.setMusicBackdrop(musicBackdrops[id] ?? musicBackdrop, animated: false)   // a new display starts where the rest are
            if let (fallback, source) = style { r.apply(styles[id] ?? fallback, source: source) }
            return r
        }
        guard let r = made else {
            link.invalidate()
            DispatchQueue.main.async { [weak self] in self?.onSurfaceFailed?(id, token) }
            return
        }
        if !loggedThread {
            loggedThread = true
            log("render thread qos=\(qos_class_self().rawValue) (utility=\(QOS_CLASS_UTILITY.rawValue)) gpu=\(device.name)")
        }
        link.isPaused = true
        link.add(to: .current, forMode: .common)
        r.setMediaPaused(true)            // held until setPlans runs its frames
        let s = Surface(id: id, token: token, layer: layer, link: link, renderer: r, config: config)
        s.mediaPaused = true
        s.backdrop = musicBackdrops[id] ?? musicBackdrop
        if let (fallback, source) = style {
            s.preset = styles[id] ?? fallback
            s.source = source
            s.location = location
        }
        surfaces[id] = s
        setDrawableSize(s, config.drawableSize)
    }

    /// One-time setup — making a renderer, loading a style's media, and the first frame
    /// of a style, which builds lazy assets (the Clocks text atlas fans out over every
    /// core with concurrentPerform; Universe decodes its planet maps) — runs at
    /// user-initiated QoS: it is the direct result of the user picking a style, and at
    /// utility the atlas alone took ~16 s instead of ~5 s (Debug build). Steady-state
    /// frames go back to `frameQoS`.
    private func boosted<T>(_ work: () -> T) -> T {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        defer { pthread_set_qos_class_self_np(frameQoS, 0) }
        return work()
    }

    /// This thread's QoS between one-time setups: user-initiated while any display is
    /// animating, utility for clock ticks and idle (see the header).
    private var frameQoS = QOS_CLASS_UTILITY

    private func updateFrameQoS() {
        // Any continuously animating display runs user-initiated: under CPU load utility QoS
        // dropped frames even at 30 fps (up to ~9% late, 292 ms gaps — measured 2026-11-09 on
        // an M5 Pro, which has no efficiency cores), and the owner flagged lag. Utility stays
        // for the 1 Hz clock ticks and idle, where a late wake-up is invisible.
        let animating = surfaces.values.contains { !$0.link.isPaused }
        let q = animating ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY
        guard q.rawValue != frameQoS.rawValue else { return }
        frameQoS = q
        pthread_set_qos_class_self_np(q, 0)
        if debug { log("frame qos \(q.rawValue) (\(animating ? "animating" : "ticks/idle"))") }
    }

    private func configureSurface(_ id: CGDirectDisplayID, _ config: WallpaperSurfaceConfig) {
        guard let s = surfaces[id], s.config != config else { return }
        let rateChanged = s.config.refreshRate != config.refreshRate
        s.config = config
        setDrawableSize(s, config.drawableSize)
        if rateChanged, s.plan.isContinuous { setPlans() }   // re-derive the divisor
    }

    private func setDrawableSize(_ s: Surface, _ size: CGSize) {
        guard s.layer.drawableSize != size else { return }
        // This thread has no implicit Core Animation transaction flush of its own.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.drawableSize = size
        CATransaction.commit()
    }

    private func removeSurface(_ id: CGDirectDisplayID) {
        guard let s = surfaces.removeValue(forKey: id) else { return }
        s.link.invalidate()
        s.renderer.setMediaPaused(true)
        s.renderer.onPresented = nil
        // The layer belongs to a view; let its last reference go on the main thread.
        let layer = s.layer
        DispatchQueue.main.async { withExtendedLifetime(layer) {} }
        setPlans()
    }

    private func apply(_ st: WallpaperFrameState, forceDraw: Bool) {
        state = st
        // A fresh frame on each display that can show one when something changed or it's
        // resuming from a hold; a running display link just keeps going. A frame its next plan
        // will hold shows the end of any fade it would start (a track change, a time-base
        // switch). A new display draws its first frame even before its occlusion state
        // settles, so it can fade in over the system wallpaper with real content.
        if st.canDraw, !st.visible.isEmpty {
            for s in surfaces.values where st.visible.contains(s.id) || !s.hasDrawn {
                guard forceDraw || s.plan == .none else { continue }
                draw(s, fromLink: false, settled: !plan(for: s).isContinuous)
            }
            noteStats()
        }
        setPlans()
    }

    /// What one display's frames should do now.
    private func plan(for s: Surface) -> WallpaperPacing.Plan {
        guard state.canDraw, state.visible.contains(s.id) else { return .none }
        let p = state.pacing(s.id)
        return WallpaperPacing.plan(p.profile, fps: p.fps, still: state.still)
    }

    /// Start/stop each display's link and decoders, the shared clock timer (armed for the
    /// soonest clock frame due on any display) and the App Nap activity, to match each
    /// display's plan.
    private func setPlans() {
        let now = Date()
        var soonest: TimeInterval?
        for s in surfaces.values {
            let p = plan(for: s)
            s.plan = p
            switch p {
            case .continuous(let fps):
                let step = state.pacing(s.id).stepFPS
                runLink(s, at: WallpaperPacing.rate(target: fps, step: step, refresh: s.config.refreshRate))
                s.due = .distantFuture
            case .after(let delay):
                pauseLink(s)
                s.due = now.addingTimeInterval(delay)
                soonest = min(soonest ?? delay, delay)
            case .none:
                pauseLink(s)
                s.due = .distantFuture
            }
            setMediaPaused(s, !p.isContinuous)
        }
        updateFrameQoS()
        if let soonest {
            armClock(after: soonest)
        } else {
            clockTimer?.fireDate = .distantFuture
        }
        setActive(state.canDraw && surfaces.values.contains { $0.plan != .none })
    }

    private func runLink(_ s: Surface, at fps: Double) {
        if fps != s.linkRate {
            let r = Float(fps)
            s.link.preferredFrameRateRange = CAFrameRateRange(minimum: r, maximum: r, preferred: r)
            s.linkRate = fps
        }
        if s.link.isPaused {
            s.pacing.reset()
            s.link.isPaused = false
        }
    }

    private func pauseLink(_ s: Surface) {
        guard !s.link.isPaused else { return }
        s.link.isPaused = true
        s.pacing.reset()
    }

    /// One display-link frame; `presentAt` = the link's targetTimestamp (when it will be shown).
    fileprivate func linkFired(_ id: CGDirectDisplayID, presentAt: CFTimeInterval) {
        guard let s = surfaces[id] else { return }
        guard state.canDraw, state.visible.contains(id) else { pauseLink(s); return }
        if debug { s.pacing.tick() }
        draw(s, fromLink: true, presentAt: presentAt)
        noteStats()
        // A clock only animates around a change; hand back to the 1 Hz timer after.
        if case .clock = state.pacing(id).profile, plan(for: s) != s.plan { setPlans() }
    }

    /// - settled: the frame will be held (no display link runs after it), so it must show
    ///   the end state of any crossfade rather than its first frame.
    /// - presentAt: the display link's targetTimestamp: a stepped style (Bloom) times its steps
    ///   by when the frame is shown rather than when it is encoded (MetalRenderer's StepClock).
    private func draw(_ s: Surface, fromLink: Bool, settled: Bool = false, presentAt: CFTimeInterval? = nil) {
        let pacing = s.pacing
        s.renderer.onPresented = (debug && fromLink) ? { pacing.presented($0) } : nil
        // Held once a minute (Still / Low Power / hot): a clock shows the new minute settled.
        s.renderer.settlesClocks = state.still
        let drawn = s.warming ? boosted { s.renderer.draw(to: s.layer, settled: settled, presentAt: presentAt) }
                              : s.renderer.draw(to: s.layer, settled: settled, presentAt: presentAt)
        guard drawn else { return }
        s.warming = false
        framesDrawn += 1
        framesDrawnTotal += 1
        if debugCounts { framesDrawnPerDisplay[s.id, default: 0] += 1 }
        guard !s.hasDrawn else { return }
        s.hasDrawn = true
        let id = s.id, token = s.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in   // let the GPU land it
            self?.onFirstFrame?(id, token)
        }
    }

    // Clock ticks: one run-loop timer on this thread, re-armed for each second. The
    // tolerance lets macOS coalesce the wake-up with others; 30 ms is under one frame
    // at 30 fps, so a clock still turns over on the second to the eye.
    private func armClock(after delay: TimeInterval) {
        let t = clockTimer ?? makeClockTimer()
        t.fireDate = Date(timeIntervalSinceNow: delay)
    }

    private func makeClockTimer() -> Timer {
        let t = Timer(fire: .distantFuture, interval: 86_400, repeats: true) { [weak self] _ in
            autoreleasepool { self?.clockFired() }
        }
        t.tolerance = 0.03
        RunLoop.current.add(t, forMode: .common)
        clockTimer = t
        return t
    }

    private func clockFired() {
        if debug {
            clockTicks += 1
            clockTickLatest = max(clockTickLatest, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1))
        }
        guard state.canDraw else { setPlans(); return }
        // The displays whose clock frame is due (within the timer's 30 ms tolerance); one whose
        // next tick is later (a once-a-minute still clock beside a seconds clock) waits for it.
        let now = Date().addingTimeInterval(0.03)
        for s in surfaces.values where s.due <= now && state.visible.contains(s.id) {
            draw(s, fromLink: false, settled: !plan(for: s).isContinuous)
        }
        noteStats()
        setPlans()
    }

    /// A video source keeps decoding on its own clock; stop it with that display's frames.
    /// Invariant: each renderer has been told its surface's value since its media last changed
    /// (addSurface and setStyles push it after `apply`), so calls that wouldn't change it skip.
    private func setMediaPaused(_ s: Surface, _ paused: Bool) {
        guard paused != s.mediaPaused else { return }
        s.mediaPaused = paused
        s.renderer.setMediaPaused(paused)
    }

    /// While frames are actually being drawn, tell the system this is ongoing work so
    /// App Nap never throttles the display link or the clock timer with the main window
    /// closed. `.background` is the least aggressive activity: no sleep or display-sleep
    /// assertion, no priority boost. Ended whenever paused. (A visible, drawing desktop
    /// window already keeps the app out of App Nap; this only covers the edge cases.)
    private func setActive(_ on: Bool) {
        if Self.noActivity { return }
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Live wallpaper")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func noteStats() {
        let now = CACurrentMediaTime()
        guard debug, now - statsSince >= 10 else { return }
        let gpu = surfaces.values.reduce(0) { $0 + $1.renderer.takeGPUSeconds() }
        let pacing = surfaces.values.map {
            let px = $0.layer.drawableSize
            return "[\(Int(px.width))x\(Int(px.height))] "
                + $0.pacing.take(slot: $0.linkRate > 0 ? 1 / $0.linkRate : 0, refresh: $0.config.refreshRate)
        }.joined(separator: " ")
        let span = now - statsSince
        let clock = clockTicks > 0
            ? String(format: ", clock ticks %d (latest +%.0fms past the second)", clockTicks, clockTickLatest * 1000) : ""
        log(String(format: "stats %.1f fps, GPU busy %.2f%% (%.2f ms/frame) over %.0fs, intervals %@ (profile=%@)%@",
                   Double(framesDrawn) / span, gpu / span * 100,
                   framesDrawn > 0 ? gpu / Double(framesDrawn) * 1000 : 0, span, pacing,
                   surfaces.keys.map { "\($0)=\(state.pacing($0).profile)" }.joined(separator: " "), clock))
        framesDrawn = 0
        statsSince = now
        clockTicks = 0
        clockTickLatest = 0
    }

    private func log(_ message: @autoclosure () -> String) {
        store.debug("wallpaper", message())
    }

    // MARK: Display link target

    /// Created on the main thread (NSView.displayLink is AppKit API), fired on the
    /// render thread's run loop. CADisplayLink retains its target; this weak
    /// trampoline keeps the loop free to go.
    static func linkTarget(_ loop: WallpaperRenderLoop, display id: CGDirectDisplayID) -> NSObject {
        LinkTarget(loop, id)
    }

    static let linkSelector = #selector(LinkTarget.fire(_:))

    private final class LinkTarget: NSObject {
        weak var loop: WallpaperRenderLoop?
        let id: CGDirectDisplayID
        init(_ loop: WallpaperRenderLoop, _ id: CGDirectDisplayID) { self.loop = loop; self.id = id }
        @objc func fire(_ link: CADisplayLink) {
            autoreleasepool { loop?.linkFired(id, presentAt: link.targetTimestamp) }
        }
    }
}

// MARK: - The thread

/// A thread with its own run loop that runs posted blocks in order. Posting never
/// blocks beyond a short lock; blocks posted before the run loop exists wait in the queue.
private final class RenderThread: Thread {
    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?

    func async(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        let rl = runLoop, src = source
        lock.unlock()
        if let rl, let src {
            CFRunLoopSourceSignal(src)
            CFRunLoopWakeUp(rl)
        }
    }

    override func main() {
        var ctx = CFRunLoopSourceContext()
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        ctx.perform = { info in
            guard let info else { return }
            Unmanaged<RenderThread>.fromOpaque(info).takeUnretainedValue().drain()
        }
        let rl = CFRunLoopGetCurrent()!
        let src = CFRunLoopSourceCreate(nil, 0, &ctx)!
        CFRunLoopAddSource(rl, src, .commonModes)
        lock.lock()
        runLoop = rl
        source = src
        let pending = !queue.isEmpty
        lock.unlock()
        if pending { CFRunLoopSourceSignal(src) }
        while true {
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 1e9, true) }
        }
    }

    private func drain() {
        lock.lock()
        let work = queue
        queue.removeAll()
        lock.unlock()
        for w in work { autoreleasepool { w() } }
    }
}
