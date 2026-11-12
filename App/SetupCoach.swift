//  SetupCoach.swift — the setup guide's coach marks: with the user's one-time Accessibility
//  permission, DotStudio reads System Settings' accessibility tree while the guide panel is
//  open, draws a glowing ring around the exact control to click next (Wallpaper › "Screen
//  Saver…" › scroll to Other › DotStudio › Done) and moves on as the user clicks.
//
//  Pieces:
//    SetupCoach        (main actor) permission, the step, the overlay, panel docking, logging.
//    CoachWorker       its own thread + run loop: every Accessibility call (they can stall), an
//                      AXObserver on System Settings, a 10 Hz frame re-read of the current
//                      targets and a ~1 Hz full capture, plus CGWindowList occlusion. Never
//                      touches the main thread except to hand over an observation.
//    CoachOverlay      a borderless, transparent panel ABOVE System Settings that draws the
//                      ring and callout. It can never take a click: ignoresMouseEvents, a
//                      hosting view whose hitTest is nil, non-activating, never key or main.
//    SetupCoachMatch.swift  the pure matcher and step logic (unit-tested by
//                      tools/setup-coach-check without System Settings).
//    SetupCoachViews.swift  the ring, the callout and the panel's coach card.
//
//  Privacy: reads only System Settings (com.apple.systempreferences) and its Wallpaper
//  settings extension's process (the page lives there), only while the guide is coaching.
//  stop() removes every observer and timer. Declined or unavailable → the illustrated guide.
//
//  Diagnostics: DOTSTUDIO_AX_DUMP=<file> writes the captured tree (text, plus <file>.json for
//  tools/setup-coach-check) whenever a step's target can't be found. Step changes go to the
//  debug log ([coach …] lines, when debug.enabled exists).

import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - Observation

/// One look at System Settings, handed from the worker to the main actor.
struct CoachObservation {
    var scene = CoachScene()
    /// The captured tree (full captures only, and only when DOTSTUDIO_AX_DUMP is set).
    var tree: AXNodeSnapshot?
    var settingsRunning = false
    /// A Settings window is on screen in the current Space.
    var settingsOnScreen = false
    /// Other apps' windows in front of System Settings (AX/CG global frames).
    var occluders: [CGRect] = []
    /// Accessibility refused (not trusted any more) or System Settings isn't answering.
    var axError: String?
    var at = Date()
}

// MARK: - The coach

@MainActor
final class SetupCoach: ObservableObject {
    static let shared = SetupCoach()

    static let settingsBundleID = "com.apple.systempreferences"
    /// DOTSTUDIO_AX_DUMP: where to write the captured tree when a target isn't found.
    static let dumpPath: String? = {
        let p = ProcessInfo.processInfo.environment["DOTSTUDIO_AX_DUMP"] ?? ""
        return p.isEmpty ? nil : (p as NSString).expandingTildeInPath
    }()
    /// How long a step's target may stay missing before the illustrated step takes over.
    static let degradeAfter: TimeInterval = 3

    enum Mode: Equatable {
        case off
        /// "Guide Me" was clicked; macOS's Accessibility prompt is (or was) up.
        case waitingForPermission
        case coaching
    }

    @Published private(set) var mode: Mode = .off
    /// What the coach shows: the step derived from System Settings.
    @Published private(set) var decision = CoachDecision(step: .openWallpaper, situation: .settingsClosed)
    /// Back / Skip: a step the user picked instead of the observed one (cleared when the
    /// observed step changes).
    @Published private(set) var override: CoachStep?
    /// The current step's control couldn't be found (or Accessibility failed): the panel
    /// shows the illustrated step instead.
    @Published private(set) var degraded = false
    /// The ring is on screen now.
    @Published private(set) var ringShown = false
    /// Where the last AX dump went (DOTSTUDIO_AX_DUMP).
    @Published private(set) var lastDump: String?
    /// Accessibility is already allowed (read when the offer appears; never prompts).
    @Published private(set) var trusted = false

    /// The step on screen: Back/Skip's pick, else the observed one.
    var shownStep: CoachStep { override ?? decision.step }

    let isDemo: Bool
    /// Debug-log lines ([coach …]).
    var log: ((String) -> Void)?
    /// The Settings window's frame changed (AX global): the panel docks beside it.
    var onSettingsFrame: ((CGRect) -> Void)?
    /// Install the screensaver first (when it isn't): the panel's model does it.
    var install: (() -> Void)?

    private var worker: CoachWorker?
    private var overlay: CoachOverlay?
    private var permissionPoll: Timer?
    private var tick: Timer?
    private var subs: Set<AnyCancellable> = []
    private var observation = CoachObservation()
    private var lastObservationAt = Date.distantPast
    private var settingsPID: pid_t?
    private var lastPage: CoachScene.Page = .none
    private var chosenWhenOpened: Int?
    private var targetMissingSince: Date?
    private var dumpedThisStep = false
    private var lastDockedFrame: CGRect?
    private var lastLoggedStep: String?
    private var lastTarget: CGRect?
    private var celebrateUntil: Date?
    /// Self-test harness: observations are fed by hand, nothing is shown, the clock is fake.
    private var harness = false
    private var clock: () -> Date = Date.init
    private var testChoice: SetupSnapshot.Choice?

    init() { isDemo = false }

    /// UI shots: a pinned state; never starts anything.
    init(demoMode: Mode, decision: CoachDecision, override: CoachStep? = nil, degraded: Bool = false,
         ringShown: Bool = true, trusted: Bool = false) {
        isDemo = true
        mode = demoMode
        self.decision = decision
        self.override = override
        self.degraded = degraded
        self.ringShown = ringShown
        self.trusted = trusted
    }

    private var guide: SetupGuideModel { SetupGuideModel.shared }

    // MARK: Permission

    /// Re-reads whether Accessibility is allowed (no prompt).
    func refreshTrust() {
        guard !isDemo, !OffscreenCapture.isActive else { return }
        trusted = AXIsProcessTrusted()
    }

    /// "Guide Me": coach now if allowed; else macOS's one-time prompt, then wait for it.
    func guideMe() {
        guard !isDemo, !OffscreenCapture.isActive, mode == .off else { return }
        if AXIsProcessTrusted() {
            trusted = true
            startCoaching()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            trusted = true
            startCoaching()
            return
        }
        mode = .waitingForPermission
        say("asked for Accessibility; waiting")
        // macOS doesn't notify when it's granted: look once a second.
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .waitingForPermission else { return }
                if AXIsProcessTrusted() {
                    self.trusted = true
                    self.say("Accessibility granted")
                    self.startCoaching()
                }
            }
        }
    }

    /// Privacy & Security › Accessibility, for a "Don't Allow" that the user takes back.
    func openAccessibilitySettings() {
        guard !isDemo, !OffscreenCapture.isActive,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Lifecycle

    private func startCoaching() {
        permissionPoll?.invalidate(); permissionPoll = nil
        guard mode != .coaching else { return }
        mode = .coaching
        override = nil
        degraded = false
        dumpedThisStep = false
        lastDockedFrame = nil
        lastLoggedStep = nil
        chosenWhenOpened = nil
        targetMissingSince = Date()
        say("coaching on (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")

        if !Installer.isInstalled { install?() } else { Installer.openScreenSaverSettings() }

        let strings = CoachStrings.system()
        say("labels: button=\(strings.screenSaverButton.sorted()) other=\(strings.other.sorted()) done=\(strings.done.sorted())")
        let w = CoachWorker(strings: strings, ourPID: ProcessInfo.processInfo.processIdentifier,
                            keepTree: Self.dumpPath != nil)
        w.onObservation = { [weak self] obs in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(obs) } }
        }
        worker = w
        w.start()
        updateSettingsPID()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateSettingsPID() } }
                .store(in: &subs)
        }
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &subs)
        guide.$snapshot
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.recompute() } } }
            .store(in: &subs)
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
    }

    /// Stop everything: observers, the worker thread, timers, the overlay.
    func stop() {
        guard !isDemo else { return }
        permissionPoll?.invalidate(); permissionPoll = nil
        tick?.invalidate(); tick = nil
        subs.removeAll()
        worker?.stop()
        worker = nil
        overlay?.close()
        overlay = nil
        if mode == .coaching { say("coaching off") }
        mode = .off
        override = nil
        degraded = false
        ringShown = false
        celebrateUntil = nil
    }

    /// "Use the Picture Instead" / "Stop Guiding".
    func useIllustratedGuide() { stop() }

    /// "Go Back to Wallpaper" / "Open System Settings".
    func reopenWallpaper() {
        guard !isDemo, !OffscreenCapture.isActive else { return }
        Installer.openScreenSaverSettings()
    }

    func back() {
        let s = shownStep
        guard s > .openWallpaper else { return }
        setOverride(CoachStep(rawValue: min(s.rawValue, CoachStep.clickDone.rawValue) - 1))
    }

    func skip() {
        let s = shownStep
        guard s < .clickDone else { return }
        setOverride(CoachStep(rawValue: s.rawValue + 1))
    }

    private func setOverride(_ s: CoachStep?) {
        override = s == decision.step ? nil : s
        say("user moved to \(shownStep.name)")
        recompute()
    }

    private func updateSettingsPID() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first?.processIdentifier
        guard pid != settingsPID else { return }
        settingsPID = pid
        worker?.setSettingsPID(pid)
    }

    // MARK: Each observation

    private func apply(_ obs: CoachObservation) {
        guard mode == .coaching else { return }
        observation = obs
        lastObservationAt = obs.at
        recompute()
    }

    private func recompute() {
        guard mode == .coaching else { return }
        let now = clock()
        var obs = observation
        // The worker stopped answering (System Settings hung): no ring on stale frames.
        if now.timeIntervalSince(lastObservationAt) > 3 && settingsPID != nil {
            obs.axError = obs.axError ?? "System Settings isn't answering"
            obs.scene = CoachScene(page: .none)
        }
        let scene = obs.scene

        var chosenOn: Int?, chosenOf: Int?
        if case .chosen(let on, let of) = testChoice ?? guide.snapshot.choice { chosenOn = on; chosenOf = of }
        if scene.page == .chooser && lastPage != .chooser { chosenWhenOpened = chosenOn }
        if scene.page != .chooser && scene.page != .none { chosenWhenOpened = nil }
        lastPage = scene.page

        var d = CoachPlanner.decide(scene, chosenOn: chosenOn, chosenOf: chosenOf, chosenWhenOpened: chosenWhenOpened)
        if settingsPID == nil { d = CoachDecision(step: .openWallpaper, situation: .settingsClosed) }
        // Accessibility failing while System Settings runs: not "closed" — keep the step the
        // user was on, with no ring (it turns into the illustrated step below).
        let axFailing = obs.axError != nil && settingsPID != nil
        if axFailing {
            d = CoachDecision(step: decision.step == .finished ? .finished : decision.step)
        }

        if d.step != decision.step || d.situation != decision.situation {
            if d.step == .finished && decision.step != .finished && decision.step >= .openChooser {
                celebrateUntil = now.addingTimeInterval(1.8)
            }
            if d.step != decision.step {
                override = nil
                dumpedThisStep = false
            }
            targetMissingSince = d.target == nil ? now : nil
        }
        if d != decision { decision = d }
        let key = "\(d.step.name)/\(d.situation)"
        if key != lastLoggedStep {
            lastLoggedStep = key
            say("step → \(key) page=\(scene.page) target=\(d.target.map { "\($0)" } ?? "none")")
        }

        // Missing for a few seconds (or AX failing): the illustrated step, and a dump.
        let needsTarget = d.step != .finished && d.situation != .settingsClosed
        if d.target != nil {
            targetMissingSince = nil
        } else if targetMissingSince == nil {
            targetMissingSince = now
        }
        let missingLong = needsTarget && d.target == nil && now.timeIntervalSince(targetMissingSince ?? now) >= Self.degradeAfter
        let nowDegraded = missingLong
        if nowDegraded != degraded {
            degraded = nowDegraded
            say(nowDegraded ? "can't find the target for \(d.step.name) (\(obs.axError ?? "not in the tree")): illustrated step" : "target found again")
        }
        if missingLong && !dumpedThisStep {
            dumpedThisStep = true
            writeDump(obs: obs, decision: d)
        }

        // The ring: on the observed step's target, when System Settings (or the guide) is in
        // front, its window is on this Space and nothing covers the target.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ours = ProcessInfo.processInfo.processIdentifier
        let frontOK = harness || front == ours || (front != nil && front == settingsPID)
        var ring: CGRect?
        if let t = d.target, override == nil || override == d.step, frontOK, obs.settingsOnScreen, obs.axError == nil,
           CoachGeometry.coveredFraction(t, by: obs.occluders) < 0.3 {
            ring = t
        }
        if ring != nil { lastTarget = ring }

        if let until = celebrateUntil, now < until, let last = lastTarget {
            showOverlay(ring: last, kind: .control, callout: "DotStudio is your screensaver", step: 4, celebrate: true)
        } else {
            celebrateUntil = nil
            if let ring {
                showOverlay(ring: ring, kind: d.kind, callout: d.callout ?? d.step.title,
                            step: d.step.walkthroughStep + 1, celebrate: false)
            } else {
                overlay?.hide()
                if ringShown { ringShown = false }
            }
        }

        // Keep the guide panel beside the Settings window (not over it).
        if let w = scene.window, obs.settingsOnScreen {
            if lastDockedFrame == nil || !(lastDockedFrame!.equalTo(w)) {
                lastDockedFrame = w
                onSettingsFrame?(w)
            }
        }
    }

    private func showOverlay(ring: CGRect, kind: CoachTargetKind, callout: String, step: Int, celebrate: Bool) {
        if harness { if !ringShown { ringShown = true }; return }
        if overlay == nil { overlay = CoachOverlay() }
        overlay?.show(ringAX: ring, kind: kind, callout: callout, step: step, celebrate: celebrate)
        if !ringShown { ringShown = true }
    }

    // MARK: Diagnostics

    private func say(_ message: String) {
        log?(message)
    }

    private func writeDump(obs: CoachObservation, decision d: CoachDecision) {
        guard let path = Self.dumpPath else { return }
        let jsonPath = path.hasSuffix(".json") ? path : path + ".json"
        let textPath = path.hasSuffix(".json") ? String(path.dropLast(5)) + ".txt" : path
        var text = "DotStudio setup coach — System Settings accessibility tree\n"
        text += "date: \(Date())\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))\n"
        text += "step: \(d.step.name) (\(d.situation)); target not found\n"
        let s = obs.scene
        text += "scene: page=\(s.page) window=\(String(describing: s.window)) sidebarRow=\(String(describing: s.wallpaperRow)) "
        text += "button=\(String(describing: s.screenSaverButton)) chooser=\(String(describing: s.chooser)) sheet=\(s.chooserIsSheet) "
        text += "list=\(String(describing: s.scrollArea)) other=\(String(describing: s.otherHeader)) tile=\(String(describing: s.tile)) "
        text += "tileOutOfView=\(s.tileOutOfView) done=\(String(describing: s.done))\n"
        if let e = obs.axError { text += "accessibility: \(e)\n" }
        text += "\n"
        if let tree = obs.tree {
            tree.dumpText(into: &text)
            if let json = try? JSONEncoder().encode(tree) { try? json.write(to: URL(fileURLWithPath: jsonPath)) }
        } else {
            text += "(no tree captured yet)\n"
        }
        do {
            try text.write(toFile: textPath, atomically: true, encoding: .utf8)
            lastDump = textPath
            say("wrote AX dump to \(textPath)")
        } catch {
            say("couldn't write AX dump to \(textPath): \(error.localizedDescription)")
        }
    }

    // MARK: Self-test

    /// DOTSTUDIO_COACH_SELFTEST=1: checks the overlay window can never take a click (never
    /// shown), the labels load and the matcher runs, then exits. Nothing appears on screen.
    nonisolated static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DOTSTUDIO_COACH_SELFTEST"] != nil else { return }
        MainActor.assumeIsolated {
            var failures = 0
            func check(_ ok: Bool, _ what: String) {
                print("\(ok ? "ok  " : "FAIL") \(what)")
                if !ok { failures += 1 }
            }
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let w = CoachOverlayWindow()
            check(w.ignoresMouseEvents, "overlay ignores mouse events (clicks go to System Settings)")
            check(!w.canBecomeKey && !w.canBecomeMain, "overlay never becomes key or main")
            check(w.styleMask.contains(.nonactivatingPanel) && w.styleMask.contains(.borderless), "overlay is a borderless non-activating panel")
            check(w.level.rawValue >= NSWindow.Level.floating.rawValue, "overlay floats above System Settings (level \(w.level.rawValue))")
            check(w.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]),
                  "overlay joins all Spaces, full screen aux, stationary, ignores cycle")
            check(!w.isOpaque && w.backgroundColor == .clear && !w.hasShadow, "overlay is transparent")
            check(!w.isVisible, "overlay was never shown")
            w.setFrame(CGRect(x: -20000, y: -20000, width: 400, height: 300), display: false)
            let model = CoachOverlayModel()
            model.ring = CGRect(x: 100, y: 100, width: 120, height: 30)
            model.callout = "Click Screen Saver\u{2026}"
            let host = CoachHostingView(rootView: CoachMarkView(model: model))
            host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            check(host.hitTest(CGPoint(x: 160, y: 185)) == nil && host.hitTest(CGPoint(x: 5, y: 5)) == nil,
                  "overlay content never hit-tests, even on the ring")
            check(!host.acceptsFirstMouse(for: nil), "overlay content refuses first mouse")
            let strings = CoachStrings.system()
            check(!strings.screenSaverButton.isEmpty && !strings.other.isEmpty, "labels: \(strings.screenSaverButton.sorted()) / \(strings.other.sorted())")
            let tree = AXNodeSnapshot("AXApplication", children: [
                AXNodeSnapshot("AXWindow", subrole: "AXStandardWindow", title: "Wallpaper", frame: CGRect(x: 0, y: 0, width: 700, height: 600),
                               focused: true, children: [AXNodeSnapshot("AXButton", title: "Screen Saver\u{2026}", frame: CGRect(x: 500, y: 540, width: 110, height: 24))])])
            let d = CoachPlanner.decide(CoachMatcher.match(tree, strings: strings), chosenOn: 0, chosenOf: 1, chosenWhenOpened: nil)
            check(d.step == .openChooser && d.target != nil, "matcher finds Screen Saver… in a minimal tree")
            w.close()
            harnessChecks(check)
            print(failures == 0 ? "coach self-test: PASS" : "coach self-test: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// The coach's state machine with hand-fed observations and a fake clock: steps advance,
    /// Skip/Back clear on progress, a missing target turns into the picture after 3 s, AX
    /// failure keeps the step, finishing celebrates, stop() ends it. No window, no System
    /// Settings, no permission prompt. `check` prints and counts.
    private static func harnessChecks(_ check: (Bool, String) -> Void) {
        func expect(_ ok: Bool, _ what: String) { check(ok, "state: " + what) }
        let coach = SetupCoach()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        coach.clock = { now }
        coach.harness = true
        coach.mode = .coaching
        coach.settingsPID = 4242
        coach.testChoice = .chosen(on: 0, of: 1)
        coach.targetMissingSince = now
        func feed(_ s: CoachScene, error: String? = nil) {
            var o = CoachObservation(scene: s, settingsRunning: true, settingsOnScreen: true)
            o.axError = error
            o.at = now
            coach.apply(o)
        }
        let button = CGRect(x: 790, y: 690, width: 110, height: 24)
        let list = CGRect(x: 250, y: 180, width: 615, height: 470)
        let tile = CGRect(x: 680, y: 542, width: 120, height: 92)
        let done = CGRect(x: 790, y: 670, width: 60, height: 24)
        let wallpaper = CoachScene(page: .wallpaper, screenSaverButton: button)

        feed(wallpaper)
        expect(coach.decision.step == .openChooser && coach.ringShown && !coach.degraded, "Wallpaper page → ring on Screen Saver…")
        coach.skip()
        expect(coach.override == .scrollToTile && coach.shownStep == .scrollToTile, "Skip shows the next step")
        var sheet = CoachScene(page: .chooser, chooserIsSheet: true, scrollArea: list, tileOutOfView: true, done: done)
        now += 0.5; feed(sheet)
        expect(coach.decision.step == .scrollToTile && coach.override == nil, "sheet open → scroll step; Skip cleared by progress")
        sheet.tile = tile; sheet.tileOutOfView = false
        now += 0.5; feed(sheet)
        expect(coach.decision.step == .chooseTile && coach.decision.target == tile, "tile in view → ring on DotStudio")
        coach.back()
        expect(coach.shownStep == .scrollToTile && coach.override != nil, "Back steps back")
        now += 0.5; coach.testChoice = .chosen(on: 1, of: 1); feed(sheet)
        expect(coach.decision.step == .clickDone && coach.decision.target == done && coach.override == nil,
               "the store says chosen → ring on Done (Back cleared)")
        now += 0.5; feed(wallpaper)
        expect(coach.decision.step == .finished && coach.celebrateUntil != nil, "sheet closed, chosen everywhere → all set, celebrates")

        // A target that never turns up: the picture after 3 s (not before)
        coach.testChoice = .chosen(on: 0, of: 1)
        let lost = CoachScene(page: .chooser, chooserIsSheet: true)
        now += 0.5; feed(lost)
        expect(coach.decision.step == .scrollToTile && coach.decision.target == nil && !coach.degraded, "chooser without a list: no ring, not yet the picture")
        now += 2; coach.recompute()
        expect(!coach.degraded, "…still waiting at 2 s")
        now += 1.5; coach.recompute()
        expect(coach.degraded && !coach.ringShown, "…the illustrated step after 3 s, no ring")
        now += 0.5; feed(sheet)
        expect(!coach.degraded && coach.decision.step == .chooseTile, "found again → back to the ring")

        // Accessibility failing: keeps the step (not "System Settings closed"), then the picture
        now += 0.5; feed(CoachScene(page: .none), error: "Accessibility isn't allowed for DotStudio")
        expect(coach.decision.step == .chooseTile && coach.decision.situation == .normal && coach.decision.target == nil,
               "AX failure keeps the step, drops the ring")
        now += 3.5; feed(CoachScene(page: .none), error: "Accessibility isn't allowed for DotStudio")
        expect(coach.degraded, "AX failure → the illustrated step")

        // Settings quits
        coach.settingsPID = nil
        now += 0.5; feed(CoachScene(page: .none))
        expect(coach.decision.situation == .settingsClosed && !coach.degraded, "System Settings quit → Open System Settings, no picture")
        // Somewhere else in Settings, sidebar row found
        coach.settingsPID = 4242
        now += 0.5; feed(CoachScene(page: .elsewhere, wallpaperRow: CGRect(x: 200, y: 440, width: 215, height: 28)))
        expect(coach.decision.situation == .elsewhere && coach.ringShown, "another page → Go Back to Wallpaper, ring on the sidebar row")

        coach.harness = false   // stop() must not reach a worker/overlay here (there are none)
        coach.stop()
        expect(coach.mode == .off && !coach.ringShown, "stop() turns everything off")
    }
}

// MARK: - The overlay window

/// Above System Settings, never in the way: transparent, click-through, never key or main,
/// never activates DotStudio, on every Space, out of the window cycle.
final class CoachOverlayWindow: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        title = "DotStudio Setup Coach"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The overlay's hosting view: no hit-testing at all, so nothing in it can catch a click even
/// if the window ever stopped ignoring mouse events.
final class CoachHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

/// What the overlay draws (view space: top-left of the overlay's screen, points).
final class CoachOverlayModel: ObservableObject {
    @Published var ring: CGRect?
    @Published var kind: CoachTargetKind = .control
    @Published var callout = ""
    @Published var step = 1
    @Published var celebrate = false
}

@MainActor
final class CoachOverlay {
    private let window = CoachOverlayWindow()
    private let model = CoachOverlayModel()
    private var screenAX: CGRect?

    init() {
        let host = CoachHostingView(rootView: CoachMarkView(model: model).adaptiveLayout())
        host.sizingOptions = []
        window.contentView = host
    }

    /// Shows the ring around `ringAX` (AX global) on the screen that holds it.
    func show(ringAX: CGRect, kind: CoachTargetKind, callout: String, step: Int, celebrate: Bool) {
        let screens = NSScreen.screens
        guard let main = screens.first else { hide(); return }
        let mainH = main.frame.height
        let center = CGPoint(x: ringAX.midX, y: ringAX.midY)
        let best = screens.first { CoachGeometry.flip($0.frame, mainHeight: mainH).contains(center) }
            ?? screens.max { a, b in
                let fa = CoachGeometry.flip(a.frame, mainHeight: mainH).intersection(ringAX)
                let fb = CoachGeometry.flip(b.frame, mainHeight: mainH).intersection(ringAX)
                return (fa.isNull ? 0 : fa.width * fa.height) < (fb.isNull ? 0 : fb.width * fb.height)
            }
        guard let screen = best else { hide(); return }
        let ax = CoachGeometry.flip(screen.frame, mainHeight: mainH)
        if screenAX != ax || !window.isVisible {
            screenAX = ax
            window.setFrame(screen.frame, display: false)
        }
        let local = ringAX.offsetBy(dx: -ax.minX, dy: -ax.minY)
        if model.ring != local { model.ring = local }
        if model.kind != kind { model.kind = kind }
        if model.callout != callout { model.callout = callout }
        if model.step != step { model.step = step }
        if model.celebrate != celebrate { model.celebrate = celebrate }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        model.ring = nil
        if window.isVisible { window.orderOut(nil) }
    }

    func close() {
        hide()
        window.close()
    }
}

// MARK: - The worker (all Accessibility calls)

/// Runs on its own thread with its own run loop, so a stalled AX call never blocks the UI.
/// Captures System Settings' tree (BFS, node + time budget), re-reads the current targets'
/// frames at 10 Hz, rescans on AX notifications and once a second, and checks which other
/// windows sit in front of Settings.
final class CoachWorker: @unchecked Sendable {
    var onObservation: ((CoachObservation) -> Void)?

    private let strings: CoachStrings
    private let ourPID: pid_t
    private let keepTree: Bool
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var stopped = false
    private var timer: CFRunLoopTimer?

    // Worker-thread state
    private var settingsPID: pid_t?
    private var extensionPIDs: [pid_t] = []
    private var skipUntil: [pid_t: Date] = [:]
    private var lastExtensionScan = Date.distantPast
    private var observers: [pid_t: AXObserver] = [:]
    private var dirty = true
    private var lastFull = Date.distantPast
    private var tree = AXNodeSnapshot("AXApplication")
    private var refs: [Int: AXUIElement] = [:]
    private var paths: [Int: [Int]] = [:]
    private var scene = CoachScene()
    private var lastPublished: (scene: CoachScene, occluders: [CGRect], onScreen: Bool)?

    static let maxNodes = 4000
    static let maxScanTime: CFTimeInterval = 0.35
    static let notifications = [
        kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification,
        kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification, kAXSheetCreatedNotification,
        kAXTitleChangedNotification,
    ]

    init(strings: CoachStrings, ourPID: pid_t, keepTree: Bool) {
        self.strings = strings
        self.ourPID = ourPID
        self.keepTree = keepTree
    }

    func start() {
        let t = Thread { [self] in self.threadMain() }
        t.name = "DotStudio.SetupCoach.AX"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        ready.wait()
    }

    func stop() {
        perform { [self] in
            self.stopped = true
            self.teardown()
            if let rl = self.runLoop { CFRunLoopStop(rl) }
        }
    }

    func setSettingsPID(_ pid: pid_t?) {
        perform { [self] in
            guard self.settingsPID != pid else { return }
            self.settingsPID = pid
            self.lastExtensionScan = .distantPast
            self.resetObservers()
            self.dirty = true
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        // AX calls give up after 0.25 s instead of the default 6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.05, 0.1, 0, 0) { [self] _ in
            self.tickOnWorker()
        }
        timer = t
        CFRunLoopAddTimer(runLoop, t, .defaultMode)
        ready.signal()
        while !stopped {
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 1, false) }
        }
        teardown()
        runLoop = nil
    }

    private func teardown() {
        if let t = timer { CFRunLoopTimerInvalidate(t); timer = nil }
        resetObservers()
        refs.removeAll()
        onObservation = nil
    }

    // MARK: Observers

    private func resetObservers() {
        for (pid, obs) in observers {
            let app = AXUIElementCreateApplication(pid)
            for n in Self.notifications { AXObserverRemoveNotification(obs, app, n as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers.removeAll()
    }

    private func ensureObservers(_ pids: [pid_t]) {
        for pid in observers.keys where !pids.contains(pid) {
            if let obs = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil {
            var obs: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, refcon in
                guard let refcon else { return }
                let worker = Unmanaged<CoachWorker>.fromOpaque(refcon).takeUnretainedValue()
                worker.noted(notification as String)
            }
            guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { continue }
            let app = AXUIElementCreateApplication(pid)
            for n in Self.notifications { AXObserverAddNotification(obs, app, n as CFString, refcon) }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
        }
    }

    /// An AX notification (worker thread): moves and resizes only need the targets'
    /// frames re-read (next tick); anything else asks for a new capture.
    private func noted(_ notification: String) {
        if notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification { return }
        dirty = true
    }

    // MARK: Tick

    private func tickOnWorker() {
        guard !stopped else { return }
        let now = Date()
        guard let pid = settingsPID else {
            if now.timeIntervalSince(lastFull) >= 1 {
                lastFull = now
                publish(CoachObservation(), force: true)
            }
            return
        }
        if now.timeIntervalSince(lastExtensionScan) >= 2 {
            lastExtensionScan = now
            extensionPIDs = Self.wallpaperExtensionPIDs()
            ensureObservers([pid] + extensionPIDs)
        }
        let since = now.timeIntervalSince(lastFull)
        if (dirty && since >= 0.25) || since >= 1 {
            fullCapture(pid: pid)
        } else {
            fastUpdate(pid: pid)
        }
    }

    private func fullCapture(pid: pid_t) {
        dirty = false
        let now = Date()
        lastFull = now
        skipUntil = skipUntil.filter { $0.value > now }
        let apps = [pid] + extensionPIDs.filter { skipUntil[$0] == nil }
        let result = AXCapture.capture(pids: apps, maxNodes: Self.maxNodes, maxTime: Self.maxScanTime)
        for p in result.unresponsive { skipUntil[p] = now.addingTimeInterval(10) }
        tree = result.tree
        refs = result.refs
        paths = result.paths
        scene = CoachMatcher.match(tree, strings: strings)
        var obs = observe(pids: Set(apps))
        obs.tree = keepTree ? tree : nil
        obs.axError = result.error
        publish(obs, force: true)
    }

    /// Re-read only the elements behind the current targets (a few AX calls), re-match.
    private func fastUpdate(pid: pid_t) {
        guard !scene.ids.isEmpty else {
            let obs = observe(pids: Set([pid] + extensionPIDs))
            publish(obs, force: false)
            return
        }
        var changed = false
        for id in scene.ids {
            guard let el = refs[id], let path = paths[id] else { continue }
            switch AXCapture.frameAndSelection(el) {
            case .gone:
                dirty = true
            case .ok(let frame, let selected):
                changed = AXCapture.patch(&tree, path: path[...], frame: frame, selected: selected) || changed
            case .failed:
                break
            }
        }
        if changed { scene = CoachMatcher.match(tree, strings: strings) }
        publish(observe(pids: Set([pid] + extensionPIDs)), force: false)
    }

    /// Whether a Settings window is on screen, and which other windows are in front of it.
    private func observe(pids: Set<pid_t>) -> CoachObservation {
        var obs = CoachObservation()
        obs.scene = scene
        obs.settingsRunning = true
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return obs }
        var occluders: [CGRect] = []
        for w in list {   // front to back
            guard let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { continue }
            if pids.contains(owner) && layer == 0 {
                obs.settingsOnScreen = true
                break
            }
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if layer == 0 && owner != ourPID && alpha > 0.05 && bounds.width > 40 && bounds.height > 40 {
                occluders.append(bounds)
            }
        }
        obs.occluders = occluders
        return obs
    }

    private func publish(_ obs: CoachObservation, force: Bool) {
        let key = (obs.scene, obs.occluders, obs.settingsOnScreen)
        if !force, let last = lastPublished, last.scene == key.0, last.occluders == key.1, last.onScreen == key.2 { return }
        lastPublished = key
        onObservation?(obs)
    }

    /// The Wallpaper settings extension's processes (System Settings shows the Wallpaper page
    /// from there; on some versions its sheet is that process's own window).
    static func wallpaperExtensionPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: 4096)
        let uid = getuid()
        var out: [pid_t] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            guard path.hasPrefix("/System/Library/ExtensionKit/Extensions/"),
                  path.contains("/Wallpaper.appex/") || path.contains("/ScreenSaver") else { continue }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid != uid { continue }
            out.append(pid)
        }
        return out
    }
}

// MARK: - Capturing the AX tree

enum AXCapture {
    static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXSelectedAttribute, kAXMainAttribute, kAXChildrenAttribute,
    ]

    struct Result {
        var tree: AXNodeSnapshot
        var refs: [Int: AXUIElement]
        var paths: [Int: [Int]]
        var error: String?
        /// Processes that didn't answer (skipped for a while: each costs a timeout).
        var unresponsive: [pid_t] = []
    }

    private final class Box {
        var node: AXNodeSnapshot
        var kids: [Box] = []
        init(_ n: AXNodeSnapshot) { node = n }
    }

    /// Breadth first from each app's windows, up to `maxNodes` elements or `maxTime` seconds.
    static func capture(pids: [pid_t], maxNodes: Int, maxTime: CFTimeInterval) -> Result {
        let start = CACurrentMediaTime()
        let root = Box(AXNodeSnapshot("AXApplication", title: "System Settings"))
        var refs: [Int: AXUIElement] = [:]
        var queue: [(AXUIElement, Box, Int)] = []
        var nextID = 0
        var error: String?
        var unresponsive: [pid_t] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            if err == .apiDisabled { error = "Accessibility isn't allowed for DotStudio" }
            else if err == .cannotComplete {
                if pid == pids.first { error = "System Settings isn't answering" } else { unresponsive.append(pid) }
            }
            guard err == .success, let windows = windowsRef as? [AnyObject] else { continue }
            var focusedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
            for w in windows where CFGetTypeID(w) == AXUIElementGetTypeID() {
                let el = unsafeBitCast(w, to: AXUIElement.self)
                var n = AXNodeSnapshot("AXWindow")
                if let f = focusedRef, CFEqual(f, el) { n.focused = true }
                let box = Box(n)
                root.kids.append(box)
                queue.append((el, box, 0))
            }
        }
        var head = 0
        while head < queue.count {
            if nextID >= maxNodes || CACurrentMediaTime() - start > maxTime { break }
            let (el, box, depth) = queue[head]; head += 1
            let id = nextID; nextID += 1
            refs[id] = el
            box.node.id = id
            guard let values = read(el, attributes) else { continue }
            let wasFocused = box.node.focused
            fill(&box.node, values)
            if wasFocused == true { box.node.focused = true }
            if box.node.role == "AXMenuBar" || depth >= 60 { continue }
            if let kids = values[kAXChildrenAttribute] as? [AnyObject] {
                for k in kids.prefix(400) where CFGetTypeID(k) == AXUIElementGetTypeID() {
                    let child = Box(AXNodeSnapshot("AXUnknown"))
                    box.kids.append(child)
                    queue.append((unsafeBitCast(k, to: AXUIElement.self), child, depth + 1))
                }
            }
        }
        // Unvisited boxes (budget ran out) are dropped.
        var paths: [Int: [Int]] = [:]
        func build(_ b: Box, path: [Int]) -> AXNodeSnapshot {
            var n = b.node
            if let id = n.id { paths[id] = path }
            var kids: [AXNodeSnapshot] = []
            for k in b.kids where k.node.id != nil {
                kids.append(build(k, path: path + [kids.count]))
            }
            n.children = kids
            return n
        }
        var tree = root.node
        var kids: [AXNodeSnapshot] = []
        for k in root.kids where k.node.id != nil { kids.append(build(k, path: [kids.count])) }
        tree.children = kids
        return Result(tree: tree, refs: refs, paths: paths, error: error, unresponsive: unresponsive)
    }

    /// Several attributes in one round trip; missing ones are left out.
    static func read(_ el: AXUIElement, _ names: [String]) -> [String: AnyObject]? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let arr = values as? [AnyObject], arr.count == names.count else { return nil }
        var out: [String: AnyObject] = [:]
        for (name, v) in zip(names, arr) {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(v, to: AXValue.self)) == .axError { continue }
            out[name] = v
        }
        return out
    }

    private static func string(_ o: AnyObject?) -> String? {
        if let s = o as? String { return s.count > 200 ? String(s.prefix(200)) : s }
        if let n = o as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        if let n = o as? NSNumber { return n.boolValue ? "1" : "0" }
        return nil
    }

    static func frame(_ values: [String: AnyObject]) -> CGRect? {
        guard let p = values[kAXPositionAttribute], let s = values[kAXSizeAttribute],
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &pt),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private static func fill(_ n: inout AXNodeSnapshot, _ v: [String: AnyObject]) {
        n.role = (v[kAXRoleAttribute] as? String) ?? "AXUnknown"
        n.subrole = v[kAXSubroleAttribute] as? String
        n.identifier = v[kAXIdentifierAttribute] as? String
        n.title = string(v[kAXTitleAttribute])
        n.label = string(v[kAXDescriptionAttribute])
        n.value = string(v[kAXValueAttribute])
        n.help = string(v[kAXHelpAttribute])
        n.frame = frame(v)
        if let s = v[kAXSelectedAttribute] as? NSNumber { n.selected = s.boolValue }
        if let m = v[kAXMainAttribute] as? NSNumber, m.boolValue { n.focused = true }
    }

    enum Reread {
        case ok(CGRect?, Bool?)
        /// The element is gone (destroyed or replaced): capture again.
        case gone
        case failed
    }

    static func frameAndSelection(_ el: AXUIElement) -> Reread {
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXSelectedAttribute]
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if err == .invalidUIElement { return .gone }
        guard err == .success, let arr = values as? [AnyObject], arr.count == names.count else { return .failed }
        var out: [String: AnyObject] = [:]
        for (name, v) in zip(names, arr) {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(v, to: AXValue.self)) == .axError {
                if name == kAXPositionAttribute { return .gone }
                continue
            }
            out[name] = v
        }
        return .ok(frame(out), (out[kAXSelectedAttribute] as? NSNumber)?.boolValue)
    }

    /// Writes a re-read frame/selection into the captured tree; true when it changed.
    static func patch(_ t: inout AXNodeSnapshot, path: ArraySlice<Int>, frame: CGRect?, selected: Bool?) -> Bool {
        guard let i = path.first else {
            var changed = false
            if t.frame != frame { t.frame = frame; changed = true }
            if let selected, t.selected != selected { t.selected = selected; changed = true }
            return changed
        }
        guard t.children.indices.contains(i) else { return false }
        return patch(&t.children[i], path: path.dropFirst(), frame: frame, selected: selected)
    }
}
