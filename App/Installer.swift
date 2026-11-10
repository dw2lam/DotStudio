//  Installer.swift — installs the bundled .saver and opens Screen Saver settings.

import AppKit

enum Installer {
    static let saverName = "DotStudio.saver"

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/\(saverName)")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    enum Status: Equatable {
        case notInstalled
        case notChosen      // installed, but another screensaver is picked in System Settings
        case ready
    }

    static var status: Status {
        guard isInstalled else { return .notInstalled }
        return isChosenInSystemSettings ? .ready : .notChosen
    }

    /// True when DotStudio is the screensaver on at least one connected display. (Read-only;
    /// best effort: when the store can't be read it says yes, so nothing nags.)
    static var isChosenInSystemSettings: Bool {
        if case .chosen(let on, _) = screensaverChoice() { return on > 0 }
        return true   // can't tell: don't nag
    }

    /// Which connected displays show DotStudio as their screensaver. macOS 14+ keeps the pick
    /// per Space and display in the wallpaper store (WallpaperStoreReader); only each display's
    /// CURRENT Space counts — the store remembers every Space it has ever seen. Falls back to
    /// the legacy `com.apple.screensaver` moduleDict (-currentHost) when there's no store.
    /// Read-only; safe off the main thread.
    static func screensaverChoice() -> SetupSnapshot.Choice {
        let displays = connectedDisplays()
        if let data = try? Data(contentsOf: WallpaperStoreReader.indexURL) {
            if let r = WallpaperStoreReader.resolve(indexData: data, displays: displays) {
                return .chosen(on: r.chosen, of: r.total)
            }
            if let any = WallpaperStoreReader.mentionsSaver(indexData: data) {
                return .chosen(on: any ? 1 : 0, of: max(displays.count, 1))
            }
        }
        let app = "com.apple.screensaver" as CFString
        if let dict = CFPreferencesCopyValue("moduleDict" as CFString, app, kCFPreferencesCurrentUser,
                                             kCFPreferencesCurrentHost) as? [String: Any] {
            let path = (dict["path"] as? String ?? "") + (dict["moduleName"] as? String ?? "")
            let ours = path.contains(saverName) || (dict["moduleName"] as? String) == "DotStudio"
            return .chosen(on: ours ? max(displays.count, 1) : 0, of: max(displays.count, 1))
        }
        return .unknown
    }

    /// Connected displays (mirrors once), each with the Space it shows now (com.apple.spaces).
    static func connectedDisplays() -> [WallpaperStoreReader.Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &n) == .success else { return [] }
        let spaces = WallpaperStoreReader.currentSpaces(
            spacesConfiguration: CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString,
                                                           "com.apple.spaces" as CFString))
        return ids.prefix(Int(n)).compactMap { id in
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let s = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return WallpaperStoreReader.Display(uuid: s, isMain: CGDisplayIsMain(id) != 0,
                                                currentSpace: WallpaperStoreReader.space(for: s, in: spaces))
        }
    }

    /// Returns the .saver bundled inside the app (embedded at build time).
    static var bundledSaverURL: URL? {
        Bundle.main.url(forResource: "DotStudio", withExtension: "saver")
            ?? Bundle.main.url(forResource: "DotStudio", withExtension: "saver", subdirectory: "Resources")
    }

    /// After an app update the user's installed .saver is stale — replace it when the
    /// bundled copy is newer. The old code keeps running until legacyScreenSaver next
    /// relaunches; that's fine for a screensaver.
    static func reinstallIfOutdated() {
        guard isInstalled,
              let bundledURL = bundledSaverURL,
              let bundled = Bundle(url: bundledURL)?.infoDictionary?["CFBundleVersion"] as? String,
              let installed = Bundle(url: installedURL)?.infoDictionary?["CFBundleVersion"] as? String,
              bundled.compare(installed, options: .numeric) == .orderedDescending
        else { return }
        if case .success = install() {
            // macOS keeps the old saver code loaded until its host restarts; the
            // user is in the app, not the screensaver, so restart it now.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-q", "legacyScreenSaver"]
            try? p.run()
        }
    }

    @discardableResult
    static func install() -> Result<URL, Error> {
        guard let src = bundledSaverURL else {
            return .failure(NSError(domain: "DotStudio", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Bundled screensaver not found in app."]))
        }
        let fm = FileManager.default
        let dst = installedURL
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            refreshPipelineArchive()
            return .success(dst)
        } catch {
            return .failure(error)
        }
    }

    private static let archiveQueue = DispatchQueue(label: "DotStudio.pipelineArchive", qos: .utility)

    /// Precompiles the installed saver's pipelines for this Mac (Shared/PipelineArchive.swift),
    /// so its first start after an install or update shows a frame at once instead of compiling
    /// fx_fragment for seconds. Runs at launch (macOS or the GPU may have changed) and after
    /// every install; off the main thread, one at a time, a no-op while the archive is current.
    static func refreshPipelineArchive(delay: TimeInterval = 0) {
        archiveQueue.asyncAfter(deadline: .now() + delay) {
            guard isInstalled else { return }
            let outcome = PipelineArchive.refresh(saver: installedURL, baseDir: SharedStore.appBaseDir)
            if outcome != .upToDate { NSLog("DotStudio: screensaver pipeline archive \(outcome)") }
        }
    }

    static func openScreenSaverSettings() {
        // macOS 14+: the screen-saver picker is the Wallpaper page's "Screen Saver…" button
        // (macOS 26/27 have no separate Screen Saver page; verified: the Wallpaper settings
        // extension is com.apple.Wallpaper-Settings.extension and allows this URL scheme).
        let candidates = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
        // Fallback: reveal the installed saver in Finder.
        NSWorkspace.shared.activateFileViewerSelecting([installedURL])
    }
}
