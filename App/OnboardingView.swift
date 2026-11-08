//  OnboardingView.swift — first-launch welcome sheet (also Help ▸ Welcome to DotStudio…).
//
//  Four short steps: what DotStudio is, pick what plays, turn the screensaver on
//  in System Settings, and a couple of tips. ContentView presents it and records
//  completion (`hasCompletedOnboarding`) when the sheet goes away, however that happens.

import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, pick, enable, done
    }

    @EnvironmentObject var model: AppModel

    @State private var step: Step
    @State private var forward = true
    /// Live Metal hero on the welcome step. Off for offscreen UI shots, where Metal renders black.
    private let livePreview: Bool
    /// Pins the setup status (UI shots only — the real status comes from the model).
    private let statusOverride: Installer.Status?

    static let size = CGSize(width: 640, height: 520)

    init(initialStep: Step = .welcome, livePreview: Bool = true, statusOverride: Installer.Status? = nil) {
        _step = State(initialValue: initialStep)
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
            // Esc closes the whole flow (counts as completed — the gallery banner still offers setup).
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
        case .pick: PickPage()
        case .enable: EnablePage(status: status, polling: statusOverride == nil)
        case .done: DonePage(status: status)
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
            Button("Continue") { go(to: .enable) }
                .defaultPrimary()
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
        let preferredScenes = ["Aurora", "Black Hole", "Universe", "Silk", "Liquid Chrome", "Afterglow", "Hyperspace"]
        let preferredLooks = ["Riso Duotone", "Liquid Glass", "Soft Focus", "Green Phosphor"]
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

// MARK: - 2. Pick

private struct PickPage: View {
    @EnvironmentObject var model: AppModel
    @State private var picks: [Preset] = []

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(title: "Pick Your Screensaver",
                       subtitle: "Choose one to start. You can switch, or rotate through several, any time.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                ForEach(picks) { preset in
                    PickTile(preset: preset,
                             selected: model.library.activeID == preset.id) {
                        withAnimation(.easeOut(duration: 0.15)) { model.useAsScreensaver(preset.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
        // Freeze the list on appear so tiles don't reshuffle when the pick changes.
        .onAppear { if picks.isEmpty { picks = model.onboardingPicks() } }
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

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: status == .ready ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 50, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status == .ready ? Color.green : Color.accentColor)
                .padding(.top, 6)
            PageHeader(title: status == .ready ? "You're All Set" : "Ready When You Are",
                       subtitle: status == .ready
                           ? "DotStudio will play the next time your screensaver starts."
                           : "Turn on the screensaver any time from the banner at the top of the gallery.")
            VStack(alignment: .leading, spacing: 16) {
                Tip(symbol: "cursorarrow.click.2", tint: .blue,
                    title: "Make it yours",
                    detail: "Double-click any tile to customize its colors and effects.")
                Tip(symbol: "arrow.triangle.2.circlepath", tint: .orange,
                    title: "Mix it up",
                    detail: "Use Playback to rotate through styles, or switch between day and night.")
                Tip(symbol: "play.rectangle.fill", tint: .purple,
                    title: "Preview anytime",
                    detail: "Hover a tile and click Preview to see it full screen.")
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .frame(maxHeight: .infinity, alignment: .top)
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
