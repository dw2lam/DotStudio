//  ContentView.swift — root: the style gallery, or the editor for one style.
//
//  Picking what plays (the everyday task) lives in the gallery; changing how a
//  style looks (the occasional task) lives in a dedicated editor you open by
//  double-clicking a tile. The two never compete for space.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow

    /// Offscreen UI renders (Shots.swift) must never present the sheet or touch the flag.
    private static let isRenderingShots = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil

    var body: some View {
        ZStack {
            if let id = model.editingID, model.preset(id) != nil {
                EditorView(id: id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)),
                                            removal: .opacity))
            } else {
                LibraryView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.editingID)
        .frame(minWidth: 880, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSetupStatus()   // user may have just picked us in System Settings
        }
        .sheet(isPresented: $model.showOnboarding, onDismiss: {
            hasCompletedOnboarding = true   // finishing, skipping, or Esc all count
        }) {
            OnboardingView(initialStep: DemoHooks.onboardingCreate ? .pick : .welcome,
                           pickMode: DemoHooks.onboardingCreate ? .create : .presets)
                .environmentObject(model)
        }
        .onAppear {
            // Lets the Dock icon / menu bar reopen this window after it was closed.
            WallpaperController.shared.registerOpenMainWindow { openWindow(id: DotStudioApp.mainWindowID) }
            if DemoHooks.isActive { DemoHooks.apply(to: model) } else { presentOnboardingIfNeeded() }
        }
        .onChange(of: model.storeAlert == nil) { _, clear in
            if clear { presentOnboardingIfNeeded() }   // wait out a launch-time library alert
        }
        .alert(item: $model.storeAlert) { alert in
            if let backup = alert.backupURL {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Reveal Backup in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    },
                    secondaryButton: .cancel(Text("OK")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message),
                         dismissButton: .default(Text("OK")))
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding, !Self.isRenderingShots, !DemoHooks.isActive,
              !model.showOnboarding, model.storeAlert == nil else { return }
        model.showOnboarding = true
    }
}

/// DEV-ONLY hooks for website screen grabs; inert unless one of these env vars is set:
///   DOTSTUDIO_DEMO_EDIT=<style name>    open that style in the editor on launch
///   DOTSTUDIO_DEMO_ONBOARDING=create    open the welcome sheet on its "Create Your Own" tab
///   DOTSTUDIO_DEMO_WINDOW=1440x900      size the main window's content
///   DOTSTUDIO_DEMO_WALLPAPER=<name>     turn the live wallpaper on with that style
///                                       (WallpaperController.applyDevOverrides; more knobs there)
///   DOTSTUDIO_DEMO_CLOSE_WINDOW=1       close the main window after launch (wallpaper-only,
///                                       as after a login launch) for power measurements
///   DOTSTUDIO_DEMO_COVER_DESKTOP=<s>    for <s> seconds, hide the desktop behind an opaque,
///                                       click-through window ordered beneath every app window,
///                                       to verify the occlusion pause without touching others' windows
/// While any is set the first-launch sheet never auto-presents. Pair with DOTSTUDIO_STORE_DIR.
enum DemoHooks {
    private static let env = ProcessInfo.processInfo.environment
    static let editName = env["DOTSTUDIO_DEMO_EDIT"]
    static let onboardingCreate = env["DOTSTUDIO_DEMO_ONBOARDING"] == "create"
    static let windowSize: CGSize? = env["DOTSTUDIO_DEMO_WINDOW"].flatMap { s in
        let p = s.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
    static let wallpaperName = env["DOTSTUDIO_DEMO_WALLPAPER"]
    static let closeWindow = env["DOTSTUDIO_DEMO_CLOSE_WINDOW"] == "1"
    static let coverSeconds = env["DOTSTUDIO_DEMO_COVER_DESKTOP"].flatMap(Double.init)
    private static var cover: NSWindow?
    static var isActive: Bool {
        editName != nil || onboardingCreate || windowSize != nil || wallpaperName != nil || closeWindow
            || coverSeconds != nil
    }

    @MainActor static func apply(to model: AppModel) {
        if let name = editName, let p = model.library.presets.first(where: { $0.name == name }) {
            model.edit(p.id)
        }
        DispatchQueue.main.async {
            if let size = windowSize,
               let win = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                win.setContentSize(size)
                win.center()
            }
            if onboardingCreate { model.showOnboarding = true }
        }
    }

    /// The wallpaper hooks run from applicationDidFinishLaunching — they must work even
    /// when no main window is restored (as after a login launch).
    @MainActor static func applyAtLaunch() {
        if closeWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.close() }
            }
        }
        if let secs = coverSeconds, let screen = NSScreen.screens.first {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = NSColor(white: 0.12, alpha: 1)
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.orderFront(nil)
            w.orderBack(nil)      // beneath every app window: hides only the desktop
            cover = w
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { cover?.orderOut(nil); cover = nil }
        }
    }
}

/// Shared "what does this style do for the screensaver right now" badge.
struct RoleBadge: View {
    let role: AppModel.Role

    var body: some View {
        if let (text, symbol) = content {
            Label(text, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
        }
    }

    private var content: (String, String)? {
        switch role {
        case .none, .rotating: return nil
        case .active: return ("Screensaver", "checkmark")
        case .day: return ("Day", "sun.max.fill")
        case .night: return ("Night", "moon.fill")
        case .dayAndNight: return ("Day & Night", "circle.lefthalf.filled")
        }
    }
}
