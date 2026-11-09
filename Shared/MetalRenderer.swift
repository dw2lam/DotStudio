//  MetalRenderer.swift — renders a Preset as a chain of fullscreen shader passes.

import Metal
import MetalKit
import simd
import QuartzCore

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// The format the live passes draw in (the view's / layer's).
    private let pixelFormat: MTLPixelFormat
    private var veilDownPipeline: MTLRenderPipelineState?
    private var veilPipeline: MTLRenderPipelineState?
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
    /// The instance time base's slideshow origin: when the source was applied. Unlike
    /// `startTime` it never wraps, so the hourly wrap never moves the slideshow.
    private var slideOrigin: CFTimeInterval = CACurrentMediaTime()
    /// Which chain the current time origin belongs to: bumped whenever a fade parks the
    /// current chain as `outgoing`, so per-chain state (weather cloud drift) stays with its chain.
    private var chainID = 0
    private var loggedFirstFrame = false

    /// What the animation time `t` counts from.
    enum TimeBase: Equatable {
        /// Seconds since this renderer applied its current source (the default): every
        /// preview, saver and wallpaper instance starts its own motion from zero. Like the
        /// wall clock it wraps every `wallClockPeriod` (behind the same 2 s crossfade), so a
        /// saver left running for days never feeds the shaders a coarse Float time.
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
            if preset != nil, outgoing == nil, drewOnce {
                // The outgoing chain keeps the OLD clock: captured before the origin moves.
                beginFade(now: now, duration: 1.0, wallSlides: oldValue == .wallClock)
            }
            if timeBase == .wallClock { syncWallClockOrigin(now, allowWrapFade: false) }
            else { slideOrigin = startTime }       // the slideshow carries on from the same origin
        }
    }
    private var drewOnce = false

    // Cap frames-in-flight so drawables/IOSurfaces are recycled rather than queued up.
    private let inFlight = DispatchSemaphore(value: 2)
    /// Zen Garden's planned cart paths and data textures, per configuration on screen (SandGarden in Studio2.swift).
    let sandGardens = SandGarden.Cache()

    // Render description
    private(set) var preset: Preset?
    private var source = SourceSpec()
    private var media: MediaSource?
    private var collection: CollectionSource?           // .collection sources (slideshow)
    // Thumbnail/export slideshows (no eviction), keyed by decode size class.
    private var thumbCollections: [Int: CollectionSource] = [:]
    private let store: SharedStore
    private lazy var weatherLink = WeatherLink(baseDir: store.baseDir)   // Shared/Weather
    var location: (lat: Double, lon: Double)?      // resolved device location (Universe marker, live sky)
    /// Renders as if the wall clock read this instead of now (offscreen gallery only).
    var clockOverride: Date?
    /// Tools only (gallery --checks): the wall clock the time base reads runs this far ahead,
    /// so an hourly wrap can be put a moment away.
    var timeBaseSkew: TimeInterval = 0
    private func timeBaseEpoch() -> Double { Date().timeIntervalSince1970 + timeBaseSkew }
    /// Tools only: puts the instance time base's t at `t` now.
    func setInstanceTime(_ t: Double) { startTime = CACurrentMediaTime() - t }

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
        /// Its instance slideshow's origin (see `slideOrigin`).
        let slideOrigin: CFTimeInterval
        /// Its slideshow ran on the wall clock (see `slideClock`).
        let wallSlides: Bool
        /// Its `chainID`.
        let chain: Int
    }
    private var outgoing: Outgoing?
    /// A preset switch asked for while a same-preset fade (the hourly wrap, a time-base
    /// switch) was in flight: started as soon as that fade ends (see `transition`).
    private var pendingTransition: (preset: Preset, source: SourceSpec, duration: Double)?

    /// Parks the current chain — preset, uniforms, time origins — as `outgoing` and starts a
    /// crossfade from it; whatever is drawn next is a new chain.
    private func beginFade(now: CFTimeInterval, duration: Double, wallSlides: Bool) {
        guard let p = preset else { return }
        outgoing = Outgoing(preset: p, packed: packedUniforms, startTime: startTime, slideOrigin: slideOrigin,
                            wallSlides: wallSlides, chain: chainID)
        chainID &+= 1
        transitionBegan = now
        transitionDuration = duration
    }
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

    // Music backdrop (Full Screen music, MusicPresentation): eased between 0 (the plain style)
    // and 1 (fully behind the music). `musicBackdropKind` is what's drawn while the amount is
    // above 0 — kept through a fade-out after the target went back to `.none`.
    private var musicBackdropTarget: MusicBackdrop = .none
    private var musicBackdropKind: MusicBackdrop = .none
    private var musicBackdropFrom: Double = 0
    private var musicBackdropTo: Double = 0
    private var musicBackdropBegan: CFTimeInterval = -.infinity
    /// Tools only (the gallery's transition frames): draw the backdrop at exactly this amount.
    var musicBackdropAmountOverride: Double?
    /// The veil's Kawase pyramid (level k = 1/2^k of the frame) and the Album Art backdrop
    /// while it cross-fades with the style. Freed once the backdrop is fully in or out.
    private var veilLevels: [MTLTexture] = []
    private var veilArt: MTLTexture?
    /// While Album Art fades out after music stopped: hold the last cover and palette rather
    /// than fading to the idle glow at the same time.
    private var musicArtHeld = false

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
        self.pixelFormat = pixelFormat
        WeatherLink.adopt(library, device: device)      // its pipelines use this metallib too
        // The music veil's own small passes (Shaders.metal, "music veil").
        func veilPSO(_ name: String) -> MTLRenderPipelineState? {
            guard let f = library.makeFunction(name: name) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = pixelFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        veilDownPipeline = veilPSO("fx_veil_down")
        veilPipeline = veilPSO("fx_veil")

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
        pendingTransition = nil                    // this supersedes a switch still waiting
        if preset != self.preset { WeatherLink.prewarm(for: preset, device: device, format: pixelFormat) }
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
            if timeBase == .instance { startTime = CACurrentMediaTime(); slideOrigin = startTime }
            loadMedia(for: source)
        }
        ditherHistoryKey = nil
    }

    /// The animation time (seconds) a frame drawn at `now` would use, per the time base.
    /// With `.wallClock` every renderer on the Mac returns the same value at the same moment.
    /// Read-only: it never moves the origin a frame's wrap crossfade is detected against.
    func animationTime(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        timeBase == .wallClock ? Self.wallPhase(timeBaseEpoch()) : now - startTime
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
        let origin = now - Self.wallPhase(timeBaseEpoch())
        if allowWrapFade, abs(origin - startTime) > 0.25, preset != nil {
            // Another fade (a style change) in flight: the wrap waits for it to end, t running
            // on past the period meanwhile, rather than jumping under a chain on screen.
            if outgoing != nil { return }
            // The outgoing chain keeps counting past the period for the 2 s fade.
            beginFade(now: now, duration: 2.0, wallSlides: true)
        }
        startTime = origin
    }

    /// Instance time base: wrap t every `wallClockPeriod`, behind the same 2 s crossfade as the
    /// wall clock's (deferred while another fade is in flight), so it stays a precise Float.
    private func wrapInstanceOrigin(_ now: CFTimeInterval, allowFade: Bool) {
        let p = Self.wallClockPeriod
        guard now - startTime >= p else { return }
        if allowFade, preset != nil {
            if outgoing != nil { return }
            beginFade(now: now, duration: 2.0, wallSlides: false)
        }
        startTime += p * ((now - startTime) / p).rounded(.down)
    }

    /// The slideshow timeline a chain shows: on the wall clock, full-precision epoch seconds
    /// with a fixed photo order (seed 0), so every synced renderer shows the same photo with
    /// the same Ken Burns framing and the hourly wrap never touches it; otherwise the
    /// instance time with this source's own random first photo.
    private func slideClock(wall: Bool, origin: CFTimeInterval, now: CFTimeInterval, epoch: Double) -> SlideClock {
        wall ? SlideClock(t: epoch, seed: 0) : SlideClock(t: now - origin, seed: nil)
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
        // Nothing playing (or paused past the linger) shows the idle background — except while
        // an Album Art backdrop fades out, which keeps the cover it had.
        if musicArtHeld && musicPrepared { return }
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
        let visible = musicArtHeld || snap.state?.isVisible(at: wall, lingerMinutes: musicLingerMinutes) == true
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

    // MARK: Music backdrop (Full Screen music)

    /// How long the backdrop eases in and out — the overlay's full-screen fade matches it
    /// (MusicOverlayLayer.fullFadeSeconds).
    static let musicBackdropSeconds: Double = 1.4

    /// What to draw behind Full Screen music (MusicPresentation.backdrop). The change eases
    /// over `musicBackdropSeconds` from wherever the current one is (a reversal mid-fade
    /// turns around smoothly); `animated: false` jumps. Switching between two backdrops while
    /// one is up (a settings change) swaps them in place.
    func setMusicBackdrop(_ b: MusicBackdrop, animated: Bool = true) {
        guard b != musicBackdropTarget else { return }
        let now = CACurrentMediaTime()
        let current = musicBackdropAmount(at: now)
        musicBackdropTarget = b
        if b != .none { musicBackdropKind = b }
        musicBackdropTo = b == .none ? 0 : 1
        musicBackdropFrom = animated ? current : musicBackdropTo
        musicBackdropBegan = animated ? now : -.infinity
    }

    /// 0 = the plain style … 1 = fully behind the music, eased (smoothstep — the overlay's
    /// ease-in-ease-out to within a frame).
    private func musicBackdropAmount(at now: CFTimeInterval) -> Double {
        if let o = musicBackdropAmountOverride { return min(max(o, 0), 1) }
        let k = min(max((now - musicBackdropBegan) / Self.musicBackdropSeconds, 0), 1)
        let e = k * k * (3 - 2 * k)
        return musicBackdropFrom + (musicBackdropTo - musicBackdropFrom) * e
    }

    /// The veil's blur, in Kawase levels: enough that the coarsest is ~`veilTexels` tall at
    /// any resolution (fractional — the composite blends the two nearest levels), so the
    /// blur looks the same from a gallery tile to 6K.
    static let veilTexels: Double = 42
    static func veilBlurLevels(height: Int) -> Double { max(log2(Double(max(height, 1)) / veilTexels), 1) }

    /// The pyramid for a `w`×`h` frame, levels 1…n (reused while the size holds).
    private func veilPyramid(_ w: Int, _ h: Int, levels n: Int, format: MTLPixelFormat,
                             reuse: [MTLTexture]) -> [MTLTexture] {
        var out: [MTLTexture] = []
        for k in 1...max(n, 1) {
            let lw = max((w + (1 << k) - 1) >> k, 1), lh = max((h + (1 << k) - 1) >> k, 1)
            if k - 1 < reuse.count, reuse[k - 1].width == lw, reuse[k - 1].height == lh,
               reuse[k - 1].pixelFormat == format {
                out.append(reuse[k - 1]); continue
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: lw, height: lh, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { break }
            out.append(t)
        }
        return out
    }

    /// One internal pass (73, the music veil: its own fragment functions) into `target`.
    private func encodeVeilPass(_ cmd: MTLCommandBuffer, target: MTLRenderPassDescriptor, size: CGSize,
                                u inU: FXUniforms, src: MTLTexture, next: MTLTexture?, art: MTLTexture?) {
        let down = inU.p0.w > 0.5
        guard let pso = down ? veilDownPipeline : veilPipeline,
              let enc = cmd.makeRenderCommandEncoder(descriptor: target) else { return }
        var u = inU
        u.effect = 73
        u.resolution = simd_float2(Float(size.width), Float(size.height))
        u.srcSize = simd_float2(Float(src.width), Float(src.height))
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentTexture(next ?? dummy, index: 5)
        enc.setFragmentTexture(art ?? dummy, index: 8)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The veil over `style` into `final`: a Kawase pyramid of the frame (only as deep as
    /// this amount's blur needs), then one full-size composite that blends the two nearest
    /// levels (progressive blur while it eases in), dims in linear light with a soft
    /// highlight compression (a bright Look lands as low as a dark scene), vignettes, and —
    /// for Album Art — cross-fades into `art`.
    private func encodeVeil(_ cmd: MTLCommandBuffer, style: MTLTexture, final: MTLRenderPassDescriptor,
                            size: CGSize, amount: Double, art: MTLTexture?, pyramid: inout [MTLTexture]) {
        let w = Int(size.width), h = Int(size.height)
        let blur = amount * Self.veilBlurLevels(height: h)
        let need = Int(ceil(blur - 1e-6))
        if need > 0 {
            pyramid = veilPyramid(w, h, levels: need, format: style.pixelFormat, reuse: pyramid)
        }
        let levels = min(need, pyramid.count)
        // Downsample: level k from level k − 1 (level 0 = the frame).
        var down = FXUniforms()
        down.p0 = simd_float4(0, 0, 0, 1)
        for k in 0..<levels {
            let src = k == 0 ? style : pyramid[k - 1]
            let dst = pyramid[k]
            encodeVeilPass(cmd, target: offscreenDescriptor(dst),
                           size: CGSize(width: dst.width, height: dst.height), u: down, src: src, next: nil, art: nil)
        }
        // Composite: blend level ⌊blur⌋ (0 = the sharp frame) with the next.
        let b = min(blur, Double(levels))
        let lo = Int(b.rounded(.down)), frac = b - Double(lo)
        let loTex = lo == 0 ? style : pyramid[lo - 1]
        let hiTex: MTLTexture? = lo < levels ? pyramid[lo] : nil
        var u = FXUniforms()
        u.p0 = simd_float4(Float(amount), Float(hiTex == nil ? 0 : frac), art == nil ? 0 : 1, 0)
        u.p1 = simd_float4(lo == 0 ? 1 : 0, 0, 0, 0)
        encodeVeilPass(cmd, target: final, size: size, u: u, src: loTex, next: hiTex, art: art)
    }

    /// Tools only (gallery --veilbench): GPU milliseconds of the veil's own passes at a size —
    /// the pyramid plus the composite, fully in, over a static frame — the median of `runs`
    /// command buffers of `reps` veils each, from the buffers' GPU timestamps.
    /// `reference: true` times one plain full-size pass instead (the internal crossfade, two
    /// taps) — the floor any full-screen pass pays at this size, to read the veil against.
    func benchmarkVeil(width: Int, height: Int, amount: Double = 1, reference: Bool = false,
                       reps: Int = 24, runs: Int = 12) -> Double {
        let fmt: MTLPixelFormat = .bgra8Unorm
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        guard let src = device.makeTexture(descriptor: d), let dst = device.makeTexture(descriptor: d) else { return -1 }
        let size = CGSize(width: width, height: height)
        var pyramid: [MTLTexture] = []
        var ms: [Double] = []
        for run in 0..<(runs + 3) {
            guard let cmd = queue.makeCommandBuffer() else { return -1 }
            for _ in 0..<reps {
                if reference {
                    encodeBlend(cmd, final: offscreenDescriptor(dst), newTex: src, oldTex: src, progress: 0.5, size: size)
                } else {
                    encodeVeil(cmd, style: src, final: offscreenDescriptor(dst), size: size, amount: amount, art: nil,
                               pyramid: &pyramid)
                }
            }
            cmd.commit()
            cmd.waitUntilCompleted()
            if run >= 3 { ms.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000 / Double(reps)) }
        }
        ms.sort()
        return ms[ms.count / 2]
    }

    private func ensureVeilArt(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let t = veilArt, t.width == width, t.height == height, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width, 1),
                                                         height: max(height, 1), mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        veilArt = device.makeTexture(descriptor: d)
        return veilArt
    }

    /// Switch presets with a GPU crossfade. Falls back to a hard cut when there's
    /// nothing to fade from (first apply) or the duration is negligible.
    func transition(to preset: Preset, source: SourceSpec, duration: Double) {
        guard duration > 0.05, let current = self.preset else {
            apply(preset, source: source)
            return
        }
        let now = CACurrentMediaTime()
        // A same-preset fade in flight (the hourly wrap — a rotation lands on the hour — or a
        // time-base switch) shows one style at two times: replacing its outgoing chain would cut
        // away the one mostly on screen. Let it finish; this switch starts when it ends.
        if let out = outgoing, out.preset == current, now - transitionBegan < transitionDuration {
            pendingTransition = (preset, source, duration)
            return
        }
        beginFade(now: now, duration: duration, wallSlides: timeBase == .wallClock)
        apply(preset, source: source)   // shared global source ⇒ no media reload mid-fade
    }

    /// Starts a switch `transition` held back, once the fade it waited for is over (or at
    /// once, without a fade, for a held frame).
    private func startPendingTransition(_ now: CFTimeInterval, settled: Bool) {
        guard let p = pendingTransition,
              settled || outgoing == nil || now - transitionBegan >= transitionDuration else { return }
        pendingTransition = nil
        outgoing = nil
        if settled { apply(p.preset, source: p.source) }
        else { transition(to: p.preset, source: p.source, duration: p.duration) }
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
        startPendingTransition(CACurrentMediaTime(), settled: settled)
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
        else { wrapInstanceOrigin(now, allowFade: drewOnce && !settled) }
        drewOnce = true
        let t = Float(now - startTime)
        // Full Screen music's backdrop: a held frame shows where its ease ends.
        if settled, musicBackdropAmountOverride == nil {
            musicBackdropFrom = musicBackdropTo
            musicBackdropBegan = -.infinity
        }
        let backdrop = musicBackdropAmount(at: now)
        if backdrop <= 0, musicBackdropTo <= 0, musicBackdropAmountOverride == nil {
            musicBackdropKind = .none                  // fully out: free the veil's textures
            veilLevels = []
            veilArt = nil
        }
        var artPreset: Preset?
        if backdrop > 0, case .albumArt(let layout) = musicBackdropKind {
            artPreset = MusicPresentation.albumArtPreset(layout)
        }
        // Album Art fading out after the music stopped keeps the cover it had.
        musicArtHeld = artPreset != nil && musicBackdropTo <= 0
        // Now Playing (a style, or the Album Art backdrop): poll / upload artwork before any
        // pass samples it.
        if preset.isMusicScene || (outgoing?.preset.isMusicScene ?? false) || artPreset != nil {
            prepareMusic(cmd, now: now, wall: clockOverride ?? Date(), fade: !settled)
        } else {
            releaseMusic()
        }
        // Album Art fully up: the style is hidden behind it, so only the art is drawn.
        if let art = artPreset, backdrop >= 1 {
            veilArt = nil
            veilLevels = []
            if outgoing != nil, now - transitionBegan >= transitionDuration {
                outgoing = nil                   // a style change behind the art finished unseen
                fadeOld = nil; fadeNew = nil
            }
            encodePasses(cmd, finalDescriptor: final, pingA: texA, pingB: texB, size: drawableSize, time: t,
                         preset: art, source: SourceSpec(), sourceTex: nil)
            if let drawable {
                if let onPresented { drawable.addPresentedHandler { onPresented($0.presentedTime) } }
                cmd.present(drawable)
            }
            cmd.commit()
            return cmd
        }
        // Easing in or out of the Album Art: draw it first (it uses the ping-pong textures the
        // style then reuses), into its own texture for the veil's composite.
        var artTex: MTLTexture?
        if let art = artPreset,
           let tex = ensureVeilArt(width: Int(ds.width), height: Int(ds.height), format: format) {
            encodePasses(cmd, finalDescriptor: offscreenDescriptor(tex), pingA: texA, pingB: texB,
                         size: drawableSize, time: t, preset: art, source: SourceSpec(), sourceTex: nil)
            artTex = tex
        } else {
            veilArt = nil
        }
        // Slideshow state comes from the source clock (see slideClock): both chains of a
        // preset crossfade show the same photo; a time-base switch fades between the two
        // clocks' photos. Scenes ignore the source, so an idle slideshow doesn't decode photos.
        let wantsSource = !preset.isScene || (outgoing.map { !$0.preset.isScene } ?? false)
        var slides: SlideFrame?
        var outSlides: SlideFrame?
        if wantsSource, let c = collection {
            let epoch = timeBaseEpoch()
            let inClock = slideClock(wall: timeBase == .wallClock, origin: slideOrigin, now: now, epoch: epoch)
            let outClock = outgoing.map { slideClock(wall: $0.wallSlides, origin: $0.slideOrigin, now: now, epoch: epoch) }
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

        // Behind Full Screen music the style renders offscreen — into a ping-pong texture its
        // own last pass doesn't read — and the veil composites it into `final`.
        let veiled = backdrop > 0 && veilPipeline != nil && veilDownPipeline != nil
        // encodePasses: pass i < last writes pong[i % 2], the last (i = effects) reads pong[(i − 1) % 2].
        let chainOut = preset.effects.filter(\.enabled).count % 2 == 0 ? texA : texB
        var styleTex: MTLTexture = chainOut
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
                                 slides: outSlides, packedUniforms: out.packed, chain: out.chain)
                    // Incoming chain → fadeNew. The shared ping-pong is safe: the chains
                    // encode sequentially and each result is parked before the next starts.
                    encodePasses(cmd, finalDescriptor: offscreenDescriptor(fn), pingA: texA, pingB: texB,
                                 size: drawableSize, time: t, preset: preset, source: source,
                                 sourceTex: sTex, slides: slides, packedUniforms: packedUniforms, chain: chainID)
                    // Both chains are parked: texA is free for the blend when veiled.
                    encodeBlend(cmd, final: veiled ? offscreenDescriptor(texA) : final, newTex: fn, oldTex: fo,
                                progress: Float(progress), size: drawableSize)
                    styleTex = texA
                    blended = true
                }
            }
        }
        if !blended {
            encodePasses(cmd, finalDescriptor: veiled ? offscreenDescriptor(chainOut) : final, pingA: texA, pingB: texB,
                         size: drawableSize, time: t, preset: preset, source: source,
                         sourceTex: sTex, slides: slides, packedUniforms: packedUniforms, chain: chainID)
        }
        if veiled {
            encodeVeil(cmd, style: styleTex, final: final, size: drawableSize, amount: backdrop,
                       art: artTex, pyramid: &veilLevels)
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
                              packedUniforms packed: [FXUniforms]? = nil, chain: Int = -1) {
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
            var sceneData: MTLTexture?           // a scene's own data in slot 6 (Zen Garden's track and stones)

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
                weatherLink.fill(&u, inst: inst!, time: time, wall: wall, chain: chain,
                                 encoder: enc, format: rpd.colorAttachments[0].texture?.pixelFormat)
                if inst!.kind == .sandGarden { sceneData = sandGardens.prepare(&u, wall: wall, device: device) }
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
            enc.setFragmentTexture(sceneData ?? TextAtlas.texture(device, uniforms: u) ?? dummy, index: 6)
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

    // MARK: Live sky ("Follow the Sun": Ocean Horizon, Shallows, Pleats, Dichroic, Zen Garden; Window Light)

    /// Fills u.sun / u.moon / u.sky for a scene following the real sun (Ocean Horizon, Shallows,
    /// Pleats, Dichroic, Zen Garden in "Follow the Sun", Window Light following the sun); leaves
    /// them zero for anything else. Time Lapse (minutes per simulated day, 0 = real time) runs the
    /// clock forward from `now` by the scene's own time.
    static func fillLiveSky(_ u: inout FXUniforms, inst: EffectInstance, now: Date, time: Float,
                            location: (lat: Double, lon: Double)?) {
        let live = ([.oceanHorizon, .shallows, .pleats, .dichroic, .sandGarden].contains(inst.kind) && (inst.params["live"] ?? 0) > 0.5)
            || (inst.kind == .windowLight && (inst.params["follow"] ?? 1) > 0.5)
        guard live else { return }
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

    /// - musicBackdrop: Full Screen music's backdrop (a still of the screensaver while music
    ///   shows): Album Art draws the living art instead of the style; the veil draws the style
    ///   blurred and dimmed.
    /// - backdropAmount: how far it has eased in (tools render frames of the transition).
    func renderThumbnail(preset inPreset: Preset, source: SourceSpec, width: Int, height: Int, time: Float = 1.2,
                         sourceTexOverride: MTLTexture? = nil, musicBackdrop: MusicBackdrop = .none,
                         backdropAmount: Double = 1) -> CGImage? {
        let fmt: MTLPixelFormat = .bgra8Unorm
        var preset = inPreset
        let amount = musicBackdrop == .none ? 0 : min(max(backdropAmount, 0), 1)
        var artPreset: Preset?
        if case .albumArt(let layout) = musicBackdrop, amount > 0 {
            if amount >= 1 { preset = MusicPresentation.albumArtPreset(layout) }
            else { artPreset = MusicPresentation.albumArtPreset(layout) }
        }
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
            thumbTex = thumbImage(name)?.currentTexture()
        }
        // Slideshow: the frame at `time`, photos decoded on the spot.
        var slides: SlideFrame?
        if thumbTex == nil, source.kind == .collection, !preset.isScene {
            slides = thumbCollection(for: source, width: width, height: height)?.frame(at: Double(time), sync: true)
            thumbTex = slides?.texA
        }

        // Now Playing: the current artwork, settled (no cross-fade in a still).
        if preset.isMusicScene || artPreset != nil {
            prepareMusic(cmd, now: CACurrentMediaTime(), wall: clockOverride ?? Date(), fade: false)
        }

        let size = CGSize(width: width, height: height)
        if amount > 0, artPreset != nil || musicBackdrop == .veil, veilPipeline != nil, veilDownPipeline != nil {
            // The art first (it borrows the ping-pong textures), then the style, then the veil.
            var artTex: MTLTexture?
            if let art = artPreset {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
                d.usage = [.shaderRead, .renderTarget]
                d.storageMode = .private
                if let t = device.makeTexture(descriptor: d) {
                    encodePasses(cmd, finalDescriptor: offscreenDescriptor(t), pingA: pingA, pingB: pingB, size: size,
                                 time: time, preset: art, source: SourceSpec(), sourceTex: nil)
                    artTex = t
                }
            }
            let out = preset.effects.filter(\.enabled).count % 2 == 0 ? pingA : pingB
            encodePasses(cmd, finalDescriptor: offscreenDescriptor(out), pingA: pingA, pingB: pingB,
                         size: size, time: time, preset: preset, source: source, sourceTex: thumbTex, slides: slides)
            var pyramid: [MTLTexture] = []
            encodeVeil(cmd, style: out, final: desc, size: size, amount: amount, art: artTex, pyramid: &pyramid)
        } else {
            encodePasses(cmd, finalDescriptor: desc, pingA: pingA, pingB: pingB, size: size, time: time,
                         preset: preset, source: source, sourceTex: thumbTex, slides: slides)
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return readBack(outTex)
    }

    /// The last image source a thumbnail decoded, by file and modification date: a run of
    /// thumbnails over one photo (every style's card) decodes it once, not once a card.
    private var thumbImageCache: (name: String, modified: Date?, source: ImageSource)?

    private func thumbImage(_ name: String) -> ImageSource? {
        let url = store.mediaURL(name)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let c = thumbImageCache, c.name == name, c.modified == modified { return c.source }
        thumbImageCache = nil                    // drop the old photo before decoding the next
        guard let s = ImageSource(url: url, device: device) else { return nil }
        thumbImageCache = (name, modified, s)
        return s
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
