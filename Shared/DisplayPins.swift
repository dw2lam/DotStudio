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
}

enum DisplayIdentity {
    /// The display behind a screen (NSScreenNumber).
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A display's stable key: its UUID as a string (nil for a display that has none).
    static func key(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func key(_ screen: NSScreen) -> String? {
        displayID(screen).flatMap(key)
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
