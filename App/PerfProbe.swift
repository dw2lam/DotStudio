//  PerfProbe.swift — DEV-ONLY efficiency measurements; inert unless set.
//
//    DOTSTUDIO_PERF=1   count SwiftUI body evaluations and background work (Perf.count) in
//                       a normal run; nothing is printed unless a probe runs.
//
//    DOTSTUDIO_PERF_PROBE=idle|window  (ALWAYS with DOTSTUDIO_STORE_DIR=<fresh temp dir>)
//        Runs the app's background services headlessly — activation policy .prohibited, no
//        Dock icon, no menu-bar item, never a window on screen — and prints what they cost:
//          idle    menu-bar mode with every window closed: the model, music watching,
//                  weather, presence. Phases: quiet, then a synthetic track playing (a
//                  notification on a PRIVATE name — no real player is involved or contacted:
//                  Apple Events and artwork lookups are off).
//          window  the same, plus the main window's content (ContentView at 1440x900) hosted
//                  in a borderless window parked far off screen and never ordered in (as
//                  UIShots does). Then scripted events — a thumbnail landing, a song
//                  changing, a selection, an edit — each reported as the SwiftUI bodies it
//                  re-evaluated.
//        DOTSTUDIO_PERF_SECONDS=<n>   length of each measured quiet phase (default 30)
//
//  Per phase: main run-loop wake-ups, process wake-ups (idle + interrupt), CPU time, memory
//  footprint, and the Perf counters (body:<View>, and named background events).

import AppKit
import SwiftUI
import Darwin
import Combine

enum Perf {
    private static let env = ProcessInfo.processInfo.environment
    static let enabled = env["DOTSTUDIO_PERF"] != nil || env["DOTSTUDIO_PERF_PROBE"] != nil

    private static var counts: [String: Int] = [:]
    private static let lock = NSLock()

    /// Counts one occurrence of `key` (any thread). Free when perf counting is off.
    @inline(__always) static func count(_ key: @autoclosure () -> String) {
        guard enabled else { return }
        let k = key()
        lock.lock(); counts[k, default: 0] += 1; lock.unlock()
    }

    /// A SwiftUI body evaluation: `let _ = Perf.body("StyleTile")` at the top of `body`.
    @inline(__always) static func body(_ name: StaticString) {
        guard enabled else { return }
        count("body:\(name)")
    }

    /// The counts so far, and a fresh start.
    static func take() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let c = counts
        counts.removeAll()
        return c
    }

    // MARK: Process usage

    struct Usage {
        var cpu: Double          // user + system seconds
        var wakeups: UInt64      // idle (package) + interrupt wake-ups
        var footprintMB: Double
        var residentMB: Double

        static func now() -> Usage {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { return Usage(cpu: 0, wakeups: 0, footprintMB: 0, residentMB: 0) }
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let ns = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
            return Usage(cpu: ns / 1e9,
                         wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                         footprintMB: Double(info.ri_phys_footprint) / 1_048_576,
                         residentMB: Double(info.ri_resident_size) / 1_048_576)
        }
    }

    /// Main run-loop wake-ups (timers, sources, dispatch to main) since install.
    final class RunLoopWakes {
        private(set) var count = 0
        private var observer: CFRunLoopObserver?

        init() {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { [weak self] _, _ in
                self?.count += 1
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func take() -> Int { defer { count = 0 }; return count }
    }
}

// MARK: - Probe

enum PerfProbe {
    private static let env = ProcessInfo.processInfo.environment

    static func runIfRequested() {
        guard let mode = env["DOTSTUDIO_PERF_PROBE"] else { return }
        let store = env["DOTSTUDIO_STORE_DIR"] ?? ""
        guard !store.isEmpty,
              URL(fileURLWithPath: store).standardizedFileURL.resolvingSymlinksInPath().path
                != SharedStore.sharedDir.standardizedFileURL.resolvingSymlinksInPath().path else {
            FileHandle.standardError.write(Data("perf probe: set DOTSTUDIO_STORE_DIR to a throwaway folder\n".utf8))
            exit(2)
        }
        // Never reach a real player, the network or the user's defaults-backed switches.
        setenv("DOTSTUDIO_MUSIC_NO_AE", "1", 1)
        setenv("DOTSTUDIO_MUSIC_NO_NETWORK", "1", 1)
        setenv("DOTSTUDIO_MUSIC_NOTIFY_PREFIX", prefix, 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppPrefs.shared.ephemeral()
        MainActor.assumeIsolated {
            switch mode {
            case "window": runWindow()
            case "scroll": runScroll()
            case "backdrop": runBackdrop()
            default: runIdle()
            }
        }
        exit(0)
    }

    private static let prefix = "com.davidlam.DotStudio.perfprobe.\(getpid())."
    private static var seconds: Double { env["DOTSTUDIO_PERF_SECONDS"].flatMap(Double.init) ?? 30 }

    /// What the app sets up at launch (DotStudioApp.init + applicationDidFinishLaunching),
    /// minus anything that shows: no wallpaper is restored, no window opens.
    @MainActor private static func bootServices() -> (AppModel, UpdateController) {
        let model = AppModel()
        model.storeAlert = nil
        // Music on (Show music: Corner) so the monitor watches, as for most users.
        if !model.library.musicSettings.needsMonitoring {
            var spec = model.library.musicSettings
            spec.setDisplay(.corner)
            model.library.music = spec
            model.save()
        }
        // A resolved location and a fresh weather reading: the steady state of a running app
        // (live-weather styles then wait out their 20 minutes; nothing goes to the network).
        if model.locationTuple == nil {
            model.library.locationLat = 37.77; model.library.locationLon = -122.42
            model.save()
        }
        let reading = WeatherState(openMeteo: ["weather_code": 2, "cloud_cover": 40, "is_day": 1],
                                   latitude: 37.8, longitude: -122.4, place: "Probe", at: Date())
        if let data = try? JSONEncoder().encode(reading) {
            try? data.write(to: model.store.baseDir.appendingPathComponent(WeatherState.fileName))
        }
        let updates = UpdateController()
        WallpaperController.shared.attach(model: model)
        MusicLifecycle.shared.attach(model: model)
        WeatherService.shared.attach(model: model)
        AppPresence.shared.attach(model: model)
        MusicLifecycle.shared.start()
        WeatherService.shared.start()
        // Who publishes, how often.
        func watch<P: Publisher>(_ name: String, _ p: P) where P.Failure == Never {
            p.sink { _ in Perf.count("publish:\(name)") }.store(in: &subs)
        }
        watch("AppModel", model.objectWillChange)
        watch("MusicNow", MusicNow.shared.objectWillChange)
        watch("MusicMonitor", MusicMonitor.shared.objectWillChange)
        watch("WallpaperController", WallpaperController.shared.objectWillChange)
        watch("WallpaperSlot", WallpaperSlot.shared.objectWillChange)
        watch("WeatherService", WeatherService.shared.objectWillChange)
        watch("AppPresence", AppPresence.shared.objectWillChange)
        watch("UpdateController", updates.objectWillChange)
        return (model, updates)
    }

    private static let wakes = Perf.RunLoopWakes()
    private static var subs = Set<AnyCancellable>()

    private static func spin(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.main.run(until: end) }   // one wake-up at the end, none of its own in between
    }

    private static func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    /// Measures `body` (which may spin the run loop) and prints one phase line + its counters.
    private static func phase(_ name: String, minutes: Bool = true, _ body: () -> Double) {
        _ = Perf.take(); _ = wakes.take()
        let u0 = Perf.Usage.now()
        let t0 = Date()
        let span = body()
        let dt = max(Date().timeIntervalSince(t0), span)
        let u1 = Perf.Usage.now()
        let w = wakes.take()
        let c = Perf.take()
        let perMin = 60 / dt
        var line = String(format: "PHASE %-22@ %6.1fs  runloop-wakes %6d (%7.1f/min)  proc-wakes %7llu (%7.1f/min)  cpu %7.3fs (%5.2f%%)  footprint %6.1f MB  rss %6.1f MB",
                          name as NSString, dt, w, Double(w) * perMin, u1.wakeups - u0.wakeups,
                          Double(u1.wakeups - u0.wakeups) * perMin, u1.cpu - u0.cpu, (u1.cpu - u0.cpu) / dt * 100,
                          u1.footprintMB, u1.residentMB)
        if !minutes { line = line.replacingOccurrences(of: "/min", with: "/min*") }
        say(line)
        let bodies = c.filter { $0.key.hasPrefix("body:") }
        let other = c.filter { !$0.key.hasPrefix("body:") }
        let total = bodies.values.reduce(0, +)
        if !bodies.isEmpty {
            say("    bodies \(total): " + bodies.sorted { $0.value > $1.value }.map { "\($0.key.dropFirst(5))=\($0.value)" }.joined(separator: " "))
        }
        if !other.isEmpty {
            say("    events: " + other.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
    }

    // MARK: Synthetic music (private notification names; no player involved)

    private static var trackNo = 0
    private static func postSpotify(playing: Bool, newTrack: Bool) {
        if newTrack { trackNo += 1 }
        let info: [String: Any] = [
            "Track ID": "spotify:track:perfprobe\(trackNo)",
            "Name": "Probe Song \(trackNo)", "Artist": "The Probes", "Album": "Measurements",
            "Player State": playing ? "Playing" : "Paused",
            "Duration": 215_000, "Playback Position": 12.0,
        ]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(prefix + "com.spotify.client.PlaybackStateChanged"), object: nil,
            userInfo: info, deliverImmediately: true)
    }

    // MARK: Idle (menu-bar mode, every window closed)

    @MainActor private static func runIdle() {
        let (_, updates) = bootServices()
        _ = updates
        say("perf probe: idle (menu-bar mode, no windows) — \(Int(seconds)) s per phase")
        phase("launch-settle") { spin(5); return 5 }
        phase("idle-quiet") { spin(seconds); return seconds }
        postSpotify(playing: true, newTrack: true)
        phase("song-starts") { spin(3); return 3 }
        phase("idle-song-playing") { spin(seconds); return seconds }
        postSpotify(playing: false, newTrack: false)
        phase("song-paused") { spin(3); return 3 }
        phase("idle-song-paused") { spin(seconds); return seconds }
    }

    // MARK: Gallery scroll (offscreen)

    /// The gallery's own scroll view inside the hosting view (the tallest document).
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

    /// One scripted scroll pass: `step` points per frame (≈ a brisk trackpad scroll at 60 Hz)
    /// from `from` to `to`. Each step = move the clip view, then do what a frame does on the
    /// main thread (SwiftUI's update, layout, display, the transaction commit). Reports the
    /// main-thread time per step.
    @MainActor private static func scrollPass(_ name: String, host: NSView, scroll: NSScrollView,
                                              from: CGFloat, to: CGFloat, step: CGFloat) {
        var times: [Double] = []
        phase(name, minutes: false) {
            let t0 = Date()
            var y = from
            let dir: CGFloat = to >= from ? 1 : -1
            while dir > 0 ? y <= to : y >= to {
                let s = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date())          // SwiftUI's scheduled update
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - s) * 1000)
                y += dir * step
            }
            return Date().timeIntervalSince(t0)
        }
        report("main-thread", times)
    }

    private static func report(_ what: String, _ times: [Double]) {
        let sorted = times.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let over = times.filter { $0 > 16.7 }.count
        let over8 = times.filter { $0 > 8.3 }.count
        say(String(format: "    frames %d  %@ ms/frame: median %.2f  p95 %.2f  max %.1f  total %.0f  · >16.7ms: %d  >8.3ms: %d",
                   times.count, what as NSString, pct(0.5), pct(0.95), sorted.last ?? 0, times.reduce(0, +), over, over8))
    }


    @MainActor private static func runScroll() {
        let (model, updates) = bootServices()
        DemoHooks.stillPreviews = env["DOTSTUDIO_PERF_LIVE"] == nil
        let size = CGSize(width: 1440, height: 900)
        let host = NSHostingView(rootView: ContentView()
            .frame(width: size.width, height: size.height)
            .environmentObject(model)
            .environmentObject(updates))
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        spin(2)
        guard let scroll = scrollView(in: host), let doc = scroll.documentView else {
            say("perf probe: no scroll view found"); return
        }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        say(String(format: "perf probe: scroll — gallery 1440x900, %d styles, document %.0f pt, scrolling %.0f pt",
                   model.library.presets.count, doc.frame.height, maxY))
        let step = CGFloat(env["DOTSTUDIO_PERF_STEP"].flatMap(Double.init) ?? 12)
        scrollPass("scroll-down cold", host: host, scroll: scroll, from: 0, to: maxY, step: step)
        spin(2)   // background thumbnail work lands
        scrollPass("scroll-up warm", host: host, scroll: scroll, from: maxY, to: 0, step: step)
        scrollPass("scroll-down warm", host: host, scroll: scroll, from: 0, to: maxY, step: step)
        for _ in 0..<(env["DOTSTUDIO_PERF_REPEAT"].flatMap(Int.init) ?? 0) {   // long runs for a sampler
            scrollPass("scroll-up warm (repeat)", host: host, scroll: scroll, from: maxY, to: 0, step: step)
            scrollPass("scroll-down warm (repeat)", host: host, scroll: scroll, from: 0, to: maxY, step: step)
        }
        // A song changing and a still landing mid-scroll (what ticks while the user scrolls).
        phase("scroll-up + events", minutes: false) {
            var y = maxY
            var i = 0
            while y >= 0 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                if i % 40 == 10 { postSpotify(playing: true, newTrack: true) }
                if i % 40 == 30 { model.thumbnailer.debugAnnounceUpdate(model.library.presets[0].id) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.004))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                y -= step; i += 1
            }
            return 0
        }
        win.contentView = nil
        win.close()
    }

    // MARK: Window open (offscreen)

    @MainActor private static func runWindow() {
        let (model, updates) = bootServices()
        DemoHooks.stillPreviews = env["DOTSTUDIO_PERF_LIVE"] == nil
        let size = CGSize(width: 1440, height: 900)
        let host = NSHostingView(rootView: ContentView()
            .frame(width: size.width, height: size.height)
            .environmentObject(model)
            .environmentObject(updates))
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        say("perf probe: window (ContentView 1440x900, offscreen, never shown) — \(Int(seconds)) s quiet phases")

        phase("first-render") { host.layoutSubtreeIfNeeded(); spin(4); return 4 }
        phase("window-quiet") { spin(seconds); return seconds }

        phase("thumbnail-lands x5") {
            for _ in 0..<5 { model.thumbnailer.debugAnnounceUpdate(model.library.presets[0].id); spin(0.5) }
            return 2.5
        }
        phase("song-starts") { postSpotify(playing: true, newTrack: true); spin(3); return 3 }
        phase("window-song-playing") { spin(seconds); return seconds }
        phase("song-pause/play x4") {
            for i in 0..<4 { postSpotify(playing: i % 2 == 1, newTrack: false); spin(1) }
            return 4
        }
        phase("next-track x3") {
            for _ in 0..<3 { postSpotify(playing: true, newTrack: true); spin(2) }
            return 6
        }
        let ids = model.library.presets.map(\.id)
        phase("select x5") {
            for i in 0..<5 { model.selectedID = ids[(i * 3) % ids.count]; spin(0.5) }
            return 2.5
        }
        phase("edit-param x10") {
            // A slider drag on the selected style's first effect (no-op value wobble).
            if let i = model.library.presets.firstIndex(where: { !$0.effects.isEmpty }) {
                let id = model.library.presets[i].id
                for k in 0..<10 {
                    var p = model.library.presets[i]
                    let key = p.effects[0].params.keys.sorted().first ?? "amount"
                    p.effects[0].params[key] = (p.effects[0].params[key] ?? 0.5) + (k % 2 == 0 ? 0.001 : -0.001)
                    model.presetBinding(id).wrappedValue = p
                    spin(0.2)
                }
            }
            return 2
        }
        phase("after-events-quiet") { spin(seconds / 2); return seconds / 2 }

        // Close it, as the user does: the app goes back to menu-bar idle.
        win.contentView = nil
        win.close()
        model.releaseThumbnails()   // what AppPresence does once the last window has closed
        phase("closed-settle") { spin(3); return 3 }
        phase("closed-quiet") { spin(seconds); return seconds }
    }

    // MARK: Backdrop (look check)

    /// DOTSTUDIO_PERF_PROBE=backdrop DOTSTUDIO_PERF_OUT=<dir>: renders the live-blur
    /// AmbientBackdrop and the pre-blurred GalleryBackdrop with SwiftUI's own renderer
    /// (ImageRenderer draws blur filters; offscreen window captures don't) for comparison.
    @MainActor private static func runBackdrop() {
        let (model, _) = bootServices()
        let out = env["DOTSTUDIO_PERF_OUT"] ?? NSTemporaryDirectory()
        let size = CGSize(width: 1440, height: 900)
        let ids = [model.nowPlayingID] + model.library.presets.prefix(6).map { Optional($0.id) }
        for (i, id) in ids.enumerated() {
            for dark in [false, true] {
                let scheme: ColorScheme = dark ? .dark : .light
                func shot(_ v: some View, _ name: String) {
                    let r = ImageRenderer(content: v.frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, scheme).environmentObject(model))
                    r.scale = 1
                    guard let cg = r.cgImage else { return }
                    let url = URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(i)\(dark ? "-dark" : "").png")
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
                }
                _ = model.thumbnailer.image(for: model.preset(id!)!, source: model.library.source,
                                            music: model.library.musicSettings)
                shot(AmbientBackdrop(presetID: id), "old")
                shot(GalleryBackdrop(presetID: id), "new")
            }
        }
        say("backdrops written to \(out)")
    }
}
