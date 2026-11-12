//  JSON.swift — loose JSON values for the MCP wire (JSONSerialization objects) and a small
//  JSON Schema checker for the subset the tool schemas use.

import Foundation

typealias JSONObject = [String: Any]

enum JSON {
    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    static func isNumber(_ v: Any) -> Bool { v is NSNumber && !isBool(v) }
    static func isInteger(_ v: Any) -> Bool {
        guard isNumber(v), let d = (v as? NSNumber)?.doubleValue else { return false }
        return d.isFinite && d == d.rounded()
    }

    static func data(_ v: Any, pretty: Bool = false) -> Data {
        // fragmentsAllowed: a bare string/number (enum values, consts) — without it Foundation
        // raises an Objective-C exception, which would take the server down.
        var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted); opts.insert(.sortedKeys) }
        if v is [Any] || v is [String: Any], !JSONSerialization.isValidJSONObject(v) { return Data("null".utf8) }
        if let d = (v as? NSNumber)?.doubleValue, !JSON.isBool(v), !d.isFinite { return Data("null".utf8) }
        return (try? JSONSerialization.data(withJSONObject: v, options: opts)) ?? Data("null".utf8)
    }
    static func string(_ v: Any, pretty: Bool = false) -> String { String(decoding: data(v, pretty: pretty), as: UTF8.self) }

    static func parse(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }

    /// A Codable value as a loose JSON object.
    static func from<T: Encodable>(_ value: T) -> Any {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(value), let v = parse(d) else { return NSNull() }
        return v
    }

    /// A loose JSON object as a Codable value.
    static func decode<T: Decodable>(_ type: T.Type, from v: Any) throws -> T {
        let d = try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: d)
    }
}

/// JSON Schema (draft 2020-12 subset): type, properties, required, additionalProperties: false,
/// enum, const, minimum/maximum, minLength/maxLength, pattern, items, minItems/maxItems,
/// oneOf/anyOf (first match). Error messages name the path and say what was expected.
enum Schema {
    static func validate(_ value: Any?, _ schema: JSONObject, path: String = "arguments") -> [String] {
        var errors: [String] = []
        check(value, schema, path, &errors)
        return errors
    }

    private static func typeName(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        if JSON.isBool(v) { return "boolean" }
        if JSON.isNumber(v) { return JSON.isInteger(v) ? "integer" : "number" }
        if v is String { return "string" }
        if v is [Any] { return "array" }
        if v is JSONObject { return "object" }
        return "unknown"
    }

    private static func matches(_ v: Any?, type: String) -> Bool {
        let t = typeName(v)
        if type == "number" { return t == "number" || t == "integer" }
        return t == type
    }

    private static func check(_ v: Any?, _ s: JSONObject, _ path: String, _ errors: inout [String]) {
        if let any = s["anyOf"] as? [JSONObject] ?? s["oneOf"] as? [JSONObject] {
            var best: [String]?
            for sub in any {
                var e: [String] = []
                check(v, sub, path, &e)
                if e.isEmpty { return }
                if best == nil || e.count < best!.count { best = e }
            }
            errors.append(contentsOf: best ?? ["\(path): matches none of the allowed shapes"])
            return
        }
        if let types = s["type"] as? [String] {
            guard types.contains(where: { matches(v, type: $0) }) else {
                errors.append("\(path): expected \(types.joined(separator: " or ")), got \(typeName(v))"); return
            }
        } else if let type = s["type"] as? String, !matches(v, type: type) {
            errors.append("\(path): expected \(type), got \(typeName(v))")
            return
        }
        if let c = s["const"], let v, !(JSON.string(c) == JSON.string(v)) {
            errors.append("\(path): must be \(JSON.string(c))")
        }
        if let e = s["enum"] as? [Any], let v {
            let have = JSON.string(v)
            if !e.contains(where: { JSON.string($0) == have }) {
                errors.append("\(path): \(have) isn't one of \(e.map { JSON.string($0) }.joined(separator: ", "))")
            }
        }
        if let n = (v as? NSNumber)?.doubleValue, JSON.isNumber(v as Any) {
            if !n.isFinite { errors.append("\(path): must be a finite number") }
            if let mn = (s["minimum"] as? NSNumber)?.doubleValue, n < mn { errors.append("\(path): \(fmt(n)) is below the minimum \(fmt(mn))") }
            if let mx = (s["maximum"] as? NSNumber)?.doubleValue, n > mx { errors.append("\(path): \(fmt(n)) is above the maximum \(fmt(mx))") }
        }
        if let str = v as? String {
            if let mn = s["minLength"] as? Int, str.count < mn { errors.append("\(path): must be at least \(mn) characters") }
            if let mx = s["maxLength"] as? Int, str.count > mx { errors.append("\(path): must be at most \(mx) characters (got \(str.count))") }
            if let p = s["pattern"] as? String, str.range(of: p, options: .regularExpression) == nil {
                errors.append("\(path): \"\(str.prefix(60))\" doesn't match \(p)")
            }
        }
        if let arr = v as? [Any] {
            if let mn = s["minItems"] as? Int, arr.count < mn { errors.append("\(path): needs at least \(mn) item(s)") }
            if let mx = s["maxItems"] as? Int, arr.count > mx { errors.append("\(path): at most \(mx) item(s) (got \(arr.count))") }
            if let items = s["items"] as? JSONObject {
                for (i, item) in arr.enumerated() { check(item, items, "\(path)[\(i)]", &errors) }
            }
        }
        if let obj = v as? JSONObject {
            let props = s["properties"] as? JSONObject ?? [:]
            for r in s["required"] as? [String] ?? [] where obj[r] == nil {
                errors.append("\(path): missing required \"\(r)\"")
            }
            for (k, val) in obj {
                if let ps = props[k] as? JSONObject {
                    check(val, ps, "\(path).\(k)", &errors)
                } else if let ap = s["additionalProperties"] {
                    if let apSchema = ap as? JSONObject {
                        check(val, apSchema, "\(path).\(k)", &errors)
                    } else if JSON.isBool(ap), (ap as? Bool) == false {
                        let known = props.keys.sorted().joined(separator: ", ")
                        errors.append("\(path): unknown property \"\(k)\"" + (known.isEmpty ? "" : " (allowed: \(known))"))
                    }
                }
            }
        }
    }

    static func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%g", d)
    }
}
