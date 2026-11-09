//  SettingsView.swift — rarely-touched, library-wide settings (⌘,).
//  What plays (playlist, night style, wallpaper) lives in the main window's
//  destination cards; this is only setup, transitions, performance, and updates.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateController
    @Environment(\.layout) private var layout

    /// The Form grows with the text (its row labels do), from this width at the default size.
    @ScaledLength(relativeTo: .body) private var formWidth: CGFloat = SettingsMetrics.width
    @ScaledLength(relativeTo: .caption) private var valueWidth: CGFloat = SettingsMetrics.valueWidth
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth
    @ScaledLength(relativeTo: .title2) private var iconBox: CGFloat = SettingsMetrics.iconBox

    /// Offscreen UI shots (Shots.swift) render Settings at its natural height, so the review
    /// matrix shows every section; the real window opens at `SettingsMetrics.openHeight`.
    private static let isRenderingShots = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil

    var body: some View {
        Form {
            setupSection
            WallpaperSettingsSection()
            transitionsSection
            performanceSection
            updatesSection
        }
        .formStyle(.grouped)
        .textRole(.body)          // row labels follow the text size (macOS never scales them itself)
        .adaptiveControlSize()
        .frame(minWidth: SettingsMetrics.width, idealWidth: formWidth, maxWidth: formWidth)
        // All five sections run ~1100 pt — taller than a 13" display. Open shorter and let the
        // Form scroll; the window can still be dragged taller.
        .frame(minHeight: SettingsMetrics.minHeight,
               idealHeight: Self.isRenderingShots ? nil : SettingsMetrics.openHeight,
               maxHeight: .infinity)
        .onAppear {
            model.refreshSetupStatus()
            updates.refreshStatus()
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
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
            // Controls sit on the trailing edge like every other row, and wrap if they outgrow it.
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .trailing) {
                Button(scaled: model.setupStatus == .notInstalled ? "Install" : "Reinstall") { model.installScreensaver() }
                Button(scaled: "Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
            }
        } header: {
            SettingsHeader("Screensaver")
        } footer: {
            SettingsNote("Reinstall if the screensaver looks out of date — macOS picks up the new copy the next time it starts.")
        }
    }

    // MARK: Transitions

    private var transitionsSection: some View {
        Section {
            LabeledContent("Crossfade") {
                HStack(spacing: layout.controlGap) {
                    Slider(value: Binding(get: { model.rotation.transitionSeconds },
                                          set: { v in model.updateRotation { $0.transitionSeconds = v } }),
                           in: 0...3)
                    Text(model.rotation.transitionSeconds < 0.05
                         ? "Off" : String(format: "%.1f s", model.rotation.transitionSeconds))
                        .textRole(.value)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: valueWidth, alignment: .trailing)   // a minimum: the readout never truncates
                }
            }
        } header: {
            SettingsHeader("Transitions")
        } footer: {
            SettingsNote("Blend between styles as the playlist changes, and at sunrise and sunset.")
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        Section {
            LabeledContent("Quality") {
                Picker("Quality", selection: qualityBinding) {
                    Text("Full").tag(1.0)
                    Text("Balanced").tag(0.75)
                    Text("Efficient").tag(0.5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fillingSegments(width: segmentWidth)
            }
        } header: {
            // The screensaver's render scale — distinct from Live Wallpaper › Quality.
            SettingsHeader("Screensaver Performance")
        } footer: {
            SettingsNote("Balanced and Efficient render at reduced resolution — far less GPU memory and battery on Retina displays, same chunky look. On battery the frame rate also caps automatically.")
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section {
            // One row when it fits; the button drops under the status when it doesn't
            // (a long failure message, large text).
            ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.itemGap) {
                HStack(alignment: .center, spacing: layout.iconGap) {
                    updateIcon
                        .scaledFont { .scaled(.title2, $0) }
                        .frame(width: iconBox, alignment: .leading)   // icon on the Form's leading edge
                    VStack(alignment: .leading, spacing: layout.labelGap) {
                        Text(updateHeadline)
                            .textRole(.bodyEmphasis)
                            .wrapping()
                        Text(updateDetail)
                            .textRole(.caption)
                            .foregroundStyle(.secondary)
                            .wrapping()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(scaled: updateButtonTitle) { updates.primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(isUpdateReady || isUpdateAvailable ? .accentColor : .secondary)
                    .disabled(!updates.canCheck && !isUpdateReady)
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updates.automaticallyInstalls },
                set: { updates.automaticallyInstalls = $0 }))
                .disabled(!updates.automaticallyChecks)
        } header: {
            SettingsHeader("Updates")
        } footer: {
            SettingsNote("New versions come from DotStudio's GitHub releases. They download in the background and install the next time you quit — the screensaver updates along with the app.")
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

// MARK: - Shared Settings pieces (also used by WallpaperSettingsSection)

/// Settings' own metrics, at the default text size — local constants derived from the
/// Layout.swift scale. Views scale them with `@ScaledLength`.
enum SettingsMetrics {
    /// The Form's width (and the window's minimum).
    static let width: CGFloat = 460
    /// The window's opening height; the Form scrolls past it.
    static let openHeight = Space.grid(180)       // 720
    static let minHeight = Space.grid(100)        // 400
    /// Every segmented picker is this wide, so their leading edges line up in the value
    /// column (fits "Balanced · 30 fps | Smooth · display rate").
    static let segmentWidth = Space.grid(76)      // 304
    /// The Style pop-up's widest; a long style name truncates (full name in the tooltip).
    static let popUpMaxWidth = Space.grid(60)     // 240
    /// Minimum width of a slider's value readout ("1.5 s").
    static let valueWidth = Space.grid(9)         // 36
    /// The Updates status icon's column.
    static let iconBox = Space.grid(5)            // 20
}

/// A section header at a role size (a Form's own headers never follow the text size).
struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).textRole(.headline)
    }
}

/// Help text under a section's card — the Form's secondary style, without a row separator.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(.secondary)
            .wrapping()
    }
}

/// A button title that follows the text size. On macOS a `Button("…")` title keeps the
/// control's own font at every size; a Text label with a role scales (the bezel grows to fit).
struct RoleButtonTitle: View {
    let title: String

    var body: some View {
        Text(title).textRole(.body)
    }
}

extension Button where Label == RoleButtonTitle {
    /// `Button(scaled: "Install") { … }`: a real Button (so styles, shortcuts and `.disabled`
    /// apply as usual) whose title follows the text size. Used by Settings and onboarding.
    init(scaled title: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { RoleButtonTitle(title: title) }
    }
}

extension View {
    /// A segmented picker `width` wide (narrower only when the row has less room), its
    /// segments sharing the width — so pickers with different titles line up on both edges.
    /// (A segmented control otherwise hugs its titles at any proposed width.) Before macOS 26
    /// it keeps its own width, placed by `alignment` (trailing, like every other Form control).
    func fillingSegments(width: CGFloat, alignment: Alignment = .trailing) -> some View {
        modifier(FillingSegments()).frame(idealWidth: width, maxWidth: width, alignment: alignment)
    }
}

private struct FillingSegments: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible)
        } else {
            content
        }
    }
}
