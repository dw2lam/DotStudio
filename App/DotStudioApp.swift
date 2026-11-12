//  DotStudioApp.swift — entry point for the playground app.

import SwiftUI
import Sparkle

@main
struct DotStudioApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    /// The live wallpaper (it outlives the main window).
    @StateObject private var wallpaper = WallpaperController.shared
    /// Dock app vs. menu-bar item, and the menu-bar item's visibility (AppPresence.swift).
    @StateObject private var presence = AppPresence.shared

    /// Sparkle auto-updates from GitHub Releases (app-side only — the saver never links Sparkle).
    @StateObject private var updates = UpdateController()

    init() {
        if ProcessInfo.processInfo.environment["DOTSTUDIO_DIAG"] != nil {
            // Headless storage check: prints what the app can do with its library folder, then exits.
            let store = SharedStore(role: .app)
            let fm = FileManager.default
            var out = "baseDir: \(store.baseDir.path)\n"
            out += "exists: \(fm.fileExists(atPath: store.baseDir.path)) writable: \(fm.isWritableFile(atPath: store.baseDir.path))\n"
            out += "library exists: \(fm.fileExists(atPath: store.libraryURL.path))\n"
            do {
                let probe = store.baseDir.appendingPathComponent(".probe")
                try Data("x".utf8).write(to: probe, options: .atomic)
                try fm.removeItem(at: probe)
                out += "probe write: OK\n"
            } catch { out += "probe write FAILED: \(error)\n" }
            FileHandle.standardOutput.write(Data(out.utf8))
            exit(0)
        }
        // Crash reporting first: a crash anywhere after this is recorded (CrashReporter.swift).
        CrashReporter.shared.start()
        #if DEBUG
        DebugCrash.runIfRequested()   // DOTSTUDIO_DEBUG_CRASH: the crash reporter's self-test
        CrashSelfTest.runIfRequested()
        #endif
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] {
            Shots.run(outDir: dir)   // renders the gallery and exits
        }
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] {
            UIShots.run(outDir: dir)  // renders the app's screens offscreen and exits
        }
        PerfProbe.runIfRequested()    // DOTSTUDIO_PERF_PROBE: headless cost measurements, then exits
        ClickProbe.runIfRequested()   // DOTSTUDIO_CLICK_PROBE: the gallery's click paths, headless, then exits
        SetupCoach.runSelfTestIfRequested()   // DOTSTUDIO_COACH_SELFTEST: the coach overlay's click-through checks, then exits
        if ProcessInfo.processInfo.environment["DOTSTUDIO_MIGRATE_ONLY"] != nil {
            // Headless migration check (pair with DOTSTUDIO_STORE_DIR): migrates library.json
            // the way a launch does, saves it, prints a summary, exits.
            AppModel.migrateOnly()
        }
        // dotstudio-mcp writes library.json itself only while the app isn't running, under this
        // lock; the app holds it from loading the library until its AI bridge is open, so the
        // two never interleave (Shared/AI/AIBridge.swift). Never blocks a launch for long.
        let storeLock = StoreLock.acquire(store: SharedStore.appBaseDir, timeout: 5)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        WallpaperController.shared.attach(model: model)   // restored in applicationDidFinishLaunching
        MusicLifecycle.shared.attach(model: model)        // started in applicationDidFinishLaunching
        WeatherService.shared.attach(model: model)        // started in applicationDidFinishLaunching
        AppPresence.shared.attach(model: model)
        SetupGuidePanel.shared.attach(model: model)        // Help ▸ Set Up Screensaver… (SetupGuide.swift)
        LoginNudge.shared.attach(model: model)             // started in applicationDidFinishLaunching
        AIBridgeHost.shared.start(model: model)            // AI assistants' changes (AIBridgeHost.swift)
        storeLock?.release()
        // After an app update, silently refresh the installed .saver so the
        // screensaver actually gets the new code (takes effect next start).
        Installer.reinstallIfOutdated()
    }

    var body: some Scene {
        WindowGroup(id: DotStudioApp.mainWindowID) {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
        }
        .windowStyle(.titleBar)
        // A double-clicked .dotstudiopreset goes to AppDelegate.application(_:open:), which
        // imports it and brings THE main window forward — not a new window per document.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Look") { model.addPreset() }
                    .keyboardShortcut("n")
                Menu("New Scene") {
                    ForEach(EffectKind.allCases.filter { $0.isScene && !$0.isRetired }, id: \.self) { kind in
                        Button(kind.displayName) { model.addScene(kind) }
                    }
                }
                Button("Add Built-in Styles") { model.addDemoPack() }
                Divider()
                Button("Import Style…") { model.importPresetsViaPanel() }
                    .keyboardShortcut("o")
                Button("Export Style…") { model.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(model.selectedID == nil)
                Divider()
                Button("Save Image…") { model.exportSelectedAsImage() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedID == nil)
                Button("Set as Desktop Picture (Still)") { model.setSelectedAsWallpaper() }
                    .disabled(model.selectedID == nil)
            }
            CommandMenu("Style") {
                Button("Edit") { if let id = model.selectedID { model.edit(id) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedID == nil || model.editingID != nil)
                Button("Back to Library") { model.closeEditor() }
                    .disabled(model.editingID == nil)
                Divider()
                Button("Play as Screensaver") { if let id = model.selectedID { model.playAsScreensaver(id) } }
                    .disabled(model.selectedID == nil)
                Button("Preview Full Screen") {
                    if let id = model.editingID ?? model.selectedID, let p = model.preset(id) {
                        ScreensaverPreviewController.shared.present(
                            preset: p, source: model.library.source, store: model.store)
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedID == nil && model.editingID == nil)
                Divider()
                Button("Duplicate") { model.duplicateSelected() }
                    .keyboardShortcut("d")
                    .disabled(model.selectedID == nil)
            }
            CommandGroup(before: .help) {
                Button("Welcome to DotStudio…") { model.showOnboarding = true }
                Button("Set Up Screensaver…") { SetupGuidePanel.shared.show(model: model) }
                Divider()
                Button("Report a Problem…") { CrashReportPanel.shared.reportProblem() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.primaryAction() }
                    .disabled(!updates.canCheck)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updates)
                .adaptiveLayout()   // Settings is its own window: its own width class (Layout.swift)
        }

        // Whenever menu-bar mode is on, or a live wallpaper plays (MenuBarMenu.swift).
        MenuBarExtra(isInserted: Binding(get: { presence.showsMenuBarItem }, set: { _ in })) {
            DotStudioMenu()
                .environmentObject(model)
                .environmentObject(updates)
        } label: {
            DotStudioMenuLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App-level hooks SwiftUI doesn't expose. Window / Dock / menu-bar behaviour lives in
/// AppPresence; the live wallpaper must outlive the main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safe mode (two quick crashes in a row): no live wallpaper until "Start Normally".
        if CrashReporter.shared.safeMode {
            NotificationCenter.default.addObserver(forName: CrashReporter.safeModeChanged, object: nil,
                                                   queue: .main) { _ in WallpaperController.shared.restore() }
        } else {
            WallpaperController.shared.restore()
        }
        // The last session crashed: offer the report once the launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CrashReportPanel.shared.presentPendingIfNeeded() }
        // Watch Spotify / Music while the library's music options (or a Now Playing style)
        // need it; re-applied on every library change (MusicUI.swift).
        MusicLifecycle.shared.start()
        WeatherService.shared.start()             // live weather for the sea scenes (App/Weather)
        AppPresence.shared.didFinishLaunching()   // login launch → menu bar; else a regular Dock app
        // "Start at login?" once, when the wallpaper or music display is turned on (after the
        // restore above, so restoring never counts as turning on).
        LoginNudge.shared.start()
        // The installed saver's pipelines, precompiled for this saver build / macOS / GPU (a few
        // seconds of background work after an update; otherwise a quick check). Delayed so it
        // never competes with the launch itself.
        Installer.refreshPipelineArchive(delay: 8)
        if DemoHooks.isActive { DemoHooks.applyAtLaunch() }
        // Opened from the disk image / Downloads (or translocated): offer, once, to move into
        // /Applications — updates and the login item need it there (MoveToApplications.swift).
        MoveToApplications.shared.offerIfNeeded()
    }

    /// AppPresence decides (menu-bar mode → menu bar; off → quit, unless a wallpaper plays).
    /// AppKit's own rule counts the wallpaper's desktop windows and the status item's window
    /// as open windows, so it can't be relied on to fire.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click or a second launch: the main window, in front, with a Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !AppPresence.shared.reopen()
    }

    /// A double-clicked .dotstudiopreset (or any URL handed to the app): import, then show it.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppPresence.shared.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Breadcrumbs.note("quit")
        AIBridgeHost.shared.stop()     // dotstudio-mcp edits the files from now on
        MusicLifecycle.shared.stop()   // clears music.json: the saver shows no stale track
        WallpaperController.shared.shutdown()
    }
}
