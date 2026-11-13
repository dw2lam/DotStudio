//  CustomScenes.swift — scene packages the user (or an AI, through DotStudio's MCP server) makes,
//  and the engines that turn them into render pipelines. The contract: docs/ai/CONTRACT.md.
//
//  On disk, in the shared store (so the sandboxed screensaver reads them like media/):
//    <store>/scenes/<id>/            scene.json (CustomSceneManifest), the entry source, assets/
//    <store>/engines/<id>/<version>/ engine.json (EngineManifest) + headers / wrapper / guide
//  Built-in engines ship in the app and the saver: Resources/Engines/<id>/<version>/ (Shared/Engines).
//
//  An engine is DATA: Metal headers, a wrapper that turns the package's function into a fragment
//  function, a guide and examples. Its `kind` picks what this build does with them:
//    metal-source  the package is Metal: float4 dsScene(float2 uv, DSContext ctx)
//    cells         the same function, drawn as LED dots / pixels / glyphs (the CellKit look)
//    glsl-source   Shadertoy-style GLSL (mainImage), rewritten to Metal by GLSLTranslator
//    film          looping video clips picked by sun and weather (CustomFilm.swift) — no shader
//  Nothing an engine or a package holds is ever run as native code: sources are compiled by
//  Metal's runtime compiler into GPU functions, like every other shader here.
//
//  The pieces: this file (models, store, engines, the MCP-facing API), CustomSceneCompiler.swift
//  (source assembly, diagnostics, the pipeline cache, validate's bench), CustomSceneLink.swift
//  (what each MetalRenderer uses to draw one), GLSLTranslator.swift, CustomFilm.swift.

import Foundation
import Metal
import CryptoKit

// MARK: - Manifest

/// scene.json. Decoding is tolerant (a toggle's default may be a bool, numbers may be strings of
/// numbers…) and keeps fields it doesn't know (`unknownFields`), written back by `encode`.
struct CustomSceneManifest: Codable, Equatable {
    struct EngineRequirement: Codable, Equatable {
        var id: String
        /// "1", ">=1", "^1" or nil (any). Versions are dotted integers.
        var version: String?
    }

    struct Param: Codable, Equatable {
        enum Kind: String, Codable { case slider, toggle, menu }
        var key: String
        var label: String
        var kind: Kind
        var min: Double?
        var max: Double?
        var step: Double?
        var defaultValue: Double?
        var options: [String]?

        private enum CodingKeys: String, CodingKey { case key, label, kind, min, max, step, defaultValue = "default", options }

        init(key: String, label: String, kind: Kind, min: Double? = nil, max: Double? = nil, step: Double? = nil,
             defaultValue: Double? = nil, options: [String]? = nil) {
            self.key = key; self.label = label; self.kind = kind; self.min = min; self.max = max
            self.step = step; self.defaultValue = defaultValue; self.options = options
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = (try? c.decode(String.self, forKey: .label)) ?? key
            let k = (try? c.decode(String.self, forKey: .kind))?.lowercased() ?? "slider"
            kind = Kind(rawValue: k) ?? (k == "bool" || k == "switch" ? .toggle : k == "choice" || k == "select" ? .menu : .slider)
            min = CustomSceneManifest.number(c, .min)
            max = CustomSceneManifest.number(c, .max)
            step = CustomSceneManifest.number(c, .step)
            defaultValue = CustomSceneManifest.number(c, .defaultValue)
            options = try? c.decode([String].self, forKey: .options)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
            try c.encodeIfPresent(step, forKey: .step)
            try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
            try c.encodeIfPresent(options, forKey: .options)
        }

        /// This param as the Inspector's (and SafeNumbers') ParamSpec: ranges made sane.
        var spec: ParamSpec {
            switch kind {
            case .toggle:
                return ParamSpec(key, label, 0, 1, def: (defaultValue ?? 0) > 0.5 ? 1 : 0, toggle: true)
            case .menu:
                let opts = (options ?? []).isEmpty ? ["Default"] : options!
                let d = Double(Swift.min(Swift.max(Int(saturating: defaultValue ?? 0, .toNearestOrAwayFromZero), 0), opts.count - 1))
                return ParamSpec(menu: key, label, opts, def: d)
            case .slider:
                var lo = (min ?? 0).finite(or: 0), hi = (max ?? 1).finite(or: 1)
                if lo > hi { swap(&lo, &hi) }
                if lo == hi { hi = lo + 1 }
                let d = Swift.min(Swift.max((defaultValue ?? lo).finite(or: lo), lo), hi)
                let st = (step ?? 0).finite(or: 0)
                return ParamSpec(key, label, lo, hi, step: st > 0 && st <= hi - lo ? st : 0, def: d)
            }
        }
    }

    struct ColorSlot: Codable, Equatable {
        var label: String?
        var defaultValue: [Double]?
        private enum CodingKeys: String, CodingKey { case label, defaultValue = "default" }

        /// The default as RGBA (each channel clamped 0…1; a 3-channel colour is opaque).
        var rgba: RGBA? {
            guard let v = defaultValue, v.count >= 3 else { return nil }
            func ch(_ x: Double) -> Double { Swift.min(Swift.max(x.finite(or: 0), 0), 1) }
            return RGBA(ch(v[0]), ch(v[1]), ch(v[2]), v.count > 3 ? ch(v[3]) : 1)
        }
    }

    struct Colors: Codable, Equatable {
        var a: ColorSlot?
        var b: ColorSlot?
    }

    /// Film engine: one looping clip (CustomFilm.swift). `variant`: day, golden, night, rain, any.
    struct Clip: Codable, Equatable {
        var variant: String
        var file: String
        var loop: Bool?
        /// "hevc" / "h264" (informational; AVFoundation reads the file's own).
        var codec: String?
    }

    var format: Int = 1
    var id: String
    var name: String
    var author: String?
    var licence: String?
    var engine: EngineRequirement
    var entry: String?
    var fps: Int?
    var stepped: Bool?
    var params: [Param] = []
    var colors: Colors?
    /// "sun", "weather", "music": what the scene reads (the app fetches the weather only for a
    /// style that uses it).
    var uses: [String]?
    var description: String?
    var guides: [String]?
    /// Asset files (package-relative, `assets/*.png|jpg`), bound to ctx.asset0…3 in this order.
    var assets: [String]?
    /// Film engine only.
    var clips: [Clip]?

    /// Fields this build doesn't know, kept verbatim.
    var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case format, id, name, author, licence, engine, entry, fps, stepped, params, colors, uses, description,
             guides, assets, clips
    }

    init(id: String, name: String, engine: EngineRequirement, entry: String?) {
        self.id = id; self.name = name; self.engine = engine; self.entry = entry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: JSONValue.AnyKey.self)
        for k in all.allKeys where CodingKeys(stringValue: k.stringValue) == nil {
            unknownFields[k.stringValue] = try all.decode(JSONValue.self, forKey: k)
        }
        format = (try? c.decode(Int.self, forKey: .format)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled Scene"
        author = try? c.decode(String.self, forKey: .author)
        licence = try? c.decode(String.self, forKey: .licence)
        if let e = try? c.decode(EngineRequirement.self, forKey: .engine) { engine = e }
        else if let s = try? c.decode(String.self, forKey: .engine) { engine = EngineRequirement(id: s, version: nil) }
        else { engine = EngineRequirement(id: "metal", version: nil) }
        entry = try? c.decode(String.self, forKey: .entry)
        fps = CustomSceneManifest.number(c, .fps).map { Int(saturating: $0, .toNearestOrAwayFromZero) }
        stepped = try? c.decode(Bool.self, forKey: .stepped)
        params = (try? c.decode([Param].self, forKey: .params)) ?? []
        colors = try? c.decode(Colors.self, forKey: .colors)
        uses = try? c.decode([String].self, forKey: .uses)
        description = try? c.decode(String.self, forKey: .description)
        guides = try? c.decode([String].self, forKey: .guides)
        assets = try? c.decode([String].self, forKey: .assets)
        clips = try? c.decode([Clip].self, forKey: .clips)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(licence, forKey: .licence)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(entry, forKey: .entry)
        try c.encodeIfPresent(fps, forKey: .fps)
        try c.encodeIfPresent(stepped, forKey: .stepped)
        try c.encode(params, forKey: .params)
        try c.encodeIfPresent(colors, forKey: .colors)
        try c.encodeIfPresent(uses, forKey: .uses)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(guides, forKey: .guides)
        try c.encodeIfPresent(assets, forKey: .assets)
        try c.encodeIfPresent(clips, forKey: .clips)
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: JSONValue.AnyKey.self)
            for (k, v) in unknownFields { try extra.encode(v, forKey: JSONValue.AnyKey(k)) }
        }
    }

    /// A number however it was written: 0.5, "0.5", true / false.
    fileprivate static func number<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> Double? {
        if let d = try? c.decode(Double.self, forKey: k) { return d.isFinite ? d : nil }
        if let b = try? c.decode(Bool.self, forKey: k) { return b ? 1 : 0 }
        if let s = try? c.decode(String.self, forKey: k), let d = Double(s), d.isFinite { return d }
        return nil
    }

    // MARK: What the app and the renderer read

    /// The params as ParamSpecs, in manifest order (at most 16: p[0…15]).
    var paramSpecs: [ParamSpec] { params.prefix(CustomScenes.maxParams).map(\.spec) }
    var defaultColorA: RGBA { colors?.a?.rgba ?? EffectKind.custom.defaultColorA ?? .black }
    var defaultColorB: RGBA { colors?.b?.rgba ?? EffectKind.custom.defaultColorB ?? .white }
    var colorALabel: String { colors?.a?.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Colour A" }
    var colorBLabel: String { colors?.b?.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Colour B" }
    var usesSet: Set<String> { Set((uses ?? []).map { $0.lowercased() }) }
    /// The frame rate the scene steps its time at, when "stepped" (else nil: smooth).
    var steppedFPS: Double? { (stepped ?? false) ? Double(Swift.min(Swift.max(fps ?? 24, 1), 60)) : nil }
}

// MARK: - Engines

/// engine.json.
struct EngineManifest: Codable, Equatable {
    var id: String
    var version: String
    /// metal-source, cells, glsl-source, film.
    var kind: String
    var name: String?
    var summary: String?
    /// Headers prepended (in order) before the package's source.
    var headers: [String]?
    /// The fragment function's source, appended after the package's (defines ds_fragment).
    var wrapper: String?
    /// Another engine whose headers come first (cells and shadertoy build on metal's DSContext).
    var base: CustomSceneManifest.EngineRequirement?
    /// Params the engine adds to every scene (cells: Render, Cell Size, Glow) → u.scene[8], ≤ 4.
    var params: [CustomSceneManifest.Param]?
    var entryExtensions: [String]?
    var guide: String?
    var examples: [String]?
    var minApp: String?
}

/// An engine this build can use: built in, or pulled into the store.
struct EngineInfo: Equatable {
    var id: String
    var version: String
    var kind: String
    var builtIn: Bool
    /// The engine's folder (engine.json, headers, guide, examples).
    var url: URL
    var manifest: EngineManifest

    var name: String { manifest.name ?? id }
    var summary: String { manifest.summary ?? "" }
    var guideURL: URL? { manifest.guide.map { url.appendingPathComponent($0) } }
    var exampleURLs: [URL] { (manifest.examples ?? []).map { url.appendingPathComponent($0, isDirectory: true) } }
    var minApp: String? { manifest.minApp }
    /// The params the engine adds (cells), at most 4.
    var engineParamSpecs: [ParamSpec] { (manifest.params ?? []).prefix(4).map(\.spec) }
}

/// One entry of engines-index.json (a GitHub release of dw2lam/DotStudio, tag `engines`).
struct EngineIndexEntry: Codable, Equatable {
    var id: String
    var version: String
    /// The engine bundle (.dsengine.json); relative to the index's own URL when not absolute.
    var url: String
    var sha256: String
    var size: Int
    var minApp: String?
    var summary: String?
}

/// engines-index.json.
struct EngineIndex: Codable, Equatable {
    var format: Int?
    var engines: [EngineIndexEntry]
}

/// A downloadable engine: its files, base64, in one JSON document (tools/engines/build-index.sh).
/// No archive format to unpack, so nothing can land outside the engine's folder.
struct EngineBundle: Codable {
    var format: Int
    var id: String
    var version: String
    var files: [String: String]
}

// MARK: - Reports

struct Diagnostic: Codable, Equatable, Hashable {
    enum Severity: String, Codable { case error, warning, note }
    /// 1-based, in the package's file `file` (0 = not tied to a line).
    var line: Int
    var column: Int
    var message: String
    var severity: Severity
    /// The package file it's in (the entry, an included file, scene.json), or an engine header.
    var file: String?

    init(line: Int = 0, column: Int = 0, message: String, severity: Severity = .error, file: String? = nil) {
        self.line = line; self.column = column; self.message = message; self.severity = severity; self.file = file
    }

    var formatted: String {
        let loc = line > 0 ? "\(file ?? "scene"):\(line):\(column): " : (file.map { "\($0): " } ?? "")
        return "\(loc)\(severity.rawValue): \(message)"
    }
}

struct CustomSceneReport {
    var ok: Bool
    var diagnostics: [Diagnostic]
    /// GPU ms per frame at 5120×2880 (median of a few frames), when it compiled.
    var gpuMsAt5K: Double?
    var warnings: [String]
    // Additive (beyond the contract):
    /// The manifest as read and sanitized.
    var manifest: CustomSceneManifest? = nil
    /// The engine it resolved to.
    var engine: String? = nil
}

enum CustomSceneError: LocalizedError {
    case invalid([Diagnostic])
    case notFound(String)
    case engine(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let d): return d.map(\.formatted).joined(separator: "\n")
        case .notFound(let s), .engine(let s), .download(let s): return s
        }
    }
}

// MARK: - API

enum CustomScenes {
    static let maxParams = 16
    static let maxSourceBytes = 256 * 1024
    static let maxAssetBytes = 8 * 1024 * 1024
    static let maxAssets = 4
    /// Film clips can be large; they're video, played by AVFoundation.
    static let maxClipBytes = 400 * 1024 * 1024
    static let maxEngineBytes = 4 * 1024 * 1024
    static let fallbackShaderID: Int32 = 90

    /// Where pullable engines are listed. DOTSTUDIO_ENGINES_INDEX overrides it (an https or
    /// file:// URL, or a plain path) — for testing offline.
    static var indexURL: URL {
        if let s = ProcessInfo.processInfo.environment["DOTSTUDIO_ENGINES_INDEX"], !s.isEmpty {
            return s.contains("://") ? (URL(string: s) ?? URL(fileURLWithPath: s)) : URL(fileURLWithPath: s)
        }
        return URL(string: "https://github.com/dw2lam/DotStudio/releases/download/engines/engines-index.json")!
    }

    /// The store the app side uses when a caller doesn't pass one (the Inspector, validate).
    static var defaultStore: URL { SharedStore.appBaseDir }

    static func scenesDir(_ store: URL) -> URL { store.appendingPathComponent("scenes", isDirectory: true) }
    static func enginesDir(_ store: URL) -> URL { store.appendingPathComponent("engines", isDirectory: true) }
    /// Where package `id` is read from: the store's copy, else a built-in package with that id
    /// (Resources/Films), else the store path (missing).
    static func packageDir(id: String, store: URL) -> URL {
        let mine = storePackageDir(id: id, store: store)
        if FileManager.default.fileExists(atPath: mine.path) { return mine }
        return builtInPackageDir(id: id) ?? mine
    }
    /// The store's own copy of package `id` (install and remove write only here, never a bundle).
    static func storePackageDir(id: String, store: URL) -> URL { scenesDir(store).appendingPathComponent(id, isDirectory: true) }

    // MARK: Built-in packages (film scenes rendered offline that ship with the app)

    /// Built-in scene packages ship ONCE, inside the saver (Resources/Films), like the slideshow
    /// photos; the app and dotstudio-mcp read them from the embedded DotStudio.saver. The tools put
    /// a Films folder next to their binary; DOTSTUDIO_FILMS_DIR overrides.
    static var builtInPackagesDirs: [URL] {
        var dirs: [URL] = []
        if let s = ProcessInfo.processInfo.environment["DOTSTUDIO_FILMS_DIR"], !s.isEmpty {
            dirs.append(URL(fileURLWithPath: s, isDirectory: true))
        }
        if let r = Bundle(for: MetalRenderer.self).resourceURL { dirs.append(r.appendingPathComponent("Films", isDirectory: true)) }
        if let r = Bundle.main.resourceURL {
            dirs.append(r.appendingPathComponent("DotStudio.saver/Contents/Resources/Films", isDirectory: true))
            dirs.append(r.appendingPathComponent("Films", isDirectory: true))
        }
        return dirs
    }

    static func builtInPackageDir(id: String) -> URL? {
        guard isValidID(id) else { return nil }
        for d in builtInPackagesDirs {
            let u = d.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("scene.json").path) { return u }
        }
        return nil
    }

    /// The built-in packages' manifests (first folder that has any), by name.
    static func builtInManifests() -> [CustomSceneManifest] {
        let fm = FileManager.default
        for d in builtInPackagesDirs {
            guard let ids = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            let ms = ids.filter(isValidID).sorted().compactMap { id -> CustomSceneManifest? in
                guard let m = readManifest(packageAt: d.appendingPathComponent(id, isDirectory: true)).0, m.id == id else { return nil }
                return m
            }
            if !ms.isEmpty { return ms }
        }
        return []
    }

    static func isBuiltIn(id: String) -> Bool { builtInPackageDir(id: id) != nil }

    /// `[a-z0-9-]{1,48}` + "-" + 8 hex.
    static func isValidID(_ id: String) -> Bool {
        let b = Array(id.utf8)
        guard b.count >= 10, b.count <= 57, b[b.count - 9] == UInt8(ascii: "-") else { return false }
        let hex = b.suffix(8), head = b.prefix(b.count - 9)
        func isHex(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 97 && c <= 102) }
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 97 && c <= 122) || c == 45 }
        return !head.isEmpty && head.allSatisfy(ok) && hex.allSatisfy(isHex)
    }

    /// A fresh id from a scene name: "aurora-lake-1a2b3c4d".
    static func makeID(name: String) -> String {
        var slug = ""
        var dash = false
        for ch in name.lowercased().unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { slug.unicodeScalars.append(ch); dash = false }
            else if !dash && !slug.isEmpty { slug += "-"; dash = true }
            if slug.count >= 40 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "scene" }
        return slug + "-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    // MARK: Manifest reading + validation

    /// The manifest in a package folder, sanitized, and what's wrong with it (errors fail validate
    /// and install; warnings don't).
    static func readManifest(packageAt url: URL) -> (CustomSceneManifest?, [Diagnostic]) {
        let file = url.appendingPathComponent("scene.json")
        guard let data = try? Data(contentsOf: file) else {
            return (nil, [Diagnostic(message: "no scene.json in \(url.lastPathComponent)", file: "scene.json")])
        }
        guard data.count <= 256 * 1024 else { return (nil, [Diagnostic(message: "scene.json is over 256 KB", file: "scene.json")]) }
        let m: CustomSceneManifest
        do { m = try JSONDecoder().decode(CustomSceneManifest.self, from: data) } catch {
            return (nil, [Diagnostic(message: "scene.json isn't valid JSON: \(describe(error))", file: "scene.json")])
        }
        return sanitize(m)
    }

    private static func describe(_ e: Error) -> String {
        if case DecodingError.dataCorrupted(let c) = e { return c.debugDescription + ((c.underlyingError as NSError?).map { " (\($0.localizedDescription))" } ?? "") }
        return e.localizedDescription
    }

    /// Clamps what can be clamped (SafeNumbers' rules), reports what can't.
    static func sanitize(_ input: CustomSceneManifest) -> (CustomSceneManifest, [Diagnostic]) {
        var m = input
        var d: [Diagnostic] = []
        func err(_ s: String) { d.append(Diagnostic(message: s, severity: .error, file: "scene.json")) }
        func warn(_ s: String) { d.append(Diagnostic(message: s, severity: .warning, file: "scene.json")) }
        if m.format != 1 { warn("format \(m.format): this build reads format 1") }
        m.name = String(m.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if m.name.isEmpty { m.name = "Untitled Scene"; warn("no name: called it \"Untitled Scene\"") }
        if !m.id.isEmpty && !isValidID(m.id) { warn("id \"\(m.id)\" isn't [a-z0-9-]{1,48}-<8 hex>: install gives it a new one") }
        if m.engine.id.isEmpty { err("engine.id is empty") }
        if let f = m.fps { m.fps = Swift.min(Swift.max(f, 1), 120) }
        if m.params.count > maxParams { err("\(m.params.count) params: at most \(maxParams) (p[0…15])") }
        var keys = Set<String>()
        for (i, p) in m.params.enumerated() {
            let okKey = !p.key.isEmpty && p.key.count <= 32 && p.key.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            } && !p.key.hasPrefix("ds.")
            if !okKey { err("param \(i): key \"\(p.key)\" must be 1–32 letters, digits, _ or - (and not start with ds.)") }
            if !keys.insert(p.key).inserted { err("param \(i): key \"\(p.key)\" is used twice") }
            if p.label.count > 40 { m.params[i].label = String(p.label.prefix(40)) }
            switch p.kind {
            case .slider:
                if p.min == nil || p.max == nil { warn("param \"\(p.key)\": slider without min/max — using 0…1") }
                if let lo = p.min, let hi = p.max, lo >= hi { warn("param \"\(p.key)\": min ≥ max") }
                if let lo = p.min, let hi = p.max, abs(hi - lo) > 1e7 { err("param \"\(p.key)\": range over 1e7") }
            case .menu:
                let n = p.options?.count ?? 0
                if n == 0 { err("param \"\(p.key)\": menu without options") }
                if n > 32 { err("param \"\(p.key)\": over 32 options") }
                m.params[i].options = p.options?.map { String($0.prefix(40)) }
            case .toggle: break
            }
            // Stored clamped, as the Inspector shows them.
            let s = m.params[i].spec
            m.params[i].defaultValue = s.def
            if p.kind == .slider { m.params[i].min = s.min; m.params[i].max = s.max }
        }
        for (slot, c) in [("a", m.colors?.a), ("b", m.colors?.b)] {
            if let c, let v = c.defaultValue, v.count < 3 || v.count > 4 || !v.allSatisfy(\.isFinite) {
                warn("colors.\(slot).default should be [r, g, b] or [r, g, b, a], each 0…1")
            }
        }
        if let a = m.assets, a.count > maxAssets { err("\(a.count) assets: at most \(maxAssets)") }
        for a in m.assets ?? [] where !isSafeRelativePath(a) || !(a.hasPrefix("assets/")) || !["png", "jpg", "jpeg"].contains((a as NSString).pathExtension.lowercased()) {
            err("asset \"\(a)\" must be assets/<name>.png|jpg")
        }
        if let e = m.entry, !isSafeRelativePath(e) { err("entry \"\(e)\" must be a file inside the package") }
        if m.engine.id != "film", m.entry == nil { err("no entry: the source file to compile (e.g. \"scene.metal\")") }
        let known = Set(["sun", "weather", "music", "clock"])
        for u in m.uses ?? [] where !known.contains(u.lowercased()) { warn("uses \"\(u)\": known are sun, weather, music, clock") }
        return (m, d)
    }

    /// A plain relative path inside a package: no "..", no absolute path, no hidden parts.
    static func isSafeRelativePath(_ p: String, maxDepth: Int = 3) -> Bool {
        guard !p.isEmpty, p.count <= 200, !p.hasPrefix("/"), !p.contains("\\"), !p.contains("\0") else { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= maxDepth && parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." && !$0.hasPrefix(".") }
    }

    // MARK: Install / remove / list

    /// Copies the package at `url` into `<store>/scenes/<id>/` (replacing a package with the same
    /// id — that's how a scene is edited) and returns its id. The manifest must be valid (compile
    /// errors don't stop an install: the style draws its stand-in; validate first). A missing or
    /// malformed id gets a new one, written into the installed scene.json.
    @discardableResult
    static func install(packageAt url: URL, into store: URL) throws -> String {
        let (manifest, diags) = readManifest(packageAt: url)
        guard var m = manifest, !diags.contains(where: { $0.severity == .error }) else { throw CustomSceneError.invalid(diags) }
        if !isValidID(m.id) { m.id = makeID(name: m.name) }
        let files = try packageFiles(url, manifest: m)
        let fm = FileManager.default
        let scenes = scenesDir(store)
        try fm.createDirectory(at: scenes, withIntermediateDirectories: true)
        let tmp = scenes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            for rel in files where rel != "scene.json" {
                let dst = tmp.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url.appendingPathComponent(rel), to: dst)
            }
            // scene.json as written (every field kept, nested unknown ones too), with only its id
            // replaced when it needed a new one.
            let raw = try Data(contentsOf: url.appendingPathComponent("scene.json"))
            if var obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                if (obj["id"] as? String) != m.id {
                    obj["id"] = m.id
                    try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                        .write(to: tmp.appendingPathComponent("scene.json"), options: .atomic)
                } else {
                    try raw.write(to: tmp.appendingPathComponent("scene.json"), options: .atomic)
                }
            } else {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(m).write(to: tmp.appendingPathComponent("scene.json"), options: .atomic)
            }
            let dst = storePackageDir(id: m.id, store: store)
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dst)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        clearCaches(id: m.id)
        return m.id
    }

    /// The files a package consists of (package-relative), enforcing the size caps. Only what a
    /// scene can use is copied: scene.json, sources (.metal .glsl .h .frag), the listed assets and
    /// clips, a preview image and markdown notes. Symlinks are never followed.
    static func packageFiles(_ url: URL, manifest m: CustomSceneManifest) throws -> [String] {
        let fm = FileManager.default
        var out = ["scene.json"]
        var diags: [Diagnostic] = []
        var sourceBytes = 0, assetBytes = 0, clipBytes = 0
        func size(_ rel: String) -> Int? {
            let p = url.appendingPathComponent(rel)
            guard let a = try? fm.attributesOfItem(atPath: p.path), (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return (a[.size] as? Int) ?? 0
        }
        let top = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        for name in top.sorted() where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            if ["metal", "glsl", "frag", "h", "md"].contains(ext) || name == "preview.png" || name == "preview.jpg" {
                guard let s = size(name) else { continue }
                if ext != "md" && !name.hasPrefix("preview.") { sourceBytes += s } else if s > 2 * 1024 * 1024 { continue }
                out.append(name)
            }
        }
        if let e = m.entry {
            if size(e) == nil { diags.append(Diagnostic(message: "the entry \"\(e)\" isn't in the package", file: e)) }
            else if !out.contains(e) { out.append(e); sourceBytes += size(e) ?? 0 }
        }
        if sourceBytes > maxSourceBytes { diags.append(Diagnostic(message: "sources are \(sourceBytes / 1024) KB: at most \(maxSourceBytes / 1024) KB")) }
        for a in m.assets ?? [] {
            guard let s = size(a) else { diags.append(Diagnostic(message: "asset \"\(a)\" is missing", file: a)); continue }
            assetBytes += s
            out.append(a)
        }
        if assetBytes > maxAssetBytes { diags.append(Diagnostic(message: "assets are \(assetBytes / 1024 / 1024) MB: at most 8 MB")) }
        for c in m.clips ?? [] {
            guard isSafeRelativePath(c.file) else { diags.append(Diagnostic(message: "clip \"\(c.file)\" must be a file inside the package")); continue }
            guard let s = size(c.file) else { diags.append(Diagnostic(message: "clip \"\(c.file)\" is missing", file: c.file)); continue }
            clipBytes += s
            if !out.contains(c.file) { out.append(c.file) }
        }
        if clipBytes > maxClipBytes { diags.append(Diagnostic(message: "clips are \(clipBytes / 1024 / 1024) MB: at most \(maxClipBytes / 1024 / 1024) MB")) }
        if !diags.isEmpty { throw CustomSceneError.invalid(diags) }
        return out
    }

    static func remove(id: String, store: URL) throws {
        guard isValidID(id) else { throw CustomSceneError.notFound("no scene \"\(id)\"") }
        let dir = storePackageDir(id: id, store: store)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw CustomSceneError.notFound("no scene \"\(id)\"") }
        try FileManager.default.removeItem(at: dir)
        clearCaches(id: id)
    }

    /// Every installed package's manifest, by name.
    static func installed(store: URL) -> [CustomSceneManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: scenesDir(store).path)) ?? []
        return dirs.filter(isValidID).compactMap { manifest(id: $0, store: store) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Manifest cache (the Inspector, FramePacing, WeatherLink read it many times a second)

    private static let cacheLock = NSLock()
    private struct CachedManifest { var stamp: FileStamp?; var checked: CFAbsoluteTime; var manifest: CustomSceneManifest? }
    private static var manifestCache: [String: CachedManifest] = [:]

    /// The installed package's manifest (sanitized), re-read when scene.json changes (checked at
    /// most every half second).
    static func manifest(id: String, store: URL) -> CustomSceneManifest? {
        guard isValidID(id) else { return nil }
        let key = store.path + "|" + id
        let now = CFAbsoluteTimeGetCurrent()
        cacheLock.lock()
        if let c = manifestCache[key], now - c.checked < 0.5 { cacheLock.unlock(); return c.manifest }
        cacheLock.unlock()
        let path = packageDir(id: id, store: store).appendingPathComponent("scene.json").path
        let stamp = FileStamp(path: path)
        cacheLock.lock()
        if let c = manifestCache[key], c.stamp == stamp {
            manifestCache[key]?.checked = now
            cacheLock.unlock()
            return c.manifest
        }
        cacheLock.unlock()
        let m = stamp == nil ? nil : readManifest(packageAt: packageDir(id: id, store: store)).0
        cacheLock.lock()
        manifestCache[key] = CachedManifest(stamp: stamp, checked: now, manifest: m)
        if let m { knownByID[id] = m }
        cacheLock.unlock()
        return m
    }

    /// The last manifest read for `id` from any store (callers without a store: FramePacing,
    /// WeatherLink.followsLive). Filled by `manifest(id:store:)`.
    private static var knownByID: [String: CustomSceneManifest] = [:]
    static func knownManifest(id: String) -> CustomSceneManifest? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return knownByID[id]
    }

    /// Changes whenever the installed package's files do (thumbnail cache keys).
    static func revisionKey(id: String, store: URL) -> String {
        let dir = packageDir(id: id, store: store)
        let m = manifest(id: id, store: store)
        var parts = ["scene.json"] + (m?.entry.map { [$0] } ?? []) + (m?.assets ?? [])
        parts += (m?.clips ?? []).map(\.file)
        return parts.map { rel -> String in
            guard let s = FileStamp(path: dir.appendingPathComponent(rel).path) else { return "-" }
            return "\(s.size).\(s.sec).\(s.nsec).\(s.inode)"
        }.joined(separator: "|")
    }

    static func clearCaches(id: String) {
        cacheLock.lock()
        manifestCache = manifestCache.filter { !$0.key.hasSuffix("|" + id) }
        cacheLock.unlock()
    }

    // MARK: Engines

    /// The built-in engines' folder: Resources/Engines in the app and the saver; DOTSTUDIO_ENGINES_DIR
    /// overrides it (the tools put a copy next to their binary).
    static var builtInEnginesDir: URL? {
        if let s = ProcessInfo.processInfo.environment["DOTSTUDIO_ENGINES_DIR"], !s.isEmpty {
            return URL(fileURLWithPath: s, isDirectory: true)
        }
        for b in [Bundle(for: MetalRenderer.self), Bundle.main] {
            if let u = b.resourceURL?.appendingPathComponent("Engines", isDirectory: true),
               FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private static func loadEngines(in dir: URL, builtIn: Bool) -> [EngineInfo] {
        let fm = FileManager.default
        var out: [EngineInfo] = []
        for id in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !id.hasPrefix(".") {
            let idDir = dir.appendingPathComponent(id, isDirectory: true)
            for v in ((try? fm.contentsOfDirectory(atPath: idDir.path)) ?? []).sorted() where !v.hasPrefix(".") {
                let vDir = idDir.appendingPathComponent(v, isDirectory: true)
                guard let data = try? Data(contentsOf: vDir.appendingPathComponent("engine.json")),
                      let m = try? JSONDecoder().decode(EngineManifest.self, from: data),
                      m.id == id, m.version == v else { continue }
                out.append(EngineInfo(id: id, version: v, kind: m.kind, builtIn: builtIn, url: vDir, manifest: m))
            }
        }
        return out
    }

    private static var builtInCache: [EngineInfo]?

    /// Built-in engines, then the ones pulled into `store` (a pulled engine never shadows a
    /// built-in one of the same id).
    static func engines(store: URL) -> [EngineInfo] {
        cacheLock.lock()
        var builtIns = builtInCache
        cacheLock.unlock()
        if builtIns == nil {
            builtIns = builtInEnginesDir.map { loadEngines(in: $0, builtIn: true) } ?? []
            cacheLock.lock(); builtInCache = builtIns; cacheLock.unlock()
        }
        let ids = Set(builtIns!.map(\.id))
        let pulled = loadEngines(in: enginesDir(store), builtIn: false).filter { !ids.contains($0.id) }
        return builtIns! + pulled
    }

    /// The newest engine meeting `req`.
    static func resolveEngine(_ req: CustomSceneManifest.EngineRequirement, store: URL) -> EngineInfo? {
        engines(store: store).filter { $0.id == req.id && satisfies($0.version, req.version) }
            .max { compareVersions($0.version, $1.version) < 0 }
    }

    /// Dotted-integer comparison ("1.10" > "1.9").
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    /// "1" (that major version), ">=1", "^1" (same major, at least), nil / "" / "*" (any).
    static func satisfies(_ version: String, _ requirement: String?) -> Bool {
        guard var r = requirement?.trimmingCharacters(in: .whitespaces), !r.isEmpty, r != "*" else { return true }
        if r.hasPrefix(">=") { r.removeFirst(2); return compareVersions(version, r.trimmingCharacters(in: .whitespaces)) >= 0 }
        if r.hasPrefix("^") {
            r.removeFirst()
            let major = r.split(separator: ".").first.map(String.init) ?? r
            return version.split(separator: ".").first.map(String.init) == major && compareVersions(version, r) >= 0
        }
        if r.hasPrefix("=") { r.removeFirst() }
        // "1" matches 1, 1.2, …; "1.2" matches exactly 1.2(.x)
        let want = r.split(separator: ".")
        let have = version.split(separator: ".")
        return have.count >= want.count && zip(have, want).allSatisfy { Int($0) == Int($1) }
    }

    /// This build's version (nil in the tools: then nothing is too new).
    static var appVersion: String? {
        for b in [Bundle.main, Bundle(for: MetalRenderer.self)] {
            if let v = b.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty, !v.contains("$") { return v }
        }
        return nil
    }

    static func isCompatible(minApp: String?) -> Bool {
        guard let min = minApp, let app = appVersion else { return true }
        return compareVersions(app, min) >= 0
    }

    // MARK: Pullable engines

    /// engines-index.json, from `indexURL`.
    static func availableEngines() async throws -> [EngineIndexEntry] {
        let data = try await fetch(indexURL, limit: 1024 * 1024)
        do {
            return try JSONDecoder().decode(EngineIndex.self, from: data).engines
        } catch {
            throw CustomSceneError.download("engines-index.json isn't readable: \(error.localizedDescription)")
        }
    }

    /// Downloads the newest compatible version of engine `id`, verifies its size and SHA-256
    /// against the index, and installs it into `<store>/engines/<id>/<version>/`.
    @discardableResult
    static func pullEngine(id: String, store: URL) async throws -> EngineInfo {
        let index = try await availableEngines()
        guard let entry = index.filter({ $0.id == id && isCompatible(minApp: $0.minApp) })
                .max(by: { compareVersions($0.version, $1.version) < 0 }) else {
            throw CustomSceneError.engine("no engine \"\(id)\" for this version of DotStudio in the index")
        }
        if engines(store: store).contains(where: { $0.id == id && $0.builtIn }) {
            throw CustomSceneError.engine("\"\(id)\" is built in")
        }
        guard entry.size > 0, entry.size <= maxEngineBytes else { throw CustomSceneError.download("engine size \(entry.size) out of range") }
        let url = URL(string: entry.url, relativeTo: indexURL)?.absoluteURL ?? indexURL
        let data = try await fetch(url, limit: maxEngineBytes)
        guard data.count == entry.size else { throw CustomSceneError.download("size mismatch: \(data.count) bytes, the index says \(entry.size)") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == entry.sha256.lowercased() else { throw CustomSceneError.download("SHA-256 mismatch: the download isn't the engine the index lists") }
        return try installEngineBundle(data, expecting: entry, store: store)
    }

    /// Unpacks a verified engine bundle into the store (atomically: a temp folder moved in).
    static func installEngineBundle(_ data: Data, expecting entry: EngineIndexEntry, store: URL) throws -> EngineInfo {
        guard let bundle = try? JSONDecoder().decode(EngineBundle.self, from: data), bundle.format == 1 else {
            throw CustomSceneError.download("not an engine bundle")
        }
        guard bundle.id == entry.id, bundle.version == entry.version,
              bundle.id.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil,
              bundle.version.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil else {
            throw CustomSceneError.download("the bundle is \(bundle.id) \(bundle.version), not \(entry.id) \(entry.version)")
        }
        let allowed = Set(["json", "h", "metal", "md", "glsl", "txt", "png", "jpg"])
        let fm = FileManager.default
        let root = enginesDir(store).appendingPathComponent(bundle.id, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".pull-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            for (path, b64) in bundle.files {
                guard isSafeRelativePath(path, maxDepth: 4),
                      allowed.contains((path as NSString).pathExtension.lowercased()),
                      let bytes = Data(base64Encoded: b64) else {
                    throw CustomSceneError.download("the bundle has a file this build won't install: \(path)")
                }
                let dst = tmp.appendingPathComponent(path)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: dst)
            }
            guard let mdata = try? Data(contentsOf: tmp.appendingPathComponent("engine.json")),
                  let m = try? JSONDecoder().decode(EngineManifest.self, from: mdata),
                  m.id == bundle.id, m.version == bundle.version,
                  ["metal-source", "cells", "glsl-source", "film"].contains(m.kind) else {
                throw CustomSceneError.download("the bundle's engine.json is missing or doesn't match")
            }
            let dst = root.appendingPathComponent(bundle.version, isDirectory: true)
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dst) }
            return EngineInfo(id: m.id, version: m.version, kind: m.kind, builtIn: false, url: dst, manifest: m)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private static func fetch(_ url: URL, limit: Int) async throws -> Data {
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url) else { throw CustomSceneError.download("can't read \(url.path)") }
            guard d.count <= limit else { throw CustomSceneError.download("\(url.lastPathComponent) is too large") }
            return d
        }
        guard url.scheme == "https" else { throw CustomSceneError.download("only https downloads: \(url)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("DotStudio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw CustomSceneError.download("HTTP \(h.statusCode) for \(url.lastPathComponent)")
        }
        guard data.count <= limit else { throw CustomSceneError.download("\(url.lastPathComponent) is too large") }
        return data
    }
}

// MARK: - Styles made from a package

extension EffectInstance {
    /// A Custom Scene effect for an installed package, at the manifest's defaults.
    static func customScene(_ m: CustomSceneManifest) -> EffectInstance {
        var e = EffectInstance(.custom)
        e.custom = CustomSceneRef(id: m.id)
        e.params = [:]
        for s in m.paramSpecs { e.params[s.key] = s.def }
        e.colorA = m.defaultColorA
        e.colorB = m.defaultColorB
        // A film package from the Blender toolkit carries its look ("look": {grain, bloom,
        // halation}): its grain is the style's starting Grain (the engine adds it live); bloom and
        // halation are baked into its clips, so the engine's Halation starts at 0.
        if m.engine.id == "film", case .object(let look)? = m.unknownFields["look"] {
            func num(_ v: JSONValue?) -> Double? {
                switch v { case .number(let d)?: return d; case .integer(let i)?: return Double(i); default: return nil }
            }
            if let g = num(look["grain"]), g.isFinite { e.params["ds.grain"] = Swift.min(Swift.max(g, 0), 1) }
            if look["halation"] != nil { e.params["ds.halation"] = 0 }
        }
        return e
    }

    /// This effect's package manifest (Custom Scene only), from the app's store.
    var customManifest: CustomSceneManifest? {
        guard kind == .custom, let id = custom?.id else { return nil }
        return CustomScenes.manifest(id: id, store: CustomScenes.defaultStore)
    }

    // What the Inspector shows: the kind's metadata, or for a Custom Scene its package's.
    var paramSpecs: [ParamSpec] {
        guard kind == .custom else { return kind.params }
        guard let m = customManifest else { return [] }
        let engineParams = CustomScenes.resolveEngine(m.engine, store: CustomScenes.defaultStore)?.engineParamSpecs ?? []
        return m.paramSpecs + engineParams
    }
    var defaultParamValues: [String: Double] {
        var d: [String: Double] = [:]
        for p in paramSpecs { d[p.key] = p.def }
        return d
    }
    var defaultColorAValue: RGBA? { kind == .custom ? (customManifest?.defaultColorA ?? kind.defaultColorA) : kind.defaultColorA }
    var defaultColorBValue: RGBA? { kind == .custom ? (customManifest?.defaultColorB ?? kind.defaultColorB) : kind.defaultColorB }
    var colorALabelText: String { kind == .custom ? (customManifest?.colorALabel ?? "Colour A") : kind.colorALabel }
    var colorBLabelText: String { kind == .custom ? (customManifest?.colorBLabel ?? "Colour B") : kind.colorBLabel }
    var displayNameText: String { kind == .custom ? (customManifest?.name ?? kind.displayName) : kind.displayName }
    var blurbText: String { kind == .custom ? (customManifest?.description ?? kind.blurb) : kind.blurb }
}

extension Preset {
    /// A new style drawing an installed scene package (its name, frame rate and defaults).
    static func customScene(_ m: CustomSceneManifest) -> Preset {
        var p = Preset(name: m.name, effects: [.customScene(m)])
        p.fps = Swift.min(Swift.max(m.fps ?? 30, 1), 120)
        return p
    }

    /// The scene packages this style draws.
    var customSceneIDs: [String] { effects.compactMap { $0.enabled && $0.kind == .custom ? $0.custom?.id : nil } }

    /// Whether a Custom Scene in this style reads `feature` ("sun", "weather", "music"), from the
    /// manifests read so far (CustomScenes.knownManifest).
    func customUses(_ feature: String) -> Bool {
        customSceneIDs.contains {
            guard let m = CustomScenes.knownManifest(id: $0) else { return false }
            if m.usesSet.contains(feature) { return true }
            // a film follows the sun, and the weather when it has a rain clip
            if m.engine.id == "film" { return feature == "sun" || (feature == "weather" && (m.clips ?? []).contains { $0.variant.lowercased() == "rain" }) }
            return false
        }
    }

    /// Whether this style's first scene is a film package (video clips: the wallpaper holds a
    /// still on battery Efficient, where decoding would cost more than the reduced frame rate saves).
    var isFilmScene: Bool {
        guard let first = effects.first(where: \.enabled), first.kind == .custom, let id = first.custom?.id else { return false }
        return CustomScenes.knownManifest(id: id)?.engine.id == "film"
    }
}
