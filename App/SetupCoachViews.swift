//  SetupCoachViews.swift — what the setup coach draws (SetupCoach.swift): the glowing ring
//  and its callout over System Settings (CoachMarkView, in the click-through overlay), and the
//  guide panel's coach card (offer · waiting for permission · the live step · all set).
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

/// Top of the guide panel: offers the coach, waits for permission, or shows the live step.
struct CoachCard: View {
    @Environment(\.layout) private var layout
    @ObservedObject var coach: SetupCoach
    @ObservedObject var guide: SetupGuideModel

    var body: some View {
        Group {
            switch coach.mode {
            case .off: offer
            case .waitingForPermission: waiting
            case .coaching: coaching
            }
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22)))
        .accessibilityElement(children: .contain)
        .onAppear { coach.refreshTrust() }
    }

    // MARK: Offer

    private var offer: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                icon("hand.point.up.left.fill")
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text("Guide Me in System Settings").textRole(.headline).wrapping()
                    Text(coach.trusted
                         ? "DotStudio points at each button in System Settings and moves on as you click."
                         : "DotStudio points at each button in System Settings and moves on as you click. macOS asks once for Accessibility permission, so DotStudio can see where the buttons are \u{2014} it only reads System Settings, and only while this guide is open.")
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            HStack {
                Spacer(minLength: 0)
                let button = Button { coach.guideMe() } label: { Text("Guide Me").textRole(.body) }
                    .adaptiveControlSize(.large)
                    .accessibilityHint("Points at the controls to click in System Settings")
                if guide.snapshot.status == .ready {
                    button.buttonStyle(.bordered)
                } else {
                    button.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Waiting for permission

    private var waiting: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                icon("lock.shield")
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    HStack(spacing: layout.controlGap) {
                        Text("Waiting for permission").textRole(.headline).wrapping()
                        ProgressView().controlSize(.small)
                    }
                    Text("In the window macOS showed, click Open System Settings, then turn on DotStudio under Accessibility. The guide starts by itself.")
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
                Button { coach.openAccessibilitySettings() } label: { Text("Open Accessibility Settings\u{2026}").textRole(.body) }
                    .buttonStyle(.link)
                    .accessibilityHint("Opens System Settings at Privacy & Security, Accessibility")
                Spacer(minLength: 0)
                Button { coach.useIllustratedGuide() } label: { Text("Use the Picture Instead").textRole(.body) }
                    .buttonStyle(.bordered)
                    .adaptiveControlSize()
            }
        }
    }

    // MARK: Coaching

    private var step: CoachStep { coach.shownStep }
    private var manual: Bool { coach.override != nil }

    @ViewBuilder private var coaching: some View {
        if step == .finished {
            finished
        } else {
            VStack(alignment: .leading, spacing: layout.itemGap) {
                HStack(alignment: .top, spacing: layout.itemGap) {
                    StepBadge(number: step.walkthroughStep + 1)
                    VStack(alignment: .leading, spacing: layout.labelGap) {
                        Text("Step \(step.walkthroughStep + 1) of 4").textRole(.eyebrow).foregroundStyle(.secondary)
                        Text(title).textRole(.headline).wrapping()
                        Text(.init(detail)).textRole(.callout).foregroundStyle(.secondary).wrapping()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let status = statusLine {
                    Label { Text(status).textRole(.caption).wrapping() } icon: {
                        Image(systemName: statusSymbol)
                    }
                    .foregroundStyle(coach.degraded || manual ? Color.secondary : Color.accentColor)
                    .accessibilityElement(children: .combine)
                }
                if showsPicture {
                    SetupWalkthrough(frozenStep: step.walkthroughStep, narrow: true)
                }
                actionRow
            }
            .animation(.easeOut(duration: 0.2), value: step)
        }
    }

    private var title: String {
        switch coach.decision.situation {
        case .settingsClosed where !manual: return "Open System Settings"
        case .elsewhere where !manual: return "Go Back to Wallpaper"
        case .otherDisplay where !manual && step == .openChooser: return "Now Your Other Display"
        default: return step.title
        }
    }

    private var detail: String {
        if !manual {
            switch coach.decision.situation {
            case .settingsClosed:
                return "System Settings isn't open. Open it at Wallpaper and the guide picks up where you are."
            case .elsewhere:
                return "System Settings is showing another page. Click **Wallpaper** in its sidebar, or use the button below."
            case .otherDisplay where step == .openChooser:
                if case .chosen(let on, let of) = guide.snapshot.choice {
                    return "DotStudio is on \(on) of \(of) displays. At the top of the Wallpaper page, pick the other display, then click **Screen Saver\u{2026}** again."
                }
            default: break
            }
        }
        switch step {
        case .openWallpaper: return "In System Settings, click **Wallpaper** in the sidebar."
        case .openChooser: return "Click **Screen Saver\u{2026}** at the bottom of the Wallpaper page."
        case .scrollToTile: return "Scroll down the screen savers to the **Other** section."
        case .chooseTile: return "Click **DotStudio** under Other."
        case .clickDone: return "DotStudio is chosen. Click **Done** to close the screen savers."
        case .finished: return ""
        }
    }

    private var statusLine: String? {
        if manual { return "You moved ahead of the guide \u{2014} it follows again when you click in System Settings." }
        if coach.degraded {
            if let d = coach.lastDump { return "DotStudio can't find this on screen, so here's the picture. (Saved what it sees to \(d).)" }
            return "DotStudio can't find this on screen \u{2014} the picture shows where it is."
        }
        if coach.decision.situation == .settingsClosed { return nil }
        if coach.ringShown { return "Look for the glowing ring in System Settings." }
        if coach.decision.target != nil { return "Bring System Settings to the front to see where to click." }
        return "Looking for it in System Settings\u{2026}"
    }

    private var statusSymbol: String {
        if manual { return "hand.raised" }
        if coach.degraded { return "photo" }
        return coach.ringShown ? "scope" : "magnifyingglass"
    }

    /// The illustrated step: when the coach can't point, or the user stepped away from it.
    private var showsPicture: Bool { coach.degraded || manual }

    private var actionRow: some View {
        ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
            HStack(spacing: layout.controlGap) {
                Button { coach.back() } label: { Label("Back", systemImage: "chevron.left").textRole(.body) }
                    .disabled(step == .openWallpaper)
                    .accessibilityHint("Shows the previous step")
                Button { coach.skip() } label: { Label("Skip", systemImage: "chevron.right").textRole(.body) }
                    .disabled(step >= .clickDone)
                    .accessibilityHint("Shows the next step")
            }
            .buttonStyle(.bordered)
            .adaptiveControlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: layout.controlGap) {
                Button { coach.useIllustratedGuide() } label: { Text("Stop Guiding").textRole(.body) }
                    .buttonStyle(.link)
                    .accessibilityHint("Turns off the pointers and shows the picture guide")
                if !manual && coach.decision.situation == .settingsClosed {
                    Button { coach.reopenWallpaper() } label: { Text("Open System Settings").textRole(.body) }
                        .buttonStyle(.borderedProminent)
                        .adaptiveControlSize()
                } else if !manual && coach.decision.situation == .elsewhere {
                    Button { coach.reopenWallpaper() } label: { Text("Go Back to Wallpaper").textRole(.body) }
                        .buttonStyle(.borderedProminent)
                        .adaptiveControlSize()
                        .accessibilityHint("Opens System Settings at Wallpaper")
                }
            }
            .fixedSize()
        }
    }

    // MARK: All set

    private var finished: some View {
        let s = guide.snapshot
        let conflicts = s.displaySleepConflicts
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont { .scaled(points: 26, $0, weight: .semibold) }
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: coach.decision.step)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text("DotStudio Is Your Screensaver").textRole(.headline).wrapping()
                    Text(chosenWhere(s)).textRole(.callout).foregroundStyle(.secondary).wrapping()
                }
            }
            if !s.startsWhenInactive {
                attention("\u{201C}Start Screen Saver when inactive\u{201D} is set to Never, so it won't start on its own. Pick a time in Lock Screen settings.")
            } else if !conflicts.isEmpty {
                attention("Your display turns off before the screensaver starts (\(conflicts.map { "on \($0.source) after \(SetupWords.short(seconds: $0.minutes * 60))" }.joined(separator: ", "))). Set it later than \(SetupWords.short(seconds: s.effectiveIdle)) in Lock Screen settings.")
            } else {
                Text("It starts after \(SetupWords.duration(seconds: s.effectiveIdle)) of inactivity. Nothing else to do.")
                    .textRole(.callout).foregroundStyle(.secondary).wrapping()
            }
            HStack {
                Spacer(minLength: 0)
                Button { coach.useIllustratedGuide() } label: { Text("Stop Guiding").textRole(.body) }
                    .buttonStyle(.link)
            }
        }
    }

    private func chosenWhere(_ s: SetupSnapshot) -> String {
        if case .chosen(let on, let of) = s.choice, of > 1 {
            return on >= of ? (of == 2 ? "On both displays." : "On all \(of) displays.") : "On \(on) of \(of) displays."
        }
        return "Chosen in System Settings \u{203A} Wallpaper."
    }

    private func attention(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: layout.controlGap) {
            Label { Text(text).textRole(.callout).wrapping() } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button { SystemSettingsLink.openLockScreen() } label: { Text("Lock Screen Settings\u{2026}").textRole(.body) }
                .buttonStyle(.link)
                .accessibilityHint("Opens System Settings at Lock Screen")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .scaledFont { .scaled(points: 20, $0, weight: .medium) }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

/// A step's number in an accent disc (the walkthrough's style).
private struct StepBadge: View {
    @ScaledLength(relativeTo: .headline) private var size: CGFloat = 26
    let number: Int

    var body: some View {
        Text("\(number)")
            .scaledFont { .scaled(points: 13, $0, weight: .bold, design: .rounded) }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor))
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
