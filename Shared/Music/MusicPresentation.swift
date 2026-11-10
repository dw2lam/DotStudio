//  MusicPresentation.swift — the ONE decision every renderer host makes about music: from the
//  settings, the feed and the time (and the style on screen), what the overlay draws and what
//  the renderer draws behind it. The saver, the live wallpaper, the in-app previews, the
//  full-screen Preview, thumbnails and the gallery tool all call `resolve`, so they agree.
//
//  Music is a presentation over the CURRENT screensaver (owner, 2026-11-09):
//    • Off         — nothing.
//    • Corner      — artwork, title, artist and a thin bar straight on the scene, over a
//                    feathered scrim (no card), while music is visible.
//    • Full Screen — the big Album (or Stage) layout over the style while music is visible,
//                    with the artwork's living art behind it (`.albumArt`, shader 66) or the
//                    style itself softly blurred and dimmed (`.veil`, internal pass 73). The
//                    renderer eases the backdrop in and out (MetalRenderer.musicBackdropSeconds),
//                    the overlay fades with it; when music stops or the linger ends it all
//                    fades back to the plain screensaver — never an empty "Not Playing" screen.
//  "Visible" = playing, or paused within the linger (MusicState.isVisible).
//
//  A library that still holds a legacy Now Playing style (shader 66 as a style) keeps it
//  working: it is its own living-art background, shows its foreground while music is visible,
//  and is calm ambient art otherwise.

import Foundation

/// What the renderer draws behind the music foreground.
enum MusicBackdrop: Equatable {
    case none
    /// The style, softly blurred, dimmed and vignetted (internal pass 73).
    case veil
    /// The artwork's living art (the Now Playing scene, shader 66) in this layout.
    case albumArt(MusicLayoutKind)
}

struct MusicPresentation: Equatable {
    /// What the overlay draws (it hides itself again whenever music stops being visible).
    var overlay: MusicOverlayLayer.Mode
    /// What the renderer draws behind it.
    var backdrop: MusicBackdrop

    static let none = MusicPresentation(overlay: .hidden, backdrop: .none)

    /// Where the presentation shows.
    enum Surface {
        /// The screensaver, the full-screen Preview, and the app's miniatures of the
        /// screensaver (the Screensaver card's hero and still).
        case screensaver
        /// The live wallpaper: only with "Also on the live wallpaper".
        case wallpaper
    }

    /// The single source of truth. `preset` is the style on screen (a legacy Now Playing
    /// style is its own background); `music` the host's latest snapshot.
    static func resolve(settings: MusicSpec, music: MusicSnapshot, preset: Preset?,
                        surface: Surface = .screensaver, now: Date = Date()) -> MusicPresentation {
        let visible = music.isVisible(settings: settings, at: now)
        if let inst = preset?.musicScene {
            // Legacy Now Playing style: the shader is the background (living art while music
            // shows, calm ambient art otherwise); the foreground only while music is visible.
            return visible ? MusicPresentation(overlay: .full(MusicSceneOptions(inst)), backdrop: .none) : .none
        }
        guard visible else { return .none }
        if surface == .wallpaper && !settings.drawsOnWallpaper { return .none }
        switch settings.displayMode {
        case .off:
            return .none
        case .corner:
            return MusicPresentation(overlay: .card(settings.corner), backdrop: .none)
        case .fullScreen:
            let o = settings.fullOptions
            // Cover is the artwork filling the screen: always its living art, whatever
            // "Behind the music" says (that choice is kept for Album and Stage).
            let b: MusicBackdrop = settings.backdrop == .albumArt || !settings.layout.usesBackdrop
                ? .albumArt(o.layout) : .veil
            return MusicPresentation(overlay: .full(o), backdrop: b)
        }
    }

    /// The style that draws the Album Art backdrop: the built-in Now Playing scene (living
    /// art) in `layout`, with fixed ids so a renderer never sees a "new" style per frame.
    static func albumArtPreset(_ layout: MusicLayoutKind) -> Preset {
        switch layout {
        case .album: return albumArtAlbum
        case .stage: return albumArtStage
        case .cover: return albumArtCover
        }
    }

    private static func makeArtPreset(_ layout: MusicLayoutKind, _ tag: UInt8) -> Preset {
        var e = EffectInstance(.nowPlaying)
        e.params["layout"] = Double(layout.rawValue)
        e.params["background"] = Double(MusicBackground.livingArt.rawValue)
        e.id = UUID(uuidString: String(format: "6D757369-6300-4000-8000-0000000001%02X", tag))!
        var p = Preset(name: "Album Art", effects: [e])
        p.id = UUID(uuidString: String(format: "6D757369-6300-4000-8000-0000000000%02X", tag))!
        return p
    }
    private static let albumArtAlbum = makeArtPreset(.album, 0x70)
    private static let albumArtStage = makeArtPreset(.stage, 0x71)
    private static let albumArtCover = makeArtPreset(.cover, 0x72)
}
