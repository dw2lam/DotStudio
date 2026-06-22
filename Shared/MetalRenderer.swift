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

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var drawableSize: CGSize = .zero

    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var loggedFirstFrame = false

    // Render description
    private(set) var preset: Preset?
    private var source = SourceSpec()
    private var media: MediaSource?
    private let store: SharedStore

    init?(pixelFormat: MTLPixelFormat, store: SharedStore) {
        guard let device = MTLCreateSystemDefaultDevice(),
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

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
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
        if sourceChanged {
            startTime = CACurrentMediaTime()
            loadMedia(for: source)
        }
    }

    private func loadMedia(for source: SourceSpec) {
        media = nil
        guard source.kind != .gradient, let name = source.mediaFilename else { return }
        let url = store.mediaURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch source.kind {
        case .image: media = ImageSource(url: url, device: device)
        case .video: media = VideoSource(url: url, device: device)
        case .gradient: break
        }
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
        // Ensure offscreen textures exist & match the drawable. In a screensaver the
        // view is created at full size before the delegate is set, so the initial
        // drawableSizeWillChange callback can be missed — recreate here if needed.
        let ds = view.drawableSize
        if texA == nil || texB == nil || drawableSize != ds {
            mtkView(view, drawableSizeWillChange: ds)
        }
        guard let preset = preset,
              let cmd = queue.makeCommandBuffer(),
              let final = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let texA = texA, let texB = texB else { return }

        let t = Float(CACurrentMediaTime() - startTime)
        let sTex = media?.currentTexture()
        if !loggedFirstFrame {
            loggedFirstFrame = true
            store.debug("first draw size=\(drawableSize) effects=\(preset.effects.count) srcTexNil=\(sTex == nil) sourceKind=\(source.kind.rawValue)")
        }
        encodePasses(cmd, finalDescriptor: final, pingA: texA, pingB: texB,
                     size: drawableSize, time: t, preset: preset, source: source,
                     sourceTex: sTex)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Encode the full source→effects pass chain. Last pass writes into `finalDescriptor`.
    private func encodePasses(_ cmd: MTLCommandBuffer, finalDescriptor: MTLRenderPassDescriptor,
                              pingA: MTLTexture, pingB: MTLTexture, size: CGSize, time: Float,
                              preset: Preset, source: SourceSpec, sourceTex: MTLTexture?) {
        let res = simd_float2(Float(size.width), Float(size.height))
        let useGradient = (source.kind == .gradient) || (sourceTex == nil)
        let effects = preset.effects.filter { $0.enabled }
        let passCount = 1 + effects.count
        let pong = [pingA, pingB]

        for i in 0..<passCount {
            let isLast = (i == passCount - 1)
            let input: MTLTexture = (i == 0) ? (sourceTex ?? dummy) : pong[(i - 1) % 2]

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

            var u = FXUniforms()
            u.resolution = res
            u.time = time
            u.glyphCount = Int32(GlyphAtlas.count)
            u.srcSize = simd_float2(Float(input.width), Float(input.height))
            u.fillMode = Int32(source.fillMode)

            if i == 0 {
                if useGradient {
                    u.effect = 1
                    u.p0 = simd_float4(Float(source.gradientAngle), Float(source.gradientDrift), 0, 0)
                    u.colorA = source.colorA.simd
                    u.colorB = source.colorB.simd
                } else {
                    u.effect = 0   // passthrough source-fit
                    u.srcSize = simd_float2(Float(sourceTex?.width ?? input.width),
                                            Float(sourceTex?.height ?? input.height))
                }
            } else {
                effects[i - 1].pack(into: &u)
            }

            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(glyphs ?? dummy, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    // MARK: Thumbnails (offscreen, one frame, synchronous)

    func renderThumbnail(preset: Preset, source: SourceSpec, width: Int, height: Int, time: Float = 1.2) -> CGImage? {
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

        // Load an image source synchronously; video/gradient render on the gradient fallback.
        var thumbTex: MTLTexture?
        if source.kind == .image, let name = source.mediaFilename {
            thumbTex = ImageSource(url: store.mediaURL(name), device: device)?.currentTexture()
        }

        encodePasses(cmd, finalDescriptor: desc, pingA: pingA, pingB: pingB,
                     size: CGSize(width: width, height: height), time: time,
                     preset: preset, source: source, sourceTex: thumbTex)
        cmd.commit()
        cmd.waitUntilCompleted()

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
