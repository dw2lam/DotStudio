//  PreviewRenderer.swift — offscreen stills, contact sheets and GPU timings of any style, in
//  process, through the same MetalRenderer path tools/gallery uses (renderThumbnail for stills,
//  renderFrame + GPU timestamps for benchmarks). Never touches a display.

import AppKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

final class PreviewRenderer {
    let store: SharedStore
    private var renderer: MetalRenderer?

    init(store: SharedStore) { self.store = store }

    private func shared() throws -> MetalRenderer {
        if let r = renderer { return r }
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else {
            throw ToolError("No Metal GPU available to render previews.")
        }
        r.waitsForScenePipelines = true      // draw what the scene's own pipeline draws, never a stand-in
        renderer = r
        return r
    }

    struct Options {
        var width = 1280
        var height = 800
        var time: Double = 4
        var clock: Date?
        var weather: String?               // a WeatherCondition raw value; nil = the scene's own pick
        var musicCard = false
        var location: (lat: Double, lon: Double)?
    }

    static let weatherNames = WeatherCondition.allCases.map(\.rawValue)

    /// The style's frame at `time` seconds as a CGImage.
    func still(_ preset: Preset, library: Library, _ o: Options) throws -> CGImage {
        let r = try shared()
        r.location = o.location ?? library.locationLat.flatMap { la in library.locationLon.map { (la, $0) } }
        r.clockOverride = o.clock
        defer { r.clockOverride = nil; WeatherLink.forced = nil }
        if let w = o.weather {
            guard let c = WeatherCondition(rawValue: w) else { throw ToolError("Unknown weather \(w). Use one of \(Self.weatherNames.joined(separator: ", ")).") }
            WeatherLink.forced = WeatherMix.preset(c)
        }
        r.setMusic(o.musicCard ? Self.sampleSong : .empty)
        guard let cg = r.renderThumbnail(preset: preset, source: library.source, width: o.width, height: o.height,
                                         time: Float(o.time)) else {
            throw ToolError("The renderer returned no image for “\(preset.name)”.")
        }
        guard o.musicCard else { return cg }
        return composite(cg, music: library.musicSettings, now: o.clock ?? Date(), width: o.width, height: o.height)
    }

    /// N frames from `start` over `span` seconds, in a grid.
    func contactSheet(_ preset: Preset, library: Library, _ o: Options, frames n: Int, span: Double) throws -> (CGImage, [Double]) {
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellW = o.width / cols, cellH = o.height / cols
        let times = (0..<n).map { o.time + span * Double($0) / Double(max(n - 1, 1)) }
        guard let ctx = CGContext(data: nil, width: cellW * cols, height: cellH * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ToolError("couldn't make the contact sheet") }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cellW * cols, height: cellH * rows))
        for (i, t) in times.enumerated() {
            var fo = o
            fo.width = cellW; fo.height = cellH; fo.time = t
            if let c = o.clock { fo.clock = c.addingTimeInterval(t - o.time) }
            let img = try still(preset, library: library, fo)
            let col = i % cols, row = i / cols
            let rect = CGRect(x: col * cellW, y: (rows - 1 - row) * cellH, width: cellW, height: cellH).insetBy(dx: 1, dy: 1)
            ctx.draw(img, in: rect)
        }
        return (ctx.makeImage()!, times)
    }

    /// GPU milliseconds per live frame at `width`×`height` (min, median of 20), as the saver
    /// draws it (MetalRenderer.renderFrame with GPU timestamps — immune to CPU load).
    func benchmark(_ preset: Preset, library: Library, width: Int = 5120, height: Int = 2880) throws -> (min: Double, median: Double) {
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { throw ToolError("No Metal GPU available.") }
        r.waitsForScenePipelines = true
        r.location = library.locationLat.flatMap { la in library.locationLon.map { (la, $0) } }
        r.apply(preset, source: library.source)
        for _ in 0..<6 { _ = r.renderFrame(width: width, height: height); Thread.sleep(forTimeInterval: 0.05) }
        r.measuresGPUTime = true
        _ = r.takeGPUSeconds()
        var ms: [Double] = []
        for _ in 0..<20 {
            _ = r.renderFrame(width: width, height: height)
            Thread.sleep(forTimeInterval: 0.01)
            ms.append(r.takeGPUSeconds() * 1000)
        }
        ms.sort()
        return (ms[0], ms[ms.count / 2])
    }

    static var gpuName: String { MTLCreateSystemDefaultDevice()?.name ?? "no GPU" }

    // MARK: Music card

    /// A made-up song for previews with the music card on.
    static var sampleSong: MusicSnapshot {
        var st = MusicState()
        st.title = "Harbour Lights"
        st.artist = "The Quiet Hours"
        st.album = "Low Tide"
        st.trackID = "preview"
        st.isPlaying = true
        st.duration = 214
        st.position = 63
        st.positionAt = Date().timeIntervalSince1970
        return MusicSnapshot(state: st, artwork: sampleArt, revision: 1)
    }

    private static let sampleArt: CGImage = {
        let c = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(srgbRed: 0.10, green: 0.16, blue: 0.30, alpha: 1),
                                    CGColor(srgbRed: 0.93, green: 0.62, blue: 0.40, alpha: 1)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 256, y: 256), options: [])
        c.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.75, alpha: 0.9))
        c.fillEllipse(in: CGRect(x: 150, y: 150, width: 56, height: 56))
        return c.makeImage()!
    }()

    private func composite(_ cg: CGImage, music: MusicSpec, now: Date, width W: Int, height H: Int) -> CGImage {
        let scale: CGFloat = W >= 2400 ? 2 : 1
        let layer = MusicOverlayLayer()
        layer.contentsScale = scale
        layer.frame = CGRect(x: 0, y: 0, width: CGFloat(W) / scale, height: CGFloat(H) / scale)
        layer.reduceMotion = true
        var m = music
        m.setDisplay(.corner)
        layer.update(mode: .card(m.corner), music: Self.sampleSong, settings: m, now: now, animated: false)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return cg }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage() ?? cg
    }

    // MARK: PNG

    static func png(_ cg: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Mean luminance 0…1 and a coarse "is it blank" check, for the tool's text.
    static func stats(_ cg: CGImage) -> (mean: Double, spread: Double) {
        let w = 32, h = 20
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.interpolationQuality = .medium
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var lums: [Double] = []
        for i in stride(from: 0, to: buf.count, by: 4) {
            lums.append((0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])) / 255)
        }
        let mean = lums.reduce(0, +) / Double(lums.count)
        let spread = (lums.max() ?? 0) - (lums.min() ?? 0)
        return (mean, spread)
    }
}
