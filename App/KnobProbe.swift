//  KnobProbe.swift — DEV-ONLY check that a Retro dial turns under the mouse inside a List
//  whose rows can be reordered (the editor's layers), where a SwiftUI drag gesture lost the
//  mouse to the row's reorder drag. DOTSTUDIO_KNOB_PROBE=1: hosts dials in such a List in a
//  fully transparent window parked far off screen (never key), sends it a press–drag–release and a
//  double-click through NSApp.sendEvent (no real input, no sound), prints the values, exits.
#if DEBUG
import AppKit
import SwiftUI

enum KnobProbe {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["DOTSTUDIO_KNOB_PROBE"] != nil else { return }
        final class Box: ObservableObject { @Published var values: [Double] = [0.5, 0.5] }
        struct Probe: View {
            @ObservedObject var box: Box
            var body: some View {
                List {
                    ForEach(box.values.indices, id: \.self) { i in
                        ConsoleKnob(label: "knob \(i)", value: $box.values[i], range: 0...1,
                                    defaultValue: 0.5, colorIndex: i, format: { String(format: "%.3f", $0) })
                    }
                    .onMove { _, _ in }
                }
                .frame(width: 300, height: 400)
            }
        }
        let box = Box()
        let host = NSHostingView(rootView: Probe(box: box))
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        // Ordered in (AppKit drops mouse events for a window that isn't) but fully transparent,
        // far off every screen, and never key: nothing ever shows.
        w.alphaValue = 0
        w.ignoresMouseEvents = false
        w.orderFrontRegardless()
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // the first dial's catcher: the first NSView subclass named *Catcher*
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).contains("Catcher") { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        guard let catcher = find(host) else { print("knob probe: FAIL (no catcher)"); exit(1) }
        let c = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        // Posted into this app's own event queue (never the system's) and dispatched by the
        // app's run loop, as real clicks are — so the window's hit-testing runs as it does live.
        func post(_ e: NSEvent) { NSApp.postEvent(e, atStart: false) }
        func pump(_ s: Double) {
            let end = Date().addingTimeInterval(s)
            while Date() < end {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                }
            }
        }
        let before = box.values[0]
        post(ev(.leftMouseDown, c))
        for k in 1...6 { post(ev(.leftMouseDragged, NSPoint(x: c.x, y: c.y + CGFloat(k * 6)))) }
        post(ev(.leftMouseUp, NSPoint(x: c.x, y: c.y + 36)))
        pump(0.4)
        let after = box.values[0]
        post(ev(.leftMouseDown, c, clicks: 2))
        post(ev(.leftMouseUp, c, clicks: 2))
        pump(0.3)
        let reset = box.values[0]
        let ok = after > before + 0.1 && abs(reset - 0.5) < 1e-9
        print(String(format: "knob probe: before %.3f after drag up 36pt %.3f after double-click %.3f — %@",
                     before, after, reset, ok ? "PASS" : "FAIL"))
        exit(ok ? 0 : 1)
    }
}
#endif
