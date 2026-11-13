//  CustomFilm.swift — the `film` engine: a scene package of looping video clips (HEVC loops
//  rendered offline, e.g. by the Blender toolkit), one per variant of the day:
//
//      "engine": { "id": "film" },
//      "clips": [ { "variant": "day",    "file": "clips/day.mov",    "loop": true },
//                 { "variant": "golden", "file": "clips/golden.mov" },
//                 { "variant": "night",  "file": "clips/night.mov" },
//                 { "variant": "rain",   "file": "clips/rain.mov" } ]
//
//  The variant follows the real sun (night below −4°, golden hour −4°…8°, day above) and the
//  weather (rain while it rains, if the package has a rain clip), re-checked every few seconds;
//  a change crossfades over 3 s. Each clip plays through VideoSource (AVPlayerLooper: seamless
//  loops, hardware decode, muted), aspect-filled by the film engine's wrapper (Engines/film/1/
//  film.metal) — the same runtime-compiled pipeline path as every Custom Scene. One-off renders
//  (thumbnails, the gallery) and the first frames before a clip decodes draw its poster frame.
//  Power: the hosts' media pause (MetalRenderer.setMediaPaused: the wallpaper's held stills —
//  Low Power, On Battery Still or Efficient) pauses the clips.

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

    init(prepared: PreparedScene) { self.prepared = prepared }

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

    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; let c = current?.video, o = previous?.video; lock.unlock()
        c?.setPaused(p); o?.setPaused(p)
    }

    /// This frame's textures: the clip showing (A), the one it's fading from (B, or A), and the
    /// mix (0 = all A). `live`: a host drawing continuously (plays video); else a still from the
    /// clips' posters (thumbnails, the gallery).
    func frame(device: MTLDevice, now: CFTimeInterval, wall: Date, location: (lat: Double, lon: Double)?,
               weather: WeatherMix, live: Bool) -> (a: MTLTexture, b: MTLTexture, mix: Float, fps: Float)? {
        let clips = prepared.manifest.clips ?? []
        guard !clips.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if current == nil || now - lastCheck >= CustomFilm.recheckSeconds || !live {
            lastCheck = now
            let el = CustomSceneLink.sun(at: wall, location: location).elevation
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

    /// The film-specific checks of validate: known variants, playable clips, a day or "any" clip.
    static func validate(_ p: PreparedScene) -> (diagnostics: [Diagnostic], warnings: [String]) {
        var d: [Diagnostic] = []
        var w: [String] = []
        let clips = p.manifest.clips ?? []
        if clips.isEmpty { d.append(Diagnostic(message: "a film scene needs \"clips\": [{\"variant\": \"day\", \"file\": \"clips/day.mov\"}, …]", file: "scene.json")) }
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
        if !clips.isEmpty && !vs.contains("day") && !vs.contains("any") {
            w.append("no \"day\" or \"any\" clip: daytime falls back to \(clips[0].variant)")
        }
        return (d, w)
    }
}
