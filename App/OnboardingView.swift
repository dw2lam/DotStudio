//  OnboardingView.swift — first-launch welcome sheet (also Help ▸ Welcome to DotStudio…).
//
//  Five short steps: what DotStudio is, pick a preset or create your own, turn the
//  screensaver on in System Settings (the guided setup: an illustrated walkthrough of System
//  Settings beside a live checklist — SetupGuide*.swift), showing what's playing in Spotify or
//  Apple Music (how it connects, how it's controlled, what stays private), and where to go to
//  keep creating.
//  A wide, landscape sheet sized from the window it sits on: every step has its title and a
//  one-line subtitle centred on top, and its content in one or two columns below, on the
//  sheet's side insets; the step dots and buttons are pinned below.
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
    /// The presenting window's size: the sheet is sized from it, and never outgrows it (nil:
    /// no window, as in UI shots — the sheet is `size`).
    private let windowSize: CGSize?

    /// The sheet at the default text size with no window to size from (UIShots renders it at
    /// this size).
    static let size = CGSize(width: 980, height: 700)
    /// The sheet's share of the window, and its limits (before text growth).
    static let widthShare: CGFloat = 0.82, heightShare: CGFloat = 0.84
    static let widthRange: ClosedRange<CGFloat> = 900...1240
    static let heightRange: ClosedRange<CGFloat> = 640...880
    /// Room kept between the sheet and the window's edges.
    static let windowMargin: CGFloat = 40
    /// Side inset shared by every step AND the footer, so the content edges, the step dots and
    /// the buttons sit on one grid and don't jump between steps.
    static let inset = Space.grid(10)   // 40

    /// From the window (a share of it, within limits), grown with the text (by half the
    /// text's growth, like component spacing) so bigger text gets a bigger sheet and not only
    /// more scrolling — but never larger than the window allows.
    private var sheetSize: CGSize {
        guard let windowSize, windowSize.width > 0, windowSize.height > 0 else {
            return CGSize(width: max(Self.size.width, layout.scaled(Self.size.width)),
                          height: max(Self.size.height, layout.scaled(Self.size.height)))
        }
        func fit(_ window: CGFloat, _ share: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
            let base = min(max(window * share, range.lowerBound), range.upperBound)
            return Space.snap(min(max(base, layout.scaled(base)), window - Self.windowMargin))
        }
        return CGSize(width: fit(windowSize.width, Self.widthShare, Self.widthRange),
                      height: fit(windowSize.height, Self.heightShare, Self.heightRange))
    }

    /// The smallest the sheet gets: `size` in UI shots, else exactly `sheetSize` (already
    /// capped to the window).
    private var minSize: CGSize { windowSize == nil ? Self.size : sheetSize }

    /// The sheet's text runs one text size above the app's (up to xxxLarge — the accessibility
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
         windowSize: CGSize? = nil) {
        _step = State(initialValue: initialStep)
        _pickMode = State(initialValue: pickMode)
        self.livePreview = livePreview
        self.statusOverride = statusOverride
        _guide = ObservedObject(wrappedValue: guide ?? SetupGuideModel.shared)
        self.walkthroughStep = walkthroughStep
        self.stillWalkthrough = stillWalkthrough
        self.windowSize = windowSize
    }

    private var status: Installer.Status { statusOverride ?? model.setupStatus }

    var body: some View {
        let size = sheetSize, minSize = minSize
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
        // The sheet's own text size, and the layout metrics re-measured for it (the sheet's
        // size, below, follows the app's text size).
        .adaptiveLayout()
        .environment(\.dynamicTypeSize, Self.cardTypeSize(typeSize))
        .frame(minWidth: minSize.width, idealWidth: size.width, maxWidth: size.width,
               minHeight: minSize.height, idealHeight: size.height, maxHeight: size.height)
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
        .padding(.vertical, Space.m + Space.xxs)
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
                    .help("Turn on the screensaver first, or skip for now")
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

/// The gap between a page's header and its content, and between its two columns: one step
/// more than the layout's section gap, as the sheet is roomy.
private extension LayoutMetrics {
    var pageGap: CGFloat { sectionGap + Space.xs }
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
        .readableWidth(layout, alignment: .center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A step's body. It scrolls when the text outgrows the sheet (the footer stays pinned), and
/// every step shares the same side inset and top padding, so the header and the content's
/// edges hold their place from step to step. `centered` centres short content in the height
/// (the welcome step).
private struct PageScroll<Content: View>: View {
    var centered = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                content
                    .padding(.horizontal, OnboardingView.inset)
                    .padding(.vertical, Space.xl)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height,
                           alignment: centered ? .center : .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// A step's two columns, top-aligned and equally wide, on the page's insets — stacked (left
/// over right) when the text is big enough that side by side gets cramped.
private struct TwoColumns<Leading: View, Trailing: View>: View {
    @Environment(\.layout) private var layout
    /// The leading column's share of the width (side by side).
    var leadingShare: CGFloat = 0.5
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if layout.prefersStacking {
            VStack(alignment: .leading, spacing: layout.pageGap) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                trailing.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            SplitColumns(share: leadingShare, spacing: layout.pageGap) {
                leading
                trailing
            }
        }
    }
}

/// Two subviews side by side: the first gets `share` of the width (less the gap), the second
/// the rest; as tall as the taller one, both top-aligned.
private struct SplitColumns: Layout {
    var share: CGFloat
    var spacing: CGFloat

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let room = max(0, total - spacing)
        let first = (room * share).rounded()
        return (first, room - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? 800
        let (a, b) = widths(total)
        let ha = subviews[0].sizeThatFits(ProposedViewSize(width: a, height: proposal.height)).height
        let hb = subviews[1].sizeThatFits(ProposedViewSize(width: b, height: proposal.height)).height
        return CGSize(width: total, height: max(ha, hb))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (a, b) = widths(bounds.width)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: a, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: b, height: bounds.height))
    }
}

private extension View {
    /// Tips set against a panel (TwoColumns): side by side, the first tip's title is level with
    /// the panel's first line; stacked under it, the tips' edges are the panel content's.
    func tipsBesidePanel(_ layout: LayoutMetrics) -> some View {
        padding(layout.prefersStacking ? .horizontal : .top, layout.cardPadding)
    }
}

/// A rounded, softly filled panel (the music card, the player rows).
private struct Panel<Content: View>: View {
    @Environment(\.layout) private var layout
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        content
            .padding(layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
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

    /// The fan's widest (the front card is 44 % of it): grows with the text, like the sheet.
    private static let maxHeroWidth: CGFloat = 1000

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
            VStack(spacing: layout.pageGap + Space.xs) {
                heroStack
                    .frame(maxWidth: layout.scaled(Self.maxHeroWidth))
                PageHeader(title: "Welcome to DotStudio",
                           subtitle: "Living, generative screensavers for your Mac.")
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appeared = true }
        }
    }

    /// Three cards fanned out across the width: the front one at 44 %, the side ones tucked
    /// behind it. Sized from the width it gets, so it scales with the sheet.
    private var heroStack: some View {
        let cards = hero
        return Color.clear
            .aspectRatio(2.85, contentMode: .fit)   // the front card plus the tilted side cards' overhang
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { i, preset in
                            let isFront = cards.count == 3 ? i == 1 : i == 0
                            let side: CGFloat = i == 0 ? -1 : 1
                            PreviewCard(preset: preset, live: isFront && livePreview)
                                .frame(width: w * (isFront ? 0.44 : 0.33))
                                .shadow(color: .black.opacity(isFront ? 0.35 : 0.22), radius: isFront ? 20 : 12, y: isFront ? 12 : 6)
                                .rotationEffect(.degrees(isFront ? 0 : Double(side) * (appeared ? 6 : 2)))
                                .offset(x: isFront ? 0 : side * w * (appeared ? 0.25 : 0.08), y: isFront ? 0 : w * 0.02)
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

    var body: some View {
        Group {
            if mode == .create && !CreatePanel.stacks(layout) {
                // Side by side: the effect picker scrolls on its own and fills the height
                // under the header, so this page doesn't scroll as a whole. Same insets as
                // PageScroll, so the header doesn't move when switching tabs.
                VStack(spacing: layout.pageGap) {
                    header
                    CreatePanel(draft: $draft, nameEdited: $nameEdited, livePreview: livePreview, stacked: false)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, OnboardingView.inset)
                .padding(.vertical, Space.xl)
            } else {
                PageScroll {
                    VStack(spacing: layout.pageGap) {
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
                       subtitle: "Pick a preset, or create your own.")
            ScaledSegmentedPicker(title: "Mode", selection: $mode.animation(.easeOut(duration: 0.18)),
                                  options: OnboardingView.PickMode.allCases.map { ($0.rawValue, $0) },
                                  fills: true, alignment: .center)
                .frame(maxWidth: layout.scaled(Space.grid(90)))   // 360: two equal segments
        }
    }

    /// Three across (two under big text), two rows: the six picks fill the page's width.
    private var presetGrid: some View {
        let count = layout.prefersStacking ? 2 : 3
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.gridColumnGap, alignment: .top),
                                        count: count),
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
    /// Stacked: a full-width row (preview beside the name and blurb) above the full-width
    /// pickers, inside the page's scroll (the pickers get a fixed height). Side by side: the
    /// pickers fill the height beside the details column.
    let stacked: Bool

    /// Side by side, the details column has a fixed height to fit in; from .xxLarge text on
    /// (and whenever the layout prefers stacking) it no longer reliably does, so stack.
    static func stacks(_ layout: LayoutMetrics) -> Bool {
        layout.prefersStacking || layout.typeSize >= .xxxLarge
    }

    /// The stacked preview's width at the default text size (grows with `layout.scaled`). Kept
    /// small so the row stays short and the effect picker — the step's main control — starts
    /// on the first screen.
    private static let stackedPreviewWidth = Space.grid(70)   // 280
    @State private var tab: Tab = .effect

    enum Tab: String, CaseIterable, Identifiable {
        case effect = "Effect", canvas = "Canvas"
        var id: String { rawValue }
    }

    private var kind: EffectKind? { draft.effects.first?.kind }

    var body: some View {
        if stacked {
            // Spans the page like the header and the preset grid: no empty half beside it.
            VStack(alignment: .leading, spacing: layout.pageGap) {
                HStack(alignment: .top, spacing: layout.pageGap) {
                    preview
                        .frame(width: layout.scaled(Self.stackedPreviewWidth))
                    detailText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                effectPanel
                    .frame(height: layout.scaled(400))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SplitColumns(share: 0.4, spacing: layout.pageGap) {
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    preview
                    detailText
                }
                .frame(maxHeight: .infinity, alignment: .top)
                effectPanel
            }
        }
    }

    /// Name, effect and what it makes — under the preview side by side, beside it stacked.
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

    private var preview: some View {
        PreviewCard(preset: draft, live: livePreview)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .accessibilityHidden(true)
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
                                .scaledFont { .scaled(points: 20, $0, weight: .semibold) }
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
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 3. Turn it on (the guided setup)

/// The guided setup: the System Settings walkthrough (its picture, the current step's
/// caption) with its "Open System Settings" button, beside the live checklist
/// (SetupGuideChecklist.swift). Polls ~1 s while on screen.
private struct EnablePage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var guide: SetupGuideModel
    let frozenStep: Int?
    let forceStill: Bool

    var body: some View {
        PageScroll {
            VStack(spacing: layout.pageGap) {
                PageHeader(title: "Turn It On",
                           subtitle: "Choose DotStudio in System Settings. Just once.")
                TwoColumns(leadingShare: 0.54) {
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        SetupWalkthrough(frozenStep: frozenStep, forceStill: forceStill,
                                         narrow: layout.prefersStacking)
                        SetupOpenSettingsButton(guide: guide) {
                            // The floating guide keeps the steps beside System Settings; it
                            // opens first so System Settings comes up in front of everything.
                            SetupGuidePanel.shared.show(model: model)
                            guide.openSystemSettings()
                        }
                    }
                } trailing: {
                    SetupChecklist(guide: guide, commitPhrase: "when you continue")
                }
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

/// Show what's playing: the one choice that matters here (Show music, and Full Screen's
/// layout) beside how it connects, how it's controlled, what stays on the Mac and why
/// DotStudio has to keep running. The player rows are Settings › Music's own: each one's
/// status and, for a running player macOS hasn't asked about (or one that was refused), its
/// "Allow…" — MusicNow.allowControl, so macOS's prompt comes only from that click (or System
/// Settings › Automation opens). The page itself never prompts: on appear it only re-checks,
/// silently, like Settings › Music.
private struct MusicPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var now = MusicNow.shared
    /// The tips' icon column.
    @ScaledLength(relativeTo: .headline) private var iconColumn: CGFloat = 44

    var body: some View {
        let spec = model.library.musicSettings
        PageScroll {
            VStack(spacing: layout.pageGap) {
                PageHeader(title: "Show What's Playing",
                           subtitle: "Your screensaver shows the song that's playing.")
                TwoColumns {
                    // The choice, and (while watching) each player's status beside it.
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        displayCard(spec)
                        if now.isMonitoring {
                            players.transition(.opacity)
                        }
                    }
                } trailing: {
                    VStack(alignment: .leading, spacing: layout.sectionGap) {
                        Tip(symbol: "link", tint: .green, iconColumn: iconColumn,
                            title: "Connects on this Mac",
                            detail: "No sign-in. When macOS asks, click OK so the controls work. Change it in Privacy & Security › Automation.")
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
                    .tipsBesidePanel(layout)
                }
                .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: spec.displayMode)
                .animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion), value: now.isMonitoring)
            }
        }
        // A silent re-check (never a prompt), as Settings › Music does.
        .onAppear { now.refreshAutomation() }
    }

    /// Show music (Off / Corner / Full Screen) — the same setting as Settings › Music and the
    /// Screensaver card's Music key — with Full Screen's layouts and one line on the mode.
    private func displayCard(_ spec: MusicSpec) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: layout.itemGap) {
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
        }
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
        Panel {
            VStack(alignment: .leading, spacing: layout.itemGap) {
                MusicPlayerRow(status: now.spotify, now: now)
                Divider()
                MusicPlayerRow(status: now.music, now: now)
            }
        }
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
        PageScroll(centered: true) {
            VStack(spacing: layout.pageGap) {
                // The glyph's own side bearing and the title's ascent already add space, so
                // the tightest step keeps the icon visibly grouped with its header.
                VStack(spacing: Space.xs) {
                    Image(systemName: status == .ready ? "checkmark.seal.fill" : "sparkles")
                        .scaledFont { .scaled(points: 56, $0) }
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(status == .ready ? Color.green : Color.accentColor)
                        .accessibilityHidden(true)
                    PageHeader(title: status == .ready ? "You're All Set" : "Ready When You Are",
                               subtitle: status == .ready
                                   ? "DotStudio plays the next time your screensaver starts."
                                   : "Turn it on later from the Screensaver card.")
                }
                TwoColumns {
                    createCard
                } trailing: {
                    VStack(alignment: .leading, spacing: layout.sectionGap) {
                        Tip(symbol: "arrow.triangle.2.circlepath", tint: .orange, iconColumn: iconColumn,
                            title: "Mix it up",
                            detail: "Add styles to the Screensaver card to rotate them, or set one for night.")
                        Tip(symbol: "cursorarrow.click.2", tint: .purple, iconColumn: iconColumn,
                            title: "Edit anything",
                            detail: "Double-click a tile to change its effects, colors and motion.")
                    }
                    .tipsBesidePanel(layout)
                }
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
            .accessibilityHidden(true)
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
