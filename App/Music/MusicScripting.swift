//  MusicScripting.swift — the Apple Events side of music detection: just enough of the
//  Spotify and Music scripting dictionaries for DotStudio, plus one serial queue that owns
//  every scripting handle (and a separate one for the blocking permission prompt).
//
//  Rules (the reason this file exists rather than `tell application "Spotify"`):
//  - Never launch a player. Handles are addressed by the pid of an ALREADY-RUNNING process
//    (`SBApplication(processIdentifier:)`), so an event sent after the player quit fails
//    instead of relaunching it.
//  - Never on the main thread. Every event is a blocking round trip to another process;
//    they all run on `MusicAppleEvents.queue` with a short timeout.
//  - Never throw. A failed event (no current track, player quitting, permission denied)
//    comes back as nil through an error-sink delegate that records the error code.
//  - Permission is checked with AEDeterminePermissionToAutomateTarget(askUserIfNeeded:
//    false), which never shows a prompt. Only `requestPermission` (an explicit user action,
//    or the first sign of playback) may ask — on `permissionQueue`, never on `queue`: the
//    ask blocks until the owner answers macOS's prompt, and reads, artwork and controls for
//    BOTH players must keep flowing meanwhile.

import AppKit
import ScriptingBridge

// MARK: - Scripting dictionaries (only what DotStudio reads or sends)

/// Spotify's `application` class. Player state is read as its raw four-char code
/// ('kPSP' playing, 'kPSp' paused, 'kPSS' stopped) — see `MusicPlayerStateCode`.
@objc protocol MusicSpotifyScriptable {
    @objc optional var currentTrack: MusicSpotifyTrackScriptable { get }
    @objc optional var playerState: AEKeyword { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
    @objc optional func setPlayerPosition(_ seconds: Double)
}

/// Spotify's `track` class. `duration` is in milliseconds despite the dictionary's wording.
@objc protocol MusicSpotifyTrackScriptable {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Int { get }
    @objc optional var artworkUrl: String { get }
    @objc optional func id() -> String
}

/// Music's `application` class.
@objc protocol MusicAppleMusicScriptable {
    @objc optional var currentTrack: MusicAppleMusicTrackScriptable { get }
    @objc optional var playerState: AEKeyword { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func backTrack()
    @objc optional func setPlayerPosition(_ seconds: Double)
}

/// Music's `track` class (`duration` in seconds; `persistentID` is a 16-digit hex string).
@objc protocol MusicAppleMusicTrackScriptable {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: String { get }
    @objc optional func artworks() -> SBElementArray
}

/// Music's `artwork` class: `rawData` is the original bytes, `data` a decoded picture.
@objc protocol MusicAppleMusicArtworkScriptable {
    @objc optional var rawData: Any { get }
    @objc optional var data: NSImage { get }
}

extension SBApplication: MusicSpotifyScriptable, MusicAppleMusicScriptable {}
extension SBObject: MusicSpotifyTrackScriptable, MusicAppleMusicTrackScriptable, MusicAppleMusicArtworkScriptable {}

/// The players' shared `ePlS` enumeration, as raw four-char codes.
enum MusicPlayerStateCode {
    static let stopped: AEKeyword = 0x6B50_5353        // 'kPSS'
    static let playing: AEKeyword = 0x6B50_5350        // 'kPSP'
    static let paused: AEKeyword = 0x6B50_5370         // 'kPSp'
    static let fastForwarding: AEKeyword = 0x6B50_5346 // 'kPSF' (Music)
    static let rewinding: AEKeyword = 0x6B50_5352      // 'kPSR' (Music)

    static func playState(_ code: AEKeyword?) -> MusicPlayState? {
        switch code {
        case playing?, fastForwarding?, rewinding?: return .playing
        case paused?: return .paused
        case stopped?: return .stopped
        default: return nil   // 0 = the event failed
        }
    }
}

// MARK: - Automation permission

/// Whether macOS lets DotStudio send Apple Events to a player
/// (System Settings → Privacy & Security → Automation).
enum MusicAutomationStatus: String, Equatable {
    /// Granted — exact position, artwork and controls work.
    case allowed
    /// Refused — DotStudio falls back to notification payloads + public artwork lookups;
    /// controls are unavailable. Fix: `MusicMonitor.openAutomationSettings()`.
    case denied
    /// Never asked yet. The first read (or `requestAutomation`) shows macOS's prompt.
    case notDetermined
    /// Player not running, or the check failed.
    case unknown

    init(status: OSStatus) {
        switch status {
        case noErr: self = .allowed
        case OSStatus(errAEEventNotPermitted): self = .denied
        case OSStatus(errAEEventWouldRequireUserConsent): self = .notDetermined
        default: self = .unknown
        }
    }
}

// MARK: - Error sink

/// Swallows failed events so ScriptingBridge returns nil instead of raising, and remembers
/// the last error so callers can tell "no track" from "permission denied" or a timeout.
final class MusicScriptingErrorSink: NSObject, SBApplicationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int = 0

    func reset() { lock.lock(); code = 0; lock.unlock() }
    var lastErrorCode: Int { lock.lock(); defer { lock.unlock() }; return code }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lock.lock(); code = (error as NSError).code; lock.unlock()
        return nil
    }
}

// MARK: - The Apple Events queue

/// Owns every scripting handle. All methods named `…OnQueue` must run on `queue`.
final class MusicAppleEvents: @unchecked Sendable {   // queue-confined handles + locked counters
    struct Config {
        /// false ⇒ no Apple Events at all (tests, or a future "notifications only" mode).
        var enabled = true
        /// Tests: count would-be events but never send them (and never create handles).
        var dryRun = false
        /// Seconds a read may take before it's abandoned (a busy player, a hung process).
        var readTimeout: TimeInterval = 2
        /// Controls get a little longer: the player may be switching tracks.
        var commandTimeout: TimeInterval = 4
        /// A control still waiting in `queue` this long after the click is dropped (a hung
        /// player held the queue): firing it seconds later would surprise the owner.
        var commandMaxQueueDelay: TimeInterval = 2
        /// Dry-run only (tests): what the silent check reports per player (default allowed),
        /// what the prompt is answered, and how long the owner takes to answer it.
        var dryRunStatus: [MusicSource: MusicAutomationStatus] = [:]
        var dryRunAnswer: MusicAutomationStatus = .allowed
        var dryRunAnswerDelay: TimeInterval = 0
    }

    /// The event the permission PROMPT is requested for. Not typeWildCard: wildcards are only
    /// dependable for the silent check (ask false). With askUserIfNeeded true, macOS can answer
    /// a wildcard request with errAEEventWouldRequireUserConsent WITHOUT ever showing the
    /// prompt — the owner would never be asked and controls would never work. So ask for a
    /// concrete event DotStudio really sends: Core Suite "get data" ('core'/'getd') — every
    /// property read (player state, position, track, artwork) is exactly that event, and the
    /// consent macOS records is per target app, so it covers play/pause/next/previous too.
    static let requestEventClass = AEEventClass(kAECoreSuite)
    static let requestEventID = AEEventID(kAEGetData)

    let config: Config
    let queue = DispatchQueue(label: "com.davidlam.DotStudio.music.appleevents", qos: .utility)
    /// Only `requestPermissionOnQueue` runs here: it can block for as long as the prompt is up.
    let permissionQueue = DispatchQueue(label: "com.davidlam.DotStudio.music.appleevents.permission", qos: .utility)

    // Queue-confined.
    private var handles: [pid_t: (app: SBApplication, sink: MusicScriptingErrorSink)] = [:]

    // Counters (any thread) — tests assert no events go to players that aren't running.
    private let statsLock = NSLock()
    private var eventCounts: [MusicSource: Int] = [:]
    private var permissionCounts: [MusicSource: Int] = [:]
    private var requestCounts: [MusicSource: Int] = [:]
    private var commandLog: [MusicSource: [MusicCommand]] = [:]

    init(config: Config) { self.config = config }

    /// Permission PROMPT requests per player (a subset of `permissionChecks`).
    func permissionRequests(_ source: MusicSource) -> Int { statsLock.lock(); defer { statsLock.unlock() }; return requestCounts[source] ?? 0 }
    /// Controls actually handed to a player (or, in dry-run, that would have been), in order.
    func sentCommands(_ source: MusicSource) -> [MusicCommand] { statsLock.lock(); defer { statsLock.unlock() }; return commandLog[source] ?? [] }
    func noteCommand(_ cmd: MusicCommand, to source: MusicSource) {
        statsLock.lock(); commandLog[source, default: []].append(cmd); statsLock.unlock()
    }

    /// Apple Event operations attempted (or, in dry-run, that would have been sent) per player.
    func attempts(_ source: MusicSource) -> Int { statsLock.lock(); defer { statsLock.unlock() }; return eventCounts[source] ?? 0 }
    /// Permission checks/requests per player.
    func permissionChecks(_ source: MusicSource) -> Int { statsLock.lock(); defer { statsLock.unlock() }; return permissionCounts[source] ?? 0 }
    var totalAttempts: Int { statsLock.lock(); defer { statsLock.unlock() }; return eventCounts.values.reduce(0, +) + permissionCounts.values.reduce(0, +) }

    private func count(_ source: MusicSource, permission: Bool = false) {
        statsLock.lock()
        if permission { permissionCounts[source, default: 0] += 1 } else { eventCounts[source, default: 0] += 1 }
        statsLock.unlock()
    }

    /// Runs `body` with a pid-addressed handle on the queue. Returns nil (without sending
    /// anything) when Apple Events are disabled, in dry-run, or the pid is gone. `errorCode`
    /// receives the last failed event's code (0 = all succeeded).
    func performOnQueue<T>(_ source: MusicSource, pid: pid_t, timeout: TimeInterval? = nil,
                           errorCode: UnsafeMutablePointer<Int>? = nil,
                           _ body: (SBApplication) -> T?) -> T? {
        dispatchPrecondition(condition: .onQueue(queue))
        errorCode?.pointee = 0
        guard config.enabled else { return nil }
        count(source)
        guard !config.dryRun else { return nil }
        // The process must still be alive and be the player we think it is.
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              running.bundleIdentifier == source.bundleID else {
            handles[pid] = nil
            errorCode?.pointee = Int(procNotFound)
            return nil
        }
        let handle: (app: SBApplication, sink: MusicScriptingErrorSink)
        if let h = handles[pid] {
            handle = h
        } else {
            guard let app = SBApplication(processIdentifier: pid) else { return nil }
            let sink = MusicScriptingErrorSink()
            app.delegate = sink
            handle = (app, sink)
            handles = handles.filter { NSRunningApplication(processIdentifier: $0.key)?.isTerminated == false }
            handles[pid] = handle
        }
        handle.app.timeout = max(1, Int((timeout ?? config.readTimeout) * 60))   // ticks
        handle.sink.reset()
        let result = body(handle.app)
        errorCode?.pointee = handle.sink.lastErrorCode
        return result
    }

    /// Never prompts. Must only be called for a running player (on the queue).
    func permissionStatusOnQueue(_ source: MusicSource, pid: pid_t) -> MusicAutomationStatus {
        dispatchPrecondition(condition: .onQueue(queue))
        guard config.enabled else { return .unknown }
        count(source, permission: true)
        guard !config.dryRun else { return config.dryRunStatus[source] ?? .allowed }   // dry-run: "allowed" by default
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return .unknown }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        // Wildcards are fine (and broadest) for the silent check — see requestEventClass.
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return MusicAutomationStatus(status: status)
    }

    /// May show macOS's "DotStudio wants to control <player>" prompt and blocks until it's
    /// answered — so it runs on `permissionQueue`, never `queue`. Only for an explicit user
    /// action or the first sign of playback.
    func requestPermissionOnQueue(_ source: MusicSource, pid: pid_t) -> MusicAutomationStatus {
        dispatchPrecondition(condition: .onQueue(permissionQueue))
        guard config.enabled else { return .unknown }
        count(source, permission: true)
        statsLock.lock(); requestCounts[source, default: 0] += 1; statsLock.unlock()
        guard !config.dryRun else {
            if config.dryRunAnswerDelay > 0 { Thread.sleep(forTimeInterval: config.dryRunAnswerDelay) }
            return config.dryRunAnswer
        }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return .unknown }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        // A concrete event, not typeWildCard (see requestEventClass): with ask true a wildcard
        // may be refused as "would require consent" without the prompt ever appearing.
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, Self.requestEventClass, Self.requestEventID, true)
        return MusicAutomationStatus(status: status)
    }

    /// Drops a quit player's handle (on the queue).
    func forgetOnQueue(pid: pid_t) { handles[pid] = nil }
}
