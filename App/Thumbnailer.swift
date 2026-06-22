//  Thumbnailer.swift — renders small cached previews of each screensaver.

import AppKit

final class Thumbnailer {
    private let renderer: MetalRenderer?
    private var cache: [UUID: NSImage] = [:]
    private var keys: [UUID: Int] = [:]
    let width = 168, height = 94

    init(store: SharedStore) {
        renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
    }

    func image(for preset: Preset, source: SourceSpec) -> NSImage? {
        var hasher = Hasher()
        hasher.combine(preset)
        hasher.combine(source)
        let key = hasher.finalize()
        if keys[preset.id] == key, let img = cache[preset.id] { return img }

        guard let cg = renderer?.renderThumbnail(preset: preset, source: source, width: width, height: height) else {
            return cache[preset.id]
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        cache[preset.id] = img
        keys[preset.id] = key
        return img
    }
}
