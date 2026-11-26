//  ContentView.swift — root: the style gallery, or the editor for one style.
//
//  Picking what plays (the everyday task) lives in the gallery; changing how a
//  style looks (the occasional task) lives in a dedicated editor you open by
//  double-clicking a tile. The two never compete for space.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Settings › General › Appearance (Console.swift; issue #6).
    @AppStorage(Appearance.key) private var appearance: Appearance = .classic
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var hero

    /// Offscreen UI renders (Shots.swift) must never present the sheet or touch the flag.
    private static let isRenderingShots = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil

    /// What the window draws: never the saved choice in a headless run (Appearance.effective).
    private var isConsole: Bool { Appearance.effective(saved: appearance) == .console }

    /// The style open in the editor, if it still exists.
    private var editing: Preset? { model.editingID.flatMap(model.preset) }

    var body: some View {
        let _ = Perf.body("ContentView")
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
        .adaptiveLayout()   // width class + text size → \.layout for every view inside (Layout.swift)
        .stillContext(model)   // what every StyleThumb needs, so none of them observes the model
        // The window's own colour (Console: the chassis): no colour-washed backdrop.
        .background((isConsole ? ConsoleInk.chassis : Color(nsColor: .windowBackgroundColor)).ignoresSafeArea())
        .environment(\.console, isConsole)
        .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: isConsole)
        .environment(\.heroNamespace, reduceMotion ? nil : hero)
        .animation(Motion.pick(Motion.hero, reduceMotion: reduceMotion), value: model.editingID)
        .navigationTitle(editing?.name ?? "DotStudio")
        .navigationSubtitle(editing.map { $0.isScene ? "Scene" : "Look" } ?? "")
        // Console prints its own wordmark (LibraryView) and the editor its own name strip: the
        // window keeps its title (Window menu, Mission Control, VoiceOver) but doesn't draw it
        // twice. macOS 15+: SwiftUI owns the toolbar title (an NSWindow titleVisibility flip
        // gets undone), so it's removed there; macOS 14 hides the drawn title on the window.
        .modifier(ConsoleHidesWindowTitle(hidden: isConsole))
        // Settings: a large sheet on this window (not a window of its own), so it's there in
        // full screen too. Sized from the window, within limits.
        .background {
            GeometryReader { geo in
                Color.clear.sheet(isPresented: Binding(get: { model.settingsPane != nil },
                                                       set: { if !$0 { model.settingsPane = nil } })) {
                    SettingsView()
                        .environmentObject(model)
                        .environment(\.console, isConsole)
                        // About a stock Settings window (NotchTune's 780×560 ideal), a little
                        // wider for the pictures; never bigger than the window.
                        .frame(width: min(max(geo.size.width * 0.7, 760), 900, geo.size.width - 40),
                               height: min(max(geo.size.height * 0.75, 540), 700, geo.size.height - 40))
                        .adaptiveLayout()
                }
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: CrashReporter.safeModeChanged)) { _ in
            model.objectWillChange.send()   // live previews come back (safe mode ended)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSetupStatus()   // user may have just picked us in System Settings
            WallpaperSlot.shared.refresh()
        }
        // The welcome sheet: wide, sized from the window (OnboardingView.sheetSize), so it's
        // measured here like the Settings sheet above.
        .background {
            GeometryReader { geo in
                Color.clear.sheet(isPresented: $model.showOnboarding, onDismiss: {
                    hasCompletedOnboarding = true   // finishing, skipping, or Esc all count
                }) {
                    OnboardingView(initialStep: DemoHooks.onboardingCreate ? .pick : .welcome,
                                   pickMode: DemoHooks.onboardingCreate ? .create : .presets,
                                   windowSize: geo.size)   // never larger than the window
                        .environmentObject(model)
                        .adaptiveLayout()   // the sheet is its own root: measure the sheet, not the window
                }
            }
        }
        .onAppear {
            // At launch this runs inside the launch's first Apple event, before the app
            // activates: the earliest point to become a Dock app (or, for a login launch on an
            // older macOS that still opened the window, to put it away). Once per launch.
            AppPresence.shared.decideLaunch()
            // Lets the Dock icon / menu bar reopen this window after it was closed.
            let open = { openWindow(id: DotStudioApp.mainWindowID) }
            AppPresence.shared.register(openMainWindow: open)
            WallpaperController.shared.registerOpenMainWindow(open)
            if DemoHooks.isActive { DemoHooks.apply(to: model) } else { presentOnboardingIfNeeded() }
        }
        .onChange(of: model.storeAlert == nil) { _, clear in
            if clear { presentOnboardingIfNeeded() }   // wait out a launch-time library alert
        }
        // While the welcome sheet is up it presents the alert itself (OnboardingView): one shown
        // here would sit behind the sheet. Exactly one of the two presenters is active.
        .alert(item: Binding(get: { model.showOnboarding ? nil : model.storeAlert },
                             set: { model.storeAlert = $0 })) { $0.alert }
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding, !Self.isRenderingShots, !DemoHooks.isActive,
              !model.showOnboarding, model.storeAlert == nil else { return }
        model.showOnboarding = true
    }
}

/// Hides the window's drawn title in Console (see ContentView). The availability branch is
/// fixed for a run, so the content's identity never changes; nil keeps the title.
private struct ConsoleHidesWindowTitle: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: hidden ? .title : nil)
        } else {
            content.background(WindowTitleVisibility(hidden: hidden))
        }
    }
}

/// Shows or hides the hosting window's drawn title (the title itself stays set).
private struct WindowTitleVisibility: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ v: Probe, context: Context) {
        v.hidesTitle = hidden
        v.apply()
    }

    final class Probe: NSView {
        var hidesTitle = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window else { return }
            let want: NSWindow.TitleVisibility = hidesTitle ? .hidden : .visible
            if window.titleVisibility != want { window.titleVisibility = want }
        }
    }
}

extension Appearance {
    /// A headless run: offscreen UI renders and gallery renders (Shots.swift), the click probe
    /// (ClickProbe.swift) and the perf probe (PerfProbe.swift). They run the Debug build, which
    /// shares the real app's bundle ID and so its UserDefaults — the owner's saved Appearance —
    /// and DOTSTUDIO_STORE_DIR doesn't move @AppStorage. (A dev instance with only a store dir
    /// is not headless: its own picker still works.)
    static let isHeadlessRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return TileProbe.enabled
            || ["DOTSTUDIO_UI_SHOTS", "DOTSTUDIO_SHOTS", "DOTSTUDIO_PERF_PROBE"].contains { env[$0] != nil }
    }()

    /// The appearance to draw, given the saved choice (Settings › General › Appearance):
    /// DOTSTUDIO_APPEARANCE when set; else Classic in a headless run, so renders and probe
    /// baselines stay comparable whatever the owner is trying out; else the saved choice.
    /// ContentView (and through it the Settings sheet) and the UIShots root all read it.
    static func effective(saved: Appearance) -> Appearance {
        forced ?? (isHeadlessRun ? .classic : saved)
    }
}

extension StoreAlert {
    /// The alert as ContentView and the welcome sheet present it.
    var alert: Alert {
        if let backup = backupURL {
            return Alert(
                title: Text(title),
                message: Text(message),
                primaryButton: .default(Text("Reveal Backup in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                },
                secondaryButton: .cancel(Text("OK")))
        }
        return Alert(title: Text(title), message: Text(message),
                     dismissButton: .default(Text("OK")))
    }
}

/// DEV-ONLY hooks for website screen grabs and design review; inert unless set:
///   DOTSTUDIO_DEMO_EDIT=<style name>      open that style in the editor on launch
///   DOTSTUDIO_DEMO_ONBOARDING=create      open the welcome sheet on its "Create Your Own" tab
///   DOTSTUDIO_DEMO_WINDOW=1440x900        size the main window's content
///   DOTSTUDIO_DEMO_APPEARANCE=dark|light  force the app's appearance
///   DOTSTUDIO_DEMO_FILTER=<chip>          start the gallery on a filter chip (all, playing, scenes, looks, clocks, nature, flowing, retro, space, abstract)
///   DOTSTUDIO_DEMO_MUSIC=<state>          the app's music UI shows idle|playing|paused|denied|ask|off (MusicDemo,
///                                         MusicUI.swift) — the track from DOTSTUDIO_MUSIC_FAKE=<fixture.json>
///                                         (tools/music-fixtures/make.sh), else a built-in sample; no player involved
///   DOTSTUDIO_DEMO_SEARCH=<text>          start the gallery with a search
///   DOTSTUDIO_DEMO_HOVER=<style name>     show that tile in its hover state
///   DOTSTUDIO_DEMO_PLAYLIST=<a>|<b>|…     set the screensaver playlist by name
///   DOTSTUDIO_DEMO_NIGHT=<style name>     set the night style by name
///   DOTSTUDIO_DEMO_SETUP=notInstalled|notChosen|ready   pin the setup state
///   DOTSTUDIO_DEMO_WALLPAPER_STUB=<name>  in-memory wallpaper slot playing that style
///   DOTSTUDIO_DEMO_STILL=1                stills instead of live previews (stable captures)
///   DOTSTUDIO_DEMO_EXPAND=all             open every effect in the editor's inspector
///   DOTSTUDIO_DEMO_WALLPAPER=<name>       turn the LIVE wallpaper on with that style
///                                         (WallpaperController.applyDevOverrides; more knobs there)
///   DOTSTUDIO_DEMO_CLOSE_WINDOW=1         close the main window after launch (wallpaper-only,
///                                         as after a login launch) for power measurements
///   DOTSTUDIO_DEMO_COVER_DESKTOP=<s>      for <s> seconds, hide the desktop behind an opaque,
///                                         click-through window ordered beneath every app window,
///                                         to verify the occlusion pause without touching others' windows
/// While any is set the first-launch sheet never auto-presents. Pair with DOTSTUDIO_STORE_DIR.
///
/// Presence hooks (AppPresence.swift; they don't suppress the first-launch sheet):
///   DOTSTUDIO_DEMO_LOGIN_LAUNCH=1         treat this launch as a login-item launch (the real
///                                         signal is the oapp event's keyAELaunchedAsLogInItem;
///                                         a test can also send that event through LaunchServices)
///   DOTSTUDIO_DEV_COMMANDS=1              accept test commands by distributed notification
///                                         (open, settings, close, wallpaper-stop, …) — see
///                                         AppPresence.listenForDevCommands
/// App-level switches (menu-bar mode) live in <store>/app-prefs.json under DOTSTUDIO_STORE_DIR.
/// The `static var` hooks are also set per render by UIShots (Shots.swift).
enum DemoHooks {
    private static let env = ProcessInfo.processInfo.environment
    static let editName = env["DOTSTUDIO_DEMO_EDIT"]
    static let onboardingCreate = env["DOTSTUDIO_DEMO_ONBOARDING"] == "create"
    static let windowSize: CGSize? = env["DOTSTUDIO_DEMO_WINDOW"].flatMap { s in
        let p = s.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
    static let appearance = env["DOTSTUDIO_DEMO_APPEARANCE"]
    static var filter = env["DOTSTUDIO_DEMO_FILTER"].flatMap(GalleryFilter.init(demoName:))
    static var search = env["DOTSTUDIO_DEMO_SEARCH"]
    static var hoverName = env["DOTSTUDIO_DEMO_HOVER"]
    static let playlistNames = env["DOTSTUDIO_DEMO_PLAYLIST"]?.split(separator: "|").map(String.init)
    static let nightName = env["DOTSTUDIO_DEMO_NIGHT"]
    static var setupOverride: Installer.Status? = {
        switch env["DOTSTUDIO_DEMO_SETUP"] {
        case "notInstalled": return .notInstalled
        case "notChosen": return .notChosen
        case "ready": return .ready
        default: return nil
        }
    }()
    static let wallpaperName = env["DOTSTUDIO_DEMO_WALLPAPER_STUB"]
    static let wallpaperStub: WallpaperSlot.Backend? = wallpaperName.map { _ in .memory(initial: nil) }
    static var stillPreviews = env["DOTSTUDIO_DEMO_STILL"] != nil
    /// Stills instead of live previews: the demo hook, or safe mode after two quick crashes
    /// (CrashReporter) until "Start Normally".
    static var livePreviewsPaused: Bool { stillPreviews || CrashReporter.shared.safeMode }
    static var expandAllEffects = env["DOTSTUDIO_DEMO_EXPAND"] == "all"
    static let liveWallpaperName = env["DOTSTUDIO_DEMO_WALLPAPER"]
    static let closeWindow = env["DOTSTUDIO_DEMO_CLOSE_WINDOW"] == "1"
    static let coverSeconds = env["DOTSTUDIO_DEMO_COVER_DESKTOP"].flatMap(Double.init)
    static let loginLaunch = env["DOTSTUDIO_DEMO_LOGIN_LAUNCH"] == "1"
    static let devCommands = env["DOTSTUDIO_DEV_COMMANDS"] == "1"
    static let musicDemo = env["DOTSTUDIO_DEMO_MUSIC"]
    private static var cover: NSWindow?

    static var isActive: Bool {
        editName != nil || onboardingCreate || windowSize != nil || appearance != nil || filter != nil
            || search != nil || hoverName != nil || playlistNames != nil || nightName != nil
            || setupOverride != nil || wallpaperName != nil || musicDemo != nil
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
