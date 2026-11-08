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
    }

    func image(for preset: Preset, source: SourceSpec) -> NSImage? {
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
        let key = hasher.finalize()
        if keys[preset.id] == key, let img = cache[preset.id] { return img }

        guard let cg = renderer?.renderThumbnail(preset: preset, source: source,
                                                 width: width, height: height,
                                                 sourceTexOverride: override) else {
            return cache[preset.id]
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
        cache[preset.id] = img
        keys[preset.id] = key
        return img
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
