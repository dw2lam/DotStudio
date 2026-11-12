# The `cells` engine (v1)

The CellKit look of DotStudio's Bloom scene: your scene, sampled once per cell, drawn as
**LED dots**, **rounded LED pixels** or **glyphs** (△ ▽ C Z O ☆ · ( )) over a soft glow of its
own light. Built on the `metal` engine — read its guide first; everything in `DotStudio.h` works.

```metal
#include <DotStudio.h>

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float d = dsSdCircle(p, 0.25 + 0.02 * sin(ctx.t));
    float cover = dsFill(d, 0.02);                    // 1 inside, 0 outside
    return float4(ctx.colorB, cover);                 // rgb = colour, a = COVERAGE
}
```

- The **alpha is coverage**: 0 leaves the cell empty (just the background), 1 lights it fully.
  Return a colour for every cell you light (display sRGB).
- Think in **cells**, not pixels: shapes need to be a few cells across to read (a cell is
  ~13 px at 1000 px of screen height by default; the user changes it). Soft edges look better than
  hard ones — partial coverage dims a cell rather than aliasing.
- The engine calls `dsScene` at each cell's centre, and once more per pixel for the glow (only
  when Glow is on) — so keep it cheap.
- **Background**: the style's colour A as a gentle vertical gradient. Draw your own (smooth, not
  celled — a sky, a horizon) by defining, before `dsScene`:

  ```metal
  #define DS_HAS_BACKGROUND 1
  float3 dsBackground(float2 uv, DSContext ctx) { return mix(ctx.colorA, ctx.colorA * 0.4, uv.y); }
  ```

- The engine adds three params to every cells scene (don't declare them): **Render** (Glyphs,
  Pixels, Dots), **Cell Size** (6–32 per 1000 px of height), **Glow** (0–1). Your own params are
  `ctx.p[0…]` as usual (up to 16).
- Glyphs are picked per cell from its brightness (dim · ( ) C Z O △ ▽ ☆ bright), so brightness
  variation shows as texture in Glyphs mode.

Package: as for `metal`, with `"engine": { "id": "cells", "version": ">=1" }`. Same 3 ms budget at
5120×2880. Examples in `examples/`.
