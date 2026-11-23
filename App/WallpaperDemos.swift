//  WallpaperDemos.swift — the little animated desktops beside the wallpaper's power settings.
//
//  Each one is a miniature desktop playing a dot "wallpaper" and acts out what its row's
//  current choice does: coarser dots for lower Quality, stepped motion for Balanced frame
//  rate or Efficient on battery, a held frame with a pause badge, or an app window that
//  comes forward and (with the switch on) freezes the wallpaper until the desktop is clicked.
//  Illustrations, not measurements: Balanced is drawn at a visibly stepped rate because 30 vs
//  120 fps can't be told apart on most screens.
//
//  Cheap by design: one Canvas, ~100 dots, 30 fps, only while the Settings window shows it;
//  Reduce Motion shows a still.

import SwiftUI

struct WallpaperDemo: View {
    enum Scene: Equatable {
        /// Dot density follows Quality.
        case quality(WallpaperSettings.Quality)
        /// Balanced steps, Smooth glides.
        case frameRate(WallpaperSettings.FrameRate)
        /// Full plays, Efficient steps and coarsens, Pause holds.
        case battery(WallpaperSettings.BatteryMode)
        /// A window comes forward; with `pauses` the wallpaper holds until the desktop is clicked.
        case otherApp(pauses: Bool)
    }

    let scene: Scene
    /// A fixed moment instead of the clock (offscreen contact sheets).
    var at: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static let size = CGSize(width: 112, height: 70)
    /// One run of the focus story: desktop, window in, window focused, desktop clicked.
    private static let loop: Double = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || at != nil)) { ctx in
            let t = at ?? (reduceMotion ? 1.2 : ctx.date.timeIntervalSinceReferenceDate)
            Canvas(rendersAsynchronously: false) { g, size in draw(&g, size, t) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ now: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let phase = now.truncatingRemainder(dividingBy: Self.loop)

        // What the wallpaper does at this moment.
        var spacing: CGFloat = 7          // dot pitch: smaller = finer
        var fps: Double? = nil            // nil = smooth
        var held = false
        var window: WindowState? = nil
        switch scene {
        case .quality(let q):
            spacing = q == .full ? 5.5 : q == .balanced ? 7.5 : 11
        case .frameRate(let f):
            fps = f == .balanced ? 10 : nil
        case .battery(let m):
            if m == .efficient { fps = 6; spacing = 10 }
            held = m == .still
        case .otherApp(let pauses):
            window = WindowState(phase: phase)
            held = pauses && window!.focused
        }

        // Time the wallpaper shows: frozen while held (from a fixed moment, so the held
        // frame is a nice one), stepped at `fps`, else continuous.
        var wt = now
        if held { wt = window == nil ? 1.2 : now - phase + 2.4 }
        if let fps { wt = (wt * fps).rounded(.down) / fps }

        drawWallpaper(&g, rect, time: wt, spacing: spacing)
        if let window { drawWindow(&g, rect, window) }
        if held { drawPauseBadge(&g, rect) }
        if case .battery = scene { drawPowerGlyph(&g, rect, "battery.50percent") }
        if case .frameRate = scene { drawPowerGlyph(&g, rect, "powerplug") }
    }

    /// A field of dots swelling in a slow diagonal wave over a deep gradient — the house look.
    private func drawWallpaper(_ g: inout GraphicsContext, _ r: CGRect, time t: Double, spacing: CGFloat) {
        g.fill(Path(r), with: .linearGradient(
            Gradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.35, green: 0.12, blue: 0.40)]),
            startPoint: .zero, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        let cols = Int(r.width / spacing) + 1, rows = Int(r.height / spacing) + 1
        let ox = (r.width - CGFloat(cols - 1) * spacing) / 2, oy = (r.height - CGFloat(rows - 1) * spacing) / 2
        for j in 0..<rows {
            for i in 0..<cols {
                let x = ox + CGFloat(i) * spacing, y = oy + CGFloat(j) * spacing
                let w = sin(Double(x) * 0.09 + Double(y) * 0.06 - t * 2.2)
                let rad = spacing * CGFloat(0.16 + 0.22 * (w * 0.5 + 0.5))
                let a = 0.35 + 0.55 * (w * 0.5 + 0.5)
                g.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)),
                       with: .color(Color(red: 1, green: 0.78, blue: 0.55).opacity(a)))
            }
        }
    }

    /// The focus story over one loop: desktop only → window slides in and is clicked →
    /// window in front → the desktop is clicked (window steps back) → window leaves.
    private struct WindowState {
        let slide: Double        // 0 off-screen … 1 in place
        let focused: Bool
        let cursor: CGPoint      // unit coordinates
        let clicking: Bool
        init(phase p: Double) {
            func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
            slide = p < 1.2 ? 0 : p < 1.7 ? ease((p - 1.2) / 0.5) : p < 5.3 ? 1 : 1 - ease((p - 5.3) / 0.5)
            focused = p >= 2.2 && p < 4.2
            clicking = (p >= 2.0 && p < 2.3) || (p >= 4.0 && p < 4.3)
            // cursor: rests low-left, travels onto the window, then back out to the desktop
            let onWindow = CGPoint(x: 0.62, y: 0.55), onDesktop = CGPoint(x: 0.18, y: 0.72)
            let k = p < 1.5 ? 0 : p < 2.0 ? ease((p - 1.5) / 0.5) : p < 3.4 ? 1 : p < 4.0 ? 1 - ease((p - 3.4) / 0.6) : 0
            cursor = CGPoint(x: onDesktop.x + (onWindow.x - onDesktop.x) * k,
                             y: onDesktop.y + (onWindow.y - onDesktop.y) * k)
        }
    }

    private func drawWindow(_ g: inout GraphicsContext, _ r: CGRect, _ w: WindowState) {
        let ww = r.width * 0.58, wh = r.height * 0.62
        let x = r.maxX - ww - 6 + (1 - CGFloat(w.slide)) * (ww + 12)
        let frame = CGRect(x: x, y: r.height * 0.2, width: ww, height: wh)
        if w.slide > 0 {
            let shape = Path(roundedRect: frame, cornerRadius: 4)
            var shadow = g
            shadow.addFilter(.shadow(color: .black.opacity(w.focused ? 0.45 : 0.2), radius: w.focused ? 5 : 2, y: 2))
            let light = colorScheme == .light
            shadow.fill(shape, with: .color(light ? Color(white: 0.97) : Color(white: 0.2)))
            // title bar with traffic lights (grey when the window isn't in front)
            let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 9)
            g.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(light ? Color(white: 0.9) : Color(white: 0.28)))
            let lights: [Color] = w.focused ? [.red, .yellow, .green] : [.gray, .gray, .gray]
            for (i, c) in lights.enumerated() {
                g.fill(Path(ellipseIn: CGRect(x: frame.minX + 4 + CGFloat(i) * 5, y: frame.minY + 3, width: 3, height: 3)),
                       with: .color(c.opacity(0.9)))
            }
            // a few lines of "content"
            for i in 0..<3 {
                let line = CGRect(x: frame.minX + 6, y: frame.minY + 14 + CGFloat(i) * 7,
                                  width: frame.width * (i == 2 ? 0.45 : 0.75), height: 3)
                g.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color(.primary.opacity(0.18)))
            }
        }
        // the pointer, with a ring on each click
        let c = CGPoint(x: r.width * w.cursor.x, y: r.height * w.cursor.y)
        if w.clicking {
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

    private func drawPauseBadge(_ g: inout GraphicsContext, _ r: CGRect) {
        let d: CGFloat = 16
        let rect = CGRect(x: 5, y: 5, width: d, height: d)
        g.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.55)))
        for dx in [-2.2, 2.2] {
            g.fill(Path(roundedRect: CGRect(x: rect.midX + dx - 1.1, y: rect.midY - 3.6, width: 2.2, height: 7.2), cornerRadius: 1),
                   with: .color(.white))
        }
    }

    private func drawPowerGlyph(_ g: inout GraphicsContext, _ r: CGRect, _ symbol: String) {
        var img = g.resolve(Image(systemName: symbol))
        img.shading = .color(.white.opacity(0.9))
        let s = img.size
        let h: CGFloat = 9, w = s.width / max(s.height, 1) * h
        let rect = CGRect(x: r.maxX - w - 5, y: r.maxY - h - 5, width: w, height: h)
        var c = g
        c.addFilter(.shadow(color: .black.opacity(0.5), radius: 1.5))
        c.draw(img, in: rect)
    }
}

/// A Form row: the demo on the leading side, then the setting's name, a one-line
/// explanation and its control. At large text sizes the demo sits above the rest.
struct DemoSettingRow<Control: View>: View {
    let title: String
    let detail: String
    let demo: WallpaperDemo.Scene
    /// Switches sit trailing on the title line; pickers get their own line under the text.
    var inlineControl = false
    @ViewBuilder var control: () -> Control
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize >= SettingsMetrics.scaledControlsFrom
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))
        layout {
            WallpaperDemo(scene: demo)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).textRole(.bodyEmphasis)
                        Text(detail).textRole(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if inlineControl {
                        Spacer(minLength: Space.xs)
                        control()
                    }
                }
                if !inlineControl { control() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .contain)
    }
}

/// Every demo across one loop, for checking the animation offscreen (UIShots
/// "settings-wallpaper-demos"): rows = scenes, columns = moments.
struct WallpaperDemoSheet: View {
    private let scenes: [(String, WallpaperDemo.Scene)] = [
        ("Quality Full", .quality(.full)), ("Quality Efficient", .quality(.efficient)),
        ("Smooth", .frameRate(.smooth)), ("Battery Pause", .battery(.still)),
        ("Other app: keep playing", .otherApp(pauses: false)), ("Other app: pause", .otherApp(pauses: true)),
    ]
    private let moments: [Double] = [0.5, 1.5, 2.1, 3.0, 4.1, 5.0, 5.6]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(scenes.indices, id: \.self) { i in
                GridRow {
                    Text(scenes[i].0).font(.caption).frame(width: 120, alignment: .leading)
                    ForEach(moments, id: \.self) { m in
                        WallpaperDemo(scene: scenes[i].1, at: 600 + m)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
