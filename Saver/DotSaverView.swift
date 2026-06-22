//  DotSaverView.swift — the universal screensaver. Renders whichever preset is
//  marked active in the shared library, and live-reloads when that changes.

import ScreenSaver
import MetalKit

@objc(DotSaverView)
final class DotSaverView: ScreenSaverView {
    private let store = SharedStore(role: .saver)
    private var metalView: MTKView?
    private var renderer: MetalRenderer?
    private var activeID: UUID?
    private var lastModified: Date?
    private var frameTick = 0

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 30.0
        let view = MTKView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = true
        // The screensaver host doesn't run MTKView's display link, so we drive
        // each frame manually from animateOneFrame().
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = true
        try? FileManager.default.removeItem(at: store.baseDir.appendingPathComponent("debug.log"))
        store.debug("=== commonInit \(Date()) bounds=\(bounds) isPreview=\(isPreview) ===")
        guard let r = MetalRenderer(pixelFormat: view.colorPixelFormat, store: store) else {
            store.debug("MetalRenderer init returned nil — black screen")
            return
        }
        view.device = r.device
        view.delegate = r
        renderer = r
        metalView = view
        addSubview(view)
        store.debug("renderer ready, store base=\(store.baseDir.path)")
        reload(force: true)
    }

    private func reload(force: Bool) {
        let mod = store.libraryModified()
        guard let lib = store.load(), !lib.presets.isEmpty else {
            if force {
                store.debug("reload: library MISSING/empty at \(store.libraryURL.path) — gradient fallback")
                renderer?.apply(Preset(name: "Default"), source: SourceSpec())
            }
            return
        }
        let active = lib.presets.first { $0.id == lib.activeID } ?? lib.presets.first!
        let changed = force || active.id != activeID || mod != lastModified
        if force { store.debug("reload active=\(active.name) effects=\(active.effects.count) sourceKind=\(lib.source.kind.rawValue)") }
        if changed {
            activeID = active.id
            lastModified = mod
            if let la = lib.locationLat, let lo = lib.locationLon {
                renderer?.location = (la, lo)
            }
            renderer?.apply(active, source: lib.source)
            animationTimeInterval = 1.0 / Double(max(active.fps, 1))
        }
    }

    override func animateOneFrame() {
        guard let mv = metalView else { return }
        if mv.frame.size != bounds.size { mv.frame = bounds }   // catch up if we started 0×0
        frameTick += 1
        if frameTick % 30 == 0 { reload(force: false) }         // poll for edits ~1×/sec
        mv.draw()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
