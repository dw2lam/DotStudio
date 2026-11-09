//  MusicWriter.swift — publishes the monitor's state to every renderer:
//    <baseDir>/music.json        MusicState, written atomically (temp file + rename)
//    <baseDir>/music/art-<k>.jpg the current cover, copied in BEFORE the JSON names it
//  Old covers are pruned after each write; the previous one is kept briefly so a reader
//  that decoded the old JSON a moment ago can still open its file.
//  All file work happens on one serial utility queue — never on the main thread.

import Foundation

final class MusicStateWriter: @unchecked Sendable {   // all file work on its serial queue
    let baseDir: URL
    let jsonURL: URL
    let artDir: URL

    private let queue = DispatchQueue(label: "com.davidlam.DotStudio.music.writer", qos: .utility)
    private let log: (String) -> Void
    // Queue-confined.
    private var currentArt: String?
    private var previousArt: String?

    private let statsLock = NSLock()
    private var _writes = 0
    /// music.json writes performed (tests check rapid skips don't thrash the file).
    var writeCount: Int { statsLock.lock(); defer { statsLock.unlock() }; return _writes }

    init(baseDir: URL, log: @escaping (String) -> Void = { _ in }) {
        self.baseDir = baseDir
        jsonURL = baseDir.appendingPathComponent(MusicState.fileName)
        artDir = baseDir.appendingPathComponent(MusicState.artDirName, isDirectory: true)
        self.log = log
    }

    /// Publishes `state`; `artSource` is the cached cover named by `state.artwork`.
    func write(_ state: MusicState, artSource: URL?) {
        queue.async { self.writeOnQueue(state, artSource: artSource) }
    }

    /// Blocks until queued writes are on disk (stop(), tests).
    func flush() { queue.sync {} }

    private func writeOnQueue(_ state: MusicState, artSource: URL?) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: artDir, withIntermediateDirectories: true)
        } catch {
            log("writer: can't create \(artDir.path): \(error.localizedDescription)")
            return
        }
        var state = state
        // 1. Cover first, so the JSON never names a file that isn't there yet.
        if let name = state.artwork {
            let dst = artDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                guard let src = artSource, copyAtomically(src, to: dst) else {
                    log("writer: artwork \(name) unavailable — writing without it")
                    state.artwork = nil
                    return finishJSON(state)
                }
            }
            if name != currentArt { previousArt = currentArt; currentArt = name }
        }
        finishJSON(state)
    }

    private func finishJSON(_ state: MusicState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        do {
            try data.write(to: jsonURL, options: .atomic)
            statsLock.lock(); _writes += 1; statsLock.unlock()
        } catch {
            log("writer: music.json write FAILED: \(error.localizedDescription)")
        }
        prune(keeping: [state.artwork, previousArt].compactMap { $0 })
    }

    /// Copy to a temp name in the same folder, then rename(2) — readers never see a partial file.
    private func copyAtomically(_ src: URL, to dst: URL) -> Bool {
        let tmp = artDir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
            guard rename(tmp.path, dst.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            log("writer: copy \(src.lastPathComponent) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes covers other than `keep`, and temp files a crash left behind.
    private func prune(keeping keep: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: artDir.path) else { return }
        let keepSet = Set(keep)
        for f in files where !keepSet.contains(f) && (f.hasPrefix("art-") || f.hasPrefix(".tmp-")) {
            try? fm.removeItem(at: artDir.appendingPathComponent(f))
        }
        if previousArt.map({ !keepSet.contains($0) }) ?? false { previousArt = nil }
    }
}
