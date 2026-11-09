//  MusicScene.swift — what the Now Playing scene's background (Metal) and foreground
//  (MusicOverlayLayer) share: the scene's options, the layout geometry, an immutable
//  snapshot of the feed that can cross threads, and a palette fallback.

import Foundation
import CoreGraphics
import CoreText

/// Foreground arrangement of the Now Playing scene (the "Layout" menu).
enum MusicLayoutKind: Int, CaseIterable {
    /// Apple Music full screen: artwork left, big type right.
    case album = 0
    /// Spotify TV: artwork centred, type below.
    case stage = 1
    /// The artwork fills the screen, type bottom-left.
    case cover = 2

    var label: String {
        switch self {
        case .album: return "Album"
        case .stage: return "Stage"
        case .cover: return "Cover"
        }
    }
}

/// What the shader paints behind the foreground (the "Background" menu).
enum MusicBackground: Int, CaseIterable {
    case livingArt = 0, blur = 1, dark = 2

    var label: String {
        switch self {
        case .livingArt: return "Living Art"
        case .blur: return "Blur"
        case .dark: return "Dark"
        }
    }
}

/// The Now Playing effect's params, resolved.
struct MusicSceneOptions: Equatable {
    var layout: MusicLayoutKind = .album
    var background: MusicBackground = .livingArt
    var motion: Double = 1
    var showAlbum = true
    var showProgress = true

    init() {}

    init(_ inst: EffectInstance) {
        func v(_ k: String) -> Double { Double(inst.g(k)) }
        layout = MusicLayoutKind(rawValue: Int(v("layout").rounded())) ?? .album
        background = MusicBackground(rawValue: Int(v("background").rounded())) ?? .livingArt
        motion = v("motion")
        showAlbum = v("album") > 0.5
        showProgress = v("progress") > 0.5
    }
}

extension Preset {
    /// The enabled Now Playing effect in this style, if any. Its params drive the foreground.
    var musicScene: EffectInstance? { effects.first { $0.enabled && $0.kind == .nowPlaying } }
    /// A style that shows what's playing full screen (draws its own foreground; no card).
    var isMusicScene: Bool { musicScene != nil }
}

// MARK: - Snapshot

/// An immutable copy of a MusicFeed's current state. Value type + immutable CGImage, so
/// one thread can poll the feed and hand snapshots to a render thread.
struct MusicSnapshot {
    var state: MusicState?
    var artwork: CGImage?
    /// The feed's revision when taken (changes ⇒ state or artwork changed).
    var revision: Int = 0

    static let empty = MusicSnapshot()

    var hasTrack: Bool { state?.hasTrack ?? false }

    /// Whether the card / foreground should show what's playing (playing, or paused
    /// within the linger window).
    func isVisible(settings: MusicSpec, at now: Date = Date()) -> Bool {
        state?.isVisible(at: now, lingerMinutes: settings.linger) ?? false
    }

    /// The artwork palette: the writer's, else extracted from the artwork, else empty.
    var palette: [RGBA] {
        if let p = state?.palette, !p.isEmpty { return p }
        return artwork.map(MusicFallbackPalette.extract) ?? []
    }
}

extension MusicFeed {
    var snapshot: MusicSnapshot { MusicSnapshot(state: state, artwork: artwork, revision: revision) }
}

// MARK: - Palette fallback

enum MusicFallbackPalette {
    /// Three representative colours of an image (vivid, mean, deep), brightest first.
    /// A fallback for writers that don't supply `MusicState.palette`; ~0.1 ms.
    static func extract(_ image: CGImage) -> [RGBA] {
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return [] }
        var cols: [(r: Double, g: Double, b: Double)] = []
        for i in 0..<(n * n) {
            cols.append((Double(px[i * 4]) / 255, Double(px[i * 4 + 1]) / 255, Double(px[i * 4 + 2]) / 255))
        }
        func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        func mean(_ s: ArraySlice<(r: Double, g: Double, b: Double)>) -> RGBA {
            let k = Double(max(s.count, 1))
            return RGBA(s.reduce(0) { $0 + $1.r } / k, s.reduce(0) { $0 + $1.g } / k, s.reduce(0) { $0 + $1.b } / k)
        }
        let vivid = mean(cols.sorted { chroma($0) * (0.3 + luma($0)) > chroma($1) * (0.3 + luma($1)) }.prefix(12))
        let all = mean(cols[...])
        let deep = mean(cols.sorted { luma($0) < luma($1) }.prefix(16))
        return [vivid, all, deep].sorted { $0.r * 0.2126 + $0.g * 0.7152 + $0.b * 0.0722
                                         > $1.r * 0.2126 + $1.g * 0.7152 + $1.b * 0.0722 }
    }
}

// MARK: - Geometry

/// Where the foreground goes, as fractions of the screen — shared by the overlay (points)
/// and the shader (uv), so the background's glow sits behind the overlay's artwork.
/// The artwork's place depends only on the screen size and layout, never on the text,
/// so a long title never pushes the art around between tracks.
enum MusicGeometry {
    /// The design unit: the height of the largest 16:10 box that fits the screen. Type and
    /// spacing are multiples of it, so the design holds from a tile to a 6K display, and an
    /// ultra-wide screen gets more margin rather than bigger type.
    static func unit(_ size: CGSize) -> CGFloat { max(min(size.height, size.width / 1.6), 1) }

    /// Album layout: artwork square + gap + text column, centred as one composition.
    static let albumArt: CGFloat = 0.50       // artwork side, in units
    static let albumGap: CGFloat = 0.075      // artwork → text column
    static let albumText: CGFloat = 0.56      // text column width
    /// Stage layout (Spotify TV): the type scale and gaps of the block the artwork heads, in
    /// units — the overlay draws with these, and `stageBlock` sums them, so the reserved
    /// block is measured, not guessed.
    enum Stage {
        static let art: CGFloat = 0.44
        static let artGap: CGFloat = 0.055               // artwork → title
        static let title: CGFloat = 0.046, titleLeading: CGFloat = 1.08, titleLines = 2
        static let artist: CGFloat = 0.030, artistGap: CGFloat = 0.012
        static let album: CGFloat = 0.023, albumGap: CGFloat = 0.008
        static let barGap: CGFloat = 0.042, bar: CGFloat = 0.0058
        static let times: CGFloat = 0.0158, timesGap: CGFloat = 0.014
        static let caption: CGFloat = 0.0138, captionGap: CGFloat = 0.034
    }

    /// Height of one line of the system font (ascent + descent) per point of size — how
    /// MusicText measures a single-line block. SF Pro: 0.967 + 0.211.
    static let lineBox: CGFloat = {
        let f = CTFontCreateUIFontForLanguage(.system, 100, nil)
        return f.map { (CTFontGetAscent($0) + CTFontGetDescent($0)) / 100 } ?? 1.18
    }()

    /// The Stage block from the artwork's top to the caption's bottom, in units, for the
    /// worst case (a two-line title) so the artwork never moves between tracks. Rows the
    /// scene hides (album, progress) aren't reserved.
    static func stageBlock(_ o: MusicSceneOptions) -> CGFloat {
        typealias S = Stage
        var h = S.art + S.artGap
        h += S.title * lineBox + S.title * S.titleLeading * CGFloat(S.titleLines - 1)
        h += S.artistGap + S.artist * lineBox
        if o.showAlbum { h += S.albumGap + S.album * lineBox }
        if o.showProgress { h += S.barGap + S.bar + S.timesGap + S.times * lineBox }
        return h + S.captionGap + S.caption * lineBox
    }

    /// The artwork rect in the screen's own units, top-left origin (y down). For Cover the
    /// artwork is the whole screen. `insets` (menu bar, Dock — the overlay's safe insets)
    /// only move Stage, which centres its block between them; the shader passes none (its
    /// glow behind the art is soft enough not to mind the few points).
    static func artRect(_ layout: MusicLayoutKind, size: CGSize, options: MusicSceneOptions = MusicSceneOptions(),
                        insets: (top: CGFloat, bottom: CGFloat) = (0, 0)) -> CGRect {
        let u = unit(size)
        switch layout {
        case .album:
            let s = albumArt * u
            // Centre the composition on the text's visual width (titles rarely fill the column).
            let comp = s + albumGap * u + albumText * u * 0.82
            let x = (size.width - comp) / 2
            let y = (size.height - s) / 2 - 0.01 * u      // optical centre: a hair above
            return CGRect(x: x, y: y, width: s, height: s)
        case .stage:
            let s = Stage.art * u
            let avail = size.height - insets.top - insets.bottom
            let top = insets.top + max((avail - stageBlock(options) * u) / 2, min(0.02 * u, avail * 0.02))
            return CGRect(x: (size.width - s) / 2, y: top, width: s, height: s)
        case .cover:
            return CGRect(origin: .zero, size: size)
        }
    }

    /// The artwork rect as uv (x, y from the top, w, h) for the shader.
    static func artUV(_ layout: MusicLayoutKind, size: CGSize,
                      options: MusicSceneOptions = MusicSceneOptions()) -> (x: Float, y: Float, w: Float, h: Float) {
        guard size.width > 0, size.height > 0 else { return (0, 0, 0, 0) }
        let r = artRect(layout, size: size, options: options)
        return (Float(r.minX / size.width), Float(r.minY / size.height),
                Float(r.width / size.width), Float(r.height / size.height))
    }
}
