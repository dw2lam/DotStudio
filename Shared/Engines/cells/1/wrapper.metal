//  wrapper.metal — the `cells` engine's fragment function (the CellKit look of Bloom):
//  dsScene sampled at each cell's centre, drawn as a glyph / LED pixel / LED dot over a glow of
//  the scene's light and the background. u.scene[8] = (render 0 glyphs · 1 pixels · 2 dots,
//  cell size per 1000 px, glow 0…1, 0).

static inline float3 ds_cells_background(float2 uv, DSContext ctx) {
#ifdef DS_HAS_BACKGROUND
    return dsToLinear(saturate(dsBackground(uv, ctx)));
#else
    float3 top = dsToLinear(ctx.colorA);
    float3 bottom = dsToLinear(saturate(ctx.colorA * 1.35 + float3(0.03, 0.035, 0.045)));
    return mix(bottom, top, smoothstep(0.0, 1.0, uv.y));
#endif
}

/// A glyph for a cell of this brightness (dim → bright: · ( ) C Z O △ ☆), varied a little per cell.
static inline int ds_cells_glyph(float l, float2 cell) {
    const int order[8] = { 6, 7, 2, 3, 4, 0, 1, 5 };
    float j = dsHash(cell * 0.731) * 0.9 - 0.45;
    return order[clamp(int(l * 7.99 + j), 0, 7)];
}

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    DSContext ctx = ds_context(u, dsA0, dsA1, dsA2, dsA3, dsSmp);
    int render = clamp(int(u.scene[8].x + 0.5), 0, 2);
    float cellPx = max(u.scene[8].y * ctx.res.y / 1000.0, 3.0);
    float glow = saturate(u.scene[8].z);

    float2 px = float2(in.pos.x, ctx.res.y - in.pos.y);          // pixels, y up
    float2 uv = px / ctx.res;
    // the grid, centred on the screen so the edges are symmetric
    float2 origin = 0.5 * ctx.res;
    float2 g = (px - origin) / cellPx;
    float2 cell = floor(g);
    float2 lp = g - cell - 0.5;                                    // −0.5…0.5 in the cell, y up
    float2 cuv = (origin + (cell + 0.5) * cellPx) / ctx.res;

    float4 sharp = dsScene(cuv, ctx);
    float a = saturate(sharp.a);
    float3 sc = dsToLinear(saturate(sharp.rgb));
    float3 col = ds_cells_background(uv, ctx);

    // the scene's own light, unsampled, as a low glow under the cells
    if (glow > 0.01) {
        float4 soft = dsScene(uv, ctx);
        col += dsToLinear(saturate(soft.rgb)) * saturate(soft.a) * glow * (render == 0 ? 0.30 : 0.20);
    }
    float aa = 1.0 / cellPx;                                       // a pixel, in cells
    if (a > 0.01) {
        if (render == 0) {
            // GLYPHS: light glyphs tinted by the cell's colour, a faint wash of it behind
            float l = dsLuma(dsToSrgb(sc));
            int gi = ds_cells_glyph(saturate(l * 1.15 + 0.1 * a), cell);
            float d = cellkit_glyph(gi, lp);
            float ink = saturate(0.5 - d / aa) * smoothstep(0.02, 0.45, a);
            float3 gcol = dsToLinear(saturate(mix(dsToSrgb(sc), float3(0.95, 0.97, 1.0), 0.35)));
            col = mix(col, sc * 0.6, 0.18 * a);
            col = mix(col, gcol, ink);
        } else {
            // PIXELS (rounded squares with a gap) or DOTS (round, all the same size)
            float dd = cellkit_led(lp, render == 2);
            float m = saturate(0.5 - dd / aa);
            float3 lc = sc * cellkit_dome(lp) * (1.0 + 0.25 * glow);
            col = mix(col, lc, m * smoothstep(0.0, 0.6, a));
        }
    }
    return ds_finish(dsToSrgb(max(col, 0.0)), in.pos.xy);
}
