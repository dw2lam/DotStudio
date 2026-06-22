//  MetalPreview.swift — live Metal preview of a preset inside SwiftUI.

import SwiftUI
import MetalKit

struct MetalPreview: NSViewRepresentable {
    let preset: Preset
    let source: SourceSpec
    let location: (lat: Double, lon: Double)?
    let store: SharedStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = true
        if let r = MetalRenderer(pixelFormat: view.colorPixelFormat, store: store) {
            view.device = r.device
            view.delegate = r
            r.location = location
            r.apply(preset, source: source)
            context.coordinator.renderer = r
        }
        view.preferredFramesPerSecond = preset.fps
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.location = location
        context.coordinator.renderer?.apply(preset, source: source)
        view.preferredFramesPerSecond = preset.fps
    }

    final class Coordinator {
        var renderer: MetalRenderer?
    }
}

// MARK: - Color <-> RGBA

extension Color {
    init(_ c: RGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
