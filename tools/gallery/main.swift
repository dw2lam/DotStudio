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
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    default: break
    }
}

let store = SharedStore(role: .app)
guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { print("no renderer"); exit(1) }
renderer.location = loc
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
        guard let cg = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: t,
                                                sourceTexOverride: photoTex) else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let name = p.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let tl = t == t.rounded() ? "\(Int(t))" : String(format: "%.3f", t)
        var suffix = times.count > 1 ? "@" + tl : ""
        if let clk { suffix += "@" + clk.replacingOccurrences(of: ":", with: "") }
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)\(suffix).png"))
        print(String(format: "%@%@ %@  %.0f ms", p.isScene ? "[scene] " : "[look]  ", p.name, suffix, ms))
    }
    }
}
