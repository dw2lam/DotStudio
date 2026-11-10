//  SharedStore.swift — where presets + media live, shared between app and saver.
//
//  The library lives in ~/Library/Application Support/DotStudio. The app (not
//  sandboxed) owns and writes it. The screensaver runs inside Apple's sandboxed
//  `legacyScreenSaver` host, whose entitlements allow read-only access to the
//  whole filesystem (`temporary-exception.files.absolute-path.read-only: /`), so
//  it reads the same folder by its real path.
//
//  Before 1.3 the app wrote into the host's own container instead. macOS's
//  "access data from other apps" protection blocks that (EPERM) unless the user
//  approves — and an ad-hoc-signed app is a "new app" after every update, so the
//  approval never stuck. The old container is now only a read fallback for the
//  saver and a one-time migration source for the app.

import Foundation
import QuartzCore

enum StoreRole { case app, saver }

final class SharedStore {
    static let folderName = "DotStudio"
    static let legacyHost = "com.apple.ScreenSaver.Engine.legacyScreenSaver"

    /// The user's real home — inside the sandbox `homeDirectoryForCurrentUser`
    /// points at the container, so ask the password database.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/DotStudio — the shared library folder.
    static var sharedDir: URL {
        realHome.appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
    }

    /// The folder the app's store uses: `sharedDir`, or DOTSTUDIO_STORE_DIR (dev/test).
    static var appBaseDir: URL {
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return sharedDir
    }

    /// Pre-1.3 location, inside the screensaver host's container.
    static var legacyContainerDir: URL {
        realHome.appendingPathComponent(
            "Library/Containers/\(legacyHost)/Data/Library/Application Support/\(folderName)", isDirectory: true)
    }

    let baseDir: URL
    let mediaDir: URL
    let libraryURL: URL
    /// Somewhere this process may write (debug log, corrupt-library backups). The
    /// saver can only read `baseDir`, so it logs into its own container.
    let writableDir: URL
    /// Debug logging is opt-in: `touch debug.enabled` next to library.json.
    /// Checked once at init so shipping saver launches don't touch a log file.
    let debugEnabled: Bool
    /// Why the most recent save failed (shown in the app's alert).
    private(set) var lastSaveError: String?

    init(role: StoreRole) {
        let fm = FileManager.default
        switch role {
        case .app where ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil:
            // Dev/test override: keep headless renders away from the real library.
            baseDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"]!, isDirectory: true)
            writableDir = baseDir
        case .app:
            baseDir = SharedStore.sharedDir
            writableDir = baseDir
            SharedStore.migrateFromContainer(to: baseDir)
        case .saver:
            let own = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(SharedStore.folderName, isDirectory: true)
            let shared = SharedStore.sharedDir
            // Prefer the shared folder; fall back to the container for a pre-1.3 app.
            baseDir = fm.fileExists(atPath: shared.appendingPathComponent("library.json").path) ? shared : own
            writableDir = own
            try? fm.createDirectory(at: own, withIntermediateDirectories: true)
        }
        mediaDir = baseDir.appendingPathComponent("media", isDirectory: true)
        libraryURL = baseDir.appendingPathComponent("library.json")
        if role == .app { try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true) }
        debugEnabled = fm.fileExists(atPath: baseDir.appendingPathComponent("debug.enabled").path)
            || fm.fileExists(atPath: writableDir.appendingPathComponent("debug.enabled").path)
    }

    /// One-time move of a pre-1.3 library out of the screensaver's container.
    /// Best effort: macOS may refuse to let us read it, and then we start fresh.
    private static func migrateFromContainer(to dir: URL) {
        let fm = FileManager.default
        let newLib = dir.appendingPathComponent("library.json")
        guard !fm.fileExists(atPath: newLib.path) else { return }
        let old = legacyContainerDir
        guard let data = try? Data(contentsOf: old.appendingPathComponent("library.json")) else { return }
        try? fm.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        if let media = try? fm.contentsOfDirectory(at: old.appendingPathComponent("media"),
                                                   includingPropertiesForKeys: nil) {
            for f in media {
                try? fm.copyItem(at: f, to: dir.appendingPathComponent("media").appendingPathComponent(f.lastPathComponent))
            }
        }
        try? data.write(to: newLib, options: .atomic)
    }

    // MARK: Library

    /// Outcome of reading library.json. `.corrupt` means the file exists but failed to
    /// decode — the caller must NOT overwrite it blindly; a timestamped backup has
    /// already been made (nil if even the backup copy failed).
    enum LibraryLoad {
        case loaded(Library)
        case missing
        case corrupt(backup: URL?)
    }

    func loadLibrary() -> LibraryLoad {
        guard let data = try? Data(contentsOf: libraryURL) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(Library.self, from: data))
        } catch {
            let backup = backupCorruptLibrary()
            debug("library.json corrupt (\(error)) — backup: \(backup?.lastPathComponent ?? "FAILED")")
            return .corrupt(backup: backup)
        }
    }

    /// Convenience for callers that treat missing and corrupt the same (e.g. Shots).
    func load() -> Library? {
        if case .loaded(let lib) = loadLibrary() { return lib }
        return nil
    }

    /// Preserve an undecodable library.json before anything can overwrite it.
    /// Named after the corrupt file's mtime so the saver's 1 Hz reload poll reuses
    /// one backup per corruption instead of minting a new file every second.
    private func backupCorruptLibrary() -> URL? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: libraryModified() ?? Date())
        let dst = writableDir.appendingPathComponent("library.json.backup-\(stamp)")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }   // already saved
        do {
            try FileManager.default.copyItem(at: libraryURL, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    @discardableResult
    func save(_ library: Library) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(library)
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            try data.write(to: libraryURL, options: .atomic)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = (error as NSError).localizedDescription
                + " [\((error as NSError).domain) \((error as NSError).code)]"
            debug("library.json save FAILED: \(error)")
            return false
        }
    }

    func libraryModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: libraryURL.path)[.modificationDate]) as? Date
    }

    // MARK: Debug

    /// Callers on several threads (the live wallpaper's render thread) append whole lines.
    private static let debugLock = NSLock()

    func debug(_ message: String) {
        guard debugEnabled else { return }
        SharedStore.debugLock.lock(); defer { SharedStore.debugLock.unlock() }
        let url = writableDir.appendingPathComponent("debug.log")
        let line = message + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    /// A debug line tagged and time-stamped, `[tag 1234.567] message`; nothing is built while
    /// debug logging is off.
    func debug(_ tag: String, _ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        debug("[\(tag) \(String(format: "%.3f", CACurrentMediaTime()))] \(message())")
    }

    // MARK: Media

    func mediaURL(_ filename: String) -> URL { mediaDir.appendingPathComponent(filename) }

    /// Copy an imported file into the shared media folder, returning the stored filename.
    @discardableResult
    func importMedia(from src: URL) throws -> String {
        let ext = src.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dst = mediaURL(name)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        return name
    }
}
