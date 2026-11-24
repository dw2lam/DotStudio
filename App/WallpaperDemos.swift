//  WallpaperDemos.swift — little animated Macs beside the settings, showing what a choice
//  looks like on your own screen: a tiny desktop (menu bar, Dock, windows) over an animated
//  ocean beach, or the screensaver / lock screen full screen.
//
//  Each Scene acts out its row's current choice: coarser pixels for lower Quality, stepped
//  waves for Balanced frame rate or Efficient on battery, a held frame with a pause badge, a
//  window that comes forward (and with the switch on freezes the wallpaper until the desktop
//  is clicked), a crossfade between day and sunset, the music card, the lock screen, the menu
//  bar. Illustrations, not measurements: Balanced is drawn visibly stepped, because 30 vs 120
//  fps can't be told apart on most screens.
//
//  Cheap by design: vector shapes in one Canvas at 30 fps (a raster pass only for Quality,
//  a few thousand cells), only while Settings shows it; Reduce Motion shows a still.

import SwiftUI

struct WallpaperDemo: View {
    enum Scene: Equatable {
        /// The wallpaper's Quality: pixel size on the desktop.
        case quality(WallpaperSettings.Quality)
        /// The screensaver's Quality (render scale 1 / 0.75 / 0.5), full screen.
        case screensaverQuality(Double)
        /// Balanced steps, Smooth glides.
        case frameRate(WallpaperSettings.FrameRate)
        /// The one frame rate: fewer frames step more visibly (exaggerated so 15 vs 30 reads).
        case fps(Int)
        /// Full plays, Efficient steps and coarsens, Pause holds.
        case battery(WallpaperSettings.BatteryMode)
        /// A window comes forward; with `pauses` the wallpaper holds until the desktop is clicked.
        case otherApp(WallpaperSettings.OtherAppMode)
        /// Frame Rate Mode: Forced stays at 120 while you work; Dynamic drops to 60 while a load
        /// graph runs high; Reactive drops to 60 while you type in a window.
        case fpsMode(WallpaperSettings.FPSMode, top: Int = 120)
        /// A full-screen app comes up over the desktop: the wallpaper always pauses.
        case covered
        /// Low Power Mode on (or a hot Mac): the wallpaper holds a still frame.
        case lowPower
        /// The lock screen: the wallpaper's still, or your own picture.
        case lockScreen(on: Bool)
        /// The screensaver changing style (day → sunset) with this crossfade (0 = a cut).
        case crossfade(seconds: Double)
        /// The screensaver with music: nothing, a corner card, or full screen.
        case music(MusicSpec.Display)
        /// The window closes: DotStudio stays in the menu bar, or quits.
        case menuBarMode(keepsRunning: Bool)
        /// The menu bar, up close, with this icon.
        case menuBarIcon(String)
    }

    let scene: Scene
    /// A fixed moment instead of the clock (offscreen contact sheets).
    var at: Double? = nil
    /// Off: hold one telling frame (a choice that isn't picked or hovered stays still).
    var animates = true
    /// The frame a still tile shows: mid-story (window in front, paused badge, menu bar icon).
    static let stillMoment: Double = 600 + 3.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drawn at `base` (all the stories' coordinates) and scaled up to `size`.
    static let base = CGSize(width: 176, height: 110)
    /// One run of each story (window in, click, close…).
    private static let loop: Double = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || at != nil || !animates)) { ctx in
            let t = at ?? (reduceMotion || !animates ? Self.stillMoment : ctx.date.timeIntervalSinceReferenceDate)
            Canvas(rendersAsynchronously: false) { g, size in
                var g = g
                g.scaleBy(x: size.width / Self.base.width, y: size.height / Self.base.height)
                draw(&g, CGRect(origin: .zero, size: Self.base), t)
            }
        }
        .aspectRatio(Self.base.width / Self.base.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .accessibilityHidden(true)
    }

    // MARK: - Stories

    private func draw(_ g: inout GraphicsContext, _ r: CGRect, _ now: Double) {
        let phase = now.truncatingRemainder(dividingBy: Self.loop)
        switch scene {
        case .quality(let q):
            let cell: CGFloat = q == .full ? 0 : q == .balanced ? 2 : 3.5
            beach(&g, r, t: now, cell: cell)
            desktopChrome(&g, r)
        case .screensaverQuality(let s):
            beach(&g, r, t: now, cell: s >= 1 ? 0 : s >= 0.75 ? 2 : 3.5)
        case .frameRate(let f):
            beach(&g, r, t: f == .balanced ? stepped(now, 8) : now)
            desktopChrome(&g, r)
            badge(&g, r, symbol: "powerplug")
        case .fps(let f):
            let shown: Double? = f >= 120 ? nil : f >= 60 ? 24 : f >= 30 ? 12 : f >= 24 ? 9 : 6
            beach(&g, r, t: shown.map { stepped(now, $0) } ?? now)
            desktopChrome(&g, r)
            g.draw(Text("\(f) fps").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white),
                   at: CGPoint(x: r.width - 22, y: Self.menuBarHeight + 11))
        case .battery(let m):
            switch m {
            case .full: beach(&g, r, t: now)
            case .efficient: beach(&g, r, t: stepped(now, 5), cell: 2.5)
            case .still: beach(&g, r, t: 3)
            }
            desktopChrome(&g, r)
            badge(&g, r, symbol: "battery.50percent")
            if m == .still { pauseBadge(&g, r) }
        case .otherApp(let mode):
            let w = WindowStory(phase: phase)
            let held = mode == .pause && w.focused
            let slowed = mode == .efficient && w.focused
            if slowed { beach(&g, r, t: stepped(now, 5), cell: 2.5) }
            else { beach(&g, r, t: held ? now - phase + 2.4 : now) }
            desktopChrome(&g, r, frontApp: w.focused ? 1 : 0)
            appWindow(&g, r, slide: w.slide, focused: w.focused)
            pointer(&g, r, at: w.cursor, clicking: w.clicking)
            if held { pauseBadge(&g, r) }
            if slowed { badge(&g, r, symbol: "tortoise.fill") }
        case .fpsMode(let mode, let top):
            let w = WindowStory(phase: phase)
            // Dynamic: the load climbs while the window works, a beat after it opens
            let load = mode == .dynamic ? (phase < 1.9 ? 0.15 : phase < 2.4 ? 0.15 + ease((phase - 1.9) / 0.5) * 0.7
                                           : phase < 4.2 ? 0.85 : 0.85 - ease((phase - 4.2) / 0.5) * 0.7) : 0
            let down = mode == .dynamic ? load > 0.5 : mode == .reactive ? w.focused : false
            beach(&g, r, t: down ? stepped(now, 12) : now)
            desktopChrome(&g, r, frontApp: w.focused ? 1 : 0)
            appWindow(&g, r, slide: w.slide, focused: w.focused)
            if w.slide > 0 {
                let ww = r.width * 0.56, wh = r.height * 0.56, restX = r.maxX - ww - 8
                let f = CGRect(x: restX + (1 - w.slide) * (r.maxX - restX + 6), y: r.height * 0.2, width: ww, height: wh)
                if mode == .dynamic {
                    // a CPU graph: bars scrolling left, as tall as the load
                    let n = 14, bw = (f.width - 12) / CGFloat(n)
                    for i in 0..<n {
                        let age = Double(n - 1 - i) * 0.12
                        let p = max(0, phase - age)
                        let l = p < 1.9 ? 0.15 : p < 2.4 ? 0.15 + ease((p - 1.9) / 0.5) * 0.7
                              : p < 4.2 ? 0.85 : 0.85 - ease((p - 4.2) / 0.5) * 0.7
                        let h = (f.height - 18) * l * (0.85 + 0.15 * sin(Double(i) * 2.1 + now * 3))
                        g.fill(Path(CGRect(x: f.minX + 6 + CGFloat(i) * bw, y: f.maxY - 5 - h, width: bw - 1, height: h)),
                               with: .color((l > 0.5 ? Color.orange : Color.green).opacity(0.8)))
                    }
                } else {
                    // lines of text: Reactive types them while focused; Forced the same, unmoved
                    let typed = w.focused ? min(1, (phase - 2.2) / 1.8) : phase >= 4.2 ? 1 : 0
                    for i in 0..<4 {
                        let k = max(0, min(1, typed * 4 - Double(i)))
                        guard k > 0 else { continue }
                        g.fill(Path(roundedRect: CGRect(x: f.minX + 6, y: f.minY + 14 + CGFloat(i) * 8,
                                                        width: (f.width - 16) * (i == 3 ? 0.5 : 1) * k, height: 3),
                                    cornerRadius: 1.5), with: .color(.black.opacity(0.2)))
                    }
                }
            }
            if mode != .dynamic { pointer(&g, r, at: w.cursor, clicking: w.clicking) }
            let label = "\(Int(down ? WallpaperBudget.stepDown(Double(top), 1) : Double(top))) fps"
            let pill = CGRect(x: 6, y: Self.menuBarHeight + 5, width: 30, height: 11)
            g.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color((down ? Color.orange : .black).opacity(0.6)))
            g.draw(Text(label).font(.system(size: 6.5, weight: .bold, design: .rounded)).foregroundStyle(.white),
                   at: CGPoint(x: pill.midX, y: pill.midY))
        case .covered:
            // a full-screen app grows over the desktop, then leaves
            let k = phase < 1.5 ? 0 : phase < 2.1 ? ease((phase - 1.5) / 0.6) : phase < 4.6 ? 1 : 1 - ease((phase - 4.6) / 0.6)
            beach(&g, r, t: k > 0.98 ? now - phase + 2.1 : now)
            desktopChrome(&g, r)
            let full = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
            let small = CGRect(x: r.width * 0.3, y: r.height * 0.25, width: r.width * 0.4, height: r.height * 0.45)
            if k > 0 {
                let f = CGRect(x: small.minX + (full.minX - small.minX) * k, y: small.minY + (full.minY - small.minY) * k,
                               width: small.width + (full.width - small.width) * k,
                               height: small.height + (full.height - small.height) * k)
                g.fill(Path(roundedRect: f, cornerRadius: 4 * (1 - k)), with: .color(Color(white: 0.96).opacity(min(1, k * 2))))
                for i in 0..<4 {
                    g.fill(Path(roundedRect: CGRect(x: f.minX + 10, y: f.minY + 14 + CGFloat(i) * 9,
                                                    width: f.width * (i == 3 ? 0.35 : 0.6), height: 3.5), cornerRadius: 1.75),
                           with: .color(.black.opacity(0.12 * k)))
                }
            }
            if k > 0.98 { pauseBadge(&g, r) }
        case .lowPower:
            beach(&g, r, t: 3)
            desktopChrome(&g, r)
            badge(&g, r, symbol: "leaf.fill")
            pauseBadge(&g, r)
        case .lockScreen(let on):
            if on { beach(&g, r, t: 3) } else { ownPicture(&g, r) }
            lockScreenOverlay(&g, r)
        case .crossfade(let seconds):
            // day for 3 s, sunset for 3 s, blending over `seconds` at each change
            let half = Self.loop / 2
            let into = phase.truncatingRemainder(dividingBy: half)
            let k = seconds < 0.05 ? 1 : min(into / seconds, 1)
            let k2 = k * k * (3 - 2 * k)
            beach(&g, r, t: now, sunset: phase < half ? 1 - k2 : k2)
        case .music(let mode):
            beach(&g, r, t: now, sunset: 0.35)
            musicOverlay(&g, r, mode)
        case .menuBarMode(let keeps):
            let p = phase
            let open = p < 2.4                       // the window, until its close button is clicked
            let gone = !keeps && p >= 2.6            // quit: off the Dock and the menu bar
            beach(&g, r, t: now)
            desktopChrome(&g, r, showsStatusIcon: !gone, dotStudioInDock: open)
            if open { appWindow(&g, r, slide: 1, focused: true, title: true) }
            let k = p < 1.0 ? 0 : p < 1.8 ? ease((p - 1.0) / 0.8) : p < 3.6 ? 1 : 1 - ease((p - 3.6) / 0.8)
            let closeButton = CGPoint(x: 0.285, y: 0.225), rest = CGPoint(x: 0.55, y: 0.70)
            pointer(&g, r, at: lerp(rest, closeButton, k), clicking: p >= 2.0 && p < 2.4)
            if !open && keeps && p < 5 {
                highlight(&g, statusIconRect(r))       // still there, in the menu bar
            }
        case .menuBarIcon(let symbol):
            beach(&g, r, t: now)
            zoomedMenuBar(&g, r, symbol: symbol)
        }
    }

    private func stepped(_ t: Double, _ fps: Double) -> Double { (t * fps).rounded(.down) / fps }
    private func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    private func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    /// The focus story: desktop → window slides in and is clicked → in front (paused, if set)
    /// → the desktop is clicked → window leaves.
    private struct WindowStory {
        let slide: Double, focused: Bool, cursor: CGPoint, clicking: Bool
        init(phase p: Double) {
            func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
            slide = p < 1.2 ? 0 : p < 1.7 ? ease((p - 1.2) / 0.5) : p < 5.3 ? 1 : 1 - ease((p - 5.3) / 0.5)
            focused = p >= 2.2 && p < 4.2
            clicking = (p >= 2.0 && p < 2.3) || (p >= 4.0 && p < 4.3)
            let onWindow = CGPoint(x: 0.62, y: 0.48), onDesktop = CGPoint(x: 0.20, y: 0.66)
            let k = p < 1.5 ? 0 : p < 2.0 ? ease((p - 1.5) / 0.5) : p < 3.4 ? 1 : p < 4.0 ? 1 - ease((p - 3.4) / 0.6) : 0
            cursor = CGPoint(x: onDesktop.x + (onWindow.x - onDesktop.x) * k,
                             y: onDesktop.y + (onWindow.y - onDesktop.y) * k)
        }
    }

    // MARK: - The beach

    /// Day and sunset colours; `mix` blends between them.
    private struct Palette {
        var skyTop, skyHorizon, sun, seaFar, seaNear, sand, wetSand: SIMD3<Double>
        static let day = Palette(skyTop: [0.33, 0.60, 0.92], skyHorizon: [0.80, 0.90, 0.98], sun: [1, 0.98, 0.88],
                                 seaFar: [0.07, 0.38, 0.60], seaNear: [0.20, 0.72, 0.76],
                                 sand: [0.94, 0.85, 0.67], wetSand: [0.80, 0.70, 0.54])
        static let sunset = Palette(skyTop: [0.24, 0.20, 0.45], skyHorizon: [0.99, 0.63, 0.42], sun: [1, 0.84, 0.58],
                                    seaFar: [0.20, 0.20, 0.40], seaNear: [0.50, 0.42, 0.56],
                                    sand: [0.82, 0.63, 0.52], wetSand: [0.62, 0.47, 0.42])
        static func mix(_ k: Double) -> Palette {
            func m(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { a + (b - a) * k }
            let a = day, b = sunset
            return Palette(skyTop: m(a.skyTop, b.skyTop), skyHorizon: m(a.skyHorizon, b.skyHorizon), sun: m(a.sun, b.sun),
                           seaFar: m(a.seaFar, b.seaFar), seaNear: m(a.seaNear, b.seaNear),
                           sand: m(a.sand, b.sand), wetSand: m(a.wetSand, b.wetSand))
        }
    }

    private static let horizon = 0.44
    /// Where the water ends (unit y) — it washes in and out.
    private static func shore(_ u: Double, _ t: Double) -> Double {
        0.70 + 0.035 * sin(t * 0.9) + 0.012 * sin(u * 9 + t * 1.3)
    }
    private static let foam = 0.022
    /// The rolling wave lines' depths (0 at the horizon … 1 at the shore), moving in.
    private static func waveDepths(_ t: Double) -> [Double] {
        (0..<2).map { k in (Double(k) / 2 + 0.25 + t * 0.06).truncatingRemainder(dividingBy: 1) }
    }

    private func color(_ c: SIMD3<Double>, _ a: Double = 1) -> Color { Color(red: c.x, green: c.y, blue: c.z).opacity(a) }

    /// The beach at time `t`. `cell` > 0 draws it in square pixels that size (lower quality).
    private func beach(_ g: inout GraphicsContext, _ r: CGRect, t: Double, sunset: Double = 0, cell: CGFloat = 0) {
        let p = Palette.mix(sunset)
        if cell > 0 { pixelBeach(&g, r, t: t, p: p, sunset: sunset, cell: cell); return }
        let W = r.width, H = r.height, hy = H * Self.horizon
        // sky and sun
        g.fill(Path(CGRect(x: 0, y: 0, width: W, height: hy + 1)),
               with: .linearGradient(Gradient(colors: [color(p.skyTop), color(p.skyHorizon)]),
                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: hy)))
        let sun = sunCenter(r, sunset), sr = H * 0.075
        g.fill(Path(ellipseIn: CGRect(x: sun.x - sr * 2.2, y: sun.y - sr * 2.2, width: sr * 4.4, height: sr * 4.4)),
               with: .radialGradient(Gradient(colors: [color(p.sun, 0.45), color(p.sun, 0)]),
                                     center: sun, startRadius: sr * 0.8, endRadius: sr * 2.2))
        var sky = g
        sky.clip(to: Path(CGRect(x: 0, y: 0, width: W, height: hy)))
        sky.fill(Path(ellipseIn: CGRect(x: sun.x - sr, y: sun.y - sr, width: sr * 2, height: sr * 2)), with: .color(color(p.sun)))
        // sand first (the sea and foam lie over it)
        g.fill(Path(CGRect(x: 0, y: hy, width: W, height: H - hy)),
               with: .linearGradient(Gradient(colors: [color(p.wetSand), color(p.sand)]),
                                     startPoint: CGPoint(x: 0, y: H * 0.68), endPoint: CGPoint(x: 0, y: H * 0.80)))
        // the sea, down to the shoreline
        var sea = Path()
        sea.move(to: CGPoint(x: 0, y: hy))
        sea.addLine(to: CGPoint(x: W, y: hy))
        for i in stride(from: 16, through: 0, by: -1) {
            let u = Double(i) / 16
            sea.addLine(to: CGPoint(x: W * u, y: H * Self.shore(u, t)))
        }
        sea.closeSubpath()
        g.fill(sea, with: .linearGradient(Gradient(colors: [color(p.seaFar), color(p.seaNear)]),
                                          startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: H * 0.72)))
        // rolling wave lines, brighter as they near the shore
        for d in Self.waveDepths(t) {
            var line = Path()
            for i in 0...16 {
                let u = Double(i) / 16
                let y = hy + (H * Self.shore(u, t) - hy) * d * d + sin(u * 6 + t * 1.2 + d * 6) * 0.5
                if i == 0 { line.move(to: CGPoint(x: W * u, y: y)) } else { line.addLine(to: CGPoint(x: W * u, y: y)) }
            }
            let fade = min(d / 0.25, 1) * min((1 - d) / 0.2, 1)   // fade in at the horizon, out at the shore
            g.stroke(line, with: .color(.white.opacity(0.35 * max(fade, 0))), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
        // foam where the water meets the sand
        var foam = Path()
        for i in 0...16 {
            let u = Double(i) / 16
            let pt = CGPoint(x: W * u, y: H * Self.shore(u, t))
            if i == 0 { foam.move(to: pt) } else { foam.addLine(to: pt) }
        }
        g.stroke(foam, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: H * Self.foam, lineCap: .round, lineJoin: .round))
    }

    private func sunCenter(_ r: CGRect, _ sunset: Double) -> CGPoint {
        CGPoint(x: r.width * 0.72, y: r.height * (0.22 + 0.2 * sunset))
    }

    /// The same beach as square pixels `cell` points wide — what a lower render scale looks like.
    private func pixelBeach(_ g: inout GraphicsContext, _ r: CGRect, t: Double, p: Palette, sunset: Double, cell: CGFloat) {
        let cols = Int((r.width / cell).rounded(.up)), rows = Int((r.height / cell).rounded(.up))
        var px = [UInt8](repeating: 255, count: cols * rows * 4)
        let sun = sunCenter(CGRect(x: 0, y: 0, width: 1, height: 1), sunset)
        let aspect = Double(r.width / r.height)
        for j in 0..<rows {
            let v = (Double(j) + 0.5) / Double(rows)
            for i in 0..<cols {
                let u = (Double(i) + 0.5) / Double(cols)
                let shore = Self.shore(u, t)
                var c: SIMD3<Double>
                if v < Self.horizon {
                    c = p.skyTop + (p.skyHorizon - p.skyTop) * (v / Self.horizon)
                    let dx = (u - sun.x) * aspect, dy = v - sun.y
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < 0.075 { c = p.sun } else if d < 0.165 { c += (p.sun - c) * 0.45 * (1 - (d - 0.075) / 0.09) }
                } else if v < shore - Self.foam / 2 {
                    let k = min((v - Self.horizon) / (0.72 - Self.horizon), 1)
                    c = p.seaFar + (p.seaNear - p.seaFar) * k
                } else if v < shore + Self.foam / 2 {
                    c = [0.97, 0.98, 1]
                } else {
                    c = p.wetSand + (p.sand - p.wetSand) * max(min((v - 0.68) / 0.12, 1), 0)
                }
                let o = (j * cols + i) * 4
                px[o] = UInt8(max(0, min(255, c.x * 255)))
                px[o + 1] = UInt8(max(0, min(255, c.y * 255)))
                px[o + 2] = UInt8(max(0, min(255, c.z * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        g.draw(Image(decorative: img, scale: 1).interpolation(.none).resizable(),
               in: CGRect(x: 0, y: 0, width: CGFloat(cols) * cell, height: CGFloat(rows) * cell))
    }

    /// "Your own picture" on the lock screen: a plain macOS-like gradient.
    private func ownPicture(_ g: inout GraphicsContext, _ r: CGRect) {
        g.fill(Path(r), with: .linearGradient(Gradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.62),
                                                                 Color(red: 0.55, green: 0.38, blue: 0.70)]),
                                              startPoint: .zero, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
    }

    // MARK: - The Mac around it

    private static let menuBarHeight: CGFloat = 8

    /// Menu bar along the top (Apple menu, a few menus, status icons with DotStudio's) and the
    /// Dock along the bottom. `frontApp` 1: another app's (shorter) name is in front.
    private func desktopChrome(_ g: inout GraphicsContext, _ r: CGRect, frontApp: Int = 0,
                               showsStatusIcon: Bool = true, dotStudioInDock: Bool = false) {
        let mh = Self.menuBarHeight
        g.fill(Path(CGRect(x: 0, y: 0, width: r.width, height: mh)), with: .color(.white.opacity(0.45)))
        symbol(&g, "apple.logo", in: CGRect(x: 5, y: 1.5, width: 5, height: mh - 3), color: .black.opacity(0.75))
        let widths: [CGFloat] = [frontApp == 0 ? 14 : 10, 7, 6, 8]
        var x: CGFloat = 14
        for (i, w) in widths.enumerated() {
            g.fill(Path(roundedRect: CGRect(x: x, y: mh / 2 - 1, width: w, height: 2), cornerRadius: 1),
                   with: .color(.black.opacity(i == 0 ? 0.7 : 0.4)))
            x += w + 4
        }
        if showsStatusIcon { symbol(&g, currentMenuIcon, in: statusIconRect(r), color: .black.opacity(0.75)) }
        symbol(&g, "wifi", in: CGRect(x: r.width - 24, y: 1.5, width: 6, height: mh - 3), color: .black.opacity(0.7))
        g.fill(Path(roundedRect: CGRect(x: r.width - 14, y: mh / 2 - 1, width: 10, height: 2), cornerRadius: 1),
               with: .color(.black.opacity(0.6)))
        // the Dock
        let icons: [Color] = [.blue, .green, .orange, .pink, .purple] + (dotStudioInDock ? [.teal] : [])
        let s: CGFloat = 9, gap: CGFloat = 2.5
        let dw = CGFloat(icons.count) * (s + gap) + gap + 2
        let dock = CGRect(x: (r.width - dw) / 2, y: r.height - s - 6, width: dw, height: s + 4)
        g.fill(Path(roundedRect: dock, cornerRadius: 4.5), with: .color(.white.opacity(0.5)))
        for (i, c) in icons.enumerated() {
            let ir = CGRect(x: dock.minX + gap + 1 + CGFloat(i) * (s + gap), y: dock.minY + 2, width: s, height: s)
            g.fill(Path(roundedRect: ir, cornerRadius: 2.4), with: .color(c.opacity(0.85)))
            if c == .teal { symbol(&g, "circle.hexagongrid.fill", in: ir.insetBy(dx: 2, dy: 2), color: .white) }
        }
    }

    private func statusIconRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.width - 35, y: 1, width: 7, height: Self.menuBarHeight - 2)
    }

    /// The icon chosen in General (the menu bar demo shows its own).
    private var currentMenuIcon: String {
        (UserDefaults.standard.string(forKey: MenuBarIcon.key).flatMap(MenuBarIcon.init(rawValue:)) ?? .standard)
            .symbol(live: true)
    }

    private func symbol(_ g: inout GraphicsContext, _ name: String, in rect: CGRect, color: Color) {
        var img = g.resolve(Image(systemName: name))
        img.shading = .color(color)
        let s = img.size
        let scale = min(rect.width / max(s.width, 1), rect.height / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        g.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// An app window over the desktop (`slide` 0 = off to the right). With `title`, it's
    /// DotStudio's own window (a gallery of tiles), its close button where the pointer goes.
    private func appWindow(_ g: inout GraphicsContext, _ r: CGRect, slide: Double, focused: Bool, title: Bool = false) {
        guard slide > 0 else { return }
        let ww = r.width * (title ? 0.62 : 0.56), wh = r.height * 0.56
        let restX = title ? r.width * 0.26 : r.maxX - ww - 8
        let frame = CGRect(x: restX + (1 - slide) * (r.maxX - restX + 6), y: r.height * 0.2, width: ww, height: wh)
        var shadowed = g
        shadowed.addFilter(.shadow(color: .black.opacity(focused ? 0.4 : 0.18), radius: focused ? 5 : 2, y: 2))
        shadowed.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Color(white: 0.97)))
        g.fill(Path(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 9), cornerRadius: 4),
               with: .color(Color(white: 0.9)))
        let lights: [Color] = focused ? [.red, .yellow, .green] : [.gray, .gray, .gray]
        for (i, c) in lights.enumerated() {
            g.fill(Path(ellipseIn: CGRect(x: frame.minX + 4 + CGFloat(i) * 5, y: frame.minY + 3, width: 3, height: 3)),
                   with: .color(c.opacity(0.9)))
        }
        if title {
            let tw = (frame.width - 12 - 9) / 4
            for j in 0..<2 {
                for i in 0..<4 {
                    let tr = CGRect(x: frame.minX + 6 + CGFloat(i) * (tw + 3),
                                    y: frame.minY + 13 + CGFloat(j) * (tw * 0.65 + 3), width: tw, height: tw * 0.65)
                    g.fill(Path(roundedRect: tr, cornerRadius: 1.5),
                           with: .color(Color(hue: Double(i + j * 4) / 8, saturation: 0.45, brightness: 0.8)))
                }
            }
        } else {
            for i in 0..<3 {
                let line = CGRect(x: frame.minX + 6, y: frame.minY + 14 + CGFloat(i) * 7,
                                  width: frame.width * (i == 2 ? 0.45 : 0.75), height: 3)
                g.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color(.black.opacity(0.14)))
            }
        }
    }

    private func pointer(_ g: inout GraphicsContext, _ r: CGRect, at unit: CGPoint, clicking: Bool) {
        let c = CGPoint(x: r.width * unit.x, y: r.height * unit.y)
        if clicking {
            g.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.accentColor), lineWidth: 1.6)
        }
        var arrow = Path()
        arrow.move(to: c)
        arrow.addLine(to: CGPoint(x: c.x, y: c.y + 10))
        arrow.addLine(to: CGPoint(x: c.x + 2.8, y: c.y + 7.4))
        arrow.addLine(to: CGPoint(x: c.x + 7, y: c.y + 7.4))
        arrow.closeSubpath()
        g.fill(arrow, with: .color(.black))
        g.stroke(arrow, with: .color(.white), lineWidth: 0.9)
    }

    private func highlight(_ g: inout GraphicsContext, _ rect: CGRect) {
        g.stroke(Path(roundedRect: rect.insetBy(dx: -2.5, dy: -1.2), cornerRadius: 2.5),
                 with: .color(.accentColor), lineWidth: 1.4)
    }

    private func pauseBadge(_ g: inout GraphicsContext, _ r: CGRect) {
        let rect = CGRect(x: 6, y: Self.menuBarHeight + 5, width: 16, height: 16)
        g.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.55)))
        for dx in [-2.2, 2.2] {
            g.fill(Path(roundedRect: CGRect(x: rect.midX + dx - 1.1, y: rect.midY - 3.6, width: 2.2, height: 7.2),
                        cornerRadius: 1), with: .color(.white))
        }
    }

    /// Plugged in / on battery, top right under the menu bar.
    private func badge(_ g: inout GraphicsContext, _ r: CGRect, symbol name: String) {
        let rect = CGRect(x: r.width - 22, y: Self.menuBarHeight + 5, width: 16, height: 11)
        g.fill(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 4), with: .color(.black.opacity(0.45)))
        symbol(&g, name, in: rect, color: .white)
    }

    private func lockScreenOverlay(_ g: inout GraphicsContext, _ r: CGRect) {
        g.draw(Text("Sunday, November 22").font(.system(size: 6.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)),
               at: CGPoint(x: r.midX, y: r.height * 0.12))
        g.draw(Text("9:41").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92)),
               at: CGPoint(x: r.midX, y: r.height * 0.3))
        let a = CGRect(x: r.midX - 6, y: r.height * 0.70, width: 12, height: 12)
        g.fill(Path(ellipseIn: a), with: .color(.white.opacity(0.85)))
        symbol(&g, "person.fill", in: a.insetBy(dx: 3, dy: 3), color: .gray)
        g.fill(Path(roundedRect: CGRect(x: r.midX - 16, y: r.height * 0.85, width: 32, height: 5), cornerRadius: 2.5),
               with: .color(.white.opacity(0.4)))
    }

    private func musicOverlay(_ g: inout GraphicsContext, _ r: CGRect, _ mode: MusicSpec.Display) {
        let art = Gradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.35), Color(red: 0.45, green: 0.25, blue: 0.70)])
        switch mode {
        case .off:
            return
        case .corner:
            let card = CGRect(x: 8, y: r.height - 30, width: 66, height: 22)
            g.fill(Path(roundedRect: card, cornerRadius: 5), with: .color(.black.opacity(0.38)))
            let a = CGRect(x: card.minX + 3, y: card.minY + 3, width: 16, height: 16)
            g.fill(Path(roundedRect: a, cornerRadius: 2.5),
                   with: .linearGradient(art, startPoint: a.origin, endPoint: CGPoint(x: a.maxX, y: a.maxY)))
            g.fill(Path(roundedRect: CGRect(x: a.maxX + 4, y: card.minY + 6, width: 36, height: 3), cornerRadius: 1.5),
                   with: .color(.white.opacity(0.9)))
            g.fill(Path(roundedRect: CGRect(x: a.maxX + 4, y: card.minY + 12, width: 24, height: 2.5), cornerRadius: 1.25),
                   with: .color(.white.opacity(0.55)))
        case .fullScreen:
            g.fill(Path(r), with: .color(.black.opacity(0.45)))
            let a = CGRect(x: r.midX - 22, y: r.height * 0.16, width: 44, height: 44)
            var s = g
            s.addFilter(.shadow(color: .black.opacity(0.4), radius: 4, y: 2))
            s.fill(Path(roundedRect: a, cornerRadius: 4),
                   with: .linearGradient(art, startPoint: a.origin, endPoint: CGPoint(x: a.maxX, y: a.maxY)))
            g.fill(Path(roundedRect: CGRect(x: r.midX - 26, y: a.maxY + 8, width: 52, height: 4), cornerRadius: 2),
                   with: .color(.white.opacity(0.92)))
            g.fill(Path(roundedRect: CGRect(x: r.midX - 17, y: a.maxY + 16, width: 34, height: 3), cornerRadius: 1.5),
                   with: .color(.white.opacity(0.55)))
        }
    }

    /// The menu bar's right end, magnified, with `symbol` as DotStudio's icon.
    private func zoomedMenuBar(_ g: inout GraphicsContext, _ r: CGRect, symbol name: String) {
        g.fill(Path(CGRect(x: 0, y: 0, width: r.width, height: 26)), with: .color(.white.opacity(0.6)))
        let items = [name, "wifi", "battery.75percent", "magnifyingglass"]
        var x = r.width * 0.12
        for (i, s) in items.enumerated() {
            let w: CGFloat = i == 2 ? 24 : 16
            let rect = CGRect(x: x, y: 5, width: w, height: 16)
            if i == 0 {
                g.fill(Path(roundedRect: rect.insetBy(dx: -4, dy: -2), cornerRadius: 5), with: .color(.black.opacity(0.12)))
            }
            symbol(&g, s, in: rect, color: .black.opacity(i == 0 ? 0.85 : 0.6))
            x += w + 12
        }
        g.draw(Text("9:41").font(.system(size: 11, weight: .medium)).foregroundStyle(.black.opacity(0.7)),
               at: CGPoint(x: min(x + 10, r.width - 14), y: 13))
    }
}

/// A Form row for a setting whose effect is easier to see than to read: the name and a line
/// about it with its control (switch or picker) on the same line, and underneath, in the same
/// cell, a little animated Mac acting out what the control is set to now.
struct VisualSettingRow<Control: View>: View {
    let title: String
    let detail: String
    let demo: WallpaperDemo.Scene
    @ViewBuilder var control: () -> Control
    @ScaledLength(relativeTo: .body) private var demoWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).textRole(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
            WallpaperDemo(scene: demo)
                .frame(width: demoWidth)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .contain)
    }
}

/// A Power Saving row in the manner of Wallpaper Engine's performance settings: the situation
/// ("Another app is focused"), then a card per option acting out what it does, with a stepped
/// slider under them — each stop under its card — and a line saying what the chosen option
/// does. The active card is in full colour with an accent ring that slides along with the
/// slider; the others are greyed (and hold still) until hovered or picked.
struct OptionCards<Value: Hashable>: View {
    struct Option {
        let label: String
        let value: Value
        let scene: WallpaperDemo.Scene
        /// What it does, in a sentence (shown under the slider while it's the chosen one).
        var explain: String = ""
    }

    let title: String
    var icon: String? = nil
    let options: [Option]
    @Binding var selection: Value
    /// A row that states what always happens (cards only, no slider).
    var fixed = false
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }

    private func choose(_ i: Int) {
        guard options.indices.contains(i), options[i].value != selection else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { selection = options[i].value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label {
                Text(title).textRole(.bodyEmphasis)
            } icon: {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            }
            OptionCardRow(spacing: Space.s) {
                ForEach(options.indices, id: \.self) { i in
                    OptionCard(label: options[i].label, scene: options[i].scene, active: fixed || i == index,
                               fixed: fixed, ring: ring) { choose(i) }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if !fixed && options.count > 1 {
                // The slider: its ends sit under the first and last cards' centres.
                let card = OptionCardRow.cardWidth(width, spacing: Space.s)
                let span = CGFloat(options.count - 1) * (card + Space.s)
                Slider(value: Binding(get: { Double(index) }, set: { choose(Int($0.rounded())) }),
                       in: 0...Double(options.count - 1), step: 1)
                    .labelsHidden()
                    .frame(width: span + 24)
                    .padding(.leading, max(card / 2 - 12, 0))
                    .accessibilityLabel(title)
                    .accessibilityValue(options[index].label)
                let chosen = options[index]
                if !chosen.explain.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(chosen.label).textRole(.bodyEmphasis).foregroundStyle(Color.accentColor)
                        Text(chosen.explain).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(index)
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
    }
}

private struct OptionCard: View {
    let label: String
    let scene: WallpaperDemo.Scene
    let active: Bool
    let fixed: Bool
    let ring: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                WallpaperDemo(scene: scene, animates: active || hovering)
                    .saturation(active || hovering ? 1 : 0)
                    .opacity(active ? 1 : hovering ? 0.9 : 0.55)
                    .padding(4)
                    .background {
                        if active && !fixed {
                            RoundedRectangle(cornerRadius: Radius.s + 4, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .matchedGeometryEffect(id: "ring", in: ring)
                        }
                    }
                Text(label)
                    .textRole(active ? .calloutEmphasis : .callout)
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fixed)
        .onHover { hovering = $0 && !active }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// The option cards on a shared three-column grid, left-aligned, so every row's cards line up.
struct OptionCardRow: Layout {
    var spacing: CGFloat
    var columns = 3

    static func cardWidth(_ width: CGFloat?, spacing: CGFloat, columns: Int = 3) -> CGFloat {
        guard let width, width.isFinite, width > 0 else { return 200 }
        return max(90, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
    private func cardWidth(_ width: CGFloat?) -> CGFloat { Self.cardWidth(width, spacing: spacing, columns: columns) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = cardWidth(proposal.width)
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? CGFloat(columns) * w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = cardWidth(bounds.width)
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (w + spacing), y: bounds.minY),
                    proposal: ProposedViewSize(width: w, height: nil))
        }
    }
}

/// Every demo across one loop, for checking the animation offscreen (UIShots
/// "settings-wallpaper-demos"): rows = scenes, columns = moments.
struct WallpaperDemoSheet: View {
    private let scenes: [(String, WallpaperDemo.Scene)] = [
        ("Quality Full", .quality(.full)), ("Quality Efficient", .quality(.efficient)),
        ("Battery Pause", .battery(.still)), ("Other app: pause", .otherApp(.pause)),
        ("Other app: slow down", .otherApp(.efficient)),
        ("FPS Forced", .fpsMode(.forced)), ("FPS Dynamic", .fpsMode(.dynamic)), ("FPS Reactive", .fpsMode(.reactive)),
        ("Full screen", .covered), ("Low Power", .lowPower),
        ("Lock screen", .lockScreen(on: true)), ("Crossfade 1.5 s", .crossfade(seconds: 1.5)),
        ("Music corner", .music(.corner)), ("Music full", .music(.fullScreen)),
        ("Menu bar: keeps running", .menuBarMode(keepsRunning: true)), ("Menu bar: quits", .menuBarMode(keepsRunning: false)),
        ("Menu bar icon", .menuBarIcon("circle.grid.3x3.fill")),
    ]
    private let moments: [Double] = [0.5, 2.1, 3.0, 4.1, 5.0]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(scenes.indices, id: \.self) { i in
                GridRow {
                    Text(scenes[i].0).font(.caption).frame(width: 130, alignment: .leading)
                    ForEach(moments, id: \.self) { m in
                        WallpaperDemo(scene: scenes[i].1, at: 600 + m).frame(width: 176)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
