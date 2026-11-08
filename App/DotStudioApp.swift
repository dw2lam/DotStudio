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
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] {
            UIShots.run(outDir: dir)  // renders the app's screens offscreen and exits
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
                Button("Set as Desktop Picture") { model.setSelectedAsWallpaper() }
                    .disabled(model.selectedID == nil)
            }
            CommandMenu("Style") {
                Button("Edit") { if let id = model.selectedID { model.edit(id) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedID == nil || model.editingID != nil)
                Button("Back to Library") { model.closeEditor() }
                    .disabled(model.editingID == nil)
                Divider()
                Button("Use as Screensaver") { if let id = model.selectedID { model.useAsScreensaver(id) } }
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
