//  SettingsView.swift — library-wide screensaver settings (⌘,).
//  Per-preset editing stays in the Inspector; everything that applies to the
//  whole library (playback mode, quality, updates) lives here.

import SwiftUI
import Sparkle

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    let updater: SPUUpdater

    private enum Mode: String, CaseIterable, Identifiable {
        case single = "Single style"
        case rotate = "Rotate styles"
        case dayNight = "Day & night"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            playbackSection
            performanceSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section {
            Picker("Mode", selection: mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode.wrappedValue {
            case .single:
                LabeledContent("Showing", value: model.activeName)
                Text("The screensaver plays the style marked Active. Pick a different one from the sidebar anytime.")
                    .font(.caption).foregroundStyle(.secondary)
            case .rotate:
                Picker("Change every", selection: rotation(\.intervalMinutes)) {
                    Text("1 minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                Toggle("Shuffle order", isOn: rotation(\.shuffle))
                crossfadeRow
                Text("Cycles through every style in your library. All displays stay in sync.")
                    .font(.caption).foregroundStyle(.secondary)
            case .dayNight:
                presetPicker("Day style", selection: schedule(\.dayPresetID))
                presetPicker("Night style", selection: schedule(\.nightPresetID))
                crossfadeRow
                LabeledContent("Right now", value: sunStatus)
                Text("Follows the sun at your location and crossfades at sunrise and sunset. Without a resolved location, your time zone stands in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Playback")
        }
    }

    private var crossfadeRow: some View {
        HStack {
            Text("Crossfade")
            Slider(value: rotation(\.transitionSeconds), in: 0...3)
            Text(rotation(\.transitionSeconds).wrappedValue == 0
                 ? "Off"
                 : String(format: "%.1f s", rotation(\.transitionSeconds).wrappedValue))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        Section {
            Picker("Quality", selection: qualityBinding) {
                Text("Full").tag(1.0)
                Text("Balanced").tag(0.75)
                Text("Efficient").tag(0.5)
            }
            .pickerStyle(.segmented)
            Text("Balanced and Efficient render at reduced resolution — far less GPU memory and battery on Retina displays, same chunky look. On battery the frame rate also caps automatically.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Performance")
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section {
            Toggle("Check for updates automatically", isOn: autoCheck)
            LabeledContent("Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Button("Check for Updates…") { updater.checkForUpdates() }
        } header: {
            Text("Updates")
        }
    }

    // MARK: Bindings & helpers

    /// Rotation vs day/night collapse into one mode — no fighting toggles.
    private var mode: Binding<Mode> {
        Binding(
            get: {
                if model.library.schedule?.enabled == true { return .dayNight }
                if model.library.rotation?.enabled == true { return .rotate }
                return .single
            },
            set: { m in
                var rot = model.library.rotation ?? RotationSpec()
                var sch = model.library.schedule ?? ScheduleSpec()
                rot.enabled = (m == .rotate)
                sch.enabled = (m == .dayNight)
                model.library.rotation = rot
                model.library.schedule = sch
                model.save()
            })
    }

    private func rotation<T>(_ kp: WritableKeyPath<RotationSpec, T>) -> Binding<T> {
        Binding(get: { (model.library.rotation ?? RotationSpec())[keyPath: kp] },
                set: {
                    var spec = model.library.rotation ?? RotationSpec()
                    spec[keyPath: kp] = $0
                    model.library.rotation = spec
                    model.save()
                })
    }

    private func schedule<T>(_ kp: WritableKeyPath<ScheduleSpec, T>) -> Binding<T> {
        Binding(get: { (model.library.schedule ?? ScheduleSpec())[keyPath: kp] },
                set: {
                    var spec = model.library.schedule ?? ScheduleSpec()
                    spec[keyPath: kp] = $0
                    model.library.schedule = spec
                    model.save()
                })
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { model.library.renderScale ?? 1.0 },
                set: { model.library.renderScale = $0 >= 1.0 ? nil : $0; model.save() })
    }

    private var autoCheck: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 })
    }

    private func presetPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(model.library.presets) { p in
                Text(p.name).tag(UUID?.some(p.id))
            }
        }
    }

    private var sunStatus: String {
        let deg = MetalRenderer.solarElevation(location: model.locationTuple) * 180 / .pi
        return deg >= -0.833
            ? String(format: "Day — sun %.0f° above the horizon", max(deg, 0))
            : "Night"
    }
}
