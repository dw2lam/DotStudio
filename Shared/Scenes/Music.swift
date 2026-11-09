//  Music.swift — the Music scene pack (shader id 66). See SceneCatalog.swift.
//
//  "Now Playing" is split in two, because Metal output is often rendered below native
//  resolution and upscaled with nearest filtering — text there would pixelate:
//    • the shader (Music_cases.h) draws only the background: the artwork as slowly
//      drifting "living art", a soft blur, or a dark glow; a calm gradient when idle;
//    • MusicOverlayLayer (Shared/Music) draws the foreground — artwork, titles, progress —
//      as a CALayer tree at the display's native scale, above the Metal layer.
//  Both read the same params (MusicSceneOptions) and the same geometry (MusicGeometry),
//  so the background's glow sits exactly behind the overlay's artwork.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Music" line of EffectKind.
    static let music: [EffectKind: SceneSpec] = [
        .nowPlaying: SceneSpec(
            name: "Now Playing",
            blurb: "What's playing in Spotify or Apple Music: big album art over its own colours, slowly moving.",
            shaderID: 66,
            // Packed in order: p0 = (layout, background, motion, album), p1.x = progress.
            params: [ParamSpec(menu: "layout", "Layout", MusicLayoutKind.allCases.map(\.label), def: 0),
                     ParamSpec(menu: "background", "Background", MusicBackground.allCases.map(\.label), def: 0),
                     ParamSpec("motion", "Motion", 0, 2, def: 1),
                     ParamSpec("album", "Show Album", 0, 1, def: 1, toggle: true),
                     ParamSpec("progress", "Show Progress", 0, 1, def: 1, toggle: true)],
            // Idle (nothing playing, or a track without artwork or palette): a calm gradient.
            colorA: RGBA(0.05, 0.05, 0.07), colorB: RGBA(0.42, 0.36, 0.62),
            colorALabel: "Idle Background", colorBLabel: "Idle Glow"),
    ]

    /// Styles this pack adds to the default library. "Now Playing" (Album) is featured;
    /// Stage and Cover are one click away in Add Built-in Styles.
    static var musicPresets: [Preset] {
        func np(_ name: String, layout: MusicLayoutKind, background: MusicBackground) -> Preset {
            var e = EffectInstance(.nowPlaying)
            e.params["layout"] = Double(layout.rawValue)
            e.params["background"] = Double(background.rawValue)
            return Preset(name: name, effects: [e])
        }
        return [
            np("Now Playing", layout: .album, background: .livingArt),
            np("Now Playing — Stage", layout: .stage, background: .livingArt),
            np("Now Playing — Cover", layout: .cover, background: .livingArt),
        ]
    }
}
