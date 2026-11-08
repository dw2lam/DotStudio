//  ContentView.swift — root: the style gallery, or the editor for one style.
//
//  Picking what plays (the everyday task) lives in the gallery; changing how a
//  style looks (the occasional task) lives in a dedicated editor you open by
//  double-clicking a tile. The two never compete for space.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
            OnboardingView()
                .environmentObject(model)
        }
        .onAppear { presentOnboardingIfNeeded() }
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
        guard !hasCompletedOnboarding, !Self.isRenderingShots,
              !model.showOnboarding, model.storeAlert == nil else { return }
        model.showOnboarding = true
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
