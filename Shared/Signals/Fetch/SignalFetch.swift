//  SignalFetch.swift — what may be fetched, and fetching it (docs/signals-design.md §2).
//
//  APP AND dotstudio-mcp ONLY: project.yml excludes Signals/Fetch/** from the saver, which must
//  never touch the network. The app's SignalService schedules fetches; dotstudio-mcp's test_signal
//  fetches once (offline, a signal without a key).
//
//  Rules every fetch keeps: https only, GET only, no body, an ephemeral session (no cookies, no
//  cache), UA "DotStudio/<version>", 10 s timeout, 256 KB cap, at most 3 redirects each re-checked
//  against the same policy (and the key header dropped when the host changes). Signals an AI makes
//  can't reach localhost, *.local, or loopback / private / link-local / ULA addresses — written as
//  an address, or behind a name that resolves to one (checked before each fetch and redirect, and
//  the connection's peer after it: "Where a name points" below). A URL whose
//  query carries a key-like parameter is refused: keys go in `auth`, whose value only the Keychain
//  holds. Errors are short words ("HTTP 503", "Timed out") — never a URL, a header or a body.
//
//  Test hook (DEBUG builds only — compiled out of Release): DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1 also
//  allows http:// and https:// to 127.0.0.1 / localhost, so tools/mcp-selftest can serve a local
//  fixture. Every other refusal (http elsewhere, private and link-local addresses, key-like query
//  parameters) still holds with it on. DOTSTUDIO_SIGNAL_FAKE_DNS (DEBUG only too) replaces the
//  lookups AI-made fetches make with a fixed table, so the self-test checks the DNS refusals
//  without a real lookup.

import Foundation

// MARK: - Results

/// One leaf of a fetched document, for the outline test_signal and Settings show (never the body).
struct SignalOutlineItem: Codable, Equatable {
    var pointer: String
    var value: JSONValue
}

/// A fetch (or a file read), as the UI and the AI see it.
struct SignalFetchResult: Codable, Equatable {
    var value: SignalValue?
    var status: Int?
    var ms: Int?
    var bytes: Int?
    var error: String?
    /// Seconds the server asked us to wait (Retry-After on 429 / 503).
    var retryAfter: Double?
    var outline: [SignalOutlineItem]?
    /// The signal has a key and none is stored (or it can't be read): the user must enter it.
    var needsSecret: Bool?

    var ok: Bool { error == nil && value?.hasValue == true }
}

// MARK: - Policy

enum SignalPolicy {
    static let maxBytes = 256 * 1024
    static let maxFileBytes = 64 * 1024
    static let timeout: TimeInterval = 10
    static let maxRedirects = 3
    static let filesDirName = "signal-files"
    static let keyLikeParams: Set<String> = ["key", "apikey", "api_key", "api-key", "token", "access_token",
                                             "appid", "secret", "password", "sig", "signature"]

    static func filesDir(_ store: URL) -> URL { store.appendingPathComponent(filesDirName, isDirectory: true) }

    /// The self-test's local fixture hook (see the header). Never honoured in Release.
    static var allowLocal: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DOTSTUDIO_SIGNAL_ALLOW_LOCAL"] == "1"
        #else
        return false
        #endif
    }

    /// The URL to fetch, with `{lat}` / `{lon}` filled (nil location: placeholders → "0.0").
    static func resolvedURL(_ template: String, location: (lat: Double, lon: Double)?) -> URL? {
        let lat = location.map { String(format: "%.1f", ($0.lat * 10).rounded() / 10) } ?? "0.0"
        let lon = location.map { String(format: "%.1f", ($0.lon * 10).rounded() / 10) } ?? "0.0"
        return URL(string: template.replacingOccurrences(of: "{lat}", with: lat).replacingOccurrences(of: "{lon}", with: lon))
    }

    static func usesLocation(_ template: String) -> Bool { template.contains("{lat}") || template.contains("{lon}") }

    /// Why a URL may not be fetched (nil = fine). `forAI`: the host policy for AI-made signals.
    static func refusal(_ url: URL?, forAI: Bool) -> String? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), let rawHost = c.host, !rawHost.isEmpty else {
            return "That isn't a valid URL."
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let localFixture = allowLocal && (host == "127.0.0.1" || host == "localhost")
        if scheme != "https", !(localFixture && scheme == "http") {
            return "Only https:// URLs can be signals (this one is \(scheme)://)."
        }
        if c.user != nil || c.password != nil { return "Put no user name or password in the URL — use an API key (auth) instead." }
        for item in c.queryItems ?? [] where keyLikeParams.contains(item.name.lowercased()) {
            return "The URL carries a key in its query (\(item.name)=…). Never put a key in the URL: remove it and set `auth` {in: \"query\", name: \"\(item.name)\"} — the user then pastes the key in DotStudio ▸ Settings ▸ Signals, where it goes to the Keychain."
        }
        if forAI, !localFixture, let why = privateHost(host) { return why }
        return nil
    }

    /// Hosts an AI-made signal may not reach (nil = public).
    static func privateHost(_ host: String) -> String? {
        let h = host.hasSuffix(".") ? String(host.dropLast()) : host
        var probe4 = in_addr()
        // Numbers in an unusual form ("2130706433", "0x7f.1") are IP literals in disguise.
        if inet_pton(AF_INET, h, &probe4) != 1, h.first?.isNumber == true,
           h.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }) {
            return "Use a host name or a dotted address, not \(h)."
        }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal")
            || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") || !h.contains(".") && !h.contains(":") {
            return "Signals an assistant makes can't reach this Mac or the local network (\(h)). The user can add a signal for a local service themselves in DotStudio ▸ Settings ▸ Signals, or feed a file in signal-files."
        }
        if isPrivateAddress(h) == true {
            return "Signals an assistant makes can't reach private, loopback or link-local addresses (\(h))."
        }
        return nil
    }

    /// Whether an IP address (a literal: "10.0.0.1", "fe80::1%en0") is one an AI-made signal may
    /// not reach: unspecified, loopback, private (10/8, 172.16/12, 192.168/16), CGNAT (100.64/10),
    /// link-local (169.254/16, fe80::/10), site-local (fec0::/10), ULA (fc00::/7), multicast and
    /// reserved (224/4 and up, ff00::/8) — and the IPv6 forms that carry an IPv4 address inside
    /// (::ffff:a.b.c.d, ::a.b.c.d, 64:ff9b::/96 NAT64, 2002::/16 6to4), judged by that address.
    /// nil = not an IP literal.
    static func isPrivateAddress(_ literal: String) -> Bool? {
        let s = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal   // a zone index
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return isPrivateV4(withUnsafeBytes(of: v4.s_addr) { Array($0) })   // network order
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return isPrivateV6(withUnsafeBytes(of: v6) { Array($0) })
        }
        return nil
    }

    static func isPrivateV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        return b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1])) || b[0] >= 224
    }

    static func isPrivateV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        let zeros10 = b[0..<10].allSatisfy { $0 == 0 }
        if zeros10, b[10] == 0xff, b[11] == 0xff { return isPrivateV4(Array(b[12..<16])) }     // ::ffff:a.b.c.d
        if zeros10, b[10] == 0, b[11] == 0 {
            // :: (unspecified) and ::1 (loopback); else the deprecated IPv4-compatible ::a.b.c.d
            if b[12..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return true }
            return isPrivateV4(Array(b[12..<16]))
        }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            return isPrivateV4(Array(b[12..<16]))                                                // 64:ff9b::/96 (NAT64)
        }
        if b[0] == 0x20, b[1] == 0x02 { return isPrivateV4(Array(b[2..<6])) }                    // 2002::/16 (6to4)
        let linkOrSiteLocal = b[0] == 0xfe && (b[1] & 0x80) == 0x80                              // fe80::/10, fec0::/10
        let ula = (b[0] & 0xfe) == 0xfc                                                          // fc00::/7
        return linkOrSiteLocal || ula || b[0] == 0xff                                            // ff00::/8 multicast
    }

    // MARK: Where a name points (AI-made signals)
    //
    // A public NAME can still point at this Mac or the LAN (a DNS record for 10.0.0.5, or one
    // that changes between two lookups: DNS rebinding), so for an AI-made signal every fetch —
    // and every redirect — first resolves the host and refuses if ANY address is one of the
    // above. URLSession then resolves the name again itself; a record that changes in between
    // (the residual time-of-check gap) is caught after the fact: the address the connection
    // actually reached (URLSessionTaskMetrics.remoteAddress) is checked too, and a private one
    // discards the response. What that can't undo is the request itself having reached the LAN
    // host — a GET without a body, cookies or credentials (only a signal's own key, for a host
    // that kept its public name long enough to pass the first check). Through an HTTP proxy the
    // proxy resolves the name, and the peer is the proxy: only the first check applies there.

    /// The addresses a host name resolves to (numeric strings), nil = it doesn't resolve.
    /// Blocking: never on the main thread. Replaceable for tests; DEBUG builds also honour
    /// DOTSTUDIO_SIGNAL_FAKE_DNS="host=addr,addr;host2=addr" — a fixed table, no real lookups.
    static var resolve: (String) -> [String]? = { host in
        if let table = fakeDNS { return table[host.lowercased()] }
        return systemResolve(host)
    }

    /// The DEBUG-only fake resolver's table (see `resolve`). Never honoured in Release.
    static var fakeDNS: [String: [String]]? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["DOTSTUDIO_SIGNAL_FAKE_DNS"] else { return nil }
        var t: [String: [String]] = [:]
        for entry in raw.split(separator: ";") {
            let kv = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            t[kv[0].lowercased()] = kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return t
        #else
        return nil
        #endif
    }

    static func systemResolve(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let sa = ai.pointee.ai_addr, let s = numericAddress(sa, Int(ai.pointee.ai_addrlen)) { out.append(s) }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// A sockaddr (IPv4 or IPv6) as a numeric string; nil for anything else.
    static func numericAddress(_ sa: UnsafePointer<sockaddr>, _ len: Int) -> String? {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        switch Int32(sa.pointee.sa_family) {
        case AF_INET where len >= MemoryLayout<sockaddr_in>.size:
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
        case AF_INET6 where len >= MemoryLayout<sockaddr_in6>.size:
            var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
        default:
            return nil
        }
        return String(cString: buf)
    }

    /// The self-test's local fixture (127.0.0.1 / localhost, DEBUG hook on) — the one loopback
    /// host the AI policy lets through, and only in a DEBUG build.
    static func isLocalFixture(_ url: URL?) -> Bool {
        guard allowLocal, let h = url?.host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost"
    }

    /// The host whose addresses an AI-made fetch of `url` must check first: nil for an IP
    /// literal (`refusal` judged it already) and for the self-test's local fixture.
    static func hostToResolve(_ url: URL?) -> String? {
        guard let raw = url?.host?.lowercased(), !raw.isEmpty else { return nil }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLocalFixture(url) { return nil }
        if isPrivateAddress(host) != nil { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Why an AI-made signal may not reach `host` once it's resolved (nil = every address is
    /// public). Blocking (a DNS lookup): never on the main thread.
    static func resolvedRefusal(_ host: String, resolve: (String) -> [String]? = SignalPolicy.resolve) -> String? {
        guard let addrs = resolve(host), !addrs.isEmpty else { return "Host not found" }
        for a in addrs where isPrivateAddress(a) != false {
            return "Signals an assistant makes can't reach this Mac or the local network: \(host) points to a private, loopback or link-local address (\(a))."
        }
        return nil
    }

    /// Everything wrong with a signal definition (empty = fine). `forAI`: an assistant made or
    /// changed it (the stricter host policy). Shared by Settings and the MCP tools.
    static func validate(_ s: Signal, forAI: Bool) -> [String] {
        var out: [String] = []
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { out.append("The signal needs a name.") }
        if name.count > 60 { out.append("Name: 60 characters at most.") }
        switch s.kind {
        case .web:
            if let u = s.url, !u.isEmpty {
                if u.count > 2048 { out.append("The URL is longer than 2048 characters.") }
                if let why = refusal(resolvedURL(u, location: nil), forAI: forAI) { out.append(why) }
            } else { out.append("A web signal needs a url (https://…).") }
            if let p = s.pollMinutes, !(p >= Signal.minPollMinutes && p <= 1440) {
                out.append("pollMinutes is \(Int(Signal.minPollMinutes))…1440 (every 5 minutes at most).")
            }
            if let a = s.auth {
                let ok = !a.name.isEmpty && a.name.count <= 60
                    && a.name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
                if !ok { out.append("auth.name is a header or query name: letters, digits, - _ . (60 at most).") }
                if a.placement == .header, ["host", "cookie", "content-length", "connection"].contains(a.name.lowercased()) {
                    out.append("auth.name can't be \(a.name).")
                }
            }
        case .file:
            let f = s.file ?? ""
            if f.isEmpty { out.append("A file signal needs `file`: a file name in \(filesDirName).") }
            else if f.contains("/") || f.hasPrefix(".") || f.count > 120 || f.contains("\0") {
                out.append("`file` is a plain file name inside \(filesDirName) (no folders, not hidden).")
            }
            if s.auth != nil { out.append("Only web signals have a key.") }
        }
        if let p = s.pointer, !p.isEmpty, !p.hasPrefix("/") || p.count > 256 { out.append("pointer is a JSON Pointer: \"\" or \"/a/0/b\".") }
        if let r = s.range, r.count != 2 || !r.allSatisfy(\.isFinite) || r[0] >= r[1] { out.append("range is [low, high] with low < high.") }
        for (k, v) in [("scale", s.scale), ("offset", s.offset), ("default", s.defaultValue)] {
            if let v, !v.isFinite { out.append("\(k) must be a number.") }
        }
        if let u = s.unit, u.count > 12 { out.append("unit: 12 characters at most.") }
        return out
    }
}

// MARK: - Reading a document

enum JSONPointer {
    static func resolve(_ doc: Any, _ pointer: String?) -> Any? {
        guard let pointer, !pointer.isEmpty else { return doc }
        guard pointer.hasPrefix("/") else { return nil }
        var cur: Any = doc
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let o = cur as? [String: Any], let next = o[token] { cur = next }
            else if let a = cur as? [Any], let i = Int(token), a.indices.contains(i) { cur = a[i] }
            else { return nil }
        }
        return cur
    }

    static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Up to `limit` leaves (pointer → number / bool / string ≤ 40 characters), depth first.
    static func outline(_ doc: Any, limit: Int = 60) -> [SignalOutlineItem] {
        var out: [SignalOutlineItem] = []
        func walk(_ v: Any, _ path: String, _ depth: Int) {
            guard out.count < limit, depth < 12 else { return }
            if let o = v as? [String: Any] {
                for k in o.keys.sorted() { walk(o[k]!, path + "/" + escape(k), depth + 1) }
            } else if let a = v as? [Any] {
                for (i, x) in a.prefix(20).enumerated() { walk(x, path + "/\(i)", depth + 1) }
            } else if let leaf = leafValue(v) {
                out.append(SignalOutlineItem(pointer: path, value: leaf))
            }
        }
        walk(doc, "", 0)
        return out
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func leafValue(_ v: Any) -> JSONValue? {
        if let n = v as? NSNumber {
            if isBool(n) { return .bool(n.boolValue) }
            let d = n.doubleValue
            return d.isFinite ? .number(d) : nil
        }
        if let s = v as? String { return .string(s.count > 40 ? String(s.prefix(39)) + "…" : s) }
        return nil
    }
}

enum SignalExtract {
    enum Outcome { case value(SignalValue), problem(String) }

    /// The signal's value from a parsed document (JSON) or plain text, as SignalValue (no `at`).
    static func value(_ s: Signal, json: Any?, text: String?) -> Outcome {
        let raw: Any
        if let json {
            guard let r = JSONPointer.resolve(json, s.pointer) else { return .problem("Nothing at \(s.pointer ?? "")") }
            raw = r
        } else {
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return .problem("Empty") }
            raw = String(t.split(separator: "\n").first ?? "")
        }
        switch s.valueType {
        case .number:
            var d: Double?
            if let n = raw as? NSNumber { d = n.doubleValue }
            else if let str = raw as? String { d = Double(str.trimmingCharacters(in: .whitespaces)) }
            guard let x = d, x.isFinite else { return .problem("Not a number") }
            let y = x * (s.scale ?? 1) + (s.offset ?? 0)
            return y.isFinite ? .value(SignalValue(v: y)) : .problem("Not a number")
        case .bool:
            if let n = raw as? NSNumber { return .value(SignalValue(v: n.doubleValue != 0 ? 1 : 0)) }
            if let str = (raw as? String)?.lowercased().trimmingCharacters(in: .whitespaces) {
                if ["true", "yes", "on", "1"].contains(str) { return .value(SignalValue(v: 1)) }
                if ["false", "no", "off", "0"].contains(str) { return .value(SignalValue(v: 0)) }
            }
            return .problem("Not yes or no")
        case .string:
            if let str = raw as? String {
                let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? .problem("Empty") : .value(SignalValue(s: String(t.prefix(64))))
            }
            if let n = raw as? NSNumber {
                return .value(SignalValue(s: JSONPointer.isBool(n) ? (n.boolValue ? "true" : "false") : SignalValue.format(n.doubleValue)))
            }
            return .problem("Not a word")
        }
    }

    /// Parse bytes as JSON, else as text (a file signal may be either).
    static func parse(_ data: Data, preferJSON: Bool) -> (json: Any?, text: String?) {
        if let j = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return (j, nil) }
        if preferJSON { return (nil, nil) }
        return (nil, String(data: data, encoding: .utf8))
    }
}

// MARK: - Files

enum SignalFileReader {
    /// A file signal's value now. The file must resolve (symlinks too) inside <store>/signal-files/.
    static func read(_ s: Signal, store: URL, now: Date = Date()) -> SignalFetchResult {
        guard let name = s.file, !name.isEmpty, !name.contains("/") else { return SignalFetchResult(error: "No file") }
        let dir = SignalPolicy.filesDir(store)
        let url = dir.appendingPathComponent(name)
        guard let real = realpath(url.path), let realDir = realpath(dir.path), real.hasPrefix(realDir + "/") else {
            return SignalFetchResult(error: FileManager.default.fileExists(atPath: url.path) ? "Outside signal-files" : "No such file")
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return SignalFetchResult(error: "Not a file") }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= SignalPolicy.maxFileBytes else { return SignalFetchResult(bytes: size, error: "Larger than 64 KB") }
        guard let data = FileManager.default.contents(atPath: real) else { return SignalFetchResult(error: "Can't read it") }
        let parsed = SignalExtract.parse(data, preferJSON: !(s.pointer ?? "").isEmpty)
        var r = SignalFetchResult(bytes: data.count)
        if let j = parsed.json { r.outline = JSONPointer.outline(j) }
        switch SignalExtract.value(s, json: parsed.json, text: parsed.text) {
        case .value(var v):
            v.at = now.timeIntervalSince1970
            v.stale = s.staleAfter
            r.value = v
        case .problem(let why): r.error = why
        }
        return r
    }

    private static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

// MARK: - The web

enum SignalFetcher {
    static var userAgent: String {
        "DotStudio/" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
    }

    /// Fetch once. `secret`: the key from the Keychain (nil = none / not needed). `forAI`: apply
    /// the AI host policy to the URL and every redirect. Completion on an arbitrary queue.
    static func fetch(_ s: Signal, secret: String?, location: (lat: Double, lon: Double)?, forAI: Bool,
                      completion: @escaping (SignalFetchResult) -> Void) {
        guard s.kind == .web, let template = s.url else { completion(SignalFetchResult(error: "No URL")); return }
        if s.auth != nil, (secret ?? "").isEmpty { completion(SignalFetchResult(error: "Needs its key", needsSecret: true)); return }
        if SignalPolicy.usesLocation(template), location == nil { completion(SignalFetchResult(error: "No location yet")); return }
        guard let base = SignalPolicy.resolvedURL(template, location: location) else { completion(SignalFetchResult(error: "Bad URL")); return }
        if let why = SignalPolicy.refusal(base, forAI: forAI) { completion(SignalFetchResult(error: why)); return }
        var url = base
        var req = URLRequest(url: url)
        if let a = s.auth, let secret {
            switch a.placement {
            case .header: req.setValue(secret, forHTTPHeaderField: a.name)
            case .query:
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: a.name, value: secret)]
                url = c.url ?? url
                req.url = url
            }
        }
        req.httpMethod = "GET"
        req.timeoutInterval = SignalPolicy.timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain;q=0.5", forHTTPHeaderField: "Accept")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = SignalPolicy.timeout
        cfg.timeoutIntervalForResource = SignalPolicy.timeout + 5
        cfg.httpMaximumConnectionsPerHost = 1
        let started = Date()
        let go = { [req] in
            let delegate = FetchDelegate(signal: s, forAI: forAI, authHeader: s.auth?.placement == .header ? s.auth?.name : nil,
                                         originalHost: base.host?.lowercased(), started: started, completion: completion)
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            delegate.queue = session.delegateQueue
            session.dataTask(with: req).resume()
            session.finishTasksAndInvalidate()
        }
        // An AI-made signal's host name: where it points, first (see "Where a name points").
        guard forAI, let host = SignalPolicy.hostToResolve(base) else { go(); return }
        DispatchQueue.global(qos: .utility).async {
            if let why = SignalPolicy.resolvedRefusal(host) {
                completion(SignalFetchResult(ms: Int(Date().timeIntervalSince(started) * 1000), error: why))
                return
            }
            go()
        }
    }

    /// Fetch and wait (dotstudio-mcp's test_signal; never on the main thread).
    static func fetchSync(_ s: Signal, secret: String?, location: (lat: Double, lon: Double)?, forAI: Bool) -> SignalFetchResult {
        let sem = DispatchSemaphore(value: 0)
        var out = SignalFetchResult(error: "Timed out")
        fetch(s, secret: secret, location: location, forAI: forAI) { r in out = r; sem.signal() }
        _ = sem.wait(timeout: .now() + SignalPolicy.timeout + 8)
        return out
    }

    private final class FetchDelegate: NSObject, URLSessionDataDelegate {
        let signal: Signal
        let forAI: Bool
        let authHeader: String?
        let originalHost: String?
        let started: Date
        var completion: ((SignalFetchResult) -> Void)?
        var data = Data()
        var redirects = 0
        var refused: String?
        var tooBig = false
        var status: Int?
        var retryAfter: Double?
        /// The session's (serial) delegate queue, for work that comes back from elsewhere.
        var queue: OperationQueue?
        /// AI-made: the connection's peer was checked (metrics arrived) — and refused, if so.
        var metricsSeen = false
        var peerRefused: String?
        /// The result, held until the peer is checked.
        var pending: SignalFetchResult?

        init(signal: Signal, forAI: Bool, authHeader: String?, originalHost: String?, started: Date,
             completion: @escaping (SignalFetchResult) -> Void) {
            self.signal = signal; self.forAI = forAI; self.authHeader = authHeader
            self.originalHost = originalHost; self.started = started; self.completion = completion
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            if redirects > SignalPolicy.maxRedirects { refused = "Too many redirects"; completionHandler(nil); return }
            if let why = SignalPolicy.refusal(request.url, forAI: forAI) { refused = "Redirected somewhere not allowed: " + why; completionHandler(nil); return }
            var next = request
            // The key never follows a redirect to another host.
            if let h = authHeader, request.url?.host?.lowercased() != originalHost { next.setValue(nil, forHTTPHeaderField: h) }
            // An AI-made signal: where the new name points, too (off this queue: it's a lookup).
            guard forAI, let host = SignalPolicy.hostToResolve(request.url) else { completionHandler(next); return }
            DispatchQueue.global(qos: .utility).async { [self, queue] in
                let why = SignalPolicy.resolvedRefusal(host)
                let finish = {
                    if let why { self.refused = "Redirected somewhere not allowed: " + why; completionHandler(nil) }
                    else { completionHandler(next) }
                }
                if let queue { queue.addOperation(finish) } else { finish() }
            }
        }

        /// The address each connection actually reached (see "Where a name points"): a private
        /// one discards the response. Delivered before didCompleteWithError.
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            metricsSeen = true
            guard forAI, peerRefused == nil else { finishIfWaiting(); return }
            for t in metrics.transactionMetrics where t.resourceFetchType == .networkLoad && !t.isProxyConnection {
                // The self-test's local fixture (DEBUG hook) is the one loopback peer allowed.
                if SignalPolicy.isLocalFixture(t.request.url) { continue }
                guard let addr = t.remoteAddress, !addr.isEmpty else { continue }
                if SignalPolicy.isPrivateAddress(addr) != false {
                    peerRefused = "Signals an assistant makes can't reach this Mac or the local network: the server's address turned out to be private, loopback or link-local (\(addr))."
                    break
                }
            }
            finishIfWaiting()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                if let ra = http.value(forHTTPHeaderField: "Retry-After"), let s = Double(ra.trimmingCharacters(in: .whitespaces)) {
                    retryAfter = min(max(s, 0), 6 * 3600)
                }
            }
            if response.expectedContentLength > Int64(SignalPolicy.maxBytes) { tooBig = true; completionHandler(.cancel); return }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            data.append(d)
            if data.count > SignalPolicy.maxBytes { tooBig = true; dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard completion != nil, pending == nil else { return }
            let r = result(error)
            // An AI-made fetch answers only once the peer's address is checked (metrics come
            // first; should they not, it answers after a moment without the body).
            if forAI, !metricsSeen {
                pending = r
                // (Holds the delegate: the session lets go of it once the task is done.)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self, queue] in
                    let late = { self.finish(peerUnknown: true) }
                    if let queue { queue.addOperation(late) } else { late() }
                }
                return
            }
            deliver(r)
        }

        /// Metrics arrived after the task completed.
        func finishIfWaiting() {
            if pending != nil { finish(peerUnknown: false) }
        }

        private func finish(peerUnknown: Bool) {
            guard var r = pending else { return }
            pending = nil
            if peerUnknown, peerRefused == nil, r.error == nil {
                r = SignalFetchResult(status: r.status, ms: r.ms, error: "Couldn't check the server's address")
            }
            deliver(r)
        }

        private func deliver(_ r: SignalFetchResult) {
            guard let completion else { return }
            self.completion = nil
            if let peerRefused {
                // Nothing of what a private address sent goes anywhere.
                completion(SignalFetchResult(status: r.status, ms: r.ms, error: peerRefused))
                return
            }
            completion(r)
        }

        private func result(_ error: Error?) -> SignalFetchResult {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            var r = SignalFetchResult(status: status, ms: ms, bytes: data.count, retryAfter: retryAfter)
            if tooBig { r.error = "Larger than 256 KB"; return r }
            if let refused { r.error = refused; return r }
            if let e = error as? URLError {
                r.error = Self.words(e)
                return r
            } else if error != nil {
                r.error = "Couldn't connect"
                return r
            }
            guard let code = status, (200..<300).contains(code) else {
                r.error = status.map { "HTTP \($0)" } ?? "No answer"
                return r
            }
            let parsed = SignalExtract.parse(data, preferJSON: !(signal.pointer ?? "").isEmpty)
            if let j = parsed.json { r.outline = JSONPointer.outline(j) }
            switch SignalExtract.value(signal, json: parsed.json, text: parsed.text) {
            case .value(var v):
                v.at = Date().timeIntervalSince1970
                v.stale = signal.staleAfter
                r.value = v
            case .problem(let why):
                r.error = why
            }
            return r
        }

        /// A URLError in a few words (its own description can carry the URL — and so a key).
        static func words(_ e: URLError) -> String {
            switch e.code {
            case .timedOut: return "Timed out"
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            case .cannotFindHost, .dnsLookupFailed: return "Host not found"
            case .cannotConnectToHost: return "Couldn't connect"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "Secure connection failed"
            case .cancelled: return "Cancelled"
            case .httpTooManyRedirects, .redirectToNonExistentLocation: return "Too many redirects"
            case .appTransportSecurityRequiresSecureConnection: return "Only https is allowed"
            default: return "Couldn't fetch (\(e.code.rawValue))"
            }
        }
    }
}
