//  MetalPreview.swift — live Metal preview of a preset inside SwiftUI.
//
//  A legacy Now Playing style also shows its foreground (MusicOverlayView above the Metal
//  view), fed by the app's shared MusicFeedHub; `showsMusic` presents music over any other
//  style exactly as the screensaver would (MusicPresentation: Corner, or Full Screen with its
//  backdrop easing in). `music` is the library's music settings — Show music, the corner and
//  size, the backdrop, the paused linger — so a preview keeps a paused song exactly as long
//  as the screensaver does.
//
//  A preview draws only while someone can see it: it holds its last frame while it is scrolled
//  out of its scroll view, while that scroll view is being scrolled (the scroll gets the main
//  thread — MTKView draws there), and while its window is covered or minimized.

import SwiftUI
import MetalKit
import Combine

struct MetalPreview: NSViewRepresentable {
    let preset: Preset
    let source: SourceSpec
    let location: (lat: Double, lon: Double)?
    let store: SharedStore
    /// Caps the frame rate below the style's own (small, always-on previews).
    var maxFPS: Int? = nil
    /// The library's music settings (Library.musicSettings).
    var music = MusicSpec()
    /// Present music as the screensaver does (the Screensaver card's hero); off for gallery
    /// tiles and the editor. Legacy Now Playing styles always show their foreground.
    var showsMusic = false

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
            context.coordinator.applied = (preset, source)
        }
        view.preferredFramesPerSecond = fps
        context.coordinator.container = container
        context.coordinator.update(preset: preset, music: music, presents: showsMusic)
        return container
    }

    func updateNSView(_ container: PreviewContainer, context: Context) {
        let c = context.coordinator
        c.renderer?.location = location
        // Any model change re-runs this; re-applying an unchanged style would only repack its
        // uniforms and restart its dither history.
        if c.applied?.preset != preset || c.applied?.source != source {
            c.renderer?.apply(preset, source: source)
            c.applied = (preset, source)
        }
        if container.metal.preferredFramesPerSecond != fps { container.metal.preferredFramesPerSecond = fps }
        context.coordinator.update(preset: preset, music: music, presents: showsMusic)
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

        deinit { stopWatching() }

        // MARK: Draw only while seen

        private var watched: [NSObjectProtocol] = []
        private var scrollSub: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard let window else { return }
            let nc = NotificationCenter.default
            var tokens = [
                nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    self?.updateDrawing()
                },
            ]
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                tokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    self?.updateDrawing()
                })
            }
            watched = tokens
            scrollSub = ScrollActivity.changes.sink { [weak self] _ in self?.updateDrawing() }
            updateDrawing()
        }

        override func layout() {
            super.layout()
            updateDrawing()
        }

        private func stopWatching() {
            for t in watched { NotificationCenter.default.removeObserver(t) }
            watched = []
            scrollSub = nil
        }

        /// Pause while nobody can see it: scrolled out of view, scrolling (its own scroll view),
        /// or its window covered / minimized. Paused, MTKView keeps showing its last frame.
        /// DEV harness only (ClickProbe): an off-screen window counts as seen.
        static var probeAssumesVisible = false

        private func updateDrawing() {
            var seen = false
            if let window, Self.probeAssumesVisible || window.occlusionState.contains(.visible), !window.isMiniaturized {
                seen = !visibleRect.isEmpty
                if seen, let sv = enclosingScrollView, ScrollActivity.isScrolling,
                   sv.window != nil, ScrollActivity.isScrolling(sv) { seen = false }
            }
            if metal.isPaused == seen { metal.isPaused = !seen }
        }

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
        /// What the renderer last got from `apply` (skipped when unchanged).
        var applied: (preset: Preset, source: SourceSpec)?
        private let store: SharedStore
        private var token: MusicFeedHub.Token?
        private var preset: Preset?
        private var music = MusicSpec()
        private var presents = false
        /// The next tick is this preview's first look: a backdrop already up shows at once.
        private var fresh = true

        init(store: SharedStore) { self.store = store }

        /// Subscribe to the hub only while this preview can show music.
        func update(preset: Preset, music: MusicSpec, presents: Bool) {
            self.preset = preset
            self.music = music
            self.presents = presents
            let wants = preset.isMusicScene || (presents && music.displayMode != .off)
            if wants, token == nil {
                token = MusicFeedHub.shared.subscribe(store: store) { [weak self] snap, changed in
                    self?.tick(snap, changed: changed)
                }
            } else if !wants {
                stopMusic()
            } else {
                tick(MusicFeedHub.shared.snapshot(store: store), changed: false)
            }
        }

        func stopMusic() {
            token = nil
            renderer?.setMusicBackdrop(.none, animated: false)
            _ = container?.setOverlay(false)
            fresh = true
        }

        private func tick(_ snap: MusicSnapshot, changed: Bool) {
            guard let preset else { return }
            if changed { renderer?.setMusic(snap) }
            renderer?.musicLingerMinutes = music.linger
            var p = MusicPresentation.resolve(settings: music, music: snap, preset: preset)
            if !presents && !preset.isMusicScene { p = .none }
            let animated = !fresh
            fresh = false
            renderer?.setMusicBackdrop(p.backdrop, animated: animated)
            guard let ov = container?.setOverlay(true) else { return }   // kept while subscribed: it fades out itself
            ov.overlay.update(mode: p.overlay, music: snap, settings: music, animated: animated)
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
