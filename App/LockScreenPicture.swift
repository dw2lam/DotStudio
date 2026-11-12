//  LockScreenPicture.swift — "Use as lock & login screen picture" (Settings › Live Wallpaper).
//
//  A live wallpaper can't run on the lock or login screen; macOS shows the desktop picture
//  there. So, opt-in, a still of the wallpaper's style becomes each screen's desktop picture —
//  invisible on the desktop itself (the live wallpaper's window covers it), shown when the Mac
//  locks and at the login window.
//
//  This file is the mechanism, with the desktop behind a protocol so it is tested against a
//  fake (tools/wallpaper-selftest) and never touches the real desktop there:
//    • saveOriginals — before the first replacement, each screen's own picture (URL + options)
//      is recorded (WallpaperSettings.savedDesktopPictures); never one of ours.
//    • prepare       — renders one still per native pixel size (and per style: each display can
//      play its own) and writes it under a NEW file name each time (macOS caches pictures by
//      URL), off the main thread.
//    • set           — points each screen at its file, then deletes the older files (keeping the
//      previous one, which macOS may still be reading).
//    • restore       — puts the recorded pictures back on screens still showing ours (a picture
//      the user picked meanwhile is left alone), and deletes our files.
//  WallpaperController decides when (lock, style change, every 15 min for time-of-day styles,
//  screen changes) — see its "Lock screen picture" section.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The desktop as the lock-screen picture sees it. Real: NSWorkspace (WorkspaceDesktopPictures);
/// tests: a fake.
protocol DesktopPictures {
    /// The connected screens: a stable key (the display's UUID) and native pixel size.
    func screens() -> [LockScreenPicture.Screen]
    /// The picture a screen shows now, or nil if macOS doesn't say (no file URL).
    func picture(for key: String) -> SavedDesktopPicture?
    func setPicture(_ picture: SavedDesktopPicture, for key: String) throws
}

final class LockScreenPicture {
    struct Screen: Equatable {
        var key: String
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// A rendered still on disk, for the screens of one pixel size.
    struct Prepared {
        var url: URL
        var screens: [String]
    }

    /// Our files: <store>/lockscreen.
    let dir: URL
    let desktop: DesktopPictures

    init(dir: URL, desktop: DesktopPictures) {
        self.dir = dir.standardizedFileURL
        self.desktop = desktop
    }

    /// Whether a picture URL is one of ours.
    func isOurs(_ url: String) -> Bool {
        guard let u = URL(string: url), u.isFileURL else { return false }
        // Compared with symlinks resolved on both sides (standardizing alone drops /private from
        // /private/var… only once the file exists, so the two spellings of one folder differ).
        let parent = u.deletingLastPathComponent()
        return parent.path == dir.path
            || parent.resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path
    }

    /// Record each screen's own picture the first time we're about to replace it. Returns
    /// whether `saved` changed. A screen already showing one of ours (a crash before restore)
    /// keeps whatever was recorded for it.
    @discardableResult
    func saveOriginals(into saved: inout [String: SavedDesktopPicture]) -> Bool {
        var changed = false
        for s in desktop.screens() where saved[s.key] == nil {
            guard let p = desktop.picture(for: s.key), !isOurs(p.url) else { continue }
            saved[s.key] = p
            changed = true
        }
        return changed
    }

    /// Render one still per distinct native pixel size and write each to a fresh file name.
    /// Thread-safe (no shared state but the file system); call it off the main thread.
    /// - render: width, height → the frame (nil = failed; those screens are skipped).
    func prepare(screens: [Screen], render: (Int, Int) -> CGImage?) -> [Prepared] {
        prepare(screens: screens, style: { _ in "" }) { render($0.pixelWidth, $0.pixelHeight) }
    }

    /// One still per distinct (style, native pixel size): screens showing different styles get
    /// stills of their own. Files are named lock-<W>x<H>-<stamp>[-<n>].heic, n counting the
    /// styles of one size in this call.
    /// - style: a screen's style identity (equal = one shared still).
    /// - render: the first screen of a group → the frame (nil = failed; that group is skipped).
    func prepare(screens: [Screen], style: (Screen) -> String, render: (Screen) -> CGImage?) -> [Prepared] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var groups: [String: [Screen]] = [:]
        var order: [(key: String, size: String)] = []
        for s in screens {
            let size = "\(s.pixelWidth)x\(s.pixelHeight)"
            let k = size + "|" + style(s)
            if groups[k] == nil { order.append((k, size)) }
            groups[k, default: []].append(s)
        }
        let stamp = Self.stamp()
        var out: [Prepared] = []
        var perSize: [String: Int] = [:]
        for (k, size) in order {
            guard let group = groups[k], let first = group.first, let image = render(first) else { continue }
            let n = perSize[size, default: 0]
            perSize[size] = n + 1
            let url = dir.appendingPathComponent("lock-\(size)-\(stamp)\(n > 0 ? "-\(n)" : "").heic")
            guard Self.write(image, to: url) else { continue }
            out.append(Prepared(url: url, screens: group.map(\.key)))
        }
        return out
    }

    /// Point each screen at its new still, then delete our older files (keeping the newest
    /// two renders of each size: the new one, and the one macOS may still be reading — every
    /// style's still of a render counts as that render). Returns the keys of the screens set.
    @discardableResult
    func set(_ prepared: [Prepared]) -> [String] {
        var done: [String] = []
        for p in prepared {
            let pic = SavedDesktopPicture(url: p.url.absoluteString,
                                          scaling: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                          allowClipping: true, fillColor: nil)
            for key in p.screens {
                if (try? desktop.setPicture(pic, for: key)) != nil { done.append(key) }
            }
        }
        prune(keep: 2)
        return done
    }

    /// Put back the recorded pictures on screens still showing ours, forget them, and delete
    /// our files. A screen showing something else (the user picked a new picture) keeps it.
    func restore(_ saved: inout [String: SavedDesktopPicture]) {
        let connected = Set(desktop.screens().map(\.key))
        for (key, original) in saved {
            guard connected.contains(key) else { continue }   // not here now: keep it for later
            if let now = desktop.picture(for: key), !isOurs(now.url) {
                saved[key] = nil                                // the user changed it: leave theirs
                continue
            }
            if (try? desktop.setPicture(original, for: key)) != nil { saved[key] = nil }
        }
        // Screens that aren't connected may still show ours next time; their files stay until then.
        if saved.isEmpty { prune(keep: 0) }
    }

    // MARK: Files

    /// Our files, newest first.
    func files() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("lock-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // the stamp sorts by time
    }

    /// Delete all but the newest `keep` renders of each pixel size (a render = the files of one
    /// stamp: one per style shown at that size).
    private func prune(keep: Int) {
        var stamps: [String: [String]] = [:]       // size → stamps, newest first
        var parsed: [(url: URL, size: String, stamp: String)] = []
        for url in files() {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-").map(String.init)
            let size = parts.count > 1 ? parts[1] : ""
            let stamp = parts.count > 2 ? parts[2] : ""
            parsed.append((url, size, stamp))
            if !(stamps[size]?.contains(stamp) ?? false) { stamps[size, default: []].append(stamp) }
        }
        for f in parsed {
            let newest = (stamps[f.size] ?? []).sorted(by: >).prefix(keep)
            if !newest.contains(f.stamp) { try? FileManager.default.removeItem(at: f.url) }
        }
    }

    /// Sortable and unique per call: UTC time to the millisecond, plus a counter.
    private static var counter = 0
    private static let counterLock = NSLock()
    private static func stamp() -> String {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%013lld%04d", ms, counter % 10_000)
    }

    /// HEIC (what macOS's own pictures use; hardware-encoded, a fraction of a PNG's size),
    /// falling back to PNG where HEIC can't be written.
    static func write(_ image: CGImage, to url: URL) -> Bool {
        if let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(d) { return true }
        }
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, image, nil)
        return CGImageDestinationFinalize(d)
    }
}

// MARK: - The real desktop

/// NSWorkspace's desktop pictures, one per screen, screens keyed by display UUID (stable across
/// reconnects and reboots, unlike CGDirectDisplayID). Main thread.
struct WorkspaceDesktopPictures: DesktopPictures {
    func screens() -> [LockScreenPicture.Screen] {
        NSScreen.screens.compactMap { screen in
            guard let key = Self.key(screen) else { return nil }
            let s = screen.backingScaleFactor
            return .init(key: key, pixelWidth: Int((screen.frame.width * s).rounded()),
                         pixelHeight: Int((screen.frame.height * s).rounded()))
        }
    }

    func picture(for key: String) -> SavedDesktopPicture? {
        guard let screen = Self.screen(key), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let o = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        var fill: [Double]?
        if let c = (o[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            fill = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
        }
        return SavedDesktopPicture(url: url.absoluteString,
                                   scaling: (o[.imageScaling] as? NSNumber)?.intValue,
                                   allowClipping: (o[.allowClipping] as? NSNumber)?.boolValue,
                                   fillColor: fill)
    }

    func setPicture(_ p: SavedDesktopPicture, for key: String) throws {
        guard let screen = Self.screen(key), let url = URL(string: p.url) else { return }
        var o: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let s = p.scaling { o[.imageScaling] = NSNumber(value: s) }
        if let c = p.allowClipping { o[.allowClipping] = NSNumber(value: c) }
        if let f = p.fillColor, f.count == 4 {
            o[.fillColor] = NSColor(srgbRed: f[0], green: f[1], blue: f[2], alpha: f[3])
        }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: o)
    }

    static func key(_ screen: NSScreen) -> String? {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func screen(_ key: String) -> NSScreen? {
        NSScreen.screens.first { Self.key($0) == key }
    }
}
