//  SharedStore.swift — where presets + media live, shared across the sandbox.
//
//  The screensaver runs inside the sandboxed `legacyScreenSaver` host. The app
//  is NOT sandboxed, so it writes presets + media directly into that host's
//  container; from inside the saver the very same folder is just its own
//  Application Support directory. No entitlements required.

import Foundation

enum StoreRole { case app, saver }

final class SharedStore {
    static let folderName = "DotStudio"
    static let legacyHost = "com.apple.ScreenSaver.Engine.legacyScreenSaver"

    let baseDir: URL
    let mediaDir: URL
    let libraryURL: URL
    /// Debug logging is opt-in: `touch debug.enabled` next to library.json.
    /// Checked once at init so shipping saver launches don't touch a log file.
    let debugEnabled: Bool

    init(role: StoreRole) {
        let fm = FileManager.default
        switch role {
        case .app:
            // Write into the screensaver host's sandbox container.
            let home = fm.homeDirectoryForCurrentUser
            baseDir = home
                .appendingPathComponent("Library/Containers/\(SharedStore.legacyHost)/Data/Library/Application Support/\(SharedStore.folderName)", isDirectory: true)
        case .saver:
            // Inside the sandbox this resolves to the container's Application Support.
            let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDir = appSup.appendingPathComponent(SharedStore.folderName, isDirectory: true)
        }
        mediaDir = baseDir.appendingPathComponent("media", isDirectory: true)
        libraryURL = baseDir.appendingPathComponent("library.json")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        debugEnabled = fm.fileExists(atPath: baseDir.appendingPathComponent("debug.enabled").path)
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
        let dst = baseDir.appendingPathComponent("library.json.backup-\(stamp)")
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
            try data.write(to: libraryURL, options: .atomic)
            return true
        } catch {
            debug("library.json save FAILED: \(error)")
            return false
        }
    }

    func libraryModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: libraryURL.path)[.modificationDate]) as? Date
    }

    // MARK: Debug

    func debug(_ message: String) {
        guard debugEnabled else { return }
        let url = baseDir.appendingPathComponent("debug.log")
        let line = message + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
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
