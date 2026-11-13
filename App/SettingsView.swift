//  SettingsView.swift — rarely-touched, library-wide settings (⌘,).
//  What plays (playlist, night style, wallpaper) lives in the main window's
//  destination cards; this is how the app runs (General), setup, transitions,
//  performance, and updates.

import SwiftUI
import ServiceManagement

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

    /// The MCP popover's "More in Settings…" scrolls to the AI section.
    @ObservedObject private var ai = AIConnect.shared
    @State private var revealedAI = 0

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { revealAI(proxy) }
                .onChange(of: ai.revealRequest) { _, _ in revealAI(proxy) }
        }
    }

    private func revealAI(_ proxy: ScrollViewProxy) {
        guard ai.revealRequest != revealedAI else { return }
        revealedAI = ai.revealRequest
        // after the window has laid out (it may be opening just now)
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(AISettingsSection.anchor, anchor: .top) } }
    }

    private var form: some View {
        Form {
            GeneralSettingsSection()
            MusicSettingsSlot()        // the Music section (MusicSlots.swift)
            WeatherSettingsSection()   // live weather for the sea scenes (WeatherSettingsSection.swift)
            setupSection
            WallpaperSettingsSection()
            AISettingsSection()        // assistants via dotstudio-mcp (AISettingsSection.swift)
            transitionsSection
            performanceSection
            updatesSection
        }
        .formStyle(.grouped)
        .textRole(.body)          // row labels follow the text size (macOS never scales them itself)
        .formControlSize()        // stock sizes at standard text; a step up per text bump after
        .frame(minWidth: SettingsMetrics.width, idealWidth: formWidth, maxWidth: formWidth)
        // All six sections run ~1250 pt — taller than a 13" display. Open shorter and let the
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
            // As wide as the segmented pickers, so the value column has one leading edge.
            SettingsValueRow("Crossfade", valueWidth: segmentWidth) {
                HStack(spacing: layout.controlGap) {
                    Slider(value: Binding(get: { model.rotation.transitionSeconds },
                                          set: { v in model.updateRotation { $0.transitionSeconds = v } }),
                           in: 0...3)
                        .labelsHidden()   // outside a LabeledContent a Form keeps a label column for it
                        // labelsHidden drops the slider's name for VoiceOver too: give it back.
                        .accessibilityLabel("Crossfade")
                        .accessibilityValue(model.rotation.transitionSeconds < 0.05
                                            ? "Off" : String(format: "%.1f seconds", model.rotation.transitionSeconds))
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
            SettingsValueRow("Quality", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Quality", selection: qualityBinding,
                                      options: [("Full", 1.0), ("Balanced", 0.75), ("Efficient", 0.5)],
                                      fills: true)
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
                .formSwitchSize()
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updates.automaticallyInstalls },
                set: { updates.automaticallyInstalls = $0 }))
                .formSwitchSize()
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
            ProgressView().adaptiveControlSize(.small)
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

// MARK: - General

/// How DotStudio runs: in the menu bar when its window is closed (menu-bar mode, on by
/// default — AppPresence), and whether it opens at login (quietly in the menu bar in
/// menu-bar mode, else with its window — the footer says which). Also the way back into the
/// guided setup ("Run Setup Again"), and the one-time "start at login" suggestion when the
/// wallpaper or music display was just turned on (SetupGuide.swift).
struct GeneralSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var presence = AppPresence.shared
    @ObservedObject private var nudge = LoginNudge.shared
    /// Read through LoginItem (pinned in UI shots; never SMAppService there).
    @State private var loginStatus = LoginItem.status()
    @State private var loginError: String?

    private var opensAtLogin: Bool { loginStatus != .off }

    var body: some View {
        Section {
            if nudge.pending != nil { LoginNudgeBanner(topPadding: 0) }
            Toggle("Keep running in the menu bar", isOn: $presence.menuBarMode)
                .formSwitchSize()
            Toggle("Open DotStudio at login", isOn: Binding(get: { opensAtLogin }, set: setOpenAtLogin))
                .formSwitchSize()
            if loginStatus == .requiresApproval {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("Allow DotStudio in System Settings › General › Login Items.")
                        .textRole(.caption).foregroundStyle(.orange).wrapping()
                    Spacer(minLength: 0)
                    Button(scaled: "Open Login Items\u{2026}") { LoginItem.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
            } else if let loginError {
                Text(loginError).textRole(.caption).foregroundStyle(.orange).wrapping()
            }
            LabeledContent("Screensaver setup") {
                Button(scaled: "Run Setup Again\u{2026}") { SetupGuidePanel.shared.show(model: model) }
                    .help("The step-by-step guide: install, choose DotStudio in System Settings, and check the settings that keep it working")
            }
        } header: {
            SettingsHeader("General")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote(presence.menuBarMode
                    ? "Closing the window takes DotStudio out of the Dock; it keeps running in the menu bar, so your live wallpaper keeps playing. Open or quit it from there."
                    : "Closing the window quits DotStudio — unless a live wallpaper is playing; then it stays in the menu bar until you stop it.")
                if opensAtLogin {
                    // What a login launch does (AppPresence.decideLaunch).
                    SettingsNote(presence.menuBarMode
                        ? "At login it starts quietly in the menu bar, without opening its window."
                        : "At login it opens its window — or, if your live wallpaper was on, starts quietly in the menu bar and keeps it playing.")
                }
            }
        }
        .onAppear { loginStatus = LoginItem.status() }
        // The nudge's Turn On, or the guide, may have changed it.
        .onChange(of: nudge.pending) { loginStatus = LoginItem.status() }
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        loginStatus = LoginItem.status()
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
    /// A regular stock segmented control's height (the scaled segmented control's track).
    static let segmentHeight = Space.grid(6)      // 24
    /// How much more a grouped Form insets custom row content (top and bottom) than a
    /// LabeledContent row — measured: 44.5 vs 40.5 pt rows around a 24-pt control.
    static let customRowInsetExcess = Space.xxs / 2   // 2
    /// Where `adaptiveControlSize` starts growing bezels — and so where stock 13-pt control
    /// titles fall behind the role-sized labels around them. Below it the panels use stock
    /// controls at stock sizes; from it, role-sized stand-ins (segmented, the Style pull-down).
    static let scaledControlsFrom: DynamicTypeSize = .xxLarge
    /// The size a grouped Form gives its switches when nothing sets one.
    static let switchSize: ControlSize = .mini
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

extension View {
    /// Stock control sizes at the standard text sizes, then `adaptiveControlSize(base)` from
    /// .xxLarge. Below that it sets nothing: any explicit control size on a grouped Form
    /// replaces the Form's own (smaller) switches.
    func formControlSize(_ base: ControlSize = .regular) -> some View {
        modifier(FormControlSize(base: base))
    }

    /// A Form switch: the grouped Form's own switch size, a step up per text bump from .xxLarge.
    func formSwitchSize() -> some View { formControlSize(SettingsMetrics.switchSize) }
}

private struct FormControlSize: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let base: ControlSize

    func body(content: Content) -> some View {
        if typeSize >= SettingsMetrics.scaledControlsFrom {
            content.adaptiveControlSize(base)
        } else {
            content
        }
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

/// A segmented picker whose segment titles follow the text size. Used by Settings and
/// onboarding.
///
/// A stock segmented control keeps 13-pt titles at every text size (macOS never scales control
/// labels), so once `adaptiveControlSize` starts growing bezels (.xxLarge) its titles look
/// undersized next to role-sized labels. Below .xxLarge this IS the stock control, pixel for
/// pixel; from .xxLarge it draws the same capsule track (same fills, measured from the stock
/// control in light and dark) with `.body`-role titles, which never truncate or break mid-word:
/// the segments stack into a column when the titles don't fit side by side.
///
/// `fills`: the segments share the whole proposed width — give it one with a frame — so
/// pickers with different titles line up on both edges; false hugs the titles. Before macOS 26
/// a stock control can't stretch its segments; `alignment` places it in the slot.
struct ScaledSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var fills = false
    var alignment: Alignment = .trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize < SettingsMetrics.scaledControlsFrom {
            let picker = Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if fills {
                picker.modifier(FillingSegments()).frame(maxWidth: .infinity, alignment: alignment)
            } else {
                picker   // a stock segmented control hugs its titles by itself
            }
        } else if fills {
            ScaledSegments(title: title, selection: $selection, options: options)
                .frame(maxWidth: .infinity)
        } else {
            ScaledSegments(title: title, selection: $selection, options: options)
                .fixedSize()
        }
    }
}

/// A Form row whose value has a set width (`valueWidth`): beside its label while both fit, so
/// every such row's value starts on one leading edge; otherwise under the label at the full row
/// width, flush with it. (A plain LabeledContent stacks too, but keeps the value's own width
/// and leaves it trailing, a few points to a few dozen in from the label.) A custom Layout
/// rather than a VStack or ViewThatFits: a grouped Form re-styles a VStack of label and
/// control as its own trailing-value row, and ViewThatFits over a LabeledContent never picks
/// the side-by-side layout.
struct SettingsValueRow<Value: View>: View {
    @Environment(\.layout) private var layout
    let label: String
    let valueWidth: CGFloat
    @ViewBuilder var value: () -> Value

    init(_ label: String, valueWidth: CGFloat, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.valueWidth = valueWidth
        self.value = value
    }

    var body: some View {
        LabelValueLayout(valueWidth: valueWidth, gap: layout.itemGap, stackedGap: layout.controlGap) {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
            value()
                .frame(maxWidth: .infinity)   // takes the width it is given (a slider row hugs otherwise)
        }
        // A grouped Form insets custom row content 2 pt more per side than a LabeledContent
        // row; take that back so these rows stay as tall as their stock neighbours.
        .padding(.vertical, -SettingsMetrics.customRowInsetExcess)
        .accessibilityElement(children: .contain)
    }
}

private struct LabelValueLayout: Layout {
    let valueWidth: CGFloat
    /// The least room between label and value side by side.
    let gap: CGFloat
    /// Between label and value when stacked.
    let stackedGap: CGFloat

    private func stacks(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        subviews[0].sizeThatFits(.unspecified).width + gap + valueWidth > width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let label = subviews[0].sizeThatFits(.unspecified)
        guard let width = proposal.width, width.isFinite else {
            let value = subviews[1].sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
            return CGSize(width: label.width + gap + valueWidth, height: max(label.height, value.height))
        }
        if stacks(width, subviews) {
            let l = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let v = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: l.height + stackedGap + v.height)
        }
        let value = subviews[1].sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
        return CGSize(width: width, height: max(label.height, value.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if stacks(bounds.width, subviews) {
            let full = ProposedViewSize(width: bounds.width, height: nil)
            let l = subviews[0].sizeThatFits(full)
            subviews[0].place(at: bounds.origin, proposal: full)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + l.height + stackedGap), proposal: full)
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: valueWidth, height: nil))
        }
    }
}

/// The role-sized segmented control (see `ScaledSegmentedPicker`). Segments sit side by side
/// at one shared width while every title fits on one line; when they don't (long titles,
/// accessibility sizes in a narrow window) the same segments stack into a column, so a title
/// never breaks mid-word.
private struct ScaledSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    /// A regular stock segmented control is this tall at the default text size; the track
    /// keeps that proportion to its title as the text grows.
    @ScaledLength(relativeTo: .body) private var height: CGFloat = SettingsMetrics.segmentHeight

    /// Same fills as the stock control (light: 228 on a 247 row, 200 selected; dark: 54 on 37,
    /// 80 selected) — `primary` keeps them right in both appearances.
    private static var trackFill: Color { Color.primary.opacity(0.078) }
    private static var selectedFill: Color { Color.primary.opacity(0.13) }
    private static var separatorFill: Color { Color.primary.opacity(0.15) }

    /// A capsule for a one-line segment; a rounded rectangle for a column of them.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: height / 2, style: .continuous) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            EqualSegmentsLayout {
                ForEach(options.indices, id: \.self) { i in segment(i, axis: .horizontal) }
            }
            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in segment(i, axis: .vertical) }
            }
        }
        .background(shape.fill(Self.trackFill))
        .animation(.easeOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segment(_ i: Int, axis: Axis) -> some View {
        let isOn = options[i].value == selection
        // The stock control draws a hairline between two unselected neighbours.
        let separates = i > 0 && !isOn && options[i - 1].value != selection
        return Button { selection = options[i].value } label: {
            Text(options[i].title)
                .textRole(.body)
                .foregroundStyle(.primary)   // a Form styles a row's value secondary; stock segments ignore that
                .lineLimit(axis == .horizontal ? 1 : nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, height / 2)
                .padding(.vertical, Space.xxs)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(shape.fill(Self.selectedFill).opacity(isOn ? 1 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: axis == .horizontal ? .leading : .top) {
            if separates {
                Rectangle()
                    .fill(Self.separatorFill)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .horizontal ? height / 2 : 1)
                    .padding(.horizontal, axis == .vertical ? height / 2 : 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Equal-width segments in a row: each is as wide as the widest one's single-line title
/// needs (its ideal width), and they share any extra room. Ideally `count × widest`, which is
/// what `ViewThatFits` compares with the room it has — so the row is only chosen when no title
/// would wrap or truncate.
private struct EqualSegmentsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let ideal = widest * CGFloat(subviews.count)
        let width = max(ideal, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal)
        let each = ProposedViewSize(width: width / CGFloat(subviews.count), height: nil)
        let height = subviews.map { $0.sizeThatFits(each).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let each = bounds.width / CGFloat(subviews.count)
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(i) * each, y: bounds.minY),
                          proposal: ProposedViewSize(width: each, height: bounds.height))
        }
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
