//  AppearancePicker.swift — Settings › General › Theme: Classic and Retro as short films, one card
//  each (owner, 2026-11-26: "cinematic and 3D layering of each theme"; then "they all layer in,
//  just snapping into place"). Each film is the theme's real UI as a product shot on a plain field
//  (light grey in light, black in dark): the empty window and inspector, then every element — the
//  toolbar keys, the cards and their screens and keys, the filter chips, each style tile, the
//  inspector's parts — drops in and seats with a small press, Retro's dials as machined aluminium
//  knobs that seat and turn; the app holds, then lifts apart again (a seamless loop). The films are
//  made by tools/film/scenes/theme-reel/render-all.sh and ship in App/ThemeFilms (theme-<classic|
//  retro>-<light|dark>.mov + a .jpg poster of the assembled app).
//
//  A card plays its film muted and looping, in the light or dark the app wears now; under Reduce
//  Motion, in offscreen renders, or without the film, it shows the poster. The films are props:
//  a click anywhere on a card picks its theme, and they pause whenever the pane isn't on screen.
//  BundledFilm (poster + looping film) is shared with the What's New clips (ChangelogViews.swift).

import SwiftUI
import AppKit
import AVFoundation

/// Settings › General › Theme: a film of each theme, with its name.
struct ThemePictureChoices: View {
    @Binding var selection: Appearance
    @Environment(\.consoleSettings) private var console
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))
        layout {
            ForEach(Appearance.allCases) { theme in
                card(theme)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
    }

    private func card(_ theme: Appearance) -> some View {
        let on = theme == selection
        let ring = console ? ConsoleInk.signal : Color.accentColor
        let corner: CGFloat = theme == .console ? 6 : 10
        return VStack(spacing: Space.xs) {
            ThemeFilm(theme: theme)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                    .strokeBorder(on ? ring : .clear, lineWidth: 3))
            Text(theme.title)
                .settingsText(console ? (on ? .consoleBodySmallEmphasis : .consoleBodySmall)
                                      : (on ? .calloutEmphasis : .callout))
                .foregroundStyle(on ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selection = theme }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = theme }
    }
}

/// One theme's film (16:10), in the app's light or dark.
private struct ThemeFilm: View {
    let theme: Appearance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        BundledFilm(name: "theme-\(theme == .console ? "retro" : "classic")-\(scheme == .dark ? "dark" : "light")",
                    fallback: theme == .console ? ConsoleInk.panel : Color(nsColor: .windowBackgroundColor))
            .accessibilityHidden(true)
    }
}

/// A film bundled in the app (<name>.mov + its <name>.jpg poster), 16:10, filling its width:
/// the poster, and the muted looping film over it while it's on screen. The poster alone under
/// Reduce Motion, in a headless render, or without the film; `fallback` without either. The
/// theme cards and the What's New clips (ChangelogViews.swift) use it.
struct BundledFilm: View {
    let name: String
    var fallback: Color = .clear
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On screen (the pane is showing): the film plays only then.
    @State private var shown = false

    var body: some View {
        let film = reduceMotion || Appearance.isHeadlessRun ? nil : Bundle.main.url(forResource: name, withExtension: "mov")
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                ZStack {
                    if let poster = Self.poster(name) {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        fallback
                    }
                    if let film {
                        LoopingFilm(url: film, playing: shown)
                    }
                }
            }
            .clipped()
            .onAppear { shown = true }
            .onDisappear { shown = false }
            .allowsHitTesting(false)
    }

    private static var posters: [String: NSImage] = [:]

    private static func poster(_ name: String) -> NSImage? {
        if let p = posters[name] { return p }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        posters[name] = image
        return image
    }
}

/// A muted, seamlessly looping film in an AVPlayerLayer (fills its frame; no controls, no
/// audio). Plays while `playing`, its window is visible and it isn't scrolled out of view;
/// pauses otherwise.
private struct LoopingFilm: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeNSView(context: Context) -> FilmView {
        let view = FilmView()
        view.load(url)
        view.wantsToPlay = playing
        return view
    }

    func updateNSView(_ view: FilmView, context: Context) {
        if view.url != url { view.load(url) }
        view.wantsToPlay = playing
    }

    static func dismantleNSView(_ view: FilmView, coordinator: ()) {
        view.stop()
    }

    final class FilmView: NSView {
        private let player = AVQueuePlayer()
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var observers: [NSObjectProtocol] = []
        private(set) var url: URL?
        var wantsToPlay = false { didSet { update() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let root = CALayer()
            layer = root                     // layer-hosting: the player layer is ours to place
            wantsLayer = true
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.allowsExternalPlayback = false
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
            update()
        }

        func load(_ url: URL) {
            self.url = url
            looper?.disableLooping()
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            update()
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            unobserve()
        }

        private func unobserve() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unobserve()
            if let window {
                let center = NotificationCenter.default
                // a hidden, minimised or covered window: no film decoding behind it
                observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                    object: window, queue: .main) { [weak self] _ in self?.update() })
                // scrolled out of its scroll view (the What's New sheet, Settings): paused too
                if let clip = enclosingScrollView?.contentView {
                    clip.postsBoundsChangedNotifications = true
                    observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                        object: clip, queue: .main) { [weak self] _ in self?.update() })
                }
            }
            update()
        }

        private func update() {
            let visible = (window?.occlusionState.contains(.visible) ?? false) && !visibleRect.isEmpty
            if wantsToPlay && visible && looper != nil {
                if player.rate == 0 { player.play() }
            } else if player.rate != 0 {
                player.pause()
            }
        }
    }
}
