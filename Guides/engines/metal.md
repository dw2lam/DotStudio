# Engine: metal (custom scenes in Metal)

Placeholder. The `metal` engine ships with DotStudio once custom scenes arrive; its own `guide.md` (the full `DotStudio.h` API, helpers and examples) replaces this page when it is installed. Until then this is the contract summary.

## What you write

```metal
#include <DotStudio.h>
float4 dsScene(float2 uv, DSContext ctx) {   // uv 0…1, y up
    // return display-sRGB rgb, alpha 1
}
```

`DSContext` (read-only): `res` (pixels), `aspect`, `t` (seconds; stepped when the manifest says `"stepped": true`), `clock` (seconds since local midnight), `date` (y, m, d, weekday), `sun` (elevation°, azimuth°, isDay), `weather` (cloud, rain, snow, fog, wind 0…1), `music` (playing, level 0…1, art colours a/b/c), `p[16]` (your params in manifest order), `colorA`, `colorB`, `seed`.

## Package

`scene.json` + `scene.metal` (+ small `assets/*.png|jpg`, 8 MB max). Up to 16 params (`slider` min/max/default, `toggle` 0/1, `menu` options + index). Colours `a` and `b` with labels and defaults. `uses`: any of `sun`, `weather`, `music`, `clock`.

## Rules

- Read `style/dotstudio` first: slow, calm, dark-first, never an obvious loop.
- Budget: aim for 4 ms per frame at 5K (validate_custom_scene reports it). Keep loops short: few fbm octaves, few raymarch steps.
- No text: the engine has no glyph rendering; use the built-in clock scenes for time.
- Anything static drifts or dims (see `burn-in`).
