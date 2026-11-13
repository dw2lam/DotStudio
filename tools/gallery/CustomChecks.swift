//  tools/gallery/CustomChecks.swift — the Custom Scene checks of `gallery --checks`
//  (Shared/CustomScenes.swift, docs/ai/CONTRACT.md). Every package is installed into the temp
//  store (DOTSTUDIO_STORE_DIR); scratch packages live in a temp folder removed at the end.

import AppKit
import AVFoundation
import Metal

/// Writes a scene package into `dir` (scene.json from `manifest`, plus `files`).
func writePackage(_ dir: URL, manifest: [String: Any], files: [String: String]) {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
        try? d.write(to: dir.appendingPathComponent("scene.json"))
    }
    for (name, text) in files {
        let u = dir.appendingPathComponent(name)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }
}

/// A short H.264 clip of one flat colour (film checks).
func writeTestClip(_ url: URL, rgb: (Double, Double, Double), seconds: Double = 1.0, fps: Int32 = 24,
                   w: Int = 160, h: Int = 90) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)
    let n = Int(Double(fps) * seconds)
    let (r, g, b) = (UInt8(rgb.0 * 255), UInt8(rgb.1 * 255), UInt8(rgb.2 * 255))
    for i in 0..<n {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            for x in 0..<w { let o = y * bpr + x * 4; base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed
}

func customSceneChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    guard ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil else {
        print("SKIP  Custom Scene checks: DOTSTUDIO_STORE_DIR isn't set (they install packages into the store)")
        return true
    }
    let fm = FileManager.default
    let storeURL = store.baseDir
    guard let dev = MTLCreateSystemDefaultDevice() else { check(false, "custom: a GPU"); return false }
    let work = fm.temporaryDirectory.appendingPathComponent("ds-custom-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    func meanDiff(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return .infinity }
        let n = min(CFDataGetLength(da), CFDataGetLength(db)), pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
        var s = 0
        for i in 0..<n where i % 4 != 3 { s += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(s) / Double(n / 4 * 3)
    }
    /// A live frame of `p` (renderFrame: the saver's / wallpaper's path), on its own renderer.
    func frame(_ p: Preset, mode: FXPipelines.Mode = .blocking, wait: Bool = true, w: Int = 320, h: Int = 200) -> CGImage? {
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store, pipelines: mode) else { return nil }
        r.waitsForScenePipelines = wait
        r.apply(p, source: SourceSpec())
        if mode == .fastStart {
            let until = CFAbsoluteTimeGetCurrent() + 20
            while !r.framePipelinesReady(), CFAbsoluteTimeGetCurrent() < until { Thread.sleep(forTimeInterval: 0.02) }
        }
        return r.renderFrame(width: w, height: h, settled: true)
    }
    /// The stand-in a Custom Scene shows when its package can't draw (same colours, no package).
    func fallback(_ p: Preset) -> CGImage? {
        var q = p
        q.effects[0].custom = CustomSceneRef(id: "missing-package-00000000")
        return frame(q)
    }
    func mean(_ i: CGImage?) -> (Double, Double, Double) {
        guard let i, let d = i.dataProvider?.data else { return (0, 0, 0) }
        let n = CFDataGetLength(d), b = CFDataGetBytePtr(d)!
        var s = (0, 0, 0)
        for o in stride(from: 0, to: n, by: 4) { s.0 += Int(b[o + 2]); s.1 += Int(b[o + 1]); s.2 += Int(b[o]) }
        let c = Double(n / 4) * 255
        return (Double(s.0) / c, Double(s.1) / c, Double(s.2) / c)
    }

    // 1. The runtime prelude's FXUniforms is EffectUniforms.h's layout (size and field offsets,
    //    from a compiled scene's reflection).
    do {
        let dir = work.appendingPathComponent("layout")
        writePackage(dir, manifest: ["format": 1, "id": "layout-00000001", "name": "Layout", "engine": ["id": "metal"], "entry": "scene.metal"],
                     files: ["scene.metal": "float4 dsScene(float2 uv, DSContext ctx) { return float4(ctx.colorA * ctx.p[15] + ctx.music.a * ctx.weather.fog + ctx.sun.elevation + ctx.res.x, 1.0); }\n"])
        let prep = CustomSceneCompiler.prepare(packageAt: dir, store: storeURL)
        var size = -1
        var offsets: [String: Int] = [:]
        if let src = prep.source, let lib = try? dev.makeLibrary(source: src, options: CustomSceneCompiler.compileOptions()) {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "ds_vertex"); d.fragmentFunction = lib.makeFunction(name: "ds_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            var refl: MTLAutoreleasedRenderPipelineReflection?
            _ = try? dev.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &refl)
            if let b = refl?.fragmentBindings.first(where: { $0.type == .buffer && $0.index == 0 }) as? MTLBufferBinding {
                size = b.bufferDataSize
                for m in b.bufferStructType?.members ?? [] { offsets[m.name] = m.offset }
            }
        }
        let want: [String: Int] = ["resolution": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.resolution)!,
                                   "colorA": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.colorA)!,
                                   "clock": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.clock)!,
                                   "musicPal0": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.musicPal0)!,
                                   "weather3": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.weather3)!,
                                   "scene": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.scene)!,
                                   "still": MemoryLayout<FXUniforms>.offset(of: \FXUniforms.still)!]
        let same = want.allSatisfy { offsets[$0.key] == $0.value }
        check(size == MemoryLayout<FXUniforms>.stride && same,
              "custom: the runtime prelude's FXUniforms matches EffectUniforms.h (\(size) / \(MemoryLayout<FXUniforms>.stride) bytes; offsets \(same ? "match" : "\(offsets) ≠ \(want)"))")
    }

    // 2. The cells engine's CellKit.h is Shared/Scenes/CellKit_funcs.h, byte for byte.
    if let root = ProcessInfo.processInfo.environment["DOTSTUDIO_REPO_ROOT"], let engines = CustomScenes.builtInEnginesDir {
        let a = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Shared/Scenes/CellKit_funcs.h"))
        let b = try? Data(contentsOf: engines.appendingPathComponent("cells/1/CellKit.h"))
        check(a != nil && a == b, "custom: Engines/cells/1/CellKit.h is a copy of Shared/Scenes/CellKit_funcs.h (re-copy it when that changes)")
    }

    // 3. Every built-in engine is found, and every example package validates, installs and renders
    //    through the live path — its own pipeline, not the stand-in — within 3 ms at 5K.
    let engines = CustomScenes.engines(store: storeURL)
    check(Set(engines.map(\.id)).isSuperset(of: ["metal", "cells", "film"]) && engines.allSatisfy(\.builtIn),
          "custom: built-in engines \(engines.map { "\($0.id) \($0.version)" })")
    var examples = 0
    for e in engines {
        for dir in e.exampleURLs {
            let r = CustomScenes.validate(packageAt: dir, device: dev, store: storeURL)
            examples += 1
            guard r.ok, let id = try? CustomScenes.install(packageAt: dir, into: storeURL),
                  let m = CustomScenes.manifest(id: id, store: storeURL) else {
                check(false, "custom: example \(e.id)/\(dir.lastPathComponent) validates (\(r.diagnostics.map(\.formatted).prefix(3)))")
                continue
            }
            let p = Preset.customScene(m)
            let img = frame(p), fb = fallback(p)
            let d = meanDiff(img, fb)
            let status = CustomSceneLink.shared(store: storeURL).status(id)
            var ms = r.gpuMsAt5K ?? 99
            if ms > 3.0 {           // a busy GPU: the best of two more benches
                let prep = CustomSceneCompiler.prepare(packageAt: dir, store: storeURL)
                if case .success(let pso) = CustomSceneCompiler.build(prep, device: dev, format: .bgra8Unorm) {
                    let b = CustomSceneBench(device: dev, pso: pso, prepared: prep)
                    for _ in 0..<2 { ms = min(ms, b.median5K() ?? 99) }
                }
            }
            check(img != nil && d > 2 && status == .ready && ms <= 3.0,
                  String(format: "custom: example %@/%@ compiles, renders its own frame (Δ stand-in %.1f), %.2f ms at 5K (≤ 3)",
                         e.id, dir.lastPathComponent, d, ms))
        }
    }
    check(examples >= 6, "custom: \(examples) example packages across the built-in engines (≥ 6)")

    // 4. A broken package: diagnostics at the package's own lines (its entry and a file it
    //    includes, past the engine's prelude), and the style draws the calm stand-in.
    do {
        let dir = work.appendingPathComponent("broken")
        writePackage(dir, manifest: ["format": 1, "id": "broken-0000b0b0", "name": "Broken", "engine": ["id": "metal", "version": ">=1"],
                                     "entry": "scene.metal", "colors": ["a": ["label": "Sky", "default": [0.2, 0.4, 0.8]]]],
                     files: ["scene.metal": "#include <DotStudio.h>\n// a comment\n#include \"helpers.metal\"\nfloat4 dsScene(float2 uv, DSContext ctx) {\n    float3 c = helperColour(uv);\n    return float4(c + missingThing, 1.0);\n}\n",
                             "helpers.metal": "// helpers\nstatic float3 helperColour(float2 uv) {\n    return float3(uv, 0.5) * notDeclared;\n}\n"])
        let r = CustomScenes.validate(packageAt: dir, device: dev, store: storeURL)
        let errs = r.diagnostics.filter { $0.severity == .error }
        let atEntry = errs.contains { $0.file == "scene.metal" && $0.line == 6 && $0.message.contains("missingThing") }
        let atHelper = errs.contains { $0.file == "helpers.metal" && $0.line == 3 && $0.message.contains("notDeclared") }
        check(!r.ok && atEntry && atHelper,
              "custom: compile errors at the package's lines (scene.metal:6, helpers.metal:3): \(errs.map(\.formatted).prefix(4))")
        if let id = try? CustomScenes.install(packageAt: dir, into: storeURL), let m = CustomScenes.manifest(id: id, store: storeURL) {
            let p = Preset.customScene(m)
            let img = frame(p)
            let c = mean(img)
            let status = CustomSceneLink.shared(store: storeURL).status(id)
            var failedWithLines = false
            if case .failed(let d) = status { failedWithLines = d.contains { $0.line == 6 } }
            check(img != nil && meanDiff(img, fallback(p)) < 1 && c.2 > c.0 && failedWithLines,
                  String(format: "custom: a broken scene renders the stand-in (colour A gradient, mean rgb %.2f %.2f %.2f) and is flagged with its errors", c.0, c.1, c.2))
        } else {
            check(false, "custom: a broken scene still installs (it draws the stand-in)")
        }
        // the manifest's own errors
        let bad = work.appendingPathComponent("badmanifest")
        writePackage(bad, manifest: ["format": 1, "name": "Bad", "engine": ["id": "metal"], "entry": "../escape.metal",
                                     "params": (0..<17).map { ["key": "k\($0)", "label": "K", "kind": "slider", "min": 0, "max": 1] }],
                     files: [:])
        let rb = CustomScenes.validate(packageAt: bad, device: dev, store: storeURL)
        check(!rb.ok && rb.diagnostics.contains { $0.message.contains("at most 16") } && rb.diagnostics.contains { $0.message.contains("inside the package") }
              && (try? CustomScenes.install(packageAt: bad, into: storeURL)) == nil,
              "custom: 17 params and an entry outside the package are refused (validate and install)")
        let big = work.appendingPathComponent("big")
        writePackage(big, manifest: ["format": 1, "name": "Big", "engine": ["id": "metal"], "entry": "scene.metal"],
                     files: ["scene.metal": String(repeating: "// padding padding padding padding padding padding\n", count: 6000)])
        check(!CustomScenes.validate(packageAt: big, device: dev, store: storeURL).ok
              && (try? CustomScenes.install(packageAt: big, into: storeURL)) == nil, "custom: a source over 256 KB is refused")
    }

    // 5. An unknown engine fails cleanly: a diagnostic naming it, the stand-in draws.
    do {
        let dir = work.appendingPathComponent("unknown")
        writePackage(dir, manifest: ["format": 1, "id": "unknown-engine-0000e0e0", "name": "Unknown", "engine": ["id": "hologram", "version": ">=3"], "entry": "scene.holo"],
                     files: ["scene.holo": "?"])
        let r = CustomScenes.validate(packageAt: dir, device: dev, store: storeURL)
        let id = try? CustomScenes.install(packageAt: dir, into: storeURL)
        var drawn = false, flagged = false
        if let id, let m = CustomScenes.manifest(id: id, store: storeURL) {
            let p = Preset.customScene(m)
            drawn = meanDiff(frame(p), fallback(p)) < 1
            if case .failed = CustomSceneLink.shared(store: storeURL).status(id) { flagged = true }
        }
        check(!r.ok && r.diagnostics.contains { $0.message.contains("unknown engine \"hologram\"") } && drawn && flagged,
              "custom: an unknown engine fails cleanly (\(r.diagnostics.first?.message.prefix(60) ?? "-")…), the stand-in draws")
    }

    // 6. Library round trip: the reference survives; no other effect writes one; a reference that
    //    isn't a package id (a path) is dropped by sanitize.
    do {
        let ex = engines.first { $0.id == "metal" }?.exampleURLs.first
        let m = ex.flatMap { try? CustomScenes.install(packageAt: $0, into: storeURL) }.flatMap { CustomScenes.manifest(id: $0, store: storeURL) }
        var lib = DefaultPresets.makeLibrary()
        // built-in film scenes (Commute) are Custom Scenes in the default library already
        let builtInRefs = lib.presets.flatMap(\.effects).filter { $0.custom != nil }.count
        if let m { var p = Preset.customScene(m); p.effects[0].params["speed"] = 0.9; lib.presets.append(p) }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(lib)) ?? Data()
        var back = try? JSONDecoder().decode(Library.self, from: data)
        _ = back?.sanitize()
        let json = String(decoding: data, as: UTF8.self)
        let refs = json.components(separatedBy: "\"custom\":{").count - 1
        check(m != nil && back == lib && refs == 1 + builtInRefs && back?.presets.last?.effects.first?.custom?.id == m?.id,
              "custom: a library with a Custom Scene round-trips (reference + params kept; only Custom Scenes write \"custom\": 1 + \(builtInRefs) built-in)")
        var hostile = Preset.customScene(m ?? CustomSceneManifest(id: "x-00000000", name: "x", engine: .init(id: "metal", version: nil), entry: "s.metal"))
        hostile.effects[0].custom = CustomSceneRef(id: "../../Library/Keychains")
        hostile.effects[0].params["speed"] = .nan
        hostile.sanitize()
        check(hostile.effects[0].custom == nil && hostile.effects[0].params["speed"] == nil,
              "custom: sanitize drops a reference that isn't a package id, and NaN params")
    }

    // 7. A GPU fault disables the scene until it's edited (reinstalled with another source).
    if let ex = engines.first(where: { $0.id == "metal" })?.exampleURLs.first {
        // (a copy of its own: another id and source, so the fault never touches the example)
        let copy = work.appendingPathComponent("faulty")
        try? fm.removeItem(at: copy)
        try? fm.copyItem(at: ex, to: copy)
        var fj = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: copy.appendingPathComponent("scene.json")))) as? [String: Any]) ?? [:]
        fj["id"] = "faulty-0000fa17"
        if let d = try? JSONSerialization.data(withJSONObject: fj) { try? d.write(to: copy.appendingPathComponent("scene.json")) }
        let fsrc = copy.appendingPathComponent("scene.metal")
        if let t = try? String(contentsOf: fsrc, encoding: .utf8) { try? (t + "\n// faulty \(UUID())\n").write(to: fsrc, atomically: true, encoding: .utf8) }
        if let id = try? CustomScenes.install(packageAt: copy, into: storeURL), let m = CustomScenes.manifest(id: id, store: storeURL) {
            let p = Preset.customScene(m)
            let hash = CustomSceneLink(store: storeURL).prepared(id)?.hash ?? ""
            CustomScenePipelines.reportGPUFault(hash: hash, packageDir: CustomScenes.packageDir(id: id, store: storeURL), reason: "test fault")
            let off = meanDiff(frame(p), fallback(p)) < 1
            var disabled = false
            if case .disabled = CustomSceneLink(store: storeURL).status(id) { disabled = true }
            let src = copy.appendingPathComponent("scene.metal")
            if let t = try? String(contentsOf: src, encoding: .utf8) { try? (t + "\n// edited\n").write(to: src, atomically: true, encoding: .utf8) }
            _ = try? CustomScenes.install(packageAt: copy, into: storeURL)
            let back = meanDiff(frame(p), fallback(p)) > 2
            check(off && disabled && back, "custom: after a GPU fault the scene draws its stand-in (flagged disabled) until edited, then draws again")
        }
    }

    // 8. The screensaver's path (fastStart): the first frame waits for the custom pipeline; a
    //    blocking host draws the stand-in while a fresh compile runs, never waiting on it.
    if let ex = engines.first(where: { $0.id == "metal" })?.exampleURLs.first,
       let id = try? CustomScenes.install(packageAt: ex, into: storeURL), let m = CustomScenes.manifest(id: id, store: storeURL) {
        let p = Preset.customScene(m)
        let saver = frame(p, mode: .fastStart, wait: false)
        check(saver != nil && meanDiff(saver, fallback(p)) > 2, "custom: a fastStart (screensaver) renderer's first frame is the scene, not its stand-in")
        let dir = work.appendingPathComponent("fresh")
        try? fm.removeItem(at: dir); try? fm.copyItem(at: ex, to: dir)
        let src = dir.appendingPathComponent("scene.metal")
        if let t = try? String(contentsOf: src, encoding: .utf8) { try? (t + "\n// fresh \(UUID())\n").write(to: src, atomically: true, encoding: .utf8) }
        var mj = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("scene.json")))) as? [String: Any]) ?? [:]
        mj["id"] = "fresh-compile-0000f0f0"
        if let d = try? JSONSerialization.data(withJSONObject: mj) { try? d.write(to: dir.appendingPathComponent("scene.json")) }
        if let fid = try? CustomScenes.install(packageAt: dir, into: storeURL), let fm2 = CustomScenes.manifest(id: fid, store: storeURL) {
            let fp = Preset.customScene(fm2)
            let t0 = CFAbsoluteTimeGetCurrent()
            let first = frame(fp, wait: false)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            check(first != nil && meanDiff(first, fallback(fp)) < 1,
                  String(format: "custom: a live (blocking) renderer draws the stand-in while the scene compiles, never waiting (%.0f ms)", ms))
        }
    }

    // 9. Pullable engines: an offline index (tools/engines/build-index.sh), SHA-256 verified.
    if let idx = ProcessInfo.processInfo.environment["DOTSTUDIO_TEST_ENGINES_INDEX"], fm.fileExists(atPath: idx) {
        setenv("DOTSTUDIO_ENGINES_INDEX", idx, 1)
        defer { unsetenv("DOTSTUDIO_ENGINES_INDEX") }
        let sem = DispatchSemaphore(value: 0)
        var available: [EngineIndexEntry] = []
        var pulled: EngineInfo?
        var pullError: String?
        Task {
            available = (try? await CustomScenes.availableEngines()) ?? []
            do { pulled = try await CustomScenes.pullEngine(id: "shadertoy", store: storeURL) } catch { pullError = error.localizedDescription }
            sem.signal()
        }
        sem.wait()
        check(available.contains { $0.id == "shadertoy" } && pulled?.id == "shadertoy" && pulled?.builtIn == false
              && CustomScenes.engines(store: storeURL).contains { $0.id == "shadertoy" },
              "custom: pullEngine(shadertoy) from an offline index installs it into <store>/engines (\(pullError ?? "ok"))")
        for dir in pulled?.exampleURLs ?? [] {
            let r = CustomScenes.validate(packageAt: dir, device: dev, store: storeURL)
            var rendered = false
            if r.ok, let id = try? CustomScenes.install(packageAt: dir, into: storeURL), let m = CustomScenes.manifest(id: id, store: storeURL) {
                let p = Preset.customScene(m)
                rendered = meanDiff(frame(p), fallback(p)) > 2
            }
            check(r.ok && rendered, String(format: "custom: shadertoy example %@ translates, compiles and renders (%.2f ms at 5K) %@",
                                           dir.lastPathComponent, r.gpuMsAt5K ?? -1, r.diagnostics.map(\.formatted).prefix(3).joined(separator: "; ")))
        }
        // a tampered index (another SHA-256): refused, nothing installed
        if let data = try? Data(contentsOf: URL(fileURLWithPath: idx)), var index = try? JSONDecoder().decode(EngineIndex.self, from: data) {
            let base = URL(fileURLWithPath: idx).deletingLastPathComponent()
            for i in index.engines.indices {
                index.engines[i].sha256 = String(repeating: "0", count: 64)
                index.engines[i].url = base.appendingPathComponent(index.engines[i].url).absoluteString
            }
            let tampered = work.appendingPathComponent("tampered-index.json")
            try? JSONEncoder().encode(index).write(to: tampered)
            setenv("DOTSTUDIO_ENGINES_INDEX", tampered.path, 1)
            let other = work.appendingPathComponent("store2", isDirectory: true)
            var err: String?
            Task {
                do { _ = try await CustomScenes.pullEngine(id: "shadertoy", store: other) } catch { err = error.localizedDescription }
                sem.signal()
            }
            sem.wait()
            check(err?.contains("SHA-256") == true && !fm.fileExists(atPath: other.appendingPathComponent("engines/shadertoy/1").path),
                  "custom: a download whose SHA-256 doesn't match the index is refused (\(err ?? "no error"))")
        }
    } else {
        print("SKIP  pullable engine checks: no DOTSTUDIO_TEST_ENGINES_INDEX (render.sh builds one with tools/engines/build-index.sh)")
    }

    // 10. Film: clips chosen by sun and weather; posters in one-off renders; video in live ones.
    do {
        let c = { (v: String) in CustomSceneManifest.Clip(variant: v, file: "\(v).mov", loop: true) }
        let all = ["day", "golden", "night", "rain"].map(c)
        let picks = [CustomFilm.choose(all, elevation: 40, raining: false)?.variant, CustomFilm.choose(all, elevation: 3, raining: false)?.variant,
                     CustomFilm.choose(all, elevation: -20, raining: false)?.variant, CustomFilm.choose(all, elevation: 40, raining: true)?.variant,
                     CustomFilm.choose([c("day"), c("night")], elevation: 2, raining: true)?.variant,
                     CustomFilm.choose([c("any")], elevation: -30, raining: false)?.variant]
        check(picks == ["day", "golden", "night", "rain", "day", "any"], "film: variants by sun and weather, with fallbacks \(picks.map { $0 ?? "nil" })")
        let dir = work.appendingPathComponent("film")
        writePackage(dir, manifest: ["format": 1, "id": "test-film-0000f11e", "name": "Test Film", "engine": ["id": "film"],
                                     "clips": [["variant": "day", "file": "clips/day.mov", "loop": true],
                                               ["variant": "night", "file": "clips/night.mov", "loop": true]]], files: [:])
        try? fm.createDirectory(at: dir.appendingPathComponent("clips"), withIntermediateDirectories: true)
        let made = writeTestClip(dir.appendingPathComponent("clips/day.mov"), rgb: (0.9, 0.6, 0.2))
            && writeTestClip(dir.appendingPathComponent("clips/night.mov"), rgb: (0.05, 0.1, 0.5))
        let r = CustomScenes.validate(packageAt: dir, device: dev, store: storeURL)
        check(made && r.ok, "film: a two-clip package (generated test clips) validates (\(r.diagnostics.map(\.formatted)); \(r.warnings.count) warnings)")
        if let id = try? CustomScenes.install(packageAt: dir, into: storeURL), let m = CustomScenes.manifest(id: id, store: storeURL) {
            let p = Preset.customScene(m)
            let el = CustomSceneLink.sun(at: Date(), location: loc).elevation
            let want = CustomFilm.choose(m.clips ?? [], elevation: el, raining: false)?.variant ?? "?"
            func looks(_ col: (Double, Double, Double)) -> String { col.0 > 0.7 && col.2 < 0.35 ? "day" : col.2 > 0.35 && col.0 < 0.2 ? "night" : "?" }
            let tr = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
            tr?.location = loc
            let img = tr?.renderThumbnail(preset: p, source: SourceSpec(), width: 160, height: 100)
            let col = mean(img)
            check(img != nil && looks(col) == want,
                  String(format: "film: a thumbnail shows the %@ clip's poster, aspect-filled (mean rgb %.2f %.2f %.2f; sun %.0f°)", want, col.0, col.1, col.2, el))
            if let r2 = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) {
                r2.waitsForScenePipelines = true
                r2.location = loc
                r2.apply(p, source: SourceSpec())
                var live: CGImage?
                for _ in 0..<40 { live = r2.renderFrame(width: 160, height: 100); Thread.sleep(forTimeInterval: 0.03) }
                let lc = mean(live)
                check(live != nil && looks(lc) == want,
                      String(format: "film: live frames play the %@ clip from the video decoder (mean rgb %.2f %.2f %.2f)", want, lc.0, lc.1, lc.2))
                r2.setMediaPaused(true)
            }
            // The live grain (and halation): engine params in the Inspector, zero-mean, stepped at the
            // clip's frame rate, one cheap pass.
            let specs = Preset.customScene(m).effects[0].paramSpecs.map(\.key)
            check(specs.contains("ds.grain") && specs.contains("ds.halation")
                  && Preset.customScene(m).effects[0].defaultParamValues["ds.grain"] == 0.35,
                  "film: Grain (default 0.35) and Halation are engine params in the Inspector \(specs)")
            func still(grain: Double, halation: Double = 0, time: Float) -> CGImage? {
                var q = Preset.customScene(m)
                q.effects[0].params["ds.grain"] = grain
                q.effects[0].params["ds.halation"] = halation
                let tr = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
                tr?.location = loc
                return tr?.renderThumbnail(preset: q, source: SourceSpec(), width: 320, height: 200, time: time)
            }
            let clean = still(grain: 0, time: 1), grainy = still(grain: 1, time: 1)
            let sameFrame = still(grain: 1, time: 1.01), nextFrame = still(grain: 1, time: 1.2)
            let mc = mean(clean), mg = mean(grainy)
            let drift = max(abs(mc.0 - mg.0), abs(mc.1 - mg.1), abs(mc.2 - mg.2))
            check(meanDiff(clean, grainy) > 1 && drift < 0.02 && meanDiff(grainy, sameFrame) < 0.01 && meanDiff(grainy, nextFrame) > 1,
                  String(format: "film: grain shows (Δ %.1f), keeps the mean (drift %.3f), holds within a clip frame and changes with the next", meanDiff(clean, grainy), drift))
            let halo = still(grain: 0, halation: 1, time: 1)
            check(meanDiff(clean, halo) < 40, String(format: "film: halation on a flat clip stays subtle (Δ %.1f)", meanDiff(clean, halo)))
            let prep = CustomSceneCompiler.prepare(packageAt: CustomScenes.packageDir(id: id, store: storeURL), store: storeURL)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 3840, height: 2160, mipmapped: false)
            td.usage = .shaderRead; td.storageMode = .private
            if case .success(let pso) = CustomSceneCompiler.build(prep, device: dev, format: .bgra8Unorm), let clip = dev.makeTexture(descriptor: td) {
                let benches = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0)].map { g, h -> CustomSceneBench in
                    let b = CustomSceneBench(device: dev, pso: pso, prepared: prep)
                    b.textures = [clip, clip]
                    b.params = ["ds.grain": g, "ds.halation": h]
                    return b
                }
                // the best of 8 interleaved rounds of 6 frames each (the GPU's clocks and other work
                // make single runs noisy; interleaving keeps the three configurations comparable)
                // — and when another app is drawing on the GPU meanwhile (a live wallpaper, the real
                // DotStudio), up to 3 such batches, keeping each configuration's best so far
                var best = [Double](repeating: .infinity, count: 3)
                for batch in 0..<3 {
                    for round in 0..<8 {
                        for (i, b) in benches.enumerated() {
                            if let f = b.render(width: 5120, height: 2880, time: Float(batch * 8 + round) * 0.7 + 1, frames: 6, readBack: false) {
                                best[i] = min(best[i], f.ms)
                            }
                        }
                    }
                    if best[1] - best[0] <= 0.3 && best[2] - best[0] <= 0.3 { break }
                }
                let plain = best[0], grained = best[1], full = best[2]
                // (the pass itself — a 4K clip aspect-filled to 5K — is the floor any video pass pays)
                check(grained - plain <= 0.3 && full - plain <= 0.3,
                      String(format: "film: grain adds %.3f ms (with halation %.3f) at 5120×2880 over the plain clip pass (%.3f ms): ≤ 0.3",
                             grained - plain, full - plain, plain))
            }
        }
    }
    return ok
}
