#include <DotStudio.h>

// Music Bloom — soft fields of colour drifting into each other. While music plays they take the
// album art's palette (ctx.music.a / b / c) and breathe with the music's level; with nothing
// playing they settle back to the style's own two colours. (DotStudio never listens to the
// sound: level is a smooth envelope that rises while something plays.)
//   p[0] Speed   p[1] Softness   p[2] Grain
//   colorA, colorB = the palette with nothing playing.

// A soft blob of light: a wide Gaussian.
static float blob(float2 p, float2 c, float r) {
    float2 d = p - c;
    return exp(-dot(d, d) / (r * r));
}

// A colour no brighter than `maxL` (luma): a white album cover mustn't light the whole screen.
static float3 tame(float3 c, float maxL) {
    float l = dsLuma(c);
    return l > maxL ? c * (maxL / l) : c;
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float t = ctx.t * mix(0.02, 0.12, ctx.p[0]);
    float soft = mix(0.75, 1.4, ctx.p[1]);
    float m = ctx.music.level;                                   // 0 idle … 1 playing

    // the palette: the style's colours, eased toward the album's while music plays (its colours
    // a little richer: artwork palettes are often dusty, and a full screen of dust looks muddy)
    float3 ma = tame(saturate(dsAdjust(ctx.music.a, 0.0, 1.4) * 1.1), 0.62);
    float3 mb = tame(saturate(dsAdjust(ctx.music.b, 0.0, 1.4) * 1.1), 0.55);
    float3 mc = tame(saturate(dsAdjust(ctx.music.c, 0.0, 1.3)), 0.4);
    float3 a = dsToLinear(mix(ctx.colorA, mc * 0.45, m));
    float3 b = dsToLinear(mix(ctx.colorB, ma, m));
    float3 c = dsToLinear(mix(dsAdjust(ctx.colorB, -0.09, 1.15) * 0.85, mb, m));            // a warmer neighbour
    float3 e = dsToLinear(mix(saturate(dsAdjust(ctx.colorA, 0.06, 1.2) * 3.2), mc, m));     // a lifted shade of the deep

    // four blobs on slow Lissajous paths; the music makes them a little larger
    float w = ctx.aspect * 0.5;
    float r = 0.3 * soft * (1.0 + 0.12 * m);
    float2 c1 = float2(w * 0.55 * sin(t * 1.0 + 0.3), 0.30 * cos(t * 1.3));
    float2 c2 = float2(w * 0.60 * cos(t * 0.8 + 2.0), 0.32 * sin(t * 1.1 + 1.0));
    float2 c3 = float2(w * 0.45 * sin(t * 1.4 + 4.0), 0.28 * sin(t * 0.7 + 3.0));
    float2 c4 = float2(w * 0.50 * cos(t * 0.6 + 5.0), 0.30 * cos(t * 0.9 + 2.0));
    // a gentle warp so the fields fold into each other instead of looking like discs
    float2 q = p + 0.06 * float2(sin(p.y * 3.0 + t * 3.0), cos(p.x * 2.5 - t * 2.0));
    float w1 = blob(q, c1, r), w2 = blob(q, c2, r * 0.9), w3 = blob(q, c3, r * 1.1), w4 = blob(q, c4, r * 0.8);
    float3 col = a * 0.6;                                         // the ground
    col = mix(col, e, w4 * 0.85);
    col = mix(col, b, w1 * 0.9);
    col = mix(col, c, w2 * 0.85);
    col = mix(col, mix(b, float3(1.0, 0.9, 0.8), 0.35), w3 * 0.5);

    // breathing: a slow swell of brightness while music plays
    col *= 1.0 + m * 0.12 * sin(ctx.t * 1.2);
    col *= dsVignette(uv, 0.3);
    return float4(dsToSrgb(col) + dsGrain(uv, ctx, mix(0.0, 0.035, ctx.p[2])), 1.0);
}
