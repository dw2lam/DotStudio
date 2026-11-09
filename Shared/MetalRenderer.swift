//  MetalRenderer.swift — renders a Preset as a chain of fullscreen shader passes.

import Metal
import MetalKit
import simd
import QuartzCore

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let glyphs: MTLTexture?
    private let dummy: MTLTexture
    /// Universe's planet maps load on first use; every other effect binds placeholders.
    private lazy var planetTex = PlanetTextures(device: device, queue: queue)
    private lazy var planetPlaceholder = PlanetTextures(placeholderFor: device)
    private func planetTextures(for effect: Int32) -> PlanetTextures {
        effect == EffectKind.universe.shaderID ? planetTex : planetPlaceholder
    }

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var drawableSize: CGSize = .zero

    // Serial dither (error diffusion / Riemersma) compute resources.
    private var ditherPrepPSO: MTLComputePipelineState?
    private var ditherWavePSO: MTLComputePipelineState?
    private var ditherRiemPSO: MTLComputePipelineState?
    private var ditherRelaxPSO: MTLComputePipelineState?
    private var ditherFinalPSO: MTLComputePipelineState?
    private var gridTex: MTLTexture?
    private var errBuf: MTLBuffer?
    private var gridW = 0, gridH = 0, gridCell = 1
    /// What the dither history in `errBuf` was made with (packed params, colours, grid). Any
    /// change (another preset, an edited param, a resize) or apply() starts from no history:
    /// a different dither must never inherit the previous one's pattern.
    private var ditherHistoryKey: [Float]?

    /// Media-clock origin of the animation time: t = now − startTime. With the instance
    /// time base it's when the source was applied; with the wall-clock base it is re-derived
    /// every frame from the wall clock (see `timeBase`).
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var loggedFirstFrame = false

    /// What the animation time `t` counts from.
    enum TimeBase: Equatable {
        /// Seconds since this renderer applied its current source (the default): every
        /// preview, saver and wallpaper instance starts its own motion from zero.
        case instance
        /// Seconds into the current wall-clock hour (`wallClockPeriod`, aligned to the Unix
        /// epoch, so DST and time-zone changes never move it), read from the wall clock each
        /// frame. Every renderer using it (screensaver, live wallpaper) draws the same frame at
        /// the same moment — the screensaver picks up exactly where the desktop was.
        ///
        /// Shaders get t as a Float: under an hour it resolves 0.24 ms at worst, so frame steps
        /// stay even at 120 fps (seconds since midnight reached 7.8 ms and visibly juddered).
        /// At each boundary t wraps to 0; the renderer hides the jump with a 2 s crossfade from
        /// the old time to the new, which every synced renderer performs at the same wall time.
        /// A slideshow source runs on the full-precision wall clock instead, so it never wraps
        /// (see `slideClock`); a video keeps its own decoder clock.
        case wallClock
    }

    /// The wall-clock time base's period: t ∈ [0, 3600).
    static let wallClockPeriod: Double = 3600

    /// Switching bases mid-show crossfades (motion and slideshow jump); before the first
    /// frame it's free. Wall clock → instance keeps the current origin, so the motion carries
    /// on from where it was and only a slideshow changes.
    var timeBase: TimeBase = .instance {
        didSet {
            guard timeBase != oldValue else { return }
            let now = CACurrentMediaTime()
            if let p = preset, outgoing == nil, drewOnce {
                // The outgoing chain keeps the OLD clock: captured before the origin moves.
                outgoing = Outgoing(preset: p, packed: packedUniforms, startTime: startTime,
                                    wallSlides: oldValue == .wallClock)
                transitionBegan = now
                transitionDuration = 1.0
            }
            if timeBase == .wallClock { syncWallClockOrigin(now, allowWrapFade: false) }
        }
    }
    private var drewOnce = false

    // Cap frames-in-flight so drawables/IOSurfaces are recycled rather than queued up.
    private let inFlight = DispatchSemaphore(value: 2)

    // Render description
    private(set) var preset: Preset?
    private var source = SourceSpec()
    private var media: MediaSource?
    private var collection: CollectionSource?           // .collection sources (slideshow)
    // Thumbnail/export slideshows (no eviction), keyed by decode size class.
    private var thumbCollections: [Int: CollectionSource] = [:]
    private let store: SharedStore
    var location: (lat: Double, lon: Double)?      // resolved device location (Universe marker, live sky)
    /// Renders as if the wall clock read this instead of now (offscreen gallery only).
    var clockOverride: Date?

    // Per-effect uniforms packed once at apply(); per frame only the dynamic
    // fields (time/resolution/srcSize/astro) are overwritten on a copy.
    private var packedUniforms: [FXUniforms] = []

    // astro() only changes at wall-clock resolution — recompute at most 1×/sec.
    private var astroCached: (at: CFTimeInterval, value: (sun: simd_float3, userLon: Float, userLat: Float, hasLoc: Bool))?

    // Crossfade: while `outgoing` is set, both chains render (old → fadeOld,
    // new → drawable via blend pass 41) until progress reaches 1.
    private struct Outgoing {
        let preset: Preset
        let packed: [FXUniforms]
        /// The outgoing chain's own time origin (a wall-clock wrap keeps counting past it).
        let startTime: CFTimeInterval
        /// Its slideshow ran on the wall clock (see `slideClock`).
        let wallSlides: Bool
    }
    private var outgoing: Outgoing?
    private var transitionBegan: CFTimeInterval = 0
    private var transitionDuration: Double = 0
    private var fadeOld: MTLTexture?
    private var fadeNew: MTLTexture?

    // Now Playing (scene 66): artwork in slot 7, the previous track's in slot 8 while the
    // background cross-fades. See setMusic(_:).
    private var hostMusic: MusicSnapshot?
    private var ownMusicFeed: MusicFeed?
    private var lastMusicPoll: CFTimeInterval = -.infinity
    private var musicArtImage: CGImage?
    private var musicArtTex: MTLTexture?
    private var musicArtPrevTex: MTLTexture?
    private var musicArtChangedAt: CFTimeInterval = -.infinity
    private var musicPrepared = false
    private var musicPalette: [RGBA] = []
    private var musicPaletteKey: (CGImage?, [RGBA]?) = (nil, nil)
    /// Paused-track linger (Library.musicSettings.linger) for deciding "nothing playing".
    var musicLingerMinutes: Double = MusicSpec().linger
    /// Accessibility Reduce Motion: the Now Playing background drifts at a third of the speed.
    var reduceMotion = false

    /// - device: the GPU to render on (the live wallpaper uses the one driving its
    ///   display); nil = the system default.
    init?(pixelFormat: MTLPixelFormat, store: SharedStore, device preferredDevice: MTLDevice? = nil) {
        guard let device = preferredDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.store = store

        // Load the metallib from THIS class's bundle. In the app that's the app
        // bundle; in the screensaver it's the .saver bundle. Using the default
        // library would read Bundle.main — the host process — and fail in the saver.
        let bundle = Bundle(for: MetalRenderer.self)
        var library = try? device.makeDefaultLibrary(bundle: bundle)
        if library == nil {
            store.debug("metallib from bundle FAILED at \(bundle.bundlePath); trying default")
            library = device.makeDefaultLibrary()
        }
        guard let library,
              let vfn = library.makeFunction(name: "fx_vertex"),
              let ffn = library.makeFunction(name: "fx_fragment") else {
            store.debug("FATAL shader library/functions missing (library=\(library == nil ? "nil" : "ok"))")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = pso

        func compute(_ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        ditherPrepPSO = compute("dither_prep")
        ditherWavePSO = compute("dither_wave")
        ditherRiemPSO = compute("dither_riem")
        ditherRelaxPSO = compute("dither_relax")
        ditherFinalPSO = compute("dither_final")

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.mipFilter = .linear   // only slideshow photos carry mips; every other texture has one level
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        glyphs = GlyphAtlas.make(device: device)

        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead, .renderTarget]
        dummy = device.makeTexture(descriptor: dd)!

        super.init()
    }

    // MARK: Preset / media

    func apply(_ preset: Preset, source: SourceSpec) {
        let sourceChanged = (self.source != source)
        self.preset = preset
        self.source = source
        // Pack static uniforms (effect id, params, palette) once per preset change
        // instead of re-reading the params dictionary every pass every frame.
        packedUniforms = preset.effects.filter { $0.enabled }.map { inst in
            var u = FXUniforms()
            inst.pack(into: &u)
            return u
        }
        if sourceChanged {
            if timeBase == .instance { startTime = CACurrentMediaTime() }
            loadMedia(for: source)
        }
        ditherHistoryKey = nil
    }

    /// The animation time (seconds) a frame drawn at `now` would use, per the time base.
    /// With `.wallClock` every renderer on the Mac returns the same value at the same moment.
    /// Read-only: it never moves the origin a frame's wrap crossfade is detected against.
    func animationTime(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        timeBase == .wallClock ? Self.wallPhase(Date().timeIntervalSince1970) : now - startTime
    }

    /// Seconds into the current wall-clock period (0 ..< wallClockPeriod).
    static func wallPhase(_ epoch: Double) -> Double {
        let p = wallClockPeriod
        return max(epoch - (epoch / p).rounded(.down) * p, 0)
    }

    /// Wall-clock time base: put `startTime` where t = seconds into the current period. When
    /// the origin moves (the hourly wrap, the clock being set, a wake from sleep) that frame
    /// starts a crossfade whose outgoing chain keeps the old origin, so motion never visibly
    /// jumps. Every synced renderer wraps at the same wall time.
    private func syncWallClockOrigin(_ now: CFTimeInterval, allowWrapFade: Bool) {
        let origin = now - Self.wallPhase(Date().timeIntervalSince1970)
        if allowWrapFade, abs(origin - startTime) > 0.25, let p = preset, outgoing == nil {
            // The outgoing chain keeps counting past the period for the 2 s fade.
            outgoing = Outgoing(preset: p, packed: packedUniforms, startTime: startTime, wallSlides: true)
            transitionBegan = now
            transitionDuration = 2.0
        }
        startTime = origin
    }

    /// The slideshow timeline a chain shows: on the wall clock, full-precision epoch seconds
    /// with a fixed photo order (seed 0), so every synced renderer shows the same photo with
    /// the same Ken Burns framing and the hourly wrap never touches it; otherwise the
    /// instance time with this source's own random first photo.
    private func slideClock(wall: Bool, startTime: CFTimeInterval, now: CFTimeInterval, epoch: Double) -> SlideClock {
        wall ? SlideClock(t: epoch, seed: 0) : SlideClock(t: now - startTime, seed: nil)
    }

    /// Opt-in GPU accounting (live wallpaper power stats): GPU execution time of drawn
    /// frames, accumulated from Metal's completion threads.
    var measuresGPUTime = false
    private let gpuLock = NSLock()
    private var gpuAccum: Double = 0
    /// Seconds of GPU time since the last call (thread-safe).
    func takeGPUSeconds() -> Double {
        gpuLock.lock(); defer { gpuLock.unlock() }
        let s = gpuAccum
        gpuAccum = 0
        return s
    }
    /// Debug pacing (live wallpaper): called on a Metal thread with each drawn frame's
    /// on-screen time (0 = never shown). Nil = no presented handler at all.
    var onPresented: ((CFTimeInterval) -> Void)?

    /// Pause/resume a video source's decoder while the host draws nothing (the live
    /// wallpaper's pause must stop the decoder too, not just the draws).
    func setMediaPaused(_ paused: Bool) {
        (media as? VideoSource)?.setPaused(paused)
    }

    // MARK: Music (Now Playing)

    /// What's playing, for the Now Playing scene. A host that polls its own MusicFeed (the
    /// saver, the wallpaper's render thread, previews) hands each new snapshot here, on the
    /// thread that draws. Until a host does, a renderer drawing a Now Playing style reads the
    /// shared music.json itself, about once a second. The artwork texture is rebuilt only
    /// when the artwork changes.
    func setMusic(_ snapshot: MusicSnapshot) {
        hostMusic = snapshot
    }

    private var currentMusic: MusicSnapshot { hostMusic ?? ownMusicFeed?.snapshot ?? .empty }

    /// The background's track-change cross-fade (Music_cases.h: smoothstep(0, 1.6, music.w)).
    static let musicFadeSeconds: Double = 1.6

    /// Poll (own feed only), and upload new artwork into this frame's command buffer ahead
    /// of the passes that sample it.
    /// - fade: cross-fade the background from the old art (a host drawing continuously).
    ///   false = settled: the frame shows the current art fully, finishing any fade — for a
    ///   host that holds this frame (a still wallpaper) or a one-off render.
    private func prepareMusic(_ cmd: MTLCommandBuffer, now: CFTimeInterval, wall: Date, fade: Bool) {
        if hostMusic == nil {
            if ownMusicFeed == nil { ownMusicFeed = MusicFeed(baseDir: store.baseDir) }
            if now - lastMusicPoll >= 1 {
                lastMusicPoll = now
                ownMusicFeed?.poll()
            }
        }
        let snap = currentMusic
        // Nothing playing (or paused past the linger) shows the idle background.
        let art = snap.state?.isVisible(at: wall, lingerMinutes: musicLingerMinutes) == true ? snap.artwork : nil
        if !fade {
            musicArtPrevTex = nil
            musicArtChangedAt = -.infinity
        }
        // Skipping tracks faster than the fade: let the running fade finish first, then fade
        // to whatever is current by then (never cut from a half-faded mix).
        let midFade = now - musicArtChangedAt < Self.musicFadeSeconds
        if !musicPrepared || (art !== musicArtImage && !midFade) {
            let crossfade = fade && musicPrepared       // the very first artwork just appears
            musicArtPrevTex = crossfade ? musicArtTex : nil
            musicArtTex = art.flatMap { uploadArt($0, cmd) }
            musicArtImage = art
            musicArtChangedAt = crossfade ? now : -.infinity
            musicPrepared = true
        } else if musicArtPrevTex != nil, now - musicArtChangedAt > Self.musicFadeSeconds + 0.4 {
            musicArtPrevTex = nil                          // fade done: free the old artwork
        }
        // The palette follows the artwork on screen (not one still waiting for its fade).
        if art === musicArtImage, musicPaletteKey.0 !== snap.artwork || musicPaletteKey.1 != snap.state?.palette {
            musicPaletteKey = (snap.artwork, snap.state?.palette)
            musicPalette = snap.palette
        }
    }

    /// Drop the artwork textures (and stop reading music.json) once no chain shows Now Playing.
    private func releaseMusic() {
        guard musicPrepared || ownMusicFeed != nil else { return }
        musicArtTex = nil; musicArtPrevTex = nil; musicArtImage = nil
        musicPrepared = false
        ownMusicFeed = nil
        lastMusicPoll = -.infinity
    }

    /// Per-frame Now Playing uniforms (palette, progress, artwork flags, its place on screen).
    private func fillMusic(_ u: inout FXUniforms, options: MusicSceneOptions, size: CGSize,
                           now: CFTimeInterval, wall: Date) {
        let snap = currentMusic
        let flags = (musicArtTex != nil ? 1 : 0) + (musicArtPrevTex != nil ? 2 : 0)
        let visible = snap.state?.isVisible(at: wall, lingerMinutes: musicLingerMinutes) == true
        let progress = visible ? (snap.state?.progress(at: wall) ?? -1) : -1
        u.music = simd_float4(Float(flags), Float(progress), snap.state?.isPlaying == true ? 1 : 0,
                              Float(min(max(now - musicArtChangedAt, 0), 10_000)))
        let pal = visible ? musicPalette : []
        func slot(_ i: Int) -> simd_float4 {
            guard i < pal.count else { return .zero }
            return simd_float4(Float(pal[i].r), Float(pal[i].g), Float(pal[i].b), 1)
        }
        u.musicPal0 = slot(0); u.musicPal1 = slot(1); u.musicPal2 = slot(2)
        let layout = MusicLayoutKind(rawValue: Int(u.p0.x.rounded())) ?? .album
        let r = MusicGeometry.artUV(layout, size: size, options: options)
        u.musicRect = simd_float4(r.x, r.y, r.w, r.h)
        if reduceMotion { u.p0.z *= 0.33 }
    }

    /// Artwork → mipmapped RGBA8 (raw sRGB values, like ImageSource) on this renderer's
    /// device; the mip chain is built on the GPU in `cmd`, before any pass samples it.
    private func uploadArt(_ cg: CGImage, _ cmd: MTLCommandBuffer) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        return tex
    }

    /// Switch presets with a GPU crossfade. Falls back to a hard cut when there's
    /// nothing to fade from (first apply) or the duration is negligible.
    func transition(to preset: Preset, source: SourceSpec, duration: Double) {
        guard duration > 0.05, let current = self.preset else {
            apply(preset, source: source)
            return
        }
        outgoing = Outgoing(preset: current, packed: packedUniforms, startTime: startTime,
                            wallSlides: timeBase == .wallClock)
        transitionBegan = CACurrentMediaTime()
        transitionDuration = duration
        apply(preset, source: source)   // shared global source ⇒ no media reload mid-fade
    }

    /// Sun/location for the Universe effect, cached for a second.
    private func cachedAstro() -> (sun: simd_float3, userLon: Float, userLat: Float, hasLoc: Bool) {
        let now = CACurrentMediaTime()
        if let c = astroCached, now - c.at < 1 { return c.value }
        let v = MetalRenderer.astro(location: location)
        astroCached = (now, v)
        return v
    }

    private func loadMedia(for source: SourceSpec) {
        media = nil
        if source.kind == .collection {
            // Interval/motion edits keep the decoded photos; a new photo list reloads.
            if let c = collection, c.filenames == (source.mediaFilenames ?? []) {
                c.update(source)
            } else {
                collection = CollectionSource(spec: source, store: store, device: device, live: true)
                if collection == nil { store.debug("slideshow has no photos (builtIn=\(source.usesBuiltInPhotos))") }
            }
            return
        }
        collection = nil
        guard source.kind != .gradient, let name = source.mediaFilename else { return }
        let url = store.mediaURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch source.kind {
        case .image: media = ImageSource(url: url, device: device)
        case .video: media = VideoSource(url: url, device: device)
        case .gradient, .collection: break
        }
    }

    /// A non-evicting slideshow for one-off renders, decoded at a size suited to `width`.
    private func thumbCollection(for source: SourceSpec, width: Int, height: Int) -> CollectionSource? {
        let long = max(width, height)
        let maxPixel = long <= 640 ? 1024 : long <= 1280 ? 1600 : 3200
        if let c = thumbCollections[maxPixel], c.filenames == (source.mediaFilenames ?? []) {
            c.update(source)
            return c
        }
        let c = CollectionSource(spec: source, store: store, device: device, live: false, maxPixel: maxPixel)
        thumbCollections[maxPixel] = c
        return c
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        drawableSize = size
        (texA, texB) = makeOffscreen(width: Int(size.width), height: Int(size.height), format: view.colorPixelFormat)
    }

    private func makeOffscreen(width: Int, height: Int, format: MTLPixelFormat) -> (MTLTexture?, MTLTexture?) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        return (device.makeTexture(descriptor: d), device.makeTexture(descriptor: d))
    }

    func draw(in view: MTKView) {
        // The screensaver host drives each frame manually (see DotSaverView) rather than
        // through MTKView's display link, so nothing drains an autorelease pool per frame.
        // Without this pool the per-frame CAMetalDrawable / IOSurface / command buffer
        // objects accumulate and leak GPU memory (grew to ~14 GB over days of idle).
        autoreleasepool {
            // Ensure offscreen textures exist & match the drawable. In a screensaver the
            // view is created at full size before the delegate is set, so the initial
            // drawableSizeWillChange callback can be missed — recreate here if needed.
            let ds = view.drawableSize
            if texA == nil || texB == nil || drawableSize != ds {
                mtkView(view, drawableSizeWillChange: ds)
            }
            guard preset != nil,
                  let final = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            encodeFrame(final: final, drawable: drawable, size: ds, format: view.colorPixelFormat)
        }
    }

    /// One frame straight into a CAMetalLayer, from whichever thread owns this renderer
    /// (the live wallpaper's render thread). The layer's drawableSize is the render size.
    /// - settled: the host will hold this frame (a still wallpaper) rather than draw the next
    ///   one shortly: finish any crossfade in progress (style, time-base wrap, track change)
    ///   and show the end state, instead of a first fade frame that would stay on screen.
    /// - Returns: whether a frame was encoded and committed.
    @discardableResult
    func draw(to layer: CAMetalLayer, settled: Bool = false) -> Bool {
        autoreleasepool {
            let ds = layer.drawableSize
            guard preset != nil, ds.width > 0, ds.height > 0 else { return false }
            if texA == nil || texB == nil || drawableSize != ds {
                drawableSize = ds
                (texA, texB) = makeOffscreen(width: Int(ds.width), height: Int(ds.height), format: layer.pixelFormat)
            }
            guard let drawable = layer.nextDrawable() else { return false }
            // Every pass writes every pixel (fullscreen triangle, no blending), so the old
            // contents never need loading or clearing.
            let final = MTLRenderPassDescriptor()
            final.colorAttachments[0].texture = drawable.texture
            final.colorAttachments[0].loadAction = .dontCare
            final.colorAttachments[0].storeAction = .store
            return encodeFrame(final: final, drawable: drawable, size: ds, format: layer.pixelFormat,
                               settled: settled) != nil
        }
    }

    /// One live frame — the same path as `draw(to:)`: time base, crossfades, slideshow
    /// clock, track-change fade — rendered offscreen and read back. For checks in the gallery
    /// tool; it resizes the renderer's working textures, so never call it between live draws.
    func renderFrame(width: Int, height: Int, settled: Bool = false) -> CGImage? {
        let fmt: MTLPixelFormat = .bgra8Unorm
        let ds = CGSize(width: width, height: height)
        guard preset != nil, width > 0, height > 0 else { return nil }
        if texA == nil || texB == nil || drawableSize != ds {
            drawableSize = ds
            (texA, texB) = makeOffscreen(width: width, height: height, format: fmt)
        }
        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
        fd.usage = [.shaderRead, .renderTarget]
        fd.storageMode = .shared
        guard let out = device.makeTexture(descriptor: fd) else { return nil }
        let final = offscreenDescriptor(out)
        guard let cmd = encodeFrame(final: final, drawable: nil, size: ds, format: fmt, settled: settled) else { return nil }
        cmd.waitUntilCompleted()
        return readBack(out)
    }

    /// Encode and commit one frame of the current preset into `final` (presenting
    /// `drawable` when there is one). Returns the committed command buffer.
    @discardableResult
    private func encodeFrame(final: MTLRenderPassDescriptor, drawable: MTLDrawable?,
                             size ds: CGSize, format: MTLPixelFormat, settled: Bool = false) -> MTLCommandBuffer? {
        guard let preset = preset, let texA = texA, let texB = texB else { return nil }

        // Throttle frames-in-flight; released in the command buffer's completion handler.
        inFlight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return nil }
        cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        if measuresGPUTime {
            cmd.addCompletedHandler { [weak self] cb in
                let dt = max(cb.gpuEndTime - cb.gpuStartTime, 0)
                guard let self else { return }
                self.gpuLock.lock(); self.gpuAccum += dt; self.gpuLock.unlock()
            }
        }

        let now = CACurrentMediaTime()
        if settled, outgoing != nil {
            outgoing = nil                       // a held frame shows where the fade ends
            fadeOld = nil; fadeNew = nil
        }
        if timeBase == .wallClock { syncWallClockOrigin(now, allowWrapFade: drewOnce && !settled) }
        drewOnce = true
        let t = Float(now - startTime)
        // Now Playing: poll / upload artwork before any pass samples it.
        if preset.isMusicScene || (outgoing?.preset.isMusicScene ?? false) {
            prepareMusic(cmd, now: now, wall: clockOverride ?? Date(), fade: !settled)
        } else {
            releaseMusic()
        }
        // Slideshow state comes from the source clock (see slideClock): both chains of a
        // preset crossfade show the same photo; a time-base switch fades between the two
        // clocks' photos. Scenes ignore the source, so an idle slideshow doesn't decode photos.
        let wantsSource = !preset.isScene || (outgoing.map { !$0.preset.isScene } ?? false)
        var slides: SlideFrame?
        var outSlides: SlideFrame?
        if wantsSource, let c = collection {
            let epoch = Date().timeIntervalSince1970
            let inClock = slideClock(wall: timeBase == .wallClock, startTime: startTime, now: now, epoch: epoch)
            let outClock = outgoing.map { slideClock(wall: $0.wallSlides, startTime: $0.startTime, now: now, epoch: epoch) }
            if let outClock, outClock != inClock {
                let f = c.frames(at: [inClock, outClock], sync: false)
                slides = f[0]; outSlides = f[1]
            } else {
                slides = c.frames(at: [inClock], sync: false)[0]
                outSlides = slides
            }
        }
        let sTex = media?.currentTexture() ?? slides?.texA
        if !loggedFirstFrame {
            loggedFirstFrame = true
            store.debug("first draw size=\(drawableSize) effects=\(preset.effects.count) srcTexNil=\(sTex == nil) sourceKind=\(source.kind.rawValue)")
        }

        var blended = false
        if let out = outgoing {
            let progress = (now - transitionBegan) / max(transitionDuration, 0.001)
            if progress >= 1 {
                outgoing = nil
                fadeOld = nil; fadeNew = nil     // ~2 drawables of VRAM back until the next fade
            } else {
                ensureFadeTextures(width: Int(ds.width), height: Int(ds.height),
                                   format: format)
                if let fo = fadeOld, let fn = fadeNew {
                    // Outgoing chain → fadeOld (its own time base keeps its motion coherent).
                    encodePasses(cmd, finalDescriptor: offscreenDescriptor(fo), pingA: texA, pingB: texB,
                                 size: drawableSize, time: Float(now - out.startTime),
                                 preset: out.preset, source: source,
                                 sourceTex: media?.currentTexture() ?? outSlides?.texA,
                                 slides: outSlides, packedUniforms: out.packed)
                    // Incoming chain → fadeNew. The shared ping-pong is safe: the chains
                    // encode sequentially and each result is parked before the next starts.
                    encodePasses(cmd, finalDescriptor: offscreenDescriptor(fn), pingA: texA, pingB: texB,
                                 size: drawableSize, time: t, preset: preset, source: source,
                                 sourceTex: sTex, slides: slides, packedUniforms: packedUniforms)
                    encodeBlend(cmd, final: final, newTex: fn, oldTex: fo,
                                progress: Float(progress), size: drawableSize)
                    blended = true
                }
            }
        }
        if !blended {
            encodePasses(cmd, finalDescriptor: final, pingA: texA, pingB: texB,
                         size: drawableSize, time: t, preset: preset, source: source,
                         sourceTex: sTex, slides: slides, packedUniforms: packedUniforms)
        }
        if let drawable {
            if let onPresented { drawable.addPresentedHandler { onPresented($0.presentedTime) } }
            cmd.present(drawable)
        }
        cmd.commit()
        return cmd
    }

    // MARK: Crossfade helpers

    private func ensureFadeTextures(width: Int, height: Int, format: MTLPixelFormat) {
        if fadeOld?.width == width, fadeOld?.height == height, fadeNew != nil { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                         width: max(width, 1), height: max(height, 1),
                                                         mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        fadeOld = device.makeTexture(descriptor: d)
        fadeNew = device.makeTexture(descriptor: d)
    }

    private func offscreenDescriptor(_ tex: MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        return rpd
    }

    /// Final pass of a transition frame: mix(fadeOld, fadeNew, smoothstep(progress))
    /// straight into the drawable, via internal shader effect 41.
    private func encodeBlend(_ cmd: MTLCommandBuffer, final: MTLRenderPassDescriptor,
                             newTex: MTLTexture, oldTex: MTLTexture,
                             progress: Float, size: CGSize) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: final) else { return }
        enc.setRenderPipelineState(pipeline)
        var u = FXUniforms()
        u.resolution = simd_float2(Float(size.width), Float(size.height))
        u.effect = 41
        u.p0 = simd_float4(progress, 0, 0, 0)
        u.srcSize = simd_float2(Float(newTex.width), Float(newTex.height))
        enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        enc.setFragmentTexture(newTex, index: 0)
        enc.setFragmentTexture(glyphs ?? dummy, index: 1)
        let planets = planetTextures(for: u.effect)
        enc.setFragmentTexture(planets.earthDay, index: 2)
        enc.setFragmentTexture(planets.earthNight, index: 3)
        enc.setFragmentTexture(planets.planets, index: 4)
        enc.setFragmentTexture(oldTex, index: 5)
        enc.setFragmentTexture(dummy, index: 6)
        enc.setFragmentTexture(dummy, index: 7)
        enc.setFragmentTexture(dummy, index: 8)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Encode the full source→effects pass chain. Last pass writes into `finalDescriptor`.
    private func encodePasses(_ cmd: MTLCommandBuffer, finalDescriptor: MTLRenderPassDescriptor,
                              pingA: MTLTexture, pingB: MTLTexture, size: CGSize, time: Float,
                              preset: Preset, source: SourceSpec, sourceTex: MTLTexture?,
                              slides: SlideFrame? = nil,
                              packedUniforms packed: [FXUniforms]? = nil) {
        let res = simd_float2(Float(size.width), Float(size.height))
        let useGradient = (source.kind == .gradient) || (sourceTex == nil)
        let effects = preset.effects.filter { $0.enabled }
        let passCount = 1 + effects.count
        let pong = [pingA, pingB]

        for i in 0..<passCount {
            let isLast = (i == passCount - 1)
            let input: MTLTexture = (i == 0) ? (sourceTex ?? dummy) : pong[(i - 1) % 2]
            let inst: EffectInstance? = (i == 0) ? nil : effects[i - 1]

            // Serial dither (error diffusion / Riemersma) runs a compute pass first,
            // producing a coarse grid that the blit pass (effect 38) upscales.
            var fragInput = input
            var serialBlit = false
            if let inst = inst, isSerialDither(inst), ditherWavePSO != nil {
                encodeSerialDither(cmd, inst: inst, input: input, size: size)
                if let g = gridTex { fragInput = g; serialBlit = true }
            }

            let rpd: MTLRenderPassDescriptor
            if isLast {
                rpd = finalDescriptor
            } else {
                rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = pong[i % 2]
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
            }

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setRenderPipelineState(pipeline)

            // Start from the pre-packed uniforms (effect id, params, palette) when the
            // caller supplied them; thumbnails of arbitrary presets pack per pass below.
            let havePacked = (packed?.count == effects.count)
            var u = (havePacked && i > 0 && !serialBlit) ? packed![i - 1] : FXUniforms()
            u.resolution = res
            u.time = time
            u.glyphCount = Int32(GlyphAtlas.count)
            let wall = clockOverride ?? Date()
            (u.clock, u.date) = MetalRenderer.wallClock(wall)
            u.srcSize = simd_float2(Float(fragInput.width), Float(fragInput.height))
            u.fillMode = Int32(source.fillMode)

            if i == 0 {
                if useGradient {
                    u.effect = 1
                    u.p0 = simd_float4(Float(source.gradientAngle), Float(source.gradientDrift), 0, 0)
                    u.colorA = source.colorA.simd
                    u.colorB = source.colorB.simd
                } else if let s = slides {
                    // Slideshow: fillMode 3 = two Ken Burns-framed photos, A (slot 0)
                    // cross-fading into B (slot 5). p0 = (zoomA, panA, mix), p1 = (zoomB, panB).
                    u.effect = 0
                    u.fillMode = 3
                    u.srcSize = simd_float2(Float(s.texA.width), Float(s.texA.height))
                    u.p0 = simd_float4(s.kbA.x, s.kbA.y, s.kbA.z, s.texB == nil ? 0 : s.mix)
                    u.p1 = s.kbB
                    u.p2 = simd_float4(Float(s.texB?.width ?? 1), Float(s.texB?.height ?? 1), 0, 0)
                } else {
                    u.effect = 0   // passthrough source-fit
                    u.srcSize = simd_float2(Float(sourceTex?.width ?? input.width),
                                            Float(sourceTex?.height ?? input.height))
                }
            } else if serialBlit {
                u.effect = 38                      // upscale the precomputed dither grid
                u.p0 = simd_float4(Float(gridW), Float(gridH), Float(gridCell), 0)
            } else {
                if !havePacked { inst!.pack(into: &u) }
                if inst!.kind == .universe {
                    let a = cachedAstro()
                    u.p1 = simd_float4(a.sun.x, a.sun.y, a.sun.z, 0)
                    let orbits: Float = (inst!.params["orbits"] ?? 1) > 0.5 ? 1 : 0
                    u.p2 = simd_float4(a.userLon, a.userLat, a.hasLoc ? 1 : 0, orbits)
                }
                MetalRenderer.fillLiveSky(&u, inst: inst!, now: wall, time: time, location: location)
                if inst!.kind == .nowPlaying {
                    fillMusic(&u, options: MusicSceneOptions(inst!), size: size, now: CACurrentMediaTime(), wall: wall)
                }
            }

            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            enc.setFragmentTexture(fragInput, index: 0)
            enc.setFragmentTexture(glyphs ?? dummy, index: 1)
            let planets = planetTextures(for: u.effect)
            enc.setFragmentTexture(planets.earthDay, index: 2)
            enc.setFragmentTexture(planets.earthNight, index: 3)
            enc.setFragmentTexture(planets.planets, index: 4)
            // fadePrev: real only during a preset crossfade, or the slideshow's incoming photo.
            enc.setFragmentTexture((i == 0 ? slides?.texB : nil) ?? dummy, index: 5)
            enc.setFragmentTexture(TextAtlas.texture(device, effect: u.effect) ?? dummy, index: 6)
            // musicArt / musicArtPrev: real only for the Now Playing pass.
            let music = u.effect == EffectKind.nowPlaying.shaderID
            enc.setFragmentTexture((music ? musicArtTex : nil) ?? dummy, index: 7)
            enc.setFragmentTexture((music ? musicArtPrevTex : nil) ?? dummy, index: 8)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    // MARK: Astronomy (Universe effect)

    /// Local wall-clock time + date for clock/time-aware scenes (see FXUniforms.clock/.date).
    static func wallClock(_ now: Date = Date()) -> (simd_float4, simd_float4) {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: now)
        let sec = Float(c.second ?? 0) + Float(c.nanosecond ?? 0) / 1e9
        let min = Float(c.minute ?? 0) + sec / 60
        let hour = Float(c.hour ?? 0) + min / 60
        let doy = Float(cal.ordinality(of: .day, in: .year, for: now) ?? 1)
        return (simd_float4(hour, min, sec, Float(c.weekday ?? 1)),
                simd_float4(Float(c.year ?? 2026), Float(c.month ?? 1), Float(c.day ?? 1), doy))
    }

    /// Live sun direction (view space) + the user's longitude, from the wall clock and
    /// the Mac's time zone — no Location permission needed.
    static func astro(location: (lat: Double, lon: Double)?) -> (sun: simd_float3, userLon: Float, userLat: Float, hasLoc: Bool) {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        let utcH = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0 + Double(c.second ?? 0) / 3600.0
        let doy = Double(cal.ordinality(of: .day, in: .year, for: now) ?? 1)
        let decl = 23.44 * .pi / 180.0 * sin(2.0 * .pi * (284.0 + doy) / 365.0)   // solar declination
        let subLon = (12.0 - utcH) * 15.0 * .pi / 180.0                            // subsolar longitude
        // Longitude from the resolved location, else from the Mac's time zone.
        let userLonDeg = location?.lon ?? (Double(TimeZone.current.secondsFromGMT()) / 3600.0 * 15.0)
        let userLon = userLonDeg * .pi / 180.0
        let userLat = (location?.lat ?? 0.0) * .pi / 180.0
        let rel = subLon - userLon
        let sun = simd_float3(Float(cos(decl) * sin(rel)), Float(sin(decl)), Float(cos(decl) * cos(rel)))
        return (sun, Float(userLon), Float(userLat), location != nil)
    }

    /// Solar elevation (radians) at the user's location right now, derived from
    /// astro()'s sun vector: sin(alt) = sinφ·sun.y + cosφ·sun.z. Negative below the
    /// horizon; −0.833° is conventional sunset (refraction + solar radius).
    static func solarElevation(location: (lat: Double, lon: Double)?) -> Double {
        let a = astro(location: location)
        let s = Double(sin(a.userLat)) * Double(a.sun.y) + Double(cos(a.userLat)) * Double(a.sun.z)
        return asin(max(-1, min(1, s)))
    }

    // MARK: Live sky (Ocean Horizon "Follow the Sun")

    /// Fills u.sun / u.moon / u.sky for an Ocean Horizon following the real sun; leaves
    /// them zero for anything else. Time Lapse (minutes per simulated day, 0 = real time)
    /// runs the clock forward from `now` by the scene's own time.
    static func fillLiveSky(_ u: inout FXUniforms, inst: EffectInstance, now: Date, time: Float,
                            location: (lat: Double, lon: Double)?) {
        guard inst.kind == .oceanHorizon, (inst.params["live"] ?? 0) > 0.5 else { return }
        let lapse = inst.params["lapse"] ?? 0
        let rate = lapse > 0.05 ? 1440.0 / lapse : 1.0           // simulated s per real s
        let date = now.addingTimeInterval(Double(time) * (rate - 1))
        let s = liveSky(at: date, location: location)
        u.sun = s.sun; u.moon = s.moon; u.sky = s.sky
    }

    /// Low-precision sun and moon for `date` (NOAA / Meeus-style mean elements, ~0.01° sun,
    /// ~0.3° moon — sunrise/sunset good to a minute or two). Without a resolved location it
    /// assumes 40° N on the time zone's meridian, like astro().
    static func liveSky(at date: Date, location: (lat: Double, lon: Double)?)
        -> (sun: simd_float4, moon: simd_float4, sky: simd_float4) {
        let d2r = Double.pi / 180
        func wrapPi(_ x: Double) -> Double { let a = fmod(fmod(x + .pi, 2 * .pi) + 2 * .pi, 2 * .pi); return a - .pi }
        // Hour angle at which a body of declination `dec` crosses altitude h0 (0…π; π = never sets, 0 = never rises).
        func halfArc(_ lat: Double, _ dec: Double, _ h0: Double) -> Double {
            acos(max(-1, min(1, (sin(h0) - sin(lat) * sin(dec)) / max(cos(lat) * cos(dec), 1e-9))))
        }
        // Atmospheric refraction (Bennett), faded out below −1° so it stays continuous.
        func refracted(_ h: Double) -> Double {
            let hd = max(h / d2r, -1)
            let r = 1.02 / tan((hd + 10.3 / (hd + 5.11)) * d2r) / 60 * d2r
            return h + r * max(0, min(1, 1 + (h / d2r + 1) / 2))
        }
        let latDeg = location?.lat ?? 40
        let lonDeg = location?.lon ?? (Double(TimeZone.current.secondsFromGMT(for: date)) / 3600 * 15)
        let lat = latDeg * d2r
        let n = date.timeIntervalSince1970 / 86400 - 10957.5           // days since J2000.0
        let eps = (23.439 - 4e-7 * n) * d2r
        let lst = (280.46061837 + 360.98564736629 * n + lonDeg) * d2r

        // Sun: mean longitude + equation of centre → ecliptic longitude → RA/Dec.
        let L = (280.460 + 0.9856474 * n) * d2r, g = (357.528 + 0.9856003 * n) * d2r
        let lamS = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * d2r
        let raS = atan2(cos(eps) * sin(lamS), cos(lamS)), decS = asin(sin(eps) * sin(lamS))
        let Hs = wrapPi(lst - raS)
        let hs = asin(sin(lat) * sin(decS) + cos(lat) * cos(decS) * cos(Hs))

        // Moon: mean elements + the six largest periodic terms, topocentric parallax.
        let Lm = (218.316 + 13.176396 * n) * d2r, Mm = (134.963 + 13.064993 * n) * d2r
        let F = (93.272 + 13.229350 * n) * d2r, D = (297.850 + 12.190749 * n) * d2r
        let lamM = Lm + (6.289 * sin(Mm) + 1.274 * sin(2 * D - Mm) + 0.658 * sin(2 * D) + 0.214 * sin(2 * Mm)
                         - 0.186 * sin(g) - 0.114 * sin(2 * F)) * d2r
        let betM = (5.128 * sin(F) + 0.281 * sin(Mm + F) + 0.278 * sin(Mm - F) + 0.173 * sin(2 * D - F)) * d2r
        let dist = 385001 - 20905 * cos(Mm)                              // km
        let xm = cos(betM) * cos(lamM), ym = cos(betM) * sin(lamM), zm = sin(betM)
        let raM = atan2(ym * cos(eps) - zm * sin(eps), xm), decM = asin(ym * sin(eps) + zm * cos(eps))
        let Hm = wrapPi(lst - raM)
        var hm = asin(sin(lat) * sin(decM) + cos(lat) * cos(decM) * cos(Hm))
        hm -= asin(6378.0 / dist) * cos(hm)
        // Elongation from the sun, 0…2π (past π = waning).
        var elong = acos(max(-1, min(1, cos(betM) * cos(lamM - lamS))))
        if wrapPi(lamM - lamS) < 0 { elong = 2 * .pi - elong }

        return (simd_float4(Float(refracted(hs)), Float(Hs), Float(halfArc(lat, decS, -0.833 * d2r)), Float(lat)),
                simd_float4(Float(refracted(hm)), Float(Hm), Float(halfArc(lat, decM, 0.125 * d2r)), Float(elong)),
                simd_float4(Float(wrapPi(lst)), 1, 0, 0))
    }

    // MARK: Error-diffusion dither (compute)

    private func isSerialDither(_ inst: EffectInstance) -> Bool {
        inst.kind == .dither && Int((inst.params["algo"] ?? 1).rounded()) >= 4
    }

    /// Whole-pixel cell size for an error-diffusion dither: "Pixel Size" is in pixels of a
    /// 1000-px-tall frame, so the pattern keeps its scale from a thumbnail to 5K (it used to
    /// collapse to whatever a 130k-cell cap allowed, at a fractional size that beat).
    static func ditherCellPixels(cell: Double, size: CGSize) -> Int {
        let k = max(size.height, 1) / 1000
        var cp = max(1, Int((max(cell, 1) * k).rounded()))
        // Keep the grid small enough for one threadgroup's wavefront to stay ~1 ms.
        while Double(cp * cp) * 600_000 < Double(size.width * size.height) { cp += 1 }
        return cp
    }

    private func ensureGrid(_ w: Int, _ h: Int) {
        if gridTex?.width == w, gridTex?.height == h, errBuf != nil { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        gridTex = device.makeTexture(descriptor: d)
        // Five half4 per cell (see dither_prep): error, persistent level + input, input, level,
        // held-back error.
        errBuf = device.makeBuffer(length: max(w * h, 1) * 5 * 8, options: .storageModePrivate)
        ditherHistoryKey = nil
    }

    private func encodeSerialDither(_ cmd: MTLCommandBuffer, inst: EffectInstance, input: MTLTexture, size: CGSize) {
        guard let prep = ditherPrepPSO, let wave = ditherWavePSO, let riem = ditherRiemPSO,
              let relax = ditherRelaxPSO, let final = ditherFinalPSO else { return }
        let cp = MetalRenderer.ditherCellPixels(cell: Double(inst.g("cell")), size: size)
        let gw = max(1, Int((size.width / CGFloat(cp)).rounded(.up)))
        let gh = max(1, Int((size.height / CGFloat(cp)).rounded(.up)))
        ensureGrid(gw, gh)
        guard let gridTex = gridTex, let errBuf = errBuf else { return }
        var u = FXUniforms()
        u.resolution = simd_float2(Float(size.width), Float(size.height))
        inst.pack(into: &u)                        // p0 = (cell, levels, mono, algo), colorA/B
        let key: [Float] = [u.p0.x, u.p0.y, u.p0.z, u.p0.w, u.colorA.x, u.colorA.y, u.colorA.z,
                            u.colorB.x, u.colorB.y, u.colorB.z, Float(cp), Float(gw), Float(gh)]
        if key != ditherHistoryKey, let bl = cmd.makeBlitCommandEncoder() {
            bl.fill(buffer: errBuf, range: 0..<errBuf.length, value: 0)   // no history
            bl.endEncoding()
            ditherHistoryKey = key
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        let algo = Int((inst.params["algo"] ?? 4).rounded())
        let riemersma = algo == 16
        u.p1 = simd_float4(Float(riemersma ? 100 : algo - 4), Float(gw), Float(gh), Float(cp))
        u.p2 = MetalRenderer.ditherTuning
        enc.setBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        enc.setTexture(input, index: 0)
        enc.setTexture(gridTex, index: 1)
        enc.setBuffer(errBuf, offset: 0, index: 1)
        enc.setSamplerState(sampler, index: 0)
        let cells = MTLSize(width: (gw + 15) / 16, height: (gh + 15) / 16, depth: 1)
        let tile = MTLSize(width: 16, height: 16, depth: 1)
        enc.setComputePipelineState(prep)
        enc.dispatchThreadgroups(cells, threadsPerThreadgroup: tile)
        if riemersma {
            var side = 1
            while side < gw || side < gh { side <<= 1 }
            let chunks = (side * side + 255) / 256
            enc.setComputePipelineState(riem)
            enc.dispatchThreadgroups(MTLSize(width: (chunks + 63) / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        } else {
            // One threadgroup: rows run as a wavefront, a band of `t` rows at a time.
            let t = min(gh, wave.maxTotalThreadsPerThreadgroup, 1024)
            enc.setComputePipelineState(wave)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: t, height: 1, depth: 1))
        }
        // Relax chained dots, 9 interleaved phases (see dither_relax), then write the grid.
        enc.setComputePipelineState(relax)
        let thirds = MTLSize(width: (gw + 47) / 48, height: (gh + 47) / 48, depth: 1)
        for phase in 0..<9 {
            var ph = UInt32(phase)
            enc.setBytes(&ph, length: 4, index: 2)
            enc.dispatchThreadgroups(thirds, threadsPerThreadgroup: tile)
        }
        enc.setComputePipelineState(final)
        enc.dispatchThreadgroups(cells, threadsPerThreadgroup: tile)
        enc.endEncoding()
        gridW = gw; gridH = gh; gridCell = cp
    }
    /// (hysteresis in levels, sharpen, threshold jitter, relax margin) — see dither_prep.
    static let ditherTuning = simd_float4(0.5, 0.35, 0.18, 0.5)

    // MARK: Thumbnails (offscreen, one frame, synchronous)

    func renderThumbnail(preset: Preset, source: SourceSpec, width: Int, height: Int, time: Float = 1.2,
                         sourceTexOverride: MTLTexture? = nil) -> CGImage? {
        let fmt: MTLPixelFormat = .bgra8Unorm
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        let (a, b) = makeOffscreen(width: width, height: height, format: fmt)
        guard let pingA = a, let pingB = b else { return nil }

        // Final target must be CPU-readable.
        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
        fd.usage = [.shaderRead, .renderTarget]
        fd.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: fd) else { return nil }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = outTex
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        desc.colorAttachments[0].storeAction = .store

        // Load an image source synchronously; video passes a poster frame via
        // sourceTexOverride (see Thumbnailer); gradient renders the fallback.
        var thumbTex: MTLTexture? = sourceTexOverride
        if thumbTex == nil, source.kind == .image, let name = source.mediaFilename {
            thumbTex = ImageSource(url: store.mediaURL(name), device: device)?.currentTexture()
        }
        // Slideshow: the frame at `time`, photos decoded on the spot.
        var slides: SlideFrame?
        if thumbTex == nil, source.kind == .collection, !preset.isScene {
            slides = thumbCollection(for: source, width: width, height: height)?.frame(at: Double(time), sync: true)
            thumbTex = slides?.texA
        }

        // Now Playing: the current artwork, settled (no cross-fade in a still).
        if preset.isMusicScene {
            prepareMusic(cmd, now: CACurrentMediaTime(), wall: clockOverride ?? Date(), fade: false)
        }

        encodePasses(cmd, finalDescriptor: desc, pingA: pingA, pingB: pingB,
                     size: CGSize(width: width, height: height), time: time,
                     preset: preset, source: source, sourceTex: thumbTex, slides: slides)
        cmd.commit()
        cmd.waitUntilCompleted()
        return readBack(outTex)
    }

    /// A finished, CPU-readable BGRA8 render target as a CGImage.
    private func readBack(_ outTex: MTLTexture) -> CGImage? {
        let width = outTex.width, height = outTex.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        outTex.getBytes(&bytes, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
