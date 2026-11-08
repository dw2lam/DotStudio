//  SettingsView.swift — rarely-touched, library-wide settings (⌘,).
//  What plays (mode, rotation, day/night) lives in the main window's Playback
//  panel; this is only setup, transitions, performance, and updates.

import SwiftUI
import Sparkle

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    let updater: SPUUpdater

    var body: some View {
        Form {
            setupSection
            transitionsSection
            performanceSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { model.refreshSetupStatus() }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section("Screensaver") {
            LabeledContent("Status") {
                switch model.setupStatus {
                case .ready:
                    Label("Installed and selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notChosen:
                    Label("Installed, not selected", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .notInstalled:
                    Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.setupStatus == .notInstalled ? "Install" : "Reinstall") { model.installScreensaver() }
                Button("Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
            }
            Text("Reinstall if the screensaver looks out of date — macOS picks up the new copy the next time it starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Transitions

    private var transitionsSection: some View {
        Section("Transitions") {
            LabeledContent("Crossfade") {
                HStack {
                    Slider(value: Binding(get: { model.rotation.transitionSeconds },
                                          set: { v in model.updateRotation { $0.transitionSeconds = v } }),
                           in: 0...3)
                    Text(model.rotation.transitionSeconds < 0.05
                         ? "Off" : String(format: "%.1f s", model.rotation.transitionSeconds))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Text("Blend between styles when rotating or at sunrise and sunset.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        Section("Performance") {
            Picker("Quality", selection: qualityBinding) {
                Text("Full").tag(1.0)
                Text("Balanced").tag(0.75)
                Text("Efficient").tag(0.5)
            }
            .pickerStyle(.segmented)
            Text("Balanced and Efficient render at reduced resolution — far less GPU memory and battery on Retina displays, same chunky look. On battery the frame rate also caps automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: autoCheck)
            LabeledContent("Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }

    // MARK: Bindings

    private var qualityBinding: Binding<Double> {
        Binding(get: { model.library.renderScale ?? 1.0 },
                set: { model.library.renderScale = $0 >= 1.0 ? nil : $0; model.save() })
    }

    private var autoCheck: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 })
    }
}
