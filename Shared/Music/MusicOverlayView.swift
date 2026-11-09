//  MusicOverlayView.swift — an AppKit host for MusicOverlayLayer: put it above a Metal
//  view (same frame, autoresizing) and it keeps the layer's size and scale in step with the
//  window. Clicks pass straight through.

import AppKit

final class MusicOverlayView: NSView {
    let overlay = MusicOverlayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: AppKit never draws into or rearranges the overlay's sublayers.
        layer = overlay
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        overlay.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        CATransaction.commit()
        overlay.setNeedsLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
    }

    private func syncScale() {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard overlay.contentsScale != s else { return }
        overlay.contentsScale = s
        overlay.setNeedsLayout()
    }
}
