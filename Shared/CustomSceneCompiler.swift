//  CustomSceneCompiler.swift — a scene package → Metal source → a render pipeline, at runtime.
//
//  The source handed to Metal's compiler is assembled from:
//    the prelude (this file: metal_stdlib, FXUniforms — EffectUniforms.h's layout, checked by
//    tools/gallery --checks against the Swift struct — and the fullscreen vertex function),
//    each engine's headers (its base engine's first), the package's entry (translated first for
//    glsl-source engines; package-local #includes inlined), and the engine's wrapper, which
//    defines `ds_fragment`. `#line` markers before each part make the compiler report errors in
//    the package's own files and line numbers, never the assembled source's.
//  Compiles happen off the main thread (a renderer never waits on one unless it's a tool), are
//  cached by the assembled source's SHA-256 per GPU, and a failure is remembered with its
//  diagnostics until the source changes. A pipeline whose command buffer faults on the GPU (a
//  timeout, a page fault) is disabled until the package is edited (CustomScenes.reportGPUFault).

import Foundation
import Metal
import CryptoKit
import QuartzCore
import simd

/// A package read and assembled, ready to compile (or why it can't be).
struct PreparedScene {
    let id: String
    let packageDir: URL
    let manifest: CustomSceneManifest
    let engine: EngineInfo?
    /// The assembled Metal source (nil: the package can't be compiled — see `diagnostics`).
    let source: String?
    /// SHA-256 of `source` (the pipeline cache's key).
    let hash: String
    /// Problems found before compiling (the manifest, a missing engine, the translator).
    let diagnostics: [Diagnostic]
    /// The entry's file name, as compile errors name it.
    var entryName: String { manifest.entry ?? "scene" }
    var kind: String { engine?.kind ?? "" }
    var isFilm: Bool { kind == "film" }
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// A compile's diagnostics, as an Error.
struct CompileFailure: Error {
    let diagnostics: [Diagnostic]
    init(_ d: [Diagnostic]) { diagnostics = d }
}

enum CustomSceneCompiler {
    /// FXUniforms as Metal sees it — the same layout as EffectUniforms.h (gallery --checks compares
    /// a compiled scene's buffer(0) reflection with MemoryLayout<FXUniforms>).
    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct FXUniforms {
        float2 resolution; float time; int effect;
        float4 p0; float4 p1; float4 p2;
        float4 colorA; float4 colorB;
        float2 srcSize; int fillMode; int glyphCount;
        float4 clock; float4 date;
        float4 sun; float4 moon; float4 sky;
        float4 musicPal0; float4 musicPal1; float4 musicPal2; float4 music; float4 musicRect;
        float4 weather; float4 weather2; float4 weather3;
        float4 scene[16];
    };
    struct DSVOut { float4 pos [[position]]; float2 uv; };
    vertex DSVOut ds_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        DSVOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv  = float2(p.x, 1.0 - p.y);
        return o;
    }

    """
    static let vertexFunction = "ds_vertex"
    static let fragmentFunction = "ds_fragment"

    // MARK: Preparing

    /// Reads and assembles the package at `dir` (installed or not).
    static func prepare(packageAt dir: URL, store: URL) -> PreparedScene {
        let (manifest, mdiags) = CustomScenes.readManifest(packageAt: dir)
        guard let m = manifest else {
            return PreparedScene(id: "", packageDir: dir, manifest: CustomSceneManifest(id: "", name: "", engine: .init(id: "", version: nil), entry: nil),
                                 engine: nil, source: nil, hash: "", diagnostics: mdiags)
        }
        var diags = mdiags
        do { _ = try CustomScenes.packageFiles(dir, manifest: m) } catch CustomSceneError.invalid(let d) { diags += d } catch {}
        guard let engine = CustomScenes.resolveEngine(m.engine, store: store) else {
            let have = CustomScenes.engines(store: store).map { "\($0.id) \($0.version)" }.joined(separator: ", ")
            diags.append(Diagnostic(message: "unknown engine \"\(m.engine.id)\"\(m.engine.version.map { " (\($0))" } ?? "") — installed: \(have.isEmpty ? "none" : have). A pullable engine installs with pullEngine.",
                                    file: "scene.json"))
            return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: nil, source: nil, hash: "", diagnostics: diags)
        }
        guard ["metal-source", "cells", "glsl-source", "film"].contains(engine.kind) else {
            diags.append(Diagnostic(message: "engine kind \"\(engine.kind)\" isn't supported by this build", file: "scene.json"))
            return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
        }
        if diags.contains(where: { $0.severity == .error }) {
            return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
        }
        var parts = [prelude]
        var headerNames = Set(["DotStudio.h"])
        // The engine chain: bases first.
        var chain: [EngineInfo] = [engine]
        var seen = Set([engine.id])
        while let b = chain.first?.manifest.base, chain.count < 4 {
            guard let be = CustomScenes.resolveEngine(b, store: store), seen.insert(be.id).inserted else {
                diags.append(Diagnostic(message: "engine \(engine.id) needs base engine \(b.id) \(b.version ?? ""), which isn't installed", file: "scene.json"))
                return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
            }
            chain.insert(be, at: 0)
        }
        parts.append("#define DS_ENGINE_\(engine.kind.uppercased().replacingOccurrences(of: "-", with: "_")) 1\n")
        for e in chain {
            for h in e.manifest.headers ?? [] {
                guard CustomScenes.isSafeRelativePath(h), let text = try? String(contentsOf: e.url.appendingPathComponent(h), encoding: .utf8) else {
                    diags.append(Diagnostic(message: "engine \(e.id) \(e.version) is missing its header \(h)"))
                    return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
                }
                headerNames.insert((h as NSString).lastPathComponent)
                parts.append("#line 1 \"\(e.id)/\(h)\"\n" + text + "\n")
            }
        }
        // The package's source (a film has none: its engine's wrapper is the whole shader).
        let entry = m.entry ?? ""
        if engine.kind == "film" {
            // (falls through to the wrapper)
        } else if let raw = readText(dir, entry) {
            var body = raw
            if engine.kind == "glsl-source" {
                let t = GLSLTranslator.translate(raw, file: entry)
                body = t.source
                diags += t.diagnostics
            }
            var included = Set([entry])
            body = expandIncludes(body, file: entry, dir: dir, headerNames: headerNames, depth: 0, seen: &included, diags: &diags)
            parts.append("#line 1 \"\(entry)\"\n" + body + "\n")
        } else {
            diags.append(Diagnostic(message: "can't read the entry \"\(entry)\" (UTF-8 text)", file: entry))
            return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
        }
        // The wrapper.
        if let w = engine.manifest.wrapper {
            guard CustomScenes.isSafeRelativePath(w), let text = try? String(contentsOf: engine.url.appendingPathComponent(w), encoding: .utf8) else {
                diags.append(Diagnostic(message: "engine \(engine.id) \(engine.version) is missing its wrapper \(w)"))
                return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
            }
            parts.append("#line 1 \"\(engine.id)/\(w)\"\n" + text + "\n")
        }
        let source = parts.joined()
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        if diags.contains(where: { $0.severity == .error }) {
            return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: nil, hash: "", diagnostics: diags)
        }
        return PreparedScene(id: m.id, packageDir: dir, manifest: m, engine: engine, source: source, hash: hash, diagnostics: diags)
    }

    private static func readText(_ dir: URL, _ rel: String) -> String? {
        guard CustomScenes.isSafeRelativePath(rel) else { return nil }
        let u = dir.appendingPathComponent(rel)
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path), (a[.type] as? FileAttributeType) == .typeRegular,
              ((a[.size] as? Int) ?? 0) <= CustomScenes.maxSourceBytes else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    /// Package-local `#include "file"` inlined (with #line markers), the engine's own headers
    /// (`#include <DotStudio.h>`) dropped — they're already in — line count kept.
    private static func expandIncludes(_ text: String, file: String, dir: URL, headerNames: Set<String>, depth: Int,
                                       seen: inout Set<String>, diags: inout [Diagnostic]) -> String {
        var out: [String] = []
        var lineNo = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#"), let r = t.range(of: "^#\\s*include\\s*[<\"]([^>\"]+)[>\"]", options: .regularExpression) else {
                out.append(String(line)); continue
            }
            let inc = t[r]
            let name = inc.split(whereSeparator: { $0 == "<" || $0 == ">" || $0 == "\"" }).dropFirst().first.map(String.init) ?? ""
            let base = (name as NSString).lastPathComponent
            if headerNames.contains(base) { out.append("// (engine header \(base))"); continue }
            if inc.contains("<") {
                if name.hasPrefix("metal_") || name.hasPrefix("simd/") { out.append(String(line)) }
                else {
                    diags.append(Diagnostic(line: lineNo, column: 1, message: "#include <\(name)>: only the engine's headers and <metal_*> are available", severity: .error, file: file))
                    out.append("")
                }
                continue
            }
            guard depth < 4, CustomScenes.isSafeRelativePath(name), !seen.contains(name), let sub = readText(dir, name) else {
                diags.append(Diagnostic(line: lineNo, column: 1, message: "#include \"\(name)\": not a readable file of this package (or included twice)", severity: .error, file: file))
                out.append("")
                continue
            }
            seen.insert(name)
            let expanded = expandIncludes(sub, file: name, dir: dir, headerNames: headerNames, depth: depth + 1, seen: &seen, diags: &diags)
            out.append("#line 1 \"\(name)\"\n" + expanded + "\n#line \(lineNo + 1) \"\(file)\"")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Diagnostics

    /// Metal's compiler log → diagnostics in the package's files. Lines from the engine's own
    /// headers keep their header's name; lines from the prelude say "engine".
    static func parseLog(_ log: String, prepared: PreparedScene) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let re = try! NSRegularExpression(pattern: "^(.*?):(\\d+):(\\d+): (fatal error|error|warning|note): (.*)$", options: [.anchorsMatchLines])
        let ns = log as NSString
        for mt in re.matches(in: log, range: NSRange(location: 0, length: ns.length)) {
            var file = ns.substring(with: mt.range(at: 1))
            if let r = file.range(of: "program_source") { file = String(file[r]) }
            let line = Int(ns.substring(with: mt.range(at: 2))) ?? 0
            let col = Int(ns.substring(with: mt.range(at: 3))) ?? 0
            let sev = ns.substring(with: mt.range(at: 4))
            let msg = ns.substring(with: mt.range(at: 5))
            let severity: Diagnostic.Severity = sev.contains("error") ? .error : sev == "warning" ? .warning : .note
            if severity == .note && out.count > 40 { continue }
            let d = Diagnostic(line: line, column: col, message: msg, severity: severity,
                               file: file == "program_source" ? "engine" : file)
            if !out.contains(d) { out.append(d) }
            if out.count >= 60 { break }
        }
        if out.isEmpty, !log.isEmpty {
            out.append(Diagnostic(message: String(log.prefix(2000)), severity: .error))
        }
        return out
    }

    // MARK: Compiling

    static func compileOptions() -> MTLCompileOptions {
        let o = MTLCompileOptions()
        if #available(macOS 15.0, *) { o.mathMode = .fast } else { o.fastMathEnabled = true }
        return o
    }

    /// Compiles the prepared source into a pipeline for `format` (blocking: call off the main
    /// thread). Errors come back mapped to the package's lines.
    static func build(_ p: PreparedScene, device: MTLDevice, format: MTLPixelFormat) -> Result<MTLRenderPipelineState, CompileFailure> {
        guard let source = p.source, !p.hasErrors else {
            return .failure(CompileFailure(p.diagnostics.isEmpty ? [Diagnostic(message: "nothing to compile")] : p.diagnostics))
        }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: source, options: compileOptions()) } catch {
            let log = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? "\(error)"
            return .failure(CompileFailure(parseLog(log, prepared: p)))
        }
        guard let v = lib.makeFunction(name: vertexFunction), let f = lib.makeFunction(name: fragmentFunction) else {
            return .failure(CompileFailure([Diagnostic(message: "the engine's wrapper defines no ds_fragment")]))
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        do { return .success(try device.makeRenderPipelineState(descriptor: d)) } catch {
            return .failure(CompileFailure([Diagnostic(message: "pipeline: \(error.localizedDescription)")]))
        }
    }
}

// MARK: - Pipeline cache (process-wide, per GPU and format)

enum CustomScenePipelines {
    enum State: Equatable {
        case ready
        case building
        case failed([Diagnostic])
        /// Faulted on the GPU: off until the package changes.
        case disabled(String)
    }
    private enum Slot {
        case ready(MTLRenderPipelineState)
        case building(DispatchGroup)
        case failed([Diagnostic])
    }
    private static let lock = NSLock()
    private static var slots: [String: Slot] = [:]
    private static var disabled: [String: String] = [:]
    private static let queue = DispatchQueue(label: "com.davidlam.DotStudio.customscenes", qos: .userInitiated, attributes: .concurrent)

    private static func key(_ hash: String, _ device: MTLDevice, _ format: MTLPixelFormat) -> String {
        "\(device.registryID)/\(format.rawValue)/\(hash)"
    }

    /// The pipeline for `p`, if built. `wait`: build it on this thread (tools, validate);
    /// otherwise the build starts in the background and this returns nil until it's done.
    static func pipeline(_ p: PreparedScene, device: MTLDevice, format: MTLPixelFormat, wait: Bool) -> MTLRenderPipelineState? {
        guard !p.hash.isEmpty, p.source != nil else { return nil }
        let k = key(p.hash, device, format)
        lock.lock()
        if disabled[p.hash] != nil { lock.unlock(); return nil }
        switch slots[k] {
        case .ready(let pso)?: lock.unlock(); return pso
        case .failed?: lock.unlock(); return nil
        case .building(let g)?:
            lock.unlock()
            guard wait else { return nil }
            g.wait()
            lock.lock(); defer { lock.unlock() }
            if case .ready(let pso)? = slots[k] { return pso }
            return nil
        case nil: break
        }
        let g = DispatchGroup()
        g.enter()
        slots[k] = .building(g)
        lock.unlock()
        let work = {
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = CustomSceneCompiler.build(p, device: device, format: format)
            lock.lock()
            switch r {
            case .success(let pso): slots[k] = .ready(pso)
            case .failure(let f): slots[k] = .failed(f.diagnostics)
            }
            lastCompileMs[p.hash] = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            lock.unlock()
            g.leave()
        }
        if wait { work(); return pipeline(p, device: device, format: format, wait: false) }
        queue.async(execute: work)
        return nil
    }

    private static var lastCompileMs: [String: Double] = [:]
    /// How long the last compile of `hash` took (ms).
    static func compileMs(_ hash: String) -> Double? { lock.lock(); defer { lock.unlock() }; return lastCompileMs[hash] }

    static func state(_ p: PreparedScene, device: MTLDevice, format: MTLPixelFormat) -> State {
        if p.source == nil { return .failed(p.diagnostics) }
        lock.lock(); defer { lock.unlock() }
        if let r = disabled[p.hash] { return .disabled(r) }
        switch slots[key(p.hash, device, format)] {
        case .ready?: return .ready
        case .failed(let d)?: return .failed(d)
        default: return .building
        }
    }

    /// A command buffer that drew `hash` failed on the GPU: the scene is drawn by its stand-in
    /// until its source changes. The app (which can write the store) leaves a note in the package
    /// so a screensaver starting later skips it too.
    static func reportGPUFault(hash: String, packageDir: URL?, reason: String) {
        lock.lock()
        let first = disabled[hash] == nil
        disabled[hash] = reason
        lock.unlock()
        guard first, let dir = packageDir else { return }
        let note = ["hash": hash, "reason": reason, "at": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: note) {
            try? d.write(to: dir.appendingPathComponent(".gpu-fault.json"), options: .atomic)
        }
    }

    /// Whether a fault note for exactly this source sits in the package.
    static func faultNoted(hash: String, packageDir: URL) -> String? {
        guard let d = try? Data(contentsOf: packageDir.appendingPathComponent(".gpu-fault.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String], o["hash"] == hash else { return nil }
        return o["reason"] ?? "faulted on the GPU"
    }

    static func markDisabled(hash: String, reason: String) {
        lock.lock(); disabled[hash] = reason; lock.unlock()
    }

    static func isDisabled(_ hash: String) -> Bool { lock.lock(); defer { lock.unlock() }; return disabled[hash] != nil }

    /// Frees every pipeline (the screensaver's teardown).
    static func purge() {
        lock.lock()
        slots = slots.filter { if case .building = $0.value { return true } else { return false } }
        lock.unlock()
    }
}

// MARK: - Validate (the MCP server's check before install)

extension CustomScenes {
    static func validate(packageAt url: URL, device: MTLDevice) -> CustomSceneReport {
        validate(packageAt: url, device: device, store: defaultStore)
    }

    /// Manifest, sizes, engine, compile (errors with the package's line numbers), a test frame
    /// (a flat or all-black frame is a warning) and the GPU cost at 5120×2880 (over 3 ms a
    /// frame is a warning; over 60 ms an error — the screensaver couldn't hold 15 fps).
    static func validate(packageAt url: URL, device: MTLDevice, store: URL) -> CustomSceneReport {
        let p = CustomSceneCompiler.prepare(packageAt: url, store: store)
        var report = CustomSceneReport(ok: false, diagnostics: p.diagnostics, gpuMsAt5K: nil, warnings: [],
                                       manifest: p.id.isEmpty && p.manifest.name.isEmpty ? nil : p.manifest,
                                       engine: p.engine.map { "\($0.id) \($0.version)" })
        report.warnings += p.diagnostics.filter { $0.severity == .warning }.map(\.formatted)
        if p.isFilm {
            let f = CustomFilm.validate(p)
            report.diagnostics += f.diagnostics
            report.warnings += f.warnings
        }
        guard !p.hasErrors, p.source != nil, !report.diagnostics.contains(where: { $0.severity == .error }) else { return report }
        let t0 = CFAbsoluteTimeGetCurrent()
        switch CustomSceneCompiler.build(p, device: device, format: .bgra8Unorm) {
        case .failure(let f):
            report.diagnostics += f.diagnostics.filter { !report.diagnostics.contains($0) }
            return report
        case .success(let pso):
            let compileMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if compileMs > 4000 { report.warnings.append(String(format: "compiling took %.1f s — the screensaver waits that long before its first frame", compileMs / 1000)) }
            let bench = CustomSceneBench(device: device, pso: pso, prepared: p)
            // A small frame first: a runaway loop shows here, before it costs seconds at 5K.
            guard let small = bench.render(width: 320, height: 180, time: 2.0) else {
                report.diagnostics.append(Diagnostic(message: "the GPU failed drawing a test frame (\(bench.lastError ?? "error")) — an endless or very long loop?"))
                return report
            }
            if small.ms > 40 {
                report.diagnostics.append(Diagnostic(message: String(format: "%.0f ms for a 320×180 frame: far too slow (a loop that never ends early?)", small.ms)))
                return report
            }
            if small.flat, !p.isFilm { report.warnings.append("the test frame is one flat colour (\(small.describe)) — is dsScene drawing anything?") }
            if let ms = bench.median5K() {
                report.gpuMsAt5K = ms
                if ms > 60 {
                    report.diagnostics.append(Diagnostic(message: String(format: "%.1f ms a frame at 5120×2880: too slow for a screensaver (keep it under 3 ms; 60 is the limit)", ms)))
                } else if ms > 3 {
                    report.warnings.append(String(format: "%.1f ms a frame at 5120×2880 (budget 3 ms): fewer fbm octaves / raymarch steps, or stepped fps, would make it lighter on battery", ms))
                }
            } else {
                report.diagnostics.append(Diagnostic(message: "the GPU failed at 5120×2880 (\(bench.lastError ?? "error"))"))
            }
        }
        report.ok = !report.diagnostics.contains { $0.severity == .error }
        return report
    }
}

/// Renders a compiled custom pipeline offscreen with GPU timestamps (validate; tools/gallery).
final class CustomSceneBench {
    let device: MTLDevice
    let pso: MTLRenderPipelineState
    let prepared: PreparedScene
    private let queue: MTLCommandQueue?
    private(set) var lastError: String?
    var params: [String: Double] = [:]

    init(device: MTLDevice, pso: MTLRenderPipelineState, prepared: PreparedScene) {
        self.device = device; self.pso = pso; self.prepared = prepared
        queue = device.makeCommandQueue()
    }

    struct Frame { var ms: Double; var flat: Bool; var describe: String; var image: CGImage? }

    /// One frame (and `extra` more in the same command buffer: the time is per frame).
    func render(width: Int, height: Int, time: Float, frames: Int = 1, readBack: Bool = true) -> Frame? {
        guard let queue, let cmd = queue.makeCommandBuffer() else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = readBack ? .shared : .private
        guard let target = device.makeTexture(descriptor: td) else { return nil }
        let inst = EffectInstance.customScene(prepared.manifest)
        var u = FXUniforms()
        inst.pack(into: &u)
        var vals = inst.params
        vals.merge(params) { _, b in b }
        var instP = inst; instP.params = vals
        CustomSceneLink.fillStatic(&u, inst: instP, prepared: prepared, wall: Date(), location: nil,
                                   weather: .clear, musicPlaying: false, musicLevel: 0)
        u.resolution = simd_float2(Float(width), Float(height))
        let assets = CustomSceneAssets.textures(for: prepared, device: device)
        for f in 0..<frames {
            u.time = time + Float(f) * 0.37
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            for i in 0..<4 { enc.setFragmentTexture(assets[i], index: 9 + i) }
            enc.setFragmentSamplerState(CustomSceneAssets.sampler(device), index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error {
            lastError = cmd.error?.localizedDescription ?? "command buffer error"
            return nil
        }
        let ms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000 / Double(frames)
        guard readBack else { return Frame(ms: ms, flat: false, describe: "", image: nil) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var lo = [255, 255, 255], hi = [0, 0, 0]
        var sum = [0, 0, 0]
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for c in 0..<3 {
                let v = Int(bytes[i + 2 - c])               // BGRA → R, G, B
                lo[c] = min(lo[c], v); hi[c] = max(hi[c], v); sum[c] += v
            }
        }
        let n = max(width * height, 1)
        let flat = (0..<3).allSatisfy { hi[$0] - lo[$0] <= 3 }
        let desc = "rgb \(sum[0] / n), \(sum[1] / n), \(sum[2] / n)"
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let img = CGDataProvider(data: Data(bytes) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                    bitmapInfo: info, provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return Frame(ms: ms, flat: flat, describe: desc, image: img)
    }

    /// GPU ms a frame at 5120×2880: the median of 5 command buffers of 2 frames (after a warm-up).
    func median5K(width: Int = 5120, height: Int = 2880) -> Double? {
        guard render(width: width, height: height, time: 1, frames: 1, readBack: false) != nil else { return nil }
        var ms: [Double] = []
        for i in 0..<5 {
            guard let f = render(width: width, height: height, time: Float(i) * 3.1 + 2, frames: 2, readBack: false) else { return nil }
            ms.append(f.ms)
        }
        ms.sort()
        return ms[ms.count / 2]
    }
}
