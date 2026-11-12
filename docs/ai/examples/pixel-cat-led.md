# A pixel cat on an LED panel (custom scene, cells engine)

> **You:** Make a little pixel cat sleeping on an LED panel, like the penguin one.

_Custom scenes arrive with DotStudio's scene-engine update. This session was recorded against the self-test's stand-in engine, so the tool calls and answers are real but no preview image is shown._

```
→ list_engines({})
```
```text
- metal v1 (metal-source), built in
- cells v1 (cells), built in
```

```
→ read_guide({"id": "engines/cells"})
```
```text
# Engine: cells (LED panels, pixels, glyph cells)

Placeholder. The `cells` engine ships with DotStudio once custom scenes arrive; its `guide.md` replaces this page when installed.

Same signature as `metal` (`float4 dsScene(float2 uv, DSContext ctx)`), but the result is colour + coverage per cell: the engine draws it as LED dots, square pixels or glyphs (the CellKit look of LED Wall and Penguin), …
```

```
→ create_custom_scene({"manifest": {"name": "Sleepy Cat", "engine": {"id": "cells", "version": ">=1"}, "fps": 24, "stepped": true, "licence": "own work", "params": [{"key": "breath", "label": "Breathing", "kind": "slider", "min": 0, "max": 1, "default": 0.5}, {"key": "zzz", "label": "Zzz", "kind": "toggle", "default": 1}], "colors": {"a": {"label": "Panel", "default": [0.02, 0.02, 0.03, 1]}, "b": {"label": "Cat", "default": [0.98, 0.72, 0.38, 1]}}, "uses": [], "description": "A pixel cat asleep on a dark LED panel.", "guides": ["style/dotstudio"]}, "source": "…below…"})
```
`source`:

```metal
#include <DotStudio.h>
// A sleeping cat, 24×14 cells, breathing slowly; one z drifts up every ~9 s.
float4 dsScene(float2 uv, DSContext ctx) {
    float2 g = floor(uv * float2(48, 27));                 // cell grid
    float breathe = 0.5 + 0.5 * sin(ctx.t * 0.7);          // slow, never a hard loop with the z below
    float2 c = g - float2(24, 9);
    float body = step(length(c / float2(9, 4.5 + breathe * 0.4)), 1.0) * step(-4.0, c.y);
    float head = step(length((c - float2(7, 3)) / 3.2), 1.0);
    float ears = step(abs(c.x - 6) + abs(c.y - 6.5), 1.2) + step(abs(c.x - 9) + abs(c.y - 6.5), 1.2);
    float cat = saturate(body + head + ears);
    float zt = fract(ctx.t / 9.0);
    float2 zp = float2(31 + zt * 3, 13 + zt * 6);
    float z = step(abs(g.x - zp.x) + abs(g.y - zp.y), 0.6) * (1 - zt) * ctx.p[1];
    float3 col = mix(ctx.colorA.rgb, ctx.colorB.rgb, cat) + z * 0.6;
    return float4(col, max(cat, z));                       // colour + coverage: the engine lights cells
}
```
```text
Compiles.
GPU ≈ 2.50 ms per frame at 5K.
Installed as sleepy-cat-035dd8ec. Use it: create_style(effects: [{"kind": "custom", "scene": "sleepy-cat-035dd8ec"}]).
```

```
→ create_style({"name": "Sleepy Cat", "fps": 24, "effects": [{"kind": "custom", "scene": "sleepy-cat-035dd8ec", "params": {"zzz": true}}]})
```
```text
Created “Sleepy Cat” (8021C859-B0A4-4494-94A8-8F86C1EF2B77). DotStudio isn't running: library.json was updated; the app shows it next time it opens.
Next: preview_style(style: "8021C859-B0A4-4494-94A8-8F86C1EF2B77") — and a contact sheet over time (frames: 6) to check the motion.
```

Resulting style (as stored in `library.json`):

```json
{
  "effects": [
    {
      "colorA": {
        "r": 0.02,
        "b": 0.03,
        "g": 0.02,
        "a": 1
      },
      "colorB": {
        "r": 0.98,
        "b": 0.38,
        "g": 0.72,
        "a": 1
      },
      "custom": {
        "id": "sleepy-cat-035dd8ec"
      },
      "enabled": true,
      "id": "AF2FB205-FB8D-4DF9-AF5F-7D4C0A08E966",
      "params": {
        "breath": 0.5,
        "zzz": 1
      },
      "kind": "custom"
    }
  ],
  "id": "8021C859-B0A4-4494-94A8-8F86C1EF2B77",
  "fps": 24,
  "name": "Sleepy Cat"
}
```
