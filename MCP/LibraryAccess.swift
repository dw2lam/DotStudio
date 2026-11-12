//  LibraryAccess.swift — reading the library, and changing it without clobbering the app.
//
//  Every change goes through `perform(_:)`:
//    1. take StoreLock (the app holds it while it loads the library and opens its bridge);
//    2. the app answers on its AI bridge → release the lock and send the request there: the app
//       applies it through AppModel (UI updates live, wallpaper follows, a notice shows);
//    3. no app → run the same request here (`LibraryExecutor`) on library.json / wallpaper.json
//       and write them atomically before releasing the lock.
//  The self-test's stand-in app (`--fake-app`) runs LibraryExecutor on an in-memory library, the
//  way the real app keeps one, so the routing is tested against a writer that would clobber.

import AppKit
import Foundation

struct DisplayEntry {
    let key: String
    let name: String
    let builtIn: Bool
}

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

    init(store: SharedStore) { self.store = store }

    /// The library as it is on disk (the app writes every change straight away). A missing
    /// library (DotStudio never opened) reads as the default one, as the app would create.
    func library() throws -> Library {
        switch store.loadLibrary() {
        case .loaded(let lib): return lib
        case .missing: return DefaultPresets.makeLibrary()
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
        var wall = Self.loadWallpaper(dir)
        let settings = AISettings.load(store: dir)
        let r = LibraryExecutor.run(req, library: &lib, wallpaper: &wall, displays: Displays.connected(), settings: settings)
        guard r.ok else { return r }
        if !store.save(lib) { throw ToolError("Couldn't write library.json: \(store.lastSaveError ?? "unknown error")") }
        if req.op == .setWallpaper || req.op == .deleteStyle { Self.saveWallpaper(wall, dir) }
        return r
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

/// One BridgeRequest applied to a library (and wallpaper.json, as loose JSON so fields this
/// build doesn't know survive) — what the app does for the same request, minus its UI.
enum LibraryExecutor {
    static func run(_ req: BridgeRequest, library lib: inout Library, wallpaper wall: inout JSONObject,
                    displays: [DisplayEntry], settings: AISettings) -> BridgeResponse {
        switch req.op {
        case .ping:
            return BridgeResponse(ok: true, appVersion: "offline")
        case .upsertStyle:
            guard var p = req.preset else { return .fail("no style given") }
            if let i = lib.presets.firstIndex(where: { $0.id == p.id }) {
                lib.presets[i] = p
                return BridgeResponse(ok: true, id: p.id, name: p.name, message: "Updated “\(p.name)”.")
            }
            p.name = lib.uniqueName(p.name)
            lib.presets.append(p)
            return BridgeResponse(ok: true, id: p.id, name: p.name, message: "Added “\(p.name)” to the library.")
        case .deleteStyle:
            guard let id = req.id, let p = lib.presets.first(where: { $0.id == id }) else { return .fail("no such style") }
            guard lib.presets.count > 1 else { return .fail("“\(p.name)” is the only style; the library can't be empty.") }
            lib.removePreset(id)
            // A wallpaper showing it stops; displays that had it as their own go back to the shared pick.
            if (wall["presetID"] as? String).flatMap(UUID.init) == id { wall["enabled"] = false }
            if var pins = wall["displayStyles"] as? JSONObject {
                pins = pins.filter { (($0.value as? JSONObject)?["presetID"] as? String).flatMap(UUID.init) != id }
                wall["displayStyles"] = pins
            }
            return BridgeResponse(ok: true, id: id, name: p.name, message: "Deleted “\(p.name)”.")
        case .duplicateStyle:
            guard let id = req.id, let copy = lib.duplicatePreset(id, name: req.name) else { return .fail("no such style") }
            return BridgeResponse(ok: true, id: copy.id, name: copy.name, message: "Duplicated as “\(copy.name)”.")
        case .setScreensaver:
            guard settings.allowPlaybackChanges else { return .fail(playbackOff) }
            return screensaver(req, &lib, displays)
        case .setWallpaper:
            guard settings.allowPlaybackChanges else { return .fail(playbackOff) }
            return wallpaper(req, &lib, &wall, displays)
        }
    }

    static let playbackOff = "The user has turned off “Let AI change what plays” in DotStudio ▸ Settings ▸ AI. Styles can still be created; ask the user to set it themselves, or to turn that setting on."

    private static func screensaver(_ req: BridgeRequest, _ lib: inout Library, _ displays: [DisplayEntry]) -> BridgeResponse {
        let mode = req.mode ?? "only"
        func name(_ id: UUID?) -> String { id.flatMap { i in lib.presets.first { $0.id == i }?.name } ?? "—" }
        if mode == "unpin" {
            guard let key = req.display else { return .fail("unpin needs a display") }
            lib.displayStyles?[key] = nil
            if lib.displayStyles?.isEmpty == true { lib.displayStyles = nil }
            return BridgeResponse(ok: true, message: "That display plays the screensaver lineup again.")
        }
        var l = lib.screensaverLineup
        if mode == "dayOnly" {
            l.night = nil
            lib.applyLineup(l)
            return BridgeResponse(ok: true, message: "No separate night style: the lineup plays all day.")
        }
        guard let id = req.id, lib.presets.contains(where: { $0.id == id }) else { return .fail("no such style") }
        switch mode {
        case "only":
            if let key = req.display {
                guard let d = displays.first(where: { $0.key == key }) else { return .fail("No connected display has the key \(key). Call list_displays.") }
                var pins = lib.displayStyles ?? [:]
                pins[key] = DisplayPin(presetID: id, name: d.name)
                lib.displayStyles = pins
                return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is now the screensaver on \(d.name).")
            }
            lib.displayStyles = nil
            lib.playAsScreensaver(id)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is now the screensaver on every display.")
        case "add":
            if !l.playlist.contains(id) { l.playlist.append(id) }
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” joined the screensaver rotation (\(lib.screensaverLineup.playlist.count) styles).")
        case "remove":
            guard l.playlist.count > 1, let i = l.playlist.firstIndex(of: id) else {
                return .fail("“\(name(id))” isn't in the rotation, or it's the only style playing (something always plays).")
            }
            l.playlist.remove(at: i)
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” left the rotation.")
        case "night":
            l.night = id
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” now plays after sunset.")
        case "dayOnly":
            l.night = nil
            lib.applyLineup(l)
            return BridgeResponse(ok: true, message: "No separate night style: the lineup plays all day.")
        default:
            return .fail("unknown screensaver mode \(mode)")
        }
    }

    private static func wallpaper(_ req: BridgeRequest, _ lib: inout Library, _ wall: inout JSONObject,
                                  _ displays: [DisplayEntry]) -> BridgeResponse {
        let mode = req.mode ?? "set"
        func name(_ id: UUID?) -> String { id.flatMap { i in lib.presets.first { $0.id == i }?.name } ?? "—" }
        switch mode {
        case "off":
            wall["enabled"] = false
            return BridgeResponse(ok: true, message: "The live wallpaper is off.")
        case "follow":
            wall["enabled"] = true
            wall["followsScreensaver"] = true
            return BridgeResponse(ok: true, message: "The live wallpaper now matches the screensaver.")
        case "set", "unpin":
            var pins = wall["displayStyles"] as? JSONObject ?? [:]
            if mode == "unpin" {
                guard let key = req.display else { return .fail("unpin needs a display") }
                pins[key] = nil
                wall["displayStyles"] = pins
                return BridgeResponse(ok: true, message: "That display shows the shared wallpaper again.")
            }
            guard let id = req.id, lib.presets.contains(where: { $0.id == id }) else { return .fail("no such style") }
            if let key = req.display {
                guard let d = displays.first(where: { $0.key == key }) else { return .fail("No connected display has the key \(key). Call list_displays.") }
                pins[key] = ["presetID": id.uuidString, "name": d.name]
                wall["displayStyles"] = pins
                if (wall["enabled"] as? Bool) != true || (wall["followsScreensaver"] as? Bool) == true {
                    let shared = (wall["presetID"] as? String).flatMap(UUID.init).flatMap { i in lib.presets.contains { $0.id == i } ? i : nil }
                    wall["presetID"] = (shared ?? lib.activeID ?? id).uuidString
                }
                wall["enabled"] = true
                wall["followsScreensaver"] = false
                return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is the live wallpaper on \(d.name) (starts when DotStudio runs).")
            }
            wall["displayStyles"] = JSONObject()       // "All Displays"
            wall["enabled"] = true
            wall["presetID"] = id.uuidString
            wall["followsScreensaver"] = false
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is the live wallpaper (it plays while DotStudio runs).")
        default:
            return .fail("unknown wallpaper mode \(mode)")
        }
    }
}
