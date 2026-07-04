//  DotStudioApp.swift — entry point for the playground app.

import SwiftUI
import Sparkle

@main
struct DotStudioApp: App {
    @StateObject private var model = AppModel()

    /// Sparkle auto-updates (app-side only — the saver never links Sparkle).
    private let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                       updaterDelegate: nil,
                                                       userDriverDelegate: nil)

    init() {
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] {
            Shots.run(outDir: dir)   // renders the gallery and exits
        }
        // After an app update, silently refresh the installed .saver so the
        // screensaver actually gets the new code (takes effect next start).
        Installer.reinstallIfOutdated()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Screensaver") { model.addPreset() }
                    .keyboardShortcut("n")
                Button("Add Demo Screensavers") { model.addDemoPack() }
                Divider()
                Button("Import Screensavers…") { model.importPresetsViaPanel() }
                    .keyboardShortcut("o")
                Button("Export Screensaver…") { model.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(model.selectedID == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
        }

        Settings {
            SettingsView(updater: updater.updater)
                .environmentObject(model)
        }
    }
}
