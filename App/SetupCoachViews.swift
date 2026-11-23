//  SetupCoachViews.swift — what the setup coach draws (SetupCoach.swift): the glowing ring
//  and its callout over System Settings (CoachMarkView, in the click-through overlay), and the
//  guide panel's coach card (waiting for permission · what the coach sees · all set).
//  CoachOverlayPreview stands in for System Settings in UI shots (Shots.swift: coach-*).

import SwiftUI

// MARK: - Ring + callout (the overlay)

struct CoachMarkView: View {
    @ObservedObject var model: CoachOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calloutSize = CGSize(width: 220, height: 40)

    /// The ring sits this far outside the control.
    static let pad: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let target = model.ring {
                    let ring = target.insetBy(dx: -Self.pad, dy: -Self.pad)
                    if !model.celebrate {
                        ringView(ring).transition(.opacity)
                    }
                    let placed = CoachGeometry.callout(ring: ring, size: calloutSize,
                                                       bounds: CGRect(origin: .zero, size: geo.size))
                    callout
                        .fixedSize()
                        .background(GeometryReader { g in Color.clear.preference(key: CalloutSizeKey.self, value: g.size) })
                        .position(x: placed.frame.midX, y: placed.frame.midY)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onPreferenceChange(CalloutSizeKey.self) { calloutSize = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: model.step)
        .animation(.easeOut(duration: 0.2), value: model.celebrate)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tint: Color { model.celebrate ? .green : .accentColor }

    private func corner(_ r: CGRect) -> CGFloat {
        model.kind == .area ? 14 : min(12, r.height / 2)
    }

    private func ringView(_ r: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner(r), style: .continuous)
        let area = model.kind == .area
        let animate = !reduceMotion && !OffscreenCapture.isActive
        return ZStack {
            // A faint wash inside a control's ring (not over a whole list).
            shape.fill(tint.opacity(area ? 0 : 0.10))
            // The pulse: an outer ring that grows and fades every 1.4 s, driven by the clock so
            // every new ring pulses (none under Reduce Motion, or in UI shots).
            if animate {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - (1 - t) * (1 - t)
                    shape.stroke(tint.opacity(0.55), lineWidth: 2)
                        .padding(-CGFloat(eased) * 9)
                        .opacity(0.85 * (1 - eased))
                }
            }
            shape.stroke(tint, style: StrokeStyle(lineWidth: area ? 2.5 : 3, dash: area ? [9, 6] : []))
                .shadow(color: tint.opacity(0.75), radius: 6)
                .shadow(color: tint.opacity(0.35), radius: 16)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    private var callout: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                Circle().fill(tint)
                if model.celebrate {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else {
                    Text("\(model.step)").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            Text(model.callout)
                .textRole(.bodyEmphasis)
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if model.kind == .area && !model.celebrate {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.leading, Space.xs)
        .padding(.trailing, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct CalloutSizeKey: PreferenceKey {
    static var defaultValue = CGSize(width: 220, height: 40)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - The panel's coach card

/// Under the setup card in the guide panel (SetupGuideCard.swift), once Guide Me was clicked:
/// waits for permission, or says what the coach sees. The step itself (its line and picture) is the card's.
struct CoachCard: View {
    @Environment(\.layout) private var layout
    @ObservedObject var coach: SetupCoach
    @ObservedObject var guide: SetupGuideModel

    var body: some View {
        Group {
            switch coach.mode {
            case .off: EmptyView()   // the setup card offers Guide Me
            case .waitingForPermission: waiting
            case .coaching: coaching
            }
        }
        .padding(layout.itemGap + Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22)))
        .accessibilityElement(children: .contain)
    }

    // MARK: Waiting for permission

    private var waiting: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                icon("lock.shield")
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    HStack(spacing: layout.controlGap) {
                        Text("Waiting for Permission").textRole(.headline).wrapping()
                        ProgressView().controlSize(.small)
                    }
                    Text("Turn on DotStudio in Privacy & Security \u{203A} Accessibility. The guide starts by itself.")
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                    Text("Already listed? Remove it with \u{2212}, then add it again.")
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
                Button { coach.openAccessibilitySettings() } label: { Text("Accessibility Settings\u{2026}").textRole(.body) }
                    .buttonStyle(.link)
                    .accessibilityHint("Opens System Settings at Privacy & Security, Accessibility")
                Spacer(minLength: 0)
                Button { coach.useIllustratedGuide() } label: { Text("Just Show Pictures").textRole(.body) }
                    .buttonStyle(.bordered)
                    .adaptiveControlSize()
                    .accessibilityHint("Skips the pointer; step through the pictures instead")
            }
        }
    }

    // MARK: Coaching

    private var step: CoachStep { coach.shownStep }
    private var manual: Bool { coach.override != nil }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                icon(step == .finished ? "checkmark.seal.fill" : statusSymbol)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(headline).textRole(.headline).wrapping()
                    if let line = statusLine {
                        Text(.init(line)).textRole(.callout).foregroundStyle(.secondary).wrapping()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
                primaryButton
                Spacer(minLength: 0)
                Button { coach.useIllustratedGuide() } label: { Text("Stop Guiding").textRole(.body) }
                    .buttonStyle(.link)
                    .accessibilityHint("Turns off the pointer; step through the pictures instead")
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }

    /// What the coach sees, in a few words.
    private var headline: String {
        if step == .finished { return "All Set" }
        if manual { return "Guide Paused" }
        if coach.accessibilityOff { return "Accessibility Is Off" }
        switch coach.decision.situation {
        case .settingsClosed: return "System Settings Is Closed"
        case .elsewhere: return "Go Back to Wallpaper"
        case .otherDisplay where step == .openChooser: return "Now Your Other Display"
        default: break
        }
        if coach.blockedByGuide || coach.degraded { return "Use the Picture" }
        return coach.ringShown ? "Follow the Ring" : "Looking in System Settings\u{2026}"
    }

    private var statusLine: String? {
        if step == .finished { return "DotStudio stops reading System Settings now." }
        if manual { return "You moved ahead. The ring follows your next click." }
        if coach.accessibilityOff {
            return "So there\u{2019}s no ring. Turn DotStudio on in Privacy & Security \u{203A} Accessibility (listed already? Remove it with \u{2212} and add it again)."
        }
        switch coach.decision.situation {
        case .settingsClosed: return "Open it and the guide picks up where you are."
        case .elsewhere: return "System Settings is on another page."
        case .otherDisplay where step == .openChooser:
            if case .chosen(let on, let of) = guide.snapshot.choice {
                return "Done on \(on) of \(of). Pick the other display at the top of Wallpaper, then click **Screen Saver\u{2026}**."
            }
        default: break
        }
        if coach.blockedByGuide { return "This guide covers it. Move the guide aside to see the ring." }
        if coach.degraded {
            if let d = coach.lastDump { return "Can\u{2019}t find it on screen. (Saved what it sees to \(d).)" }
            return "Can\u{2019}t find it on screen. The picture above shows where it is."
        }
        if coach.ringShown { return "A glowing ring marks where to click." }
        if coach.decision.target != nil { return "Bring System Settings to the front." }
        return nil
    }

    private var statusSymbol: String {
        if manual { return "hand.raised" }
        if coach.accessibilityOff { return "lock.shield" }
        switch coach.decision.situation {
        case .settingsClosed, .elsewhere: return "gearshape"
        case .otherDisplay: return "display.2"
        case .normal: break
        }
        if coach.degraded { return "photo" }
        return coach.ringShown ? "scope" : "magnifyingglass"
    }

    @ViewBuilder private var primaryButton: some View {
        if coach.accessibilityOff {
            Button { coach.openAccessibilitySettings() } label: { Text("Accessibility Settings\u{2026}").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .adaptiveControlSize()
                .accessibilityHint("Opens System Settings at Privacy & Security, Accessibility")
        } else if !manual && coach.decision.situation == .settingsClosed && step != .finished {
            Button { coach.reopenWallpaper() } label: { Text("Open System Settings").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .adaptiveControlSize()
                .accessibilityHint("Opens System Settings at Wallpaper")
        } else if !manual && coach.decision.situation == .elsewhere {
            Button { coach.reopenWallpaper() } label: { Text("Go Back to Wallpaper").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .adaptiveControlSize()
                .accessibilityHint("Opens System Settings at Wallpaper")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .scaledFont { .scaled(points: 20, $0, weight: .medium) }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(step == .finished && coach.mode == .coaching ? Color.green : Color.accentColor)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

// MARK: - UI shots: the overlay over a stand-in for System Settings

/// A plain sketch of a Settings window (no Apple artwork) under the real CoachMarkView, so
/// the ring and callout can be reviewed offscreen. Coordinates are the sketch's own.
struct CoachOverlayPreview: View {
    enum Scene: String, CaseIterable { case button, tile, scroll, done, edge, celebrate, sidebar }
    let scene: Scene
    static let size = CGSize(width: 960, height: 640)

    private static let window = CGRect(x: 120, y: 60, width: 720, height: 520)
    private static let sheet = CGRect(x: 200, y: 100, width: 560, height: 440)
    private static let list = CGRect(x: 200, y: 150, width: 560, height: 330)

    private var model: CoachOverlayModel {
        let m = CoachOverlayModel()
        switch scene {
        case .button: m.ring = CGRect(x: 690, y: 528, width: 120, height: 24); m.callout = "Click Screen Saver\u{2026}"; m.step = 2
        case .sidebar: m.ring = CGRect(x: 132, y: 296, width: 186, height: 26); m.callout = "Click Wallpaper"; m.step = 1
        case .scroll: m.ring = Self.list; m.kind = .area; m.callout = "Scroll down to Other"; m.step = 3
        case .tile: m.ring = CGRect(x: 352, y: 333, width: 104, height: 80); m.callout = "Click DotStudio"; m.step = 4
        case .done: m.ring = CGRect(x: 676, y: 500, width: 64, height: 24); m.callout = "Click Done"; m.step = 4
        case .edge: m.ring = CGRect(x: 690, y: 588, width: 120, height: 24); m.callout = "Click Screen Saver\u{2026}"; m.step = 2
        case .celebrate: m.ring = CGRect(x: 676, y: 500, width: 64, height: 24); m.callout = "DotStudio is your screensaver"; m.step = 4; m.celebrate = true
        }
        return m
    }

    private var sheetOpen: Bool { [.scroll, .tile, .done, .celebrate].contains(scene) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.62), Color(red: 0.62, green: 0.45, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            settingsSketch
            CoachMarkView(model: model)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var settingsSketch: some View {
        let w = scene == .edge ? CGRect(x: 120, y: 120, width: 720, height: 520) : Self.window
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                .frame(width: w.width, height: w.height)
                .offset(x: w.minX, y: w.minY)
            // Sidebar
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 200, height: w.height - 20)
                .offset(x: w.minX + 8, y: w.minY + 10)
            ForEach(0..<12, id: \.self) { i in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25 + Double(i % 4) * 0.15)).frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.18)).frame(width: CGFloat(60 + (i * 37) % 70), height: 8)
                }
                .offset(x: w.minX + 20, y: w.minY + 60 + CGFloat(i) * 30)
            }
            // Page
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                .frame(width: 220, height: 130).offset(x: w.minX + 240, y: w.minY + 70)
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1))
                    .frame(width: 130, height: 80)
                    .offset(x: w.minX + 240 + CGFloat(i % 3) * 145, y: w.minY + 230 + CGFloat(i / 3) * 95)
            }
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.12))
                .frame(width: 120, height: 24)
                .overlay(Text("Screen Saver\u{2026}").font(.system(size: 12)))
                .offset(x: w.maxX - 150, y: w.maxY - 52)
            if sheetOpen { sheetSketch }
        }
    }

    private var sheetSketch: some View {
        let s = Self.sheet
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.15).frame(width: Self.window.width, height: Self.window.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .offset(x: Self.window.minX, y: Self.window.minY)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .frame(width: s.width, height: s.height)
                .offset(x: s.minX, y: s.minY)
            Text("Other").font(.system(size: 13, weight: .semibold)).offset(x: s.minX + 24, y: 300)
            ForEach(0..<4, id: \.self) { i in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == 1 ? Color(red: 0.1, green: 0.12, blue: 0.2) : Color.primary.opacity(0.12))
                        .frame(width: 100, height: 56)
                    Text(["Arabesque", "DotStudio", "Flurry", "Shell"][i]).font(.system(size: 11))
                }
                .offset(x: s.minX + 24 + CGFloat(i) * 130, y: 335)
            }
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                .frame(width: 60, height: 22)
                .overlay(Text("Done").font(.system(size: 12, weight: .medium)).foregroundStyle(.white))
                .offset(x: 678, y: 501)
        }
    }
}
