# Film light layers (format v1 draft, DotStudio 1.6)

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

## Manifest

```json
"engine": { "id": "film", "version": ">=1.1" },
"layers": {
  "file": "clips/layers.mov",
  "grid": [3, 2],
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
