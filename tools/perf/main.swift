//  tools/perf/main.swift — CPU / allocation / file-system / wake-up harness for the render loop.
//  Nothing is shown on screen: the renderer draws into a CAMetalLayer that's in no window, the
//  saver's view lives in a window that's never ordered in, and the wallpaper's render loop drives
//  an offscreen layer from a real display link. Everything reads a temp store (DOTSTUDIO_STORE_DIR)
//  and fixtures — never the user's library. Build + run with tools/perf/run.sh.
//
//  usage: perf <mode> [--fps 30,120] [--seconds 4] [--only name,…] [--size 3024x1964]
//  modes:
//    renderer   MetalRenderer.draw(to:) on the main thread, paced at each fps (the wallpaper's frame)
//    saver      DotSaverView.animateOneFrame at each fps (the screensaver's whole tick: polls, overlay)
//    wallpaper  WallpaperRenderLoop driving an offscreen layer from a display link (continuous, clock)
//    idle       WallpaperRenderLoop paused / covered / clock: wake-ups and CPU per second
//  Columns: call = CPU ms in the frame call on its own thread; main = the main thread's CPU per
//  frame including its run loop (CA commits, timers); proc = the whole process's CPU per frame
//  (Metal completion threads, decoders); allocs = malloc calls per frame on the frame's thread /
//  in the whole process; fs = stat-class calls and opens+reads per second under the store and
//  fixtures; wk = process wake-ups per second (interrupt + package idle).

import AppKit
import Metal
import QuartzCore
import ScreenSaver
import MetalKit

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { print("usage: perf renderer|saver|wallpaper|idle [...]"); exit(2) }
args.removeFirst()
var fpsList: [Double] = [30, 120]
var seconds = 4.0
var only: [String] = []
var W = 3024, H = 1964
/// --power ac|battery|lowpower: run the real power policy instead of --fps. saver: pins the saver's
/// power state (DOTSTUDIO_SAVER_FORCE) and paces frames at the interval it then asks for, at the
/// drawable it sizes. wallpaper: WallpaperBudget with default settings (Balanced, Quality Balanced =
/// 0.75 of --size, On Battery Efficient) picks fps and drawable; Low Power holds a still.
var power: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--fps": fpsList = args.removeFirst().split(separator: ",").compactMap { Double($0) }
    case "--seconds": seconds = Double(args.removeFirst()) ?? seconds
    case "--only": only = args.removeFirst().lowercased().split(separator: ",").map(String.init)
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    case "--power": power = args.removeFirst().lowercased()
    default: print("unknown \(a)"); exit(2)
    }
}

if let power, mode == "saver" { setenv("DOTSTUDIO_SAVER_FORCE", power, 1) }   // before any DotSaverView

guard let storeDir = ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] else {
    print("set DOTSTUDIO_STORE_DIR to a temp dir"); exit(2)
}
let fixtures = ProcessInfo.processInfo.environment["PERF_FIXTURES"] ?? ""
if perf_hooks_install() == 0 { print("warning: no malloc_logger — allocation counts are 0") }
perf_hooks_watch(URL(fileURLWithPath: storeDir).resolvingSymlinksInPath().path)
perf_hooks_watch(storeDir)
if !fixtures.isEmpty { perf_hooks_watch(fixtures) }

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

// MARK: Counters

func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
func processCPU() -> Double {
    var r = rusage()
    getrusage(RUSAGE_SELF, &r)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(r.ru_utime) + s(r.ru_stime)
}
func wakeups() -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? info.ri_interrupt_wkups + info.ri_pkg_idle_wkups : 0
}
/// CPU seconds of the thread named `name` (the wallpaper's render thread).
func namedThreadCPU(_ name: String) -> Double {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
    defer {
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }
    var total = 0.0
    for i in 0..<Int(count) {
        var info = thread_extended_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &n) }
        }
        guard kr == KERN_SUCCESS else { continue }
        let tn = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if tn == name { total += Double(info.pth_user_time + info.pth_system_time) / 1e9 }
    }
    return total
}

struct Snap {
    let t = CACurrentMediaTime(), main = threadCPU(), proc = processCPU(), allocs = perf_allocs_total()
    let tallocs = perf_allocs_thread()
    let stats = perf_fs_stats(), opens = perf_fs_opens() + perf_fs_reads(), wk = wakeups()
}

struct Row {
    var name: String, fps: Double, frames: Int
    var call = 0.0, main = 0.0, proc = 0.0, callAllocs = 0.0, procAllocs = 0.0
    var stats = 0.0, opens = 0.0, wk = 0.0, extra = ""
}
func report(_ r: Row) {
    print(String(format: "%@ %4.0f fps %5d fr | call %6.3f ms  main %6.3f ms  proc %6.3f ms | allocs %7.1f / %7.1f | fs %5.1f stat/s %5.1f io/s | wk %6.1f/s %@",
                 r.name.padding(toLength: 24, withPad: " ", startingAt: 0), r.fps, r.frames, r.call, r.main, r.proc, r.callAllocs, r.procAllocs, r.stats, r.opens, r.wk, r.extra))
}

/// Spin the main run loop (CA commits, timers, dispatch to main) until `deadline`.
func runLoop(until deadline: CFTimeInterval) {
    while CACurrentMediaTime() < deadline {
        let d = Date(timeIntervalSinceNow: max(deadline - CACurrentMediaTime(), 0))
        _ = RunLoop.main.run(mode: .default, before: d)
    }
}

// MARK: Scenarios

let lib = DefaultPresets.makeLibrary()
let allPresets = lib.presets + DefaultPresets.coolPack() + SceneCatalog.presets + DefaultPresets.looks()
func preset(_ name: String) -> Preset {
    guard let p = allPresets.first(where: { $0.name == name }) else { print("no preset \(name)"); exit(1) }
    return p
}

struct Scenario {
    var name: String
    var preset: Preset
    var source = SourceSpec()
    var music: MusicSpec?
    var weather = false
}
func musicSpec(full: MusicSpec.Backdrop?) -> MusicSpec {
    var m = MusicSpec(cardCorner: full == nil ? .bottomLeft : nil, cardSize: .medium, fullBackdrop: full, fullLayout: .album)
    m.setDisplay(full != nil ? .fullScreen : .corner)
    return m
}
let store = SharedStore(role: .app)

/// A Custom Scene (CustomScenes.swift): the metal engine's first example package, installed into
/// the temp store — the saver compiles it at runtime (its first frame waits for the pipeline).
func customScenePreset() -> Preset? {
    guard let ex = CustomScenes.engines(store: store.baseDir).first(where: { $0.id == "metal" })?.exampleURLs.first,
          let id = try? CustomScenes.install(packageAt: ex, into: store.baseDir),
          let m = CustomScenes.manifest(id: id, store: store.baseDir) else { return nil }
    return .customScene(m)
}
let customPreset = customScenePreset()

var scenarios: [Scenario] = [
    Scenario(name: "Liquid Chrome", preset: preset("Liquid Chrome")),
    Scenario(name: "Tidewater (live wx)", preset: preset("Tidewater"), weather: true),
    // the saver's cost cap (a smaller drawable under the rain) and stepped pacing (24 fps steps)
    Scenario(name: "Meadow (live wx)", preset: preset("Meadow"), weather: true),
    Scenario(name: "Bloom", preset: preset("Blue Bloom")),
    Scenario(name: "Penguin", preset: preset("Penguin")),
    Scenario(name: "Zen Garden", preset: preset("Zen Garden")),
    Scenario(name: "Flip Clock", preset: preset("Flip Clock")),
    Scenario(name: "Chronometer", preset: preset("Chronometer")),
    Scenario(name: "StandBy", preset: preset("StandBy")),
    Scenario(name: "Look: Film slideshow", preset: preset("Film"), source: .builtInPhotos),
    Scenario(name: "Music corner", preset: preset("Liquid Chrome"), music: musicSpec(full: nil)),
    Scenario(name: "Music full (veil)", preset: preset("Liquid Chrome"), music: musicSpec(full: .screensaver)),
    Scenario(name: "Music full (art)", preset: preset("Liquid Chrome"), music: musicSpec(full: .albumArt)),
] + (customPreset.map { [Scenario(name: "Custom Scene (\($0.name))", preset: $0)] } ?? [])
if !only.isEmpty { scenarios = scenarios.filter { s in only.contains { s.name.lowercased().contains($0) } } }
if customPreset == nil { print("warning: no Custom Scene example to install (Engines/ next to the binary?)") }

/// Live weather (rain, fetched now) for Tidewater, written where every WeatherFeed reads it.
func writeWeather() {
    var w = WeatherState()
    w.version = 1
    w.condition = .rain
    w.cloudCover = 1; w.precipitation = 0.55; w.windSpeed = 8; w.windGusts = 12; w.visibility = 6000
    w.fetchedAt = Date().timeIntervalSince1970
    if let d = try? JSONEncoder().encode(w) {
        try? d.write(to: store.baseDir.appendingPathComponent(WeatherState.fileName), options: .atomic)
    }
}
writeWeather()

/// The library the saver reads for a scenario: just its style, active.
func writeLibrary(_ s: Scenario) {
    var l = Library()
    l.presets = [s.preset]
    l.activeID = s.preset.id
    l.source = s.source
    l.music = s.music ?? { var m = MusicSpec(); m.setDisplay(.off); return m }()
    _ = store.save(l)
}

func musicSnapshot() -> MusicSnapshot {
    let f = MusicFeed(baseDir: store.baseDir)
    f.poll()
    return f.snapshot
}

// MARK: Allocation sites (PERF_TRACE=1)

let tracing = ProcessInfo.processInfo.environment["PERF_TRACE"] == "1"

/// The main thread's allocations inside the frame calls, grouped by the first frame in this
/// binary (the app code that asked) and the system function it went through.
func dumpTrace(frames: Int) {
    let n = Int(perf_trace_end())
    var counts: [String: Int] = [:]
    var names: Set<String> = []
    var keys: [(app: String, via: String)] = []
    let me = CommandLine.arguments[0]
    for i in 0..<n {
        let d = Int(perf_trace_depth(Int32(i)))
        var via = "?", app = "(no app frame)"
        for k in 2..<max(d, 2) {
            guard let pc = perf_trace_frame(Int32(i), Int32(k)) else { continue }
            var info = Dl_info()
            guard dladdr(pc, &info) != 0 else { continue }
            let file = info.dli_fname.map { String(cString: $0) } ?? ""
            let sym = info.dli_sname.map { String(cString: $0) } ?? "?"
            if file.hasSuffix("/perf") || file == me {
                app = sym; break
            }
            via = sym
        }
        names.insert(app); names.insert(via)
        keys.append((app, via))
    }
    // demangle in one go
    var demangled: [String: String] = [:]
    let list = Array(names)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["swift-demangle", "--simplified"]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe; p.standardOutput = outPipe
    try? p.run()
    inPipe.fileHandleForWriting.write(list.joined(separator: "\n").data(using: .utf8)!)
    try? inPipe.fileHandleForWriting.close()
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    for (a, b) in zip(list, out.split(separator: "\n", omittingEmptySubsequences: false)) {
        demangled[a] = String(b.prefix(140))
    }
    for k in keys { counts["\(demangled[k.app] ?? k.app)\n        via \(demangled[k.via] ?? k.via)", default: 0] += 1 }
    print(String(format: "  allocation sites (main thread, %.1f per frame):", Double(n) / Double(max(frames, 1))))
    for (k, c) in counts.sorted(by: { $0.value > $1.value }).prefix(40) {
        print(String(format: "  %6.2f/fr  %@", Double(c) / Double(max(frames, 1)), k))
    }
}

// MARK: Renderer (the wallpaper's per-frame call, no loop)

func runRenderer(_ s: Scenario, fps: Double) -> Row {
    let layer = CAMetalLayer()
    guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { print("no renderer"); exit(1) }
    layer.device = r.device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    layer.drawableSize = CGSize(width: W, height: H)
    if let m = s.music {
        let snap = musicSnapshot()
        r.setMusic(snap)
        let p = MusicPresentation.resolve(settings: m, music: snap, preset: s.preset)
        r.setMusicBackdrop(p.backdrop, animated: false)
    }
    r.apply(s.preset, source: s.source)
    // warm: pipelines, atlases, the first photos
    for _ in 0..<10 { r.draw(to: layer); runLoop(until: CACurrentMediaTime() + 0.03) }
    runLoop(until: CACurrentMediaTime() + 0.3)
    let frames = Int(fps * seconds)
    let dt = 1 / fps
    var call = 0.0, callAllocs: UInt64 = 0
    let a = Snap()
    var next = CACurrentMediaTime()
    if tracing { perf_trace_begin() }
    defer { if tracing { dumpTrace(frames: frames) } }
    for _ in 0..<frames {
        let c0 = threadCPU(), al0 = perf_allocs_thread()
        if tracing { perf_trace_begin_resume() }
        r.draw(to: layer)
        if tracing { perf_trace_pause() }
        call += threadCPU() - c0
        callAllocs += perf_allocs_thread() - al0
        next += dt
        runLoop(until: next)
    }
    let b = Snap()
    let n = Double(frames), span = b.t - a.t
    return Row(name: s.name, fps: fps, frames: frames, call: call / n * 1000, main: (b.main - a.main) / n * 1000,
               proc: (b.proc - a.proc) / n * 1000, callAllocs: Double(callAllocs) / n,
               procAllocs: Double(b.allocs - a.allocs) / n, stats: Double(b.stats - a.stats) / span,
               opens: Double(b.opens - a.opens) / span, wk: Double(b.wk - a.wk) / span)
}

// MARK: Saver (DotSaverView's whole tick)

func runSaver(_ s: Scenario, fps: Double) -> Row {
    writeLibrary(s)
    let pts = CGSize(width: CGFloat(W) / 2, height: CGFloat(H) / 2)
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: pts), styleMask: [.borderless], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    // never ordered in: nothing reaches the screen
    guard let v = DotSaverView(frame: NSRect(origin: .zero, size: pts), isPreview: false) else { print("no saver"); exit(1) }
    win.contentView = v
    let warmUntil = CACurrentMediaTime() + 8
    var drawn = false
    while CACurrentMediaTime() < warmUntil {
        v.animateOneFrame()
        runLoop(until: CACurrentMediaTime() + 1 / 30)
        if !drawn, v.subviews.first?.alphaValue ?? 0 > 0 { drawn = true; break }
    }
    if !drawn, let mv = v.subviews.first as? MTKView {
        let l = mv.layer as? CAMetalLayer
        print("warning: the saver never drew — layer=\(String(describing: l)) ds=\(String(describing: l?.drawableSize)) mvds=\(mv.drawableSize) dev=\(String(describing: l?.device?.name)) fmt=\(String(describing: l?.pixelFormat.rawValue))")
    }
    for _ in 0..<15 { v.animateOneFrame(); runLoop(until: CACurrentMediaTime() + 1 / 30) }
    runLoop(until: CACurrentMediaTime() + 1.2)                     // let the overlay's fade settle
    // --power: the rate the saver asks the host for under that budget (and the drawable it sized).
    let fps = power != nil ? 1 / v.animationTimeInterval : fps
    let ds = (v.subviews.first as? MTKView)?.drawableSize ?? .zero
    let frames = Int(fps * seconds)
    let dt = 1 / fps
    var call = 0.0, callAllocs: UInt64 = 0
    let a = Snap()
    var next = CACurrentMediaTime()
    if tracing { perf_trace_begin() }
    for _ in 0..<frames {
        let c0 = threadCPU(), al0 = perf_allocs_thread()
        if tracing { perf_trace_begin_resume() }
        v.animateOneFrame()
        if tracing { perf_trace_pause() }
        call += threadCPU() - c0
        callAllocs += perf_allocs_thread() - al0
        next += dt
        runLoop(until: next)
    }
    let b = Snap()
    if tracing { dumpTrace(frames: frames) }
    v.removeFromSuperview()                       // detach → the saver tears its stack down
    win.contentView = nil
    runLoop(until: CACurrentMediaTime() + 0.2)
    let n = Double(frames), span = b.t - a.t
    return Row(name: s.name, fps: fps, frames: frames, call: call / n * 1000, main: (b.main - a.main) / n * 1000,
               proc: (b.proc - a.proc) / n * 1000, callAllocs: Double(callAllocs) / n,
               procAllocs: Double(b.allocs - a.allocs) / n, stats: Double(b.stats - a.stats) / span,
               opens: Double(b.opens - a.opens) / span, wk: Double(b.wk - a.wk) / span,
               extra: String(format: "[%.0fx%.0f]", ds.width, ds.height) + (drawn ? "" : " (never drew)"))
}

// MARK: Wallpaper loop

final class WallpaperRig {
    let loop: WallpaperRenderLoop
    let layer = CAMetalLayer()
    let id: CGDirectDisplayID
    let screen: NSScreen
    init(_ s: Scenario, drawable: CGSize = CGSize(width: W, height: H)) {
        screen = NSScreen.main!
        id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        loop = WallpaperRenderLoop(store: store)
        let device = WallpaperGPU.device(for: id)!
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        let link = screen.displayLink(target: WallpaperRenderLoop.linkTarget(loop, display: id),
                                      selector: WallpaperRenderLoop.linkSelector)
        loop.addDisplay(id, token: 1, layer: layer, link: link, device: device,
                        config: WallpaperSurfaceConfig(drawableSize: drawable,
                                                       refreshRate: Double(screen.maximumFramesPerSecond)))
        loop.setStyle(s.preset, source: s.source, location: nil)
    }
    func state(_ s: Scenario, fps: Double, canDraw: Bool = true, visible: Bool = true, still: Bool = false) {
        loop.update(WallpaperFrameState(canDraw: canDraw, visible: visible ? [id] : [],
                                        profile: WallpaperPacing.profile(for: s.preset, source: s.source),
                                        fps: fps, still: still), forceDraw: true)
    }
}

func measureLoop(_ rig: WallpaperRig, name: String, fps: Double, extra: String = "") -> Row {
    let a = Snap(), f0 = rig.loop.framesDrawnTotal, r0 = namedThreadCPU("DotStudio Wallpaper Render")
    runLoop(until: CACurrentMediaTime() + seconds)
    let b = Snap(), f1 = rig.loop.framesDrawnTotal, r1 = namedThreadCPU("DotStudio Wallpaper Render")
    let frames = f1 - f0
    let n = Double(max(frames, 1)), span = b.t - a.t
    // per frame when it draws; per second (as "frames" = 0) when idle
    let per = frames > 0 ? n : span
    return Row(name: name, fps: fps, frames: frames, call: (r1 - r0) / per * 1000, main: (b.main - a.main) / per * 1000,
               proc: (b.proc - a.proc) / per * 1000, callAllocs: .nan, procAllocs: Double(b.allocs - a.allocs) / per,
               stats: Double(b.stats - a.stats) / span, opens: Double(b.opens - a.opens) / span,
               wk: Double(b.wk - a.wk) / span, extra: extra + (frames > 0 ? "" : " (per SECOND, nothing drawn)"))
}

// MARK: Run

switch mode {
case "renderer":
    print("renderer: MetalRenderer.draw(to:) at \(W)x\(H)  [call = render thread CPU per frame]")
    for s in scenarios { for fps in fpsList { report(runRenderer(s, fps: fps)) } }
case "saver":
    print("saver: DotSaverView.animateOneFrame at \(W)x\(H) px  [call = the whole tick on the main thread]")
    for s in scenarios { for fps in fpsList { report(runSaver(s, fps: fps)) } }
    // The saver drew the Custom Scene with its own runtime-compiled pipeline, not the stand-in.
    if let c = customPreset, scenarios.contains(where: { $0.preset.id == c.id }), let id = c.effects.first?.custom?.id {
        let st = CustomSceneLink.shared(store: store.baseDir).status(id)
        print(st == .ready ? "saver: Custom Scene \(c.name): PASS — compiled at runtime and drawn by the saver"
                           : "saver: Custom Scene \(c.name): FAIL — \(st)")
        if st != .ready { exit(1) }
    }
case "wallpaper" where power != nil:
    // The controller's policy (WallpaperBudget) with default settings, on a --size native screen.
    var settings = WallpaperSettings()
    if let m = ProcessInfo.processInfo.environment["PERF_ON_BATTERY"].flatMap(WallpaperSettings.BatteryMode.init) {
        settings.batteryMode = m
    }
    var st = WallpaperPowerMonitor.State()
    st.onBattery = power == "battery"
    st.lowPowerMode = power == "lowpower"
    let ppp = settings.quality.pixelsPerPoint(backing: 2) / 2          // of native pixels
    print("wallpaper --power \(power!): WallpaperBudget, quality \(settings.quality.rawValue), on battery \(settings.batteryMode.rawValue), native \(W)x\(H)  [call = render thread CPU per frame]")
    for s in scenarios where s.music == nil {
        let profile = WallpaperPacing.profile(for: s.preset, source: s.source)
        let scale = ppp * WallpaperBudget.renderScale(settings, onBattery: st.onBattery, profile: profile)
        let ds = CGSize(width: (CGFloat(W) * scale).rounded(), height: (CGFloat(H) * scale).rounded())
        let fps = WallpaperBudget.fps(settings, presetFPS: s.preset.fps, onBattery: st.onBattery)
        let still = WallpaperBudget.stillReason(settings, st) != nil
        let rig = WallpaperRig(s, drawable: ds)
        rig.state(s, fps: fps, canDraw: true, still: still)   // Low Power: a held still (stillReason)
        runLoop(until: CACurrentMediaTime() + 1.0)
        report(measureLoop(rig, name: s.name, fps: fps, extra: String(format: "[%.0fx%.0f]", ds.width, ds.height)))
        rig.loop.removeAll()
        runLoop(until: CACurrentMediaTime() + 0.3)
    }
case "wallpaper":
    print("wallpaper: WallpaperRenderLoop + display link at \(W)x\(H)  [call = render thread CPU per frame]")
    for s in scenarios where s.music == nil {
        let rig = WallpaperRig(s)
        for fps in fpsList {
            rig.state(s, fps: fps)
            runLoop(until: CACurrentMediaTime() + 1.0)
            report(measureLoop(rig, name: s.name, fps: fps))
        }
        rig.loop.removeAll()
        runLoop(until: CACurrentMediaTime() + 0.3)
    }
case "saverpin":
    // The screensaver view finds its display and plays that display's own style
    // (Library.displayStyles): a view in a window on the main screen (never ordered in), its
    // display pinned to Flip Clock while the lineup is Liquid Chrome; then the pin is removed,
    // then a pin for another (unplugged) display only. Read back from the store's debug log.
    let fm = FileManager.default
    fm.createFile(atPath: store.baseDir.appendingPathComponent("debug.enabled").path, contents: Data())
    let logURL = store.baseDir.appendingPathComponent("debug.log")
    let screen = NSScreen.main!
    let key = DisplayIdentity.key(screen)!
    let chrome = preset("Liquid Chrome"), clock = preset("Flip Clock")
    func write(_ pins: [String: DisplayPin]?) {
        var l = Library()
        l.presets = [chrome, clock]
        l.activeID = chrome.id
        l.displayStyles = pins
        var m = MusicSpec(); m.setDisplay(.off); l.music = m
        _ = store.save(l)
    }
    write([key: DisplayPin(presetID: clock.id, name: screen.localizedName)])
    let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
    win.isReleasedWhenClosed = false
    // never ordered in: nothing reaches the screen
    guard let v = DotSaverView(frame: NSRect(origin: .zero, size: screen.frame.size), isPreview: false) else { exit(1) }
    win.contentView = v
    func frames(_ n: Int) { for _ in 0..<n { v.animateOneFrame(); runLoop(until: CACurrentMediaTime() + 1 / 30) } }
    func shown() -> [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { $0.contains("] showing ") }.map { String($0.split(separator: "]").last ?? "") }
    }
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { print((ok ? "ok    " : "FAIL  ") + what); if !ok { fails += 1 } }
    print("saverpin: window.screen = \(win.screen?.localizedName ?? "nil"), key \(key)")
    frames(3)
    let first = shown()
    expect(first.last?.contains("Flip Clock") == true && first.last?.contains(key) == true,
           "pinned display plays its own style from the first frames: \(first)")
    expect(!first.contains { $0.contains("Liquid Chrome") },
           "never loads the shared style first (the first load waits for the screen)")
    // A view whose window never gets a screen still draws, after the short wait.
    let lost = DotSaverView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), isPreview: false)!
    let before = shown().count
    for _ in 0..<3 { lost.animateOneFrame(); runLoop(until: CACurrentMediaTime() + 1 / 30) }
    expect(shown().count == before, "no window: nothing loaded")
    let lostWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless],
                           backing: .buffered, defer: false)
    lostWin.isReleasedWhenClosed = false
    lostWin.contentView = lost
    for _ in 0..<30 { lost.animateOneFrame(); runLoop(until: CACurrentMediaTime() + 1 / 30) }
    expect(shown().count > before, "a view in a window loads its style within the wait (\(shown().last ?? "-"))")
    lostWin.contentView = nil
    write(nil)
    frames(45)                                   // the 1 Hz reload
    expect(shown().last?.contains("Liquid Chrome") == true, "pin removed: back to the lineup (\(shown().last ?? "-"))")
    write(["00000000-0000-0000-0000-00000000DEAD": DisplayPin(presetID: clock.id, name: "Unplugged")])
    frames(45)
    expect(shown().last?.contains("Liquid Chrome") == true, "a pin for another display changes nothing here")
    var preview: DotSaverView? = DotSaverView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), isPreview: true)
    write([key: DisplayPin(presetID: clock.id, name: screen.localizedName)])
    let pwin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                        backing: .buffered, defer: false, screen: screen)
    pwin.contentView = preview
    for _ in 0..<3 { preview?.animateOneFrame(); runLoop(until: CACurrentMediaTime() + 1 / 10) }
    expect(shown().last?.contains("Liquid Chrome") == true && shown().last?.contains("display -") == true,
           "the System Settings thumbnail shows the lineup, not a display's pin")
    preview = nil
    print(fails == 0 ? "saverpin: PASS" : "saverpin: \(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
case "displays":
    // Two displays with styles of their own on one render loop (WallpaperRenderLoop.setStyles):
    // Liquid Chrome (motion, display-link paced) on one, Flip Clock (1 Hz ticks) on the other —
    // each paced by its own plan. Two offscreen layers on the main screen's link (the second
    // display ID is made up; nothing is shown). Then the motion display is covered: it stops,
    // the clock keeps ticking.
    let screen = NSScreen.main!
    let realID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    let a = realID, b = realID &+ 7777
    let loop = WallpaperRenderLoop(store: store)
    let device = WallpaperGPU.device(for: realID)!
    var layers: [CAMetalLayer] = []
    for id in [a, b] {
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = true
        layer.maximumDrawableCount = 3; layer.allowsNextDrawableTimeout = true
        layers.append(layer)
        let link = screen.displayLink(target: WallpaperRenderLoop.linkTarget(loop, display: id),
                                      selector: WallpaperRenderLoop.linkSelector)
        loop.addDisplay(id, token: UInt64(id), layer: layer, link: link, device: device,
                        config: WallpaperSurfaceConfig(drawableSize: CGSize(width: 1280, height: 800),
                                                       refreshRate: Double(screen.maximumFramesPerSecond)))
    }
    let chrome = preset("Liquid Chrome"), clock = preset("Flip Clock")
    loop.setStyles([a: chrome, b: clock], fallback: chrome, source: SourceSpec(), location: nil)
    func pace(_ p: Preset) -> WallpaperFrameState.Pacing {
        .init(profile: WallpaperPacing.profile(for: p, source: SourceSpec()), fps: 30, stepFPS: nil)
    }
    var fails = 0
    func measure(_ label: String, visible: Set<CGDirectDisplayID>, expectA: ClosedRange<Double>, expectB: ClosedRange<Double>) {
        loop.update(WallpaperFrameState(canDraw: true, visible: visible, still: false,
                                        displays: [a: pace(chrome), b: pace(clock)]), forceDraw: true)
        runLoop(until: CACurrentMediaTime() + 1.0)
        let a0 = loop.framesDrawnPerDisplay[a] ?? 0, b0 = loop.framesDrawnPerDisplay[b] ?? 0
        runLoop(until: CACurrentMediaTime() + seconds)
        let ra = Double((loop.framesDrawnPerDisplay[a] ?? 0) - a0) / seconds
        let rb = Double((loop.framesDrawnPerDisplay[b] ?? 0) - b0) / seconds
        let ok = expectA.contains(ra) && expectB.contains(rb)
        if !ok { fails += 1 }
        print(String(format: "%@ %@: Liquid Chrome %.1f fps, Flip Clock %.1f fps", ok ? "ok  " : "FAIL", label, ra, rb))
    }
    print("displays: two styles on one render loop, 1280x800 each, \(Int(seconds)) s per step")
    // A minute burst of the flip clock may fall in a window: allow it a few frames over 1/s.
    measure("both visible", visible: [a, b], expectA: 25...31, expectB: 0.5...8)
    measure("motion display covered", visible: [b], expectA: 0...0, expectB: 0.5...8)
    measure("clock display covered", visible: [a], expectA: 25...31, expectB: 0...0)
    loop.removeAll()
    runLoop(until: CACurrentMediaTime() + 0.3)
    print(fails == 0 ? "displays: PASS" : "displays: \(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
case "idle":
    print("idle: per SECOND with nothing (or 1 Hz ticks) drawn  [call = render thread CPU]")
    let base = Snap()
    runLoop(until: CACurrentMediaTime() + seconds)
    let baseEnd = Snap()
    print(String(format: "baseline (no wallpaper)          wk %6.1f/s  proc %6.3f ms/s",
                 Double(baseEnd.wk - base.wk) / (baseEnd.t - base.t), (baseEnd.proc - base.proc) / (baseEnd.t - base.t) * 1000))
    for s in scenarios where s.music == nil && (s.name == "Liquid Chrome" || s.name == "Flip Clock") {
        let rig = WallpaperRig(s)
        rig.state(s, fps: 30)
        runLoop(until: CACurrentMediaTime() + 1.0)
        rig.state(s, fps: 30, canDraw: false)
        runLoop(until: CACurrentMediaTime() + 0.5)
        report(measureLoop(rig, name: s.name + " paused", fps: 30))
        rig.state(s, fps: 30, visible: false)
        runLoop(until: CACurrentMediaTime() + 0.5)
        report(measureLoop(rig, name: s.name + " covered", fps: 30))
        if s.name == "Flip Clock" {
            rig.state(s, fps: 30)
            runLoop(until: CACurrentMediaTime() + 0.5)
            report(measureLoop(rig, name: s.name + " ticking", fps: 30, extra: "(1 Hz ticks + minute burst)"))
        }
        rig.loop.removeAll()
        runLoop(until: CACurrentMediaTime() + 0.3)
    }
default:
    print("unknown mode \(mode)"); exit(2)
}
exit(0)
