//  ToolsSignals.swift — the MCP tools for Signals and When rules (docs/signals-design.md §6):
//  list_signals, test_signal, create_signal, update_signal, delete_signal, list_rules, set_rule,
//  delete_rule, bind_signal. Every change goes through LibraryAccess.perform (the running app, or
//  the files under the lock); the gates live in both executors: signal edits need
//  AISettings.allowSignals, rule edits need allowPlaybackChanges (they change what plays).
//  bind_signal edits a style (it connects a Custom Scene's input to a signal: what plays doesn't
//  change), so it needs nothing beyond what update_style needs.
//
//  Secrets: an assistant can say WHERE a key goes (auth {in, name}) but never sees, sets or reads
//  a key's value — no schema here has a field for one, and nothing here reads the Keychain. A
//  keyed signal is tested through the running app, which holds the key.

import Foundation

extension Toolbox {
    static let signalRef = S.str("A signal: a built-in id (weather.condition, power.battery…) or one of the user's signals by id or exact name (list_signals).", max: 80)
    static let ruleRef = S.str("A When rule's id or exact name (list_rules).", max: 80)

    static var signalFields: JSONObject {
        ["name": S.str("Short name the user will see (\"Air quality\").", max: 60),
         "kind": S.str("web (default): an https JSON URL. file: a file in DotStudio's signal-files folder that a Shortcut, script or cron job writes.", enum: ["web", "file"]),
         "url": S.str("web: the https URL (GET, JSON). Optional {lat} / {lon} placeholders get the weather's rounded location. NEVER a key in it.", max: 2048),
         "file": S.str("file: a plain file name inside signal-files (e.g. \"office.json\").", max: 120),
         "pointer": S.str("JSON Pointer (RFC 6901) to the value, e.g. \"/data/aqi\" (\"\" = the whole document). test_signal's outline lists them.", max: 256),
         "valueType": S.str("number (default), bool or string.", enum: ["number", "bool", "string"]),
         "scale": S.num("number: value × scale + offset."),
         "offset": S.num("number: value × scale + offset."),
         "unit": S.str("Shown after the value (\"AQI\", \"°C\", \"%\").", max: 12),
         "range": S.arr(S.num("bound"), "[low, high]: the value's usual range (a When rule's threshold lets go 5 % of it back).", min: 2, max: 2),
         "default": S.num("The value while it's missing or stale (for scene inputs)."),
         "pollMinutes": S.num("web: minutes between fetches (5–1440, default 15).", min: 5, max: 1440),
         "auth": S.obj(["in": S.str("Where the key goes.", enum: ["header", "query"]),
                        "name": S.str("The header or query parameter name, e.g. \"X-API-Key\" or \"token\".", max: 60)],
                       required: ["in", "name"]),
         "enabled": S.bool("Fetch it (default true)."),
        ]
    }

    var signalTools: [Tool] {
        [
            Tool(name: "list_signals", title: "List signals",
                 description: "The live values DotStudio can react to: the built-ins (weather.condition, weather.precip/snow/cloud/fog/storm 0…1, weather.wind m/s, weather.tempC, sun.elevation, sun.isDay, time.hour, time.weekday, power.battery %, power.onAC, music.playing) and the user's own signals (web: an https JSON value; file: a file in signal-files). Each: id, name, kind, where it comes from (host or file), type, unit, the current value and how fresh it is, the last error, and what uses it (referencedBy: When rules, and styles whose Custom Scene inputs are bound to it — boundBy). Values come from signal-values.json, which the running app writes (fetched only while a rule or a binding uses the signal).",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in try self.listSignals() },
            Tool(name: "test_signal", title: "Test a signal",
                 description: "Fetch a signal once and show what came back: the value it reads, HTTP status, time, size, and an OUTLINE of the document (up to 60 JSON Pointer → leaf values) to pick `pointer` from — never the raw body or headers. Pass `signal` (a saved one) or a `draft` (kind/url/file/pointer/valueType…) before create_signal. A signal with a key can only be tested while DotStudio runs (the app holds the key). Assistants can't reach localhost or the local network; https only.",
                 input: S.obj(["signal": Self.signalRef,
                               "draft": S.obj(["kind": Self.signalFields["kind"]!, "url": Self.signalFields["url"]!, "file": Self.signalFields["file"]!,
                                               "pointer": Self.signalFields["pointer"]!, "valueType": Self.signalFields["valueType"]!,
                                               "scale": Self.signalFields["scale"]!, "offset": Self.signalFields["offset"]!])]),
                 readOnly: true, openWorld: true) { [unowned self] a in try self.testSignal(a) },
            Tool(name: "create_signal", title: "Create a signal",
                 description: "Add a live data signal the user's When rules can react to, or a Custom Scene's input can follow (bind_signal): an https JSON value (kind web: url + pointer; fetched at most every 5 minutes, and only while an enabled When rule or a binding uses it) or a file in DotStudio's signal-files folder (kind file: for Shortcuts, scripts, Home Assistant). test_signal first to find the pointer. If the API needs a key: NEVER put it in the URL and NEVER ask the user to paste it into the chat — set `auth` {in, name} and tell the user to paste the key in DotStudio ▸ Settings ▸ Signals ▸ <name> (it goes to the Keychain; you can never read or set it). Assistants can't add signals for localhost or the local network. Read read_guide(\"signals\") first.",
                 input: S.obj(Self.signalFields, required: ["name"])) { [unowned self] a in try self.createSignal(a) },
            Tool(name: "update_signal", title: "Update a signal",
                 description: "Change one of the user's signals: any field of create_signal (name, url, pointer, valueType, scale, offset, unit, range, pollMinutes, auth, enabled), or remove_auth. Keys still only go in through Settings ▸ Signals.",
                 input: S.obj(Self.signalFields.merging(["signal": Self.signalRef, "remove_auth": S.bool("Stop sending a key.")]) { a, _ in a },
                              required: ["signal"])) { [unowned self] a in try self.updateSignal(a) },
            Tool(name: "delete_signal", title: "Delete a signal",
                 description: "Remove one of the user's signals (its stored key goes too). Refused while a When rule tests it or a style's scene input is bound to it, unless force: true, which also removes those tests (and a rule left with none) and disconnects those inputs (they read their defaults).",
                 input: S.obj(["signal": Self.signalRef, "force": S.bool("Also remove the rule tests that use it.")], required: ["signal"]),
                 destructive: true) { [unowned self] a in
                let s = try self.userSignal(a["signal"] as! String)
                let (r, viaApp) = try self.perform(BridgeRequest(op: .deleteSignal, id: s.id, force: a["force"] as? Bool))
                return .ok((r.message ?? "Deleted.") + " " + self.whereNote(viaApp), ["deleted": s.id.uuidString, "liveInApp": viaApp])
            },
            Tool(name: "bind_signal", title: "Connect a scene input to a signal",
                 description: "Connect one input of a Custom Scene in a style (the package declares them: list_custom_scenes `inputs`, e.g. aqi \"Air quality\" 0…300) to a signal — a built-in (weather.tempC, weather.precip, sun.elevation, power.battery…) or one of the user's (list_signals) — so the scene follows it live: ctx.input[i] eases to the value over ~20 s; while the signal is missing or stale the input eases back to its default. `signal: null` disconnects. Numbers and yes/no signals only. It edits the style (what plays doesn't change); from then on DotStudio watches that signal while the style exists. Inline form: create_style / update_style effects take `inputs` too.",
                 input: S.obj(["style": Self.styleRef,
                               "effect_index": S.num("Which effect (0 = first). Default: the first Custom Scene that declares `input`.", min: 0, integer: true),
                               "input": S.str("The input's key, from the scene's manifest (e.g. \"aqi\").", pattern: "^[a-z][A-Za-z0-9_]{0,31}$"),
                               "signal": ["type": ["string", "null"], "maxLength": 80,
                                          "description": "A built-in signal id (weather.tempC…) or one of the user's signals by id or exact name; null disconnects."] as JSONObject],
                              required: ["style", "input", "signal"]),
                 idempotent: true) { [unowned self] a in try self.bindSignal(a) },
            Tool(name: "list_rules", title: "List When rules",
                 description: "The user's When rules — \"when ⟨condition⟩, play ⟨style⟩\" — in priority order (the first that matches plays): id, name, enabled, the condition (all/any tests on signals, optional timeOfDay), the styles, holdMinutes, a sentence, and activeNow (the rule the running app says plays now). Precedence on screen: a display's own style > the active When rule > the night style > the rotation.",
                 input: S.obj([:]), readOnly: true, idempotent: true) { [unowned self] _ in try self.listRules() },
            Tool(name: "set_rule", title: "Set a When rule",
                 description: "CHANGES WHAT PLAYS: add a When rule, or change one (`rule`). when: {all: [tests], any: [tests], timeOfDay: day|night}; a test is {signal, op, value | values} — ops gt/gte/lt/lte (numbers), eq/neq (any), in (values: [..]), between (values: [lo, hi]); weather.condition takes clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, thunderstorm, snow, sleet; bools take true/false. play: 1–8 styles (several rotate). The running app decides (hysteresis: thresholds let go 5 % of the range back; a rule holds hold_minutes, default 10). Only when the user asked for it; refused while they've turned off “Let AI change what plays”.",
                 input: S.obj(["rule": Self.ruleRef,
                               "name": S.str("Short name (\"Snow day\").", max: 60),
                               "when": S.obj(["all": S.arr(Self.clauseSchema, "Every one must hold.", max: 8),
                                              "any": S.arr(Self.clauseSchema, "At least one must hold.", max: 8),
                                              "timeOfDay": S.str("Only by day or only at night.", enum: ["day", "night"])]),
                               "play": S.arr(Self.styleRef, "The style(s) to play (several rotate).", min: 1, max: PlayRule.maxStyles),
                               "enabled": S.bool("On (default true)."),
                               "hold_minutes": S.num("Once on, stay at least this long (default 10).", min: 0, max: 720)]),
                 idempotent: true) { [unowned self] a in try self.setRule(a) },
            Tool(name: "delete_rule", title: "Delete a When rule",
                 description: "CHANGES WHAT PLAYS: remove a When rule. Only when the user asked. Refused while they've turned off “Let AI change what plays”.",
                 input: S.obj(["rule": Self.ruleRef], required: ["rule"]), destructive: true) { [unowned self] a in
                let r = try self.resolveRule(a["rule"] as! String)
                let (resp, viaApp) = try self.perform(BridgeRequest(op: .deleteRule, id: r.id))
                return .ok((resp.message ?? "Deleted.") + " " + self.whereNote(viaApp), ["deleted": r.id.uuidString, "liveInApp": viaApp])
            },
        ]
    }

    static let clauseSchema: JSONObject = S.obj(
        ["signal": signalRef,
         "op": S.str("gt gte lt lte (numbers), eq neq, in, between.", enum: RuleOp.allCases.map(\.rawValue)),
         "value": ["type": ["number", "boolean", "string"], "description": "The value to compare with."],
         "values": S.arr(["type": ["number", "boolean", "string"]], "in: the values; between: [low, high].", min: 1, max: 12)],
        required: ["signal", "op"])

    // MARK: - Helpers

    var liveState: SignalState? { SignalState.read(baseDir: store) }

    /// One of the user's signals by id or exact name.
    func userSignal(_ ref: String) throws -> Signal {
        let l = try lib.library()
        let all = l.signals ?? []
        if let id = UUID(uuidString: ref), let s = all.first(where: { $0.id == id }) { return s }
        let m = all.filter { $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if m.count == 1 { return m[0] }
        if BuiltInSignals.find(ref) != nil { throw ToolError("\(ref) is built in: it can't be changed or deleted.") }
        throw ToolError("No signal \"\(ref)\". Call list_signals.")
    }

    /// A signal reference in a rule test → its values-map key (built-in id or UUID string).
    func signalKey(_ ref: String, _ l: Library) throws -> String {
        if BuiltInSignals.find(ref) != nil { return ref }
        let all = l.signals ?? []
        if let id = UUID(uuidString: ref), all.contains(where: { $0.id == id }) { return id.uuidString }
        let m = all.filter { $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if m.count == 1 { return m[0].key }
        throw ToolError("No signal \"\(ref)\". Built-ins: \(BuiltInSignals.all.map(\.id).joined(separator: ", ")); or one of the user's (list_signals).")
    }

    func resolveRule(_ ref: String) throws -> PlayRule {
        let rules = try lib.library().rules ?? []
        if let id = UUID(uuidString: ref), let r = rules.first(where: { $0.id == id }) { return r }
        let m = rules.filter { $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if m.count == 1 { return m[0] }
        throw ToolError("No When rule \"\(ref)\". Call list_rules.")
    }

    func signalJSON(_ s: Signal, _ l: Library, _ st: SignalState?, now: Date) -> JSONObject {
        var o: JSONObject = ["id": s.id.uuidString, "name": s.name, "kind": s.kind.rawValue, "valueType": s.valueType.rawValue,
                             "enabled": s.enabled, "createdByAI": s.createdByAI, "hasKey": s.auth != nil]
        uses(&o, s.key, l)
        if s.kind == .web {
            o["host"] = s.host ?? ""
            // The URL the AI chose is its own; the user's own URLs stay with the user (host only).
            if s.createdByAI, let u = s.url { o["url"] = u }
            o["pollMinutes"] = s.interval / 60
            if let a = s.auth { o["keyIn"] = a.placement.rawValue; o["keyName"] = a.name }
        } else {
            o["file"] = s.file ?? ""
        }
        if let p = s.pointer { o["pointer"] = p }
        if let u = s.unit { o["unit"] = u }
        if let r = s.range { o["range"] = r }
        if let d = s.defaultValue { o["default"] = d }
        valueFields(&o, st?.value(s.key, at: now), type: s.valueType, unit: s.unit, now: now)
        return o
    }

    /// What uses a signal: referencedBy (rule names, then "<style> ← <input>" for bindings) and
    /// boundBy ([{style, styleId, input}]).
    func uses(_ o: inout JSONObject, _ key: String, _ l: Library) {
        let bound = l.inputBindings(using: key)
        o["referencedBy"] = l.rules(using: key).map(\.name) + bound.map { "\($0.style.name) ← \($0.input)" }
        o["boundBy"] = bound.map { ["style": $0.style.name, "styleId": $0.style.id.uuidString, "input": $0.input] as JSONObject }
    }

    func valueFields(_ o: inout JSONObject, _ v: SignalValue?, type: SignalValueType, unit: String?, now: Date) {
        guard let v else { o["value"] = NSNull(); o["freshness"] = 0; return }
        o["value"] = v.s.map { $0 as Any } ?? v.v.map { type == .bool ? ($0 > 0.5) as Any : $0 as Any } ?? NSNull()
        o["display"] = v.display(type: type, unit: unit)
        o["freshness"] = Catalog.round3(v.freshness(at: now))
        if let at = v.at { o["at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)) }
        if let e = v.error { o["error"] = e }
    }

    // MARK: - Tools

    func listSignals() throws -> ToolResult {
        let l = try lib.library()
        let st = liveState, now = Date()
        let builtIns: [JSONObject] = BuiltInSignals.all.map { b in
            var o: JSONObject = ["id": b.id, "name": b.name, "kind": "builtin", "valueType": b.type.rawValue]
            uses(&o, b.id, l)
            if let u = b.unit { o["unit"] = u }
            if let r = b.range { o["range"] = [r.lowerBound, r.upperBound] }
            if let opts = b.options { o["options"] = opts }
            valueFields(&o, st?.value(b.id, at: now), type: b.type, unit: b.unit, now: now)
            return o
        }
        let mine = (l.signals ?? []).map { signalJSON($0, l, st, now: now) }
        var text = "\(builtIns.count) built-in signals and \(mine.count) of the user's (at most \(Signal.maxCount)).\n"
        text += builtIns.map { "- \($0["id"]!) — \($0["name"]!)" + (($0["display"] as? String).map { ": \($0)" } ?? "") }.joined(separator: "\n")
        if !mine.isEmpty {
            text += "\nThe user's:\n" + mine.map { o -> String in
                let from = (o["host"] as? String) ?? (o["file"] as? String) ?? ""
                return "- \(o["name"]!) [\(o["kind"]!), \(from)] \(o["id"]!)" + ((o["display"] as? String).map { ": \($0)" } ?? ": no value yet")
                    + ((o["error"] as? String).map { " (last error: \($0))" } ?? "")
            }.joined(separator: "\n")
        }
        if st == nil { text += "\nNo live values yet: DotStudio writes them while it runs and a When rule or a scene input uses a signal." }
        return .ok(text, ["builtIn": builtIns, "signals": mine, "appWritesValues": st != nil])
    }

    func testSignal(_ a: JSONObject) throws -> ToolResult {
        if a["signal"] != nil, a["draft"] != nil { throw ToolError("Pass `signal` or `draft`, not both.") }
        let l = try lib.library()
        var target: Signal
        var isDraft = false
        if let d = a["draft"] as? JSONObject {
            target = Signal(name: "Draft")
            try apply(d, to: &target)
            target.createdBy = "ai"
            isDraft = true
            let problems = SignalPolicy.validate(target, forAI: true)
            if !problems.isEmpty { throw ToolError(problems.joined(separator: " ")) }
        } else if let ref = a["signal"] as? String {
            if BuiltInSignals.find(ref) != nil { throw ToolError("\(ref) is built in: list_signals shows its value.") }
            target = try userSignal(ref)
        } else { throw ToolError("Pass `signal` (a saved signal) or `draft`.") }

        // The running app tests it (it has the Keychain); otherwise here, without a key.
        var req = BridgeRequest(op: .testSignal)
        if isDraft { req.signal = target } else { req.id = target.id }
        req.client = lib.clientName()
        var result: SignalFetchResult
        var viaApp = false
        switch AIBridge.send(req, store: store, timeout: 25) {
        case .success(let r):
            guard r.ok, let t = r.test else { throw ToolError(r.error ?? "DotStudio couldn't test it.") }
            result = t
            viaApp = true
        case .failure(.notRunning):
            if target.auth != nil {
                throw ToolError("“\(target.name)” sends a key, which only the running DotStudio app can use (it's in the Keychain). Ask the user to open DotStudio, then test again.")
            }
            result = target.kind == .file ? SignalFileReader.read(target, store: store)
                : SignalFetcher.fetchSync(target, secret: nil, location: l.signalLocation, forAI: isDraft || target.createdByAI)
        case .failure(.failed(let why)):
            throw ToolError("Couldn't reach DotStudio: \(why)")
        }
        var o: JSONObject = ["ok": result.ok, "viaApp": viaApp]
        if let v = result.value { o["value"] = v.s.map { $0 as Any } ?? v.v.map { $0 as Any } ?? NSNull(); o["display"] = v.display(type: target.valueType, unit: target.unit) }
        if let s = result.status { o["status"] = s }
        if let ms = result.ms { o["ms"] = ms }
        if let b = result.bytes { o["bytes"] = b }
        if let e = result.error { o["error"] = e }
        if result.needsSecret == true { o["needsSecret"] = true }
        let outline = (result.outline ?? []).map { ["pointer": $0.pointer, "value": JSON.from($0.value)] as JSONObject }
        o["outline"] = outline
        var text = "“\(target.name)”: "
        if result.ok, let d = o["display"] as? String { text += "reads \(d)" } else { text += "no value — \(result.error ?? "nothing came back")" }
        var facts: [String] = []
        if let s = result.status { facts.append("HTTP \(s)") }
        if let ms = result.ms { facts.append("\(ms) ms") }
        if let b = result.bytes { facts.append(b >= 1024 ? String(format: "%.1f KB", Double(b) / 1024) : "\(b) bytes") }
        if !facts.isEmpty { text += " (" + facts.joined(separator: ", ") + ")" }
        if result.needsSecret == true { text += ". It needs its key: ask the user to paste it in DotStudio ▸ Settings ▸ Signals ▸ \(target.name)" }
        if !outline.isEmpty {
            text += ".\nOutline (pointer → value):\n" + (result.outline ?? []).map { "  \($0.pointer.isEmpty ? "\"\"" : $0.pointer) → \(JSON.string(JSON.from($0.value)))" }.joined(separator: "\n")
        } else { text += "." }
        return .ok(text, o)
    }

    /// Copy create/update_signal fields onto a signal.
    func apply(_ a: JSONObject, to s: inout Signal) throws {
        if let n = a["name"] as? String { s.name = n.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let k = a["kind"] as? String { s.kind = SignalKind(rawValue: k) ?? .web }
        if let u = a["url"] as? String { s.url = u.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let f = a["file"] as? String { s.file = f }
        if let p = a["pointer"] as? String { s.pointer = p }
        if let t = a["valueType"] as? String { s.valueType = SignalValueType(rawValue: t) ?? .number }
        if let v = a["scale"] as? NSNumber { s.scale = v.doubleValue }
        if let v = a["offset"] as? NSNumber { s.offset = v.doubleValue }
        if let u = a["unit"] as? String { s.unit = u }
        if let r = a["range"] as? [NSNumber] { s.range = r.map(\.doubleValue) }
        if let v = a["default"] as? NSNumber { s.defaultValue = v.doubleValue }
        if let v = a["pollMinutes"] as? NSNumber { s.pollMinutes = v.doubleValue }
        if let au = a["auth"] as? JSONObject, let inStr = au["in"] as? String, let n = au["name"] as? String {
            s.auth = SignalAuth(placement: SignalAuth.Placement(rawValue: inStr) ?? .header, name: n)
        }
        if let e = a["enabled"] as? Bool { s.enabled = e }
    }

    func signalAdvice(_ s: Signal, created: Bool) -> String {
        var t = ""
        if s.auth != nil {
            t += " It sends a key (\(s.auth!.placement.rawValue) \(s.auth!.name)): ask the user to paste it in DotStudio ▸ Settings ▸ Signals ▸ \(s.name) — never in this chat. You can't set or read it."
        }
        t += " DotStudio fetches it only while an enabled When rule (set_rule) or a style's scene input (bind_signal) uses it"
        if s.kind == .web { t += ", every \(Int(s.interval / 60)) min" }
        return t + "."
    }

    func createSignal(_ a: JSONObject) throws -> ToolResult {
        var s = Signal(name: "")
        try apply(a, to: &s)
        s.createdBy = "ai"
        let problems = SignalPolicy.validate(s, forAI: true)
        if !problems.isEmpty { throw ToolError(problems.joined(separator: " ")) }
        let (r, viaApp) = try perform(BridgeRequest(op: .upsertSignal, signal: s))
        var o: JSONObject = ["id": s.id.uuidString, "name": r.name ?? s.name, "liveInApp": viaApp]
        if s.auth != nil {
            o["needsSecret"] = true
            o["askUser"] = "Paste the key in DotStudio ▸ Settings ▸ Signals ▸ \(s.name)."
        }
        return .ok("Created the signal “\(s.name)” (\(s.id.uuidString)). \(whereNote(viaApp))" + signalAdvice(s, created: true), o)
    }

    func updateSignal(_ a: JSONObject) throws -> ToolResult {
        var s = try userSignal(a["signal"] as! String)
        let hadAuth = s.auth
        try apply(a, to: &s)
        if (a["remove_auth"] as? Bool) == true { s.auth = nil }
        let (r, viaApp) = try perform(BridgeRequest(op: .upsertSignal, signal: s))
        var o: JSONObject = ["id": s.id.uuidString, "name": r.name ?? s.name, "liveInApp": viaApp]
        let newKey = s.auth != nil && (hadAuth == nil || hadAuth?.name != s.auth?.name || hadAuth?.placement != s.auth?.placement)
        if newKey { o["needsSecret"] = true }
        return .ok("Updated the signal “\(s.name)”. \(whereNote(viaApp))" + (newKey ? signalAdvice(s, created: false) : ""), o)
    }

    func listRules() throws -> ToolResult {
        let l = try lib.library()
        let now = Date()
        let active = liveState?.activeRuleID(at: now)
        let items: [JSONObject] = (l.rules ?? []).map { r in
            ["id": r.id.uuidString, "name": r.name, "enabled": r.enabled, "when": JSON.from(r.when),
             "play": r.play.map { id in ["id": id.uuidString, "name": l.presets.first { $0.id == id }?.name ?? "—"] as JSONObject },
             "holdMinutes": r.holdMinutes ?? PlayRule.defaultHold, "summary": RuleText.summary(r, in: l),
             "activeNow": r.id == active && r.enabled, "createdByAI": r.createdBy == "ai"]
        }
        var text = items.isEmpty ? "No When rules yet (set_rule adds one)." : "\(items.count) When rule(s), first match wins:\n"
        text += items.map { o in
            "- \(o["name"]!)\((o["enabled"] as? Bool) == false ? " (off)" : "")\((o["activeNow"] as? Bool) == true ? " — PLAYING NOW" : ""): \(o["summary"]!) [\(o["id"]!)]"
        }.joined(separator: "\n")
        return .ok(text, ["rules": items, "activeNow": active.map { $0.uuidString as Any } ?? NSNull()])
    }

    /// bind_signal: connect (or disconnect) one Custom Scene input of a style.
    func bindSignal(_ a: JSONObject) throws -> ToolResult {
        let l = try lib.library()
        var p = try resolve(a)
        let key = a["input"] as! String
        let ref = a["signal"] as? String                     // nil (JSON null) = disconnect
        let customs = p.effects.indices.filter { p.effects[$0].kind == .custom }
        let index: Int
        if let n = (a["effect_index"] as? NSNumber)?.intValue {
            guard p.effects.indices.contains(n) else {
                throw ToolError("effect_index \(n): “\(p.name)” has \(p.effects.count) effect(s) (0…\(max(p.effects.count - 1, 0))).")
            }
            guard p.effects[n].kind == .custom else {
                throw ToolError("effect \(n) of “\(p.name)” is \(p.effects[n].kind.displayName), not a Custom Scene: only Custom Scenes have inputs.")
            }
            index = n
        } else {
            guard !customs.isEmpty else { throw ToolError("“\(p.name)” has no Custom Scene, so it has no inputs to connect (only Custom Scenes declare inputs).") }
            index = customs.first { i in (p.effects[i].custom.flatMap { scenes.inputs(scene: $0.id) } ?? []).contains { $0.key == key } } ?? customs[0]
        }
        guard let scene = p.effects[index].custom?.id else { throw ToolError("effect \(index) of “\(p.name)” has no scene package.") }
        guard let declared = scenes.inputs(scene: scene) else {
            throw ToolError("The scene package \(scene) isn't installed (list_custom_scenes).")
        }
        let before = p.effects[index].inputs?[key]?.signal
        try StyleBuilder.bind(&p.effects[index], input: key, signal: ref, declared: declared, scene: scene,
                              where_: "input \(key)", ctx: builderContext)
        let after = p.effects[index].inputs?[key]?.signal
        let spec = declared.first { $0.key == key }!
        let sigName = after.flatMap { l.signalInfo($0)?.name } ?? ref
        var o: JSONObject = ["style": p.name, "styleId": p.id.uuidString, "effectIndex": index, "input": key,
                             "signal": after.map { $0 as Any } ?? NSNull(), "default": spec.def]
        if before == after {
            o["changed"] = false
            return .ok(after == nil ? "“\(p.name)” \(key) wasn't connected; nothing changed." : "“\(p.name)” \(key) already follows \(sigName ?? after!).", o)
        }
        let (_, viaApp) = try perform(BridgeRequest(op: .upsertStyle, preset: p))
        o["changed"] = true
        o["liveInApp"] = viaApp
        var text: String
        if let after {
            text = "Connected “\(p.name)” \(spec.label) (\(key)) ← \(sigName ?? after). The scene follows it, eased over ~20 s; while it's missing or stale it reads \(SignalValue.format(spec.def))\(RuleText.unitSuffix(spec.unit))."
            let now = Date()
            if let r = SignalLink.reading(after, state: liveState, wall: now) {
                let v = spec.clamp(r.value)
                o["valueNow"] = v
                text += " Now: \(SignalValue.format(v))\(RuleText.unitSuffix(spec.unit))\(r.freshness < 0.5 ? " (stale)" : "")."
            } else {
                text += " No value yet: DotStudio fetches it while it runs."
            }
        } else {
            text = "Disconnected “\(p.name)” \(spec.label) (\(key)): it reads its default, \(SignalValue.format(spec.def))\(RuleText.unitSuffix(spec.unit))."
        }
        return .ok(text + " " + whereNote(viaApp), o)
    }

    func setRule(_ a: JSONObject) throws -> ToolResult {
        let l = try lib.library()
        var r: PlayRule
        let existing = try (a["rule"] as? String).map(resolveRule)
        if let e = existing { r = e } else {
            guard a["when"] != nil, a["play"] != nil else { throw ToolError("A new rule needs `when` and `play` (or pass `rule` to change one).") }
            r = PlayRule(name: "", when: RuleCondition(), play: [])
        }
        if let w = a["when"] as? JSONObject {
            func clauses(_ key: String) throws -> [RuleClause]? {
                guard let arr = w[key] as? [Any] else { return nil }
                return try arr.enumerated().map { i, any in
                    guard let c = any as? JSONObject, let sig = c["signal"] as? String, let op = (c["op"] as? String).flatMap(RuleOp.init(rawValue:)) else {
                        throw ToolError("when.\(key)[\(i)] needs signal and op.")
                    }
                    let value = try c["value"].map { try JSON.decode(JSONValue.self, from: $0) }
                    let values = try (c["values"] as? [Any]).map { try $0.map { try JSON.decode(JSONValue.self, from: $0) } }
                    return RuleClause(signal: try signalKey(sig, l), op: op, value: value, values: values)
                }
            }
            r.when = RuleCondition(all: try clauses("all"), any: try clauses("any"), timeOfDay: w["timeOfDay"] as? String)
        }
        if let play = a["play"] as? [String] { r.play = try play.map { try lib.preset($0).id } }
        if let n = a["name"] as? String { r.name = n }
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty {
            r.name = String(r.when.clauses.first.map { RuleText.clause($0, in: l) }?.prefix(60) ?? "Rule")
        }
        if let e = a["enabled"] as? Bool { r.enabled = e }
        if let h = a["hold_minutes"] as? NSNumber { r.holdMinutes = h.doubleValue }
        let problems = RuleEngine.validate(r, in: l)
        if !problems.isEmpty { throw ToolError(problems.joined(separator: " ")) }
        let (resp, viaApp) = try perform(BridgeRequest(op: .upsertRule, rule: r))
        let text = (resp.message ?? "Saved.") + " " + whereNote(viaApp)
            + (viaApp ? " The app decides when it plays (a notice shows Undo)." : " It starts deciding when DotStudio next runs.")
        return .ok(text, ["id": r.id.uuidString, "name": r.name, "summary": RuleText.summary(r, in: l), "liveInApp": viaApp])
    }
}
