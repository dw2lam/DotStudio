# Film light layers (format v1, DotStudio 1.6 — film engine 1.1)

The contract between the Blender film toolkit (tools/film, which renders layered packages) and the
`film` engine (Shared/CustomFilm.swift + Shared/Engines/film, which plays them).

## Idea

Light adds up. Render the scene once per light source and the app can mix those layers with any
weights, live, and get a correct relit image: any time of day and any weather from one render,
changing smoothly instead of crossfading between clips. Verified on Commute (2026-11-14,
renders/commute/relight-test): sun + sky + cabin reproduces the all-lights render within 4 %, and
mixes match the real day/night/rain/golden renders closely.

## Layers (tiles)

| tile | what it holds | lit by |
|---|---|---|
| `sun` | direct light of a high sun (the scene's day sun, ~15–25°) | the sun lamp only |
| `sun_low` | direct light of a low warm sun (~5–10°, sunrise/sunset) | a second sun lamp only |
| `sky` | the sky's light (and the sky itself in windows) | the world/HDRI only |
| `cabin` | the scene's own interior lights (lamps, screens, emissive props) | interior emitters only |
| `city` | outside lights that only matter at night (lit windows, signs, street lamps) | outside emitters only |
| `mask` | where glass is (1) vs not (0); for rain/fog/condensation drawn live on the glass | (a matte, not light) |

Each light tile is rendered with every other source off (EEVEE: probes re-baked per layer).
Everything else about the frame is identical: same camera, motion, frame numbers, motion blur.
Render no film look (bloom/halation/vignette/fog) into layers: the engine applies the look live.

## Encoding

- One video, `clips/layers.mov`: HEVC 10-bit (Main10), the tiles in a grid, left→right then
  top→bottom in the manifest's `tiles` order. Default grid 3×2, tile 1600×1000 (video 4800×2000).
  Loops seamlessly like any film clip.
- Light tiles store `v = clamp(linear / scale, 0, 1) ^ (1/4)` per channel (scene-linear Rec.709,
  before any exposure); decode `linear = scale * v^4`. `scale` per tile = its 99.95th percentile
  over the loop (measured by the toolkit), so highlights barely clip and shadows keep precision.
- The `mask` tile stores the matte directly (0…1, no curve).
- Tiles sit `gutter` pixels apart (the toolkit uses 8, edge-replicated), so 4:2:0 chroma never
  bleeds between tiles: tile *i* is at x = (i % cols)·(w + gutter), y = (i / cols)·(h + gutter),
  and the video is cols·w + (cols − 1)·gutter wide. The engine derives the pitch from the video
  and tile sizes.
- Colour: RGB → Y'CbCr with the **BT.709** matrix, video range, 4:2:0 (2×2-averaged chroma),
  HEVC Main10 `hvc1`, tagged `-colorspace bt709 -color_primaries bt709 -color_trc bt709`. The
  engine decodes the 10-bit planes directly (no colour management) with the stream's matrix
  tag; untagged = BT.709.
- `sun_low` is rendered with a WHITE sun and coloured live by `tint.sun_low`.

## Manifest

```json
"engine": { "id": "film", "version": ">=1.1" },
"layers": {
  "file": "clips/layers.mov",
  "grid": [3, 2],
  "gutter": 8,
  "tiles": ["sun", "sun_low", "sky", "cabin", "city", "mask"],
  "encoding": "pow4",
  "scale": { "sun": 1.13, "sun_low": 0.47, "sky": 0.42, "cabin": 0.90, "city": 0.6 },
  "exposure": { "day": 1.5, "night": 3.2 },
  "tint": { "sun_low": [1.0, 0.52, 0.22] }
},
"look": { "bloom": 0.25, "halation": 0.15, "grain": 0.2 }
```

`clips` may still be present (older apps play those; 1.6 prefers `layers`). `exposure` are EV
values the scene was balanced at; `tint` overrides a sun tile's colour if it was rendered white.

## The mix (engine)

From the sun elevation `e` (°) and weather (cloud, rain, fog — WeatherMix):
`up = smoothstep(-6, 4, e)`, `low = smoothstep(-2, 6, e) * (1 - smoothstep(10, 22, e))`,
`high = smoothstep(8, 20, e)`, `clear = 1 - smoothstep(0.3, 0.92, max(cloud, 2·rain))`;
weights `sun = high·clear`, `sun_low = low·clear`, `sky = (night blue 0.08·(1-up) + up·warm(low)·(0.4+0.6·high))·(1-0.68·rain)·cool(cloud)`,
`cabin = 1 + 1.2·rain + 0.3·cloud`, `city = 1 - up`; exposure lerps day → night by `up`, plus
rain/cloud lift. Tone map: AgX (Blender's view; minimal fit), then the film look and live grain.
Glass (mask): rain beads/runnels with refraction, fog veil, all drawn live.
Reference implementation: docs/film-layers-demo/scene.metal (the metal-engine demo; passes.py there renders the layers for one frame).

## Passes and cost (engine)

Per **new video frame** (or light), in a command buffer of their own committed ahead of the
frame (CustomSceneLink.prepass): `ds_film_mix` (tiles → HDR + highlights, at the tiles' size)
→ mipmaps of both → `ds_film_look` (halation + bloom from the mips, at half the tiles' size)
→ `ds_film_mist` (only while there's mist: the misted view, AgX of mip 3). Per **grain frame**:
`ds_film_grain`, the grain's lattice for the screen size (so the screen pass gathers four
corners instead of hashing them); in the same texture, redrawn only when the screen, rain, snow
or wind change, the glass's cell tables (each rain-bead / runnel / settled-flake cell's hashes,
gathered instead of hashed per pixel) and the glass map (per 8-pixel block, which bead, runnel
and flake layers can reach it: the others are skipped). Per **displayed frame**: the screen
pass only — `ds_film_dry` (no rain, snow, lightning or mist), `ds_film_damp` (mist and fog
only), `ds_film_rain` (no snow), `ds_film_snow` (no rain) or `ds_fragment` (everything: sleet);
the lean ones are the full pass with code compiled out that the weather skips, so the same
pixels.

While live, light-only changes (the sun, the weather easing, cloud shadows drifting, lightning)
re-mix at most at the clip's frame rate; with the video playing they ride on its frames. A film
with an `fps` is drawn at that rate where the display allows (FramePacing: 24 on 120 Hz, 30 on
60 Hz), since nothing in it changes faster.

Rain and snow (the tables, map, early-outs and rain / snow variants, 1.6.2): the screen pass
measured 12–19 % less in every wet weather, best runs on a busy GPU at high clocks (drizzle
1.02 → 0.90 ms, rain 1.11 → 0.93, heavy rain 1.18 → 0.95, storm 1.16 → 0.95, snow 1.14 → 0.98, sleet 1.24 → 1.06;
clear 0.69, overcast 0.76 for scale) — about 4.4–5.1 ms at idle clocks, still over the 4 ms aim:
the drops, flakes and falling snow are drawn per glass pixel.

Measured on an M5 Pro at 5120×2880 with the full Commute loop (1600×1000 tiles), benchmark_style
(GPU at idle clocks, as a 30 fps wallpaper runs it): screen pass 3.3 ms dry, 3.6 damp, 4.9–6.0
with rain or snow before the tables and map (≈ 4.4–5.1 after); the per-video-frame passes 0.85 ms
(1.05 with mist), at most 24 a second. benchmark_style reports a film as a frame that shows a
new video frame (screen + passes) and gives both parts. Before (1.6.0): 5.1 ms dry to 7.8 sleet
per frame for the screen pass alone, with the mix re-run on every frame whenever the light moved.
With 2560×1600 tiles (video 7696×3208) the screen pass is unchanged (it's per screen pixel) and
the per-video-frame passes scale with the tiles' pixels: ~2.5× (best runs 0.25 → 0.63 ms, 0.31
→ 0.72 with mist, on a busy GPU at high clocks), so ≈ 2.1–2.6 ms at idle clocks, ≤ 24 a second.
