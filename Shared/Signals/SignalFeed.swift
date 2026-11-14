//  SignalFeed.swift — the reader side of signal-values.json (SignalState, Signal.swift), like
//  WeatherFeed: one stat per poll, a decode only when the file changed. Every host that asks
//  "what plays now?" (the saver per display, dotstudio-mcp, the self-tests) reads through it; the
//  app keeps its own in-memory state (SignalService) and never reads the file back.
//
//  Test hook: DOTSTUDIO_SIGNALS_FAKE=<path to a SignalState JSON> reads that file instead.
//  Phase 2 (scene inputs): a SignalLink per MetalRenderer polls this the same way.

import Foundation

final class SignalFeed {
    let fileURL: URL
    private let filePath: String
    private(set) var state: SignalState?
    /// Bumps whenever `state` changes.
    private(set) var revision = 0
    private var lastModified: FileStamp?
    private var checked = false

    init(baseDir: URL) {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_SIGNALS_FAKE"], !fake.isEmpty {
            fileURL = URL(fileURLWithPath: fake)
        } else {
            fileURL = baseDir.appendingPathComponent(SignalState.fileName)
        }
        filePath = fileURL.path
    }

    /// Re-reads the file if it changed. Returns true when the state changed.
    @discardableResult
    func poll() -> Bool {
        let mod = FileStamp(path: filePath)
        guard !checked || mod != lastModified else { return false }
        checked = true
        lastModified = mod
        let new: SignalState? = mod == nil ? nil
            : (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(SignalState.self, from: $0) }
        guard new != state else { return false }
        state = new
        revision &+= 1
        return true
    }
}
