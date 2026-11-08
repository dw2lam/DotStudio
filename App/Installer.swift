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

    /// macOS 14+ keeps the screen-saver pick per display/space in the wallpaper
    /// store; each Idle choice holds a nested plist whose `module` URL names the
    /// .saver. True if any of them points at ours. (Read-only; best effort.)
    static var isChosenInSystemSettings: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return true }   // can't tell: don't nag
        let needle = Data(saverName.utf8)
        func scan(_ o: Any, idle: Bool) -> Bool {
            if let d = o as? [String: Any] {
                return d.contains { k, v in scan(v, idle: idle || k == "Idle") }
            }
            if let a = o as? [Any] { return a.contains { scan($0, idle: idle) } }
            if idle, let d = o as? Data { return d.range(of: needle) != nil }
            return false
        }
        return scan(root, idle: false)
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
        _ = install()
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
            return .success(dst)
        } catch {
            return .failure(error)
        }
    }

    static func openScreenSaverSettings() {
        // On modern macOS the screen-saver picker lives on the Wallpaper page.
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
