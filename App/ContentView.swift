//  ContentView.swift — root: the style gallery, or the editor for one style.
//
//  Picking what plays (the everyday task) lives in the gallery; changing how a
//  style looks (the occasional task) lives in a dedicated editor you open by
//  double-clicking a tile. The two never compete for space.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var hero

    /// Offscreen UI renders (Shots.swift) must never present the sheet or touch the flag.
    private static let isRenderingShots = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil

    /// The style open in the editor, if it still exists.
    private var editing: Preset? { model.editingID.flatMap(model.preset) }

    var body: some View {
        let editing = editing
        ZStack {
            // The gallery stays alive under the editor (scroll position, hover state) and
            // recedes slightly while the editor is up front.
            LibraryView()
                .opacity(editing == nil ? 1 : 0)
                .scaleEffect(editing == nil || reduceMotion ? 1 : 0.985)
                .allowsHitTesting(editing == nil)
                .accessibilityHidden(editing != nil)

            if let editing {
                EditorView(id: editing.id)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background {
            AmbientBackdrop(presetID: editing?.id ?? model.nowPlayingID)
                .ignoresSafeArea()
        }
        .environment(\.heroNamespace, reduceMotion ? nil : hero)
        .animation(Motion.pick(Motion.hero, reduceMotion: reduceMotion), value: model.editingID)
        .navigationTitle(editing?.name ?? "DotStudio")
        .navigationSubtitle(editing.map { $0.isScene ? "Scene" : "Look" } ?? "")
        .frame(minWidth: 880, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSetupStatus()   // user may have just picked us in System Settings
            WallpaperSlot.shared.refresh()
        }
        .sheet(isPresented: $model.showOnboarding, onDismiss: {
            hasCompletedOnboarding = true   // finishing, skipping, or Esc all count
        }) {
            OnboardingView(initialStep: DemoHooks.onboardingCreate ? .pick : .welcome,
                           pickMode: DemoHooks.onboardingCreate ? .create : .presets)
                .environmentObject(model)
        }
        .onAppear {
            // Lets the Dock icon / menu bar reopen this window after it was closed.
            WallpaperController.shared.registerOpenMainWindow { openWindow(id: DotStudioApp.mainWindowID) }
            if DemoHooks.isActive { DemoHooks.apply(to: model) } else { presentOnboardingIfNeeded() }
        }
        .onChange(of: model.storeAlert == nil) { _, clear in
            if clear { presentOnboardingIfNeeded() }   // wait out a launch-time library alert
        }
        .alert(item: $model.storeAlert) { alert in
            if let backup = alert.backupURL {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Reveal Backup in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    },
                    secondaryButton: .cancel(Text("OK")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message),
                         dismissButton: .default(Text("OK")))
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding, !Self.isRenderingShots, !DemoHooks.isActive,
              !model.showOnboarding, model.storeAlert == nil else { return }
        model.showOnboarding = true
    }
}

/// DEV-ONLY hooks for website screen grabs and design review; inert unless set:
///   DOTSTUDIO_DEMO_EDIT=<style name>      open that style in the editor on launch
///   DOTSTUDIO_DEMO_ONBOARDING=create      open the welcome sheet on its "Create Your Own" tab
///   DOTSTUDIO_DEMO_WINDOW=1440x900        size the main window's content
///   DOTSTUDIO_DEMO_APPEARANCE=dark|light  force the app's appearance
///   DOTSTUDIO_DEMO_FILTER=<chip>          start the gallery on a filter chip (all, playing, scenes, looks, clocks, nature, flowing, retro, space, abstract)
///   DOTSTUDIO_DEMO_SEARCH=<text>          start the gallery with a search
///   DOTSTUDIO_DEMO_HOVER=<style name>     show that tile in its hover state
///   DOTSTUDIO_DEMO_PLAYLIST=<a>|<b>|…     set the screensaver playlist by name
///   DOTSTUDIO_DEMO_NIGHT=<style name>     set the night style by name
///   DOTSTUDIO_DEMO_SETUP=notInstalled|notChosen|ready   pin the setup state
///   DOTSTUDIO_DEMO_WALLPAPER_STUB=<name>  in-memory wallpaper slot playing that style
///   DOTSTUDIO_DEMO_STILL=1                stills instead of live previews (stable captures)
///   DOTSTUDIO_DEMO_WALLPAPER=<name>       turn the LIVE wallpaper on with that style
///                                         (WallpaperController.applyDevOverrides; more knobs there)
///   DOTSTUDIO_DEMO_CLOSE_WINDOW=1         close the main window after launch (wallpaper-only,
///                                         as after a login launch) for power measurements
///   DOTSTUDIO_DEMO_COVER_DESKTOP=<s>      for <s> seconds, hide the desktop behind an opaque,
///                                         click-through window ordered beneath every app window,
///                                         to verify the occlusion pause without touching others' windows
/// While any is set the first-launch sheet never auto-presents. Pair with DOTSTUDIO_STORE_DIR.
enum DemoHooks {
    private static let env = ProcessInfo.processInfo.environment
    static let editName = env["DOTSTUDIO_DEMO_EDIT"]
    static let onboardingCreate = env["DOTSTUDIO_DEMO_ONBOARDING"] == "create"
    static let windowSize: CGSize? = env["DOTSTUDIO_DEMO_WINDOW"].flatMap { s in
        let p = s.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
    static let appearance = env["DOTSTUDIO_DEMO_APPEARANCE"]
    static let filter = env["DOTSTUDIO_DEMO_FILTER"].flatMap(GalleryFilter.init(demoName:))
    static let search = env["DOTSTUDIO_DEMO_SEARCH"]
    static let hoverName = env["DOTSTUDIO_DEMO_HOVER"]
    static let playlistNames = env["DOTSTUDIO_DEMO_PLAYLIST"]?.split(separator: "|").map(String.init)
    static let nightName = env["DOTSTUDIO_DEMO_NIGHT"]
    static let setupOverride: Installer.Status? = {
        switch env["DOTSTUDIO_DEMO_SETUP"] {
        case "notInstalled": return .notInstalled
        case "notChosen": return .notChosen
        case "ready": return .ready
        default: return nil
        }
    }()
    static let wallpaperName = env["DOTSTUDIO_DEMO_WALLPAPER_STUB"]
    static let wallpaperStub: WallpaperSlot.Backend? = wallpaperName.map { _ in .memory(initial: nil) }
    static let stillPreviews = env["DOTSTUDIO_DEMO_STILL"] != nil
    static let liveWallpaperName = env["DOTSTUDIO_DEMO_WALLPAPER"]
    static let closeWindow = env["DOTSTUDIO_DEMO_CLOSE_WINDOW"] == "1"
    static let coverSeconds = env["DOTSTUDIO_DEMO_COVER_DESKTOP"].flatMap(Double.init)
    private static var cover: NSWindow?

    static var isActive: Bool {
        editName != nil || onboardingCreate || windowSize != nil || appearance != nil || filter != nil
            || search != nil || hoverName != nil || playlistNames != nil || nightName != nil
            || setupOverride != nil || wallpaperName != nil
            || liveWallpaperName != nil || closeWindow || coverSeconds != nil
    }

    @MainActor static func apply(to model: AppModel) {
        func id(_ name: String) -> UUID? { model.library.presets.first { $0.name == name }?.id }
        if let a = appearance {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        if let names = playlistNames {
            var l = model.screensaverLineup
            l.playlist = names.compactMap(id)
            model.applyLineup(l)
        }
        if let n = nightName {
            model.setNight(id(n))
        }
        if let w = wallpaperName, let wid = id(w) { WallpaperSlot.shared.set(wid) }
        if let name = editName, let p = model.library.presets.first(where: { $0.name == name }) {
            // DOTSTUDIO_DEMO_EDIT_DELAY=<sec> opens it later, animated (to review the zoom).
            if let delay = env["DOTSTUDIO_DEMO_EDIT_DELAY"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.edit(p.id) }
            } else {
                model.edit(p.id)
            }
        }
        DispatchQueue.main.async {
            if let size = windowSize,
               let win = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                win.setContentSize(size)
                win.center()
            }
            if onboardingCreate { model.showOnboarding = true }
            if env["DOTSTUDIO_DEMO_ACTIVATE"] != nil {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The wallpaper hooks run from applicationDidFinishLaunching — they must work even
    /// when no main window is restored (as after a login launch).
    @MainActor static func applyAtLaunch() {
        if closeWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.close() }
            }
        }
        if let secs = coverSeconds, let screen = NSScreen.screens.first {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = NSColor(white: 0.12, alpha: 1)
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.orderFront(nil)
            w.orderBack(nil)      // beneath every app window: hides only the desktop
            cover = w
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { cover?.orderOut(nil); cover = nil }
        }
    }
}
