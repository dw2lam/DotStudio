//  CustomFilm.swift — the `film` engine: a scene package of looping video rendered offline (e.g.
//  by the Blender toolkit), in one of two forms.
//
//  Variant clips (engine 1):
//      "engine": { "id": "film" },
//      "clips": [ { "variant": "day",    "file": "clips/day.mov",    "loop": true },
//                 { "variant": "golden", "file": "clips/golden.mov" },
//                 { "variant": "night",  "file": "clips/night.mov" },
//                 { "variant": "rain",   "file": "clips/rain.mov" } ]
//  The variant follows the real sun (night below −4°, golden hour −4°…8°, day above) and the
//  weather (rain while it rains, if the package has a rain clip), re-checked every few seconds;
//  a change crossfades over 3 s. Each clip plays through VideoSource (AVPlayerLooper: seamless
//  loops, hardware decode, muted), aspect-filled by the film engine's wrapper (Engines/film/1.1/
//  film.metal) — the same runtime-compiled pipeline path as every Custom Scene. One-off renders
//  (thumbnails, the gallery) and the first frames before a clip decodes draw its poster frame.
//
//  Light layers (engine ≥ 1.1, docs/film-layers.md — FilmLayers below):
//      "layers": { "file": "clips/layers.mov", "grid": [3, 2],
//                  "tiles": ["sun", "sun_low", "sky", "cabin", "city", "mask"], "encoding": "pow4",
//                  "scale": {…}, "exposure": { "day": 1.5, "night": 3.2 }, "tint": {…} }
//  One HEVC Main10 video whose frames are a grid of light layers. The engine mixes them with
//  weights from the real sun's elevation and the weather (ds_film_mix and its blurs: passes at
//  the tiles' resolution, run only for a new video frame or light), then the screen pass draws
//  the glass weather through the mask, bloom / halation, vignette, AgX and grain. Any time of day
//  and every weather condition from one render, changing smoothly. The video decodes to its own
//  10-bit Y'CbCr planes (zero-copy, converted in the shader): 8 bits would band the pow4
//  encoding's shadows. A film with an "fps" is drawn at that rate where the display allows
//  (CustomSceneManifest.steppedFPS): its pictures only change that often.
//
//  A style can pin the weather (the engine's "Weather" menu, ds.weather: Live or a condition).
//  Power: the hosts' media pause (MetalRenderer.setMediaPaused: the wallpaper's held stills —
//  Low Power, On Battery Still or Efficient) pauses the video.

import Foundation
import AVFoundation
import Metal
import MetalKit
import QuartzCore
import simd

final class CustomFilm {
    let prepared: PreparedScene
    static let variants = ["day", "golden", "night", "rain", "any"]
    static let fadeSeconds: Double = 3
    static let recheckSeconds: Double = 5

    private struct Playing {
        let clip: CustomSceneManifest.Clip
        let video: VideoSource?
        let poster: MTLTexture?
        /// The clip's frame rate (the grain steps with it).
        let fps: Float
    }
    private var current: Playing?
    private var previous: Playing?
    private var fadeStart: CFTimeInterval = -.infinity
    private var lastCheck: CFTimeInterval = -.infinity
    private var paused = false
    private let lock = NSLock()
    /// The light-layers player (a package with "layers").
    let layers: FilmLayers?

    init(prepared: PreparedScene) {
        self.prepared = prepared
        layers = prepared.manifest.layers.map { FilmLayers(prepared: prepared, layers: $0) }
    }

    /// The sun's variant: night below −4°, golden hour to 8°, day above.
    static func sunVariant(elevation: Double) -> String {
        elevation < -4 ? "night" : elevation < 8 ? "golden" : "day"
    }

    /// The clip to play for this sun and weather among `clips` (first match of a fallback order).
    static func choose(_ clips: [CustomSceneManifest.Clip], elevation: Double, raining: Bool) -> CustomSceneManifest.Clip? {
        let sun = sunVariant(elevation: elevation)
        let order: [String]
        switch sun {
        case "night": order = ["night", "any", "golden", "day"]
        case "golden": order = ["golden", "day", "any", "night"]
        default: order = ["day", "any", "golden", "night"]
        }
        let wanted = (raining ? ["rain"] : []) + order + ["rain"]
        for v in wanted { if let c = clips.first(where: { $0.variant.lowercased() == v }) { return c } }
        return clips.first
    }

    /// Time of day (ds.time) for variant clips: 0 follows the real sun, 1 always day, 2 always
    /// night, 3 follows the Mac's Light/Dark mode.
    static func timeMode(_ inst: EffectInstance) -> Int {
        Int(saturating: inst.params["ds.time"] ?? 0, .toNearestOrAwayFromZero)
    }

    /// The sun elevation (°) the clip choice uses: the real one, or one well inside day / night.
    static func elevation(mode: Int, real: () -> Double) -> Double {
        switch mode {
        case 1: return 45
        case 2: return -20
        case 3: return systemDark ? -20 : 45
        default: return real()
        }
    }

    /// The Mac's appearance (the global AppleInterfaceStyle; readable from the saver too).
    static var systemDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    /// The settings a film style can really change, from what its package holds — so a film
    /// never shows a control that does nothing:
    ///   • light layers (relit live): Grain, Halation, Weather — the screen pass draws them;
    ///   • variant clips: Time of day (which clip plays), and Weather only with a rain clip.
    ///     Their look is baked into the clips (grain comes from the package's "look").
    static func editableParams(_ m: CustomSceneManifest, engine: [ParamSpec]) -> [ParamSpec] {
        guard m.engine.id == "film" else { return engine }
        if m.layers != nil { return engine.filter { $0.key != "ds.time" } }
        let rain = (m.clips ?? []).contains { $0.variant.lowercased() == "rain" }
        return engine.filter { $0.key == "ds.time" || ($0.key == "ds.weather" && rain) }
    }

    /// The engine's Weather menu (ds.weather): 0 = Live, then every condition in declaration order.
    static let weatherMenu = ["Live", "Clear", "Partly Cloudy", "Overcast", "Fog", "Drizzle", "Rain", "Heavy Rain",
                              "Thunderstorm", "Snow", "Sleet"]

    /// The condition a style pinned (nil: Live).
    static func pinnedCondition(_ inst: EffectInstance) -> WeatherCondition? {
        let i = Int(saturating: inst.params["ds.weather"] ?? 0, .toNearestOrAwayFromZero)
        guard i >= 1, i <= WeatherCondition.allCases.count else { return nil }
        return WeatherCondition.allCases[i - 1]
    }

    /// The weather a film style shows: a forced one (previews: WeatherLink.forced) over the
    /// style's pinned condition over the live weather.
    static func weather(_ inst: EffectInstance, live: WeatherMix) -> WeatherMix {
        if WeatherLink.forced != nil { return live }
        return pinnedCondition(inst).map(WeatherMix.preset) ?? live
    }

    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; let c = current?.video, o = previous?.video; lock.unlock()
        c?.setPaused(p); o?.setPaused(p)
        layers?.setPaused(p)
    }

    /// This frame's textures: the clip showing (A), the one it's fading from (B, or A), and the
    /// mix (0 = all A). `live`: a host drawing continuously (plays video); else a still from the
    /// clips' posters (thumbnails, the gallery).
    func frame(device: MTLDevice, now: CFTimeInterval, wall: Date, location: (lat: Double, lon: Double)?,
               weather: WeatherMix, live: Bool, timeMode: Int = 0) -> (a: MTLTexture, b: MTLTexture, mix: Float, fps: Float)? {
        let clips = prepared.manifest.clips ?? []
        guard !clips.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if current == nil || now - lastCheck >= CustomFilm.recheckSeconds || !live {
            lastCheck = now
            let el = CustomFilm.elevation(mode: timeMode) { CustomSceneLink.sun(at: wall, location: location).elevation }
            let raining = weather.precip * (1 - weather.snow) > 0.25
            if let c = CustomFilm.choose(clips, elevation: el, raining: raining), c != current?.clip {
                let next = make(c, device: device, live: live)
                if current != nil, live {
                    previous = current
                    fadeStart = now
                } else {
                    previous = nil
                }
                current = next
            }
        }
        guard let cur = current else { return nil }
        func tex(_ p: Playing) -> MTLTexture? { (live ? p.video?.currentTexture() : nil) ?? p.poster }
        guard let a = tex(cur) else { return nil }
        var mix: Float = 0
        var b = a
        if let prev = previous {
            // The fade starts once the new clip has a frame of its own.
            if live, cur.video?.currentTexture() == nil { fadeStart = now }
            let k = min(max((now - fadeStart) / CustomFilm.fadeSeconds, 0), 1)
            if k >= 1 { previous = nil } else if let pb = tex(prev) {
                b = pb
                mix = Float(1 - k * k * (3 - 2 * k))
            }
        }
        return (a, b, mix, cur.fps)
    }

    private func make(_ c: CustomSceneManifest.Clip, device: MTLDevice, live: Bool) -> Playing {
        let url = prepared.packageDir.appendingPathComponent(c.file)
        let v = live ? VideoSource(url: url, device: device) : nil
        if paused { v?.setPaused(true) }
        let rate = AVURLAsset(url: url).tracks(withMediaType: .video).first?.nominalFrameRate ?? 24
        return Playing(clip: c, video: v, poster: CustomFilm.poster(url, device: device), fps: rate > 1 ? rate : 24)
    }

    private static let posterLock = NSLock()
    private static var posters: [String: MTLTexture] = [:]

    /// A clip's first frame as a texture (cached per file and size/mtime).
    static func poster(_ url: URL, device: MTLDevice) -> MTLTexture? {
        let st = FileStamp(path: url.path)
        let key = "\(device.registryID)|\(url.path)|\(st?.size ?? 0)|\(st?.sec ?? 0)"
        posterLock.lock()
        if let t = posters[key] { posterLock.unlock(); return t }
        posterLock.unlock()
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let frame = try? gen.copyCGImage(at: .zero, actualTime: nil),
              let cg = eightBit(frame),
              let t = try? MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [
                  .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                  .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]) else { return nil }
        posterLock.lock()
        if posters.count > 16 { posters.removeAll() }
        posters[key] = t
        posterLock.unlock()
        return t
    }

    /// The frame as 8-bit sRGB RGBA: a 10-bit HEVC clip (the Blender toolkit's Main10) decodes to a
    /// 16-bit CGImage, which MTKTextureLoader refuses ("Image decoding failed").
    static func eightBit(_ cg: CGImage) -> CGImage? {
        if cg.bitsPerComponent == 8 && cg.bitsPerPixel == 32 { return cg }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// The film-specific checks of validate: known variants, playable clips, a day or "any" clip;
    /// for light layers, the grid, tiles, scales and the video.
    static func validate(_ p: PreparedScene) -> (diagnostics: [Diagnostic], warnings: [String]) {
        var d: [Diagnostic] = []
        var w: [String] = []
        let clips = p.manifest.clips ?? []
        if let l = p.manifest.layers {
            let r = FilmLayers.validate(l, packageDir: p.packageDir, engineVersion: p.engine?.version)
            d += r.diagnostics; w += r.warnings
        } else if clips.isEmpty {
            d.append(Diagnostic(message: "a film scene needs \"clips\": [{\"variant\": \"day\", \"file\": \"clips/day.mov\"}, …] or \"layers\" (engine >=1.1)", file: "scene.json"))
        }
        for c in clips {
            if !variants.contains(c.variant.lowercased()) {
                d.append(Diagnostic(message: "clip \(c.file): variant \"\(c.variant)\" isn't one of \(variants.joined(separator: ", "))", file: "scene.json"))
            }
            if c.loop == false { w.append("clip \(c.file): \"loop\": false — clips always loop") }
            let url = p.packageDir.appendingPathComponent(c.file)
            let asset = AVURLAsset(url: url)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }   // (packageFiles reports it)
            let tracks = asset.tracks(withMediaType: .video)
            if tracks.isEmpty || !asset.isPlayable {
                d.append(Diagnostic(message: "clip \(c.file) isn't a playable video", file: c.file)); continue
            }
            let dur = CMTimeGetSeconds(asset.duration)
            if !(dur > 0.4) { d.append(Diagnostic(message: String(format: "clip %@ is %.2f s: too short to loop", c.file, dur), file: c.file)) }
            if let t = tracks.first {
                let s = t.naturalSize.applying(t.preferredTransform)
                if abs(s.width) < 640 { w.append("clip \(c.file) is \(Int(abs(s.width))) px wide: it will look soft full-screen") }
                let codec = (t.formatDescriptions.first.map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) }) ?? 0
                if codec != kCMVideoCodecType_HEVC && codec != kCMVideoCodecType_H264 {
                    w.append("clip \(c.file): HEVC (or H.264) decodes in hardware; this codec may not")
                }
            }
        }
        let vs = Set(clips.map { $0.variant.lowercased() })
        if !clips.isEmpty && !vs.contains("day") && !vs.contains("any") && p.manifest.layers == nil {
            w.append("no \"day\" or \"any\" clip: daytime falls back to \(clips[0].variant)")
        }
        return (d, w)
    }
}

// MARK: - Light layers

/// A layered film package's player: the layers video (live) or its first frame (stills), the
/// passes that run per video frame (mix → mips → look, mist) and per grain frame (the lattice),
/// and the screen pass's uniforms. film.metal's header has the passes.
///
/// Cost (Apple M5 Pro, 5120×2880, the 1600×1000-tile Commute loop, GPU at benchmark_style's
/// idle clocks): the screen pass is what every displayed frame pays — 3.3 ms dry (clear, partly
/// cloudy), 3.6 damp (overcast, fog), ≈ 4.4–5.1 with rain or snow on the glass (the drops and
/// flakes, per glass pixel); the per-video-frame passes 0.85–1.05 ms, at most the clip's frame
/// rate: a new video frame, or the light changing — light-only changes are rate-limited to the
/// frame rate while live (the cloud shadows' drift, lightning, the weather easing and the sun
/// move it nearly every frame).
final class FilmLayers {
    static let mixFunction = "ds_film_mix"
    static let lookFunction = "ds_film_look"
    static let mistFunction = "ds_film_mist"
    static let grainFunction = "ds_film_grain"
    /// The screen pass's lean variants (the same pixels when they're picked): dry glass (no rain,
    /// snow, lightning or mist), damp glass (mist and fog, no rain, snow or lightning).
    static let dryFunction = "ds_film_dry"
    static let dampFunction = "ds_film_damp"
    /// … and with rain but no snow, with snow but no rain (the full ds_fragment: both, sleet).
    static let rainFunction = "ds_film_rain"
    static let snowFunction = "ds_film_snow"
    static let screenVariants = [dryFunction, dampFunction, rainFunction, snowFunction]
    static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let glowFormat: MTLPixelFormat = .rg16Float
    static let lookFormat: MTLPixelFormat = .rgba16Float
    static let grainFormat: MTLPixelFormat = .r32Float
    /// The glass's cell tables below the grain lattice: their rows, and the most cells a layer has
    /// down (film.metal: FILM_TABLE_ROWS, FILM_TABLE_SC).
    static let tableRows = 493
    static let tableMaxCells: Float = 70
    /// The glass map's block, in screen pixels (film.metal: FILM_MAP_BLOCK).
    static let mapBlock = 8

    /// The extra pipelines a layered film needs beside its screen pass: (fragment, format, more formats).
    static let passes: [(String, MTLPixelFormat, [MTLPixelFormat])] = [
        (mixFunction, hdrFormat, [glowFormat]), (lookFunction, lookFormat, []), (grainFunction, grainFormat, []),
        (mistFunction, lookFormat, [])]

    let prepared: PreparedScene
    let layers: CustomSceneManifest.Layers
    let url: URL
    let fps: Float
    private let lock = NSLock()
    private var video: VideoSource?
    private var paused = false
    private var cache: CVMetalTextureCache?
    private var cacheDevice: UInt64 = 0

    /// When the per-video-frame passes run (benchmarks measure the two costs apart).
    enum MixMode { case auto, hold, always }

    /// What the screen pass binds, and how.
    struct Output {
        let hdr: MTLTexture
        /// The look pass's halation + bloom light, and its mist (rgb) + mist edge (a).
        let light: MTLTexture
        let mist: MTLTexture
        /// The grain lattice for this frame and screen (nil: the shader hashes the grain).
        let grain: MTLTexture?
        /// u.scene[0…3].
        let screen: [simd_float4]
        /// The screen pass's lean variant for this weather (dryFunction, dampFunction; nil: the
        /// full ds_fragment) — the same pixels, cheaper.
        let variant: String?
        /// Whether this call encoded anything on the command buffer.
        let encoded: Bool
    }

    /// What the passes made, per kind of render (live / one-off), so a thumbnail drawn by a
    /// live renderer never overwrites the texture its in-flight frames read.
    final class Target {
        var hdr: MTLTexture?
        var glow: MTLTexture?
        var light: MTLTexture?
        var mist: MTLTexture?
        var key: [Float] = []
        var lookKey: [Float] = []
        var frameObject: ObjectIdentifier?
        var serial = -1
        var mixedAt: CFTimeInterval = -.infinity
        var grain: MTLTexture?
        var grainFrame: Float = -1
        var grainStaticKey: [Float] = []
    }
    private var targets: [Bool: Target] = [:]

    init(prepared: PreparedScene, layers: CustomSceneManifest.Layers) {
        self.prepared = prepared
        self.layers = layers
        url = prepared.packageDir.appendingPathComponent(layers.file)
        let rate = AVURLAsset(url: url).tracks(withMediaType: .video).first?.nominalFrameRate ?? 24
        fps = rate > 1 ? rate : 24
    }

    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; let v = video; lock.unlock()
        v?.setPaused(p)
    }

    // MARK: The light

    /// The mix's weights for a sun elevation (°), weather and time (s): per light tile an rgb
    /// weight (before scale / exposure), the exposure (EV), the sun's gate (clear sky) with the
    /// cloud-shadow amount, and the lightning flash. docs/film-layers.md "The mix", extended to
    /// every condition: snow (colder, softer, brighter sky), fog, storms (lightning).
    struct Mix: Equatable {
        var sun: Float = 0, sunLow: Float = 0, cabin: Float = 1, city: Float = 0
        var sky = SIMD3<Float>(repeating: 0)
        var ev: Float = 0
        var clear: Float = 1
        var shadow: Float = 0
        var flash: Float = 0
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func mix(elevation e: Double, weather w: WeatherMix, time: Double, day: Double = 1.5, night: Double = 3.2) -> Mix {
        let rain = w.precip * (1 - w.snow), snow = w.precip * w.snow
        let cloud = max(w.cover, w.fog)
        let up = smoothstep(-6, 4, e)
        let low = smoothstep(-2, 6, e) * (1 - smoothstep(10, 22, e))
        let high = smoothstep(8, 20, e)
        let clear = 1 - smoothstep(0.3, 0.92, max(cloud, 2 * rain, 2 * snow))
        func v(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, y, z) }
        func lerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ k: Double) -> SIMD3<Double> { a + (b - a) * k }
        let warm = lerp(v(1, 1, 1), v(1, 0.80, 0.60), low * clear)
        var sky = (v(0.75, 0.85, 1.0) * 0.08 * (1 - up) + warm * up * (0.4 + 0.6 * high))
            * (1 - 0.68 * rain) * lerp(v(1, 1, 1), v(0.75, 0.78, 0.82), cloud * (1 - rain))
        // snow: a colder, softer, brighter sky (the snow lights everything from below); fog: greyer
        sky *= lerp(v(1, 1, 1), v(0.95, 1.0, 1.12) * 1.25, snow)
        sky *= lerp(v(1, 1, 1), v(0.96, 0.98, 1.0), w.fog)
        var m = Mix()
        m.flash = Float(lightning(time: time, storm: w.storm))
        if m.flash > 0 {                         // a spike of the sky's light, cool (milder by day)
            let f = Double(m.flash)
            sky = sky * (1 + 3 * f * (1 - 0.75 * up)) + v(0.8, 0.9, 1.15) * 0.05 * f * (1 - 0.6 * up)
        }
        m.sky = SIMD3<Float>(sky)
        m.sun = Float(high)
        m.sunLow = Float(low)
        m.clear = Float(clear)
        // partly cloudy: shadows drift over the sun's light (strongest halfway between clear and overcast)
        m.shadow = Float(min(1, 4 * clear * (1 - clear) * 1.2))
        m.cabin = Float(1 + 1.2 * rain + 0.3 * cloud + 0.4 * snow)
        m.city = Float(1 - up)
        m.ev = Float(night * (1 - up) + up * (day + 0.1 * low) + 0.45 * rain + 0.3 * cloud * (1 - rain) + 0.15 * snow)
        return m
    }

    /// Lightning, 0…1: a brief double flash with a flicker, at most one every 8–20 s (14 s slots,
    /// a random start within the first 6 s of each), only in a storm. Gentle by design: two
    /// pulses ~0.2 s apart, decaying in ~0.1 s, never strobing.
    static func lightning(time t: Double, storm: Double) -> Double {
        guard storm > 0.05 else { return 0 }
        let slot = (t / 14).rounded(.down)
        func hash(_ x: Double) -> Double { let s = sin(x * 12.9898 + 78.233) * 43758.5453; return s - s.rounded(.down) }
        guard hash(slot) < storm * 0.85 else { return 0 }           // not every slot
        let start = slot * 14 + hash(slot + 0.37) * 6
        let dt = t - start
        guard dt >= 0, dt < 1.2 else { return 0 }
        var f = exp(-dt / 0.09)
        if dt > 0.21 { f += 0.7 * exp(-(dt - 0.21) / 0.12) }
        let flicker = 0.85 + 0.15 * sin(dt * 90)
        return min(max(f * flicker * min(storm * 1.2, 1), 0), 1)
    }

    /// The per-tile mix uniforms (u.scene[5…10]) for `m`: weight × scale × tint × 2^EV.
    func weights(_ m: Mix) -> [simd_float4] {
        let exposure = Float(pow(2.0, Double(m.ev)))
        func w(_ tile: String, _ rgb: SIMD3<Float>) -> simd_float4 {
            guard let i = layers.index(of: tile) else { return simd_float4(0, 0, 0, -1) }
            let s = Float(layers.scale?[tile] ?? 1)
            var tint = SIMD3<Float>(repeating: 1)
            if let t = layers.tint?[tile], t.count >= 3 { tint = SIMD3(Float(t[0]), Float(t[1]), Float(t[2])) }
            let v = rgb * tint * s * exposure
            return simd_float4(v.x, v.y, v.z, Float(i))
        }
        let one = SIMD3<Float>(repeating: 1)
        return [w("sun", one * m.sun), w("sun_low", one * m.sunLow), w("sky", m.sky), w("cabin", one * m.cabin),
                w("city", one * m.city),
                simd_float4(layers.index(of: "mask").map(Float.init) ?? -1, m.clear, m.shadow, 0)]
    }

    // MARK: Frames

    private func textureCache(_ device: MTLDevice) -> CVMetalTextureCache? {
        if let c = cache, cacheDevice == device.registryID { return c }
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c)
        cache = c; cacheDevice = device.registryID
        return c
    }

    private static let posterLock = NSLock()
    private static var posters: [String: YCbCrFrame] = [:]

    /// The video's first frame (stills), cached per file and size/mtime.
    func poster(_ device: MTLDevice) -> YCbCrFrame? {
        let st = FileStamp(path: url.path)
        let key = "\(device.registryID)|\(url.path)|\(st?.size ?? 0)|\(st?.sec ?? 0)|\(st?.nsec ?? 0)"
        FilmLayers.posterLock.lock()
        if let f = FilmLayers.posters[key] { FilmLayers.posterLock.unlock(); return f }
        FilmLayers.posterLock.unlock()
        lock.lock(); let c = textureCache(device); lock.unlock()
        guard let c, let f = YCbCrFrame.firstFrame(url, cache: c) else { return nil }
        FilmLayers.posterLock.lock()
        if FilmLayers.posters.count > 8 { FilmLayers.posters.removeAll() }
        FilmLayers.posters[key] = f
        FilmLayers.posterLock.unlock()
        return f
    }

    /// The frame to mix: the playing video's newest (live; its first frame until it decodes one),
    /// else the first frame.
    /// A layers video under 0.4 s (render_film_loop still_frame: one frame) is a relightable
    /// STILL: its frame is decoded once (the poster path) and no player loops it.
    private lazy var isStill: Bool = {
        let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return d.isFinite && d < 0.4
    }()

    private func source(_ device: MTLDevice, live: Bool) -> YCbCrFrame? {
        if live && !isStill {
            lock.lock()
            if video == nil {
                let fmt = YCbCrFrame.pixelFormat(for: AVURLAsset(url: url).tracks(withMediaType: .video).first)
                video = VideoSource(url: url, device: device, pixelFormat: fmt)
                if paused { video?.setPaused(true) }
            }
            let v = video
            lock.unlock()
            if let f = v?.currentPlanes() { return f }
        }
        return poster(device)
    }

    private func texture(_ device: MTLDevice, _ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ old: MTLTexture?,
                         mipmapped: Bool = true) -> MTLTexture? {
        if let old, old.width == w, old.height == h, old.pixelFormat == fmt { return old }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// The grain's cell in screen pixels for a screen `height` px tall (film.metal: film_finish).
    static func grainCell(height: Int) -> Float { max(Float(height) / 1100 * 1.4, 1) }

    /// Encodes on `cmd` what changed since the last call: the mix + mips + look passes for a new
    /// video frame or light (else keeps the last ones), and the grain lattice for a new grain frame
    /// or screen size. Returns what the screen pass binds. nil while the pipelines compile
    /// (`wait`: compile now) or before a frame decodes.
    /// - halation: the style's Halation (ds.halation, u.scene[8].y of the screen pass).
    /// - screen: the screen pass's size (nil: no grain lattice; the screen pass hashes the grain).
    /// - live: a host drawing continuously: the playing video, and light-only changes (the sun,
    ///   the weather easing, cloud shadows, lightning) re-mix at most at the clip's frame rate.
    func encode(_ cmd: MTLCommandBuffer, device: MTLDevice, elevation: Double, weather: WeatherMix, time: Double,
                halation: Float = 0.15, screen size: (width: Int, height: Int)? = nil, live: Bool, wait: Bool,
                mode: MixMode = .auto) -> Output? {
        func pso(_ i: Int) -> MTLRenderPipelineState? {
            let p = FilmLayers.passes[i]
            return CustomScenePipelines.pipeline(prepared, device: device, format: p.1, wait: wait, fragment: p.0, extraFormats: p.2)
        }
        guard let mixPSO = pso(0), let lookPSO = pso(1), let frame = source(device, live: live) else { return nil }
        let cols = layers.columns, rows = layers.rows
        let vw = frame.luma.width, vh = frame.luma.height
        let (tw, th) = layers.tileSize(videoWidth: vw, videoHeight: vh)   // (gutters excluded)
        let m = FilmLayers.mix(elevation: elevation, weather: weather, time: time,
                               day: layers.exposure?.day ?? 1.5, night: layers.exposure?.night ?? 3.2)
        let exposure = Float(pow(2.0, Double(m.ev)))
        var w = weights(m)
        // the cloud shadows' drift (slow, faster in wind)
        // (none at night: no sun to shade, and a still phase keeps the mix from re-running)
        let sunLit = w[0].w >= 0 && w[0].x + w[0].y + w[0].z > 0 || w[1].w >= 0 && w[1].x + w[1].y + w[1].z > 0
        w[5].w = m.shadow > 0.01 && sunLit ? Float((time * 0.012 * weather.driftRate).truncatingRemainder(dividingBy: 1000)) : 0
        let head: [simd_float4] = [simd_float4(Float(vw), Float(vh), Float(tw), Float(th)),
                                   simd_float4(Float(cols), Float(rows), 2 * exposure, 3 * exposure),
                                   frame.rows.0, frame.rows.1, frame.rows.2]
        let all = head + w
        lock.lock()
        let target = targets[live] ?? Target()
        targets[live] = target
        lock.unlock()
        let key = [Float(frame.serial)] + all.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        var screen = screenUniforms(m, weather: weather, tileWidth: tw, tileHeight: th)
        let object = ObjectIdentifier(frame.luma)
        let now = CACurrentMediaTime()
        let sameFrame = object == target.frameObject && frame.serial == target.serial
        var remix: Bool
        switch mode {
        case .always: remix = true
        case .hold: remix = target.hdr == nil
        case .auto:
            remix = key != target.key || !sameFrame
            // live, the light alone moves nearly every frame (cloud shadows, lightning, the weather
            // easing, the sun): picked up with the next video frame, or after a frame's time
            if remix, live, sameFrame, now - target.mixedAt < 1 / Double(fps) { remix = false }
        }
        if target.hdr == nil || target.light == nil { remix = true }

        // the look pass's inputs: the style's halation, the package's bloom, the blur sizes, the mist
        let mist = Float(max(Double(screen[2].z), 0.5 * Double(screen[2].x), 0.45 * Double(screen[2].y))) > 0.02
        let hal = min(max(halation, 0), 1)
        let lookKey: [Float] = [hal, screen[1].w, screen[3].y, screen[3].z, mist ? 1 : 0]
        let relook = remix || lookKey != target.lookKey

        if remix {
            guard let hdr = texture(device, FilmLayers.hdrFormat, tw, th, target.hdr),
                  let glow = texture(device, FilmLayers.glowFormat, tw, th, target.glow) else { return nil }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = hdr
            rpd.colorAttachments[1].texture = glow
            for i in 0..<2 { rpd.colorAttachments[i].loadAction = .dontCare; rpd.colorAttachments[i].storeAction = .store }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
            var u = FXUniforms()
            u.resolution = simd_float2(Float(tw), Float(th))
            u.time = Float(time.truncatingRemainder(dividingBy: 3600))
            withUnsafeMutableBytes(of: &u.scene) { raw in
                let s = raw.bindMemory(to: simd_float4.self)
                for (i, v) in all.enumerated() where i < 16 { s[i] = v }
            }
            enc.setRenderPipelineState(mixPSO)
            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            let ph = CustomSceneAssets.placeholder(device)
            enc.setFragmentTexture(frame.luma, index: 9)
            enc.setFragmentTexture(frame.chroma, index: 10)
            enc.setFragmentTexture(ph, index: 11)
            enc.setFragmentTexture(ph, index: 12)
            enc.setFragmentSamplerState(CustomSceneAssets.sampler(device), index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            if let blit = cmd.makeBlitCommandEncoder() {                 // (the blurs are mip taps)
                blit.generateMipmaps(for: hdr)
                blit.generateMipmaps(for: glow)
                blit.endEncoding()
            }
            // the frame's buffers stay alive until the GPU is done with them
            cmd.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
            target.hdr = hdr; target.glow = glow; target.key = key; target.frameObject = object
            target.serial = frame.serial; target.mixedAt = now
        }
        guard let hdr = target.hdr, let glow = target.glow else { return nil }

        // the look: halation + bloom (and the mist), from the mips
        if relook {
            func pass(_ pso: MTLRenderPipelineState, into t: MTLTexture) -> Bool {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = t
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
                var u = FXUniforms()
                u.resolution = simd_float2(Float(t.width), Float(t.height))
                u.scene.0 = simd_float4(lookKey[0], lookKey[1], lookKey[2], lookKey[3])
                enc.setRenderPipelineState(pso)
                enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                let ph = CustomSceneAssets.placeholder(device)
                enc.setFragmentTexture(hdr, index: 9)
                enc.setFragmentTexture(glow, index: 10)
                enc.setFragmentTexture(ph, index: 11)
                enc.setFragmentTexture(ph, index: 12)
                enc.setFragmentSamplerState(CustomSceneAssets.sampler(device), index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
                return true
            }
            // the light at half the tiles' size (blurs of tens of pixels); the mist (an AgX of a
            // blur, sharper where it's bright) at their own
            guard let light = texture(device, FilmLayers.lookFormat, max((tw + 1) / 2, 1), max((th + 1) / 2, 1),
                                      target.light, mipmapped: false),
                  pass(lookPSO, into: light) else { return nil }
            target.light = light
            if mist {
                guard let mistPSO = pso(3),
                      let mt = texture(device, FilmLayers.lookFormat, tw, th, target.mist, mipmapped: false),
                      pass(mistPSO, into: mt) else { return nil }
                target.mist = mt
            }
            target.lookKey = lookKey
        }
        guard let light = target.light else { return nil }
        let mistT = (mist ? target.mist : nil) ?? CustomSceneAssets.placeholder(device)

        // the grain lattice: once per grain frame (film_finish_layers' frame: ⌊t · fps⌋) and screen
        var grain: MTLTexture?
        var grainEncoded = false
        if let size, size.width > 0, size.height > 0, let grainPSO = pso(2) {
            let gframe = max((Float(time) * fps).rounded(.down), 0)
            let cell = FilmLayers.grainCell(height: size.height)
            let gw = Int((Float(size.width) - 0.5) / cell) + 2, gh = Int((Float(size.height) - 0.5) / cell) + 2
            // below the lattice, the glass's cell tables (film.metal: film_drop_hashes) for this aspect,
            // then the glass map (FilmLayers.mapBlock-pixel blocks) for this screen, rain, snow and wind
            let aspect = Float(tw) / Float(th)
            let mw = (size.width + FilmLayers.mapBlock - 1) / FilmLayers.mapBlock
            let mh = (size.height + FilmLayers.mapBlock - 1) / FilmLayers.mapBlock
            let fullW = max(gw, 2 * (Int((aspect * FilmLayers.tableMaxCells).rounded(.down)) + 1), mw)
            let fullH = gh + FilmLayers.tableRows + mh
            let staticKey: [Float] = [Float(size.width), Float(size.height), aspect, screen[2].x, screen[2].y, screen[3].w]
            if gframe == target.grainFrame, staticKey == target.grainStaticKey, mode != .always, let g = target.grain {
                grain = g
            } else if let g = texture(device, FilmLayers.grainFormat, fullW, fullH, target.grain, mipmapped: false) {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = g
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                // the tables and the map stay while their inputs do: then only the lattice's rows
                if g === target.grain, staticKey == target.grainStaticKey {
                    rpd.renderTargetWidth = fullW
                    rpd.renderTargetHeight = gh
                }
                if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                    var u = FXUniforms()
                    u.resolution = simd_float2(Float(fullW), Float(fullH))
                    u.scene.0 = simd_float4(gframe, Float(gh), aspect, 0)
                    u.scene.1 = simd_float4(Float(size.width), Float(size.height), Float(tw), Float(th))
                    u.scene.2 = simd_float4(screen[2].x, screen[2].y, 0, screen[3].w)
                    enc.setRenderPipelineState(grainPSO)
                    enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                    target.grain = g; target.grainFrame = gframe; target.grainStaticKey = staticKey
                    grain = g; grainEncoded = true
                }
            }
            if grain != nil { screen[0].z = gframe; screen[0].w = Float(size.height); screen[1].x = Float(gh) }
        }
        let s2 = screen[2]
        // no rain, snow or lightning: damp (or dry, without the mist and fog film_layered skips ≤ 0.02)
        let still = s2.x <= 0 && s2.y <= 0 && s2.w <= 0
        let variant = still ? (s2.z <= 0.02 ? FilmLayers.dryFunction : FilmLayers.dampFunction)
            : s2.y <= 0 ? FilmLayers.rainFunction : s2.x <= 0 ? FilmLayers.snowFunction : nil
        return Output(hdr: hdr, light: light, mist: mistT, grain: grain, screen: screen, variant: variant,
                      encoded: remix || relook || grainEncoded)
    }

    /// The screen pass's u.scene[0…3] (film.metal's header).
    func screenUniforms(_ m: Mix, weather: WeatherMix, tileWidth: Int, tileHeight: Int) -> [simd_float4] {
        let look = prepared.manifest
        let bloom = Float(min(max(look.lookValue("bloom") ?? 0.25, 0), 1)) * (0.32 / 0.25)
        let vignette = Float(min(max(look.lookValue("vignette") ?? 0.22, 0), 1))
        let wd = Double(tileWidth)
        let halLod = Float(log2(max(0.02 * wd, 1))), bloomLod = Float(log2(max(0.05 * wd, 1)))
        let rain = weather.precip * (1 - weather.snow), snow = weather.precip * weather.snow
        return [simd_float4(Float(tileWidth), Float(tileHeight), -1, 0),
                simd_float4(0, fps, 1, bloom),
                simd_float4(Float(rain), Float(snow), Float(weather.fog), m.flash),
                simd_float4(vignette, halLod, bloomLod, Float(min(max(weather.wind / 20, 0), 1)))]
    }

    // MARK: Validate

    static func validate(_ l: CustomSceneManifest.Layers, packageDir: URL, engineVersion: String?) -> (diagnostics: [Diagnostic], warnings: [String]) {
        var d: [Diagnostic] = []
        var w: [String] = []
        func err(_ s: String, _ file: String = "scene.json") { d.append(Diagnostic(message: "layers: " + s, file: file)) }
        if let v = engineVersion, CustomScenes.compareVersions(v, "1.1") < 0 {
            err("light layers need the film engine 1.1 or later (\"engine\": {\"id\": \"film\", \"version\": \">=1.1\"})")
        }
        let cols = l.columns, rows = l.rows
        if let g = l.grid, g.count != 2 || g.contains(where: { $0 < 1 || $0 > 8 }) { err("\"grid\" must be [columns, rows], each 1…8") }
        if l.tiles.isEmpty { err("\"tiles\" is empty: list the grid's tiles left→right, top→bottom") }
        if l.tiles.count != cols * rows { err("\(l.tiles.count) tiles for a \(cols)×\(rows) grid: they must match") }
        if Set(l.tiles).count != l.tiles.count { err("a tile is listed twice") }
        for t in l.tiles where !CustomSceneManifest.Layers.knownTiles.contains(t) {
            w.append("layers: tile \"\(t)\" isn't one of \(CustomSceneManifest.Layers.lightTiles.joined(separator: ", ")), mask — it's ignored")
        }
        if !l.tiles.contains(where: { ["sun", "sky", "cabin"].contains($0) }) { err("no light tiles (sun, sky or cabin)") }
        if let e = l.encoding, e != "pow4" { err("encoding \"\(e)\": this build reads \"pow4\"") }
        for t in l.tiles where CustomSceneManifest.Layers.lightTiles.contains(t) {
            guard let s = l.scale?[t] else { err("no \"scale\" for the \(t) tile (its 99.95th percentile, linear)"); continue }
            if !(s > 0 && s < 1000) { err("scale for \(t) is \(s): expected a positive number (linear, ~0.1…10)") }
        }
        if !l.tiles.contains("mask") { w.append("layers: no mask tile — no rain, snow or fog on the glass") }
        if let e = l.exposure, [e.day, e.night].contains(where: { $0.map { !$0.isFinite || abs($0) > 16 } ?? false }) {
            err("exposure day / night must be EV values within ±16")
        }
        for (k, v) in l.tint ?? [:] where v.count != 3 || v.contains(where: { !$0.isFinite || $0 < 0 || $0 > 4 }) {
            err("tint \(k) must be [r, g, b], each 0…4")
        }
        let url = packageDir.appendingPathComponent(l.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return (d, w) }      // (packageFiles reports it)
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first, asset.isPlayable else {
            err("\(l.file) isn't a playable video", l.file); return (d, w)
        }
        let dur = CMTimeGetSeconds(asset.duration)
        if !(dur > 0) { err("\(l.file) has no frames", l.file) }
        else if dur < 0.4 { w.append(String(format: "layers: %@ is %.2f s — played as a still (its first frame, relit live)", l.file, dur)) }
        let s = track.naturalSize.applying(track.preferredTransform)
        let vw = Int(abs(s.width)), vh = Int(abs(s.height))
        if vw > 8192 || vh > 8192 { err("\(l.file) is \(vw)×\(vh): at most 8192 px a side (hardware decode)", l.file) }
        let g = l.gutterPixels
        if let gg = l.gutter, gg < 0 || gg > 64 { err("\"gutter\" is \(gg): expected 0…64 pixels between tiles") }
        if (vw - (cols - 1) * g) % cols != 0 || (vh - (rows - 1) * g) % rows != 0 {
            w.append("layers: \(vw)×\(vh) doesn't split evenly into \(cols)×\(rows) tiles with a \(g) px gutter")
        }
        let tw = l.tileSize(videoWidth: vw, videoHeight: vh).w
        if tw < 640 { w.append("layers: tiles are \(tw) px wide: soft full-screen (1600×1000 is the default)") }
        if let fd = track.formatDescriptions.first {
            let f = fd as! CMFormatDescription
            if CMFormatDescriptionGetMediaSubType(f) != kCMVideoCodecType_HEVC {
                err("\(l.file) must be HEVC Main10 (10-bit): 8-bit video bands the layers' shadows", l.file)
            }
            if CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) == nil {
                w.append("layers: \(l.file) has no colour matrix tag: read as BT.709 (encode with -colorspace bt709)")
            }
        }
        return (d, w)
    }
}
