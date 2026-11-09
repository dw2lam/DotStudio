//  PreviewWindow.swift — full-screen live preview of a screensaver, just like the
//  System Settings "Preview" button. Renders the selected preset with the real
//  Metal pipeline and exits on any key press or mouse input. Music shows exactly as it would
//  in the saver (MusicPresentation): Corner, or Full Screen with its backdrop easing in and
//  out as music starts and stops — and a legacy Now Playing style's own foreground.

import AppKit
import MetalKit

/// Borderless window that can become key (so it receives key events to dismiss).
private final class PreviewNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ScreensaverPreviewController: ObservableObject {
    static let shared = ScreensaverPreviewController()

    /// A Now Playing style is up full screen: MusicLifecycle keeps the players watched for it
    /// (like a Now Playing style in the editor), whatever Show music says.
    @Published private(set) var musicScene = false

    private var window: NSWindow?
    private var renderer: MetalRenderer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var armed = false
    private var musicToken: MusicFeedHub.Token?

    /// - music: the library's music settings (Show music, corner, backdrop); nil = read them
    ///   from the stored library.
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
        if preset.isMusicScene || settings.displayMode != .off {
            let ov = MusicOverlayView(frame: container.bounds)
            container.addSubview(ov, positioned: .above, relativeTo: mtk)
            r.musicLingerMinutes = settings.linger
            var first = true   // music already playing is simply there; later changes ease
            musicToken = MusicFeedHub.shared.subscribe(store: store) { [weak r, weak ov] snap, changed in
                if changed { r?.setMusic(snap) }
                let p = MusicPresentation.resolve(settings: settings, music: snap, preset: preset)
                r?.setMusicBackdrop(p.backdrop, animated: !first)
                ov?.overlay.update(mode: p.overlay, music: snap, settings: settings, animated: !first)
                first = false
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
        if preset.isMusicScene { musicScene = true }

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
        if musicScene { musicScene = false }
    }
}
