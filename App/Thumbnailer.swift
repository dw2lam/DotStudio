//  Thumbnailer.swift — renders small cached previews of each screensaver.
//
//  A style's first still renders right away (so a tile never shows up empty); every later
//  re-render — an edit, a poster landing, the clock turning over — runs on a background
//  queue, coalesced per style, while the tile keeps its current still, and the gallery
//  repaints once when the new one lands. So dragging a slider in the editor never blocks the
//  main thread on a Metal render, however many views show that style.
//
//  Who repaints: a view that shows a still asked `image(for:)` for it in its body, which reads
//  that style's change signal (Observation) — so a still landing repaints exactly the views
//  showing THAT style, never the whole gallery (a video poster landing, which can touch any
//  still, bumps one shared signal; the song changing bumps another, read only by the stills
//  that show music). Opening the gallery also renders every missing first still
//  in the background (`prewarm`), so scrolling never waits on a Metal render.
//
//  Stills that depend on the wall clock (clocks, Window Light, the live sky, Night Sky,
//  Universe) or on the live weather carry a time bucket / weather revision in their key, and
//  are re-rendered at those boundaries while a DotStudio window is on screen — only those
//  styles. With every window closed (menu-bar mode) nothing ticks; the next gallery render
//  catches up before it shows them.

import AppKit
import AVFoundation
import MetalKit
import Observation

final class Thumbnailer {
    private let renderer: MetalRenderer?
    private let store: SharedStore
    /// Guards `renderer`: it renders on the main thread (a style's first still, swatches) and
    /// on `refreshQueue` (every refresh). One render at a time.
    private let renderLock = NSLock()
    private let refreshQueue = DispatchQueue(label: "com.davidlam.DotStudio.thumbnails", qos: .userInitiated)
    private var cache: [UUID: NSImage] = [:]
    private var stamps: [UUID: Stamp] = [:]
    /// Gallery tiles are ~260pt wide; 16:10 matches most Mac displays.
    let width = 448, height = 280
    private var effectCache: [Int: NSImage] = [:]

    /// One style's change signal: views read it (through `image(for:)`) while rendering, so
    /// bumping it repaints only the views showing that style.
    @Observable final class Signal {
        var revision = 0
    }
    private var signals: [UUID: Signal] = [:]
    /// Bumped by changes that can touch any still: a video poster landing. Main thread.
    private let everyStill = Signal()
    /// Bumped when what a music still shows changes (the track, play/pause): read only by the
    /// views that show music (a legacy Now Playing tile, the Screensaver card's still hero), so
    /// a song change never repaints the other tiles or the backdrop. Main thread.
    private let musicStills = Signal()
    /// Perf probe: its offscreen window counts as an app window on screen (the probe's window
    /// is borderless and never ordered in, so nothing ticks or follows the music otherwise).
    static var assumesWindowOnScreen = false

    private func signal(_ id: UUID) -> Signal {
        if let s = signals[id] { return s }
        let s = Signal()
        signals[id] = s
        return s
    }

    /// Registers the calling view (in its body) as showing `id`'s still.
    private func observe(_ id: UUID) {
        _ = signal(id).revision
        _ = everyStill.revision
    }
    /// The device location (live sky, Universe marker); AppModel supplies it.
    var location: () -> (lat: Double, lon: Double)? = { nil }

    // Video poster frames: one per media file, only for the current video, never retried.
    private var posters: [String: MTLTexture] = [:]
    private var postersPending: Set<String> = []
    private var postersFailed: Set<String> = []
    /// Twice the tile (Retina): a 4K video's full-size frame would be a 33 MB texture.
    static let posterMaxSize = CGSize(width: 896, height: 560)

    // Background refreshes (main thread bookkeeping).
    private var inFlight: Set<UUID> = []
    private var queued: [UUID: Job] = [:]

    // Time-dependent stills: what was last asked for, and when a view last showed it.
    private var timed: [UUID: (job: Job, seen: Date)] = [:]
    private var tick: Timer?

    /// The live weather's revision, for "Live" weather stills (stat of weather.json, ≤ every 5 s).
    private lazy var weather = WeatherFeed(baseDir: store.baseDir)
    private var weatherPolled: CFTimeInterval = -.infinity

    /// Offscreen UI shots capture right after the body pass: every still must be in place then.
    private static let synchronous = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil

    /// What a cached still was rendered for: its content, and the time bucket it shows.
    private struct Stamp: Equatable {
        var content: Int
        var bucket: Int
    }

    /// Everything one render needs, captured on the main thread.
    private struct Job {
        let preset: Preset
        let source: SourceSpec
        let poster: MTLTexture?
        let settings: MusicSpec
        let music: MusicSnapshot?
        let location: (lat: Double, lon: Double)?
        let time: Float
        let period: TimeInterval?
        let stamp: Stamp
    }

    init(store: SharedStore) {
        self.store = store
        renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
        // A window coming back into view (uncovered, unminimized) catches up at once on stills
        // whose time moved on while nobody could see them.
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.timed.isEmpty, Self.appWindowOnScreen else { return }
            // Nothing scrolled while it was hidden: what showed then still shows.
            let now = Date()
            for (id, entry) in self.timed { self.timed[id] = (entry.job, now) }
            self.tick?.invalidate()
            self.tickFired()
        }
    }

    deinit {
        Perf.count("Thumbnailer.deinit")
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        tick?.invalidate()
    }

    private var occlusion: NSObjectProtocol?

    /// Drop cached thumbnails for presets no longer in the library.
    func retain(ids: Set<UUID>) {
        cache = cache.filter { ids.contains($0.key) }
        stamps = stamps.filter { ids.contains($0.key) }
        cardCache = cardCache.filter { ids.contains($0.key) }
        timed = timed.filter { ids.contains($0.key) }
        queued = queued.filter { ids.contains($0.key) }
        signals = signals.filter { ids.contains($0.key) }
    }

    /// - music: the library's music settings — a Now Playing tile keeps a paused song exactly
    ///   as long as the screensaver does (its linger).
    func image(for preset: Preset, source: SourceSpec, music settings: MusicSpec = MusicSpec()) -> NSImage? {
        Perf.count("thumb:image(for:)")
        let id = preset.id
        observe(id)
        let job = makeJob(preset, source: source, settings: settings)
        if job.period != nil {
            timed[id] = (job, Date())
            armTick()
        } else if timed[id] != nil {
            timed[id] = nil
        }
        if stamps[id] == job.stamp, let img = cache[id] { return img }

        // Already has a still: keep showing it and re-render in the background — unless it is
        // from several time buckets ago (a window reopened after hours in the menu bar), which
        // must never show, even for a moment.
        if let img = cache[id], let old = stamps[id], !Self.synchronous,
           !(old.content == job.stamp.content && job.stamp.bucket - old.bucket > 1) {
            refresh(job)
            return img
        }
        guard let cg = render(job) else { return cache[id] }
        return store(job, cg)
    }

    // MARK: Jobs

    private func makeJob(_ preset: Preset, source: SourceSpec, settings: MusicSpec) -> Job {
        // Resolve a poster override for video sources (kicks off async generation on first
        // sight; the gradient fallback shows until it lands).
        let poster = posterTexture(for: source)
        var hasher = Hasher()
        // The name only matters where it picks the photo (a Look on the slideshow); renaming
        // anything else must not re-render it.
        var content = preset
        if source.kind != .collection || preset.isScene { content.name = "" }
        hasher.combine(content)
        hasher.combine(source)
        hasher.combine(poster != nil)   // re-render once the poster arrives
        // Now Playing tiles show the current track: re-render when it (not its progress) changes.
        var music: MusicSnapshot?
        if preset.isMusicScene {
            _ = musicStills.revision
            musicSettings = settings
            watchMusic()
            let snap = MusicFeedHub.shared.snapshot(store: store)
            music = snap
            hasher.combine(Self.musicKey(snap, settings))
        }
        let period = Self.refreshPeriod(preset)
        var loc: (lat: Double, lon: Double)?
        if period != nil {
            loc = location()
            hasher.combine(loc?.lat)
            hasher.combine(loc?.lon)
        }
        if WeatherLink.followsLive(preset) { hasher.combine(weatherRevision()) }
        let bucket = period.map { Int((Date().timeIntervalSince1970 / $0).rounded(.down)) } ?? 0
        return Job(preset: preset, source: source, poster: poster, settings: settings, music: music,
                   location: loc, time: thumbTime(preset, source), period: period,
                   stamp: Stamp(content: hasher.finalize(), bucket: bucket))
    }

    /// Renders a job's frame (any thread).
    private func render(_ job: Job) -> CGImage? {
        Perf.count(Thread.isMainThread ? "thumb:render-main" : "thumb:render-bg")
        renderLock.lock(); defer { renderLock.unlock() }
        guard let renderer else { return nil }
        if let music = job.music { renderer.setMusic(music) }
        renderer.musicLingerMinutes = job.settings.linger
        renderer.location = job.location
        return renderer.renderThumbnail(preset: job.preset, source: job.source,
                                        width: width, height: height, time: job.time,
                                        sourceTexOverride: job.poster)
    }

    /// Caches a rendered frame as the job's still (main thread).
    @discardableResult
    private func store(_ job: Job, _ frame: CGImage) -> NSImage {
        var cg = frame
        // A legacy Now Playing style: its own foreground while a song shows (calm art otherwise).
        if let music = job.music {
            let p = MusicPresentation.resolve(settings: job.settings, music: music, preset: job.preset)
            cg = Self.composite(cg, mode: p.overlay, music: music, settings: job.settings) ?? cg
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
        cache[job.preset.id] = img
        stamps[job.preset.id] = job.stamp
        return img
    }

    /// Re-render in the background; at most one render per style in flight, the latest
    /// request queued behind it (a slider drag renders its last value, not every tick).
    private func refresh(_ job: Job) {
        let id = job.preset.id
        if inFlight.contains(id) { queued[id] = job; return }
        inFlight.insert(id)
        refreshQueue.async { [weak self] in
            let frame = self?.render(job)
            DispatchQueue.main.async { self?.finished(job, frame) }
        }
    }

    private func finished(_ job: Job, _ frame: CGImage?) {
        let id = job.preset.id
        inFlight.remove(id)
        let next = queued.removeValue(forKey: id)
        guard cache[id] != nil else { return }        // the style was deleted meanwhile
        if let frame {
            store(job, frame)
            signal(id).revision += 1
        }
        if let next, next.stamp != job.stamp { refresh(next) }
    }

    // MARK: Prewarm

    /// Renders, in the background, the first still of every style that has none yet (the
    /// gallery appearing): the tiles a scroll brings into view then find their still cached
    /// instead of rendering it on the main thread mid-scroll. One render at a time, in order.
    func prewarm(_ presets: [Preset], source: SourceSpec, music settings: MusicSpec) {
        guard !Self.synchronous else { return }
        for p in presets where cache[p.id] == nil && !inFlight.contains(p.id) {
            let job = makeJob(p, source: source, settings: settings)
            inFlight.insert(p.id)
            refreshQueue.async { [weak self] in
                let frame = self?.render(job)
                DispatchQueue.main.async { self?.prewarmed(job, frame) }
            }
        }
    }

    private func prewarmed(_ job: Job, _ frame: CGImage?) {
        let id = job.preset.id
        inFlight.remove(id)
        let next = queued.removeValue(forKey: id)
        // A view may have rendered it itself meanwhile (it was on screen first): keep that one.
        if cache[id] == nil, let frame {
            store(job, frame)
            signal(id).revision += 1
        }
        if let next, cache[id] != nil, next.stamp != stamps[id] { refresh(next) }
    }

    /// Perf probe: announce a still landing exactly as a finished refresh does.
    func debugAnnounceUpdate(_ id: UUID) { signal(id).revision += 1 }

    // MARK: Time and weather

    /// How often a style's still goes stale: a clock each minute, the sky every ten, the live
    /// weather every five (plus whenever a new reading lands). Nil: it never does.
    private static func refreshPeriod(_ preset: Preset) -> TimeInterval? {
        var best: TimeInterval?
        func take(_ s: TimeInterval) { best = min(best ?? s, s) }
        for e in preset.effects where e.enabled {
            switch e.kind {
            case .typeClock, .flipClock, .wordClock, .dialClock, .windowLight,
                 .standbyClock, .minimalClock, .watchClock: take(60)
            case .nightSky, .universe: take(600)
            default: break
            }
            // MetalRenderer.fillLiveSky: these follow the real sun and moon when "live" is on.
            if [.oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden].contains(e.kind),
               (e.params["live"] ?? 0) > 0.5 { take(600) }
            if e.kind == .meadow, (e.params["live"] ?? 1) > 0.5 { take(600) }
            if e.kind == .waddle, (e.params["night"] ?? 1) > 0.5 { take(600) }   // dozes and dims at night
            if WeatherLink.usesWeather(e.kind), WeatherLink.fixedCondition(e) == nil { take(300) }
        }
        return best
    }

    private func weatherRevision() -> Int {
        let now = CACurrentMediaTime()
        if now - weatherPolled >= WeatherLink.pollSeconds {
            weatherPolled = now
            weather.poll()
        }
        return weather.revision
    }

    /// Wake at the next boundary of the shortest period among the time-dependent stills.
    private func armTick() {
        guard tick == nil, !Self.synchronous,
              let period = timed.values.compactMap(\.job.period).min() else { return }
        let now = Date().timeIntervalSince1970
        let delay = period - now.truncatingRemainder(dividingBy: period) + 0.05
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tickFired() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    /// Re-render the time-dependent stills a view showed lately, if their bucket (or the weather)
    /// moved on — only while a DotStudio window is on screen.
    private func tickFired() {
        Perf.count("tick:Thumbnailer")
        tick = nil
        // Nobody can see a still (every window closed, covered or minimized): stop until a
        // window comes back into view (the occlusion observer) or a view asks again.
        guard Self.appWindowOnScreen else { return }
        let now = Date()
        for (id, entry) in timed {
            guard let period = entry.job.period, now.timeIntervalSince(entry.seen) <= period + 120 else {
                timed[id] = nil       // not shown any more (scrolled off, filtered out, editor closed)
                continue
            }
            let job = makeJob(entry.job.preset, source: entry.job.source, settings: entry.job.settings)
            timed[id] = (job, entry.seen)
            if cache[id] != nil, stamps[id] != job.stamp { refresh(job) }
        }
        armTick()
    }

    private static var appWindowOnScreen: Bool {
        assumesWindowOnScreen || NSApp?.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
        } ?? false
    }

    // MARK: Music (legacy Now Playing tiles, music on the screensaver's still)

    private var musicToken: MusicFeedHub.Token?
    private var lastMusicKey: String?
    /// The settings the latest music render used (the feed watcher's key needs the linger).
    private var musicSettings = MusicSpec()
    private var cardCache: [UUID: (key: String, image: NSImage)] = [:]

    /// The thumbnail with music presented on it as the screensaver shows it right now
    /// (MusicPresentation: Corner at its true share of the screen, or Full Screen over its
    /// backdrop) — the Screensaver card's still hero. Plain while nothing shows.
    func image(for preset: Preset, source: SourceSpec, music settings: MusicSpec, showsMusic: Bool) -> NSImage? {
        let base = image(for: preset, source: source, music: settings)
        guard showsMusic, !preset.isMusicScene, settings.displayMode != .off, let base else { return base }
        _ = musicStills.revision
        musicSettings = settings
        watchMusic()
        let snap = MusicFeedHub.shared.snapshot(store: store)
        let p = MusicPresentation.resolve(settings: settings, music: snap, preset: preset)
        guard p.overlay != .hidden else { return base }
        let key = [Self.musicKey(snap, settings), "\(p.overlay)", "\(p.backdrop)", settings.cardSizePreference.rawValue,
                   "\(ObjectIdentifier(base).hashValue)"].joined(separator: "|")
        if let hit = cardCache[preset.id], hit.key == key { return hit.image }
        var frame: CGImage?
        if p.backdrop != .none {
            let poster = posterTexture(for: source)
            renderLock.lock()
            renderer?.setMusic(snap)
            renderer?.musicLingerMinutes = settings.linger
            renderer?.location = location()
            frame = renderer?.renderThumbnail(preset: preset, source: source, width: width, height: height,
                                              time: thumbTime(preset, source), sourceTexOverride: poster,
                                              musicBackdrop: p.backdrop)
            renderLock.unlock()
        } else {
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            frame = base.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let frame, let out = Self.composite(frame, mode: p.overlay, music: snap, settings: settings,
                                                  trueScale: true) else { return base }
        let img = NSImage(cgImage: out, size: base.size)
        cardCache[preset.id] = (key, img)
        return img
    }

    /// What a Now Playing tile depends on: the track, its artwork and whether it's showing —
    /// not the progress, so a playing song doesn't re-render the gallery every second.
    private static func musicKey(_ s: MusicSnapshot, _ settings: MusicSpec) -> String {
        let visible = s.isVisible(settings: settings)
        guard visible, let st = s.state else { return "idle" }
        return [st.trackID ?? st.title ?? "", st.artwork ?? "-", st.isPlaying == true ? "▶" : "Ⅱ"].joined(separator: "|")
    }

    /// Once a still shows music (a Now Playing tile, the Screensaver card's hero), follow the
    /// feed and repaint those stills (only) when its key changes — only while an app window is
    /// up: with every window closed (menu-bar mode) the subscription drops itself, and the next
    /// gallery render subscribes again.
    private func watchMusic() {
        guard musicToken == nil else { return }
        musicToken = MusicFeedHub.shared.subscribe(store: store) { [weak self] snap, _ in
            guard let self else { return }
            if !Self.assumesWindowOnScreen, let app = NSApp,
               !app.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                self.musicToken = nil
                self.lastMusicKey = nil
                return
            }
            let k = Self.musicKey(snap, self.musicSettings)
            if self.lastMusicKey != nil, k != self.lastMusicKey { self.musicStills.revision += 1 }
            self.lastMusicKey = k
        }
    }

    /// The music foreground (native-resolution CALayer tree) drawn over a rendered frame.
    /// - trueScale: a miniature of a real screen (no legibility floor under the card).
    static func composite(_ frame: CGImage, mode: MusicOverlayLayer.Mode, music: MusicSnapshot,
                          settings: MusicSpec = MusicSpec(), scale: CGFloat = 2,
                          trueScale: Bool = false) -> CGImage? {
        let w = frame.width, h = frame.height
        let layer = MusicOverlayLayer()
        layer.trueScale = trueScale
        layer.ambientMotion = false            // a still: a title too long to fit wraps, never scrolls
        layer.contentsScale = scale
        layer.frame = CGRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        layer.update(mode: mode, music: music, settings: settings, animated: false)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Thumbnail time. For a slideshow, each Look gets its own photo (stable per name), so
    /// the gallery shows off the set instead of one picture eleven times.
    private func thumbTime(_ preset: Preset, _ source: SourceSpec) -> Float {
        guard source.kind == .collection, !preset.isScene else { return 1.2 }
        var h: UInt32 = 2166136261
        for b in preset.name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }   // FNV-1a: stable across launches
        return Float(Double(h % 101) * source.slideInterval + 1.2)
    }

    /// A small swatch of one effect applied alone to the current source (Add Effect picker).
    func effectImage(_ kind: EffectKind, source: SourceSpec) -> NSImage? {
        _ = everyStill.revision
        let override = posterTexture(for: source)
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(source)
        hasher.combine(override != nil)
        let key = hasher.finalize()
        if let img = effectCache[key] { return img }
        let w = 224, h = 140
        renderLock.lock()
        let cg = renderer?.renderThumbnail(preset: Preset(name: kind.displayName, effects: [EffectInstance(kind)]),
                                           source: source, width: w, height: h,
                                           sourceTexOverride: override)
        renderLock.unlock()
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: w / 2, height: h / 2))
        if effectCache.count > 200 { effectCache.removeAll() }
        effectCache[key] = img
        return img
    }

    // MARK: Video posters

    /// The poster for the current video source, if it has landed (requested on first sight).
    /// Posters of any other media are dropped: only the library's one source is ever drawn.
    private func posterTexture(for source: SourceSpec) -> MTLTexture? {
        let current = source.kind == .video ? source.mediaFilename : nil
        if posters.keys.contains(where: { $0 != current }) {
            posters = posters.filter { $0.key == current }
        }
        guard let name = current else { return nil }
        if let tex = posters[name] { return tex }
        requestPoster(name)
        return nil
    }

    /// Grab a frame ~1s into the video (at most twice the tile's size) and upload it as a
    /// Metal texture. A file that yields no frame isn't asked again (the gradient fallback stays).
    private func requestPoster(_ name: String) {
        guard !postersPending.contains(name), !postersFailed.contains(name),
              let device = renderer?.device else { return }
        postersPending.insert(name)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: store.mediaURL(name)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = Self.posterMaxSize
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] cg, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.postersPending.remove(name)
                // Match ImageSource's loader options so posters render identically.
                let loader = MTKTextureLoader(device: device)
                let opts: [MTKTextureLoader.Option: Any] = [
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .origin: MTKTextureLoader.Origin.topLeft.rawValue
                ]
                guard let cg, let tex = try? loader.newTexture(cgImage: cg, options: opts) else {
                    self.postersFailed.insert(name)
                    return
                }
                self.posters[name] = tex
                self.everyStill.revision += 1
            }
        }
    }
}
