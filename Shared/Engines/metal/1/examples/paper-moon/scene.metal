#include <DotStudio.h>

// Paper Moon — layered paper-cut hills drifting past at different speeds, each casting a soft
// shadow on the layer behind it. The disc in the sky is the REAL sun (ctx.sun): it rises, arcs
// and sets with the day; once the sun is down a pale moon takes its place and the palette turns
// to night. Paper grain over everything.
//   p[0] Drift (parallax speed)   p[1] Layers (3–6)   p[2] Grain
//   colorA = the daytime sky, colorB = the hills (near layers are deeper shades of it).

// The top edge of hill layer i (0 = farthest) at x, screen-height units from the centre.
static float hillEdge(float x, float i, float t, float seed) {
    float drift = t * 0.004 * (1.0 + i * 1.6);                 // near layers move faster
    float f = 1.1 + i * 0.55;
    float xx = (x + drift) * f + seed * 17.0 + i * 3.7;
    float h = 0.045 * sin(xx * 1.3) + 0.03 * sin(xx * 2.9 + 1.7);
    h += 0.022 * sin(xx * 0.53 + i * 2.1) + 0.012 * sin(xx * 6.1 + i * 4.3);
    return 0.0 - i * 0.075 + h * (0.8 + 0.2 * i);
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float t = ctx.t * mix(0.0, 3.0, ctx.p[0]);
    int layers = clamp(int(ctx.p[1] + 0.5), 3, 6);

    // day ↔ night from the real sun; warm near the horizon at dawn and dusk
    float el = ctx.sun.elevation;
    float day = smoothstep(-8.0, 6.0, el);
    float dusk = exp(-abs(el - 1.0) / 6.0) * (1.0 - smoothstep(10.0, 18.0, el));
    float3 dayTop = dsToLinear(ctx.colorA);
    float3 dayLow = dsToLinear(saturate(ctx.colorA + float3(0.36, 0.22, 0.04)));
    float3 nightTop = dsToLinear(float3(0.04, 0.05, 0.12));
    float3 nightLow = dsToLinear(float3(0.12, 0.13, 0.25));
    float3 duskLow = dsToLinear(float3(0.98, 0.62, 0.42));
    float k = smoothstep(-0.25, 0.5, p.y);
    float3 top = mix(nightTop, dayTop, day);
    float3 low = mix(nightLow, dayLow, day);
    low = mix(low, duskLow, dusk * 0.8);
    float3 col = mix(low, top, k);

    // The disc: the sun by day, the moon (opposite it) by night. Facing south: azimuth 180°
    // is the middle of the screen; the horizon sits a little below centre.
    bool sunUp = el > -3.0;
    float az = sunUp ? el > -90.0 ? ctx.sun.azimuth : 180.0 : ctx.sun.azimuth + 180.0;
    float alt = sunUp ? el : clamp(-el, 18.0, 50.0);
    float dx = (fmod(az + 360.0, 360.0) - 180.0) / 110.0;
    float2 c = float2(clamp(dx, -1.2, 1.2) * 0.38 * ctx.aspect, 0.02 + alt / 70.0 * 0.55);
    float r = sunUp ? 0.055 : 0.045;
    float d = dsSdCircle(p - c, r);
    float3 discCol = sunUp ? mix(float3(1.0, 0.55, 0.3), float3(1.0, 0.93, 0.78), smoothstep(0.0, 25.0, el))
                           : float3(0.93, 0.93, 0.86);
    float3 disc = dsToLinear(discCol);
    col += disc * dsGlow(d, sunUp ? 0.09 : 0.05) * (sunUp ? 0.35 : 0.18);
    col = mix(col, disc, dsFill(d, dsPixel(ctx) * 1.5));

    // stars at night, very sparse
    if (day < 0.9) {
        float2 g = p * 60.0;
        float2 id = floor(g);
        float s = step(0.975, dsHash(id + 7.0)) * exp(-dot(g - id - 0.5, g - id - 0.5) * 45.0);
        col += float3(0.8, 0.85, 1.0) * s * (1.0 - day) * smoothstep(-0.05, 0.25, p.y) * 0.8;
    }

    // Hill layers, drawn NEAR to FAR: each pixel stops at the first layer that covers it, so
    // the work is one or two layers deep, not six. A layer casts a soft shadow upward onto
    // everything behind it (`shade`). Far layers are pale and hazy, near ones deep: by day from
    // colour B, by night moonlit blues.
    float3 hillDay = dsToLinear(ctx.colorB);
    float3 farDay = mix(dsToLinear(saturate(ctx.colorB * 1.5 + 0.12)), low, 0.35);
    float3 nearNight = dsToLinear(float3(0.05, 0.055, 0.11));
    float3 farNight = dsToLinear(float3(0.15, 0.15, 0.28));
    float3 nearCol = mix(nearNight, hillDay * 0.45, day);
    float3 farCol = mix(farNight, farDay, day);
    float n = float(layers);
    float px = dsPixel(ctx) * 1.2;
    float paper = dsNoise(p * float2(3.0, 2.0) + ctx.seed * 9.0);    // the paper isn't flat
    float shadow = mix(0.45, 0.3, day), rimK = mix(0.6, 0.12, day);
    float3 acc = 0.0;
    float cover = 0.0, shade = 1.0;
    for (int j = 0; j < 6; j++) {
        if (j >= layers) break;
        float i = float(layers - 1 - j);                          // nearest first
        float fi = i * 5.0 / max(n - 1.0, 1.0);                   // spread the layers over the same depth
        if (p.y > 0.18 - fi * 0.075) continue;                    // well above this layer's highest edge
        float e = hillEdge(p.x, fi, t, ctx.seed);
        float depth = i / max(n - 1.0, 1.0);                      // 0 far … 1 near
        float above = p.y - e;
        float inside = dsFill(above, px);
        if (inside > 0.0) {
            float rim = exp(-max(-above, 0.0) / 0.005) * rimK;    // a lit paper edge (moonlit at night)
            float3 lc = mix(farCol, nearCol, pow(depth, 0.8)) * (1.0 + rim + 0.06 * (paper - 0.5));
            acc += (1.0 - cover) * inside * lc * shade;
            cover += (1.0 - cover) * inside;
            if (cover > 0.995) break;
        }
        shade *= 1.0 - shadow * exp(-max(above, 0.0) / 0.014) * step(0.0, above);
    }
    col = acc + (1.0 - cover) * col * shade;

    // paper grain and fibres (hashes: cheap at 5K)
    float grain = ctx.p[2];
    float2 g2 = floor(uv * ctx.res);
    float spk = dsHash(g2) - 0.5;
    float fib = dsHash(float2(floor(g2.x / 3.0), floor(g2.y / 11.0))) - 0.5;
    col *= 1.0 + grain * (0.035 * fib + 0.05 * spk);
    col *= dsVignette(uv, 0.25);
    return float4(dsToSrgb(col), 1.0);
}
