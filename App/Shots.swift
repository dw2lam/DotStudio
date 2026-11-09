//  Shots.swift — headless gallery renderer. Triggered by the DOTSTUDIO_SHOTS env
//  var (an output directory): renders every screensaver to a PNG and exits.

import AppKit

enum Shots {
    static func run(outDir: String) {
        let store = SharedStore(role: .app)
        let lib = store.load() ?? DefaultPresets.makeLibrary()
        guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { exit(1) }
        if let la = lib.locationLat, let lo = lib.locationLon { renderer.location = (la, lo) }
        else { renderer.location = (37.77, -122.42) }   // demo marker (San Francisco)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for preset in lib.presets {
            guard let cg = renderer.renderThumbnail(preset: preset, source: lib.source,
                                                    width: 1600, height: 1000, time: 1.6) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = preset.name.replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
            try? data.write(to: url)
            FileHandle.standardOutput.write(Data("rendered \(preset.name)\n".utf8))
        }
        exit(0)
    }
}

// MARK: - UI shots

import SwiftUI

/// Headless renders of the app's screens (DOTSTUDIO_UI_SHOTS=<dir>) for design
/// review without opening a visible window. Pair with DOTSTUDIO_STORE_DIR so it
/// never touches the real library. Metal views render black here; tiles use thumbnails.
enum UIShots {
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let model = AppModel()
        model.storeAlert = nil
        let updates = UpdateController()   // never starts Sparkle under UI shots
        let size = CGSize(width: 1280, height: 860)

        func snap<V: View>(_ name: String, _ size: CGSize, dark: Bool, _ view: V) {
            let host = NSHostingView(rootView: view.environmentObject(model).environmentObject(updates)
                .frame(width: size.width, height: size.height))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = host.appearance
            win.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = dark ? "-dark" : ""
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)\(suffix).png"))
            win.contentView = nil
        }

        for dark in [false, true] {
            model.editingID = nil
            snap("library", size, dark: dark, ContentView())
            if let look = model.library.presets.first(where: { !$0.isScene }) {
                model.editingID = look.id
                snap("editor-look", size, dark: dark, ContentView())
            }
            if let scene = model.library.presets.first(where: { $0.isScene }) {
                model.editingID = scene.id
                snap("editor-scene", size, dark: dark, ContentView())
            }
            snap("add-effect", CGSize(width: 430, height: 500), dark: dark,
                 AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer) { _ in })
            snap("source", CGSize(width: 340, height: 300), dark: dark,
                 SourceEditor(source: .constant(model.library.source), model: model).padding(16))

            // Welcome sheet, one PNG per step (and per setup state on "Turn It On").
            // Rendered standalone — ContentView never presents it under UI shots.
            let sheet = OnboardingView.size
            snap("onboarding-1-welcome", sheet, dark: dark,
                 OnboardingView(initialStep: .welcome, livePreview: false))
            snap("onboarding-2-pick", sheet, dark: dark,
                 OnboardingView(initialStep: .pick, livePreview: false))
            snap("onboarding-2-create", sheet, dark: dark,
                 OnboardingView(initialStep: .pick, pickMode: .create, livePreview: false))
            for (status, tag) in [(Installer.Status.notInstalled, "not-installed"),
                                  (.notChosen, "not-chosen"), (.ready, "ready")] {
                snap("onboarding-3-enable-\(tag)", sheet, dark: dark,
                     OnboardingView(initialStep: .enable, livePreview: false, statusOverride: status))
            }
            snap("onboarding-4-done", sheet, dark: dark,
                 OnboardingView(initialStep: .done, livePreview: false, statusOverride: .ready))
            snap("onboarding-4-done-skipped", sheet, dark: dark,
                 OnboardingView(initialStep: .done, livePreview: false, statusOverride: .notInstalled))
        }
        FileHandle.standardOutput.write(Data("ui shots done\n".utf8))
        exit(0)
    }
}
