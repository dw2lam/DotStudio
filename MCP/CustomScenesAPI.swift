//  CustomScenesAPI.swift — what dotstudio-mcp needs from the custom-scene engine side.
//
//  The engine side (Shared/CustomScenes.swift: `enum CustomScenes`, scene packages, runtime
//  shader compile, pullable engines) is built on another branch; see the shared contract
//  (mcp-contract.md §2–4). This protocol mirrors that API with dotstudio-mcp's own value types,
//  so this target compiles and is tested without it. At merge, `CustomScenesBridge` (a few
//  lines mapping CustomSceneReport / CustomSceneManifest / EngineInfo / EngineIndexEntry onto
//  these) replaces `UnavailableCustomScenes` in `makeCustomScenesAPI`.

import Foundation

struct CSDiagnostic {
    var line: Int?
    var column: Int?
    var message: String
    var severity: String          // "error" | "warning" | "note"
    var json: JSONObject {
        var o: JSONObject = ["message": message, "severity": severity]
        if let line { o["line"] = line }
        if let column { o["column"] = column }
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
    /// False until the engine side is in this build: every call below then throws.
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
}

struct CustomScenesUnavailable: Error {}

/// This build has no custom-scene engine: say so plainly.
struct UnavailableCustomScenes: CustomScenesAPI {
    static let message = "Custom scenes aren't available in this build of DotStudio yet (they arrive with the scene-engine update). Build the screensaver from the built-in scenes and looks instead: list_scenes, describe_scene, create_style."
    var isAvailable: Bool { false }
    func validate(packageAt url: URL) throws -> CSReport { throw ToolError(Self.message) }
    func install(packageAt url: URL) throws -> String { throw ToolError(Self.message) }
    func remove(id: String) throws { throw ToolError(Self.message) }
    func installed() -> [JSONObject] { [] }
    func engines() -> [CSEngine] { [] }
    func availableEngines() throws -> [CSEngineIndexEntry] { throw ToolError(Self.message) }
    func pullEngine(id: String) throws -> CSEngine { throw ToolError(Self.message) }
}

/// Self-test stand-in (DOTSTUDIO_MCP_TEST_FAKES=1): checks packages structurally, "compiles"
/// by looking for `dsScene(` and a planted `#error`, installs by copying — so the tools' flow
/// (staging, diagnostics, install, update, use in a style) is exercised end to end.
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
        if !src.contains("dsScene(") { diags.append(CSDiagnostic(line: 1, column: 1, message: "no dsScene(uv, ctx) function", severity: "error")) }
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
        var out = [CSEngine(id: "metal", version: "1", kind: "metal-source", builtIn: true, guide: nil, summary: "Metal dsScene(uv, ctx)"),
                   CSEngine(id: "cells", version: "1", kind: "cells", builtIn: true, guide: nil, summary: "LED / pixel cells")]
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
}

func makeCustomScenesAPI(store: URL) -> CustomScenesAPI {
    if ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_TEST_FAKES"] == "1" { return FakeCustomScenes(store: store) }
    return UnavailableCustomScenes()
}
