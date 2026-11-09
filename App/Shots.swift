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
            autoreleasepool {   // no event loop drains the pool here (see UIShots' render)
                guard let cg = renderer.renderThumbnail(preset: preset, source: lib.source,
                                                        width: 1600, height: 1000, time: 1.6) else { return }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let data = rep.representation(using: .png, properties: [:]) else { return }
                let name = preset.name.replacingOccurrences(of: " ", with: "-")
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
                try? data.write(to: url)
                FileHandle.standardOutput.write(Data("rendered \(preset.name)\n".utf8))
            }
        }
        exit(0)
    }
}

// MARK: - UI shots

import SwiftUI

/// Headless renders of every screen of the app, as a MATRIX for layout review:
/// window sizes × text sizes × (normal | stress data) × (light | dark).
///
/// Run with DOTSTUDIO_UI_SHOTS=<outdir>, ALWAYS paired with DOTSTUDIO_STORE_DIR=<fresh temp
/// dir> so the real library is never touched. Nothing is ever shown on screen: each render
/// is an NSHostingView in a borderless window parked far off-screen, never ordered in.
/// Metal views can't draw here, so previews use cached stills (DemoHooks.stillPreviews)
/// and Liquid Glass may show its material fallback — judge layout, not glass.
///
/// Files: <screen>@<W>x<H>[-<text>][-stress][-dark].png, plus manifest.tsv and index.html.
///   W×H    main-window screens: the window's CONTENT size (880x600 is the minimum).
///          Sheets, popovers, Settings, the menu: their natural size.
///   text   xl · xxxl · ax1 (none = the default size, .large). Only text set with
///          `.textRole` / `Font.scaled` / `@ScaledLength` responds — see Layout.swift.
///   stress very long style names, an 8+ style playlist, long effect stacks, long search
///          text and file names (the empty-library and zero-result screens render in both).
///   music  every screen starts "watching, nothing playing"; the music screens (names with
///          "music" or "nowplaying") play a fixture — DOTSTUDIO_MUSIC_FAKE=<dir>/playing.json from
///          tools/music-fixtures/make.sh, else a built-in sample track (MusicDemo, MusicUI.swift).
///
/// Narrowing (all optional; lists are comma-separated):
///   DOTSTUDIO_UI_ONLY=library,dest-       screens whose name contains any of these
///   DOTSTUDIO_UI_SIZES=880x600,1440x900   window sizes for main-window screens
///   DOTSTUDIO_UI_TEXT=default,ax1         default xl xxxl ax1 (also xs s m xxl ax2 ax3 ax4 ax5)
///   DOTSTUDIO_UI_STRESS=1 | both          stress data only | normal + stress (default: normal)
///   DOTSTUDIO_UI_APPEARANCE=light|dark|both   default: light, plus dark at 1440x900 (or the
///                                         natural size) with default text
///   DOTSTUDIO_UI_SETTLE=0.6               seconds each render settles before capture
///   DOTSTUDIO_UI_LIST=1                   print the screen names and exit
enum UIShots {
    static let windowSizes: [CGSize] = [CGSize(width: 880, height: 600), CGSize(width: 1100, height: 720),
                                        CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1200),
                                        CGSize(width: 2560, height: 1440)]
    /// The size that also renders in dark by default.
    static let referenceSize = CGSize(width: 1440, height: 900)

    static let textSizes: [(tag: String, size: DynamicTypeSize)] = [
        ("xs", .xSmall), ("s", .small), ("m", .medium), ("default", .large), ("xl", .xLarge),
        ("xxl", .xxLarge), ("xxxl", .xxxLarge), ("ax1", .accessibility1), ("ax2", .accessibility2),
        ("ax3", .accessibility3), ("ax4", .accessibility4), ("ax5", .accessibility5),
    ]
    static let defaultTextTags = ["default", "xl", "xxxl", "ax1"]

    private static let env = ProcessInfo.processInfo.environment

    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppPrefs.shared.ephemeral()   // renders flip menu-bar mode; never persist it
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let model = AppModel()
        model.storeAlert = nil
        let updates = UpdateController()   // never starts Sparkle under UI shots
        // Real wallpaper settings (for the menu and Settings), but never started: with no
        // display hosts, `update` only records the choice. The gallery's wallpaper state
        // runs on an in-memory slot, so "Set as Wallpaper" can never open a desktop window.
        WallpaperController.shared.attach(model: model)
        WallpaperSlot.shared.connect(.memory(initial: nil))
        DemoHooks.stillPreviews = true

        var normal = model.library
        guard !normal.presets.isEmpty else {
            FileHandle.standardError.write(Data("ui shots: the library is empty\n".utf8)); exit(1)
        }
        if normal.locationLat == nil { normal.locationLat = 37.77; normal.locationLon = -122.42 }

        let screens = catalogue()
        if env["DOTSTUDIO_UI_LIST"] != nil {
            FileHandle.standardOutput.write(Data((screens.map(\.name).joined(separator: "\n") + "\n").utf8))
            exit(0)
        }
        let only = list("DOTSTUDIO_UI_ONLY")
        let chosen = screens.filter { s in only.isEmpty || only.contains { s.name.contains($0) } }
        let sizes = list("DOTSTUDIO_UI_SIZES").compactMap(parseSize)
        let windowSizes = sizes.isEmpty ? Self.windowSizes : sizes
        let textTags = list("DOTSTUDIO_UI_TEXT").isEmpty ? defaultTextTags : list("DOTSTUDIO_UI_TEXT")
        let texts = textTags.compactMap { tag in textSizes.first { $0.tag == tag } }
        let stressModes: [Bool] = {
            switch env["DOTSTUDIO_UI_STRESS"] {
            case "both": return [false, true]
            case "1", "true", "yes", "only": return [true]
            default: return [false]
            }
        }()
        let settle = env["DOTSTUDIO_UI_SETTLE"].flatMap(Double.init) ?? 0.6

        let shooter = Shooter(model: model, updates: updates, settle: settle)
        var manifest: [Shot] = []
        let started = Date()

        for stress in stressModes {
            let stage = Stage(model: model, library: stress ? stressLibrary(from: normal) : normal, stress: stress)
            for screen in chosen {
                let frames: [CGSize?] = screen.frame.isWindow ? windowSizes.map { Optional($0) } : [nil]
                for windowSize in frames {
                    for text in texts {
                        let isReference = text.size == .large && (windowSize == nil || windowSize == referenceSize)
                        for dark in appearances(reference: isReference) {
                            stage.reset()
                            screen.prepare(stage)
                            guard let size = shooter.size(for: screen, windowSize: windowSize,
                                                          typeSize: text.size, view: screen.view(stage)) else { continue }
                            var file = "\(screen.name)@\(Int(size.width))x\(Int(size.height))"
                            if text.size != .large { file += "-\(text.tag)" }
                            if stress { file += "-stress" }
                            if dark { file += "-dark" }
                            file += ".png"
                            // Build the view after prepare() so it sees this render's state.
                            if shooter.render(screen.view(stage), size: size, typeSize: text.size, dark: dark,
                                              to: out.appendingPathComponent(file)) {
                                manifest.append(Shot(file: file, screen: screen.name, size: size, text: text.tag,
                                                     stress: stress, dark: dark))
                                FileHandle.standardOutput.write(Data("shot \(file)\n".utf8))
                            }
                        }
                    }
                }
            }
        }
        writeManifest(manifest, to: out)
        let secs = Int(Date().timeIntervalSince(started))
        FileHandle.standardOutput.write(Data("ui shots done: \(manifest.count) files in \(secs)s → \(out.path)\n".utf8))
        exit(0)
    }

    // MARK: Screens

    private struct Screen {
        enum Frame {
            /// A main-window screen: renders at every window size.
            case window
            /// A sheet or popover with its own fixed size.
            case fixed(CGSize)
            /// Natural height at a fixed width (Settings, menus, small editors).
            case fit(width: CGFloat, minHeight: CGFloat = 120)

            var isWindow: Bool { if case .window = self { return true } else { return false } }
        }

        let name: String
        let frame: Frame
        var prepare: (Stage) -> Void = { _ in }
        let view: (Stage) -> AnyView
    }

    /// Every screen, in review order. Names are stable: area teams narrow runs with
    /// DOTSTUDIO_UI_ONLY=<prefix> (library, dest-, editor-, add-, source-, playlist-,
    /// onboarding-, settings, menu-).
    private static func catalogue() -> [Screen] {
        let main: (Stage) -> AnyView = { _ in AnyView(ContentView()) }
        var s: [Screen] = []

        // Library (gallery)
        s.append(Screen(name: "library", frame: .window, view: main))
        s.append(Screen(name: "library-filtered", frame: .window,
                        prepare: { DemoHooks.filter = richestTag($0.model) }, view: main))
        s.append(Screen(name: "library-search", frame: .window,
                        prepare: { DemoHooks.search = $0.searchText }, view: main))
        s.append(Screen(name: "library-noresults", frame: .window,
                        prepare: { DemoHooks.search = $0.noMatchText }, view: main))
        s.append(Screen(name: "library-empty", frame: .window,
                        prepare: { $0.emptyLibrary() }, view: main))
        s.append(Screen(name: "library-empty-filtered", frame: .window,
                        prepare: { $0.emptyLibrary(); DemoHooks.filter = .scenes }, view: main))
        // Hover bar + every badge kind, on the first tile of the grid.
        s.append(Screen(name: "library-hover", frame: .window, prepare: { st in
            let first = st.firstScene
            st.lineup([first] + st.playlist.filter { $0 != first }.prefix(2), night: st.night)
            WallpaperSlot.shared.set(first)
            DemoHooks.hoverName = st.name(first)
        }, view: main))

        // Destination cards (top of the gallery) in each state
        s.append(Screen(name: "dest-single", frame: .window, view: main))
        s.append(Screen(name: "dest-playlist", frame: .window,
                        prepare: { $0.lineup($0.playlist) }, view: main))
        s.append(Screen(name: "dest-night", frame: .window,
                        prepare: { $0.lineup([$0.hero], night: $0.night) }, view: main))
        s.append(Screen(name: "dest-notinstalled", frame: .window,
                        prepare: { $0.setup(.notInstalled) }, view: main))
        s.append(Screen(name: "dest-notchosen", frame: .window,
                        prepare: { $0.setup(.notChosen) }, view: main))
        s.append(Screen(name: "dest-wallpaper", frame: .window,
                        prepare: { WallpaperSlot.shared.set($0.wallpaper) }, view: main))
        s.append(Screen(name: "dest-full", frame: .window, prepare: { st in
            st.lineup(st.playlist, night: st.night)
            WallpaperSlot.shared.set(st.wallpaper)
            st.setup(.notChosen)
        }, view: main))
        // Music on the Screensaver card (the card on the hero, the now-playing line) and the
        // Wallpaper card matching the screensaver. Every music screen is fixture-driven
        // (MusicDemo): DOTSTUDIO_MUSIC_FAKE=<tools/music-fixtures/make.sh dir>/playing.json,
        // else a built-in sample track without artwork.
        s.append(Screen(name: "dest-music", frame: .window, prepare: { st in
            MusicDemo.apply(.playing)
            WallpaperSlot.shared.set(st.wallpaper)
        }, view: main))
        s.append(Screen(name: "dest-music-denied", frame: .window,
                        prepare: { _ in MusicDemo.apply(.denied) }, view: main))
        // Show music: Full Screen with a song showing: the hero shows it over the Album Art
        // backdrop, as the saver does; the row's menu reads Full Screen.
        s.append(Screen(name: "dest-music-full", frame: .window, prepare: { st in
            MusicDemo.apply(.playing)
            var m = st.model.library.musicSettings; m.setDisplay(.fullScreen)
            st.model.library.music = m
        }, view: main))
        // The Screensaver card's "Show what's playing" menu, laid out as a column (menus can't
        // render offscreen): Full Screen with its Layout / Behind the Music sections, and Corner
        // with its Corner / Size sections.
        for (mode, tag) in [(MusicSpec.Display.fullScreen, "full"), (.corner, "corner")] {
            s.append(Screen(name: "dest-music-menu-\(tag)", frame: .fit(width: 240), prepare: { st in
                var m = st.model.library.musicSettings; m.setDisplay(mode)
                if mode == .fullScreen { m.fullLayout = .stage }
                st.model.library.music = m
            }, view: { _ in AnyView(MenuPreview { MusicDisplayMenuItems() }) }))
        }
        // The Wallpaper card synced while the screensaver rotates a playlist.
        s.append(Screen(name: "dest-wallpaper-synced", frame: .window, prepare: { st in
            st.lineup(st.playlist, night: st.night)
            WallpaperController.shared.update { $0.enabled = true; $0.followsScreensaver = true }
            WallpaperSlot.shared.set(st.model.nowPlayingID ?? st.hero)
            MusicDemo.apply(.playing)
        }, view: main))
        // The Wallpaper card while matching shows what follow mode would: the screensaver's
        // style right now (WallpaperController.currentPreset), not a style of its own.
        s.append(Screen(name: "dest-wallpaper-match", frame: .window, prepare: { st in
            st.lineup(st.playlist)
            WallpaperController.shared.update { $0.enabled = true; $0.followsScreensaver = true }
            WallpaperSlot.shared.set(st.model.nowPlayingID ?? st.hero)
        }, view: main))

        // Editor (preview + destination bar + inspector with every effect expanded)
        s.append(Screen(name: "editor-scene", frame: .window, prepare: { st in
            st.lineup([st.scene])
            WallpaperSlot.shared.set(st.scene)
            st.edit(st.scene)
        }, view: main))
        s.append(Screen(name: "editor-look", frame: .window, prepare: { st in
            st.lineup([st.hero], night: st.stress ? st.look : nil)
            st.edit(st.look)
        }, view: main))

        // Popover contents
        s.append(Screen(name: "add-effect", frame: .fixed(CGSize(width: 430, height: 500)), view: { st in
            AnyView(AddEffectPicker(source: st.model.library.source, thumbnailer: st.model.thumbnailer,
                                    include: { !$0.isScene }) { _ in })
        }))
        s.append(Screen(name: "add-scene", frame: .fixed(CGSize(width: 430, height: 500)), view: { st in
            AnyView(AddEffectPicker(source: st.model.library.source, thumbnailer: st.model.thumbnailer,
                                    include: { $0.isScene }, prompt: "Search scenes") { _ in })
        }))
        s.append(Screen(name: "playlist-editor", frame: .fixed(CGSize(width: 420, height: 460)),
                        prepare: { $0.lineup($0.playlist) }, view: { _ in AnyView(PlaylistEditor()) }))
        for kind in ["slideshow", "photo", "video", "gradient"] {
            s.append(Screen(name: "source-\(kind)", frame: .fit(width: 320), view: { st in
                AnyView(SourceEditor(source: .constant(st.source(kind)), model: st.model).padding(Space.m))
            }))
        }

        // Onboarding sheet, one per step (and per setup state on "Turn It On")
        let sheet = OnboardingView.size
        s.append(Screen(name: "onboarding-1-welcome", frame: .fixed(sheet), view: { _ in
            AnyView(OnboardingView(initialStep: .welcome, livePreview: false))
        }))
        s.append(Screen(name: "onboarding-2-pick", frame: .fixed(sheet), view: { _ in
            AnyView(OnboardingView(initialStep: .pick, livePreview: false))
        }))
        s.append(Screen(name: "onboarding-2-create", frame: .fixed(sheet), view: { _ in
            AnyView(OnboardingView(initialStep: .pick, pickMode: .create, livePreview: false))
        }))
        for (status, tag) in [(Installer.Status.notInstalled, "not-installed"), (.notChosen, "not-chosen"), (.ready, "ready")] {
            s.append(Screen(name: "onboarding-3-enable-\(tag)", frame: .fixed(sheet), view: { _ in
                AnyView(OnboardingView(initialStep: .enable, livePreview: false, statusOverride: status))
            }))
        }
        s.append(Screen(name: "onboarding-4-done", frame: .fixed(sheet), view: { _ in
            AnyView(OnboardingView(initialStep: .done, livePreview: false, statusOverride: .ready))
        }))
        s.append(Screen(name: "onboarding-4-done-skipped", frame: .fixed(sheet), view: { _ in
            AnyView(OnboardingView(initialStep: .done, livePreview: false, statusOverride: .notInstalled))
        }))

        // Settings: every section (General, Screensaver, Live Wallpaper, Transitions, Performance, Updates)
        s.append(Screen(name: "settings", frame: .fit(width: 460, minHeight: 600),
                        prepare: { st in WallpaperController.shared.update { $0.presetID = st.wallpaper } },
                        view: { _ in AnyView(SettingsView()) }))
        // Settings › General on its own, in both menu-bar modes (the footer changes with it)
        s.append(Screen(name: "settings-general", frame: .fit(width: 460, minHeight: 160),
                        view: { _ in AnyView(SettingsSectionPreview { GeneralSettingsSection() }) }))
        s.append(Screen(name: "settings-general-off", frame: .fit(width: 460, minHeight: 160),
                        prepare: { _ in AppPresence.shared.menuBarMode = false },
                        view: { _ in AnyView(SettingsSectionPreview { GeneralSettingsSection() }) }))
        // Settings › Music: nothing playing, playing (controls), permission needed (all Corner,
        // the default), Show music Off (not watching), and Full Screen (its own options)
        for (scenario, tag) in [(MusicDemo.Scenario.idle, ""), (.playing, "-playing"), (.denied, "-denied"),
                                (.off, "-off"), (.playing, "-full")] {
            s.append(Screen(name: "settings-music\(tag)", frame: .fit(width: 460, minHeight: 300), prepare: { st in
                MusicDemo.apply(scenario)
                var m = MusicSpec()
                if scenario == .off { m.setDisplay(.off) }
                if tag == "-full" { m.setDisplay(.fullScreen) }
                if scenario == .off || tag == "-full" { st.model.library.music = m }
            }, view: { _ in AnyView(SettingsSectionPreview { MusicSettingsSlot() }) }))
        }
        // …with menu-bar mode off: closing the window quits, and the note says so
        s.append(Screen(name: "settings-music-menubar-off", frame: .fit(width: 460, minHeight: 300), prepare: { _ in
            MusicDemo.apply(.playing)
            AppPresence.shared.menuBarMode = false
        }, view: { _ in AnyView(SettingsSectionPreview { MusicSettingsSlot() }) }))
        // Settings › Live Wallpaper matching the screensaver (no style picker)
        s.append(Screen(name: "settings-wallpaper-match", frame: .fit(width: 460, minHeight: 300), prepare: { _ in
            WallpaperController.shared.update { $0.enabled = true; $0.followsScreensaver = true }
        }, view: { _ in AnyView(SettingsSectionPreview { WallpaperSettingsSection() }) }))

        // The DotStudio menu-bar menu, laid out as a plain column (menus can't render offscreen):
        // wallpaper off, playing, paused, a rotating screensaver playlist, and not set up
        s.append(Screen(name: "menu-off", frame: .fit(width: 320), view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        s.append(Screen(name: "menu-on", frame: .fit(width: 320), prepare: { st in
            WallpaperController.shared.update { $0.enabled = true; $0.presetID = st.wallpaper }
        }, view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        s.append(Screen(name: "menu-paused", frame: .fit(width: 320), prepare: { st in
            WallpaperController.shared.update { $0.enabled = true; $0.presetID = st.wallpaper }
            WallpaperController.shared.togglePause()
        }, view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        s.append(Screen(name: "menu-playlist", frame: .fit(width: 320),
                        prepare: { $0.lineup($0.playlist, night: $0.night) },
                        view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        // The screensaver isn't set up: the line says so and leads to the setup strip
        s.append(Screen(name: "menu-setup", frame: .fit(width: 320),
                        prepare: { $0.setup(.notChosen) },
                        view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        // Music at the top of the menu: playing, and with the player's permission refused
        s.append(Screen(name: "menu-music", frame: .fit(width: 320),
                        prepare: { _ in MusicDemo.apply(.playing) },
                        view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        s.append(Screen(name: "menu-music-denied", frame: .fit(width: 320),
                        prepare: { _ in MusicDemo.apply(.denied) },
                        view: { _ in AnyView(MenuPreview { DotStudioMenu() }) }))
        // The one-time "still running" popover (menu-bar mode off, wallpaper playing)
        s.append(Screen(name: "menu-notice", frame: .fit(width: 288, minHeight: 80), view: { _ in
            AnyView(MenuBarStayNotice(quit: {}, keepRunning: {}, turnOnMenuBarMode: {})
                .background(.regularMaterial))
        }))
        return s
    }

    /// The tag chip with the most styles, so the filtered gallery has something to show.
    private static func richestTag(_ model: AppModel) -> GalleryFilter {
        let count: (StyleTag) -> Int = { t in model.library.presets.filter { StyleTag.tags(for: $0).contains(t) }.count }
        return StyleTag.allCases.max { count($0) < count($1) }.map(GalleryFilter.tag) ?? .scenes
    }

    // MARK: Stage

    /// The cast of styles each screen uses, picked once per data set, and the reset that
    /// puts the model back to a known state before every render.
    private final class Stage {
        let model: AppModel
        let library: Library
        let stress: Bool

        let hero: UUID          // what plays (single lineup)
        let firstScene: UUID    // first tile of the grid
        let playlist: [UUID]    // a rotation: 4 styles, or 9 under stress (more than the card shows)
        let night: UUID
        let wallpaper: UUID
        let scene: UUID         // opened in the editor
        let look: UUID          // opened in the editor
        let searchText: String
        let noMatchText: String

        init(model: AppModel, library: Library, stress: Bool) {
            self.model = model
            self.library = library
            self.stress = stress
            let all = library.presets
            let scenes = all.filter(\.isScene)
            let looks = all.filter { !$0.isScene }
            func named(_ n: String) -> UUID? { all.first { $0.name == n }?.id }
            let first = all[0].id

            let hero = library.activeID ?? first
            self.hero = hero
            firstScene = scenes.first?.id ?? first
            let others = (scenes + looks).map(\.id).filter { $0 != hero }
            playlist = [hero] + others.prefix(stress ? 8 : 3)
            night = (stress ? named(UIShots.longNames[1]) : nil)
                ?? scenes.first { $0.id != hero }?.id ?? first
            wallpaper = (stress ? named(UIShots.longNames[2]) : nil)
                ?? scenes.dropFirst(2).first?.id ?? first
            scene = (stress ? named(UIShots.longNames[1]) : nil)
                ?? scenes.max { $0.effects.count < $1.effects.count }?.id ?? first
            look = (stress ? named(UIShots.stackName) : nil)
                ?? looks.max { $0.effects.count < $1.effects.count }?.id ?? first
            let heroName = all.first { $0.id == hero }?.name ?? ""
            searchText = stress ? "golden hour over the pacific extended director's cut"
                                : String(heroName.lowercased().split(separator: " ").first ?? "a")
            noMatchText = stress ? "a deliberately long search that matches nothing at all — no name, effect, pack or tag"
                                 : "zxqv"
        }

        func name(_ id: UUID) -> String { model.preset(id)?.name ?? "" }

        func reset() {
            model.library = library
            model.editingID = nil
            model.selectedID = hero
            model.showOnboarding = false
            DemoHooks.filter = nil
            DemoHooks.search = nil
            DemoHooks.hoverName = nil
            DemoHooks.expandAllEffects = false
            setup(.ready)
            WallpaperSlot.shared.stop()
            WallpaperController.shared.update { $0.enabled = false; $0.followsScreensaver = false }
            MusicDemo.apply(.idle)   // watching, nothing playing (music screens set their own)
            if WallpaperController.shared.userPaused { WallpaperController.shared.togglePause() }
            AppPresence.shared.menuBarMode = true   // the default (prefs are in-memory here)
            lineup([hero])
        }

        func lineup(_ ids: [UUID], night: UUID? = nil) {
            model.applyLineup(ScreensaverLineup(playlist: ids, night: night))
        }

        func setup(_ status: Installer.Status) {
            DemoHooks.setupOverride = status
            model.refreshSetupStatus()
        }

        func edit(_ id: UUID) {
            DemoHooks.expandAllEffects = true
            model.selectedID = id
            model.editingID = id
        }

        func emptyLibrary() {
            model.library.presets = []
            model.selectedID = nil
        }

        func source(_ kind: String) -> SourceSpec {
            var s = library.source
            switch kind {
            case "photo":
                s.kind = .image
                s.mediaFilename = stress ? "Screenshot 2026-11-09 at 09.41.27 — Golden Hour over the Pacific, final FINAL v3 (edited).png" : nil
            case "video":
                s.kind = .video
                s.mediaFilename = stress ? "Drone footage of the coastline at dusk, 4K HDR, color graded, take 17.mov" : nil
            case "gradient":
                s.kind = .gradient
            default:
                s = .builtInPhotos
                if stress { s.mediaFilenames = (1...24).map { String(format: "IMG_%04d.HEIC", $0) } }
            }
            return s
        }
    }

    // MARK: Stress data

    static let longNames = [
        "Golden Hour over the Pacific — extended director's cut edition",
        "Midnight Aurora Borealis Above the Frozen Lake (4K Remaster)",
        "Supercalifragilisticexpialidocious_UnbrokenStyleNameWithoutAnySpaces_2026",
        "Ünïcödé Ştyłe · 日本語のスタイル名 · mixed scripts and diacritics",
    ]
    static let stackName = "Every Effect at Once — a Look with far too many layers to read in one go"

    /// The normal library with long names (the playing style, the first scenes, the first
    /// Look), a Look stacking the longest-named effects, and layers on a renamed scene.
    private static func stressLibrary(from normal: Library) -> Library {
        var lib = normal
        var targets: [Int] = []
        if let a = lib.presets.firstIndex(where: { $0.id == lib.activeID }) { targets.append(a) }
        for (i, p) in lib.presets.enumerated() where p.isScene && !targets.contains(i) && targets.count < 3 {
            targets.append(i)
        }
        if let l = lib.presets.firstIndex(where: { !$0.isScene }) { targets.append(l) }
        for (n, i) in targets.enumerated() where n < longNames.count { lib.presets[i].name = longNames[n] }

        let longest = EffectKind.allCases.filter { !$0.isScene && !$0.isRetired }
            .sorted { $0.displayName.count > $1.displayName.count }
        if targets.count > 1 {   // the editor's stress scene: a scene with layers on top
            lib.presets[targets[1]].effects += longest.prefix(3).map { EffectInstance($0) }
        }
        var stack = Preset(name: stackName)
        stack.effects = longest.prefix(8).map { EffectInstance($0) }
        lib.presets.append(stack)
        return lib
    }

    // MARK: Rendering

    private final class Shooter {
        let model: AppModel
        let updates: UpdateController
        let settle: Double

        init(model: AppModel, updates: UpdateController, settle: Double) {
            self.model = model
            self.updates = updates
            self.settle = settle
        }

        private func root(_ view: AnyView, width: CGFloat, height: CGFloat?, typeSize: DynamicTypeSize) -> some View {
            view
                .frame(width: width, height: height)
                .adaptiveLayout()
                .environment(\.dynamicTypeSize, typeSize)
                .environmentObject(model)
                .environmentObject(updates)
        }

        /// The render size: the window's content size, a fixed sheet size, or the natural
        /// height of the view at its width.
        func size(for screen: Screen, windowSize: CGSize?, typeSize: DynamicTypeSize, view: AnyView) -> CGSize? {
            switch screen.frame {
            case .window: return windowSize
            case .fixed(let s): return s
            case .fit(let width, let minHeight):
                // Its own pool: the probe's view graph goes as soon as it has been measured.
                return autoreleasepool {
                    let probe = NSHostingView(rootView: root(view, width: width, height: nil, typeSize: typeSize)
                        .fixedSize(horizontal: false, vertical: true))
                    let h = probe.fittingSize.height
                    return CGSize(width: width, height: min(max(h.rounded(.up), minHeight), 4000))
                }
            }
        }

        /// One render per autorelease pool, its window closed and its hosting view detached
        /// before the pool drains. This loop runs from App.init, outside NSApplication's event
        /// loop (which is what normally drains autoreleased objects): without this, renders'
        /// windows, hosting views and SwiftUI graphs piled up until AttributeGraph aborted in
        /// grow_region after ~580 renders.
        func render(_ view: AnyView, size: CGSize, typeSize: DynamicTypeSize, dark: Bool, to url: URL) -> Bool {
            autoreleasepool {
                let host = NSHostingView(rootView: root(view, width: size.width, height: size.height, typeSize: typeSize))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.appearance = host.appearance
                win.contentView = host
                host.frame = CGRect(origin: .zero, size: size)
                defer {
                    win.contentView = nil
                    win.close()   // never ordered in; closing drops it from NSApp.windows
                }
                let passes = 3
                for _ in 0..<passes {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(settle / Double(passes)))
                }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                return (try? png.write(to: url)) != nil
            }
        }
    }

    // MARK: Options + manifest

    private struct Shot {
        let file: String
        let screen: String
        let size: CGSize
        let text: String
        let stress: Bool
        let dark: Bool
    }

    private static func list(_ key: String) -> [String] {
        (env[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseSize(_ s: String) -> CGSize? {
        let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }

    private static func appearances(reference: Bool) -> [Bool] {
        switch env["DOTSTUDIO_UI_APPEARANCE"] {
        case "dark": return [true]
        case "light": return [false]
        case "both": return [false, true]
        default: return reference ? [false, true] : [false]
        }
    }

    /// manifest.tsv (one row per file) and index.html (every file, grouped by screen).
    private static func writeManifest(_ shots: [Shot], to dir: URL) {
        var tsv = "file\tscreen\twidth\theight\ttext\tstress\tappearance\n"
        for s in shots {
            tsv += "\(s.file)\t\(s.screen)\t\(Int(s.size.width))\t\(Int(s.size.height))\t\(s.text)\t\(s.stress ? 1 : 0)\t\(s.dark ? "dark" : "light")\n"
        }
        try? tsv.write(to: dir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)

        var html = """
        <!doctype html><meta charset="utf-8"><title>DotStudio UI shots</title>
        <style>body{font:13px -apple-system,system-ui;margin:24px;background:#f4f4f6;color:#222}
        h2{margin:32px 0 8px;font-size:16px}.row{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}
        figure{margin:0;max-width:480px}img{max-width:480px;width:100%;border:1px solid #0002;border-radius:6px;background:#fff}
        figcaption{font-size:11px;color:#666;margin-top:4px;word-break:break-all}</style>
        <h1>DotStudio UI shots</h1><p>\(shots.count) renders</p>
        """
        var seen: [String] = []
        for s in shots where !seen.contains(s.screen) { seen.append(s.screen) }
        for screen in seen {
            html += "<h2 id=\"\(screen)\">\(screen)</h2><div class=\"row\">"
            for s in shots where s.screen == screen {
                html += "<figure><a href=\"\(s.file)\"><img loading=\"lazy\" src=\"\(s.file)\"></a><figcaption>\(s.file)</figcaption></figure>"
            }
            html += "</div>"
        }
        try? html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }
}

/// The DotStudio menu-bar menu's items laid out as a plain column, standing in for the real
/// menu (menus can't be drawn offscreen). Shows what each item says — submenus as pull-down
/// buttons — at the current text size, not the system menu's own metrics.
private struct MenuPreview<Items: View>: View {
    @ViewBuilder var items: () -> Items

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            items()
        }
        .textRole(.body)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

/// One Settings section in the grouped Form Settings uses, at the Settings window's width.
private struct SettingsSectionPreview<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .textRole(.body)
            .formControlSize()
            .scrollDisabled(true)
    }
}
