#include <DotStudio.h>

// Tide Pool — looking down through clear shallow water at rippled sand, with sunlight focused
// into a slow web of caustics. The wind (ctx.weather.wind) stirs the surface: the web moves a
// little faster and wobbles more on a breezy day.
//   p[0] Speed   p[1] Caustics (brightness)   p[2] Scale
//   colorA = the water, colorB = the sunlight.

// Distance to the nearest and second-nearest cell point. A lean Voronoi: each cell's point
// stays in the middle half of its cell, so the 2×2 cells around p's nearest grid corner are
// enough (4 lookups, not 9); squared distances compared, one square root each at the end.
static float2 cells(float2 p) {
    float2 n = floor(p), f = fract(p);
    float2 base = n + step(0.5, f) - 1.0;          // the 2x2 block of cells around p's nearest corner
    float d1 = 8.0, d2 = 8.0;
    for (int y = 0; y <= 1; y++) {
        for (int x = 0; x <= 1; x++) {
            float2 c = base + float2(x, y);
            float2 v = c + 0.25 + 0.5 * dsHash2(c) - p;
            float d = dot(v, v);
            d2 = min(d2, max(d1, d));
            d1 = min(d1, d);
        }
    }
    return sqrt(float2(d1, d2));
}

// The caustic web: thin bright seams between softly warped cells, brightest at the junctions.
static float caustic(float2 p, float t, float wobble) {
    float2 w = float2(sin(p.y * 0.9 + t * 0.7), sin(p.x * 0.8 - t * 0.6)) + 0.5 * float2(sin(p.y * 2.3 - t), sin(p.x * 2.1 + t * 0.8));
    float2 v = cells(p + w * 0.24 * wobble + float2(0.11, -0.07) * t);
    float e = v.y - v.x;
    return exp(-e * 20.0) * (0.5 + 0.5 * smoothstep(0.15, 0.6, v.x));
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float wind = ctx.weather.wind;
    float t = ctx.t * mix(0.15, 0.8, ctx.p[0]) * (1.0 + 0.8 * wind);
    float scale = mix(4.0, 10.0, ctx.p[2]);

    // The sand: warm, with soft ripple ridges and fine grain.
    float2 sp = p * 7.0;
    float ridge = sin(sp.x * 1.3 + sp.y * 2.4 + 1.2 * sin(sp.x * 0.7 - sp.y * 0.4) + 0.8 * sin(sp.y * 1.1 + 2.0));
    float3 sand = dsToLinear(float3(0.86, 0.76, 0.58));
    sand *= 0.8 + 0.2 * smoothstep(-1.0, 1.0, ridge);
    sand *= 0.94 + 0.12 * (dsHash(floor(uv * ctx.res)) - 0.5);

    // The water over it: deeper (bluer, darker) toward the top of the screen.
    float3 water = dsToLinear(ctx.colorA);
    float depth = 0.25 + 0.55 * smoothstep(-0.6, 0.5, p.y) + 0.06 * sin(p.x * 3.1 + p.y * 1.7);
    float3 col = mix(sand * mix(float3(1.0), water * 1.5, depth), water * 0.6, depth * 0.55);

    // Caustics: two webs at different scales; where they cross, the light focuses brightest.
    float wob = 0.6 + 1.2 * wind;
    float2 q = p * scale;
    float c1 = caustic(q, t, wob);
    float c2 = caustic(q * 0.61 + 11.0, t * 0.8, wob);
    float light = (c1 * 0.4 + c2 * 0.25 + c1 * c2 * 1.8) * mix(0.3, 1.5, ctx.p[1]);
    float3 sun = dsToLinear(ctx.colorB);
    col += sun * light * (1.0 - 0.5 * depth);

    // a soft dark rim, like the edge of a rock pool
    col *= dsVignette(uv, 0.45);
    col = dsTonemap(col * 1.25);
    return float4(dsToSrgb(col), 1.0);
}
