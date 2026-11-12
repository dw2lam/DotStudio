//  Cells.h — the `cells` engine, version 1 (on top of the metal engine's DotStudio.h).
//
//  The package writes the same function as a metal scene, but its alpha is COVERAGE:
//
//      float4 dsScene(float2 uv, DSContext ctx)   // rgb = display-sRGB colour, a = 0…1 coverage
//
//  The engine samples it once per cell (at the cell's centre) and draws each cell as a glyph, a
//  rounded LED pixel or a round LED dot (the user's Render setting), over a soft glow of the
//  scene's own light and a background. a = 0 leaves a cell empty (just the background).
//
//  The background is the style's colour A as a gentle vertical gradient, unless the package
//  defines its own before anything else:
//
//      #define DS_HAS_BACKGROUND 1
//      float3 dsBackground(float2 uv, DSContext ctx) { … }   // display sRGB, smooth (not celled)
//
//  Engine params, added to every cells scene (you don't declare them): Render (Glyphs / Pixels /
//  Dots), Cell Size, Glow. Read them if you need to with dsCellSize(ctx) (pixels) — rarely needed.
//  Glyphs (CellKit.h): △ ▽ C Z O ☆ · ( ), picked per cell from its brightness.

#ifndef DOTSTUDIO_CELLS_H
#define DOTSTUDIO_CELLS_H

/// The cell pitch in pixels on this screen (the Cell Size setting, per 1000 px of height).
static inline float dsCellSize(DSContext ctx, constant FXUniforms& u) { return max(u.scene[8].y * ctx.res.y / 1000.0, 3.0); }

#endif
