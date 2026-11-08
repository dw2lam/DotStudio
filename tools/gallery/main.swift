//  tools/gallery/main.swift — headless gallery renderer for the DEFAULT presets.
//  Unlike the app's DOTSTUDIO_SHOTS mode it never reads the user's library, so it
//  always shows what ships. Build + run with tools/gallery/render.sh.
//
//  usage: gallery <outDir> [--photo file.jpg] [--times 1.6,9] [--only substr] [--pack]
//                          [--size 1600x1000] [--bench]

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
var W = 1600, H = 1000
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--photo": photo = args.removeFirst()
    case "--times": times = args.removeFirst().split(separator: ",").compactMap { Float($0) }
    case "--only": only = args.removeFirst().lowercased()
    case "--pack": includePack = true
    case "--bench": bench = true
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    default: break
    }
}

let store = SharedStore(role: .app)
guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { print("no renderer"); exit(1) }
renderer.location = (37.77, -122.42)
let lib = DefaultPresets.makeLibrary()
var presets = lib.presets
if includePack { presets += DefaultPresets.coolPack() }
if let only { presets = presets.filter { $0.name.lowercased().contains(only) } }

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

if bench {
    // Min-of-8 wall time per full offscreen render (includes alloc + readback floor,
    // so compare against a trivial preset such as Matrix Rain).
    for p in presets {
        var best = Double.infinity
        for i in 0..<8 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: Float(i) * 0.7,
                                         sourceTexOverride: photoTex)
            best = min(best, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        print(String(format: "%6.1f ms  %@", best, p.name))
    }
    exit(0)
}

for p in presets {
    for t in times {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let cg = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: t,
                                                sourceTexOverride: photoTex) else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let name = p.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let suffix = times.count > 1 ? "@\(Int(t))" : ""
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)\(suffix).png"))
        print(String(format: "%@%@ %@  %.0f ms", p.isScene ? "[scene] " : "[look]  ", p.name, suffix, ms))
    }
}
