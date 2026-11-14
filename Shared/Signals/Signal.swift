//  Signal.swift — live values DotStudio watches (docs/signals-design.md §2–3), shared by every
//  host: the definitions the user or the AI made (library.json, Library.signals), the built-ins,
//  and the live values the app writes for everyone else (<store>/signal-values.json, SignalState).
//
//  Data flows one way, like the weather: only the app fetches (App/Signals/SignalService.swift,
//  with Shared/Signals/Fetch — never compiled into the saver) and only the app evaluates the When
//  rules (RuleEngine, PlayRule.swift). It writes the values and its rule decision as a LEASE into
//  signal-values.json; the saver, the wallpaper, the gallery and dotstudio-mcp read that file
//  (SignalFeed) and agree on what plays (Playback). A quit app → the lease runs out → the normal
//  lineup. Live values NEVER go in library.json (the saver re-applies the style on its mtime).
//
//  Secrets: a web signal's API key lives only in the macOS Keychain (App/Signals/SignalKeychain);
//  `auth` here says where it goes (header or query, and the name), never the value.

import Foundation

enum SignalKind: String, Codable, CaseIterable {
    /// An HTTPS JSON endpoint (GET).
    case web
    /// A file in <store>/signal-files/ (JSON + pointer, or plain text with one number or word).
    case file

    init(from decoder: Decoder) throws {
        self = SignalKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .web
    }
}

enum SignalValueType: String, Codable, CaseIterable {
    case number, bool, string

    init(from decoder: Decoder) throws {
        self = SignalValueType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .number
    }
}

/// Where a web signal's key goes. The value itself is only ever in the Keychain.
struct SignalAuth: Codable, Equatable, Hashable {
    enum Placement: String, Codable, CaseIterable { case header, query }
    var placement: Placement
    /// The header or query parameter name ("X-API-Key", "token").
    var name: String

    private enum CodingKeys: String, CodingKey { case placement = "in", name }
}

/// A user- or AI-defined signal (library.json). Additive and tolerant: a field this build
/// doesn't know is dropped, a bad one decodes as its default.
struct Signal: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: SignalKind = .web
    /// web: the https URL (optional `{lat}` / `{lon}` placeholders: the weather's rounded location).
    var url: String?
    /// file: a file name inside <store>/signal-files/.
    var file: String?
    /// RFC 6901 JSON Pointer to the value ("" or nil = the whole document).
    var pointer: String?
    var valueType: SignalValueType = .number
    /// number = raw × scale + offset.
    var scale: Double?
    var offset: Double?
    var unit: String?
    /// The value's usual range [lo, hi]: the UI's slider, and how far a When rule's threshold must
    /// be crossed back before it lets go (5 % of it).
    var range: [Double]?
    var defaultValue: Double?
    /// web: minutes between fetches (≥ 5, default 15).
    var pollMinutes: Double?
    var auth: SignalAuth?
    var enabled: Bool = true
    /// "ai" for signals an assistant made (marked in Settings, notice + Undo); nil = the user's.
    var createdBy: String?

    static let minPollMinutes = 5.0
    static let defaultPollMinutes = 15.0
    /// The most user signals a library holds.
    static let maxCount = 16

    init(id: UUID = UUID(), name: String, kind: SignalKind = .web) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, url, file, pointer, valueType, scale, offset, unit, range
        case defaultValue = "default", pollMinutes, auth, enabled, createdBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Signal"
        kind = (try? c.decode(SignalKind.self, forKey: .kind)) ?? .web
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        pointer = try? c.decodeIfPresent(String.self, forKey: .pointer)
        valueType = (try? c.decode(SignalValueType.self, forKey: .valueType)) ?? .number
        scale = try? c.decodeIfPresent(Double.self, forKey: .scale)
        offset = try? c.decodeIfPresent(Double.self, forKey: .offset)
        unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        range = (try? c.decodeIfPresent([Double].self, forKey: .range)).flatMap { $0?.count == 2 ? $0 : nil }
        defaultValue = try? c.decodeIfPresent(Double.self, forKey: .defaultValue)
        pollMinutes = try? c.decodeIfPresent(Double.self, forKey: .pollMinutes)
        auth = try? c.decodeIfPresent(SignalAuth.self, forKey: .auth)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
    }

    var createdByAI: Bool { createdBy == "ai" }
    /// The values map's key for this signal.
    var key: String { id.uuidString }
    /// Minutes between fetches, never under the minimum.
    var interval: TimeInterval { max(pollMinutes ?? Self.defaultPollMinutes, Self.minPollMinutes) * 60 }
    /// A reading older than this counts as stale (rules read it as false): 3 polls, ≥ 30 min.
    var staleAfter: TimeInterval { max(3 * (kind == .file ? 10 : interval), 30 * 60) }
    var valueRange: ClosedRange<Double>? {
        guard let r = range, r.count == 2, r[0].isFinite, r[1].isFinite, r[0] < r[1] else { return nil }
        return r[0]...r[1]
    }
    /// The host it fetches from, for the UI ("api.waqi.info") — never the path or query.
    var host: String? { url.flatMap { URLComponents(string: $0)?.host } }
    /// "api.waqi.info" or "aqi.json".
    var whereFrom: String { kind == .web ? (host ?? "—") : (file ?? "—") }
}

/// The built-in signals: values the app already has, no new network (design §2).
struct BuiltInSignal: Equatable {
    let id: String
    let name: String
    let type: SignalValueType
    let unit: String?
    let range: ClosedRange<Double>?
    let symbol: String
    /// string signals: the values it takes.
    var options: [String]? = nil
}

enum BuiltInSignals {
    static let all: [BuiltInSignal] = [
        BuiltInSignal(id: "weather.condition", name: "Weather", type: .string, unit: nil, range: nil, symbol: "cloud.sun",
                      options: WeatherCondition.allCases.map(\.rawValue)),
        BuiltInSignal(id: "weather.precip", name: "Rain or snow", type: .number, unit: nil, range: 0...1, symbol: "cloud.rain"),
        BuiltInSignal(id: "weather.snow", name: "Snow share", type: .number, unit: nil, range: 0...1, symbol: "snowflake"),
        BuiltInSignal(id: "weather.cloud", name: "Cloud cover", type: .number, unit: nil, range: 0...1, symbol: "cloud"),
        BuiltInSignal(id: "weather.fog", name: "Fog", type: .number, unit: nil, range: 0...1, symbol: "cloud.fog"),
        BuiltInSignal(id: "weather.storm", name: "Storm", type: .number, unit: nil, range: 0...1, symbol: "cloud.bolt"),
        BuiltInSignal(id: "weather.wind", name: "Wind", type: .number, unit: "m/s", range: 0...30, symbol: "wind"),
        BuiltInSignal(id: "weather.tempC", name: "Temperature", type: .number, unit: "°C", range: -30...45, symbol: "thermometer.medium"),
        BuiltInSignal(id: "sun.elevation", name: "Sun height", type: .number, unit: "°", range: -90...90, symbol: "sun.horizon"),
        BuiltInSignal(id: "sun.isDay", name: "Daylight", type: .bool, unit: nil, range: nil, symbol: "sun.max"),
        BuiltInSignal(id: "time.hour", name: "Hour", type: .number, unit: "h", range: 0...24, symbol: "clock"),
        BuiltInSignal(id: "time.weekday", name: "Weekday", type: .number, unit: nil, range: 1...7, symbol: "calendar"),
        BuiltInSignal(id: "power.battery", name: "Battery", type: .number, unit: "%", range: 0...100, symbol: "battery.50"),
        BuiltInSignal(id: "power.onAC", name: "Plugged in", type: .bool, unit: nil, range: nil, symbol: "powerplug"),
        BuiltInSignal(id: "music.playing", name: "Music playing", type: .bool, unit: nil, range: nil, symbol: "music.note"),
    ]

    static func find(_ id: String) -> BuiltInSignal? { all.first { $0.id == id } }

    /// time.* are the clock: every host computes them itself (they are never written to the file).
    static func clockValue(_ id: String, at now: Date) -> SignalValue? {
        let cal = Calendar.current
        switch id {
        case "time.hour":
            let c = cal.dateComponents([.hour, .minute], from: now)
            return SignalValue(v: Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60, at: now.timeIntervalSince1970)
        case "time.weekday":
            return SignalValue(v: Double(cal.component(.weekday, from: now)), at: now.timeIntervalSince1970)
        default:
            return nil
        }
    }
}

/// One signal's live value (signal-values.json). Numbers and bools in `v` (bool: 1 / 0), words in `s`.
struct SignalValue: Codable, Equatable {
    var v: Double?
    var s: String?
    /// Unix seconds of the reading (the last good one; `error` may be newer).
    var at: Double?
    /// The last fetch's problem ("HTTP 503", "Timed out") — never a URL, header or key.
    var error: String?
    /// Seconds after `at` the reading counts as stale (rules read stale as false).
    var stale: Double?

    init(v: Double? = nil, s: String? = nil, at: Double? = nil, error: String? = nil, stale: Double? = nil) {
        self.v = v; self.s = s; self.at = at; self.error = error; self.stale = stale
    }

    var hasValue: Bool { v != nil || s != nil }

    /// 1 while fresh, fading to 0 over 30 minutes after `stale` (like WeatherState.freshness).
    func freshness(at now: Date = Date()) -> Double {
        guard hasValue, let at else { return 0 }
        let age = now.timeIntervalSince1970 - at
        if age < -3600 { return 0 }
        let x = (age - (stale ?? 30 * 60)) / (30 * 60)
        return x <= 0 ? 1 : (x >= 1 ? 0 : 1 - x * x * (3 - 2 * x))
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard hasValue, let at else { return false }
        let age = now.timeIntervalSince1970 - at
        return age >= -3600 && age <= (stale ?? 30 * 60)
    }

    /// "42 µg/m³", "Snow", "On".
    func display(type: SignalValueType, unit: String?) -> String {
        switch type {
        case .bool: return v.map { $0 > 0.5 ? "Yes" : "No" } ?? "—"
        case .string: return s ?? v.map { SignalValue.format($0) } ?? "—"
        case .number:
            guard let v else { return s ?? "—" }
            return SignalValue.format(v) + (unit.map { $0.isEmpty ? "" : ($0 == "%" || $0 == "°" ? $0 : " " + $0) } ?? "")
        }
    }

    /// 42, 23.5, 1.4, 0.25 — at most two decimals, no trailing zeros.
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        var s = abs(v) >= 100 ? String(format: "%.0f", v) : abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// The app's When-rule decision, as a lease every host honours until `validUntil`.
struct RuleLease: Codable, Equatable {
    /// The rule playing now; nil = none (the normal lineup).
    var id: UUID?
    /// When this decision (this rule, or none) started.
    var since: Double
    /// Hosts ignore the lease after this (the app refreshes it every 10 minutes).
    var validUntil: Double
}

/// <store>/signal-values.json — CONTRACT between the app (writer) and every host (readers).
struct SignalState: Codable, Equatable {
    static let fileName = "signal-values.json"
    /// How long a decision holds without the app refreshing it.
    static let leaseSeconds: TimeInterval = 30 * 60
    /// The app rewrites the lease at least this often.
    static let leaseRefresh: TimeInterval = 10 * 60

    var version: Int = 1
    var writtenAt: Double?
    /// Signal id ("weather.tempC", a user signal's UUID) → its value.
    var values: [String: SignalValue] = [:]
    var rule: RuleLease?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        writtenAt = try? c.decodeIfPresent(Double.self, forKey: .writtenAt)
        values = ((try? c.decodeIfPresent([String: SignalValue].self, forKey: .values)) ?? nil) ?? [:]
        rule = try? c.decodeIfPresent(RuleLease.self, forKey: .rule)
    }

    /// The rule the app says plays now, while its lease runs (nil = none, or the app is gone).
    func activeRuleID(at now: Date) -> UUID? {
        guard let r = rule, let id = r.id, r.validUntil > now.timeIntervalSince1970 else { return nil }
        return id
    }

    /// A signal's value now: the clock ones computed here, the rest from the file.
    func value(_ id: String, at now: Date = Date()) -> SignalValue? {
        BuiltInSignals.clockValue(id, at: now) ?? values[id]
    }

    static func read(baseDir: URL) -> SignalState? {
        guard let d = try? Data(contentsOf: baseDir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(SignalState.self, from: d)
    }
}

extension Library {
    /// A signal by id: a built-in's dotted id, or a user signal's UUID string.
    func signalInfo(_ id: String) -> (name: String, type: SignalValueType, unit: String?, range: ClosedRange<Double>?, options: [String]?)? {
        if let b = BuiltInSignals.find(id) { return (b.name, b.type, b.unit, b.range, b.options) }
        guard let s = (signals ?? []).first(where: { $0.key == id || $0.id.uuidString.lowercased() == id.lowercased() }) else { return nil }
        return (s.name, s.valueType, s.unit, s.valueRange, nil)
    }

    func signal(_ id: UUID) -> Signal? { (signals ?? []).first { $0.id == id } }

    /// The location the weather uses (web signals' {lat}/{lon} placeholders, rounded to 0.1°).
    var signalLocation: (lat: Double, lon: Double)? {
        guard let la = locationLat, let lo = locationLon else { return nil }
        return (la, lo)
    }
}
