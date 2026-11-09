//  DotStudioApp.swift — entry point for the playground app.

import SwiftUI
import Sparkle

@main
struct DotStudioApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    /// The live wallpaper; its menu bar item exists only while a wallpaper is on.
    @StateObject private var wallpaper = WallpaperController.shared

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
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] {
            Shots.run(outDir: dir)   // renders the gallery and exits
        }
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] {
            UIShots.run(outDir: dir)  // renders the app's screens offscreen and exits
        }
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        WallpaperController.shared.attach(model: model)   // restored in applicationDidFinishLaunching
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

        MenuBarExtra(isInserted: Binding(get: { wallpaper.isActive }, set: { _ in })) {
            WallpaperMenu()
                .environmentObject(model)
        } label: {
            WallpaperMenuLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App-level hooks SwiftUI doesn't expose: the live wallpaper must outlive the main
/// window, and the Dock icon must bring the window back even though the wallpaper's
/// own (desktop-level) windows are technically visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WallpaperController.shared.restore()
        if DemoHooks.isActive { DemoHooks.applyAtLaunch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let wallpaper = WallpaperController.shared
        guard wallpaper.isActive, !wallpaper.hasVisibleMainWindow else { return true }
        wallpaper.openMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        WallpaperController.shared.shutdown()
    }
}
