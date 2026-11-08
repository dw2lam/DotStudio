//  Exporter.swift — captures a preset as a still image: PNG export + desktop wallpaper.

import AppKit
import AVFoundation
import MetalKit
import UniformTypeIdentifiers

enum Exporter {
    enum ExportError: LocalizedError {
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: return "The image couldn't be rendered."
            case .encodeFailed: return "The image couldn't be encoded as PNG."
            }
        }
    }

    /// Render one frame of `preset` at `width`×`height` pixels, offscreen.
    /// Video sources capture a frame ~1s in (same as sidebar thumbnails).
    static func renderImage(preset: Preset, library: Library, store: SharedStore,
                            width: Int, height: Int, time: Float) -> CGImage? {
        guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { return nil }
        if let la = library.locationLat, let lo = library.locationLon {
            renderer.location = (la, lo)
        }
        var override: MTLTexture?
        if library.source.kind == .video, let name = library.source.mediaFilename {
            override = videoPoster(url: store.mediaURL(name), device: renderer.device)
        }
        return renderer.renderThumbnail(preset: preset, source: library.source,
                                        width: width, height: height,
                                        time: time, sourceTexOverride: override)
    }

    static func pngData(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Pixel size of a screen (points × backing scale).
    static func pixelSize(of screen: NSScreen) -> (width: Int, height: Int) {
        let s = screen.backingScaleFactor
        return (Int(screen.frame.width * s), Int(screen.frame.height * s))
    }

    /// Render at every screen's native resolution and set each desktop image.
    /// Files are written under Application Support with unique names — macOS
    /// won't refresh a wallpaper whose URL it has already seen.
    static func setAsWallpaper(preset: Preset, library: Library, store: SharedStore) throws {
        let dir = wallpaperDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // One time base for all screens so a multi-monitor desktop is coherent;
        // random so repeated invocations capture a fresh frame of the animation.
        let time = Float.random(in: 2...90)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        // Render one image per distinct resolution, then assign per screen.
        var rendered: [String: URL] = [:]
        var newFiles: [URL] = []
        for screen in NSScreen.screens {
            let (w, h) = pixelSize(of: screen)
            let key = "\(w)x\(h)"
            if rendered[key] == nil {
                guard let cg = renderImage(preset: preset, library: library, store: store,
                                           width: w, height: h, time: time),
                      let data = pngData(cg) else { throw ExportError.renderFailed }
                let url = dir.appendingPathComponent("\(sanitized(preset.name))-\(stamp)-\(key).png")
                try data.write(to: url, options: .atomic)
                rendered[key] = url
                newFiles.append(url)
            }
            try NSWorkspace.shared.setDesktopImageURL(rendered[key]!, for: screen, options: [:])
        }
        cleanOldWallpapers(in: dir, keeping: Set(newFiles.map(\.lastPathComponent)))
    }

    /// Export the preset as a PNG via a save panel, rendered at the main
    /// screen's native resolution.
    static func exportImagePanel(preset: Preset, library: Library, store: SharedStore) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = sanitized(preset.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let (w, h) = screen.map(pixelSize(of:)) ?? (3840, 2160)
        guard let cg = renderImage(preset: preset, library: library, store: store,
                                   width: w, height: h, time: Float.random(in: 2...90))
        else { throw ExportError.renderFailed }
        guard let data = pngData(cg) else { throw ExportError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Helpers

    private static func wallpaperDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DotStudio/Wallpapers", isDirectory: true)
    }

    /// Drop wallpapers from previous invocations so the folder doesn't grow
    /// forever. The files currently referenced by the desktop are kept.
    private static func cleanOldWallpapers(in dir: URL, keeping current: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let inUse = Set(NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.lastPathComponent
        })
        for f in files where f.pathExtension == "png"
            && !current.contains(f.lastPathComponent)
            && !inUse.contains(f.lastPathComponent) {
            try? fm.removeItem(at: f)
        }
    }

    private static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        return name.components(separatedBy: bad).joined(separator: "-")
    }

    /// Grab a frame ~1s into a video, synchronously (export is a one-shot,
    /// user-initiated action; waiting briefly is fine).
    private static func videoPoster(url: URL, device: MTLDevice) -> MTLTexture? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        var poster: CGImage?
        let sem = DispatchSemaphore(value: 0)
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { cg, _, _ in
            poster = cg
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        guard let cg = poster else { return nil }
        // Match ImageSource's loader options so the export renders identically.
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue
        ]
        return try? loader.newTexture(cgImage: cg, options: opts)
    }
}
