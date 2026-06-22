//  DotStudioApp.swift — entry point for the playground app.

import SwiftUI

@main
struct DotStudioApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] {
            Shots.run(outDir: dir)   // renders the gallery and exits
        }
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
            }
        }
    }
}
