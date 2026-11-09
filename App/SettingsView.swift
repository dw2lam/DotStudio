//  SettingsView.swift — rarely-touched, library-wide settings (⌘,).
//  What plays (mode, rotation, day/night) lives in the main window's Playback
//  panel; this is only setup, transitions, performance, and updates.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController

    var body: some View {
        Form {
            setupSection
            WallpaperSettingsSection()
            transitionsSection
            performanceSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            model.refreshSetupStatus()
            updates.refreshStatus()
        }
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
            HStack(alignment: .center, spacing: 12) {
                updateIcon
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updateHeadline).font(.body.weight(.medium))
                    Text(updateDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(updateButtonTitle) { updates.primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(isUpdateReady || isUpdateAvailable ? .accentColor : .secondary)
                    .disabled(!updates.canCheck && !isUpdateReady)
            }
            .padding(.vertical, 2)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updates.automaticallyInstalls },
                set: { updates.automaticallyInstalls = $0 }))
                .disabled(!updates.automaticallyChecks)
            Text("New versions come from DotStudio's GitHub releases. They download in the background and install the next time you quit — the screensaver updates along with the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isUpdateReady: Bool {
        if case .readyToInstall = updates.state { return true } else { return false }
    }
    private var isUpdateAvailable: Bool {
        if case .available = updates.state { return true } else { return false }
    }

    @ViewBuilder private var updateIcon: some View {
        switch updates.state {
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        case .readyToInstall, .available:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle, .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var updateHeadline: String {
        switch updates.state {
        case .checking: return "Checking for updates…"
        case .downloading(let v): return "Downloading DotStudio \(v)…"
        case .available(let v): return "DotStudio \(v) is available"
        case .readyToInstall(let v): return "DotStudio \(v) is ready to install"
        case .failed: return "Couldn't check for updates"
        case .idle, .upToDate: return "DotStudio \(updates.currentVersion) is up to date"
        }
    }

    private var updateDetail: String {
        switch updates.state {
        case .readyToInstall: return "Restart now, or it installs when you quit."
        case .available: return "You're on \(updates.currentVersion)."
        case .failed(let why): return why
        case .downloading: return "This happens in the background."
        default:
            guard let d = updates.lastChecked else { return "Version \(updates.currentVersion)" }
            let rel = RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
            return "Version \(updates.currentVersion) · checked \(rel)"
        }
    }

    private var updateButtonTitle: String {
        switch updates.state {
        case .readyToInstall: return "Restart to Update"
        case .available: return "Update Now"
        default: return "Check Now"
        }
    }

    // MARK: Bindings

    private var qualityBinding: Binding<Double> {
        Binding(get: { model.library.renderScale ?? 1.0 },
                set: { model.library.renderScale = $0 >= 1.0 ? nil : $0; model.save() })
    }
}
