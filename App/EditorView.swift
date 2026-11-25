//  EditorView.swift — edit one style: a big live preview floating over the style's own
//  ambient wash, and a glass inspector on the right.

import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    @Environment(\.heroNamespace) private var hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    let id: UUID
    @State private var tab: Tab = .effects
    @State private var confirmDelete = false
    /// The live Metal view fades in once the zoom from the tile has landed.
    @State private var live = false

    enum Tab: String, CaseIterable, Identifiable {
        case effects = "Effects", source = "Source"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = Perf.body("EditorView")
        let binding = model.presetBinding(id)
        let preset = binding.wrappedValue
        // Two columns, one margin on every side and between them (20 · 32 · 48 by width): the
        // preview takes all the room the inspector leaves and grows with the window; the
        // inspector keeps its comfortable width range. Both start on the same top edge.
        HStack(alignment: .top, spacing: layout.pagePadding) {
            previewPane(preset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            inspector(binding, name: preset.name)
                .frame(width: layout.inspectorWidth)
                .frame(maxHeight: .infinity)
                .modifier(InspectorSurface(console: console))
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
        .padding(layout.pagePadding)
        .toolbar { toolbar(preset) }
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: {
            Text("This can't be undone.")
        }
        .onChange(of: preset.isScene) { _, isScene in if isScene { tab = .effects } }
        .onAppear {
            if reduceMotion { live = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * Motion.slow) {
                withAnimation(.easeIn(duration: 0.3)) { live = true }
            }
        }
    }

    // MARK: Preview

    /// The preview on the inspector's top edge, as big as the column allows (by width, or by
    /// the height left after the destination row), with the destination row right under it.
    private func previewPane(_ preset: Preset) -> some View {
        VStack(spacing: layout.itemGap) {
            ZStack {
                // The still only until the live preview is up: under it, it would re-render on
                // every edit for nothing. The hero geometry stays on the (black) frame.
                Color.black
                    .heroGeometry(id, in: hero)
                if !live || DemoHooks.livePreviewsPaused {
                    StyleThumb(preset: preset)
                        // Gone only once the live view has faded in over it (no dip to black).
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .opacity.animation(.linear(duration: 0.01).delay(0.6))))
                }
                if live && !DemoHooks.livePreviewsPaused {
                    MetalPreview(preset: preset, source: model.library.source,
                                 location: model.locationTuple, store: model.store,
                                 music: model.library.musicSettings)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                // Console: what the knob in your hand is changing, in its colour
                if console { ConsoleTouchTag() }
            }
            .aspectRatio(screenAspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(console ? ConsoleInk.hairline : Color.white.opacity(0.12)))
            // Layered shadow: a tight contact shadow plus a wide, soft lift. Console sits flat
            // on the chassis: its hairline and a 1-pt contact shadow, no lift. (Values, not an
            // if/else: a different view tree would restart the live Metal preview.)
            .shadow(color: .black.opacity(console ? 0.12 : 0.18), radius: console ? 1 : 3, y: console ? 1 : 2)
            .shadow(color: .black.opacity(console ? 0 : 0.30), radius: console ? 0 : 34, y: console ? 0 : 18)
            .onTapGesture(count: 2) {
                ScreensaverPreviewController.shared.present(
                    preset: preset, source: model.library.source, store: model.store)
            }
            .help("Double-click for a full-screen preview")

            DestinationBar(id: id)
                .layoutPriority(1)   // its full height first; the preview fits what's left
        }
    }

    private var screenAspect: CGFloat {
        guard let f = NSScreen.main?.frame, f.height > 0 else { return 16.0 / 10.0 }
        return f.width / f.height
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ binding: Binding<Preset>, name: String) -> some View {
        let isScene = binding.wrappedValue.isScene
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: layout.itemGap) {
                // A long name wraps (up to 3 lines) instead of running off the card.
                TextField("Name", text: binding.name, axis: .vertical)
                    .textFieldStyle(.plain)
                    .textRole(.inspectorTitle)
                    .lineLimit(1...3)
                    .help(name)
                // Scenes draw themselves (no shared source), so they have no tabs: just the
                // name, and the list starts right under it.
                if !isScene {
                    SegmentedChoice(title: "Section",
                                    selection: $tab.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion)),
                                    options: Tab.allCases.map { ($0.rawValue, $0) })
                }
            }
            .padding([.horizontal, .top], layout.cardPadding)
            .padding(.bottom, layout.itemGap)
            Divider().opacity(0.6)
                .padding(.horizontal, layout.cardPadding)

            ZStack {
                if tab == .source && !isScene {
                    // Same edges as the Effects list: content on edge A, and its first line
                    // as far below the divider as the list's first row, so switching tabs
                    // doesn't shift anything. The inspector's own metrics (not a new root),
                    // so both tabs share one set of gaps.
                    ScrollView {
                        SourceEditor(source: model.sourceBinding, model: model, isLayoutRoot: false)
                            .padding(.horizontal, layout.cardPadding)
                            .padding(.top, EffectStackView.listTopInset + layout.labelGap)
                            .padding(.bottom, layout.cardPadding)
                    }
                    .transition(.opacity)
                } else {
                    EffectStackView(preset: binding, model: model)
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ preset: Preset) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.closeEditor() } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to all styles (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                ScreensaverPreviewController.shared.present(
                    preset: preset, source: model.library.source, store: model.store)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .help("Full-screen preview — move the mouse or press any key to exit")

            Menu {
                Button("Duplicate") { model.duplicate(id).map { model.edit($0) } }
                Button("Export Style…") { model.exportPreset(id) }
                Divider()
                if wallpaper.isAvailable {
                    if wallpaper.styleID == id {
                        Button("Stop Wallpaper") { wallpaper.stop() }
                    } else {
                        Button("Set as Wallpaper") { wallpaper.set(id) }
                    }
                }
                Button("Save Image…") { model.exportSelectedAsImage(id) }
                Button("Set as Desktop Picture (Still)") { model.setSelectedAsWallpaper(id) }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Duplicate, export, or delete this style")
        }
    }
}

extension TextRole {
    /// The style's name at the top of the inspector (macOS .title3, 15 pt semibold).
    /// Layout.swift has no title3 role; this one is local to the editor.
    static let inspectorTitle = TextRole(style: .title3, weight: .semibold)
}

/// Under the editor preview: where this style plays, as glass buttons. They wrap onto a
/// second centred line when the preview column is too narrow, instead of truncating.
/// Every title is role-sized (`ScaledControlLabel`), so the editor's main actions grow with
/// the text like everything around them; `.adaptiveControlSize` steps the bezels.
/// Console draws them as flat keys instead (`DestinationKeyFace`), with the same actions.
private struct DestinationBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var wallpaper = WallpaperSlot.shared
    /// "Same as Screensaver" lives on the controller (the slot only knows styles).
    @ObservedObject private var controller = WallpaperController.shared
    @Environment(\.layout) private var layout
    let id: UUID

    var body: some View {
        let _ = Perf.body("DestinationBar")
        let lineup = model.screensaverLineup
        let only = lineup.playlist == [id]
        let inPlaylist = lineup.playlist.contains(id)
        let playlistLabel = inPlaylist ? "In Playlist" : "Add to Screensaver"
        GlassGroup(spacing: layout.controlGap) {
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .center) {
                if only {
                    DestinationPill(title: "Your Screensaver", systemImage: "checkmark.circle.fill")
                } else {
                    Button { Motion.run { model.playAsScreensaver(id) } } label: {
                        DestinationLabel(title: "Play as Screensaver", systemImage: "play.fill")
                    }
                    .modifier(DestinationButtonStyle(kind: .prominent))
                    .help("Play as Screensaver — make this the only style your screensaver shows")
                    Button { Motion.run { model.togglePlaylist(id) } } label: {
                        DestinationLabel(title: playlistLabel, systemImage: inPlaylist ? "checkmark" : "plus",
                                         lit: inPlaylist)
                    }
                    .modifier(DestinationButtonStyle())
                    .help(inPlaylist ? "In Playlist — click to remove it from the screensaver playlist"
                                     : "Add to Screensaver — rotate this with the other styles in the playlist")
                }
                if lineup.night == id {
                    DestinationPill(title: "At Night", systemImage: "moon.fill")
                }
                if wallpaper.isAvailable {
                    wallpaperControl
                }
            }
            .adaptiveControlSize(.large)
        }
        .motion(Motion.smooth, value: lineup)
    }

    /// The wallpaper's button. Not following the screensaver: a click sets this style as the
    /// wallpaper (or stops it, when it is), and its menu offers "Same as Screensaver". While the
    /// wallpaper is Same as Screensaver, the button says so and its menu sets this style
    /// instead, turns sync off, or stops the wallpaper.
    @ViewBuilder private var wallpaperControl: some View {
        let synced = controller.isActive && controller.followsScreensaver
        let isOurs = !synced && wallpaper.styleID == id
        if synced {
            GlassMenuPill(title: "Wallpaper: Same as Screensaver", systemImage: "link", lit: true) {
                wallpaperMenu(synced: true, isOurs: false)
            }
            .help("The wallpaper plays whatever the screensaver shows — set this style instead, or stop it")
        } else {
            let title = isOurs ? "Stop Wallpaper" : "Set as Wallpaper"
            GlassMenuPill(title: title, systemImage: "photo.artframe", lit: isOurs,
                          primary: { Motion.run { wallpaper.toggle(id) } }) {
                wallpaperMenu(synced: false, isOurs: isOurs)
            }
            .help("\(title) — or, from the arrow, Same as Screensaver")
        }
    }

    @ViewBuilder private func wallpaperMenu(synced: Bool, isOurs: Bool) -> some View {
        Button(isOurs ? "Stop Wallpaper" : "Set as Wallpaper") {
            Motion.run { if isOurs { wallpaper.stop() } else { wallpaper.set(id) } }
        }
        Toggle("Same as Screensaver", isOn: Binding(get: { synced },
                                                    set: { on in Motion.run { controller.setFollowsScreensaver(on) } }))
        if synced {
            Divider()
            Button("Stop Wallpaper") { Motion.run { wallpaper.stop() } }
        }
    }
}

/// A glass button with a menu, among the destination buttons. With `primary`, a split button:
/// the title runs it and the chevron opens the menu; without, the whole capsule opens it.
/// Sized like `DestinationPill` (an invisible glass button with the same label), and drawn
/// plain over it, so the title is role-sized like its neighbours' — a stock pull-down's
/// title is AppKit's and never follows the text size.
/// Console: a flat key (`DestinationKeyFace`), its LED lit when `lit`.
private struct GlassMenuPill<Items: View>: View {
    let title: String
    let systemImage: String
    /// Console: this style is on the wallpaper (or the wallpaper follows the screensaver).
    var lit = false
    var primary: (() -> Void)? = nil
    @ViewBuilder var items: Items
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .body) private var chevronWidth: CGFloat = Space.grid(7)   // 28
    @ScaledLength(relativeTo: .body) private var keyInset: CGFloat = DestinationKeyMetrics.inset
    @ScaledLength(relativeTo: .body) private var keyLineInset: CGFloat = Space.xxs

    var body: some View {
        if console { consoleKey } else { glass }
    }

    private var glass: some View {
        Button {} label: {
            HStack(spacing: 0) { label; Color.clear.frame(width: chevronWidth, height: 1) }
        }
        .glassButton()
        .hidden()
        .overlay {
            visible
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassSurface(.regular, in: Capsule())
        }
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        ScaledControlLabel(title: title, systemImage: systemImage).lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .textRole(.captionEmphasis)
            .foregroundStyle(.secondary)
            .frame(width: chevronWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var visible: some View {
        if let primary {
            HStack(spacing: 0) {
                Button(action: primary) {
                    label.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1)
                    .padding(.vertical, Space.xs)
                    .accessibilityHidden(true)
                menu { chevron }
                    .accessibilityLabel("More wallpaper options")
            }
        } else {
            menu {
                HStack(spacing: 0) {
                    label.frame(maxWidth: .infinity)
                    chevron
                }
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
            }
            .accessibilityLabel(title)
        }
    }

    /// A plain-styled menu draws its own (role-sized) label.
    private func menu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu { items } label: { label() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }

    // MARK: Console

    /// The same split key (title runs `primary`, the chevron opens the menu) or menu key, as
    /// a flat Console key. Sized by the key itself, like its neighbours.
    private var consoleKey: some View {
        DestinationKeyFace(padded: false) {
            if let primary {
                HStack(spacing: 0) {
                    Button(action: primary) {
                        DestinationKeyLegend(title: title, lit: lit)
                            .padding(.leading, keyInset)
                            .padding(.trailing, keyInset / 2)
                            .padding(.vertical, keyLineInset)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    Rectangle()
                        .fill(ConsoleInk.hairline)
                        .frame(width: 1)
                        .padding(.vertical, Space.xs)
                        .accessibilityHidden(true)
                    menu { consoleChevron }
                        .accessibilityLabel("More wallpaper options")
                }
            } else {
                menu {
                    HStack(spacing: 0) {
                        DestinationKeyLegend(title: title, lit: lit)
                            .padding(.leading, keyInset)
                            .padding(.vertical, keyLineInset)
                        consoleChevron
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(title)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var consoleChevron: some View {
        Image(systemName: "chevron.down")
            .textRole(.captionEmphasis)
            .foregroundStyle(ConsoleInk.legend)
            .frame(width: chevronWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

/// A status capsule among the destination buttons ("Your Screensaver", "At Night"). It is
/// sized by an invisible glass button with the same label, so at every control size and
/// text size a pill is exactly as tall, padded and round as the buttons beside it; the
/// visible capsule is plain (non-interactive) glass with a medium-weight title.
/// Console: a flat key with its LED lit — a state, not a control.
private struct DestinationPill: View {
    let title: String
    let systemImage: String
    @Environment(\.console) private var console

    var body: some View {
        if console {
            DestinationKeyFace { DestinationKeyLegend(title: title, lit: true) }
                .help(title)
                .accessibilityElement(children: .combine)
        } else {
            glass
        }
    }

    private var glass: some View {
        Button {} label: { label }
            .glassButton()
            .hidden()
            .overlay {
                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassSurface(.regular, in: Capsule())
            }
            .help(title)
            .accessibilityElement(children: .combine)
    }

    private var label: some View {
        ScaledControlLabel(title: title, systemImage: systemImage, role: .bodyEmphasis)
            .lineLimit(1)
    }
}

// MARK: - Destination buttons: glass (Classic) or Console keys

/// A destination button's title: role-sized with its symbol (Classic), or a Console key's
/// legend — with an LED instead of the symbol where the button has an on state (`lit`).
private struct DestinationLabel: View {
    let title: String
    let systemImage: String
    var lit: Bool? = nil
    @Environment(\.console) private var console

    var body: some View {
        if console {
            DestinationKeyLegend(title: title, systemImage: lit == nil ? systemImage : nil, lit: lit)
        } else {
            ScaledControlLabel(title: title, systemImage: systemImage)
        }
    }
}

/// A destination button's style: glass (Classic) or a flat Console key.
private struct DestinationButtonStyle: ViewModifier {
    var kind: GlassButtonKind = .normal
    @Environment(\.console) private var console

    func body(content: Content) -> some View {
        if console { content.buttonStyle(DestinationKeyStyle(prominent: kind == .prominent)) }
        else { content.glassButton(kind) }
    }
}

/// Console (issue #6) key metrics at the default text size; they scale with the text.
private enum DestinationKeyMetrics {
    /// A key's height: a large stock control's.
    static let height: CGFloat = Space.grid(7)   // 28
    /// Its legend's inset from the key's ends.
    static let inset: CGFloat = Space.s           // 12
}

private extension TextRole {
    /// A Console key's legend under the editor preview: small mono caps (11 pt).
    static let destinationKey = TextRole(style: .subheadline, weight: .semibold, design: .monospaced,
                                         tracking: 0.5, uppercase: true)
}

/// Console: a flat key on the chassis — the panel colour (the recessed well while pressed;
/// graphite ink for the main action), a hairline edge, no glass and no shadow. Every key is
/// this tall at a given text size, so a row of them lines up.
private struct DestinationKeyFace<Content: View>: View {
    var prominent = false
    var pressed = false
    /// Insets the content from the key's edges (a split key insets its own parts, so the
    /// whole face stays clickable).
    var padded = true
    @ViewBuilder var content: Content
    @ScaledLength(relativeTo: .body) private var height: CGFloat = DestinationKeyMetrics.height
    @ScaledLength(relativeTo: .body) private var inset: CGFloat = DestinationKeyMetrics.inset
    /// Above and below a two-line legend (a one-line one sits inside `height` anyway).
    @ScaledLength(relativeTo: .body) private var lineInset: CGFloat = Space.xxs

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        content
            .padding(.horizontal, padded ? inset : 0)
            .padding(.vertical, padded ? lineInset : 0)
            .frame(minHeight: height)
            .foregroundStyle(prominent ? ConsoleInk.chassis : ConsoleInk.ink)
            .background(shape.fill(prominent ? ConsoleInk.ink.opacity(pressed ? 0.8 : 1)
                                             : pressed ? ConsoleInk.well : ConsoleInk.panel))
            .overlay(shape.strokeBorder(ConsoleInk.hairline, lineWidth: 1))
            .contentShape(shape)
    }
}

private struct DestinationKeyStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        DestinationKeyFace(prominent: prominent, pressed: configuration.isPressed) { configuration.label }
    }
}

/// A Console key's legend: mono caps, after its LED (lit in the signal colour when on) or,
/// for a plain action, its symbol. The words carry the state ("In Playlist", "Stop
/// Wallpaper"), so the LED is never the only signal, and VoiceOver reads just the words.
private struct DestinationKeyLegend: View {
    let title: String
    var systemImage: String? = nil
    var lit: Bool? = nil
    @Environment(\.layout) private var layout

    var body: some View {
        HStack(spacing: layout.iconGap) {
            if let lit {
                ConsoleLED(on: lit)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            // Mono caps run wide: in a narrow column (big text) a legend takes a second line
            // before it ever truncates (the key's tooltip has it in full).
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textRole(.destinationKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// The inspector's card: glass (Classic) or a flat panel (Console).
private struct InspectorSurface: ViewModifier {
    let console: Bool
    func body(content: Content) -> some View {
        if console { content.consolePanel(cornerRadius: Radius.card) }
        else { content.glassCard(cornerRadius: Radius.card) }
    }
}

/// Console: while a knob is turned, a tag in its colour over the preview says what is
/// changing and to what ("● GRAIN 42%"), with the preview's edge lit in the same colour.
/// Its own view, so only it redraws as the value moves.
private struct ConsoleTouchTag: View {
    @ObservedObject private var touch = ConsoleTouch.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .caption2) private var dot: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let t = touch.current {
                let c = ConsoleInk.knobs[t.colorIndex % ConsoleInk.knobs.count]
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(c.opacity(0.9), lineWidth: 2)
                    .allowsHitTesting(false)
                HStack(spacing: Space.xs) {
                    Circle().fill(c).frame(width: dot, height: dot)
                    Text(t.label).textRole(.legend).foregroundStyle(.white.opacity(0.85))
                    Text(t.value).textRole(.readout).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs + 2)
                .background(Capsule().fill(.black.opacity(0.6)))
                .overlay(Capsule().strokeBorder(c.opacity(0.8), lineWidth: 1))
                .padding(Space.s)
                .transition(.opacity)
                .accessibilityHidden(true)   // the knob itself speaks its value
            }
        }
        .animation(Motion.pick(Motion.brief, reduceMotion: reduceMotion), value: touch.current?.label)
        .allowsHitTesting(false)
    }
}
