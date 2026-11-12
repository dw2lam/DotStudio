//  ClaudeDesktopConfig.swift — "Add to Claude Desktop" (Settings ▸ AI).
//
//  Merges `mcpServers.dotstudio` into Claude Desktop's claude_desktop_config.json without
//  touching anything else in it: other servers, preferences and unknown keys are kept. The
//  existing file is backed up first (claude_desktop_config.json.dotstudio-backup-<stamp>), the
//  new one is written atomically, and a file that isn't valid JSON is never overwritten. The
//  app isn't sandboxed, so it may write there; the path is injectable for the self-test, which
//  must never touch the real file.

import Foundation

enum ClaudeDesktopConfig {
    static let serverKey = "dotstudio"

    /// ~/Library/Application Support/Claude/claude_desktop_config.json
    static var defaultURL: URL {
        SharedStore.realHome.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// The entry DotStudio adds.
    static func entry(command: String) -> [String: Any] {
        ["command": command, "args": [String]()]
    }

    /// The `mcpServers` JSON for clients that take a snippet (Cursor, VS Code use the same shape).
    static func snippet(command: String) -> String {
        let obj: [String: Any] = ["mcpServers": [serverKey: entry(command: command)]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `claude mcp add` for Claude Code.
    static func claudeCodeCommand(command: String) -> String {
        "claude mcp add \(serverKey) -- \"\(command)\""
    }

    enum Outcome: Equatable {
        /// Written; `backup` is the previous file (nil when there was none).
        case added(backup: URL?)
        /// Already there with this exact command: nothing written.
        case unchanged
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notJSON(String)
        case writeFailed(String)
        var description: String {
            switch self {
            case .notJSON(let why): return "Claude Desktop's config file isn't valid JSON (\(why)), so DotStudio left it alone. Copy the snippet and add it by hand."
            case .writeFailed(let why): return "Couldn't write Claude Desktop's config: \(why)"
            }
        }
    }

    /// Is `mcpServers.dotstudio` present (with any command)?
    static func installedCommand(at url: URL = defaultURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let mine = servers[serverKey] as? [String: Any] else { return nil }
        return mine["command"] as? String
    }

    /// Merge the entry into the file at `url` (created, with its folder, when missing).
    static func install(command: String, at url: URL = defaultURL, now: Date = Date()) -> Result<Outcome, Failure> {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        var existing: Data?
        if let data = try? Data(contentsOf: url) {
            existing = data
            let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                do {
                    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return .failure(.notJSON("its top level isn't an object"))
                    }
                    root = obj
                } catch {
                    return .failure(.notJSON((error as NSError).localizedDescription))
                }
            }
        }
        if let servers = root["mcpServers"], !(servers is [String: Any]) {
            return .failure(.notJSON("mcpServers isn't an object"))
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let mine = servers[serverKey] as? [String: Any], mine["command"] as? String == command,
           (mine["args"] as? [Any])?.isEmpty ?? true {
            return .success(.unchanged)
        }
        var mine = servers[serverKey] as? [String: Any] ?? [:]
        for (k, v) in entry(command: command) { mine[k] = v }
        servers[serverKey] = mine
        root["mcpServers"] = servers

        var backup: URL?
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd-HHmmss"
                f.locale = Locale(identifier: "en_US_POSIX")
                let b = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".dotstudio-backup-" + f.string(from: now))
                try? fm.removeItem(at: b)
                try existing.write(to: b, options: .atomic)
                backup = b
            }
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed((error as NSError).localizedDescription))
        }
        return .success(.added(backup: backup))
    }
}
