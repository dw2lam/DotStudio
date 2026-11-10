//  MediaSource.swift — turns an image or video file into a Metal texture per frame.

import Metal
import MetalKit
import AVFoundation
import CoreVideo
import ImageIO
import simd

protocol MediaSource: AnyObject {
    var size: CGSize { get }
    func currentTexture() -> MTLTexture?
}

/// A still image, decoded once.
final class ImageSource: MediaSource {
    private let texture: MTLTexture?
    let size: CGSize

    init?(url: URL, device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue
        ]
        guard let t = try? loader.newTexture(URL: url, options: opts) else { return nil }
        texture = t
        size = CGSize(width: t.width, height: t.height)
    }

    func currentTexture() -> MTLTexture? { texture }
}

/// A looping, hardware-decoded video.
final class VideoSource: MediaSource {
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private let output: AVPlayerItemVideoOutput
    private var cache: CVMetalTextureCache?
    private let device: MTLDevice
    private(set) var size: CGSize = CGSize(width: 1920, height: 1080)

    init?(url: URL, device: MTLDevice) {
        self.device = device
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: item)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        if let track = asset.tracks(withMediaType: .video).first {
            let s = track.naturalSize.applying(track.preferredTransform)
            size = CGSize(width: abs(s.width), height: abs(s.height))
        }
        player.play()
    }

    func setPaused(_ paused: Bool) {
        if paused { player.pause() } else { player.play() }
    }

    func currentTexture() -> MTLTexture? {
        guard let cache = cache else { return nil }
        let host = CACurrentMediaTime()
        let time = output.itemTime(forHostTime: host)
        guard output.hasNewPixelBuffer(forItemTime: time) || lastTexture == nil,
              let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) ?? lastBuffer
        else { return lastTexture }

        lastBuffer = pb
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        size = CGSize(width: w, height: h)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return lastTexture
        }
        lastTexture = tex
        return tex
    }

    private var lastTexture: MTLTexture?
    private var lastBuffer: CVPixelBuffer?
}

// MARK: - Collection (photo slideshow)

/// One frame of a slideshow, as the source pass draws it: photo A cross-fading into
/// photo B, each framed by its own slow Ken Burns move.
struct SlideFrame {
    let texA: MTLTexture
    let kbA: simd_float4          // (zoom ≥ 1, panX, panY, 0); pan is −1…1 of the free travel
    let texB: MTLTexture?
    let kbB: simd_float4
    let mix: Float                // 0 = all A, 1 = all B
}

/// A position on a slideshow's timeline: seconds, and the photo-order seed (nil = the
/// source's own start — random for a live source). Renderers on the wall-clock time base
/// pass epoch seconds and seed 0, so every one of them shows the same photo and framing.
struct SlideClock: Equatable {
    var t: Double
    var seed: Int?
}

/// A slowly panning, cross-fading photo slideshow: the built-in curated set (shipped in
/// the .saver bundle) or the user's own photos from the media folder. Everything is a
/// pure function of time, so the saver, previews and thumbnails agree; photos decode on
/// a background queue one slide ahead, and only the slides on screen stay in memory.
final class CollectionSource {
    let urls: [URL]
    let filenames: [String]
    var interval: Double
    var motion: Double
    var fade: Double { min(4.0, interval * 0.35) }

    private let device: MTLDevice
    private let queue: MTLCommandQueue?        // mipmap generation
    private let maxPixel: Int
    private let evicts: Bool
    private let offset: Int
    private let lock = NSLock()
    private var cache: [Int: MTLTexture] = [:]
    private var pending: Set<Int> = []
    private var failed: Set<Int> = []
    private static let queue = DispatchQueue(label: "DotStudio.CollectionSource", qos: .utility)

    /// - Parameters:
    ///   - live: true for the saver/previews (random first photo, evict off-screen slides,
    ///     background decoding); false for thumbnails (slide 0 first, keep everything).
    ///   - maxPixel: long-edge cap for decoded photos.
    init?(spec: SourceSpec, store: SharedStore, device: MTLDevice, live: Bool, maxPixel: Int = 3200) {
        let names = spec.mediaFilenames ?? []
        let urls = names.isEmpty
            ? CollectionSource.builtInPhotoURLs()
            : names.map { store.mediaURL($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return nil }
        self.urls = urls
        self.filenames = names
        self.device = device
        self.queue = device.makeCommandQueue()
        self.interval = spec.slideInterval
        self.motion = spec.motionAmount
        self.maxPixel = maxPixel
        self.evicts = live
        self.offset = live ? Int.random(in: 0..<urls.count) : 0
    }

    func update(_ spec: SourceSpec) {
        interval = spec.slideInterval
        motion = spec.motionAmount
    }

    // MARK: Built-in set

    /// The curated photos, in slideshow order (files are numbered). The saver carries
    /// them in its own Resources/Photos; the app reads the embedded saver's copy, so the
    /// JPEGs ship once. The gallery tool keeps them next to its binary.
    static func builtInPhotoURLs() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let r = Bundle(for: CollectionSource.self).resourceURL { dirs.append(r.appendingPathComponent("Photos")) }
        if let r = Bundle.main.resourceURL {
            dirs.append(r.appendingPathComponent("DotStudio.saver/Contents/Resources/Photos"))
            dirs.append(r.appendingPathComponent("Photos"))
        }
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let jpgs = items.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !jpgs.isEmpty { return jpgs }
        }
        return []
    }

    // MARK: Timeline

    /// The slideshow at `t` seconds. `sync` decodes missing photos on the spot
    /// (thumbnails/export); otherwise they load in the background and the frame shows
    /// whatever is ready. `seed` fixes the photo order (nil = this source's own start).
    func frame(at t: Double, sync: Bool, seed: Int? = nil) -> SlideFrame? {
        frame(clock: SlideClock(t: t, seed: seed), sync: sync)
    }

    /// One timeline (every frame but a time-base crossfade's): `frames(at:)` without the arrays,
    /// sets and dictionary copies a frame would otherwise allocate.
    func frame(clock c: SlideClock, sync: Bool) -> SlideFrame? {
        let s = step(c)
        if evicts {
            let keep = (index(s.k - 1, s.seed), index(s.k, s.seed), index(s.k + 1, s.seed))
            lock.lock()
            // only rebuild the cache when it holds a slide this frame doesn't need (a slide change)
            if cache.keys.contains(where: { $0 != keep.0 && $0 != keep.1 && $0 != keep.2 }) {
                cache = cache.filter { $0.key == keep.0 || $0.key == keep.1 || $0.key == keep.2 }
            }
            lock.unlock()
            _ = texture(keep.2, sync: false)                 // prefetch the next photo
        }
        return frame(s, sync: sync)
    }

    private typealias Step = (k: Int, local: Double, m: Float, seed: Int)

    private func step(_ c: SlideClock) -> Step {
        let F = fade
        let tt = max(c.t, 0) + F                     // t = 0 opens fully on the first photo
        let k = Int(floor(tt / interval))
        let local = tt - Double(k) * interval
        let x = min(max(local / F, 0), 1)
        return (k, local, Float(x * x * (3 - 2 * x)), c.seed ?? offset)
    }

    private func frame(_ s: Step, sync: Bool) -> SlideFrame? {
        let iPrev = index(s.k - 1, s.seed), iCur = index(s.k, s.seed)
        var cur = texture(iCur, sync: sync)
        let prev = (s.m < 1) ? texture(iPrev, sync: sync) : nil
        if cur == nil && prev == nil { cur = texture(iCur, sync: true) }   // first frame
        let kbCur = kenBurns(slide: s.k, localTime: s.local, seed: s.seed)
        let kbPrev = kenBurns(slide: s.k - 1, localTime: s.local + interval, seed: s.seed)

        switch (prev, cur) {
        case let (p?, c?) where s.m < 1:
            return SlideFrame(texA: p, kbA: kbPrev, texB: c, kbB: kbCur, mix: s.m)
        case let (_, c?):
            return SlideFrame(texA: c, kbA: kbCur, texB: nil, kbB: kbCur, mix: 0)
        case let (p?, nil):
            return SlideFrame(texA: p, kbA: kbPrev, texB: nil, kbB: kbPrev, mix: 0)
        default:
            return nil
        }
    }

    /// Several timelines at once — the two chains of a crossfade between clocks (a renderer
    /// switching time base). Evicts only photos none of them needs, so the two never take
    /// turns throwing out each other's slides.
    func frames(at clocks: [SlideClock], sync: Bool) -> [SlideFrame?] {
        let steps = clocks.map(step)
        if evicts {
            var keep = Set<Int>()
            for s in steps { keep.formUnion([index(s.k - 1, s.seed), index(s.k, s.seed), index(s.k + 1, s.seed)]) }
            lock.lock()
            cache = cache.filter { keep.contains($0.key) }
            lock.unlock()
            for s in steps { _ = texture(index(s.k + 1, s.seed), sync: false) }   // prefetch the next photo
        }
        return steps.map { frame($0, sync: sync) }
    }

    private func index(_ slide: Int, _ seed: Int) -> Int {
        let n = urls.count
        return ((slide % n + seed % n) % n + n) % n
    }

    /// Per-slide framing: zoom in or out by up to ~13%, drifting across the frame along a
    /// random direction. Seeded by the slide number, so a photo moves differently each
    /// time it comes round.
    private func kenBurns(slide: Int, localTime: Double, seed: Int) -> simd_float4 {
        let s = UInt64(bitPattern: Int64(slide &+ seed &* 7919))
        func h(_ salt: UInt64) -> Double {
            var z = s &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(UInt64(1) << 53)
        }
        let p = min(max(localTime / (interval + fade), 0), 1)
        let zLo = 1.0 + 0.03 * motion, zHi = 1.0 + 0.16 * motion
        let zoom = h(1) < 0.5 ? zLo + (zHi - zLo) * p : zHi - (zHi - zLo) * p
        let a = h(2) * 2 * Double.pi
        let pan = (2 * p - 1) * 0.85 * motion
        return simd_float4(Float(zoom), Float(cos(a) * pan), Float(sin(a) * pan), 0)
    }

    // MARK: Decoding

    private func texture(_ i: Int, sync: Bool) -> MTLTexture? {
        lock.lock()
        if let t = cache[i] { lock.unlock(); return t }
        if failed.contains(i) || (!sync && pending.contains(i)) { lock.unlock(); return nil }
        if !sync { pending.insert(i) }
        lock.unlock()

        if sync {
            let t = decode(urls[i])
            lock.lock()
            if let t { cache[i] = t } else { failed.insert(i) }
            lock.unlock()
            return t
        }
        let url = urls[i]
        CollectionSource.queue.async { [weak self] in
            guard let self else { return }
            let t = self.decode(url)
            self.lock.lock()
            if let t { self.cache[i] = t } else { self.failed.insert(i) }
            self.pending.remove(i)
            self.lock.unlock()
        }
        return nil
    }

    /// Decode (EXIF-rotated, capped at `maxPixel`) and upload with mipmaps, so small
    /// previews and slow zooms minify cleanly.
    private func decode(_ url: URL) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary)
        else { return nil }
        // Redraw into a known RGBA8 layout (ImageIO hands back BGRA/RGB/gray variants that
        // MTKTextureLoader doesn't always map faithfully), stored as raw sRGB values like
        // ImageSource, then build the mip chain on the GPU.
        let w = cg.width, h = cg.height
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
        if let cmd = queue?.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return tex
    }
}
