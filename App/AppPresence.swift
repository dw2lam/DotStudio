//  AppPresence.swift — how DotStudio lives on the Mac: a Dock app while one of its windows
//  is open, a menu-bar item otherwise.
//
//  Menu-bar mode (Settings › General, ON by default):
//    • on  — closing the last window also drops the Dock icon (activation policy .accessory);
//            the DotStudio menu-bar item stays, so the live wallpaper (and music) keep going.
//    • off — closing the last window quits, unless a live wallpaper is playing: then DotStudio
//            stays in the menu bar for it and says so, once, in a popover under its icon.
//  Opening any window — from the menu bar, a second launch or Dock click (reopen), a
//  document, Settings — switches back to .regular and activates FIRST, so the window comes
//  up in front with DotStudio's own menu bar (AppKit installs the menu bar on an activation
//  change, so a menu-bar app that is already active steps aside and comes back).
//
//  Launch: Info.plist starts DotStudio as a UIElement (LSUIElement), so no Dock icon shows
//  before it knows why it was launched. While handling the launch's first Apple event (the
//  main window appears inside it; didFinishLaunching runs at its end) it decides once:
//    • launched as a login item (oapp with keyAEPropData = keyAELaunchedAsLogInItem — what
//      loginwindow sends SMAppService.mainApp items; on macOS 27 SwiftUI then skips the
//      window too) and there is a reason to live in the menu bar (menu-bar mode, or a
//      wallpaper to restore) → stay accessory: no window, no Dock icon;
//    • anything else → .regular before the app activates (no flicker, normal Dock launch);
//      a login launch with no reason to hide opens the main window itself, since SwiftUI
//      didn't ("Open DotStudio at login" in Dock-app mode means its window).
//
//  "App windows" are titled windows that are visible, minimized, or put away by Hide (⌘H,
//  another app's Hide Others): the main window(s), Settings, Sparkle's update windows,
//  open/save panels and alerts. Not: the wallpaper's desktop windows, the status item, menus,
//  popovers, floating utility panels (colours) or the borderless full-screen preview.
//  A hidden app's windows report isVisible == false, and unhiding is asynchronous, so the
//  windows on screen at Hide are remembered until AppKit has put them back; anything that
//  shows a window waits for that (whenUnhidden) instead of opening a second main window.
//
//  AppKit's own applicationShouldTerminateAfterLastWindowClosed isn't used: it counts the
//  wallpaper's desktop windows and the status item's window as open windows, so it would
//  never fire while either exists. This controller watches the windows itself.

import AppKit
import Combine
import SwiftUI

// MARK: - App-level preferences

/// App-level switches that aren't part of the shared library (the saver never reads them).
/// UserDefaults normally. Under DOTSTUDIO_STORE_DIR (tests, UI shots, dev builds) they live in
/// `<store>/app-prefs.json` instead, so a dev instance never reads or writes the user's real
/// defaults; `ephemeral()` keeps them in memory only (UI shots).
final class AppPrefs {
    static let shared = AppPrefs()

    private var fileURL: URL?
    private var values: [String: Bool] = [:]
    private var inMemory = false

    private init() {
        if let dir = ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("app-prefs.json")
            fileURL = url
            values = (try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))) ?? [:]
        }
    }

    /// Never persist again (offscreen renders flip switches per render).
    func ephemeral() { inMemory = true }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        if fileURL != nil || inMemory { return values[key] ?? fallback }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    func set(_ value: Bool, _ key: String) {
        if fileURL != nil || inMemory {
            values[key] = value
            guard !inMemory, let fileURL else { return }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(values).write(to: fileURL, options: .atomic)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

// MARK: - Presence

final class AppPresence: NSObject, ObservableObject {
    static let shared = AppPresence()

    static let menuBarModeKey = "menuBarMode"
    static let stayNoticeKey = "menuBarStayNoticeShown"

    /// Settings › General › "Keep running in the menu bar". On by default.
    @Published var menuBarMode: Bool {
        didSet {
            guard menuBarMode != oldValue else { return }
            AppPrefs.shared.set(menuBarMode, Self.menuBarModeKey)
            log("menu-bar mode \(menuBarMode ? "on" : "off")")
            if menuBarMode { closeNotice() }   // the "still running" notice is moot now
            refreshMenuBarItem()
        }
    }

    /// The DotStudio menu-bar item is shown: menu-bar mode, or a live wallpaper to control.
    /// (Music adds its track and controls to the item while it's shown — it never puts the
    /// item up by itself: with menu-bar mode off, closing the window quits, as planned.)
    @Published private(set) var showsMenuBarItem: Bool

    /// This launch came from the login item and started in the menu bar.
    private(set) var startedHidden = false

    /// Offscreen renders (Shots.swift) build ContentView and the menu many times over: they
    /// must never change the activation policy or open anything.
    private let inert = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil
        || ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] != nil

    fileprivate weak var model: AppModel?
    private var openMainWindowAction: (() -> Void)?
    private var openSettingsAction: (() -> Void)?
    private var wantsMainWindow = false
    private var launchDecided = false
    private var launched = false
    private var observers: [NSObjectProtocol] = []
    private var wallpaperSub: AnyCancellable?
    private var wallpaperWasActive = false
    private var accessoryWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var notice: NSPopover?
    private var noticePanel: NSPanel?
    /// The app windows on screen when DotStudio was hidden; they count as open (they come
    /// back on unhide) until AppKit has put them back or they close.
    private static let hiddenWindows = NSHashTable<NSWindow>.weakObjects()
    private var unhideWaiters: [() -> Void] = []
    private var unhideTimeout: DispatchWorkItem?

    private override init() {
        let on = AppPrefs.shared.bool(Self.menuBarModeKey, default: true)
        menuBarMode = on
        showsMenuBarItem = on
        super.init()
    }

    // MARK: Lifecycle

    /// Called once from App.init, after WallpaperController.attach.
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        wallpaperWasActive = WallpaperController.shared.isActive
        refreshMenuBarItem()
        wallpaperSub = WallpaperController.shared.objectWillChange
            .receive(on: DispatchQueue.main)      // objectWillChange fires before the change
            .sink { [weak self] _ in self?.wallpaperChanged() }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
                // Only a window the user could see: SwiftUI also creates and closes windows that
                // never appear (e.g. while handling a document at launch).
                guard let w = n.object as? NSWindow, Self.isAppWindow(w) else { return }
                DispatchQueue.main.async {   // after AppKit has ordered it out
                    Self.hiddenWindows.remove(w)
                    self?.windowClosed(w)
                }
            },
            // Synchronous (queue nil): the windows are still on screen when Hide is announced.
            nc.addObserver(forName: NSApplication.willHideNotification, object: nil, queue: nil) { _ in
                for w in NSApp.windows where w.isVisible && Self.isAppWindow(w) { Self.hiddenWindows.add(w) }
            },
            nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
                Self.hiddenWindows.removeAllObjects()   // back on screen: isVisible tells the truth again
                self?.runUnhideWaiters()
            },
            // The setup state can change in System Settings while no DotStudio window is open
            // (the main window refreshes it on activation): refresh it as a menu opens, so the
            // menu-bar menu's Screensaver line is current.
            nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
                guard let menu = n.object as? NSMenu, menu !== NSApp.mainMenu, menu.supermenu == nil else { return }
                self?.model?.refreshSetupStatus()
            },
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                self?.windowShown(n.object as? NSWindow)
            },
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] n in
                self?.windowShown(n.object as? NSWindow)
            },
        ]
    }

    /// The launch decision (see the header). Runs at the earliest of: the main window
    /// appearing during launch (`windowAppeared`), or didFinishLaunching — both inside the
    /// launch's first Apple event, before the app activates.
    func decideLaunch(windowAppeared: Bool = true) {
        guard !launchDecided, !inert else { return }
        launchDecided = true
        let login = Self.launchedAsLoginItem()
        let wallpaper = WallpaperController.shared.isActive   // restored at didFinishLaunching
        startedHidden = login && (menuBarMode || wallpaper)
        if startedHidden {
            // SwiftUI already skips the window for a login launch on macOS 27; earlier systems
            // may have opened it. Ordered out first, so its close doesn't count as the user's
            // (only visible windows do).
            for w in mainWindows() { w.orderOut(nil); w.close() }
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        } else {
            NSApp.setActivationPolicy(.regular)
            if login && !windowAppeared {
                // A Dock app opened at login: SwiftUI skipped the window (macOS 27 does for
                // login launches), which would leave a Dock icon with nothing behind it.
                // Once the launch event is done, unless a window turned up after all.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.mainWindows().isEmpty else { return }
                    self.log("login launch as a Dock app, no window → open the main window")
                    self.showMainWindow()
                }
            }
        }
        log("launch login=\(login) wallpaper=\(wallpaper) menuBarMode=\(menuBarMode) → \(startedHidden ? "menu bar (accessory)" : "regular")")
    }

    /// applicationDidFinishLaunching.
    func didFinishLaunching() {
        decideLaunch(windowAppeared: false)
        if startedHidden {
            // macOS 14/15 may still be ordering the main window in when decideLaunch ran (from
            // its onAppear, before it was visible, so mainWindows() skipped it). One run-loop
            // turn later, put away every main window by identifier — visible or not. (macOS 27
            // opens none for a login launch: nothing to do there.)
            DispatchQueue.main.async { [weak self] in self?.putAwayLaunchWindows() }
        }
        launched = true
        wallpaperWasActive = WallpaperController.shared.isActive
        refreshMenuBarItem()
        listenForDevCommands()
    }

    /// A menu-bar login launch: close any main window SwiftUI opened anyway, and stay (or go
    /// back to) accessory if nothing else is open. Runs one turn after launch, before the user
    /// can have asked for a window.
    private func putAwayLaunchWindows() {
        let strays = NSApp.windows.filter { w in
            w.styleMask.contains(.titled) && !(w is WallpaperWindow)
                && (w.identifier?.rawValue.hasPrefix(DotStudioApp.mainWindowID + "-") ?? false)
        }
        guard !strays.isEmpty else { return }
        log("login launch: putting away \(strays.count) main window(s)")
        // Ordered out first, so their close doesn't count as the user's (only visible windows do).
        for w in strays { w.orderOut(nil); w.close() }
        if !hasAppWindows(), NSApp.activationPolicy() != .accessory {
            accessoryWork?.cancel(); accessoryWork = nil
            NSApp.setActivationPolicy(.accessory)
            log("policy accessory")
        }
    }

    /// SwiftUI's openWindow / openSettings, captured from a view's environment (the main
    /// window's root and the menu-bar label both register; either works).
    func register(openMainWindow: @escaping () -> Void, openSettings: (() -> Void)? = nil) {
        guard !inert else { return }
        openMainWindowAction = openMainWindow
        if let openSettings { openSettingsAction = openSettings }
        if wantsMainWindow {
            wantsMainWindow = false
            DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        }
    }

    // MARK: Opening windows

    /// Open (or bring forward) the main window: the menu bar's "Open DotStudio", reopen, documents.
    func showMainWindow() {
        closeNotice()
        becomeRegular(activate: true)
        whenUnhidden { [weak self] in
            guard let self else { return }
            if let w = self.mainWindows().first {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            } else if let open = self.openMainWindowAction {
                open()
            } else if NSApp.delegate?.applicationOpenUntitledFile?(NSApp) == true {
                // No view has handed over openWindow yet: SwiftUI's own "open untitled" opens
                // the main WindowGroup's window.
            } else {
                self.wantsMainWindow = true   // opened as soon as a view registers openWindow
            }
            self.bringToFront { [weak self] in self?.mainWindows().first }
            self.settleSoon()
        }
    }

    /// Settings… from the menu bar (⌘, inside the app goes through SwiftUI directly).
    func showSettings() {
        closeNotice()
        becomeRegular(activate: true)
        whenUnhidden { [weak self] in
            if let w = Self.settingsWindow(), Self.isOpen(w) {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            } else if let open = self?.openSettingsAction {   // SwiftUI keeps a closed Settings window; let it reopen it
                open()
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            self?.bringToFront { Self.settingsWindow() }
            self?.settleSoon()
        }
    }

    /// Check for Updates… from the menu bar: Sparkle's windows need a regular, active app.
    func checkForUpdates(_ updates: UpdateController) {
        closeNotice()
        becomeRegular(activate: true)
        whenUnhidden { [weak self] in
            updates.primaryAction()
            self?.settleSoon(after: 3)
        }
    }

    /// Runs `body` once DotStudio isn't hidden: right away, or when AppKit has put its hidden
    /// windows back. Callers have already started the unhide (becomeRegular(activate: true)
    /// unhides; it's asynchronous). Until it lands the windows aren't visible and can't be
    /// brought forward. Never waits more than a second.
    private func whenUnhidden(_ body: @escaping () -> Void) {
        guard NSApp.isHidden else { body(); return }
        unhideWaiters.append(body)
        log("hidden — waiting for unhide")
        guard unhideTimeout == nil else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.runUnhideWaiters() }
        unhideTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func runUnhideWaiters() {
        unhideTimeout?.cancel()
        unhideTimeout = nil
        let waiting = unhideWaiters
        unhideWaiters = []
        waiting.forEach { $0() }
    }

    /// A second launch, or a Dock click. Returns false when SwiftUI should open its default
    /// window itself (nothing has registered openWindow yet and no window exists).
    func reopen() -> Bool {
        if mainWindows().isEmpty && openMainWindowAction == nil {
            becomeRegular(activate: true)
            return false
        }
        showMainWindow()
        return true
    }

    /// Files and URLs handed to DotStudio (a double-clicked .dotstudiopreset).
    func open(_ urls: [URL]) {
        let presets = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "dotstudiopreset" }
        log("open \(urls.count) url(s), \(presets.count) preset(s)")
        if !presets.isEmpty { model?.importPresets(from: presets) }
        showMainWindow()
    }

    // MARK: Policy

    /// Every titled window of DotStudio's own that the user can see or get back (minimized,
    /// or hidden with the app).
    static func isAppWindow(_ w: NSWindow) -> Bool {
        if w is WallpaperWindow { return false }
        guard w.styleMask.contains(.titled) else { return false }      // status item, menus, popovers, preview
        if let panel = w as? NSPanel, panel.isFloatingPanel { return false }   // colour / font panels
        return isOpen(w)
    }

    /// On screen, minimized, or put away by Hide (it comes back on unhide).
    private static func isOpen(_ w: NSWindow) -> Bool {
        w.isVisible || w.isMiniaturized || hiddenWindows.contains(w)
    }

    private func hasAppWindows(excluding gone: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { $0 !== gone && Self.isAppWindow($0) }
    }

    func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { w in
            w.styleMask.contains(.titled) && !(w is WallpaperWindow)
                && (w.identifier?.rawValue.hasPrefix(DotStudioApp.mainWindowID + "-") ?? false)
                && Self.isOpen(w)
        }
    }

    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true && $0.styleMask.contains(.titled) }
    }

    /// Dock icon + the app's own menu bar, now. `activate` brings DotStudio forward too.
    private func becomeRegular(activate: Bool) {
        accessoryWork?.cancel()
        accessoryWork = nil
        var bounce = false
        if NSApp.activationPolicy() != .regular {
            bounce = activate && NSApp.isActive
            NSApp.setActivationPolicy(.regular)
            log("policy regular")
        }
        guard activate else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if bounce {
            // Already active as a menu-bar app (LaunchServices activates before a reopen):
            // AppKit installs the menu bar only on an activation change.
            NSApp.deactivate()
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// After a window opens: make sure it ends up key and in front even if activation
    /// landed a beat late (the classic accessory-app "window opens behind" bug).
    private func bringToFront(_ window: @escaping () -> NSWindow?) {
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let w = window(), w.isVisible, !w.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// If nothing ended up on screen (a window failed to open, Sparkle stayed silent), go
    /// back to the menu bar rather than leave a Dock icon with no window behind it.
    private func settleSoon(after seconds: Double = 1.5) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.launched, !self.hasAppWindows() else { return }
            if self.menuBarMode || WallpaperController.shared.isActive { self.enterMenuBar() }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Drop the Dock icon after a short grace period (closing one window often opens another,
    /// e.g. the main window → Settings), then give activation back to the app underneath.
    private func enterMenuBar() {
        accessoryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasAppWindows() else { return }
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
                self.log("policy accessory")
            }
            // So the app underneath gets its menu bar back, and DotStudio's next activation
            // is a real change (AppKit only installs the menu bar then).
            if NSApp.isActive { NSApp.deactivate() }
        }
        accessoryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func windowShown(_ window: NSWindow?) {
        guard launched, let w = window, Self.isAppWindow(w), w.isVisible else { return }
        // A window opened some other way (Sparkle's own alert, a panel): it needs a Dock icon.
        // Activation stays with whoever opened it.
        if NSApp.activationPolicy() != .regular || accessoryWork != nil { becomeRegular(activate: false) }
    }

    private func windowClosed(_ window: NSWindow) {
        guard launched, !hasAppWindows(excluding: window) else { return }
        if menuBarMode {
            log("last window closed → menu bar")
            enterMenuBar()
        } else if WallpaperController.shared.isActive {
            log("last window closed, menu-bar mode off, wallpaper playing → menu bar")
            enterMenuBar()
            showStayNoticeOnce()
        } else {
            log("last window closed, menu-bar mode off → quit")
            NSApp.terminate(nil)
        }
    }

    private func wallpaperChanged() {
        let active = WallpaperController.shared.isActive
        refreshMenuBarItem()
        defer { wallpaperWasActive = active }
        // Menu-bar mode off and DotStudio was only still running for the wallpaper.
        guard launched, wallpaperWasActive, !active, !menuBarMode, !hasAppWindows() else { return }
        log("wallpaper stopped with no window, menu-bar mode off → quit")
        NSApp.terminate(nil)
    }

    private func refreshMenuBarItem() {
        let shows = menuBarMode || WallpaperController.shared.isActive
        if shows != showsMenuBarItem { showsMenuBarItem = shows }
    }

    // MARK: Login launch

    /// loginwindow launches login items (SMAppService.mainApp included) with an 'oapp' event
    /// whose keyAEPropData is keyAELaunchedAsLogInItem. Valid only while that event is being
    /// handled: from the first window's creation through didFinishLaunching.
    /// DOTSTUDIO_DEMO_LOGIN_LAUNCH=1 treats any launch as one.
    static func launchedAsLoginItem() -> Bool {
        if DemoHooks.loginLaunch { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: "Still running" notice (menu-bar mode off, wallpaper on)

    /// Until the owner has answered it once. It counts as seen only when answered (OK, Quit,
    /// or the menu-bar-mode link): it stays up until then — through app switches, a locked
    /// screen, time away — so it can't be used up unseen. Opening a window puts it away; it
    /// comes back the next time the window closes with the wallpaper playing.
    private func showStayNoticeOnce() {
        guard !AppPrefs.shared.bool(Self.stayNoticeKey, default: false) else { return }
        // After the Dock icon has gone, so the popover isn't dismissed by the switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Still true? (A window may have reopened, or the wallpaper stopped, meanwhile.)
            guard let self, !self.menuBarMode, WallpaperController.shared.isActive, !self.hasAppWindows() else { return }
            self.presentStayNotice()
        }
    }

    private func presentStayNotice() {
        closeNotice()
        let anchor = Self.statusItemButton()
        let answered = { AppPrefs.shared.set(true, Self.stayNoticeKey) }
        let view = MenuBarStayNotice(
            quit: { answered(); NSApp.terminate(nil) },
            keepRunning: { [weak self] in answered(); self?.closeNotice() },
            turnOnMenuBarMode: { [weak self] in answered(); self?.menuBarMode = true; self?.closeNotice() },
            ownBackground: anchor == nil)
            .adaptiveLayout()
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        if let anchor {
            let pop = NSPopover()
            pop.behavior = .applicationDefined   // stays until answered (see showStayNoticeOnce)
            pop.animates = true
            pop.contentViewController = host
            pop.contentSize = host.view.fittingSize
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            notice = pop
            log("stay notice shown under the menu-bar icon")
        } else if let screen = NSScreen.main {
            // No status-item button to point at: a small panel under the menu bar, top right.
            let size = host.view.fittingSize
            let frame = NSRect(x: screen.visibleFrame.maxX - size.width - Space.s,
                               y: screen.visibleFrame.maxY - size.height - Space.s,
                               width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentViewController = host
            panel.orderFrontRegardless()
            noticePanel = panel
            log("stay notice shown as a panel (no status-item button found)")
        }
    }

    private func closeNotice() {
        notice?.performClose(nil)
        notice = nil
        noticePanel?.orderOut(nil)
        noticePanel = nil
    }

    /// The menu-bar item's button (SwiftUI's MenuBarExtra keeps its NSStatusItem private).
    private static func statusItemButton() -> NSView? {
        func find(_ v: NSView?) -> NSView? {
            guard let v else { return nil }
            if v is NSStatusBarButton { return v }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return NSApp.windows
            .filter { $0.className.contains("StatusBar") && $0.isVisible && $0.frame.width > 0 }
            .lazy.compactMap { find($0.contentView) }.first
    }

    // MARK: Dev

    fileprivate func log(_ message: String) {
        model?.store.debug("[presence \(String(format: "%.3f", CACurrentMediaTime()))] \(message) · policy=\(Self.policyName) windows=\(NSApp.windows.filter { Self.isAppWindow($0) }.count)")
    }

    private static var policyName: String {
        switch NSApp.activationPolicy() {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "?"
        }
    }

    static let devCommandName = Notification.Name("com.davidlam.DotStudio.dev.command")

    /// DOTSTUDIO_DEV_COMMANDS=1: drive the same code paths as the menu items from a test
    /// script, by distributed notification (object = this process's pid, userInfo["command"]):
    /// open · settings · close (performClose on every app window, like the red ✕) ·
    /// wallpaper-stop · wallpaper:<style name> · menubar:on|off · add-built-ins · state ·
    /// menu (log the menu-bar menu's music, screensaver + wallpaper items as AppKit builds them) ·
    /// menu-pick:<submenu>/<item> (choose that item, as a click would) · quit.
    private func listenForDevCommands() {
        guard DemoHooks.devCommands else { return }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(devCommand(_:)), name: Self.devCommandName,
            object: String(ProcessInfo.processInfo.processIdentifier), suspensionBehavior: .deliverImmediately)
        log("dev commands on")
    }

    @objc private func devCommand(_ note: Notification) {
        guard let command = note.userInfo?["command"] as? String else { return }
        log("dev command \(command)")
        switch command {
        case "open": showMainWindow()
        case "settings": showSettings()
        case "close": NSApp.windows.filter { Self.isAppWindow($0) }.forEach { $0.performClose(nil) }
        case "wallpaper-stop": WallpaperController.shared.stop()
        case "menubar:on": menuBarMode = true
        case "menubar:off": menuBarMode = false
        case "state":
            let wins = NSApp.windows.map { w in
                "#\(w.windowNumber) \(type(of: w))\(w.isVisible ? "+vis" : "")\(Self.isAppWindow(w) ? "+app" : "") '\(w.title)'"
            }
            let shownNotice = notice.map { $0.isShown && ($0.contentViewController?.view.window?.isVisible ?? false) } ?? (noticePanel?.isVisible ?? false)
            log("state menuBarItem=\(showsMenuBarItem) wallpaper=\(WallpaperController.shared.isActive) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) putAway=\(Self.hiddenWindows.count) main=\(mainWindows().count) settings=\(Self.settingsWindow().map(Self.isOpen) ?? false) notice=\(shownNotice) noticeAnswered=\(AppPrefs.shared.bool(Self.stayNoticeKey, default: false)) setup=\(model.map { "\($0.setupStatus)" } ?? "?") all=[\(wins.joined(separator: ", "))]")
        case "add-built-ins": model?.addDemoPack()
        case "menu": devMenu(pick: nil)
        case "quit": NSApp.terminate(nil)   // the menu's Quit (applicationWillTerminate runs)
        default:
            if command.hasPrefix("wallpaper:"), let p = model?.library.presets.first(where: { $0.name == String(command.dropFirst(10)) }) {
                WallpaperController.shared.use(p.id)
            } else if command.hasPrefix("menu-pick:") {
                devMenu(pick: String(command.dropFirst(10)))
            }
        }
    }
}

// MARK: - Dev: the menu as AppKit builds it

extension AppPresence {
    /// The menu-bar menu's music, screensaver and wallpaper items, built into a real NSMenu the way
    /// MenuBarExtra builds them (NSHostingMenu, macOS 15+), so a test can read titles, check
    /// marks and submenus — and choose an item — without opening a menu on screen.
    fileprivate func devMenu(pick: String?) {
        guard #available(macOS 15, *), let model else { return }
        let menu = NSHostingMenu(rootView: Group {
            MenuBarMusicSlot(); ScreensaverMenu(); Divider(); WallpaperMenu()
        }.environmentObject(model))
        menu.update()
        func lines(_ m: NSMenu, _ depth: Int) -> [String] {
            m.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [String(repeating: "  ", count: depth) + "───"] }
                let mark = item.state == .on ? "✓ " : ""
                let flags = (item.isSectionHeader ? " [header]" : "") + (item.isEnabled ? "" : " [disabled]")
                    + (item.image.map { " [image \(Int($0.size.width))x\(Int($0.size.height))]" } ?? "")
                var out = [String(repeating: "  ", count: depth) + mark + item.title + flags]
                if let sub = item.submenu { sub.update(); out += lines(sub, depth + 1) }
                return out
            }
        }
        if let pick {
            let parts = pick.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sub = menu.items.first(where: { $0.title == parts[0] })?.submenu else {
                log("menu-pick: no submenu \(pick)"); return
            }
            sub.update()
            guard let i = sub.items.firstIndex(where: { $0.title == parts[1] }) else { log("menu-pick: no item \(pick)"); return }
            sub.performActionForItem(at: i)
            log("menu-pick \(pick)")
        } else {
            log("menu:\n" + lines(menu, 1).joined(separator: "\n"))
        }
    }
}

// MARK: - Notice

/// The one-time explanation when menu-bar mode is off but a live wallpaper keeps DotStudio
/// running after its window closed.
struct MenuBarStayNotice: View {
    var quit: () -> Void
    var keepRunning: () -> Void
    var turnOnMenuBarMode: () -> Void
    /// Drawn on its own material (the fallback panel); a popover brings its own.
    var ownBackground = false
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .body) private var width: CGFloat = Space.grid(72)   // 288

    var body: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text("DotStudio is still running")
                    .textRole(.headline)
                    .wrapping()
                Text("Your live wallpaper keeps playing from the menu bar. Stop it or quit DotStudio there whenever you like.")
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            Button(action: turnOnMenuBarMode) {
                Text("Always keep DotStudio in the menu bar")
                    .textRole(.callout)
                    .wrapping()
            }
            .buttonStyle(.link)
            ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.controlGap) {
                Button(scaled: "Quit DotStudio", action: quit)
                Button(scaled: "OK", action: keepRunning)
                    .keyboardShortcut(.defaultAction)
            }
            .adaptiveControlSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: width, alignment: .leading)   // the popover sizes to it; narrower hosts wrap
        .background {
            if ownBackground {
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.regularMaterial)
            }
        }
    }
}
