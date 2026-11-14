//  Server.swift — the MCP stdio transport and JSON-RPC 2.0 dispatch.
//
//  Hand-rolled on purpose (no SDK): stdio is the only transport needed, the protocol surface
//  is small (initialize, ping, tools/*, resources/*, prompts/*), the official Swift SDK is
//  still 0.x with API churn and wants Swift 6 language mode while this project builds in Swift 5,
//  and a dependency here would ship inside every DotStudio.app. Messages are newline-delimited
//  JSON on stdin/stdout; everything else (logs, stray prints from shared code) goes to stderr.

import Foundation

/// A tool failure the model can act on: returned as a tool result with isError, not a
/// JSON-RPC error, so the model sees the message and can correct its call.
struct ToolError: Error {
    let message: String
    var details: JSONObject? = nil
    init(_ message: String, details: JSONObject? = nil) { self.message = message; self.details = details }
}

/// What a tool returns: text for every client, structured JSON for clients that read it,
/// images (PNG) for previews.
struct ToolResult {
    var text: String
    var structured: JSONObject?
    var images: [Data] = []
    var isError = false

    static func ok(_ text: String, _ structured: JSONObject? = nil, images: [Data] = []) -> ToolResult {
        ToolResult(text: text, structured: structured, images: images)
    }

    var json: JSONObject {
        var content: [JSONObject] = [["type": "text", "text": text]]
        for png in images { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
        if let structured, !isError {
            // Older clients read only `content`: the structured result is there too, as JSON text.
            content.append(["type": "text", "text": JSON.string(structured, pretty: true)])
        }
        var r: JSONObject = ["content": content, "isError": isError]
        if let structured { r["structuredContent"] = structured }
        return r
    }
}

struct Tool {
    let name: String
    let title: String
    let description: String
    let input: JSONObject
    var readOnly = false
    var destructive = false
    var idempotent = false
    var openWorld = false
    let run: (JSONObject) throws -> ToolResult

    var listing: JSONObject {
        ["name": name, "title": title, "description": description, "inputSchema": input,
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                         "idempotentHint": idempotent, "openWorldHint": openWorld]]
    }
}

/// Schema helpers for terse tool definitions.
enum S {
    static func obj(_ props: JSONObject, required: [String] = [], extra: Bool = false) -> JSONObject {
        var o: JSONObject = ["type": "object", "properties": props, "additionalProperties": extra]
        if !required.isEmpty { o["required"] = required }
        return o
    }
    static func str(_ d: String, enum e: [String]? = nil, pattern: String? = nil, max: Int? = nil) -> JSONObject {
        var o: JSONObject = ["type": "string", "description": d]
        if let e { o["enum"] = e }
        if let pattern { o["pattern"] = pattern }
        if let max { o["maxLength"] = max }
        return o
    }
    static func num(_ d: String, min: Double? = nil, max: Double? = nil, integer: Bool = false) -> JSONObject {
        var o: JSONObject = ["type": integer ? "integer" : "number", "description": d]
        if let min { o["minimum"] = min }
        if let max { o["maximum"] = max }
        return o
    }
    static func bool(_ d: String) -> JSONObject { ["type": "boolean", "description": d] }
    static func arr(_ items: JSONObject, _ d: String, min: Int? = nil, max: Int? = nil) -> JSONObject {
        var o: JSONObject = ["type": "array", "items": items, "description": d]
        if let min { o["minItems"] = min }
        if let max { o["maxItems"] = max }
        return o
    }
    static let uuid = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    static let color: JSONObject = [
        "type": "object", "description": "A colour, display sRGB 0…1 (alpha optional, default 1).",
        "properties": ["r": num("red 0…1", min: 0, max: 1), "g": num("green 0…1", min: 0, max: 1),
                       "b": num("blue 0…1", min: 0, max: 1), "a": num("alpha 0…1", min: 0, max: 1)],
        "required": ["r", "g", "b"], "additionalProperties": false]
}

final class MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    var tools: [Tool] = []
    var resources: () -> [JSONObject] = { [] }
    var readResource: (String) throws -> JSONObject = { _ in throw ToolError("no resources") }
    var prompts: () -> [JSONObject] = { [] }
    var getPrompt: (String, [String: String]) throws -> JSONObject = { _, _ in throw ToolError("no prompts") }
    var instructions = ""
    /// The client's name from initialize ("claude-ai", "cursor"…), for notices in the app.
    private(set) var clientName = "AI"

    private let out: FileHandle
    private let writeLock = NSLock()
    private let work = DispatchQueue(label: "dotstudio-mcp.work")

    init() {
        // The protocol owns the real stdout; anything else printed goes to stderr.
        let protocolFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        out = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)
    }

    func log(_ s: String) { FileHandle.standardError.write(Data(("[dotstudio-mcp] " + s + "\n").utf8)) }

    private func send(_ msg: JSONObject) {
        var d = JSON.data(msg)
        d.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        out.write(d)
    }

    /// Read stdin until EOF; requests run one at a time in order on a work queue.
    func run() -> Never {
        let input = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) else { continue }
                let data = Data(line)
                // ping skips the queue: a client's keep-alive must not wait behind a slow
                // render or preview, or it may decide the server hung.
                if let o = JSON.parse(data) as? JSONObject, o["method"] as? String == "ping", let id = o["id"] {
                    send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
                    continue
                }
                work.async { self.handle(data) }
            }
        }
        work.sync {}
        exit(0)
    }

    private func handle(_ data: Data) {
        guard let any = JSON.parse(data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = any as? [Any] {   // 2025-03-26 batches: answer each
            for m in batch { if let o = m as? JSONObject { handleMessage(o) } }
            return
        }
        guard let msg = any as? JSONObject else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
            return
        }
        handleMessage(msg)
    }

    private func handleMessage(_ msg: JSONObject) {
        guard let method = msg["method"] as? String else { return }   // a response to us: ignore
        let id = msg["id"]
        let params = msg["params"] as? JSONObject ?? [:]
        guard let id else { return }   // notifications (initialized, cancelled…) need no answer
        do {
            let result = try dispatch(method, params)
            send(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let e as RPCError {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]])
        } catch let e as ToolError {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": e.message]])
        } catch {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
        }
    }

    struct RPCError: Error { let code: Int; let message: String }

    private func dispatch(_ method: String, _ p: JSONObject) throws -> JSONObject {
        switch method {
        case "initialize":
            let asked = p["protocolVersion"] as? String ?? Self.protocolVersions[0]
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            if let info = p["clientInfo"] as? JSONObject, let n = info["name"] as? String { clientName = Self.friendly(n) }
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return ["protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false],
                                     "resources": ["listChanged": false, "subscribe": false],
                                     "prompts": ["listChanged": false],
                                     "logging": [:]],
                    "serverInfo": ["name": "dotstudio", "title": "DotStudio", "version": appVersion],
                    "instructions": instructions]
        case "ping":
            return [:]
        case "logging/setLevel":
            return [:]
        case "tools/list":
            return ["tools": tools.map(\.listing)]
        case "tools/call":
            guard let name = p["name"] as? String else { throw RPCError(code: -32602, message: "tools/call needs a name") }
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool \"\(name)\". Call tools/list to see them.")
            }
            let args = p["arguments"] as? JSONObject ?? [:]
            if p["arguments"] != nil, !(p["arguments"] is JSONObject), !(p["arguments"] is NSNull) {
                return ToolResult(text: "arguments must be an object", structured: nil, isError: true).json
            }
            let problems = Schema.validate(args, tool.input)
            if !problems.isEmpty {
                let text = "Invalid arguments for \(name):\n- " + problems.joined(separator: "\n- ")
                    + "\nSee the tool's inputSchema (tools/list) for the expected shape."
                return ToolResult(text: text, structured: ["error": "invalid_arguments", "problems": problems], isError: true).json
            }
            do {
                return try tool.run(args).json
            } catch let e as ToolError {
                var s: JSONObject = ["error": e.message]
                if let d = e.details { s["details"] = d }
                return ToolResult(text: e.message + (e.details.map { "\n" + JSON.string($0, pretty: true) } ?? ""),
                                  structured: s, isError: true).json
            }
        case "resources/list":
            return ["resources": resources()]
        case "resources/templates/list":
            return ["resourceTemplates": [["uriTemplate": "dotstudio://guides/{id}", "name": "guide",
                                           "title": "DotStudio guide", "mimeType": "text/markdown",
                                           "description": "Any guide by id (see list_guides), e.g. dotstudio://guides/style/dotstudio"]]]
        case "resources/read":
            guard let uri = p["uri"] as? String else { throw RPCError(code: -32602, message: "resources/read needs a uri") }
            do { return try readResource(uri) } catch let e as ToolError {
                throw RPCError(code: -32002, message: e.message)
            }
        case "prompts/list":
            return ["prompts": prompts()]
        case "prompts/get":
            guard let name = p["name"] as? String else { throw RPCError(code: -32602, message: "prompts/get needs a name") }
            var args: [String: String] = [:]
            for (k, v) in p["arguments"] as? JSONObject ?? [:] { args[k] = v as? String ?? JSON.string(v) }
            do { return try getPrompt(name, args) } catch let e as ToolError {
                throw RPCError(code: -32602, message: e.message)
            }
        case "completion/complete":
            return ["completion": ["values": [], "hasMore": false]]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    static func friendly(_ client: String) -> String {
        let c = client.lowercased()
        if c.contains("claude") { return "Claude" }
        if c.contains("cursor") { return "Cursor" }
        if c.contains("code") && c.contains("visual") || c.contains("vscode") { return "VS Code" }
        if c.contains("codex") { return "Codex" }
        return client.isEmpty ? "AI" : client
    }
}
