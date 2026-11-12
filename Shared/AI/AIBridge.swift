//  AIBridge.swift — how dotstudio-mcp asks the RUNNING app to change the library.
//
//  The app holds the library in memory and writes library.json on every change; it never
//  re-reads the file. So while the app runs, a direct write from another process would be
//  silently overwritten by the app's next save. Instead the app listens on a Unix-domain
//  socket in the store (`<store>/.ai-bridge.sock`, mode 0600 — the store folder is the user's
//  own) and applies each request through AppModel, exactly as a click would: the UI updates
//  live, the wallpaper follows, and a notice shows.
//
//  Wire format: one JSON request per connection, newline-terminated; one JSON response back,
//  newline-terminated; the connection closes. No socket (or a stale one: ECONNREFUSED) means
//  the app isn't running, and dotstudio-mcp edits library.json itself under StoreLock — which
//  the app also holds while it loads the library and opens this socket, so the two can't
//  interleave. Neither side is sandboxed (project.yml: ENABLE_APP_SANDBOX NO).

import Foundation

struct BridgeRequest: Codable, Equatable {
    enum Op: String, Codable {
        case ping
        /// Add `preset` (new id) or replace the style with its id.
        case upsertStyle
        case deleteStyle
        case duplicateStyle
        /// `mode`: only | add | remove | night | dayOnly; `display`: one display's key (only).
        case setScreensaver
        /// `mode`: set | off | follow; `display`: one display's key (set).
        case setWallpaper
    }
    var op: Op
    var preset: Preset?
    var id: UUID?
    var name: String?
    var display: String?
    var mode: String?
    /// Who asks ("Claude", "Cursor"…), for the notice.
    var client: String?
}

struct BridgeResponse: Codable, Equatable {
    var ok: Bool
    var error: String?
    var id: UUID?
    var name: String?
    var appVersion: String?
    /// What happened, in a sentence (shown to the AI).
    var message: String?

    static func fail(_ error: String) -> BridgeResponse { BridgeResponse(ok: false, error: error) }
}

enum AIBridge {
    static let maxMessage = 8 << 20

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < maxMessage {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return out.isEmpty ? nil : out }
            if let nl = buf[0..<n].firstIndex(of: 10) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var d = data
        d.append(10)
        return d.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    // MARK: Client (dotstudio-mcp)

    enum ClientError: Error { case notRunning, failed(String) }

    /// Send one request to the running app. `.notRunning` when nobody listens.
    static func send(_ req: BridgeRequest, store: URL, timeout: Int = 15) -> Result<BridgeResponse, ClientError> {
        let path = AIStore.socketURL(store).path
        guard FileManager.default.fileExists(atPath: path) else { return .failure(.notRunning) }
        guard var addr = address(path) else { return .failure(.failed("socket path too long: \(path)")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed("socket() failed: errno \(errno)")) }
        defer { close(fd) }
        setTimeouts(fd, seconds: timeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            // ECONNREFUSED: a socket file left by an app that quit or crashed.
            return (errno == ECONNREFUSED || errno == ENOENT) ? .failure(.notRunning)
                : .failure(.failed("connect() failed: errno \(errno)"))
        }
        guard let body = try? JSONEncoder().encode(req), writeAll(fd, body) else {
            return .failure(.failed("couldn't send the request to DotStudio"))
        }
        guard let line = readLine(fd) else {
            return .failure(.failed("DotStudio didn't answer within \(timeout) s"))
        }
        guard let resp = try? JSONDecoder().decode(BridgeResponse.self, from: line) else {
            return .failure(.failed("DotStudio sent an unreadable answer"))
        }
        return .success(resp)
    }

    /// Is the app's bridge answering right now?
    static func appRunning(store: URL) -> Bool {
        if case .success(let r) = send(BridgeRequest(op: .ping), store: store, timeout: 3) { return r.ok }
        return false
    }

    // MARK: Server (the app; the self-test's stand-in app)

    final class Server {
        typealias Handler = (BridgeRequest, @escaping (BridgeResponse) -> Void) -> Void
        private let path: String
        private let handler: Handler
        private var fd: Int32 = -1
        private var thread: Thread?

        init(store: URL, handler: @escaping Handler) {
            path = AIStore.socketURL(store).path
            self.handler = handler
        }

        /// Bind and start accepting on a background thread. False = couldn't (path too long, …).
        @discardableResult
        func start() -> Bool {
            guard var addr = AIBridge.address(path) else { return false }
            unlink(path)
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { return false }
            let old = umask(0o077)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(old)
            guard rc == 0, listen(s, 8) == 0 else { close(s); return false }
            chmod(path, 0o600)
            fd = s
            let t = Thread { [weak self] in self?.acceptLoop(s) }
            t.name = "DotStudio AI bridge"
            t.qualityOfService = .utility
            thread = t
            t.start()
            return true
        }

        func stop() {
            if fd >= 0 { close(fd); fd = -1 }
            unlink(path)
        }

        private func acceptLoop(_ s: Int32) {
            while true {
                let c = accept(s, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return                       // closed by stop()
                }
                AIBridge.setTimeouts(c, seconds: 30)
                DispatchQueue.global(qos: .utility).async { [handler] in
                    guard let line = AIBridge.readLine(c),
                          let req = try? JSONDecoder().decode(BridgeRequest.self, from: line) else {
                        _ = AIBridge.writeAll(c, (try? JSONEncoder().encode(BridgeResponse.fail("unreadable request"))) ?? Data())
                        close(c)
                        return
                    }
                    handler(req) { resp in
                        _ = AIBridge.writeAll(c, (try? JSONEncoder().encode(resp)) ?? Data())
                        close(c)
                    }
                }
            }
        }
    }
}
