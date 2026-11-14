//  FakeApp.swift — `dotstudio-mcp --fake-app`: a stand-in for the running DotStudio app, for
//  tools/mcp-selftest. It behaves like the real app where it matters for clobbering: it takes
//  StoreLock while it loads library.json, keeps the library IN MEMORY, serves the AI bridge, and
//  writes its in-memory library back (every change, and every --clobber-ms) — so any edit that
//  bypassed the bridge would be lost and the self-test would see it.
//
//  args: [--hold-lock-ms N]  keep the lock N ms before loading (a slow launch)
//        [--clobber-ms N]    re-save the in-memory library every N ms (UI edits)
//  Settings requests run SettingsExecutor on its memory (prefs in <store>/app-prefs.json, as the
//  app keeps them under DOTSTUDIO_STORE_DIR); actions are acknowledged, never performed.
//  Prints "ready" when the bridge is up and "applied <op>" per request; exits at stdin EOF.

import Foundation

enum FakeApp {
    static func run(_ args: [String]) -> Never {
        func arg(_ name: String) -> Int? { args.firstIndex(of: name).flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } }
        let store = SharedStore(role: .app)
        let dir = store.baseDir
        guard let lock = StoreLock.acquire(store: dir, timeout: 30) else { print("lock failed"); exit(1) }
        if let ms = arg("--hold-lock-ms") { print("holding lock"); fflush(stdout); usleep(useconds_t(ms * 1000)) }
        var lib: Library
        switch store.loadLibrary() {
        case .loaded(let l): lib = l
        default: lib = DefaultPresets.makeLibrary()
        }
        store.save(lib)
        var wall = LibraryAccess.loadWallpaper(dir)
        var prefs = PrefsStore.load(dir)
        // What only the running app can read, as the real app would report it.
        let liveSystem: [String: JSONValue] = ["general.openAtLogin": .bool(false), "system.loginItemApproval": .string("off"),
                                               "system.screensaverInstalled": .bool(true), "system.screensaverChosen": .string("on 1 of 2 displays"),
                                               "system.startScreenSaverAfter": .number(20), "system.accessibilityForGuideMe": .bool(false)]
        let q = DispatchQueue(label: "fake-app")
        let server = AIBridge.Server(store: dir) { req, reply in
            q.async {
                var r: BridgeResponse
                if req.op == .getSettings || req.op == .updateSettings || req.op == .appAction {
                    // As the app keeps them under DOTSTUDIO_STORE_DIR: <store>/app-prefs.json.
                    let before = prefs
                    r = SettingsExecutor.run(req, library: &lib, wallpaper: &wall, prefs: &prefs, store: store,
                                             ai: AISettings.load(store: dir), live: liveSystem, appActions: true)
                    if r.ok { PrefsStore.save(prefs, changed: prefs.keys.filter { prefs[$0] != before[$0] }, dir) }
                    if r.ok, req.op == .appAction { r.message = "Did \(req.mode ?? "") (stand-in app)." }
                } else {
                    r = LibraryExecutor.run(req, library: &lib, wallpaper: &wall, displays: Displays.connected(),
                                            settings: AISettings.load(store: dir))
                }
                if r.ok, req.op != .ping {
                    store.save(lib)
                    LibraryAccess.saveWallpaper(wall, dir)
                }
                r.appVersion = "fake-app"
                print("applied \(req.op.rawValue) ok=\(r.ok) client=\(req.client ?? "-")")
                fflush(stdout)
                reply(r)
            }
        }
        guard server.start() else { print("bridge failed"); exit(1) }
        lock.release()
        print("ready")
        fflush(stdout)
        if let ms = arg("--clobber-ms") {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
            t.setEventHandler { store.save(lib) }
            t.resume()
            _clobber = t
        }
        while !FileHandle.standardInput.availableData.isEmpty {}
        server.stop()
        exit(0)
    }
    private static var _clobber: DispatchSourceTimer?
}
