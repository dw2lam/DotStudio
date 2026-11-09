//  PreviewWindow.swift — full-screen live preview of a screensaver, just like the
//  System Settings "Preview" button. Renders the selected preset with the real
//  Metal pipeline and exits on any key press or mouse input. Music shows as it would in
//  the saver: a Now Playing style's foreground, or the corner card over any other style.

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
    private var musicToken: MusicFeedHub.Token?

    /// - music: the library's music settings (card on/off, corner); nil = read them from
    ///   the stored library.
    func present(preset: Preset, source: SourceSpec, store: SharedStore, music: MusicSpec? = nil) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let mtk = MTKView(frame: CGRect(origin: .zero, size: frame.size))
        mtk.framebufferOnly = true
        mtk.enableSetNeedsDisplay = false
        mtk.isPaused = false
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.layer?.isOpaque = true
        mtk.autoresizingMask = [.width, .height]
        guard let r = MetalRenderer(pixelFormat: mtk.colorPixelFormat, store: store) else { return }
        mtk.device = r.device
        mtk.delegate = r
        r.reduceMotion = MusicOverlayLayer.systemReduceMotion
        r.apply(preset, source: source)
        mtk.preferredFramesPerSecond = preset.fps
        renderer = r

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(mtk)
        let settings = music ?? store.load()?.musicSettings ?? MusicSpec()
        let mode: MusicOverlayLayer.Mode = preset.musicScene.map { .full(MusicSceneOptions($0)) }
            ?? (settings.isCardEnabled ? .card(settings.corner) : .hidden)
        if mode != .hidden {
            let ov = MusicOverlayView(frame: container.bounds)
            container.addSubview(ov, positioned: .above, relativeTo: mtk)
            r.musicLingerMinutes = settings.linger
            musicToken = MusicFeedHub.shared.subscribe(store: store) { [weak r, weak ov] snap, changed in
                if changed { r?.setMusic(snap) }
                ov?.overlay.update(mode: mode, music: snap, settings: settings)
            }
        }

        let win = PreviewNSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // above menu bar & dock
        win.isOpaque = true
        win.backgroundColor = .black
        win.contentView = container
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
        musicToken = nil
        window?.orderOut(nil)
        window = nil
        renderer = nil
        armed = false
    }
}
