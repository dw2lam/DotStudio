//  ToolsCustom.swift — custom shader scenes (CustomScenesAPI) and film scenes (FilmToolkitAPI).

import Foundation

extension Toolbox {
    static let manifestSchema: JSONObject = [
        "type": "object",
        "description": "scene.json (contract §2). id is generated from name when omitted. Params map to ctx.p[0…15] in order; colours to ctx.colorA / colorB.",
        "properties": [
            "id": S.str("Optional: [a-z0-9-]{1,48}-<8 hex>. Omit to generate.", pattern: "^[a-z0-9-]{1,48}-[0-9a-f]{8}$"),
            "name": S.str("Display name.", max: 60),
            "author": S.str("Author."), "licence": S.str("Licence of the source (e.g. \"MIT\", \"CC BY 4.0\", \"own work\")."),
            "engine": S.obj(["id": S.str("metal, cells, or a pulled engine (list_engines)."), "version": S.str("e.g. \">=1\"")], required: ["id"]),
            "entry": S.str("Entry source file name (default scene.metal; scene.glsl for shadertoy).", pattern: "^[A-Za-z0-9._-]{1,64}$"),
            "fps": ["type": "integer", "enum": [15, 24, 30, 60], "description": "Frame rate (24/30 for calm scenes)."],
            "stepped": S.bool("Stepped time (ctx.t advances in whole frames at fps)."),
            "params": S.arr(S.obj(["key": S.str("Param key.", pattern: "^[a-z][A-Za-z0-9_]{0,31}$"), "label": S.str("UI label.", max: 32),
                                   "kind": S.str("slider, toggle or menu", enum: ["slider", "toggle", "menu"]),
                                   "min": S.num("slider min"), "max": S.num("slider max"), "default": S.num("default value (menu: index)"),
                                   "options": S.arr(S.str("option", max: 24), "menu options", min: 2, max: 12)],
                                  required: ["key", "label", "kind", "default"], extra: false), "Up to 16 params.", max: 16),
            "colors": S.obj(["a": S.obj(["label": S.str("Label", max: 24), "default": S.arr(S.num("0…1", min: 0, max: 1), "[r,g,b,a]", min: 3, max: 4)], required: ["label", "default"]),
                             "b": S.obj(["label": S.str("Label", max: 24), "default": S.arr(S.num("0…1", min: 0, max: 1), "[r,g,b,a]", min: 3, max: 4)], required: ["label", "default"])]),
            "uses": S.arr(S.str("what it reads", enum: ["sun", "weather", "music", "clock"]), "What the scene reacts to."),
            "description": S.str("One or two sentences.", max: 400),
            "guides": S.arr(S.str("guide id"), "Guides it follows, e.g. [\"style/dotstudio\"]."),
        ],
        "required": ["name", "engine"],
        "additionalProperties": true,
    ]

    static let filesSchema: JSONObject = ["type": "object", "description": "Extra source files by relative name (e.g. {\"common.h\": \"…\"}).",
                                          "additionalProperties": ["type": "string"]]

    // MARK: Custom scenes

    var custom: [Tool] {
        [
            Tool(name: "list_engines", title: "List engines",
                 description: "Rendering engines for custom scenes: built-in (metal: write `float4 dsScene(float2 uv, DSContext ctx)` in Metal; cells: LED/pixel-panel scenes) and pullable ones (shadertoy: GLSL mainImage compatibility; film: photoreal Blender renders). Read an engine's guide (read_guide engines/<id>) before writing a scene for it.",
                 input: S.obj(["include_available": S.bool("Also list engines that can be pulled (needs the network).")]),
                 readOnly: true, idempotent: true, openWorld: true) { [unowned self] a in
                guard self.scenes.isAvailable else { throw ToolError(UnavailableCustomScenes.message) }
                let installed: [JSONObject] = self.scenes.engines().map {
                    ["id": $0.id, "version": $0.version, "kind": $0.kind, "builtIn": $0.builtIn, "summary": $0.summary, "guide": "engines/\($0.id)"]
                }
                var o: JSONObject = ["installed": installed]
                if (a["include_available"] as? Bool) == true {
                    o["available"] = try self.scenes.availableEngines().map {
                        ["id": $0.id, "version": $0.version, "summary": $0.summary, "sizeBytes": $0.size, "minApp": $0.minApp] as JSONObject
                    }
                }
                return .ok(installed.map { "- \($0["id"]!) v\($0["version"]!) (\($0["kind"]!))\(($0["builtIn"] as? Bool) == true ? ", built in" : "")" }.joined(separator: "\n"), o)
            },
            Tool(name: "pull_engine", title: "Pull an engine",
                 description: "Download and install an optional engine (e.g. \"shadertoy\", \"film\") from DotStudio's engine index. Verified by sha256; engines are shader headers, translators and docs, never native code. Tell the user before pulling a large one (film).",
                 input: S.obj(["id": S.str("Engine id from list_engines(include_available: true).", pattern: "^[a-z0-9-]{1,32}$")], required: ["id"]),
                 idempotent: true, openWorld: true) { [unowned self] a in
                let e = try self.scenes.pullEngine(id: a["id"] as! String)
                return .ok("Installed engine \(e.id) v\(e.version). Read its guide: read_guide(\"engines/\(e.id)\").",
                           ["id": e.id, "version": e.version, "kind": e.kind, "guide": "engines/\(e.id)"])
            },
            Tool(name: "list_custom_scenes", title: "List custom scenes",
                 description: "Installed custom scene packages (id, name, engine, params, colours, uses). Use one in a style with create_style effects: [{\"kind\": \"custom\", \"scene\": \"<id>\", \"params\": {…}}].",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in
                guard self.scenes.isAvailable else { throw ToolError(UnavailableCustomScenes.message) }
                let m = self.scenes.installed()
                return .ok(m.isEmpty ? "No custom scenes installed." : m.map { "- \($0["id"] ?? "?"): \($0["name"] ?? "")" }.joined(separator: "\n"), ["scenes": m])
            },
            Tool(name: "validate_custom_scene", title: "Validate a custom scene",
                 description: "Check a scene package without installing it: manifest rules and a real shader compile, with diagnostics (line, column, message) and the source lines around each error, plus GPU ms at 5K when it compiles. Pass manifest + source, or `id` to re-check an installed one.",
                 input: S.obj(["manifest": Self.manifestSchema, "source": S.str("The entry file's source."), "files": Self.filesSchema,
                               "id": S.str("An installed scene id instead.")]),
                 readOnly: true, idempotent: true) { [unowned self] a in
                guard self.scenes.isAvailable else { throw ToolError(UnavailableCustomScenes.message) }
                if let id = a["id"] as? String {
                    let dir = AIStore.scenesDir(self.store).appendingPathComponent(id)
                    guard FileManager.default.fileExists(atPath: dir.path) else { throw ToolError("No installed scene \(id).") }
                    let src = self.entrySource(dir)
                    return self.reportResult(try self.scenes.validate(packageAt: dir), source: src, installed: nil)
                }
                guard let m = a["manifest"] as? JSONObject, let src = a["source"] as? String else { throw ToolError("Pass manifest + source, or id.") }
                let (dir, _) = try self.stage(m, source: src, files: a["files"] as? JSONObject, existingID: nil)
                defer { try? FileManager.default.removeItem(at: dir) }
                return self.reportResult(try self.scenes.validate(packageAt: dir), source: src, installed: nil)
            },
            Tool(name: "create_custom_scene", title: "Create a custom scene",
                 description: "Write a new scene as shader source (engine metal: `#include <DotStudio.h>` then `float4 dsScene(float2 uv, DSContext ctx)`; read_guide engines/<engine> first) plus its manifest. It's validated and compiled; on errors you get diagnostics to fix (nothing installed); on success it's installed and you get its id — then create_style with {\"kind\": \"custom\", \"scene\": id} and preview it. Follow style/dotstudio: slow, calm, dark-first, burn-in safe.",
                 input: S.obj(["manifest": Self.manifestSchema, "source": S.str("The entry file's source."), "files": Self.filesSchema],
                              required: ["manifest", "source"])) { [unowned self] a in
                guard self.scenes.isAvailable else { throw ToolError(UnavailableCustomScenes.message) }
                let m = a["manifest"] as! JSONObject, src = a["source"] as! String
                if let id = m["id"] as? String, self.scenes.installed().contains(where: { $0["id"] as? String == id }) {
                    throw ToolError("A scene with id \(id) is installed already: use update_custom_scene, or omit id for a new one.")
                }
                let (dir, _) = try self.stage(m, source: src, files: a["files"] as? JSONObject, existingID: nil)
                defer { try? FileManager.default.removeItem(at: dir) }
                let report = try self.scenes.validate(packageAt: dir)
                guard report.ok else { return self.reportResult(report, source: src, installed: nil) }
                let installed = try self.scenes.install(packageAt: dir)
                return self.reportResult(report, source: src, installed: installed)
            },
            Tool(name: "update_custom_scene", title: "Update a custom scene",
                 description: "Change an installed custom scene's source and/or manifest (same id). Validated first; the installed version is replaced only if the new one compiles. Styles using it pick up the change.",
                 input: S.obj(["id": S.str("Installed scene id."), "manifest": Self.manifestSchema, "source": S.str("New entry source."), "files": Self.filesSchema],
                              required: ["id"])) { [unowned self] a in
                guard self.scenes.isAvailable else { throw ToolError(UnavailableCustomScenes.message) }
                let id = a["id"] as! String
                let dir = AIStore.scenesDir(self.store).appendingPathComponent(id)
                guard let d = try? Data(contentsOf: dir.appendingPathComponent("scene.json")), var m = JSON.parse(d) as? JSONObject else {
                    throw ToolError("No installed scene \(id). list_custom_scenes shows them.")
                }
                if let nm = a["manifest"] as? JSONObject { for (k, v) in nm where k != "id" { m[k] = v } }
                m["id"] = id
                let src = a["source"] as? String ?? self.entrySource(dir)
                let (stage, _) = try self.stage(m, source: src, files: a["files"] as? JSONObject, existingID: id, copyFrom: dir)
                defer { try? FileManager.default.removeItem(at: stage) }
                let report = try self.scenes.validate(packageAt: stage)
                guard report.ok else { return self.reportResult(report, source: src, installed: nil) }
                return self.reportResult(report, source: src, installed: try self.scenes.install(packageAt: stage))
            },
        ]
    }

    func entrySource(_ dir: URL) -> String {
        let m = (try? Data(contentsOf: dir.appendingPathComponent("scene.json"))).flatMap { JSON.parse($0) as? JSONObject } ?? [:]
        let entry = m["entry"] as? String ?? "scene.metal"
        return (try? String(contentsOf: dir.appendingPathComponent(entry), encoding: .utf8)) ?? ""
    }

    /// Manifest rules beyond the schema (ranges, defaults, engines), then a package folder in
    /// <store>/.staging (inside the store, so the engine side and a sandboxed reader agree).
    func stage(_ manifest: JSONObject, source: String, files: JSONObject?, existingID: String?, copyFrom: URL? = nil) throws -> (URL, String) {
        var m = manifest
        var problems: [String] = []
        let engine = (m["engine"] as? JSONObject)?["id"] as? String ?? ""
        let engines = scenes.engines().map(\.id)
        if !engines.contains(engine) {
            problems.append("engine \"\(engine)\" isn't installed (have: \(engines.joined(separator: ", "))). pull_engine it first if it's pullable.")
        }
        for (i, p) in (m["params"] as? [JSONObject] ?? []).enumerated() {
            let kind = p["kind"] as? String ?? "slider"
            let def = (p["default"] as? NSNumber)?.doubleValue ?? 0
            switch kind {
            case "slider":
                guard let mn = (p["min"] as? NSNumber)?.doubleValue, let mx = (p["max"] as? NSNumber)?.doubleValue else {
                    problems.append("params[\(i)]: a slider needs min and max"); continue
                }
                if mn >= mx { problems.append("params[\(i)]: min must be below max") }
                if def < mn || def > mx { problems.append("params[\(i)]: default \(Schema.fmt(def)) is outside \(Schema.fmt(mn))…\(Schema.fmt(mx))") }
            case "toggle":
                if def != 0 && def != 1 { problems.append("params[\(i)]: a toggle's default is 0 or 1") }
            default:
                let n = (p["options"] as? [Any])?.count ?? 0
                if n < 2 { problems.append("params[\(i)]: a menu needs 2+ options") }
                if def < 0 || Int(def) >= max(n, 1) || def != def.rounded() { problems.append("params[\(i)]: a menu's default is an option index 0…\(max(n - 1, 0))") }
            }
        }
        let keys = (m["params"] as? [JSONObject] ?? []).compactMap { $0["key"] as? String }
        if Set(keys).count != keys.count { problems.append("param keys must be unique") }
        if source.utf8.count > 512 * 1024 { problems.append("source is over 512 KB") }
        var extra: [(String, String)] = []
        for (name, v) in files ?? [:] {
            guard let text = v as? String else { problems.append("files.\(name) must be a string"); continue }
            if name.range(of: "^[A-Za-z0-9._-]{1,64}(/[A-Za-z0-9._-]{1,64})?$", options: .regularExpression) == nil || name.contains("..") || name == "scene.json" {
                problems.append("files: \"\(name)\" isn't an allowed file name"); continue
            }
            extra.append((name, text))
        }
        guard problems.isEmpty else {
            throw ToolError("The manifest needs fixing:\n- " + problems.joined(separator: "\n- "), details: ["problems": problems])
        }
        let id: String
        if let e = existingID { id = e } else if let given = m["id"] as? String { id = given } else {
            let slug = (m["name"] as? String ?? "scene").lowercased().unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
                .split(separator: "-").joined(separator: "-")
            id = String((slug.isEmpty ? "scene" : slug).prefix(48)) + "-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        }
        m["id"] = id
        m["format"] = m["format"] ?? 1
        let entry = m["entry"] as? String ?? (engine == "shadertoy" ? "scene.glsl" : "scene.metal")
        m["entry"] = entry
        let dir = store.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        if let copyFrom { try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.copyItem(at: copyFrom, to: dir) }
        else { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try JSON.data(m, pretty: true).write(to: dir.appendingPathComponent("scene.json"))
        try Data(source.utf8).write(to: dir.appendingPathComponent(entry))
        for (name, text) in extra {
            let u = dir.appendingPathComponent(name)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        return (dir, id)
    }

    func reportResult(_ r: CSReport, source: String, installed: String?) -> ToolResult {
        let lines = source.components(separatedBy: "\n")
        var text = r.ok ? "Compiles." : "Doesn't compile yet: \(r.diagnostics.filter { $0.severity == "error" }.count) error(s)."
        for d in r.diagnostics {
            text += "\n\(d.severity) \(d.line.map { "line \($0)\(d.column.map { ":\($0)" } ?? "")" } ?? ""): \(d.message)"
            if let l = d.line, l >= 1, l <= lines.count {
                for n in max(1, l - 2)...min(lines.count, l + 2) { text += "\n  \(n == l ? ">" : " ")\(String(format: "%4d", n)) | \(lines[n - 1])" }
            }
        }
        for w in r.warnings { text += "\nwarning: \(w)" }
        if let ms = r.gpuMsAt5K { text += String(format: "\nGPU ≈ %.2f ms per frame at 5K.", ms) }
        if let installed { text += "\nInstalled as \(installed). Use it: create_style(effects: [{\"kind\": \"custom\", \"scene\": \"\(installed)\"}])." }
        var o: JSONObject = ["ok": r.ok, "diagnostics": r.diagnostics.map(\.json), "warnings": r.warnings]
        if let ms = r.gpuMsAt5K { o["gpuMsAt5K"] = ms }
        if let installed { o["id"] = installed }
        var res = ToolResult.ok(text, o)
        res.isError = !r.ok
        return res
    }

    // MARK: Film

    var filmTools: [Tool] {
        let variants = S.arr(S.str("variant", enum: ["day", "golden", "night", "rain"]), "Lighting/weather variants (default all four).", min: 1, max: 4)
        return [
            Tool(name: "film_status", title: "Film status",
                 description: "Can this Mac make film scenes (photoreal, ray-traced Blender renders played as seamless video loops)? Reports Blender (installed? version), whether the film engine/toolkit is pulled, the GPU, and recent film jobs. Film scenes are big: renders take tens of minutes to hours and clips are hundreds of MB — tell the user before starting one.",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in
                let s = self.film.status()
                let jobs = FilmJobs.all(self.store).prefix(10).map { j -> JSONObject in
                    ["id": j.id, "kind": j.kind, "state": FilmJobs.state(self.store, j).0.rawValue]
                }
                var text = "Blender: \(s.blenderPath.map { "\($0) (\(s.blenderVersion ?? "version unknown"))" } ?? "not installed (blender.org; DotStudio looks in /Applications)"). "
                text += "Film engine: \(s.toolkitPulled ? "pulled v\(s.toolkitVersion ?? "?")" : "not pulled (pull_engine \"film\")"). GPU: \(s.gpu)."
                if !s.notes.isEmpty { text += "\n" + s.notes.joined(separator: "\n") }
                return .ok(text, ["available": self.film.isAvailable, "blender": s.blenderPath ?? NSNull(), "blenderVersion": s.blenderVersion ?? NSNull(),
                                  "toolkitPulled": s.toolkitPulled, "gpu": s.gpu, "jobs": Array(jobs)])
            },
            Tool(name: "create_film_scene", title: "Create a film scene",
                 description: "Save a film scene draft from a scene spec in the film toolkit's format (read_guide engines/film for the schema: camera, set, assets (CC0), lighting, motion that loops). Validates the spec; returns a draft id for render_film_stills → render_film_loop. Nothing renders yet.",
                 input: S.obj(["spec": ["type": "object", "description": "The toolkit's scene spec (engines/film)."],
                               "name": S.str("Name for the scene.", max: 60)], required: ["spec"])) { [unowned self] a in
                guard self.film.isAvailable else { throw ToolError(UnavailableFilmToolkit.message) }
                var spec = a["spec"] as! JSONObject
                if let n = a["name"] as? String { spec["name"] = n }
                let r = self.film.validate(spec: spec)
                guard r.ok else { return self.reportResult(r, source: JSON.string(spec, pretty: true), installed: nil) }
                let id = "film-" + String(UUID().uuidString.prefix(8)).lowercased()
                let dir = FilmPaths.draftsDir(self.store).appendingPathComponent(id)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try JSON.data(spec, pretty: true).write(to: dir.appendingPathComponent("spec.json"))
                return .ok("Saved film draft \(id). Next: render_film_stills(draft: \"\(id)\") and show the stills to the user before animating.",
                           ["draft": id, "warnings": r.warnings])
            },
            Tool(name: "render_film_stills", title: "Render film stills",
                 description: "Ray-traced (Cycles) stills of a film draft, one per variant, so the user can approve the base scene BEFORE the long loop render. Runs as a background job; waits up to `wait_seconds` (default 60) and returns the images if done, else the job id for film_job_status.",
                 input: S.obj(["draft": S.str("Draft id from create_film_scene.", pattern: "^film-[0-9a-f]{8}$"), "variants": variants,
                               "width": S.num("Default 1280.", min: 320, max: 3840, integer: true),
                               "height": S.num("Default 720.", min: 180, max: 2160, integer: true),
                               "samples": S.num("Cycles samples (default 64).", min: 1, max: 4096, integer: true),
                               "wait_seconds": S.num("How long to wait for the result (0–120, default 60).", min: 0, max: 120)],
                              required: ["draft"]), openWorld: false) { [unowned self] a in
                guard self.film.isAvailable else { throw ToolError(UnavailableFilmToolkit.message) }
                let draft = a["draft"] as! String
                let spec = try self.draftSpecURL(draft)
                let vs = a["variants"] as? [String] ?? ["day", "golden", "night", "rain"]
                let job = try FilmJobs.start(store: self.store, kind: "stills", draft: draft, variants: vs) { out in
                    try self.film.stillsCommand(spec: spec, outDir: out, variants: vs,
                                                width: a["width"] as? Int ?? 1280, height: a["height"] as? Int ?? 720,
                                                samples: a["samples"] as? Int ?? 64)
                }
                let wait = (a["wait_seconds"] as? NSNumber)?.doubleValue ?? 60
                let deadline = Date().addingTimeInterval(wait)
                while FilmJobs.state(self.store, job).0 == .running && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
                return try self.jobStatus(job.id)
            },
            Tool(name: "render_film_loop", title: "Render a film loop",
                 description: "Start the long render: a seamless video loop per variant (Blender headless, nice'd, in the background — it keeps going if this chat ends). Returns a job id at once; poll film_job_status (progress, ETA, log tail). When it finishes, the clips are packaged as a film scene and installed; its id goes into create_style {\"kind\": \"custom\", \"scene\": id}. Confirm with the user first: it can take hours and hundreds of MB.",
                 input: S.obj(["draft": S.str("Draft id.", pattern: "^film-[0-9a-f]{8}$"), "variants": variants,
                               "seconds": S.num("Loop length (default 20).", min: 4, max: 120),
                               "fps": ["type": "integer", "enum": [24, 30], "description": "Default 24."],
                               "width": S.num("Default 3840.", min: 640, max: 7680, integer: true),
                               "height": S.num("Default 2160.", min: 360, max: 4320, integer: true),
                               "quality": S.str("draft, standard (default) or final", enum: ["draft", "standard", "final"])],
                              required: ["draft"])) { [unowned self] a in
                guard self.film.isAvailable else { throw ToolError(UnavailableFilmToolkit.message) }
                let draft = a["draft"] as! String
                let spec = try self.draftSpecURL(draft)
                let vs = a["variants"] as? [String] ?? ["day", "golden", "night", "rain"]
                let job = try FilmJobs.start(store: self.store, kind: "loop", draft: draft, variants: vs) { out in
                    try self.film.loopCommand(spec: spec, outDir: out, variants: vs,
                                              seconds: (a["seconds"] as? NSNumber)?.doubleValue ?? 20, fps: a["fps"] as? Int ?? 24,
                                              width: a["width"] as? Int ?? 3840, height: a["height"] as? Int ?? 2160,
                                              quality: a["quality"] as? String ?? "standard")
                }
                return .ok("Started \(job.id) (\(vs.joined(separator: ", "))). It runs in the background; check film_job_status(job: \"\(job.id)\").",
                           ["job": job.id, "state": "running"])
            },
            Tool(name: "film_job_status", title: "Film job status",
                 description: "Progress of a film job: state (running/done/failed/cancelled), fraction, stage, ETA, the log's last lines; stills come back as images when done; a finished loop is installed as a film scene and its id returned. Without `job`, lists recent jobs.",
                 input: S.obj(["job": S.str("Job id.", pattern: "^[a-z0-9-]{1,64}$")]), readOnly: false, idempotent: true) { [unowned self] a in
                guard let id = a["job"] as? String else {
                    let jobs = FilmJobs.all(self.store).map { j -> JSONObject in ["id": j.id, "kind": j.kind, "draft": j.draft, "state": FilmJobs.state(self.store, j).0.rawValue] }
                    return .ok(jobs.isEmpty ? "No film jobs." : jobs.map { "- \($0["id"]!) \($0["kind"]!) \($0["state"]!)" }.joined(separator: "\n"), ["jobs": jobs])
                }
                return try self.jobStatus(id)
            },
            Tool(name: "cancel_film_job", title: "Cancel a film job",
                 description: "Stop a running film render (its whole process group). Partial output is kept in the job folder but nothing is installed.",
                 input: S.obj(["job": S.str("Job id.", pattern: "^[a-z0-9-]{1,64}$")], required: ["job"]), destructive: true, idempotent: true) { [unowned self] a in
                let job = try FilmJobs.load(self.store, a["job"] as! String)
                let (st, _) = FilmJobs.state(self.store, job)
                guard st == .running else { return .ok("\(job.id) isn't running (\(st.rawValue)).", ["job": job.id, "state": st.rawValue]) }
                FilmJobs.cancel(self.store, job)
                return .ok("Cancelled \(job.id).", ["job": job.id, "state": "cancelled"])
            },
        ]
    }

    func draftSpecURL(_ draft: String) throws -> URL {
        let u = FilmPaths.draftsDir(store).appendingPathComponent(draft).appendingPathComponent("spec.json")
        guard FileManager.default.fileExists(atPath: u.path) else { throw ToolError("No film draft \(draft). create_film_scene makes one.") }
        return u
    }

    func jobStatus(_ id: String) throws -> ToolResult {
        var job = try FilmJobs.load(store, id)
        let jd = FilmJobs.dir(store, id)
        let (st, code) = FilmJobs.state(store, job)
        let prog = FilmJobs.progress(store, job)
        var o: JSONObject = ["job": id, "kind": job.kind, "draft": job.draft, "state": st.rawValue, "progress": prog,
                             "logTail": FilmJobs.logTail(store, job)]
        if let code { o["exitCode"] = code }
        var text = "\(id): \(st.rawValue)"
        if let f = (prog["fraction"] as? NSNumber)?.doubleValue { text += String(format: ", %.0f%%", f * 100) }
        if let s = prog["stage"] as? String { text += " — \(s)" }
        if let eta = (prog["eta_s"] as? NSNumber)?.doubleValue, st == .running { text += String(format: ", about %.0f min left", max(eta / 60, 0.1)) }
        var images: [Data] = []
        if st == .done, job.kind == "stills" {
            for v in job.variants {
                if let d = try? Data(contentsOf: jd.appendingPathComponent("out/\(v).png")) { images.append(d) }
            }
            text += ". \(images.count) still(s): \(job.variants.joined(separator: ", ")). Show them to the user; when the base scene is approved, render_film_loop."
        }
        if st == .done, job.kind == "loop" {
            if job.installedScene == nil, job.packageError == nil {
                do {
                    let spec = JSON.parse(try Data(contentsOf: try draftSpecURL(job.draft))) as? JSONObject ?? [:]
                    let pkg = store.appendingPathComponent(".staging/\(UUID().uuidString)")
                    let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
                    try film.package(loopOutput: jd.appendingPathComponent("out"), spec: spec, sceneID: "\(job.draft)-\(hex)", into: pkg)
                    defer { try? FileManager.default.removeItem(at: pkg) }
                    job.installedScene = try scenes.install(packageAt: pkg)
                } catch let e as ToolError { job.packageError = e.message } catch { job.packageError = "\(error)" }
                FilmJobs.save(store, job)
            }
            if let s = job.installedScene {
                o["scene"] = s
                text += ". Installed film scene \(s): create_style(effects: [{\"kind\": \"custom\", \"scene\": \"\(s)\"}])."
            } else if let e = job.packageError {
                o["packageError"] = e
                text += ". Rendered, but packaging failed: \(e)"
            }
        }
        if st == .failed { text += ". Log tail:\n" + FilmJobs.logTail(store, job, lines: 12) }
        return ToolResult(text: text + (st == .failed || text.hasSuffix(".") ? "" : "."), structured: o, images: images, isError: false)
    }
}
