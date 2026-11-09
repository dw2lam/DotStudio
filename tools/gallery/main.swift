//  tools/gallery/main.swift — headless gallery renderer for the DEFAULT presets.
//  Unlike the app's DOTSTUDIO_SHOTS mode it never reads the user's library, so it
//  always shows what ships. Build + run with tools/gallery/render.sh.
//
//  usage: gallery <outDir> [--photo file.jpg] [--times 1.6,9] [--only substr] [--pack]
//                          [--size 1600x1000] [--bench] [--gpubench] [--solo] [--set key=val,key=val]
//  --set overrides params on each preset's first effect (e.g. --set tilt=70,scale=1.4).
//  --gpubench times just the first effect's fragment pass with GPU timestamps
//  (no alloc/readback, immune to CPU load): the number to compare shader costs by.
//  --solo keeps only each preset's first effect (benchmark one shader, not its post chain).
//  --slides renders one frame per built-in slideshow photo; --looks skips the Scenes.
//  Wall clock (clock scenes, Ocean Horizon's Follow the Sun): --clock 06:40[,07:00,…] renders
//  each preset at each local time on --date 2026-06-21 (default today), in --tz America/Toronto
//  (default the Mac's), at --loc 43.7,-79.4 (default San Francisco; "none" = the no-location fallback).
//  Music: DOTSTUDIO_MUSIC_FAKE=<fixture.json> feeds the Now Playing scene; --overlay composites the
//  native-resolution foreground (MusicOverlayLayer, via layer.render(in:)) onto Now Playing presets;
//  --card bottomLeft|bottomRight|topLeft|topRight|all composites the corner card onto every other
//  preset; --scale 2 sets the overlay's pixels per point (default 2 from 2400 px wide, else 1);
//  --tag name appends "@name" to the file names.
//  --checks runs the live-renderer checks (wall-clock time base, synced slideshow, held-frame
//  track change, rapid skips) through MetalRenderer.renderFrame and exits non-zero on a failure.

import AppKit
import Metal
import MetalKit

var args = Array(CommandLine.arguments.dropFirst())
guard let outDir = args.first else { print("usage: gallery <outDir> [...]"); exit(2) }
args.removeFirst()
var photo: String?
var times: [Float] = [1.6]
var only: String?
var includePack = false
var bench = false
var overrides: [String: Double] = [:]
var solo = false
var gpuBench = false
var looksOnly = false
var W = 1600, H = 1000
var clocks: [String] = []
var dateArg: String?
var tzArg: String?
var loc: (lat: Double, lon: Double)? = (37.77, -122.42)
var overlay = false
var cardCorners: [MusicSpec.Corner] = []
var overlayScale: CGFloat?
var tag: String?
var musicFadeBench = false
var runChecks = false
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--photo": photo = args.removeFirst()
    case "--times": times = args.removeFirst().split(separator: ",").compactMap { Float($0) }
    case "--only": only = args.removeFirst().lowercased()
    case "--pack": includePack = true
    case "--bench": bench = true
    case "--solo": solo = true
    case "--gpubench": gpuBench = true
    case "--looks": looksOnly = true
    case "--slides":
        // One frame per built-in photo, mid-hold (the slideshow is a pure function of time).
        let s = SourceSpec.builtInPhotos
        let n = CollectionSource.builtInPhotoURLs().count
        let fade = min(4.0, s.slideInterval * 0.35)
        times = (0..<max(n, 1)).map { Float(Double($0) * s.slideInterval + s.slideInterval * 0.5 - fade) }
    case "--set":
        for kv in args.removeFirst().split(separator: ",") {
            let p = kv.split(separator: "=")
            if p.count == 2, let v = Double(p[1]) { overrides[String(p[0])] = v }
        }
    case "--clock": clocks = args.removeFirst().split(separator: ",").map(String.init)
    case "--date": dateArg = args.removeFirst()
    case "--tz": tzArg = args.removeFirst()
    case "--loc":
        let v = args.removeFirst()
        let p = v.split(separator: ",").compactMap { Double($0) }
        loc = p.count == 2 ? (p[0], p[1]) : nil
    case "--overlay": overlay = true
    case "--musicfade": musicFadeBench = true
    case "--checks": runChecks = true
    case "--card":
        let v = args.removeFirst()
        cardCorners = v == "all" ? MusicSpec.Corner.allCases : [MusicSpec.Corner(rawValue: v) ?? .bottomLeft]
    case "--scale": overlayScale = CGFloat(Double(args.removeFirst()) ?? 2)
    case "--tag": tag = args.removeFirst()
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    default: break
    }
}

let store = SharedStore(role: .app)
guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { print("no renderer"); exit(1) }
renderer.location = loc
let musicFeed = MusicFeed(baseDir: store.baseDir)
musicFeed.poll()
renderer.setMusic(musicFeed.snapshot)

/// The music foreground composited over a Metal frame, the way the saver stacks its layers.
func compositeMusic(_ cg: CGImage, preset: Preset, corner: MusicSpec.Corner?, now: Date) -> CGImage {
    let mode: MusicOverlayLayer.Mode
    if let inst = preset.musicScene {
        mode = .full(MusicSceneOptions(inst))
    } else if let corner {
        mode = .card(corner)
    } else {
        return cg
    }
    let scale = overlayScale ?? (W >= 2400 ? 2 : 1)
    let layer = MusicOverlayLayer()
    layer.contentsScale = scale
    layer.frame = CGRect(x: 0, y: 0, width: CGFloat(W) / scale, height: CGFloat(H) / scale)
    layer.reduceMotion = true
    layer.update(mode: mode, music: musicFeed.snapshot, settings: MusicSpec(), now: now, animated: false)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return cg }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.scaleBy(x: scale, y: scale)
    layer.render(in: ctx)
    return ctx.makeImage() ?? cg
}

/// Live-path checks: what two renderers, a held wallpaper frame and a skipping listener see.
func liveChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    func meanDiff(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height else { return .infinity }
        func px(_ i: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: i.width * i.height * 4)
            buf.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: i.width, height: i.height, bitsPerComponent: 8,
                                  bytesPerRow: i.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            }
            return buf
        }
        let pa = px(a), pb = px(b)
        return Double(zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(pa.count)
    }
    let w = 320, h = 200

    // 1. Wall-clock time stays small: Float frame steps at 120 Hz near the end of the period.
    let top = Float(MetalRenderer.wallClockPeriod - 0.001)
    check(top.ulp <= 0.00025, String(format: "wall-clock t < %.0f s: Float resolution %.3f ms at the top (seconds since midnight: %.1f ms)",
                                     MetalRenderer.wallClockPeriod, Double(top.ulp) * 1000, Double(Float(86_399).ulp) * 1000))
    check(abs(MetalRenderer.wallPhase(3600 * 491_234 + 12.5) - 12.5) < 1e-6, "wall phase = seconds into the hour")

    // 2. Match Screensaver on a slideshow Look: two wall-clock renderers draw the same photo and framing.
    let look = Preset(name: "Look", effects: [EffectInstance(.halftone)])
    func slideRenderer(_ base: MetalRenderer.TimeBase) -> MetalRenderer {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = base
        r.apply(look, source: .builtInPhotos)
        return r
    }
    let wallFrames = (0..<4).map { _ in slideRenderer(.wallClock).renderFrame(width: w, height: h) }
    let worst = (1..<wallFrames.count).map { meanDiff(wallFrames[0], wallFrames[$0]) }.max() ?? .infinity
    check(worst < 1.5, String(format: "4 wall-clock slideshow renderers agree (worst mean |Δ| %.2f)", worst))
    let instance = (0..<4).map { _ in slideRenderer(.instance).renderFrame(width: w, height: h) }
    let spread = (1..<instance.count).map { meanDiff(instance[0], instance[$0]) }.max() ?? 0
    print(String(format: "info  per-instance slideshow renderers differ by up to %.2f (random first photo)", spread))

    // 3. A held wallpaper frame after a track change shows the NEW cover (settled draw).
    func cover(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        c.setFillColor(CGColor(srgbRed: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1)); c.fill(CGRect(x: 8, y: 8, width: 24, height: 40))
        return c.makeImage()!
    }
    func song(_ id: String, _ art: CGImage?, rev: Int) -> MusicSnapshot {
        var st = MusicState()
        st.title = "Song \(id)"; st.artist = "Artist"; st.trackID = id; st.isPlaying = true
        st.duration = 200; st.position = 20; st.positionAt = Date().timeIntervalSince1970
        return MusicSnapshot(state: st, artwork: art, revision: rev)
    }
    let A = song("a", cover(0.95, 0.85, 0.2), rev: 1), B = song("b", cover(0.1, 0.3, 0.9), rev: 2)
    let C = song("c", cover(0.9, 0.2, 0.3), rev: 3)
    let np = SceneCatalog.musicPresets.first { $0.name.contains("Cover") } ?? SceneCatalog.musicPresets[0]
    func musicRenderer(_ snap: MusicSnapshot) -> MetalRenderer {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = .wallClock          // same t for every renderer, so frames compare
        r.setMusic(snap)
        r.apply(np, source: SourceSpec())
        return r
    }
    let held = musicRenderer(A)
    _ = held.renderFrame(width: w, height: h)
    held.setMusic(B)
    let heldB = held.renderFrame(width: w, height: h, settled: true)
    let freshB = musicRenderer(B).renderFrame(width: w, height: h)
    let freshA = musicRenderer(A).renderFrame(width: w, height: h)
    let dB = meanDiff(heldB, freshB), dA = meanDiff(heldB, freshA)
    check(dB < 1.0 && dA > 10, String(format: "held frame after a cover change shows the new cover (Δ new %.2f, Δ old %.2f)", dB, dA))
    let running = musicRenderer(A)
    _ = running.renderFrame(width: w, height: h)
    running.setMusic(B)
    let firstFade = running.renderFrame(width: w, height: h)
    print(String(format: "info  a continuous host's first frame after the change is still the old cover (Δ old %.2f) — it fades over %.1f s",
                 meanDiff(firstFade, freshA), MetalRenderer.musicFadeSeconds))

    // 4. Skipping again mid-fade never cuts from the half-faded mix.
    let skip = musicRenderer(A)
    _ = skip.renderFrame(width: w, height: h)
    skip.setMusic(B)
    _ = skip.renderFrame(width: w, height: h)
    Thread.sleep(forTimeInterval: 0.6)
    let mid = skip.renderFrame(width: w, height: h)
    skip.setMusic(C)
    let after = skip.renderFrame(width: w, height: h)
    let jump = meanDiff(mid, after), span = meanDiff(freshA, freshB)
    check(jump < span * 0.1, String(format: "a skip 0.6 s into a fade doesn't pop (Δ %.2f vs A→B %.2f)", jump, span))

    // 5. Wall clock → instance keeps the motion where it was (no jump to t = 0).
    let lc = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
    lc.timeBase = .wallClock
    lc.apply(Preset(name: "LC", effects: [EffectInstance(.liquidChrome)]), source: SourceSpec())
    _ = lc.renderFrame(width: w, height: h)
    let before = lc.animationTime()
    lc.timeBase = .instance
    let afterSwitch = lc.animationTime()
    check(abs(afterSwitch - before) < 0.05, String(format: "wall clock → instance continues t (%.2f s → %.2f s)", before, afterSwitch))
    return ok
}
if runChecks { exit(liveChecks() ? 0 : 1) }

if let tzArg, let tz = TimeZone(identifier: tzArg) { NSTimeZone.default = tz }
/// Local wall time HH:MM on --date (or today) in the --tz zone.
func wallDate(_ hhmm: String) -> Date? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = NSTimeZone.default
    var dc = cal.dateComponents([.year, .month, .day], from: Date())
    if let d = dateArg?.split(separator: "-").compactMap({ Int($0) }), d.count == 3 {
        dc.year = d[0]; dc.month = d[1]; dc.day = d[2]
    }
    let hm = hhmm.split(separator: ":").compactMap { Int($0) }
    guard hm.count == 2 else { return nil }
    dc.hour = hm[0]; dc.minute = hm[1]
    return cal.date(from: dc)
}
let lib = DefaultPresets.makeLibrary()
var presets = lib.presets
if includePack { presets += DefaultPresets.coolPack() }
if let only { presets = presets.filter { $0.name.lowercased().contains(only) } }
if looksOnly { presets = [Preset(name: "Source")] + presets.filter { !$0.isScene } }
if solo {
    for i in presets.indices where presets[i].effects.count > 1 { presets[i].effects = [presets[i].effects[0]] }
}
if !overrides.isEmpty {
    for i in presets.indices where !presets[i].effects.isEmpty {
        presets[i].effects[0].params.merge(overrides) { _, new in new }
    }
}

var source = lib.source
var photoTex: MTLTexture?
if let photo {
    let loader = MTKTextureLoader(device: renderer.device)
    photoTex = try? loader.newTexture(URL: URL(fileURLWithPath: photo), options: [
        .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)])
    source.kind = .image
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if gpuBench {
    // One fullscreen pass of each preset's first effect, encoded the way MetalRenderer does,
    // 3 frames per command buffer; GPU time from the command buffer's own timestamps.
    let dev = renderer.device
    let libURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("default.metallib")
    guard let queue = dev.makeCommandQueue(), let lib = try? dev.makeLibrary(URL: libURL),
          let vfn = lib.makeFunction(name: "fx_vertex"), let ffn = lib.makeFunction(name: "fx_fragment") else {
        print("gpubench: no metallib at \(libURL.path)"); exit(1)
    }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = vfn; pd.fragmentFunction = ffn
    pd.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pso = try! dev.makeRenderPipelineState(descriptor: pd)
    let sd = MTLSamplerDescriptor()
    sd.minFilter = .linear; sd.magFilter = .linear
    sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
    let samp = dev.makeSamplerState(descriptor: sd)!
    let tex = PlanetTextures(device: dev, queue: queue)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = dev.makeTexture(descriptor: td)!, input = dev.makeTexture(descriptor: td)!
    let astro = MetalRenderer.astro(location: renderer.location)
    // Now Playing samples slots 7/8: bench with the fixture's artwork, mipmapped as the renderer binds it.
    var artTex: MTLTexture = input
    if let art = musicFeed.artwork {
        let w = art.width, h = art.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(art, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        let t = dev.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        let cb = queue.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
        bl.generateMipmaps(for: t); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        artTex = t
    }
    let pal = musicFeed.snapshot.palette
    for p in presets {
        guard let inst = p.effects.first(where: { $0.enabled }) else { continue }
        var u = FXUniforms()
        inst.pack(into: &u)
        u.resolution = simd_float2(Float(W), Float(H))
        if inst.kind == .universe {
            u.p1 = simd_float4(astro.sun.x, astro.sun.y, astro.sun.z, 0)
            u.p2 = simd_float4(astro.userLon, astro.userLat, astro.hasLoc ? 1 : 0, (inst.params["orbits"] ?? 1) > 0.5 ? 1 : 0)
        }
        let wall = clocks.first.flatMap(wallDate) ?? Date()
        (u.clock, u.date) = MetalRenderer.wallClock(wall)
        MetalRenderer.fillLiveSky(&u, inst: inst, now: wall, time: 0, location: renderer.location)
        if inst.kind == .nowPlaying {
            // Steady playback; --musicfade benches the 1.6 s track-change cross-fade instead
            // (both backgrounds rendered).
            let has: Float = musicFeed.artwork != nil ? 1 : 0
            u.music = musicFadeBench ? simd_float4(has * 3, 0.4, 1, 0.8) : simd_float4(has, 0.4, 1, 1000)
            func c(_ i: Int) -> simd_float4 {
                i < pal.count ? simd_float4(Float(pal[i].r), Float(pal[i].g), Float(pal[i].b), 1) : .zero
            }
            u.musicPal0 = c(0); u.musicPal1 = c(1); u.musicPal2 = c(2)
            let r = MusicGeometry.artUV(MusicLayoutKind(rawValue: Int(u.p0.x.rounded())) ?? .album,
                                        size: CGSize(width: W, height: H), options: MusicSceneOptions(inst))
            u.musicRect = simd_float4(r.x, r.y, r.w, r.h)
        }
        var samples: [Double] = []
        for rep in 0..<14 {
            let cmd = queue.makeCommandBuffer()!
            for f in 0..<3 {
                u.time = Float(rep * 3 + f) * 1.7
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
                enc.setRenderPipelineState(pso)
                enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(input, index: 1)
                enc.setFragmentTexture(tex.earthDay, index: 2)
                enc.setFragmentTexture(tex.earthNight, index: 3)
                enc.setFragmentTexture(tex.planets, index: 4)
                enc.setFragmentTexture(input, index: 5)
                enc.setFragmentTexture(input, index: 6)
                enc.setFragmentTexture(artTex, index: 7)
                enc.setFragmentTexture(artTex, index: 8)
                enc.setFragmentSamplerState(samp, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
            if rep >= 2 { samples.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000 / 3) }
        }
        samples.sort()
        print(String(format: "%6.2f ms GPU  (median %5.2f)  %@ [%@]", samples[0], samples[samples.count / 2],
                     p.name, inst.kind.displayName))
    }
    exit(0)
}

if bench {
    // Wall time per full offscreen render (includes the alloc + readback floor, so compare
    // presets against each other, not against a frame budget). 4 warm-up renders let the
    // GPU clock ramp, then min and median of 24 renders spread over a minute of scene time.
    for p in presets {
        for i in 0..<4 {
            _ = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: Float(i),
                                         sourceTexOverride: photoTex)
        }
        var ms: [Double] = []
        for i in 0..<24 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: Float(i) * 2.5,
                                         sourceTexOverride: photoTex)
            ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        ms.sort()
        print(String(format: "%6.1f ms  (median %5.1f)  %@", ms[0], ms[ms.count / 2], p.name))
    }
    exit(0)
}

let clockList: [String?] = clocks.isEmpty ? [nil] : clocks
for p in presets {
    for clk in clockList {
    renderer.clockOverride = clk.flatMap(wallDate)
    for t in times {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let frame = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: t,
                                                   sourceTexOverride: photoTex) else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let corners: [MusicSpec.Corner?] = p.isMusicScene || cardCorners.isEmpty ? [nil] : cardCorners
        for corner in corners {
        let cg = (overlay || corner != nil)
            ? compositeMusic(frame, preset: p, corner: corner, now: renderer.clockOverride ?? Date()) : frame
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let name = p.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let tl = t == t.rounded() ? "\(Int(t))" : String(format: "%.3f", t)
        var suffix = times.count > 1 ? "@" + tl : ""
        if let clk { suffix += "@" + clk.replacingOccurrences(of: ":", with: "") }
        if let corner { suffix += "@card-" + corner.rawValue }
        if let tag { suffix += "@" + tag }
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)\(suffix).png"))
        print(String(format: "%@%@ %@  %.0f ms", p.isScene ? "[scene] " : "[look]  ", p.name, suffix, ms))
        }
    }
    }
}
