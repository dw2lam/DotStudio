//  MusicUI.swift — the music feature in the app's own chrome (the renderers have theirs in
//  Shared/Music):
//    • MusicLifecycle — when the monitor (App/Music) runs: from launch while the library's
//      music settings, or a Now Playing style in use (lineup, wallpaper, editor, full-screen
//      Preview), need it; stopped at quit. It never keeps the app or its menu-bar item up:
//      that's menu-bar mode's job (AppPresence).
//    • MusicNow — what the UI shows: MusicMonitor's published state, or — under UI shots and
//      DOTSTUDIO_DEMO_MUSIC — a fixture (MusicDemo), so every screen renders without a player.
//    • the small views Settings › Music, the Screensaver card, the menu and the editor share.

import SwiftUI
import Combine

// MARK: - Lifecycle

/// Starts / re-applies / stops MusicMonitor as the library changes. Main thread.
final class MusicLifecycle {
    static let shared = MusicLifecycle()

    private weak var model: AppModel?
    private var subs: [AnyCancellable] = []
    private var started = false

    /// App.init.
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // $library / objectWillChange fire before the change: read it on the next turn.
        subs = [
            model.$library.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reevaluate() },
            model.$editingID.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reevaluate() },
            WallpaperController.shared.objectWillChange.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reevaluate() },
            ScreensaverPreviewController.shared.$musicScene.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reevaluate() },
        ]
    }

    /// applicationDidFinishLaunching.
    func start() {
        started = true
        reevaluate()
    }

    /// applicationWillTerminate: clears music.json so the saver shows nothing stale.
    func stop() {
        started = false
        MainActor.assumeIsolated { MusicMonitor.shared.stop() }
    }

    private func reevaluate() {
        Perf.count("MusicLifecycle.reevaluate")
        guard let model else { return }
        let spec = model.library.musicSettings
        let styles = Self.stylesNeedMusic(model)
        let needed = spec.needsMonitoring || styles
        MainActor.assumeIsolated {
            MusicNow.shared.lingerMinutes = spec.linger
            // A demo (DOTSTUDIO_DEMO_MUSIC) stands in for the players: never watch the real ones.
            guard started, DemoHooks.musicDemo == nil else { return }
            let monitor = MusicMonitor.shared
            monitor.neededByStyles = styles
            if needed && !monitor.isMonitoring {
                monitor.start(store: model.store, settings: spec)
            } else {
                monitor.apply(settings: spec)   // stops it, or re-picks the source
            }
        }
    }

    /// A Now Playing style plays on the screensaver (playlist or night), on the wallpaper, is
    /// open in the editor, or fills the screen in a Preview (a gallery tile's, the editor's) —
    /// it shows what's playing whatever Show music says.
    static func stylesNeedMusic(_ model: AppModel) -> Bool {
        let lineup = model.screensaverLineup
        let ids = Set(lineup.playlist + [lineup.night].compactMap { $0 })
        if model.library.presets.contains(where: { ids.contains($0.id) && $0.isMusicScene }) { return true }
        let wallpaper = WallpaperController.shared
        if wallpaper.isActive, wallpaper.currentPreset?.isMusicScene == true { return true }
        if let id = model.editingID, model.preset(id)?.isMusicScene == true { return true }
        if ScreensaverPreviewController.shared.musicScene { return true }
        return false
    }
}

// MARK: - What the UI shows

/// The app UI's view of the music players: MusicMonitor, or a demo stand-in (UI shots,
/// DOTSTUDIO_DEMO_MUSIC). Views observe this, never the monitor directly.
@MainActor
final class MusicNow: ObservableObject {
    static let shared = MusicNow()

    /// What the monitor would publish, for renders without a player.
    struct Demo {
        var state = MusicState()
        var artwork: CGImage?
        var spotify = MusicPlayerStatus(source: .spotify)
        var music = MusicPlayerStatus(source: .music)
        var monitoring = true
    }

    @Published private(set) var demo: Demo?
    /// The library's paused linger (MusicLifecycle keeps it current): when a paused track's
    /// time is up, views refresh so it disappears like it does on the screensaver.
    var lingerMinutes: Double = MusicSpec().linger {
        didSet { if lingerMinutes != oldValue { scheduleExpiry() } }
    }

    private let monitor = MusicMonitor.shared
    private var subs: Set<AnyCancellable> = []
    private var expiry: Timer?

    private init() {
        demo = MusicDemo.fromEnvironment()
        monitor.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleExpiry() } }
            }
            .store(in: &subs)
    }

    func setDemo(_ d: Demo?) {
        demo = d
        scheduleExpiry()
    }

    // MARK: State

    var state: MusicState { demo?.state ?? monitor.state }
    var artwork: CGImage? {
        if let demo { return demo.artwork }
        return monitor.artwork
    }
    var spotify: MusicPlayerStatus { demo?.spotify ?? monitor.spotify }
    var music: MusicPlayerStatus { demo?.music ?? monitor.music }
    var isMonitoring: Bool { demo?.monitoring ?? monitor.isMonitoring }
    var players: [MusicPlayerStatus] { [spotify, music] }

    func status(for source: MusicSource) -> MusicPlayerStatus { source == .music ? music : spotify }

    /// The player the shown track comes from.
    var source: MusicSource? {
        let s = state
        guard s.hasTrack else { return nil }
        if demo == nil, let a = monitor.activeSource { return a }
        return s.source == .music ? .music : .spotify
    }
    var player: MusicPlayerStatus? { source.map(status(for:)) }
    /// "Spotify" / "Apple Music" — the player's name in DotStudio's UI.
    var sourceName: String { source?.displayName ?? "Music" }

    /// Playing, or paused within the linger — exactly when the screensaver shows it.
    func isVisible(_ settings: MusicSpec) -> Bool { state.isVisible(lingerMinutes: settings.linger) }
    var isPlaying: Bool { state.isPlaying == true }
    var title: String { state.title ?? "" }
    var artist: String { state.artist ?? "" }
    /// "Song — Artist".
    var trackLine: String { artist.isEmpty ? title : "\(title) \u{2014} \(artist)" }

    var canControl: Bool { player?.canControl ?? false }
    /// The shown track's player refused Automation: controls are off until it's allowed.
    var needsAutomationFix: Bool { player?.needsAutomationFix ?? false }
    /// A running player that refused Automation (even with nothing playing).
    var deniedPlayer: MusicPlayerStatus? { players.first { $0.needsAutomationFix } }

    // MARK: Actions

    func playPause() {
        if var d = demo {
            let now = Date().timeIntervalSince1970
            d.state.position = d.state.elapsed(); d.state.positionAt = now
            d.state.isPlaying = !(d.state.isPlaying ?? false)
            d.state.pausedAt = d.state.isPlaying == true ? nil : now
            setDemo(d)
            return
        }
        monitor.playPause()
    }

    func next() { if demo == nil { monitor.next() } }
    func previous() { if demo == nil { monitor.previous() } }

    /// The fix-it: refused before → System Settings › Privacy & Security › Automation;
    /// never asked → macOS's own prompt (only for a running player; nothing is launched).
    func allowControl(_ source: MusicSource) {
        guard demo == nil else { return }
        if status(for: source).automation == .denied {
            monitor.openAutomationSettings()
        } else {
            monitor.requestAutomation(for: source)
        }
    }

    /// Re-check permissions without prompting (Settings › Music appearing).
    func refreshAutomation() { if demo == nil { monitor.refreshAutomationStatus() } }

    func beginPositionUpdates() { if demo == nil { monitor.beginPositionUpdates() } }
    func endPositionUpdates() { if demo == nil { monitor.endPositionUpdates() } }

    // MARK: Paused linger

    private func scheduleExpiry() {
        expiry?.invalidate()
        expiry = nil
        let s = state
        guard s.hasTrack, s.isPlaying != true, let at = s.pausedAt ?? s.updatedAt else { return }
        let wait = at + lingerMinutes * 60 + 0.5 - Date().timeIntervalSince1970
        guard wait > 0, wait.isFinite else { return }
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        expiry = t
    }
}

// MARK: - Demo (fixtures)

/// Fixture-driven music for renders without a player:
///   • UI shots (Shots.swift) call `apply(_:)` per screen;
///   • DOTSTUDIO_DEMO_MUSIC=idle|playing|paused|denied|ask|off (with DOTSTUDIO_MUSIC_FAKE=<fixture
///     .json>, see tools/music-fixtures/make.sh) makes a GUI instance's UI show that state —
///     the renderers read the same fixture through MusicFeed.
/// Without a fixture, a built-in sample track (no artwork) stands in.
enum MusicDemo {
    enum Scenario: String, CaseIterable {
        /// Watching; Spotify open with nothing playing, Music installed but closed.
        case idle
        /// A track plays; its player allows control.
        case playing
        case paused
        /// A track plays, but its player refused Automation (controls off, fix-it shown).
        case denied
        /// A track plays; macOS hasn't asked about Automation yet.
        case ask
        /// Every music option off: not watching.
        case off
    }

    static var fixtureURL: URL? {
        ProcessInfo.processInfo.environment["DOTSTUDIO_MUSIC_FAKE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    @MainActor static func fromEnvironment() -> MusicNow.Demo? {
        guard let raw = ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_MUSIC"],
              let scenario = Scenario(rawValue: raw.lowercased()) else { return nil }
        return make(scenario).demo
    }

    /// Sets what the UI (MusicNow) and every in-app renderer (MusicFeedHub) see. Main thread.
    static func apply(_ scenario: Scenario) {
        MainActor.assumeIsolated {
            let (demo, snap) = make(scenario)
            MusicNow.shared.setDemo(demo)
            MusicFeedHub.shared.setDemo(snap)
        }
    }

    /// The fixture's track with fresh times (a fixture written a while ago would read as a
    /// stale, long-finished song), or the built-in sample.
    static func track(playing: Bool) -> (MusicState, CGImage?) {
        var state: MusicState
        var art: CGImage?
        if let url = fixtureURL, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(MusicState.self, from: data), s.hasTrack {
            state = s
            if let name = s.artwork { art = decode(url.deletingLastPathComponent().appendingPathComponent(name)) }
        } else {
            state = MusicState(source: .spotify, title: "Weightless", artist: "Marconi Union",
                               album: "Ambient Transmissions", duration: 488, position: 131,
                               palette: [RGBA(0.95, 0.66, 0.36), RGBA(0.55, 0.30, 0.18), RGBA(0.16, 0.08, 0.06)],
                               trackID: "demo:weightless")
        }
        let now = Date().timeIntervalSince1970
        state.isPlaying = playing
        state.positionAt = playing ? now : now - 30
        state.pausedAt = playing ? nil : now - 30
        state.updatedAt = now
        if state.source == nil || state.source == .unknown { state.source = .spotify }
        return (state, art)
    }

    @MainActor static func make(_ scenario: Scenario) -> (demo: MusicNow.Demo, snapshot: MusicSnapshot) {
        var spotify = MusicPlayerStatus(source: .spotify)
        spotify.isInstalled = true; spotify.isRunning = true; spotify.automation = .allowed
        var music = MusicPlayerStatus(source: .music)
        music.isInstalled = true
        switch scenario {
        case .idle, .off:
            var d = MusicNow.Demo(spotify: spotify, music: music)
            if scenario == .off {
                d.monitoring = false
                d.spotify = MusicPlayerStatus(source: .spotify)
                d.music = MusicPlayerStatus(source: .music)
            }
            return (d, .empty)
        case .playing, .paused, .denied, .ask:
            let (state, art) = track(playing: scenario != .paused)
            var p = state.source == .music ? music : spotify
            p.isInstalled = true; p.isRunning = true; p.hasTrack = true
            p.isPlaying = state.isPlaying == true
            p.automation = scenario == .denied ? .denied : scenario == .ask ? .notDetermined : .allowed
            if state.source == .music { music = p } else { spotify = p }
            let d = MusicNow.Demo(state: state, artwork: art, spotify: spotify, music: music)
            return (d, MusicSnapshot(state: state, artwork: art))
        }
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Shared views

/// The current track's cover (or a drawn stand-in) as a small rounded square.
struct MusicArtThumb: View {
    let image: CGImage?
    var palette: [RGBA] = []
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(side * 0.16, 3), style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.10)))
        .accessibilityHidden(true)
    }

    private var placeholderColors: [Color] {
        if let a = palette.first, let b = palette.last { return [Color(a), Color(b)] }
        return [Color.pink.opacity(0.8), Color.purple.opacity(0.8)]
    }
}

/// Previous · Play/Pause · Next. Glass buttons on the glass cards; borderless in a Form.
/// Disabled while the player can't be controlled (not running, or Automation refused).
struct MusicTransport: View {
    @ObservedObject var now: MusicNow
    var showsPrevious = true
    var glass = true
    @ScaledLength(relativeTo: .callout) private var glyph: CGFloat = 12
    @ScaledLength(relativeTo: .callout) private var hit: CGFloat = 16

    var body: some View {
        HStack(spacing: glass ? Space.xxs : Space.xs) {
            if showsPrevious {
                control("backward.fill", "Previous") { now.previous() }
            }
            control(now.isPlaying ? "pause.fill" : "play.fill", now.isPlaying ? "Pause" : "Play") { now.playPause() }
            control("forward.fill", "Next") { now.next() }
        }
        .disabled(!now.canControl)
    }

    @ViewBuilder
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        let tip = now.canControl ? label : "Allow DotStudio to control \(now.sourceName) to use the controls (Settings › Music)"
        let b = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .frame(minWidth: hit, minHeight: hit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .help(tip)
        if glass {
            b.glassButton()
        } else {
            b.buttonStyle(.borderless)
        }
    }
}
