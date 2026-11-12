# The `film` engine (v1)

A scene made of **looping video clips** — e.g. a landscape rendered in Blender at four times of
day — that follow the real sun and weather. No shader to write: the package is a manifest and
its clips.

```json
{ "format": 1, "id": "lake-house-2b7c9e10", "name": "Lake House", "author": "…", "licence": "…",
  "engine": { "id": "film" },
  "clips": [ { "variant": "day",    "file": "clips/day.mov",    "loop": true },
             { "variant": "golden", "file": "clips/golden.mov", "loop": true },
             { "variant": "night",  "file": "clips/night.mov",  "loop": true },
             { "variant": "rain",   "file": "clips/rain.mov",   "loop": true } ],
  "description": "…" }
```

## Which clip plays

| variant | when |
|---|---|
| `day` | the sun above 8° |
| `golden` | the sun between −4° and 8° (sunrise, sunset) |
| `night` | the sun below −4° |
| `rain` | while it rains (the live weather), whatever the time |
| `any` | a fallback for whatever has no clip of its own |

Missing variants fall back: golden → day → any → night; night → any → golden → day; rain → the
sun's variant. The choice is re-checked every few seconds; a change **crossfades over 3 s**.

## Clips

- **HEVC** (or H.264) in .mov / .mp4, decoded in hardware. 3840×2160 or 2560×1440, 24–30 fps.
- **Seamless loops**: the last frame must flow into the first (render a cyclic animation; avoid
  a hold or a dissolve at the seam). Clips always loop. 10–30 s is plenty.
- **Aspect-fill**: the clip covers the screen, cropping its overflow — keep the subject inside the
  centre 16:10 so wide, tall and portrait displays all frame it well.
- Calm motion (water, leaves, clouds, light), no cuts, no camera shake. No audio (it's muted).
- Up to 400 MB of clips per package.

## Power

The clips decode only while the scene is on screen. A live wallpaper holds a still frame on
battery (Efficient or Still) and in Low Power Mode; previews and thumbnails show each clip's first
frame (its poster).

`validate` checks the variants, that every clip is a playable video at least 0.4 s long, and warns
about low resolution or a codec without hardware decode.

## Grain and halation (applied live)

Don't bake grain into the clips: the engine adds it at playback, so it stays sharp at every
screen size and never smears in the video codec.
- **Grain** (0…1, default 0.35): fine, animated, luminance-weighted — strongest in the mids, gentle
  in shadows and highlights; a new pattern on every frame of the clip (stepped at its frame rate);
  about 1.4 pt per grain at any resolution.
- **Halation** (0…1, default 0): a subtle warm bleed around highlights, for clips that weren't
  graded with it (the Blender toolkit's clips bake their own — leave it at 0 for those).
Both are engine params: they appear in the Inspector under every film style, and a style stores
them as `ds.grain` / `ds.halation` in its params. One fragment pass, ≤ 0.3 ms at 5120×2880.
