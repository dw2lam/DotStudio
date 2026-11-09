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

    static let size = CGSize(width: 760, height: 600)

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
            .clipped()

            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
        HStack(spacing: 10) {
            StepDots(count: Step.allCases.count, current: step.rawValue)
            Spacer()
            if step == .enable && status != .ready {
                Button("Skip for Now") { go(to: .done) }
                    .buttonStyle(.link)
                    .padding(.trailing, 6)
            }
            if step != .welcome {
                Button("Back") { go(to: Step(rawValue: step.rawValue - 1)!) }
                    .controlSize(.large)
            }
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(alignment: .top) { Divider() }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get Started") { go(to: .pick) }
                .defaultPrimary()
        case .pick:
            if pickMode == .create {
                Button(createdName == nil ? "Create & Continue" : "Save & Continue") {
                    createdName = model.saveCreated(draft)
                    draft.name = createdName ?? draft.name
                    go(to: .enable)
                }
                .defaultPrimary()
            } else {
                Button("Continue") { go(to: .enable) }
                    .defaultPrimary()
            }
        case .enable:
            // Until it's on, the step's own Install / Open button holds the Return key.
            if status == .ready {
                Button("Continue") { go(to: .done) }
                    .defaultPrimary()
            } else {
                Button("Continue") { go(to: .done) }
                    .controlSize(.large)
                    .disabled(true)
                    .help("Turn on the screensaver above, or skip for now")
            }
        case .done:
            Button("Start Using DotStudio") { close() }
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
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Step indicator

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(i < current ? 0.35 : 0.15))
                    .frame(width: i == current ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Shared bits

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 540)
    }
}

/// A style's still thumbnail (from the gallery's cache), rounded and framed like a gallery tile.
private struct ThumbCard: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    var cornerRadius: CGFloat = 10

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
        VStack(spacing: 34) {
            heroStack
                .frame(height: 200)
            PageHeader(title: "Welcome to DotStudio",
                       subtitle: "Living, generative screensavers for your Mac.")
        }
        .frame(maxHeight: .infinity)
        .padding(.bottom, 6)
        .padding(.horizontal, 40)
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
            ThumbCard(preset: preset, cornerRadius: 12)
                .overlay {
                    MetalPreview(preset: preset, source: model.library.source,
                                 location: model.locationTuple, store: model.store)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .allowsHitTesting(false)
                }
        } else {
            ThumbCard(preset: preset, cornerRadius: 12)
        }
    }
}

// MARK: - 2. Pick or create

private struct PickPage: View {
    @EnvironmentObject var model: AppModel
    @Binding var mode: OnboardingView.PickMode
    @Binding var draft: Preset
    @Binding var nameEdited: Bool
    let livePreview: Bool
    @State private var picks: [Preset] = []

    var body: some View {
        VStack(spacing: 16) {
            PageHeader(title: "Make Your Screensaver",
                       subtitle: "Start from a preset, or create your own. You can change it any time.")
            Picker("Mode", selection: $mode.animation(.easeOut(duration: 0.18))) {
                ForEach(OnboardingView.PickMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Group {
                switch mode {
                case .presets: presetGrid
                case .create: CreatePanel(draft: $draft, nameEdited: $nameEdited, livePreview: livePreview)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        // Freeze the list on appear so tiles don't reshuffle when the pick changes.
        .onAppear { if picks.isEmpty { picks = model.onboardingPicks() } }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
            ForEach(picks) { preset in
                PickTile(preset: preset,
                         selected: model.library.activeID == preset.id) {
                    withAnimation(.easeOut(duration: 0.15)) { model.playAsScreensaver(preset.id) }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// "Create Your Own": live preview + name on the left; the same Effect / Canvas
/// pickers as the editor on the right. Picking a Scene makes it a Scene.
private struct CreatePanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var draft: Preset
    @Binding var nameEdited: Bool
    let livePreview: Bool
    @State private var tab: Tab = .effect

    enum Tab: String, CaseIterable, Identifiable {
        case effect = "Effect", canvas = "Canvas"
        var id: String { rawValue }
    }

    private var kind: EffectKind? { draft.effects.first?.kind }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                TextField("Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                if let kind {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(kind.displayName, systemImage: kind.category.symbol)
                            .font(.headline)
                        Text(kind.blurb)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(draft.isScene
                     ? "This is a Scene — it draws itself. Add layers and tune it later in the editor."
                     : "This is a Look — it restyles your canvas. Layer more effects later in the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 330)

            VStack(spacing: 10) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch tab {
                    case .effect:
                        AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                                        prompt: "Search effects and scenes",
                                        selected: kind, size: nil, scenesLast: true) { pick($0) }
                    case .canvas:
                        if draft.isScene {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles").font(.title).foregroundStyle(.secondary)
                                Text("Scenes don't use a canvas.").font(.headline)
                                Text("Pick a Look in Effect to restyle a gradient, photo or video.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                SourceEditor(source: model.sourceBinding, model: model)
                                    .padding(14)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var preview: some View {
        ThumbCard(preset: draft, cornerRadius: 12)
            .overlay {
                if livePreview {
                    MetalPreview(preset: draft, source: model.library.source,
                                 location: model.locationTuple, store: model.store)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    let preset: Preset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ThumbCard(preset: preset)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                                .padding(7)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                    .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                    .scaleEffect(hovering ? 1.02 : 1)
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.body.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(preset.isScene ? "Scene" : "Look")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
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
    let status: Installer.Status
    /// Poll System Settings' choice while this step is visible (off for UI shots).
    let polling: Bool

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(title: "Turn It On",
                       subtitle: "macOS lets only you choose the screensaver. It takes a moment, once.")

            VStack(spacing: 0) {
                SetupRow(number: 1,
                         title: "Install the screensaver",
                         detail: "Adds DotStudio to your Mac's screen savers, then opens Wallpaper settings for you.",
                         done: status != .notInstalled) {
                    if status == .notInstalled {
                        // installScreensaver() opens Wallpaper settings itself when needed.
                        Button("Install") { model.installScreensaver() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                Divider().padding(.leading, 52)
                SetupRow(number: 2,
                         title: "Choose DotStudio",
                         detail: nil,
                         done: status == .ready) {
                    if status == .notChosen {
                        Button("Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } extra: {
                    SettingsPath(items: ["System\u{00A0}Settings", "Wallpaper", "Screen\u{00A0}Saver", "DotStudio"])
                        .opacity(status == .notInstalled ? 0.55 : 1)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))

            statusLine
                .animation(.easeOut(duration: 0.2), value: status)
        }
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
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

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .ready:
            Label("DotStudio is your screensaver.", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .notChosen:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to choose DotStudio in System Settings…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .notInstalled:
            Label("Not installed yet", systemImage: "circle.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SetupRow<Action: View, Extra: View>: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 10)
                action()
                    .controlSize(.large)
            }
            // Full-width line under the title column (not squeezed by the button).
            extra()
                .padding(.leading, 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var badge: some View {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.14))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 26, height: 26)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
    }
}

/// "⚙ System Settings › Wallpaper › Screen Saver › DotStudio" as one wrapping line.
private struct SettingsPath: View {
    let items: [String]

    var body: some View {
        items.enumerated().reduce(Text(Image(systemName: "gearshape.fill")).foregroundColor(.secondary)) { line, pair in
            let (i, item) = pair
            let last = i == items.count - 1
            let word = last ? Text(item).fontWeight(.semibold).foregroundColor(.primary)
                            : Text(item).foregroundColor(.secondary)
            let sep = i == 0 ? Text(" ")
                : Text("  ") + Text(Image(systemName: "chevron.right")).font(.caption2.weight(.bold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor)) + Text("  ")
            return line + sep + word
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("System Settings, Wallpaper, Screen Saver, DotStudio")
    }
}

// MARK: - 4. Done

private struct DonePage: View {
    let status: Installer.Status
    /// Set when the user made a style in "Create Your Own".
    let createdName: String?
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: status == .ready ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status == .ready ? Color.green : Color.accentColor)
                .padding(.top, 4)
            PageHeader(title: status == .ready ? "You're All Set" : "Ready When You Are",
                       subtitle: status == .ready
                           ? "DotStudio will play the next time your screensaver starts."
                           : "Turn on the screensaver any time from the Screensaver card at the top of the gallery.")

            createCard

            VStack(alignment: .leading, spacing: 14) {
                Tip(symbol: "arrow.triangle.2.circlepath", tint: .orange,
                    title: "Mix it up",
                    detail: "Add styles to the Screensaver card to rotate them, or pick a different one for night.")
                Tip(symbol: "cursorarrow.click.2", tint: .purple,
                    title: "Edit anything",
                    detail: "Double-click any tile to change its effects, colors and motion.")
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The app is about making styles — end on that, not just on "done".
    private var createCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text(createdName.map { "Keep shaping \u{201C}\($0)\u{201D}" } ?? "Create your own")
                    .font(.headline)
                Text(createdName == nil
                     ? "Stack effects on a gradient, photo or video — or build a Scene from scratch."
                     : "Open it in the editor to layer more effects and tune colors and motion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(createdName == nil ? "Create a Style" : "Open in Editor", action: onCreate)
                .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

private struct Tip: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
