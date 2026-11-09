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

// MARK: - Row geometry

/// How the two destination cards share the row, worked out from the row's MEASURED width
/// (not the width class alone), so the Screensaver card's text column never gets crushed
/// beside the Wallpaper card, and nothing jumps when the window crosses a class boundary.
///
///   • stacked — the Wallpaper card goes under the Screensaver card: side by side, the
///     Screensaver text column would be narrower than `textMin` even with the smallest hero.
///   • side    — Screensaver card (preview beside text) + a narrow Wallpaper card (preview
///     on top, as tall as the hero, its top level with the hero's).
///   • mirror  — both cards lay out preview beside text, with the same preview size; the
///     text columns split evenly once both are roomy, and the Wallpaper actions line up
///     with the Screensaver night row.
///   • single  — no live wallpaper on this Mac: the Screensaver card alone.
///
/// Both previews are always 16:10 and the same size, in every arrangement.
struct DestinationGeometry: Equatable {
    enum Arrangement { case single, stacked, side, mirror }

    var arrangement: Arrangement
    /// The Screensaver hero's width, and the Wallpaper preview's when it sits beside its text.
    var previewWidth: CGFloat
    /// The Screensaver card's width when the cards sit side by side; nil fills the row.
    var screensaverWidth: CGFloat?

    /// Both previews are 16:10.
    var previewHeight: CGFloat { (previewWidth * 10 / 16).rounded() }
    /// The Wallpaper card puts its preview beside its text (not on top).
    var wallpaperPreviewBeside: Bool { arrangement != .side }

    init(width measured: CGFloat?, layout: LayoutMetrics, hasWallpaper: Bool) {
        let p = layout.cardPadding
        let g = layout.gridColumnGap
        let range = layout.heroWidth
        let lo = range.lowerBound
        // No tokens for these text-column widths; they're on the grid and grow with the text.
        let textMin = layout.scaled(300)    // Screensaver: header + Preview, deck, rotation, night
        let textCap = layout.scaled(440)    // room for the night row on one line
        let wallpaperTextMin = layout.scaled(200)
        let wallpaperTextComfort = layout.scaled(240)
        let largeText = layout.typeSize >= .xxLarge
        // Before the first measurement: a typical row for the class.
        let w = measured ?? layout.widthClass.pick(840, 1036, 1760)

        /// The hero for a card `card` wide: 40% of its content, inside `heroWidth`, never
        /// squeezing the text column below `minText` (the hero shrinks first). The small end
        /// at large text sizes, where the text needs the room.
        func hero(card: CGFloat, minText: CGFloat) -> CGFloat {
            if largeText { return lo }
            let ideal = Space.snap((card - 3 * p) * 0.4)
            let room = ((card - 3 * p - minText) / 4).rounded(.down) * 4
            return max(lo, min(range.upperBound, ideal, room))
        }

        guard hasWallpaper else {
            self.init(arrangement: .single, previewWidth: hero(card: w, minText: textMin), screensaverWidth: nil)
            return
        }
        let sideRoom = w - g - layout.sideCardWidth.lowerBound
        if sideRoom - 3 * p - lo < textMin {
            self.init(arrangement: .stacked, previewWidth: hero(card: w, minText: textMin), screensaverWidth: nil)
        } else if w - g - 6 * p - 2 * lo >= textMin + wallpaperTextMin {
            let fit = ((w - g - 6 * p - textMin - wallpaperTextMin) / 8).rounded(.down) * 4
            let h = max(lo, min(hero(card: (w - g) / 2, minText: 0), fit))
            // The text columns split evenly once both are roomy; until then the Screensaver
            // column (more to hold) fills up to its cap first, the Wallpaper keeping enough
            // for its name.
            let text = w - g - 6 * p - 2 * h
            let preferred = max(text / 2, min(textCap, text - wallpaperTextComfort))
            let screensaverText = min(max(textMin, preferred), text - wallpaperTextMin)
            self.init(arrangement: .mirror, previewWidth: h,
                      screensaverWidth: (3 * p + h + screensaverText).rounded(.down))
        } else {
            let h = hero(card: sideRoom, minText: textMin)
            self.init(arrangement: .side, previewWidth: h,
                      screensaverWidth: min(sideRoom, 3 * p + h + textCap))
        }
    }

    private init(arrangement: Arrangement, previewWidth: CGFloat, screensaverWidth: CGFloat?) {
        self.arrangement = arrangement
        self.previewWidth = previewWidth
        self.screensaverWidth = screensaverWidth
    }
}

// MARK: - Row

struct DestinationRow: View {
    @Environment(\.layout) private var layout
    let state: GalleryState
    @State private var width: CGFloat?
    /// Height of the Screensaver card's preview + text block, so a mirrored Wallpaper card
    /// can end its own block (and its actions) level with it.
    @State private var screensaverBlock: CGFloat = 0

    var body: some View {
        let hasWallpaper = WallpaperSlot.shared.isAvailable
        let geometry = DestinationGeometry(width: width, layout: layout, hasWallpaper: hasWallpaper)
        let stacked = geometry.arrangement == .stacked
        // Children keep their identity (and state) when the arrangement changes.
        let arrangement = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: layout.gridColumnGap))
            : AnyLayout(HStackLayout(alignment: .top, spacing: layout.gridColumnGap))
        arrangement {
            // Side by side, both cards are as tall as the taller one.
            ScreensaverCard(state: state, geometry: geometry) { screensaverBlock = $0 }
                .frame(width: geometry.screensaverWidth)
                .frame(maxWidth: geometry.screensaverWidth == nil ? .infinity : nil,
                       maxHeight: .infinity, alignment: .top)
            if hasWallpaper {
                WallpaperCard(state: state, geometry: geometry,
                              alignHeight: geometry.arrangement == .mirror ? screensaverBlock : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Screensaver

struct ScreensaverCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @ObservedObject private var now = MusicNow.shared
    @ScaledLength(relativeTo: .callout) private var musicArt: CGFloat = 22
    let state: GalleryState
    let geometry: DestinationGeometry
    /// Reports the preview + text block's height (see DestinationRow).
    var onBlockHeight: (CGFloat) -> Void = { _ in }

    private var lineup: ScreensaverLineup { state.lineup }
    private var playing: Preset? { state.nowPlaying.flatMap(model.preset) }
    /// The music card's settings while it's on (the hero shows it, as the screensaver would).
    private var musicCard: MusicSpec? {
        let m = model.library.musicSettings
        return m.isCardEnabled ? m : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The block keeps its own height (at least the hero's); if the Wallpaper card
            // beside it is taller, the extra room falls below the card's content.
            HStack(alignment: .top, spacing: layout.cardPadding) {
                hero
                column
                    .frame(maxWidth: .infinity, minHeight: geometry.previewHeight, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onBlockHeight($0) }
            .padding(layout.cardPadding)

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
            // The option rows end level with the hero's foot (or an even step below the
            // rest, when the text runs longer than the hero).
            Spacer(minLength: layout.itemGap)
            VStack(alignment: .leading, spacing: layout.itemGap) {
                nightRow
                musicRow
            }
        }
    }

    // MARK: Live preview

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let p = playing {
                    // Live while the gallery is up front; a still otherwise (no GPU in the background).
                    if model.editingID == nil && activeState != .inactive && !DemoHooks.stillPreviews {
                        MetalPreview(preset: p, source: model.library.source,
                                     location: model.locationTuple, store: model.store, maxFPS: 30,
                                     musicCard: musicCard)
                            .allowsHitTesting(false)
                    } else {
                        StyleThumb(preset: p, musicCard: musicCard)
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
        .frame(width: geometry.previewWidth, height: geometry.previewHeight)
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
        // Preview sits on the title's line, right beside what it previews.
        DestinationHeader(eyebrow: "Screensaver", status: StatusDot(status: model.setupStatus),
                          title: playing?.name ?? "Nothing yet", subtitle: subtitle) {
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
        // A no-break space before the dot: a wrapped line never starts with "·".
        return lineup.night == nil ? "Now playing\u{00A0}· one of \(n) styles" : "Now playing\u{00A0}· \(n) styles by day"
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
        // A Menu and a button-style toggle drawn in SwiftUI (not the AppKit pop-up and
        // push-on/push-off button), so their labels follow the text size like the rest of
        // the row.
        let current = model.rotation.intervalMinutes
        let interval = HStack(spacing: layout.controlGap) {
            Text("Change every")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Menu {
                ForEach(intervalOptions, id: \.self) { m in
                    Button { model.setRotationInterval(m) } label: {
                        if m == current { Label(intervalLabel(m), systemImage: "checkmark") } else { Text(intervalLabel(m)) }
                    }
                }
            } label: {
                Text(intervalLabel(current)).textRole(.callout)
            }
            .menuStyle(.button)
            .glassButton()
            .fixedSize()
            .accessibilityLabel("Change every")
            .accessibilityValue(intervalLabel(current))
        }
        let shuffle = Toggle(isOn: Binding(get: { model.rotation.shuffle }, set: { model.setShuffle($0) })) {
            Label("Shuffle", systemImage: "shuffle").textRole(.callout)
        }
        .toggleStyle(GlassToggleButtonStyle())
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
        // The picker and its caption move to a second line together in a narrow card; the
        // picker takes the whole line before a long name truncates (full name in its tooltip).
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
                HStack(spacing: layout.controlGap) {
                    StylePickerMenu(current: night, title: night.name, maxWidth: .infinity) { model.setNight($0) }
                    Text(model.isNightNow ? "Playing now" : "After sunset")
                        .textRole(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .transition(.lift(reduceMotion: reduceMotion))
            }
        }
        .adaptiveControlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, layout.itemGap)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Music

    /// "Show what's playing" (the corner card, Settings › Music has the rest) and, while a
    /// song shows, what it is with Play/Pause and Next — the same row style as the night row.
    private var musicRow: some View {
        let spec = model.library.musicSettings
        let visible = now.isVisible(spec)
        return FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
            Toggle(isOn: Binding(get: { spec.isCardEnabled },
                                 set: { on in Motion.run { model.setMusicCard(on) } })) {
                Label("Show what's playing", systemImage: "music.note")
                    .textRole(.callout)
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .fixedSize()
            .help("A card with the song, artist and progress in a corner of the screensaver while Spotify or Music plays")

            if visible {
                nowPlayingLine
                    .transition(.lift(reduceMotion: reduceMotion))
            }
        }
        .adaptiveControlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, layout.itemGap)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
        .motion(Motion.smooth, value: visible)
    }

    /// Cover · "Song — Artist" · Play/Pause · Next. The song truncates before the controls do.
    private var nowPlayingLine: some View {
        HStack(spacing: layout.controlGap) {
            MusicArtThumb(image: now.artwork, palette: now.state.palette ?? [], side: musicArt)
            (Text(now.title).fontWeight(.medium)
                + Text(now.artist.isEmpty ? "" : " \u{2014} \(now.artist)").foregroundColor(.secondary))
                .textRole(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(now.trackLine)
            MusicTransport(now: now, showsPrevious: false)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(now.trackLine)")
    }
}

extension AppModel {
    /// The music corner card on / off (Library.music.cardEnabled).
    func setMusicCard(_ on: Bool) {
        var m = library.musicSettings
        guard m.isCardEnabled != on else { return }
        m.cardEnabled = on
        library.music = m
        save()
    }
}

/// The primary actions on both destination cards (Preview; Change / Stop) share a size.
enum DestinationAction {
    static let size: ControlSize = .regular
}

/// The top of both destination cards — eyebrow + status, title, subtitle — with one
/// structure and one set of gaps, so the two cards' titles and subtitles line up when they
/// sit side by side. `accessory` (the Screensaver's Preview) sits on the title's line.
private struct DestinationHeader<Accessory: View>: View {
    @Environment(\.layout) private var layout
    let eyebrow: String
    let status: StatusDot
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: layout.labelGap) {
            // The status moves under the eyebrow rather than breaking either word.
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.labelGap) {
                CardEyebrow(text: eyebrow)
                status
            }
            HStack(alignment: .top, spacing: layout.itemGap) {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(title)
                        .textRole(.cardTitle)
                        .truncating(title, lines: 2)
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .textRole(.callout)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
        }
    }
}

extension DestinationHeader where Accessory == EmptyView {
    init(eyebrow: String, status: StatusDot, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, status: status, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A toggle drawn as a glass button — tinted while on — whose label is SwiftUI text, so it
/// follows the text size (the stock `.button` toggle style is an AppKit button whose title
/// never scales on macOS).
struct GlassToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .glassButton(configuration.isOn ? .prominent : .normal)
            .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
    }
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

    /// The `n` chips on show, in playlist order. When only some fit, the window slides so
    /// it always holds the style playing now (the one with the accent ring).
    private func shownIDs(_ n: Int) -> [UUID] {
        guard n < ids.count, let current, let i = ids.firstIndex(of: current), i >= n else {
            return Array(ids.prefix(n))
        }
        let start = min(i, ids.count - n)
        return Array(ids[start ..< start + n])
    }

    private func content(_ d: Deck) -> some View {
        let shown = shownIDs(d.shown)
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
            // Title and caption close together; the field an item step below them.
            VStack(alignment: .leading, spacing: layout.itemGap) {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text("Screensaver Playlist").textRole(.headline).wrapping()
                    Text(lineup.rotates ? "\(lineup.playlist.count) styles take turns." : "One style plays. Tick more to rotate.")
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
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
    let state: GalleryState
    let geometry: DestinationGeometry
    /// Side by side in the mirror arrangement: the Screensaver card's block height, so this
    /// card's actions end level with its night row.
    var alignHeight: CGFloat = 0
    /// "Match Screensaver" lives on the controller (wallpaper.json); the slot only knows styles.
    @ObservedObject private var controller = WallpaperController.shared

    private var style: Preset? { slot.styleID.flatMap(model.preset) }
    /// Live and showing whatever the screensaver shows (WallpaperController.setFollowsScreensaver).
    private var matching: Bool { controller.followsScreensaver && style != nil }

    var body: some View {
        // Content keeps its own height; if the Screensaver card beside it is taller (the
        // setup strip), the extra room falls below rather than pulling the actions down.
        Group {
            if geometry.wallpaperPreviewBeside {
                // Mirrors the Screensaver card: a preview the hero's size, the same header.
                HStack(alignment: .top, spacing: layout.cardPadding) {
                    preview
                        .frame(width: geometry.previewWidth, height: geometry.previewHeight)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Spacer(minLength: layout.itemGap)
                        VStack(alignment: .leading, spacing: layout.itemGap) {
                            actions
                            matchRow
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: max(geometry.previewHeight, alignHeight),
                           alignment: .topLeading)
                }
            } else {
                // A narrow card beside the Screensaver card: the preview on top, as tall as
                // the hero and level with it.
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.previewHeight)
                    header
                    actions
                    matchRow
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(cornerRadius: Radius.card)
        .motion(Motion.smooth, value: slot.styleID)
        .motion(Motion.smooth, value: matching)
    }

    private var header: some View {
        DestinationHeader(eyebrow: "Wallpaper",
                          status: StatusDot(color: style != nil ? .green : .secondary.opacity(0.6),
                                            text: style != nil ? "Live" : "Off"),
                          title: style?.name ?? "Your desktop, alive",
                          subtitle: style != nil ? "Playing behind your windows" : "Play any style behind your windows.")
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

    private var actions: some View {
        FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap) {
            if matching {
                // No style of its own to pick while it follows the screensaver.
                Label("Matches your screensaver", systemImage: "play.rectangle.on.rectangle")
                    .textRole(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            } else {
                StylePickerMenu(current: style, title: style == nil ? "Choose Style" : "Change",
                                size: DestinationAction.size) { slot.set($0) }
            }
            if style != nil {
                Button { Motion.run { slot.stop() } } label: { Text("Stop").textRole(.body) }
                    .glassButton()
                    .adaptiveControlSize(DestinationAction.size)
                    .fixedSize()
                    .transition(.lift(reduceMotion: reduceMotion))
            }
        }
    }

    /// "Match Screensaver": the desktop plays what the screensaver would, in step (same
    /// playlist slot, night style and music take-over, on a shared clock), so the screensaver
    /// starts exactly where the desktop was. Turning it on starts the wallpaper. Same row
    /// style as the Screensaver card's options.
    private var matchRow: some View {
        Toggle(isOn: Binding(get: { matching },
                             set: { on in Motion.run { controller.setFollowsScreensaver(on) } })) {
            Label("Match Screensaver", systemImage: "link")
                .textRole(.callout)
                .lineLimit(1)
        }
        .toggleStyle(.switch)
        .fixedSize()
        .help("Play whatever the screensaver shows — same playlist, night style and music — so the screensaver picks up right where your desktop was")
        .adaptiveControlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, layout.itemGap)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
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
    /// The music card's settings: drawn on the still while a song shows (the Screensaver
    /// card's hero when it can't be live). nil = the plain thumbnail.
    var musicCard: MusicSpec? = nil

    var body: some View {
        // Takes exactly the size it's offered; the image fills it and is clipped, so a
        // thumbnail never pushes its container's layout around.
        Color.black
            .overlay {
                if let img = model.thumbnailer.image(for: preset, source: model.library.source, musicCard: musicCard) {
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
