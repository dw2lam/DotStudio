//  DestinationCards.swift — the two glass cards at the top of the gallery that say
//  where styles play: the Screensaver (a playlist + optional night style, plus setup)
//  and the live Wallpaper. See Destinations.swift for how they map onto library.json.

import SwiftUI

/// The gallery's snapshot of who plays where, computed once per render.
struct GalleryState {
    let lineup: ScreensaverLineup
    let nowPlaying: UUID?
    let wallpaperID: UUID?

    init(model: AppModel, wallpaperID: UUID?) {
        lineup = model.screensaverLineup
        nowPlaying = model.nowPlayingID
        self.wallpaperID = wallpaperID
    }

    /// Styles on any destination (the "Playing" filter).
    var playingIDs: Set<UUID> {
        var s = Set(lineup.playlist)
        if let n = lineup.night { s.insert(n) }
        if let w = wallpaperID { s.insert(w) }
        return s
    }

    func badges(for id: UUID) -> TileBadges {
        TileBadges(onScreensaver: lineup.playlist.contains(id),
                   inRotation: lineup.rotates && lineup.playlist.contains(id),
                   playingNow: nowPlaying == id,
                   night: lineup.night == id,
                   wallpaper: wallpaperID == id)
    }
}

struct TileBadges: Equatable {
    var onScreensaver = false
    var inRotation = false
    var playingNow = false
    var night = false
    var wallpaper = false
    var isEmpty: Bool { !onScreensaver && !night && !wallpaper }
}

// MARK: - Card metrics

fileprivate extension LayoutMetrics {
    /// Width of a destination card's preview (the Screensaver hero, and the Wallpaper
    /// preview when that card lays out side by side): the small end of `heroWidth` in
    /// compact windows and at accessibility text sizes, the large end otherwise.
    var destinationPreviewWidth: CGFloat {
        isCompact || typeSize.isAccessibilitySize ? heroWidth.lowerBound : heroWidth.upperBound
    }

    /// Widest the Screensaver card gets beside the Wallpaper card: its preview plus a text
    /// column of readable width. Past that the Wallpaper card takes the room, so the
    /// Preview button never drifts far from the title and no card is mostly empty.
    var screensaverCardMaxWidth: CGFloat {
        cardPadding * 3 + destinationPreviewWidth + readableWidth
    }

    /// The Wallpaper card goes under the Screensaver card in a compact window at the
    /// largest text sizes (side by side, neither would have room for its text).
    var stacksDestinations: Bool { isCompact && prefersStacking }
}

fileprivate extension View {
    /// A destination card's preview: a fixed width, at least 16:10 tall, and free to grow
    /// to a square — so it fills a card made taller by its neighbour (the two cards in a
    /// row share one height) instead of leaving a gap under it.
    func destinationPreviewFrame(width: CGFloat, grows: Bool = true) -> some View {
        let height = (width * 10 / 16).rounded()
        return frame(width: width)
            .frame(minHeight: height, maxHeight: grows ? width : height, alignment: .top)
    }
}

// MARK: - Row

struct DestinationRow: View {
    @Environment(\.layout) private var layout
    let state: GalleryState

    var body: some View {
        let stacked = layout.stacksDestinations
        let hasWallpaper = WallpaperSlot.shared.isAvailable
        // Side by side, both cards as tall as the taller one; the Screensaver card takes
        // the room first (up to its cap) and the Wallpaper card the rest.
        AdaptiveStack(rowAlignment: .top, columnAlignment: .leading, spacing: layout.gridColumnGap,
                      stackWhen: { $0.stacksDestinations }) {
            ScreensaverCard(state: state)
                .frame(maxWidth: stacked || !hasWallpaper ? .infinity : layout.screensaverCardMaxWidth,
                       maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
            if hasWallpaper {
                WallpaperCard(state: state)
                    .frame(minWidth: stacked ? nil : layout.sideCardWidth.lowerBound,
                           maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Screensaver

struct ScreensaverCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    let state: GalleryState

    private var lineup: ScreensaverLineup { state.lineup }
    private var playing: Preset? { state.nowPlaying.flatMap(model.preset) }

    /// The night picker's widest (a long style name truncates, full name in its tooltip).
    /// No token for it: three quarters of the narrowest side card, on the grid.
    private var nightPickerMaxWidth: CGFloat { Space.snap(layout.sideCardWidth.lowerBound * 0.75) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: layout.cardPadding) {
                hero
                column
            }
            .padding(layout.cardPadding)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.setupStatus != .ready {
                SetupStrip(status: model.setupStatus)
                    .padding([.horizontal, .bottom], SetupStrip.inset)
                    .transition(.reveal(reduceMotion: reduceMotion, edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: Radius.card)
        .motion(Motion.smooth, value: lineup)
        .motion(Motion.smooth, value: model.setupStatus)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: layout.itemGap) {
                header
                playlistRow
                if lineup.rotates {
                    rotationControls
                        .transition(.reveal(reduceMotion: reduceMotion))
                }
            }
            // The night row sits at the foot of the card, an even step below the rest.
            Spacer(minLength: layout.itemGap)
            nightRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Live preview

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let p = playing {
                    // Live while the gallery is up front; a still otherwise (no GPU in the background).
                    if model.editingID == nil && activeState != .inactive && !DemoHooks.stillPreviews {
                        MetalPreview(preset: p, source: model.library.source,
                                     location: model.locationTuple, store: model.store, maxFPS: 30)
                            .allowsHitTesting(false)
                    } else {
                        StyleThumb(preset: p)
                    }
                } else {
                    Color.black
                }
            }
            .id(playing?.id)
            .transition(.opacity)

            if lineup.night != nil {
                GlassBadge(text: model.isNightNow ? "Night" : "Day",
                           symbol: model.isNightNow ? "moon.fill" : "sun.max.fill")
                    .padding(Space.xs)
            }
        }
        .destinationPreviewFrame(width: layout.destinationPreviewWidth)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: Radius.tile))
        .onTapGesture(count: 2) { if let p = playing { model.edit(p.id) } }
        .help(playing.map { "\($0.name) — double-click to edit" } ?? "")
        .motion(Motion.smooth, value: playing?.id)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: layout.itemGap) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                // The status moves under the eyebrow rather than breaking either word.
                FlowLayout(spacing: layout.controlGap, lineSpacing: layout.labelGap) {
                    CardEyebrow(text: "Screensaver")
                    StatusDot(status: model.setupStatus)
                }
                let name = playing?.name ?? "Nothing yet"
                Text(name)
                    .textRole(.cardTitle)
                    .truncating(name, lines: 2)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let p = playing {
                    ScreensaverPreviewController.shared.present(
                        preset: p, source: model.library.source, store: model.store)
                }
            } label: {
                Label("Preview", systemImage: "play.fill")
                    .textRole(.body)
            }
            .glassButton()
            .adaptiveControlSize(DestinationAction.size)
            .fixedSize()
            .disabled(playing == nil)
            .help("Full-screen preview of what's playing now — move the mouse or press a key to exit")
        }
    }

    private var subtitle: String {
        let n = lineup.playlist.count
        if n <= 1 { return lineup.night == nil ? "Plays all the time" : "Plays by day" }
        return lineup.night == nil ? "Now playing · one of \(n) styles" : "Now playing · \(n) styles by day"
    }

    // MARK: Playlist

    @ViewBuilder private var playlistRow: some View {
        if lineup.playlist.count <= 1 {
            // One style: the hint sits beside the chip, or under it when there's no room.
            ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.controlGap) {
                PlaylistStack(ids: lineup.playlist, current: state.nowPlaying, lineup: lineup)
                if lineup.playlist.count == 1 {
                    Text("Add styles to rotate between them")
                        .textRole(.caption)
                        .foregroundStyle(.tertiary)
                        .wrapping()
                        .transition(.opacity)
                }
            }
        } else {
            PlaylistStack(ids: lineup.playlist, current: state.nowPlaying, lineup: lineup, fitsWidth: true)
        }
    }

    private var rotationControls: some View {
        let interval = HStack(spacing: layout.controlGap) {
            Text("Change every")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Picker("Interval", selection: Binding(get: { model.rotation.intervalMinutes },
                                                  set: { model.setRotationInterval($0) })) {
                ForEach(intervalOptions, id: \.self) { m in Text(intervalLabel(m)).tag(m) }
            }
            .labelsHidden()
            .fixedSize()
        }
        let shuffle = Toggle(isOn: Binding(get: { model.rotation.shuffle }, set: { model.setShuffle($0) })) {
            Label("Shuffle", systemImage: "shuffle")
        }
        .toggleStyle(.button)
        .fixedSize()
        .help("Play the playlist in a random order")

        // One line when it fits; otherwise Shuffle moves under the interval.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: layout.controlGap) {
                interval
                Text("·").foregroundStyle(.tertiary)
                shuffle
            }
            VStack(alignment: .leading, spacing: layout.controlGap) {
                interval
                shuffle
            }
        }
        .textRole(.callout)
        .adaptiveControlSize(.small)
    }

    private var intervalOptions: [Double] {
        var opts: [Double] = [1, 5, 15, 30, 60]
        let cur = model.rotation.intervalMinutes
        if !opts.contains(cur) { opts.append(cur); opts.sort() }
        return opts
    }

    private func intervalLabel(_ m: Double) -> String {
        if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 {
            return m == 60 ? "hour" : "\(Int(m / 60)) hours"
        }
        if m < 1 { return "\(Int(m * 60)) sec" }
        return m == 1 ? "minute" : "\(Int(m)) min"
    }

    // MARK: Night

    private var nightRow: some View {
        // Switch, picker and caption flow onto a second line in a narrow card.
        FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
            Toggle(isOn: Binding(get: { lineup.night != nil },
                                 set: { on in Motion.run { model.setNightEnabled(on) } })) {
                Label("Different style at night", systemImage: "moon.stars")
                    .textRole(.callout)
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .fixedSize()

            if let nightID = lineup.night, let night = model.preset(nightID) {
                StylePickerMenu(current: night, title: night.name, maxWidth: nightPickerMaxWidth) { model.setNight($0) }
                    .transition(.lift(reduceMotion: reduceMotion))
                Text(model.isNightNow ? "Playing now" : "After sunset")
                    .textRole(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .adaptiveControlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, layout.itemGap)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// The primary actions on both destination cards (Preview; Change / Stop) share a size.
enum DestinationAction {
    static let size: ControlSize = .regular
}

/// "SCREENSAVER", "WALLPAPER": the small caps label that opens each card. Never breaks.
private struct CardEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.eyebrow)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A dot + word for a destination's state (Screensaver: on / not selected / not
/// installed; Wallpaper: live / off). Never wraps.
struct StatusDot: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption) private var diameter: CGFloat = 7
    let color: Color
    let text: String

    init(color: Color, text: String) {
        self.color = color
        self.text = text
    }

    /// The screensaver's install state.
    init(status: Installer.Status) {
        switch status {
        case .ready: self.init(color: .green, text: "On")
        case .notChosen: self.init(color: .orange, text: "Not selected")
        case .notInstalled: self.init(color: .secondary, text: "Not installed")
        }
    }

    var body: some View {
        HStack(spacing: layout.labelGap) {
            Circle().fill(color).frame(width: diameter, height: diameter)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(text)
                .textRole(TextRole.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// Folded-in setup step, at the foot of the Screensaver card until it's on.
struct SetupStrip: View {
    /// Inset from the card's edges; the strip's corners stay concentric with the card's.
    static let inset = Space.xs
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    let status: Installer.Status

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.concentric(Radius.card, inset: Self.inset), style: .continuous)
        // The button sits beside the text while the text keeps a comfortable column
        // (it wraps as needed); in a narrower strip it moves under the text.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: layout.itemGap) {
                message
                    .frame(minWidth: layout.scaled(240), idealWidth: layout.scaled(240),
                           maxWidth: .infinity, alignment: .leading)
                button
            }
            VStack(alignment: .leading, spacing: layout.itemGap) {
                message
                button
            }
        }
        // Its content lines up with the card's own content edge.
        .padding(.horizontal, layout.cardPadding - Self.inset)
        .padding(.vertical, Space.s)
        .background(shape.fill(Color.accentColor.opacity(0.10)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.22)))
    }

    private var message: some View {
        HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: status == .notInstalled ? "arrow.down.circle.fill" : "hand.point.up.left.fill")
                .scaledFont { .scaled(points: 20, $0) }
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(status == .notInstalled ? "Install the screensaver to start playing"
                                             : "One more step: choose DotStudio in System Settings")
                    .textRole(.calloutEmphasis)
                    .wrapping()
                Text(status == .notInstalled
                     ? "It's added to your Mac once — after that, everything is controlled from here."
                     : "Wallpaper ▸ Screen Saver ▸ DotStudio. Repeat for each display you want it on.")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
        }
    }

    private var button: some View {
        Group {
            if status == .notInstalled {
                Button { model.installScreensaver() } label: { Text("Install").textRole(.body) }
            } else {
                Button { Installer.openScreenSaverSettings() } label: { Text("Open Settings").textRole(.body) }
            }
        }
        .glassButton(.prominent)
        .adaptiveControlSize(.large)
        .fixedSize()
    }
}

// MARK: - Playlist stack

/// The playlist as a small deck of thumbnails that fans out on hover, then "+N" and the
/// "+" button. With `fitsWidth`, it takes the row's full width, shows only as many chips as
/// fit, and reserves its fanned-out width up front — so hovering never moves anything
/// around it or spills out of the card.
struct PlaylistStack: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .callout) private var chipWidth: CGFloat = 64
    @ScaledLength(relativeTo: .callout) private var chipHeight: CGFloat = 40
    let ids: [UUID]
    let current: UUID?
    let lineup: ScreensaverLineup
    var fitsWidth = false
    @State private var fanned = false
    @State private var available: CGFloat?

    private let maxShown = 7

    private struct Deck {
        var shown: Int
        var restStep: CGFloat
        var fanStep: CGFloat
        var width: CGFloat
    }

    /// How many chips fit, how far apart they sit resting and fanned, and the deck's width.
    private func deck(in room: CGFloat?) -> Deck {
        let gap = layout.controlGap
        let total = ids.count
        let spread = chipWidth + Space.xs                  // fanned: side by side
        let stacked = (chipWidth * 0.6).rounded()          // resting: overlapped
        let rest = total <= 3 ? spread : stacked
        func width(_ n: Int, _ step: CGFloat) -> CGFloat {
            let chips = n > 0 ? chipWidth + CGFloat(n - 1) * step + gap : 0
            let more = total > n ? plusWidth + gap : 0
            return chips + more + chipHeight                // + the round "+" button
        }
        var n = min(total, maxShown)
        let limit = room ?? .infinity
        while n > 1 && width(n, rest) > limit { n -= 1 }
        var fan = n > 1 && total > 3 ? spread : rest
        if n > 1, width(n, fan) > limit {
            fan = max(rest, ((limit - width(n, 0)) / CGFloat(n - 1)).rounded(.down))
        }
        return Deck(shown: n, restStep: rest, fanStep: fan, width: width(n, max(fan, rest)))
    }

    private var plusWidth: CGFloat { chipHeight + Space.xs }

    var body: some View {
        if fitsWidth {
            // Measure the row (not the deck), so the deck can never push the card wider.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: chipHeight)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
                .overlay(alignment: .leading) { content(deck(in: available)) }
        } else {
            content(deck(in: nil))
        }
    }

    private func content(_ d: Deck) -> some View {
        let shown = Array(ids.prefix(d.shown))
        let step = fanned ? d.fanStep : d.restStep
        return HStack(spacing: layout.controlGap) {
            if !shown.isEmpty {
                HStack(spacing: step - chipWidth) {
                    ForEach(Array(shown.enumerated()), id: \.element) { i, id in
                        if let p = model.preset(id) {
                            PlaylistChip(preset: p, isCurrent: ids.count > 1 && id == current,
                                         canRemove: ids.count > 1, size: CGSize(width: chipWidth, height: chipHeight))
                                .zIndex(Double(shown.count - i))
                                .transition(.lift(reduceMotion: reduceMotion))
                        }
                    }
                }
                .onHover { h in fanned = h }
            }
            if ids.count > d.shown {
                Text("+\(ids.count - d.shown)")
                    .textRole(.captionEmphasis)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: plusWidth, height: chipHeight)
                    .glassSurface(.regular, in: Capsule())
                    .help("\(ids.count - d.shown) more in the playlist")
            }
            AddToPlaylistButton(lineup: lineup, diameter: chipHeight)
        }
        .frame(width: fitsWidth ? d.width : nil, alignment: .leading)
        .motion(Motion.smooth, value: fanned)
        .motion(Motion.smooth, value: ids)
    }
}

private struct PlaylistChip: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    let isCurrent: Bool
    let canRemove: Bool
    let size: CGSize
    @State private var hovering = false

    var body: some View {
        StyleThumb(preset: preset)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(0.55),
                              lineWidth: isCurrent ? 2 : 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if hovering && canRemove {
                    Button { Motion.run { model.removeFromPlaylist(preset.id) } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .scaledFont { .scaled(points: 14, $0) }
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove from Screensaver")
                    .transition(.opacity)
                }
            }
            .scaleEffect(hovering ? 1.06 : 1)
            .onHover { hovering = $0 }
            .motion(Motion.snappy, value: hovering)
            .onTapGesture(count: 2) { model.edit(preset.id) }
            .onTapGesture { model.selectedID = preset.id }
            .help(preset.name)
            .contextMenu {
                Button("Play Only This") { Motion.run { model.playAsScreensaver(preset.id) } }
                Button("Remove from Screensaver") { Motion.run { model.removeFromPlaylist(preset.id) } }
                    .disabled(!canRemove)
                Divider()
                Button("Edit") { model.edit(preset.id) }
            }
    }
}

/// "+" — a popover to tick styles in and out of the playlist. As tall as a playlist chip.
private struct AddToPlaylistButton: View {
    @EnvironmentObject var model: AppModel
    let lineup: ScreensaverLineup
    let diameter: CGFloat
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "plus")
                .scaledFont { .scaled(points: 13, $0, weight: .semibold) }
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
        .glassSurface(.regular, in: Circle(), interactive: true)
        .help("Choose which styles the screensaver plays")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PlaylistEditor()
                .adaptiveLayout()   // the popover is its own root
        }
    }
}

/// Multi-select of every style, grouped Scenes / Looks.
struct PlaylistEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption) private var checkSize: CGFloat = 15
    @State private var query = ""

    var body: some View {
        let lineup = model.screensaverLineup
        let q = query.lowercased()
        let presets = model.library.presets.filter { q.isEmpty || StyleMatcher.searchText(for: $0).contains(q) }
        let width = layout.popoverWidth
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: layout.controlGap) {
                Text("Screensaver Playlist").textRole(.headline).wrapping()
                Text(lineup.rotates ? "\(lineup.playlist.count) styles take turns." : "One style plays. Tick more to rotate.")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
                SearchField(text: $query, prompt: "Filter styles")
            }
            .padding(layout.cardPadding)
            Divider()
            ScrollView {
                LazyVGrid(columns: layout.columns(minimum: 112, spacing: Space.s), alignment: .leading,
                          spacing: layout.itemGap) {
                    ForEach(presets) { p in
                        let on = lineup.playlist.contains(p.id)
                        Button {
                            Motion.run { on ? model.removeFromPlaylist(p.id) : model.addToPlaylist(p.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                StyleThumb(preset: p)
                                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                        .strokeBorder(on ? Color.accentColor : .primary.opacity(0.1), lineWidth: on ? 2.5 : 1))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, on ? Color.accentColor : .black.opacity(0.35))
                                            .font(.system(size: checkSize))
                                            .shadow(radius: 2)
                                            .padding(Space.xxs)
                                    }
                                // Two lines, always reserved, so the grid's rows line up.
                                Text(p.name)
                                    .textRole(.caption)
                                    .foregroundStyle(on ? .primary : .secondary)
                                    .truncating(p.name, lines: 2, reservesSpace: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(on && lineup.playlist.count == 1)
                    }
                }
                .padding(layout.cardPadding)
            }
        }
        // A popover takes its ideal size; in a fixed frame (UI shots) it fits within it.
        .frame(minWidth: width.lowerBound, idealWidth: min(max(layout.scaled(420), width.lowerBound), width.upperBound),
               maxWidth: width.upperBound,
               minHeight: layout.scaled(320), idealHeight: layout.scaled(460), maxHeight: .infinity)
    }
}

/// A compact menu button showing a style's thumbnail + name, listing every style.
struct StylePickerMenu: View {
    @EnvironmentObject var model: AppModel
    @ScaledLength(relativeTo: .callout) private var thumbWidth: CGFloat = 32
    @ScaledLength(relativeTo: .callout) private var thumbHeight: CGFloat = 20
    let current: Preset?
    let title: String
    var size: ControlSize = .small
    /// Caps a long style name: it truncates, with the full name in the tooltip.
    var maxWidth: CGFloat? = nil
    let onPick: (UUID) -> Void

    var body: some View {
        let menu = Menu {
            let scenes = model.library.presets.filter(\.isScene)
            let looks = model.library.presets.filter { !$0.isScene }
            Section("Scenes") { ForEach(scenes) { p in item(p) } }
            Section("Looks") { ForEach(looks) { p in item(p) } }
        } label: {
            HStack(spacing: Space.xs) {
                if let current {
                    StyleThumb(preset: current)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                }
                Text(title)
                    .textRole(size == .small ? .callout : .body)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .menuStyle(.button)
        .glassButton()
        .adaptiveControlSize(size)
        .help(current?.name ?? title)

        if let maxWidth {
            menu.frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            menu.fixedSize()
        }
    }

    @ViewBuilder private func item(_ p: Preset) -> some View {
        Button {
            Motion.run { onPick(p.id) }
        } label: {
            if p.id == current?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }
}

// MARK: - Wallpaper

struct WallpaperCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var slot = WallpaperSlot.shared
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shortest the preview gets when the card lays out top to bottom (it grows to fill).
    @ScaledLength(relativeTo: .body) private var previewMinHeight: CGFloat = 80
    @State private var width: CGFloat = 0
    let state: GalleryState

    private var style: Preset? { slot.styleID.flatMap(model.preset) }

    /// Wide enough to mirror the Screensaver card — preview beside the text — when the
    /// text keeps at least a narrow column's width.
    private var sideBySide: Bool {
        width >= layout.cardPadding * 3 + layout.destinationPreviewWidth + layout.scaled(200)
    }

    var body: some View {
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: layout.cardPadding) {
                    // 16:10, the same size and top as the Screensaver hero beside it.
                    preview
                        .destinationPreviewFrame(width: layout.destinationPreviewWidth, grows: false)
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: layout.itemGap) {
                            eyebrow
                            details
                        }
                        Spacer(minLength: layout.itemGap)
                        actions
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                // The preview grows to fill a card made taller by its neighbour, up to
                // 16:10; past that the actions settle at the foot of the card.
                let previewMax = max(previewMinHeight, ((width - layout.cardPadding * 2) * 10 / 16).rounded())
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: layout.itemGap) {
                        eyebrow
                        preview
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: previewMinHeight, idealHeight: previewMinHeight, maxHeight: previewMax)
                        details
                    }
                    Spacer(minLength: layout.itemGap)
                    actions
                }
            }
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .glassCard(cornerRadius: Radius.card)
        .motion(Motion.smooth, value: slot.styleID)
    }

    private var eyebrow: some View {
        FlowLayout(spacing: layout.controlGap, lineSpacing: layout.labelGap) {
            CardEyebrow(text: "Wallpaper")
            StatusDot(color: style != nil ? .green : .secondary.opacity(0.6), text: style != nil ? "Live" : "Off")
        }
    }

    private var preview: some View {
        ZStack {
            if let style {
                StyleThumb(preset: style)
                    .transition(.opacity)
            } else {
                DesktopGlyph()
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: layout.labelGap) {
            let name = style?.name ?? "Your desktop, alive"
            Text(name)
                .textRole(.cardTitle)
                .truncating(name, lines: 2)
            Text(style != nil ? "Playing behind your windows" : "Play any style behind your windows.")
                .textRole(.callout)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    private var actions: some View {
        FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
            StylePickerMenu(current: style, title: style == nil ? "Choose Style" : "Change",
                            size: DestinationAction.size) { slot.set($0) }
            if style != nil {
                Button { Motion.run { slot.stop() } } label: { Text("Stop").textRole(.body) }
                    .glassButton()
                    .adaptiveControlSize(DestinationAction.size)
                    .fixedSize()
                    .transition(.lift(reduceMotion: reduceMotion))
            }
        }
    }
}

/// A tiny drawn desktop: menu bar, dock, a soft gradient — the "off" state.
private struct DesktopGlyph: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.purple.opacity(0.18), Color.orange.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 7)
                Spacer()
                Capsule().fill(.primary.opacity(0.10)).frame(width: 96, height: 12).padding(.bottom, Space.xs)
            }
            Image(systemName: "sparkles")
                .scaledFont { .scaled(points: 22, $0, weight: .light) }
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared bits

/// A style's cached thumbnail (black until it renders).
struct StyleThumb: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset

    var body: some View {
        // Takes exactly the size it's offered; the image fills it and is clipped, so a
        // thumbnail never pushes its container's layout around.
        Color.black
            .overlay {
                if let img = model.thumbnailer.image(for: preset, source: model.library.source) {
                    Image(nsImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}

/// The gallery's small-control height, shared by the search field and the filter chips so
/// their edges line up. No token for it: 28 at the default text size, grown with
/// `@ScaledLength(relativeTo: .callout)` where it's used.
enum GalleryControl {
    static let height: CGFloat = 28
}

/// Inline glass search field.
struct SearchField: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = GalleryControl.height
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: layout.iconGap) {
            Image(systemName: "magnifyingglass")
                .scaledFont { .scaled(points: 12, $0, weight: .medium) }
                .foregroundStyle(.secondary)
            field
                .textRole(.body)
                .help(text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont { .scaled(.body, $0) }
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, layout.controlGap + Space.xxs)
        .frame(height: height)
        .glassSurface(.regular, in: Capsule())
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
    }
}

extension View {
    /// `glassSurface` with a tint (a selected chip, a state badge). Offscreen UIShots
    /// captures can't draw TINTED Liquid Glass — one tinted shape blanks the whole render —
    /// so there the tint is a plain fill under untinted glass. On screen this is exactly
    /// `glassSurface(_:in:tint:interactive:)`.
    @ViewBuilder
    func tintedGlassSurface<S: Shape>(_ style: GlassStyle = .regular, in shape: S,
                                      tint: Color?, interactive: Bool = false) -> some View {
        if let tint, OffscreenCapture.isActive {
            self.background(shape.fill(tint.opacity(0.85)))
                .glassSurface(style, in: shape, interactive: interactive)
        } else {
            self.glassSurface(style, in: shape, tint: tint, interactive: interactive)
        }
    }
}

/// True while UIShots renders screens offscreen (DOTSTUDIO_UI_SHOTS).
enum OffscreenCapture {
    static let isActive = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil
}

/// The blurred, color-washed backdrop behind the gallery and editor.
struct AmbientBackdrop: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let presetID: UUID?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let p = presetID.flatMap(model.preset),
               let img = model.thumbnailer.image(for: p, source: model.library.source) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.35)
                    .opacity(scheme == .dark ? 0.8 : 0.6)
                    .id(p.id)
                    .transition(.opacity)
            }
            // Keep the top calm under the toolbar and fade the wash out down the page.
            LinearGradient(stops: [
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.05), location: 0),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.45 : 0.5), location: 0.45),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: presetID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
