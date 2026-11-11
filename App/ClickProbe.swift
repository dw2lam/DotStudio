//  ClickProbe.swift — DEV-ONLY crash harness for the gallery's click paths; inert unless set.
//
//    DOTSTUDIO_CLICK_PROBE=1   (ALWAYS with DOTSTUDIO_STORE_DIR=<fresh temp dir>)
//        Hosts ContentView in a titled window (with the toolbar SwiftUI bridges into it, as the
//        app's WindowGroup window has) parked far off screen and never ordered in, then for
//        EVERY style in the Scenes and Looks sections does what a user does, through the tile's
//        own handlers (TileProbe: exactly the closures its onHover / tap gestures run), each
//        run inside the hosting view's layout pass — where SwiftUI runs a gesture's action:
//          • the pointer enters the tile (the lift, the action bar and, after the dwell, the
//            tile's live Metal preview — whose frames the probe draws by hand, since an
//            off-screen window's display link never fires),
//          • a click (the selection and its Core Animation ring), then ~1 s,
//          • a little live scroll while it is selected,
//          • a double-click (the editor: its zoom, live preview and inspector list), its first
//            effect closed and opened again (the chevron), then back to the gallery;
//        then the same window shrunk to its minimum and below. (Synthetic NSEvents never reach
//        SwiftUI's gestures in a window that isn't on screen, hence the handlers.)
//        It also counts every "window needs update constraints" marking AppKit gets, and those
//        made while one of the window's own constraint/layout passes is running — the chain
//        that macOS 26 turns into "…more Update Constraints in Window passes than there are
//        views in the window" (an NSException → crash; macOS 27 logs and drops). Run it on
//        macOS 26 to see the crash itself. Prints one line per style and "click probe: PASS".
//
//      DOTSTUDIO_CLICK_SIZE=<w>x<h>        window size (default 1440x900)
//      DOTSTUDIO_CLICK_ONLY=<name>|<name>  only these styles
//      DOTSTUDIO_CLICK_EDIT=0              skip the double-click → editor step
//      DOTSTUDIO_CLICK_TIMING=runloop      run the handlers from the run loop, not in layout
//      DOTSTUDIO_CLICK_DEBUG=1             per-phase marking counts, the views marked, frames
//      DOTSTUDIO_CLICK_STACKS=1            (with DEBUG) the stack of a long marking chain
//      DOTSTUDIO_CLICK_PINNED=1            pin the content to the window size (as UIShots)
//      DOTSTUDIO_CLICK_TOOLBAR=0           a borderless window, no toolbar
//      DOTSTUDIO_CLICK_SCENARIO=<a,b,…>    extra conditions, any of:
//          music        music shown (Corner) with a track playing (MusicDemo: no player involved)
//          fullscreen   music shown Full Screen with a track playing
//          menubar      menu-bar mode on
//          bounceimage  Bounce set to an image logo (a temp PNG in the store)
//          screens      a display-configuration change posted after every few styles
//          dupes        a duplicate style id and a duplicate name added first
//          retired      edited copies of retired styles (Pipeworks, Sunray, Light Tunnel,
//                       Fireflies, Now Playing) added first
//
//  The harness never touches the real library (it refuses without DOTSTUDIO_STORE_DIR),
//  never shows a window, never plays a sound and never reaches a real music player.
//  tools/click-probe/run.sh runs the matrix.

import AppKit
import SwiftUI
import MetalKit

/// Where each gallery tile is in its window (window coordinates, top-left origin), reported by
/// the tiles themselves while the probe runs (StyleTile). Empty — and free — otherwise.
enum TileProbe {
    static let enabled = ProcessInfo.processInfo.environment["DOTSTUDIO_CLICK_PROBE"] != nil
    static var frames: [UUID: CGRect] = [:]
    /// Each tile's own click and double-click handlers (exactly what its tap gestures run).
    static var actions: [UUID: (select: () -> Void, open: () -> Void, hover: (Bool) -> Void)] = [:]
    /// The editor's effect list: open/close its first effect (as clicking its chevron does).
    static var toggleEffects: (() -> Void)?
}

struct TileProbeReporter: View {
    let id: UUID
    let select: () -> Void
    let open: () -> Void
    let hover: (Bool) -> Void
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear
                .onAppear { TileProbe.frames[id] = f; TileProbe.actions[id] = (select, open, hover) }
                .onChange(of: f) { _, now in TileProbe.frames[id] = now; TileProbe.actions[id] = (select, open, hover) }
                .onDisappear { TileProbe.frames[id] = nil }
        }
    }
}

/// The probe's hosting view: runs a queued action in the middle of its own layout — where a
/// tap gesture's action runs when SwiftUI resolves the gesture during a view-graph update
/// (a single click on a tile waits for the double-click to fail, then fires in an update).
final class ProbeHost<Content: View>: NSHostingView<Content> {
    static var duringLayout: (() -> Void)? { get { ProbeLayoutAction.pending } set { ProbeLayoutAction.pending = newValue } }
    override func layout() {
        super.layout()
        if let a = ProbeLayoutAction.pending {
            ProbeLayoutAction.pending = nil
            ProbeLayoutAction.inLayout = true
            a()
            ProbeLayoutAction.inLayout = false
        }
    }
}

enum ProbeLayoutAction {
    static var pending: (() -> Void)?
    static var inLayout = false
}

/// Counts the window's "needs update constraints" markings per display-cycle pass: a view
/// graph that keeps invalidating constraints while the window lays out runs into AppKit's
/// display-cycle limit (macOS 26 throws "…more Update Constraints in Window passes than there
/// are views in the window"; macOS 27 logs and drops). Run the probe with
/// `-NSWindowAssertWhenDisplayCycleLimitReached YES` to make 27 throw as 26 does.
enum ConstraintPassCounter {
    static var marks = 0
    static var total = 0
    static var maxPerSpin = 0
    static func install() {
        let sel = NSSelectorFromString("_postWindowNeedsUpdateConstraints")
        guard let m = class_getInstanceMethod(NSWindow.self, sel),
              let r = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.probe_postWindowNeedsUpdateConstraints)) else { return }
        method_exchangeImplementations(m, r)
        for (o, n) in [(#selector(NSWindow.updateConstraintsIfNeeded), #selector(NSWindow.probe_updateConstraintsIfNeeded)),
                       (#selector(NSWindow.layoutIfNeeded), #selector(NSWindow.probe_layoutIfNeeded)),
                       (#selector(setter: NSWindow.contentMinSize), #selector(NSWindow.probe_setContentMinSize(_:))),
                       (#selector(setter: NSWindow.contentMaxSize), #selector(NSWindow.probe_setContentMaxSize(_:))),
                       (#selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.probe_setFrame(_:display:)))] {
            if let a = class_getInstanceMethod(NSWindow.self, o), let b = class_getInstanceMethod(NSWindow.self, n) {
                method_exchangeImplementations(a, b)
            }
        }
        if let a = class_getInstanceMethod(NSView.self, #selector(setter: NSView.needsUpdateConstraints)),
           let b = class_getInstanceMethod(NSView.self, #selector(NSView.probe_setNeedsUpdateConstraints(_:))) {
            method_exchangeImplementations(a, b)
        }
    }
    static var tracing = true
    static var extrema: [String] = []
    static var lastMarked: [String] = []
    static var depth = 0
    /// Markings made inside a window pass: in this outermost pass, in all, the most in one.
    static var reentrant = 0
    static var reentrantTotal = 0
    static var maxReentrant = 0
    static var reentrantStacks: [String] = []
    static func enterPass() {
        if depth == 0 { reentrant = 0 }
        depth += 1
    }
    static func exitPass() {
        depth -= 1
        if depth == 0 { maxReentrant = max(maxReentrant, reentrant) }
    }
    static var byClass: [String: Int] = [:]

    /// Markings during `seconds` of run loop: (total, the views that asked).
    static func measure(_ label: String, _ seconds: Double, _ win: NSWindow, spin: (Double, NSWindow) -> Void) -> Int {
        let t0 = total
        let r0 = reentrantTotal
        byClass = [:]
        extrema = []
        _ = Perf.take()
        spin(seconds, win)
        let n = total - t0
        let top = byClass.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        FileHandle.standardOutput.write(Data(String(format: "  constraints %-10@ %6d markings in %.1fs (%d during passes)  %@\n", label as NSString, n, seconds, reentrantTotal - r0, top as NSString).utf8))
        let ex = extrema; extrema = []
        if !ex.isEmpty {
            var counts: [String: Int] = [:]
            for e in ex { counts[e, default: 0] += 1 }
            FileHandle.standardOutput.write(Data("    window extrema/frame sets: \(ex.count): \(counts.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: " "))\n".utf8))
        }
        let bodies = Perf.take().sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        if !bodies.isEmpty { FileHandle.standardOutput.write(Data("    bodies: \(bodies)\n".utf8)) }
        return n
    }
}

extension NSView {
    @objc dynamic func probe_setNeedsUpdateConstraints(_ flag: Bool) {
        if flag, ConstraintPassCounter.tracing {
            let name = String(describing: type(of: self))
            if ConstraintPassCounter.depth > 0 {
                var chain: [String] = []
                var v: NSView? = self
                while let x = v, chain.count < 14 {
                    chain.append(String(String(describing: type(of: x)).prefix(48)))
                    v = x.superview
                }
                ConstraintPassCounter.lastMarked.append(chain.joined(separator: " < "))
                if ConstraintPassCounter.lastMarked.count > 12 { ConstraintPassCounter.lastMarked.removeFirst() }
            }
            ConstraintPassCounter.byClass[String(name.prefix(80)), default: 0] += 1
            if ConstraintPassCounter.depth > 0, name.contains("Hosting") || name.hasPrefix("ProbeHost"),
               ConstraintPassCounter.reentrantStacks.count < 4,
               ProcessInfo.processInfo.environment["DOTSTUDIO_CLICK_STACKS"] != nil {
                ConstraintPassCounter.reentrantStacks.append(name.prefix(60) + "\n" + Thread.callStackSymbols.prefix(45).joined(separator: "\n"))
            }
        }
        probe_setNeedsUpdateConstraints(flag)
    }
}

extension NSWindow {
    @objc dynamic func probe_setContentMinSize(_ s: NSSize) {
        ConstraintPassCounter.extrema.append("min \(s.width)x\(s.height)")
        probe_setContentMinSize(s)
    }
    @objc dynamic func probe_setContentMaxSize(_ s: NSSize) {
        ConstraintPassCounter.extrema.append("max \(s.width)x\(s.height)")
        probe_setContentMaxSize(s)
    }
    @objc dynamic func probe_setFrame(_ r: NSRect, display: Bool) {
        ConstraintPassCounter.extrema.append("frame \(r.size.width)x\(r.size.height)")
        probe_setFrame(r, display: display)
    }

    /// The window's own constraint and layout passes (the display cycle runs these): a marking
    /// made while one is running asks for ANOTHER pass in the same cycle — what AppKit limits.
    @objc dynamic func probe_updateConstraintsIfNeeded() {
        ConstraintPassCounter.enterPass()
        probe_updateConstraintsIfNeeded()
        ConstraintPassCounter.exitPass()
    }

    @objc dynamic func probe_layoutIfNeeded() {
        ConstraintPassCounter.enterPass()
        probe_layoutIfNeeded()
        ConstraintPassCounter.exitPass()
    }

    @objc dynamic func probe_postWindowNeedsUpdateConstraints() {
        ConstraintPassCounter.marks += 1
        ConstraintPassCounter.total += 1
        if ConstraintPassCounter.depth > 0 {
            if ConstraintPassCounter.reentrant == 300, ProcessInfo.processInfo.environment["DOTSTUDIO_CLICK_STACKS"] != nil {
                FileHandle.standardOutput.write(Data(("STACK at 300 markings in one pass:\n" + Thread.callStackSymbols.prefix(160).joined(separator: "\n") + "\n").utf8))
            }
            if ConstraintPassCounter.reentrant == 40 {
                FileHandle.standardOutput.write(Data(("40 markings in one window pass; the last views marked:\n  "
                    + ConstraintPassCounter.lastMarked.joined(separator: "\n  ") + "\n").utf8))
            }
            ConstraintPassCounter.reentrant += 1
            ConstraintPassCounter.reentrantTotal += 1
        }
        probe_postWindowNeedsUpdateConstraints()
    }
}

enum ClickProbe {
    private static let env = ProcessInfo.processInfo.environment

    static func runIfRequested() {
        guard env["DOTSTUDIO_CLICK_PROBE"] != nil else { return }
        let store = env["DOTSTUDIO_STORE_DIR"] ?? ""
        guard !store.isEmpty,
              URL(fileURLWithPath: store).standardizedFileURL.resolvingSymlinksInPath().path
                != SharedStore.sharedDir.standardizedFileURL.resolvingSymlinksInPath().path else {
            FileHandle.standardError.write(Data("click probe: set DOTSTUDIO_STORE_DIR to a throwaway folder\n".utf8))
            exit(2)
        }
        setenv("DOTSTUDIO_MUSIC_NO_AE", "1", 1)
        setenv("DOTSTUDIO_MUSIC_NO_NETWORK", "1", 1)
        setenv("DOTSTUDIO_MUSIC_NOTIFY_PREFIX", "com.davidlam.DotStudio.clickprobe.\(getpid()).", 1)
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppPrefs.shared.ephemeral()
        MainActor.assumeIsolated { run() }
        exit(0)
    }

    private static var scenarios: Set<String> {
        Set((env["DOTSTUDIO_CLICK_SCENARIO"] ?? "").lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    // MARK: Run

    @MainActor private static func run() {
        let sc = scenarios
        let model = AppModel()
        model.storeAlert = nil
        let updates = UpdateController()    // never starts Sparkle in a probe
        WallpaperSlot.shared.connect(.memory(initial: nil))   // "Set as Wallpaper" stays in memory
        WallpaperController.shared.attach(model: model)
        MusicLifecycle.shared.attach(model: model)
        Breadcrumbs.note("probe start")

        if model.locationTuple == nil {
            model.library.locationLat = 37.77; model.library.locationLon = -122.42
        }
        if sc.contains("retired") { addRetiredCopies(model) }
        if sc.contains("dupes") { addDuplicates(model) }
        if sc.contains("bounceimage") { setBounceImage(model) }
        if sc.contains("music") || sc.contains("fullscreen") {
            var spec = model.library.musicSettings
            spec.setDisplay(sc.contains("fullscreen") ? .fullScreen : .corner)
            model.library.music = spec
            MusicDemo.apply(.playing)
        }
        if sc.contains("menubar") { AppPresence.shared.menuBarMode = true }
        model.save()

        let size = parseSize(env["DOTSTUDIO_CLICK_SIZE"]) ?? CGSize(width: 1440, height: 900)
        ConstraintPassCounter.install()
        // As the app's window: the content isn't pinned to a size — the window's size drives
        // it, and SwiftUI keeps the window's min/max size in step with the content
        // (DOTSTUDIO_CLICK_PINNED=1 pins it as UIShots does).
        let pinned = env["DOTSTUDIO_CLICK_PINNED"] == "1"
        let host = ProbeHost(rootView: ContentView()
            .frame(width: pinned ? size.width : nil, height: pinned ? size.height : nil)
            .environmentObject(model)
            .environmentObject(updates))
        // A titled window with the toolbar SwiftUI bridges into it (as the app's WindowGroup
        // window has): the toolbar items are SwiftUI hosting views inside AppKit's toolbar.
        let titled = env["DOTSTUDIO_CLICK_TOOLBAR"] != "0"
        let win = ProbeWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.acceptsMouseMovedEvents = true
        if titled { host.sceneBridgingOptions = [.toolbars, .title] }
        win.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        win.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        // AppKit's display cycle (constraint passes and their limit) runs only for a window
        // that is ordered in: DOTSTUDIO_CLICK_ORDER_IN=1 orders it in — still 30 000 pt off
        // every display, fully transparent and click-through, so nothing ever shows.
        if env["DOTSTUDIO_CLICK_ORDER_IN"] == "1" {
            win.alphaValue = 0
            win.ignoresMouseEvents = true
            win.hasShadow = false
            win.collectionBehavior = [.transient, .ignoresCycle]
            win.orderBack(nil)
            win.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        }
        Thumbnailer.assumesWindowOnScreen = true
        MetalPreview.PreviewContainer.probeAssumesVisible = true
        host.layoutSubtreeIfNeeded()
        spin(2, win)
        if env["DOTSTUDIO_CLICK_DEBUG"] != nil, let frame = win.contentView?.superview {
            func walk(_ v: NSView, _ d: Int) {
                let n = String(describing: type(of: v))
                if n.contains("Hosting") || n.contains("Toolbar") || n.contains("Titlebar") {
                    say(String(repeating: "  ", count: d) + n.prefix(120) + " \(v.frame)")
                }
                v.subviews.forEach { walk($0, d + 1) }
            }
            walk(frame, 0)
        }
        var resizes: [String] = []
        let resizeObs = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: win, queue: nil) { _ in
            if resizes.count < 12 { resizes.append("\(win.frame) min \(win.contentMinSize)") } else { resizes.append("") }
        }
        let moveObs = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: win, queue: nil) { _ in
            if resizes.count < 12 { resizes.append("moved \(win.frame)") } else { resizes.append("") }
        }
        defer {
            NotificationCenter.default.removeObserver(resizeObs); NotificationCenter.default.removeObserver(moveObs)
            say("click probe: window resized/moved \(resizes.count) times; first: " + resizes.prefix(12).joined(separator: " | "))
        }
        let before = ConstraintPassCounter.total
        win.contentView?.needsUpdateConstraints = true
        say("click probe: constraint-marking hook \(ConstraintPassCounter.total > before ? "live" : "NOT CALLED")")
        say("click probe: toolbar items \(win.toolbar?.items.count ?? 0), display-cycle assert \(UserDefaults.standard.bool(forKey: "NSWindowAssertWhenDisplayCycleLimitReached"))")

        let only = Set((env["DOTSTUDIO_CLICK_ONLY"] ?? "").split(separator: "|").map(String.init))
        let all = model.library.presets
        let ordered = all.filter(\.isScene) + all.filter { !$0.isScene }
        let targets = ordered.filter { only.isEmpty || only.contains($0.name) }
        let doEdit = env["DOTSTUDIO_CLICK_EDIT"] != "0"
        say(String(format: "click probe: %d styles (%d scenes, %d looks), window %.0fx%.0f, scenarios [%@]",
                   targets.count, targets.filter(\.isScene).count, targets.filter { !$0.isScene }.count,
                   size.width, size.height, sc.sorted().joined(separator: ",")))

        var failures: [String] = []
        for (n, preset) in targets.enumerated() {
            let id = preset.id
            guard let frame = reveal(id, host: host, win: win) else {
                failures.append("\(preset.name): tile never came into view")
                say("MISS  \(preset.name): tile never came into view")
                continue
            }
            let p = CGPoint(x: frame.midX, y: frame.midY)
            if env["DOTSTUDIO_CLICK_DEBUG"] != nil, let root = win.contentView {
                let wp = CGPoint(x: p.x, y: root.bounds.height - p.y)
                let hit = root.hitTest(root.convert(wp, from: nil))
                say("  debug: frame \(frame) window-point \(wp) hit \(hit.map { String(describing: type(of: $0)) } ?? "nil") key \(win.isKeyWindow) visible \(win.isVisible)")
            }
            // Hover: lift, action bar, live preview after the dwell.
            Breadcrumbs.note("probe hover \(preset.name)")
            mouse(.mouseMoved, at: p, win: win)
            if env["DOTSTUDIO_CLICK_DEBUG"] != nil { _ = ConstraintPassCounter.measure("idle", 0.5, win, spin: spin) }
            // The pointer enters the tile (its onHover handler): the lift, the action bar, and
            // the live preview after the dwell.
            Breadcrumbs.note("probe hover \(preset.name)")
            perform({ TileProbe.actions[id]?.hover(true) }, host: host, win: win)
            if env["DOTSTUDIO_CLICK_DEBUG"] != nil { _ = ConstraintPassCounter.measure("hover", 1.0, win, spin: spin) }
            else { spin(0.8, win) }
            let live = metalViews(in: host).count
            // Single click: the selection.
            Breadcrumbs.note("probe click \(preset.name)")
            perform(TileProbe.actions[id]?.select, host: host, win: win)
            let selected = waitUntil(2.0, win) { model.selectedID == id }
            if env["DOTSTUDIO_CLICK_DEBUG"] != nil { _ = ConstraintPassCounter.measure("selected", 1.0, win, spin: spin) }
            else { spin(1.0, win) }
            // Scroll a little while it's selected (and the pointer still over the gallery).
            scrollBy(60, host: host, win: win)
            scrollBy(-60, host: host, win: win)
            // Double click: the editor, then back.
            var edited = "skip"
            if doEdit, let f2 = TileProbe.frames[id] ?? Optional(frame) {
                let q = CGPoint(x: f2.midX, y: f2.midY)
                mouse(.mouseMoved, at: q, win: win)
                spin(0.2, win)
                Breadcrumbs.note("probe double-click \(preset.name)")
                perform(TileProbe.actions[id]?.select, host: host, win: win)
                spin(0.3, win)
                perform(TileProbe.actions[id]?.open, host: host, win: win)
                let opened = waitUntil(2.0, win) { model.editingID == id }
                if env["DOTSTUDIO_CLICK_DEBUG"] != nil {
                    _ = ConstraintPassCounter.measure("editor", 1.0, win, spin: spin)
                    _ = ConstraintPassCounter.measure("editor+1s", 1.0, win, spin: spin)
                    _ = ConstraintPassCounter.measure("editor+2s", 1.0, win, spin: spin)
                }
                else { spin(1.0, win) }
                edited = opened ? "ok" : "NO"
                // Close and reopen the first effect, as a click on its chevron does.
                for _ in 0..<2 {
                    perform(TileProbe.toggleEffects, host: host, win: win)
                    spin(0.5, win)
                }
                model.closeEditor()
                spin(0.6, win)
                if !opened { failures.append("\(preset.name): double-click didn't open the editor") }
            }
            perform({ TileProbe.actions[id]?.hover(false) }, host: host, win: win)
            spin(0.2, win)
            if !selected { failures.append("\(preset.name): click didn't select") }
            if env["DOTSTUDIO_CLICK_DEBUG"] != nil {
                say("  window content \(win.contentLayoutRect.size) min \(win.contentMinSize) max \(win.contentMaxSize)")
            }
            say(String(format: "%@  %-28@ %@  select=%@ live=%d edit=%@", selected ? "OK  " : "FAIL",
                       preset.name as NSString, preset.isScene ? "scene" : "look ",
                       selected ? "ok" : "NO", live, edited))
            if sc.contains("screens"), n % 5 == 4 {
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                spin(0.3, win)
            }
        }
        // Small window: the same window, shrunk to the minimum and below.
        for s in [CGSize(width: 880, height: 600), CGSize(width: 420, height: 300)] {
            win.setContentSize(s); host.frame = CGRect(origin: .zero, size: s)
            spin(0.8, win)
            if let first = targets.first, let f = reveal(first.id, host: host, win: win) {
                click(at: CGPoint(x: f.midX, y: f.midY), win: win, count: 1)
                spin(0.8, win)
            }
        }
        win.contentView = nil
        win.close()
        say("click probe: constraint-update markings: \(ConstraintPassCounter.total) in all, at most \(ConstraintPassCounter.maxPerSpin) per run-loop turn; made DURING a window pass: \(ConstraintPassCounter.reentrantTotal) in all, at most \(ConstraintPassCounter.maxReentrant) in one pass")
        for st in ConstraintPassCounter.reentrantStacks { say("re-entrant marking:\n" + st) }
        if failures.isEmpty {
            say("click probe: PASS (\(targets.count) styles)")
        } else {
            say("click probe: \(failures.count) problem(s):\n  " + failures.joined(separator: "\n  "))
            say("click probe: FAIL")
            exit(1)
        }
    }

    // MARK: Library variants

    @MainActor private static func addRetiredCopies(_ model: AppModel) {
        for kind in [EffectKind.pipes, .dialClock, .demoTunnel, .fireflies, .nowPlaying] {
            var p = Preset(name: "Edited \(kind.displayName)")
            var e = EffectInstance(kind)
            if let k = e.params.keys.sorted().first { e.params[k] = (e.params[k] ?? 0.5) * 0.9 + 0.01 }
            p.effects = [e]
            AppModel.insertBuiltIn(p, into: &model.library.presets)
        }
    }

    @MainActor private static func addDuplicates(_ model: AppModel) {
        guard let scene = model.library.presets.first(where: \.isScene),
              let look = model.library.presets.first(where: { !$0.isScene }) else { return }
        var twin = scene                       // same id: what a broken merge could leave
        twin.name = scene.name
        AppModel.insertBuiltIn(twin, into: &model.library.presets)
        var named = look
        named.id = UUID()                      // same name, new id
        AppModel.insertBuiltIn(named, into: &model.library.presets)
    }

    @MainActor private static func setBounceImage(_ model: AppModel) {
        guard let i = model.library.presets.firstIndex(where: { $0.effects.first?.kind == .bounce }) else { return }
        let name = "clickprobe-logo.png"
        UIShots.writeTestLogo(to: model.store.mediaURL(name))
        var e = model.library.presets[i].effects[0]
        e.logoKind = .image
        e.logoFile = name
        model.library.presets[i].effects[0] = e
    }

    // MARK: Pointer

    /// `p` in window coordinates with a top-left origin (SwiftUI's global space here).
    private static func mouse(_ type: NSEvent.EventType, at p: CGPoint, win: NSWindow, count: Int = 0) {
        let h = win.contentView?.bounds.height ?? 0
        guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        win.sendEvent(e)
    }

    /// Runs a tile's handler where a gesture's action runs: inside the hosting view's layout
    /// (DOTSTUDIO_CLICK_TIMING=layout, the default), or from the run loop (=runloop).
    private static func perform(_ action: (() -> Void)?, host: NSView, win: NSWindow) {
        guard let action else { return }
        if env["DOTSTUDIO_CLICK_TIMING"] == "runloop" {
            action()
        } else {
            ProbeLayoutAction.pending = action
            host.needsLayout = true
            win.layoutIfNeeded()
        }
        spin(0.05, win)
    }

    private static func click(at p: CGPoint, win: NSWindow, count: Int) {
        mouse(.leftMouseDown, at: p, win: win, count: count)
        spin(0.05, win)
        mouse(.leftMouseUp, at: p, win: win, count: count)
        spin(0.05, win)
    }

    // MARK: Scrolling

    private static func scrollView(in v: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(v)
        return best
    }

    /// A live scroll by `dy` points (what a trackpad gesture reports), in a few steps.
    private static func scrollBy(_ dy: CGFloat, host: NSView, win: NSWindow) {
        guard let sv = scrollView(in: host), let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: sv)
        for _ in 0..<4 {
            let y = min(max(sv.contentView.bounds.origin.y + dy / 4, 0), maxY)
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            spin(0.03, win)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: sv)
        spin(0.1, win)
    }

    /// Scrolls the gallery until the tile is fully in the clear part of the window (below the
    /// pinned filter bar); its frame then.
    private static func reveal(_ id: UUID, host: NSView, win: NSWindow) -> CGRect? {
        guard let sv = scrollView(in: host), let doc = sv.documentView else { return nil }
        let h = host.bounds.height
        let top: CGFloat = 170, bottom = h - 10
        func visible(_ f: CGRect) -> Bool { f.minY >= top && f.maxY <= bottom || (f.midY >= top && f.midY <= bottom && f.height > bottom - top) }
        func setY(_ y: CGFloat) {
            let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
            sv.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), maxY)))
            sv.reflectScrolledClipView(sv.contentView)
            spin(0.25, win)
        }
        for _ in 0..<6 {
            if let f = TileProbe.frames[id], f.width > 0 {
                if visible(f) { return f }
                setY(sv.contentView.bounds.origin.y + (f.midY - (top + bottom) / 2))
                continue
            }
            break
        }
        // Not laid out yet: sweep the gallery top to bottom until it appears.
        var y: CGFloat = 0
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        while y <= maxY + 1 {
            setY(y)
            if let f = TileProbe.frames[id], f.width > 0 {
                if visible(f) { return f }
                setY(sv.contentView.bounds.origin.y + (f.midY - (top + bottom) / 2))
                if let g = TileProbe.frames[id], visible(g) { return g }
            }
            y += max(120, (bottom - top) * 0.6)
        }
        setY(.greatestFiniteMagnitude)   // the very bottom (the last row)
        spin(0.3, win)
        return TileProbe.frames[id].flatMap { $0.midY > top && $0.midY < bottom ? $0 : nil }
    }

    // MARK: Run loop + frames

    private static func metalViews(in v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView { out.append(m) }
            v.subviews.forEach(walk)
        }
        walk(v)
        return out
    }

    /// Spins the main run loop for `s` seconds, drawing every live Metal view about 30 times a
    /// second (an off-screen window's display link never fires on its own).
    private static func spin(_ s: Double, _ win: NSWindow) {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            ConstraintPassCounter.marks = 0
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(1.0 / 30)))
            win.updateConstraintsIfNeeded()
            win.layoutIfNeeded()
            ConstraintPassCounter.maxPerSpin = max(ConstraintPassCounter.maxPerSpin, ConstraintPassCounter.marks)
            if let root = win.contentView {
                root.layoutSubtreeIfNeeded()
                for m in metalViews(in: root) where !m.isPaused && m.drawableSize.width > 0 { m.draw() }
                root.displayIfNeeded()
            }
            CATransaction.flush()
        }
    }

    private static func waitUntil(_ s: Double, _ win: NSWindow, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            if cond() { return true }
            spin(0.05, win)
        }
        return cond()
    }

    private static func parseSize(_ s: String?) -> CGSize? {
        guard let p = s?.lowercased().split(separator: "x").compactMap({ Double($0) }), p.count == 2 else { return nil }
        return CGSize(width: p[0], height: p[1])
    }
}


/// The probe's window: never on screen, but it answers as the key, main window (so a click
/// goes straight to the view, as in the app's frontmost window, rather than first activating
/// the window).
private final class ProbeWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
