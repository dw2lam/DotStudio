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
//  Lifecycle (driven by MusicLifecycle, App/MusicUI.swift):
//      MusicMonitor.shared.neededByStyles = …     // a Now Playing style is in use
//      MusicMonitor.shared.start(store:)          // no-op unless needsMonitoring || neededByStyles
//      MusicMonitor.shared.apply(settings:)       // on every library change (starts/stops, source pin)
//      MusicMonitor.shared.stop()                 // clears music.json (also on app quit)
//  Controls: playPause() / next() / previous() / skip(seconds:) — optimistic, with a 1.5 s
//  window in which a stale echo can't flip the play state back. A new track always wins,
//  and when the window closes without the player agreeing, its last word (or an exact
//  Apple Events read) is applied — the click never outvotes the player for long.
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
        /// Longest a new track's write waits for its cover before going out without it —
        /// restarted for each new track in a skip burst, up to `artWaitCap` overall.
        var artWait: TimeInterval = 1.2
        /// Longest any burst of changes waits for a cover, from the first unsent change.
        var artWaitCap: TimeInterval = 2.5
        /// A cover lookup that failed transiently (offline) is retried after these delays.
        var artRetryDelays: [TimeInterval] = [20, 60, 180]
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
    /// The cover `state.artwork` names (≤ 512 px) for in-app UI; nil = placeholder. Always
    /// published together with `state`, so the pair never shows one track's title with
    /// another's (or no) cover while a new cover is being looked up.
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
        /// Transient cover-lookup failures for this track (drives the retry backoff).
        var artRetries = 0
        var pending: (playing: Bool, until: Date)?
        /// The player's last report that the pending window overruled (and when it came) —
        /// applied when the window closes unless the player agreed (or was read) meanwhile.
        var overruled: (report: MusicReport, at: Double)?
        /// Bumped on every ingested report (a replay must not overwrite a newer one).
        var reports = 0
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
    /// Art wait: the track being waited for, and when the first unsent change happened.
    private var artWaitKey: String?
    private var artWaitStarted: Date?
    /// A track already published without its cover: never held back again (a later pause
    /// report shouldn't sit out another wait just because the lookup is still running).
    private var artWaitGaveUp: String?
    private var artWaitItem: DispatchWorkItem?
    private var artRetryItems: [MusicSource: DispatchWorkItem] = [:]
    private var pendingItems: [MusicSource: DispatchWorkItem] = [:]
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

    /// The app's own reason to watch beyond the settings' features: a Now Playing style is in
    /// use (on the screensaver or wallpaper, or open in the editor) — it shows what's playing
    /// even with the card and take-over off. Set before `start` / `apply` (MusicLifecycle).
    var neededByStyles = false

    private func wanted(_ settings: MusicSpec) -> Bool { settings.needsMonitoring || neededByStyles }

    /// Starts watching when the library's music settings need it (card, wallpaper card or
    /// take-over) or `neededByStyles`. Returns whether monitoring is on. Safe to call repeatedly.
    @discardableResult
    func start(store: SharedStore, settings: MusicSpec? = nil) -> Bool {
        let settings = settings ?? store.load()?.musicSettings ?? MusicSpec()
        self.settings = settings
        self.store = store
        guard wanted(settings) else {
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
        installed.removeAll()
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
                refreshAutomation(source, snapshot: "start")
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
        artWaitItem?.cancel(); artWaitItem = nil; artWaitKey = nil; artWaitStarted = nil
        for item in Array(artRetryItems.values) + Array(pendingItems.values) { item.cancel() }
        artRetryItems.removeAll(); pendingItems.removeAll()
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
        if wanted(settings), !isMonitoring, let store {
            start(store: store, settings: settings)
        } else if !wanted(settings), isMonitoring {
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
        // Coming back from System Settings → re-check Automation (the grant has no event), and
        // whether the players are installed (one may have been installed since).
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installed.removeAll()
                self?.publishStatuses()
                self?.refreshAutomationForRunning(force: true)
            }
        }
        // Quitting (⌘Q, menu bar Quit, Sparkle relaunch): clear music.json synchronously, so
        // the saver goes idle instead of showing a stale "playing" card (a stream without a
        // duration would never go stale on its own). Posted on the main thread inside
        // -terminate:, before the process exits; queue nil = run right there, in-line.
        let quit = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            let clear = { MainActor.assumeIsolated { self?.appWillTerminate() } }
            if Thread.isMainThread { clear() } else { DispatchQueue.main.sync(execute: clear) }
        }
        observerTokens += [(NotificationCenter.default, active), (NotificationCenter.default, quit)]
    }

    private func appWillTerminate() {
        guard isMonitoring else { return }
        logger.write("monitor: app terminating → clear")
        stop()   // writes the empty state and waits for it to reach disk
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
        installed[source] = true      // it runs, so it's installed (maybe since we last looked)
        logger.write("workspace: \(source.rawValue) launched (pid \(app.processIdentifier))")
        publishStatuses()
        // Give the player a moment to finish launching before the first event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshAutomation(source, snapshot: "launch")
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
        artRetryItems.removeValue(forKey: source)?.cancel()
        pendingItems.removeValue(forKey: source)?.cancel()
        artGeneration[source, default: 0] += 1
        guard var r = records[source] else { return }
        r.track = nil; r.art = nil; r.artKey = nil; r.artRetries = 0
        r.isPlaying = false; r.pausedAt = nil; r.pending = nil; r.overruled = nil
        r.reports += 1
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
        // Newer information than any report the pending window held back (see pendingExpired).
        records[source]?.reports += 1
        r.reports += 1
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
                r.art = nil; r.artKey = nil; r.artRetries = 0
                artRetryItems.removeValue(forKey: source)?.cancel()
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

        // Play state, honouring an optimistic play/pause click: inside the window a report
        // that contradicts the click is held back (a stale echo would flicker the button) —
        // but a NEW track always wins (an echo names the track that was playing), and an
        // overruled report is applied when the window closes (pendingExpired).
        let wasPlaying = r.isPlaying
        var playing = report.state.map { $0 == .playing } ?? wasPlaying
        if trackChanged, r.pending != nil {
            r.pending = nil; r.overruled = nil
            pendingItems.removeValue(forKey: source)?.cancel()
        }
        if let p = r.pending, let said = report.state {
            if Date() < p.until, (said == .playing) != p.playing {
                playing = wasPlaying
                r.overruled = (report, now)
                logger.write("\(source.rawValue): '\(said.rawValue)' held back (play/pause click pending)")
            } else {
                r.pending = nil; r.overruled = nil
                pendingItems.removeValue(forKey: source)?.cancel()
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
        } else {
            if wasPlaying != playing {
                logger.write("\(source.rawValue): \(playing ? "playing" : "paused") at \(String(format: "%.1f", r.position))s")
            }
            // Resumed with a cover that failed to load (offline): try again now rather than
            // at the next backoff step — the network is likelier back.
            if playing, !wasPlaying, r.art == nil, artRetryItems[source] != nil, artTasks[source] == nil {
                artRetryItems.removeValue(forKey: source)?.cancel()
                startArt(source)
            }
        }
        afterChange()
    }

    /// `userAction`: a control click — show its effect now, even while a new track's cover is
    /// still being looked up (feedback beats avoiding one placeholder frame).
    private func afterChange(userAction: Bool = false) {
        updateActive()
        publishStatuses()
        commit(force: userAction)
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
        // `artwork` is published by commit(), together with the state that names it.
    }

    private func publishStatuses() {
        for source in [MusicSource.spotify, .music] {
            let r = records[source] ?? Record(source: source)
            var s = status(for: source)
            // Cached; reset on start() and whenever DotStudio becomes active, and set by a launch.
            if installed[source] == nil {
                installed[source] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: adapters[source]!.bundleID) != nil
            }
            s.isInstalled = (installed[source] ?? false) || r.running
            s.isRunning = r.running && isMonitoring
            s.isPlaying = r.isPlaying && r.track != nil
            s.hasTrack = r.track != nil
            s.automation = r.automation
            if source == .spotify { if s != spotify { spotify = s } } else if s != music { music = s }
        }
    }

    // MARK: - Commit (publish + write)

    private func compose() -> (MusicState, URL?, CGImage?) {
        guard let src = activeSource, let r = records[src], let t = r.track else { return (MusicState(), nil, nil) }
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
        var image: CGImage?
        if r.artKey == t.key, let art = r.art {
            s.artwork = art.fileName
            s.palette = art.palette
            artURL = art.fileURL
            image = art.image
        }
        return (s, artURL, image)
    }

    /// The active track's key while it is new and its cover is still being looked up.
    private var awaitedArtKey: String? {
        guard let src = activeSource, let r = records[src], let t = r.track,
              r.artKey != t.key, artTasks[src] != nil else { return nil }
        return t.key
    }

    /// Publishes (`state` + `artwork` together) and writes the composed state if it changed.
    /// A brand-new track waits up to `artWait` for its cover so neither the card nor the
    /// in-app UI flashes a placeholder. Each new track in a skip burst restarts that wait
    /// (the track the player lands on gets its full wait), capped at `artWaitCap` from the
    /// first unsent change so a never-ending burst still goes out — and coalesces to one write.
    private func commit(force: Bool) {
        if !force, let key = awaitedArtKey, key != artWaitGaveUp {
            let now = Date()
            let started = artWaitStarted ?? now
            artWaitStarted = started
            if key != artWaitKey {
                artWaitKey = key
                let deadline = min(now.addingTimeInterval(options.artWait), started.addingTimeInterval(options.artWaitCap))
                artWaitItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.artWaitItem = nil
                        self.logger.write("art wait over — publishing without the cover")
                        self.commit(force: true)
                    }
                }
                artWaitItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now)), execute: item)
            }
            return
        }
        artWaitItem?.cancel(); artWaitItem = nil; artWaitKey = nil; artWaitStarted = nil
        var (s, artURL, image) = compose()
        if s != state { state = s }
        if image !== artwork { artwork = image }
        artWaitGaveUp = awaitedArtKey
        guard force || s != lastWritten else { return }
        lastWritten = s
        s.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        writer?.write(s, artSource: artURL)
    }

    // MARK: - Artwork

    private func startArt(_ source: MusicSource) {
        artTasks[source]?.cancel()
        artTasks[source] = nil
        artRetryItems.removeValue(forKey: source)?.cancel()
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
            let outcome = await resolver.resolve(req)
            guard let self, !Task.isCancelled, self.artGeneration[source] == gen else { return }
            self.artTasks[source] = nil
            self.artResolved(outcome, source: source, key: key)
        }
    }

    private func artResolved(_ outcome: MusicArtOutcome, source: MusicSource, key: String) {
        guard var r = records[source], r.track?.key == key else { return }
        let result = outcome.result
        // A retry that failed again keeps whatever the track already had.
        if result != nil || r.artKey != key { r.art = result }
        r.artKey = key
        records[source] = r
        logger.write("\(source.rawValue): art \(result.map { "\($0.origin) \($0.fileName), \($0.palette.count) colours" } ?? (outcome.isFailure ? "lookup failed — placeholder for now" : "none (placeholder)"))")
        if outcome.isFailure, r.art == nil { scheduleArtRetry(source, key: key) }
        updateActive()
        commit(force: false)
    }

    /// Offline (Wi-Fi still reconnecting after wake/login): retry with backoff while the same
    /// track stays current — and at once if it's resumed meanwhile (see ingest).
    private func scheduleArtRetry(_ source: MusicSource, key: String) {
        guard let r = records[source], r.artRetries < options.artRetryDelays.count else {
            logger.write("\(source.rawValue): cover lookups keep failing — placeholder for this track")
            return
        }
        let delay = options.artRetryDelays[r.artRetries]
        records[source]?.artRetries += 1
        artRetryItems[source]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.artRetryItems[source] = nil
                guard let r = self.records[source], r.track?.key == key, r.art == nil, self.artTasks[source] == nil else { return }
                self.logger.write("\(source.rawValue): retrying the cover lookup")
                self.startArt(source)
            }
        }
        artRetryItems[source] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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

    /// One exact read of play state + position. `completion(true)` when it produced a state.
    private func readPosition(_ source: MusicSource, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard isMonitoring, canUseAppleEvents(source), let pid = pid(for: source), let adapter = adapters[source] else {
            completion?(false); return
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
                    var got = false
                    defer { completion?(got) }
                    guard let self, self.isMonitoring else { return }
                    self.noteAppleEventError(err, source: source)
                    guard let (state, position) = read, let state else { return }
                    var report = MusicReport(source: source, origin: .appleEvents)
                    report.state = state
                    report.position = position
                    got = true
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

    /// `snapshot`: the caller wants the player's full state read afterwards (start, launch) —
    /// read exactly once here, instead of also via automationChanged's "newly allowed" read.
    private func refreshAutomation(_ source: MusicSource, force: Bool = false, snapshot reason: String? = nil,
                                   then: (@MainActor () -> Void)? = nil) {
        let finish: @MainActor () -> Void = { [weak self] in
            if let reason { self?.readSnapshot(source, reason: reason) }
            then?()
        }
        guard isMonitoring, options.appleEvents.enabled, let pid = pid(for: source) else { finish(); return }
        if !force, let at = records[source]?.automationCheckedAt, Date().timeIntervalSince(at) < 20 { finish(); return }
        records[source]?.automationCheckedAt = Date()
        let ae = appleEvents
        ae.queue.async { [weak self] in
            let status = ae.permissionStatusOnQueue(source, pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.automationChanged(source, to: status, snapshot: reason == nil)
                    finish()
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

    private func automationChanged(_ source: MusicSource, to status: MusicAutomationStatus, snapshot: Bool = true) {
        guard var r = records[source] else { return }
        let old = r.automation
        r.automation = status
        records[source] = r
        guard old != status else { return }
        logger.write("automation \(source.rawValue): \(old.rawValue) → \(status.rawValue)")
        publishStatuses()
        updatePollTimer()
        if status == .allowed {
            // Newly allowed: exact state now (unless the caller reads it anyway), and upgrade
            // a missing cover.
            if snapshot { readSnapshot(source, reason: "allowed") }
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
        readPosition(source) { [weak self] _ in self?.pollInFlight = false }
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
        r.overruled = nil
        records[src] = r
        schedulePendingExpiry(src)
        logger.write("control \(src.rawValue): playPause → \(target ? "playing" : "paused") (optimistic)")
        afterChange(userAction: true)
        send(.playPause, to: src)
        return true
    }

    private func schedulePendingExpiry(_ source: MusicSource) {
        pendingItems[source]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pendingExpired(source) }
        }
        pendingItems[source] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + options.pendingWindow + 0.05, execute: item)
    }

    /// The optimistic window closed and the player never agreed (an agreeing report clears
    /// `pending`). Re-sync: an exact Apple Events read when possible (controls need them
    /// anyway); failing that, apply the player's last overruled report.
    private func pendingExpired(_ source: MusicSource) {
        pendingItems[source] = nil
        guard isMonitoring, var r = records[source], let p = r.pending else { return }
        if Date() < p.until { schedulePendingExpiry(source); return }
        let overruled = r.overruled
        let seen = r.reports
        r.pending = nil; r.overruled = nil
        records[source] = r
        logger.write("\(source.rawValue): play/pause window closed without the player agreeing — re-syncing")
        readPosition(source) { [weak self] gotState in
            guard let self, !gotState, self.isMonitoring, let (report, at) = overruled,
                  let r = self.records[source], r.reports == seen else { return }
            var replay = report
            if replay.state == .playing, let pos = replay.position {
                replay.position = pos + max(0, Date().timeIntervalSince1970 - at)   // measured `at`
            }
            self.logger.write("\(source.rawValue): applying the player's last report ('\(replay.state?.rawValue ?? "?")')")
            self.ingest(replay)
        }
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
        afterChange(userAction: true)
        let ae = appleEvents
        ae.queue.async { _ = ae.performOnQueue(src, pid: pid, timeout: ae.config.commandTimeout) { adapter.seek(to: target, in: $0) } }
        return true
    }

    private func command(_ cmd: MusicCommand, _ source: MusicSource?) -> Bool {
        guard let src = source ?? activeSource, records[src]?.track != nil, sendable(src) else { return false }
        logger.write("control \(src.rawValue): \(cmd.rawValue)")
        // Whatever the player reports next is about the new track: no click to honour.
        records[src]?.pending = nil; records[src]?.overruled = nil
        pendingItems.removeValue(forKey: src)?.cancel()
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
        r.pending = nil; r.overruled = nil
        pendingItems.removeValue(forKey: source)?.cancel()
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
