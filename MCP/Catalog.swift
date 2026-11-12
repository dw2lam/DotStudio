//  Catalog.swift — the scenes and looks as the AI sees them (from EffectKind / SceneCatalog, so
//  it never drifts), and building a style from tool arguments with strict checks.

import Foundation

enum Catalog {
    static let fpsChoices = [15, 24, 30, 60, 120]

    /// Every effect the AI may use: not retired (retired ones still render in old libraries).
    static var available: [EffectKind] { EffectKind.allCases.filter { !$0.isRetired } }

    static func kind(_ key: String) -> EffectKind? {
        if let k = EffectKind(rawValue: key) { return k }
        return EffectKind.allCases.first { $0.displayName.compare(key, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// GPU ms per frame at 5120×2880 (best of 20 frames, MetalRenderer.renderFrame — source,
    /// every effect, compute passes) for each built-in style, measured with
    /// `tools/gallery/render.sh --pack --framebench --size 5120x2880` on an Apple-silicon Pro GPU
    /// (Nov 2026). Looks include the photo slideshow under them. A reference, not a promise:
    /// benchmark_style measures on this Mac.
    static let reference5K: [String: Double] = [
        "Liquid Chrome": 5.99, "Aurora": 8.01, "Universe": 7.19, "Topography": 7.75, "Zen Garden": 4.50, "Black Hole": 10.11,
        "Afterglow": 2.79, "StandBy": 4.21, "Minimal": 2.57, "Chronometer": 3.10, "Flip Clock": 3.79, "Word Clock": 3.15,
        "Window Light": 4.50, "Lava Lamp": 7.30, "Currents": 5.94, "Golden Hour": 5.09, "Shallows": 5.03, "Meadow": 6.47,
        "Tall Grass": 6.97, "Night Sky": 6.73, "First Snow": 7.50, "Blue Bloom": 2.60, "Baby's Breath": 3.40,
        "Neon Horizon": 7.24, "Light Ribbons": 7.62, "Bounce": 1.31, "Film": 3.87, "Riso Duotone": 5.23, "Cyanotype": 6.45,
        "Floyd–Steinberg": 6.06, "Atkinson": 4.45, "ASCII": 5.22, "Amber CRT": 4.50, "Soft Focus": 7.41, "Silk": 2.98,
        "Hyperspace": 6.52, "Glass Clock": 5.05, "Plaster Clock": 5.41, "Ivory Flip": 3.42, "Printed Words": 3.23,
        "Solar Wind": 6.27, "Ultraviolet Lamp": 6.44, "Afterlight": 5.11, "Rainy Window": 7.21, "Night Drive": 5.95,
        "Low Tide": 5.52, "Black Sand": 4.20, "Pleats": 5.38, "Graphite Satin": 5.56, "Paper Lantern": 4.45, "Dichroic": 5.67,
        "Black Box": 5.40, "Soap Film": 5.72, "Oil Slick": 4.89, "Rolling Hills": 5.26, "Hillside": 3.19, "White Anemone": 1.65,
        "Cobalt Print": 4.81, "Riso Halftone": 3.47, "Fluted Glass": 5.94, "Liquid Glass": 8.72, "Matrix Rain": 1.94,
        "Halftone": 1.51, "Riemersma": 4.01, "Blue Noise": 2.68, "Paper Contours": 7.77, "Holographic": 4.98,
        "Quicksilver": 4.63, "Brushed Gold": 4.96, "Midnight Satin": 2.78, "Lagoon": 2.79, "Orchid": 2.64,
        "Polar Night": 7.74, "Glass Tiles": 7.06, "Starfield": 5.03, "VHS": 3.88, "Data Glitch": 1.73, "Game Boy": 2.26,
        "Super NES": 4.94, "LED Wall": 2.40, "Neon Wire": 1.64, "Kaleidoscope": 1.02, "Thermal Cam": 1.35,
    ]

    private static var builtIns: [Preset] { DefaultPresets.scenes() + DefaultPresets.looks() + DefaultPresets.coolPack() }

    /// Reference ms for an effect: the cheapest built-in style led by it (nil = none measured).
    static func referenceMs(_ kind: EffectKind) -> Double? {
        builtIns.filter { $0.leadKindAI == kind }.compactMap { reference5K[$0.name] }.min()
    }

    /// light < 3 ms, medium < 6 ms, heavy ≥ 6 ms at 5K on the reference GPU.
    static func perfClass(ms: Double?) -> String {
        guard let ms else { return "unmeasured" }
        return ms < 3 ? "light" : ms < 6 ? "medium" : "heavy"
    }

    /// What a scene follows on its own: the clock, the sun (and so the location), live weather,
    /// music. Derived from its params, so a new scene is described correctly without edits here.
    static func reactsTo(_ kind: EffectKind) -> [String] {
        let keys = Set(kind.params.map(\.key))
        let labels = kind.params.map { $0.label.lowercased() }
        var out: [String] = []
        let clockKinds: Set<EffectKind> = [.typeClock, .flipClock, .wordClock, .windowLight, .dialClock,
                                           .standbyClock, .minimalClock, .watchClock]
        if clockKinds.contains(kind) || keys.contains("h24") { out.append("clock") }
        if kind == .universe || labels.contains("follow the sun") { out.append("sun") }
        if kind == .universe || kind == .nightSky || labels.contains("follow the sun") { out.append("location") }
        if keys.contains("weather") { out.append("weather") }
        if kind == .nowPlaying { out.append("music") }
        if !kind.isScene { out.append("source") }
        return out
    }

    static func paramJSON(_ p: ParamSpec) -> JSONObject {
        var o: JSONObject = ["key": p.key, "label": p.label, "default": p.def]
        if let opts = p.options {
            o["kind"] = "menu"
            o["options"] = opts
            o["note"] = "value = option index (0…\(opts.count - 1)) or the option's name"
        } else if p.isToggle {
            o["kind"] = "toggle"
            o["note"] = "true/false or 1/0"
        } else {
            o["kind"] = "slider"
            o["min"] = p.min
            o["max"] = p.max
            if p.step > 0 { o["step"] = p.step }
        }
        return o
    }

    static func colorJSON(_ c: RGBA?) -> Any {
        guard let c else { return NSNull() }
        return ["r": round3(c.r), "g": round3(c.g), "b": round3(c.b), "a": round3(c.a)]
    }

    static func round3(_ d: Double) -> Double { (d * 1000).rounded() / 1000 }

    static func summary(_ kind: EffectKind) -> JSONObject {
        let ms = referenceMs(kind)
        return ["kind": kind.rawValue, "name": kind.displayName, "type": kind.isScene ? "scene" : "look",
                "category": kind.category.rawValue, "blurb": kind.blurb, "reactsTo": reactsTo(kind),
                "perfClass": perfClass(ms: ms)]
    }

    static func describe(_ kind: EffectKind) -> JSONObject {
        var o = summary(kind)
        o["params"] = kind.params.map(paramJSON)
        var colors: JSONObject = [:]
        if kind.usesColors {
            colors["colorA"] = ["label": kind.colorALabel, "default": colorJSON(kind.defaultColorA)]
            colors["colorB"] = ["label": kind.colorBLabel, "default": colorJSON(kind.defaultColorB)]
        }
        o["colors"] = colors
        if let ms = referenceMs(kind) { o["referenceGpuMsAt5K"] = ms }
        o["retired"] = kind.isRetired
        let examples = builtIns.filter { $0.leadKindAI == kind }.map(\.name)
        if !examples.isEmpty { o["builtInStyles"] = examples }
        o["usage"] = kind.isScene
            ? "A scene draws its own image: put it FIRST in a style's effects; looks after it restyle it."
            : "A look restyles what's under it (the shared photo slideshow/image/video/gradient, or a scene placed before it)."
        if kind == .bounce { o["extra"] = "Bounce takes an optional logo_text: the word that bounces (else the DotStudio mark)." }
        return o
    }
}

extension Preset {
    /// The first enabled effect (Destinations' leadKind is app-only).
    var leadKindAI: EffectKind? { (effects.first(where: \.enabled) ?? effects.first)?.kind }
}

/// A style from tool arguments. Strict: unknown kinds, unknown params and out-of-range values
/// are errors that say what's allowed (the model corrects itself), never silently clamped.
enum StyleBuilder {
    static let effectSchema: JSONObject = S.obj([
        "kind": S.str("Effect kind (list_scenes `kind`, e.g. \"oceanHorizon\", \"liquidChrome\", \"halftone\"), or \"custom\" with `scene`."),
        "scene": S.str("For kind \"custom\": the installed custom scene id (list_custom_scenes)."),
        "params": ["type": "object", "description": "Param values by key (describe_scene). Sliders: a number in range. Toggles: true/false. Menus: option index or option name. Omitted params keep their defaults.",
                   "additionalProperties": ["type": ["number", "boolean", "string"]]],
        "colorA": S.color, "colorB": S.color,
        "enabled": S.bool("Default true."),
        "logo_text": S.str("Bounce only: the word that bounces (max 24 characters).", max: 24),
    ], required: ["kind"])

    struct Context {
        var customScenes: [JSONObject]        // installed manifests (custom kind)
        var customAvailable: Bool
    }

    static func effect(_ e: JSONObject, index: Int, ctx: Context, existing: EffectInstance? = nil) throws -> JSONObject {
        let where_ = "effects[\(index)]"
        guard let k = e["kind"] as? String else { throw ToolError("\(where_): needs a kind") }
        if k == "custom" { return try customEffect(e, where_: where_, ctx: ctx) }
        guard let kind = Catalog.kind(k) else {
            throw ToolError("\(where_): unknown kind \"\(k)\". Call list_scenes for the kinds (scenes and looks).")
        }
        if kind.isRetired, existing?.kind != kind {
            throw ToolError("\(where_): \(kind.displayName) is retired (it no longer meets DotStudio's bar; see read_guide style/dotstudio). Pick another kind.")
        }
        var inst = existing ?? EffectInstance(kind)
        if existing?.kind != kind { inst = EffectInstance(kind) }
        if let params = e["params"] as? JSONObject {
            for (key, v) in params {
                guard let spec = kind.params.first(where: { $0.key == key }) else {
                    throw ToolError("\(where_): \(kind.displayName) has no param \"\(key)\". Its params: \(kind.params.map(\.key).joined(separator: ", ")).")
                }
                inst.params[key] = try value(v, spec, where_ + ".params." + key)
            }
        }
        if let c = e["colorA"] as? JSONObject { inst.colorA = rgba(c) }
        if let c = e["colorB"] as? JSONObject { inst.colorB = rgba(c) }
        if (e["colorA"] != nil || e["colorB"] != nil), !kind.usesColors {
            throw ToolError("\(where_): \(kind.displayName) has no colour wells; leave colorA/colorB out.")
        }
        if let en = e["enabled"] as? Bool { inst.enabled = en }
        if let t = e["logo_text"] as? String {
            guard kind == .bounce else { throw ToolError("\(where_): logo_text is for bounce only.") }
            inst.logoKind = .text
            inst.logoText = t
        }
        return JSON.from(inst) as? JSONObject ?? [:]
    }

    private static func customEffect(_ e: JSONObject, where_: String, ctx: Context) throws -> JSONObject {
        guard ctx.customAvailable else {
            throw ToolError("\(where_): custom scenes aren't available in this build of DotStudio yet. Use the built-in scenes (list_scenes).")
        }
        guard let id = e["scene"] as? String else { throw ToolError("\(where_): kind \"custom\" needs `scene` (an id from list_custom_scenes).") }
        guard let m = ctx.customScenes.first(where: { $0["id"] as? String == id }) else {
            throw ToolError("\(where_): no installed custom scene \"\(id)\". Call list_custom_scenes, or create_custom_scene first.")
        }
        let specs = m["params"] as? [JSONObject] ?? []
        var params: [String: Double] = [:]
        for s in specs { if let k = s["key"] as? String { params[k] = (s["default"] as? NSNumber)?.doubleValue ?? 0 } }
        for (key, v) in e["params"] as? JSONObject ?? [:] {
            guard let s = specs.first(where: { $0["key"] as? String == key }) else {
                throw ToolError("\(where_): scene \(id) has no param \"\(key)\". Its params: \(specs.compactMap { $0["key"] as? String }.joined(separator: ", ")).")
            }
            let kindStr = s["kind"] as? String ?? "slider"
            let spec: ParamSpec
            if kindStr == "menu", let opts = s["options"] as? [String] {
                spec = ParamSpec(menu: key, s["label"] as? String ?? key, opts, def: 0)
            } else {
                spec = ParamSpec(key, s["label"] as? String ?? key, (s["min"] as? NSNumber)?.doubleValue ?? 0,
                                 (s["max"] as? NSNumber)?.doubleValue ?? 1, def: 0, toggle: kindStr == "toggle")
            }
            params[key] = try value(v, spec, where_ + ".params." + key)
        }
        var o: JSONObject = ["id": UUID().uuidString, "kind": "custom", "enabled": (e["enabled"] as? Bool) ?? true,
                             "params": params, "custom": ["id": id]]
        let colors = m["colors"] as? JSONObject ?? [:]
        func color(_ slot: String, _ given: Any?) -> Any? {
            if let g = given as? JSONObject { return JSON.from(rgba(g)) }
            if let d = (colors[slot] as? JSONObject)?["default"] as? [NSNumber], d.count >= 3 {
                return JSON.from(RGBA(d[0].doubleValue, d[1].doubleValue, d[2].doubleValue, d.count > 3 ? d[3].doubleValue : 1))
            }
            return nil
        }
        if let a = color("a", e["colorA"]) { o["colorA"] = a }
        if let b = color("b", e["colorB"]) { o["colorB"] = b }
        return o
    }

    static func value(_ v: Any, _ spec: ParamSpec, _ path: String) throws -> Double {
        if let opts = spec.options {
            if let s = v as? String {
                if let i = opts.firstIndex(where: { $0.compare(s, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { return Double(i) }
                throw ToolError("\(path): \"\(s)\" isn't an option. Options: \(opts.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: ", ")).")
            }
            guard JSON.isNumber(v), let n = (v as? NSNumber)?.doubleValue, n == n.rounded(), n >= 0, Int(n) < opts.count else {
                throw ToolError("\(path): a menu takes an option index 0…\(opts.count - 1) or an option name (\(opts.joined(separator: ", "))).")
            }
            return n
        }
        if spec.isToggle {
            if JSON.isBool(v) { return (v as? Bool) == true ? 1 : 0 }
            if JSON.isNumber(v), let n = (v as? NSNumber)?.doubleValue, n == 0 || n == 1 { return n }
            throw ToolError("\(path): a toggle takes true/false.")
        }
        guard JSON.isNumber(v), let n = (v as? NSNumber)?.doubleValue, n.isFinite else {
            throw ToolError("\(path): a slider takes a number \(Schema.fmt(spec.min))…\(Schema.fmt(spec.max)).")
        }
        guard n >= spec.min - 1e-9, n <= spec.max + 1e-9 else {
            throw ToolError("\(path): \(Schema.fmt(n)) is outside \(spec.label)'s range \(Schema.fmt(spec.min))…\(Schema.fmt(spec.max)) (default \(Schema.fmt(spec.def))).")
        }
        return n
    }

    static func rgba(_ c: JSONObject) -> RGBA {
        func d(_ k: String, _ def: Double) -> Double { min(max((c[k] as? NSNumber)?.doubleValue ?? def, 0), 1) }
        return RGBA(d("r", 0), d("g", 0), d("b", 0), d("a", 1))
    }

    /// The style a create/update call describes, decoded through Preset's own decoder (so a
    /// kind this build doesn't know — "custom" before the engine lands — is kept verbatim).
    static func preset(id: UUID, name: String, fps: Int, effects: [JSONObject]) throws -> Preset {
        let o: JSONObject = ["id": id.uuidString, "name": name, "fps": fps, "effects": effects]
        do { return try JSON.decode(Preset.self, from: o) } catch {
            throw ToolError("Couldn't build the style: \(error)")
        }
    }

    /// Plain-language warnings about a style against the DotStudio guides (not errors).
    static func advice(_ p: Preset) -> [String] {
        var w: [String] = []
        let kinds = p.effects.filter(\.enabled).map(\.kind)
        if let first = kinds.first, !first.isScene {
            w.append("No scene leads this style, so it restyles the shared source (the photo slideshow by default) — that's a Look. Put a scene first for a self-contained screensaver.")
        }
        if kinds.dropFirst().contains(where: \.isScene) {
            w.append("Only the first scene draws; a scene later in the stack replaces everything before it.")
        }
        if p.fps > 30 { w.append("\(p.fps) fps costs battery; DotStudio styles read smooth at 24–30 fps (read_guide power).") }
        if kinds.count > 3 { w.append("\(kinds.count) effects stacked: each is a full-screen pass. Keep it to 1–3.") }
        let cost = kinds.compactMap { Catalog.referenceMs($0) }.max() ?? 0
        if cost >= 8 { w.append(String(format: "Its lead effect is heavy (~%.1f ms/frame at 5K on a Pro GPU); run benchmark_style.", cost)) }
        return w
    }
}
