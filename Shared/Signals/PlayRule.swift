//  PlayRule.swift — When rules: "When ⟨condition⟩, play ⟨style⟩" (docs/signals-design.md §3, §5).
//
//  Rules are an OVERLAY on the screensaver's lineup, never part of it: display pin > active When
//  rule > night schedule > rotation > active style (Playback). The app is the only evaluator
//  (RuleEngine.decide, with hysteresis and a hold) and writes its decision as a lease in
//  signal-values.json, so every host plays the same thing and a quit app falls back to the lineup.

import Foundation

enum RuleOp: String, Codable, CaseIterable {
    case gt, gte, lt, lte, eq, neq, `in`, between

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let op = RuleOp(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown op \(raw)"))
        }
        self = op
    }

    var isThreshold: Bool { [.gt, .gte, .lt, .lte, .between].contains(self) }
}

/// One test on one signal: {signal, op, value | values}.
struct RuleClause: Codable, Equatable, Hashable {
    /// A built-in id ("weather.condition") or a user signal's UUID string.
    var signal: String
    var op: RuleOp
    /// gt…neq: one value (number, bool or word).
    var value: JSONValue?
    /// in: the words or numbers; between: [lo, hi].
    var values: [JSONValue]?

    init(signal: String, op: RuleOp, value: JSONValue? = nil, values: [JSONValue]? = nil) {
        self.signal = signal; self.op = op; self.value = value; self.values = values
    }
}

/// {all|any: [clauses]}, optionally only by day or only at night (Playback.isNight).
struct RuleCondition: Codable, Equatable, Hashable {
    var all: [RuleClause]?
    var any: [RuleClause]?
    /// "day" | "night"; nil = any time.
    var timeOfDay: String?

    init(all: [RuleClause]? = nil, any: [RuleClause]? = nil, timeOfDay: String? = nil) {
        self.all = all; self.any = any; self.timeOfDay = timeOfDay
    }

    var clauses: [RuleClause] { (all ?? []) + (any ?? []) }
}

struct PlayRule: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var enabled: Bool = true
    var when: RuleCondition
    /// One style, or several that rotate (with the playlist's interval and shuffle).
    var play: [UUID]
    /// Once on, the rule stays at least this long (default 10).
    var holdMinutes: Double?
    /// "ai" for rules an assistant made.
    var createdBy: String?

    static let defaultHold = 10.0
    static let maxCount = 24
    static let maxStyles = 8

    init(id: UUID = UUID(), name: String, enabled: Bool = true, when: RuleCondition, play: [UUID], holdMinutes: Double? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.when = when; self.play = play; self.holdMinutes = holdMinutes
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, when, play, holdMinutes, createdBy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Rule"
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        when = try c.decode(RuleCondition.self, forKey: .when)
        play = (try? c.decode([UUID].self, forKey: .play)) ?? []
        holdMinutes = try? c.decodeIfPresent(Double.self, forKey: .holdMinutes)
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
    }

    var hold: TimeInterval { max(holdMinutes ?? Self.defaultHold, 0) * 60 }
}

// MARK: - Evaluation

enum RuleEngine {
    /// Numeric thresholds let go only after the value crosses back by this share of the range.
    static let hysteresisShare = 0.05

    /// One clause against a value. Missing or stale → false. `wasActive`: the clause's rule plays
    /// now, so a threshold holds until the value is `hysteresisShare` of `range` back across it.
    static func matches(_ c: RuleClause, value: SignalValue?, range: ClosedRange<Double>?, wasActive: Bool, now: Date) -> Bool {
        guard let value, value.isFresh(at: now) else { return false }
        func num(_ j: JSONValue?) -> Double? {
            switch j {
            case .number(let d): return d
            case .integer(let i): return Double(i)
            case .bool(let b): return b ? 1 : 0
            case .string(let s): return Double(s)
            default: return nil
            }
        }
        func word(_ j: JSONValue?) -> String? {
            switch j {
            case .string(let s): return s
            case .number(let d): return SignalValue.format(d)
            case .integer(let i): return String(i)
            case .bool(let b): return b ? "true" : "false"
            default: return nil
            }
        }
        func equal(_ j: JSONValue?) -> Bool {
            if let s = value.s, let w = word(j) { return s.caseInsensitiveCompare(w) == .orderedSame }
            if let v = value.v, let n = num(j) { return abs(v - n) < 1e-9 }
            return false
        }
        // How far a held threshold may be crossed back before it lets go.
        let slack: Double = {
            guard wasActive, c.op.isThreshold else { return 0 }
            if let r = range { return (r.upperBound - r.lowerBound) * hysteresisShare }
            let t = num(c.value) ?? c.values?.compactMap(num).map(abs).max() ?? 1
            return max(abs(t), 1) * hysteresisShare
        }()
        switch c.op {
        case .gt, .gte, .lt, .lte:
            guard let v = value.v, let t = num(c.value) else { return false }
            switch c.op {
            case .gt: return v > t - slack
            case .gte: return v >= t - slack
            case .lt: return v < t + slack
            default: return v <= t + slack
            }
        case .between:
            guard let v = value.v, let vs = c.values, vs.count == 2, let a = num(vs[0]), let b = num(vs[1]) else { return false }
            return v >= min(a, b) - slack && v <= max(a, b) + slack
        case .eq: return equal(c.value)
        case .neq: return value.hasValue && !equal(c.value)
        case .in: return (c.values ?? []).contains { equal($0) }
        }
    }

    /// A whole rule: every `all` clause and (if any) one `any` clause, at the right time of day.
    static func matches(_ r: PlayRule, values: (String) -> SignalValue?, range: (String) -> ClosedRange<Double>?,
                        isNight: Bool, wasActive: Bool, now: Date) -> Bool {
        if let t = r.when.timeOfDay {
            if t == "night", !isNight { return false }
            if t == "day", isNight { return false }
        }
        let all = r.when.all ?? [], any = r.when.any ?? []
        guard !all.isEmpty || !any.isEmpty else { return false }
        func test(_ c: RuleClause) -> Bool {
            matches(c, value: values(c.signal), range: range(c.signal), wasActive: wasActive, now: now)
        }
        return all.allSatisfy(test) && (any.isEmpty || any.contains(where: test))
    }

    /// The decision: the first enabled rule (list order) that matches and has a style to play —
    /// except that a playing rule holds for its `holdMinutes`, and its thresholds hold with
    /// hysteresis. Returns a fresh lease (id nil = no rule).
    static func decide(rules: [PlayRule], styles: Set<UUID>, values: (String) -> SignalValue?,
                       range: (String) -> ClosedRange<Double>?, isNight: Bool, previous: RuleLease?, now: Date) -> RuleLease {
        let t = now.timeIntervalSince1970
        let usable = rules.filter { $0.enabled && $0.play.contains(where: styles.contains) }
        var winner: UUID?
        if let prevID = previous?.id, let prev = usable.first(where: { $0.id == prevID }),
           let since = previous?.since, t - since < prev.hold, t >= since {
            winner = prevID                                    // holding
        } else {
            winner = usable.first { r in
                matches(r, values: values, range: range, isNight: isNight, wasActive: r.id == previous?.id, now: now)
            }?.id
        }
        let since = (winner == previous?.id ? previous?.since : nil) ?? t
        return RuleLease(id: winner, since: since, validUntil: t + SignalState.leaseSeconds)
    }

    /// Problems with a rule against a library (empty = fine). Shared by the app's editor and the
    /// MCP tools (set_rule), so both refuse the same things.
    static func validate(_ r: PlayRule, in lib: Library) -> [String] {
        var out: [String] = []
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("The rule needs a name.") }
        if r.name.count > 60 { out.append("The rule's name is longer than 60 characters.") }
        let clauses = r.when.clauses
        if clauses.isEmpty { out.append("`when` needs at least one test (all or any).") }
        if clauses.count > 8 { out.append("At most 8 tests per rule.") }
        if let t = r.when.timeOfDay, t != "day", t != "night" { out.append("timeOfDay is \"day\" or \"night\".") }
        for c in clauses {
            guard let info = lib.signalInfo(c.signal) else {
                out.append("No signal \"\(c.signal)\". Call list_signals (built-in ids like weather.condition, or a signal's id).")
                continue
            }
            switch (c.op, info.type) {
            case (.gt, .string), (.gte, .string), (.lt, .string), (.lte, .string), (.between, .string):
                out.append("“\(info.name)” is a word: use eq, neq or in, not \(c.op.rawValue).")
            case (.gt, .bool), (.gte, .bool), (.lt, .bool), (.lte, .bool), (.between, .bool), (.in, .bool):
                out.append("“\(info.name)” is yes/no: use eq or neq with true or false.")
            default: break
            }
            switch c.op {
            case .in:
                if (c.values ?? []).isEmpty { out.append("`in` needs `values`.") }
            case .between:
                if c.values?.count != 2 { out.append("`between` needs `values`: [low, high].") }
            default:
                if c.value == nil { out.append("`\(c.op.rawValue)` needs a `value`.") }
            }
            if info.type == .string, let opts = info.options {
                let given: [String] = ([c.value].compactMap { $0 } + (c.values ?? [])).compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                for g in given where !opts.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                    out.append("“\(info.name)” is never \"\(g)\" — it is one of: \(opts.joined(separator: ", ")).")
                }
            }
        }
        if r.play.isEmpty { out.append("`play` needs at least one style.") }
        if r.play.count > PlayRule.maxStyles { out.append("A rule plays at most \(PlayRule.maxStyles) styles.") }
        let ids = Set(lib.presets.map(\.id))
        for p in r.play where !ids.contains(p) { out.append("No style with id \(p.uuidString) (list_styles).") }
        if let h = r.holdMinutes, !(0...720).contains(h) { out.append("holdMinutes is 0…720.") }
        return out
    }
}

// MARK: - Words

enum RuleText {
    /// "Weather is Snow", "Battery is below 20%", "Air quality is above 150 AQI · at night".
    static func condition(_ c: RuleCondition, in lib: Library) -> String {
        let parts = (c.all ?? []).map { clause($0, in: lib) }
        var s = parts.joined(separator: " and ")
        if let any = c.any, !any.isEmpty {
            let a = any.map { clause($0, in: lib) }.joined(separator: " or ")
            s = s.isEmpty ? a : s + " and (" + a + ")"
        }
        if c.timeOfDay == "night" { s += " · at night" }
        if c.timeOfDay == "day" { s += " · by day" }
        return s.isEmpty ? "Never" : s
    }

    /// "when Weather is Snow, play “Snowfall”".
    static func summary(_ r: PlayRule, in lib: Library) -> String {
        let styles = r.play.compactMap { id in lib.presets.first { $0.id == id }?.name }
        let play = styles.isEmpty ? "nothing" : styles.count == 1 ? "“\(styles[0])”"
            : styles.map { "“\($0)”" }.joined(separator: ", ") + " in turn"
        return "when \(condition(r.when, in: lib)), play \(play)"
    }

    /// The chip / badge words: the rule's name when it has one, else its first test.
    static func short(_ r: PlayRule, in lib: Library) -> String {
        let n = r.name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return r.when.clauses.first.map { clause($0, in: lib) } ?? "Rule"
    }

    static func clause(_ c: RuleClause, in lib: Library) -> String {
        let info = lib.signalInfo(c.signal)
        let name = info?.name ?? "A missing signal"
        func v(_ j: JSONValue?) -> String {
            switch j {
            case .string(let s): return info?.type == .string ? word(s) : s
            case .number(let d): return SignalValue.format(d) + unitSuffix(info?.unit)
            case .integer(let i): return String(i) + unitSuffix(info?.unit)
            case .bool(let b): return b ? "yes" : "no"
            default: return "—"
            }
        }
        switch c.op {
        case .gt: return "\(name) is above \(v(c.value))"
        case .gte: return "\(name) is at least \(v(c.value))"
        case .lt: return "\(name) is below \(v(c.value))"
        case .lte: return "\(name) is at most \(v(c.value))"
        case .eq:
            if info?.type == .bool, case .bool(let b) = c.value { return b ? name : "Not \(name.lowercased())" }
            return "\(name) is \(v(c.value))"
        case .neq: return "\(name) isn't \(v(c.value))"
        case .in: return "\(name) is " + (c.values ?? []).map(v).joined(separator: " or ")
        case .between:
            let vs = c.values ?? []
            return vs.count == 2 ? "\(name) is \(v(vs[0]))–\(v(vs[1]))" : "\(name) is in a range"
        }
    }

    /// A weather condition's display name ("partlyCloudy" → "Partly cloudy"), else the word.
    static func word(_ s: String) -> String {
        WeatherCondition(rawValue: s)?.displayName ?? s
    }

    static func unitSuffix(_ u: String?) -> String {
        guard let u, !u.isEmpty else { return "" }
        return u == "%" || u == "°" ? u : " " + u
    }

    /// The SF Symbol for a rule's first test (weather condition → its own symbol).
    static func symbol(_ r: PlayRule, in lib: Library) -> String {
        guard let c = r.when.clauses.first else { return "bolt" }
        if c.signal == "weather.condition", case .string(let s)? = c.value ?? c.values?.first,
           let w = WeatherCondition(rawValue: s) { return w.symbol }
        if let b = BuiltInSignals.find(c.signal) { return b.symbol }
        return (lib.signals ?? []).first { $0.key == c.signal }?.kind == .file ? "doc.text" : "antenna.radiowaves.left.and.right"
    }
}

// MARK: - Library

extension Library {
    /// The active When rule's styles at `now` (the lease, the rule still enabled, its styles still
    /// here), else nil.
    func activeRule(live: SignalState?, now: Date) -> (rule: PlayRule, styles: [Preset])? {
        guard let id = live?.activeRuleID(at: now), let r = (rules ?? []).first(where: { $0.id == id }), r.enabled else { return nil }
        let styles = r.play.compactMap { pid in presets.first { $0.id == pid } }
        return styles.isEmpty ? nil : (r, styles)
    }

    /// Signals any enabled rule tests, or any style's Custom Scene input is bound to (by
    /// values-map key): what the app samples and fetches.
    var referencedSignalKeys: Set<String> {
        ruleSignalKeys.union(boundSignalKeys)
    }

    /// Signals any enabled rule tests.
    var ruleSignalKeys: Set<String> {
        Set((rules ?? []).filter(\.enabled).flatMap { $0.when.clauses.map(\.signal) })
    }

    /// The rules that test a signal (any state).
    func rules(using key: String) -> [PlayRule] {
        (rules ?? []).filter { $0.when.clauses.contains { $0.signal == key } }
    }

    /// Drop deleted styles from rules, and rules left with none (a style this build can't draw
    /// still counts). Returns whether anything changed.
    @discardableResult
    mutating func pruneRules() -> Bool {
        guard let list = rules else { return false }
        let ids = Set(presets.map(\.id) + unknownPresets.map(\.preset.id))
        var next: [PlayRule] = []
        for var r in list {
            r.play = r.play.filter(ids.contains)
            if !r.play.isEmpty { next.append(r) }
        }
        let out = next.isEmpty ? nil : next
        guard out != rules else { return false }
        rules = out
        return true
    }
}
