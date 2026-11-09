//  MusicFeedHub.swift — one MusicFeed for the whole app (main thread): the live wallpaper,
//  in-app previews, the full-screen preview and the thumbnailer all listen to it, so
//  music.json is stat'ed once a second and each new cover decoded once, however many
//  views show it. The timer runs only while someone listens.

import Foundation
import QuartzCore

final class MusicFeedHub {
    static let shared = MusicFeedHub()

    /// A listener registration; dropping (or `cancel()`ing) it unsubscribes.
    final class Token {
        fileprivate let id = UUID()
        fileprivate weak var hub: MusicFeedHub?
        fileprivate init(_ hub: MusicFeedHub) { self.hub = hub }
        func cancel() { hub?.remove(id) }
        deinit { cancel() }
    }

    private var feed: MusicFeed?
    private var timer: Timer?
    private var lastPoll: CFTimeInterval = -.infinity
    /// (snapshot, changed) — `changed` = music.json or the artwork changed since the last tick.
    private var listeners: [UUID: (MusicSnapshot, Bool) -> Void] = [:]

    /// The latest snapshot (polls first if the last poll is older than a quarter second).
    func snapshot(store: SharedStore) -> MusicSnapshot {
        ensureFeed(store)
        poll()
        return feed?.snapshot ?? .empty
    }

    /// Call `handler` about once a second (and now) with the current snapshot. Main thread.
    func subscribe(store: SharedStore, _ handler: @escaping (MusicSnapshot, _ changed: Bool) -> Void) -> Token {
        ensureFeed(store)
        let t = Token(self)
        listeners[t.id] = handler
        poll()
        handler(feed?.snapshot ?? .empty, true)
        if timer == nil {
            let tm = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            tm.tolerance = 0.15
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        }
        return t
    }

    private func remove(_ id: UUID) {
        listeners.removeValue(forKey: id)
        if listeners.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func ensureFeed(_ store: SharedStore) {
        if feed == nil { feed = MusicFeed(baseDir: store.baseDir) }
    }

    @discardableResult
    private func poll() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastPoll >= 0.25 else { return false }
        lastPoll = now
        return feed?.poll() ?? false
    }

    private func tick() {
        poll()
        let snap = feed?.snapshot ?? .empty
        // Compare revisions rather than trusting this poll: a `snapshot(store:)` call between
        // ticks may have been the one that saw the change.
        let changed = snap.revision != deliveredRevision
        deliveredRevision = snap.revision
        for l in Array(listeners.values) { l(snap, changed) }
    }
    private var deliveredRevision = -1
}
