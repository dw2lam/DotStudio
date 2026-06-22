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
    }

    // MARK: Library

    func load() -> Library? {
        guard let data = try? Data(contentsOf: libraryURL) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }

    func save(_ library: Library) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(library) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    func libraryModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: libraryURL.path)[.modificationDate]) as? Date
    }

    // MARK: Debug

    func debug(_ message: String) {
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
