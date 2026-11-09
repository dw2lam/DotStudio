//  MusicOverlayLayer.swift — the music foreground, drawn as a CALayer tree at the display's
//  native scale above the Metal layer (Metal output is often reduced and nearest-upscaled,
//  so type there would pixelate). No SwiftUI: the saver, the live wallpaper, the in-app
//  previews and thumbnails (layer.render(in:)) all host the same layer. What it shows is
//  decided by MusicPresentation, the same for every host.
//
//  Two modes, both shown only while music is visible (playing, or paused within the linger) —
//  nothing playing is never an empty screen, just the screensaver:
//    • full — Full Screen music (and a legacy Now Playing style's foreground), per layout:
//        Album  (Apple Music full screen) artwork left, big type right;
//        Stage  (Spotify TV)              artwork centred, type below;
//        Cover  (artwork fills the screen) type bottom-left over the shader's scrim.
//      It fades with the renderer's backdrop (fullFadeSeconds).
//    • card — Corner: rounded artwork, title, artist and a thin bar drawn straight on the
//      scene over a feathered scrim that fades out with no edge — no box.
//  The player's name never shows on screen. Paused = the progress bar dims (and a small
//  pause glyph sits after the elapsed time, or where a stream's bar would be).
//
//  Song text is never cut off, in any layout (MusicText.fit): up to two balanced lines per
//  field, then slightly smaller (85 %), then a slow marquee on the last line — or, with Reduce
//  Motion, on the live wallpaper and in stills, a third line. The corner's column widens for
//  long text, and every block stays inside the screen's margins (and clear of a notch).
//
//  Type: SF Pro (Display for the large lines, Text for the small — the system font's own
//  optical sizes), Medium titles (Semibold only where a corner title gets small), Regular
//  for the rest; every line carries MusicText's soft two-layer shadow.
//
//  Hosts call `update(mode:music:settings:)` about once a second and whenever the mode or the
//  feed changes; between track changes that only moves the progress bar and the times.
//  Track changes cross-fade (the corner's artwork flips); Reduce Motion keeps only fades.
//  Main thread only.

import AppKit
import QuartzCore

final class MusicOverlayLayer: CALayer {
    struct Insets: Equatable {
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    }

    enum Mode: Equatable {
        case hidden
        /// Full Screen music, or a legacy Now Playing style's foreground (its Layout / Show
        /// Album / Show Progress params).
        case full(MusicSceneOptions)
        /// Corner music over any style.
        case card(MusicSpec.Corner)
    }

    /// Screen areas to keep the type clear of, in points (menu bar and Dock on the wallpaper).
    /// Album is centred with margins wider than both; Stage centres its block in the area
    /// between them; the Cover type and the corner move off them.
    var safeInsets = Insets() { didSet { if safeInsets != oldValue { setNeedsLayout() } } }
    /// The camera housing's band at the top of a notched built-in display, in points (its
    /// safe-area top; 0 = no notch, or not a full-screen host). A top corner keeps out of it
    /// and out of the top 3 % of such a screen. MusicOverlayView sets it.
    var notch: CGFloat = 0 { didSet { if notch != oldValue { groupKey = nil; setNeedsLayout() } } }
    /// Accessibility Reduce Motion: no flips, no scaling, no marquee — fades only (a title too
    /// long to scroll takes a third line instead).
    var reduceMotion = MusicOverlayLayer.systemReduceMotion {
        didSet { if reduceMotion != oldValue { groupKey = nil; setNeedsLayout() } }
    }
    static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Continuous decoration: the progress bar gliding between ticks and the marquee of a line
    /// too long to fit. It keeps WindowServer compositing every refresh, so the live wallpaper
    /// turns it off (progress steps once a second, a long title takes a third line instead) —
    /// as do stills (thumbnails); the screensaver keeps it.
    var ambientMotion = true {
        didSet { if ambientMotion != oldValue { groupKey = nil; setNeedsLayout() } }
    }
    /// Tools only: draw every marquee posed at this fraction of its travel (0 = resting at its
    /// start, 1 = at its end) as a still bitmap — a faithful frame of the live layer, which
    /// `render(in:)` can't capture (it ignores masks and animations). nil = live.
    static var stillMarqueePose: CGFloat?

    /// Tools: where the text and artwork landed (top-left points): "text" = a block's ink box,
    /// "marquee" = a scrolling line's viewport, "art", and "block" = the corner's whole block.
    var debugRects: [(kind: String, rect: CGRect)] { group?.debugRects ?? [] }
    /// A miniature of a real screen (the app's Screensaver hero, its still): the corner keeps
    /// its true share of the screen instead of the legibility floor a small preview of the
    /// saver itself gets (System Settings' thumbnail). Set before the first update.
    var trueScale = false { didSet { if trueScale != oldValue { groupKey = nil; setNeedsLayout() } } }

    /// Continuous decoration never needs the panel's full rate: at most 30 Hz, so a ProMotion
    /// display doesn't recomposite the overlay at 120 Hz over a 30 fps Metal background.
    static let decorationRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
    /// Full Screen fades in step with the renderer's backdrop (MetalRenderer.musicBackdropSeconds),
    /// choreographed so the type never ghosts over a still-sharp style: in, the foreground
    /// starts `fullFadeInDelay` after the backdrop and lands with it; out, it is gone in
    /// `fullFadeOutSeconds`, before the backdrop has cleared.
    static let fullFadeSeconds = MetalRenderer.musicBackdropSeconds
    static let fullFadeInDelay: Double = 0.35
    static let fullFadeOutSeconds: Double = 0.9

    /// The foreground's opacity `t` seconds into a full-screen fade in (0…1) — CA's
    /// ease-in-ease-out after the delay. Tools use it to draw frames of the transition.
    static func fullFadeInOpacity(at t: Double) -> Double {
        let k = min(max((t - fullFadeInDelay) / (fullFadeSeconds - fullFadeInDelay), 0), 1)
        return easeInEaseOut(k)
    }

    /// CAMediaTimingFunction(name: .easeInEaseOut) — cubic-bezier(0.42, 0, 0.58, 1) — at `k`.
    static func easeInEaseOut(_ k: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<32 {                                   // solve x(s) = k
            let s = (lo + hi) / 2
            let x = 3 * (1 - s) * (1 - s) * s * 0.42 + 3 * (1 - s) * s * s * 0.58 + s * s * s
            if x < k { lo = s } else { hi = s }
        }
        let s = (lo + hi) / 2
        return 3 * (1 - s) * s * s + s * s * s
    }

    private(set) var mode: Mode = .hidden
    private var music = MusicSnapshot.empty
    private var settings = MusicSpec()
    private var group: MusicOverlayGroup?
    private var groupKey: GroupKey?

    /// True while something is on screen (hosts may stop ticking when false).
    var isShowing: Bool { group != nil }

    override init() {
        super.init()
        masksToBounds = false
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Never animate the overlay's own geometry (window resizes, scale changes).
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// - animated: false for one-off renders (thumbnails) — no transitions.
    func update(mode: Mode, music: MusicSnapshot, settings: MusicSpec, now: Date = Date(), animated: Bool = true) {
        self.mode = mode
        self.music = music
        self.settings = settings
        refresh(now: now, animated: animated)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        refresh(now: Date(), animated: false)
    }

    // MARK: Resolve + transitions

    /// Something shows only while music is visible, in every mode.
    private func resolve(now: Date) -> MusicDisplay? {
        guard mode != .hidden, music.isVisible(settings: settings, at: now) else { return nil }
        return MusicDisplay(mode: mode, music: music)
    }

    private func refresh(now: Date, animated: Bool) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let display = resolve(now: now)
        let cardSize = settings.cardSizePreference
        let key = display.map { GroupKey($0, size: bounds.size, scale: contentsScale, insets: safeInsets,
                                         cardSize: cardSize) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if key == groupKey, let g = group, let d = display {
            g.tick(d, now: now, animated: animated)
            return
        }
        let old = group, oldKey = groupKey
        group = nil
        groupKey = key
        // An unanimated update also drops groups still fading out from earlier changes.
        if !animated {
            for l in sublayers ?? [] where l !== old { l.removeFromSuperlayer() }
        }
        if let d = display, let key {
            let g = MusicOverlayGroup(d, bounds: bounds, insets: safeInsets, scale: contentsScale,
                                      reduceMotion: reduceMotion, ambient: ambientMotion, cardSize: cardSize,
                                      trueScale: trueScale, notch: notch)
            g.tick(d, now: now, animated: false)
            addSublayer(g)
            group = g
            if animated, let oldKey { animateIn(g, from: oldKey, to: key) }
            else if animated { g.appear(reduceMotion: reduceMotion) }
        }
        guard let old else { return }
        let structural = oldKey?.size != key?.size || oldKey?.scale != key?.scale || oldKey?.insets != key?.insets
            || oldKey?.cardSize != key?.cardSize
        if animated && !structural {
            old.disappear(trackChange: key.map { oldKey?.isTrackChange(to: $0) ?? false } ?? false,
                          reduceMotion: reduceMotion)
        } else {
            old.removeFromSuperlayer()
        }
    }

    private func animateIn(_ g: MusicOverlayGroup, from old: GroupKey, to new: GroupKey) {
        if old.isTrackChange(to: new) {
            g.arriveAsNewTrack(reduceMotion: reduceMotion)
        } else {
            g.appear(reduceMotion: reduceMotion)
        }
    }

    /// What forces a rebuild (anything else updates in place).
    private struct GroupKey: Equatable {
        var mode: Mode
        var track: String
        var art: ObjectIdentifier?
        var size: CGSize
        var scale: CGFloat
        var insets: Insets
        /// Corner only (nil otherwise, so a size change never rebuilds a full layout).
        var cardSize: MusicSpec.CardSize?

        init(_ d: MusicDisplay, size: CGSize, scale: CGFloat, insets: Insets, cardSize: MusicSpec.CardSize) {
            mode = d.mode; track = d.trackKey
            art = d.art.map { ObjectIdentifier($0) }
            self.size = size; self.scale = scale; self.insets = insets
            if case .card = d.mode { self.cardSize = cardSize }
        }

        /// Same place, same mode, a different song (or new artwork for it).
        func isTrackChange(to n: GroupKey) -> Bool {
            mode == n.mode && (track != n.track || art != n.art) && size == n.size && scale == n.scale
        }
    }
}

// MARK: - What to show

/// The overlay's resolved content for one moment.
struct MusicDisplay {
    var mode: MusicOverlayLayer.Mode
    var state: MusicState?
    var art: CGImage?
    var palette: [RGBA]
    var title: String
    var artist: String
    var album: String
    var playing: Bool

    init(mode: MusicOverlayLayer.Mode, music: MusicSnapshot) {
        self.mode = mode
        state = music.state
        art = music.artwork
        palette = music.palette
        title = state?.title ?? ""
        artist = state?.artist ?? ""
        album = state?.album ?? ""
        playing = state?.isPlaying ?? false
    }

    var trackKey: String { state?.trackID ?? "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// A stream (no duration) has no bar.
    var hasDuration: Bool { (state?.duration ?? 0) > 0 }
}

// MARK: - One arrangement on screen

/// Every layer of one arrangement (mode + track + size). Rebuilt on structural changes,
/// ticked in place otherwise. Coordinates: layout is computed top-left (y down) and placed
/// into Core Animation's bottom-left space by `place`.
private final class MusicOverlayGroup: CALayer {
    private let W: CGFloat, H: CGFloat, u: CGFloat
    private let scale: CGFloat
    private let reduceMotion: Bool
    private let ambient: Bool
    private let mode: MusicOverlayLayer.Mode

    private var artFace: CALayer?
    private var fill: CALayer?
    private var barRect: CGRect = .zero
    private var timeStyle: MusicTextStyle?
    private var elapsedLayer: CALayer?
    private var remainingLayer: CALayer?
    private var timesTop: CGFloat = 0
    /// The paused indicator and where it goes: after the elapsed time, or at a fixed spot.
    private var pauseGlyph: MusicPauseGlyph?
    private var glyphFollowsElapsed = false
    private var elapsedWidth: CGFloat = 0
    private var lastSecond = Int.min
    private var lastPlaying: Bool?
    private var lastFill: CGFloat = -1
    private let display: MusicDisplay
    private let notch: CGFloat
    /// Where the text and artwork landed (MusicOverlayLayer.debugRects).
    private(set) var debugRects: [(kind: String, rect: CGRect)] = []

    /// A line too long for its column scrolls (a marquee) only with motion allowed; otherwise
    /// it takes one more line (MusicText.fit).
    private var marquee: Bool { !reduceMotion && ambient }

    init(_ d: MusicDisplay, bounds: CGRect, insets: MusicOverlayLayer.Insets, scale: CGFloat, reduceMotion: Bool,
         ambient: Bool, cardSize: MusicSpec.CardSize = .medium, trueScale: Bool = false, notch: CGFloat = 0) {
        self.ambient = ambient
        self.notch = notch
        W = bounds.width; H = bounds.height
        u = MusicGeometry.unit(bounds.size)
        self.scale = scale
        self.reduceMotion = reduceMotion
        mode = d.mode
        display = d
        super.init()
        frame = bounds
        contentsScale = scale
        switch d.mode {
        case .full(let o):
            switch o.layout {
            case .album: buildAlbum(d, o)
            case .stage: buildStage(d, o, insets)
            case .cover: buildCover(d, o, insets)
            }
        case .card(let corner):
            buildCorner(d, corner, insets, size: cardSize, trueScale: trueScale)
        case .hidden:
            break
        }
    }

    override init(layer: Any) {
        let g = layer as? MusicOverlayGroup
        W = g?.W ?? 0; H = g?.H ?? 0; u = g?.u ?? 1; scale = g?.scale ?? 2
        reduceMotion = g?.reduceMotion ?? false; ambient = g?.ambient ?? false; mode = g?.mode ?? .hidden
        display = g?.display ?? MusicDisplay(mode: .hidden, music: .empty)
        notch = g?.notch ?? 0
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? { NSNull() }

    private var isFull: Bool { if case .full = mode { return true } else { return false } }

    // MARK: Placement helpers

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    /// Top-left rect → Core Animation frame, snapped to device pixels.
    private func place(_ l: CALayer, _ r: CGRect, in parent: CALayer? = nil) {
        let x = snap(r.minX), y = snap(H - r.maxY)
        l.frame = CGRect(x: x, y: y, width: snap(r.maxX) - x, height: snap(H - r.minY) - y)
        l.contentsScale = scale
        (parent ?? self).addSublayer(l)
    }

    /// Add a fitted block (MusicText.fit) whose box starts at (x, top) in a column `width`
    /// wide; returns its box height (0 when empty). A last line that overflows scrolls.
    @discardableResult
    private func addBlock(_ b: MusicTextBlock, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
        guard !b.isEmpty else { return 0 }
        let n = b.lines.count
        let still = b.overflows ? b.slice(0..<(n - 1)) : b
        if !still.isEmpty, let l = textLayer(still, x: x, top: top, width: width) {
            addSublayer(l)
            let inkW = still.lineWidths.max() ?? 0
            let ix = still.style.alignment == .center ? x + (width - inkW) / 2
                : still.style.alignment == .right ? x + width - inkW : x
            debugRects.append(("text", CGRect(x: ix, y: top, width: inkW, height: still.height)))
        }
        if b.overflows {
            addMarquee(b.slice((n - 1)..<n), x: x, top: top + CGFloat(n - 1) * b.lineStep, width: width)
        }
        return b.height
    }

    // MARK: Marquee

    /// The marquee's timing: it rests `hold` seconds at each end and eases between them at
    /// about `speed` × its size per second — slow enough to read along (2.5…14 s a way).
    private static let marqueeHold: Double = 2.6
    private static let marqueeSpeed: CGFloat = 1.4
    private static let marqueeRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    /// The marquee's mask across its viewport (`vw` wide: the column plus `pad` either side):
    /// gradient stops, and their opacities for a fade on the left `l` and right `r` (0 = hard
    /// edge, 1 = faded) — transparent over the pad, easing in over `fade` inside the column.
    private static func marqueeMask(vw: CGFloat, pad: CGFloat, fade: CGFloat,
                                    l: CGFloat, r: CGFloat) -> (stops: [CGFloat], alphas: [CGFloat]) {
        let a = pad / vw, b = (pad + fade) / vw
        return ([0, a, b, 1 - b, 1 - a, 1], [1 - l, 1 - l, 1, 1, 1 - r, 1 - r])
    }

    /// A line wider than its column, scrolled: it rests at its start (lined up with the lines
    /// above), eases to its end, rests, and eases back — forever, gently, never stepping. The
    /// edge it is scrolling past fades softly; at rest the edge where the line begins or ends
    /// is crisp. In a still it rests at its start (or at MusicOverlayLayer.stillMarqueePose).
    private func addMarquee(_ b: MusicTextBlock, x: CGFloat, top: CGFloat, width: CGFloat) {
        let lineW = ceil(b.lineWidths.first ?? 0)
        guard lineW > 0 else { return }
        let pad = MusicText.pad(b.style)
        let fade = min(b.style.size * 1.2, width * 0.18)
        let d = snap(max(lineW - width, 0))                 // how far it travels
        let view = CGRect(x: x - pad, y: top - pad, width: width + pad * 2, height: b.height + pad * 2)
        debugRects.append(("marquee", CGRect(x: x, y: top, width: width, height: b.height)))
        let vw = snap(view.maxX) - snap(view.minX)
        func ends(_ p: CGFloat) -> (l: CGFloat, r: CGFloat) { d > 0 ? (p > 0 ? 1 : 0, p < 1 ? 1 : 0) : (0, 0) }

        if let pose = MusicOverlayLayer.stillMarqueePose {
            // A still: the frame the live layer shows at this point of its travel, baked.
            let p = min(max(pose, 0), 1)
            let e = ends(p)
            let mask = Self.marqueeMask(vw: vw, pad: pad, fade: fade, l: e.l, r: e.r)
            guard let img = MusicText.marqueeFrame(b, viewport: vw, offset: snap(d * p), stops: mask.stops,
                                                   alphas: mask.alphas, scale: scale) else { return }
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resize
            place(l, CGRect(x: view.minX, y: view.minY, width: vw, height: CGFloat(img.height) / scale))
            return
        }

        guard let img = MusicText.image(b, boxWidth: lineW, scale: scale) else { return }
        let imgW = CGFloat(img.width) / scale, imgH = CGFloat(img.height) / scale
        let clip = CALayer()
        place(clip, CGRect(x: view.minX, y: view.minY, width: vw, height: imgH))
        let text = CALayer()
        text.contents = img
        text.contentsGravity = .resize
        text.contentsScale = scale
        text.anchorPoint = .zero
        text.bounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
        text.position = .zero                               // ink starts at the column's edge
        clip.addSublayer(text)
        let mask = CAGradientLayer()
        mask.frame = clip.bounds
        mask.contentsScale = scale
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        func colors(_ l: CGFloat, _ r: CGFloat) -> [CGColor] {
            Self.marqueeMask(vw: vw, pad: pad, fade: fade, l: l, r: r).alphas.map { CGColor(gray: 0, alpha: $0) }
        }
        let rest = Self.marqueeMask(vw: vw, pad: pad, fade: fade, l: 0, r: 1)
        mask.locations = rest.stops.map { NSNumber(value: Double($0)) }
        mask.colors = colors(ends(0).l, ends(0).r)
        clip.mask = mask
        guard d > 0 else { return }

        // Rest · ease to the end · rest · ease back. The fade on the edge being scrolled past
        // comes in over the first part of a move (the ease is slow there) and leaves over its last.
        let hold = Self.marqueeHold
        let travel = min(max(Double(d / (b.style.size * Self.marqueeSpeed)), 2.5), 14)
        let T = 2 * hold + 2 * travel, ramp = travel * 0.18
        let ease = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        let linear = CAMediaTimingFunction(name: .linear)
        func k(_ t: Double) -> NSNumber { NSNumber(value: t / T) }
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [0, 0, -d, -d, 0]
        move.keyTimes = [0, k(hold), k(hold + travel), k(2 * hold + travel), 1]
        move.timingFunctions = [linear, ease, linear, ease]
        let edges = CAKeyframeAnimation(keyPath: "colors")
        let s = colors(0, 1), mid = colors(1, 1), e = colors(1, 0)
        edges.values = [s, s, mid, mid, e, e, mid, mid, s]
        edges.keyTimes = [0, k(hold), k(hold + ramp), k(hold + travel - ramp), k(hold + travel),
                          k(2 * hold + travel), k(2 * hold + travel + ramp), k(2 * hold + 2 * travel - ramp), 1]
        for a in [move, edges] as [CAKeyframeAnimation] {
            a.duration = T
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            a.preferredFrameRateRange = Self.marqueeRate
        }
        text.add(move, forKey: "marquee")
        mask.add(edges, forKey: "marquee")
    }

    private func textLayer(_ b: MusicTextBlock, x: CGFloat, top: CGFloat, width: CGFloat) -> CALayer? {
        guard !b.isEmpty else { return nil }
        let box = b.style.alignment == .left || b.style.alignment == .right ? ceil(b.width) : width
        guard let img = MusicText.image(b, boxWidth: box, scale: scale) else { return nil }
        let pad = MusicText.pad(b.style)
        let bx = b.style.alignment == .right ? x + width - box : x
        let l = CALayer()
        l.contents = img
        l.contentsGravity = .resize
        // Pixel-exact: the bitmap was rendered at this size, so no resampling blur.
        let r = CGRect(x: bx - pad, y: top - pad, width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        let ox = snap(r.minX), oy = snap(H - r.maxY)
        l.frame = CGRect(x: ox, y: oy, width: r.width, height: r.height)
        l.contentsScale = scale
        return l
    }

    private func measure(_ s: String, _ style: MusicTextStyle, width: CGFloat) -> MusicTextBlock {
        MusicText.layout(s, style, width: width)
    }

    private static let white = { (a: CGFloat) in CGColor(gray: 1, alpha: a) }

    // MARK: Type

    /// The type of one layout. Titles are Medium (a Display cut at these sizes, with slightly
    /// tighter tracking), Semibold only where a corner title gets small; the artist is
    /// Regular; album and times Regular at reduced opacity. Nothing Bold.
    private struct TypeSet {
        var title: MusicTextStyle
        var artist: MusicTextStyle
        var album: MusicTextStyle
        var time: MusicTextStyle
    }

    private func typeSet(title: CGFloat, artist: CGFloat, album: CGFloat, time: CGFloat,
                         align: CTTextAlignment, titleLines: Int) -> TypeSet {
        let t = MusicTextStyle(size: title, weight: title < 20 ? .semibold : .medium, color: Self.white(0.98),
                               tracking: title >= 28 ? -0.010 : -0.004, maxLines: titleLines, alignment: align,
                               leading: 1.10)
        let ar = MusicTextStyle(size: artist, weight: .regular, color: Self.white(0.82), tracking: -0.002,
                                maxLines: 1, alignment: align)
        let al = MusicTextStyle(size: album, weight: .regular, color: Self.white(0.64), maxLines: 1, alignment: align)
        let tm = MusicTextStyle(size: time, weight: .regular, color: Self.white(0.64), monospacedDigits: true)
        return TypeSet(title: t, artist: ar, album: al, time: tm)
    }

    // MARK: Artwork

    /// Artwork (or a placeholder) at `r`, with a soft two-layer shadow (a faint contact shadow
    /// and a wide, low one); `radius` as a fraction of the side.
    private func addArt(_ d: MusicDisplay, _ r: CGRect, radius: CGFloat, shadow: CGFloat) {
        let side = min(r.width, r.height)
        let holder = CALayer()
        place(holder, r)
        // Perspective for the flip lives on the holder, so it vanishes at the art's centre.
        var p = CATransform3DIdentity
        p.m34 = -1 / (side * 3.2)
        holder.sublayerTransform = p

        let face = CALayer()
        face.frame = holder.bounds
        face.contentsScale = scale
        let path = CGPath(roundedRect: face.bounds, cornerWidth: side * radius, cornerHeight: side * radius, transform: nil)
        if shadow > 0 {
            // Wide and soft, on the face itself…
            face.shadowPath = path
            face.shadowColor = CGColor(gray: 0, alpha: 1)
            face.shadowOpacity = Float(0.30 * shadow)
            face.shadowRadius = side * 0.11 * shadow
            face.shadowOffset = CGSize(width: 0, height: -side * 0.035 * shadow)
            // …and a faint contact shadow just under the edge.
            let contact = CALayer()
            contact.frame = face.bounds
            contact.shadowPath = path
            contact.shadowColor = CGColor(gray: 0, alpha: 1)
            contact.shadowOpacity = Float(0.22 * shadow)
            contact.shadowRadius = max(side * 0.018, 1)
            contact.shadowOffset = CGSize(width: 0, height: -max(side * 0.008, 0.5))
            face.addSublayer(contact)
        }
        holder.addSublayer(face)

        let img = CALayer()
        img.frame = face.bounds
        img.contentsScale = scale
        img.cornerRadius = side * radius
        img.cornerCurve = .continuous
        img.masksToBounds = true
        img.contentsGravity = .resizeAspectFill
        img.borderWidth = 1 / scale
        img.borderColor = Self.white(0.08)
        let px = Int((side * scale).rounded())
        if let art = d.art {
            img.contents = MusicArtwork.scaled(art, side: px)
        } else {
            img.contents = MusicArtwork.placeholder(side: px, palette: d.palette, idle: false)
        }
        face.addSublayer(img)
        artFace = face
    }

    // MARK: Progress + paused

    /// The bar (and, with `timesTop`, the elapsed / remaining times under it).
    private func addProgress(_ d: MusicDisplay, bar: CGRect, timesTop: CGFloat?, time: MusicTextStyle?,
                             trackAlpha: CGFloat = 0.20) {
        guard d.hasDuration else { return }
        barRect = bar
        let track = CALayer()
        track.backgroundColor = Self.white(trackAlpha)
        track.cornerRadius = bar.height / 2
        place(track, bar)
        let f = CALayer()
        f.backgroundColor = Self.white(0.90)
        f.cornerRadius = bar.height / 2
        f.anchorPoint = CGPoint(x: 0, y: 0.5)
        place(f, bar)
        f.bounds.size.width = 0
        f.position = CGPoint(x: track.frame.minX, y: track.frame.midY)
        fill = f
        if let timesTop, let time {
            self.timesTop = timesTop
            timeStyle = time
        }
    }

    /// The paused glyph, `h` tall: after the elapsed time (`followsElapsed`, re-placed as the
    /// time changes), else with its top-left at `at`.
    private func addPauseGlyph(height h: CGFloat, color: CGColor, at: CGPoint, followsElapsed: Bool) {
        let g = MusicPauseGlyph(height: h, color: color, scale: scale)
        g.opacity = 0
        pauseGlyph = g
        glyphFollowsElapsed = followsElapsed
        let ox = snap(at.x), oy = snap(H - at.y - h)
        g.frame = CGRect(x: ox, y: oy, width: g.bounds.width, height: h)
        addSublayer(g)
    }

    /// Next to the elapsed time: on its cap height, a space after it.
    private func placeGlyphAfterElapsed() {
        guard glyphFollowsElapsed, let g = pauseGlyph, let style = timeStyle else { return }
        let f = MusicText.font(style)
        let baseline = timesTop + CTFontGetAscent(f)
        let h = g.bounds.height
        let x = barRect.minX + elapsedWidth + style.size * 0.55
        g.frame = CGRect(x: snap(x), y: snap(H - baseline), width: g.bounds.width, height: h)
    }

    private func updateTimes(_ d: MusicDisplay, now: Date) {
        guard let st = d.state, let style = timeStyle else { return }
        // An estimated position (Apple Music without Automation: counted from when the track
        // was seen) keeps the bar as a rough guide but never claims to-the-second times.
        if st.positionIsApproximate == true {
            elapsedLayer?.removeFromSuperlayer(); remainingLayer?.removeFromSuperlayer()
            elapsedLayer = nil; remainingLayer = nil
            lastSecond = Int.min
            elapsedWidth = -style.size * 0.55          // the glyph starts the row
            placeGlyphAfterElapsed()
            return
        }
        let e = st.elapsed(at: now)
        let sec = Int(e)
        guard sec != lastSecond else { return }
        lastSecond = sec
        let elapsed = MusicState.timeString(e)
        let remaining = "−" + MusicState.timeString(max((st.duration ?? 0) - Double(sec), 0))
        elapsedLayer?.removeFromSuperlayer(); remainingLayer?.removeFromSuperlayer()
        var l = style; l.alignment = .left
        var r = style; r.alignment = .right
        let eb = measure(elapsed, l, width: barRect.width)
        elapsedWidth = ceil(eb.width)
        elapsedLayer = textLayer(eb, x: barRect.minX, top: timesTop, width: barRect.width)
        remainingLayer = textLayer(measure(remaining, r, width: barRect.width), x: barRect.minX,
                                   top: timesTop, width: barRect.width)
        if let l = elapsedLayer { addSublayer(l) }
        if let l = remainingLayer { addSublayer(l) }
        placeGlyphAfterElapsed()
    }

    // MARK: Tick (in place, about once a second)

    func tick(_ d: MusicDisplay, now: Date, animated: Bool) {
        if d.playing != lastPlaying {
            let first = lastPlaying == nil
            lastPlaying = d.playing
            setPaused(!d.playing, animated: animated && !first)
        }
        if let fill, let st = d.state, let p = st.progress(at: now) {
            let w = (barRect.width * CGFloat(p) * scale).rounded() / scale
            if w != lastFill {
                // Glide between ticks while playing; jump on seeks and first show.
                let glide = animated && ambient && d.playing && lastFill >= 0 && abs(w - lastFill) < barRect.width * 0.05
                if glide {
                    let a = CABasicAnimation(keyPath: "bounds.size.width")
                    a.fromValue = fill.presentation()?.bounds.width ?? lastFill
                    a.toValue = w
                    a.duration = 1.0
                    a.timingFunction = CAMediaTimingFunction(name: .linear)
                    a.preferredFrameRateRange = MusicOverlayLayer.decorationRate
                    fill.add(a, forKey: "glide")
                }
                fill.bounds.size.width = w
                lastFill = w
            }
            updateTimes(d, now: now)
        }
    }

    /// Paused: the bar dims, the pause glyph fades in, and the big artwork settles back a
    /// little, like Apple Music.
    private func setPaused(_ paused: Bool, animated: Bool) {
        func fade(_ l: CALayer?, to v: Float) {
            guard let l else { return }
            let from = l.presentation()?.opacity ?? l.opacity
            l.opacity = v
            guard animated, from != v else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from; a.toValue = v
            a.duration = 0.35
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "paused")
        }
        fade(fill, to: paused ? 0.42 : 1)
        fade(pauseGlyph, to: paused ? 1 : 0)
        guard let face = artFace, case .full(let o) = mode, o.layout != .cover else { return }
        let target: CGFloat = (paused && !reduceMotion) ? 0.93 : 1.0
        let from = (face.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat)
            ?? (face.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? 1
        face.setValue(target, forKeyPath: "transform.scale")
        guard animated, from != target else { return }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = from
        a.toValue = target
        a.damping = 22; a.stiffness = 170; a.mass = 1
        a.duration = a.settlingDuration
        face.add(a, forKey: "pause")
    }

    // MARK: Transitions

    func appear(reduceMotion: Bool) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1
        if isFull {
            // In step with the backdrop easing in behind it: starts once it has softened.
            a.beginTime = CACurrentMediaTime() + MusicOverlayLayer.fullFadeInDelay
            a.fillMode = .backwards
            a.duration = MusicOverlayLayer.fullFadeSeconds - MusicOverlayLayer.fullFadeInDelay
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            a.duration = 0.8
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        add(a, forKey: "in")
        if case .card = mode, !reduceMotion {
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.fromValue = 0.97; s.toValue = 1
            s.damping = 20; s.stiffness = 160
            s.duration = s.settlingDuration
            add(s, forKey: "inScale")
        }
    }

    func arriveAsNewTrack(reduceMotion: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = 0.55
        fade.beginTime = CACurrentMediaTime() + 0.18
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(fade, forKey: "in")
        guard !reduceMotion, let face = artFace else { return }
        if case .card = mode {
            // NotchTune-style flip: the new cover swings in from edge-on.
            let flip = CABasicAnimation(keyPath: "transform.rotation.y")
            flip.fromValue = -CGFloat.pi / 2; flip.toValue = 0
            flip.duration = 0.32
            flip.beginTime = CACurrentMediaTime() + 0.22
            flip.fillMode = .backwards
            flip.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            face.add(flip, forKey: "flip")
        } else {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 0.965; s.toValue = 1
            s.duration = 0.8
            s.beginTime = CACurrentMediaTime() + 0.18
            s.fillMode = .backwards
            s.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            face.add(s, forKey: "arrive")
        }
    }

    /// Fade out (flip the old cover away on a corner track change), then remove.
    func disappear(trackChange: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperlayer() }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = presentation()?.opacity ?? 1
        a.toValue = 0
        if trackChange {
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        } else if isFull {
            // Gone before the backdrop clears, so no type hangs over the returning style.
            a.duration = MusicOverlayLayer.fullFadeOutSeconds
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            a.duration = 0.7
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        opacity = 0
        add(a, forKey: "out")
        if trackChange, !reduceMotion, case .card = mode, let face = artFace {
            let flip = CABasicAnimation(keyPath: "transform.rotation.y")
            flip.fromValue = 0; flip.toValue = CGFloat.pi / 2
            flip.duration = 0.22
            flip.fillMode = .forwards
            flip.isRemovedOnCompletion = false
            flip.timingFunction = CAMediaTimingFunction(name: .easeIn)
            face.add(flip, forKey: "flip")
        }
        if case .card = mode, !trackChange, !reduceMotion {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1; s.toValue = 0.98
            s.duration = 0.7
            s.fillMode = .forwards
            s.isRemovedOnCompletion = false
            add(s, forKey: "outScale")
        }
        CATransaction.commit()
    }

    // MARK: Layouts

    /// The pause glyph's height for a line of `size`: about its cap height.
    private static func glyphHeight(_ size: CGFloat) -> CGFloat { size * 0.70 }

    /// Title, artist and album set by MusicText.fit (never cut off): up to two lines each,
    /// balanced, smaller down to 85 % if they must be, then a marquee (or a third line). The
    /// secondary lines never outgrow a title that had to shrink. `squeeze` scales all three
    /// (a layout short of height) without changing their weights.
    private func fitType(_ d: MusicDisplay, _ ts: TypeSet, column c: CGFloat, album: Bool,
                         squeeze: CGFloat = 1) -> (title: MusicTextBlock, artist: MusicTextBlock, album: MusicTextBlock?) {
        var t = ts.title, a = ts.artist, l = ts.album
        t.size *= squeeze; a.size *= squeeze; l.size *= squeeze
        let tb = MusicText.fit(d.title, t, column: c, lines: 2, marquee: marquee)
        let k = t.size > 0 ? tb.style.size / t.size : 1
        let ab = MusicText.fit(d.artist, a, column: c, lines: 2, maxScale: k, marquee: marquee)
        let lb = album ? MusicText.fit(d.album, l, column: c, lines: 2, maxScale: k, marquee: marquee) : nil
        return (tb, ab, lb)
    }

    /// Apple Music full screen: artwork left, type right, the group centred on the art.
    private func buildAlbum(_ d: MusicDisplay, _ o: MusicSceneOptions) {
        let art = MusicGeometry.artRect(.album, size: CGSize(width: W, height: H))
        addArt(d, art, radius: 0.028, shadow: 1)
        debugRects.append(("art", art))
        let x = art.maxX + MusicGeometry.albumGap * u
        let colW = max(min(MusicGeometry.albumText * u, W - x - 0.06 * u), 40)
        // Sized for the far side of a room: the title's cap height is ≈ 4.5 % of a 16:10
        // screen's height (0.064 u); every other line in step with it.
        let ts = typeSet(title: 0.064 * u, artist: 0.040 * u, album: 0.030 * u, time: 0.0195 * u,
                         align: .left, titleLines: 2)
        let barH = max(0.0062 * u, 3)
        let showBar = o.showProgress && d.hasDuration
        let rowGap = 0.054 * u
        let margin = 0.05 * u
        // Measure, then centre the whole column on the artwork — within the screen's margins,
        // with smaller type only if a Reduce Motion third line would otherwise leave them.
        var squeeze: CGFloat = 1
        var fitted = fitType(d, ts, column: colW, album: o.showAlbum)
        var h: CGFloat = 0
        while true {
            let (tb, ab, lb) = fitted
            h = tb.height
            if !ab.isEmpty { h += 0.018 * u + ab.height }
            if let lb, !lb.isEmpty { h += 0.010 * u + lb.height }
            if showBar { h += rowGap + barH + 0.017 * u + ts.time.size * MusicGeometry.lineBox }
            else { h += rowGap + Self.glyphHeight(ts.time.size) }
            if h <= H - 2 * margin || squeeze <= 0.7 { break }
            squeeze -= 0.05
            fitted = fitType(d, ts, column: colW, album: o.showAlbum, squeeze: squeeze)
        }
        let (tb, ab, lb) = fitted
        var y = max(art.midY - h / 2, art.minY)
        y = max(min(y, H - margin - h), margin)
        y += addBlock(tb, x: x, top: y, width: colW)
        if !ab.isEmpty { y += 0.018 * u; y += addBlock(ab, x: x, top: y, width: colW) }
        if let lb, !lb.isEmpty { y += 0.010 * u; y += addBlock(lb, x: x, top: y, width: colW) }
        y += rowGap
        let glyphH = Self.glyphHeight(ts.time.size)
        if showBar {
            let barW = min(colW, MusicGeometry.albumArt * u)
            addProgress(d, bar: CGRect(x: x, y: y, width: barW, height: barH),
                        timesTop: y + barH + 0.017 * u, time: ts.time)
            addPauseGlyph(height: glyphH, color: ts.time.color, at: CGPoint(x: x, y: y + barH + 0.017 * u),
                          followsElapsed: true)
        } else {
            addPauseGlyph(height: glyphH, color: ts.time.color, at: CGPoint(x: x, y: y), followsElapsed: false)
        }
    }

    /// Spotify TV: artwork centred, type centred below. The block (sized for a two-line
    /// title — MusicGeometry.stageBlock) is centred between the menu bar and the Dock; the
    /// artwork never moves for the text, so text that needs more room than that block (a
    /// wrapped artist or album, a Reduce Motion third line) gets slightly smaller type
    /// rather than leave the screen.
    private func buildStage(_ d: MusicDisplay, _ o: MusicSceneOptions, _ insets: MusicOverlayLayer.Insets) {
        typealias S = MusicGeometry.Stage
        let art = MusicGeometry.artRect(.stage, size: CGSize(width: W, height: H), options: o,
                                        insets: (insets.top, insets.bottom))
        addArt(d, art, radius: 0.024, shadow: 1)
        debugRects.append(("art", art))
        let colW = min(W - 0.16 * u - insets.left - insets.right, 1.3 * u)
        let x = insets.left + (W - insets.left - insets.right - colW) / 2
        let ts = typeSet(title: S.title * u, artist: S.artist * u, album: S.album * u, time: S.times * u,
                         align: .center, titleLines: S.titleLines)
        let barH = max(S.bar * u, 3)
        let glyphH = Self.glyphHeight(ts.time.size)
        let showBar = o.showProgress && d.hasDuration
        let room = H - insets.bottom - 0.03 * u - (art.maxY + S.artGap * u)
        var squeeze: CGFloat = 1
        var fitted = fitType(d, ts, column: colW, album: o.showAlbum)
        while true {
            let (tb, ab, lb) = fitted
            var h = tb.height
            if !ab.isEmpty { h += S.artistGap * u + ab.height }
            if let lb, !lb.isEmpty { h += S.albumGap * u + lb.height }
            h += S.barGap * u + (showBar ? barH + S.timesGap * u + ts.time.size * MusicGeometry.lineBox : glyphH)
            if h <= room || squeeze <= 0.7 { break }
            squeeze -= 0.05
            fitted = fitType(d, ts, column: colW, album: o.showAlbum, squeeze: squeeze)
        }
        let (tb, ab, lb) = fitted
        var y = art.maxY + S.artGap * u
        y += addBlock(tb, x: x, top: y, width: colW)
        if !ab.isEmpty { y += S.artistGap * u; y += addBlock(ab, x: x, top: y, width: colW) }
        if let lb, !lb.isEmpty { y += S.albumGap * u; y += addBlock(lb, x: x, top: y, width: colW) }
        if showBar {
            y += S.barGap * u
            let bar = CGRect(x: art.minX, y: y, width: art.width, height: barH)
            addProgress(d, bar: bar, timesTop: y + barH + S.timesGap * u, time: ts.time)
            addPauseGlyph(height: glyphH, color: ts.time.color, at: CGPoint(x: bar.minX, y: y + barH + S.timesGap * u),
                          followsElapsed: true)
        } else {
            addPauseGlyph(height: glyphH, color: ts.time.color,
                          at: CGPoint(x: (W - glyphH) / 2, y: y + S.barGap * u), followsElapsed: false)
        }
    }

    /// Full-bleed artwork (the shader), type bottom-left over its scrim (Full Screen's Cover
    /// layout, and legacy Cover styles).
    private func buildCover(_ d: MusicDisplay, _ o: MusicSceneOptions, _ insets: MusicOverlayLayer.Insets) {
        let m = 0.072 * u
        let left = m + insets.left
        let bottom = H - m - insets.bottom
        let colW = max(min(1.05 * u, W - left - m - insets.right), 40)
        var ts = typeSet(title: 0.080 * u, artist: 0.040 * u, album: 0.028 * u, time: 0.0172 * u,
                         align: .left, titleLines: 2)
        // Over full-bleed art the secondary lines need more weight than over the calm Album /
        // Stage backgrounds (the shader's scrim targets ≥ 7:1 for the title; these keep ≥ 4.5:1).
        ts.artist.color = Self.white(0.86); ts.album.color = Self.white(0.70); ts.time.color = Self.white(0.72)
        let (tb, ab, lb) = fitType(d, ts, column: colW, album: o.showAlbum)
        // Bottom-up: times, bar, album, artist, title.
        var y = bottom
        let showBar = o.showProgress && d.hasDuration
        let glyphH = Self.glyphHeight(ts.time.size)
        if showBar {
            let barH = max(0.0062 * u, 3)
            y -= ts.time.size * 1.2
            let timesTop = y
            y -= 0.016 * u + barH
            addProgress(d, bar: CGRect(x: left, y: y, width: min(0.56 * u, colW), height: barH),
                        timesTop: timesTop, time: ts.time, trackAlpha: 0.26)
            addPauseGlyph(height: glyphH, color: ts.time.color, at: CGPoint(x: left, y: timesTop), followsElapsed: true)
            y -= 0.050 * u
        } else {
            y -= glyphH
            addPauseGlyph(height: glyphH, color: ts.time.color, at: CGPoint(x: left, y: y), followsElapsed: false)
            y -= 0.040 * u
        }
        if let lb, !lb.isEmpty { y -= lb.height; addBlock(lb, x: left, top: y, width: colW); y -= 0.010 * u }
        if !ab.isEmpty { y -= ab.height; addBlock(ab, x: left, top: y, width: colW); y -= 0.016 * u }
        y -= tb.height
        addBlock(tb, x: left, top: y, width: colW)
    }

    /// One arrangement of the corner block, measured (planCorner).
    private struct CornerPlan {
        var s: CGFloat, gap: CGFloat
        var column: CGFloat
        var title: MusicTextBlock, artist: MusicTextBlock
        var ts: TypeSet
        var barH: CGFloat, barGap: CGFloat, artistGap: CGFloat
        /// The text's height (title, artist, bar) and width (the bar spans it).
        var textH: CGFloat, textW: CGFloat
        var blockW: CGFloat { s + gap + textW }
    }

    /// The corner block at `squeeze` × its size: the artwork, then a column as narrow as sets
    /// the title and artist in two lines each — widening for long ones up to `Card.grow` × the
    /// size's nominal width (`Card.maxShare` of the screen, inside `maxWidth`) — and in it
    /// MusicText.fit's rules.
    private func planCorner(_ d: MusicDisplay, size: MusicSpec.CardSize, trueScale: Bool, maxWidth: CGFloat,
                            squeeze: CGFloat) -> CornerPlan {
        let g = MusicGeometry.Card.self
        let f = g.size(size)
        let floor = trueScale ? 0 : min(60, 0.2 * u) * f.height / g.size(.medium).height
        let hc0 = max(f.height * u, floor)                    // the block's nominal height
        let hc = hc0 * squeeze
        let s = hc * g.art                                    // artwork side
        let gap = s * g.gap
        let wc = min(hc * f.width / f.height, W * 0.46)       // nominal width
        let wMax = min(wc * g.grow, W * g.maxShare, maxWidth)
        let twMax = max(wMax - s - gap, 20)                   // the widest the column may grow
        let tw = min(max(wc - s - gap, 20), twMax)            // its nominal width
        // Weights from the unsqueezed sizes: squeezing never turns a Medium title Semibold.
        let s0 = hc0 * g.art
        var ts = typeSet(title: s0 * g.title, artist: s0 * g.artist, album: s0 * g.artist, time: s0 * g.artist,
                         align: .left, titleLines: 2)
        ts.title.size *= squeeze; ts.artist.size *= squeeze; ts.album.size *= squeeze; ts.time.size *= squeeze
        let need = [MusicText.neededWidth(d.title, ts.title, lines: 2, min: tw, max: twMax) ?? twMax,
                    MusicText.neededWidth(d.artist, ts.artist, lines: 2, min: tw, max: twMax) ?? twMax]
        let col = min(max(need.max() ?? tw, tw), twMax)
        let (tb, ab, _) = fitType(d, ts, column: col, album: false)
        let barH = max(s * g.bar, 2 / scale)
        let barGap = s * 0.15, artistGap = s * 0.045
        var th = tb.height
        if !ab.isEmpty { th += artistGap + ab.height }
        th += barGap + max(barH, d.hasDuration ? 0 : Self.glyphHeight(ts.artist.size))
        // The block is as wide as what it shows (the bar spans the type), so a short title in a
        // right-hand corner still sits against the margin.
        let textW = min(col, max(ceil(max(tb.width, ab.width)), s * 1.5))
        return CornerPlan(s: s, gap: gap, column: col, title: tb, artist: ab, ts: ts, barH: barH, barGap: barGap,
                          artistGap: artistGap, textH: th, textW: textW)
    }

    /// Corner: rounded artwork with a soft shadow, then title, artist and a thin bar, drawn
    /// straight on the scene over a feathered scrim — no card. Its size follows the screen's
    /// height (MusicGeometry.Card, per size) with no upper cap — a bigger display is read from
    /// further away — and in a small preview of the saver never drops below a legible
    /// minimum, in step with the size so Small / Medium / Large still differ there.
    /// `trueScale` (the app's miniatures) skips the minimum.
    ///
    /// Text is never cut off (owner, 2026-11-09; MusicText.fit): long titles and artists wrap
    /// to two balanced lines in a column that widens for them, then shrink a little, then
    /// scroll. The artwork stays put in its corner whatever the text does — text taller than
    /// the artwork grows away from the screen's edge — and the whole block stays inside the
    /// screen's margins; on a notched display a top corner also clears the camera housing.
    private func buildCorner(_ d: MusicDisplay, _ corner: MusicSpec.Corner, _ insets: MusicOverlayLayer.Insets,
                             size: MusicSpec.CardSize, trueScale: Bool) {
        let g = MusicGeometry.Card.self
        let m = max(g.margin * u, min(20, 0.07 * u))
        // The area the block keeps inside: the margins past the safe insets (menu bar, Dock),
        // and on a notched display, for a top corner, below the camera housing's band (at least
        // the top 3 % of the screen) by half a margin.
        let left = m + insets.left, right = W - m - insets.right
        var top = m + insets.top
        if notch > 0 { top = max(top, max(notch, 0.03 * H) + m * 0.5) }
        let bottom = H - m - insets.bottom
        // Full size unless the screen is too short for what must show (tiny previews only).
        var squeeze: CGFloat = 1
        var p = planCorner(d, size: size, trueScale: trueScale, maxWidth: right - left, squeeze: squeeze)
        while max(p.textH, p.s) > bottom - top && squeeze > 0.5 {
            squeeze -= 0.1
            p = planCorner(d, size: size, trueScale: trueScale, maxWidth: right - left, squeeze: squeeze)
        }
        let isLeft = corner == .bottomLeft || corner == .topLeft
        let isTop = corner == .topLeft || corner == .topRight
        let s = p.s
        let x = isLeft ? left : right - p.blockW
        let artY = isTop ? top : bottom - s
        // Text centred on the artwork; taller than it, it grows away from the screen's edge.
        let ty = p.textH <= s ? artY + (s - p.textH) / 2 : (isTop ? artY : artY + s - p.textH)
        let blockTop = min(artY, ty), blockBottom = max(artY + s, ty + p.textH)
        let block = CGRect(x: x, y: blockTop, width: p.blockW, height: blockBottom - blockTop)
        debugRects.append(("block", block))
        // The scrim first (under everything), around what's actually drawn.
        addScrim(around: block, corner: corner, unit: s)

        let art = CGRect(x: x, y: artY, width: s, height: s)
        addArt(d, art, radius: 0.085, shadow: 0.8)
        debugRects.append(("art", art))
        let tx = x + s + p.gap
        var y = ty
        y += addBlock(p.title, x: tx, top: y, width: p.column)
        if !p.artist.isEmpty { y += p.artistGap; y += addBlock(p.artist, x: tx, top: y, width: p.column) }
        y += p.barGap
        if d.hasDuration {
            addProgress(d, bar: CGRect(x: tx, y: y, width: p.textW, height: p.barH),
                        timesTop: nil, time: nil, trackAlpha: 0.22)
        } else {
            addPauseGlyph(height: Self.glyphHeight(p.ts.artist.size), color: p.ts.album.color,
                          at: CGPoint(x: tx, y: y), followsElapsed: false)
        }
    }

    /// The corner's feathered scrim: an elliptical darkening around `block`, leaning toward
    /// the screen corner, with a Gaussian falloff that reaches zero long before its bitmap's
    /// edge (no edge to see) and a little dither (no banding in a dark gradient).
    private func addScrim(around block: CGRect, corner: MusicSpec.Corner, unit s: CGFloat) {
        let lean: CGFloat = 0.18
        let cx = block.midX + (corner == .bottomLeft || corner == .topLeft ? -1 : 1) * block.width * lean
        let cy = block.midY + (corner == .bottomLeft || corner == .bottomRight ? 1 : -1) * block.height * lean
        let rx = block.width * 0.62 + s * 0.55, ry = block.height * 0.62 + s * 0.55
        let reach: CGFloat = 2.2                                   // radii covered by the bitmap
        let r = CGRect(x: cx - rx * reach, y: cy - ry * reach, width: rx * reach * 2, height: ry * reach * 2)
        // The falloff is smooth: a bitmap pixel per two points, upscaled linearly, is plenty.
        let k: CGFloat = 0.5
        let w = max(Int((r.width * k).rounded()), 2), h = max(Int((r.height * k).rounded()), 2)
        guard let img = MusicScrim.image(width: w, height: h, reach: reach, peak: MusicScrim.peak) else { return }
        let l = CALayer()
        l.contents = img
        l.contentsGravity = .resize
        l.minificationFilter = .linear
        l.magnificationFilter = .linear
        place(l, r)
    }
}

// MARK: - Scrim bitmap

enum MusicScrim {
    /// The scrim's darkest point (black alpha), where the type sits. Over a dark scene it's
    /// invisible; over a bright Look it sinks the corner enough for the type to read.
    static let peak: CGFloat = 0.56

    /// An elliptical Gaussian falloff of black, `peak` at the centre, essentially zero at
    /// `reach` radii (the bitmap's edge), dithered. Cached for the last few sizes.
    static func image(width w: Int, height h: Int, reach: CGFloat, peak: CGFloat) -> CGImage? {
        if let hit = cache.first(where: { $0.w == w && $0.h == h }) { return hit.image }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 0x9E3779B9
        let fx = 2 * reach / CGFloat(w), fy = 2 * reach / CGFloat(h)
        for j in 0..<h {
            let ny = (CGFloat(j) + 0.5) * fy - reach
            for i in 0..<w {
                let nx = (CGFloat(i) + 0.5) * fx - reach
                let d2 = nx * nx + ny * ny
                // Gaussian (exp(−1.35 r²)), eased to exactly zero at the bitmap's edge.
                var a = exp(-1.35 * d2)
                let edge = min(max((reach * reach - d2) / (reach * reach * 0.35), 0), 1)
                a *= edge * edge * (3 - 2 * edge)
                seed = seed &* 1664525 &+ 1013904223
                let noise = CGFloat(seed >> 8) / CGFloat(1 << 24) - 0.5
                let v = min(max(a * peak * 255 + noise, 0), 255)
                px[(j * w + i) * 4 + 3] = UInt8(v.rounded())     // premultiplied black: rgb 0
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        cache.insert((w, h, img), at: 0)
        if cache.count > 4 { cache.removeLast() }
        return img
    }

    /// Drop the cached bitmaps (the saver's teardown).
    static func purge() { cache.removeAll() }
    private static var cache: [(w: Int, h: Int, image: CGImage)] = []
}

// MARK: - Pause glyph

/// Two short rounded bars: "paused", quietly.
private final class MusicPauseGlyph: CALayer {
    init(height h: CGFloat, color: CGColor, scale: CGFloat) {
        super.init()
        let bw = max(h * 0.30, 1), gap = max(h * 0.28, 1)
        bounds = CGRect(x: 0, y: 0, width: bw * 2 + gap, height: h)
        contentsScale = scale
        for i in 0..<2 {
            let b = CALayer()
            b.backgroundColor = color
            b.cornerRadius = bw * 0.4
            b.frame = CGRect(x: CGFloat(i) * (bw + gap), y: 0, width: bw, height: h)
            b.contentsScale = scale
            addSublayer(b)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

// MARK: - Artwork bitmaps

enum MusicArtwork {
    /// The artwork redrawn at exactly `side` px, so a 1400 px cover shown at 160 px in a card
    /// stays crisp instead of aliasing. A square-ish cover fills the square; a clearly
    /// non-square one (video art, user art) is shown whole, fitted over a soft, dimmed blow-up
    /// of itself, instead of losing its sides. Cached for the last few requests. Main thread.
    static func scaled(_ art: CGImage, side: Int) -> CGImage {
        // Identity, not address: the entry holds its source, so a new cover can never be
        // mistaken for a freed one that happened to live at the same address.
        if let hit = cache.first(where: { $0.art === art && $0.side == side }) { return hit.image }
        guard side > 0, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return art }
        ctx.interpolationQuality = .high
        let w = CGFloat(art.width), h = CGFloat(art.height), S = CGFloat(side)
        func draw(_ img: CGImage, scale s: CGFloat, in c: CGContext, side: CGFloat) {
            c.draw(img, in: CGRect(x: (side - w * s) / 2, y: (side - h * s) / 2, width: w * s, height: h * s))
        }
        if abs(w / max(h, 1) - 1) > 0.05 {
            if let fill = backdrop(art) {
                ctx.draw(fill, in: CGRect(x: 0, y: 0, width: S, height: S))
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.30))
                ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
            }
            draw(art, scale: S / max(w, h), in: ctx, side: S)           // aspect-fit
        } else {
            draw(art, scale: S / min(w, h), in: ctx, side: S)           // aspect-fill (≤ 5% crop)
        }
        let out = ctx.makeImage() ?? art
        cache.insert(Entry(art: art, side: side, image: out), at: 0)
        if cache.count > 4 { cache.removeLast() }
        return out
    }

    /// Drop the cached bitmaps (the saver calls this when it tears down: the host process
    /// outlives every activation, and a 5K cover is ~8 MB).
    static func purge() { cache.removeAll() }

    /// The art aspect-filled into a few pixels: smoothly upscaled, a soft blur of its colours.
    private static func backdrop(_ art: CGImage) -> CGImage? {
        let n = 6
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .medium
        let w = CGFloat(art.width), h = CGFloat(art.height), s = CGFloat(n) / min(w, h)
        c.draw(art, in: CGRect(x: (CGFloat(n) - w * s) / 2, y: (CGFloat(n) - h * s) / 2, width: w * s, height: h * s))
        return c.makeImage()
    }

    private struct Entry { let art: CGImage; let side: Int; let image: CGImage }
    private static var cache: [Entry] = []

    /// A designed stand-in: a soft gradient (the track's palette, or a quiet neutral when
    /// idle) with a music note.
    static func placeholder(side: Int, palette: [RGBA], idle: Bool) -> CGImage? {
        guard side > 0, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(side)
        let top: CGColor, bottom: CGColor
        if idle || palette.isEmpty {
            top = CGColor(gray: 1, alpha: idle ? 0.10 : 0.16)
            bottom = CGColor(gray: 1, alpha: idle ? 0.04 : 0.07)
        } else {
            let a = palette.first!, b = palette.last!
            top = CGColor(srgbRed: a.r * 0.85, green: a.g * 0.85, blue: a.b * 0.85, alpha: 1)
            bottom = CGColor(srgbRed: b.r * 0.6, green: b.g * 0.6, blue: b.b * 0.6, alpha: 1)
        }
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.4, y: 0), options: [])
        }
        // The note, tinted.
        let pt = s * 0.30
        if let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .regular)),
           let glyph = tinted(sym, color: CGColor(gray: 1, alpha: idle ? 0.30 : 0.55)) {
            let gw = CGFloat(glyph.width), gh = CGFloat(glyph.height)
            let k = min(pt * 1.25 / max(gw, gh), 10)
            ctx.draw(glyph, in: CGRect(x: (s - gw * k) / 2, y: (s - gh * k) / 2, width: gw * k, height: gh * k))
        }
        return ctx.makeImage()
    }

    private static func tinted(_ img: NSImage, color: CGColor) -> CGImage? {
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        let w = cg.width * 2, h = cg.height * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color)
        ctx.fill(rect)
        return ctx.makeImage()
    }
}
