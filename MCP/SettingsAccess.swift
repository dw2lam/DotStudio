//  SettingsAccess.swift — the app's own settings over MCP: get_settings, update_settings and
//  app_action (the catalog and the shared validation/apply are Shared/AI/AppSettings.swift).
//
//  Routing is LibraryAccess.perform's, like every other change: the running app applies a patch
//  live through its controllers (AIBridgeHost); without it, SettingsExecutor applies it to
//  library.json, wallpaper.json and the app's preferences (PrefsStore) under StoreLock.

import CoreFoundation
import Foundation

/// The app's preferences (AppPrefs, App/AppPresence.swift) as dotstudio-mcp reaches them: the
/// app's own defaults domain when the store is the real one, else `<store>/app-prefs.json` —
/// where the app keeps them under DOTSTUDIO_STORE_DIR, so a test store never touches the
/// user's real preferences.
enum PrefsStore {
    static let appID = "com.davidlam.DotStudio" as CFString

    static func usesDefaults(_ dir: URL) -> Bool {
        dir.standardizedFileURL.resolvingSymlinksInPath().path
            == SharedStore.sharedDir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func fileURL(_ dir: URL) -> URL { dir.appendingPathComponent("app-prefs.json") }

    /// The settings' preference values that are set (missing = the setting's default).
    static func load(_ dir: URL) -> [String: Bool] {
        var out: [String: Bool] = [:]
        if usesDefaults(dir) {
            CFPreferencesAppSynchronize(appID)
            for (k, _) in AppSettings.prefKeys {
                if let v = CFPreferencesCopyAppValue(k as CFString, appID) as? Bool { out[k] = v }
            }
        } else if let d = try? Data(contentsOf: fileURL(dir)), let all = try? JSONDecoder().decode([String: Bool].self, from: d) {
            for (k, _) in AppSettings.prefKeys { if let v = all[k] { out[k] = v } }
        }
        return out
    }

    /// Write the changed values (other keys in app-prefs.json are kept).
    static func save(_ prefs: [String: Bool], changed: [String], _ dir: URL) {
        guard !changed.isEmpty else { return }
        if usesDefaults(dir) {
            for k in changed { CFPreferencesSetAppValue(k as CFString, prefs[k].map { $0 as CFBoolean } as CFPropertyList?, appID) }
            CFPreferencesAppSynchronize(appID)
            return
        }
        var all = (try? Data(contentsOf: fileURL(dir))).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
        for k in changed { all[k] = prefs[k] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(all).write(to: fileURL(dir), options: .atomic)
    }
}

/// A settings request applied to the files (or to the stand-in app's memory) — what the app's
/// AIBridgeHost does for the same request, minus its UI.
enum SettingsExecutor {
    /// What can be read about macOS's side without the app (read-only, never changes anything).
    static func offlineSystem() -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        let saver = SharedStore.realHome.appendingPathComponent("Library/Screen Savers/DotStudio.saver")
        o["system.screensaverInstalled"] = .bool(FileManager.default.fileExists(atPath: saver.path))
        let app = "com.apple.screensaver" as CFString
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let idle = (CFPreferencesCopyValue("idleTime" as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.intValue ?? 1200
        o["system.startScreenSaverAfter"] = .number(Double(idle) / 60)
        return o
    }

    /// Settings only the running app can read (login item, setup checks…), offline.
    static let needsAppNote = "DotStudio isn't running: open it to read this."

    /// `appActions`: the stand-in app answers actions (it has no windows to open); offline they fail.
    static func run(_ req: BridgeRequest, library lib: inout Library, wallpaper wall: inout JSONObject,
                    prefs: inout [String: Bool], store: SharedStore, ai: AISettings,
                    live: [String: JSONValue], appActions: Bool = false) -> BridgeResponse {
        var state = AppSettings.State(library: lib, wallpaper: (try? JSON.decode([String: JSONValue].self, from: wall)) ?? [:],
                                      prefs: prefs, ai: ai)
        switch req.op {
        case .getSettings:
            var values = AppSettings.read(state)
            values.merge(live) { _, new in new }
            return BridgeResponse(ok: true, settings: values)
        case .updateSettings:
            let changes: [AppSettings.Change]
            switch AppSettings.validate(req.settings ?? [:], library: lib) {
            case .success(let c): changes = c
            case .failure(let e): return .fail(e.message)
            }
            let gated = AppSettings.gatedKeys(changes)
            if !gated.isEmpty, !ai.allowPlaybackChanges {
                return .fail(LibraryExecutor.playbackOff + " (Refused: \(gated.joined(separator: ", ")) change what plays; the other settings can be sent on their own.)")
            }
            if let app = changes.first(where: \.def.needsApp), !appActions {
                return .fail("\(app.def.key) can only be changed while DotStudio is running (the app registers its own login item). Ask the user to open DotStudio, then try again — nothing was changed.")
            }
            do {
                // The stand-in app acknowledges the login item (the real app registers it).
                try AppSettings.apply(changes.filter { !$0.def.needsApp }, to: &state) { try store.importMedia(from: $0) }
            } catch let e as SettingsError {
                return .fail(e.message)
            } catch {
                return .fail("Couldn't copy the file into DotStudio's library: \(error.localizedDescription). Nothing was changed.")
            }
            lib = state.library
            wall = JSON.from(JSONValue.object(state.wallpaper)) as? JSONObject ?? wall
            prefs = state.prefs
            let after = AppSettings.read(state)
            var changed: [String: JSONValue] = [:]
            for c in changes { changed[c.def.key] = after[c.def.key] ?? c.value }
            let msg = "Changed " + changes.map { AppSettings.describe($0, library: lib) }.joined(separator: "; ") + "."
            return BridgeResponse(ok: true, message: msg, settings: changed)
        case .appAction:
            guard let a = req.mode, AppSettings.actions.contains(where: { $0.id == a }) else { return .fail("unknown action \(req.mode ?? "")") }
            guard appActions else {
                return .fail("DotStudio isn't running, and \(a) is one of its own buttons. Ask the user to open DotStudio, then try again.")
            }
            return BridgeResponse(ok: true, message: "Did \(a).")
        default:
            return .fail("not a settings request")
        }
    }
}

// MARK: - Tools

extension Toolbox {
    static let settingGroups = AppSettings.groups.map(\.id)

    /// The JSON Schema of one settable value (update_settings' `settings` properties).
    static func schema(_ d: SettingDef) -> JSONObject {
        let desc = "\(d.label) (\(d.place)): \(d.meaning)" + (d.gated ? " Changes what plays." : "")
        switch d.type {
        case .bool: return S.bool(desc)
        case .choice(let c): return S.str(desc, enum: c)
        case .number(let lo, let hi): return S.num(desc, min: lo, max: hi)
        case .numberChoice(let n): return ["type": "number", "enum": n, "description": desc]
        case .color: var c = S.color; c["description"] = desc; return c
        case .style: return S.str(desc + " A style id or exact name (list_styles).")
        case .photos: return ["description": desc, "anyOf": [S.str("\"builtIn\"", enum: ["builtIn"]),
                                                             S.arr(S.str("Absolute path to an image.", pattern: "^/"), "Image files.", min: 1, max: 200)]]
        case .mediaFile: return S.str(desc, pattern: "^/")
        case .readOnly: return [:]
        }
    }

    var settingsTools: [Tool] {
        [
            Tool(name: "get_settings", title: "Get DotStudio's settings",
                 description: "Every setting the user can change in the DotStudio app — General (menu bar, open at login), Screensaver (playlist interval, shuffle, crossfade, quality), Music, Weather, Live Wallpaper (on, same as screensaver, style, frame rate, quality, on battery, lock screen picture), the Source that Looks restyle, Updates — with each one's current value, allowed values, where it is in the app, a one-line meaning and whether it changes what plays. Also the read-only state macOS owns (is the screensaver installed and chosen, idle time, display sleep, login item, Accessibility, text size) with how the user changes it, and the app_action list. Change settings with update_settings.",
                 input: S.obj(["group": S.str("Only this group.", enum: Self.settingGroups),
                               "keys": S.arr(S.str("A setting key, e.g. music.show"), "Only these settings.", min: 1, max: 80)]),
                 readOnly: true, idempotent: true) { [unowned self] a in try self.getSettings(a) },
            Tool(name: "update_settings", title: "Change DotStudio's settings",
                 description: "CHANGES THE USER'S DOTSTUDIO SETTINGS: a patch of setting keys → values from get_settings, e.g. {\"settings\": {\"music.show\": \"fullScreen\", \"music.layout\": \"stage\", \"wallpaper.quality\": \"efficient\"}}. Checked as a whole: an unknown key, a read-only one or a bad value refuses the whole patch with the reason. Settings marked changesWhatPlays (playlist interval/shuffle, Show music, wallpaper on/same-as-screensaver/style/lock screen) are refused while the user has turned off “Let AI change what plays”. With DotStudio open the change is live in its Settings window, with a notice and Undo; otherwise it's written to its files for next launch. Only change what the user asked for.",
                 input: S.obj(["settings": ["type": "object", "description": "Setting key → new value (see get_settings for keys and allowed values).",
                                            "properties": Dictionary(uniqueKeysWithValues: AppSettings.settable.map { ($0.key, Self.schema($0)) }),
                                            "additionalProperties": true]],
                              required: ["settings"]),
                 idempotent: true) { [unowned self] a in try self.updateSettings(a) },
            Tool(name: "app_action", title: "Do it in DotStudio",
                 description: "Press one of DotStudio's own buttons for the user (DotStudio must be running): " + AppSettings.actions.map { "\($0.id) — \($0.meaning)" }.joined(separator: " ") + " These open windows on the user's screen or install the screensaver: only when the user asked. macOS's own settings (which screensaver is chosen, idle time, Accessibility, login-item approval) stay the user's to click — these actions take them to the right place.",
                 input: S.obj(["action": S.str("What to do.", enum: AppSettings.actions.map(\.id))], required: ["action"])) { [unowned self] a in
                let action = a["action"] as! String
                let (r, viaApp) = try self.perform(BridgeRequest(op: .appAction, mode: action))
                return .ok((r.message ?? "Done.") + (viaApp ? "" : " " + self.whereNote(viaApp)), ["action": action, "message": r.message ?? "", "liveInApp": viaApp])
            },
        ]
    }

    func getSettings(_ a: JSONObject) throws -> ToolResult {
        let (r, viaApp) = try perform(BridgeRequest(op: .getSettings))
        let values = r.settings ?? [:]
        let wantKeys = (a["keys"] as? [String]).map(Set.init)
        if let keys = wantKeys {
            let unknown = keys.filter { AppSettings.def($0) == nil }.sorted()
            if !unknown.isEmpty { throw ToolError("Unknown setting key(s): \(unknown.joined(separator: ", ")). Call get_settings without `keys` to see them all.") }
        }
        let group = a["group"] as? String
        let allow = values["ai.allowPlaybackChanges"]?.boolValue ?? true
        var groups: [JSONObject] = []
        var text = "DotStudio is \(viaApp ? "running: values are live" : "not running: values are from its files"). "
            + "The AI \(allow ? "may" : "may NOT") change settings marked changesWhatPlays.\n"
        for g in AppSettings.groups where group == nil || group == g.id {
            let defs = AppSettings.all.filter { $0.group == g.id && (wantKeys == nil || wantKeys!.contains($0.key)) }
            guard !defs.isEmpty else { continue }
            text += "\n\(g.title)\n"
            let items: [JSONObject] = defs.map { d in
                let v = values[d.key] ?? .null
                var o: JSONObject = ["key": d.key, "label": d.label, "where": d.place, "meaning": d.meaning,
                                     "value": JSON.from(v), "allowed": JSON.from(d.allowedJSON),
                                     "readOnly": d.readOnly, "changesWhatPlays": d.gated]
                if let h = d.howToChange { o["howToChange"] = h }
                if d.needsApp { o["needsApp"] = true }
                if values[d.key] == nil, d.store == .system || d.store == .app { o["note"] = SettingsExecutor.needsAppNote }
                var line = "- \(d.key) = \(values[d.key].map { $0.display } ?? "unknown")"
                if d.readOnly { line += "  (read-only: \(d.howToChange ?? "—"))" }
                else {
                    if let allowed = allowedText(d) { line += "  [\(allowed)]" }
                    if d.gated { line += " · changes what plays" }
                    if d.needsApp { line += " · needs the app running" }
                }
                text += line + "\n"
                return o
            }
            groups.append(["id": g.id, "title": g.title, "settings": items])
        }
        if group == nil, wantKeys == nil {
            text += "\nActions (app_action, DotStudio running): " + AppSettings.actions.map(\.id).joined(separator: ", ") + "\n"
        }
        var extras: JSONObject = [:]
        for k in ["weather.now", "updates.status", "updates.version"] { if let v = values[k] { extras[k] = JSON.from(v) } }
        return .ok(text, ["appRunning": viaApp, "allowPlaybackChanges": allow, "groups": groups,
                          "actions": AppSettings.actions.map { ["id": $0.id, "meaning": $0.meaning] }, "status": extras])
    }

    private func allowedText(_ d: SettingDef) -> String? {
        switch d.type {
        case .bool: return "true|false"
        case .choice(let c): return c.joined(separator: "|")
        case .number(let lo, let hi): return "\(AppSettings.fmt(lo))…\(AppSettings.fmt(hi))"
        case .numberChoice(let n): return n.map(AppSettings.fmt).joined(separator: "|")
        case .color: return "{r,g,b,a?} 0…1"
        case .style: return "style id or name"
        case .photos: return "\"builtIn\" | [image paths]"
        case .mediaFile: return "image/video path"
        case .readOnly: return nil
        }
    }

    func updateSettings(_ a: JSONObject) throws -> ToolResult {
        guard var raw = a["settings"] as? JSONObject else { throw ToolError("Pass `settings`: an object of setting key → value.") }
        // A style may be named; the app takes ids.
        if let s = raw["wallpaper.style"] as? String { raw["wallpaper.style"] = try lib.preset(s).id.uuidString }
        guard let patch = try? JSON.decode([String: JSONValue].self, from: raw) else { throw ToolError("`settings` must be a JSON object.") }
        // Checked here first so a bad patch never reaches the app (the app checks again).
        if case .failure(let e) = AppSettings.validate(patch, library: try lib.library()) { throw ToolError(e.message) }
        let (r, viaApp) = try perform(BridgeRequest(op: .updateSettings, settings: patch))
        let changed = (r.settings ?? [:]).mapValues { JSON.from($0) }
        return .ok((r.message ?? "Done.") + " " + settingsWhereNote(viaApp), ["changed": changed, "liveInApp": viaApp])
    }

    func settingsWhereNote(_ viaApp: Bool) -> String {
        viaApp ? "DotStudio is running: the change is live (its Settings window shows it)."
            : "DotStudio isn't running: its files were updated; the app uses them next time it opens."
    }
}
