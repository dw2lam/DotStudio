//  SetupGuideChecklist.swift — the guided setup's live checklist (installed, chosen, starts
//  when inactive, display sleep, open at login, music permission), the onboarding step's
//  "Open System Settings" button, and the floating panel's content (SetupGuidePanelView: the
//  setup card from SetupGuideCard.swift over the checklist). State: SetupGuide.swift.
//  Console (\.console, injected by SetupGuidePanel): the checklist as ruled rows with square
//  status marks, keys for its actions, a Console switch for Open at login, and Done as a key.

import SwiftUI

// MARK: - Open System Settings

/// "Open System Settings" — the prominent, Return-key button while choosing DotStudio is
/// what's left to do. Used by the guide and the onboarding "Turn It On" step.
struct SetupOpenSettingsButton: View {
    @ObservedObject var guide: SetupGuideModel
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label("Open System Settings", systemImage: "gearshape")
                .textRole(.body)
        }
        .adaptiveControlSize(.large)
        .help("Opens System Settings at Wallpaper — the guide stays on top while you follow it")
        .accessibilityHint("Opens System Settings at Wallpaper")
        if guide.snapshot.status == .notChosen {
            // Return opens it while choosing DotStudio is what's left to do.
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

// MARK: - Checklist

struct SetupChecklist: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ObservedObject var guide: SetupGuideModel
    @ObservedObject private var music = MusicNow.shared
    var commitPhrase: String
    /// The coach is pointing in System Settings: the wording follows.
    var coaching = false
    /// The install row's own Install button (the setup card has one above it).
    var showsInstallButton = true

    private var s: SetupSnapshot { guide.snapshot }

    var body: some View {
        let rows = self.rows
        let done = rows.filter { $0 == .done }.count
        VStack(alignment: .leading, spacing: console ? Space.xs : layout.controlGap) {
            HStack(alignment: .firstTextBaseline) {
                if console {
                    // Console: a printed legend over the ruled list, the count as a readout.
                    Text("Checklist").textRole(.legend).foregroundStyle(ConsoleInk.legend)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Text("Checklist").textRole(.headline)
                }
                Spacer(minLength: layout.controlGap)
                Text("\(done) of \(rows.count) done")
                    .textRole(console ? .legend : .caption)
                    .foregroundStyle(console ? AnyShapeStyle(done == rows.count ? ConsoleInk.ink : ConsoleInk.legend)
                                             : AnyShapeStyle(.secondary))
                    .accessibilityLabel("\(done) of \(rows.count) items done")
            }
            let list = VStack(spacing: 0) {
                installRow
                chooseRow
                idleRow
                if showsSleepRow { sleepRow }
                loginRow
                if showsMusicRow { musicRow }
            }
            if console {
                list.overlay(alignment: .top) { ConsoleHairline() }
            } else {
                list
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            }
            Text("Ticks itself as you go.")
                .textRole(console ? .consoleBodySmall : .caption)
                .foregroundStyle(console ? AnyShapeStyle(ConsoleInk.legend) : AnyShapeStyle(.secondary))
                .wrapping()
        }
        .animation(.easeOut(duration: 0.2), value: s)
    }

    /// Every shown row's state, for the "n of m done" count.
    private var rows: [ChecklistState] {
        var r = [installState, chooseState, idleState]
        if showsSleepRow { r.append(sleepState) }
        r.append(loginState)
        if showsMusicRow { r.append(musicState) }
        return r
    }

    // MARK: a. Installed

    private var installState: ChecklistState { s.installed ? .done : .todo }

    private var installRow: some View {
        ChecklistRow(state: installState, first: true,
                     title: s.installed ? "Screensaver installed" : "Install the screensaver",
                     detail: s.installed ? "DotStudio is in your screen savers."
                                         : "Adds DotStudio, then opens System Settings.") {
            if !s.installed && showsInstallButton {
                Button { model.installScreensaver(); guide.refresh() } label: { ChecklistKeyLabel(title: "Install", classicRole: .body) }
                    .modifier(ChecklistActionStyle(classic: .prominent, consoleTint: .signal))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Installs the DotStudio screensaver")
            }
        }
    }

    // MARK: b. Chosen

    private var chooseState: ChecklistState {
        guard s.installed else { return .todo }
        switch s.choice {
        case .unknown: return .info
        case .chosen(let on, let of): return on == 0 ? .todo : on < of ? .warning : .done
        }
    }

    private var chooseRow: some View {
        let title: String
        let detail: String
        switch s.choice {
        case .chosen(let on, let of) where s.installed && on > 0 && on < of:
            title = "Chosen on \(on) of \(of) displays"
            detail = "Pick the next display at the top of Wallpaper, then choose DotStudio."
        case .chosen(let on, let of) where s.installed && on > 0:
            title = "DotStudio is your screensaver"
            detail = of == 2 ? "On both displays." : of > 2 ? "On all \(of) displays." : "Set in System Settings › Wallpaper."
        case .unknown where s.installed:
            title = "Choose DotStudio as your screensaver"
            detail = coaching ? "Can't check this here. Follow the ring."
                              : "Can't check this here. Follow the steps."
        default:
            title = "Choose DotStudio as your screensaver"
            if coaching {
                detail = s.installed ? "Follow the ring in System Settings." : "Install first, then follow the ring."
            } else {
                detail = s.installed ? "Follow the steps above." : "Install first, then follow the steps."
            }
        }
        return ChecklistRow(state: chooseState, title: title, detail: detail) { EmptyView() }
    }

    // MARK: c. Starts when inactive

    private var idleState: ChecklistState { s.startsWhenInactive ? .done : .warning }

    private var idleRow: some View {
        let title: String
        let detail: String
        if s.startsWhenInactive {
            title = "Starts after \(SetupWords.duration(seconds: s.effectiveIdle)) of inactivity"
            detail = s.idleSeconds == nil
                ? "macOS default. Change it in Lock Screen settings."
                : "Change it in Lock Screen settings."
        } else {
            title = "Screensaver never starts on its own"
            detail = "Set \u{201C}Start Screen Saver when inactive\u{201D} in Lock Screen settings."
        }
        return ChecklistRow(state: idleState, title: title, detail: detail) {
            if !s.startsWhenInactive { lockScreenLink }
        }
    }

    private var lockScreenLink: some View {
        Button { SystemSettingsLink.openLockScreen() } label: { ChecklistKeyLabel(title: "Lock Screen Settings\u{2026}") }
            .modifier(ChecklistActionStyle(classic: .link))
            .accessibilityHint("Opens System Settings at Lock Screen")
    }

    // MARK: d. Display sleep

    /// Only once the screensaver starts on its own and the timers could be read.
    private var showsSleepRow: Bool { s.startsWhenInactive && s.displaySleep != nil }
    private var sleepState: ChecklistState { s.displaySleepConflicts.isEmpty ? .done : .warning }

    private var sleepRow: some View {
        let conflicts = s.displaySleepConflicts
        let idle = SetupWords.short(seconds: s.effectiveIdle)
        let title: String
        let detail: String
        if conflicts.isEmpty {
            title = "Your display stays on for it"
            detail = sleepSummary.map { "It turns off after \($0), once the screensaver is on." }
                ?? "Your display never turns off on its own."
        } else {
            title = "Your display turns off first"
            if conflicts.count == 2 && conflicts[0].minutes == conflicts[1].minutes {
                detail = "It turns off after \(SetupWords.short(seconds: conflicts[0].minutes * 60)); the screensaver starts at \(idle)."
            } else {
                detail = conflicts.map { "On \($0.source): off after \(SetupWords.short(seconds: $0.minutes * 60)); the screensaver starts at \(idle)." }
                    .joined(separator: " ")
            }
        }
        return ChecklistRow(state: sleepState, title: title, detail: detail) {
            if !conflicts.isEmpty { lockScreenLink }
        }
    }

    /// "10 min", or "2 min on battery, 10 min on power adapter".
    private var sleepSummary: String? {
        guard let t = s.displaySleep else { return nil }
        let parts = [(t.battery, "on battery"), (t.ac, "on power adapter")].compactMap { v, w -> (Int, String)? in
            guard let v, v > 0 else { return nil }
            return (v, w)
        }
        if parts.isEmpty { return nil }
        if parts.count == 2 && parts[0].0 == parts[1].0 || parts.count == 1 && !t.hasBattery {
            return SetupWords.short(seconds: parts[0].0 * 60)
        }
        return parts.map { "\(SetupWords.short(seconds: $0.0 * 60)) \($0.1)" }.joined(separator: ", ")
    }

    // MARK: e. Open at login

    private var loginState: ChecklistState {
        switch s.login {
        case .enabled: return guide.wantsLogin ? .done : .info
        case .requiresApproval: return .warning
        case .off: return guide.wantsLogin ? .pending : .info
        }
    }

    private var loginRow: some View {
        let detail: String
        switch s.login {
        case .requiresApproval:
            detail = "Turn DotStudio on in General › Login Items."
        case .enabled where !guide.wantsLogin, .off where guide.wantsLogin:
            detail = "Keeps your wallpaper and music going after a restart. Applies \(commitPhrase)."
        default:
            detail = "Keeps your wallpaper and music going after a restart."
        }
        return ChecklistRow(state: loginState, title: "Open DotStudio at login", detail: detail) {
            if console {
                ConsoleSwitch(isOn: $guide.wantsLogin)
                    .accessibilityLabel("Open DotStudio at login")
            } else {
                Toggle("Open DotStudio at login", isOn: $guide.wantsLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .adaptiveControlSize(.small)
                    .accessibilityLabel("Open DotStudio at login")
            }
        } extra: {
            if s.login == .requiresApproval {
                Button { LoginItem.openLoginItemsSettings() } label: { ChecklistKeyLabel(title: "Open Login Items\u{2026}") }
                    .modifier(ChecklistActionStyle(classic: .link))
                    .accessibilityHint("Opens System Settings at Login Items")
            } else if let e = guide.loginError {
                Text(e).textRole(console ? .consoleBodySmall : .caption)
                    .foregroundStyle(console ? ConsoleInk.signalInk : .orange).wrapping()
            }
        }
    }

    // MARK: f. Music permission

    private var showsMusicRow: Bool { model.library.musicSettings.displayMode != .off }

    private var musicState: ChecklistState {
        let running = music.players.filter(\.isRunning)
        if running.contains(where: { $0.automation == .denied }) { return .warning }
        if !running.isEmpty && running.allSatisfy({ $0.automation == .allowed }) { return .done }
        return .info
    }

    private var musicRow: some View {
        let running = music.players.filter(\.isRunning)
        let denied = running.first { $0.automation == .denied }
        let title: String
        let detail: String
        if let denied {
            title = "Allow DotStudio to control \(denied.source.displayName)"
            detail = "Turn on \(denied.source.automationName) under DotStudio in Privacy & Security › Automation."
        } else if musicState == .done {
            title = "Music can show on your screensaver"
            detail = "Allowed for \(running.map(\.source.displayName).joined(separator: " and "))."
        } else {
            title = "Music on your screensaver"
            detail = "When macOS asks to let DotStudio control Spotify or Music, click OK."
        }
        return ChecklistRow(state: musicState, title: title, detail: detail) {
            if let denied {
                Button { music.allowControl(denied.source) } label: { ChecklistKeyLabel(title: "Allow\u{2026}") }
                    .modifier(ChecklistActionStyle(classic: .standard))
                    .accessibilityHint("Opens System Settings at Privacy & Security, Automation")
            }
        }
    }
}

// MARK: - Row

enum ChecklistState: Equatable {
    case done, todo, warning, info
    /// Will be done when the user continues (Open at login, ticked).
    case pending

    var word: String {
        switch self {
        case .done: return "Done"
        case .todo: return "To do"
        case .warning: return "Needs attention"
        case .info: return "Information"
        case .pending: return "Turns on when you continue"
        }
    }
}

/// One checklist line: a state mark, the title and detail, and an optional control on the
/// trailing edge (under the text at large sizes) plus extra content under the detail.
struct ChecklistRow<Action: View, Extra: View>: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .headline) private var mark: CGFloat = 20
    @ScaledLength(relativeTo: .body) private var square: CGFloat = 20
    @ScaledLength(relativeTo: .body) private var squareGlyph: CGFloat = 10
    let state: ChecklistState
    var first = false
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    @ViewBuilder var extra: () -> Extra

    init(state: ChecklistState, first: Bool = false, title: String, detail: String,
         @ViewBuilder action: @escaping () -> Action,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.state = state; self.first = first; self.title = title; self.detail = detail
        self.action = action; self.extra = extra
    }

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console: a ruled row (the hairline under it; the list draws the one on top) — a small
    /// square for the state (green with a tick when done, amber with ! for attention, a grey
    /// key-face square to do or for information, an orange-edged one turning on when you
    /// continue), the title in the text face and the detail in the legend grey, the action as
    /// a key or a Console switch at the end.
    private var consoleBody: some View {
        HStack(alignment: .top, spacing: Space.s) {
            consoleMark
            VStack(alignment: .leading, spacing: Space.xs) {
                AdaptiveStack(rowAlignment: .top, columnAlignment: .leading, spacing: layout.controlGap) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    action().fixedSize()
                }
                extra()
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { ConsoleHairline() }
        .accessibilityElement(children: .contain)
    }

    private var consoleMark: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return ZStack {
            switch state {
            case .done:
                shape.fill(ConsoleInk.green)
                Image(systemName: "checkmark").font(.system(size: squareGlyph, weight: .bold))
                    .foregroundStyle(ConsoleInk.onSignal)
            case .warning:
                shape.fill(ConsoleInk.amber)
                Image(systemName: "exclamationmark").font(.system(size: squareGlyph, weight: .bold))
                    .foregroundStyle(ConsoleInk.onSignal)
            case .info:
                shape.fill(ConsoleInk.keyFace)
                shape.strokeBorder(ConsoleInk.hairline, lineWidth: 1)
                Image(systemName: "info").font(.system(size: squareGlyph, weight: .bold))
                    .foregroundStyle(ConsoleInk.legend)
            case .pending:
                shape.fill(ConsoleInk.well)
                shape.strokeBorder(ConsoleInk.signal, lineWidth: 1.5)
                shape.fill(ConsoleInk.signal).padding(square * 0.32)
            case .todo:
                shape.fill(ConsoleInk.keyFace)
                shape.strokeBorder(ConsoleInk.hairline, lineWidth: 1)
            }
        }
        .frame(width: square, height: square)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
    }

    private var classicBody: some View {
        HStack(alignment: .top, spacing: layout.itemGap) {
            stateMark
            VStack(alignment: .leading, spacing: layout.controlGap) {
                // The control beside the text (it wraps), under it at the largest sizes.
                AdaptiveStack(rowAlignment: .top, columnAlignment: .leading, spacing: layout.controlGap) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    action().fixedSize()
                }
                extra()
            }
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !first { Divider().padding(.leading, layout.cardPadding + mark + layout.itemGap) }
        }
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: console ? 2 : layout.labelGap) {
            Text(title)
                .textRole(console ? .consoleTitle : .bodyEmphasis)
                .modifier(ConsoleOnlyInk(primary: ConsoleInk.ink))
                .wrapping()
            Text(detail)
                .textRole(console ? .consoleBodySmall : .caption)
                .foregroundStyle(console ? AnyShapeStyle(ConsoleInk.legend) : AnyShapeStyle(.secondary))
                .wrapping()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(state.word). \(detail)")
    }

    private var stateMark: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .info:
                Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor.opacity(0.85))
            case .pending:
                Image(systemName: "circle.dotted.circle").foregroundStyle(Color.accentColor)
            case .todo:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .scaledFont { .scaled(points: 17, $0, weight: .semibold) }
        .frame(width: mark, height: mark)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
    }
}

/// Console's inks (ink, and the legend grey as `.secondary`); Classic keeps what it inherits.
private struct ConsoleOnlyInk: ViewModifier {
    let primary: Color
    var secondary: Color? = nil
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if !console {
            content
        } else if let secondary {
            content.foregroundStyle(primary, secondary)
        } else {
            content.foregroundStyle(primary)
        }
    }
}

/// A checklist action's title: Classic's role-sized text; Console's key legend (mono caps).
private struct ChecklistKeyLabel: View {
    let title: String
    var classicRole: TextRole = .body
    @Environment(\.console) private var console
    var body: some View {
        if console {
            Text(title).textRole(.consoleKey).lineLimit(1).fixedSize()
        } else {
            Text(title).textRole(classicRole)
        }
    }
}

/// A checklist action's button: Classic's link / prominent / stock button as before; Console's
/// small key (the orange one for the step's main action).
private struct ChecklistActionStyle: ViewModifier {
    enum Classic { case link, prominent, standard }
    let classic: Classic
    var consoleTint: ConsoleKeycapStyle.Tint = .plain
    @Environment(\.console) private var console

    func body(content: Content) -> some View {
        if console {
            content.buttonStyle(.keycap(consoleTint, padding: HubMetrics.smallKey))
        } else {
            switch classic {
            case .link: content.buttonStyle(.link)
            case .prominent: content.buttonStyle(.borderedProminent)
            case .standard: content
            }
        }
    }
}

// MARK: - The floating panel

/// SetupGuidePanel's content: the setup card (SetupGuideCard.swift) and the checklist, Done at
/// the foot. The picture goes beside the steps once the panel is dragged (or rendered) wide.
struct SetupGuidePanelView: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ObservedObject var guide: SetupGuideModel
    /// The coach marks (SetupCoach.swift); UI shots pass a pinned one.
    @ObservedObject var coach: SetupCoach = .shared
    var frozenStep: Int?
    var forceStill = false
    var onOpenSettings: () -> Void = {}
    var onDone: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= layout.scaled(760) && !layout.typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: layout.sectionGap) {
                        SetupCard(guide: guide, coach: coach, context: .panel, status: guide.snapshot.status,
                                  sideBySide: wide, frozenStep: frozenStep, forceStill: forceStill) {
                            onOpenSettings()
                            guide.openSystemSettings()
                        }
                        SetupChecklist(guide: guide, commitPhrase: "when you click Done",
                                       coaching: coach.mode == .coaching, showsInstallButton: false)
                    }
                    .padding(wide ? layout.pagePadding : layout.cardPadding + Space.xxs)
                    .frame(maxWidth: wide ? 1100 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    Spacer()
                    doneButton
                        .keyboardShortcut(guide.snapshot.status == .ready ? .defaultAction : .cancelAction)
                        .accessibilityHint("Closes the guide and applies Open at login")
                }
                .padding(.horizontal, layout.cardPadding + Space.xxs)
                .padding(.vertical, Space.s)
                .background(alignment: .top) { if console { ConsoleHairline() } else { Divider() } }
            }
        }
        // Console: the panel colour (as Settings' pane and the popovers), its text in the inks.
        .background(console ? ConsoleInk.panel : Color(nsColor: .windowBackgroundColor))
        .modifier(ConsoleOnlyInk(primary: ConsoleInk.ink, secondary: ConsoleInk.legend))
        .onAppear { guide.begin() }
        .onDisappear { guide.end() }
    }

    /// Done: Classic's large button; Console's key, orange once everything's set (it's then
    /// the Return key — before that, the card's Open System Settings is the orange one).
    @ViewBuilder private var doneButton: some View {
        if console {
            Button(action: onDone) { Text("Done").textRole(.consoleKey) }
                .buttonStyle(.keycap(guide.snapshot.status == .ready ? .signal : .plain,
                                     padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)))
        } else {
            Button(action: onDone) { Text("Done").textRole(.body) }
                .adaptiveControlSize(.large)
        }
    }
}
