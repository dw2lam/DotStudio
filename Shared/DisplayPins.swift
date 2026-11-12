//  DisplayPins.swift — a style of its own on one display.
//
//  With more than one display, each display can play a style of its own instead of what the
//  others play ("Same on all displays", the default). One map per destination, keyed by the
//  display's stable identity:
//    • the screensaver's in library.json (Library.displayStyles), which the sandboxed saver
//      reads — each saver view finds its own display and plays its pin (Playback);
//    • the live wallpaper's in wallpaper.json (WallpaperSettings.displayStyles, app-only).
//  A pin is one style (no per-display playlists or night styles). A pinned style that no longer
//  exists is ignored (that display plays the default) and the pin is dropped on the next save.
//
//  Identity: CGDisplayCreateUUIDFromDisplayID — stable across reboots, reconnects and port
//  changes, unlike CGDirectDisplayID (a session number that a reconnect may hand to another
//  display). The display's name is stored beside the style, for the UI while it's unplugged.

import AppKit
import CoreGraphics

/// One display's own style.
struct DisplayPin: Codable, Equatable, Hashable {
    var presetID: UUID
    /// The display's name when it was pinned (NSScreen.localizedName), for menus while it's
    /// not connected.
    var name: String?
    /// When the display was last seen connected (seconds since 1970; DisplayPins.reconcile), so
    /// the pins of displays long gone can be capped.
    var seen: Double?

    init(presetID: UUID, name: String?, seen: Double? = nil) {
        self.presetID = presetID
        self.name = name
        self.seen = seen
    }
}

enum DisplayPins {
    /// Pins kept for displays that aren't connected (the most recently seen).
    static let keepDisconnected = 8

    /// Bring a pin map in line with the displays connected now (key, name):
    ///   • a connected display with no pin adopts the one disconnected pin carrying its name —
    ///     some displays get a new UUID each session (no serial number);
    ///   • connected pinned displays are stamped as seen (at most hourly, to keep writes rare);
    ///   • only the `keepDisconnected` most recently seen disconnected pins stay.
    /// nil = nothing changed. Pure.
    static func reconcile(_ pins: [String: DisplayPin], connected: [(key: String, name: String)],
                          now: Date = Date()) -> [String: DisplayPin]? {
        guard !pins.isEmpty else { return nil }
        var out = pins
        let t = now.timeIntervalSince1970
        let keys = Set(connected.map(\.key))
        for d in connected where out[d.key] == nil {
            let candidates = out.filter { !keys.contains($0.key) && $0.value.name == d.name }
            guard candidates.count == 1, let (old, pin) = candidates.first else { continue }
            out[old] = nil
            var p = pin
            p.seen = t
            out[d.key] = p
        }
        for d in connected {
            guard var p = out[d.key] else { continue }
            if p.seen.map({ t - $0 > 3600 || $0 > t }) ?? true { p.seen = t; out[d.key] = p }
        }
        let away = out.filter { !keys.contains($0.key) }
            .sorted { ($0.value.seen ?? 0, $0.key) > ($1.value.seen ?? 0, $1.key) }
        for (key, _) in away.dropFirst(keepDisconnected) { out[key] = nil }
        return out == pins ? nil : out
    }
}

enum DisplayIdentity {
    /// The display behind a screen (NSScreenNumber).
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A display's raw UUID as a string (nil for a display that has none). Two identical
    /// monitors without serial numbers can share one: use `key(_ screen:)`, which tells them
    /// apart.
    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// One connected display, for `keys`.
    struct Entry: Equatable {
        var id: CGDirectDisplayID
        var uuid: String
        var x: CGFloat
        var y: CGFloat
    }

    /// Each display's key: its UUID — and where several connected displays share one, the
    /// second and later (left to right, then bottom to top, then display number) get "#2",
    /// "#3"…, the same in the app and in the saver. Pure.
    static func keys(_ entries: [Entry]) -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for (uuid, group) in Dictionary(grouping: entries, by: \.uuid) {
            let ordered = group.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) }
            for (i, e) in ordered.enumerated() { out[e.id] = i == 0 ? uuid : "\(uuid)#\(i + 1)" }
        }
        return out
    }

    /// The connected screens' keys (see `keys`).
    static func keys(_ screens: [NSScreen] = NSScreen.screens) -> [CGDirectDisplayID: String] {
        keys(screens.compactMap { s in
            guard let id = displayID(s), let u = uuid(id) else { return nil }
            return Entry(id: id, uuid: u, x: s.frame.minX, y: s.frame.minY)
        })
    }

    /// A connected display's stable key.
    static func key(_ id: CGDirectDisplayID) -> String? {
        keys()[id] ?? uuid(id)
    }

    static func key(_ screen: NSScreen) -> String? {
        displayID(screen).flatMap(key)
    }
}

extension Playback {
    /// What the screensaver shows, said once for the app (the Screensaver card, the menu bar):
    /// the lineup's style — unless every connected display has a style of its own, then the
    /// first display's (with one display connected, its own style is simply what plays).
    /// `displays`: the connected displays' keys, in the app's order.
    static func shownPreset(in lib: Library, now: Date, displays: [String]) -> Preset {
        if let first = displays.first, displays.allSatisfy({ lib.pinnedPreset(display: $0) != nil }),
           let p = lib.pinnedPreset(display: first) {
            return p
        }
        return effectivePreset(in: lib, now: now)
    }
}

extension Library {
    /// The style pinned to `display` on the screensaver, when it still exists.
    func pinnedPreset(display: String?) -> Preset? {
        guard let display, let id = displayStyles?[display]?.presetID else { return nil }
        return presets.first { $0.id == id }
    }

    /// Drop pins whose style is gone (a style this build can't draw still counts: a newer
    /// DotStudio wrote it, and will want its pin back). Returns whether anything changed.
    @discardableResult
    mutating func pruneDisplayStyles() -> Bool {
        guard let pins = displayStyles else { return false }
        let ids = Set(presets.map(\.id) + unknownPresets.map(\.preset.id))
        let kept = pins.filter { ids.contains($0.value.presetID) }
        let next = kept.isEmpty ? nil : kept
        guard next != displayStyles else { return false }
        displayStyles = next
        return true
    }
}
