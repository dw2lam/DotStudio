//  MetalPreview.swift — live Metal preview of a preset inside SwiftUI.
//
//  A Now Playing style also shows its foreground (MusicOverlayView above the Metal view),
//  fed by the app's shared MusicFeedHub; `showsMusicCard` shows the corner card over any
//  other style too (as the screensaver would). `music` is the library's music settings —
//  the paused linger, the card's corner and size — so a preview keeps a paused song exactly
//  as long as the screensaver (and the editor's status row) does.

import SwiftUI
import MetalKit

struct MetalPreview: NSViewRepresentable {
    let preset: Preset
    let source: SourceSpec
    let location: (lat: Double, lon: Double)?
    let store: SharedStore
    /// Caps the frame rate below the style's own (small, always-on previews).
    var maxFPS: Int? = nil
    /// The library's music settings (Library.musicSettings): linger, card corner and size.
    var music = MusicSpec()
    /// The corner card over a non-music style (the Screensaver hero, while the card is on);
    /// off for gallery tiles and the editor. Now Playing styles always show their foreground.
    var showsMusicCard = false

    private var fps: Int { min(preset.fps, maxFPS ?? preset.fps) }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> PreviewContainer {
        let view = MTKView()
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = true
        let container = PreviewContainer(metal: view)
        if let r = MetalRenderer(pixelFormat: view.colorPixelFormat, store: store) {
            view.device = r.device
            view.delegate = r
            r.location = location
            r.reduceMotion = MusicOverlayLayer.systemReduceMotion
            r.apply(preset, source: source)
            context.coordinator.renderer = r
        }
        view.preferredFramesPerSecond = fps
        context.coordinator.container = container
        context.coordinator.update(preset: preset, music: music, card: showsMusicCard)
        return container
    }

    func updateNSView(_ container: PreviewContainer, context: Context) {
        context.coordinator.renderer?.location = location
        context.coordinator.renderer?.apply(preset, source: source)
        container.metal.preferredFramesPerSecond = fps
        context.coordinator.update(preset: preset, music: music, card: showsMusicCard)
    }

    static func dismantleNSView(_ container: PreviewContainer, coordinator: Coordinator) {
        coordinator.stopMusic()
    }

    /// The MTKView plus, while music is shown, the overlay above it.
    final class PreviewContainer: NSView {
        let metal: MTKView
        var overlay: MusicOverlayView?

        init(metal: MTKView) {
            self.metal = metal
            super.init(frame: .zero)
            metal.frame = bounds
            metal.autoresizingMask = [.width, .height]
            addSubview(metal)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setOverlay(_ on: Bool) -> MusicOverlayView? {
            if on, overlay == nil {
                let ov = MusicOverlayView(frame: bounds)
                ov.overlay.trueScale = true   // a miniature of the screen: the card at its true size
                addSubview(ov, positioned: .above, relativeTo: metal)
                overlay = ov
            } else if !on, let ov = overlay {
                ov.removeFromSuperview()
                overlay = nil
            }
            return overlay
        }
    }

    final class Coordinator {
        var renderer: MetalRenderer?
        weak var container: PreviewContainer?
        private let store: SharedStore
        private var token: MusicFeedHub.Token?
        private var preset: Preset?
        private var music = MusicSpec()
        private var card = false

        init(store: SharedStore) { self.store = store }

        /// Subscribe to the hub only while this preview shows music.
        func update(preset: Preset, music: MusicSpec, card: Bool) {
            self.preset = preset
            self.music = music
            self.card = card
            let wants = preset.isMusicScene || card
            if wants, token == nil {
                token = MusicFeedHub.shared.subscribe(store: store) { [weak self] snap, changed in
                    self?.tick(snap, changed: changed, animated: true)
                }
            } else if !wants {
                stopMusic()
            } else {
                tick(MusicFeedHub.shared.snapshot(store: store), changed: false, animated: false)
            }
        }

        func stopMusic() {
            token = nil
            _ = container?.setOverlay(false)
        }

        private func tick(_ snap: MusicSnapshot, changed: Bool, animated: Bool) {
            guard let preset else { return }
            if changed { renderer?.setMusic(snap) }
            renderer?.musicLingerMinutes = music.linger
            let mode: MusicOverlayLayer.Mode
            if let inst = preset.musicScene {
                mode = .full(MusicSceneOptions(inst))
            } else if card {
                mode = .card(music.corner)
            } else {
                mode = .hidden
            }
            guard let ov = container?.setOverlay(mode != .hidden) else { return }
            ov.overlay.update(mode: mode, music: snap, settings: music, animated: animated)
        }
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
