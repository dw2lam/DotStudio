//  ScrollActivity.swift — whether the user is scrolling one of DotStudio's views right now
//  (a trackpad or Magic Mouse gesture, momentum included: AppKit's live-scroll
//  notifications). While it is, the gallery keeps the main thread for the scroll: tiles
//  sliding under the pointer don't lift or start live previews (StyleTile), and live Metal
//  previews hold their last frame (MetalPreview). Main thread.

import AppKit
import Combine

enum ScrollActivity {
    /// A live scroll is in progress in one of the app's scroll views (still in a window — one
    /// that went away mid-scroll never counts).
    static var isScrolling: Bool { scrolling.allObjects.contains { $0.window != nil } }

    /// This scroll view is being scrolled.
    static func isScrolling(_ view: NSScrollView) -> Bool { scrolling.contains(view) }

    /// Emits on every start (true) and end (false) of a live scroll.
    static var changes: AnyPublisher<Bool, Never> {
        install()
        return subject.eraseToAnyPublisher()
    }

    private static let subject = PassthroughSubject<Bool, Never>()
    private static let scrolling = NSHashTable<NSScrollView>.weakObjects()
    private static var reported = false
    private static var observers: [NSObjectProtocol] = []

    private static func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { n in
                if let v = n.object as? NSScrollView { scrolling.add(v) }
                report()
            },
            nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { n in
                if let v = n.object as? NSScrollView { scrolling.remove(v) }
                report()
            },
        ]
    }

    private static func report() {
        let now = isScrolling
        guard now != reported else { return }
        reported = now
        subject.send(now)
    }
}
