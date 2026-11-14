//  LibraryAccess.swift — reading the library, and changing it without clobbering the app.
//
//  Every change goes through `perform(_:)`:
//    1. take StoreLock (the app holds it while it loads the library and opens its bridge);
//    2. the app answers on its AI bridge → release the lock and send the request there: the app
//       applies it through AppModel (UI updates live, wallpaper follows, a notice shows);
//    3. no app → run the same request here on library.json / wallpaper.json and write them
//       atomically before releasing the lock.
//  Either way the decision and the edit are LibraryOps.apply's (Shared/AI/LibraryOps.swift): the
//  app calls it on its in-memory library, this file on the files. The self-test's stand-in app
//  (`--fake-app`) calls it on an in-memory library, the way the real app keeps one, so the
//  routing is tested against a writer that would clobber.

import AppKit
import Foundation

enum Displays {
    /// The connected displays, built-in first, then left to right (DisplayRoster's order and keys).
    static func connected() -> [DisplayEntry] {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_FAKE_DISPLAYS"] {
            // Self-test: "KEY=Name,KEY2=Name 2"
            return fake.split(separator: ",").enumerated().map { i, kv in
                let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                return DisplayEntry(key: p[0], name: p.count > 1 ? p[1] : p[0], builtIn: i == 0)
            }
        }
        let screens = NSScreen.screens
        let keys = DisplayIdentity.keys(screens)
        var out: [(DisplayEntry, CGFloat, CGFloat)] = []
        for s in screens {
            guard let id = DisplayIdentity.displayID(s), let key = keys[id] else { continue }
            out.append((DisplayEntry(key: key, name: s.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0), s.frame.minX, s.frame.minY))
        }
        out.sort { a, b in
            if a.0.builtIn != b.0.builtIn { return a.0.builtIn }
            return a.1 != b.1 ? a.1 < b.1 : a.2 < b.2
        }
        return out.map(\.0)
    }
}

final class LibraryAccess {
    let store: SharedStore
    var dir: URL { store.baseDir }
    /// Who's asking (the MCP client's name), for the app's notices.
    var clientName: () -> String = { "AI" }

    private var defaultLibrary: Library?

    init(store: SharedStore) { self.store = store }

    /// The library as it is on disk (the app writes every change straight away). A missing
    /// library (DotStudio never opened) reads as the default one, as the app would create —
    /// the SAME one until it's written: its styles get fresh ids, and a tool resolves a style's
    /// id on one read and edits it on the next.
    func library() throws -> Library {
        switch store.loadLibrary() {
        case .loaded(let lib): return lib
        case .missing:
            if let d = defaultLibrary { return d }
            let d = DefaultPresets.makeLibrary()
            defaultLibrary = d
            return d
        case .corrupt(let backup):
            throw ToolError("DotStudio's library.json can't be read (a backup was saved as \(backup?.lastPathComponent ?? "—")). Open DotStudio to recover it; no changes were made.")
        }
    }

    func preset(_ idOrName: String) throws -> Preset {
        let lib = try library()
        // Styles this build can't draw (only custom effects, before the scene engine) still count.
        let all = lib.presets + lib.unknownPresets.map(\.preset)
        if let id = UUID(uuidString: idOrName), let p = all.first(where: { $0.id == id }) { return p }
        let matches = all.filter { $0.name.compare(idOrName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ToolError("\(matches.count) styles are named “\(idOrName)”; pass the id instead.",
                            details: ["ids": matches.map(\.id.uuidString)])
        }
        throw ToolError("No style \"\(idOrName)\". Call list_styles to see the library (ids or exact names).")
    }

    var appRunning: Bool { AIBridge.appRunning(store: dir) }

    /// Apply one change, routed to the running app or done here (see the header).
    func perform(_ req: BridgeRequest) throws -> (BridgeResponse, viaApp: Bool) {
        var req = req
        req.client = clientName()
        guard let lock = StoreLock.acquire(store: dir, timeout: 15) else {
            throw ToolError("DotStudio's library is busy (another process holds its lock). Try again in a moment.")
        }
        var lockHeld = true
        defer { if lockHeld { lock.release() } }
        switch AIBridge.send(BridgeRequest(op: .ping), store: dir, timeout: 3) {
        case .success:
            lock.release(); lockHeld = false
            switch AIBridge.send(req, store: dir, timeout: 20) {
            case .success(let r): return (r, true)
            case .failure(.notRunning): break    // quit just now: fall through to the file
            case .failure(.failed(let why)): throw ToolError("DotStudio is running but didn't apply the change: \(why)")
            }
            guard let again = StoreLock.acquire(store: dir, timeout: 15) else { throw ToolError("DotStudio's library is busy. Try again.") }
            defer { again.release() }
            return (try performOffline(req), false)
        case .failure(.notRunning):
            return (try performOffline(req), false)
        case .failure(.failed(let why)):
            throw ToolError("Couldn't reach DotStudio: \(why)")
        }
    }

    /// The change on the files, under the lock (the caller holds it).
    private func performOffline(_ req: BridgeRequest) throws -> BridgeResponse {
        var lib = try library()
        let settings = AISettings.load(store: dir)
        if req.op == .getSettings || req.op == .updateSettings || req.op == .appAction {
            var wall = Self.loadWallpaper(dir)
            var prefs = PrefsStore.load(dir)
            let before = prefs
            let r = SettingsExecutor.run(req, library: &lib, wallpaper: &wall, prefs: &prefs, store: store, ai: settings,
                                         live: SettingsExecutor.offlineSystem())
            guard r.ok, req.op == .updateSettings else { return r }
            if !store.save(lib) { throw ToolError("Couldn't write library.json: \(store.lastSaveError ?? "unknown error")") }
            Self.saveWallpaper(wall, dir)
            PrefsStore.save(prefs, changed: prefs.keys.filter { prefs[$0] != before[$0] }, dir)
            return r
        }
        if req.op == .ping { return BridgeResponse(ok: true, appVersion: "offline") }
        let json = Self.loadWallpaper(dir)
        var wall = WallpaperChoice(json: json)
        let before = wall
        var r = LibraryOps.apply(req, library: &lib, wallpaper: &wall, Self.context(dir, settings))
        guard r.ok else { return r }
        if !store.save(lib) { throw ToolError("Couldn't write library.json: \(store.lastSaveError ?? "unknown error")") }
        if wall != before { Self.saveWallpaper(wall.merged(into: json), dir) }
        // Only the running app draws the live wallpaper.
        if req.op == .setWallpaper, wall.enabled, let m = r.message { r.message = m + " It plays while DotStudio runs." }
        return r
    }

    /// What LibraryOps decides against here: the displays connected now, Settings ▸ AI, and the
    /// When rule lease the app last wrote.
    static func context(_ dir: URL, _ settings: AISettings) -> LibraryOps.Context {
        LibraryOps.Context(displays: Displays.connected(), settings: settings, live: SignalState.read(baseDir: dir))
    }

    static func loadWallpaper(_ dir: URL) -> JSONObject {
        guard let d = try? Data(contentsOf: AIStore.wallpaperURL(dir)), let o = JSON.parse(d) as? JSONObject else { return [:] }
        return o
    }

    static func saveWallpaper(_ o: JSONObject, _ dir: URL) {
        try? JSON.data(o, pretty: true).write(to: AIStore.wallpaperURL(dir), options: .atomic)
    }

    /// Record a style as the AI's own (delete_style may remove those without confirming).
    func markCreated(_ id: UUID) {
        guard let lock = StoreLock.acquire(store: dir, timeout: 5) else { return }
        defer { lock.release() }
        var c = AICreatedStyles.load(store: dir)
        if !c.ids.contains(id) { c.ids.append(id); c.save(store: dir) }
    }
}
