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
        // Console: the header strip carries the name and its kind tag itself (see the toolbar)
        .modifier(ConsoleHidesWindowTitle(console: console))
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
                // Console: the design's status tag — real facts (kind, source, the rate it
                // plays at), or what the fader in your hand is changing while you move it
                if console { ConsoleStatusTag(facts: statusFacts(preset)) }
            }
            .aspectRatio(screenAspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: console ? Self.consoleRadius : Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: console ? Self.consoleRadius : Radius.l, style: .continuous)
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

    /// Console: the design's panel corners (its rounded-md).
    static let consoleRadius: CGFloat = 6

    /// Console: the preview tag's facts — "SCENE // 60 FPS", "LOOK // SLIDESHOW // 30 FPS".
    private func statusFacts(_ preset: Preset) -> String {
        var parts = [preset.isScene ? "Scene" : "Look"]
        if !preset.isScene {
            switch model.library.source.kind {
            case .collection: parts.append("Slideshow")
            case .image: parts.append("Photo")
            case .video: parts.append("Video")
            case .gradient: parts.append("Gradient")
            }
        }
        parts.append("\(preset.playFPS(limit: model.library.frameRate ?? 120)) fps")
        return parts.joined(separator: " // ")
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
            if console {
                consoleHeader(binding, name: name, isScene: isScene)
            } else {
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
            }

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
        .clipShape(RoundedRectangle(cornerRadius: console ? Self.consoleRadius : Radius.card, style: .continuous))
    }

    /// Console: the design's inspector header — the name in the display face with the
    /// INSPECTOR legend at its end, a hairline under them; then (a Look) its Effects | Source
    /// keys.
    private func consoleHeader(_ binding: Binding<Preset>, name: String, isScene: Bool) -> some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                TextField("Name", text: binding.name, axis: .vertical)
                    .textFieldStyle(.plain)
                    .textRole(.consoleHeadline)
                    .foregroundStyle(ConsoleInk.ink)
                    .lineLimit(1...3)
                    .help(name)
                Text("Inspector")
                    .textRole(.legend)
                    .foregroundStyle(ConsoleInk.legend)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.bottom, Space.xs)
            .overlay(alignment: .bottom) { Rectangle().fill(ConsoleInk.hairline).frame(height: 1) }
            if !isScene {
                SegmentedChoice(title: "Section",
                                selection: $tab.animation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion)),
                                options: Tab.allCases.map { ($0.rawValue, $0) })
            }
        }
        .padding([.horizontal, .top], layout.cardPadding)
        .padding(.bottom, Space.xxs)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ preset: Preset) -> some ToolbarContent {
        if console {
            consoleToolbar(preset)
        } else {
            classicToolbar(preset)
        }
    }

    /// Console: the design's header strip — a square back key, the name with its kind tag;
    /// at the end ▶ (full-screen preview) and ••• keys. The same actions and menu as Classic.
    @ToolbarContentBuilder
    private func consoleToolbar(_ preset: Preset) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: Space.s) {
                Button { model.closeEditor() } label: {
                    HeaderKeyGlyph(systemImage: "chevron.left")
                }
                .buttonStyle(.iconKeycap)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to all styles (⌘[)")
                .accessibilityLabel("Library")
                HStack(spacing: Space.xs) {
                    Text(preset.name)
                        .textRole(.consoleTitle)
                        .foregroundStyle(ConsoleInk.ink)
                        .lineLimit(1)
                    ConsoleTag(text: preset.isScene ? "Scene" : "Look").fixedSize()
                }
                .padding(.bottom, ConsoleKeycapStyle.skirt)   // on the keys' faces, not their skirts
                .accessibilityElement(children: .combine)
            }
            .fixedSize()
        }
        .consoleBareToolbarItem()
        // (with the window title gone, nothing else pushes the keys to the strip's end)
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: Space.xxs) {
                Button {
                    ScreensaverPreviewController.shared.present(
                        preset: preset, source: model.library.source, store: model.store)
                } label: {
                    HeaderKeyGlyph(systemImage: "play.fill")
                }
                .buttonStyle(.iconKeycap)
                .help("Full-screen preview — move the mouse or press any key to exit")
                .accessibilityLabel("Preview")
                ConsoleMenuButton(title: "More", edge: .trailing) { moreEntries } label: { HeaderMenuKey() }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Duplicate, export, or delete this style")
                    .accessibilityLabel("More")
            }
        }
        .consoleBareToolbarItem()
    }

    /// The ••• menu (both appearances: Classic's toolbar menu, Retro's header key).
    private var moreEntries: [MenuEntry] {
        EditorMenus.more(model, id: id, wallpaper: wallpaper) { confirmDelete = true }
    }

    @ToolbarContentBuilder
    private func classicToolbar(_ preset: Preset) -> some ToolbarContent {
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
                NativeMenuItems(moreEntries)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Duplicate, export, or delete this style")
        }
    }
}

/// The editor's menus as items (MenuEntry), for both looks and UIShots' captures.
enum EditorMenus {
    @MenuBuilder
    static func more(_ model: AppModel, id: UUID, wallpaper: WallpaperSlot, delete: @escaping () -> Void) -> [MenuEntry] {
        MenuEntry.button("Duplicate") { model.duplicate(id).map { model.edit($0) } }
        MenuEntry.button("Export Style…") { model.exportPreset(id) }
        MenuEntry.divider
        if wallpaper.isAvailable {
            if wallpaper.styleID == id {
                MenuEntry.button("Stop Wallpaper") { wallpaper.stop() }
            } else {
                MenuEntry.button("Set as Wallpaper") { wallpaper.set(id) }
            }
        }
        MenuEntry.button("Save Image…") { model.exportSelectedAsImage(id) }
        MenuEntry.button("Set as Desktop Picture (Still)") { model.setSelectedAsWallpaper(id) }
        MenuEntry.divider
        MenuEntry.button("Delete…", destructive: true, delete)
    }

    /// The wallpaper key's menu under the preview (DestinationBar).
    @MenuBuilder
    static func wallpaper(id: UUID, wallpaper: WallpaperSlot, controller: WallpaperController,
                          synced: Bool, isOurs: Bool) -> [MenuEntry] {
        MenuEntry.button(isOurs ? "Stop Wallpaper" : "Set as Wallpaper") {
            Motion.run { if isOurs { wallpaper.stop() } else { wallpaper.set(id) } }
        }
        MenuEntry.toggle("Same as Screensaver", isOn: synced) { on in Motion.run { controller.setFollowsScreensaver(on) } }
        if synced {
            MenuEntry.divider
            MenuEntry.button("Stop Wallpaper") { Motion.run { wallpaper.stop() } }
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
/// Console draws them as the design's keycaps instead, with the same actions.
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
                        DestinationLabel(title: playlistLabel, systemImage: inPlaylist ? "checkmark" : "plus")
                    }
                    .modifier(DestinationButtonStyle(latched: inPlaylist))
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
            GlassMenuPill(title: "Wallpaper: Same as Screensaver", systemImage: "link", lit: true,
                          entries: wallpaperMenu(synced: true, isOurs: false))
            .help("The wallpaper plays whatever the screensaver shows — set this style instead, or stop it")
        } else {
            let title = isOurs ? "Stop Wallpaper" : "Set as Wallpaper"
            GlassMenuPill(title: title, systemImage: "photo.artframe", lit: isOurs,
                          primary: { Motion.run { wallpaper.toggle(id) } },
                          entries: wallpaperMenu(synced: false, isOurs: isOurs))
            .help("\(title) — or, from the arrow, Same as Screensaver")
        }
    }

    private func wallpaperMenu(synced: Bool, isOurs: Bool) -> [MenuEntry] {
        EditorMenus.wallpaper(id: id, wallpaper: wallpaper, controller: controller, synced: synced, isOurs: isOurs)
    }
}

/// A glass button with a menu, among the destination buttons. With `primary`, a split button:
/// the title runs it and the chevron opens the menu; without, the whole capsule opens it.
/// Sized like `DestinationPill` (an invisible glass button with the same label), and drawn
/// plain over it, so the title is role-sized like its neighbours' — a stock pull-down's
/// title is AppKit's and never follows the text size.
/// Console: a keycap (`ConsoleSplitKey`), blue when `lit`.
private struct GlassMenuPill: View {
    let title: String
    let systemImage: String
    /// Console: this style is on the wallpaper (or the wallpaper follows the screensaver).
    var lit = false
    var primary: (() -> Void)? = nil
    let entries: [MenuEntry]
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .body) private var chevronWidth: CGFloat = Space.grid(7)   // 28

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
        Menu { NativeMenuItems(entries) } label: { label() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }

    // MARK: Console

    /// The same split key (title runs `primary`, the chevron opens the menu) or menu key, as
    /// a Console keycap with travel — blue while the wallpaper plays this style (or follows the
    /// screensaver), as the design's "playing behind your windows" colour.
    private var consoleKey: some View {
        ConsoleSplitKey(title: title, systemImage: systemImage, lit: lit, primary: primary, entries: entries)
    }
}

/// Console: the wallpaper's split key. Its face is drawn here (a Menu can't take a ButtonStyle),
/// and each half sinks on its own press.
private struct ConsoleSplitKey: View {
    let title: String
    let systemImage: String
    let lit: Bool
    var primary: (() -> Void)?
    let entries: [MenuEntry]
    @State private var hovering = false
    @ScaledLength(relativeTo: .body) private var chevronWidth: CGFloat = Space.grid(7)   // 28
    @ScaledInsets(relativeTo: DestinationConsoleMetrics.style) private var padding = DestinationConsoleMetrics.padding

    var body: some View {
        let ink: Color = lit ? .white : (hovering ? ConsoleInk.signalInk : ConsoleInk.ink)
        Group {
            if let primary {
                HStack(spacing: 0) {
                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        primary()
                    }) {
                        DestinationConsoleLegend(title: title, systemImage: systemImage)
                            .padding(.leading, padding.leading)
                            .padding(.trailing, padding.trailing * 0.75)   // 12 at the default size
                            .padding(.vertical, padding.top)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    Rectangle()
                        .fill(lit ? Color.white.opacity(0.3) : ConsoleInk.hairline)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                    menu { chevron }
                        .accessibilityLabel("More wallpaper options")
                }
            } else {
                menu {
                    HStack(spacing: 0) {
                        DestinationConsoleLegend(title: title, systemImage: systemImage)
                            .padding(.leading, padding.leading)
                            .padding(.vertical, padding.top)
                        chevron
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(title)
            }
        }
        .foregroundStyle(ink)
        .fixedSize()
        .consoleKeyFace(lit ? .blue : .plain, hovering: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .textRole(.captionEmphasis)
            .opacity(0.75)
            .frame(width: chevronWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// The Retro dropdown, hanging from the key's trailing edge.
    private func menu<L: View>(@ViewBuilder label: @escaping () -> L) -> some View {
        ConsoleMenuButton(title: "Wallpaper", edge: .trailing) { entries } label: { label() }
            .buttonStyle(.plain)
    }
}

/// A status capsule among the destination buttons ("Your Screensaver", "At Night"). It is
/// sized by an invisible glass button with the same label, so at every control size and
/// text size a pill is exactly as tall, padded and round as the buttons beside it; the
/// visible capsule is plain (non-interactive) glass with a medium-weight title.
/// Console: a key held down with its LED lit — a state, not a control.
private struct DestinationPill: View {
    let title: String
    let systemImage: String
    @Environment(\.console) private var console
    @ScaledInsets(relativeTo: DestinationConsoleMetrics.style) private var padding = DestinationConsoleMetrics.padding

    var body: some View {
        if console {
            HStack(spacing: Space.xs) {
                ConsoleLED(on: true)
                DestinationConsoleLegend(title: title, systemImage: nil)
            }
            .foregroundStyle(ConsoleInk.ink)
            .padding(padding)
            // held down as a state: the face rests in its skirt, the footprint level with
            // the keys beside it
            .consoleKeyFace(latched: true)
            .help(title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
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
/// mono-caps legend with its symbol.
private struct DestinationLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.console) private var console

    var body: some View {
        if console {
            DestinationConsoleLegend(title: title, systemImage: systemImage)
        } else {
            ScaledControlLabel(title: title, systemImage: systemImage)
        }
    }
}

/// A destination button's style: glass (Classic) or a Console keycap — orange for the main
/// action, held down while `latched` (In Playlist).
private struct DestinationButtonStyle: ViewModifier {
    var kind: GlassButtonKind = .normal
    var latched = false
    @Environment(\.console) private var console
    @ScaledInsets(relativeTo: DestinationConsoleMetrics.style) private var padding = DestinationConsoleMetrics.padding

    func body(content: Content) -> some View {
        if console {
            content.buttonStyle(.keycap(kind == .prominent ? .signal : .plain, latched: latched,
                                        padding: padding))
        } else {
            content.glassButton(kind)
        }
    }
}

/// Console key metrics under the preview (the design's px-16 py-8 keys) at the default text
/// size. Each key reads them through `@ScaledInsets` relative to its legend's role
/// (consoleKeyLarge, a callout), so the margins grow with the text.
private enum DestinationConsoleMetrics {
    static let padding = EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    static let style: Font.TextStyle = .callout
}

/// A Console destination key's legend: its symbol and the words in mono caps (12 pt, the
/// design's label-lg). The words carry the state ("In Playlist", "Stop Wallpaper"); in a
/// narrow column (big text) a legend takes a second line before it ever truncates.
private struct DestinationConsoleLegend: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: Space.xs - 2) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textRole(.consoleKeyLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// The inspector's card: glass (Classic) or a flat panel (Console).
private struct InspectorSurface: ViewModifier {
    let console: Bool
    func body(content: Content) -> some View {
        if console { content.consolePanel(cornerRadius: EditorView.consoleRadius) }
        else { content.glassCard(cornerRadius: Radius.card) }
    }
}

/// Console: the header strip names the style itself (name + kind tag), so the window's own
/// title and subtitle leave the toolbar while the editor is up (macOS 15+; before that both
/// show). Classic: nothing changes.
private struct ConsoleHidesWindowTitle: ViewModifier {
    let console: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: console ? .title : nil)
        } else {
            content
        }
    }
}

extension ToolbarContent {
    /// Console: a toolbar item without the system's shared glass backing (macOS 26), so its
    /// keycaps sit straight on the header strip.
    @ToolbarContentBuilder
    func consoleBareToolbarItem() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// A header keycap's glyph (back, ▶): a 34 pt square face (36 pt with its 2 pt skirt; 32 + 4, and 28 + 4, before).
private struct HeaderKeyGlyph: View {
    let systemImage: String
    @ScaledLength(relativeTo: .body) private var side: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13.5, weight: .semibold))
            .frame(width: side, height: side)
            .contentShape(Rectangle())
    }
}

/// The header's ••• key: a Menu can't take the keycap ButtonStyle, so its face is drawn.
private struct HeaderMenuKey: View {
    @State private var hovering = false
    @ScaledLength(relativeTo: .body) private var side: CGFloat = 34

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(hovering ? ConsoleInk.signalInk : ConsoleInk.ink)
            .frame(width: side, height: side)
            .consoleKeyFace(hovering: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Console: the preview's status tag (the design's top-left readout): a blue light and the
/// style's real facts in mono caps; while a dial is turned, a light in its cap's colour, what
/// it is and its value. Its own view, so only it redraws as the value moves.
private struct ConsoleStatusTag: View {
    let facts: String
    @ObservedObject private var touch = ConsoleTouch.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .caption2) private var dot: CGFloat = 8

    var body: some View {
        let t = touch.current
        HStack(spacing: Space.xxs + 2) {
            Circle().fill(t.map { ConsoleInk.knobs[$0.colorIndex % ConsoleInk.knobs.count] } ?? ConsoleInk.blue)
                .overlay(Circle().strokeBorder(ConsoleInk.hairline, lineWidth: 0.5))   // (the white cap's light)
                .frame(width: dot, height: dot)
            if let t {
                Text(t.label).textRole(.legend).foregroundStyle(ConsoleInk.legend)
                Text(t.value).textRole(.legend).foregroundStyle(ConsoleInk.ink)
                    .contentTransition(.numericText())
            } else {
                Text(facts).textRole(.legend).foregroundStyle(ConsoleInk.legend)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ConsoleInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(ConsoleInk.hairline))
        .padding(Space.s)
        .animation(Motion.pick(Motion.brief, reduceMotion: reduceMotion), value: t?.label)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts)
    }
}
