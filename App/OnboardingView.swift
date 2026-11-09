//  OnboardingView.swift — first-launch welcome sheet (also Help ▸ Welcome to DotStudio…).
//
//  Four short steps: what DotStudio is, pick a preset or create your own, turn the
//  screensaver on in System Settings, and where to go to keep creating. ContentView presents it and records
//  completion (`hasCompletedOnboarding`) when the sheet goes away, however that happens.

import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, pick, enable, done
    }

    /// The pick step's two on-screen tabs.
    enum PickMode: String, CaseIterable, Identifiable {
        case presets = "Presets", create = "Create Your Own"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout

    @State private var step: Step
    @State private var forward = true
    @State private var pickMode: PickMode
    /// The style being built in "Create Your Own" (not in the library until Continue).
    @State private var draft = OnboardingView.starterDraft
    @State private var nameEdited = false
    /// Name it was saved under, once "Create & Continue" has added it to the library.
    @State private var createdName: String?
    /// Live Metal hero on the welcome step. Off for offscreen UI shots, where Metal renders black.
    private let livePreview: Bool
    /// Pins the setup status (UI shots only — the real status comes from the model).
    private let statusOverride: Installer.Status?

    /// The sheet at the default text size — and its minimum (UIShots renders it at this size).
    static let size = CGSize(width: 760, height: 600)
    /// Side inset shared by every step AND the footer, so the content edges, the step dots and
    /// the buttons sit on one grid and don't jump between steps. Local to this sheet: it is
    /// always `.compact`, where `layout.pagePadding` (20) is too tight for a modal.
    static let inset = Space.xl

    /// Grows with the text (by half the text's growth, like component spacing), so bigger
    /// text gets a bigger sheet and not only more scrolling. Never below `size`.
    private var sheetSize: CGSize {
        CGSize(width: max(Self.size.width, layout.scaled(Self.size.width)),
               height: max(Self.size.height, layout.scaled(Self.size.height)))
    }

    static var starterDraft: Preset {
        var p = Preset(name: "My Risograph")
        p.effects = [EffectInstance(.risograph)]
        return p
    }

    init(initialStep: Step = .welcome, pickMode: PickMode = .presets,
         livePreview: Bool = true, statusOverride: Installer.Status? = nil) {
        _step = State(initialValue: initialStep)
        _pickMode = State(initialValue: pickMode)
        self.livePreview = livePreview
        self.statusOverride = statusOverride
    }

    private var status: Installer.Status { statusOverride ?? model.setupStatus }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
                        removal: .offset(x: forward ? -36 : 36).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()   // the sideways page transition; every page scrolls, so content never overflows

            footer
        }
        .frame(minWidth: Self.size.width, idealWidth: sheetSize.width, maxWidth: sheetSize.width,
               minHeight: Self.size.height, idealHeight: sheetSize.height, maxHeight: sheetSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // Esc closes the whole flow (counts as completed — the Screensaver card still offers setup).
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage(livePreview: livePreview)
        case .pick: PickPage(mode: $pickMode, draft: $draft, nameEdited: $nameEdited, livePreview: livePreview)
        case .enable: EnablePage(status: status, polling: statusOverride == nil)
        case .done: DonePage(status: status, createdName: createdName, onCreate: openEditor)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: layout.controlGap) {
            StepDots(count: Step.allCases.count, current: step.rawValue)
            Spacer(minLength: layout.itemGap)
            if step == .enable && status != .ready {
                // A link sits apart from the push buttons: two control gaps.
                Button(scaled: "Skip for Now") { go(to: .done) }
                    .buttonStyle(.link)
                    .padding(.trailing, layout.controlGap)
            }
            if step != .welcome {
                Button(scaled: "Back") { go(to: Step(rawValue: step.rawValue - 1)!) }
                    .adaptiveControlSize(.large)
            }
            primaryButton
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Space.m)
        .background(alignment: .top) { Divider() }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            Button(scaled: "Get Started") { go(to: .pick) }
                .defaultPrimary()
        case .pick:
            if pickMode == .create {
                Button(scaled: createdName == nil ? "Create & Continue" : "Save & Continue") {
                    createdName = model.saveCreated(draft)
                    draft.name = createdName ?? draft.name
                    go(to: .enable)
                }
                .defaultPrimary()
            } else {
                Button(scaled: "Continue") { go(to: .enable) }
                    .defaultPrimary()
            }
        case .enable:
            // Until it's on, the step's own Install / Open button holds the Return key.
            if status == .ready {
                Button(scaled: "Continue") { go(to: .done) }
                    .defaultPrimary()
            } else {
                Button(scaled: "Continue") { go(to: .done) }
                    .adaptiveControlSize(.large)
                    .disabled(true)
                    .help("Turn on the screensaver above, or skip for now")
            }
        case .done:
            Button(scaled: "Start Using DotStudio") { close() }
                .defaultPrimary()
        }
    }

    private func go(to next: Step) {
        // Set the direction first, so the outgoing page's removal transition sees it.
        forward = next.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { step = next }
        }
    }

    private func close() {
        model.showOnboarding = false   // ContentView's onDismiss records completion
    }

    /// Done step's "keep creating": leave the sheet and land in the full editor —
    /// on the style made here, or on a fresh Look.
    private func openEditor() {
        let made = createdName != nil ? draft.id : nil
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if let made, model.preset(made) != nil { model.edit(made) } else { model.addPreset() }
        }
    }
}

private extension View {
    func defaultPrimary() -> some View {
        self.buttonStyle(.borderedProminent)
            .adaptiveControlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Step indicator

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(i < current ? 0.35 : 0.15))
                    .frame(width: i == current ? Space.l : Space.xs, height: Space.xs)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Shared bits

private struct PageHeader: View {
    @Environment(\.layout) private var layout
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: layout.labelGap) {
            Text(title)
                .textRole(.pageTitle)
                .wrapping(.center)
            Text(subtitle)
                .textRole(.pageSubtitle)
                .foregroundStyle(.secondary)
                .wrapping(.center)
        }
        .readableWidth(layout, alignment: .center)
        .frame(maxWidth: .infinity)
    }
}

/// A step's body. It scrolls when the text outgrows the sheet (the footer stays pinned), and
/// every step shares the same side inset and top padding, so the header holds its place from
/// step to step. `centered` centres short content in the height (the welcome step).
private struct PageScroll<Content: View>: View {
    var centered = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                content
                    .padding(.horizontal, OnboardingView.inset)
                    .padding(.vertical, Space.l)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height,
                           alignment: centered ? .center : .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A style's still thumbnail (from the gallery's cache), rounded and framed like a gallery tile.
private struct ThumbCard: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    var cornerRadius: CGFloat = Radius.tile   // like a gallery tile

    var body: some View {
        Group {
            if let img = model.thumbnailer.image(for: preset, source: model.library.source) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Built-in styles worth showing in onboarding: mostly Scenes, a couple of Looks,
/// always including whatever is active now. Falls back gracefully for edited libraries.
private extension AppModel {
    func onboardingPicks(scenes sceneCount: Int = 4, looks lookCount: Int = 2) -> [Preset] {
        let preferredScenes = ["Liquid Chrome", "Aurora", "Flip Clock", "Lava Lamp", "Universe", "Neon Horizon", "Golden Hour"]
        let preferredLooks = ["Riso Duotone", "Film", "Cyanotype", "Soft Focus"]
        let all = library.presets

        func pick(_ names: [String], _ count: Int, scene: Bool) -> [Preset] {
            var out = names.compactMap { n in all.first { $0.name == n && $0.isScene == scene } }
            for p in all where p.isScene == scene && !out.contains(p) { out.append(p) }
            return Array(out.prefix(count))
        }
        var scenes = pick(preferredScenes, sceneCount, scene: true)
        var looks = pick(preferredLooks, lookCount, scene: false)

        // Make sure the current pick is visible, in its own group.
        if let active = preset(library.activeID ?? UUID()), !(scenes + looks).contains(active) {
            if active.isScene { scenes = [active] + scenes.dropLast(scenes.count >= sceneCount ? 1 : 0) }
            else { looks = [active] + looks.dropLast(looks.count >= lookCount ? 1 : 0) }
        }
        // Top up from the other group if one ran short (e.g. a library with no Looks).
        var picks = scenes + looks
        for p in all where picks.count < sceneCount + lookCount && !picks.contains(p) { picks.append(p) }
        return picks
    }
}

// MARK: - 1. Welcome

private struct WelcomePage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    let livePreview: Bool
    @State private var appeared = false

    private var hero: [Preset] {
        let picks = model.onboardingPicks(scenes: 3, looks: 0)
        let active = model.preset(model.library.activeID ?? UUID())
        // Front-and-centre card = the active style when it's a Scene; flanked by two others.
        var front = picks.first
        if let active, active.isScene { front = active }
        let others = picks.filter { $0.id != front?.id }.prefix(2)
        return [others.first, front, others.dropFirst().first].compactMap { $0 }
    }

    var body: some View {
        PageScroll(centered: true) {
            VStack(spacing: layout.sectionGap) {
                heroStack
                    .frame(height: 200)   // the front card (187.5) plus the tilted side cards' overhang
                PageHeader(title: "Welcome to DotStudio",
                           subtitle: "Living, generative screensavers for your Mac.")
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appeared = true }
        }
    }

    private var heroStack: some View {
        let cards = hero
        return ZStack {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, preset in
                let isFront = cards.count == 3 ? i == 1 : i == 0
                let side: CGFloat = i == 0 ? -1 : 1
                card(preset, live: isFront && livePreview)
                    .frame(width: isFront ? 300 : 230)
                    .shadow(color: .black.opacity(isFront ? 0.35 : 0.22), radius: isFront ? 18 : 10, y: isFront ? 10 : 5)
                    .rotationEffect(.degrees(isFront ? 0 : Double(side) * (appeared ? 7 : 2)))
                    .offset(x: isFront ? 0 : side * (appeared ? 168 : 60), y: isFront ? 0 : 14)
                    .zIndex(isFront ? 1 : 0)
                    .opacity(isFront || appeared ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func card(_ preset: Preset, live: Bool) -> some View {
        if live {
            ThumbCard(preset: preset, cornerRadius: Radius.m)
                .overlay {
                    MetalPreview(preset: preset, source: model.library.source,
                                 location: model.locationTuple, store: model.store)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .allowsHitTesting(false)
                }
        } else {
            ThumbCard(preset: preset, cornerRadius: Radius.m)
        }
    }
}

// MARK: - 2. Pick or create

private struct PickPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Binding var mode: OnboardingView.PickMode
    @Binding var draft: Preset
    @Binding var nameEdited: Bool
    let livePreview: Bool
    @State private var picks: [Preset] = []

    var body: some View {
        Group {
            if mode == .create && !CreatePanel.stacks(layout) {
                // Side by side: the effect picker scrolls on its own and fills the height
                // under the header, so this page doesn't scroll as a whole. Same insets as
                // PageScroll, so the header doesn't move when switching tabs.
                VStack(spacing: layout.sectionGap) {
                    header
                    CreatePanel(draft: $draft, nameEdited: $nameEdited, livePreview: livePreview, stacked: false)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, OnboardingView.inset)
                .padding(.vertical, Space.l)
            } else {
                PageScroll {
                    VStack(spacing: layout.sectionGap) {
                        header
                        switch mode {
                        case .presets: presetGrid
                        case .create: CreatePanel(draft: $draft, nameEdited: $nameEdited, livePreview: livePreview, stacked: true)
                        }
                    }
                }
            }
        }
        // Freeze the list on appear so tiles don't reshuffle when the pick changes.
        .onAppear { if picks.isEmpty { picks = model.onboardingPicks() } }
    }

    private var header: some View {
        VStack(spacing: layout.sectionGap) {
            PageHeader(title: "Make Your Screensaver",
                       subtitle: "Start from a preset, or create your own. You can change it any time.")
            Picker("Mode", selection: $mode.animation(.easeOut(duration: 0.18))) {
                ForEach(OnboardingView.PickMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .adaptiveControlSize()
            .fillingSegments(width: Space.grid(80), alignment: .center)   // 320: two equal segments
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: layout.columns(minimum: 200, spacing: layout.gridColumnGap),
                  spacing: layout.gridRowGap) {
            ForEach(picks) { preset in
                PickTile(preset: preset,
                         selected: model.library.activeID == preset.id) {
                    withAnimation(.easeOut(duration: 0.15)) { model.playAsScreensaver(preset.id) }
                }
            }
        }
    }
}

/// "Create Your Own": live preview + name, beside (or, at large text, above) the same
/// Effect / Canvas pickers as the editor. Picking a Scene makes it a Scene.
private struct CreatePanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Binding var draft: Preset
    @Binding var nameEdited: Bool
    let livePreview: Bool
    /// Stacked: details above the pickers, inside the page's scroll (the pickers get a fixed
    /// height). Side by side: the pickers fill the height beside the details.
    let stacked: Bool

    /// Side by side, the details column has a fixed height to fit in; from .xxLarge text on
    /// (and whenever the layout prefers stacking) it no longer reliably does, so stack.
    static func stacks(_ layout: LayoutMetrics) -> Bool {
        layout.prefersStacking || layout.typeSize >= .xxLarge
    }
    @State private var tab: Tab = .effect

    enum Tab: String, CaseIterable, Identifiable {
        case effect = "Effect", canvas = "Canvas"
        var id: String { rawValue }
    }

    private var kind: EffectKind? { draft.effects.first?.kind }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                details
                    .frame(maxWidth: layout.scaled(360), alignment: .leading)
                effectPanel
                    .frame(height: layout.scaled(360))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: layout.sectionGap) {
                details
                    .frame(width: layout.scaled(300)...layout.scaled(360), alignment: .top)
                effectPanel
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            preview
            TextField("Name", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .textRole(.pageSubtitle)
            if let kind {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Label(kind.displayName, systemImage: kind.category.symbol)
                        .textRole(.headline)
                    Text(kind.blurb)
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            Text(draft.isScene
                 ? "This is a Scene — it draws itself. Add layers later in the editor."
                 : "This is a Look — it restyles your canvas. Add more effects in the editor.")
                .textRole(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    private var effectPanel: some View {
        VStack(spacing: layout.controlGap) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .adaptiveControlSize()

            Group {
                switch tab {
                case .effect:
                    AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                                    prompt: "Search effects and scenes",
                                    selected: kind, size: nil, scenesLast: true) { pick($0) }
                case .canvas:
                    if draft.isScene {
                        VStack(spacing: layout.controlGap) {
                            Image(systemName: "sparkles")
                                .scaledFont { .scaled(.title, $0) }
                                .foregroundStyle(.secondary)
                            Text("Scenes don't use a canvas.")
                                .textRole(.headline)
                                .wrapping(.center)
                            Text("Pick a Look in Effect to restyle a gradient, photo or video.")
                                .textRole(.callout)
                                .foregroundStyle(.secondary)
                                .wrapping(.center)
                        }
                        .padding(layout.cardPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            SourceEditor(source: model.sourceBinding, model: model)
                                .padding(layout.cardPadding)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
    }

    private var preview: some View {
        ThumbCard(preset: draft, cornerRadius: Radius.m)
            .overlay {
                if livePreview {
                    MetalPreview(preset: draft, source: model.library.source,
                                 location: model.locationTuple, store: model.store)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { draft.name }, set: { draft.name = $0; nameEdited = true })
    }

    private func pick(_ kind: EffectKind) {
        draft.effects = [EffectInstance(kind)]
        if !nameEdited { draft.name = "My \(kind.displayName)" }
    }
}

private struct PickTile: View {
    @Environment(\.layout) private var layout
    let preset: Preset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: layout.controlGap) {
                ThumbCard(preset: preset)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .scaledFont { .scaled(points: 18, $0, weight: .semibold) }
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                                .padding(Space.xs)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                    .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                    .scaleEffect(hovering ? 1.02 : 1)
                // One weight for every tile: selection shows as the ring and the checkmark,
                // so the name never shifts or re-truncates when the pick moves.
                HStack(alignment: .firstTextBaseline, spacing: layout.controlGap) {
                    Text(preset.name)
                        .textRole(.itemTitle)
                        .truncating(preset.name)
                    Spacer(minLength: 0)
                    Text(preset.isScene ? "Scene" : "Look")
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 3. Turn it on

private struct EnablePage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    let status: Installer.Status
    /// Poll System Settings' choice while this step is visible (off for UI shots).
    let polling: Bool

    var body: some View {
        PageScroll {
            VStack(spacing: layout.sectionGap) {
                PageHeader(title: "Turn It On",
                           subtitle: "macOS lets only you choose the screensaver. It takes a moment, once.")

                VStack(spacing: 0) {
                    SetupRow(number: 1,
                             title: "Install the screensaver",
                             detail: "Adds DotStudio to your Mac's screen savers, then opens Wallpaper settings for you.",
                             done: status != .notInstalled) {
                        if status == .notInstalled {
                            // installScreensaver() opens Wallpaper settings itself when needed.
                            Button(scaled: "Install") { model.installScreensaver() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    SetupRow(number: 2,
                             title: "Choose DotStudio",
                             detail: nil,
                             done: status == .ready) {
                        if status == .notChosen {
                            Button(scaled: "Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    } extra: {
                        SettingsPath(items: ["System\u{00A0}Settings", "Wallpaper", "Screen\u{00A0}Saver", "DotStudio"])
                            .opacity(status == .notInstalled ? 0.55 : 1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))

                statusLine
                    .animation(.easeOut(duration: 0.2), value: status)
            }
        }
        // ~1s poll while this step is on screen; cancelled when it goes away.
        // (ContentView also refreshes whenever the app becomes active.)
        .task {
            guard polling else { return }
            while !Task.isCancelled {
                model.refreshSetupStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One text role in every state; the colour and the icon carry the state.
    @ViewBuilder private var statusLine: some View {
        switch status {
        case .ready:
            Label("DotStudio is your screensaver.", systemImage: "checkmark.circle.fill")
                .textRole(.calloutEmphasis)
                .foregroundStyle(.green)
                .wrapping(.center)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .notChosen:
            HStack(spacing: layout.iconGap) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to choose DotStudio in System Settings…")
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping(.center)
            }
        case .notInstalled:
            Label("Not installed yet", systemImage: "circle.dashed")
                .textRole(.callout)
                .foregroundStyle(.secondary)
                .wrapping(.center)
        }
    }
}

/// One numbered step in the "Turn It On" card. The badge centres on the TITLE line (detail
/// and extra run full width under the title column), the title row is always as tall as the
/// action button so the card doesn't shift when a button comes and goes, and at large text
/// the button moves under the text instead of squeezing it.
private struct SetupRow<Action: View, Extra: View>: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .headline) private var badgeSize: CGFloat = Space.l
    let number: Int
    let title: String
    let detail: String?
    let done: Bool
    @ViewBuilder var action: () -> Action
    @ViewBuilder var extra: () -> Extra

    init(number: Int, title: String, detail: String?, done: Bool,
         @ViewBuilder action: @escaping () -> Action,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.number = number; self.title = title; self.detail = detail; self.done = done
        self.action = action; self.extra = extra
    }

    /// From the badge's leading edge to the title column's.
    private var textIndent: CGFloat { badgeSize + layout.itemGap }

    var body: some View {
        let stacked = layout.prefersStacking
        VStack(alignment: .leading, spacing: layout.labelGap) {
            HStack(alignment: .center, spacing: layout.itemGap) {
                ZStack {
                    if !stacked { buttonHeightStrut }
                    badge
                }
                Text(title)
                    .textRole(.headline)
                    .wrapping()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked {
                    action().adaptiveControlSize(.large)
                }
            }
            VStack(alignment: .leading, spacing: layout.itemGap) {
                if let detail {
                    Text(detail)
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
                extra()
                if stacked {
                    action().adaptiveControlSize(.large)
                }
            }
            .padding(.leading, textIndent)
        }
        .padding(layout.cardPadding)
        .overlay(alignment: .top) {
            // Inset divider from the step above, starting exactly at the text column.
            if number > 1 { Divider().padding(.leading, layout.cardPadding + textIndent) }
        }
    }

    /// Zero-width, invisible stand-in for the action button: keeps the title row as tall as a
    /// button whether or not this step shows one right now (the status flips live).
    private var buttonHeightStrut: some View {
        Button(scaled: " ") {}
            .buttonStyle(.borderedProminent)
            .adaptiveControlSize(.large)
            .frame(width: 0)
            .hidden()
            .disabled(true)
            .accessibilityHidden(true)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : Color.accentColor.opacity(0.14))
            if done {
                Image(systemName: "checkmark")
                    .scaledFont { .scaled(points: 12, $0, weight: .bold) }
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("\(number)")
                    .scaledFont { .scaled(points: 13, $0, weight: .semibold, design: .rounded) }
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
    }
}

/// "⚙ System Settings › Wallpaper › Screen Saver › DotStudio" as one wrapping line.
private struct SettingsPath: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let items: [String]

    var body: some View {
        items.enumerated().reduce(Text(Image(systemName: "gearshape.fill")).foregroundColor(.secondary)) { line, pair in
            let (i, item) = pair
            let last = i == items.count - 1
            let word = last ? Text(item).fontWeight(.semibold).foregroundColor(.primary)
                            : Text(item).foregroundColor(.secondary)
            let sep = i == 0 ? Text(" ")
                : Text("  ") + Text(Image(systemName: "chevron.right")).font(.scaled(.caption2, typeSize, weight: .bold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor)) + Text("  ")
            return line + sep + word
        }
        .textRole(.callout)
        .wrapping()
        .accessibilityLabel("System Settings, Wallpaper, Screen Saver, DotStudio")
    }
}

// MARK: - 4. Done

private struct DonePage: View {
    @Environment(\.layout) private var layout
    /// The create card's icon tile. The tips' icon column is exactly as wide, so card and tip
    /// icons centre on one line and all their text starts on one edge.
    @ScaledLength(relativeTo: .headline) private var iconColumn: CGFloat = 44
    let status: Installer.Status
    /// Set when the user made a style in "Create Your Own".
    let createdName: String?
    let onCreate: () -> Void

    var body: some View {
        PageScroll {
            VStack(spacing: layout.sectionGap) {
                VStack(spacing: Space.m) {
                    Image(systemName: status == .ready ? "checkmark.seal.fill" : "sparkles")
                        .scaledFont { .scaled(points: 46, $0) }
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(status == .ready ? Color.green : Color.accentColor)
                    PageHeader(title: status == .ready ? "You're All Set" : "Ready When You Are",
                               subtitle: status == .ready
                                   ? "DotStudio will play the next time your screensaver starts."
                                   : "Turn it on any time from the Screensaver card in the gallery.")
                }

                // Card and tips share one readable column and one inner grid.
                VStack(alignment: .leading, spacing: layout.sectionGap) {
                    createCard
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        Tip(symbol: "arrow.triangle.2.circlepath", tint: .orange, iconColumn: iconColumn,
                            title: "Mix it up",
                            detail: "Add styles to the Screensaver card to rotate them, or pick a different one for night.")
                        Tip(symbol: "cursorarrow.click.2", tint: .purple, iconColumn: iconColumn,
                            title: "Edit anything",
                            detail: "Double-click any tile to change its effects, colors and motion.")
                    }
                    .padding(.horizontal, layout.cardPadding)
                }
                .readableWidth(layout)
            }
        }
    }

    /// The app is about making styles — end on that, not just on "done".
    private var createCard: some View {
        let icon = Image(systemName: "paintbrush.pointed.fill")
            .scaledFont { .scaled(points: 20, $0, weight: .semibold) }
            .foregroundStyle(.white)
            .frame(width: iconColumn, height: iconColumn)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.accentColor.gradient))
        let text = VStack(alignment: .leading, spacing: layout.labelGap) {
            Text(createdName.map { "Keep shaping \u{201C}\($0)\u{201D}" } ?? "Create your own")
                .textRole(.headline)
                .wrapping()
            Text(createdName == nil
                 ? "Stack effects on a gradient, photo or video — or build a Scene from scratch."
                 : "Open it in the editor to layer more effects and tune colors and motion.")
                .textRole(.callout)
                .foregroundStyle(.secondary)
                .wrapping()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let button = Button(scaled: createdName == nil ? "Create a Style" : "Open in Editor", action: onCreate)
            .adaptiveControlSize(.large)

        return Group {
            if layout.prefersStacking {
                // Large text: the button drops under the text instead of squeezing it.
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    HStack(alignment: .top, spacing: layout.itemGap) { icon; text }
                    button.padding(.leading, iconColumn + layout.itemGap)
                }
            } else {
                HStack(spacing: layout.itemGap) { icon; text; button }
            }
        }
        .padding(layout.cardPadding)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.accentColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

private struct Tip: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .headline) private var tile: CGFloat = 34
    let symbol: String
    let tint: Color
    /// Width of the icon column (the create card's icon tile), the smaller tile centred in it.
    let iconColumn: CGFloat
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: layout.itemGap) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 16, $0, weight: .semibold) }
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(tint.gradient))
                .frame(width: iconColumn)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(title)
                    .textRole(.headline)
                    .wrapping()
                Text(detail)
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
        }
    }
}
