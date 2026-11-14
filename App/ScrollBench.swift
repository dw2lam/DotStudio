//  ScrollBench.swift — DEV-ONLY on-screen gallery scroll benchmark; inert unless set.
//
//    DOTSTUDIO_PERF_PROBE=onscreen   (ALWAYS with DOTSTUDIO_STORE_DIR=<fresh temp dir>)
//        Unlike the other probes this one SHOWS a window: frame pacing only exists for a window
//        the window server composites. The main window's content (ContentView, a titled window
//        with its toolbar, 1440x900 unless DOTSTUDIO_PERF_SIZE=<w>x<h>) is ordered in on the
//        main display without activating the app (no Dock icon, no menu bar, focus stays where
//        it is) and click-through (the pointer never hovers it), for ~12 s. Then it scrolls the
//        gallery the way a trackpad does — gesture events (began / changed / ended) followed by
//        momentum events, one per display-link frame, delivered to the gallery's scroll view —
//        through a fixed script: a flick to the bottom, a slow drag up, a flick to the top, a
//        slow drag down, a brisk drag up and a fling down and back. Per gesture it prints:
//          frames      display-link callbacks (the link asks for the display's top rate)
//          hitches     callbacks that came > 1.5× the refresh interval after the previous one
//                      (the main thread missed a frame), the frames lost, the longest gap
//          main ms     main-thread busy time per frame (run-loop work between wake and sleep,
//                      the CA commit included): median, p95, max, frames over one interval
//          bodies      SwiftUI body evaluations (Perf.body) and named events (thumbnail renders…)
//        DOTSTUDIO_PERF_REPEAT=<n>  run the script n times (default 1; a sampler can attach)
//        DOTSTUDIO_PERF_DIRECT=1    move the clip view directly instead of sending events
//
//  Render-server hitches (the window server compositing late) don't show on the main thread;
//  record those with `xcrun xctrace record --template 'Animation Hitches' --launch …` around
//  this probe (tools/perf/scroll-bench.sh does both).

import AppKit
import SwiftUI
import QuartzCore
import IOKit

/// TEMP experiment switches (DOTSTUDIO_EXP=a,b).
enum Exp {
    static let set = Set((ProcessInfo.processInfo.environment["DOTSTUDIO_EXP"] ?? "").split(separator: ",").map(String.init))
    static func has(_ s: String) -> Bool { set.contains(s) }
}

@MainActor
enum ScrollBench {
    private static let env = ProcessInfo.processInfo.environment

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // may show a window; never in the Dock or menu bar
        let (model, updates) = PerfProbe.bootServices()
        DemoHooks.stillPreviews = env["DOTSTUDIO_PERF_LIVE"] == nil
        let size = parseSize(env["DOTSTUDIO_PERF_SIZE"]) ?? CGSize(width: 1440, height: 900)
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(model)
            .environmentObject(updates))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        host.sceneBridgingOptions = [.toolbars, .title]
        win.contentView = host
        win.setContentSize(size)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.transient, .ignoresCycle]
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            win.setFrameOrigin(CGPoint(x: v.midX - win.frame.width / 2, y: v.midY - win.frame.height / 2))
        }
        win.orderFrontRegardless()
        PerfProbe.say(String(format: "scroll bench: window %.0fx%.0f on %@ (%d Hz max)", size.width, size.height,
                             NSScreen.main?.localizedName ?? "?", NSScreen.main?.maximumFramesPerSecond ?? 0))
        drain(5)   // first stills land (prewarm), the window settles
        guard let scroll = galleryScrollView(in: host), let doc = scroll.documentView else {
            PerfProbe.say("scroll bench: no scroll view found"); win.close(); return
        }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        PerfProbe.say(String(format: "scroll bench: %d styles, document %.0f pt, scrolls %.0f pt",
                             model.library.presets.count, doc.frame.height, maxY))
        let bench = Bench(host: host, scroll: scroll, direct: env["DOTSTUDIO_PERF_DIRECT"] != nil)
        let repeats = env["DOTSTUDIO_PERF_REPEAT"].flatMap(Int.init) ?? 1
        var all: [Bench.Result] = []
        for r in 0..<max(1, repeats) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            drain(0.5)
            all += bench.run(script(maxY: maxY), label: repeats > 1 ? " #\(r + 1)" : "")
        }
        Bench.summary(all)
        win.orderOut(nil)
        win.contentView = nil
        win.close()
    }

    // MARK: Script

    /// One frame's input: a gesture event, a momentum event, or nothing.
    enum Step {
        case gesture(dy: CGFloat, phase: CGScrollPhase)
        case momentum(dy: CGFloat, phase: CGMomentumScrollPhase)
        case idle
        /// The pointer comes to rest over the middle of the gallery (see Bench.hoverPointer).
        case pointer
    }

    private static let momentumEvents = env["DOTSTUDIO_PERF_MOMENTUM"] == "events"

    /// dy > 0 scrolls DOWN the page (content moves up), in points per frame at 120 Hz.
    static func script(maxY: CGFloat) -> [(String, [Step])] {
        /// A flick: a short, fast swipe, then a glide that decays as AppKit's momentum does
        /// (0.983 per 120-Hz frame). Synthetic momentum-phase events don't move a scroll view
        /// (AppKit only follows the system's own), so the glide is sent as the gesture's
        /// continuation: the same per-frame offsets and the same live scroll, end to end.
        func flick(_ v: CGFloat, frames: Int = 6, decay: CGFloat = 0.983) -> [Step] {
            var s: [Step] = [.gesture(dy: 0, phase: .mayBegin)]
            for i in 0..<frames { s.append(.gesture(dy: v * CGFloat(i + 1) / CGFloat(frames), phase: i == 0 ? .began : .changed)) }
            var m = v
            if momentumEvents {
                s.append(.gesture(dy: 0, phase: .ended))
                var first = true
                while abs(m) > 0.4 {
                    s.append(.momentum(dy: m, phase: first ? .begin : .continuous))
                    first = false
                    m *= decay
                }
                s.append(.momentum(dy: 0, phase: .end))
            } else {
                while abs(m) > 0.4 {
                    m *= decay
                    s.append(.gesture(dy: m, phase: .changed))
                }
                s.append(.gesture(dy: 0, phase: .ended))
            }
            return s + Array(repeating: .idle, count: 30)
        }
        /// A finger dragging at a steady `v` for `frames`, then lifting with no momentum.
        func drag(_ v: CGFloat, frames: Int) -> [Step] {
            var s: [Step] = [.gesture(dy: 0, phase: .mayBegin)]
            for i in 0..<frames {
                // A real finger isn't perfectly steady.
                let wobble = 1 + 0.25 * sin(CGFloat(i) * 0.37)
                s.append(.gesture(dy: v * wobble, phase: i == 0 ? .began : .changed))
            }
            s.append(.gesture(dy: 0, phase: .ended))
            return s + Array(repeating: .idle, count: 30)
        }
        return [
            ("flick down", flick(42) + flick(42)),
            ("slow drag up", drag(-3, frames: 240)),
            ("flick up", flick(-48) + flick(-48)),
            ("slow drag down", drag(3.5, frames: 240)),
            ("brisk drag up", drag(-14, frames: 120)),
            ("fling down+up", flick(70) + flick(-70)),
            // Down to the tiles; the pointer comes to rest on one (it lifts, its action bar
            // shows), then a flick starts under it (the tile settles back as the page moves).
            ("hover, then flick", drag(3.5, frames: 140) + [.pointer] + Array(repeating: .idle, count: 60) + flick(30)),
        ]
    }

    // MARK: Helpers

    /// Runs the event loop for `s` seconds (events are dispatched, as in the app).
    static func drain(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    /// The gallery's own scroll view (the tallest document).
    static func galleryScrollView(in v: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(v)
        return best
    }

    static func parseSize(_ s: String?) -> CGSize? {
        guard let p = s?.split(separator: "x"), p.count == 2, let w = Double(p[0]), let h = Double(p[1]) else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Bench

@MainActor
final class Bench: NSObject {
    struct Result {
        let name: String
        let intervals: [Double]     // ms between consecutive callbacks
        let busy: [Double]          // ms of main-thread work per frame
        let moving: [Bool]          // the page moved (or was asked to) in that frame
        let refresh: Double         // ms
        let gpu: Double             // mean GPU device utilization % over the gesture (whole system)
        let moved: CGFloat
        let counters: [String: Int]
    }

    private let host: NSView
    private let scroll: NSScrollView
    private let direct: Bool
    private var link: CADisplayLink?
    private var steps: [ScrollBench.Step] = []
    private var index = 0
    private var lastStamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var busy: [Double] = []
    private var moving: [Bool] = []
    private var lastY: CGFloat = 0
    private var asked = false
    private var refresh: Double = 0
    private var busyNow: Double = 0
    private var wokeAt: CFTimeInterval = 0
    private var done = false
    private var observers: [CFRunLoopObserver] = []
    private static let debug = ProcessInfo.processInfo.environment["DOTSTUDIO_PERF_DEBUG"] != nil
    private var debugCount = 0

    /// Emulates the pointer resting over the middle of the gallery (as it is when a trackpad
    /// scrolls it): the hosting view gets a mouse-entered/moved there, in this process only —
    /// the real pointer never moves. DOTSTUDIO_PERF_POINTER=0 leaves it out.
    private let pointer = ProcessInfo.processInfo.environment["DOTSTUDIO_PERF_POINTER"] != "0"
    private let gpu = GPUSampler()

    private func hoverPointer() {
        guard let w = scroll.window else { return }
        let p = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        if let ev = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: t,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
            host.mouseEntered(with: ev)
        }
        if let ev = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: t,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            host.mouseMoved(with: ev)
        }
    }

    init(host: NSView, scroll: NSScrollView, direct: Bool) {
        self.host = host
        self.scroll = scroll
        self.direct = direct
        super.init()
        // Main-thread busy time: from each wake-up to the next sleep (CA's commit observer
        // runs before the sleep observer with the highest order).
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wokeAt = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.wokeAt > 0 else { return }
                self.busyNow += (CACurrentMediaTime() - self.wokeAt) * 1000
                self.wokeAt = 0
            }
        }
        for o in [wake, sleep] {
            if let o { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes); observers.append(o) }
        }
    }

    func run(_ script: [(String, [ScrollBench.Step])], label: String) -> [Result] {
        var out: [Result] = []
        for (name, steps) in script {
            self.steps = steps
            index = 0
            intervals = []; busy = []; moving = []; asked = false
            lastY = scroll.contentView.bounds.origin.y
            lastStamp = 0; busyNow = 0; done = false
            let y0 = scroll.contentView.bounds.origin.y
            _ = Perf.take()
            if pointer { hoverPointer() }
            gpu.start()
            let l = host.displayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
            while !done { ScrollBench.drain(0.05) }
            l.invalidate()
            link = nil
            let gpuMean = gpu.stop()
            ScrollBench.drain(0.1)
            let r = Result(name: name + label, intervals: intervals, busy: busy, moving: moving, refresh: refresh, gpu: gpuMean,
                           moved: scroll.contentView.bounds.origin.y - y0, counters: Perf.take())
            Self.print(r)
            out.append(r)
        }
        return out
    }

    @objc private func tick(_ l: CADisplayLink) {
        refresh = (l.targetTimestamp - l.timestamp) * 1000
        if lastStamp > 0 {
            intervals.append((l.timestamp - lastStamp) * 1000)
            busy.append(busyNow)
            let y = scroll.contentView.bounds.origin.y
            moving.append(asked || y != lastY)
            lastY = y
        }
        busyNow = 0
        lastStamp = l.timestamp
        guard index < steps.count else { done = true; return }
        let step = steps[index]
        index += 1
        switch step {
        case .gesture(let dy, _), .momentum(let dy, _): asked = dy != 0
        case .idle, .pointer: asked = false
        }
        switch step {
        case .idle: break
        case .pointer: hoverPointer()
        case .gesture(let dy, let phase): send(dy: dy, phase: phase.rawValue, momentum: 0)
        case .momentum(let dy, let phase): send(dy: dy, phase: 0, momentum: phase.rawValue)
        }
    }

    private func send(dy: CGFloat, phase: UInt32, momentum: UInt32) {
        if direct {
            let clip = scroll.contentView
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            let y = min(max(clip.bounds.origin.y + dy, 0), maxY)
            if phase == CGScrollPhase.began.rawValue {
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            let nextIdle: Bool = { if index < steps.count, case .idle = steps[index] { return true }; return false }()
            if momentum == CGMomentumScrollPhase.end.rawValue || (phase == CGScrollPhase.ended.rawValue && nextIdle) {
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            }
            return
        }
        // A trackpad's continuous scroll event at the middle of the gallery.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32((-dy).rounded()), wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((-dy).rounded()))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(-dy))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
        if let w = scroll.window, let screen = w.screen ?? NSScreen.main {
            let p = w.convertPoint(toScreen: scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
            cg.location = CGPoint(x: p.x, y: screen.frame.maxY - p.y)
        }
        guard let ev = NSEvent(cgEvent: cg) else { return }
        if Self.debug, debugCount < 40, momentum != 0 || phase != 0 {
            debugCount += 1
            let y0 = scroll.contentView.bounds.origin.y
            scroll.scrollWheel(with: ev)
            PerfProbe.say("  ev phase \(ev.phase.rawValue) momentum \(ev.momentumPhase.rawValue) dy \(ev.scrollingDeltaY) precise \(ev.hasPreciseScrollingDeltas) moved \(scroll.contentView.bounds.origin.y - y0)")
            return
        }
        scroll.scrollWheel(with: ev)
    }

    // MARK: Report

    private static func pct(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    /// Over the frames in which the page moved (a gap there is a visible stutter).
    static func stats(_ r: Result) -> (frames: Int, hitches: Int, lost: Int, worst: Double, busy: [Double], over: Int) {
        let limit = r.refresh * 1.5
        var hitches = 0, lost = 0, worst = 0.0
        var busy: [Double] = []
        for (k, i) in r.intervals.enumerated() where r.moving[k] {
            busy.append(r.busy[k])
            worst = max(worst, i)
            if i > limit {
                hitches += 1
                lost += max(1, Int((i / r.refresh).rounded()) - 1)
            }
        }
        return (busy.count, hitches, lost, worst, busy, busy.filter { $0 > r.refresh }.count)
    }

    static func print(_ r: Result) {
        let s = stats(r)
        PerfProbe.say(String(format: "GESTURE %-16@ moving frames %4d @ %.2f ms  moved %6.0f pt  hitches %3d (lost %3d, worst %5.1f ms)  main ms/frame: mean %.2f median %.2f p95 %.2f max %.1f  >1 frame: %d",
                             r.name as NSString, s.frames, r.refresh, r.moved, s.hitches, s.lost, s.worst,
                             s.busy.reduce(0, +) / Double(max(s.busy.count, 1)), pct(s.busy, 0.5), pct(s.busy, 0.95), s.busy.max() ?? 0, s.over))
        let idle = zip(r.busy, r.moving).filter { !$0.1 }.map(\.0)
        PerfProbe.say(String(format: "    still frames %d: main ms/frame mean %.2f max %.1f · GPU device utilization (whole system) %.1f%%", idle.count,
                             idle.reduce(0, +) / Double(max(idle.count, 1)), idle.max() ?? 0, r.gpu))
        let bodies = r.counters.filter { $0.key.hasPrefix("body:") }
        let other = r.counters.filter { !$0.key.hasPrefix("body:") }
        if !bodies.isEmpty {
            PerfProbe.say("    bodies \(bodies.values.reduce(0, +)): " + bodies.sorted { $0.value > $1.value }
                .map { "\($0.key.dropFirst(5))=\($0.value)" }.joined(separator: " "))
        }
        if !other.isEmpty {
            PerfProbe.say("    events: " + other.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
    }

    static func summary(_ all: [Result]) {
        let st = all.map(stats)
        let frames = st.reduce(0) { $0 + $1.frames }
        let hitches = st.reduce(0) { $0 + $1.hitches }
        let lost = st.reduce(0) { $0 + $1.lost }
        let busy = st.flatMap(\.busy)
        let refresh = all.first?.refresh ?? 8.33
        let bodies = all.reduce(0) { $0 + $1.counters.filter { $0.key.hasPrefix("body:") }.values.reduce(0, +) }
        let gpu = all.map(\.gpu).reduce(0, +) / Double(max(all.count, 1))
        PerfProbe.say(String(format: "TOTAL GPU utilization (whole system) mean %.1f%%", gpu))
        PerfProbe.say(String(format: "TOTAL moving frames %d  hitches %d  lost %d (%.2f%%)  main ms/frame: mean %.2f median %.2f p95 %.2f p99 %.2f max %.1f  >1 frame: %d  bodies %d",
                             frames, hitches, lost, Double(lost) / Double(max(frames, 1)) * 100,
                             busy.reduce(0, +) / Double(max(busy.count, 1)), pct(busy, 0.5), pct(busy, 0.95), pct(busy, 0.99),
                             busy.max() ?? 0, busy.filter { $0 > refresh }.count, bodies))
    }
}

// MARK: - GPU utilization

/// Samples the GPU's "Device Utilization %" (IORegistry PerformanceStatistics of the
/// accelerator: the whole system's GPU, the window server's compositing included) every
/// 20 ms on a background thread. Noisy, but compositing cost moves it.
final class GPUSampler: @unchecked Sendable {
    private var samples: [Double] = []
    private let lock = NSLock()
    private var running = false

    func start() {
        lock.lock(); samples = []; running = true; lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                guard go else { return }
                if let u = Self.read() { lock.lock(); samples.append(u); lock.unlock() }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    func stop() -> Double {
        lock.lock(); defer { lock.unlock() }
        running = false
        return samples.isEmpty ? -1 : samples.reduce(0, +) / Double(samples.count)
    }

    private static func read() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while true {
            let svc = IOIteratorNext(it)
            if svc == 0 { break }
            defer { IOObjectRelease(svc) }
            if let stats = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u)
            }
        }
        return best
    }
}
