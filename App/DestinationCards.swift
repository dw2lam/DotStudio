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
    /// With more than one display: what each one shows (DisplayStyles.swift).
    let displays: DisplayLineup
    /// A When rule playing now (it outranks the playlist and the night style), and its styles.
    let rule: ActiveRule?

    struct ActiveRule {
        let name: String
        let symbol: String
        let styles: Set<UUID>
    }

    init(model: AppModel, wallpaperID: UUID?, displays: DisplayLineup = .single) {
        lineup = model.screensaverLineup
        nowPlaying = model.nowPlayingID
        self.wallpaperID = wallpaperID
        self.displays = displays
        let lib = model.library
        rule = lib.activeRule(live: SignalService.shared.live, now: Date()).map {
            ActiveRule(name: RuleText.short($0.rule, in: lib), symbol: RuleText.symbol($0.rule, in: lib),
                       styles: Set($0.styles.map(\.id)))
        }
    }

    /// Styles on any destination (the "Playing" filter).
    var playingIDs: Set<UUID> {
        var s = Set(lineup.playlist)
        if let n = lineup.night { s.insert(n) }
        if let w = wallpaperID { s.insert(w) }
        if let r = rule { s.formUnion(r.styles) }
        s.formUnion(displays.screensaverPinned.compactMap { displays.screensaver[$0] })
        s.formUnion(displays.wallpaperPinned.compactMap { displays.wallpaper[$0] })
        return s
    }

    func badges(for id: UUID) -> TileBadges {
        TileBadges(onScreensaver: lineup.playlist.contains(id),
                   inRotation: lineup.rotates && lineup.playlist.contains(id),
                   playingNow: nowPlaying == id,
                   night: lineup.night == id,
                   wallpaper: wallpaperID == id,
                   pinnedScreensaver: !displays.pinned(id, screensaver: true).isEmpty,
                   pinnedWallpaper: !displays.pinned(id, screensaver: false).isEmpty,
                   screensaverDisplay: displays.onlyDisplay(id, in: displays.screensaver)?.shortName,
                   wallpaperDisplay: displays.onlyDisplay(id, in: displays.wallpaper)?.shortName,
                   lineupOffScreen: displays.lineupOffScreen,
                   sharedWallpaperOffScreen: displays.sharedWallpaperOffScreen,
                   ruleActive: rule != nil,
                   rule: rule.flatMap { $0.styles.contains(id) ? TileBadges.Rule(name: $0.name, symbol: $0.symbol) : nil })
    }
}

struct TileBadges: Equatable {
    var onScreensaver = false
    var inRotation = false
    var playingNow = false
    var night = false
    var wallpaper = false
    /// Some display plays it as a style of its own (DisplayStyles.swift).
    var pinnedScreensaver = false
    var pinnedWallpaper = false
    /// With several displays: the one display it plays on, when that's not all of them ("LG").
    var screensaverDisplay: String? = nil
    var wallpaperDisplay: String? = nil
    /// Every connected display plays a style of its own: the lineup / the shared wallpaper is on
    /// no screen, so it isn't announced (the actions still go by `onScreensaver` / `wallpaper`).
    var lineupOffScreen = false
    var sharedWallpaperOffScreen = false
    /// A When rule plays now in the lineup's place: the playlist and the night style aren't on
    /// screen, so they aren't announced (the actions still go by `onScreensaver` / `night`).
    var ruleActive = false
    /// …and this style is one it plays (its name and symbol, as on the Screensaver card).
    var rule: Rule? = nil

    struct Rule: Equatable {
        var name: String
        var symbol: String
    }

    /// The playlist / night badges are on screen (no rule in their place, the lineup on a display).
    var showsLineup: Bool { !lineupOffScreen && !ruleActive }
    /// The When badge is on screen.
    var showsRule: Bool { rule != nil && !lineupOffScreen }

    var isEmpty: Bool {
        !((onScreensaver || night) && showsLineup) && !showsRule && !(wallpaper && !sharedWallpaperOffScreen)
            && !pinnedScreensaver && !pinnedWallpaper
    }
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

    /// The thumbnail's height over its width: 16:10, or Console's wider 16:9 screen.
    var aspect: CGFloat = 10 / 16

    var thumbHeight: CGFloat { (thumbWidth * aspect).rounded() }

    /// `console`: the Stitch decks — a fixed column of legend rows (190 pt at the default text
    /// size) beside a screen that takes the rest, and the SYNC key standing in the gap between
    /// the two decks with a gutter each side (not overlapping their padding).
    init(width measured: CGFloat?, layout: LayoutMetrics, hasWallpaper: Bool, keySize: CGSize = .zero,
         console: Bool = false) {
        let p = layout.cardPadding
        // No tokens for the column's range; on the grid, grown with the text.
        let consoleCol = layout.scaled(layout.widthClass.pick(180, 204, 232))
        let colMin = console ? consoleCol : layout.scaled(layout.widthClass.pick(176, 232, 272))
        let colMax = console ? consoleCol : layout.scaled(layout.widthClass.pick(240, 300, 360))
        let thumbMin = layout.widthClass.pick(CGFloat(140), 176, 220)
        // Before the first measurement: a typical row for the class.
        let w = measured ?? layout.widthClass.pick(840, 1036, 1824)

        /// The thumbnail's width in a `card`: what the column leaves, on the 4-pt grid.
        func thumb(card: CGFloat, cap: CGFloat) -> CGFloat {
            let col = min(max((card * 0.42).rounded(), colMin), colMax)
            return min(cap, ((card - 3 * p - col) / 4).rounded(.down) * 4)
        }
        /// The gap: the grid's, or wider so the key keeps `Space.xs` from both cards' content
        /// (Console: a gutter from both cards' edges).
        func gap(key: CGFloat) -> CGFloat {
            if console { return key > 0 ? ((key + 2 * Space.s) / 2).rounded(.up) * 2 : layout.gridColumnGap }
            let room = key > 0 ? key + 2 * Space.xs - 2 * p : 0
            return max(layout.gridColumnGap, (room / 2).rounded(.up) * 2)
        }
        let aspect: CGFloat = console ? 9 / 16 : 10 / 16

        if hasWallpaper && !layout.prefersStacking {
            let g = gap(key: keySize.width)
            let card = ((w - g) / 2).rounded(.down)
            let t = thumb(card: card, cap: console ? layout.widthClass.pick(320, 520, 640)
                                                   : layout.widthClass.pick(280, 380, 420))
            if t >= thumbMin {
                self.init(sideBySide: true, thumbWidth: t, gap: g, showsSubtitle: !layout.isCompact, aspect: aspect)
                return
            }
        }
        self.init(sideBySide: false,
                  thumbWidth: max(layout.cardPreviewWidth.lowerBound,
                                  thumb(card: w, cap: layout.widthClass.pick(240, 320, 400))),
                  gap: gap(key: hasWallpaper ? keySize.height : 0), showsSubtitle: true, aspect: aspect)
    }

    private init(sideBySide: Bool, thumbWidth: CGFloat, gap: CGFloat, showsSubtitle: Bool, aspect: CGFloat) {
        self.sideBySide = sideBySide
        self.thumbWidth = thumbWidth
        self.gap = gap
        self.showsSubtitle = showsSubtitle
        self.aspect = aspect
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
    @Environment(\.console) private var console
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
        let geometry = DestinationGeometry(width: width, layout: layout, hasWallpaper: hasWallpaper, keySize: keySize,
                                           console: console)
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
                                  gap: geometry.gap, progress: progress, snaps: reduceMotion, console: console))
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
        let inset = console ? Space.xxs : layout.cardPadding
        let clearance = (side ? keySize.height : keySize.width) / 2 + (console ? Space.xxs : Space.xs)
        ZStack(alignment: .topLeading) {
            // Console: no hairline — the SYNC key stands alone between the decks (owner's call).
            if !console {
                SeamHairline(vertical: side, center: center, length: side ? size.height : size.width,
                             inset: inset, clearance: clearance, console: console)
                    .opacity(progress)
            }
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
    var console = false

    var body: some View {
        let mid = vertical ? center.y : center.x
        let a = max(0, mid - clearance - inset)
        let b = max(0, length - inset - (mid + clearance))
        let line = console ? ConsoleInk.hairline : Color.primary.opacity(0.12)
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
    /// Console: two Stitch decks (the panel colour, a hairline, 6 pt corners) that merge.
    var console = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if enabled && console {
            let shape = DualZoneShape(vertical: vertical, first: first, gap: gap,
                                      radius: HubMetrics.panelRadius, progress: progress, snaps: snaps)
            content
                .background(shape.fill(ConsoleInk.panel))
                .overlay(shape.stroke(ConsoleInk.hairline, lineWidth: 1))
        } else if enabled {
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
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .caption2) private var ledWidth: CGFloat = 16
    @ScaledLength(relativeTo: .caption2) private var ledHeight: CGFloat = 3
    let level: CGFloat
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        if console { key } else { classic }
    }

    /// Console (the Stitch SYNC key): a keycap with a link glyph over the word; synced, it
    /// stays down and its glyph lights green (ON, as the switches) as the decks merge.
    private var key: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Image(systemName: "link")
                    .scaledFont { .scaled(points: 14, $0, weight: .semibold) }
                    .foregroundStyle(level > 0.5 ? ConsoleInk.greenInk : ConsoleInk.legend)   // ON is green, as the switches
                Text("Sync").textRole(.consoleKeySmall)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: layout.scaled(32))
        }
        .buttonStyle(.keycap(latched: isOn, padding: EdgeInsets(top: 11, leading: 10, bottom: 11, trailing: 10)))
        .fixedSize()
        .help("Same as Screensaver — play whatever the screensaver shows, same playlist and night style, so it picks up right where your desktop was. Picking a wallpaper style turns this off.")
        .accessibilityLabel("Same as Screensaver")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }

    private var classic: some View {
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

/// The one structure both destination cards share: a thumbnail that fills the card's
/// height beside a column — label, title, subtitle at the top, the keys (rows) at the
/// bottom, level with the thumbnail's edges — and an optional full-width banner under both
/// (the setup strip). `mirrored` puts the thumbnail on the trailing side (the Screensaver
/// card side by side, so both thumbnails meet at the SYNC key). The card hands VoiceOver
/// its state in words as its value (`stateValue`).
private struct DestinationCardLayout<Preview: View, Keys: View, Banner: View>: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    let geometry: DestinationGeometry
    let header: DestinationHeader
    var mirrored = false
    var drawsSurface = true
    /// "On", "Paused", "Off"…
    let stateValue: String
    @ViewBuilder var preview: Preview
    @ViewBuilder var keys: Keys
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
        // Console: the screen in a recessed well (the Stitch viewport), 4 pt corners.
        let radius = console ? HubMetrics.wellRadius : Radius.tile
        return preview
            .frame(width: geometry.thumbWidth)
            .frame(minHeight: geometry.thumbHeight, idealHeight: geometry.thumbHeight, maxHeight: .infinity)
            .background(console ? ConsoleInk.well : .clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(console ? AnyShapeStyle(ConsoleInk.hairline) : AnyShapeStyle(.primary.opacity(0.12))))
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: layout.itemGap)
            // Console: the rows sit flush, unruled; each row's hover wash reaches a little past
            // the column (PanelKey.Frame's inset) so the legends line up with the title.
            VStack(alignment: .leading, spacing: console ? 0 : PanelKey.gap(layout)) {
                keys
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, console ? -PanelKey.consoleInset : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct OwnSurface: ViewModifier {
        @Environment(\.console) private var console
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled && console {
                content.consolePanel(cornerRadius: HubMetrics.panelRadius)
            } else if enabled {
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
    @Environment(\.console) private var console
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var roster = DisplayRoster.shared
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
            WhenKey()            // When rules (WhenRules.swift)
            musicKey
            if roster.showsControls(model.screensaverPins) { displaysKey }
            if showsSong {
                NowPlayingKey()
                    .transition(.lift(reduceMotion: reduceMotion))
            }
        } banner: {
            if model.setupStatus != .ready {
                SetupStrip(status: model.setupStatus)
                    .padding(.top, layout.itemGap)
                    .transition(.reveal(reduceMotion: reduceMotion, edge: .bottom))
            }
            LoginNudgeBanner(kind: .music)   // once, after turning the music display on (SetupGuide.swift)
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
                    // A still, never a live Metal view: a CAMetalLayer inside the scrolling page
                    // presented out of step with the scroll (torn, "staticky" frames) and kept the
                    // GPU busy for the whole time the gallery was up. Preview plays it live.
                    StyleThumb(preset: p, showsMusic: true)
                } else {
                    Color.black
                }
            }
            .id(playing?.id)
            .transition(.opacity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let p = playing { model.edit(p.id) } }
            .help(playing.map { "\($0.name) — double-click to edit" } ?? "")

            if console {
                consoleHeroKeys
            } else {
                classicHeroKeys
            }
        }
        .motion(Motion.smooth, value: playing?.id)
    }

    /// Console: When / Night / Day and Customize share the top row — the tag shortens (its
    /// full text in the tooltip) before it would run under the key in a narrow deck — and
    /// Preview sits bottom right.
    private var consoleHeroKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.xs) {
                if let rule = model.activeRule {
                    HubTag(text: "When: " + RuleText.short(rule, in: model.library),
                           symbol: RuleText.symbol(rule, in: model.library), truncates: true)
                } else if lineup.night != nil {
                    HubTag(text: model.isNightNow ? "Night" : "Day",
                           symbol: model.isNightNow ? "moon.fill" : "sun.max.fill", truncates: true)
                }
                Spacer(minLength: 0)
                if let p = playing {
                    CustomizeButton(name: p.name, flat: true) { model.edit(p.id) }
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                previewButton
            }
        }
        .padding(Space.xs)
    }

    /// Classic: Customize top right; When / Night / Day top left; Preview (what it previews,
    /// right on it) bottom right.
    @ViewBuilder private var classicHeroKeys: some View {
        // Customize (the style playing now) top right.
        if let p = playing {
            CustomizeButton(name: p.name, flat: false) { model.edit(p.id) }
                .padding(Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        VStack(alignment: .leading, spacing: 0) {
            if let rule = model.activeRule {
                // A When rule plays now: it outranks the night style and the playlist.
                GlassBadge(text: "When: " + RuleText.short(rule, in: model.library),
                           symbol: RuleText.symbol(rule, in: model.library))
            } else if lineup.night != nil {
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

    @ViewBuilder private var previewButton: some View {
        if console {
            // The Stitch PREVIEW key: orange, bottom right of the screen.
            Button(action: preview) { HubKeyLabel(text: "Preview", symbol: "play.fill") }
                .buttonStyle(.keycap(.signal, padding: HubMetrics.smallKey))
                .previewKeyTraits(disabled: playing == nil)
        } else {
            Button(action: preview) {
                GlassBadge(text: "Preview", symbol: "play.fill", tint: Color.black.opacity(0.45))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .previewKeyTraits(disabled: playing == nil)
        }
    }

    private func preview() {
        if let p = playing {
            ScreensaverPreviewController.shared.present(
                preset: p, source: model.library.source, store: model.store)
        }
    }

    // MARK: Header

    private var header: DestinationHeader {
        DestinationHeader(eyebrow: "Screensaver",
                          title: playing?.name ?? "Nothing yet",
                          subtitle: geometry.showsSubtitle ? subtitle : nil,
                          badge: DeckBadge(symbol: "play.rectangle.fill", tone: .signal,
                                           lit: model.setupStatus == .ready && playing != nil))
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
        if model.activeRule != nil { return "Playing for a When rule" }
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
                .environment(\.console, console)
                .adaptiveLayout()   // the popover is its own root
        }
    }

    /// Night · style name (dimmed while off).
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

    /// Displays · "Same on all" / "LG: Golden Hour": a style of its own on any display (only
    /// with more than one display connected). See DisplayStyles.swift.
    private var displaysKey: some View {
        let pins = model.library.displayStyles ?? [:]
        let (values, on) = displayKeyValues(displays: roster.displays, pins: pins, model: model)
        return Menu {
            DisplayStylesMenuItems(displays: roster.displays, pins: pins,
                                   set: { id, d in model.setScreensaverStyle(id, on: d) },
                                   clearAll: { model.clearScreensaverPins() })
        } label: {
            PanelKeyLabel(symbol: "display.2", title: "Displays", values: values, indicator: .menuLED(on))
        }
        .panelKeyMenu()
        .help(on ? "Some displays play a style of their own — \(values[0])" : "Every display plays the same — or give a display a style of its own")
        .accessibilityLabel("Style on each display")
        .accessibilityValue(values[0])
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
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .callout) private var keyHeight: CGFloat = 30
    /// The line's own height, measured (the same for every song: one line of text).
    @State private var height: CGFloat?

    var body: some View {
        let _ = Perf.body("NowPlayingKey")
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height ?? keyHeight)
            // Console: one more ruled row (its hairline is the line's own, PanelKey.Frame).
            .background(PanelKeyFace(shape: RoundedRectangle(cornerRadius: PanelKey.radius, style: .continuous),
                                     resting: console ? 0 : 0.05))
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

    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .caption) private var consoleKey: CGFloat = 26

    var body: some View {
        let _ = Perf.body("NowPlayingLine")
        if console { consoleLine } else { classicLine }
    }

    /// Console: the cover, the song in the body face (the artist in the legend grey), and the
    /// transport as small keys in a recessed well — the PLAYBACK row's idiom — or the
    /// Automation fix-it as an orange key.
    private var consoleLine: some View {
        HStack(spacing: Space.xs) {
            MusicArtThumb(image: now.artwork, palette: now.state.palette ?? [], side: musicArt)
            (Text(now.title).foregroundColor(ConsoleInk.ink)
                + Text(now.artist.isEmpty ? "" : " \u{2014} \(now.artist)").foregroundColor(ConsoleInk.legend))
                .textRole(.consoleBodySmall)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(now.trackLine)
            if now.needsAutomationFix, let source = now.source {
                Button { now.allowControl(source) } label: { HubKeyLabel(text: "Allow\u{2026}") }
                    .buttonStyle(.keycap(.signal, padding: HubMetrics.smallKey))
                    .fixedSize()
                    .padding(.vertical, Space.xxs)
                    .help("Allow DotStudio to control \(source.displayName) — opens System Settings › Privacy & Security › Automation (turn on \(source.automationName) under DotStudio)")
            } else {
                HStack(spacing: 2) {
                    transportKey(now.isPlaying ? "pause.fill" : "play.fill", now.isPlaying ? "Pause" : "Play") { now.playPause() }
                    transportKey("forward.fill", "Next") { now.next() }
                }
                .padding([.top, .horizontal], 2)
                .consoleWell(cornerRadius: HubMetrics.wellRadius)
                .fixedSize()
                .padding(.vertical, Space.xxs)
                .disabled(!now.canControl)
            }
        }
        .modifier(PanelKey.Frame())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(now.trackLine)")
    }

    private func transportKey(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 10.5, $0, weight: .bold) }
                .frame(width: consoleKey, height: consoleKey)
        }
        .buttonStyle(.keycap(cornerRadius: 2, padding: EdgeInsets()))
        .accessibilityLabel(label)
        .help(now.canControl ? label : "Allow DotStudio to control \(now.sourceName) to use the controls (Settings › Music)")
    }

    private var classicLine: some View {
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
    @Environment(\.console) private var console
    let eyebrow: String
    let title: String
    var subtitle: String?
    var titleFrom: String? = nil
    var subtitleFrom: String? = nil
    var roll: CGFloat = 1
    /// Console: the deck's own mark — its glyph and colour (DeckBadge).
    var badge: DeckBadge? = nil

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console (a deck as a tile): the deck's badge and its name as the tile's title
    /// ("Screensaver", "Wallpaper"), then what it plays now and the one line of how.
    private var consoleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.xs + 2) {
                if let badge { badge }
                Text(eyebrow)
                    .textRole(.consoleTileTitle)
                    .foregroundStyle(ConsoleInk.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.bottom, Space.s)
            RollingReadout(from: titleFrom ?? title, to: title, progress: roll) { t in
                Text(t)
                    .textRole(.consoleNowPlaying)
                    .foregroundStyle(ConsoleInk.ink)
                    .truncating(t, lines: 2)
            }
            if let subtitle {
                RollingReadout(from: subtitleFrom ?? subtitle, to: subtitle, progress: roll) { t in
                    Text(t)
                        .textRole(.consoleBodySmall)
                        .foregroundStyle(ConsoleInk.legend)
                        .truncating(t, lines: 2)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var classicBody: some View {
        // A wide window's cards are big: their titles step up with them.
        let titleRole = TextRole.cardTitle
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
                        .textRole(.callout)
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

/// The cards' controls as quiet rows: an icon, the label, the current value on the right
/// (dimmer while the feature is off), then a chevron when it opens a menu. No face at rest,
/// a soft wash under the pointer. Every row has the same height, so the two cards' columns
/// share one rhythm.
enum PanelKey {
    static let radius: CGFloat = Radius.s

    /// Between stacked keys.
    static func gap(_ layout: LayoutMetrics) -> CGFloat { layout.scaled(6) }

    /// Console: how far a row's wash reaches past the deck's column on each side.
    static let consoleInset: CGFloat = 6

    /// A key's padding and height (30 at the default text size, grown with it; a step taller in a wide window).
    /// Console: a row of the deck's list — 26 / 28 / 30 pt by width class, unruled (24 pt with
    /// a hairline under each before 2026-11-26), its content inset by `consoleInset` inside
    /// the hover wash.
    struct Frame: ViewModifier {
        @Environment(\.layout) private var layout
        @Environment(\.console) private var console
        @ScaledLength(relativeTo: .callout) private var height: CGFloat = 30

        func body(content: Content) -> some View {
            if console {
                content
                    .padding(.horizontal, PanelKey.consoleInset)
                    .frame(maxWidth: .infinity, minHeight: layout.scaled(layout.widthClass.pick(26, 28, 30)),
                           alignment: .leading)
            } else {
                content
                    .padding(.horizontal, layout.controlGap + Space.xxs)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            }
        }
    }
}

/// A key's face: nothing at rest (a row of the card, not a box), a soft wash under the
/// pointer, a deeper one pressed or latched. `resting` gives it a quiet fill at rest (the
/// floating SYNC key, the now-playing line). Flat fills only: no shadows, no highlights,
/// nothing for the window server to re-composite as the page scrolls.
struct PanelKeyFace<S: InsettableShape>: View {
    let shape: S
    var hovering = false
    var pressed = false
    var resting: Double = 0

    var body: some View {
        let level = pressed ? 0.12 : hovering ? max(resting + 0.03, 0.06) : resting
        ZStack {
            shape.fill(Color.primary.opacity(level))
            if resting > 0 { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
        }
    }
}

/// An on/off light (the SYNC key): a quiet bar, accent-coloured when on. `level` fades it.
struct PanelLED: View {
    let level: CGFloat
    var color: Color = .accentColor

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.16))
            .overlay(Capsule().fill(color).opacity(level))
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
    @Environment(\.console) private var console
    @State private var hovering = false
    let label: Label
    let pressed: Bool
    var latched = false
    let radius: CGFloat
    let floating: Bool

    var body: some View {
        if console { row } else { key }
    }

    /// Console: a ruled row with no face; under the pointer a faint wash of the high surface,
    /// pressed a deeper one, and its value prints in signal (PanelKeyHot).
    private var row: some View {
        let shape = RoundedRectangle(cornerRadius: HubMetrics.wellRadius, style: .continuous)
        return label
            .environment(\.panelKeyHot, hovering && isEnabled)
            .background(shape.fill(ConsoleInk.surfaceHigh.opacity(pressed ? 0.6 : hovering && isEnabled ? 0.3 : 0)))
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.08), value: hovering)
    }

    private var key: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return label
            .background(PanelKeyFace(shape: shape, hovering: hovering && isEnabled && !latched,
                                     pressed: pressed || latched, resting: floating ? 0.05 : 0))
            .background { if floating { shape.fill(Color(nsColor: .windowBackgroundColor)) } }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// What a key shows: icon · label ···· value  [chevron]. `values` are the value from
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
    @Environment(\.console) private var console
    @Environment(\.panelKeyHot) private var hot
    @ScaledLength(relativeTo: .callout) private var iconBox: CGFloat = 16
    @ScaledLength(relativeTo: .caption2) private var legendIconBox: CGFloat = 15
    let symbol: String
    let title: String
    var values: [String] = []
    var indicator: Indicator = .none

    var body: some View {
        if console { row } else { key }
    }

    /// Console (the Stitch legend row): glyph and legend in mono caps on the left, the value
    /// in mono on the right — ink while the feature is on, legend grey while it's off.
    private var row: some View {
        HStack(spacing: Space.xs - 2) {
            Image(systemName: symbol)
                .scaledFont { .scaled(points: 11.5, $0, weight: .medium) }
                .foregroundStyle(ConsoleInk.legend)
                .frame(width: legendIconBox)
            if !title.isEmpty {
                Text(title)
                    .textRole(.legend)
                    .foregroundStyle(ConsoleInk.legend)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Space.xxs)
            if let last = values.last {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        consoleValue(v).fixedSize()
                    }
                    consoleValue(last).truncationMode(.tail)
                }
                .layoutPriority(-1)
            }
        }
        .modifier(PanelKey.Frame())
        .contentShape(Rectangle())
    }

    private func consoleValue(_ v: String) -> some View {
        Text(v)
            .textRole(.consoleValue)
            .foregroundStyle(hot ? ConsoleInk.signalInk : isOn ? ConsoleInk.ink : ConsoleInk.legend)
            .lineLimit(1)
    }

    private var key: some View {
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
            case .led:
                EmptyView()
            case .menuLED:
                chevron
            }
        }
        .modifier(PanelKey.Frame())
        .contentShape(Rectangle())
    }

    /// Off reads quieter than on (the light the keys used to carry).
    private var isOn: Bool {
        switch indicator {
        case .led(let on), .menuLED(let on): return on
        default: return true
        }
    }

    private func valueText(_ v: String) -> some View {
        Text(v)
            .textRole(.callout)
            .foregroundStyle(isOn ? Color.primary.opacity(0.85) : PanelInk.tertiary)
            .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .scaledFont { .scaled(.caption2, $0, weight: .semibold) }
            .foregroundStyle(PanelInk.tertiary)
    }
}

private struct PanelKeyHotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Console: the panel key around this label is under the pointer (its value prints in signal).
    var panelKeyHot: Bool {
        get { self[PanelKeyHotKey.self] }
        set { self[PanelKeyHotKey.self] = newValue }
    }
}

/// Console: a deck's mark beside its title — a small square in the deck's own colour (the
/// Screensaver's signal orange, the Wallpaper's blue: the same colours as the pads' tags and
/// the hover bar's keys) with the deck's glyph. Lit (filled) while the deck is on screen; out,
/// a grey key face with the glyph still in the deck's colour, so each tile keeps its identity
/// when it's off. Decoration — the deck's VoiceOver value says its state in words.
struct DeckBadge: View {
    enum Tone { case signal, blue }
    let symbol: String
    let tone: Tone
    let lit: Bool
    @ScaledLength(relativeTo: .title2) private var side: CGFloat = 26
    @ScaledLength(relativeTo: .title2) private var glyph: CGFloat = 12.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HubMetrics.wellRadius, style: .continuous)
        let fill = tone == .signal ? ConsoleInk.signal : ConsoleInk.blue
        let ink: Color = lit ? (tone == .signal ? ConsoleInk.onSignal : .white)
                             : (tone == .signal ? ConsoleInk.signalInk : ConsoleInk.blueInk)
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: side, height: side)
            .background(shape.fill(lit ? fill : ConsoleInk.keyFace))
            .overlay(shape.strokeBorder(lit ? Color.black.opacity(0.12) : ConsoleInk.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private extension View {
    /// The Screensaver deck's Preview key, either look.
    func previewKeyTraits(disabled: Bool) -> some View {
        self.disabled(disabled)
            .help("Full-screen preview of what's playing now — move the mouse or press a key to exit")
            .accessibilityLabel("Preview")
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

/// "Screensaver", "Wallpaper": the quiet label that opens each card. Never breaks.
private struct CardEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.calloutEmphasis)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Wallpaper transport

/// Play · Pause · Off: the wallpaper's three states as one row ("Playback" and a small
/// segmented strip of icon keys, the current one pressed in). Each key says what it does in
/// its tooltip and to VoiceOver.
private struct WallpaperTransport: View {
    enum Mode: CaseIterable { case play, pause, off }

    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .caption) private var consoleKey: CGFloat = 26
    @ScaledLength(relativeTo: .caption2) private var legendIconBox: CGFloat = 15
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = 30
    let mode: Mode
    let select: (Mode) -> Void

    @ScaledLength(relativeTo: .callout) private var iconBox: CGFloat = 16

    var body: some View {
        if console { consoleRow } else { classicRow }
    }

    /// Console (the Stitch transport): the PLAYBACK legend, and ▶ ‖ ⏻ as three small keys in a
    /// recessed well — Play a blue key while the wallpaper plays, Pause or Off held down while
    /// they're the state.
    private var consoleRow: some View {
        HStack(spacing: Space.xs - 2) {
            Image(systemName: "playpause")
                .scaledFont { .scaled(points: 11.5, $0, weight: .medium) }
                .foregroundStyle(ConsoleInk.legend)
                .frame(width: legendIconBox)
            ViewThatFits(in: .horizontal) {
                Text("Playback").textRole(.legend).foregroundStyle(ConsoleInk.legend).lineLimit(1).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(Mode.allCases, id: \.self) { m in consoleKey(m) }
            }
            .padding([.top, .horizontal], 2)
            .consoleWell(cornerRadius: HubMetrics.wellRadius)
            .fixedSize()
            .padding(.vertical, Space.xxs)
        }
        .modifier(PanelKey.Frame())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallpaper playback")
    }

    private func consoleKey(_ m: Mode) -> some View {
        let on = m == mode
        return Button { if !on { select(m) } } label: {
            Image(systemName: symbol(m))
                .scaledFont { .scaled(points: 10.5, $0, weight: .bold) }
                .frame(width: consoleKey, height: consoleKey)
        }
        .buttonStyle(.keycap(on && m == .play ? .blue : .plain, latched: on && m != .play,
                             cornerRadius: 2, padding: EdgeInsets()))
        .disabled(m == .pause && mode == .off)
        .help(help(m))
        .accessibilityLabel(label(m))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder private var classicRow: some View {
        // A row like the other keys: icon · "Playback" ···· [▶ ‖ ⏻], the three as one
        // small segmented strip, the current one pressed in.
        let h = height - Space.xs
        HStack(spacing: layout.controlGap) {
            Image(systemName: "playpause")
                .scaledFont { .scaled(.callout, $0, weight: .medium) }
                .foregroundStyle(PanelInk.secondary)
                .frame(width: iconBox)
            // The word folds away before the strip would push the card wider.
            ViewThatFits(in: .horizontal) {
                Text("Playback").textRole(.control).lineLimit(1).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(Mode.allCases, id: \.self) { m in
                    key(m, height: h)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: PanelKey.radius, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .fixedSize()
        }
        .modifier(PanelKey.Frame())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallpaper playback")
    }

    private func key(_ m: Mode, height h: CGFloat) -> some View {
        let on = m == mode
        return Button { if !on { select(m) } } label: {
            Image(systemName: symbol(m))
                .scaledFont { .scaled(.footnote, $0, weight: .semibold) }
                .foregroundStyle(on ? (m == .off ? Color.primary : Color.accentColor) : PanelInk.secondary)
            .frame(width: (h * 1.4).rounded(), height: h)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelKeyStyle(radius: PanelKey.radius - 2, latched: on))
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
    @Environment(\.console) private var console
    let status: Installer.Status

    var body: some View {
        if console { consoleStrip } else { classicStrip }
    }

    /// Console: the same strip as a printed notice — a thin signal edge on a faint signal
    /// wash, the hub's faces, and an orange key.
    private var consoleStrip: some View {
        let shape = RoundedRectangle(cornerRadius: HubMetrics.wellRadius, style: .continuous)
        return ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .center, spacing: layout.itemGap) {
                Image(systemName: status == .notInstalled ? "arrow.down.circle.fill" : "hand.point.up.left.fill")
                    .scaledFont { .scaled(points: 18, $0) }
                    .foregroundStyle(ConsoleInk.signalInk)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(headline)
                        .textRole(.consoleTitle)
                        .foregroundStyle(ConsoleInk.ink)
                        .wrapping()
                    Text(detail)
                        .textRole(.consoleBodySmall)
                        .foregroundStyle(ConsoleInk.legend)
                        .wrapping()
                }
            }
            .frame(idealWidth: layout.scaled(240), maxWidth: .infinity, alignment: .leading)
            HStack(spacing: layout.controlGap) {
                Button { SetupGuidePanel.shared.show(model: model) } label: {
                    Text("Show Me How").textRole(.consoleBodySmall).underline()
                        .foregroundStyle(ConsoleInk.signalInk)
                }
                .buttonStyle(.plain)
                .help("A step-by-step guide to choosing DotStudio in System Settings")
                if status == .notInstalled {
                    Button { model.installScreensaver() } label: { HubKeyLabel(text: "Install") }
                        .buttonStyle(.keycap(.signal))
                } else {
                    Button { Installer.openScreenSaverSettings() } label: { HubKeyLabel(text: "Open Settings") }
                        .buttonStyle(.keycap(.signal))
                }
            }
            .fixedSize()
        }
        .padding(layout.itemGap)
        .background(shape.fill(ConsoleInk.signal.opacity(0.07)))
        .overlay(shape.strokeBorder(ConsoleInk.signal.opacity(0.45), lineWidth: 1))
    }

    private var headline: String {
        status == .notInstalled ? "Install the screensaver to start playing"
                                : "One more step: choose DotStudio in System Settings"
    }

    private var detail: String {
        status == .notInstalled ? "It's added to your Mac once — after that, everything is controlled from here."
                                : "Wallpaper ▸ Screen Saver ▸ DotStudio. Repeat for each display you want it on."
    }

    @ViewBuilder private var classicStrip: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        // The button sits beside the text while the text keeps a comfortable column
        // (it wraps as needed); in a narrower strip it moves under the text.
        // One layout, never a swap: the button is an AppKit control (see ReflowStack).
        ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: layout.itemGap) {
            message
                .frame(idealWidth: layout.scaled(240), maxWidth: .infinity, alignment: .leading)
            button
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
                Text(headline)
                    .textRole(.calloutEmphasis)
                    .wrapping()
                Text(detail)
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
        }
    }

    private var button: some View {
        HStack(spacing: layout.controlGap) {
            // The guided setup (SetupGuide.swift): the illustrated walkthrough + live checklist.
            Button { SetupGuidePanel.shared.show(model: model) } label: { Text("Show Me How").textRole(.body) }
                .buttonStyle(.link)
                .help("A step-by-step guide to choosing DotStudio in System Settings")
            Group {
                if status == .notInstalled {
                    Button { model.installScreensaver() } label: { Text("Install").textRole(.body) }
                } else {
                    Button { Installer.openScreenSaverSettings() } label: { Text("Open Settings").textRole(.body) }
                }
            }
            .glassButton(.prominent)
            .adaptiveControlSize()
        }
        .fixedSize()
    }
}

/// Multi-select of every style, grouped Scenes / Looks.
struct PlaylistEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
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
                    Text("Screensaver Playlist").textRole(console ? .consoleHeadline : .headline).wrapping()
                    Text(lineup.rotates ? "\(lineup.playlist.count) styles take turns." : "One style plays. Tick more to rotate.")
                        .textRole(console ? .consoleBodySmall : .caption)
                        .foregroundStyle(console ? AnyShapeStyle(ConsoleInk.legend) : AnyShapeStyle(.secondary))
                        .wrapping()
                }
                SearchField(text: $query, prompt: "Filter styles")
            }
            .padding(layout.cardPadding)
            if console { Rectangle().fill(ConsoleInk.hairline).frame(height: 1) } else { Divider() }
            ScrollView {
                LazyVGrid(columns: layout.columns(minimum: 112, spacing: Space.s), alignment: .leading,
                          spacing: layout.itemGap) {
                    ForEach(presets) { p in
                        let on = lineup.playlist.contains(p.id)
                        Button {
                            Motion.run { on ? model.removeFromPlaylist(p.id) : model.addToPlaylist(p.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                if console {
                                    consoleThumb(p, on: on)
                                } else {
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
                                }
                                // Two lines, always reserved, so the grid's rows line up.
                                Text(p.name)
                                    .textRole(console ? .consoleBodySmall : .caption)
                                    .foregroundStyle(console ? AnyShapeStyle(on ? ConsoleInk.ink : ConsoleInk.legend)
                                                             : AnyShapeStyle(on ? .primary : .secondary))
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
        .background(console ? ConsoleInk.panel : .clear)
    }

    /// Console: the still in a well-edged screen (4 pt corners), an orange edge and a lit LED
    /// in the corner when it's in the playlist, a dark one when it isn't.
    private func consoleThumb(_ p: Preset, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: HubMetrics.wellRadius, style: .continuous)
        return StyleThumb(preset: p)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(on ? ConsoleInk.signal : ConsoleInk.hairline, lineWidth: on ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(on ? ConsoleInk.onSignal : .white, on ? ConsoleInk.signal : .black.opacity(0.35))
                    .font(.system(size: checkSize, weight: .semibold))
                    .shadow(color: .black.opacity(0.3), radius: 1.5)
                    .padding(Space.xxs)
            }
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
    @ObservedObject private var roster = DisplayRoster.shared
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.console) private var console
    let state: GalleryState
    let geometry: DestinationGeometry
    /// The sync morph (DestinationRow): 0 its own readout … 1 following the screensaver.
    var progress: CGFloat = 0
    /// The wallpaper's own style before it followed the screensaver (nil: it was off) — what
    /// the readout rolls from, and back to.
    @State private var lastOwn: UUID?

    /// What the desktop shows: its own style, or — synced — the screensaver's right now
    /// (the slot reports WallpaperController.currentPreset).
    private var style: Preset? {
        // With every connected display on a style of its own (one display, pinned), that's it.
        slot.styleID == nil ? nil : (state.displays.wallpaperNow ?? slot.styleID).flatMap(model.preset)
    }
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
            WallpaperTransport(mode: mode) { select($0) }
            // Synced, the zone's own style recedes: it's following the driver.
            styleKey
                .opacity(1 - 0.4 * progress)
            if roster.showsControls(slot.pins, synced ? model.screensaverPins : [:], alive: { model.preset($0) != nil }) {
                displaysKey
                    .opacity(1 - 0.4 * progress)
            }
        } banner: {
            LoginNudgeBanner(kind: .wallpaper)   // once, after turning it on (SetupGuide.swift)
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
                                 subtitleFrom: ownSubtitle, roll: progress,
                                 badge: DeckBadge(symbol: "photo.fill.on.rectangle.fill", tone: .blue,
                                                  lit: mode == .play))
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
        }
        .overlay(alignment: .topTrailing) {
            // Customize what's on the desktop now: its own style, or the screensaver's when synced.
            if let shown = (progress > 0.5 ? driver : own) ?? style {
                CustomizeButton(name: shown.name, flat: console) { model.edit(shown.id) }
                    .padding(Space.xs)
            }
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

    /// Displays · "Same on all" / "LG: Golden Hour": a style of its own on any display (only with
    /// more than one display connected). Synced, every display follows its screensaver; a pick
    /// here plays a style of its own instead (like the Style menu). Beside the transport the key
    /// is narrow: "Displays" folds away before the value shortens (as the Style key's word does).
    private var displaysKey: some View {
        // Synced, each display shows what its screensaver shows: the screensaver's pins.
        let (values, on) = displayKeyValues(displays: roster.displays,
                                            pins: synced ? (model.library.displayStyles ?? [:]) : slot.pins, model: model)
        return Menu {
            // Synced, the menu is the screensaver's per-display styles (what each display's
            // wallpaper shows): "Same on All" and "Same as Other Displays" clear those; picking
            // a style gives that display a wallpaper of its own (and ends sync, the others
            // keeping what they show — WallpaperController.setDisplayStyle).
            DisplayStylesMenuItems(displays: roster.displays, pins: synced ? model.screensaverPins : slot.pins,
                                   note: synced ? "Following the screensaver on each display" : nil,
                                   set: { id, d in
                                       if synced && id == nil { model.setScreensaverStyle(nil, on: d) } else { slot.set(id, on: d) }
                                   },
                                   clearAll: { synced ? model.clearScreensaverPins() : slot.clearPins() })
        } label: {
            ViewThatFits(in: .horizontal) {
                ForEach(values, id: \.self) { v in
                    PanelKeyLabel(symbol: "display.2", title: "Displays", values: [v], indicator: .menuLED(on))
                    PanelKeyLabel(symbol: "display.2", title: "", values: [v], indicator: .menuLED(on))
                }
                PanelKeyLabel(symbol: "display.2", title: "", values: [values[values.count - 1]],
                              indicator: .menuLED(on))
            }
        }
        .panelKeyMenu()
        .help(synced ? "Every display follows its screensaver — pick a style for a display to play one of its own"
              : on ? "Some displays play a wallpaper of their own — \(values[0])"
              : "Every display plays the same wallpaper — or give a display a style of its own")
        .accessibilityLabel("Wallpaper on each display")
        .accessibilityValue(values[0])
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

/// A tiny drawn desktop: menu bar, dock, a soft gradient — the "off" state. Console: a
/// powered-off display — a dark screen (in Light Mode too: a screen that's off is dark, never
/// a white box), a faint menu bar and dock, a soft glare across the glass.
private struct DesktopGlyph: View {
    @Environment(\.console) private var console

    var body: some View {
        if console { consoleGlyph } else { classicGlyph }
    }

    /// Fixed greys, not the adaptive tokens: the screen is dark in both modes.
    private static func grey(_ v: Double, _ a: Double = 1) -> Color { Color(.sRGB, red: v, green: v, blue: v + 0.012, opacity: a) }

    private var consoleGlyph: some View {
        ZStack {
            Self.grey(0.055)   // #0E0E11, the dark well
            LinearGradient(stops: [.init(color: .white.opacity(0.07), location: 0),
                                   .init(color: .white.opacity(0.02), location: 0.45),
                                   .init(color: .clear, location: 0.46)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(Self.grey(0.165)).frame(height: 6)            // #2A2A2D
                Spacer()
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.grey(0.165))
                    .frame(width: 88, height: 10).padding(.bottom, Space.xs)
            }
            Image(systemName: "sparkles")
                .scaledFont { .scaled(points: 20, $0, weight: .light) }
                .foregroundStyle(Self.grey(0.47))                              // #78767A, the outline grey
        }
        .accessibilityHidden(true)
    }

    private var classicGlyph: some View {
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
    /// Console: a filter key with its skirt, and the search well level with its face (28 before
    /// 2026-11-26).
    static let consoleHeight: CGFloat = 34
}

/// Inline glass search field.
struct SearchField: View {
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ScaledLength(relativeTo: .callout) private var height: CGFloat = GalleryControl.height
    @ScaledLength(relativeTo: .callout) private var consoleHeight: CGFloat = GalleryControl.consoleHeight
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        if console { consoleField } else { classicField }
    }

    /// Console (the Stitch search well): recessed, mono text, a signal edge while typing in it.
    /// As tall as a filter key's face, so the two line up.
    private var consoleField: some View {
        HStack(spacing: Space.xs - 2) {
            Image(systemName: "magnifyingglass")
                .scaledFont { .scaled(points: 11.5, $0, weight: .medium) }
                .foregroundStyle(ConsoleInk.legend)
            field
                .textRole(.consoleValue)
                .foregroundStyle(ConsoleInk.ink)
                .help(text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont { .scaled(.body, $0) }
                        .foregroundStyle(ConsoleInk.legend)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, Space.xs + 2)
        .frame(height: consoleHeight - HubMetrics.keySkirt)
        .consoleWell(cornerRadius: HubMetrics.wellRadius, focused: focus?.wrappedValue ?? false)
    }

    private var classicField: some View {
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
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
    }
}

/// True while UIShots renders screens offscreen (DOTSTUDIO_UI_SHOTS).
enum OffscreenCapture {
    static let isActive = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil
}
