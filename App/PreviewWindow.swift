//  PreviewWindow.swift — full-screen live preview of a screensaver, just like the
//  System Settings "Preview" button. Renders the selected preset with the real
//  Metal pipeline and exits on any key press or mouse input.

import AppKit
import MetalKit

/// Borderless window that can become key (so it receives key events to dismiss).
private final class PreviewNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ScreensaverPreviewController {
    static let shared = ScreensaverPreviewController()

    private var window: NSWindow?
    private var renderer: MetalRenderer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var armed = false

    func present(preset: Preset, source: SourceSpec, store: SharedStore) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let mtk = MTKView(frame: frame)
        mtk.framebufferOnly = true
        mtk.enableSetNeedsDisplay = false
        mtk.isPaused = false
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.layer?.isOpaque = true
        guard let r = MetalRenderer(pixelFormat: mtk.colorPixelFormat, store: store) else { return }
        mtk.device = r.device
        mtk.delegate = r
        r.apply(preset, source: source)
        mtk.preferredFramesPerSecond = preset.fps
        renderer = r

        let win = PreviewNSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // above menu bar & dock
        win.isOpaque = true
        win.backgroundColor = .black
        win.contentView = mtk
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
        win.setFrame(frame, display: true)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        NSCursor.hide()

        // Ignore the click/movement that opened the preview for a brief moment.
        armed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.armed = true }

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .mouseMoved, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            if self.armed { self.dismiss(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self = self, self.armed else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if window != nil { NSCursor.unhide() }
        window?.orderOut(nil)
        window = nil
        renderer = nil
        armed = false
    }
}
