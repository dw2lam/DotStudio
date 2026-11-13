//  Guides.swift — the guides the AI reads before it designs, from four places:
//    • bundled:   DotStudio.app/Contents/Resources/Guides/**.md (repo: Guides/) — style, power,
//                 burn-in, settings/app, film (the Blender toolkit's flow);
//    • generated: settings/index, settings/looks and settings/<scene kind>, from EffectKind /
//                 SceneCatalog at run time, so they can never drift from the build (the copies in
//                 Guides/settings/ are written by `dotstudio-mcp --write-settings-guides`, and the
//                 self-test fails if they're stale);
//    • engines:   engines/<id> is each engine's own guide.md (CustomScenesAPI.engines: the built-in
//                 ones in Resources/Engines/<id>/<version>/, repo Shared/Engines; pulled ones in
//                 <store>/engines/) — one source of truth, nothing copied into Guides/;
//    • user:      any .md in <store>/guides/ (brand guides…), as user/<file name>.
//  Exposed as MCP resources (dotstudio://guides/<id>) AND through list_guides / read_guide,
//  because many clients ignore resources.

import Foundation

struct Guide {
    let id: String
    let source: String            // bundled | generated | engine | user
    let load: () -> String?
    var title: String { Guides.title(load() ?? "") ?? id }
}

final class Guides {
    let store: URL
    let scenes: CustomScenesAPI

    init(store: URL, scenes: CustomScenesAPI) {
        self.store = store
        self.scenes = scenes
    }

    static var bundledDir: URL? {
        if let p = ProcessInfo.processInfo.environment["DOTSTUDIO_GUIDES_DIR"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL?.appendingPathComponent("Guides")
    }

    static func title(_ md: String) -> String? {
        md.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    /// The first paragraph after the title, for list_guides.
    static func summary(_ md: String) -> String {
        var lines: [Substring] = []
        var started = false
        for l in md.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("#") { if started { break } else { continue } }
            if l.trimmingCharacters(in: .whitespaces).isEmpty { if started { break } else { continue } }
            started = true
            lines.append(l)
        }
        let s = lines.joined(separator: " ")
        return s.count > 280 ? String(s.prefix(277)) + "…" : s
    }

    func all() -> [Guide] {
        var out: [String: Guide] = [:]
        let fm = FileManager.default
        if let dir = Self.bundledDir, let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "md" {
                let rel = url.path.dropFirst(dir.path.count + 1)
                let id = String(rel.dropLast(3))
                out[id] = Guide(id: id, source: "bundled") { try? String(contentsOf: url, encoding: .utf8) }
            }
        }
        out["settings/index"] = Guide(id: "settings/index", source: "generated") { SettingsGuides.index() }
        out["settings/looks"] = Guide(id: "settings/looks", source: "generated") { SettingsGuides.looks() }
        for k in Catalog.available where k.isScene {
            out["settings/\(k.rawValue)"] = Guide(id: "settings/\(k.rawValue)", source: "generated") { SettingsGuides.scene(k) }
        }
        for eng in scenes.engines() {
            if let g = eng.guide, fm.fileExists(atPath: g.path) {
                out["engines/\(eng.id)"] = Guide(id: "engines/\(eng.id)", source: "engine") { try? String(contentsOf: g, encoding: .utf8) }
            }
        }
        let user = AIStore.guidesDir(store)
        for url in (try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension.lowercased() == "md" {
            let id = "user/" + url.deletingPathExtension().lastPathComponent
            out[id] = Guide(id: id, source: "user") { try? String(contentsOf: url, encoding: .utf8) }
        }
        return out.values.sorted { Self.order($0) < Self.order($1) }
    }

    private static func order(_ g: Guide) -> String {
        let rank: [String: String] = ["style/dotstudio": "0", "settings/app": "1", "settings/index": "2", "power": "3", "burn-in": "4"]
        if let r = rank[g.id] { return r + g.id }
        if g.source == "user" { return "5" + g.id }
        if g.id.hasPrefix("engines/") { return "6" + g.id }
        return "7" + g.id
    }

    func read(_ id: String) throws -> String {
        let clean = id.replacingOccurrences(of: ".md", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let g = all().first(where: { $0.id == clean }), let text = g.load() else {
            let near = all().map(\.id).filter { $0.contains(clean.split(separator: "/").last.map(String.init) ?? clean) }
            throw ToolError("No guide \"\(id)\". \(near.isEmpty ? "" : "Did you mean \(near.prefix(5).joined(separator: ", "))? ")Call list_guides for every id.")
        }
        return text
    }

    // MARK: MCP resources

    func resources() -> [JSONObject] {
        all().map { g in
            ["uri": "dotstudio://guides/\(g.id)", "name": g.id, "title": g.title, "mimeType": "text/markdown",
             "description": "\(g.source) guide"]
        }
    }

    func readResource(_ uri: String) throws -> JSONObject {
        let prefix = "dotstudio://guides/"
        guard uri.hasPrefix(prefix) else { throw ToolError("Unknown resource \(uri)") }
        let id = String(uri.dropFirst(prefix.count))
        return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": try read(id)]]]
    }
}

/// settings/*.md, generated from the catalog this binary was built with.
enum SettingsGuides {
    static let header = "<!-- Generated by `dotstudio-mcp --write-settings-guides` from EffectKind / SceneCatalog. Do not edit by hand. -->"

    static func paramLine(_ p: ParamSpec) -> String {
        if let o = p.options {
            return "| `\(p.key)` | \(p.label) | menu | \(o.enumerated().map { "\($0.offset) \($0.element)" }.joined(separator: " · ")) | \(Int(p.def)) (\(o[min(Int(p.def), o.count - 1)])) |"
        }
        if p.isToggle { return "| `\(p.key)` | \(p.label) | toggle | 0 / 1 | \(p.def == 1 ? "on" : "off") |" }
        return "| `\(p.key)` | \(p.label) | slider | \(Schema.fmt(p.min)) … \(Schema.fmt(p.max))\(p.step > 0 ? " (step \(Schema.fmt(p.step)))" : "") | \(Schema.fmt(p.def)) |"
    }

    static func colorText(_ c: RGBA?) -> String {
        guard let c else { return "—" }
        return String(format: "{\"r\":%.3g,\"g\":%.3g,\"b\":%.3g}", c.r, c.g, c.b)
    }

    static func scene(_ k: EffectKind) -> String {
        var s = header + "\n\n# \(k.displayName) (`\(k.rawValue)`)\n\n\(k.blurb)\n\n"
        let reacts = Catalog.reactsTo(k)
        s += "- Type: \(k.isScene ? "scene (draws its own image; put it first)" : "look (restyles what's under it)")\n"
        s += "- Reacts to: \(reacts.isEmpty ? "nothing outside itself (pure motion)" : reacts.joined(separator: ", "))\n"
        let ms = Catalog.referenceMs(k)
        s += "- Cost: \(Catalog.perfClass(ms: ms))\(ms.map { String(format: " (~%.1f ms/frame at 5K on a Pro GPU)", $0) } ?? "")\n"
        let examples = (DefaultPresets.scenes() + DefaultPresets.looks()).filter { $0.leadKindAI == k }.map(\.name)
        if !examples.isEmpty { s += "- Built-in styles: \(examples.joined(separator: ", "))\n" }
        s += "\n## Params\n\n"
        if k.params.isEmpty { s += "None.\n" } else {
            s += "| key | label | kind | range / options | default |\n|---|---|---|---|---|\n"
            s += k.params.map(paramLine).joined(separator: "\n") + "\n"
        }
        if k.usesColors {
            s += "\n## Colours\n\n| slot | label | default |\n|---|---|---|\n"
            s += "| `colorA` | \(k.colorALabel) | \(colorText(k.defaultColorA)) |\n"
            s += "| `colorB` | \(k.colorBLabel) | \(colorText(k.defaultColorB)) |\n"
        }
        s += "\n## In a style\n\n```json\n{\"kind\": \"\(k.rawValue)\", \"params\": {"
        s += k.params.prefix(3).map { "\"\($0.key)\": \(Schema.fmt($0.def))" }.joined(separator: ", ")
        s += "}}\n```\n"
        return s
    }

    static func looks() -> String {
        var s = header + "\n\n# Looks: every effect that restyles a source\n\nLooks rework what's under them: the shared source (built-in photo slideshow, the user's image, video or gradient) or a scene earlier in the same style. Stack 1–3; each is a full-screen pass.\n"
        for cat in EffectCategory.allCases where !cat.isScenes {
            let kinds = EffectKind.available(in: cat)
            guard !kinds.isEmpty else { continue }
            s += "\n## \(cat.rawValue)\n\n\(cat.blurb)\n"
            for k in kinds {
                s += "\n### \(k.displayName) (`\(k.rawValue)`)\n\n\(k.blurb)\n\n"
                if !k.params.isEmpty {
                    s += "| key | label | kind | range / options | default |\n|---|---|---|---|---|\n"
                    s += k.params.map(paramLine).joined(separator: "\n") + "\n"
                }
                if k.usesColors { s += "\nColours: `colorA` \(k.colorALabel) \(colorText(k.defaultColorA)), `colorB` \(k.colorBLabel) \(colorText(k.defaultColorB)).\n" }
            }
        }
        return s
    }

    static func index() -> String {
        var s = header + "\n\n# Settings index: every scene and look\n\nOne guide per scene (`read_guide settings/<kind>`) and one for all looks (`settings/looks`). `kind` is what create_style takes. Cost: light < 3 ms, medium < 6 ms, heavy ≥ 6 ms per frame at 5K on a Pro GPU.\n\n## Scenes\n\n| kind | name | reacts to | cost | what it is |\n|---|---|---|---|---|\n"
        for k in Catalog.available where k.isScene {
            s += "| `\(k.rawValue)` | \(k.displayName) | \(Catalog.reactsTo(k).joined(separator: ", ")) | \(Catalog.perfClass(ms: Catalog.referenceMs(k))) | \(k.blurb) |\n"
        }
        s += "\n## Looks\n\n| kind | name | group |\n|---|---|---|\n"
        for k in Catalog.available where !k.isScene {
            s += "| `\(k.rawValue)` | \(k.displayName) | \(k.category.rawValue) |\n"
        }
        s += "\n## Custom scenes\n\nKind `custom` with `scene`: an installed scene package (`list_custom_scenes`; make one with `create_custom_scene`). Its params and colours are the package's own, plus its engine's (`list_custom_scenes`, `engines/<id>`). An engine compiles a package at run time:\n\n| engine | what you write | guide |\n|---|---|---|\n"
        for e in CustomScenes.engines(store: CustomScenes.defaultStore) where e.builtIn {
            s += "| `\(e.id)` v\(e.version) (built in) | \(e.summary) | `engines/\(e.id)` |\n"
        }
        s += "| `shadertoy` (pulled: `pull_engine`) | Shadertoy-style GLSL (`mainImage`), translated to Metal. | `engines/shadertoy` once pulled |\n"
        s += "\nSee also `settings/app` (styles, lineup, displays, wallpaper, music) and `style/dotstudio` (taste).\n"
        return s
    }

    /// --write-settings-guides <dir>: the generated guides as files (index, looks, one per scene).
    static func write(to dir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(String, String)] = [("index.md", index()), ("looks.md", looks())]
        for k in Catalog.available where k.isScene { files.append(("\(k.rawValue).md", scene(k))) }
        for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic) }
        return files.map(\.0)
    }
}
