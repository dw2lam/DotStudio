//  MusicFeed.swift — CONTRACT: the reader side of music.json, used by every renderer host
//  (saver, wallpaper, previews, thumbnails). One instance per host; call `poll()` from the
//  host's own thread about once a second — it only stats the file unless it changed.
//
//  Test hook: DOTSTUDIO_MUSIC_FAKE=<path to a MusicState JSON> reads that file instead (its
//  `artwork` resolves next to it), so fixture tracks render without any real player.

import Foundation
import CoreGraphics
import ImageIO

final class MusicFeed {
    let fileURL: URL
    let artDir: URL

    private(set) var state: MusicState?
    /// Decoded artwork (sRGB, long edge ≤ `maxArtPixels`), or nil (draw a placeholder).
    private(set) var artwork: CGImage?
    /// Bumps whenever `state` or `artwork` changes — cheap change detection for hosts.
    private(set) var revision = 0

    var maxArtPixels = 1400
    private var lastModified: Date?
    private var artName: String?

    init(baseDir: URL) {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_MUSIC_FAKE"], !fake.isEmpty {
            fileURL = URL(fileURLWithPath: fake)
            artDir = fileURL.deletingLastPathComponent()
        } else {
            fileURL = baseDir.appendingPathComponent(MusicState.fileName)
            artDir = baseDir.appendingPathComponent(MusicState.artDirName, isDirectory: true)
        }
    }

    /// Re-reads music.json if its mtime changed. Returns true when state or artwork changed.
    @discardableResult
    func poll() -> Bool {
        let mod = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        guard mod != lastModified else { return false }
        lastModified = mod
        let new: MusicState? = mod == nil ? nil
            : (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(MusicState.self, from: $0) }
        var changed = new != state
        state = new
        if new?.artwork != artName {
            artName = new?.artwork
            artwork = artName.flatMap { decodeArtwork(artDir.appendingPathComponent($0)) }
            changed = true
        }
        if changed { revision &+= 1 }
        return changed
    }

    /// Whether the card / Now Playing foreground should show right now.
    func isVisible(settings: MusicSpec, at now: Date = Date()) -> Bool {
        state?.isVisible(at: now, lingerMinutes: settings.linger) ?? false
    }

    private func decodeArtwork(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxArtPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
