//  SetupGuideCard.swift — the setup card: one design for the floating helper beside System
//  Settings (SetupGuidePanelView) and Settings › Screensaver (SetupSettingsSection).
//
//  Top to bottom: what's set up (one line), a picture of the current click in System Settings
//  (SettingsMock, SetupGuideWalkthrough.swift), the five clicks as a short list with the current
//  one highlighted, Back / Next, then the actions. In the panel the Guide Me coach
//  (SetupCoachViews.swift: CoachCard) sits under it and drives the current step; without it the
//  user steps through the pictures with Back / Next.

import SwiftUI

// MARK: - The five clicks

/// The clicks in System Settings, one short line each: a verb first, the thing to click in bold.
/// The same order as CoachStep (openWallpaper … clickDone), so a coach step's rawValue is its index.
enum SetupSteps {
    struct Step {
        /// Markdown: the on-screen label in bold.
        let line: String
        /// Where to look, under the current step's line.
        let hint: String
    }

    static let all: [Step] = [
        Step(line: "Click **Wallpaper**", hint: "In the sidebar."),
        Step(line: "Click **Screen Saver\u{2026}**", hint: "At the bottom of the page."),
        Step(line: "Scroll down to **Other**", hint: "Near the end of the list."),
        Step(line: "Click **DotStudio**", hint: "Under Other."),
        Step(line: "Click **Done**", hint: "That\u{2019}s it."),
    ]

    /// Also "every step done" when used as the current step.
    static var count: Int { all.count }

    static func plain(_ markdown: String) -> String { markdown.replacingOccurrences(of: "**", with: "") }
}

// MARK: - The card

/// What's set up, the current click's picture, the five clicks and the actions. Same look in
/// the floating panel and in Settings; only the actions differ (the panel adds Guide Me, Settings
/// adds Reinstall).
struct SetupCard: View {
    enum Context { case panel, settings }

    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.console) private var console
    @ObservedObject var guide: SetupGuideModel
    /// The coach marks (panel only); UI shots pass a pinned one.
    @ObservedObject var coach: SetupCoach
    var context: Context
    /// Installed / chosen, as the rest of the app shows it.
    var status: Installer.Status
    /// The picture beside the steps (a wide panel, Settings) instead of above them.
    var sideBySide = false
    /// UI shots: start on this step (0…4; 5 = all done).
    var frozenStep: Int?
    /// UI shots: the Reduce Motion picture (no pointer animation).
    var forceStill = false
    /// "Open System Settings".
    var onOpenSettings: () -> Void

    /// Back / Next's pick while the coach isn't driving (nil: follow the status).
    @State private var picked: Int?

    private var coaching: Bool { context == .panel && coach.mode == .coaching }

    /// The highlighted step, 0…4; `SetupSteps.count` when everything's done.
    private var current: Int {
        if coaching { return min(coach.shownStep.rawValue, SetupSteps.count) }
        if let picked { return picked }
        if let frozenStep { return min(max(frozenStep, 0), SetupSteps.count) }
        return status == .ready && !partial ? SetupSteps.count : 0
    }

    /// Chosen on some displays, not all.
    private var partial: Bool {
        if case .chosen(let on, let of) = guide.snapshot.choice { return on > 0 && on < of }
        return false
    }

    private var multiDisplay: Bool {
        if case .chosen(_, let of) = guide.snapshot.choice { return of > 1 }
        return false
    }

    private var gap: CGFloat { layout.cardPadding }

    /// The picture's widest when stacked: its labels are drawn at fixed sizes, so past this it
    /// only gets bigger, not clearer.
    static let maxPictureWidth: CGFloat = 480
    /// Its width beside the steps.
    static let sidePictureWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            statusHeader
            if sideBySide {
                HStack(alignment: .top, spacing: gap + Space.xs) {
                    // Its own height for that width (not squeezed to the steps' height).
                    picture.frame(width: Self.sidePictureWidth).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        stepList
                        navigation
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                picture.frame(maxWidth: Self.maxPictureWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    stepList
                    navigation
                }
            }
            actions
            if context == .panel && coach.mode != .off {
                CoachCard(coach: coach, guide: guide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.pick(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: current)
        .onChange(of: status) { _, _ in picked = nil }
        .onChange(of: coach.mode) { _, _ in picked = nil }
        .onAppear { if context == .panel { coach.refreshTrust() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screensaver setup")
    }

    // MARK: Status

    @ViewBuilder private var statusHeader: some View {
        if console {
            consoleStatusHeader
        } else {
            classicStatusHeader
        }
    }

    /// Console: the status as a module head — a coloured square with the glyph (green set up,
    /// amber to do, orange to install), the title in the display face, the line under it.
    private var consoleStatusHeader: some View {
        let (symbol, tint, title, detail) = headerContent
        let fill: Color = tint == .green ? ConsoleInk.green : tint == .orange ? ConsoleInk.amber : ConsoleInk.signal
        return HStack(alignment: .center, spacing: Space.s) {
            ConsoleIconSquare(symbol: Self.consoleGlyph(symbol), fill: fill)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textRole(.consoleHeadline).foregroundStyle(ConsoleInk.ink).wrapping()
                Text(detail).textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend).wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The header's circled glyph, bare (it sits on a square in Console).
    private static func consoleGlyph(_ symbol: String) -> String {
        switch symbol {
        case "arrow.down.circle.fill": return "arrow.down"
        case "exclamationmark.circle.fill": return "exclamationmark"
        case "info.circle.fill": return "info"
        case "checkmark.circle.fill": return "checkmark"
        default: return symbol
        }
    }

    private var classicStatusHeader: some View {
        let (symbol, tint, title, detail) = headerContent
        return HStack(alignment: .center, spacing: layout.itemGap) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 28, $0, weight: .semibold) }
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(title).textRole(.rowTitle).wrapping()
                Text(detail).textRole(.callout).foregroundStyle(.secondary).wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerContent: (String, Color, String, String) {
        if status == .notInstalled {
            return ("arrow.down.circle.fill", .accentColor, "Install the Screensaver",
                    "Then choose it in System Settings.")
        }
        if partial, case .chosen(let on, let of) = guide.snapshot.choice {
            return ("exclamationmark.circle.fill", .orange, "On \(on) of \(of) Displays",
                    "Pick the other display at the top of Wallpaper, then repeat.")
        }
        switch status {
        case .ready:
            if context == .panel, case .unknown = guide.snapshot.choice {
                return ("info.circle.fill", .accentColor, "Choose DotStudio",
                        "DotStudio can\u{2019}t check this. Follow the steps.")
            }
            let where_: String
            if case .chosen(_, let of) = guide.snapshot.choice, of > 1 {
                where_ = of == 2 ? "On both displays." : "On all \(of) displays."
            } else {
                where_ = "Chosen in System Settings \u{203A} Wallpaper."
            }
            return ("checkmark.circle.fill", .green, "DotStudio Is Your Screensaver", where_)
        default:
            return ("exclamationmark.circle.fill", .orange, "Choose DotStudio",
                    "Five clicks in System Settings.")
        }
    }

    // MARK: Picture

    private var picture: some View {
        let shown = min(current, SetupSteps.count - 1)
        let animate = frozenStep == nil && !forceStill && !reduceMotion && !OffscreenCapture.isActive
        return SetupStepPicture(step: shown, finished: current >= SetupSteps.count, animate: animate)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Picture of System Settings")
            .accessibilityValue(current >= SetupSteps.count
                                ? "All steps done"
                                : "Step \(shown + 1) of \(SetupSteps.count): \(SetupSteps.plain(SetupSteps.all[shown].line))")
            .accessibilityAddTraits(.isImage)
    }

    // MARK: Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SetupSteps.all.indices, id: \.self) { i in
                let row = SetupStepRow(number: i + 1, step: SetupSteps.all[i],
                                       hint: hint(i),
                                       state: i < current ? .done : i == current ? .current : .upcoming)
                if coaching {
                    row
                } else {
                    Button { picked = i } label: { row }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows this step\u{2019}s picture")
                }
            }
        }
        .overlay(alignment: .top) { if console { ConsoleHairline() } }
    }

    private func hint(_ i: Int) -> String {
        if i == SetupSteps.count - 1 && multiDisplay { return "Then do the same for each display." }
        return SetupSteps.all[i].hint
    }

    @ViewBuilder private var navigation: some View {
        if console {
            // Console: ‹ BACK and NEXT › keys, the step as a mono readout between them.
            HStack(spacing: layout.controlGap) {
                Button { go(-1) } label: { SetupKeyLabel(title: "Back", symbol: "chevron.left") }
                    .disabled(current == 0)
                    .accessibilityHint("Shows the previous step")
                Spacer(minLength: 0)
                Text(current >= SetupSteps.count ? "All done" : "Step \(current + 1) of \(SetupSteps.count)")
                    .textRole(.legend)
                    .foregroundStyle(ConsoleInk.legend)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { go(1) } label: { SetupKeyLabel(title: "Next", symbol: "chevron.right", trailing: true) }
                    .disabled(current >= SetupSteps.count - 1)
                    .accessibilityHint("Shows the next step")
            }
            .buttonStyle(.keycap(padding: HubMetrics.smallKey))
        } else {
            HStack(spacing: layout.controlGap) {
                Button { go(-1) } label: { Label("Back", systemImage: "chevron.left").textRole(.body) }
                    .disabled(current == 0)
                    .accessibilityHint("Shows the previous step")
                Spacer(minLength: 0)
                Text(current >= SetupSteps.count ? "All done" : "Step \(current + 1) of \(SetupSteps.count)")
                    .textRole(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { go(1) } label: {
                    Label("Next", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle()).textRole(.body)
                }
                .disabled(current >= SetupSteps.count - 1)
                .accessibilityHint("Shows the next step")
            }
            .buttonStyle(.bordered)
            .adaptiveControlSize()
        }
    }

    private func go(_ delta: Int) {
        if coaching {
            if delta < 0 { coach.back() } else { coach.skip() }
            return
        }
        picked = min(max(min(current, SetupSteps.count - 1) + delta, 0), SetupSteps.count - 1)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        let installed = status != .notInstalled
        // While the coach is pointing, its own row has the button that fits (CoachCard).
        if !installed || !coaching || context == .settings {
            VStack(alignment: .leading, spacing: layout.controlGap) {
                ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
                    if !installed {
                        Button { model.installScreensaver(); guide.refresh() } label: {
                            actionLabel("Install", symbol: "arrow.down.circle", consoleSymbol: "arrow.down")
                        }
                        .modifier(SetupActionStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Installs the DotStudio screensaver, then opens System Settings")
                    } else {
                        let open = Button(action: onOpenSettings) {
                            actionLabel("Open System Settings", symbol: "gearshape", consoleSymbol: "gearshape")
                        }
                        .help("Opens System Settings at Wallpaper, with this guide beside it")
                        .accessibilityHint("Opens System Settings at Wallpaper")
                        if status == .ready && !partial {
                            open.modifier(SetupActionStyle(prominent: false))
                        } else {
                            open.modifier(SetupActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
                        }
                        if context == .settings {
                            Button { model.installScreensaver() } label: { actionLabel("Reinstall") }
                                .modifier(SetupActionStyle(prominent: false))
                                .help("Installs a fresh copy of the screensaver")
                        }
                    }
                    if context == .panel && coach.mode == .off {
                        Button { coach.guideMe() } label: {
                            actionLabel("Guide Me", symbol: "hand.point.up.left", consoleSymbol: "hand.point.up.left")
                        }
                        .modifier(SetupActionStyle(prominent: false))
                        .help("Rings each button to click in System Settings")
                        .accessibilityHint("Points at the controls to click in System Settings")
                    }
                    Spacer(minLength: 0)
                }
                if context == .panel && coach.mode == .off {
                    Text(coach.trusted
                         ? "**Guide Me** rings each button in System Settings."
                         : "**Guide Me** rings each button in System Settings. It asks for Accessibility and only reads System Settings while this is open.")
                        .textRole(console ? .consoleBodySmall : .caption)
                        .foregroundStyle(console ? AnyShapeStyle(ConsoleInk.legend) : AnyShapeStyle(.secondary))
                        .wrapping()
                }
            }
        }
    }
}

extension SetupCard {
    /// An action's title: Classic's body-size Label (or Text); Console's key legend.
    @ViewBuilder
    fileprivate func actionLabel(_ title: String, symbol: String? = nil, consoleSymbol: String? = nil) -> some View {
        if console {
            SetupKeyLabel(title: title, symbol: consoleSymbol)
        } else if let symbol {
            Label(title, systemImage: symbol).textRole(.body)
        } else {
            Text(title).textRole(.body)
        }
    }
}

/// The card's action buttons: Classic's large bordered (prominent: filled) buttons; Console's
/// keys (prominent: the orange key).
private struct SetupActionStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.console) private var console

    func body(content: Content) -> some View {
        if console {
            content.buttonStyle(.keycap(prominent ? .signal : .plain))
        } else if prominent {
            content.buttonStyle(.borderedProminent).adaptiveControlSize(.large)
        } else {
            content.buttonStyle(.bordered).adaptiveControlSize(.large)
        }
    }
}

/// A Console key's legend: mono caps with an optional glyph before (or after) it.
private struct SetupKeyLabel: View {
    let title: String
    var symbol: String? = nil
    var trailing = false
    @ScaledLength(relativeTo: .caption) private var glyph: CGFloat = 10

    var body: some View {
        HStack(spacing: Space.xxs + 2) {
            if let symbol, !trailing { icon(symbol) }
            Text(title).textRole(.consoleKey).lineLimit(1)
            if let symbol, trailing { icon(symbol) }
        }
        .fixedSize()
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: glyph, weight: .bold)).accessibilityHidden(true)
    }
}

/// Next's label: the chevron after the word.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xxs) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - One step

private struct SetupStepRow: View {
    enum State { case done, current, upcoming }

    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .title3) private var disc: CGFloat = 26
    @ScaledLength(relativeTo: .body) private var square: CGFloat = 24
    @ScaledLength(relativeTo: .body) private var squareGlyph: CGFloat = 11
    let number: Int
    let step: SetupSteps.Step
    let hint: String
    let state: State

    var body: some View {
        if console {
            consoleBody
        } else {
            classicBody
        }
    }

    /// Console: a ruled row — a small square key with the number (orange for the current
    /// step, green with a tick once done, grey ahead), the line in the text face, the hint in
    /// the legend grey; the current row sits on the surface colour.
    private var consoleBody: some View {
        HStack(alignment: .center, spacing: Space.s) {
            consoleMarker
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(step.line))
                    .textRole(state == .current ? .consoleTitle : .consoleBody)
                    .foregroundStyle(state == .done ? ConsoleInk.legend : ConsoleInk.ink)
                    .wrapping()
                if state == .current {
                    Text(hint)
                        .textRole(.consoleBodySmall)
                        .foregroundStyle(ConsoleInk.legend)
                        .wrapping()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.xs)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(state == .current ? ConsoleInk.surface : .clear)
        )
        .overlay(alignment: .bottom) { ConsoleHairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(SetupSteps.plain(step.line))")
        .accessibilityValue(state == .done ? "Done" : state == .current ? "Current step. \(hint)" : "")
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }

    private var consoleMarker: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return ZStack {
            switch state {
            case .done:
                shape.fill(ConsoleInk.green)
                Image(systemName: "checkmark")
                    .font(.system(size: squareGlyph, weight: .bold))
                    .foregroundStyle(ConsoleInk.onSignal)
            case .current:
                shape.fill(ConsoleInk.signal)
                Text(String(format: "%02d", number)).textRole(.padNumber).foregroundStyle(ConsoleInk.onSignal)
            case .upcoming:
                shape.fill(ConsoleInk.keyFace)
                shape.strokeBorder(ConsoleInk.hairline, lineWidth: 1)
                Text(String(format: "%02d", number)).textRole(.padNumber).foregroundStyle(ConsoleInk.legend)
            }
        }
        .frame(width: square, height: square)
        .accessibilityHidden(true)
    }

    private var classicBody: some View {
        HStack(alignment: .center, spacing: layout.itemGap) {
            marker
            VStack(alignment: .leading, spacing: Space.xxs / 2) {
                Text(.init(step.line))
                    .textRole(state == .current ? .bodyLarge.weight(.medium) : .bodyLarge)
                    .foregroundStyle(state == .done ? .secondary : .primary)
                    .wrapping()
                if state == .current {
                    Text(hint)
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(Color.accentColor.opacity(state == .current ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(SetupSteps.plain(step.line))")
        .accessibilityValue(state == .done ? "Done" : state == .current ? "Current step. \(hint)" : "")
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }

    private var marker: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .scaledFont { .scaled(points: 12, $0, weight: .bold) }
                    .foregroundStyle(.white)
            case .current:
                Circle().fill(Color.accentColor)
                Text("\(number)")
                    .scaledFont { .scaled(points: 13, $0, weight: .bold, design: .rounded) }
                    .foregroundStyle(.white)
            case .upcoming:
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                Text("\(number)")
                    .scaledFont { .scaled(points: 13, $0, weight: .semibold, design: .rounded) }
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: disc, height: disc)
        .accessibilityHidden(true)
    }
}

// MARK: - The picture

/// The current click in the drawn System Settings (SettingsMock), on a soft backdrop. Plays the
/// pointer moving to the target and clicking, on a loop (held still under Reduce Motion and in
/// UI shots). With every step done, a check over the last picture.
struct SetupStepPicture: View {
    /// 0…4 (the mock's steps; 4 = Done).
    let step: Int
    var finished = false
    var animate = true

    @State private var phase: SettingsMock.Phase = .clicked
    @Environment(\.console) private var console

    var body: some View {
        if console {
            consoleBody
        } else {
            classicBody
        }
    }

    /// Console: the drawn System Settings in a recessed well (a screen's surround); done, a
    /// green square with a tick over it.
    private var consoleBody: some View {
        SettingsMock(step: step, phase: animate && !finished ? phase : .clicked)
            .padding(Space.s)
            .consoleWell(cornerRadius: 4)
            .overlay {
                if finished {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.panel.opacity(0.55))
                        Image(systemName: "checkmark")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(ConsoleInk.onSignal)
                            .frame(width: 64, height: 64)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.green))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    }
                    .transition(.opacity)
                }
            }
            .task(id: animate && !finished ? step : -1) { await loop() }
    }

    @ViewBuilder private var classicBody: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        SettingsMock(step: step, phase: animate && !finished ? phase : .clicked)
            .padding(Space.m)
            .background(
                shape.fill(LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.06)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
            .overlay {
                if finished {
                    ZStack {
                        shape.fill(.background.opacity(0.55))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    }
                    .transition(.opacity)
                }
            }
            .task(id: animate && !finished ? step : -1) { await loop() }
    }

    /// Pointer from the last target to this one, click, hold; again.
    private func loop() async {
        guard animate, !finished else { phase = .clicked; return }
        do {
            while !Task.isCancelled {
                phase = .start
                try await Task.sleep(for: .seconds(0.5))
                withAnimation(.easeInOut(duration: 0.85)) { phase = .moved }
                try await Task.sleep(for: .seconds(1.0))
                withAnimation(step == 2 ? .easeInOut(duration: 1.1) : .spring(response: 0.32, dampingFraction: 0.7)) {
                    phase = .clicked
                }
                try await Task.sleep(for: .seconds(2.8))
            }
        } catch {}
    }
}

// MARK: - Settings › Screensaver

/// Settings › Screensaver's setup section: the setup card in the Form's group.
struct SetupSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject private var guide = SetupGuideModel.shared

    var body: some View {
        Section {
            SetupCard(guide: guide, coach: .shared, context: .settings, status: model.setupStatus,
                      sideBySide: !layout.prefersStacking) {
                // The floating guide keeps the steps beside System Settings; it opens first so
                // System Settings comes up in front of everything else.
                SetupGuidePanel.shared.show(model: model)
                guide.openSystemSettings()
            }
            .padding(.vertical, Space.xs)
            .onAppear {
                guide.onStatusChange = { [weak model] _ in model?.refreshSetupStatus() }
                guide.begin()
            }
            .onDisappear { guide.end() }
        } header: {
            SettingsHeader("Screensaver")
        } footer: {
            SettingsNote(model.setupStatus == .notInstalled
                         ? "Install adds DotStudio to your screen savers. Then choose it in System Settings."
                         : "Reinstall if the screensaver looks out of date. macOS picks up the new copy the next time it starts.")
        }
    }
}
