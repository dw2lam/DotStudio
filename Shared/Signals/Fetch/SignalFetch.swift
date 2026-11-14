//  SignalFetch.swift — what may be fetched, and fetching it (docs/signals-design.md §2).
//
//  APP AND dotstudio-mcp ONLY: project.yml excludes Signals/Fetch/** from the saver, which must
//  never touch the network. The app's SignalService schedules fetches; dotstudio-mcp's test_signal
//  fetches once (offline, a signal without a key).
//
//  Rules every fetch keeps: https only, GET only, no body, an ephemeral session (no cookies, no
//  cache), UA "DotStudio/<version>", 10 s timeout, 256 KB cap, at most 3 redirects each re-checked
//  against the same policy (and the key header dropped when the host changes). Signals an AI makes
//  can't reach localhost, *.local, or loopback / private / link-local / ULA addresses. A URL whose
//  query carries a key-like parameter is refused: keys go in `auth`, whose value only the Keychain
//  holds. Errors are short words ("HTTP 503", "Timed out") — never a URL, a header or a body.
//
//  Test hook (DEBUG builds only — compiled out of Release): DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1 also
//  allows http:// and https:// to 127.0.0.1 / localhost, so tools/mcp-selftest can serve a local
//  fixture. Every other refusal (http elsewhere, private and link-local addresses, key-like query
//  parameters) still holds with it on.

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
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network order
            let priv = b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1])) || b[0] >= 224
            return priv ? "Signals an assistant makes can't reach private, loopback or link-local addresses (\(h))." : nil
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            let loop = b[0..<15].allSatisfy { $0 == 0 } && (b[15] == 1 || b[15] == 0)
            let linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            let ula = (b[0] & 0xfe) == 0xfc
            let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
            if mapped { return privateHost("\(b[12]).\(b[13]).\(b[14]).\(b[15])") }
            return loop || linkLocal || ula || b[0] == 0xff ? "Signals an assistant makes can't reach private, loopback or link-local addresses (\(h))." : nil
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
        let delegate = FetchDelegate(signal: s, forAI: forAI, authHeader: s.auth?.placement == .header ? s.auth?.name : nil,
                                     originalHost: base.host?.lowercased(), started: Date(), completion: completion)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: req).resume()
        session.finishTasksAndInvalidate()
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
            completionHandler(next)
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
            guard let completion else { return }
            self.completion = nil
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            var r = SignalFetchResult(status: status, ms: ms, bytes: data.count, retryAfter: retryAfter)
            if tooBig { r.error = "Larger than 256 KB"; completion(r); return }
            if let refused { r.error = refused; completion(r); return }
            if let e = error as? URLError {
                r.error = Self.words(e)
                completion(r)
                return
            } else if error != nil {
                r.error = "Couldn't connect"
                completion(r)
                return
            }
            guard let code = status, (200..<300).contains(code) else {
                r.error = status.map { "HTTP \($0)" } ?? "No answer"
                completion(r)
                return
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
            completion(r)
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
