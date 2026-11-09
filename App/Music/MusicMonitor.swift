//  MusicMonitor.swift — watches Spotify and Apple Music and publishes what's playing:
//  to SwiftUI (the @Published properties below) and to every renderer (music.json + cover,
//  via MusicStateWriter). The NotchTune approach, reimplemented for DotStudio.
//
//  Event-driven; idle costs nothing:
//  - Wake-ups are the players' own distributed notifications, observed by exact name with
//    the selector API and `.deliverImmediately` (the block API coalesces while DotStudio is
//    inactive — which it nearly always is), plus NSWorkspace launch/terminate.
//  - Notification payloads alone are enough (prompt-free baseline). Apple Events add exact
//    position, the state at launch, artwork and controls — only when the player is RUNNING
//    (pid-addressed, never launched) and Automation is allowed; always off the main thread.
//  - A 1 s position poll runs only while some UI asks for it (begin/endPositionUpdates) and
//    Apple Events are allowed; otherwise readers extrapolate `position + (now − positionAt)`.
//
//  Lifecycle (for the UI stage):
//      MusicMonitor.shared.start(store:)          // no-op unless library.musicSettings.needsMonitoring
//      MusicMonitor.shared.apply(settings:)       // on every library change (starts/stops, source pin)
//      MusicMonitor.shared.stop()                 // clears music.json
//  Controls: playPause() / next() / previous() / skip(seconds:) — optimistic, with a 1.5 s
//  window in which a stale player report can't flip the play state back.
//
//  Test hooks (environment):
//      DOTSTUDIO_MUSIC_MONITOR_LOG=1      log transitions to <store>/debug.log (and stderr)
//      DOTSTUDIO_MUSIC_NO_AE=1            never send Apple Events (payloads + lookups only)
//      DOTSTUDIO_MUSIC_NO_NETWORK=1       no artwork lookups
//      DOTSTUDIO_MUSIC_NOTIFY_PREFIX=<p>  observe "<p><real name>" instead (synthetic tests
//                                         never disturb other apps listening to the real ones)

import AppKit
import Combine

/// One player as the UI shows it ("Spotify · Playing", "Allow DotStudio to control Music").
struct MusicPlayerStatus: Equatable {
    var source: MusicSource
    var isInstalled = false
    var isRunning = false
    var isPlaying = false
    var hasTrack = false
    var automation: MusicAutomationStatus = .unknown

    /// Controls can be sent (an undetermined permission is asked for on the first click).
    var canControl: Bool { isRunning && automation != .denied }
    /// Show the "Allow DotStudio to read <player>" fix-it.
    var needsAutomationFix: Bool { isRunning && automation == .denied }
}

@MainActor
final class MusicMonitor: ObservableObject {
    struct Options {
        var appleEvents = MusicAppleEvents.Config()
        var art = MusicArtworkResolver.Config()
        /// Tests: listen on "<prefix><real name>" so synthetic posts stay private.
        var notificationPrefix = ""
        /// NSWorkspace launch/terminate + initial running scan.
        var observeWorkspace = true
        /// Ask macOS for Automation on the first sign of playback (a "Playing" notification).
        var autoRequestsAutomation = true
        /// Tests: pretend these players run with this pid (Apple Events must be dry-run).
        var pidOverride: [MusicSource: pid_t]?
        /// Longest a new track's write waits for its cover before going out without it.
        var artWait: TimeInterval = 1.2
        /// Optimistic play/pause window.
        var pendingWindow: TimeInterval = 1.5
        /// Artwork cache; nil = ~/Library/Caches/com.davidlam.DotStudio/MusicArt
        /// (or <store>/music-cache when DOTSTUDIO_STORE_DIR redirects the store).
        var cacheDir: URL?
        /// nil = DOTSTUDIO_MUSIC_MONITOR_LOG=1 or the store's debug.enabled.
        var logging: Bool?
        var logToStderr = false

        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Options {
            var o = Options()
            if env["DOTSTUDIO_MUSIC_NO_AE"] == "1" { o.appleEvents.enabled = false }
            if env["DOTSTUDIO_MUSIC_NO_NETWORK"] == "1" { o.art.networkEnabled = false }
            if let p = env["DOTSTUDIO_MUSIC_NOTIFY_PREFIX"], !p.isEmpty { o.notificationPrefix = p }
            if env["DOTSTUDIO_MUSIC_MONITOR_LOG"] == "1" { o.logging = true; o.logToStderr = true }
            return o
        }
    }

    static let shared = MusicMonitor()

    // MARK: Published (UI)

    /// Exactly what renderers see in music.json (`hasTrack == false` ⇒ nothing playing).
    @Published private(set) var state = MusicState()
    /// The current cover (≤ 512 px) for in-app UI; nil = placeholder.
    @Published private(set) var artwork: CGImage?
    @Published private(set) var spotify = MusicPlayerStatus(source: .spotify)
    @Published private(set) var music = MusicPlayerStatus(source: .music)
    /// The player whose track is shown (auto = the one that most recently started playing).
    @Published private(set) var activeSource: MusicSource?
    @Published private(set) var isMonitoring = false

    var players: [MusicPlayerStatus] { [spotify, music] }
    func status(for source: MusicSource) -> MusicPlayerStatus { source == .music ? music : spotify }
    /// True while a play/pause click waits for the player to agree.
    var isControlPending: Bool { activeSource.flatMap { records[$0]?.pending }.map { Date() < $0.until } ?? false }

    // MARK: Internals

    private struct Track: Equatable {
        var key: String
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var trackID: String?
        var storeTrackID: String?
        var storeAlbumID: String?
        var isLocal = false
        var isAd = false
        var isEpisode = false
        /// NotchTune's heuristic: anything over 15 minutes is long-form.
        var isPodcast: Bool { isEpisode || (duration ?? 0) > 15 * 60 }

        init(_ r: MusicReport) {
            title = r.title; artist = r.artist; album = r.album; duration = r.duration
            trackID = r.trackID; storeTrackID = r.storeTrackID; storeAlbumID = r.storeAlbumID
            isLocal = r.isLocal; isAd = r.isAd; isEpisode = r.isEpisode
            key = r.trackID.map { "\(r.source.rawValue)|\($0)" }
                ?? "\(r.source.rawValue)|meta|\(r.title ?? "")|\(r.artist ?? "")|\(r.album ?? "")"
        }

        /// Later reports may fill in fields an earlier one lacked (AE snapshot vs payload).
        mutating func merge(_ o: Track) {
            if duration == nil || (o.duration ?? 0) > 0 { duration = o.duration ?? duration }
            if (artist ?? "").isEmpty { artist = o.artist }
            if (album ?? "").isEmpty { album = o.album }
            storeTrackID = storeTrackID ?? o.storeTrackID
            storeAlbumID = storeAlbumID ?? o.storeAlbumID
        }
    }

    private struct Record {
        let source: MusicSource
        var pid: pid_t?
        var running = false
        var track: Track?
        var isPlaying = false
        var position: Double = 0
        var positionAt: Double = 0
        var approximate = false
        var pausedAt: Double?
        /// Last transition into playing (auto source = most recent wins).
        var playStartedAt: Double = 0
        /// Last moment seen playing (auto source fallback when nothing plays).
        var lastPlayingAt: Double = 0
        var art: MusicArtResult?
        var artKey: String?
        var pending: (playing: Bool, until: Date)?
        var automation: MusicAutomationStatus = .unknown
        var automationCheckedAt: Date?
        var askedAutomation = false

        init(source: MusicSource) { self.source = source }

        func elapsed(at t: Double) -> Double {
            var p = position
            if isPlaying { p += max(0, t - positionAt) }
            if let d = track?.duration, d > 0 { p = min(p, d) }
            return max(0, p)
        }
    }

    private(set) var options: Options
    private(set) var settings = MusicSpec()
    private var store: SharedStore?
    private var installed: [MusicSource: Bool] = [:]
    private(set) var writer: MusicStateWriter?
    private(set) var resolver: MusicArtworkResolver?
    private(set) var appleEvents: MusicAppleEvents
    private let adapters: [MusicSource: MusicPlayerAdapter] = [
        .spotify: MusicSpotifyAdapter(), .music: MusicAppleMusicAdapter(),
    ]
    private var records: [MusicSource: Record] = [.spotify: Record(source: .spotify), .music: Record(source: .music)]
    private var receiver: MusicNotificationReceiver?
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var artTasks: [MusicSource: Task<Void, Never>] = [:]
    private var artGeneration: [MusicSource: Int] = [:]
    private var lastWritten: MusicState?
    private var artWaitDeadline: Date?
    private var artWaitItem: DispatchWorkItem?
    private var positionClients = 0
    private var pollTimer: Timer?
    private var pollInFlight = false
    private(set) var pollTicks = 0
    private var logger = MusicLog(enabled: false, url: nil, stderr: false)

    init(options: Options = .fromEnvironment()) {
        self.options = options
        appleEvents = MusicAppleEvents(config: options.appleEvents)
    }

    // MARK: - Lifecycle

    /// Starts watching when the library's music settings need it (card, wallpaper card or
    /// take-over). Returns whether monitoring is on. Safe to call repeatedly.
    @discardableResult
    func start(store: SharedStore, settings: MusicSpec? = nil) -> Bool {
        let settings = settings ?? store.load()?.musicSettings ?? MusicSpec()
        self.settings = settings
        self.store = store
        guard settings.needsMonitoring else {
            if isMonitoring { stop() }
            return false
        }
        guard !isMonitoring else { updateActive(); commit(force: false); return true }
        logger = MusicLog(enabled: options.logging ?? (ProcessInfo.processInfo.environment["DOTSTUDIO_MUSIC_MONITOR_LOG"] == "1" || store.debugEnabled),
                          url: store.writableDir.appendingPathComponent("debug.log"),
                          stderr: options.logToStderr)
        let log = logger
        writer = MusicStateWriter(baseDir: store.baseDir, log: { log.write($0) })
        appleEvents = MusicAppleEvents(config: options.appleEvents)
        let ae = appleEvents
        let adapters = self.adapters
        resolver = MusicArtworkResolver(cacheDir: options.cacheDir ?? Self.defaultCacheDir(store: store),
                                        config: options.art, log: { log.write($0) }) { req in
            guard let pid = req.pid, let adapter = adapters[req.source] else { return nil }
            return await withCheckedContinuation { cont in
                ae.queue.async {
                    let payload = ae.performOnQueue(req.source, pid: pid) { app in
                        adapter.readArtwork(app, expectedTrackID: req.trackID)
                    }
                    cont.resume(returning: payload)
                }
            }
        }
        records = [.spotify: Record(source: .spotify), .music: Record(source: .music)]
        lastWritten = nil
        isMonitoring = true
        observe()
        log.write("monitor: start (source \(settings.sourcePreference.rawValue), AE \(options.appleEvents.enabled ? (options.appleEvents.dryRun ? "dry-run" : "on") : "off"), prefix '\(options.notificationPrefix)')")

        // Players already running: learn their state (needs Automation; never prompts here).
        for source in [MusicSource.spotify, .music] {
            if let pid = options.pidOverride?[source] {
                records[source]?.pid = pid; records[source]?.running = true
            } else if options.observeWorkspace, let app = NSRunningApplication.runningApplications(withBundleIdentifier: adapters[source]!.bundleID).first(where: { !$0.isTerminated }) {
                records[source]?.pid = app.processIdentifier; records[source]?.running = true
            }
            if records[source]?.running == true {
                refreshAutomation(source) { [weak self] in self?.readSnapshot(source, reason: "start") }
            }
        }
        publishStatuses()
        commit(force: true)   // clears whatever a previous session left in music.json
        return true
    }

    /// Stops watching and clears music.json (renderers show nothing).
    func stop() {
        guard isMonitoring else { return }
        unobserve()
        for t in artTasks.values { t.cancel() }
        artTasks.removeAll()
        artWaitItem?.cancel(); artWaitItem = nil; artWaitDeadline = nil
        pollTimer?.invalidate(); pollTimer = nil
        records = [.spotify: Record(source: .spotify), .music: Record(source: .music)]
        activeSource = nil
        artwork = nil
        state = MusicState()
        writer?.write(MusicState(updatedAt: Date().timeIntervalSince1970), artSource: nil)
        writer?.flush()
        logger.write("monitor: stop")
        isMonitoring = false
        publishStatuses()
    }

    /// Call whenever the library's music settings change: starts/stops monitoring and
    /// re-picks the source (Automatic / Spotify / Apple Music).
    func apply(settings: MusicSpec) {
        let old = self.settings
        self.settings = settings
        if settings.needsMonitoring, !isMonitoring, let store {
            start(store: store, settings: settings)
        } else if !settings.needsMonitoring, isMonitoring {
            stop()
        } else if old.sourcePreference != settings.sourcePreference {
            logger.write("monitor: source preference → \(settings.sourcePreference.rawValue)")
            updateActive()
            commit(force: false)
        }
    }

    static func defaultCacheDir(store: SharedStore) -> URL {
        if ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil {
            return store.baseDir.appendingPathComponent("music-cache", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? store.baseDir
        return caches.appendingPathComponent("com.davidlam.DotStudio/MusicArt", isDirectory: true)
    }

    // MARK: - Observation

    private func observe() {
        let receiver = MusicNotificationReceiver { [weak self] name, info in
            MainActor.assumeIsolated { self?.received(name: name, userInfo: info) }
        }
        self.receiver = receiver
        let dnc = DistributedNotificationCenter.default()
        for adapter in adapters.values {
            for name in adapter.notificationNames {
                dnc.addObserver(receiver, selector: #selector(MusicNotificationReceiver.received(_:)),
                                name: Notification.Name(options.notificationPrefix + name), object: nil,
                                suspensionBehavior: .deliverImmediately)
            }
        }
        if options.observeWorkspace {
            let wnc = NSWorkspace.shared.notificationCenter
            let launch = wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.workspace(launched: app) }
            }
            let quit = wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.workspace(terminated: app) }
            }
            observerTokens += [(wnc, launch), (wnc, quit)]
        }
        // Coming back from System Settings → re-check Automation (the grant has no event).
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAutomationForRunning(force: true) }
        }
        observerTokens.append((NotificationCenter.default, active))
    }

    private func unobserve() {
        if let receiver { DistributedNotificationCenter.default().removeObserver(receiver) }
        receiver = nil
        for (center, token) in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()
    }

    private func adapter(forNotification name: String) -> MusicPlayerAdapter? {
        let real = name.hasPrefix(options.notificationPrefix) ? String(name.dropFirst(options.notificationPrefix.count)) : name
        return adapters.values.first { $0.notificationNames.contains(real) }
    }

    private func received(name: String, userInfo: [AnyHashable: Any]?) {
        guard isMonitoring, let adapter = adapter(forNotification: name) else { return }
        let report = adapter.parse(userInfo)
        let source = adapter.source
        logger.write("notify \(source.rawValue): state=\(report.state?.rawValue ?? "?") title=\(report.title ?? "∅") id=\(report.trackID ?? "∅") pos=\(report.position.map { String(format: "%.1f", $0) } ?? "∅") dur=\(report.duration.map { String(format: "%.1f", $0) } ?? "∅")")
        // A player that posts is running (pid comes from NSWorkspace, or the test override).
        if report.state != .stopped, records[source]?.running == false { records[source]?.running = true }
        ingest(report)

        guard report.state == .playing || report.state == .paused else { return }
        if records[source]?.automationCheckedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            refreshAutomation(source) { [weak self] in self?.maybeAutoRequest(source) }
        } else {
            maybeAutoRequest(source)
        }
        // Music's payload has no position: one exact read when allowed.
        if source == .music, report.position == nil, canUseAppleEvents(source) {
            readPosition(source)
        }
    }

    private func workspace(launched app: NSRunningApplication?) {
        guard isMonitoring, let app, let source = source(forBundle: app.bundleIdentifier) else { return }
        records[source]?.pid = app.processIdentifier
        records[source]?.running = true
        records[source]?.automationCheckedAt = nil
        logger.write("workspace: \(source.rawValue) launched (pid \(app.processIdentifier))")
        publishStatuses()
        // Give the player a moment to finish launching before the first event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshAutomation(source) { self?.readSnapshot(source, reason: "launch") }
            }
        }
    }

    private func workspace(terminated app: NSRunningApplication?) {
        guard isMonitoring, let app, let source = source(forBundle: app.bundleIdentifier) else { return }
        playerQuit(source, pid: app.processIdentifier)
    }

    /// The player quit: forget its handle and clear its track.
    func playerQuit(_ source: MusicSource, pid: pid_t? = nil) {
        guard isMonitoring, var r = records[source] else { return }
        logger.write("workspace: \(source.rawValue) quit")
        if let pid = pid ?? r.pid { appleEvents.queue.async { [ae = appleEvents] in ae.forgetOnQueue(pid: pid) } }
        r.pid = nil
        r.running = false
        r.automation = .unknown
        records[source] = r
        clearTrack(source)
        afterChange()
    }

    private func source(forBundle id: String?) -> MusicSource? {
        adapters.values.first { $0.bundleID == id }?.source
    }

    private func pid(for source: MusicSource) -> pid_t? {
        if let o = options.pidOverride { return o[source] }
        return records[source]?.pid
    }

    private func canUseAppleEvents(_ source: MusicSource) -> Bool {
        options.appleEvents.enabled && pid(for: source) != nil && records[source]?.automation == .allowed
    }

    // MARK: - State machine

    private func clearTrack(_ source: MusicSource) {
        artTasks[source]?.cancel(); artTasks[source] = nil
        artGeneration[source, default: 0] += 1
        guard var r = records[source] else { return }
        r.track = nil; r.art = nil; r.artKey = nil
        r.isPlaying = false; r.pausedAt = nil; r.pending = nil
        r.position = 0; r.positionAt = 0; r.approximate = false
        records[source] = r
    }

    /// Folds one observation into the player's record. Pure bookkeeping + scheduling.
    private func ingest(_ report: MusicReport) {
        let source = report.source
        guard var r = records[source] else { return }
        let now = Date().timeIntervalSince1970

        if report.state == .stopped {
            logger.write("\(source.rawValue): stopped → clear")
            clearTrack(source)
            afterChange()
            return
        }
        if report.state == nil && report.isEmptyTrack {
            // Garbage / unknown shape: no recognisable state and no title. Don't let it
            // clear a good track.
            logger.write("\(source.rawValue): ignored payload (no recognisable state or title)")
            return
        }
        if report.state != nil && report.hasTrackFields && report.isEmptyTrack {
            if r.track != nil { logger.write("\(source.rawValue): empty track → nothing playing") }
            clearTrack(source)
            afterChange()
            return
        }

        var trackChanged = false
        let firstSighting = r.track == nil
        if report.hasTrackFields {
            let incoming = Track(report)
            if r.track?.key != incoming.key {
                r.track = incoming
                r.position = report.position.map { min($0, incoming.duration ?? $0) } ?? 0
                r.positionAt = now
                r.approximate = report.position == nil
                r.art = nil; r.artKey = nil
                trackChanged = true
            } else {
                r.track?.merge(incoming)
            }
        } else if r.track == nil {
            // A bare state change about a track we never saw: nothing to show yet.
            records[source] = r
            if canUseAppleEvents(source) { readSnapshot(source, reason: "unknown track") }
            return
        }

        // Play state, honouring an optimistic play/pause click.
        let wasPlaying = r.isPlaying
        var playing = report.state.map { $0 == .playing } ?? wasPlaying
        if let p = r.pending {
            if Date() < p.until, playing != p.playing {
                playing = wasPlaying
            } else {
                r.pending = nil
            }
        }

        // Position.
        if !trackChanged {
            let extrapolated = r.elapsed(at: now)
            if let pos = report.position {
                if wasPlaying != playing || r.approximate || abs(pos - extrapolated) > 1.5 {
                    r.position = pos; r.positionAt = now; r.approximate = false
                }
            } else if wasPlaying != playing {
                r.position = extrapolated; r.positionAt = now          // freeze / resume
            } else if playing, let d = r.track?.duration, d > 0, extrapolated >= d - 1.5 {
                r.position = 0; r.positionAt = now                    // same track again (repeat one)
            }
        }

        // Play / pause transitions.
        if playing {
            if !wasPlaying || trackChanged { r.playStartedAt = now }
            r.pausedAt = nil
            r.lastPlayingAt = now
        } else {
            if wasPlaying {
                r.pausedAt = now
                r.lastPlayingAt = now
            } else if firstSighting && report.origin == .appleEvents {
                // Found paused at launch: we don't know since when — don't linger it.
                r.pausedAt = now - 86_400
            } else if trackChanged || r.pausedAt == nil {
                r.pausedAt = now                                      // the user just changed it
            }
        }
        r.isPlaying = playing
        if report.state != nil { r.running = true }
        records[source] = r

        if trackChanged {
            logger.write("\(source.rawValue): track → \(r.track?.title ?? "") — \(r.track?.artist ?? "") [\(r.track?.trackID ?? "no id")]\(r.track?.isPodcast == true ? " (podcast)" : "")")
            startArt(source)
        } else if wasPlaying != playing {
            logger.write("\(source.rawValue): \(playing ? "playing" : "paused") at \(String(format: "%.1f", r.position))s")
        }
        afterChange()
    }

    private func afterChange() {
        updateActive()
        publishStatuses()
        commit(force: false)
        updatePollTimer()
    }

    private func updateActive() {
        let withTrack = [MusicSource.spotify, .music].compactMap { s -> Record? in
            guard let r = records[s], r.track != nil else { return nil }
            return r
        }
        let chosen: MusicSource?
        switch settings.sourcePreference {
        case .spotify: chosen = withTrack.contains { $0.source == .spotify } ? .spotify : nil
        case .music: chosen = withTrack.contains { $0.source == .music } ? .music : nil
        case .auto:
            if let p = withTrack.filter(\.isPlaying).max(by: { $0.playStartedAt < $1.playStartedAt }) {
                chosen = p.source
            } else {
                chosen = withTrack.max(by: { $0.lastPlayingAt < $1.lastPlayingAt })?.source
            }
        }
        if chosen != activeSource {
            logger.write("active source → \(chosen?.rawValue ?? "none")")
            activeSource = chosen
        }
        let image = chosen.flatMap { s -> CGImage? in
            guard let r = records[s], r.artKey == r.track?.key else { return nil }
            return r.art?.image
        }
        if image !== artwork { artwork = image }
    }

    private func publishStatuses() {
        for source in [MusicSource.spotify, .music] {
            let r = records[source] ?? Record(source: source)
            var s = status(for: source)
            if installed[source] == nil {
                installed[source] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: adapters[source]!.bundleID) != nil
            }
            s.isInstalled = installed[source] ?? false
            s.isRunning = r.running && isMonitoring
            s.isPlaying = r.isPlaying && r.track != nil
            s.hasTrack = r.track != nil
            s.automation = r.automation
            if source == .spotify { if s != spotify { spotify = s } } else if s != music { music = s }
        }
    }

    // MARK: - Commit (publish + write)

    private func compose() -> (MusicState, URL?) {
        guard let src = activeSource, let r = records[src], let t = r.track else { return (MusicState(), nil) }
        var s = MusicState()
        s.source = src
        s.title = t.title
        s.artist = t.artist
        s.album = t.album
        s.duration = t.duration
        s.position = (r.position * 1000).rounded() / 1000
        s.positionAt = (r.positionAt * 1000).rounded() / 1000
        s.positionIsApproximate = r.approximate
        s.isPlaying = r.isPlaying
        s.pausedAt = r.isPlaying ? nil : r.pausedAt
        s.trackID = t.trackID
        s.isPodcast = t.isPodcast
        var artURL: URL?
        if r.artKey == t.key, let art = r.art {
            s.artwork = art.fileName
            s.palette = art.palette
            artURL = art.fileURL
        }
        return (s, artURL)
    }

    /// The active track is new and its cover is still being looked up.
    private var waitingForArt: Bool {
        guard let src = activeSource, let r = records[src], let t = r.track else { return false }
        return r.artKey != t.key && artTasks[src] != nil
    }

    /// Publishes + writes the composed state if it changed. A brand-new track waits up to
    /// `artWait` for its cover (so the card doesn't flash a placeholder), measured from the
    /// FIRST unsent change — rapid skips coalesce into one write.
    private func commit(force: Bool) {
        if !force, waitingForArt {
            let deadline = artWaitDeadline ?? Date().addingTimeInterval(options.artWait)
            if artWaitDeadline == nil {
                artWaitDeadline = deadline
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.artWaitItem = nil
                        self?.artWaitDeadline = nil
                        self?.commit(force: true)
                    }
                }
                artWaitItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
            }
            return
        }
        artWaitItem?.cancel(); artWaitItem = nil; artWaitDeadline = nil
        var (s, artURL) = compose()
        if s != state { state = s }
        guard force || s != lastWritten else { return }
        lastWritten = s
        s.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        writer?.write(s, artSource: artURL)
    }

    // MARK: - Artwork

    private func startArt(_ source: MusicSource) {
        artTasks[source]?.cancel()
        artTasks[source] = nil
        guard let resolver, let r = records[source], let t = r.track else { return }
        var req = MusicArtRequest(source: source, trackKey: t.key)
        req.trackID = t.trackID; req.title = t.title; req.artist = t.artist; req.album = t.album
        req.storeTrackID = t.storeTrackID; req.storeAlbumID = t.storeAlbumID
        req.isLocal = t.isLocal; req.isAd = t.isAd; req.isEpisode = t.isEpisode
        req.useAppleEvents = canUseAppleEvents(source)
        req.pid = pid(for: source)
        let gen = artGeneration[source, default: 0] + 1
        artGeneration[source] = gen
        let key = t.key
        artTasks[source] = Task { [weak self] in
            let result = await resolver.resolve(req)
            guard let self, !Task.isCancelled, self.artGeneration[source] == gen else { return }
            self.artTasks[source] = nil
            self.artResolved(result, source: source, key: key)
        }
    }

    private func artResolved(_ result: MusicArtResult?, source: MusicSource, key: String) {
        guard var r = records[source], r.track?.key == key else { return }
        r.art = result
        r.artKey = key
        records[source] = r
        logger.write("\(source.rawValue): art \(result.map { "\($0.origin) \($0.fileName), \($0.palette.count) colours" } ?? "none (placeholder)")")
        updateActive()
        commit(force: false)
    }

    // MARK: - Apple Events reads

    private func readSnapshot(_ source: MusicSource, reason: String) {
        guard isMonitoring, canUseAppleEvents(source), let pid = pid(for: source), let adapter = adapters[source] else { return }
        let ae = appleEvents
        ae.queue.async { [weak self] in
            var err = 0
            let report = ae.performOnQueue(source, pid: pid, errorCode: &err) { adapter.readSnapshot($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.noteAppleEventError(err, source: source)
                    guard let report else { return }
                    self.logger.write("AE snapshot \(source.rawValue) (\(reason)): \(report.state?.rawValue ?? "?") \(report.title ?? "∅")")
                    self.ingest(report)
                }
            }
        }
    }

    private func readPosition(_ source: MusicSource, completion: (@MainActor () -> Void)? = nil) {
        guard isMonitoring, canUseAppleEvents(source), let pid = pid(for: source), let adapter = adapters[source] else {
            completion?(); return
        }
        let ae = appleEvents
        ae.queue.async { [weak self] in
            var err = 0
            let read = ae.performOnQueue(source, pid: pid, errorCode: &err) { app -> (MusicPlayState?, Double?)? in
                let r = adapter.readPosition(app)
                return (r.state, r.position)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { completion?() }
                    guard let self, self.isMonitoring else { return }
                    self.noteAppleEventError(err, source: source)
                    guard let (state, position) = read, let state else { return }
                    var report = MusicReport(source: source, origin: .appleEvents)
                    report.state = state
                    report.position = position
                    self.ingest(report)
                }
            }
        }
    }

    private func noteAppleEventError(_ code: Int, source: MusicSource) {
        guard code != 0 else { return }
        let status: MusicAutomationStatus?
        switch code {
        case Int(errAEEventNotPermitted): status = .denied
        case Int(errAEEventWouldRequireUserConsent): status = .notDetermined
        default: status = nil
        }
        logger.write("AE \(source.rawValue) error \(code)")
        if let status, records[source]?.automation != status {
            records[source]?.automation = status
            publishStatuses()
            updatePollTimer()
        }
    }

    // MARK: - Automation permission

    /// Re-checks without prompting (paced to once per 20 s unless `force`).
    func refreshAutomationStatus() { refreshAutomationForRunning(force: true) }

    private func refreshAutomationForRunning(force: Bool) {
        guard isMonitoring else { return }
        for source in [MusicSource.spotify, .music] where pid(for: source) != nil {
            refreshAutomation(source, force: force)
        }
    }

    private func refreshAutomation(_ source: MusicSource, force: Bool = false, then: (@MainActor () -> Void)? = nil) {
        guard isMonitoring, options.appleEvents.enabled, let pid = pid(for: source) else { then?(); return }
        if !force, let at = records[source]?.automationCheckedAt, Date().timeIntervalSince(at) < 20 { then?(); return }
        records[source]?.automationCheckedAt = Date()
        let ae = appleEvents
        ae.queue.async { [weak self] in
            let status = ae.permissionStatusOnQueue(source, pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.automationChanged(source, to: status)
                    then?()
                }
            }
        }
    }

    /// First sign of playback (a player reported Playing) and macOS hasn't asked yet: ask
    /// once per session, so the card gets exact progress and art from then on.
    private func maybeAutoRequest(_ source: MusicSource) {
        guard options.autoRequestsAutomation, let r = records[source], r.isPlaying,
              r.automation == .notDetermined, !r.askedAutomation, pid(for: source) != nil else { return }
        requestAutomation(for: source)
    }

    /// Asks macOS for permission to control `source` — shows the system prompt if the user
    /// hasn't answered yet. Only for a running player; never launches it.
    func requestAutomation(for source: MusicSource) {
        guard isMonitoring, options.appleEvents.enabled, let pid = pid(for: source) else { return }
        records[source]?.askedAutomation = true
        logger.write("automation: asking for \(source.rawValue)")
        let ae = appleEvents
        ae.queue.async { [weak self] in
            let status = ae.requestPermissionOnQueue(source, pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.records[source]?.automationCheckedAt = Date()
                    self.automationChanged(source, to: status)
                }
            }
        }
    }

    private func automationChanged(_ source: MusicSource, to status: MusicAutomationStatus) {
        guard var r = records[source] else { return }
        let old = r.automation
        r.automation = status
        records[source] = r
        guard old != status else { return }
        logger.write("automation \(source.rawValue): \(old.rawValue) → \(status.rawValue)")
        publishStatuses()
        updatePollTimer()
        if status == .allowed {
            // Newly allowed: exact state now, and upgrade a missing cover.
            readSnapshot(source, reason: "allowed")
            if r.track != nil, r.art == nil, artTasks[source] == nil { startArt(source) }
        }
    }

    /// Opens System Settings → Privacy & Security → Automation.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Position updates (UI-driven)

    /// A view that shows live progress calls this on appear (counted: overlapping views during
    /// a cross-fade are fine). Polls the exact position once a second, only while Apple
    /// Events are allowed for the active player; otherwise views extrapolate from `state`.
    func beginPositionUpdates() {
        positionClients += 1
        updatePollTimer()
    }

    func endPositionUpdates() {
        positionClients = max(0, positionClients - 1)
        updatePollTimer()
    }

    var isPollingPosition: Bool { pollTimer != nil }

    private func updatePollTimer() {
        let want = isMonitoring && positionClients > 0
            && activeSource.map { canUseAppleEvents($0) && records[$0]?.track != nil } ?? false
        if want, pollTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollTick() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
            pollTick()
        } else if !want, let t = pollTimer {
            t.invalidate()
            pollTimer = nil
        }
    }

    private func pollTick() {
        guard !pollInFlight, let source = activeSource else { return }
        pollInFlight = true
        pollTicks += 1
        readPosition(source) { [weak self] in self?.pollInFlight = false }
    }

    // MARK: - Controls

    /// Play/pause the active player (or `source`). Flips the UI at once; a contradicting
    /// report within 1.5 s is ignored. Returns false when it can't be sent (not running,
    /// Automation denied, Apple Events off).
    @discardableResult
    func playPause(_ source: MusicSource? = nil) -> Bool {
        guard let src = source ?? activeSource, var r = records[src], r.track != nil else { return false }
        guard sendable(src) else { return false }
        let now = Date().timeIntervalSince1970
        let target = !r.isPlaying
        r.position = r.elapsed(at: now); r.positionAt = now
        r.isPlaying = target
        if target { r.pausedAt = nil; r.playStartedAt = now; r.lastPlayingAt = now }
        else { r.pausedAt = now; r.lastPlayingAt = now }
        r.pending = (target, Date().addingTimeInterval(options.pendingWindow))
        records[src] = r
        logger.write("control \(src.rawValue): playPause → \(target ? "playing" : "paused") (optimistic)")
        afterChange()
        send(.playPause, to: src)
        return true
    }

    @discardableResult
    func next(_ source: MusicSource? = nil) -> Bool { command(.next, source) }

    @discardableResult
    func previous(_ source: MusicSource? = nil) -> Bool { command(.previous, source) }

    /// Podcasts: jump by ± seconds (the UI's 15 s buttons).
    @discardableResult
    func skip(seconds: Double, _ source: MusicSource? = nil) -> Bool {
        guard let src = source ?? activeSource, var r = records[src], r.track != nil, sendable(src),
              let pid = pid(for: src), let adapter = adapters[src] else { return false }
        let now = Date().timeIntervalSince1970
        let target = max(0, min(r.elapsed(at: now) + seconds, (r.track?.duration ?? .infinity) - 1))
        r.position = target; r.positionAt = now
        records[src] = r
        afterChange()
        let ae = appleEvents
        ae.queue.async { _ = ae.performOnQueue(src, pid: pid, timeout: ae.config.commandTimeout) { adapter.seek(to: target, in: $0) } }
        return true
    }

    private func command(_ cmd: MusicCommand, _ source: MusicSource?) -> Bool {
        guard let src = source ?? activeSource, records[src]?.track != nil, sendable(src) else { return false }
        logger.write("control \(src.rawValue): \(cmd.rawValue)")
        send(cmd, to: src)
        return true
    }

    private func sendable(_ source: MusicSource) -> Bool {
        isMonitoring && options.appleEvents.enabled && pid(for: source) != nil && records[source]?.automation != .denied
    }

    private func send(_ cmd: MusicCommand, to source: MusicSource) {
        guard let pid = pid(for: source), let adapter = adapters[source] else { return }
        let ask = records[source]?.automation != .allowed
        if ask { records[source]?.askedAutomation = true }
        let ae = appleEvents
        ae.queue.async { [weak self] in
            // A click is consent to ask: the prompt (if any) blocks only this queue.
            var status: MusicAutomationStatus = .allowed
            if ask, !ae.config.dryRun { status = ae.requestPermissionOnQueue(source, pid: pid) }
            var err = 0
            if status == .allowed {
                _ = ae.performOnQueue(source, pid: pid, timeout: ae.config.commandTimeout, errorCode: &err) { app -> Bool? in
                    adapter.send(cmd, to: app)
                    return true
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    if ask { self.automationChanged(source, to: status) }
                    self.noteAppleEventError(err, source: source)
                    if status != .allowed || err != 0 {
                        self.logger.write("control \(source.rawValue): \(cmd.rawValue) failed (\(status.rawValue), \(err))")
                        if cmd == .playPause { self.revertOptimistic(source) }
                    } else if source == .music {
                        // Music's notifications carry no position: re-read it once things settle.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            MainActor.assumeIsolated { self.readPosition(source) }
                        }
                    }
                }
            }
        }
    }

    private func revertOptimistic(_ source: MusicSource) {
        guard var r = records[source], r.pending != nil else { return }
        let now = Date().timeIntervalSince1970
        r.pending = nil
        r.position = r.elapsed(at: now); r.positionAt = now
        r.isPlaying.toggle()
        if r.isPlaying { r.pausedAt = nil } else { r.pausedAt = now }
        records[source] = r
        afterChange()
    }

    // MARK: - Test support

    /// Waits for queued file writes (tests, stop()).
    func flushWrites() { writer?.flush() }
    func artStats() async -> MusicArtStats? { await resolver?.currentStats() }
    func debugLog(_ message: String) { logger.write(message) }
}

// MARK: - Notification receiver

/// Target for the selector-based distributed observer API (the only one that honours
/// `.deliverImmediately`). Delivered on the main thread, where it was registered.
final class MusicNotificationReceiver: NSObject {
    private let handler: (String, [AnyHashable: Any]?) -> Void
    init(_ handler: @escaping (String, [AnyHashable: Any]?) -> Void) { self.handler = handler }

    @objc func received(_ note: Notification) {
        if Thread.isMainThread {
            handler(note.name.rawValue, note.userInfo)
        } else {
            let name = note.name.rawValue, info = note.userInfo
            DispatchQueue.main.async { self.handler(name, info) }
        }
    }
}

// MARK: - Log

/// Appends "[music] …" lines to the debug log (one write(2) per line, O_APPEND, so lines
/// from several threads never interleave). Off unless DOTSTUDIO_MUSIC_MONITOR_LOG=1 or
/// debug.enabled exists.
struct MusicLog: Sendable {
    let enabled: Bool
    let url: URL?
    let stderr: Bool

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func write(_ message: String) {
        guard enabled else { return }
        let line = "[music \(Self.stamp.string(from: Date()))] \(message)\n"
        if stderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let url else { return }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }
}
