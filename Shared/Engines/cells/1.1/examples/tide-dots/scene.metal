#include <DotStudio.h>

// Tide Dots — rows of swells rolling in under a low moon, drawn as LED dots. The whole sea
// rises and falls with a slow tide. It shows the cells engine's own background hook: with
// DS_HAS_BACKGROUND defined, dsBackground paints the smooth sky behind the cells (display sRGB),
// in place of the engine's colour-A gradient.
//   p[0] Swell (wave height)   p[1] Speed   p[2] Tide (toggle: the slow rise and fall)
//   colorA = the night, colorB = the foam.

#define DS_HAS_BACKGROUND 1
float3 dsBackground(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float3 top = ctx.colorA;
    float3 low = saturate(ctx.colorA * 2.2 + float3(0.04, 0.05, 0.08));
    float3 sky = mix(low, top, smoothstep(-0.1, 0.5, p.y));
    // the moon's halo, high on the left (the moon itself is drawn in cells)
    float m = exp(-length(p - float2(-0.35 * ctx.aspect * 0.5, 0.3)) * 5.0);
    return sky + float3(0.10, 0.11, 0.14) * m;
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float t = ctx.t * mix(0.15, 0.7, ctx.p[1]);
    float swell = mix(0.4, 1.4, ctx.p[0]);
    float tide = ctx.p[2] > 0.5 ? 0.02 * sin(ctx.t * DS_TAU / 240.0) : 0.0;   // a four-minute tide

    float3 foam = ctx.colorB;
    float3 deep = float3(0.10, 0.22, 0.42);

    // the moon: a disc of cells
    float2 mc = float2(-0.35 * ctx.aspect * 0.5, 0.3);
    float moon = dsFill(dsSdCircle(p - mc, 0.06), 0.004);
    if (moon > 0.0) return float4(float3(0.95, 0.93, 0.84), moon);

    if (p.y > 0.13) return float4(0.0);                      // above the farthest crest: sky only

    // Six rows of swells, nearest (lowest, tallest, brightest) first: the first row a pixel
    // falls inside is the one we see.
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float near = 1.0 - fi / 6.0;
        float base = -0.38 + fi * 0.085 + tide;
        float amp = 0.028 * swell * mix(0.45, 1.0, near);
        float f = mix(9.0, 4.0, near);
        float x = p.x + fi * 1.37;
        float crest = base + amp * sin(x * f - t * (1.0 + 0.3 * fi))
                           + amp * 0.45 * sin(x * f * 2.3 + t * 0.7 + fi * 2.0);
        float d = p.y - crest;
        if (d > 0.0) continue;                              // above this row's crest
        float depth = -d / (0.07 * mix(0.5, 1.0, near));    // 0 at the crest … 1 down the face
        // foam bright on the crest, the face darkening into deep water, broken into speckle
        float spray = dsHash(floor(p * 220.0) + fi);
        float a = exp(-depth * 2.2) * mix(0.55, 1.0, near);
        a *= 0.65 + 0.35 * step(0.3, spray);
        float3 col = mix(foam, deep, smoothstep(0.0, 0.8, depth));
        return float4(col, saturate(a + 0.12 * near));
    }
    return float4(0.0);
}
