//  SetupGuideStore.swift — read-only parsers behind the guided setup (SetupGuide.swift):
//  which screensaver macOS shows on each display (the wallpaper store's Index.plist), the
//  display-sleep timers (`pmset -g custom`), and how they're said in the checklist.
//
//  Foundation only, no AppKit: tools/setup-guide-check.sh compiles this file on its own and
//  runs it against a COPY of the real Index.plist. Nothing here ever writes anything.

import Foundation

// MARK: - Wallpaper store (which screensaver is chosen)

/// macOS 14+ keeps the screensaver choice in ~/Library/Application Support/com.apple.wallpaper/
/// Store/Index.plist (a binary plist), per Space and per display:
///
///     AllSpacesAndDisplays        "$null", or an entry that applies everywhere
///     Spaces/<space>/Default      the Space's choice for displays without their own
///     Spaces/<space>/Displays/<display UUID>
///     Displays/<display UUID>     a display's own choice
///     SystemDefault               the fallback
///
/// Each entry has a `Type` ("individual" = has its own choice; "linked" = follows the level
/// above) and an `Idle` (the screensaver) whose `Content/Choices/0` holds a `Provider` and a
/// `Configuration` — a nested plist whose `module/relative` is the screensaver's file URL
/// (".../DotStudio.saver"). Provider "default" means the system default (SystemDefault's).
/// The store keeps every Space and display it has ever seen, so only the CURRENT Space of each
/// CONNECTED display counts (com.apple.spaces), not any old entry that mentions DotStudio.
enum WallpaperStoreReader {
    static let saverName = "DotStudio.saver"

    static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// One connected display: its UUID (CGDisplayCreateUUIDFromDisplayID), whether it's the main
    /// display, and the UUID of the Space it shows now ("" is the first desktop; nil: unknown).
    struct Display: Equatable {
        var uuid: String
        var isMain: Bool
        var currentSpace: String?
    }

    /// What the store says for each display: DotStudio or not, per display.
    struct Result: Equatable {
        /// Per display, in the order given: true when DotStudio is its screensaver.
        var perDisplay: [Bool]
        var chosen: Int { perDisplay.filter { $0 }.count }
        var total: Int { perDisplay.count }
    }

    /// Resolves each display's screensaver. nil when the data isn't a store this can read.
    static func resolve(indexData data: Data, displays: [Display]) -> Result? {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        let system = idleModule(root["SystemDefault"])
        func finish(_ m: Module?) -> Bool {
            switch m {
            case .saver(let path)?: return path.contains(saverName)
            case .systemDefault?:
                if case .saver(let path)? = system { return path.contains(saverName) }
                return false
            case nil: return false
            }
        }
        // No display list (a headless check): the system default alone.
        guard !displays.isEmpty else { return Result(perDisplay: [finish(system)]) }

        let all = idleModule(root["AllSpacesAndDisplays"])
        let spaces = root["Spaces"] as? [String: Any] ?? [:]
        let byDisplay = root["Displays"] as? [String: Any] ?? [:]
        return Result(perDisplay: displays.map { d in
            if let all { return finish(all) }
            if let s = d.currentSpace, let space = spaces[s] as? [String: Any] {
                let own = (space["Displays"] as? [String: Any])?[d.uuid]
                if let m = idleModule(own) { return finish(m) }
                if let m = idleModule(space["Default"]) { return finish(m) }
            }
            if let m = idleModule(byDisplay[d.uuid]) { return finish(m) }
            return finish(system)
        })
    }

    /// A last resort when the per-display walk can't be done: is DotStudio anyone's choice?
    static func mentionsSaver(indexData data: Data) -> Bool? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let needle = Data(saverName.utf8)
        func scan(_ o: Any, idle: Bool) -> Bool {
            if let d = o as? [String: Any] { return d.contains { k, v in scan(v, idle: idle || k == "Idle") } }
            if let a = o as? [Any] { return a.contains { scan($0, idle: idle) } }
            if idle, let d = o as? Data { return d.range(of: needle) != nil }
            if idle, let s = o as? String { return s.contains(saverName) }
            return false
        }
        return scan(root, idle: false)
    }

    enum Module: Equatable {
        /// A screensaver module's URL (or anything else naming the choice).
        case saver(String)
        /// Provider "default": whatever SystemDefault says.
        case systemDefault
    }

    /// An entry's own screensaver choice; nil when it has none (linked, or no Idle).
    static func idleModule(_ entry: Any?) -> Module? {
        guard let entry = entry as? [String: Any],
              (entry["Type"] as? String) != "linked",
              let idle = entry["Idle"] as? [String: Any],
              let content = idle["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [Any])?.first as? [String: Any]
        else { return nil }
        let provider = choice["Provider"] as? String ?? ""
        if provider == "default" { return .systemDefault }
        // The nested Configuration plist: find the module URL anywhere in it.
        if let conf = choice["Configuration"] as? Data,
           let inner = try? PropertyListSerialization.propertyList(from: conf, format: nil),
           let url = firstString(in: inner, where: { $0.hasPrefix("file:") || $0.contains(".saver") || $0.contains(".appex") }) {
            return .saver(url.removingPercentEncoding ?? url)
        }
        return .saver(provider)
    }

    private static func firstString(in o: Any, where match: (String) -> Bool) -> String? {
        if let s = o as? String { return match(s) ? s : nil }
        if let d = o as? [String: Any] {
            // "module" first: it's the screensaver itself, not an option's file.
            if let m = d["module"], let s = firstString(in: m, where: match) { return s }
            for (_, v) in d.sorted(by: { $0.key < $1.key }) { if let s = firstString(in: v, where: match) { return s } }
        }
        if let a = o as? [Any] { for v in a { if let s = firstString(in: v, where: match) { return s } } }
        return nil
    }

    /// The Space each display shows now, from com.apple.spaces' SpacesDisplayConfiguration
    /// (its "Management Data" › Monitors: "Display Identifier" = a display UUID, or "Main" when
    /// Spaces span every display). Keyed by display UUID; "Main" for the shared entry.
    static func currentSpaces(spacesConfiguration conf: Any?) -> [String: String] {
        guard let conf = conf as? [String: Any],
              let data = conf["Management Data"] as? [String: Any],
              let monitors = data["Monitors"] as? [Any] else { return [:] }
        var out: [String: String] = [:]
        for case let m as [String: Any] in monitors {
            guard let id = m["Display Identifier"] as? String,
                  let current = m["Current Space"] as? [String: Any],
                  let uuid = current["uuid"] as? String else { continue }
            out[id] = uuid
        }
        return out
    }

    /// Each display's current Space from that map: its own entry, else the shared "Main" one.
    static func space(for uuid: String, in spaces: [String: String]) -> String? {
        spaces[uuid] ?? spaces["Main"]
    }
}

// MARK: - Display sleep (pmset)

/// The display-off timers per power source, from `pmset -g custom` (minutes; 0 = never).
struct DisplaySleepTimers: Equatable {
    var battery: Int?
    var ac: Int?
    var ups: Int?

    var hasBattery: Bool { battery != nil }

    /// Parses `pmset -g custom`: "Battery Power:" / "AC Power:" / "UPS Power:" sections, each
    /// with a " displaysleep   10" line.
    static func parse(pmsetCustom text: String) -> DisplaySleepTimers {
        var t = DisplaySleepTimers()
        var section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") && !raw.hasPrefix(" ") { section = line.lowercased(); continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "displaysleep", let v = Int(parts[1]) else { continue }
            switch section {
            case let s? where s.hasPrefix("battery"): t.battery = v
            case let s? where s.hasPrefix("ac"): t.ac = v
            case let s? where s.hasPrefix("ups"): t.ups = v
            default: break
            }
        }
        return t
    }
}

// MARK: - Words

enum SetupWords {
    /// "5 minutes", "1 hour", "90 seconds".
    static func duration(seconds: Int) -> String {
        if seconds % 3600 == 0 && seconds >= 3600 {
            let h = seconds / 3600
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        if seconds % 60 == 0 && seconds >= 60 {
            let m = seconds / 60
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// "2 min", "1 hr" — the short form inside a sentence that already names two times.
    static func short(seconds: Int) -> String {
        if seconds >= 3600 && seconds % 3600 == 0 { return "\(seconds / 3600) hr" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
    }
}

// MARK: - Where the app runs from (Move to Applications)

/// Whether DotStudio runs from somewhere it should be moved out of. Updates (Sparkle) and the
/// login item need a stable copy in an Applications folder; a copy opened straight from the
/// disk image or Downloads runs translocated (a read-only random path) and can do neither.
enum AppLocation {
    /// Gatekeeper's App Translocation: a quarantined app opened where it was downloaded.
    static func isTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// Inside /Applications or ~/Applications (subfolders included).
    static func isInApplications(_ bundlePath: String, home: String) -> Bool {
        let p = (bundlePath as NSString).standardizingPath
        let user = ((home as NSString).appendingPathComponent("Applications") as NSString).standardizingPath
        return p.hasPrefix("/Applications/") || p.hasPrefix(user + "/")
    }

    /// A build product (Xcode, DerivedData, this repo's build/): developers run these in place.
    static func isDevBuild(_ bundlePath: String) -> Bool {
        ["/DerivedData/", "/Build/Products/", "/.build/"].contains { bundlePath.contains($0) }
    }

    /// Offer the move: translocated, or outside both Applications folders (never a build product).
    static func shouldOfferMove(bundlePath: String, home: String) -> Bool {
        if isTranslocated(bundlePath) { return true }
        if isDevBuild(bundlePath) { return false }
        return !isInApplications(bundlePath, home: home)
    }
}
