//  OnboardingView.swift — first-launch welcome sheet (also Help ▸ Welcome to DotStudio…).
//
//  Five short steps: what DotStudio is, pick a preset or create your own, turn the
//  screensaver on in System Settings (the guided setup: an illustrated walkthrough of System
//  Settings above a live checklist — SetupGuide*.swift), showing what's playing in Spotify or
//  Apple Music (how it connects, how it's controlled, what stays private), and where to go to
//  keep creating.
//  A tall, portrait card: every step is one column — a picture on top, then the title, a
//  one-line subtitle and the step's content — with the step dots and buttons pinned below.
//  ContentView presents it and records completion (`hasCompletedOnboarding`) when the sheet
//  goes away, however that happens.

import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, pick, enable, music, done
    }

    /// The pick step's two on-screen tabs.
    enum PickMode: String, CaseIterable, Identifiable {
        case presets = "Presets", create = "Create Your Own"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

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
    /// The guided setup's state: the shared, live one — or a pinned one (UI shots).
    @ObservedObject private var guide: SetupGuideModel
    /// UI shots: the walkthrough held on this step; or its Reduce Motion still cards.
    private let walkthroughStep: Int?
    private let stillWalkthrough: Bool
    /// The presenting window's height: the card never grows taller than it allows (nil: no
    /// limit, as in UI shots).
    private let windowHeight: CGFloat?

    /// The card at the default text size: a tall portrait card (UIShots renders it at this size).
    static let size = CGSize(width: 560, height: 780)
    /// The shortest the card gets, however short the window.
    static let minHeight: CGFloat = 600
    /// Room kept between the card and the window's height.
    static let windowMargin: CGFloat = 40
    /// Side inset shared by every step AND the footer, so the content edges, the step dots and
    /// the buttons sit on one grid and don't jump between steps. Local to this sheet: it is
    /// always `.compact`, where `layout.pagePadding` (20) is too tight for a modal.
    static let inset = Space.xl

    /// Grows with the text (by half the text's growth, like component spacing), so bigger
    /// text gets a bigger card and not only more scrolling. Never below `size` — except that
    /// it is never taller than the window allows (and never below `minHeight`).
    private var sheetSize: CGSize {
        var height = max(Self.size.height, layout.scaled(Self.size.height))
        if let windowHeight, windowHeight > 0 {
            height = max(Self.minHeight, min(height, windowHeight - Self.windowMargin))
        }
        return CGSize(width: max(Self.size.width, layout.scaled(Self.size.width)), height: height)
    }

    /// The card's text runs one text size above the app's (up to xxxLarge — the accessibility
    /// sizes are big already), so its few words read easily.
    private static func cardTypeSize(_ size: DynamicTypeSize) -> DynamicTypeSize {
        guard size < .xxxLarge else { return size }
        return DynamicTypeSize.allCases.first { $0 > size } ?? size
    }

    static var starterDraft: Preset {
        var p = Preset(name: "My Risograph")
        p.effects = [EffectInstance(.risograph)]
        return p
    }

    init(initialStep: Step = .welcome, pickMode: PickMode = .presets,
         livePreview: Bool = true, statusOverride: Installer.Status? = nil,
         guide: SetupGuideModel? = nil, walkthroughStep: Int? = nil, stillWalkthrough: Bool = false,
         windowHeight: CGFloat? = nil) {
        _step = State(initialValue: initialStep)
        _pickMode = State(initialValue: pickMode)
        self.livePreview = livePreview
        self.statusOverride = statusOverride
        _guide = ObservedObject(wrappedValue: guide ?? SetupGuideModel.shared)
        self.walkthroughStep = walkthroughStep
        self.stillWalkthrough = stillWalkthrough
        self.windowHeight = windowHeight
    }

    private var status: Installer.Status { statusOverride ?? model.setupStatus }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    // Reduce Motion: the pages cross-fade instead of sliding.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
                        removal: .offset(x: forward ? -36 : 36).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()   // the sideways page transition; every page scrolls, so content never overflows

            footer
        }
        // The card's own text size, and the layout metrics re-measured for it (the card's
        // size, below, follows the app's text size).
        .adaptiveLayout()
        .environment(\.dynamicTypeSize, Self.cardTypeSize(typeSize))
        .frame(minWidth: Self.size.width, idealWidth: sheetSize.width, maxWidth: sheetSize.width,
               minHeight: Self.minHeight, idealHeight: sheetSize.height, maxHeight: sheetSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // Esc closes the whole flow (counts as completed — the Screensaver card still offers setup).
            // Only a key equivalent: not a control anyone can tab to or find with VoiceOver.
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
        }
        // Errors from inside the sheet (installing the screensaver, importing photos) — the
        // main window's alert would sit behind the sheet. ContentView stands down meanwhile.
        .alert(item: Binding(get: { model.showOnboarding ? model.storeAlert : nil },
                             set: { model.storeAlert = $0 })) { $0.alert }
    }

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage(livePreview: livePreview)
        case .pick: PickPage(mode: $pickMode, draft: $draft, nameEdited: $nameEdited, livePreview: livePreview)
        case .enable: EnablePage(guide: guide, frozenStep: walkthroughStep, forceStill: stillWalkthrough)
        case .music: MusicPage()
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
                Button(scaled: "Skip for Now") { guide.commit(); go(to: .music) }
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
                Button(scaled: "Continue") { guide.commit(); go(to: .music) }
                    .defaultPrimary()
            } else {
                Button(scaled: "Continue") { guide.commit(); go(to: .music) }
                    .adaptiveControlSize(.large)
                    .disabled(true)
                    .help("Turn on the screensaver above, or skip for now")
            }
        case .music:
            Button(scaled: "Continue") { go(to: .done) }
                .defaultPrimary()
        case .done:
            Button(scaled: "Start Using DotStudio") { close() }
                .defaultPrimary()
        }
    }

    private func go(to next: Step) {
        // Set the direction first, so the outgoing page's removal transition sees it.
        forward = next.rawValue > step.rawValue
        let animation = Motion.pick(.spring(response: 0.38, dampingFraction: 0.9), reduceMotion: reduceMotion)
        DispatchQueue.main.async {
            withAnimation(animation) { step = next }
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

/// One step, one column: the picture, the title and a one-line subtitle (centred under it),
/// then the step's content on the card's leading edge. Scrolls when it outgrows the card.
private struct OnboardingPage<Visual: View, Content: View>: View {
    @Environment(\.layout) private var layout
    let title: String
    let subtitle: String
    /// Centre short content in the height (the welcome step).
    var centered = false
    @ViewBuilder var visual: Visual
    @ViewBuilder var content: Content

    var body: some View {
        PageScroll(centered: centered) {
            VStack(spacing: layout.sectionGap) {
                visual
                    .frame(maxWidth: .infinity)
                PageHeader(title: title, subtitle: subtitle)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

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
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A step's body. It scrolls when the text outgrows the card (the footer stays pinned), and
/// every step shares the same side inset and top padding, so the edges hold their place from
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

/// A step's picture when it has no illustration of its own: a large symbol, like the Done
/// step's seal.
private struct HeroSymbol: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .scaledFont { .scaled(points: 52, $0) }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

/// A style's still thumbnail (from the gallery's cache), rounded and framed like a gallery tile.
private struct ThumbCard: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    var cornerRadius: CGFloat = Radius.tile   // like a gallery tile

    var body: some View {
        Group {
            if let img = model.thumbnailer.image(for: preset, source: model.library.source,
                                                 music: model.library.musicSettings) {
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

/// A style's preview card: its thumbnail, with the live Metal preview over it when live.
private struct PreviewCard: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    let live: Bool

    var body: some View {
        ThumbCard(preset: preset, cornerRadius: Radius.m)
            .overlay {
                if live {
                    MetalPreview(preset: preset, source: model.library.source,
                                 location: model.locationTuple, store: model.store,
                                 music: model.library.musicSettings)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
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
    /// The tips' icon column, as on the other steps.
    @ScaledLength(relativeTo: .headline) private var iconColumn: CGFloat = 44

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
        OnboardingPage(title: "Welcome to DotStudio",
                       subtitle: "Living, generative screensavers for your Mac.",
                       centered: true) {
            heroStack
        } content: {
            // What the next steps do — one line each.
            VStack(alignment: .leading, spacing: layout.itemGap) {
                Tip(symbol: "paintpalette.fill", tint: .purple, iconColumn: iconColumn,
                    title: "Pick a style", detail: "Start from a preset, or make your own.")
                Tip(symbol: "gearshape.fill", tint: .gray, iconColumn: iconColumn,
                    title: "Turn it on", detail: "Choose DotStudio in System Settings.")
                Tip(symbol: "music.note", tint: .pink, iconColumn: iconColumn,
                    title: "Show what's playing", detail: "Spotify or Apple Music, on your screensaver.")
            }
            .padding(.horizontal, layout.cardPadding)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appeared = true }
        }
    }

    /// Three cards fanned out across the card's width: the front one at 60 %, the side ones
    /// tucked behind it. Sized from the width it gets, so it scales with the card.
    private var heroStack: some View {
        let cards = hero
        return Color.clear
            .aspectRatio(2.1, contentMode: .fit)   // the front card plus the tilted side cards' overhang
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { i, preset in
                            let isFront = cards.count == 3 ? i == 1 : i == 0
                            let side: CGFloat = i == 0 ? -1 : 1
                            PreviewCard(preset: preset, live: isFront && livePreview)
                                .frame(width: w * (isFront ? 0.6 : 0.42))
                                .shadow(color: .black.opacity(isFront ? 0.35 : 0.22), radius: isFront ? 18 : 10, y: isFront ? 10 : 5)
                                .rotationEffect(.degrees(isFront ? 0 : Double(side) * (appeared ? 7 : 2)))
                                .offset(x: isFront ? 0 : side * w * (appeared ? 0.27 : 0.1), y: isFront ? 0 : w * 0.03)
                                .zIndex(isFront ? 1 : 0)
                                .opacity(isFront || appeared ? 1 : 0)
                        }
                    }
                    .frame(width: w, height: geo.size.height)
                }
            }
            .accessibilityHidden(true)
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

    /// The preview's width at the default text size (grows with `layout.scaled`). Kept modest
    /// so the tiles — the step's main control — start on the first screen.
    private static let previewWidth: CGFloat = 320

    var body: some View {
        OnboardingPage(title: "Make Your Screensaver",
                       subtitle: "Pick a preset, or create your own.") {
            // The style it will play: the pick, or the one being made.
            Group {
                if let shown {
                    PreviewCard(preset: shown, live: livePreview)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                        .id(shown.id)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: layout.scaled(Self.previewWidth))
            .accessibilityHidden(true)
        } content: {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                ScaledSegmentedPicker(title: "Mode", selection: $mode.animation(.easeOut(duration: 0.18)),
                                      options: OnboardingView.PickMode.allCases.map { ($0.rawValue, $0) },
                                      fills: true, alignment: .center)
                switch mode {
                case .presets: presetGrid
                case .create: CreatePanel(draft: $draft, nameEdited: $nameEdited)
                }
            }
        }
        // Freeze the list on appear so tiles don't reshuffle when the pick changes.
        .onAppear { if picks.isEmpty { picks = model.onboardingPicks() } }
    }

    private var shown: Preset? {
        switch mode {
        case .create: return draft
        case .presets: return model.preset(model.library.activeID ?? UUID()) ?? picks.first
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: layout.columns(minimum: 136, spacing: layout.gridColumnGap),
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

/// "Create Your Own" (the preview is the page's picture): the name and what the effect makes,
/// above the same Effect / Canvas pickers as the editor. Picking a Scene makes it a Scene.
private struct CreatePanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Binding var draft: Preset
    @Binding var nameEdited: Bool
    @State private var tab: Tab = .effect

    enum Tab: String, CaseIterable, Identifiable {
        case effect = "Effect", canvas = "Canvas"
        var id: String { rawValue }
    }

    private var kind: EffectKind? { draft.effects.first?.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.sectionGap) {
            detailText
            // A fixed height inside the page's scroll: the picker scrolls on its own.
            effectPanel
                .frame(height: layout.scaled(360))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Name, effect and what it makes.
    private var detailText: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
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
                 ? "A Scene draws itself. Add layers in the editor."
                 : "A Look restyles your canvas. Add effects in the editor.")
                .textRole(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    private var effectPanel: some View {
        VStack(spacing: layout.controlGap) {
            ScaledSegmentedPicker(title: "Section", selection: $tab,
                                  options: Tab.allCases.map { ($0.rawValue, $0) })

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
    /// Keyboard focus (Tab / Full Keyboard Access): the system ring would wrap the whole
    /// tile and its caption, so the tile draws its own around the card.
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: layout.controlGap) {
                ThumbCard(preset: preset)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.tile + 4, style: .continuous)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                            .padding(-4)
                            .opacity(focused ? 1 : 0)
                            .accessibilityHidden(true)
                    }
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name)
                        .textRole(.itemTitle)
                        .truncating(preset.name)
                    Text(preset.isScene ? "Scene" : "Look")
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 3. Turn it on (the guided setup)

/// The guided setup: the System Settings walkthrough on top (its picture, the current step's
/// caption), then the "Open System Settings" button and the live checklist
/// (SetupGuideChecklist.swift). Polls ~1 s while on screen.
private struct EnablePage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var guide: SetupGuideModel
    let frozenStep: Int?
    let forceStill: Bool

    var body: some View {
        OnboardingPage(title: "Turn It On",
                       subtitle: "Choose DotStudio in System Settings. Just once.") {
            SetupWalkthrough(frozenStep: frozenStep, forceStill: forceStill, narrow: layout.prefersStacking)
        } content: {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                SetupOpenSettingsButton(guide: guide) {
                    // The floating guide keeps the steps beside System Settings; it opens
                    // first so System Settings comes up in front of everything else.
                    SetupGuidePanel.shared.show(model: model)
                    guide.openSystemSettings()
                }
                SetupChecklist(guide: guide, commitPhrase: "when you continue")
            }
        }
        .onAppear {
            guide.onStatusChange = { [weak model] _ in model?.refreshSetupStatus() }
            guide.begin()
        }
        .onDisappear { guide.end() }
    }
}

// MARK: - 4. Music

/// Show what's playing: what it does, with the one choice that matters here (Show music, and
/// Full Screen's layout), then how it connects, how it's controlled, what stays on the Mac and
/// why DotStudio has to keep running. The player rows are Settings › Music's own: each one's
/// status and, for a running player macOS hasn't asked about (or one that was refused), its
/// "Allow…" — MusicNow.allowControl, so macOS's prompt comes only from that click (or System
/// Settings › Automation opens). The page itself never prompts: on appear it only re-checks,
/// silently, like Settings › Music.
private struct MusicPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var now = MusicNow.shared
    /// The tips' icon column, as on the Done step.
    @ScaledLength(relativeTo: .headline) private var iconColumn: CGFloat = 44

    var body: some View {
        let spec = model.library.musicSettings
        OnboardingPage(title: "Show What's Playing",
                       subtitle: "Your screensaver shows the song that's playing.") {
            HeroSymbol(symbol: "music.note.tv.fill", tint: .pink)
        } content: {
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                displayCard(spec)
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    Tip(symbol: "link", tint: .green, iconColumn: iconColumn,
                        title: "Connects on this Mac",
                        detail: "No sign-in. When macOS asks, click OK so the controls work. Change it in Privacy & Security › Automation.")
                    if now.isMonitoring {
                        players
                            .padding(.leading, iconColumn + layout.itemGap)
                            .transition(.opacity)
                    }
                    Tip(symbol: "playpause.fill", tint: .blue, iconColumn: iconColumn,
                        title: "Play, pause and skip",
                        detail: "From the menu bar, the Screensaver card or Settings › Music.")
                    Tip(symbol: "lock.fill", tint: .gray, iconColumn: iconColumn,
                        title: "Stays on your Mac",
                        detail: "A missing cover comes from Spotify's or Apple's catalog — only the song's ID, or its artist and album, is sent.")
                    Tip(symbol: "menubar.rectangle", tint: .orange, iconColumn: iconColumn,
                        title: "Keep DotStudio running",
                        detail: "Closing the window keeps it in the menu bar. Turn on Open at login in Settings › General.")
                }
                .padding(.horizontal, layout.cardPadding)
            }
            .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: spec.displayMode)
            .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: now.isMonitoring)
        }
        // A silent re-check (never a prompt), as Settings › Music does.
        .onAppear { now.refreshAutomation() }
    }

    /// Show music (Off / Corner / Full Screen) — the same setting as Settings › Music and the
    /// Screensaver card's Music key — with Full Screen's layouts and one line on the mode.
    private func displayCard(_ spec: MusicSpec) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.itemGap) {
                Text("Show music")
                    .textRole(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScaledSegmentedPicker(title: "Show music",
                                      selection: Binding(get: { model.library.musicSettings.displayMode },
                                                         set: { model.setMusicDisplay($0) }),
                                      options: MusicSpec.Display.allCases.map { ($0.label, $0) })
            }
            if spec.displayMode == .fullScreen {
                MusicLayoutChoice(selection: Binding(get: { model.library.musicSettings.layout },
                                                     set: { l in model.updateMusic { $0.fullLayout = l } }),
                                  backdrop: spec.backdrop)
                    .transition(.opacity)
            }
            Text(modeLine(spec))
                .textRole(.callout)
                .foregroundStyle(.secondary)
                .wrapping()
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }

    private func modeLine(_ spec: MusicSpec) -> String {
        let paused = "A paused song stays \(MusicSettingsSection.lingerLabel(spec.linger))."
        switch spec.displayMode {
        case .off:
            return "Nothing shows. Turn it on later with the Music key on the Screensaver card."
        case .corner:
            return "The song sits in a corner. \(paused)"
        case .fullScreen:
            let over = !spec.layout.usesBackdrop ? "The cover fills the screen."
                : spec.backdrop == .albumArt ? "The song fills the screen, over the album's living art."
                : "The song fills the screen, over your blurred screensaver."
            return "\(over) \(paused)"
        }
    }

    /// Each player's status and permission, as in Settings › Music.
    private var players: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        return VStack(alignment: .leading, spacing: layout.itemGap) {
            MusicPlayerRow(status: now.spotify, now: now)
            Divider()
            MusicPlayerRow(status: now.music, now: now)
        }
        .padding(layout.cardPadding)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - 5. Done

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
        OnboardingPage(title: status == .ready ? "You're All Set" : "Ready When You Are",
                       subtitle: status == .ready
                           ? "DotStudio plays the next time your screensaver starts."
                           : "Turn it on later from the Screensaver card.",
                       centered: true) {
            HeroSymbol(symbol: status == .ready ? "checkmark.seal.fill" : "sparkles",
                       tint: status == .ready ? .green : .accentColor)
        } content: {
            // Card and tips share one inner grid.
            VStack(alignment: .leading, spacing: layout.sectionGap) {
                createCard
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    Tip(symbol: "arrow.triangle.2.circlepath", tint: .orange, iconColumn: iconColumn,
                        title: "Mix it up",
                        detail: "Add styles to the Screensaver card to rotate them, or set one for night.")
                    Tip(symbol: "cursorarrow.click.2", tint: .purple, iconColumn: iconColumn,
                        title: "Edit anything",
                        detail: "Double-click a tile to change its effects, colors and motion.")
                }
                .padding(.horizontal, layout.cardPadding)
            }
        }
    }

    /// The app is about making styles — end on that, not just on "done". The button sits
    /// under the text, on the text's edge.
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
                 ? "Stack effects on a gradient, photo or video — or build a Scene."
                 : "Layer more effects and tune colors and motion in the editor.")
                .textRole(.callout)
                .foregroundStyle(.secondary)
                .wrapping()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let button = Button(scaled: createdName == nil ? "Create a Style" : "Open in Editor", action: onCreate)
            .adaptiveControlSize(.large)

        return VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) { icon; text }
            button.padding(.leading, iconColumn + layout.itemGap)
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(title)
                    .textRole(.headline)
                    .wrapping()
                Text(detail)
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
