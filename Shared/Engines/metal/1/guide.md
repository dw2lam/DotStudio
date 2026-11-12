# The `metal` engine (v1)

Write a DotStudio scene as **one Metal function**. DotStudio compiles it on the Mac's GPU at
runtime and runs it full-screen as a screensaver or live wallpaper, at up to 5K and 120 fps — so
it must be beautiful, calm and cheap.

```metal
#include <DotStudio.h>

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);                 // screen-height units, (0,0) = centre
    float3 sky = mix(dsToLinear(ctx.colorA), dsToLinear(ctx.colorB), uv.y);
    float sun = dsFill(dsSdCircle(p - float2(0.0, 0.1), 0.12), dsPixel(ctx));
    return float4(dsToSrgb(mix(sky, float3(1.0, 0.8, 0.5), sun)), 1.0);
}
```

- `uv` runs 0…1 across the screen with **y up** (0 = bottom).
- Return **display sRGB** with alpha 1. The engine dithers, clamps, and turns NaN / ∞ into black.
- `metal_stdlib` is included and `using namespace metal;` is in effect. Name your own helpers
  freely (everything DotStudio provides starts with `ds` / `DS`); mark them `static`.
- No globals, no textures except the package's assets, no buffers, no compute: one pure function.

## The package

```
my-scene/
  scene.json      the manifest
  scene.metal     the entry (other .metal / .h files can be #include "file.metal"d)
  assets/*.png    optional, up to 4 images, 8 MB in all (ctx.asset0…3)
```

```json
{ "format": 1, "id": "aurora-lake-1a2b3c4d", "name": "Aurora Lake", "author": "…", "licence": "MIT",
  "engine": { "id": "metal", "version": ">=1" },
  "entry": "scene.metal",
  "fps": 30, "stepped": false,
  "params": [ { "key": "speed", "label": "Speed", "kind": "slider", "min": 0, "max": 1, "default": 0.5 },
              { "key": "stars", "label": "Stars", "kind": "toggle", "default": 1 },
              { "key": "mood",  "label": "Mood",  "kind": "menu", "options": ["Calm","Vivid"], "default": 0 } ],
  "colors": { "a": { "label": "Sky", "default": [0.1,0.2,0.5,1] }, "b": { "label": "Glow", "default": [0.3,1,0.7,1] } },
  "uses": ["sun", "weather", "music"],
  "assets": ["assets/paper.png"],
  "description": "…", "guides": ["style/dotstudio"] }
```

- `id`: `[a-z0-9-]{1,48}` + `-` + 8 hex. Installing a package with an existing id replaces it
  (that's how you edit a scene). Leave it out and install picks one.
- `params`: at most 16. They arrive **in order** as `ctx.p[0…15]` (slider = value, toggle = 0/1,
  menu = option index). The user sees them as sliders / switches / menus in the Inspector; pick
  ranges where every value looks good, and put the most useful knobs first.
- `colors.a` / `colors.b`: the style's two colour wells → `ctx.colorA`, `ctx.colorB`.
- `fps`: the style's frame rate (30 is right for most scenes; 60 for fast motion, 24/20 for calm
  ones). `"stepped": true` makes `ctx.t` advance in whole frames of `fps` — a deliberate,
  film-like cadence that also saves power.
- `uses`: what you read — `sun`, `weather`, `music`. The app only fetches the weather for scenes
  that say they use it (everything is readable regardless; unused data is calm defaults).
- Limits: sources 256 KB, assets 8 MB, 16 params, 4 assets.

## `DSContext`

| field | meaning |
|---|---|
| `float2 res` | output size in pixels (up to 5120×2880, also portrait displays) |
| `float aspect` | `res.x / res.y` |
| `float t` | seconds since the scene started. Wraps every hour behind a crossfade: use it for periodic motion (`sin(t*…)`, `fract`, noise offsets), never as an ever-growing coordinate. |
| `float clock` | local wall-clock seconds since midnight (0…86400) |
| `DSDate date` | `year`, `month` 1–12, `day` 1–31, `weekday` 1 = Sunday … 7 |
| `DSSun sun` | `elevation` (° above horizon, −90…90), `azimuth` (° from north, clockwise), `isDay` |
| `DSWeather weather` | `cloud`, `rain`, `snow`, `fog`, `wind`, all 0…1 (eased; clear sky when unknown) |
| `DSMusic music` | `playing`, `level` (smooth 0…1 envelope while playing — not an audio meter), `a`, `b`, `c` (album-art palette, display sRGB, grey when none) |
| `float p[16]` | your params |
| `float3 colorA, colorB` | the style's colours, display sRGB |
| `float seed` | 0…1, fixed per style — vary layouts between copies |
| `texture2d<float> asset0…3`, `sampler smp` | your assets: `ctx.asset0.sample(ctx.smp, uv)` (y up, display sRGB) |

## Helpers (`DotStudio.h`)

**Coordinates** — `dsCentered(uv, ctx)` (screen-height units around the centre: shapes stay round),
`dsPixel(ctx)` (one pixel in those units: antialias widths), `dsRotate(a)` (float2x2),
`dsRemap(x, a, b, c, d)`, `dsBand(x, a, b, w)`.

**Noise** — `dsHash(float/float2/float3)` → 0…1, `dsHash2`, `dsHash3`; `dsNoise(float2/float3)`
(value noise 0…1); `dsGradientNoise(float2)` (−1…1, smoother); `dsFbm(p, octaves)` (0…1);
`dsWarp(p, amount, t)` (domain warp); `dsVoronoi(p, jitter)` → (nearest, second, cell id).

**2D SDF** (negative inside) — `dsSdCircle`, `dsSdBox`, `dsSdRoundBox`, `dsSdSegment`, `dsSdRing`,
`dsSdEquilateralTriangle`, `dsSdHexagon`, `dsSdStar`; `dsFill(d, px)` (antialiased 0…1),
`dsGlow(d, radius)`.

**3D SDF** — `dsSdSphere`, `dsSdBox(float3)`, `dsSdTorus`, `dsSdPlane`, `dsSdCapsule`,
`dsCameraRay(c, ro, ta, zoom)`. **Operators** — `dsSmin`, `dsSmax`, `dsSubtract` (smooth, blend
width k), `dsRepeat`.

**Colour** — `dsToLinear` / `dsToSrgb`, `dsLuma`, `dsPalette(t, a, b, c, d)` (cosine palette),
`dsHsv(h, s, v)`, `dsRgbToHsv`, `dsAdjust(rgb, hueShift, saturation)`, `dsTonemap` (ACES),
`dsVignette(uv, amount)`, `dsGrain(uv, ctx, amount)`.

**Sky** — `dsSky(dir, ctx)` / `dsSkyAt(dir, elevation°, azimuth°)`: a daylight-aware sky for a
view direction (linear colour; day blue, golden at sunrise/sunset, deep night, a sun disc);
`dsSky2D(uv, ctx)` for flat scenes.

## Taste — what makes a good DotStudio scene

- **Calm.** It runs for hours. Slow, continuous motion; no flashing, strobing or sudden cuts.
- **Light in linear.** Convert colours with `dsToLinear`, add light, `dsTonemap` if it can exceed
  1, convert back with `dsToSrgb`. Gradients and glows look clean instead of muddy.
- **Antialias edges** with SDFs and `dsFill(d, dsPixel(ctx))`; never hard `step()` on a 5K screen.
- **Burn-in.** Avoid static bright elements: let bright things drift, fade or move slowly.
- **Colour wells mean something.** `colorA` is usually the background / sky, `colorB` the light
  or subject. Defaults should look great; every user-picked pair should still look intentional.
- **Use the world.** The real sun (`ctx.sun`), weather, time of day and music make a scene feel
  alive — but it must look right in every state (night, overcast, nothing playing).
- **Grain** (`dsGrain(uv, ctx, 0.01)`) hides banding in dark gradients.

## Performance — budget **3 ms per frame at 5120×2880**

`validate` measures it and warns above 3 ms (fails above 60). Roughly: a value-noise call costs
~0.05 ms at 5K; 4-octave fbm ~0.2 ms; a 64-step raymarch with a cheap SDF ~2 ms.
- Few noise octaves (3–5); skip work where it can't show (`if (y > horizon) …`).
- Raymarch sparingly: ≤ 64 steps, early out, simple SDFs.
- Loops need constant small bounds — a GPU hang (timeout) disables the scene.
- `"stepped": true` with `fps` 20–24 halves the energy of slow scenes.

## Errors

Compile errors come back with your file's line and column (`scene.metal:12:7: error: …`). A scene
that doesn't compile, or that faults on the GPU, never crashes anything: the style shows a calm
gradient of colour A until the package is fixed and reinstalled.

## Examples

Complete packages in this engine's `examples/` folder — read them before writing a scene.
