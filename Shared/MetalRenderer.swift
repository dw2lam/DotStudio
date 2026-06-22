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
    private let planetTex: PlanetTextures

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var drawableSize: CGSize = .zero

    // Serial dither (error diffusion / Riemersma) compute resources.
    private var computePSO: MTLComputePipelineState?
    private var gridTex: MTLTexture?
    private var errBuf: MTLBuffer?
    private var gridW = 0, gridH = 0

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

        if let cfn = library.makeFunction(name: "dither_serial") {
            computePSO = try? device.makeComputePipelineState(function: cfn)
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        glyphs = GlyphAtlas.make(device: device)
        planetTex = PlanetTextures(device: device, queue: queue)

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
            let inst: EffectInstance? = (i == 0) ? nil : effects[i - 1]

            // Serial dither (error diffusion / Riemersma) runs a compute pass first,
            // producing a coarse grid that the blit pass (effect 38) upscales.
            var fragInput = input
            var serialBlit = false
            if let inst = inst, isSerialDither(inst), let cpso = computePSO {
                encodeSerialDither(cmd, pso: cpso, inst: inst, input: input, size: size)
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

            var u = FXUniforms()
            u.resolution = res
            u.time = time
            u.glyphCount = Int32(GlyphAtlas.count)
            u.srcSize = simd_float2(Float(fragInput.width), Float(fragInput.height))
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
            } else if serialBlit {
                u.effect = 38                      // upscale the precomputed dither grid
                u.p0 = simd_float4(Float(gridW), Float(gridH), 0, 0)
            } else {
                inst!.pack(into: &u)
                if inst!.kind == .universe {
                    let a = MetalRenderer.astro()
                    u.p1 = simd_float4(a.sun.x, a.sun.y, a.sun.z, 0)
                    u.p2 = simd_float4(a.userLon, 0, 0, 0)
                }
            }

            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            enc.setFragmentTexture(fragInput, index: 0)
            enc.setFragmentTexture(glyphs ?? dummy, index: 1)
            enc.setFragmentTexture(planetTex.earthDay, index: 2)
            enc.setFragmentTexture(planetTex.earthNight, index: 3)
            enc.setFragmentTexture(planetTex.planets, index: 4)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    // MARK: Astronomy (Universe effect)

    /// Live sun direction (view space) + the user's longitude, from the wall clock and
    /// the Mac's time zone — no Location permission needed.
    static func astro() -> (sun: simd_float3, userLon: Float) {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        let utcH = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0 + Double(c.second ?? 0) / 3600.0
        let doy = Double(cal.ordinality(of: .day, in: .year, for: now) ?? 1)
        let decl = 23.44 * .pi / 180.0 * sin(2.0 * .pi * (284.0 + doy) / 365.0)   // solar declination
        let subLon = (12.0 - utcH) * 15.0 * .pi / 180.0                            // subsolar longitude
        let userLon = Double(TimeZone.current.secondsFromGMT()) / 3600.0 * 15.0 * .pi / 180.0
        let rel = subLon - userLon
        let sun = simd_float3(Float(cos(decl) * sin(rel)), Float(sin(decl)), Float(cos(decl) * cos(rel)))
        return (sun, Float(userLon))
    }

    // MARK: Serial dither (compute)

    private func isSerialDither(_ inst: EffectInstance) -> Bool {
        inst.kind == .dither && Int((inst.params["algo"] ?? 1).rounded()) >= 4
    }

    private func ensureGrid(_ w: Int, _ h: Int) {
        if gridTex?.width == w, gridTex?.height == h, errBuf != nil { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        gridTex = device.makeTexture(descriptor: d)
        errBuf = device.makeBuffer(length: max(w * h, 1) * MemoryLayout<Float>.stride, options: .storageModePrivate)
    }

    private func encodeSerialDither(_ cmd: MTLCommandBuffer, pso: MTLComputePipelineState,
                                    inst: EffectInstance, input: MTLTexture, size: CGSize) {
        let cell = max(Double(inst.g("cell")), 1)
        var gw = max(1, Int(size.width / cell))
        var gh = max(1, Int(Double(gw) * size.height / max(size.width, 1)))
        let maxCells = 130_000   // cap so the single-threaded serial scan stays fast
        if gw * gh > maxCells {
            let f = (Double(maxCells) / Double(gw * gh)).squareRoot()
            gw = max(1, Int(Double(gw) * f)); gh = max(1, Int(Double(gh) * f))
        }
        ensureGrid(gw, gh)
        guard let gridTex = gridTex, let errBuf = errBuf,
              let enc = cmd.makeComputeCommandEncoder() else { return }
        var u = FXUniforms()
        u.resolution = simd_float2(Float(size.width), Float(size.height))
        inst.pack(into: &u)                        // p0 = (cell, levels, mono, algo), colorA/B
        let algo = Int((inst.params["algo"] ?? 4).rounded())
        let kernelId = (algo == 16) ? 100 : (algo - 4)
        u.p1 = simd_float4(Float(kernelId), Float(gw), Float(gh), 0)
        enc.setComputePipelineState(pso)
        enc.setBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
        enc.setTexture(input, index: 0)
        enc.setTexture(gridTex, index: 1)
        enc.setBuffer(errBuf, offset: 0, index: 1)
        enc.setSamplerState(sampler, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        gridW = gw; gridH = gh
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
