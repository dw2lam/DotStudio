//  SetupGuideChecklist.swift — the guided setup's live checklist (installed, chosen, starts
//  when inactive, display sleep, open at login, music permission) and the guide laid out two
//  ways: the onboarding "Turn It On" step (OnboardingView) and the floating panel
//  (SetupGuidePanel). State: SetupGuide.swift.

import SwiftUI

// MARK: - The guide (walkthrough + checklist)

/// The walkthrough with its "Open System Settings" button, and the checklist: side by side
/// when there's room, else stacked (walkthrough first).
struct SetupGuideContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var guide: SetupGuideModel
    /// Side by side (a wide sheet or panel) or stacked.
    var sideBySide: Bool
    /// "when you continue" / "when you click Done": when "Open at login" is applied.
    var commitPhrase: String
    var frozenStep: Int?
    var forceStill = false
    /// Opens Wallpaper settings (the panel also moves beside it).
    var onOpenSettings: () -> Void

    var body: some View {
        if sideBySide {
            HStack(alignment: .top, spacing: layout.sectionGap) {
                walkthrough.frame(maxWidth: layout.scaled(560), alignment: .top)
                SetupChecklist(guide: guide, commitPhrase: commitPhrase)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                walkthrough
                SetupChecklist(guide: guide, commitPhrase: commitPhrase)
            }
        }
    }

    private var walkthrough: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            SetupWalkthrough(frozenStep: frozenStep, forceStill: forceStill, narrow: !sideBySide && layout.prefersStacking)
            openButton
        }
    }

    @ViewBuilder private var openButton: some View {
        let button = Button(action: onOpenSettings) {
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
    @ObservedObject var guide: SetupGuideModel
    @ObservedObject private var music = MusicNow.shared
    var commitPhrase: String
    /// The coach is pointing in System Settings (no picture on screen): the wording follows.
    var coaching = false

    private var s: SetupSnapshot { guide.snapshot }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: layout.controlGap) {
            HStack(alignment: .firstTextBaseline) {
                Text("Checklist").textRole(.headline)
                Spacer(minLength: layout.controlGap)
                let done = rows.filter { $0 == .done }.count
                Text("\(done) of \(rows.count) done")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(done) of \(rows.count) items done")
            }
            VStack(spacing: 0) {
                installRow
                chooseRow
                idleRow
                if showsSleepRow { sleepRow }
                loginRow
                if showsMusicRow { musicRow }
            }
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            Text("Ticks itself as you go — no need to come back and check.")
                .textRole(.caption)
                .foregroundStyle(.secondary)
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
                     detail: s.installed ? "DotStudio is in your Mac's screen savers."
                                         : "Adds DotStudio to your Mac's screen savers, then opens System Settings.") {
            if !s.installed {
                Button { model.installScreensaver(); guide.refresh() } label: { Text("Install").textRole(.body) }
                    .buttonStyle(.borderedProminent)
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
            detail = "Pick another display at the top of the Wallpaper page, then choose DotStudio for it too."
        case .chosen(let on, let of) where s.installed && on > 0:
            title = "DotStudio is your screensaver"
            detail = of == 2 ? "On both displays." : of > 2 ? "On all \(of) displays." : "Chosen in System Settings › Wallpaper."
        case .unknown where s.installed:
            title = "Choose DotStudio as your screensaver"
            detail = coaching ? "DotStudio can't check this on your Mac — follow the ring in System Settings."
                              : "DotStudio can't check this on your Mac — follow the steps in the picture."
        default:
            title = "Choose DotStudio as your screensaver"
            if coaching {
                detail = s.installed ? "Follow the ring in System Settings. This ticks itself when it's done."
                                     : "After installing, follow the ring in System Settings."
            } else {
                detail = s.installed ? "Follow the steps in the picture. This ticks itself when it's done."
                                     : "After installing, follow the steps in the picture."
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
                ? "macOS's default. Change it in Lock Screen › Start Screen Saver when inactive."
                : "Change it in Lock Screen › Start Screen Saver when inactive."
        } else {
            title = "Screensaver never starts on its own"
            detail = "\u{201C}Start Screen Saver when inactive\u{201D} is set to Never in Lock Screen settings."
        }
        return ChecklistRow(state: idleState, title: title, detail: detail) {
            if !s.startsWhenInactive { lockScreenLink }
        }
    }

    private var lockScreenLink: some View {
        Button { SystemSettingsLink.openLockScreen() } label: { Text("Lock Screen Settings\u{2026}").textRole(.body) }
            .buttonStyle(.link)
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
            detail = sleepSummary.map { "It turns off after \($0) — after the screensaver starts." }
                ?? "Your display never turns off on its own."
        } else {
            title = "Your display turns off first"
            if conflicts.count == 2 && conflicts[0].minutes == conflicts[1].minutes {
                detail = "On battery and on power adapter your display turns off after \(SetupWords.short(seconds: conflicts[0].minutes * 60)), before the screensaver starts at \(idle)."
            } else {
                detail = conflicts.map { "On \($0.source) your display turns off after \(SetupWords.short(seconds: $0.minutes * 60)), before the screensaver starts at \(idle)." }
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
            detail = "macOS needs your OK: turn DotStudio on in System Settings › General › Login Items."
        case .enabled where !guide.wantsLogin, .off where guide.wantsLogin:
            detail = "Starts quietly in the menu bar, so your live wallpaper and music keep working after a restart. Applies \(commitPhrase)."
        default:
            detail = "Starts quietly in the menu bar, so your live wallpaper and music keep working after a restart."
        }
        return ChecklistRow(state: loginState, title: "Open DotStudio at login", detail: detail) {
            Toggle("Open DotStudio at login", isOn: $guide.wantsLogin)
                .toggleStyle(.switch)
                .labelsHidden()
                .adaptiveControlSize(.small)
                .accessibilityLabel("Open DotStudio at login")
        } extra: {
            if s.login == .requiresApproval {
                Button { LoginItem.openLoginItemsSettings() } label: { Text("Open Login Items\u{2026}").textRole(.body) }
                    .buttonStyle(.link)
                    .accessibilityHint("Opens System Settings at Login Items")
            } else if let e = guide.loginError {
                Text(e).textRole(.caption).foregroundStyle(.orange).wrapping()
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
            detail = "It was turned off, so the screensaver can't show exact progress or artwork. Turn on \(denied.source.automationName) under DotStudio in Privacy & Security › Automation."
        } else if musicState == .done {
            title = "Music can show on your screensaver"
            detail = "DotStudio may read what's playing in \(running.map(\.source.displayName).joined(separator: " and "))."
        } else {
            title = "Music on your screensaver"
            detail = "The first time a song plays, macOS asks once: \u{201C}DotStudio wants to control Spotify\u{201D} (or Music). Click OK — DotStudio only reads what's playing, and plays or pauses it when you ask."
        }
        return ChecklistRow(state: musicState, title: title, detail: detail) {
            if let denied {
                Button { music.allowControl(denied.source) } label: { Text("Allow\u{2026}").textRole(.body) }
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
    @ScaledLength(relativeTo: .headline) private var mark: CGFloat = 20
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
        VStack(alignment: .leading, spacing: layout.labelGap) {
            Text(title)
                .textRole(.bodyEmphasis)
                .wrapping()
            Text(detail)
                .textRole(.caption)
                .foregroundStyle(.secondary)
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

// MARK: - The floating panel

/// SetupGuidePanel's content: the guide under a short header, Done at the foot. Stacked in
/// the narrow panel; side by side once it's dragged (or rendered) wide.
struct SetupGuidePanelView: View {
    @Environment(\.layout) private var layout
    @ObservedObject var guide: SetupGuideModel
    /// The coach marks (SetupCoach.swift); UI shots pass a pinned one.
    @ObservedObject var coach: SetupCoach = .shared
    var frozenStep: Int?
    var forceStill = false
    var onOpenSettings: () -> Void = {}
    var onDone: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= layout.scaled(720) && !layout.typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: layout.sectionGap) {
                        VStack(alignment: .leading, spacing: layout.labelGap) {
                            Text("Set Up Your Screensaver")
                                .textRole(.sectionTitle)
                                .wrapping()
                            Text(coach.mode == .coaching
                                 ? "macOS lets only you choose the screensaver. DotStudio points at each click in System Settings \u{2014} this guide stays beside it."
                                 : "macOS lets only you choose the screensaver. Follow the picture in System Settings — this guide stays on top while you do.")
                                .textRole(.callout)
                                .foregroundStyle(.secondary)
                                .wrapping()
                        }
                        CoachCard(coach: coach, guide: guide)
                        if coach.mode == .coaching {
                            // The ring in System Settings replaces the picture (the card brings
                            // it back for a step the coach can't point at).
                            SetupChecklist(guide: guide, commitPhrase: "when you click Done", coaching: true)
                        } else {
                            SetupGuideContent(guide: guide, sideBySide: wide, commitPhrase: "when you click Done",
                                              frozenStep: frozenStep, forceStill: forceStill) {
                                onOpenSettings()
                                guide.openSystemSettings()
                            }
                        }
                    }
                    .padding(wide ? layout.pagePadding : layout.cardPadding + Space.xxs)
                    .frame(maxWidth: wide ? 1200 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    Spacer()
                    Button(action: onDone) { Text("Done").textRole(.body) }
                        .adaptiveControlSize(.large)
                        .keyboardShortcut(guide.snapshot.status == .ready ? .defaultAction : .cancelAction)
                        .accessibilityHint("Closes the guide and applies Open at login")
                }
                .padding(.horizontal, layout.cardPadding + Space.xxs)
                .padding(.vertical, Space.s)
                .background(alignment: .top) { Divider() }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { guide.begin() }
        .onDisappear { guide.end() }
    }
}
