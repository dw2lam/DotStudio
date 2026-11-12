//  tools/gallery/main.swift — headless gallery renderer for the DEFAULT presets.
//  Unlike the app's DOTSTUDIO_SHOTS mode it never reads the user's library, so it
//  always shows what ships. Build + run with tools/gallery/render.sh.
//
//  usage: gallery <outDir> [--photo file.jpg] [--times 1.6,9] [--only substr] [--pack]
//                          [--size 1600x1000] [--bench] [--gpubench] [--solo] [--set key=val,key=val]
//  --set overrides params on each preset's first effect (e.g. --set tilt=70,scale=1.4).
//  --gpubench times just the first effect's fragment pass with GPU timestamps (--benchtime T: every
//  sample at scene time T, e.g. inside a lightning flash)
//  (no alloc/readback, immune to CPU load): the number to compare shader costs by. It binds the
//  pipeline the renderer would (a scene's own fx_scene_<id> when ScenePipelines lists it, Ocean
//  Horizon's and Shallows' weather copies); --uber binds fx_fragment for every pass instead.
//  --pipebench times every preset's first effect (and the source and crossfade passes) both in
//  fx_fragment and in its own fx_scene_<id>, 3 interleaved rounds against a reference: how
//  ScenePipelines' list is chosen (add the ids to measure to SceneEntries.metal first).
//  --solo keeps only each preset's first effect (benchmark one shader, not its post chain).
//  --slides renders one frame per built-in slideshow photo; --looks skips the Scenes.
//  Weather (Ocean Horizon, Shallows): --weather rain[,thunderstorm,…] renders each preset under each
//  condition (WeatherCondition raw values, or "live" = the real weather.json; also storm, overcast,
//  partly, lightSnow, heavySnow) in place of the live feed — a scene's fixed Weather pick still wins.
//  Wall clock (clock scenes, Ocean Horizon's Follow the Sun): --clock 06:40[,07:00:30.5,…] renders
//  each preset at each local time on --date 2026-06-21 (default today), in --tz America/Toronto
//  (default the Mac's), at --loc 43.7,-79.4 (default San Francisco; "none" = the no-location fallback).
//  Music (MusicPresentation decides, exactly as the saver does): DOTSTUDIO_MUSIC_FAKE=<fixture.json>
//  feeds it. --card bottomLeft|bottomRight|topLeft|topRight|all renders Corner music over every
//  preset; --cardsize small|medium|large picks its size (default medium, as in the app);
//  --full art|veil renders Full Screen music (Album Art = living art, veil = the style blurred
//  and dimmed) with --layout album|stage; --fade 0.25,0.5,0.75 renders those as frames of the
//  ease in (time fractions of MetalRenderer.musicBackdropSeconds; the overlay's opacity follows);
//  --legacy adds the legacy Now Playing styles (shader 66 as a style) and --overlay composites
//  their foreground; --veilbench times live frames with and without each backdrop (GPU timestamps).
//  --scale 2 sets the overlay's pixels per point (default 2 from 2400 px wide, else 1);
//  --tag name appends "@name" to the file names. Fixtures: tools/music-fixtures/make.sh.
//  Song text (never cut off): music renders as with Reduce Motion (a line too long to fit takes a
//  third line) unless --marquee P poses every scrolling line at fraction P of its travel (0 = at
//  rest at its start, 1 = at its end), as the saver shows it; --notch 32 gives the screen a
//  notch band of that many points (a top corner keeps clear); --textcheck verifies every text
//  block and the artwork sit inside the screen (≥ 8 pt in) without overlapping, and prints a summary.
//  --framebench times whole live frames (MetalRenderer.renderFrame: source, every effect and any
//  compute pass, e.g. the error-diffusion dithers) with GPU timestamps, per preset, on its own renderer.
//  Bounce: --logo builtin | text:WORD | file:/path/to/image (copied into the store's media folder,
//  as the app imports one) sets the logo of every Bounce preset; each Bounce render prints its
//  corner period and the next corner hits (render one with --times).
//  --checks runs the live-renderer checks (wall-clock time base, synced slideshow, held-frame
//  track change, rapid skips) through MetalRenderer.renderFrame, the format, Bounce and retirement
//  checks, params from a shared file (1e20 / 1e300 / NaN / ±inf: clamped on load, and every kind
//  renders unsanitized without trapping), Time Lapse across the hourly wrap, and Meadow's Landscape
//  changing under live weather — and exits non-zero on a failure.
//  Custom Scenes: --scene <packageDir> (repeatable; a folder holding packages adds each) validates
//  the package (compile diagnostics, GPU ms at 5120×2880), installs it into the temp store
//  (DOTSTUDIO_STORE_DIR required) and renders it like a built-in style — only the scenes, unless
//  --only picks built-ins too. --checks also runs the Custom Scene checks (customSceneChecks).

import AppKit
import Metal
import MetalKit

var args = Array(CommandLine.arguments.dropFirst())
guard let outDir = args.first else { print("usage: gallery <outDir> [...]"); exit(2) }
args.removeFirst()
var photo: String?
var times: [Float] = [1.6]
var only: String?
var includePack = false
var bench = false
var overrides: [String: Double] = [:]
var solo = false
var gpuBench = false
var pipeBench = false
var uberOnly = false
var looksOnly = false
var W = 1600, H = 1000
var clocks: [String] = []
var dateArg: String?
var tzArg: String?
var loc: (lat: Double, lon: Double)? = (37.77, -122.42)
var overlay = false
var cardCorners: [MusicSpec.Corner] = []
var cardSize: MusicSpec.CardSize?
var overlayScale: CGFloat?
var fullBackdrop: MusicSpec.Backdrop?
var fullLayout: MusicSpec.FullLayout?
var fades: [Double] = []
var legacy = false
var veilBench = false
var tag: String?
var musicFadeBench = false
var runChecks = false
var frameBench = false
var weathers: [String] = []
var benchTime: Float?
var notchPoints: CGFloat = 0
var textCheck = false
var textCheckRuns = 0
var textCheckFailures = 0
var textCheckBuildMs = 0.0
var textCheckWarmMs = 0.0
var logoArg: String?
/// --scene <package dir> (repeatable; a folder of packages works too): installed into the temp
/// store and rendered / benched like a built-in style (CustomScenes).
var sceneArgs: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--photo": photo = args.removeFirst()
    case "--times": times = args.removeFirst().split(separator: ",").compactMap { Float($0) }
    case "--only": only = args.removeFirst().lowercased()
    case "--pack": includePack = true
    case "--bench": bench = true
    case "--solo": solo = true
    case "--gpubench": gpuBench = true
    case "--pipebench": gpuBench = true; pipeBench = true
    case "--uber": uberOnly = true
    case "--looks": looksOnly = true
    case "--slides":
        // One frame per built-in photo, mid-hold (the slideshow is a pure function of time).
        let s = SourceSpec.builtInPhotos
        let n = CollectionSource.builtInPhotoURLs().count
        let fade = min(4.0, s.slideInterval * 0.35)
        times = (0..<max(n, 1)).map { Float(Double($0) * s.slideInterval + s.slideInterval * 0.5 - fade) }
    case "--set":
        for kv in args.removeFirst().split(separator: ",") {
            let p = kv.split(separator: "=")
            if p.count == 2, let v = Double(p[1]) { overrides[String(p[0])] = v }
        }
    case "--clock": clocks = args.removeFirst().split(separator: ",").map(String.init)
    case "--weather": weathers = args.removeFirst().split(separator: ",").map(String.init)
    case "--benchtime": benchTime = Float(args.removeFirst())
    case "--date": dateArg = args.removeFirst()
    case "--tz": tzArg = args.removeFirst()
    case "--loc":
        let v = args.removeFirst()
        let p = v.split(separator: ",").compactMap { Double($0) }
        loc = p.count == 2 ? (p[0], p[1]) : nil
    case "--overlay": overlay = true
    case "--musicfade": musicFadeBench = true
    case "--checks": runChecks = true
    case "--framebench": frameBench = true
    case "--card":
        let v = args.removeFirst()
        cardCorners = v == "all" ? MusicSpec.Corner.allCases : [MusicSpec.Corner(rawValue: v) ?? .bottomLeft]
    case "--cardsize": cardSize = MusicSpec.CardSize(rawValue: args.removeFirst())
    case "--full": fullBackdrop = args.removeFirst() == "veil" ? .screensaver : .albumArt
    case "--layout": fullLayout = MusicSpec.FullLayout(rawValue: args.removeFirst())
    case "--fade": fades = args.removeFirst().split(separator: ",").compactMap { Double($0) }
    case "--legacy": legacy = true
    case "--veilbench": veilBench = true
    case "--scale": overlayScale = CGFloat(Double(args.removeFirst()) ?? 2)
    case "--tag": tag = args.removeFirst()
    case "--notch": notchPoints = CGFloat(Double(args.removeFirst()) ?? 0)
    case "--marquee": MusicOverlayLayer.stillMarqueePose = CGFloat(Double(args.removeFirst()) ?? 0)
    case "--textcheck": textCheck = true
    case "--logo": logoArg = args.removeFirst()
    case "--scene": sceneArgs.append(args.removeFirst())
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    default: break
    }
}

/// --weather names → the mix every "Live" scene shows (nil = the real feed).
func weatherMix(_ name: String) -> WeatherMix? {
    let aliases = ["storm": "thunderstorm", "overcast": "cloudy", "partly": "partlyCloudy", "heavy": "heavyRain"]
    if name == "live" { return nil }
    // Light and heavy snow (WMO 71 / 75 as the live feed reads them): the snow preset, sparser or denser.
    if name == "lightSnow" || name == "heavySnow" {
        var m = WeatherMix.preset(.snow)
        m.precip = name == "lightSnow" ? 0.30 : 0.85
        return m
    }
    guard let c = WeatherCondition(rawValue: aliases[name] ?? name) else {
        print("unknown weather \(name): \(WeatherCondition.allCases.map(\.rawValue))"); exit(2)
    }
    return WeatherMix.preset(c)
}
if let w = weathers.first { WeatherLink.forced = weatherMix(w) }
let store = SharedStore(role: .app)
guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { print("no renderer"); exit(1) }
renderer.location = loc
renderer.waitsForScenePipelines = true          // render what the scenes' own pipelines draw, never the stand-in
let musicFeed = MusicFeed(baseDir: store.baseDir)
musicFeed.poll()
renderer.setMusic(musicFeed.snapshot)

/// The music settings a render uses: Corner (`corner`), Full Screen (--full), else the defaults
/// (legacy Now Playing styles show their own foreground whatever these say).
func musicSettings(corner: MusicSpec.Corner?) -> MusicSpec {
    var m = MusicSpec(cardCorner: corner, cardSize: cardSize, fullBackdrop: fullBackdrop, fullLayout: fullLayout)
    m.setDisplay(fullBackdrop != nil ? .fullScreen : .corner)
    return m
}

/// --textcheck: every text block, marquee viewport, the artwork and the corner's block inside the
/// screen (≥ 8 pt in), no text over the artwork, and a top corner clear of the notch band.
func checkText(_ layer: MusicOverlayLayer, mode: MusicOverlayLayer.Mode) {
    textCheckRuns += 1
    let inner = layer.bounds.insetBy(dx: 8, dy: 8)
    let rects = layer.debugRects
    let arts = rects.filter { $0.kind == "art" }.map(\.rect)
    var problems: [String] = []
    func fmt(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }
    for (kind, r) in rects {
        if r.minX < inner.minX - 0.5 || r.minY < inner.minY - 0.5 || r.maxX > inner.maxX + 0.5 || r.maxY > inner.maxY + 0.5 {
            problems.append("\(kind) \(fmt(r)) leaves the screen \(fmt(layer.bounds))")
        }
        if kind == "text" || kind == "marquee", let a = arts.first(where: { $0.insetBy(dx: 1, dy: 1).intersects(r) }) {
            problems.append("\(kind) \(fmt(r)) overlaps the artwork \(fmt(a))")
        }
    }
    if case .card(let corner) = mode, let block = rects.first(where: { $0.kind == "block" })?.rect {
        if block.width > layer.bounds.width * MusicGeometry.Card.maxShare + 1 {
            problems.append("block \(fmt(block)) wider than \(MusicGeometry.Card.maxShare) of the screen")
        }
        if notchPoints > 0, corner == .topLeft || corner == .topRight,
           block.minY < max(notchPoints, 0.03 * layer.bounds.height) {
            problems.append("block \(fmt(block)) inside the notch band")
        }
    }
    if rects.isEmpty && mode != .hidden { problems.append("nothing drawn") }
    if !problems.isEmpty {
        textCheckFailures += 1
        for p in problems { print("TEXTCHECK FAIL \(mode): \(p)") }
    }
}

/// The music foreground composited over a Metal frame, the way the saver stacks its layers,
/// at `alpha` (a frame of the full-screen fade).
func compositeMusic(_ cg: CGImage, mode: MusicOverlayLayer.Mode, settings: MusicSpec, now: Date,
                    alpha: CGFloat = 1) -> CGImage {
    guard mode != .hidden, alpha > 0 else { return cg }
    let scale = overlayScale ?? (W >= 2400 ? 2 : 1)
    let layer = MusicOverlayLayer()
    layer.contentsScale = scale
    layer.frame = CGRect(x: 0, y: 0, width: CGFloat(W) / scale, height: CGFloat(H) / scale)
    layer.reduceMotion = MusicOverlayLayer.stillMarqueePose == nil
    layer.notch = notchPoints
    let t0 = CFAbsoluteTimeGetCurrent()
    layer.update(mode: mode, music: musicFeed.snapshot, settings: settings, now: now, animated: false)
    textCheckBuildMs = max(textCheckBuildMs, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    if textCheck {
        checkText(layer, mode: mode)
        // A track change in a running saver: fonts and the scaled cover warm, the text not.
        MusicText.purge()
        let again = MusicOverlayLayer()
        again.contentsScale = scale
        again.frame = layer.frame
        again.reduceMotion = layer.reduceMotion
        again.notch = notchPoints
        let t1 = CFAbsoluteTimeGetCurrent()
        again.update(mode: mode, music: musicFeed.snapshot, settings: settings, now: now, animated: false)
        textCheckWarmMs = max(textCheckWarmMs, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
    }
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return cg }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.scaleBy(x: scale, y: scale)
    layer.render(in: ctx)
    ctx.endTransparencyLayer()
    return ctx.makeImage() ?? cg
}

/// The overlay's opacity `k` of the way through the full-screen ease in (its own delayed
/// ease-in-ease-out, as MusicOverlayGroup.appear runs it).
func fadeInOpacity(_ k: Double) -> Double {
    MusicOverlayLayer.fullFadeInOpacity(at: k * MetalRenderer.musicBackdropSeconds)
}

/// Live-path checks: what two renderers, a held wallpaper frame and a skipping listener see.
func liveChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    func meanDiff(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height else { return .infinity }
        func px(_ i: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: i.width * i.height * 4)
            buf.withUnsafeMutableBytes { p in
                let c = CGContext(data: p.baseAddress, width: i.width, height: i.height, bitsPerComponent: 8,
                                  bytesPerRow: i.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            }
            return buf
        }
        let pa = px(a), pb = px(b)
        return Double(zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(pa.count)
    }
    let w = 320, h = 200

    // 1. Wall-clock time stays small: Float frame steps at 120 Hz near the end of the period.
    let top = Float(MetalRenderer.wallClockPeriod - 0.001)
    check(top.ulp <= 0.00025, String(format: "wall-clock t < %.0f s: Float resolution %.3f ms at the top (seconds since midnight: %.1f ms)",
                                     MetalRenderer.wallClockPeriod, Double(top.ulp) * 1000, Double(Float(86_399).ulp) * 1000))
    check(abs(MetalRenderer.wallPhase(3600 * 491_234 + 12.5) - 12.5) < 1e-6, "wall phase = seconds into the hour")

    // 2. Match Screensaver on a slideshow Look: two wall-clock renderers draw the same photo and framing.
    let look = Preset(name: "Look", effects: [EffectInstance(.halftone)])
    func slideRenderer(_ base: MetalRenderer.TimeBase) -> MetalRenderer {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = base
        r.apply(look, source: .builtInPhotos)
        return r
    }
    let wallFrames = (0..<4).map { _ in slideRenderer(.wallClock).renderFrame(width: w, height: h) }
    let worst = (1..<wallFrames.count).map { meanDiff(wallFrames[0], wallFrames[$0]) }.max() ?? .infinity
    check(worst < 1.5, String(format: "4 wall-clock slideshow renderers agree (worst mean |Δ| %.2f)", worst))
    let instance = (0..<4).map { _ in slideRenderer(.instance).renderFrame(width: w, height: h) }
    let spread = (1..<instance.count).map { meanDiff(instance[0], instance[$0]) }.max() ?? 0
    print(String(format: "info  per-instance slideshow renderers differ by up to %.2f (random first photo)", spread))

    // 3. A held wallpaper frame after a track change shows the NEW cover (settled draw).
    func cover(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        c.setFillColor(CGColor(srgbRed: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1)); c.fill(CGRect(x: 8, y: 8, width: 24, height: 40))
        return c.makeImage()!
    }
    func song(_ id: String, _ art: CGImage?, rev: Int) -> MusicSnapshot {
        var st = MusicState()
        st.title = "Song \(id)"; st.artist = "Artist"; st.trackID = id; st.isPlaying = true
        st.duration = 200; st.position = 20; st.positionAt = Date().timeIntervalSince1970
        return MusicSnapshot(state: st, artwork: art, revision: rev)
    }
    let A = song("a", cover(0.95, 0.85, 0.2), rev: 1), B = song("b", cover(0.1, 0.3, 0.9), rev: 2)
    let C = song("c", cover(0.9, 0.2, 0.3), rev: 3)
    let np = SceneCatalog.musicPresets.first { $0.name.contains("Cover") } ?? SceneCatalog.musicPresets[0]
    func musicRenderer(_ snap: MusicSnapshot) -> MetalRenderer {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = .wallClock          // same t for every renderer, so frames compare
        r.setMusic(snap)
        r.apply(np, source: SourceSpec())
        return r
    }
    let held = musicRenderer(A)
    _ = held.renderFrame(width: w, height: h)
    held.setMusic(B)
    let heldB = held.renderFrame(width: w, height: h, settled: true)
    let freshB = musicRenderer(B).renderFrame(width: w, height: h)
    let freshA = musicRenderer(A).renderFrame(width: w, height: h)
    let dB = meanDiff(heldB, freshB), dA = meanDiff(heldB, freshA)
    check(dB < 1.0 && dA > 10, String(format: "held frame after a cover change shows the new cover (Δ new %.2f, Δ old %.2f)", dB, dA))
    let running = musicRenderer(A)
    _ = running.renderFrame(width: w, height: h)
    running.setMusic(B)
    let firstFade = running.renderFrame(width: w, height: h)
    print(String(format: "info  a continuous host's first frame after the change is still the old cover (Δ old %.2f) — it fades over %.1f s",
                 meanDiff(firstFade, freshA), MetalRenderer.musicFadeSeconds))

    // 4. Skipping again mid-fade never cuts from the half-faded mix.
    let skip = musicRenderer(A)
    _ = skip.renderFrame(width: w, height: h)
    skip.setMusic(B)
    _ = skip.renderFrame(width: w, height: h)
    Thread.sleep(forTimeInterval: 0.6)
    let mid = skip.renderFrame(width: w, height: h)
    skip.setMusic(C)
    let after = skip.renderFrame(width: w, height: h)
    let jump = meanDiff(mid, after), span = meanDiff(freshA, freshB)
    check(jump < span * 0.1, String(format: "a skip 0.6 s into a fade doesn't pop (Δ %.2f vs A→B %.2f)", jump, span))

    // 5. Wall clock → instance keeps the motion where it was (no jump to t = 0).
    let lc = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
    lc.timeBase = .wallClock
    lc.apply(Preset(name: "LC", effects: [EffectInstance(.liquidChrome)]), source: SourceSpec())
    _ = lc.renderFrame(width: w, height: h)
    let before = lc.animationTime()
    lc.timeBase = .instance
    let afterSwitch = lc.animationTime()
    check(abs(afterSwitch - before) < 0.05, String(format: "wall clock → instance continues t (%.2f s → %.2f s)", before, afterSwitch))

    // 6–8. The hourly wrap meets a style change, and the instance time base wraps: frames drawn
    // back to back across each never step by more than a sliver of the wrap's own jump.
    let lcA = Preset(name: "LC", effects: [EffectInstance(.liquidChrome)])
    // (another style that looks the same: a step between frames is then the motion alone)
    let lcB = Preset(name: "LC B", effects: [EffectInstance(.liquidChrome)])
    func renderer(_ base: MetalRenderer.TimeBase, _ p: Preset, phase: Double) -> MetalRenderer {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = base
        r.apply(p, source: SourceSpec())
        // put the wall clock (or the instance t) `phase` seconds into the hour
        let now = Date().timeIntervalSince1970
        r.timeBaseSkew = phase - MetalRenderer.wallPhase(now)
        if base == .instance { r.setInstanceTime(phase) }
        return r
    }
    /// Frames back to back for `seconds`, running each event once its time (s) has passed:
    /// the largest step between consecutive frames.
    func maxStep(_ r: MetalRenderer, seconds: Double, events: [(Double, () -> Void)] = []) -> Double {
        let t0 = CACurrentMediaTime()
        var pending = events, last = r.renderFrame(width: w, height: h), worst = 0.0
        while CACurrentMediaTime() - t0 < seconds {
            while let e = pending.first, CACurrentMediaTime() - t0 >= e.0 { e.1(); pending.removeFirst() }
            let f = r.renderFrame(width: w, height: h)
            worst = max(worst, meanDiff(last, f))
            last = f
        }
        return worst
    }
    // the wrap's own jump: the scene at the top of the hour vs at its start
    let atTop = renderer(.instance, lcA, phase: 3599.5).renderFrame(width: w, height: h)
    let atZero = renderer(.instance, lcA, phase: 0.0).renderFrame(width: w, height: h)
    let wrapJump = meanDiff(atTop, atZero)
    print(String(format: "info  the wrap's jump (t 3600 → 0, unfaded): mean |Δ| %.2f", wrapJump))

    // 6. A rotation landing 0.3 s into the wall clock's wrap fade waits for it to finish.
    let rot = renderer(.wallClock, lcA, phase: 3599.85)
    let rotStep = maxStep(rot, seconds: 0.8, events: [(0.45, { rot.transition(to: lcB, source: SourceSpec(), duration: 1.5) })])
    check(rotStep < wrapJump * 0.15, String(format: "a style change during the hourly wrap fade doesn't pop (largest step %.2f)", rotStep))
    _ = maxStep(rot, seconds: 3.2)
    check(rot.preset?.id == lcB.id, "…and the style change it held back runs once the wrap fade ends")

    // 7. The wrap landing mid style change waits for it: the incoming style never jumps in time.
    let during = renderer(.wallClock, lcA, phase: 3599.4)
    during.transition(to: lcB, source: SourceSpec(), duration: 1.5)
    let duringStep = maxStep(during, seconds: 1.0)
    check(duringStep < wrapJump * 0.15, String(format: "the hourly wrap during a style change doesn't pop (largest step %.2f)", duringStep))
    _ = maxStep(during, seconds: 3.0)
    check(during.animationTime() < 10, String(format: "…and the wrap happens once it's done (t %.2f s)", during.animationTime()))

    // 8. The instance time base wraps too (behind a fade), so t stays a precise Float.
    let inst = renderer(.instance, lcA, phase: 3599.8)
    let instStep = maxStep(inst, seconds: 0.6)
    check(instStep < wrapJump * 0.15, String(format: "the instance time base's hourly wrap doesn't pop (largest step %.2f)", instStep))
    check(inst.animationTime() < 10, String(format: "…and t wrapped (t %.2f s)", inst.animationTime()))

    // 9. No scene reads its input (texture 0), so MetalRenderer.encodePasses draws no source pass
    //    under one: every scene's own fragment function(s), from the pipelines' reflection. (The
    //    über-shader stand-in runs the same case code.) fx_scene_0, the photo pass, must read it.
    if let dev = MTLCreateSystemDefaultDevice(), let mlib = dev.makeDefaultLibrary() {
        func readsInput(_ fn: String) -> Bool? {
            guard let d = FXPipelines.renderDescriptor(mlib, fragment: fn, format: .bgra8Unorm, archive: nil) else { return nil }
            var refl: MTLAutoreleasedRenderPipelineReflection?
            guard (try? dev.makeRenderPipelineState(descriptor: d, options: [.bindingInfo], reflection: &refl)) != nil,
                  let refl else { return nil }
            return refl.fragmentBindings.contains { $0.type == .texture && $0.index == 0 && $0.isUsed }
        }
        var readers: [String] = [], unverified: [String] = []
        var scenes = 0
        for kind in EffectKind.allCases where kind.isScene {
            scenes += 1
            let fns = WeatherLink.usesWeather(kind)
                ? WeatherLink.functionNames.filter { $0.contains(kind == .shallows ? "shallows" : kind == .meadow ? "meadow" : "ocean") }
                : ScenePipelines.functionName(kind.shaderID).map { [$0] } ?? []
            if fns.isEmpty { unverified.append(kind.displayName) }
            for fn in fns {
                switch readsInput(fn) {
                case true?: readers.append("\(kind.displayName) (\(fn))")
                case nil: unverified.append("\(kind.displayName) (\(fn))")
                default: break
                }
            }
        }
        check(readsInput("fx_scene_0") == true && readers.isEmpty && unverified.isEmpty,
              "no scene's fragment function reads the source (\(scenes) scenes; reads it: \(readers); unverified: \(unverified))")
    } else {
        check(false, "no scene reads the source: no Metal library")
    }
    return ok
}
/// Library format checks: forward compatibility with a library written by a newer DotStudio.
func formatChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    // The shipping library, plus what a newer build could write: an effect of an unknown kind
    // in the middle of a style's stack, and a style made only of unknown kinds.
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let base = DefaultPresets.makeLibrary()
    guard let data = try? enc.encode(base),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var presets = obj["presets"] as? [[String: Any]],
          let host = presets.firstIndex(where: { (($0["effects"] as? [Any])?.count ?? 0) >= 1 }) else {
        check(false, "forward compatibility: couldn't build the fixture"); return false
    }
    let future: [String: Any] = ["id": UUID().uuidString, "kind": "kindFromTheFuture", "enabled": true,
                                 "params": ["speed": 1.5], "newField": ["nested": [1, "two", NSNull(), false]]]
    var effects = presets[host]["effects"] as! [Any]
    effects.insert(future, at: 1)
    presets[host]["effects"] = effects
    presets.insert(["id": UUID().uuidString, "name": "Future Style", "fps": 30,
                    "effects": [future, future.merging(["kind": "anotherNewKind"]) { $1 }]], at: 3)
    obj["presets"] = presets
    guard let fixture = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    do {
        let lib = try JSONDecoder().decode(Library.self, from: fixture)
        check(lib.presets.map(\.id) == base.presets.map(\.id) && lib.presets.map(\.effects) == base.presets.map(\.effects)
              && lib.presets[host].unknownEffects.map(\.index) == [1] && lib.unknownPresets.map(\.index) == [3]
              && lib.unknownCounts == (1, 1),
              "a library with unknown effect kinds decodes: the styles it can draw intact, 1 unknown effect and 1 unknown style kept aside")
        let again = try enc.encode(lib)
        // (Compared as parsed JSON values: JSONSerialization keeps each number's decimal text.)
        let a = try JSONDecoder().decode(JSONValue.self, from: fixture)
        let b = try JSONDecoder().decode(JSONValue.self, from: again)
        check(a == b, "…and it saves back exactly what it read (unknown effects and styles in place)")
        var edited = lib
        edited.presets[host].effects.removeAll()
        edited.presets.removeLast()
        let reread = try JSONDecoder().decode(Library.self, from: try enc.encode(edited))
        check(reread.unknownCounts == (0, 2) && reread.presets.count == lib.presets.count - 2,
              "…edited (a style's known effects removed, another style deleted), still nothing unknown is lost")
    } catch {
        check(false, "a library with unknown effect kinds decodes (\(error))")
    }

    // Bounce's logo fields (EffectInstance.logoKind / logoText / logoFile): optional and add-only.
    do {
        var lib = DefaultPresets.makeLibrary()
        let plain = try enc.encode(lib)
        check(!String(decoding: plain, as: UTF8.self).contains("\"logo"),
              "Bounce: a library without logos writes no logo fields (the built-in mark is all nil)")
        var text = EffectInstance(.bounce)
        text.logoKind = .text; text.logoText = "Ünïcödé — Dävid 日本"
        var image = EffectInstance(.bounce)
        image.logoKind = .image; image.logoFile = "6F1C2E4A-0000-4000-8000-000000000001.png"; image.logoText = "kept"
        lib.presets.append(Preset(name: "Bounce Text", effects: [text]))
        lib.presets.append(Preset(name: "Bounce Image", effects: [image, EffectInstance(.scanlines)]))
        let data = try enc.encode(lib)
        let back = try JSONDecoder().decode(Library.self, from: data)
        let again = try enc.encode(back)
        check(back == lib && data == again,
              "Bounce: a library with a text and an image logo decodes → saves → the same JSON, byte for byte")
        // A logo kind from a newer build decodes as the built-in mark rather than failing the library.
        guard var obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var presets = obj["presets"] as? [[String: Any]], var effects = presets.last?["effects"] as? [[String: Any]]
        else { check(false, "Bounce: fixture"); return ok }
        effects[0]["logoKind"] = "hologram"
        presets[presets.count - 1]["effects"] = effects
        obj["presets"] = presets
        let future = try JSONDecoder().decode(Library.self, from: try JSONSerialization.data(withJSONObject: obj))
        check(future.presets.last?.effects.first?.logoKind == .builtIn
              && future.presets.last?.effects.first?.logoFile == image.logoFile,
              "Bounce: an unknown logo kind decodes as the built-in mark (the rest of the effect intact)")
        // An older build (no logo fields) reading this library: the effect's extra keys are ignored
        // by its synthesized Codable, and Bounce itself is an unknown kind there, kept verbatim.
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .object(let o) = raw, case .array(let ps)? = o["presets"], case .object(let last)? = ps.last,
           case .array(let es)? = last["effects"], case .object(let e0)? = es.first {
            check(e0["logoKind"] == .string("image") && e0["logoText"] == .string("kept"),
                  "Bounce: the logo fields are plain JSON keys on the effect (kept verbatim by an older build's unknown-effect path)")
        } else {
            check(false, "Bounce: logo fields in the JSON")
        }
    } catch {
        check(false, "Bounce: logo round trip (\(error))")
    }
    return ok
}
/// Bounce's motion: a pure function of t that stays on screen, lands exactly in a corner once a
/// period, and comes nowhere near one in between.
func bounceChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    var worstOut = 0.0, worstCorner = 0.0, nearMisses = 0, periods: [Double] = []
    for (w, h) in [(1600.0, 1000.0), (5120.0, 2880.0), (1920.0, 1080.0), (3024.0, 1964.0), (1000.0, 1600.0), (448.0, 280.0)] {
        for aspect in [1.0, 2.14, 4.29, 0.6] {
            for speed in [1.0, 0.5, 2.3] {
                let m = BounceLogo.timing(width: w, height: h, aspect: aspect, size: 0.24, speed: speed)
                if speed == 1 { periods.append(m.period) }
                // the corner hits
                for k in 0..<3 {
                    let t = m.tc + Double(k) * m.period
                    let c = BounceLogo.pose(m, at: t).center
                    let hit = BounceLogo.lastCorner(m, at: t + 1e-6, width: w, height: h).corner
                    let dx = min(abs(c.x - m.lw / 2), abs(c.x - (w - m.lw / 2)))
                    let dy = min(abs(c.y - m.lh / 2), abs(c.y - (h - m.lh / 2)))
                    worstCorner = max(worstCorner, dx, dy)
                    // the logo's own corner sits in the screen corner the flourish starts from
                    let lc = SIMD2(c.x + (hit.x > 0 ? m.lw / 2 : -m.lw / 2), c.y + (hit.y > 0 ? m.lh / 2 : -m.lh / 2))
                    worstCorner = max(worstCorner, abs(lc.x - hit.x), abs(lc.y - hit.y))
                }
                // a whole period at 120 fps: inside the screen, and within 2 px of a corner only at the hits
                var t = m.tc + 0.5
                while t < m.tc + m.period - 0.5 {
                    let c = BounceLogo.pose(m, at: t).center
                    worstOut = max(worstOut, m.lw / 2 - c.x, c.x - (w - m.lw / 2), m.lh / 2 - c.y, c.y - (h - m.lh / 2))
                    let dx = min(abs(c.x - m.lw / 2), abs(c.x - (w - m.lw / 2)))
                    let dy = min(abs(c.y - m.lh / 2), abs(c.y - (h - m.lh / 2)))
                    if dx < 2, dy < 2 { nearMisses += 1 }
                    t += 1.0 / 120
                }
            }
        }
    }
    check(worstOut <= 1e-6, String(format: "Bounce: the logo never leaves the screen (worst overshoot %.2g px)", worstOut))
    check(worstCorner < 1e-6, String(format: "Bounce: every corner hit is exact, in the corner the flourish starts from (worst %.2g px)", worstCorner))
    check(nearMisses == 0, "Bounce: no other near-corner (both edges within 2 px) in a whole period (\(nearMisses) frames)")
    check(periods.allSatisfy { $0 > 100 && $0 < 220 },
          String(format: "Bounce: a corner every %.0f–%.0f s at speed 1 (any screen, any logo shape)",
                 periods.min() ?? 0, periods.max() ?? 0))
    let md = URL(fileURLWithPath: "/tmp/media")
    check(BounceLogo.fileURL("A1.png", mediaDir: md)?.path == "/tmp/media/A1.png"
          && ["../library.json", "/etc/hosts", "sub/a.png", ".hidden", "", nil].allSatisfy { BounceLogo.fileURL($0, mediaDir: md) == nil },
          "Bounce: an Image logo only ever reads a plain file name inside the media folder")
    // Stateless: two renderers on the wall-clock time base draw the same frame (made and warmed
    // first, then drawn back to back: the logo moves ~0.1 px between the two reads of the clock).
    let p = Preset(name: "Bounce", effects: [EffectInstance(.bounce)])
    let rs = (0..<2).map { _ -> MetalRenderer in
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.timeBase = .wallClock
        r.apply(p, source: SourceSpec())
        for _ in 0..<3 { _ = r.renderFrame(width: 320, height: 200, settled: true) }
        return r
    }
    let a = rs[0].renderFrame(width: 320, height: 200, settled: true)
    let b = rs[1].renderFrame(width: 320, height: 200, settled: true)
    var diff = Double.infinity, lit = 0.0
    if let a, let b, let da = a.dataProvider?.data, let db = b.dataProvider?.data, CFDataGetLength(da) == CFDataGetLength(db) {
        let n = CFDataGetLength(da)
        let pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
        var d = 0, l = 0
        for i in 0..<n { d += abs(Int(pa[i]) - Int(pb[i])); if i % 4 != 3, pa[i] > 60 { l += 1 } }
        diff = Double(d) / Double(n); lit = Double(l) / Double(n / 4 * 3)
    }
    check(diff < 0.5 && lit > 0.005,
          String(format: "Bounce: two wall-clock renderers draw the same frame (mean |Δ| %.3f, logo lights %.1f%% of the colour channels)", diff, lit * 100))
    return ok
}

// MARK: - 1.4.2 retirement checks (DefaultPresets.retiredStyles / retireUntouched) ─────────────
/// The retired styles leave every offer, untouched copies leave a library (references follow),
/// edited copies stay and still render. (Migration end to end: DOTSTUDIO_MIGRATE_ONLY fixtures.)
func retirementChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    let names = Set(DefaultPresets.retiredStyles.keys)
    let defs = names.sorted().compactMap(DefaultPresets.builtInDefinition)
    check(defs.count == 8 && defs.allSatisfy { $0.isScene }, "retired: all eight built-in definitions still exist, as scenes")
    check(names.isDisjoint(with: DefaultPresets.featured)
          && names.isDisjoint(with: DefaultPresets.offeredBuiltIns().map(\.name))
          && names.isDisjoint(with: DefaultPresets.makeLibrary().presets.map(\.name)),
          "retired: not featured, not offered (Add Built-in Styles), not in a new library")
    let kinds: [EffectKind] = [.dialClock, .pipes, .demoTunnel, .fireflies]
    check(kinds.allSatisfy { $0.isRetired && $0.isScene && SceneCatalog.spec($0) != nil }
          && kinds.allSatisfy { k in !EffectKind.allCases.filter { $0.isScene && !$0.isRetired }.contains(k) },
          "retired: their kinds are hidden from New Scene / Add Effect but keep their scene specs")
    check(DefaultPresets.makeLibrary().seenBuiltIns?.contains(DefaultPresets.retirementMarker) == true,
          "retired: a new library is born past the retirement (marker recorded)")

    // A library with all eight untouched (as a 1.4.1 library + Add Built-in Styles), Sunray
    // active, Fireflies + Aurora rotating, Pipeworks the night style.
    var lib = DefaultPresets.makeLibrary()
    lib.presets += defs
    func id(_ n: String, _ l: Library) -> UUID? { l.presets.first { $0.name == n }?.id }
    lib.activeID = id("Sunray", lib)
    lib.rotation = RotationSpec(enabled: true, presetIDs: [id("Fireflies", lib)!, id("Aurora", lib)!])
    lib.schedule = ScheduleSpec(enabled: true, dayPresetID: id("Aurora", lib), nightPresetID: id("Pipeworks", lib))
    let (out, r) = DefaultPresets.retireUntouched(lib)
    let fallback = DefaultPresets.featured.lazy.compactMap { id($0, out) }.first
    let sunrayTo = id("Chronometer", out) ?? fallback
    check(Set(r.removed) == names && r.kept.isEmpty && names.isDisjoint(with: out.presets.map(\.name))
          && out.presets.count == lib.presets.count - 8,
          "retire: untouched copies of all eight leave the library")
    check(out.activeID != nil && out.activeID == sunrayTo && out.schedule?.nightPresetID == fallback
          && out.schedule?.dayPresetID == id("Aurora", out) && out.rotation?.presetIDs == [id("Aurora", out)!]
          && out.rotation?.enabled == true,
          "retire: active Sunray → \(out.presets.first { $0.id == out.activeID }?.name ?? "none"), night → first featured, rotation pruned to Aurora")
    check(DefaultPresets.retireUntouched(out).1 == DefaultPresets.Retirement(), "retire: a second pass changes nothing")

    // A stored copy from before a parameter existed is still untouched (missing = default).
    var older = defs[0]
    let atDefault = older.effects[0].params.keys.sorted().first {
        older.effects[0].params[$0] == older.effects[0].kind.defaultParams[$0]
    }
    if let k = atDefault { older.effects[0].params[k] = nil }
    older.id = UUID(); older.effects[0].id = UUID()
    var moved = defs[0]; moved.effects[0].params[atDefault ?? ""] = -7
    check(atDefault != nil && DefaultPresets.isUntouched(older, as: defs[0]) && !DefaultPresets.isUntouched(moved, as: defs[0]),
          "retire: a param missing from an old copy counts as its default (\(defs[0].name) without \"\(atDefault ?? "?")\"); a changed one doesn't")

    // Edited copies stay — and decode, and render.
    var sunray = DefaultPresets.builtInDefinition("Sunray")!, pipes = DefaultPresets.builtInDefinition("Pipeworks")!
    var flies = DefaultPresets.builtInDefinition("Fireflies")!, tunnel = DefaultPresets.builtInDefinition("Light Tunnel")!
    sunray.effects[0].params["hands"] = 1
    pipes.effects[0].colorA = RGBA(0.2, 0.8, 0.4)
    flies.fps = 60
    tunnel.effects[0].enabled = false; tunnel.effects.append(EffectInstance(.scanlines))
    var edited = DefaultPresets.makeLibrary()
    edited.presets += [sunray, pipes, flies, tunnel]
    edited.activeID = sunray.id
    let (kept, r2) = DefaultPresets.retireUntouched(edited)
    check(r2.removed.isEmpty && Set(r2.kept) == ["Sunray", "Pipeworks", "Fireflies", "Light Tunnel"] && kept == edited,
          "retire: edited copies (a param, a colour, the frame rate, the stack) all stay, nothing remapped")
    if let data = try? JSONEncoder().encode(kept), let back = try? JSONDecoder().decode(Library.self, from: data) {
        check(back.unknownPresets.isEmpty && back.presets.suffix(4).map(\.name) == ["Sunray", "Pipeworks", "Fireflies", "Light Tunnel"],
              "retire: the kept copies decode as ordinary styles")
    } else {
        check(false, "retire: the kept library round-trips")
    }
    for p in [sunray, pipes, flies] {
        let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
        r.waitsForScenePipelines = true
        r.apply(p, source: SourceSpec())
        var lit = 0.0
        if let img = r.renderFrame(width: 320, height: 200, settled: true), let d = img.dataProvider?.data {
            let n = CFDataGetLength(d), b = CFDataGetBytePtr(d)!
            var l = 0
            for i in 0..<n where i % 4 != 3 && b[i] > 40 { l += 1 }
            lit = Double(l) / Double(n / 4 * 3)
        }
        check(lit > 0.01, String(format: "retire: the kept \(p.name) still renders (%.1f%% of channels lit)", lit * 100))
    }
    return ok
}
// MARK: - end retirement checks ────────────────────────────────────────────────────────────────

// MARK: - Hardening, Time Lapse and Meadow checks ───────────────────────────────────────────────

/// Params from a shared file: no conversion traps (SafeNumbers), decoding clamps every param to
/// its range, and every effect renders with 1e20 / 1e300 / NaN / ±inf params without trapping.
func hardeningChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    let bad: [Double] = [1e20, 1e300, -1e300, .nan, -.infinity, .infinity]
    let lim = 1 << 53
    check(Int(saturating: Double.nan) == 0 && Int(saturating: Double.infinity) == lim && Int(saturating: -Double.infinity) == -lim
          && Int(saturating: 1e300) == lim && Int(saturating: Float(1e30)) == lim && Int(saturating: Float.nan) == 0
          && Int(saturating: 2.5, .toNearestOrAwayFromZero) == 3 && Int(saturating: -2.7) == -2 && Int(saturating: 2.7, .down) == 2
          && Int32(saturating: 1e20) == .max && Int32(saturating: -Double.infinity) == .min && UInt32(saturating: -5.0) == 0,
          "Int(saturating:) never traps: NaN → 0, ±inf / 1e300 → ±2⁵³, rounding rules as Int(x.rounded(rule))")

    // Every kind's params at each bad value, sanitized: all finite and in range; a param this
    // build has no spec for is kept; in-range values (the shipping library) are untouched.
    var outOfRange: [String] = []
    for kind in EffectKind.allCases {
        for v in bad {
            var e = EffectInstance(kind)
            for k in e.params.keys { e.params[k] = v }
            e.params["paramFromTheFuture"] = 0.25
            var p = Preset(name: "x", effects: [e])
            p.fps = v.isFinite ? Int(saturating: v) : 30
            p.sanitize()
            let s = p.effects[0]
            for spec in kind.params {
                guard let x = s.params[spec.key], x.isFinite, x >= min(spec.min, spec.max), x <= max(spec.min, spec.max)
                else { outOfRange.append("\(kind.rawValue).\(spec.key)@\(v)"); continue }
            }
            if s.params["paramFromTheFuture"] != 0.25 { outOfRange.append("\(kind.rawValue): unknown param dropped") }
            if !(1...120).contains(p.fps) { outOfRange.append("\(kind.rawValue): fps \(p.fps)") }
        }
    }
    check(outOfRange.isEmpty, "sanitize: \(EffectKind.allCases.count) kinds × \(bad.count) bad values → every param finite and in its range, unknown params kept, fps 1…120 \(outOfRange.prefix(6))")
    var shipping = DefaultPresets.makeLibrary()
    let shippingBefore = shipping
    check(!shipping.sanitize() && shipping == shippingBefore, "sanitize leaves the shipping library untouched (every value already in range)")

    // The load path (SharedStore.loadLibrary, which the saver and the app read): a library.json
    // with 1e300-scale params decodes clamped. Only into a temp store (DOTSTUDIO_STORE_DIR).
    if ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil {
        var lib = Library()
        for kind in EffectKind.allCases where !kind.params.isEmpty {
            for v in [1e20, 1e300, -1e300] {
                var e = EffectInstance(kind)
                for k in e.params.keys { e.params[k] = v }
                lib.presets.append(Preset(name: "\(kind.rawValue) \(v)", effects: [e]))
            }
        }
        let saved = try? Data(contentsOf: store.libraryURL)
        _ = store.save(lib)
        var bad = 0
        if case .loaded(let back) = store.loadLibrary() {
            for p in back.presets {
                for e in p.effects {
                    for spec in e.kind.params {
                        let x = e.params[spec.key] ?? .nan
                        if !(x.isFinite && x >= min(spec.min, spec.max) && x <= max(spec.min, spec.max)) { bad += 1 }
                    }
                }
            }
            check(bad == 0 && back.presets.count == lib.presets.count,
                  "loadLibrary clamps a library.json of \(lib.presets.count) styles with ±1e300 / 1e20 params (\(bad) out of range)")
        } else {
            check(false, "loadLibrary reads the 1e300 library back")
        }
        if let saved { try? saved.write(to: store.libraryURL) } else { try? FileManager.default.removeItem(at: store.libraryURL) }
    } else {
        print("SKIP  loadLibrary clamp check: DOTSTUDIO_STORE_DIR isn't set (never writes the real library)")
    }

    // Render every kind UNSANITIZED (the renderer's own conversions must hold too): live frames
    // through renderFrame (weather, live sky, music, Bounce's logo, Zen Garden, serial dither)
    // and a thumbnail, at each bad value. A trap ends the process: reaching the end is the pass.
    let t0 = CFAbsoluteTimeGetCurrent()
    var frames = 0
    let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
    r.waitsForScenePipelines = true
    for kind in EffectKind.allCases {
        for v in bad {
            var e = EffectInstance(kind)
            for k in e.params.keys { e.params[k] = v }
            let p = Preset(name: "bad", effects: kind.isScene ? [e] : [e, EffectInstance(.dither)])
            r.apply(p, source: kind.isScene ? SourceSpec() : .builtInPhotos)
            if r.renderFrame(width: 48, height: 30) != nil { frames += 1 }
            if r.renderThumbnail(preset: p, source: SourceSpec(), width: 48, height: 30, time: Float(v.isFinite ? 5 : 1)) != nil { frames += 1 }
        }
    }
    check(frames > 0, String(format: "every kind renders with 1e20 / ±1e300 / NaN / ±inf params, unsanitized, without trapping (%d frames, %.1f s)",
                             frames, CFAbsoluteTimeGetCurrent() - t0))
    return ok
}

/// Time Lapse runs on across the hourly wrap of t: the simulated hour (Meadow's fixed Time of
/// Day) and Follow the Sun's simulated instant, as the renderer computes them each frame, never
/// jump — for lapse rates that divide an hour and ones that don't.
func lapseChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    func circ(_ a: Double, _ b: Double, _ p: Double) -> Double { let d = (b - a).truncatingRemainder(dividingBy: p); return d > p / 2 ? d - p : d < -p / 2 ? d + p : d }
    for base in [MetalRenderer.TimeBase.instance, .wallClock] {
        for lapse in [1.0, 7.0, 13.0, 45.0] {
            for live in [0.0, 1.0] {
                var e = EffectInstance(.meadow)
                e.params["live"] = live; e.params["lapse"] = lapse; e.params["hour"] = 9.25
                let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
                r.timeBase = base
                r.apply(Preset(name: "Lapse", effects: [e]), source: SourceSpec())
                if base == .instance { r.setInstanceTime(3599.7) } else {
                    r.timeBaseSkew = 3599.7 - MetalRenderer.wallPhase(Date().timeIntervalSince1970)
                }
                // frames back to back across the wrap; per frame the sky the renderer would fill
                var last: (wall: Double, hour: Double, sim: Double, sunH: Float, t: Double)?
                var worst = 0.0, oldWorst = 0.0, wrapped = false
                let rateH = 24.0 / (lapse * 60)                      // simulated hours per second
                let t0 = CACurrentMediaTime()
                while CACurrentMediaTime() - t0 < 0.7 {
                    _ = r.renderFrame(width: 16, height: 10)
                    let now = Date(), L = r.lapseClock(), t = r.animationTime()
                    let hour = MetalRenderer.lapseHour(hour: 9.25, lapse: lapse, lapseClock: L)
                    let sim = MetalRenderer.lapseDate(now: now, lapse: lapse, lapseClock: L).timeIntervalSince1970
                    var u = FXUniforms()
                    MetalRenderer.fillLiveSky(&u, inst: e, now: now, lapseClock: L, location: (43.7, -79.4))
                    if let p = last {
                        let dt = now.timeIntervalSince1970 - p.wall
                        if t < p.t { wrapped = true }
                        if live < 0.5 {
                            worst = max(worst, abs(circ(p.hour, hour, 24)) - rateH * dt)
                            // what the old formula did: hour + t·rate
                            oldWorst = max(oldWorst, abs(circ(9.25 + p.t * rateH, 9.25 + t * rateH, 24)) - rateH * dt)
                        } else {
                            worst = max(worst, abs(sim - p.sim) / 3600 - 1440 / lapse * dt / 3600)
                            oldWorst = max(oldWorst, abs((now.timeIntervalSince1970 + t * (1440 / lapse - 1))
                                                         - (p.wall + p.t * (1440 / lapse - 1))) / 3600 - 1440 / lapse * dt / 3600)
                        }
                        // the hour angle the shader gets moves by no more than the frame's share
                        let dH = abs(circ(Double(p.sunH), Double(u.sun.y), 2 * .pi)) / (2 * .pi) * 24
                        worst = max(worst, dH - (live < 0.5 ? rateH : 1440 / lapse / 3600 * 1.01) * dt - 0.01)
                    }
                    last = (now.timeIntervalSince1970, hour, sim, u.sun.y, t)
                }
                check(wrapped && worst < 0.02,
                      String(format: "Time Lapse %2.0f min/day, %@, %@: continuous across the wrap (worst excess step %.4f h; the old hour + t·rate jumped %.2f h)",
                             lapse, live > 0.5 ? "Follow the Sun" : "fixed hour", base == .instance ? "instance" : "wall clock", worst, oldWorst))
            }
        }
    }
    // Follow the Sun's offset wraps by whole Metonic cycles only: the time of day is exact.
    let now = Date()
    let a = MetalRenderer.lapseDate(now: now, lapse: 1, lapseClock: MetalRenderer.lapseCycle / 1439 - 0.01)
    let b = MetalRenderer.lapseDate(now: now, lapse: 1, lapseClock: MetalRenderer.lapseCycle / 1439 + 0.01)
    let tod = { (d: Date) in d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) }
    check(abs(circ(tod(a), tod(b), 86400) - 0.02 * 1440) < 1 && abs(a.timeIntervalSince(b)) > 86400 * 6000,
          "the 19-year (Metonic) wrap of Follow the Sun's lapse keeps the time of day (only the date jumps back)")
    return ok
}

/// Meadow under Live weather: a new Landscape draws its weather from the first frame (its
/// pipelines prewarm on apply; a blocking renderer waits for them, the saver's holds the frame).
func meadowLandscapeChecks() -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    func meanDiff(_ a: CGImage?, _ b: CGImage?) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return .infinity }
        let n = min(CFDataGetLength(da), CFDataGetLength(db)), pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
        var s = 0
        for i in 0..<n where i % 4 != 3 { s += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(s) / Double(n / 4 * 3)
    }
    let saved = WeatherLink.forced
    defer { WeatherLink.forced = saved }
    func meadow(_ land: Double) -> Preset {
        var e = EffectInstance(.meadow)
        e.params["live"] = 0; e.params["hour"] = 13; e.params["weather"] = 0; e.params["landscape"] = land
        e.params["speed"] = 0                 // a still scene: frames compare across renderers
        return Preset(name: "Meadow \(Int(land))", effects: [e])
    }
    var snow = WeatherMix.preset(.snow); snow.precip = 0.85
    let w = 320, h = 200
    for mode in [FXPipelines.Mode.blocking, .fastStart] {
        for (from, to) in [(0.0, 2.0), (2.0, 3.0), (3.0, 1.0)] {
            WeatherLink.forced = snow
            let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store, pipelines: mode)!
            r.timeBase = .wallClock
            r.apply(meadow(from), source: SourceSpec())
            var first: CGImage?
            let t0 = CACurrentMediaTime()
            while first == nil, CACurrentMediaTime() - t0 < 20 { first = r.renderFrame(width: w, height: h) }
            r.apply(meadow(to), source: SourceSpec())            // the Landscape menu
            var after: CGImage?
            let t1 = CACurrentMediaTime()
            while after == nil, CACurrentMediaTime() - t1 < 20 { after = r.renderFrame(width: w, height: h) }
            // references: the new landscape settled, under the snow and under a clear sky
            func ref(_ mix: WeatherMix) -> CGImage? {
                WeatherLink.forced = mix
                let q = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)!
                q.timeBase = .wallClock
                q.apply(meadow(to), source: SourceSpec())
                _ = q.renderFrame(width: w, height: h)
                return q.renderFrame(width: w, height: h)
            }
            let wx = ref(snow), clear = ref(.clear)
            let dWx = meanDiff(after, wx), dClear = meanDiff(after, clear)
            check(after != nil && dWx < dClear * 0.5,
                  String(format: "%@: Landscape %.0f → %.0f under Live heavy snow: the first frame drawn shows the weather (Δ snow %.2f, Δ clear sky %.2f)",
                         mode == .blocking ? "blocking (app, wallpaper)" : "fastStart (saver)", from, to, dWx, dClear))
        }
    }
    return ok
}
// MARK: - end hardening checks ──────────────────────────────────────────────────────────────────

if runChecks {
    let live = liveChecks(), format = formatChecks(), bounce = bounceChecks()
    let retirement = retirementChecks()
    let hardening = hardeningChecks(), lapse = lapseChecks(), landscape = meadowLandscapeChecks()
    exit(live && format && bounce && retirement && hardening && lapse && landscape ? 0 : 1)
}

if let tzArg, let tz = TimeZone(identifier: tzArg) { NSTimeZone.default = tz }
/// Local wall time HH:MM on --date (or today) in the --tz zone.
func wallDate(_ hhmm: String) -> Date? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = NSTimeZone.default
    var dc = cal.dateComponents([.year, .month, .day], from: Date())
    if let d = dateArg?.split(separator: "-").compactMap({ Int($0) }), d.count == 3 {
        dc.year = d[0]; dc.month = d[1]; dc.day = d[2]
    }
    // HH:MM, or HH:MM:SS(.fff) for second-accurate clock frames (e.g. 11:59:58.5)
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2 || parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    let s = parts.count == 3 ? (Double(parts[2]) ?? 0) : 0
    dc.hour = h; dc.minute = m
    return cal.date(from: dc)?.addingTimeInterval(s)
}
let lib = DefaultPresets.makeLibrary()
var presets = lib.presets
if !sceneArgs.isEmpty {
    guard ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil else {
        print("--scene installs into the store: set DOTSTUDIO_STORE_DIR to a temp dir"); exit(2)
    }
    var custom: [Preset] = []
    for arg in sceneArgs {
        let url = URL(fileURLWithPath: arg, isDirectory: true)
        let fm = FileManager.default
        var dirs = [url]
        if !fm.fileExists(atPath: url.appendingPathComponent("scene.json").path) {
            dirs = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("scene.json").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for dir in dirs {
            let r = CustomScenes.validate(packageAt: dir, device: renderer.device, store: store.baseDir)
            print(String(format: "scene %@: %@  engine %@  %@ at 5120×2880", dir.lastPathComponent, r.ok ? "OK" : "FAILED",
                         r.engine ?? "-", r.gpuMsAt5K.map { String(format: "%.2f ms", $0) } ?? "-"))
            for d in r.diagnostics { print("  " + d.formatted) }
            for w in r.warnings where !r.diagnostics.contains(where: { $0.formatted == w }) { print("  warning: " + w) }
            do {
                let id = try CustomScenes.install(packageAt: dir, into: store.baseDir)
                if let m = CustomScenes.manifest(id: id, store: store.baseDir) { custom.append(.customScene(m)) }
            } catch {
                print("  install failed: \(error.localizedDescription)")
            }
        }
    }
    presets = only == nil ? custom : presets + custom
}
if includePack { presets += DefaultPresets.coolPack() }
if legacy { presets += SceneCatalog.musicPresets }
if let only { presets = presets.filter { $0.name.lowercased().contains(only) } }
if looksOnly { presets = [Preset(name: "Source")] + presets.filter { !$0.isScene } }
if solo {
    for i in presets.indices where presets[i].effects.count > 1 { presets[i].effects = [presets[i].effects[0]] }
}
if let logoArg {
    // --logo: the logo every Bounce preset draws (an image is imported like the app does it).
    var kind = BounceLogoKind.builtIn, text: String?, file: String?
    if logoArg.hasPrefix("text:") { kind = .text; text = String(logoArg.dropFirst(5)) }
    else if logoArg.hasPrefix("file:") {
        kind = .image
        do { file = try store.importMedia(from: URL(fileURLWithPath: String(logoArg.dropFirst(5)))) }
        catch { print("--logo: couldn't import \(logoArg): \(error)"); exit(2) }
    }
    for i in presets.indices {
        for j in presets[i].effects.indices where presets[i].effects[j].kind == .bounce {
            presets[i].effects[j].logoKind = kind
            presets[i].effects[j].logoText = text
            presets[i].effects[j].logoFile = file
        }
    }
}
/// Bounce: the corner period and the next few corner hits for this preset at W×H.
func bounceInfo(_ p: Preset) {
    guard let inst = p.effects.first(where: { $0.enabled && $0.kind == .bounce }),
          let e = BounceLogo.entry(for: inst, mediaDir: store.mediaDir, device: renderer.device) else { return }
    let m = BounceLogo.timing(width: Double(W), height: Double(H), aspect: e.aspect,
                              size: Double(inst.g("size")), speed: Double(inst.g("speed")))
    let hits = (0..<4).map { String(format: "%.2f", m.tc + Double($0) * m.period) }.joined(separator: ", ")
    print(String(format: "bounce %@: logo %.0f×%.0f px (aspect %.2f, %@%@), crossings x %.2f s, y %.2f s, p:q %d:%d, a corner every %.1f s — at t = %@",
                 p.name, m.lw, m.lh, e.aspect, e.card ? "card" : "bare", e.lumHi < 0 ? ", one tone" : "",
                 m.tx, m.ty, m.p, m.q, m.period, hits))
}
if !overrides.isEmpty {
    for i in presets.indices where !presets[i].effects.isEmpty {
        presets[i].effects[0].params.merge(overrides) { _, new in new }
    }
}

for p in presets { bounceInfo(p) }

var source = lib.source
var photoTex: MTLTexture?
if let photo {
    let loader = MTKTextureLoader(device: renderer.device)
    photoTex = try? loader.newTexture(URL: URL(fileURLWithPath: photo), options: [
        .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)])
    source.kind = .image
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if gpuBench {
    let benchT0 = times.first ?? 0           // scene time of the first frame (--times): where a Zen Garden composition is
    // One fullscreen pass of each preset's first effect, encoded the way MetalRenderer does,
    // 3 frames per command buffer; GPU time from the command buffer's own timestamps.
    let dev = renderer.device
    let libURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("default.metallib")
    guard let queue = dev.makeCommandQueue(), let lib = try? dev.makeLibrary(URL: libURL),
          let vfn = lib.makeFunction(name: "fx_vertex"), let ffn = lib.makeFunction(name: "fx_fragment") else {
        print("gpubench: no metallib at \(libURL.path)"); exit(1)
    }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = vfn; pd.fragmentFunction = ffn
    pd.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pso = try! dev.makeRenderPipelineState(descriptor: pd)
    let sd = MTLSamplerDescriptor()
    sd.minFilter = .linear; sd.magFilter = .linear
    sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
    let samp = dev.makeSamplerState(descriptor: sd)!
    let tex = PlanetTextures(device: dev, queue: queue)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = dev.makeTexture(descriptor: td)!, input = dev.makeTexture(descriptor: td)!
    let astro = MetalRenderer.astro(location: renderer.location)
    // Now Playing samples slots 7/8: bench with the fixture's artwork, mipmapped as the renderer binds it.
    var artTex: MTLTexture = input
    if let art = musicFeed.artwork {
        let w = art.width, h = art.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(art, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        let t = dev.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        let cb = queue.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
        bl.generateMipmaps(for: t); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        artTex = t
    }
    let pal = musicFeed.snapshot.palette
    /// The uniforms a pass of `inst` draws with (as the renderer packs them), at scene time 0.
    func benchUniforms(_ inst: EffectInstance) -> (FXUniforms, Date) {
        var u = FXUniforms()
        inst.pack(into: &u)
        u.resolution = simd_float2(Float(W), Float(H))
        if inst.kind == .universe {
            u.p1 = simd_float4(astro.sun.x, astro.sun.y, astro.sun.z, 0)
            u.p2 = simd_float4(astro.userLon, astro.userLat, astro.hasLoc ? 1 : 0, (inst.params["orbits"] ?? 1) > 0.5 ? 1 : 0)
        }
        let wall = clocks.first.flatMap(wallDate) ?? Date()
        (u.clock, u.date) = MetalRenderer.wallClock(wall)
        MetalRenderer.fillLiveSky(&u, inst: inst, now: wall, lapseClock: 0, location: renderer.location)
        if WeatherLink.usesWeather(inst.kind) {
            let mix = WeatherLink.fixedCondition(inst).map(WeatherMix.preset) ?? WeatherLink.forced ?? .clear
            WeatherLink.pack(&u, mix: mix, inst: inst, drift: 0)
        }
        if inst.kind == .nowPlaying {
            // Steady playback; --musicfade benches the 1.6 s track-change cross-fade instead
            // (both backgrounds rendered).
            let has: Float = musicFeed.artwork != nil ? 1 : 0
            u.music = musicFadeBench ? simd_float4(has * 3, 0.4, 1, 0.8) : simd_float4(has, 0.4, 1, 1000)
            func c(_ i: Int) -> simd_float4 {
                i < pal.count ? simd_float4(Float(pal[i].r), Float(pal[i].g), Float(pal[i].b), 1) : .zero
            }
            u.musicPal0 = c(0); u.musicPal1 = c(1); u.musicPal2 = c(2)
            let r = MusicGeometry.artUV(MusicLayoutKind(rawValue: Int(u.p0.x.rounded())) ?? .album,
                                        size: CGSize(width: W, height: H), options: MusicSceneOptions(inst))
            u.musicRect = simd_float4(r.x, r.y, r.w, r.h)
        }
        return (u, wall)
    }
    /// GPU ms per pass of `pso` with these uniforms: (min, median) over 12 command buffers of 3.
    func benchPass(_ uIn: FXUniforms, kind: EffectKind?, wall: Date, pso: MTLRenderPipelineState,
                   inst: EffectInstance? = nil) -> (Double, Double) {
        var u = uIn
        let benchInst = inst ?? kind.map { EffectInstance($0) }      // Bounce: its logo
        var samples: [Double] = []
        let sand = SandGarden.Cache()
        for rep in 0..<14 {
            let cmd = queue.makeCommandBuffer()!
            for f in 0..<3 {
                u.time = benchTime.map { $0 + Float(f) * 0.004 } ?? (Float(rep * 3 + f) * 1.7 + benchT0)
                var sceneData: MTLTexture?
                if kind == .sandGarden { sceneData = sand.prepare(&u, wall: wall, device: dev) }
                if kind == .bounce, let inst = benchInst {
                    sceneData = BounceLogo.prepare(&u, inst: inst, mediaDir: store.mediaDir, device: dev)
                }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
                enc.setRenderPipelineState(pso)
                enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
                enc.setFragmentTexture(input, index: 0)
                enc.setFragmentTexture(input, index: 1)
                enc.setFragmentTexture(tex.earthDay, index: 2)
                enc.setFragmentTexture(tex.earthNight, index: 3)
                enc.setFragmentTexture(tex.planets, index: 4)
                enc.setFragmentTexture(input, index: 5)
                enc.setFragmentTexture(sceneData ?? TextAtlas.texture(dev, uniforms: u) ?? input, index: 6)   // Clocks: the real atlas
                enc.setFragmentTexture(artTex, index: 7)
                enc.setFragmentTexture(artTex, index: 8)
                enc.setFragmentSamplerState(samp, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
            if rep >= 2 { samples.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000 / 3) }
        }
        samples.sort()
        return (samples[0], samples[samples.count / 2])
    }
    /// A pipeline of fx_vertex + `fragment` from the bench's metallib (nil: no such function).
    var built: [String: MTLRenderPipelineState] = [:]
    func benchPipeline(_ fragment: String) -> MTLRenderPipelineState? {
        if let p = built[fragment] { return p }
        let p = FXPipelines.renderDescriptor(lib, fragment: fragment, format: .bgra8Unorm, archive: nil)
            .flatMap { FXPipelines.makeRender($0, device: dev) }
        built[fragment] = p
        return p
    }
    /// What the renderer binds for a pass of `inst`: Ocean Horizon's and Shallows' own (clear or
    /// weather, fixed or live: WeatherLink), a scene's own (ScenePipelines), else fx_fragment.
    func rendererPipeline(_ inst: EffectInstance, _ u: FXUniforms) -> MTLRenderPipelineState {
        if let w = WeatherLink.pipeline(for: inst.kind, uniforms: u, device: dev, format: .bgra8Unorm) { return w }
        if let n = ScenePipelines.functionName(u.effect), let p = benchPipeline(n) { return p }
        return pso
    }

    if pipeBench {
        // Every preset's first effect in fx_fragment and in its own function fx_scene_<id> (when the
        // metallib has one, whether or not ScenePipelines lists it), plus the passes that aren't a
        // style's: the slideshow source (0), the gradient behind every scene (1) and the style
        // crossfade (41). 3 interleaved rounds, each also timing a reference (the first preset in
        // fx_fragment) so a clock or thermal drift shows; per entry the best of the rounds.
        struct Entry { let name: String; let id: Int32; let kind: EffectKind?; let u: FXUniforms; let wall: Date }
        var entries: [Entry] = []
        var srcU = FXUniforms()
        srcU.resolution = simd_float2(Float(W), Float(H))
        srcU.effect = 0; srcU.fillMode = 3; srcU.srcSize = simd_float2(Float(W), Float(H))
        srcU.p0 = simd_float4(1.12, 0.3, 0.7, 0.5); srcU.p1 = simd_float4(1.08, 0.6, 0.2, 0)
        srcU.p2 = simd_float4(Float(W), Float(H), 0, 0)
        entries.append(Entry(name: "(slideshow source)", id: 0, kind: nil, u: srcU, wall: Date()))
        var gradU = FXUniforms()
        gradU.resolution = simd_float2(Float(W), Float(H)); gradU.effect = 1
        gradU.p0 = simd_float4(0.6, 1, 0, 0)
        entries.append(Entry(name: "(gradient source)", id: 1, kind: nil, u: gradU, wall: Date()))
        var fadeU = FXUniforms()
        fadeU.resolution = simd_float2(Float(W), Float(H)); fadeU.effect = 41
        fadeU.p0 = simd_float4(0.5, 0, 0, 0); fadeU.srcSize = simd_float2(Float(W), Float(H))
        entries.append(Entry(name: "(style crossfade)", id: 41, kind: nil, u: fadeU, wall: Date()))
        for p in presets {
            guard let inst = p.effects.first(where: { $0.enabled }) else { continue }
            let (u, wall) = benchUniforms(inst)
            entries.append(Entry(name: p.name, id: u.effect, kind: inst.kind, u: u, wall: wall))
        }
        // Every effect a library can hold (retired ones too), at its defaults, as "[name]": the ids
        // no preset leads with (--only "[" benches just these).
        for kind in EffectKind.allCases {
            let name = "[\(kind.displayName)]"
            if let only, !name.lowercased().contains(only) { continue }
            let (u, wall) = benchUniforms(EffectInstance(kind))
            entries.append(Entry(name: name, id: u.effect, kind: kind, u: u, wall: wall))
        }
        if only == nil || only == "[" {
            var blitU = FXUniforms()                 // the error-diffusion dithers' upscale pass
            blitU.resolution = simd_float2(Float(W), Float(H)); blitU.effect = 38
            blitU.p0 = simd_float4(Float(W / 2), Float(H / 2), 2, 0); blitU.srcSize = simd_float2(Float(W), Float(H))
            entries.append(Entry(name: "(dither upscale)", id: 38, kind: nil, u: blitU, wall: Date()))
        }
        guard let ref = entries.first(where: { $0.kind != nil }) else { exit(1) }
        var uber = [Double](repeating: .infinity, count: entries.count)
        var own = [Double](repeating: .infinity, count: entries.count)
        for round in 0..<3 {
            var refs: [Double] = []
            for (i, e) in entries.enumerated() {
                refs.append(benchPass(ref.u, kind: ref.kind, wall: ref.wall, pso: pso).0)
                let a = benchPass(e.u, kind: e.kind, wall: e.wall, pso: pso).0
                uber[i] = min(uber[i], a)
                if let sp = benchPipeline("fx_scene_\(e.id)") {
                    own[i] = min(own[i], benchPass(e.u, kind: e.kind, wall: e.wall, pso: sp).0)
                }
            }
            refs.sort()
            print(String(format: "round %d: reference %@ min %.2f  median %.2f  max %.2f ms", round + 1, ref.name,
                         refs[0], refs[refs.count / 2], refs[refs.count - 1]))
        }
        print("id\tüber ms\town ms\town/über\tlisted\tname")
        for (i, e) in entries.enumerated() {
            let listed = ScenePipelines.functionName(e.id) != nil ? "yes" : "-"
            if own[i].isFinite {
                print(String(format: "%d\t%.2f\t%.2f\t%.3f\t%@\t%@", e.id, uber[i], own[i], own[i] / uber[i], listed, e.name))
            } else {
                print(String(format: "%d\t%.2f\t-\t-\t%@\t%@", e.id, uber[i], listed, e.name))
            }
        }
        exit(0)
    }

    for wname in (weathers.isEmpty ? [nil] : weathers.map { Optional($0) }) {
    if let wname { WeatherLink.forced = weatherMix(wname) }
    for p in presets {
        guard let inst = p.effects.first(where: { $0.enabled }) else { continue }
        if inst.kind == .custom, let id = inst.custom?.id {
            // A Custom Scene: its own runtime-compiled pipeline (CustomSceneBench, as validate times it).
            let prep = CustomSceneCompiler.prepare(packageAt: CustomScenes.packageDir(id: id, store: store.baseDir), store: store.baseDir)
            if case .success(let pso) = CustomSceneCompiler.build(prep, device: dev, format: .bgra8Unorm),
               let ms = CustomSceneBench(device: dev, pso: pso, prepared: prep).median5K(width: W, height: H) {
                print(String(format: "%6.2f ms GPU  (median)  %@ [Custom Scene, %@]", ms, p.name, prep.engine?.id ?? "?"))
            } else {
                print("   —  %@ [Custom Scene]: doesn't compile")
            }
            continue
        }
        let (u, wall) = benchUniforms(inst)
        // The pipeline the renderer binds (rendererPipeline); --uber: fx_fragment, always.
        let (lo, med) = benchPass(u, kind: inst.kind, wall: wall, pso: uberOnly ? pso : rendererPipeline(inst, u), inst: inst)
        print(String(format: "%6.2f ms GPU  (median %5.2f)  %@ [%@]%@", lo, med,
                     p.name, inst.kind.displayName, wname.map { " @" + $0 } ?? ""))
    }
    }
    exit(0)
}

if frameBench {
    for p in presets {
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { continue }
        r.waitsForScenePipelines = true
        r.apply(p, source: source)
        for _ in 0..<6 { _ = r.renderFrame(width: W, height: H); Thread.sleep(forTimeInterval: 0.05) }
        r.measuresGPUTime = true
        _ = r.takeGPUSeconds()
        var ms: [Double] = []
        for _ in 0..<20 {
            _ = r.renderFrame(width: W, height: H)
            Thread.sleep(forTimeInterval: 0.01)            // let the completion handler land
            ms.append(r.takeGPUSeconds() * 1000)
        }
        ms.sort()
        print(String(format: "%6.2f ms GPU frame  (median %5.2f)  %@", ms[0], ms[ms.count / 2], p.name))
    }
    exit(0)
}

if veilBench {
    // Live frames (MetalRenderer.renderFrame, the saver's path) with GPU timestamps: the plain
    // style, then the same style behind Full Screen music — the veil (the style + pass 73) and
    // Album Art (the living art alone) — fully eased in. The veil's own cost is the difference.
    func frames(_ r: MetalRenderer) -> Double {
        for _ in 0..<6 { _ = r.renderFrame(width: W, height: H); Thread.sleep(forTimeInterval: 0.03) }
        _ = r.takeGPUSeconds()
        var ms: [Double] = []
        for _ in 0..<24 {
            _ = r.renderFrame(width: W, height: H)
            Thread.sleep(forTimeInterval: 0.01)
            ms.append(r.takeGPUSeconds() * 1000)
        }
        ms.sort()
        return ms[ms.count / 2]
    }
    print(String(format: "veil passes alone (pyramid + composite, fully in) at %dx%d: %.3f ms GPU (median); "
                 + "mid-fade %.3f ms; one plain full-size pass for reference %.3f ms", W, H,
                 renderer.benchmarkVeil(width: W, height: H), renderer.benchmarkVeil(width: W, height: H, amount: 0.5),
                 renderer.benchmarkVeil(width: W, height: H, reference: true)))
    print("GPU ms per frame at \(W)x\(H) (median of 24): plain · veil (Δ) · album art")
    for p in presets where !p.isMusicScene {
        guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { continue }
        r.location = loc
        r.waitsForScenePipelines = true
        r.setMusic(musicFeed.snapshot)
        r.measuresGPUTime = true
        r.apply(p, source: source)
        Thread.sleep(forTimeInterval: 0.4)               // a slideshow decodes its first photos
        let plain = frames(r)
        r.setMusicBackdrop(.veil, animated: false)
        let veil = frames(r)
        r.setMusicBackdrop(.albumArt(.album), animated: false)
        let art = frames(r)
        print(String(format: "%6.2f · %6.2f (+%5.2f) · %6.2f  %@", plain, veil, veil - plain, art, p.name))
    }
    exit(0)
}

if bench {
    // Wall time per full offscreen render (includes the alloc + readback floor, so compare
    // presets against each other, not against a frame budget). 4 warm-up renders let the
    // GPU clock ramp, then min and median of 24 renders spread over a minute of scene time.
    for p in presets {
        for i in 0..<4 {
            _ = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: Float(i),
                                         sourceTexOverride: photoTex)
        }
        var ms: [Double] = []
        for i in 0..<24 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: Float(i) * 2.5,
                                         sourceTexOverride: photoTex)
            ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        ms.sort()
        print(String(format: "%6.1f ms  (median %5.1f)  %@", ms[0], ms[ms.count / 2], p.name))
    }
    exit(0)
}

let clockList: [String?] = clocks.isEmpty ? [nil] : clocks
let musicRun = !cardCorners.isEmpty || fullBackdrop != nil
let weatherList: [String?] = weathers.isEmpty ? [nil] : weathers
for p in presets {
    for wname in weatherList {
    if let wname { WeatherLink.forced = weatherMix(wname) }
    for clk in clockList {
    renderer.clockOverride = clk.flatMap(wallDate)
    let now = renderer.clockOverride ?? Date()
    for t in times {
        // One render per music variant: each corner, or Full Screen, or none; for Full Screen
        // each --fade frame too. MusicPresentation decides what shows, as in the saver.
        let corners: [MusicSpec.Corner?] = p.isMusicScene || cardCorners.isEmpty ? [nil] : cardCorners
        for corner in corners {
        let settings = musicSettings(corner: corner)
        var pres = (musicRun || (overlay && p.isMusicScene))
            ? MusicPresentation.resolve(settings: settings, music: musicFeed.snapshot, preset: p, now: now) : .none
        if p.isMusicScene && !overlay { pres.overlay = .hidden }
        if textCheck && musicRun && !p.isMusicScene && pres.overlay == .hidden {
            textCheckRuns += 1; textCheckFailures += 1
            print("TEXTCHECK FAIL: music not visible (no track, or a stale fixture — run make.sh again)")
        }
        let fadeList: [Double?] = fades.isEmpty || pres.backdrop == .none ? [nil] : fades.map { Optional($0) }
        for k in fadeList {
        let t0 = CFAbsoluteTimeGetCurrent()
        var amount: Double = 1
        if let k {
            let c: Double = min(max(k, 0), 1)
            amount = c * c * (3 - 2 * c)                  // the renderer's smoothstep ease
        }
        guard let frame = renderer.renderThumbnail(preset: p, source: source, width: W, height: H, time: t,
                                                   sourceTexOverride: photoTex, musicBackdrop: pres.backdrop,
                                                   backdropAmount: amount) else { continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let alpha = CGFloat(k.map(fadeInOpacity) ?? 1)
        let cg = compositeMusic(frame, mode: pres.overlay, settings: settings, now: now, alpha: alpha)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let name = p.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let tl = t == t.rounded() ? "\(Int(t))" : String(format: "%.3f", t)
        var suffix = times.count > 1 ? "@" + tl : ""
        if let wname, weatherList.count > 1 || WeatherLink.usesWeather(p.effects.first?.kind ?? .halftone) { suffix += "@" + wname }
        if let clk { suffix += "@" + clk.replacingOccurrences(of: ":", with: "") }
        if let corner { suffix += "@card-" + corner.rawValue }
        if let fb = fullBackdrop, !p.isMusicScene {
            suffix += "@full-" + (fb == .albumArt ? "art" : "veil") + (fullLayout == .stage ? "-stage" : "")
        }
        if let k { suffix += String(format: "@fade%03d", Int((k * 100).rounded())) }
        if let tag { suffix += "@" + tag }
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)\(suffix).png"))
        print(String(format: "%@%@ %@  %.0f ms", p.isScene ? "[scene] " : "[look]  ", p.name, suffix, ms))
        }
        }
    }
    }
    }
}
if textCheck {
    print(String(format: "textcheck: %d renders, %d with problems; slowest overlay build %.1f ms cold, %.1f ms warm",
                 textCheckRuns, textCheckFailures, textCheckBuildMs, textCheckWarmMs))
    if textCheckFailures > 0 { exit(1) }
}
