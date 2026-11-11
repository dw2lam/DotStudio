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

        static let stub = Backend(styleID: { nil }, set: { _ in }, stop: {})
    }

    static let shared = WallpaperSlot(backend: DemoHooks.wallpaperStub ?? .stub)

    /// The style on the desktop right now; nil = wallpaper off.
    @Published private(set) var styleID: UUID?
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

    func set(_ id: UUID) { Breadcrumbs.note("wallpaper start \(id.uuidString.prefix(8))"); backend.set(id); refresh() }
    func stop() { Breadcrumbs.note("wallpaper stop"); backend.stop(); refresh() }
    func toggle(_ id: UUID) { styleID == id ? stop() : set(id) }

    /// Re-read the backend's state.
    func refresh() {
        let id = backend.styleID()
        if id != styleID { styleID = id }
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
        final class Box { var id: UUID? ; init(_ id: UUID?) { self.id = id } }
        let box = Box(initial)
        return .init(styleID: { box.id }, set: { box.id = $0 }, stop: { box.id = nil })
    }
}
