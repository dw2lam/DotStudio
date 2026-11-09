//  MusicOverlayLayer.swift — the music foreground, drawn as a CALayer tree at the display's
//  native scale above the Metal layer (Metal output is often reduced and nearest-upscaled,
//  so type there would pixelate). No SwiftUI: the saver, the live wallpaper, the in-app
//  previews and thumbnails (layer.render(in:)) all host the same layer.
//
//  Two modes:
//    • full — the Now Playing scene's foreground, per its Layout param:
//        Album  (Apple Music full screen) artwork left, big type right;
//        Stage  (Spotify TV)              artwork centred, type below;
//        Cover  (artwork full-bleed)      type bottom-left over the shader's scrim.
//      Nothing playing ⇒ a calm "Not Playing" state.
//    • card — a compact glass card in a corner, over any style, while music is visible.
//
//  Hosts call `update(mode:music:settings:)` about once a second and whenever the mode or the
//  feed changes; between track changes that only moves the progress bar and the times.
//  Track changes cross-fade (the card's artwork flips); Reduce Motion keeps only fades.
//  Main thread only.

import AppKit
import QuartzCore

final class MusicOverlayLayer: CALayer {
    struct Insets: Equatable {
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    }

    enum Mode: Equatable {
        case hidden
        /// The Now Playing scene's foreground (its Layout / Show Album / Show Progress params).
        case full(MusicSceneOptions)
        /// The corner card over any style; shown only while music is visible.
        case card(MusicSpec.Corner)
    }

    /// Screen areas to keep the type clear of, in points (menu bar and Dock on the wallpaper).
    /// Album is centred with margins wider than both; Stage centres its block in the area
    /// between them; the Cover type and the card move off them.
    var safeInsets = Insets() { didSet { if safeInsets != oldValue { setNeedsLayout() } } }
    /// Accessibility Reduce Motion: no flips, no scaling, no equalizer bounce — fades only.
    var reduceMotion = MusicOverlayLayer.systemReduceMotion
    static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Continuous decoration: the equalizer bounce and the progress bar gliding between
    /// ticks. Both keep WindowServer compositing every refresh, so the live wallpaper turns
    /// them off (bars hold still, progress steps once a second); the screensaver keeps them.
    var ambientMotion = true

    /// Continuous decoration never needs the panel's full rate: at most 30 Hz, so a ProMotion
    /// display doesn't recomposite the overlay at 120 Hz over a 30 fps Metal background.
    static let decorationRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)

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

    private func resolve(now: Date) -> MusicDisplay? {
        let visible = music.isVisible(settings: settings, at: now)
        switch mode {
        case .hidden:
            return nil
        case .card:
            return visible ? MusicDisplay(mode: mode, idle: false, music: music, now: now) : nil
        case .full:
            return MusicDisplay(mode: mode, idle: !visible, music: music, now: now)
        }
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
                                      reduceMotion: reduceMotion, ambient: ambientMotion, cardSize: cardSize)
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
        var idle: Bool
        var track: String
        var art: ObjectIdentifier?
        var size: CGSize
        var scale: CGFloat
        var insets: Insets
        /// Card mode only (nil otherwise, so a size change never rebuilds a full layout).
        var cardSize: MusicSpec.CardSize?

        init(_ d: MusicDisplay, size: CGSize, scale: CGFloat, insets: Insets, cardSize: MusicSpec.CardSize) {
            mode = d.mode; idle = d.idle; track = d.trackKey
            art = d.art.map { ObjectIdentifier($0) }
            self.size = size; self.scale = scale; self.insets = insets
            if case .card = d.mode { self.cardSize = cardSize }
        }

        /// Same place, same mode, a different song (or new artwork for it).
        func isTrackChange(to n: GroupKey) -> Bool {
            mode == n.mode && !idle && !n.idle && (track != n.track || art != n.art)
                && size == n.size && scale == n.scale
        }
    }
}

// MARK: - What to show

/// The overlay's resolved content for one moment.
struct MusicDisplay {
    var mode: MusicOverlayLayer.Mode
    var idle: Bool
    var state: MusicState?
    var art: CGImage?
    var palette: [RGBA]
    var title: String
    var artist: String
    var album: String
    var source: MusicSource
    var playing: Bool

    init(mode: MusicOverlayLayer.Mode, idle: Bool, music: MusicSnapshot, now: Date) {
        self.mode = mode
        self.idle = idle
        let s = idle ? nil : music.state
        state = s
        art = idle ? nil : music.artwork
        palette = idle ? [] : music.palette
        title = s?.title ?? ""
        artist = s?.artist ?? ""
        album = s?.album ?? ""
        source = s?.source ?? .unknown
        playing = s?.isPlaying ?? false
    }

    var trackKey: String { state?.trackID ?? "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    var sourceName: String {
        switch source {
        case .spotify: return "Spotify"
        case .music: return "Apple Music"
        case .unknown: return "Music"
        }
    }

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
    private let idle: Bool

    private var artFace: CALayer?
    private var captionLayer: CALayer?
    private var captionStyle: MusicTextStyle?
    private var captionOrigin: (x: CGFloat, top: CGFloat, width: CGFloat, align: CTTextAlignment) = (0, 0, 0, .left)
    private var eq: MusicEQGlyph?
    private var eqLead: CGFloat = 0
    private var fill: CALayer?
    private var barRect: CGRect = .zero
    private var timeStyle: MusicTextStyle?
    private var elapsedLayer: CALayer?
    private var remainingLayer: CALayer?
    private var timesTop: CGFloat = 0
    private var cardRemaining: Bool = false
    private var lastSecond = Int.min
    private var lastPlaying: Bool?
    private var lastFill: CGFloat = -1
    private let display: MusicDisplay

    init(_ d: MusicDisplay, bounds: CGRect, insets: MusicOverlayLayer.Insets, scale: CGFloat, reduceMotion: Bool,
         ambient: Bool, cardSize: MusicSpec.CardSize = .medium) {
        self.ambient = ambient
        W = bounds.width; H = bounds.height
        u = MusicGeometry.unit(bounds.size)
        self.scale = scale
        self.reduceMotion = reduceMotion
        mode = d.mode
        idle = d.idle
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
            buildCard(d, corner, insets, size: cardSize)
        case .hidden:
            break
        }
    }

    override init(layer: Any) {
        let g = layer as? MusicOverlayGroup
        W = g?.W ?? 0; H = g?.H ?? 0; u = g?.u ?? 1; scale = g?.scale ?? 2
        reduceMotion = g?.reduceMotion ?? false; ambient = g?.ambient ?? false; mode = g?.mode ?? .hidden; idle = g?.idle ?? true
        display = g?.display ?? MusicDisplay(mode: .hidden, idle: true, music: .empty, now: Date())
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? { NSNull() }

    // MARK: Placement helpers

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    /// Top-left rect → Core Animation frame, snapped to device pixels.
    private func place(_ l: CALayer, _ r: CGRect, in parent: CALayer? = nil) {
        let x = snap(r.minX), y = snap(H - r.maxY)
        l.frame = CGRect(x: x, y: y, width: snap(r.maxX) - x, height: snap(H - r.minY) - y)
        l.contentsScale = scale
        (parent ?? self).addSublayer(l)
    }

    /// Lay out and add a text block whose box starts at (x, top) within `width`; returns its
    /// box height (0 when empty).
    @discardableResult
    private func addText(_ s: String, _ style: MusicTextStyle, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
        let b = MusicText.layout(s, style, width: width)
        guard let l = textLayer(b, x: x, top: top, width: width) else { return 0 }
        addSublayer(l)
        return b.height
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

    // MARK: Artwork

    /// Artwork (or a placeholder) at `r`, with a soft shadow; `radius` as a fraction of the side.
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
            face.shadowPath = path
            face.shadowColor = CGColor(gray: 0, alpha: 1)
            face.shadowOpacity = Float(0.42 * shadow)
            face.shadowRadius = side * 0.075 * shadow
            face.shadowOffset = CGSize(width: 0, height: -side * 0.035 * shadow)
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
        img.borderColor = Self.white(0.09)
        let px = Int((side * scale).rounded())
        if let art = d.art {
            img.contents = MusicArtwork.scaled(art, side: px)
        } else {
            img.contents = MusicArtwork.placeholder(side: px, palette: d.idle ? [] : d.palette, idle: d.idle)
        }
        face.addSublayer(img)
        artFace = face
    }

    // MARK: Caption (source) + equalizer glyph

    private func captionText(_ d: MusicDisplay, playing: Bool) -> String {
        if d.state?.isPodcast == true { return playing ? "\(d.sourceName) · Podcast" : "Paused · \(d.sourceName)" }
        return playing ? d.sourceName : "Paused · \(d.sourceName)"
    }

    /// The caption row: equalizer glyph + source. `align` = .left or .center within width.
    private func addCaption(_ d: MusicDisplay, _ style: MusicTextStyle, x: CGFloat, top: CGFloat,
                            width: CGFloat) -> CGFloat {
        let capH = style.size * 0.74                           // ≈ cap height
        let glyph = MusicEQGlyph(height: capH, color: Self.white(min(style.color.alpha + 0.16, 1)), scale: scale)
        eq = glyph
        eqLead = glyph.bounds.width + style.size * 0.55
        captionStyle = style
        captionOrigin = (x, top, width, style.alignment)
        layoutCaption(d, playing: d.playing)
        addSublayer(glyph)
        let b = measure(captionText(d, playing: d.playing), style, width: width)
        return b.height
    }

    private func layoutCaption(_ d: MusicDisplay, playing: Bool) {
        guard let style = captionStyle, let eq else { return }
        captionLayer?.removeFromSuperlayer()
        let (x, top, width, align) = captionOrigin
        var s = style
        s.alignment = .left
        let b = measure(captionText(d, playing: playing), s, width: max(width - eqLead, 10))
        let total = eqLead + ceil(b.width)
        let startX = align == .center ? x + (width - total) / 2 : x
        if let l = textLayer(b, x: startX + eqLead, top: top, width: max(width - eqLead, 10)) {
            addSublayer(l)
            captionLayer = l
        }
        // Bars sit on the caption's baseline.
        let baseline = top + b.ascent
        let gh = eq.bounds.height
        let ox = snap(startX), oy = snap(H - baseline)
        eq.frame = CGRect(x: ox, y: oy, width: eq.bounds.width, height: gh)
        eq.set(playing: playing, animated: !reduceMotion && ambient)
    }

    // MARK: Progress

    private func addProgress(_ d: MusicDisplay, bar: CGRect, timesTop: CGFloat?, timeSize: CGFloat,
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
        if let timesTop {
            self.timesTop = timesTop
            timeStyle = MusicTextStyle(size: timeSize, weight: .medium, color: Self.white(0.56),
                                       monospacedDigits: true)
        }
    }

    private func updateTimes(_ d: MusicDisplay, now: Date) {
        guard let st = d.state, let style = timeStyle else { return }
        // An estimated position (Apple Music without Automation: counted from when the track
        // was seen) keeps the bar as a rough guide but never claims to-the-second times.
        if st.positionIsApproximate == true {
            elapsedLayer?.removeFromSuperlayer(); remainingLayer?.removeFromSuperlayer()
            elapsedLayer = nil; remainingLayer = nil
            lastSecond = Int.min
            return
        }
        let e = st.elapsed(at: now)
        let sec = Int(e)
        guard sec != lastSecond else { return }
        lastSecond = sec
        let elapsed = MusicState.timeString(e)
        let remaining = "−" + MusicState.timeString(max((st.duration ?? 0) - Double(sec), 0))
        elapsedLayer?.removeFromSuperlayer(); remainingLayer?.removeFromSuperlayer()
        if cardRemaining {
            var s = style; s.alignment = .right
            remainingLayer = textLayer(measure(remaining, s, width: barRect.width), x: barRect.minX,
                                       top: timesTop, width: barRect.width)
        } else {
            var l = style; l.alignment = .left
            var r = style; r.alignment = .right
            elapsedLayer = textLayer(measure(elapsed, l, width: barRect.width), x: barRect.minX,
                                     top: timesTop, width: barRect.width)
            remainingLayer = textLayer(measure(remaining, r, width: barRect.width), x: barRect.minX,
                                       top: timesTop, width: barRect.width)
        }
        if let l = elapsedLayer { addSublayer(l) }
        if let l = remainingLayer { addSublayer(l) }
    }

    // MARK: Tick (in place, about once a second)

    func tick(_ d: MusicDisplay, now: Date, animated: Bool) {
        if !idle, d.playing != lastPlaying {
            let first = lastPlaying == nil
            lastPlaying = d.playing
            if captionStyle != nil { layoutCaption(d, playing: d.playing) }
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

    /// Paused: the big artwork settles back a little, like Apple Music.
    private func setPaused(_ paused: Bool, animated: Bool) {
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
        a.duration = 0.7
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(a, forKey: "in")
        if case .card = mode, !reduceMotion {
            let s = CASpringAnimation(keyPath: "transform.scale")
            s.fromValue = 0.96; s.toValue = 1
            s.damping = 20; s.stiffness = 180
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

    /// Fade out (flip the old cover away on a card track change), then remove.
    func disappear(trackChange: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperlayer() }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = presentation()?.opacity ?? 1
        a.toValue = 0
        a.duration = trackChange ? 0.45 : 0.6
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
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
            s.fromValue = 1; s.toValue = 0.97
            s.duration = 0.6
            s.fillMode = .forwards
            s.isRemovedOnCompletion = false
            add(s, forKey: "outScale")
        }
        CATransaction.commit()
    }

    // MARK: Layouts

    private func bodyStyles(title: CGFloat, artist: CGFloat, album: CGFloat, caption: CGFloat,
                            align: CTTextAlignment, titleLines: Int, halo: CGFloat = 0)
        -> (caption: MusicTextStyle, title: MusicTextStyle, artist: MusicTextStyle, album: MusicTextStyle) {
        let cap = MusicTextStyle(size: caption, weight: .semibold, color: Self.white(0.58), tracking: 0.09,
                                 alignment: align, uppercase: true, halo: halo)
        let t = MusicTextStyle(size: title, weight: .bold, color: Self.white(1), tracking: -0.012,
                               maxLines: titleLines, alignment: align, leading: 1.08, halo: halo)
        let ar = MusicTextStyle(size: artist, weight: .medium, color: Self.white(0.74), tracking: -0.004,
                                maxLines: 1, alignment: align, halo: halo)
        let al = MusicTextStyle(size: album, weight: .regular, color: Self.white(0.50), maxLines: 1,
                                alignment: align, halo: halo)
        return (cap, t, ar, al)
    }

    /// Idle copy (nothing playing).
    private static let idleTitle = "Not Playing"
    private static let idleSubtitle = "Play something in Spotify or Music"

    /// Apple Music full screen: artwork left, type right, the group centred on the art.
    private func buildAlbum(_ d: MusicDisplay, _ o: MusicSceneOptions) {
        let art = MusicGeometry.artRect(.album, size: CGSize(width: W, height: H))
        addArt(d, art, radius: 0.028, shadow: 1)
        let x = art.maxX + MusicGeometry.albumGap * u
        let colW = max(min(MusicGeometry.albumText * u, W - x - 0.06 * u), 40)
        // Sized for the far side of a room: the title's cap height is ≈ 4.5 % of a 16:10
        // screen's height (0.064 u); every other line in step with it.
        let st = bodyStyles(title: 0.064 * u, artist: 0.040 * u, album: 0.030 * u, caption: 0.0172 * u,
                            align: .left, titleLines: 2)
        if d.idle {
            let tb = measure(Self.idleTitle, st.title, width: colW)
            var sub = st.artist; sub.color = Self.white(0.5); sub.weight = .regular
            sub.maxLines = 2   // the hint wraps rather than losing its last words
            let sb = measure(Self.idleSubtitle, sub, width: colW)
            let h = tb.height + 0.016 * u + sb.height
            var y = art.midY - h / 2
            addText(Self.idleTitle, st.title, x: x, top: y, width: colW)
            y += tb.height + 0.016 * u
            addText(Self.idleSubtitle, sub, x: x, top: y, width: colW)
            return
        }
        // Measure, then centre the whole column on the artwork.
        let tb = measure(d.title, st.title, width: colW)
        let ab = measure(d.artist, st.artist, width: colW)
        let lb = o.showAlbum ? measure(d.album, st.album, width: colW) : nil
        let capH = st.caption.size * 1.2
        let barH = max(0.0068 * u, 3)
        let showBar = o.showProgress && d.hasDuration
        let timeSize = 0.0195 * u
        var h = capH + 0.024 * u + tb.height
        if !ab.isEmpty { h += 0.016 * u + ab.height }
        if let lb, !lb.isEmpty { h += 0.009 * u + lb.height }
        if showBar { h += 0.054 * u + barH + 0.017 * u + timeSize * 1.2 }
        var y = max(art.midY - h / 2, art.minY)
        _ = addCaption(d, st.caption, x: x, top: y, width: colW)
        y += capH + 0.024 * u
        addText(d.title, st.title, x: x, top: y, width: colW)
        y += tb.height
        if !ab.isEmpty { y += 0.016 * u; addText(d.artist, st.artist, x: x, top: y, width: colW); y += ab.height }
        if let lb, !lb.isEmpty { y += 0.009 * u; addText(d.album, st.album, x: x, top: y, width: colW); y += lb.height }
        if showBar {
            y += 0.054 * u
            let barW = min(colW, MusicGeometry.albumArt * u)
            addProgress(d, bar: CGRect(x: x, y: y, width: barW, height: barH),
                        timesTop: y + barH + 0.017 * u, timeSize: timeSize)
        }
    }

    /// Spotify TV: artwork centred, type centred below. The block (sized for a two-line
    /// title — MusicGeometry.stageBlock) is centred between the menu bar and the Dock.
    private func buildStage(_ d: MusicDisplay, _ o: MusicSceneOptions, _ insets: MusicOverlayLayer.Insets) {
        typealias S = MusicGeometry.Stage
        let art = MusicGeometry.artRect(.stage, size: CGSize(width: W, height: H), options: o,
                                        insets: (insets.top, insets.bottom))
        addArt(d, art, radius: 0.024, shadow: 1)
        let colW = min(W - 0.16 * u - insets.left - insets.right, 1.3 * u)
        let x = insets.left + (W - insets.left - insets.right - colW) / 2
        let st = bodyStyles(title: S.title * u, artist: S.artist * u, album: S.album * u, caption: S.caption * u,
                            align: .center, titleLines: S.titleLines)
        var y = art.maxY + S.artGap * u
        if d.idle {
            var sub = st.artist; sub.color = Self.white(0.5); sub.weight = .regular
            y += addText(Self.idleTitle, st.title, x: x, top: y, width: colW) + S.artistGap * u
            addText(Self.idleSubtitle, sub, x: x, top: y, width: colW)
            return
        }
        y += addText(d.title, st.title, x: x, top: y, width: colW)
        let ah = addText(d.artist, st.artist, x: x, top: y + S.artistGap * u, width: colW)
        if ah > 0 { y += S.artistGap * u + ah }
        if o.showAlbum {
            let lh = addText(d.album, st.album, x: x, top: y + S.albumGap * u, width: colW)
            if lh > 0 { y += S.albumGap * u + lh }
        }
        let barH = max(S.bar * u, 3)
        if o.showProgress && d.hasDuration {
            y += S.barGap * u
            let bar = CGRect(x: art.minX, y: y, width: art.width, height: barH)
            addProgress(d, bar: bar, timesTop: y + barH + S.timesGap * u, timeSize: S.times * u)
            y += barH + S.timesGap * u + S.times * u * MusicGeometry.lineBox
        }
        _ = addCaption(d, st.caption, x: x, top: y + S.captionGap * u, width: colW)
    }

    /// Full-bleed artwork (the shader), type bottom-left over its scrim.
    private func buildCover(_ d: MusicDisplay, _ o: MusicSceneOptions, _ insets: MusicOverlayLayer.Insets) {
        let m = 0.072 * u
        let left = m + insets.left
        let bottom = H - m - insets.bottom
        let colW = max(min(1.05 * u, W - left - m - insets.right), 40)
        var st = bodyStyles(title: 0.080 * u, artist: 0.040 * u, album: 0.028 * u, caption: 0.0158 * u,
                            align: .left, titleLines: 2, halo: 0.35)
        // Over full-bleed art the secondary lines need more weight than over the calm Album /
        // Stage backgrounds (the shader's scrim targets ≥ 7:1 for the title; these keep ≥ 4.5:1).
        st.caption.color = Self.white(0.72); st.artist.color = Self.white(0.84); st.album.color = Self.white(0.68)
        if d.idle {
            var sub = st.artist; sub.color = Self.white(0.55); sub.weight = .regular
            let sb = measure(Self.idleSubtitle, sub, width: colW)
            let tb = measure(Self.idleTitle, st.title, width: colW)
            let sy = bottom - sb.height
            addText(Self.idleSubtitle, sub, x: left, top: sy, width: colW)
            addText(Self.idleTitle, st.title, x: left, top: sy - 0.016 * u - tb.height, width: colW)
            return
        }
        // Bottom-up: times, bar, album, artist, title, caption.
        var y = bottom
        let showBar = o.showProgress && d.hasDuration
        if showBar {
            let ts = 0.0172 * u
            let barH = max(0.0062 * u, 3)
            y -= ts * 1.2
            let timesTop = y
            y -= 0.016 * u + barH
            addProgress(d, bar: CGRect(x: left, y: y, width: min(0.56 * u, colW), height: barH),
                        timesTop: timesTop, timeSize: ts, trackAlpha: 0.26)
            timeStyle?.halo = 0.35
            timeStyle?.color = Self.white(0.70)
            y -= 0.050 * u
        }
        if o.showAlbum {
            let lb = measure(d.album, st.album, width: colW)
            if !lb.isEmpty { y -= lb.height; addText(d.album, st.album, x: left, top: y, width: colW); y -= 0.010 * u }
        }
        let ab = measure(d.artist, st.artist, width: colW)
        if !ab.isEmpty { y -= ab.height; addText(d.artist, st.artist, x: left, top: y, width: colW); y -= 0.016 * u }
        let tb = measure(d.title, st.title, width: colW)
        y -= tb.height
        addText(d.title, st.title, x: left, top: y, width: colW)
        y -= 0.024 * u + st.caption.size * 1.2
        _ = addCaption(d, st.caption, x: left, top: y, width: colW)
    }

    /// The corner card: dark glass, artwork, caption + remaining time, title, artist, bar.
    /// It follows the screen's height (MusicGeometry.Card, per Card Size) with no upper cap —
    /// a bigger display is read from further away — and never drops below a legible minimum
    /// in a small preview.
    private func buildCard(_ d: MusicDisplay, _ corner: MusicSpec.Corner, _ insets: MusicOverlayLayer.Insets,
                           size: MusicSpec.CardSize) {
        let f = MusicGeometry.Card.size(size)
        let hc = max(f.height * u, min(60, 0.2 * u))
        let wc = min(hc * f.width / f.height, W * 0.46)
        let m = max(0.040 * u, min(18, 0.06 * u))
        let x: CGFloat, y: CGFloat
        switch corner {
        case .bottomLeft: x = m + insets.left; y = H - m - insets.bottom - hc
        case .bottomRight: x = W - m - insets.right - wc; y = H - m - insets.bottom - hc
        case .topLeft: x = m + insets.left; y = m + insets.top
        case .topRight: x = W - m - insets.right - wc; y = m + insets.top
        }
        let card = CGRect(x: x, y: y, width: wc, height: hc)
        let radius = hc * 0.24

        // Glass: deep artwork tint at ~70 %, a hairline rim, a soft sheen and a wide shadow.
        let bg = CALayer()
        let deep = d.palette.last ?? RGBA(0.1, 0.1, 0.12)
        let k = 0.30
        bg.backgroundColor = CGColor(srgbRed: deep.r * k, green: deep.g * k, blue: deep.b * k, alpha: 0.72)
        bg.cornerRadius = radius
        bg.cornerCurve = .continuous
        bg.borderWidth = 1 / scale
        bg.borderColor = Self.white(0.14)
        place(bg, card)
        bg.shadowPath = CGPath(roundedRect: bg.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        bg.shadowColor = CGColor(gray: 0, alpha: 1)
        bg.shadowOpacity = 0.32
        bg.shadowRadius = hc * 0.22
        bg.shadowOffset = CGSize(width: 0, height: -hc * 0.07)
        let sheen = CAGradientLayer()
        sheen.frame = bg.bounds
        sheen.cornerRadius = radius
        sheen.cornerCurve = .continuous
        sheen.masksToBounds = true
        sheen.colors = [Self.white(0.10), Self.white(0.02), Self.white(0.0)]
        sheen.locations = [0, 0.45, 1]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)      // top (CA y is up)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        bg.addSublayer(sheen)

        let p = hc * 0.15
        let side = hc - 2 * p
        addArt(d, CGRect(x: x + p, y: y + p, width: side, height: side), radius: 0.13, shadow: 0.45)

        let tx = x + p + side + hc * 0.14
        let tw = max(wc - (tx - x) - p * 1.1, 20)
        // The type is a larger share of the card than a desktop widget's: it's read from afar.
        let cap = MusicTextStyle(size: hc * 0.092, weight: .semibold, color: Self.white(0.58), tracking: 0.08,
                                 uppercase: true)
        let title = MusicTextStyle(size: hc * 0.165, weight: .semibold, color: Self.white(0.97), tracking: -0.008)
        let artist = MusicTextStyle(size: hc * 0.135, weight: .regular, color: Self.white(0.70))
        let showBar = d.hasDuration
        // Caption row (glyph + source, remaining time on the right), then title, artist; the
        // bar lines up with the artwork's bottom edge.
        let capTop = y + p + hc * 0.010
        _ = addCaption(d, cap, x: tx, top: capTop, width: tw * (showBar ? 0.72 : 1))
        var ty = capTop + cap.size * 1.2 + hc * 0.055
        ty += addText(d.title, title, x: tx, top: ty, width: tw)
        addText(d.artist, artist, x: tx, top: ty + hc * 0.022, width: tw)
        if showBar {
            let barH = max(hc * 0.028, 2)
            let by = y + p + side - barH
            addProgress(d, bar: CGRect(x: tx, y: by, width: tw, height: barH), timesTop: capTop,
                        timeSize: hc * 0.092, trackAlpha: 0.20)
            timeStyle?.color = Self.white(0.50)
            cardRemaining = true
        }
    }
}

// MARK: - Equalizer glyph

/// Three bars that bounce while playing (still when paused or with Reduce Motion).
private final class MusicEQGlyph: CALayer {
    private var bars: [CALayer] = []
    private let rest: [CGFloat] = [0.42, 0.78, 0.58]
    private let playingRest: [CGFloat] = [0.62, 1.0, 0.78]

    init(height h: CGFloat, color: CGColor, scale: CGFloat) {
        super.init()
        let bw = max(h * 0.20, 1), gap = max(h * 0.15, 1)
        bounds = CGRect(x: 0, y: 0, width: bw * 3 + gap * 2, height: h)
        contentsScale = scale
        for i in 0..<3 {
            let b = CALayer()
            b.backgroundColor = color
            b.cornerRadius = bw / 2
            b.anchorPoint = CGPoint(x: 0.5, y: 0)          // grow up from the baseline
            b.bounds = CGRect(x: 0, y: 0, width: bw, height: h)
            b.position = CGPoint(x: CGFloat(i) * (bw + gap) + bw / 2, y: 0)
            b.contentsScale = scale
            addSublayer(b)
            bars.append(b)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func action(forKey event: String) -> CAAction? { NSNull() }

    func set(playing: Bool, animated: Bool) {
        for (i, b) in bars.enumerated() {
            b.removeAnimation(forKey: "eq")
            let s = playing ? playingRest[i] : rest[i]
            b.setValue(s, forKeyPath: "transform.scale.y")
            guard playing, animated else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.30 + 0.1 * CGFloat(i)
            a.toValue = 1.0
            a.duration = [0.46, 0.38, 0.54][i]
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timeOffset = [0.0, 0.21, 0.37][i]
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.preferredFrameRateRange = MusicOverlayLayer.decorationRate
            b.add(a, forKey: "eq")
        }
    }
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
