//  Thumbnailer.swift — renders small cached previews of each screensaver.

import AppKit
import AVFoundation
import MetalKit

final class Thumbnailer {
    private let renderer: MetalRenderer?
    private let store: SharedStore
    private var cache: [UUID: NSImage] = [:]
    private var keys: [UUID: Int] = [:]
    /// Gallery tiles are ~260pt wide; 16:10 matches most Mac displays.
    let width = 448, height = 280
    private var effectCache: [Int: NSImage] = [:]

    /// Called on the main queue when an async poster frame arrives, so the
    /// owner (AppModel) can trigger a SwiftUI refresh.
    var onUpdate: (() -> Void)?

    // Video poster frames, generated once per media file.
    private var posters: [String: MTLTexture] = [:]
    private var postersPending: Set<String> = []

    init(store: SharedStore) {
        self.store = store
        renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
    }

    /// Drop cached thumbnails for presets no longer in the library.
    func retain(ids: Set<UUID>) {
        cache = cache.filter { ids.contains($0.key) }
        keys = keys.filter { ids.contains($0.key) }
        cardCache = cardCache.filter { ids.contains($0.key) }
    }

    /// - music: the library's music settings — a Now Playing tile keeps a paused song exactly
    ///   as long as the screensaver does (its linger).
    func image(for preset: Preset, source: SourceSpec, music settings: MusicSpec = MusicSpec()) -> NSImage? {
        // Resolve a poster override for video sources (kicks off async generation
        // on first sight; the gradient fallback shows until it lands).
        var override: MTLTexture?
        if source.kind == .video, let name = source.mediaFilename {
            if let tex = posters[name] { override = tex } else { requestPoster(name) }
        }

        var hasher = Hasher()
        hasher.combine(preset)
        hasher.combine(source)
        hasher.combine(override != nil)   // re-render once the poster arrives
        // Now Playing tiles show the current track: re-render when it (not its progress) changes.
        var music: MusicSnapshot?
        if preset.isMusicScene {
            musicSettings = settings
            watchMusic()
            let snap = MusicFeedHub.shared.snapshot(store: store)
            music = snap
            hasher.combine(Self.musicKey(snap, settings))
        }
        let key = hasher.finalize()
        if keys[preset.id] == key, let img = cache[preset.id] { return img }

        if let music { renderer?.setMusic(music) }
        renderer?.musicLingerMinutes = settings.linger
        guard var cg = renderer?.renderThumbnail(preset: preset, source: source,
                                                 width: width, height: height,
                                                 time: thumbTime(preset, source),
                                                 sourceTexOverride: override) else {
            return cache[preset.id]
        }
        // A legacy Now Playing style: its own foreground while a song shows (calm art otherwise).
        if let music {
            let p = MusicPresentation.resolve(settings: settings, music: music, preset: preset)
            cg = Self.composite(cg, mode: p.overlay, music: music, settings: settings) ?? cg
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
        cache[preset.id] = img
        keys[preset.id] = key
        return img
    }

    // MARK: Music (legacy Now Playing tiles, music on the screensaver's still)

    private var musicToken: MusicFeedHub.Token?
    private var lastMusicKey: String?
    /// The settings the latest music render used (the feed watcher's key needs the linger).
    private var musicSettings = MusicSpec()
    private var cardCache: [UUID: (key: String, image: NSImage)] = [:]

    /// The thumbnail with music presented on it as the screensaver shows it right now
    /// (MusicPresentation: Corner at its true share of the screen, or Full Screen over its
    /// backdrop) — the Screensaver card's still hero. Plain while nothing shows.
    func image(for preset: Preset, source: SourceSpec, music settings: MusicSpec, showsMusic: Bool) -> NSImage? {
        let base = image(for: preset, source: source, music: settings)
        guard showsMusic, !preset.isMusicScene, settings.displayMode != .off, let base else { return base }
        musicSettings = settings
        watchMusic()
        let snap = MusicFeedHub.shared.snapshot(store: store)
        let p = MusicPresentation.resolve(settings: settings, music: snap, preset: preset)
        guard p.overlay != .hidden else { return base }
        let key = [Self.musicKey(snap, settings), "\(p.overlay)", "\(p.backdrop)", settings.cardSizePreference.rawValue,
                   "\(ObjectIdentifier(base).hashValue)"].joined(separator: "|")
        if let hit = cardCache[preset.id], hit.key == key { return hit.image }
        var frame: CGImage?
        if p.backdrop != .none {
            renderer?.setMusic(snap)
            renderer?.musicLingerMinutes = settings.linger
            let poster = source.kind == .video ? source.mediaFilename.flatMap { posters[$0] } : nil
            frame = renderer?.renderThumbnail(preset: preset, source: source, width: width, height: height,
                                              time: thumbTime(preset, source), sourceTexOverride: poster,
                                              musicBackdrop: p.backdrop)
        } else {
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            frame = base.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let frame, let out = Self.composite(frame, mode: p.overlay, music: snap, settings: settings,
                                                  trueScale: true) else { return base }
        let img = NSImage(cgImage: out, size: base.size)
        cardCache[preset.id] = (key, img)
        return img
    }

    /// What a Now Playing tile depends on: the track, its artwork and whether it's showing —
    /// not the progress, so a playing song doesn't re-render the gallery every second.
    private static func musicKey(_ s: MusicSnapshot, _ settings: MusicSpec) -> String {
        let visible = s.isVisible(settings: settings)
        guard visible, let st = s.state else { return "idle" }
        return [st.trackID ?? st.title ?? "", st.artwork ?? "-", st.isPlaying == true ? "▶" : "Ⅱ"].joined(separator: "|")
    }

    /// Once a Now Playing tile exists, follow the feed and repaint the gallery when its key
    /// changes — only while an app window is up: with every window closed (menu-bar mode) the
    /// subscription drops itself, and the next gallery render subscribes again.
    private func watchMusic() {
        guard musicToken == nil else { return }
        musicToken = MusicFeedHub.shared.subscribe(store: store) { [weak self] snap, _ in
            guard let self else { return }
            if let app = NSApp, !app.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                self.musicToken = nil
                self.lastMusicKey = nil
                return
            }
            let k = Self.musicKey(snap, self.musicSettings)
            if self.lastMusicKey != nil, k != self.lastMusicKey { self.onUpdate?() }
            self.lastMusicKey = k
        }
    }

    /// The music foreground (native-resolution CALayer tree) drawn over a rendered frame.
    /// - trueScale: a miniature of a real screen (no legibility floor under the card).
    static func composite(_ frame: CGImage, mode: MusicOverlayLayer.Mode, music: MusicSnapshot,
                          settings: MusicSpec = MusicSpec(), scale: CGFloat = 2,
                          trueScale: Bool = false) -> CGImage? {
        let w = frame.width, h = frame.height
        let layer = MusicOverlayLayer()
        layer.trueScale = trueScale
        layer.contentsScale = scale
        layer.frame = CGRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        layer.update(mode: mode, music: music, settings: settings, animated: false)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Thumbnail time. For a slideshow, each Look gets its own photo (stable per name), so
    /// the gallery shows off the set instead of one picture eleven times.
    private func thumbTime(_ preset: Preset, _ source: SourceSpec) -> Float {
        guard source.kind == .collection, !preset.isScene else { return 1.2 }
        var h: UInt32 = 2166136261
        for b in preset.name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }   // FNV-1a: stable across launches
        return Float(Double(h % 101) * source.slideInterval + 1.2)
    }

    /// A small swatch of one effect applied alone to the current source (Add Effect picker).
    func effectImage(_ kind: EffectKind, source: SourceSpec) -> NSImage? {
        var override: MTLTexture?
        if source.kind == .video, let name = source.mediaFilename {
            if let tex = posters[name] { override = tex } else { requestPoster(name) }
        }
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(source)
        hasher.combine(override != nil)
        let key = hasher.finalize()
        if let img = effectCache[key] { return img }
        let w = 224, h = 140
        guard let cg = renderer?.renderThumbnail(preset: Preset(name: kind.displayName, effects: [EffectInstance(kind)]),
                                                 source: source, width: w, height: h,
                                                 sourceTexOverride: override) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: w / 2, height: h / 2))
        if effectCache.count > 200 { effectCache.removeAll() }
        effectCache[key] = img
        return img
    }

    /// Grab a frame ~1s into the video and upload it as a Metal texture.
    private func requestPoster(_ name: String) {
        guard !postersPending.contains(name), let device = renderer?.device else { return }
        postersPending.insert(name)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: store.mediaURL(name)))
        gen.appliesPreferredTrackTransform = true
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] cg, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.postersPending.remove(name)
                guard let cg else { return }
                // Match ImageSource's loader options so posters render identically.
                let loader = MTKTextureLoader(device: device)
                let opts: [MTKTextureLoader.Option: Any] = [
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .origin: MTKTextureLoader.Origin.topLeft.rawValue
                ]
                if let tex = try? loader.newTexture(cgImage: cg, options: opts) {
                    self.posters[name] = tex
                    self.onUpdate?()
                }
            }
        }
    }
}
