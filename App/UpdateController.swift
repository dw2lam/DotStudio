//  UpdateController.swift — Sparkle auto-updates from GitHub Releases.
//
//  Every `vX.Y.Z` tag pushed to GitHub builds a signed DMG + appcast.xml (see
//  .github/workflows/release.yml). The app checks that feed hourly, downloads
//  new versions silently, and installs them when you quit — or right away from
//  Settings → Updates → "Restart to Update". The bundled .saver is refreshed on
//  the next launch (Installer.reinstallIfOutdated), so one update covers both.

import SwiftUI
import Sparkle

final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(String)          // found, not downloaded yet
        case downloading(String)
        case readyToInstall(String)     // downloaded; installs on quit or on demand
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController!
    private var installNow: (() -> Void)?
    private var pendingVersion = ""
    private var observation: NSKeyValueObservation?

    var updater: SPUUpdater { controller.updater }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// True for builds made outside the release workflow: project.yml's CURRENT_PROJECT_VERSION
    /// placeholder ("1") survives only there; CI passes the commit count.
    static var isLocalBuild: Bool {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) == "1"
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        // Screenshot/render modes must never touch the network or the feed.
        let env = ProcessInfo.processInfo.environment
        guard env["DOTSTUDIO_SHOTS"] == nil, env["DOTSTUDIO_UI_SHOTS"] == nil else { return }
        // Local builds carry project.yml's placeholder build number (CI stamps real ones), so
        // Sparkle would see every published release as newer and "update" a dev build back to
        // an older version — which can't read a newer library (it happened, 2026-11-09).
        guard !Self.isLocalBuild else { return }
        controller.startUpdater()
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            DispatchQueue.main.async { self?.canCheck = u.canCheckForUpdates }
        }
    }

    // MARK: Actions

    /// The one button in Settings: install what's ready, or go look for something.
    func primaryAction() {
        if case .readyToInstall = state, let installNow {
            installNow()                       // quits, installs, relaunches
        } else {
            state = .checking
            updater.checkForUpdates()          // Sparkle's own window for download/install
        }
    }

    /// Quiet probe for the Settings status line — never shows UI.
    func refreshStatus() {
        guard canCheck else { return }
        switch state {
        case .readyToInstall, .downloading, .checking: return
        default:
            state = .checking
            updater.checkForUpdateInformation()
        }
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastChecked: Date? { updater.lastUpdateCheckDate }

    // MARK: SPUUpdaterDelegate

    /// `DOTSTUDIO_FEED_URL` points a dev build at a local test feed.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["DOTSTUDIO_FEED_URL"]
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingVersion = item.displayVersionString
        if case .readyToInstall = state { return }
        state = .available(pendingVersion)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state = .upToDate(Date())
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installNow = immediateInstallationBlock
        state = .readyToInstall(item.displayVersionString)
        return true   // keep Sparkle's default: install silently when the app quits
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        // "No update" and user-cancel arrive here too — those aren't failures.
        if ns.domain == SUSparkleErrorDomain,
           [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(ns.code) {
            if case .checking = state { state = .upToDate(Date()) }
            return
        }
        if case .readyToInstall = state { return }
        state = .failed(ns.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if case .checking = state, error == nil {
            // A user-initiated check whose window was dismissed without a verdict.
            state = pendingVersion.isEmpty ? .upToDate(Date()) : .available(pendingVersion)
        }
    }
}

/// Toolbar pill shown in the library once an update has downloaded.
struct UpdateReadyButton: View {
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        if case .readyToInstall(let v) = updates.state {
            Button { updates.primaryAction() } label: {
                Label("Update to \(v)", systemImage: "arrow.down.circle.fill")
            }
            // A toolbar shows a bare Label as its icon only: keep the title visible, as a pill
            // that never truncates.
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .lineLimit(1)
            .fixedSize()
            .help("DotStudio \(v) is downloaded — click to restart and finish updating (or it installs when you quit)")
        }
    }
}
