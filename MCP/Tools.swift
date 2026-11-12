//  Tools.swift — the DotStudio MCP tools: orientation, guides, catalog, styles, previews,
//  what plays. Custom scenes and film live in ToolsCustom.swift.

import CoreGraphics
import Foundation

final class Toolbox {
    let lib: LibraryAccess
    let preview: PreviewRenderer
    let guides: Guides
    let scenes: CustomScenesAPI
    let film: FilmToolkitAPI
    var store: URL { lib.dir }

    init(lib: LibraryAccess, preview: PreviewRenderer, guides: Guides, scenes: CustomScenesAPI, film: FilmToolkitAPI) {
        self.lib = lib
        self.preview = preview
        self.guides = guides
        self.scenes = scenes
        self.film = film
    }

    var all: [Tool] { core + playback + custom + filmTools }

    // MARK: - Helpers

    func styleJSON(_ p: Preset, _ l: Library, created: AICreatedStyles, full: Bool = false) -> JSONObject {
        let lineup = l.screensaverLineup
        var roles: [String] = []
        if lineup.playlist.contains(p.id) { roles.append(lineup.rotates ? "screensaver rotation" : "screensaver") }
        if lineup.night == p.id { roles.append("screensaver at night") }
        for (key, pin) in l.displayStyles ?? [:] where pin.presetID == p.id { roles.append("screensaver on \(pin.name ?? key)") }
        let wall = LibraryAccess.loadWallpaper(store)
        if (wall["enabled"] as? Bool) == true {
            if (wall["followsScreensaver"] as? Bool) != true, (wall["presetID"] as? String).flatMap(UUID.init) == p.id { roles.append("live wallpaper") }
            for (_, v) in wall["displayStyles"] as? JSONObject ?? [:] {
                if let o = v as? JSONObject, (o["presetID"] as? String).flatMap(UUID.init) == p.id { roles.append("live wallpaper on \(o["name"] as? String ?? "a display")") }
            }
        }
        var o: JSONObject = ["id": p.id.uuidString, "name": p.name, "type": p.isScene ? "scene" : "look",
                             "lead": p.leadKindAI?.rawValue ?? (p.unknownEffects.isEmpty ? "none" : "custom"),
                             "effects": p.effects.map(\.kind.rawValue) + p.unknownEffects.map { _ in "custom" },
                             "fps": p.fps, "createdByAI": created.contains(p.id), "playing": roles]
        if full {
            o["style"] = JSON.from(p)
            o["advice"] = StyleBuilder.advice(p)
        }
        return o
    }

    func resolve(_ args: JSONObject, key: String = "style") throws -> Preset {
        guard let s = args[key] as? String else { throw ToolError("Pass `\(key)`: a style id or exact name (list_styles).") }
        return try lib.preset(s)
    }

    var builderContext: StyleBuilder.Context {
        StyleBuilder.Context(customScenes: scenes.installed(), customAvailable: scenes.isAvailable)
    }

    func buildEffects(_ items: [Any], existing: [EffectInstance] = []) throws -> [JSONObject] {
        try items.enumerated().map { i, e in
            guard let o = e as? JSONObject else { throw ToolError("effects[\(i)] must be an object") }
            return try StyleBuilder.effect(o, index: i, ctx: builderContext, existing: existing.indices.contains(i) ? existing[i] : nil)
        }
    }

    /// A style for preview/benchmark: a saved one (`style`) or an unsaved draft.
    func previewTarget(_ args: JSONObject) throws -> Preset {
        if args["style"] != nil, args["draft"] != nil { throw ToolError("Pass `style` or `draft`, not both.") }
        if let d = args["draft"] as? JSONObject {
            let effects = try buildEffects(d["effects"] as? [Any] ?? [])
            guard !effects.isEmpty else { throw ToolError("draft.effects needs at least one effect") }
            return try StyleBuilder.preset(id: UUID(), name: d["name"] as? String ?? "Draft", fps: d["fps"] as? Int ?? 30, effects: effects)
        }
        return try resolve(args)
    }

    func perform(_ req: BridgeRequest) throws -> (BridgeResponse, Bool) {
        let (r, viaApp) = try lib.perform(req)
        guard r.ok else { throw ToolError(r.error ?? "DotStudio refused the change.") }
        return (r, viaApp)
    }

    func whereNote(_ viaApp: Bool) -> String {
        viaApp ? "DotStudio is running: the change is live in the app." : "DotStudio isn't running: library.json was updated; the app shows it next time it opens."
    }

    static let styleRef = S.str("A style id (UUID from list_styles) or its exact name.")
    static let effectsSchema = S.arr(StyleBuilder.effectSchema,
                                     "The effect stack, drawn in order: a scene first (draws its own image), then 0–2 looks that restyle it. Or looks only: they restyle the shared photo slideshow.",
                                     min: 1, max: 6)
    static let draftSchema: JSONObject = S.obj(["name": S.str("Optional name.", max: 60),
                                                "effects": effectsSchema,
                                                "fps": S.num("Frame rate.", integer: true)], required: ["effects"])

    // MARK: - Core

    var core: [Tool] {
        [
            Tool(name: "get_started", title: "Get started",
                 description: "START HERE. A short orientation to designing DotStudio screensavers: how styles work, the workflow (read guides → pick scenes → create_style → preview_style → benchmark_style → set_screensaver), which guides to read first (including the user's own brand guides), and this Mac's state (is DotStudio running, may the AI change what plays, custom/film scenes availability).",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in try self.getStarted() },
            Tool(name: "list_guides", title: "List guides",
                 description: "Every guide the AI should know about: DotStudio's taste (style/dotstudio), per-scene settings (settings/*, generated from this build), app settings, power, burn-in, engine guides (engines/*), and the user's own guides (user/*, e.g. brand guides — honour them). Returns id, title, source and a one-line summary.",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in
                let gs = self.guides.all()
                let items: [JSONObject] = gs.map { g in
                    let text = g.load() ?? ""
                    return ["id": g.id, "title": Guides.title(text) ?? g.id, "source": g.source, "summary": Guides.summary(text)]
                }
                let text = items.map { "- \($0["id"]!) (\($0["source"]!)): \($0["title"]!)" }.joined(separator: "\n")
                return .ok("\(items.count) guides. Read with read_guide(id).\n" + text, ["guides": items])
            },
            Tool(name: "read_guide", title: "Read a guide",
                 description: "The full Markdown of one guide by id (from list_guides), e.g. \"style/dotstudio\" (read before designing), \"settings/index\", \"settings/oceanHorizon\", \"power\", \"burn-in\", \"engines/metal\", \"user/<name>\".",
                 input: S.obj(["id": S.str("Guide id, e.g. style/dotstudio", max: 120)], required: ["id"]),
                 readOnly: true, idempotent: true) { [unowned self] a in
                .ok(try self.guides.read(a["id"] as! String))
            },
            Tool(name: "list_scenes", title: "List scenes and looks",
                 description: "The building blocks of a style. Scenes draw their own image (ocean, meadow, clocks, liquid chrome…); looks restyle what's under them (halftone, riso, glass, grain…). Each entry: kind (what create_style takes), name, blurb, category, what it reacts to (clock, sun, location, weather, music, source) and a perf class (light/medium/heavy at 5K). Retired kinds are left out.",
                 input: S.obj(["type": S.str("scene (default), look, or all", enum: ["scene", "look", "all"]),
                               "category": S.str("Only this group (e.g. \"Print & Halftone\").", enum: EffectCategory.allCases.map(\.rawValue))]),
                 readOnly: true, idempotent: true) { a in
                let type = a["type"] as? String ?? "scene"
                var kinds = Catalog.available.filter { type == "all" || ($0.isScene == (type == "scene")) }
                if let c = a["category"] as? String { kinds = kinds.filter { $0.category.rawValue == c } }
                let items = kinds.map(Catalog.summary)
                let text = kinds.map { "- \($0.rawValue) — \($0.displayName) [\(Catalog.perfClass(ms: Catalog.referenceMs($0)))]: \($0.blurb)" }.joined(separator: "\n")
                return .ok("\(items.count) \(type == "all" ? "effects" : type + "s"). describe_scene(kind) for params and colours.\n" + text, ["items": items])
            },
            Tool(name: "describe_scene", title: "Describe a scene or look",
                 description: "Everything needed to use one scene or look in create_style: params (key, label, slider min/max/step, toggle, menu options with indexes, defaults), the two colour wells (labels + defaults), what it reacts to (clock / sun / location / weather / music / source), perf class and reference GPU ms at 5K, and the built-in styles that use it (good starting points).",
                 input: S.obj(["kind": S.str("Effect kind from list_scenes, e.g. \"oceanHorizon\" (display names also work).")], required: ["kind"]),
                 readOnly: true, idempotent: true) { a in
                let k = a["kind"] as! String
                guard let kind = Catalog.kind(k) else { throw ToolError("Unknown kind \"\(k)\". Call list_scenes.") }
                let d = Catalog.describe(kind)
                return .ok("\(kind.displayName) (\(kind.rawValue)): \(kind.blurb)", d)
            },
            Tool(name: "list_styles", title: "List styles",
                 description: "The user's library of styles (saved screensavers): id, name, scene/look, lead effect, fps, whether the AI created it, and where it plays now (screensaver, rotation, night, per display, live wallpaper).",
                 input: S.obj(["filter": S.str("all (default), scenes, looks, ai (made by the AI), playing", enum: ["all", "scenes", "looks", "ai", "playing"])]),
                 readOnly: true, idempotent: true) { [unowned self] a in
                let l = try self.lib.library()
                let created = AICreatedStyles.load(store: self.store)
                var items = l.presets.map { self.styleJSON($0, l, created: created) }
                switch a["filter"] as? String ?? "all" {
                case "scenes": items = items.filter { $0["type"] as? String == "scene" }
                case "looks": items = items.filter { $0["type"] as? String == "look" }
                case "ai": items = items.filter { $0["createdByAI"] as? Bool == true }
                case "playing": items = items.filter { !(($0["playing"] as? [String]) ?? []).isEmpty }
                default: break
                }
                let text = items.map { o -> String in
                    let roles = (o["playing"] as? [String]) ?? []
                    return "- \(o["name"]!) [\(o["type"]!), \(o["lead"]!)] \(o["id"]!)" + (roles.isEmpty ? "" : " — " + roles.joined(separator: ", "))
                }.joined(separator: "\n")
                return .ok("\(items.count) styles.\n" + text, ["styles": items])
            },
            Tool(name: "get_style", title: "Get a style",
                 description: "One style in full: its effect stack with every param value and colour (the exact JSON DotStudio stores), fps, where it plays, and design advice.",
                 input: S.obj(["style": Self.styleRef], required: ["style"]), readOnly: true, idempotent: true) { [unowned self] a in
                let p = try self.resolve(a)
                let o = self.styleJSON(p, try self.lib.library(), created: AICreatedStyles.load(store: self.store), full: true)
                return .ok("“\(p.name)” (\(p.isScene ? "scene" : "look"), \(p.fps) fps).", o)
            },
            Tool(name: "create_style", title: "Create a style",
                 description: "Add a new style (a screensaver) to the user's DotStudio library. Give it a name, an effect stack (a scene first, then optional looks; see describe_scene for each kind's params and colours) and fps (24 or 30 are right for almost everything). Values are checked strictly against each param's range. The style is created but NOT set as the screensaver — preview it (preview_style), then set_screensaver if the user wants it. If DotStudio is open it appears in the gallery immediately.",
                 input: S.obj(["name": S.str("Short, evocative name (e.g. \"Harbour Dusk\").", max: 60),
                               "effects": Self.effectsSchema,
                               "fps": ["type": "integer", "enum": Catalog.fpsChoices, "description": "Frame rate (default 30). 24 or 30 for calm motion; 60/120 only for fast motion, at a battery cost."]],
                              required: ["name", "effects"])) { [unowned self] a in
                let name = (a["name"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ToolError("name can't be empty") }
                let effects = try self.buildEffects(a["effects"] as! [Any])
                let p = try StyleBuilder.preset(id: UUID(), name: name, fps: a["fps"] as? Int ?? 30, effects: effects)
                let (r, viaApp) = try self.perform(BridgeRequest(op: .upsertStyle, preset: p))
                let id = r.id ?? p.id
                self.lib.markCreated(id)
                var saved = p; saved.name = r.name ?? p.name
                let advice = StyleBuilder.advice(saved)
                let o: JSONObject = ["id": id.uuidString, "name": saved.name, "style": JSON.from(saved), "advice": advice, "liveInApp": viaApp]
                return .ok("Created “\(saved.name)” (\(id.uuidString)). \(self.whereNote(viaApp))"
                           + (advice.isEmpty ? "" : "\nAdvice:\n- " + advice.joined(separator: "\n- "))
                           + "\nNext: preview_style(style: \"\(id.uuidString)\") — and a contact sheet over time (frames: 6) to check the motion.", o)
            },
            Tool(name: "update_style", title: "Update a style",
                 description: "Change a style: rename it, change fps, replace its whole effect stack (`effects`), or patch individual effects by index (`patch`: params merge into the current values; colours replace). Prefer patch for small tweaks after a preview.",
                 input: S.obj(["style": Self.styleRef,
                               "name": S.str("New name.", max: 60),
                               "fps": ["type": "integer", "enum": Catalog.fpsChoices, "description": "New frame rate."],
                               "effects": Self.effectsSchema,
                               "patch": S.arr(S.obj(["index": S.num("Which effect (0 = first).", min: 0, integer: true),
                                                     "params": ["type": "object", "additionalProperties": ["type": ["number", "boolean", "string"]], "description": "Params to change."],
                                                     "colorA": S.color, "colorB": S.color, "enabled": S.bool("On/off.")],
                                                    required: ["index"]), "Edits to individual effects.", min: 1, max: 6)],
                              required: ["style"])) { [unowned self] a in
                var p = try self.resolve(a)
                if a["effects"] != nil, a["patch"] != nil { throw ToolError("Pass `effects` (replace the stack) or `patch` (edit effects), not both.") }
                if let n = a["name"] as? String {
                    let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { throw ToolError("name can't be empty") }
                    p.name = t
                }
                if let f = a["fps"] as? Int { p.fps = f }
                var effectsJSON: [JSONObject] = p.effects.map { JSON.from($0) as? JSONObject ?? [:] }
                if let items = a["effects"] as? [Any] {
                    effectsJSON = try self.buildEffects(items)
                } else if let patches = a["patch"] as? [Any] {
                    for case let pt as JSONObject in patches {
                        let i = (pt["index"] as! NSNumber).intValue
                        guard p.effects.indices.contains(i) else { throw ToolError("patch index \(i): the style has \(p.effects.count) effect(s) (0…\(p.effects.count - 1)).") }
                        var e: JSONObject = ["kind": p.effects[i].kind.rawValue]
                        for k in ["params", "colorA", "colorB", "enabled"] { if let v = pt[k] { e[k] = v } }
                        effectsJSON[i] = try StyleBuilder.effect(e, index: i, ctx: self.builderContext, existing: p.effects[i])
                    }
                }
                // Effects this build can't decode (custom, before the engine lands) keep their places.
                for u in p.unknownEffects where a["effects"] == nil {
                    if case .object(let o) = u.json { effectsJSON.insert(JSON.from(JSONValue.object(o)) as? JSONObject ?? [:], at: min(u.index, effectsJSON.count)) }
                }
                let next = try StyleBuilder.preset(id: p.id, name: p.name, fps: p.fps, effects: effectsJSON)
                let (_, viaApp) = try self.perform(BridgeRequest(op: .upsertStyle, preset: next))
                let advice = StyleBuilder.advice(next)
                return .ok("Updated “\(next.name)”. \(self.whereNote(viaApp))" + (advice.isEmpty ? "" : "\nAdvice:\n- " + advice.joined(separator: "\n- ")),
                           ["id": next.id.uuidString, "style": JSON.from(next), "advice": advice])
            },
            Tool(name: "duplicate_style", title: "Duplicate a style",
                 description: "Copy a style (e.g. a built-in like \"Golden Hour\") under a new name, to vary it without touching the original. The copy counts as the AI's.",
                 input: S.obj(["style": Self.styleRef, "name": S.str("Name for the copy (default \"<name> Copy\").", max: 60)], required: ["style"])) { [unowned self] a in
                let p = try self.resolve(a)
                let (r, viaApp) = try self.perform(BridgeRequest(op: .duplicateStyle, id: p.id, name: a["name"] as? String))
                guard let id = r.id else { throw ToolError("DotStudio didn't return the copy's id") }
                self.lib.markCreated(id)
                return .ok("Duplicated “\(p.name)” as “\(r.name ?? "")” (\(id.uuidString)). \(self.whereNote(viaApp))", ["id": id.uuidString, "name": r.name ?? ""])
            },
            Tool(name: "delete_style", title: "Delete a style",
                 description: "Remove a style from the library. Only styles the AI created (createdByAI in list_styles) can be deleted directly; deleting one of the user's own styles needs confirm: true, which you may pass ONLY after the user explicitly asked to delete that style. Anything it was playing as moves on, as in the app.",
                 input: S.obj(["style": Self.styleRef, "confirm": S.bool("The user explicitly asked to delete this (their own) style.")], required: ["style"]),
                 destructive: true) { [unowned self] a in
                let p = try self.resolve(a)
                let created = AICreatedStyles.load(store: self.store)
                if !created.contains(p.id), (a["confirm"] as? Bool) != true {
                    throw ToolError("“\(p.name)” is one of the user's own styles, not one the AI made. Ask the user; if they confirm, call delete_style again with confirm: true.")
                }
                let (_, viaApp) = try self.perform(BridgeRequest(op: .deleteStyle, id: p.id))
                return .ok("Deleted “\(p.name)”. \(self.whereNote(viaApp))", ["deleted": p.id.uuidString])
            },
            Tool(name: "preview_style", title: "Preview a style",
                 description: "Render a style (saved, or an unsaved `draft`) offscreen to a PNG you can look at: at a moment `t` (seconds into its motion), a wall-clock time (clocks, Follow the Sun), a weather condition (live-weather scenes), with or without the music card. `frames` > 1 makes a contact sheet over `span` seconds to judge the motion (slow? looping? burn-in-prone static parts?). Look at every preview critically against style/dotstudio before showing the user.",
                 input: S.obj(["style": Self.styleRef, "draft": Self.draftSchema,
                               "width": S.num("Pixels (default 1280).", min: 160, max: 2560, integer: true),
                               "height": S.num("Pixels (default 800).", min: 100, max: 1600, integer: true),
                               "t": S.num("Seconds into the motion (default 4).", min: 0, max: 86_400),
                               "clock": S.str("Local wall-clock time HH:mm (clocks and Follow the Sun), default now.", pattern: "^([01]?[0-9]|2[0-3]):[0-5][0-9]$"),
                               "date": S.str("YYYY-MM-DD for `clock` (default today).", pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"),
                               "weather": S.str("Force a weather condition for live-weather scenes.", enum: PreviewRenderer.weatherNames),
                               "music_card": S.bool("Show the corner music card with a sample song (default false)."),
                               "frames": S.num("Contact sheet: this many frames (2–12) instead of one still.", min: 1, max: 12, integer: true),
                               "span": S.num("Contact sheet: seconds covered (default 120).", min: 1, max: 86_400),
                               "save_path": S.str("Also write the PNG to this absolute path (.png).", pattern: "^/.*\\.png$")]),
                 readOnly: true, idempotent: true) { [unowned self] a in try self.previewTool(a) },
            Tool(name: "benchmark_style", title: "Benchmark a style",
                 description: "GPU milliseconds per frame (min and median of 20 live frames, GPU timestamps) at 5K (5120×2880) by default, on this Mac's GPU, with a verdict against DotStudio's budget (aim ≤ 4 ms, ceiling 6 ms at 5K for a screensaver; see read_guide power).",
                 input: S.obj(["style": Self.styleRef, "draft": Self.draftSchema,
                               "width": S.num("Default 5120.", min: 320, max: 7680, integer: true),
                               "height": S.num("Default 2880.", min: 200, max: 4320, integer: true)]),
                 readOnly: true, idempotent: true) { [unowned self] a in
                let p = try self.previewTarget(a)
                let w = a["width"] as? Int ?? 5120, h = a["height"] as? Int ?? 2880
                let r = try self.preview.benchmark(p, library: try self.lib.library(), width: w, height: h)
                let scaled = r.min * (5120.0 * 2880.0) / Double(w * h)
                let verdict = scaled <= 4 ? "within budget" : scaled <= 6 ? "acceptable, near the ceiling — consider fewer effects or lower detail params" : "too heavy for a screensaver: simplify (fewer looks, lower detail/octave params) or lower fps"
                let text = String(format: "“%@” at %d×%d on %@: %.2f ms min, %.2f ms median GPU per frame (≈%.0f fps of GPU headroom). %@.",
                                  p.name, w, h, PreviewRenderer.gpuName, r.min, r.median, 1000 / max(r.median, 0.01), verdict.prefix(1).uppercased() + verdict.dropFirst())
                return .ok(text, ["minMs": r.min, "medianMs": r.median, "width": w, "height": h, "gpu": PreviewRenderer.gpuName,
                                  "verdict": verdict, "budgetMs": 4, "ceilingMs": 6])
            },
            Tool(name: "export_style", title: "Export a style",
                 description: "Write a style as a .dotstudiopreset share file (the app's File ▸ Export Style… format: {formatVersion, preset, source?}). Anyone can double-click it to import. Returns the file path and its JSON.",
                 input: S.obj(["style": Self.styleRef,
                               "path": S.str("Absolute path ending .dotstudiopreset (default: ~/Downloads/<name>.dotstudiopreset).", pattern: "^/.*\\.dotstudiopreset$")],
                              required: ["style"]), idempotent: true) { [unowned self] a in
                let p = try self.resolve(a)
                let data = try PresetExport.encode(p, library: try self.lib.library())
                let safe = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let url = (a["path"] as? String).map { URL(fileURLWithPath: $0) }
                    ?? SharedStore.realHome.appendingPathComponent("Downloads/\(safe).dotstudiopreset")
                do { try data.write(to: url, options: .atomic) } catch {
                    throw ToolError("Couldn't write \(url.path): \(error.localizedDescription)")
                }
                return .ok("Exported “\(p.name)” to \(url.path).", ["path": url.path, "file": JSON.parse(data) ?? [:]])
            },
            Tool(name: "import_style", title: "Import a style",
                 description: "Add a style from a .dotstudiopreset share file (`path`) or its JSON (`json`). It gets fresh ids and counts as the AI's. Params are clamped to their ranges, as in the app; effects from a newer DotStudio are kept but not drawn.",
                 input: S.obj(["path": S.str("Absolute path to a .dotstudiopreset (or .json) file.", pattern: "^/"),
                               "json": ["type": ["object", "string"], "description": "The share file's JSON (object or string)."]])) { [unowned self] a in
                let data: Data
                if let path = a["path"] as? String {
                    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw ToolError("Can't read \(path).") }
                    data = d
                } else if let s = a["json"] as? String {
                    data = Data(s.utf8)
                } else if let o = a["json"] as? JSONObject {
                    data = JSON.data(o)
                } else { throw ToolError("Pass `path` or `json`.") }
                var (p, skipped, _) : (Preset, Int, SourceSpec?)
                do { (p, skipped, _) = try PresetExport.decodeShared(data) } catch {
                    throw ToolError("That isn't a DotStudio share file: \(error.localizedDescription). Expected {\"formatVersion\":1,\"preset\":{…}}.")
                }
                p.id = UUID()
                p.effects = p.effects.map { var e = $0; e.id = UUID(); return e }
                let (r, viaApp) = try self.perform(BridgeRequest(op: .upsertStyle, preset: p))
                let id = r.id ?? p.id
                self.lib.markCreated(id)
                return .ok("Imported “\(r.name ?? p.name)” (\(id.uuidString)). \(self.whereNote(viaApp))" + (skipped > 0 ? " \(skipped) effect(s) from a newer DotStudio are kept but not drawn." : ""),
                           ["id": id.uuidString, "name": r.name ?? p.name, "skippedEffects": skipped])
            },
        ]
    }

    func getStarted() throws -> ToolResult {
        let l = try lib.library()
        let running = lib.appRunning
        let settings = AISettings.load(store: store)
        let user = guides.all().filter { $0.source == "user" }.map(\.id)
        let created = AICreatedStyles.load(store: store).ids.filter { id in l.presets.contains { $0.id == id } }.count
        let playing = Playback.effectivePreset(in: l, now: Date())
        var t = """
        DotStudio makes calm, living screensavers and live wallpapers for the Mac. A STYLE is a named stack of effects: \
        a SCENE first (it draws its own image: ocean, meadow, clocks, liquid chrome, bloom…), then 0–2 LOOKS that restyle it \
        (halftone, riso, glass, grain…). A stack of looks alone restyles the shared photo slideshow.

        Workflow:
        1. read_guide("style/dotstudio") — the house taste. Non-negotiable: calm, premium, dark-first, slow motion, no cheap/glossy looks.
        2. Read the user's own guides if any (below) and honour them; read_guide("settings/index") for every scene's params.
        3. list_scenes / describe_scene to pick a scene; duplicate a close built-in (list_styles) or create_style from scratch.
        4. preview_style (a still, then frames: 6 for motion; clock/weather for scenes that use them) — look critically, iterate with update_style.
        5. benchmark_style (≤ 4 ms at 5K is the aim) — read_guide("power") and ("burn-in") for clocks and static elements.
        6. Only when the user wants it: set_screensaver / set_wallpaper (these change the user's Mac).

        """
        t += "This Mac: DotStudio is \(running ? "running (changes appear live, with a notice)" : "not running (changes are written to its library and show when it opens)"). "
        t += "The AI \(settings.allowPlaybackChanges ? "may" : "may NOT") change what plays (Settings ▸ AI). "
        t += "Library: \(l.presets.count) styles (\(created) made by the AI); the screensaver shows “\(playing.name)” now.\n"
        t += user.isEmpty ? "User guides: none (they can add .md files to \(AIStore.guidesDir(store).path)).\n"
            : "User guides (read and follow these): \(user.joined(separator: ", ")).\n"
        t += "Custom shader scenes: \(scenes.isAvailable ? "available (list_engines, read_guide engines/metal)" : "not in this build"). "
        t += "Film (photoreal Blender) scenes: \(film.isAvailable ? "available (film_status)" : "not in this build").\n"
        return .ok(t, ["appRunning": running, "allowPlaybackChanges": settings.allowPlaybackChanges, "styles": l.presets.count,
                       "aiStyles": created, "nowPlaying": playing.name, "userGuides": user,
                       "readFirst": ["style/dotstudio", "settings/index", "power", "burn-in"] + user,
                       "customScenes": scenes.isAvailable, "film": film.isAvailable, "store": store.path])
    }

    func previewTool(_ a: JSONObject) throws -> ToolResult {
        let p = try previewTarget(a)
        let l = try lib.library()
        var o = PreviewRenderer.Options()
        o.width = a["width"] as? Int ?? 1280
        o.height = a["height"] as? Int ?? 800
        o.time = (a["t"] as? NSNumber)?.doubleValue ?? 4
        o.weather = a["weather"] as? String
        o.musicCard = a["music_card"] as? Bool ?? false
        if let c = a["clock"] as? String {
            let day = (a["date"] as? String) ?? {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: Date())
            }()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let d = f.date(from: "\(day) \(c)") else { throw ToolError("clock/date don't make a valid local time") }
            // Half a second into the minute: exactly on it, the clock shaders' fast-math minute
            // (seconds / 60) can land a hair below and show the minute before.
            o.clock = d.addingTimeInterval(0.5)
        } else if a["date"] != nil { throw ToolError("`date` needs `clock` too.") }
        let n = a["frames"] as? Int ?? 1
        let cg: CGImage
        var note: String
        var meta: JSONObject = ["style": p.name, "width": o.width, "height": o.height]
        if n > 1 {
            let span = (a["span"] as? NSNumber)?.doubleValue ?? 120
            let (sheet, times) = try preview.contactSheet(p, library: l, o, frames: n, span: span)
            cg = sheet
            note = "Contact sheet of “\(p.name)”: \(n) frames at t = " + times.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " s (left to right, top to bottom)."
            meta["times"] = times
        } else {
            cg = try preview.still(p, library: l, o)
            note = String(format: "“%@” at t = %.1f s", p.name, o.time)
            meta["t"] = o.time
        }
        if let c = a["clock"] as? String { note += ", clock \(c)" }
        if let w = o.weather { note += ", weather \(w)" }
        if o.musicCard { note += ", music card on" }
        let st = PreviewRenderer.stats(cg)
        meta["meanLuminance"] = Catalog.round3(st.mean)
        if st.spread < 0.02 { note += ". WARNING: the frame is almost uniform (\(st.mean < 0.05 ? "black" : "flat")) — check the params/colours." }
        else if st.mean > 0.6 { note += ". Note: very bright overall; DotStudio styles are dark-first (style/dotstudio)." }
        let png = PreviewRenderer.png(cg)
        if let path = a["save_path"] as? String {
            do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); meta["savedTo"] = path; note += ". Saved to \(path)" }
            catch { throw ToolError("Rendered, but couldn't write \(path): \(error.localizedDescription)") }
        }
        if !p.unknownEffects.isEmpty, p.effects.isEmpty { note += ". This build can't draw custom scenes yet, so the preview is empty." }
        return .ok(note + ".", meta, images: [png])
    }

    // MARK: - What plays

    var playback: [Tool] {
        [
            Tool(name: "list_displays", title: "List displays",
                 description: "The connected displays (key, name, built-in) and what each shows as screensaver and live wallpaper. Keys are what set_screensaver / set_wallpaper take for a per-display style.",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in
                let l = try self.lib.library()
                let wall = LibraryAccess.loadWallpaper(self.store)
                let shared = Playback.effectivePreset(in: l, now: Date())
                let wallOn = (wall["enabled"] as? Bool) == true
                let wallShared = (wall["presetID"] as? String).flatMap(UUID.init).flatMap { id in l.presets.first { $0.id == id } }
                let items: [JSONObject] = Displays.connected().map { d in
                    let own = l.pinnedPreset(display: d.key)
                    var o: JSONObject = ["key": d.key, "name": d.name, "builtIn": d.builtIn,
                                         "screensaver": (own ?? shared).name, "screensaverOwnStyle": own != nil]
                    if wallOn {
                        let pin = ((wall["displayStyles"] as? JSONObject)?[d.key] as? JSONObject)?["presetID"] as? String
                        let wp = pin.flatMap(UUID.init).flatMap { id in l.presets.first { $0.id == id } }
                        o["wallpaper"] = (wall["followsScreensaver"] as? Bool) == true ? (own ?? shared).name : (wp ?? wallShared)?.name ?? "off"
                    } else { o["wallpaper"] = "off" }
                    return o
                }
                return .ok(items.map { "- \($0["name"]!) [\($0["key"]!)]: screensaver “\($0["screensaver"]!)”, wallpaper \($0["wallpaper"]!)" }.joined(separator: "\n"),
                           ["displays": items])
            },
            Tool(name: "set_screensaver", title: "Set the screensaver",
                 description: "CHANGES THE USER'S MAC: what the macOS screensaver shows. mode only (default): play just this style on every display (or on one `display`, as its own style); add / remove: put it in / take it out of the rotation; night: play it after sunset; dayOnly: no separate night style; unpin: give `display` back to the lineup. Only do this when the user asked for it. DotStudio shows a notice for each change, and the user can turn AI changes off in Settings ▸ AI.",
                 input: S.obj(["style": Self.styleRef,
                               "mode": S.str("only (default), add, remove, night, dayOnly, unpin", enum: ["only", "add", "remove", "night", "dayOnly", "unpin"]),
                               "display": S.str("A display key from list_displays (mode only / unpin).")]),
                 destructive: false, idempotent: true) { [unowned self] a in
                let mode = a["mode"] as? String ?? "only"
                var req = BridgeRequest(op: .setScreensaver, display: a["display"] as? String, mode: mode)
                if !["dayOnly", "unpin"].contains(mode) { req.id = try self.resolve(a).id }
                if mode == "unpin", req.display == nil { throw ToolError("mode unpin needs `display`.") }
                if req.display != nil, !["only", "unpin"].contains(mode) { throw ToolError("`display` works with mode only or unpin.") }
                let (r, viaApp) = try self.perform(req)
                return .ok((r.message ?? "Done.") + " " + self.whereNote(viaApp), ["message": r.message ?? "", "liveInApp": viaApp])
            },
            Tool(name: "set_wallpaper", title: "Set the live wallpaper",
                 description: "CHANGES THE USER'S MAC: DotStudio's live (animated) desktop wallpaper, which plays while the DotStudio app runs. mode set (default): this style on every display (or one `display`); off: stop it; follow: match the screensaver; unpin: give `display` back to the shared pick. Only when the user asked. The wallpaper costs battery: prefer light styles (benchmark_style) and 24–30 fps.",
                 input: S.obj(["style": Self.styleRef,
                               "mode": S.str("set (default), off, follow, unpin", enum: ["set", "off", "follow", "unpin"]),
                               "display": S.str("A display key from list_displays (mode set / unpin).")]),
                 idempotent: true) { [unowned self] a in
                let mode = a["mode"] as? String ?? "set"
                var req = BridgeRequest(op: .setWallpaper, display: a["display"] as? String, mode: mode)
                if mode == "set" { req.id = try self.resolve(a).id }
                if mode == "unpin", req.display == nil { throw ToolError("mode unpin needs `display`.") }
                let (r, viaApp) = try self.perform(req)
                return .ok((r.message ?? "Done.") + " " + self.whereNote(viaApp), ["message": r.message ?? "", "liveInApp": viaApp])
            },
        ]
    }
}
