//  CustomScenesAPI.swift — what dotstudio-mcp needs from the custom-scene engine side.
//
//  The engine side is Shared/CustomScenes.swift (`enum CustomScenes`: scene packages, runtime
//  shader compile, built-in and pullable engines; contract docs/ai/CONTRACT.md §1–4, §8). The
//  tools code against this protocol with their own value types (contract §7), so they can be
//  exercised with a stand-in too:
//    • CustomScenesBridge — the real thing: CustomScenes.* on this Mac's GPU and the MCP's store;
//    • FakeCustomScenes   — the self-test's structural stand-in (DOTSTUDIO_MCP_TEST_FAKES=1).

import Foundation
import Metal

struct CSDiagnostic {
    var line: Int?
    var column: Int?
    var message: String
    var severity: String          // "error" | "warning" | "note"
    /// The package file it's in (the entry, an included file, scene.json) or an engine header;
    /// nil = the entry.
    var file: String? = nil
    var json: JSONObject {
        var o: JSONObject = ["message": message, "severity": severity]
        if let line { o["line"] = line }
        if let column { o["column"] = column }
        if let file { o["file"] = file }
        return o
    }
}

struct CSReport {
    var ok: Bool
    var diagnostics: [CSDiagnostic]
    var gpuMsAt5K: Double?
    var warnings: [String]
}

struct CSEngine {
    var id: String
    var version: String
    var kind: String              // metal-source | glsl-source | cells | film
    var builtIn: Bool
    /// The engine's guide.md (engines/<id> in read_guide), when it has one.
    var guide: URL?
    var summary: String
}

struct CSEngineIndexEntry {
    var id: String
    var version: String
    var summary: String
    var size: Int
    var minApp: String
}

protocol CustomScenesAPI {
    /// False when this build has no custom-scene engine: every call below then throws.
    var isAvailable: Bool { get }
    /// Manifest + compile of a package folder, without installing it.
    func validate(packageAt url: URL) throws -> CSReport
    /// Copy a valid package into <store>/scenes (replacing one with the same id); its id.
    func install(packageAt url: URL) throws -> String
    func remove(id: String) throws
    /// Installed packages' scene.json manifests (as JSON, unknown fields kept).
    func installed() -> [JSONObject]
    /// Built-in + pulled engines.
    func engines() -> [CSEngine]
    /// The engines that can be pulled (engines-index.json on the `engines` GitHub release).
    func availableEngines() throws -> [CSEngineIndexEntry]
    /// Download, verify (sha256) and install an engine; never native code.
    func pullEngine(id: String) throws -> CSEngine
    /// A style's effect for installed scene `id` at its package's defaults, and every param it
    /// takes (the manifest's, then its engine's, e.g. the cells engine's `ds.render`); nil = not installed.
    func effect(scene id: String) -> (EffectInstance, [ParamSpec])?
}

// MARK: - The engine side

/// CustomScenes (Shared/CustomScenes.swift) on this Mac's GPU, in the MCP's store.
struct CustomScenesBridge: CustomScenesAPI {
    let store: URL
    let device: MTLDevice?

    init(store: URL, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.store = store
        self.device = device
    }

    var isAvailable: Bool { true }

    func validate(packageAt url: URL) throws -> CSReport {
        guard let device else { throw ToolError("No Metal GPU on this Mac: custom scenes can't be compiled here.") }
        let r = CustomScenes.validate(packageAt: url, device: device, store: store)
        let entry = r.manifest?.entry
        return CSReport(ok: r.ok,
                        diagnostics: r.diagnostics.map {
                            CSDiagnostic(line: $0.line > 0 ? $0.line : nil, column: $0.column > 0 ? $0.column : nil,
                                         message: $0.message, severity: $0.severity.rawValue,
                                         file: $0.file == entry ? nil : $0.file)
                        },
                        gpuMsAt5K: r.gpuMsAt5K,
                        // (warning diagnostics are listed above already)
                        warnings: r.warnings.filter { w in !r.diagnostics.contains { $0.formatted == w } })
    }

    func install(packageAt url: URL) throws -> String {
        do { return try CustomScenes.install(packageAt: url, into: store) } catch {
            throw ToolError("The package didn't install: \(error.localizedDescription)")
        }
    }

    func remove(id: String) throws {
        do { try CustomScenes.remove(id: id, store: store) } catch { throw ToolError(error.localizedDescription) }
    }

    /// The manifests as the app reads them (sanitized: params clamped as the Inspector shows
    /// them), unknown fields kept.
    func installed() -> [JSONObject] {
        CustomScenes.installed(store: store).compactMap { JSON.from($0) as? JSONObject }
    }

    func engines() -> [CSEngine] {
        CustomScenes.engines(store: store).map {
            CSEngine(id: $0.id, version: $0.version, kind: $0.kind, builtIn: $0.builtIn, guide: $0.guideURL, summary: $0.summary)
        }
    }

    func availableEngines() throws -> [CSEngineIndexEntry] {
        try Self.wait { try await CustomScenes.availableEngines() }.map {
            CSEngineIndexEntry(id: $0.id, version: $0.version, summary: $0.summary ?? "", size: $0.size, minApp: $0.minApp ?? "")
        }
    }

    func pullEngine(id: String) throws -> CSEngine {
        if let e = engines().first(where: { $0.id == id && $0.builtIn }) {
            throw ToolError("\"\(id)\" is built into DotStudio (v\(e.version)): nothing to pull. Read its guide: read_guide(\"engines/\(id)\").")
        }
        let e = try Self.wait { try await CustomScenes.pullEngine(id: id, store: store) }
        return CSEngine(id: e.id, version: e.version, kind: e.kind, builtIn: false, guide: e.guideURL, summary: e.summary)
    }

    func effect(scene id: String) -> (EffectInstance, [ParamSpec])? {
        guard let m = CustomScenes.manifest(id: id, store: store) else { return nil }
        let engine = CustomScenes.resolveEngine(m.engine, store: store)?.engineParamSpecs ?? []
        return (EffectInstance.customScene(m), m.paramSpecs + engine)
    }

    /// The engine's async API from a tool call (a work-queue thread, never the cooperative pool).
    private static func wait<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()                 // written once, before the signal
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await op()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        switch box.result! {
        case .success(let v): return v
        case .failure(let e as ToolError): throw e
        case .failure(let e): throw ToolError(e.localizedDescription)
        }
    }
}

// MARK: - Stand-ins

struct CustomScenesUnavailable: Error {}

/// A build without the custom-scene engine (kept for the protocol's sake; every DotStudio build
/// since 1.5 has the engine).
struct UnavailableCustomScenes: CustomScenesAPI {
    static let message = "Custom scenes aren't available in this build of DotStudio. Build the screensaver from the built-in scenes and looks instead: list_scenes, describe_scene, create_style."
    var isAvailable: Bool { false }
    func validate(packageAt url: URL) throws -> CSReport { throw ToolError(Self.message) }
    func install(packageAt url: URL) throws -> String { throw ToolError(Self.message) }
    func remove(id: String) throws { throw ToolError(Self.message) }
    func installed() -> [JSONObject] { [] }
    func engines() -> [CSEngine] { [] }
    func availableEngines() throws -> [CSEngineIndexEntry] { throw ToolError(Self.message) }
    func pullEngine(id: String) throws -> CSEngine { throw ToolError(Self.message) }
    func effect(scene id: String) -> (EffectInstance, [ParamSpec])? { nil }
}

/// Self-test stand-in (DOTSTUDIO_MCP_TEST_FAKES=1): checks packages structurally, "compiles"
/// by looking for `dsScene(` and a planted `#error`, installs by copying — so the tools' flow
/// (staging, diagnostics, install, update, use in a style) is exercised without a GPU compile.
/// (The self-test's end-to-end section runs the real engines through CustomScenesBridge.)
struct FakeCustomScenes: CustomScenesAPI {
    let store: URL
    var isAvailable: Bool { true }

    func validate(packageAt url: URL) throws -> CSReport {
        guard let d = try? Data(contentsOf: url.appendingPathComponent("scene.json")),
              let m = JSON.parse(d) as? JSONObject, let entry = m["entry"] as? String,
              let src = try? String(contentsOf: url.appendingPathComponent(entry), encoding: .utf8) else {
            return CSReport(ok: false, diagnostics: [CSDiagnostic(message: "package unreadable", severity: "error")], warnings: [])
        }
        var diags: [CSDiagnostic] = []
        for (i, line) in src.components(separatedBy: "\n").enumerated() where line.contains("#error") {
            diags.append(CSDiagnostic(line: i + 1, column: 1, message: "planted error", severity: "error"))
        }
        if !src.contains("dsScene("), !src.contains("mainImage(") {
            diags.append(CSDiagnostic(line: 1, column: 1, message: "no dsScene(uv, ctx) function", severity: "error"))
        }
        return CSReport(ok: diags.isEmpty, diagnostics: diags, gpuMsAt5K: diags.isEmpty ? 2.5 : nil, warnings: [])
    }

    func install(packageAt url: URL) throws -> String {
        let m = JSON.parse(try Data(contentsOf: url.appendingPathComponent("scene.json"))) as? JSONObject ?? [:]
        guard let id = m["id"] as? String else { throw ToolError("no id") }
        let dst = AIStore.scenesDir(store).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: AIStore.scenesDir(store), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: url, to: dst)
        return id
    }

    func remove(id: String) throws {
        try FileManager.default.removeItem(at: AIStore.scenesDir(store).appendingPathComponent(id))
    }

    func installed() -> [JSONObject] {
        let dir = AIStore.scenesDir(store)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            (try? Data(contentsOf: $0.appendingPathComponent("scene.json"))).flatMap { JSON.parse($0) as? JSONObject }
        }
    }

    func engines() -> [CSEngine] {
        // The built-in engines' real guides (Resources/Engines), so read_guide works here too.
        let guide = { (id: String) in CustomScenes.engines(store: store).first { $0.id == id }?.guideURL }
        var out = [CSEngine(id: "metal", version: "1", kind: "metal-source", builtIn: true, guide: guide("metal"), summary: "Metal dsScene(uv, ctx)"),
                   CSEngine(id: "cells", version: "1", kind: "cells", builtIn: true, guide: guide("cells"), summary: "LED / pixel cells")]
        let pulled = AIStore.enginesDir(store).appendingPathComponent("shadertoy")
        if FileManager.default.fileExists(atPath: pulled.path) {
            out.append(CSEngine(id: "shadertoy", version: "1", kind: "glsl-source", builtIn: false,
                                guide: pulled.appendingPathComponent("1/guide.md"), summary: "GLSL mainImage compatibility"))
        }
        return out
    }

    func availableEngines() throws -> [CSEngineIndexEntry] {
        [CSEngineIndexEntry(id: "shadertoy", version: "1", summary: "GLSL mainImage compatibility", size: 40_000, minApp: "1.5.0"),
         CSEngineIndexEntry(id: "film", version: "1", summary: "Blender film toolkit", size: 2_000_000, minApp: "1.5.0")]
    }

    func pullEngine(id: String) throws -> CSEngine {
        guard try availableEngines().contains(where: { $0.id == id }) else { throw ToolError("no engine \(id) in the index") }
        let dir = AIStore.enginesDir(store).appendingPathComponent(id).appendingPathComponent("1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("# \(id) engine (test)\n\nFake guide.\n".utf8).write(to: dir.appendingPathComponent("guide.md"))
        return CSEngine(id: id, version: "1", kind: id == "film" ? "film" : "glsl-source", builtIn: false,
                        guide: dir.appendingPathComponent("guide.md"), summary: "pulled")
    }

    /// From the manifest JSON, as the engine side would (params by key at their defaults, colours).
    func effect(scene id: String) -> (EffectInstance, [ParamSpec])? {
        guard let m = installed().first(where: { $0["id"] as? String == id }) else { return nil }
        var e = EffectInstance(.custom)
        e.custom = CustomSceneRef(id: id)
        e.params = [:]
        var specs: [ParamSpec] = []
        for s in m["params"] as? [JSONObject] ?? [] {
            guard let key = s["key"] as? String else { continue }
            let label = s["label"] as? String ?? key
            let def = (s["default"] as? NSNumber)?.doubleValue ?? 0
            let spec: ParamSpec
            switch s["kind"] as? String ?? "slider" {
            case "menu": spec = ParamSpec(menu: key, label, s["options"] as? [String] ?? ["Default"], def: def)
            case "toggle": spec = ParamSpec(key, label, 0, 1, def: def, toggle: true)
            default: spec = ParamSpec(key, label, (s["min"] as? NSNumber)?.doubleValue ?? 0, (s["max"] as? NSNumber)?.doubleValue ?? 1, def: def)
            }
            specs.append(spec)
            e.params[key] = def
        }
        if ((m["engine"] as? JSONObject)?["id"] as? String) == "film" {     // the film engine's own params
            let grain = ((m["look"] as? JSONObject)?["grain"] as? NSNumber)?.doubleValue ?? 0.35
            specs += [ParamSpec("ds.grain", "Grain", 0, 1, def: 0.35), ParamSpec("ds.halation", "Halation", 0, 1, def: 0)]
            e.params["ds.grain"] = grain
        }
        let colors = m["colors"] as? JSONObject ?? [:]
        func color(_ slot: String) -> RGBA? {
            guard let d = (colors[slot] as? JSONObject)?["default"] as? [NSNumber], d.count >= 3 else { return nil }
            return RGBA(d[0].doubleValue, d[1].doubleValue, d[2].doubleValue, d.count > 3 ? d[3].doubleValue : 1)
        }
        e.colorA = color("a")
        e.colorB = color("b")
        return (e, specs)
    }
}

/// The real engines; DOTSTUDIO_MCP_TEST_FAKES=1 (the self-test) swaps in the structural stand-in.
/// (DOTSTUDIO_MCP_TEST_FAKES=film fakes only the film toolkit: makeFilmToolkit.)
func makeCustomScenesAPI(store: URL) -> CustomScenesAPI {
    if ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_TEST_FAKES"] == "1" { return FakeCustomScenes(store: store) }
    return CustomScenesBridge(store: store)
}

/// One async result handed to a waiting thread (CustomScenesBridge.wait).
private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
