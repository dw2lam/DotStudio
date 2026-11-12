//  WallpaperSlot.swift — the gallery's view of the live desktop wallpaper.
//
//  The gallery (Wallpaper destination card, tile badges, "Set as Wallpaper") only ever
//  talks to this adapter. WallpaperController, which draws the wallpaper, plugs in its
//  Backend when it's attached to the model (`connect`); the UI demos and shots use an
//  in-memory one (`.memory`). Until a backend connects it runs on `.stub`: nothing is
//  ever active and set/stop do nothing.

import Foundation
import Combine

final class WallpaperSlot: ObservableObject {
    struct Backend {
        /// The style currently playing as the wallpaper, or nil when it's off.
        var styleID: () -> UUID?
        /// Start (or switch) the wallpaper to this style.
        var set: (UUID) -> Void
        /// Turn the wallpaper off.
        var stop: () -> Void
        /// Fires whenever the backend's state changes on its own (menu bar, display
        /// change, another window). Optional — set/stop through the slot refresh anyway.
        var changes: AnyPublisher<Void, Never>? = nil
        /// False hides wallpaper controls entirely (e.g. no backend in this build).
        var isAvailable = true
        /// Displays with a style of their own (display key → pin; Shared/DisplayPins.swift).
        var pins: () -> [String: DisplayPin] = { [:] }
        /// Give a display a style of its own (nil: back to the shared pick). Starts the
        /// wallpaper when it's off.
        var setPin: (String, DisplayPin?) -> Void = { _, _ in }
        /// Every display plays the shared pick again.
        var clearPins: () -> Void = {}
        /// A deleted style's pins go.
        var forget: (UUID) -> Void = { _ in }
        /// The wallpaper follows the screensaver (each display shows what its screensaver shows).
        var follows: () -> Bool = { false }

        static let stub = Backend(styleID: { nil }, set: { _ in }, stop: {})
    }

    static let shared = WallpaperSlot(backend: DemoHooks.wallpaperStub ?? .stub)

    /// The style on the desktop right now (every display without one of its own); nil =
    /// wallpaper off.
    @Published private(set) var styleID: UUID?
    /// Displays playing a style of their own (display key → pin), whether or not they're
    /// connected now. Unused while the wallpaper follows the screensaver.
    @Published private(set) var pins: [String: DisplayPin] = [:]
    /// Following the screensaver ("Same as Screensaver"): the pins are kept but unused.
    @Published private(set) var follows = false
    var isActive: Bool { styleID != nil }
    var isAvailable: Bool { backend.isAvailable }

    private var backend: Backend
    private var subscription: AnyCancellable?

    init(backend: Backend) {
        self.backend = backend
        hookUp()
    }

    /// Swap in the real backend.
    func connect(_ backend: Backend) {
        self.backend = backend
        hookUp()
    }

    func set(_ id: UUID) {
        Breadcrumbs.note("wallpaper start \(id.uuidString.prefix(8))")
        // One display connected, with a style of its own: setting a wallpaper means there.
        let roster = DisplayRoster.shared.displays
        if roster.count == 1, backend.pins()[roster[0].key] != nil { backend.setPin(roster[0].key, nil) }
        backend.set(id)
        refresh()
    }

    /// The shared pick moves (a deleted style's replacement), every display's own style kept.
    func setShared(_ id: UUID) { backend.set(id); refresh() }
    func stop() { Breadcrumbs.note("wallpaper stop"); backend.stop(); refresh() }
    func toggle(_ id: UUID) { styleID == id ? stop() : set(id) }

    /// One display plays `id` (nil: the shared pick again).
    func set(_ id: UUID?, on display: DisplayInfo) {
        Breadcrumbs.note("wallpaper display \(display.shortName): \(id.map { String($0.uuidString.prefix(8)) } ?? "shared")")
        backend.setPin(display.key, id.map { DisplayPin(presetID: $0, name: display.name) })
        refresh()
    }

    /// Every display plays `id`: the shared pick, and no display keeps a style of its own.
    func setEverywhere(_ id: UUID) {
        backend.clearPins()
        set(id)
    }

    /// Every display plays the shared pick again.
    func clearPins() { backend.clearPins(); refresh() }

    /// A deleted style: its pins go.
    func forget(_ id: UUID) { backend.forget(id); refresh() }

    /// Re-read the backend's state.
    func refresh() {
        let id = backend.styleID()
        if id != styleID { styleID = id }
        let p = backend.pins()
        if p != pins { pins = p }
        let f = backend.follows()
        if f != follows { follows = f }
    }

    private func hookUp() {
        subscription = backend.changes?
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }
}

extension WallpaperSlot.Backend {
    /// In-memory stand-in for design captures (DOTSTUDIO_DEMO_WALLPAPER_STUB): remembers
    /// the pick so the card and badges can be seen in their "on" state. Never shipped on.
    static func memory(initial: UUID?) -> Self {
        final class Box {
            var id: UUID?
            var pins: [String: DisplayPin] = [:]
            init(_ id: UUID?) { self.id = id }
        }
        let box = Box(initial)
        var b = Self(styleID: { box.id }, set: { box.id = $0 }, stop: { box.id = nil })
        b.pins = { box.pins }
        b.setPin = { key, pin in
            box.pins[key] = pin
            if let pin, box.id == nil { box.id = pin.presetID }
        }
        b.clearPins = { box.pins = [:] }
        b.forget = { id in box.pins = box.pins.filter { $0.value.presetID != id } }
        b.follows = { WallpaperController.shared.followsScreensaver }   // shots set it on the controller
        return b
    }
}
