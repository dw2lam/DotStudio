//  SetupGuideWalkthrough.swift — the guided setup's picture of System Settings: a stylized,
//  SwiftUI-drawn mock of the Settings window (sidebar + content; no screenshots, no Apple
//  marks) that shows the four clicks to choose DotStudio, with an animated pointer and
//  highlight rings. Auto-advances with step dots; pausable; under Reduce Motion it's four
//  still step cards instead.
//
//  The labels are System Settings' own (macOS 26/27, read from the Wallpaper settings
//  extension's Localizable.loctable): the sidebar's "Wallpaper", its "Screen Saver…" button,
//  the screen-saver sheet's "macOS" and "Other" sections, and "Done".

import SwiftUI

struct SetupWalkthrough: View {
    struct Step {
        let title: String
        /// Markdown: the on-screen labels in bold.
        let detail: String
    }

    static let steps: [Step] = [
        Step(title: "Open Wallpaper",
             detail: "In System Settings, click **Wallpaper** in the sidebar."),
        Step(title: "Click Screen Saver\u{2026}",
             detail: "It's the **Screen Saver\u{2026}** button at the bottom of the Wallpaper page."),
        Step(title: "Scroll to Other",
             detail: "Scroll to the bottom of the screen savers, to the **Other** section."),
        Step(title: "Choose DotStudio",
             detail: "Click **DotStudio**, then **Done**. More than one display? Choose it on each."),
    ]

    /// UI shots: hold this step, mid-click. nil: animate.
    var frozenStep: Int?
    /// UI shots: the Reduce Motion layout (four still cards).
    var forceStill = false
    /// Room is tight (the floating panel): the still cards go in one column.
    var narrow = false

    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var phase: SettingsMock.Phase = .start
    @State private var playing = true

    private var still: Bool { frozenStep == nil && (reduceMotion || forceStill) }

    var body: some View {
        if still {
            stillCards
        } else {
            animated
        }
    }

    // MARK: Animated

    private var animated: some View {
        let shown = frozenStep ?? step
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            SettingsMock(step: shown, phase: frozenStep == nil ? phase : .clicked)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Illustration of System Settings")
                .accessibilityValue("Step \(shown + 1) of \(Self.steps.count): \(plain(Self.steps[shown].detail))")
                .accessibilityAddTraits(.isImage)
            caption(shown)
            controls(shown)
        }
        .task(id: playing && frozenStep == nil ? step : -1) { await run() }
    }

    /// One step: the pointer glides from the last target to this one, clicks (the ring and
    /// the control react), holds, then the next step. Loops while playing.
    private func run() async {
        guard playing, frozenStep == nil else { return }
        phase = .start
        do {
            try await Task.sleep(for: .seconds(0.35))
            withAnimation(.easeInOut(duration: 0.9)) { phase = .moved }
            try await Task.sleep(for: .seconds(1.05))
            withAnimation(step == 2 ? .easeInOut(duration: 1.2) : .spring(response: 0.32, dampingFraction: 0.7)) {
                phase = .clicked
            }
            try await Task.sleep(for: .seconds(step == 3 ? 3.2 : 2.4))
            withAnimation(.easeInOut(duration: 0.35)) { step = (step + 1) % Self.steps.count }
        } catch {}
    }

    private func caption(_ i: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: layout.itemGap) {
            StepNumber(number: i + 1)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(Self.steps[i].title)
                    .textRole(.headline)
                    .wrapping()
                Text(.init(Self.steps[i].detail))
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(i)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func controls(_ shown: Int) -> some View {
        HStack(spacing: layout.controlGap) {
            HStack(spacing: Space.xxs) {
                ForEach(Self.steps.indices, id: \.self) { i in
                    Button {
                        playing = false
                        withAnimation(.easeInOut(duration: 0.3)) { step = i; phase = .clicked }
                    } label: {
                        Capsule()
                            .fill(i == shown ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: i == shown ? Space.l : Space.xs, height: Space.xs)
                            .padding(.vertical, Space.xs)
                            .padding(.horizontal, Space.xxs / 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(frozenStep != nil)
                    .accessibilityLabel("Step \(i + 1): \(Self.steps[i].title)")
                    .accessibilityAddTraits(i == shown ? .isSelected : [])
                    .help("Step \(i + 1): \(Self.steps[i].title)")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shown)
            Spacer(minLength: 0)
            Button {
                playing.toggle()
                if playing { phase = .start }
            } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                    .textRole(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(frozenStep != nil)
            .accessibilityLabel(playing ? "Pause the walkthrough" : "Play the walkthrough")
            .help(playing ? "Pause the walkthrough" : "Play the walkthrough")
        }
    }

    // MARK: Still (Reduce Motion)

    private var stillCards: some View {
        LazyVGrid(columns: narrow ? [GridItem(.flexible())] : layout.columns(minimum: layout.scaled(180), spacing: layout.itemGap),
                  alignment: .leading, spacing: layout.itemGap) {
            ForEach(Self.steps.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: layout.controlGap) {
                    SettingsMock(step: i, phase: .clicked)
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: layout.controlGap) {
                        StepNumber(number: i + 1)
                        VStack(alignment: .leading, spacing: layout.labelGap) {
                            Text(Self.steps[i].title).textRole(.calloutEmphasis).wrapping()
                            Text(.init(Self.steps[i].detail))
                                .textRole(.caption)
                                .foregroundStyle(.secondary)
                                .wrapping()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(i + 1) of \(Self.steps.count): \(Self.steps[i].title). \(plain(Self.steps[i].detail))")
            }
        }
    }

    private func plain(_ markdown: String) -> String { markdown.replacingOccurrences(of: "**", with: "") }
}

/// A step's number in a tinted disc.
private struct StepNumber: View {
    @ScaledLength(relativeTo: .headline) private var size: CGFloat = 22
    let number: Int

    var body: some View {
        Text("\(number)")
            .scaledFont { .scaled(points: 12, $0, weight: .semibold, design: .rounded) }
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

// MARK: - The mock

/// System Settings, drawn: a window with a sidebar and the Wallpaper page; the screen-saver
/// sheet over it from step 3. Drawn on a 480 × 300 design grid scaled to the width it gets,
/// so every line stays crisp. Its text is part of the picture: fixed sizes on purpose (it
/// doesn't follow the text size, the captions beside it do), and VoiceOver reads the
/// caption instead.
struct SettingsMock: View {
    enum Phase: Equatable {
        /// The pointer still at the last step's target.
        case start
        /// The pointer on this step's target.
        case moved
        /// Clicked: the control reacts, the ring shows (step 3: the list has scrolled).
        case clicked
    }

    let step: Int
    let phase: Phase

    static let design = CGSize(width: 480, height: 300)

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / Self.design.width
            Canvas(k: k, step: step, phase: phase)
        }
        .aspectRatio(Self.design.width / Self.design.height, contentMode: .fit)
    }

    // Design-grid geometry, shared by the drawing and the pointer.
    fileprivate enum G {
        static let titleBar: CGFloat = 28
        static let sidebarWidth: CGFloat = 136
        static let rowTop: CGFloat = 62
        static let rowHeight: CGFloat = 19
        static let sidebar: [(name: String, symbol: String, tint: Color)] = [
            ("General", "gearshape.fill", .gray),
            ("Appearance", "circle.lefthalf.filled", Color(white: 0.2)),
            ("Control Center", "switch.2", .gray),
            ("Desktop & Dock", "dock.rectangle", Color(white: 0.2)),
            ("Displays", "sun.max.fill", .blue),
            ("Spotlight", "magnifyingglass", .gray),
            ("Wallpaper", "photo", .cyan),
            ("Notifications", "bell.badge.fill", .red),
            ("Sound", "speaker.wave.2.fill", .pink),
            ("Lock Screen", "lock.fill", Color(white: 0.2)),
        ]
        static let wallpaperIndex = 6
        static var wallpaperRow: CGRect {
            CGRect(x: 6, y: rowTop + CGFloat(wallpaperIndex) * rowHeight, width: sidebarWidth - 12, height: rowHeight)
        }
        static let screenSaverButton = CGRect(x: 370, y: 264, width: 94, height: 20)

        // The sheet and its list (list coordinates are inside the viewport, before scrolling)
        static let sheet = CGRect(x: 156, y: 36, width: 308, height: 258)
        static let viewport = CGRect(x: 168, y: 48, width: 284, height: 206)
        static let tile = CGSize(width: 88, height: 50)
        static let tileGap: CGFloat = 10
        static let rowPitch: CGFloat = 60
        static let otherHeaderY: CGFloat = 204
        static let otherRowY: CGFloat = 222
        static let contentHeight: CGFloat = 296
        static var scrollDistance: CGFloat { contentHeight - viewport.height }
        static let done = CGRect(x: 400, y: 266, width: 52, height: 20)

        static func otherHeader(scroll: CGFloat) -> CGRect {
            CGRect(x: viewport.minX - 4, y: viewport.minY + otherHeaderY - scroll - 2, width: 44, height: 18)
        }
        static func dotStudioTile(scroll: CGFloat) -> CGRect {
            CGRect(x: viewport.minX + tile.width + tileGap, y: viewport.minY + otherRowY - scroll,
                   width: tile.width, height: tile.height)
        }

        /// Where the pointer rests for each step (the centre of what it clicks).
        static func target(_ step: Int) -> CGPoint {
            switch step {
            case 0: return CGPoint(x: wallpaperRow.midX - 18, y: wallpaperRow.midY)
            case 1: return CGPoint(x: screenSaverButton.midX, y: screenSaverButton.midY)
            case 2: return CGPoint(x: viewport.midX + 30, y: viewport.midY + 20)
            default: let t = dotStudioTile(scroll: scrollDistance); return CGPoint(x: t.midX + 6, y: t.midY + 4)
            }
        }
        static let rest = CGPoint(x: 300, y: 150)
    }

    private struct Canvas: View {
        let k: CGFloat
        let step: Int
        let phase: Phase

        private var wallpaperSelected: Bool { step > 0 || phase == .clicked }
        private var sheetShown: Bool { step >= 2 }
        private var scroll: CGFloat { step >= 3 || (step == 2 && phase == .clicked) ? G.scrollDistance : 0 }
        private var dotStudioChosen: Bool { step == 3 && phase == .clicked }

        var body: some View {
            ZStack(alignment: .topLeading) {
                window
                if sheetShown {
                    Color.black.opacity(0.16)
                        .clipShape(RoundedRectangle(cornerRadius: 12 * k, style: .continuous))
                        .transition(.opacity)
                    sheet
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                ring
                pointer
            }
            .frame(width: SettingsMock.design.width * k, height: SettingsMock.design.height * k, alignment: .topLeading)
            .compositingGroup()
        }

        // MARK: Window

        private var window: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12 * k, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 8 * k, y: 3 * k)
                // Sidebar
                UnevenRoundedRectangle(topLeadingRadius: 12 * k, bottomLeadingRadius: 12 * k, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(width: G.sidebarWidth * k, height: 300 * k)
                trafficLights
                searchField
                ForEach(G.sidebar.indices, id: \.self) { i in sidebarRow(i) }
                // Content
                wallpaperPage
                RoundedRectangle(cornerRadius: 12 * k, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: max(0.5, 0.8 * k))
            }
        }

        private var trafficLights: some View {
            HStack(spacing: 6 * k) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                    Circle().fill(c).frame(width: 9 * k, height: 9 * k)
                }
            }
            .offset(x: 12 * k, y: 11 * k)
        }

        private var searchField: some View {
            HStack(spacing: 4 * k) {
                Image(systemName: "magnifyingglass").font(.system(size: 8 * k))
                Text("Search").font(.system(size: 9 * k))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7 * k)
            .frame(width: (G.sidebarWidth - 20) * k, height: 18 * k)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .offset(x: 10 * k, y: 34 * k)
        }

        private func sidebarRow(_ i: Int) -> some View {
            let item = G.sidebar[i]
            let selected = i == G.wallpaperIndex && wallpaperSelected
            return HStack(spacing: 6 * k) {
                Image(systemName: item.symbol)
                    .font(.system(size: 7.5 * k, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 13 * k, height: 13 * k)
                    .background(RoundedRectangle(cornerRadius: 3.5 * k, style: .continuous).fill(item.tint.gradient))
                Text(item.name)
                    .font(.system(size: 9.5 * k, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6 * k)
            .frame(width: G.wallpaperRow.width * k, height: G.rowHeight * k)
            .background(RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
                .fill(Color.accentColor).opacity(selected ? 1 : 0))
            .offset(x: 6 * k, y: (G.rowTop + CGFloat(i) * G.rowHeight) * k)
        }

        private var wallpaperPage: some View {
            let x0: CGFloat = 152
            return ZStack(alignment: .topLeading) {
                Text("Wallpaper")
                    .font(.system(size: 13 * k, weight: .bold))
                    .offset(x: x0 * k, y: 32 * k)
                // The current wallpaper's card
                RoundedRectangle(cornerRadius: 8 * k, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(width: 312 * k, height: 70 * k)
                    .offset(x: x0 * k, y: 56 * k)
                RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.6, blue: 0.35), Color(red: 0.55, green: 0.3, blue: 0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 86 * k, height: 54 * k)
                    .offset(x: (x0 + 8) * k, y: 64 * k)
                VStack(alignment: .leading, spacing: 6 * k) {
                    Capsule().fill(Color.primary.opacity(0.22)).frame(width: 90 * k, height: 6 * k)
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 130 * k, height: 5 * k)
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 70 * k, height: 5 * k)
                }
                .offset(x: (x0 + 106) * k, y: 74 * k)
                Text("Wallpapers")
                    .font(.system(size: 9.5 * k, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: x0 * k, y: 136 * k)
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4 * k, style: .continuous)
                        .fill(Self.swatch(i))
                        .frame(width: 56 * k, height: 36 * k)
                        .offset(x: (x0 + CGFloat(i % 5) * 64) * k, y: (152 + CGFloat(i / 5) * 46) * k)
                }
                screenSaverButton
            }
        }

        private var screenSaverButton: some View {
            let pressed = step == 1 && phase == .clicked
            let r = G.screenSaverButton
            return Text("Screen Saver\u{2026}")
                .font(.system(size: 9.5 * k, weight: .medium))
                .frame(width: r.width * k, height: r.height * k)
                .background(RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
                    .fill(pressed ? Color.primary.opacity(0.2) : Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: max(0.5, 0.6 * k)))
                .offset(x: r.minX * k, y: r.minY * k)
        }

        // MARK: Sheet

        private var sheet: some View {
            let s = G.sheet, v = G.viewport
            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 11 * k, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 12 * k, y: 5 * k)
                    .overlay(RoundedRectangle(cornerRadius: 11 * k, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: max(0.5, 0.8 * k)))
                    .frame(width: s.width * k, height: s.height * k)
                    .offset(x: s.minX * k, y: s.minY * k)
                list
                    .frame(width: v.width * k, height: v.height * k, alignment: .topLeading)
                    .clipped()
                    .offset(x: v.minX * k, y: v.minY * k)
                // Scroll indicator
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 3 * k, height: v.height * v.height / G.contentHeight * k)
                    .offset(x: (v.maxX + 4) * k, y: (v.minY + scroll * v.height / G.contentHeight) * k)
                Text("Done")
                    .font(.system(size: 9.5 * k, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: G.done.width * k, height: G.done.height * k)
                    .background(RoundedRectangle(cornerRadius: 6 * k, style: .continuous).fill(Color.accentColor))
                    .offset(x: G.done.minX * k, y: G.done.minY * k)
            }
        }

        private var list: some View {
            ZStack(alignment: .topLeading) {
                sectionHeader("macOS").offset(y: 0)
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
                        .fill(Self.swatch(i + 3))
                        .frame(width: G.tile.width * k, height: G.tile.height * k)
                        .offset(x: CGFloat(i % 3) * (G.tile.width + G.tileGap) * k,
                                y: (18 + CGFloat(i / 3) * G.rowPitch) * k)
                }
                sectionHeader("Other").offset(y: G.otherHeaderY * k)
                // A third-party saver, then DotStudio's own tile (its thumbnail, as Settings shows it)
                RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
                    .fill(LinearGradient(colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.3)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: G.tile.width * k, height: G.tile.height * k)
                    .offset(y: G.otherRowY * k)
                dotStudioTile
                    .offset(x: (G.tile.width + G.tileGap) * k, y: G.otherRowY * k)
            }
            .offset(y: -scroll * k)
        }

        private func sectionHeader(_ title: String) -> some View {
            Text(title)
                .font(.system(size: 10 * k, weight: .bold))
                .foregroundStyle(.primary)
        }

        private var dotStudioTile: some View {
            VStack(spacing: 3 * k) {
                Group {
                    if let img = SaverThumbnail.image {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(red: 0.05, green: 0.1, blue: 0.3), Color(red: 0.2, green: 0.9, blue: 0.55)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: G.tile.width * k, height: G.tile.height * k)
                .clipShape(RoundedRectangle(cornerRadius: 5 * k, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7 * k, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.2 * k)
                    .padding(-3 * k)
                    .opacity(dotStudioChosen ? 1 : 0))
                Text("DotStudio")
                    .font(.system(size: 8.5 * k, weight: dotStudioChosen ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(width: G.tile.width * k)
        }

        // MARK: Pointer and ring

        /// The ring around what this step clicks, once it's clicked.
        private var ring: some View {
            let r: CGRect
            var corner: CGFloat = 7
            switch step {
            case 0: r = G.wallpaperRow
            case 1: r = G.screenSaverButton
            case 2: r = G.otherHeader(scroll: G.scrollDistance); corner = 6
            default: r = G.dotStudioTile(scroll: G.scrollDistance).insetBy(dx: -4, dy: -4); corner = 9
            }
            let on = phase == .clicked
            return RoundedRectangle(cornerRadius: corner * k, style: .continuous)
                .strokeBorder(Color.orange, lineWidth: 2.4 * k)
                .frame(width: (r.width + 8) * k, height: (r.height + 8) * k)
                .scaleEffect(on ? 1 : 1.25)
                .opacity(on ? 1 : 0)
                .offset(x: (r.minX - 4) * k, y: (r.minY - 4) * k)
        }

        private var pointer: some View {
            let from = step == 0 ? G.rest : G.target(step - 1)
            let p = phase == .start ? from : G.target(step)
            return PointerShape()
                .fill(Color.black)
                .overlay(PointerShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.3 * k, lineJoin: .round)))
                .frame(width: 12 * k, height: 19 * k)
                .scaleEffect(phase == .clicked && step != 2 ? 0.9 : 1, anchor: .topLeading)
                .shadow(color: .black.opacity(0.3), radius: 1.5 * k, y: 1 * k)
                .offset(x: p.x * k, y: p.y * k)
        }

        static func swatch(_ i: Int) -> LinearGradient {
            let pairs: [(Color, Color)] = [
                (Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.1, green: 0.2, blue: 0.55)),
                (Color(red: 0.98, green: 0.62, blue: 0.4), Color(red: 0.85, green: 0.3, blue: 0.45)),
                (Color(red: 0.45, green: 0.35, blue: 0.85), Color(red: 0.2, green: 0.15, blue: 0.45)),
                (Color(red: 0.3, green: 0.75, blue: 0.7), Color(red: 0.1, green: 0.35, blue: 0.45)),
                (Color(red: 0.95, green: 0.8, blue: 0.45), Color(red: 0.8, green: 0.45, blue: 0.25)),
                (Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.75, green: 0.55, blue: 0.8)),
                (Color(red: 0.2, green: 0.45, blue: 0.35), Color(red: 0.08, green: 0.18, blue: 0.2)),
            ]
            let (a, b) = pairs[i % pairs.count]
            return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The classic arrow pointer, tip at the top-left corner of its frame (a 12 × 19 design box).
private struct PointerShape: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 12, sy = r.height / 19
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(0, 0))
        path.addLine(to: p(0, 16))
        path.addLine(to: p(4, 12.4))
        path.addLine(to: p(6.8, 18.6))
        path.addLine(to: p(9.4, 17.4))
        path.addLine(to: p(6.7, 11.4))
        path.addLine(to: p(11.6, 11.4))
        path.closeSubpath()
        return path
    }
}

/// DotStudio's tile picture in System Settings' list: the saver's own thumbnail.
enum SaverThumbnail {
    static let image: NSImage? = {
        guard let saver = Installer.bundledSaverURL else { return nil }
        let res = saver.appendingPathComponent("Contents/Resources")
        return NSImage(contentsOf: res.appendingPathComponent("thumbnail@2x.png"))
            ?? NSImage(contentsOf: res.appendingPathComponent("thumbnail.png"))
            ?? Bundle(url: saver)?.image(forResource: "thumbnail")
    }()
}
