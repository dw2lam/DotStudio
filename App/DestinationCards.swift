//  DestinationCards.swift — the two glass cards at the top of the gallery that say
//  where styles play: the Screensaver (a playlist + optional night style, plus setup)
//  and the live Wallpaper. See Destinations.swift for how they map onto library.json.

import SwiftUI
import Combine

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

/// How the two destination cards share the row, worked out from the row's MEASURED width:
///
///   • side by side — two cards of EQUAL width (the common case), mirrored so their
///                    thumbnails meet in the middle at the SYNC key, like the two zones
///                    of a car's dual-zone climate panel;
///   • stacked      — one above the other, full width: two cards wouldn't fit side by side
///                    (a narrow window at large text sizes);
///   • single       — no live wallpaper on this Mac: the Screensaver card alone.
///
/// Each card is a big thumbnail that fills the card's height, and a column of options
/// beside it. Both cards share one structure (DestinationCardLayout) and one thumbnail
/// size, so neither reads heavier or emptier. The column keeps a comfortable width (never
/// squeezed below its minimum); the thumbnail takes the rest, up to a cap per width class.
struct DestinationGeometry: Equatable {
    var sideBySide: Bool
    var thumbWidth: CGFloat
    /// Between the two cards: room for the SYNC key on the seam, with a margin each side.
    var gap: CGFloat
    /// The subtitle folds away in a compact side-by-side card (the column is short).
    var showsSubtitle: Bool

    var thumbHeight: CGFloat { (thumbWidth * 10 / 16).rounded() }

    init(width measured: CGFloat?, layout: LayoutMetrics, hasWallpaper: Bool, keySize: CGSize = .zero) {
        let p = layout.cardPadding
        // No tokens for the column's range; on the grid, grown with the text.
        let colMin = layout.scaled(layout.widthClass.pick(176, 232, 272))
        let colMax = layout.scaled(layout.widthClass.pick(240, 300, 360))
        let thumbMin = layout.widthClass.pick(CGFloat(140), 176, 220)
        // Before the first measurement: a typical row for the class.
        let w = measured ?? layout.widthClass.pick(840, 1036, 1824)

        /// The thumbnail's width in a `card`: what the column leaves, on the 4-pt grid.
        func thumb(card: CGFloat, cap: CGFloat) -> CGFloat {
            let col = min(max((card * 0.42).rounded(), colMin), colMax)
            return min(cap, ((card - 3 * p - col) / 4).rounded(.down) * 4)
        }
        /// The gap: the grid's, or wider so the key keeps `Space.xs` from both cards' content.
        func gap(key: CGFloat) -> CGFloat {
            let room = key > 0 ? key + 2 * Space.xs - 2 * p : 0
            return max(layout.gridColumnGap, (room / 2).rounded(.up) * 2)
        }

        if hasWallpaper && !layout.prefersStacking {
            let g = gap(key: keySize.width)
            let card = ((w - g) / 2).rounded(.down)
            let t = thumb(card: card, cap: layout.widthClass.pick(280, 420, 560))
            if t >= thumbMin {
                self.init(sideBySide: true, thumbWidth: t, gap: g, showsSubtitle: !layout.isCompact)
                return
            }
        }
        self.init(sideBySide: false,
                  thumbWidth: max(layout.cardPreviewWidth.lowerBound,
                                  thumb(card: w, cap: layout.widthClass.pick(240, 320, 400))),
                  gap: gap(key: hasWallpaper ? keySize.height : 0), showsSubtitle: true)
    }

    private init(sideBySide: Bool, thumbWidth: CGFloat, gap: CGFloat, showsSubtitle: Bool) {
        self.sideBySide = sideBySide
        self.thumbWidth = thumbWidth
        self.gap = gap
        self.showsSubtitle = showsSubtitle
    }
}

// MARK: - Row

/// Shots-only: renders the sync morph frozen at a progress (0 split … 1 merged).
enum SyncMorphHook {
    static var progress: CGFloat?
}

/// The two cards as one dual-zone climate panel: Screensaver = the driver's zone, Wallpaper
/// = the passenger's. The SYNC key sits on the seam between them. Pressing it, the two glass
/// surfaces close the gap and fuse into one panel (inner corners square off, the seam fades
/// to a hairline), and the passenger's readout catches up with the driver's — its thumbnail
/// crossfades to the screensaver's style and its title rolls to that style's name. Pressing
/// it again (or picking a wallpaper style) splits them back apart.
///
/// The whole morph is ONE value, `progress` (0 split … 1 synced), animated with one spring
/// (Motion.sync): the surface (DualZoneSurface), the seam, the key's LED and the passenger's
/// readout (RollingReadout) all read it. Content never moves — only the surfaces grow
/// together — so nothing reflows mid-morph. Under Reduce Motion the surface switches at the
/// midpoint and everything else crossfades.
struct DestinationRow: View {
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var slot = WallpaperSlot.shared
    /// "Same as Screensaver" lives on the controller (wallpaper.json); the slot only knows styles.
    @ObservedObject private var controller = WallpaperController.shared
    let state: GalleryState
    @State private var width: CGFloat?
    /// The first card's extent along the row (its width side by side, its height stacked).
    @State private var firstExtent: CGFloat?
    @State private var keySize: CGSize = .zero

    private var synced: Bool { controller.followsScreensaver && slot.styleID != nil }

    var body: some View {
        let _ = Perf.body("DestinationRow")
        let hasWallpaper = slot.isAvailable
        let geometry = DestinationGeometry(width: width, layout: layout, hasWallpaper: hasWallpaper, keySize: keySize)
        let progress = SyncMorphHook.progress ?? (synced ? 1 : 0)
        let side = geometry.sideBySide
        // Children keep their identity (and state) when the arrangement changes.
        let arrangement = side
            ? AnyLayout(HStackLayout(alignment: .top, spacing: geometry.gap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: geometry.gap))
        arrangement {
            // Side by side, both cards are as tall as the taller one and equally wide: both
            // are fully flexible, so the stack splits the row evenly. (Never fixed widths from
            // the measurement: a too-wide first guess would widen the page and then measure
            // itself.)
            ScreensaverCard(state: state, geometry: geometry, mirrored: hasWallpaper && side,
                            drawsSurface: !hasWallpaper)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { side ? $0.size.width : $0.size.height } action: { firstExtent = $0 }
            if hasWallpaper {
                WallpaperCard(state: state, geometry: geometry, progress: progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DualZoneSurface(enabled: hasWallpaper, vertical: !side, first: firstExtent,
                                  gap: geometry.gap, progress: progress, snaps: reduceMotion))
        .overlay {
            if hasWallpaper {
                GeometryReader { proxy in seam(in: proxy.size, geometry: geometry, progress: progress) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(Motion.pick(Motion.sync, reduceMotion: reduceMotion), value: synced)
    }

    /// The SYNC key on the seam, and the hairline the seam fades to when the zones merge.
    /// Side by side the key is centred on the seam; stacked, it sits over the thumbnails'
    /// column so the two thumbnails meet at it.
    @ViewBuilder
    private func seam(in size: CGSize, geometry: DestinationGeometry, progress: CGFloat) -> some View {
        let side = geometry.sideBySide
        let along = (firstExtent ?? ((side ? size.width : size.height) - geometry.gap) / 2) + geometry.gap / 2
        let center = side ? CGPoint(x: along, y: size.height / 2)
                          : CGPoint(x: layout.cardPadding + geometry.thumbWidth / 2, y: along)
        let inset = layout.cardPadding
        let clearance = (side ? keySize.height : keySize.width) / 2 + Space.xs
        ZStack(alignment: .topLeading) {
            SeamHairline(vertical: side, center: center, length: side ? size.height : size.width,
                         inset: inset, clearance: clearance)
                .opacity(progress)
            SyncKey(level: progress, isOn: synced) { toggleSync() }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { keySize = $0 }
                .position(center)
        }
    }

    private func toggleSync() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        let on = !synced
        Motion.run(Motion.sync) { controller.setFollowsScreensaver(on) }
    }
}

/// A 1-pt line along the seam with a break around the key, inset from the panel's edges.
private struct SeamHairline: View {
    let vertical: Bool
    let center: CGPoint
    let length: CGFloat
    let inset: CGFloat
    let clearance: CGFloat

    var body: some View {
        let mid = vertical ? center.y : center.x
        let a = max(0, mid - clearance - inset)
        let b = max(0, length - inset - (mid + clearance))
        let line = Color.primary.opacity(0.12)
        ZStack(alignment: .topLeading) {
            if vertical {
                line.frame(width: 1, height: a).offset(x: center.x - 0.5, y: inset)
                line.frame(width: 1, height: b).offset(x: center.x - 0.5, y: mid + clearance)
            } else {
                line.frame(width: a, height: 1).offset(x: inset, y: center.y - 0.5)
                line.frame(width: b, height: 1).offset(x: mid + clearance, y: center.y - 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The two zones' glass, drawn as one animatable shape (Animatable: its body runs every
/// frame with the spring's current progress, so the glass itself morphs). Off when there's
/// no wallpaper zone (the Screensaver card draws its own surface).
private struct DualZoneSurface: ViewModifier, Animatable {
    let enabled: Bool
    let vertical: Bool
    let first: CGFloat?
    let gap: CGFloat
    var progress: CGFloat
    let snaps: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if enabled {
            content.panelSurface(in: DualZoneShape(vertical: vertical, first: first, gap: gap,
                                                   radius: Radius.card, progress: progress, snaps: snaps))
        } else {
            content
        }
    }
}

/// Two cards → one panel. At 0: two rounded rectangles `gap` apart. The gap closes over the
/// first 80% of the move while the inner corners square off over all of it; at 1 it's one
/// rounded rectangle.
struct DualZoneShape: Shape {
    var vertical: Bool
    /// The first zone's extent along the row (nil: half of it).
    var first: CGFloat?
    var gap: CGFloat
    var radius: CGFloat
    var progress: CGFloat
    var snaps = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// The outline depends only on the rect and these values; the glass asks for it far more
    /// often than they change (every frame the panel moves on screen — every frame of a
    /// scroll), so it's built once per change (PathCache) and handed back after that.
    func path(in rect: CGRect) -> Path {
        Perf.count("DualZoneShape.path")
        let key = PathCache.Key(rect: rect, vertical: vertical, first: first ?? -1, gap: gap, radius: radius,
                                progress: progress, snaps: snaps)
        return Self.cache.path(for: key) { build(in: rect) }
    }

    private static let cache = PathCache()

    private func build(in rect: CGRect) -> Path {
        Perf.count("DualZoneShape.build")
        var q = min(max(progress, 0), 1)
        if snaps { q = q >= 0.5 ? 1 : 0 }
        let whole = RoundedRectangle(cornerRadius: radius, style: .continuous)
        guard q < 0.999 else { return whole.path(in: rect) }
        let extent = vertical ? rect.height : rect.width
        let firstLen = min(first ?? (extent - gap) / 2, extent)
        let close = min(1, q / 0.8)
        let inner = radius * (1 - q)
        // Each zone reaches half the gap toward the other (and overlaps by a hair once
        // closed, so the union is one outline).
        let reach = gap / 2 * close + (close >= 1 ? 0.5 : 0)
        let a, b: CGRect
        let ra, rb: RectangleCornerRadii
        if vertical {
            a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLen + reach)
            let start = rect.minY + firstLen + gap - reach
            b = CGRect(x: rect.minX, y: start, width: rect.width, height: rect.maxY - start)
            ra = RectangleCornerRadii(topLeading: radius, bottomLeading: inner, bottomTrailing: inner, topTrailing: radius)
            rb = RectangleCornerRadii(topLeading: inner, bottomLeading: radius, bottomTrailing: radius, topTrailing: inner)
        } else {
            a = CGRect(x: rect.minX, y: rect.minY, width: firstLen + reach, height: rect.height)
            let start = rect.minX + firstLen + gap - reach
            b = CGRect(x: start, y: rect.minY, width: rect.maxX - start, height: rect.height)
            ra = RectangleCornerRadii(topLeading: radius, bottomLeading: radius, bottomTrailing: inner, topTrailing: inner)
            rb = RectangleCornerRadii(topLeading: inner, bottomLeading: inner, bottomTrailing: radius, topTrailing: radius)
        }
        let pa = UnevenRoundedRectangle(cornerRadii: ra, style: .continuous).path(in: a)
        let pb = UnevenRoundedRectangle(cornerRadii: rb, style: .continuous).path(in: b)
        if close >= 1 { return pa.union(pb) }
        var both = pa
        both.addPath(pb)
        return both
    }
}

/// The last few outlines a DualZoneShape built (a resting panel needs one; a morph or a
/// resize walks through new ones and the oldest drop off). Any thread.
private final class PathCache: @unchecked Sendable {
    struct Key: Equatable {
        var rect: CGRect
        var vertical: Bool
        var first: CGFloat
        var gap: CGFloat
        var radius: CGFloat
        var progress: CGFloat
        var snaps: Bool
    }

    private var entries: [(key: Key, path: Path)] = []
    private let lock = NSLock()
    private static let capacity = 4

    func path(for key: Key, build: () -> Path) -> Path {
        lock.lock()
        if let hit = entries.first(where: { $0.key == key }) { lock.unlock(); return hit.path }
        lock.unlock()
        let p = build()
        lock.lock()
        entries.append((key, p))
        if entries.count > Self.capacity { entries.removeFirst() }
        lock.unlock()
        return p
    }
}

// MARK: - SYNC key

/// The climate-panel SYNC key: a small rounded key with an LED bar over the word "SYNC".
/// `level` lights the LED (0 dark … 1 lit) — it's the morph's progress, so the light comes
/// up with the merge. Same wording as the menu bar, editor and Settings for VoiceOver.
struct SyncKey: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .caption2) private var ledWidth: CGFloat = 16
    @ScaledLength(relativeTo: .caption2) private var ledHeight: CGFloat = 3
    let level: CGFloat
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs + 1) {
                PanelLED(level: level)
                    .frame(width: ledWidth, height: ledHeight)
                Text("Sync")
                    .textRole(.keycap)
                    .foregroundStyle(Color.primary.opacity(0.62 + 0.38 * level))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, layout.controlGap + Space.xxs)
            .padding(.vertical, layout.controlGap)
        }
        .buttonStyle(PanelKeyStyle(radius: Radius.m, floating: true))
        .fixedSize()
        .help("Same as Screensaver — play whatever the screensaver shows, same playlist and night style, so it picks up right where your desktop was. Picking a wallpaper style turns this off.")
        .accessibilityLabel("Same as Screensaver")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

// MARK: - Card structure

/// The one structure both destination cards share:
///
///     ┌───────────────────────────────────────────┐
///     │ ┌──────────────────┐  EYEBROW              │
///     │ │                  │  Title                │
///     │ │    thumbnail     │  Subtitle             │
///     │ │  fills the card  │                       │
///     │ │      height      │  [key ············ ]  │     with an aside (the
///     │ │                  │  [key ············ ]  │  ←  Wallpaper's Play /
///     │ └▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒┘  [key ············ ]  │     Pause / Off keys):
///     │ banner (setup strip), full width           │                    [▶]
///     └───────────────────────────────────────────┘                    [‖]
///                                                        [key ········] [⏻]
///
/// The column's header sits at the top and its keys at the bottom, level with the
/// thumbnail's edges; an optional `aside` (a column of icon keys) stands beside the keys
/// at the column's trailing edge, its foot level with the last key. `mirrored` puts the thumbnail on the
/// trailing side (the Screensaver card side by side, so both thumbnails meet at the SYNC
/// key). ▒ is the thumbnail's glow (DestinationGlow, which each card lays over its picture,
/// under the picture's badges): a soft green light rising from its bottom edge while that
/// destination plays, dimmer while it holds a frame, none while it's off — the only on/off
/// readout the card shows. The card hands VoiceOver the same state, in words, as its
/// value (`stateValue`).
private struct DestinationCardLayout<Preview: View, Keys: View, Aside: View, Banner: View>: View {
    @Environment(\.layout) private var layout
    let geometry: DestinationGeometry
    let header: DestinationHeader
    var mirrored = false
    var drawsSurface = true
    /// "On", "Paused", "Off"…: what the glow shows, in words.
    let stateValue: String
    @ViewBuilder var preview: Preview
    @ViewBuilder var keys: Keys
    @ViewBuilder var aside: Aside
    @ViewBuilder var banner: Banner

    var body: some View {
        let _ = Perf.body("DestinationCardLayout")
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: layout.cardPadding) {
                if mirrored {
                    column
                    thumbnail
                } else {
                    thumbnail
                    column
                }
            }
            banner
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(OwnSurface(enabled: drawsSurface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header.eyebrow)
        .accessibilityValue(stateValue)
    }

    private var thumbnail: some View {
        preview
            .frame(width: geometry.thumbWidth)
            .frame(minHeight: geometry.thumbHeight, idealHeight: geometry.thumbHeight, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(.primary.opacity(0.12)))
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: layout.itemGap)
            // The aside stands beside the keys, never the header: the header keeps the
            // column's full width, and a card with an aside of three keys is as tall as
            // one with three rows of keys (the two cards stay even, stacked too).
            HStack(alignment: .bottom, spacing: PanelKey.gap(layout)) {
                VStack(alignment: .leading, spacing: PanelKey.gap(layout)) {
                    keys
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                aside
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct OwnSurface: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.panelSurface(in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            } else {
                content
            }
        }
    }
}

// MARK: - Screensaver

struct ScreensaverCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    let state: GalleryState
    let geometry: DestinationGeometry
    var mirrored = false
    var drawsSurface = true
    @State private var editingPlaylist = false
    /// A song is showing (playing, or paused within the linger). The card follows only this
    /// from MusicNow — the track itself is NowPlayingKey's — so a song change re-renders the
    /// one key that shows it, not the card.
    @State private var songVisible = MusicNow.shared.state.isVisible(lingerMinutes: MusicNow.shared.lingerMinutes)

    private var lineup: ScreensaverLineup { state.lineup }
    private var playing: Preset? { state.nowPlaying.flatMap(model.preset) }

    var body: some View {
        let _ = Perf.body("ScreensaverCard")
        let spec = model.library.musicSettings
        // The song only while music shows: Off shows nothing on screen, so neither does this.
        let showsSong = spec.displayMode != .off && songVisible
        DestinationCardLayout(geometry: geometry, header: header, mirrored: mirrored, drawsSurface: drawsSurface,
                              stateValue: stateValue) {
            hero
        } keys: {
            playlistKey
            nightKey
            musicKey
            if showsSong {
                NowPlayingKey()
                    .transition(.lift(reduceMotion: reduceMotion))
            }
        } aside: {
            EmptyView()
        } banner: {
            if model.setupStatus != .ready {
                SetupStrip(status: model.setupStatus)
                    .padding(.top, layout.itemGap)
                    .transition(.reveal(reduceMotion: reduceMotion, edge: .bottom))
            }
        }
        .motion(Motion.smooth, value: lineup)
        .motion(Motion.smooth, value: model.setupStatus)
        .motion(Motion.brief, value: showsSong)
        .onReceive(Self.musicChanges) { _ in updateSongVisible(spec) }
        .onChange(of: spec.linger) { updateSongVisible(spec) }
    }

    /// MusicNow changed: `objectWillChange` is sent before the change, so this arrives a
    /// main-queue turn later, once it has.
    private static let musicChanges = MusicNow.shared.objectWillChange
        .receive(on: DispatchQueue.main).eraseToAnyPublisher()

    private func updateSongVisible(_ spec: MusicSpec) {
        let v = MusicNow.shared.isVisible(spec)
        if v != songVisible { songVisible = v }
    }

    // MARK: Live preview

    private var hero: some View {
        ZStack {
            Group {
                if let p = playing {
                    // Live while the gallery is up front; a still otherwise (no GPU in the background).
                    if model.editingID == nil && activeState != .inactive && !DemoHooks.stillPreviews {
                        // Music as the screensaver would show it (Show music: Corner, or Full
                        // Screen easing in over the style).
                        MetalPreview(preset: p, source: model.library.source,
                                     location: model.locationTuple, store: model.store, maxFPS: 30,
                                     music: model.library.musicSettings, showsMusic: true)
                            .allowsHitTesting(false)
                    } else {
                        StyleThumb(preset: p, showsMusic: true)
                    }
                } else {
                    Color.black
                }
            }
            .id(playing?.id)
            .transition(.opacity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let p = playing { model.edit(p.id) } }
            .help(playing.map { "\($0.name) — double-click to edit" } ?? "")

            // Lit while the screensaver is on (under the badges: it lights the picture).
            DestinationGlow(state: model.setupStatus == .ready ? .active : .off)

            // Night/Day top left; Preview (what it previews, right on it) bottom right.
            VStack(alignment: .leading, spacing: 0) {
                if lineup.night != nil {
                    GlassBadge(text: model.isNightNow ? "Night" : "Day",
                               symbol: model.isNightNow ? "moon.fill" : "sun.max.fill")
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    previewButton
                }
            }
            .padding(Space.xs)
        }
        .motion(Motion.smooth, value: playing?.id)
    }

    private var previewButton: some View {
        Button {
            if let p = playing {
                ScreensaverPreviewController.shared.present(
                    preset: p, source: model.library.source, store: model.store)
            }
        } label: {
            GlassBadge(text: "Preview", symbol: "play.fill", tint: Color.black.opacity(0.45))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(playing == nil)
        .help("Full-screen preview of what's playing now — move the mouse or press a key to exit")
        .accessibilityLabel("Preview")
    }

    // MARK: Header

    private var header: DestinationHeader {
        DestinationHeader(eyebrow: "Screensaver",
                          title: playing?.name ?? "Nothing yet",
                          subtitle: geometry.showsSubtitle ? subtitle : nil)
    }

    /// The glow's state in words (the setup strip says what to do about it).
    private var stateValue: String {
        switch model.setupStatus {
        case .ready: return "On"
        case .notChosen: return "Not selected"
        case .notInstalled: return "Not installed"
        }
    }

    private var subtitle: String {
        let n = lineup.playlist.count
        if n <= 1 { return lineup.night == nil ? "Plays all the time" : "Plays by day" }
        // A no-break space before the dot: a wrapped line never starts with "·".
        return lineup.night == nil ? "Now playing\u{00A0}· one of \(n) styles" : "Now playing\u{00A0}· \(n) styles by day"
    }

    // MARK: Keys

    /// Playlist · "4 styles · 5 min": edit the playlist (a popover), and — while it rotates —
    /// how often it changes and whether it shuffles.
    private var playlistKey: some View {
        let n = lineup.playlist.count
        let styles = n == 1 ? "1 style" : "\(n) styles"
        let every = intervalLabel(model.rotation.intervalMinutes, short: true)
        return Menu {
            Button("Edit Playlist\u{2026}") { DispatchQueue.main.async { editingPlaylist = true } }
            if lineup.rotates {
                Section("Change Every") {
                    ForEach(intervalOptions, id: \.self) { m in
                        Button { model.setRotationInterval(m) } label: {
                            let t = intervalLabel(m, short: false)
                            if m == model.rotation.intervalMinutes { Label(t, systemImage: "checkmark") } else { Text(t) }
                        }
                    }
                }
                Toggle("Shuffle", isOn: Binding(get: { model.rotation.shuffle }, set: { model.setShuffle($0) }))
            } else {
                Text("Add styles to rotate between them")
            }
        } label: {
            PanelKeyLabel(symbol: "square.stack", title: "Playlist",
                          values: lineup.rotates ? ["\(styles) · \(every)", styles, "\(n)"] : [styles],
                          indicator: .menu)
        }
        .panelKeyMenu()
        .help("Choose which styles the screensaver plays\(lineup.rotates ? ", how often it changes and whether it shuffles" : "")")
        .accessibilityLabel("Playlist")
        .accessibilityValue(lineup.rotates ? "\(styles), changes every \(every)" : styles)
        .popover(isPresented: $editingPlaylist, arrowEdge: .bottom) {
            PlaylistEditor()
                .adaptiveLayout()   // the popover is its own root
        }
    }

    /// Night · style name, its LED lit while a different style plays after sunset.
    private var nightKey: some View {
        let night = lineup.night.flatMap(model.preset)
        return Menu {
            Button { Motion.run { model.setNightEnabled(false) } } label: {
                if night == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            Divider()
            StyleMenuItems(current: night?.id) { id in model.setNight(id) }
        } label: {
            PanelKeyLabel(symbol: "moon.stars", title: "Night",
                          values: [night?.name ?? "Off"], indicator: .menuLED(night != nil))
        }
        .panelKeyMenu()
        .help(night.map { "Different style at night: \($0.name) — \(model.isNightNow ? "playing now" : "after sunset")" }
              ?? "Different style at night: off")
        .accessibilityLabel("Different style at night")
        .accessibilityValue(night?.name ?? "Off")
    }

    /// Music · Off / Corner / Full Screen — "Show what's playing", with the mode's options.
    private var musicKey: some View {
        let mode = model.library.musicSettings.displayMode
        return Menu {
            MusicDisplayMenuItems()
        } label: {
            PanelKeyLabel(symbol: "music.note", title: "Music", values: [mode.label],
                          indicator: .menuLED(mode != .off))
        }
        .panelKeyMenu()
        .help("Show what's playing: while Spotify or Apple Music plays, nothing, the song in a corner of the screensaver, or the song full screen over it — with that mode's options")
        .accessibilityLabel("Show what's playing")
        .accessibilityValue(mode.label)
    }

    private var intervalOptions: [Double] {
        var opts: [Double] = [1, 5, 15, 30, 60]
        let cur = model.rotation.intervalMinutes
        if !opts.contains(cur) { opts.append(cur); opts.sort() }
        return opts
    }

    private func intervalLabel(_ m: Double, short: Bool) -> String {
        if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 {
            return m == 60 ? (short ? "1 hr" : "Hour") : "\(Int(m / 60)) \(short ? "hr" : "Hours")"
        }
        if m < 1 { return "\(Int(m * 60)) sec" }
        return m == 1 ? (short ? "1 min" : "Minute") : "\(Int(m)) min"
    }
}

/// Cover · "Song — Artist" · Play/Pause · Next — or, when the player refused Automation,
/// the same "Allow…" fix-it as Settings, the editor and the menu. The song truncates
/// before the controls do. Drawn on a key face, so it lines up with the keys above it.
///
/// The only view on the card that follows the track, and its frame never depends on the
/// track: the key is laid out as an empty face of the line's height, and the song is drawn
/// over it (an overlay can't resize what it's on). So a track change or a play/pause
/// re-renders and re-lays out this line alone — not the card, the row and the gallery's lazy
/// stack around it (a full page layout per song, before).
private struct NowPlayingKey: View {
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var keyHeight: CGFloat = 30
    /// The line's own height, measured (the same for every song: one line of text).
    @State private var height: CGFloat?

    var body: some View {
        let _ = Perf.body("NowPlayingKey")
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height ?? keyHeight + (layout.isWide ? Space.xs : 0))
            .background(PanelKeyFace(shape: RoundedRectangle(cornerRadius: PanelKey.radius, style: .continuous)))
            .overlay(alignment: .top) {
                NowPlayingLine()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if height != $0 { height = $0 } }
            }
    }
}

/// What NowPlayingKey shows: the song, and the transport (or the Automation fix-it).
private struct NowPlayingLine: View {
    @Environment(\.layout) private var layout
    @ObservedObject private var now = MusicNow.shared
    @ScaledLength(relativeTo: .callout) private var musicArt: CGFloat = 20

    var body: some View {
        let _ = Perf.body("NowPlayingLine")
        HStack(spacing: layout.controlGap) {
            MusicArtThumb(image: now.artwork, palette: now.state.palette ?? [], side: musicArt)
            (Text(now.title).fontWeight(.medium)
                + Text(now.artist.isEmpty ? "" : " \u{2014} \(now.artist)").foregroundColor(PanelInk.secondary))
                .textRole(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(now.trackLine)
            if now.needsAutomationFix, let source = now.source {
                Button { now.allowControl(source) } label: { Text("Allow\u{2026}").textRole(.callout) }
                    .glassButton()
                    .fixedSize()
                    .help("Allow DotStudio to control \(source.displayName) — opens System Settings › Privacy & Security › Automation (turn on \(source.automationName) under DotStudio)")
            } else {
                MusicTransport(now: now, showsPrevious: false)
                    .fixedSize()
            }
        }
        .adaptiveControlSize(.small)
        .modifier(PanelKey.Frame())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(now.trackLine)")
    }
}

// MARK: - Show what's playing

/// The menu's items: Off / Corner / Full Screen, then the current mode's options in titled
/// sections. Pickers are written over each option enum's `allCases`, so a new case (a Full
/// Screen layout, a card size) shows up here by itself.
struct MusicDisplayMenuItems: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let spec = model.library.musicSettings
        ForEach(MusicSpec.Display.allCases) { d in
            choice(d.label, d == spec.displayMode) { Motion.run { model.setMusicDisplay(d) } }
        }
        switch spec.displayMode {
        case .fullScreen:
            Divider()
            Section("Layout") {
                ForEach(MusicSpec.FullLayout.allCases) { l in
                    choice(l.label, l == spec.layout) { model.updateMusic { $0.fullLayout = l } }
                }
            }
            // Cover's artwork is the whole screen: nothing is behind it (as in Settings).
            if spec.layout.usesBackdrop {
                Section("Behind the Music") {
                    ForEach(MusicSpec.Backdrop.allCases) { b in
                        choice(b.label, b == spec.backdrop) { model.updateMusic { $0.fullBackdrop = b } }
                    }
                }
            }
        case .corner:
            Divider()
            Section("Corner") {
                ForEach(MusicSpec.Corner.allCases) { c in
                    choice(c.label, c == spec.corner) { model.updateMusic { $0.cardCorner = c } }
                }
            }
            Section("Size") {
                ForEach(MusicSpec.CardSize.allCases) { s in
                    choice(s.label, s == spec.cardSizePreference) { model.updateMusic { $0.cardSize = s } }
                }
            }
        case .off:
            EmptyView()
        }
    }

    private func choice(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

extension AppModel {
    /// "Show music": Off / Corner / Full Screen (Library.music.display, legacy fields in step).
    func setMusicDisplay(_ d: MusicSpec.Display) {
        var m = library.musicSettings
        guard m.displayMode != d || m.display == nil else { return }
        m.setDisplay(d)
        guard m != library.music else { return }
        library.music = m
        save()
    }

    /// One change to the music settings (a Full Screen layout, a corner…), saved.
    func updateMusic(_ change: (inout MusicSpec) -> Void) {
        var m = library.musicSettings
        change(&m)
        guard m != library.music else { return }
        library.music = m
        save()
    }
}

/// The top of both destination cards — eyebrow, title, subtitle — with one
/// structure and one set of gaps, so the two cards' titles and subtitles line up when they
/// sit side by side. `roll` (0 … 1) rolls the title and subtitle from `titleFrom` /
/// `subtitleFrom` to `title` / `subtitle`, like a readout catching up (the passenger's zone
/// syncing to the driver's).
private struct DestinationHeader: View {
    @Environment(\.layout) private var layout
    let eyebrow: String
    let title: String
    var subtitle: String?
    var titleFrom: String? = nil
    var subtitleFrom: String? = nil
    var roll: CGFloat = 1

    var body: some View {
        // A wide window's cards are big: their titles step up with them.
        let titleRole = layout.isWide ? TextRole(style: .title, weight: .semibold) : .cardTitle
        VStack(alignment: .leading, spacing: layout.labelGap) {
            CardEyebrow(text: eyebrow)
            RollingReadout(from: titleFrom ?? title, to: title, progress: roll) { t in
                Text(t)
                    .textRole(titleRole)
                    .foregroundStyle(.primary)
                    .truncating(t, lines: 2)
            }
            if let subtitle {
                RollingReadout(from: subtitleFrom ?? subtitle, to: subtitle, progress: roll) { t in
                    Text(t)
                        .textRole(layout.isWide ? .body : .callout)
                        .foregroundStyle(PanelInk.secondary)
                        .truncating(t, lines: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text that rolls from one value to another as `progress` goes 0 → 1: the old value lifts
/// up and blurs away while the new one rises into place and sharpens — a readout catching
/// up. Sized by whichever value is in front, so it never reserves the other's lines. Under
/// Reduce Motion it's a plain crossfade.
private struct RollingReadout<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledLength(relativeTo: .title2) private var travel: CGFloat = 12
    let from: String
    let to: String
    let progress: CGFloat
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        let rolls = from != to
        let p = rolls ? min(max(progress, 0), 1) : 0
        ReadoutLayout(front: p >= 0.5 ? 1 : 0) {
            content(from)
                .modifier(RollEffect(progress: p, incoming: false, travel: travel, reduceMotion: reduceMotion))
                .accessibilityHidden(p >= 0.5)
            content(to)
                .modifier(RollEffect(progress: p, incoming: true, travel: travel, reduceMotion: reduceMotion))
                .accessibilityHidden(p < 0.5)
        }
    }
}

/// One layer of a RollingReadout, recomputed every frame of the spring (Animatable).
private struct RollEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let incoming: Bool
    let travel: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(max(progress, 0), 1)
        // How far this layer is from rest (0 = in place, 1 = gone).
        let away = incoming ? 1 - t : t
        let opacity: CGFloat = reduceMotion
            ? 1 - away
            : incoming ? smoothstep(0.3, 1, t) : 1 - smoothstep(0, 0.7, t)
        return content
            .opacity(opacity)
            .offset(y: reduceMotion ? 0 : (incoming ? travel : -travel) * away)
            .blur(radius: reduceMotion ? 0 : 5 * away)
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }
}

/// Lays its layers on top of each other, sized by the `front` one.
private struct ReadoutLayout: Layout {
    var front: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.indices.contains(front) else { return .zero }
        return subviews[front].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

// MARK: - Panel keys

/// The cards' controls, drawn as the keys of a climate panel (the SYNC key's family):
/// raised rounded keys, one per row — an icon, the label, the current value on the right,
/// then a chevron (opens a menu) and/or an LED (on while the feature is on). Every key has
/// the same height and face, so the two cards' columns share one rhythm.
enum PanelKey {
    static let radius: CGFloat = Radius.s

    /// Between stacked keys.
    static func gap(_ layout: LayoutMetrics) -> CGFloat { layout.scaled(6) }

    /// A key's padding and height (30 at the default text size, grown with it; a step taller in a wide window).
    struct Frame: ViewModifier {
        @Environment(\.layout) private var layout
        @ScaledLength(relativeTo: .callout) private var height: CGFloat = 30

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, layout.controlGap + Space.xxs)
                .frame(maxWidth: .infinity, minHeight: height + (layout.isWide ? Space.xs : 0), alignment: .leading)
        }
    }
}

/// A key's face: raised and bright over the panel in light mode, a lifted tone in dark, with
/// a top highlight edge. Hover lifts it a touch; pressing sinks it.
struct PanelKeyFace<S: InsettableShape>: View {
    @Environment(\.colorScheme) private var scheme
    let shape: S
    var hovering = false
    var pressed = false

    var body: some View {
        let dark = scheme == .dark
        let fill = dark
            ? Color.white.opacity(pressed ? 0.06 : hovering ? 0.15 : 0.10)
            : Color.white.opacity(pressed ? 0.45 : hovering ? 0.95 : 0.78)
        ZStack {
            shape.fill(fill)
            shape.strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.13), lineWidth: 0.75)
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.14 : 0.9), Color.white.opacity(0)],
                                              startPoint: .top, endPoint: .center), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(pressed ? 0 : (dark ? 0.30 : 0.10)), radius: 2, y: 1)
    }
}

/// The panel's indicator light: dark when off, glowing green (or `color`) when on. `level` fades it.
struct PanelLED: View {
    let level: CGFloat
    var color: Color = PanelInk.led

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.18))
            .overlay(Capsule().fill(color).opacity(level))
            .shadow(color: color.opacity(0.8 * level), radius: 3)
            .accessibilityHidden(true)
    }
}

/// A key as a button: the face, hover and press states, and a focus ring in its shape.
struct PanelKeyStyle: ButtonStyle {
    var radius: CGFloat = PanelKey.radius
    /// A key on its own over the page (the SYNC key on the seam): on glass, with a shadow.
    var floating = false
    /// A latching key that's in (the wallpaper's current Play / Pause / Off): it sits
    /// pressed until another key of its set is pressed.
    var latched = false

    func makeBody(configuration: Configuration) -> some View {
        PanelKeyBody(label: configuration.label, pressed: configuration.isPressed,
                     latched: latched, radius: radius, floating: floating)
    }
}

private struct PanelKeyBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let label: Label
    let pressed: Bool
    var latched = false
    let radius: CGFloat
    let floating: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let key = label
            .background(PanelKeyFace(shape: shape, hovering: hovering && isEnabled && !latched,
                                     pressed: pressed || latched))
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
        Group {
            if floating {
                key.glassSurface(.regular, in: shape, interactive: true)
            } else {
                key
            }
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: pressed)
        .animation(Motion.snappy, value: hovering)
    }
}

/// What a key shows: icon · label ···· value  [LED] [chevron]. `values` are the value from
/// longest to shortest: the longest that fits is shown (the last one truncates).
struct PanelKeyLabel: View {
    enum Indicator: Equatable {
        case none
        /// Opens a menu.
        case menu
        /// A toggle: lit while on.
        case led(Bool)
        /// A menu whose feature is on or off (night style, music).
        case menuLED(Bool)
    }

    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var iconBox: CGFloat = 16
    @ScaledLength(relativeTo: .caption) private var led: CGFloat = 6
    let symbol: String
    let title: String
    var values: [String] = []
    var indicator: Indicator = .none

    var body: some View {
        HStack(spacing: layout.controlGap) {
            Image(systemName: symbol)
                .scaledFont { .scaled(.callout, $0, weight: .medium) }
                .foregroundStyle(PanelInk.secondary)
                .frame(width: iconBox)
            if !title.isEmpty {   // empty: the icon names the key (a folded label)
                Text(title)
                    .textRole(.control)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Space.xxs)
            if let last = values.last {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        valueText(v).fixedSize()
                    }
                    valueText(last).truncationMode(.tail)
                }
                .layoutPriority(-1)
            }
            switch indicator {
            case .none:
                EmptyView()
            case .menu:
                chevron
            case .led(let on):
                PanelLED(level: on ? 1 : 0).frame(width: led, height: led)
            case .menuLED(let on):
                PanelLED(level: on ? 1 : 0).frame(width: led, height: led)
                chevron
            }
        }
        .modifier(PanelKey.Frame())
        .contentShape(Rectangle())
    }

    private func valueText(_ v: String) -> some View {
        Text(v)
            .textRole(.callout)
            .foregroundStyle(PanelInk.secondary)
            .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .scaledFont { .scaled(.caption2, $0, weight: .semibold) }
            .foregroundStyle(PanelInk.tertiary)
    }
}

extension View {
    /// A Menu drawn as a panel key (its label a PanelKeyLabel).
    func panelKeyMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(PanelKeyStyle())
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
    }
}

/// "SCREENSAVER", "WALLPAPER": the small caps label that opens each card. Never breaks.
private struct CardEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.eyebrow)
            .foregroundStyle(PanelInk.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Glow

/// What a destination's glow shows.
enum GlowState: Equatable {
    /// Playing: lit.
    case active
    /// Holding its frame (the wallpaper paused): a dim glow.
    case paused
    /// Not playing (the wallpaper off, the screensaver not set up): no glow.
    case off
}

/// The destination's "on air" light: the thumbnail lit from below like a display — a soft
/// green (the SYNC key's LED) bleeding up from its bottom edge inside the rounded frame,
/// faint enough that the picture shows through. Paused, a dim version; off, nothing. It
/// never moves: a state change eases it in or out, and that's all (no timeline, no state
/// loop — nothing is scheduled while it shows).
struct DestinationGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: GlowState

    /// The glow's strength in each state (0 … 1).
    private var level: Double {
        switch state {
        case .active: return 1
        case .paused: return 0.4
        case .off: return 0
        }
    }

    var body: some View {
        let _ = Perf.body("DestinationGlow")
        GlowFace()
            .opacity(level)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the card carries the state as its value
            .animation(reduceMotion ? Motion.reduced : .easeInOut(duration: 0.35), value: state)
    }
}

/// One fixed drawing of the glow at full strength (DestinationGlow fades it): a light wash
/// rising from the bottom edge and a brighter band right along it, added to the picture
/// (plus-lighter) so it reads as light, not paint.
private struct GlowFace: View {
    var body: some View {
        let led = PanelInk.led
        GeometryReader { g in
            // The wash reaches about a third of the way up (within limits).
            let reach = min(max(g.size.height * 0.34, 40), 120)
            ZStack(alignment: .bottom) {
                LinearGradient(stops: [.init(color: led.opacity(0.40), location: 0),
                                       .init(color: led.opacity(0.14), location: 0.3),
                                       .init(color: led.opacity(0), location: 1)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: reach)
                // The lit edge.
                LinearGradient(colors: [led.opacity(0.7), led.opacity(0)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: 6)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .blendMode(.plusLighter)
    }
}

// MARK: - Wallpaper transport

/// Play · Pause · Off: the wallpaper's three states as a column of latching icon keys (the
/// panel-key family, sized like a key's height): the current one sits pressed in, its LED
/// lit — green while it plays or holds a frame, amber standby while it's off. No labels:
/// each key says what it does in its tooltip and to VoiceOver.
private struct WallpaperTransport: View {
    enum Mode: CaseIterable { case play, pause, off }

    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = 30
    @ScaledLength(relativeTo: .caption2) private var ledWidth: CGFloat = 10
    @ScaledLength(relativeTo: .caption2) private var ledHeight: CGFloat = 2.5
    let mode: Mode
    let select: (Mode) -> Void

    var body: some View {
        // The same height as a panel key (PanelKey.Frame), a touch wider than tall.
        let h = height + (layout.isWide ? Space.xs : 0)
        VStack(spacing: PanelKey.gap(layout)) {
            ForEach(Mode.allCases, id: \.self) { m in
                key(m, height: h)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallpaper playback")
    }

    private func key(_ m: Mode, height h: CGFloat) -> some View {
        let on = m == mode
        return Button { if !on { select(m) } } label: {
            VStack(spacing: Space.xxs - 1) {
                PanelLED(level: on ? 1 : 0, color: m == .off ? PanelInk.standby : PanelInk.led)
                    .frame(width: ledWidth, height: ledHeight)
                Image(systemName: symbol(m))
                    .scaledFont { .scaled(.footnote, $0, weight: .semibold) }
                    .foregroundStyle(on ? Color.primary : PanelInk.secondary)
            }
            .frame(width: (h * 1.2).rounded(), height: h)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelKeyStyle(latched: on))
        .disabled(m == .pause && mode == .off)
        .help(help(m))
        .accessibilityLabel(label(m))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func symbol(_ m: Mode) -> String {
        switch m {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .off: return "power"
        }
    }

    private func label(_ m: Mode) -> String {
        switch m {
        case .play: return "Play"
        case .pause: return "Pause"
        case .off: return "Off"
        }
    }

    private func help(_ m: Mode) -> String {
        switch (m, mode) {
        case (.play, .play): return "Playing behind your windows"
        case (.play, .pause): return "Resume the wallpaper"
        case (.play, .off): return "Turn the wallpaper on"
        case (.pause, .pause): return "Paused on its current frame"
        case (.pause, .off): return "Pause — turn the wallpaper on first"
        case (.pause, _): return "Pause the wallpaper on its current frame"
        case (.off, .off): return "The wallpaper is off"
        case (.off, _): return "Turn the wallpaper off"
        }
    }
}

/// Folded-in setup step on the Screensaver card until it's on: full width of the card's
/// content, between the preview row and the footer.
struct SetupStrip: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    let status: Installer.Status

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
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
        .padding(.horizontal, layout.itemGap)
        .padding(.vertical, layout.itemGap)
        .background(shape.fill(Color.accentColor.opacity(0.10)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.22)))
    }

    private var message: some View {
        HStack(alignment: .center, spacing: layout.itemGap) {
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
        .adaptiveControlSize()
        .fixedSize()
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
        .stillContext(model)   // its own root (a popover)
        // A popover takes its ideal size; in a fixed frame (UI shots) it fits within it.
        .frame(minWidth: width.lowerBound, idealWidth: min(max(layout.scaled(420), width.lowerBound), width.upperBound),
               maxWidth: width.upperBound,
               minHeight: layout.scaled(320), idealHeight: layout.scaled(460), maxHeight: .infinity)
    }
}

/// Every style as menu items, grouped Scenes / Looks, the current one checkmarked.
struct StyleMenuItems: View {
    @EnvironmentObject var model: AppModel
    let current: UUID?
    let onPick: (UUID) -> Void

    var body: some View {
        let scenes = model.library.presets.filter(\.isScene)
        let looks = model.library.presets.filter { !$0.isScene }
        Section("Scenes") { ForEach(scenes) { p in item(p) } }
        Section("Looks") { ForEach(looks) { p in item(p) } }
    }

    @ViewBuilder private func item(_ p: Preset) -> some View {
        Button {
            Motion.run { onPick(p.id) }
        } label: {
            if p.id == current { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }
}
// MARK: - Wallpaper

/// The live wallpaper — the passenger's zone: Off, Live (a style of its own) or Synced —
/// "Same as Screensaver", the desktop playing whatever the screensaver shows, in step (same
/// playlist slot and night style, on a shared clock), so the screensaver starts exactly where
/// the desktop was. Syncing is the SYNC key on the seam (DestinationRow) and the Style menu's
/// first item; both work while the wallpaper is off (it starts in sync). Picking a style
/// while synced plays that style instead (WallpaperController.use ends syncing).
struct WallpaperCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var slot = WallpaperSlot.shared
    @ObservedObject private var controller = WallpaperController.shared
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: GalleryState
    let geometry: DestinationGeometry
    /// The sync morph (DestinationRow): 0 its own readout … 1 following the screensaver.
    var progress: CGFloat = 0
    /// The wallpaper's own style before it followed the screensaver (nil: it was off) — what
    /// the readout rolls from, and back to.
    @State private var lastOwn: UUID?

    /// What the desktop shows: its own style, or — synced — the screensaver's right now
    /// (the slot reports WallpaperController.currentPreset).
    private var style: Preset? { slot.styleID.flatMap(model.preset) }
    /// Live and showing whatever the screensaver shows (WallpaperController.setFollowsScreensaver).
    private var synced: Bool { controller.followsScreensaver && style != nil }
    /// The zone's own readout: its style, or nothing (off).
    private var own: Preset? { synced ? lastOwn.flatMap(model.preset) : style }
    /// The driver's readout: what the screensaver plays now.
    private var driver: Preset? { state.nowPlaying.flatMap(model.preset) }

    var body: some View {
        let _ = Perf.body("WallpaperCard")
        DestinationCardLayout(geometry: geometry, header: header, drawsSurface: false,
                              stateValue: stateValue) {
            preview
        } keys: {
            // Synced, the zone's own style recedes: it's following the driver.
            styleKey
                .opacity(1 - 0.4 * progress)
        } aside: {
            WallpaperTransport(mode: mode) { select($0) }
        } banner: {
            EmptyView()
        }
        .motion(Motion.smooth, value: slot.styleID)
        .motion(Motion.snappy, value: mode)
        .onChange(of: slot.styleID, initial: true) { _, id in
            if !synced { lastOwn = id }
        }
    }

    /// Holding its frame (WallpaperController.togglePause); only while it plays.
    private var paused: Bool { controller.userPaused && style != nil }

    private var mode: WallpaperTransport.Mode {
        style == nil ? .off : paused ? .pause : .play
    }

    private var glow: GlowState {
        switch mode {
        case .play: return .active
        case .pause: return .paused
        case .off: return .off
        }
    }

    private var stateValue: String {
        switch mode {
        case .play: return synced ? "Same as Screensaver" : "On"
        case .pause: return "Paused"
        case .off: return "Off"
        }
    }

    private var header: DestinationHeader {
        let ownSubtitle = own == nil ? "Play any style behind your windows, or the screensaver's."
            : paused ? "Paused on its current frame" : "Playing behind your windows"
        return DestinationHeader(eyebrow: "Wallpaper",
                                 title: driver?.name ?? "Nothing yet",
                                 subtitle: geometry.showsSubtitle ? "Following the screensaver, in step" : nil,
                                 titleFrom: own?.name ?? "Your desktop, alive",
                                 subtitleFrom: ownSubtitle, roll: progress)
    }

    /// Its own style (or the drawn desktop when off), with the screensaver's style coming up
    /// over it as the zones sync.
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let own {
                    StyleThumb(preset: own)
                } else {
                    DesktopGlyph()
                }
            }
            .transition(.opacity)
            Group {
                if let driver {
                    StyleThumb(preset: driver)
                } else {
                    Color.black
                }
            }
            .scaleEffect(reduceMotion ? 1 : 1.06 - 0.06 * progress)
            .opacity(progress)
            DestinationGlow(state: glow)
        }
    }

    // MARK: Keys

    /// Style · its name: "Same as Screensaver" first, then every style.
    private var styleKey: some View {
        let value = synced ? ["Same as Screensaver", "Synced"] : [style?.name ?? "Choose"]
        return Menu {
            Button { setSynced(true) } label: {
                Label("Same as Screensaver", systemImage: synced ? "checkmark" : "link")
            }
            Divider()
            StyleMenuItems(current: synced ? nil : style?.id) { slot.set($0) }
        } label: {
            // Beside the transport the key is narrower: before its value shortens or
            // truncates, the word "Style" folds away (the icon still names the key).
            ViewThatFits(in: .horizontal) {
                ForEach(value, id: \.self) { v in
                    PanelKeyLabel(symbol: "photo.on.rectangle", title: "Style", values: [v], indicator: .menu)
                    PanelKeyLabel(symbol: "photo.on.rectangle", title: "", values: [v], indicator: .menu)
                }
                PanelKeyLabel(symbol: "photo.on.rectangle", title: "", values: [value[value.count - 1]], indicator: .menu)
            }
        }
        .panelKeyMenu()
        .help(style.map { synced ? "Following the screensaver — pick a style to play one of its own" : $0.name }
              ?? "Choose a style to play behind your windows")
        .accessibilityLabel("Wallpaper style")
        .accessibilityValue(synced ? "Same as Screensaver" : (style?.name ?? "None"))
    }

    /// The transport (WallpaperTransport): Play starts the wallpaper when it's off — what it
    /// played before, in sync if it was — or resumes it; Pause holds the current frame; Off
    /// stops it.
    private func select(_ m: WallpaperTransport.Mode) {
        switch m {
        case .play:
            if style == nil {
                Motion.run {
                    if controller.followsScreensaver {
                        controller.setFollowsScreensaver(true)
                    } else if let id = lastOwn ?? driver?.id ?? model.library.presets.first?.id {
                        slot.set(id)
                    }
                }
            }
            // Starting clears a pause in the controller; a pause left over (or the playing
            // wallpaper's) is lifted here.
            if controller.userPaused { controller.togglePause() }
        case .pause:
            if style != nil && !controller.userPaused { controller.togglePause() }
        case .off:
            if style != nil { Motion.run { slot.stop() } }
        }
    }

    private func setSynced(_ on: Bool) {
        Motion.run(Motion.sync) { controller.setFollowsScreensaver(on) }
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

/// A style's cached thumbnail (black until it renders). Never observes the model: what the
/// still depends on — the thumbnailer, the source, the music settings — comes in as one
/// value (StillContext) through the environment, so a selection or an edit elsewhere doesn't
/// re-render it; its own still landing does (the Thumbnailer's per-style signal), and so
/// does a change of source or music settings.
struct StyleThumb: View {
    @Environment(\.stillContext) private var context
    let preset: Preset
    /// Music presented on the still as the screensaver shows it while a song plays (the
    /// Screensaver card's hero when it can't be live); off = the plain thumbnail.
    var showsMusic = false

    var body: some View {
        let _ = Perf.body("StyleThumb")
        if let context {
            TileThumb(thumbnailer: context.thumbnailer, preset: preset, source: context.source,
                      music: context.music, showsMusic: showsMusic)
        } else {
            // A root that doesn't provide one (a sheet or popover rendered on its own).
            ModelStillContext { TileThumb(thumbnailer: $0.thumbnailer, preset: preset, source: $0.source,
                                          music: $0.music, showsMusic: showsMusic) }
        }
    }
}

/// What a still depends on besides its style. Equatable, so the environment only
/// re-renders the stills when one of these changes.
struct StillContext: Equatable {
    let thumbnailer: Thumbnailer
    let source: SourceSpec
    let music: MusicSpec

    init(_ model: AppModel) {
        thumbnailer = model.thumbnailer
        source = model.library.source
        music = model.library.musicSettings
    }

    static func == (a: StillContext, b: StillContext) -> Bool {
        a.thumbnailer === b.thumbnailer && a.source == b.source && a.music == b.music
    }
}

private struct StillContextKey: EnvironmentKey {
    static let defaultValue: StillContext? = nil
}

extension EnvironmentValues {
    /// Set once at the root (ContentView, and roots of their own such as the playlist popover).
    var stillContext: StillContext? {
        get { self[StillContextKey.self] }
        set { self[StillContextKey.self] = newValue }
    }
}

extension View {
    /// Hands the stills below `model`'s StillContext (call where the model is observed anyway).
    func stillContext(_ model: AppModel) -> some View {
        environment(\.stillContext, StillContext(model))
    }
}

/// The fallback for StyleThumb without a StillContext: reads the model (observing it).
private struct ModelStillContext<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder let content: (StillContext) -> Content

    var body: some View { content(StillContext(model)) }
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
