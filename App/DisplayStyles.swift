//  DisplayStyles.swift — "a different style on each display": the connected displays as the
//  UI sees them (DisplayRoster), the screensaver's per-display styles on the model, and the
//  Displays menu both destination cards share.
//
//  Stored as pins (Shared/DisplayPins.swift): the screensaver's in library.json, the
//  wallpaper's in wallpaper.json (through WallpaperSlot). Every control here appears only while
//  more than one display is connected: a single display looks exactly as before.

import AppKit
import Combine
import SwiftUI

/// One connected display, as the menus name it.
struct DisplayInfo: Identifiable, Equatable, Hashable {
    /// DisplayIdentity.key: stable across reconnects and reboots.
    let key: String
    /// NSScreen.localizedName ("Built-in Retina Display", "LG HDR 4K"); numbered when two
    /// connected displays share a name.
    let name: String
    let isBuiltIn: Bool
    var id: String { key }

    /// A word or two for a badge: "Built-in", or the name's first word ("LG", "DELL") — the
    /// whole name when that word wouldn't tell it apart.
    let shortName: String
}

/// The connected displays, built-in first, then left to right (System Settings' arrangement),
/// kept current as displays come and go. Main thread.
final class DisplayRoster: ObservableObject {
    static let shared = DisplayRoster()

    @Published private(set) var displays: [DisplayInfo] = []
    /// More than one display: the per-display controls show.
    var isMulti: Bool { displays.count > 1 }

    /// UI shots / demos (DOTSTUDIO_DEMO_DISPLAYS=2): a made-up second display beside the real
    /// ones, so the per-display controls render on a one-display Mac. Never touches a real
    /// display: only the menus see it.
    private var demoExtra: [DisplayInfo] = []
    private var observer: NSObjectProtocol?

    static let demoDisplay = DisplayInfo(key: "DEMO-DISPLAY-LG-HDR-4K", name: "LG HDR 4K", isBuiltIn: false,
                                         shortName: "LG")

    private init() {
        if ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_DISPLAYS"].flatMap(Int.init).map({ $0 > 1 }) == true {
            demoExtra = [Self.demoDisplay]
        }
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Shots: add (or drop) the made-up second display.
    func setDemo(_ on: Bool) {
        demoExtra = on ? [Self.demoDisplay] : []
        refresh()
    }

    func refresh() {
        let real = Self.read(NSScreen.screens)
        let next = real + demoExtra.filter { d in !real.contains { $0.key == d.key } }
        if next != displays { displays = next }
    }

    /// The display for a key, if connected.
    func display(_ key: String) -> DisplayInfo? { displays.first { $0.key == key } }

    static func read(_ screens: [NSScreen]) -> [DisplayInfo] {
        struct Raw { let key: String; let name: String; let builtIn: Bool; let x: CGFloat; let y: CGFloat }
        let raw: [Raw] = screens.compactMap { s in
            guard let id = DisplayIdentity.displayID(s), let key = DisplayIdentity.key(id) else { return nil }
            return Raw(key: key, name: s.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0,
                       x: s.frame.minX, y: s.frame.minY)
        }
        let sorted = raw.sorted { a, b in
            if a.builtIn != b.builtIn { return a.builtIn }
            return a.x != b.x ? a.x < b.x : a.y < b.y
        }
        return label(sorted.map { ($0.key, $0.name, $0.builtIn) })
    }

    /// Names and short names, numbered where two displays share a name.
    static func label(_ list: [(key: String, name: String, builtIn: Bool)]) -> [DisplayInfo] {
        var seen: [String: Int] = [:]
        let counts = Dictionary(list.map { ($0.name, 1) }, uniquingKeysWith: +)
        let firstWords = Dictionary(list.map { (firstWord($0.name), 1) }, uniquingKeysWith: +)
        return list.map { d in
            var name = d.name
            var short = d.builtIn ? "Built-in" : firstWord(d.name)
            // Another display starting with the same word: the short name is the whole name.
            if !d.builtIn, (firstWords[firstWord(d.name)] ?? 0) > 1 { short = d.name }
            if (counts[d.name] ?? 0) > 1 {
                let n = (seen[d.name] ?? 0) + 1
                seen[d.name] = n
                name += " (\(n))"
                short += " \(n)"
            }
            return DisplayInfo(key: d.key, name: name, isBuiltIn: d.builtIn, shortName: short)
        }
    }

    private static func firstWord(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }
}

// MARK: - The screensaver's per-display styles

extension AppModel {
    /// Displays whose screensaver plays a style of its own (pins whose style still exists).
    var screensaverPins: [String: DisplayPin] {
        (library.displayStyles ?? [:]).filter { preset($0.value.presetID) != nil }
    }

    /// One display's screensaver plays `id` (nil: the lineup, like every other display).
    func setScreensaverStyle(_ id: UUID?, on display: DisplayInfo) {
        Breadcrumbs.note("screensaver display \(display.shortName): \(crumbName(id))")
        var pins = library.displayStyles ?? [:]
        pins[display.key] = id.map { DisplayPin(presetID: $0, name: display.name) }
        library.displayStyles = pins.isEmpty ? nil : pins
        save()
    }

    /// Every display plays the lineup again.
    func clearScreensaverPins() {
        guard library.displayStyles != nil else { return }
        library.displayStyles = nil
        save()
    }

    /// "Set as Screensaver on ▸ All Displays": this style alone, on every display.
    func playAsScreensaverEverywhere(_ id: UUID) {
        library.displayStyles = nil
        playAsScreensaver(id)   // saves
    }
}

// MARK: - Who plays where, per display

/// What each connected display shows on each destination, for the badges and the menus.
struct DisplayLineup: Equatable {
    /// Connected displays, in roster order.
    let displays: [DisplayInfo]
    /// Display key → the style its screensaver shows now (its own, else the lineup's).
    let screensaver: [String: UUID]
    /// Display key → its wallpaper's style while the wallpaper is on.
    let wallpaper: [String: UUID]
    /// Displays with a screensaver / wallpaper style of their own (connected ones only).
    let screensaverPinned: Set<String>
    let wallpaperPinned: Set<String>

    static let single = DisplayLineup(displays: [], screensaver: [:], wallpaper: [:], screensaverPinned: [],
                                      wallpaperPinned: [])

    var isMulti: Bool { displays.count > 1 }

    init(displays: [DisplayInfo], screensaver: [String: UUID], wallpaper: [String: UUID],
         screensaverPinned: Set<String>, wallpaperPinned: Set<String>) {
        self.displays = displays
        self.screensaver = screensaver
        self.wallpaper = wallpaper
        self.screensaverPinned = screensaverPinned
        self.wallpaperPinned = wallpaperPinned
    }

    /// - wallpaperShared: the wallpaper's shared style (nil = off); `wallpaperPins` its own
    ///   per-display styles; `synced`: it follows the screensaver (each display shows what
    ///   that display's screensaver shows).
    init(model: AppModel, displays: [DisplayInfo], wallpaperShared: UUID?, wallpaperPins: [String: DisplayPin],
         synced: Bool) {
        guard displays.count > 1, !model.library.presets.isEmpty else { self = .single; return }
        let lib = model.library
        let now = Date()
        let shared = Playback.effectivePreset(in: lib, now: now).id
        var ss: [String: UUID] = [:], wp: [String: UUID] = [:]
        var ssPinned = Set<String>(), wpPinned = Set<String>()
        for d in displays {
            let own = lib.pinnedPreset(display: d.key)?.id
            ss[d.key] = own ?? shared
            if own != nil { ssPinned.insert(d.key) }
            guard let wShared = wallpaperShared else { continue }
            if synced {
                // Following the screensaver: a display whose screensaver has a style of its own
                // shows that style as its wallpaper too.
                wp[d.key] = ss[d.key]
                if own != nil { wpPinned.insert(d.key) }
            } else if let pin = wallpaperPins[d.key]?.presetID, model.preset(pin) != nil {
                wp[d.key] = pin
                wpPinned.insert(d.key)
            } else {
                wp[d.key] = wShared
            }
        }
        self.init(displays: displays, screensaver: ss, wallpaper: wp, screensaverPinned: ssPinned,
                  wallpaperPinned: wpPinned)
    }

    /// The one display a style plays on, when the style plays on some displays but not all.
    func onlyDisplay(_ id: UUID, in map: [String: UUID]) -> DisplayInfo? {
        guard isMulti else { return nil }
        let on = displays.filter { map[$0.key] == id }
        return on.count == 1 ? on[0] : nil
    }

    /// Displays that play `id` as a style of their own.
    func pinned(_ id: UUID, screensaver: Bool) -> [DisplayInfo] {
        let set = screensaver ? screensaverPinned : wallpaperPinned
        let map = screensaver ? self.screensaver : wallpaper
        return displays.filter { set.contains($0.key) && map[$0.key] == id }
    }
}

// MARK: - The Displays menu

/// The Displays key's menu, on both cards: "Same on All Displays" (checked when no display has a
/// style of its own), then a submenu per connected display — "LG HDR 4K: Golden Hour" — with
/// "Same as Other Displays" and every style (Scenes / Looks, like the Night and Style menus).
/// Unplugged displays that still have a style of their own are listed after, so it can be
/// cleared.
struct DisplayStylesMenuItems: View {
    @EnvironmentObject var model: AppModel
    let displays: [DisplayInfo]
    /// The destination's pins (connected or not).
    let pins: [String: DisplayPin]
    /// A line at the top (the wallpaper while it follows the screensaver), if any.
    var note: String? = nil
    let set: (UUID?, DisplayInfo) -> Void
    let clearAll: () -> Void

    var body: some View {
        let live = pins.filter { model.preset($0.value.presetID) != nil }
        let connected = Set(displays.map(\.key))
        if let note { Text(note) }
        Button { Motion.run { clearAll() } } label: {
            let none = !live.keys.contains(where: connected.contains)
            if none { Label("Same on All Displays", systemImage: "checkmark") } else { Text("Same on All Displays") }
        }
        Divider()
        ForEach(displays) { d in
            let own = live[d.key].flatMap { model.preset($0.presetID) }
            Menu(menuName("\(d.name): \(own?.name ?? "Same as Others")", limit: 44)) {
                Button { Motion.run { set(nil, d) } } label: {
                    if own == nil { Label("Same as Other Displays", systemImage: "checkmark") } else { Text("Same as Other Displays") }
                }
                Divider()
                StyleMenuItems(current: own?.id) { set($0, d) }
            }
        }
        let away = live.filter { !connected.contains($0.key) }.sorted { ($0.value.name ?? "") < ($1.value.name ?? "") }
        if !away.isEmpty {
            Section("Not Connected") {
                ForEach(away, id: \.key) { key, pin in
                    let info = DisplayInfo(key: key, name: pin.name ?? "Display", isBuiltIn: false,
                                           shortName: pin.name ?? "Display")
                    Button("Forget \(menuName(pin.name ?? "Display", limit: 24)): \(menuName(model.preset(pin.presetID)?.name ?? "", limit: 24))") {
                        set(nil, info)
                    }
                }
            }
        }
    }
}

/// The Displays key's value, longest first: "Same on all" / "LG: Golden Hour" / "Per display".
func displayKeyValues(displays: [DisplayInfo], pins: [String: DisplayPin], model: AppModel) -> (values: [String], on: Bool) {
    let own = displays.compactMap { d in pins[d.key].flatMap { model.preset($0.presetID) }.map { (d, $0) } }
    switch own.count {
    case 0: return (["Same on all", "Same"], false)
    case 1: return (["\(own[0].0.shortName): \(own[0].1.name)", own[0].1.name], true)
    default: return (["Per display"], true)
    }
}

// MARK: - "Set as Screensaver on ▸" / "Set as Wallpaper on ▸"

/// One item of a tile's per-display submenu: "All Displays", then each connected display.
struct DisplayChoice {
    let title: String
    let checked: Bool
    let action: () -> Void
}

enum DisplayChoices {
    /// "Set as Screensaver on ▸": All Displays (this style alone, everywhere) — then each
    /// display: play it there as that display's own style (checked: it plays there now; picking
    /// a display it's pinned to gives that display back to the lineup).
    static func screensaver(_ id: UUID, model: AppModel, displays: [DisplayInfo]) -> [DisplayChoice] {
        let pins = model.screensaverPins
        let alone = model.screensaverLineup.playlist == [id]
        let connectedPinned = displays.contains { pins[$0.key] != nil }
        var out = [DisplayChoice(title: "All Displays", checked: alone && !connectedPinned) {
            Motion.run { model.playAsScreensaverEverywhere(id) }
        }]
        for d in displays {
            let pinned = pins[d.key]?.presetID == id
            let shows = pinned || (pins[d.key] == nil && alone)
            out.append(DisplayChoice(title: d.name, checked: shows) {
                Motion.run { model.setScreensaverStyle(pinned ? nil : id, on: d) }
            })
        }
        return out
    }

    /// "Set as Wallpaper on ▸": All Displays (the wallpaper's style everywhere, no display keeps
    /// one of its own) — then each display (picking one it's pinned to gives it back to the
    /// shared pick).
    static func wallpaper(_ id: UUID, model: AppModel, slot: WallpaperSlot, displays: [DisplayInfo]) -> [DisplayChoice] {
        let lineup = DisplayLineup(model: model, displays: displays, wallpaperShared: slot.styleID,
                                   wallpaperPins: slot.pins, synced: slot.follows)
        let everywhere = !slot.follows && slot.styleID == id && lineup.wallpaperPinned.isEmpty
        var out = [DisplayChoice(title: "All Displays", checked: everywhere) {
            Motion.run { slot.setEverywhere(id) }
        }]
        for d in displays {
            let pinned = !slot.follows && slot.pins[d.key]?.presetID == id
            out.append(DisplayChoice(title: d.name, checked: lineup.wallpaper[d.key] == id) {
                Motion.run { slot.set(pinned ? nil : id, on: d) }
            })
        }
        return out
    }
}

/// One of those submenus in a SwiftUI menu (the tile's context menu).
struct DisplayChoiceMenu: View {
    let title: String
    let choices: [DisplayChoice]

    var body: some View {
        Menu(title) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                Button(action: c.action) {
                    if c.checked { Label(menuName(c.title, limit: 40), systemImage: "checkmark") } else { Text(menuName(c.title, limit: 40)) }
                }
                if i == 0 { Divider() }
            }
        }
    }
}
