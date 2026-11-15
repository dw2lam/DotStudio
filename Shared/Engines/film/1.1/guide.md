# The `film` engine (v1.1)

A scene made of **looping video** rendered offline (e.g. in Blender) that follows the real sun and
weather. No shader to write: the package is a manifest and its video. Two forms:

- **Variant clips** (any version): one clip per time of day / weather, crossfading between them.
- **Light layers** (engine 1.1, DotStudio 1.6): ONE video whose frames hold the scene lit by each
  light source separately; the engine mixes them live for the real sun and every weather
  condition, so the light changes smoothly through the whole day from a single render. Preferred.

## Variant clips

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

### Clips

- **HEVC** (or H.264) in .mov / .mp4, decoded in hardware. 3840×2160 or 2560×1440, 24–30 fps.
- **Seamless loops**: the last frame must flow into the first (render a cyclic animation; avoid
  a hold or a dissolve at the seam). Clips always loop. 10–30 s is plenty.
- **Aspect-fill**: the clip covers the screen, cropping its overflow — keep the subject inside the
  centre 16:10 so wide, tall and portrait displays all frame it well.
- Calm motion (water, leaves, clouds, light), no cuts, no camera shake. No audio (it's muted).
- Up to 400 MB of clips per package.

## Light layers (engine ≥ 1.1)

Light adds up: render the scene once per light source (every other source off; same camera,
motion and frames) and any mix of those renders is a correct relit image. The package:

```json
{ "format": 1, "id": "commute-3f2a9c10", "name": "Commute", "author": "…", "licence": "…",
  "engine": { "id": "film", "version": ">=1.1" },
  "fps": 24, "uses": ["sun", "weather"],
  "layers": {
    "file": "clips/layers.mov",
    "grid": [3, 2],
    "tiles": ["sun", "sun_low", "sky", "cabin", "city", "mask"],
    "encoding": "pow4",
    "scale": { "sun": 1.13, "sun_low": 0.47, "sky": 0.42, "cabin": 0.90, "city": 0.6 },
    "exposure": { "day": 1.5, "night": 3.2 },
    "tint": { "sun_low": [1.0, 0.52, 0.22] }
  },
  "look": { "bloom": 0.25, "halation": 0.15, "grain": 0.2, "vignette": 0.22 },
  "description": "…" }
```

| tile | holds | weight |
|---|---|---|
| `sun` | direct light of a high sun (~15–25°) | high sun × clear sky (cloud shadows drift over it when partly cloudy) |
| `sun_low` | direct light of a low warm sun (~5–10°) | sunrise / sunset × clear sky |
| `sky` | the sky's light (and the sky itself in windows) | day / night blue, warm at golden hour, dimmer and cooler under cloud and rain, brighter and colder in snow; lightning spikes it |
| `cabin` | the scene's own interior lights | 1, more under rain and cloud (it reads brighter against the grey) |
| `city` | outside lights that matter at night | 1 − daylight |
| `mask` | where glass is (1) vs not (0): a matte, not light | rain, snow, fog drawn live on the glass |

- **Video**: `clips/layers.mov`, **HEVC Main10 (10-bit)**, the tiles in a grid left→right then
  top→bottom in `tiles` order (default 3×2, tile 1600×1000 → 4800×2000; ≤ 8192 px a side).
  Tag it BT.709 (`-colorspace bt709 -color_primaries bt709 -color_trc bt709`, limited range):
  untagged video is read as BT.709. Loops seamlessly like a clip. 8-bit video is refused (the
  encoding's shadows band).
- **Encoding `pow4`**: light tiles store `v = clamp(linear / scale, 0, 1) ^ (1/4)` per channel
  (scene-linear Rec.709, no exposure, no look); the engine decodes `scale · v⁴`. `scale` per tile =
  its 99.95th percentile over the loop. `mask` is stored as is (0…1).
- `exposure`: the EV the scene was balanced at by day and by night (rain / cloud add a little);
  `tint`: a colour for a sun tile rendered white.
- **No look in the layers** (no bloom, halation, vignette, fog, grain): the engine draws them live
  — bloom and halation from `look` (the style's Halation starts at `look.halation`), vignette
  `look.vignette` (default 0.22), AgX ("Medium High Contrast") tone mapping, then grain.
- Keep a little margin at tile edges: the engine clamps each tile 1 px in, but HEVC's 4:2:0 colour
  is half resolution, so the outermost pixels' colour can mix with the neighbouring tile's.
- `clips` may be listed as well: apps older than 1.6 play those; 1.6 plays the layers.

### The weather, drawn live

Every condition looks distinct (the style's **Weather** menu pins one; Live follows the real
weather, eased over 90 s):

| condition | light | on the glass (mask) |
|---|---|---|
| Clear | full sun | — |
| Partly Cloudy | about half the sun, cloud shadows drifting over its light | — |
| Overcast | no direct sun, cooler sky, brighter cabin | — |
| Fog | grey, soft | the view hazes (less contrast), condensation creeps in from the edges |
| Drizzle | dim | fine sparse beads, hardly a runnel |
| Rain | dim, cool | beads and runnels that refract what's behind, a wet cool veil |
| Heavy Rain | darker | dense beads, many fast runnels, stronger veil |
| Thunderstorm | as heavy rain | + lightning: a brief, cool double flash of the sky light, at most one every 8–20 s, never strobing |
| Snow | colder, softer, brighter sky | flakes falling beyond the glass, flakes settling on it and melting |
| Sleet | cold and wet | slushy beads with a few flakes |

### Cost

The layers are mixed at the tiles' size with their blurs (≈ 0.85–1.05 ms for 1600×1000 tiles,
only for a new video frame or light: at most the clip's frame rate), then one screen pass draws
the glass, glow, tone map and grain on every displayed frame: ≈ 3.3 ms at 5120×2880 in clear or
partly cloudy weather, 3.6 overcast or foggy, ≈ 4.4–5.1 with rain or snow on the glass (Apple M5 Pro,
benchmark_style, which reports both parts). A film with an `fps` is drawn at that rate where the
display allows (24 on 120 Hz, 30 on 60 Hz). The video decodes in hardware straight to 10-bit
textures (no conversion pass).

`validate` checks: the grid matches the tile count, a `scale` for every light tile, the video
exists, is HEVC, plays, loops (≥ 0.4 s) and is ≤ 8192 px; warns about small tiles, a missing mask
or colour tags.

## Power

The clips decode only while the scene is on screen. A live wallpaper holds a still frame on
battery (Efficient or Still) and in Low Power Mode; previews and thumbnails show each clip's first
frame (its poster).

`validate` checks the variants, that every clip is a playable video at least 0.4 s long, and warns
about low resolution or a codec without hardware decode.

## Grain, halation and weather (the engine's params)

Don't bake grain into the clips: the engine adds it at playback, so it stays sharp at every
screen size and never smears in the video codec.
- **Grain** (0…1, default 0.35): fine, animated, luminance-weighted — strongest in the mids, gentle
  in shadows and highlights; a new pattern on every frame of the clip (stepped at its frame rate);
  about 1.4 pt per grain at any resolution.
- **Halation** (0…1, default 0): a subtle warm bleed around highlights, for clips that weren't
  graded with it (the Blender toolkit's clips bake their own — leave it at 0 for those).
- **Weather** (menu: Live, Clear, Partly Cloudy, Overcast, Fog, Drizzle, Rain, Heavy Rain,
  Thunderstorm, Snow, Sleet; default Live): pins a condition for this style. Light layers draw it
  (above); variant clips pick their rain clip for the wet conditions.
They are engine params: they appear in the Inspector under every film style, and a style stores
them as `ds.grain` / `ds.halation` / `ds.weather` (0 = Live, 1 = Clear … 10 = Sleet) in its
params. For variant clips: one fragment pass, ≤ 0.3 ms at 5120×2880. For light layers the
package's look sets Halation's starting value (the engine draws it, nothing is baked).

## Making one

DotStudio's film toolkit (Blender, driven by an AI through the MCP server) renders and packages film scenes in this format: `read_guide film` has its flow, budgets and rules.
