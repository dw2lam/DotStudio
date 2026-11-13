//  AIStore.swift — the files the AI integration keeps next to library.json.
//
//  Compiled into the app and the `dotstudio-mcp` helper only (the saver excludes Shared/AI).
//
//    <store>/library.json          the library (SharedStore) — written by the app while it runs,
//                                  by dotstudio-mcp under `.library.lock` while it doesn't
//    <store>/wallpaper.json        the live wallpaper's settings (app-owned; see WallpaperPower)
//    <store>/.library.lock         flock(2) lock: "who may read-modify-write library.json now"
//    <store>/.ai-bridge.sock       the running app's AI bridge (AIBridge.swift)
//    <store>/ai-settings.json      what the user allows the AI to do (Settings ▸ AI; app-written)
//    <store>/ai-created.json       ids of the styles the AI created (dotstudio-mcp-written)
//    <store>/guides/*.md           the user's own guides (brand guides…), listed for the AI
//    <store>/scenes/<id>/          custom scene packages (CustomScenes, engine side)
//    <store>/engines/<id>/<ver>/   pulled engines (engine side)

import Foundation

enum AIStore {
    static func lockURL(_ store: URL) -> URL { store.appendingPathComponent(".library.lock") }
    static func socketURL(_ store: URL) -> URL { store.appendingPathComponent(".ai-bridge.sock") }
    static func settingsURL(_ store: URL) -> URL { store.appendingPathComponent("ai-settings.json") }
    static func createdURL(_ store: URL) -> URL { store.appendingPathComponent("ai-created.json") }
    static func guidesDir(_ store: URL) -> URL { store.appendingPathComponent("guides", isDirectory: true) }
    static func scenesDir(_ store: URL) -> URL { CustomScenes.scenesDir(store) }
    static func enginesDir(_ store: URL) -> URL { CustomScenes.enginesDir(store) }
    static func wallpaperURL(_ store: URL) -> URL { store.appendingPathComponent("wallpaper.json") }
}

/// What the user lets the AI do (Settings ▸ AI). Missing file = the defaults.
struct AISettings: Codable, Equatable {
    /// The AI may change what plays (screensaver lineup, per-display styles, live wallpaper).
    /// Styles in the library can always be created and edited; this guards what's on screen.
    var allowPlaybackChanges: Bool = true
    /// Each change the AI makes to what plays shows a small notice in the app (with Undo).
    var showNotices: Bool = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowPlaybackChanges = (try? c.decodeIfPresent(Bool.self, forKey: .allowPlaybackChanges)) ?? nil ?? true
        showNotices = (try? c.decodeIfPresent(Bool.self, forKey: .showNotices)) ?? nil ?? true
    }

    static func load(store: URL) -> AISettings {
        guard let data = try? Data(contentsOf: AIStore.settingsURL(store)),
              let s = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        return s
    }

    func save(store: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: AIStore.settingsURL(store), options: .atomic)
    }
}

/// The styles the AI made (delete_style removes only these unless the user confirms).
struct AICreatedStyles: Codable, Equatable {
    var ids: [UUID] = []

    static func load(store: URL) -> AICreatedStyles {
        guard let data = try? Data(contentsOf: AIStore.createdURL(store)),
              let s = try? JSONDecoder().decode(AICreatedStyles.self, from: data) else { return AICreatedStyles() }
        return s
    }

    func save(store: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: AIStore.createdURL(store), options: .atomic)
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}

/// An advisory flock(2) on `<store>/.library.lock`. Held by the app while it loads the library
/// and opens its AI bridge (so dotstudio-mcp never writes a file the app is about to read into
/// memory), and by dotstudio-mcp for a whole read-modify-write while the app isn't running.
/// The kernel drops it when the process exits, so a crash never leaves it stuck.
final class StoreLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Waits up to `timeout` seconds; nil = still held by someone else (or no store folder).
    static func acquire(store: URL, timeout: TimeInterval = 10) -> StoreLock? {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let fd = open(AIStore.lockURL(store).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { close(fd); return nil }
            usleep(20_000)
        }
        return StoreLock(fd: fd)
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
