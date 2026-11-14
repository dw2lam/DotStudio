//  LibraryOps.swift — every library change an assistant asks for, decided ONCE.
//
//  dotstudio-mcp sends each change (BridgeRequest) to the running app when there is one
//  (App/AIBridgeHost) and applies it to library.json / wallpaper.json itself when there isn't
//  (MCP/LibraryAccess). Both call `LibraryOps.apply` — the validation, the Settings ▸ AI gates,
//  the refusal messages and the edit itself — on a library and a wallpaper choice:
//    • the app on copies of its in-memory library and WallpaperController's settings, then adopts
//      them through AppModel / WallpaperController (save, live wallpaper, signals) and shows its
//      notice with Undo;
//    • dotstudio-mcp (and the self-test's stand-in app) on the files, under StoreLock.
//  So a request lands the same way whichever path takes it. The settings requests (get/update
//  _settings, app_action) are AppSettings' (Shared/AI/AppSettings.swift); test_signal is a fetch.
//
//  App and dotstudio-mcp only: the saver target excludes Shared/AI/**.

import Foundation

/// A connected display as an assistant addresses it (list_displays): its stable key
/// (DisplayIdentity / DisplayRoster), its name, whether it's the built-in one.
struct DisplayEntry: Equatable {
    let key: String
    let name: String
    let builtIn: Bool
}

/// The live wallpaper fields an assistant's requests change — the app's WallpaperSettings
/// (App/WallpaperPower.swift) has these and more (frame rate, quality, the lock-screen picture);
/// dotstudio-mcp keeps wallpaper.json as loose JSON and merges these back (`merged(into:)`), so
/// fields this build doesn't know survive.
struct WallpaperChoice: Equatable {
    var enabled = false
    /// The shared pick: every display without a style of its own.
    var presetID: UUID?
    /// "Same as Screensaver": each display shows what its screensaver shows.
    var followsScreensaver = false
    /// Displays with a wallpaper style of their own (display key → pin).
    var displayStyles: [String: DisplayPin] = [:]

    init(enabled: Bool = false, presetID: UUID? = nil, followsScreensaver: Bool = false,
         displayStyles: [String: DisplayPin] = [:]) {
        self.enabled = enabled
        self.presetID = presetID
        self.followsScreensaver = followsScreensaver
        self.displayStyles = displayStyles
    }

    /// From wallpaper.json's object (as WallpaperSettings decodes it: missing or bad fields →
    /// their defaults).
    init(json o: [String: Any]) {
        enabled = (o["enabled"] as? Bool) ?? false
        presetID = (o["presetID"] as? String).flatMap(UUID.init)
        followsScreensaver = (o["followsScreensaver"] as? Bool) ?? false
        if let pins = o["displayStyles"], JSONSerialization.isValidJSONObject(pins),
           let d = try? JSONSerialization.data(withJSONObject: pins),
           let decoded = try? JSONDecoder().decode([String: DisplayPin].self, from: d) {
            displayStyles = decoded
        }
    }

    /// wallpaper.json's object with these fields written over it (encoded as WallpaperSettings
    /// encodes them: no presetID key while there's none, no displayStyles while empty).
    func merged(into json: [String: Any]) -> [String: Any] {
        var o = json
        o["enabled"] = enabled
        if let presetID { o["presetID"] = presetID.uuidString } else { o.removeValue(forKey: "presetID") }
        o["followsScreensaver"] = followsScreensaver
        if displayStyles.isEmpty {
            o.removeValue(forKey: "displayStyles")
        } else if let d = try? JSONEncoder().encode(displayStyles),
                  let pins = try? JSONSerialization.jsonObject(with: d) {
            o["displayStyles"] = pins
        }
        return o
    }

    // MARK: Pure picks (App/WallpaperPower.swift's WallpaperPick forwards here)

    /// The shared pick: the chosen style — or, while following the screensaver, what the
    /// screensaver's lineup shows now. nil = none (no pick, or the pick was deleted).
    func sharedPick(_ lib: Library, now: Date = Date(), live: SignalState?) -> Preset? {
        if followsScreensaver {
            return lib.presets.isEmpty ? nil : Playback.effectivePreset(in: lib, now: now, live: live)
        }
        guard let id = presetID else { return nil }
        return lib.presets.first { $0.id == id }
    }

    /// Leaving "Same as Screensaver" by giving one display a wallpaper of its own: nothing else on
    /// screen changes. The shared pick becomes what the lineup shows now, every display whose
    /// screensaver has a style of its own keeps it as its wallpaper (replacing wallpaper pins left
    /// from before syncing, which weren't on screen), and then `display` gets `pin`.
    func leavingSync(_ lib: Library, now: Date = Date(), live: SignalState?, pin: DisplayPin, display: String) -> WallpaperChoice {
        var s = self
        if let shown = sharedPick(lib, now: now, live: live) { s.presetID = shown.id }
        s.followsScreensaver = false
        let ids = Set(lib.presets.map(\.id))
        var pins = (lib.displayStyles ?? [:]).filter { ids.contains($0.value.presetID) }
        pins[display] = pin
        s.displayStyles = pins
        return s
    }

    /// The shared pick was just deleted (`lib`: after the delete). While a connected display still
    /// plays a wallpaper of its own, the others move to the screensaver's active style (else to
    /// that surviving style) rather than the whole wallpaper stopping. nil = nothing survives.
    static func sharedReplacement(pins: [String: DisplayPin], _ lib: Library, connected: [String]) -> UUID? {
        let ids = Set(lib.presets.map(\.id))
        let survivors = connected.compactMap { pins[$0]?.presetID }.filter(ids.contains)
        guard let first = survivors.first else { return nil }
        return lib.activeID.flatMap { ids.contains($0) ? $0 : nil } ?? first
    }

    /// The pins whose style still exists.
    func pruned(_ lib: Library) -> WallpaperChoice {
        var s = self
        let ids = Set(lib.presets.map(\.id))
        s.displayStyles = s.displayStyles.filter { ids.contains($0.value.presetID) }
        return s
    }

    /// The style `id` was deleted from `lib` (`lib`: after the delete) — the gallery's Delete and
    /// delete_style alike: a wallpaper showing exactly it as the shared pick moves to
    /// `sharedReplacement` while a connected display still plays one of its own, else stops; one
    /// matching the screensaver is left alone (its style is whatever the lineup shows now).
    /// Displays that had it as their own go back to the shared pick.
    mutating func styleDeleted(_ id: UUID, in lib: Library, connected: [String]) {
        if enabled, !followsScreensaver, presetID == id {
            if let next = Self.sharedReplacement(pins: displayStyles, lib, connected: connected) {
                presetID = next
            } else {
                enabled = false
            }
        }
        self = pruned(lib)
    }

    /// Whether going from `old` to this only took display pins away (nothing new to start: the
    /// app doesn't un-pause or restart a wallpaper for it).
    func onlyUnpins(from old: WallpaperChoice) -> Bool {
        enabled == old.enabled && presetID == old.presetID && followsScreensaver == old.followsScreensaver
            && displayStyles.allSatisfy { old.displayStyles[$0.key] == $0.value }
    }
}

enum LibraryOps {
    /// What a change is decided against, besides the library and the wallpaper.
    struct Context {
        /// The displays connected now (DisplayRoster in the app; NSScreen in dotstudio-mcp).
        var displays: [DisplayEntry]
        /// Settings ▸ AI.
        var settings: AISettings
        /// The When rule lease (what plays now, for leaving "Same as Screensaver").
        var live: SignalState?
        var now = Date()

        init(displays: [DisplayEntry], settings: AISettings, live: SignalState?, now: Date = Date()) {
            self.displays = displays
            self.settings = settings
            self.live = live
            self.now = now
        }
    }

    static let playbackOff = "The user has turned off “Let AI change what plays” in DotStudio ▸ Settings ▸ AI. Styles can still be created; ask the user to set it themselves, or to turn that setting on."
    static var signalsOff: String { SignalEdits.signalsOff }

    /// The requests LibraryOps applies (the others are routed elsewhere: ping, the settings
    /// requests, test_signal).
    static func handles(_ op: BridgeRequest.Op) -> Bool {
        switch op {
        case .upsertStyle, .deleteStyle, .duplicateStyle, .setScreensaver, .setWallpaper,
             .upsertSignal, .deleteSignal, .upsertRule, .deleteRule:
            return true
        case .ping, .getSettings, .updateSettings, .appAction, .testSignal:
            return false
        }
    }

    /// Changes the user sees happen to their Mac — what plays, the wallpaper, the live data — so
    /// the app shows a notice with Undo (the Undo snapshot covers exactly these).
    static func isNoticed(_ op: BridgeRequest.Op) -> Bool {
        switch op {
        case .setScreensaver, .setWallpaper, .upsertSignal, .deleteSignal, .upsertRule, .deleteRule: return true
        default: return false
        }
    }

    /// Apply one request. ok = done (`library` / `wallpaper` hold the result); else nothing changed
    /// and `error` says why, in words the assistant can act on.
    static func apply(_ req: BridgeRequest, library lib: inout Library, wallpaper wall: inout WallpaperChoice,
                      _ ctx: Context) -> BridgeResponse {
        // Work on copies: a refusal never leaves half an edit behind.
        var l = lib
        var w = wall
        let r = run(req, &l, &w, ctx)
        if r.ok {
            lib = l
            wall = w
        }
        return r
    }

    private static func run(_ req: BridgeRequest, _ lib: inout Library, _ wall: inout WallpaperChoice,
                            _ ctx: Context) -> BridgeResponse {
        switch req.op {
        case .upsertStyle:
            guard var p = req.preset else { return .fail("no style given") }
            if let n = lib.newerBuildStyle(p.id) { return .fail(Library.newerBuildMessage(n.name)) }
            if let i = lib.presets.firstIndex(where: { $0.id == p.id }) {
                lib.presets[i] = p
                return BridgeResponse(ok: true, id: p.id, name: p.name, message: "Updated “\(p.name)”.")
            }
            p.name = lib.uniqueName(p.name)
            lib.presets.append(p)
            return BridgeResponse(ok: true, id: p.id, name: p.name, message: "Added “\(p.name)” to the library.")
        case .duplicateStyle:
            if let id = req.id, let n = lib.newerBuildStyle(id) { return .fail(Library.newerBuildMessage(n.name)) }
            guard let id = req.id, let copy = lib.duplicatePreset(id, name: req.name) else { return .fail("no such style") }
            return BridgeResponse(ok: true, id: copy.id, name: copy.name, message: "Duplicated as “\(copy.name)”.")
        case .deleteStyle:
            if let id = req.id, let n = lib.newerBuildStyle(id) { return .fail(Library.newerBuildMessage(n.name)) }
            guard let id = req.id, let p = lib.presets.first(where: { $0.id == id }) else { return .fail("no such style") }
            guard lib.presets.count > 1 else { return .fail("“\(p.name)” is the only style; the library can't be empty.") }
            lib.removePreset(id)
            wall.styleDeleted(id, in: lib, connected: ctx.displays.map(\.key))
            return BridgeResponse(ok: true, id: id, name: p.name, message: "Deleted “\(p.name)”.")
        case .setScreensaver:
            guard ctx.settings.allowPlaybackChanges else { return .fail(playbackOff) }
            return screensaver(req, &lib, ctx)
        case .setWallpaper:
            guard ctx.settings.allowPlaybackChanges else { return .fail(playbackOff) }
            return wallpaper(req, lib, &wall, ctx)
        case .upsertSignal, .deleteSignal, .upsertRule, .deleteRule:
            return SignalEdits.run(req, library: &lib, settings: ctx.settings)
        case .ping, .getSettings, .updateSettings, .appAction, .testSignal:
            return .fail("\(req.op.rawValue) isn't a library change")
        }
    }

    private static func noDisplay(_ key: String) -> BridgeResponse {
        .fail("No connected display has the key \(key). Call list_displays.")
    }

    /// A display an unpin may name: a connected one, or one that has a pin to take away (a
    /// display unplugged now keeps its pin, and the user may want it gone). Its name for the
    /// message; nil = unknown key.
    private static func unpinTarget(_ key: String, pins: [String: DisplayPin], _ ctx: Context) -> String? {
        if let d = ctx.displays.first(where: { $0.key == key }) { return d.name }
        if let pin = pins[key] { return pin.name ?? "That display" }
        return nil
    }

    private static func screensaver(_ req: BridgeRequest, _ lib: inout Library, _ ctx: Context) -> BridgeResponse {
        let mode = req.mode ?? "only"
        let known = ["only", "add", "remove", "night", "dayOnly", "unpin"]
        guard known.contains(mode) else { return .fail("unknown screensaver mode \(mode)") }
        if req.display != nil, mode != "only", mode != "unpin" { return .fail("`display` works with mode only or unpin.") }
        func name(_ id: UUID) -> String { lib.presets.first { $0.id == id }?.name ?? "—" }
        if mode == "unpin" {
            guard let key = req.display else { return .fail("mode unpin needs `display`.") }
            let pins = lib.displayStyles ?? [:]
            guard let d = unpinTarget(key, pins: pins, ctx) else { return noDisplay(key) }
            guard pins[key] != nil else { return BridgeResponse(ok: true, message: "\(d) already plays the screensaver lineup.") }
            lib.displayStyles?[key] = nil
            if lib.displayStyles?.isEmpty == true { lib.displayStyles = nil }
            return BridgeResponse(ok: true, message: "\(d) plays the screensaver lineup again.")
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
                guard let d = ctx.displays.first(where: { $0.key == key }) else { return noDisplay(key) }
                var pins = lib.displayStyles ?? [:]
                pins[key] = DisplayPin(presetID: id, name: d.name)
                lib.displayStyles = pins
                return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is now the screensaver on \(d.name).")
            }
            lib.displayStyles = nil
            lib.playAsScreensaver(id)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is now the screensaver on every display.")
        case "add":
            if l.playlist.contains(id) {
                return BridgeResponse(ok: true, id: id, name: name(id),
                                      message: "“\(name(id))” is already in the screensaver rotation (\(l.playlist.count) style\(l.playlist.count == 1 ? "" : "s")).")
            }
            l.playlist.append(id)
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” joined the screensaver rotation (\(lib.screensaverLineup.playlist.count) styles).")
        case "remove":
            guard l.playlist.count > 1, let i = l.playlist.firstIndex(of: id) else {
                return .fail("“\(name(id))” isn't in the rotation, or it's the only style playing (something always plays).")
            }
            l.playlist.remove(at: i)
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” left the rotation.")
        default: // "night"
            l.night = id
            lib.applyLineup(l)
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” now plays after sunset.")
        }
    }

    private static func wallpaper(_ req: BridgeRequest, _ lib: Library, _ wall: inout WallpaperChoice, _ ctx: Context) -> BridgeResponse {
        let mode = req.mode ?? "set"
        guard ["set", "off", "follow", "unpin"].contains(mode) else { return .fail("unknown wallpaper mode \(mode)") }
        if req.display != nil, mode != "set", mode != "unpin" { return .fail("`display` works with mode set or unpin.") }
        func name(_ id: UUID) -> String { lib.presets.first { $0.id == id }?.name ?? "—" }
        func exists(_ id: UUID?) -> UUID? { id.flatMap { i in lib.presets.contains { $0.id == i } ? i : nil } }
        switch mode {
        case "off":
            wall.enabled = false
            return BridgeResponse(ok: true, message: "The live wallpaper is off.")
        case "follow":
            wall.enabled = true
            wall.followsScreensaver = true
            return BridgeResponse(ok: true, message: "The live wallpaper now matches the screensaver.")
        case "unpin":
            guard let key = req.display else { return .fail("mode unpin needs `display`.") }
            guard let d = unpinTarget(key, pins: wall.displayStyles, ctx) else { return noDisplay(key) }
            guard wall.displayStyles[key] != nil else { return BridgeResponse(ok: true, message: "\(d) already shows the shared wallpaper.") }
            wall.displayStyles[key] = nil
            return BridgeResponse(ok: true, message: "\(d) shows the shared wallpaper again.")
        default: // "set"
            guard let id = exists(req.id) else { return .fail("no such style") }
            if let key = req.display {
                guard let d = ctx.displays.first(where: { $0.key == key }) else { return noDisplay(key) }
                let pin = DisplayPin(presetID: id, name: d.name)
                if wall.followsScreensaver {
                    // Leaving "Same as Screensaver" this way changes nothing else on screen.
                    wall = wall.leavingSync(lib, now: ctx.now, live: ctx.live, pin: pin, display: key)
                } else {
                    wall.displayStyles[key] = pin
                }
                wall.enabled = true
                // The other displays play the shared pick: the last one while it exists, else
                // the screensaver's style.
                if exists(wall.presetID) == nil { wall.presetID = exists(lib.activeID) ?? id }
                return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is the live wallpaper on \(d.name).")
            }
            wall.displayStyles = [:]            // "All Displays"
            wall.enabled = true
            wall.presetID = id
            wall.followsScreensaver = false
            return BridgeResponse(ok: true, id: id, name: name(id), message: "“\(name(id))” is the live wallpaper.")
        }
    }
}
