#include <DotStudio.h>

// Commute, relit live — a demo of light-layer stacking. One frame of the Commute train was rendered
// once per light source (midday sun, low sunset sun, sky, cabin lamps). Light adds up, so mixing
// those layers with weights from the real sun and weather relights the scene for any time of day
// and any weather, with no new render.
//
// asset0 = [sun | low sun], asset1 = [sky | cabin], asset2 = window mask, asset3 = night windows.
// Layers are stored as (linear / M) ^ 1/4 in 8 bits (wide range, fine shadows); M per layer below.

constant float M_SUN = 1.1319, M_LOW = 0.4688, M_SKY = 0.4224, M_CAB = 0.8999;

static float3 layer(texture2d<float> t, sampler s, float2 uv, float half_, float m) {
    float2 a = float2(clamp(uv.x, 0.001, 0.999) * 0.5 + half_, uv.y);
    float3 v = t.sample(s, a).rgb;
    float3 v2 = v * v;
    return v2 * v2 * m;
}

// AgX (Blender's view transform), minimal fit — the layers were rendered for it
static float3 agx(float3 c) {
    const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                    float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                    float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                     float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                     float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float lo = -12.47393, hi = 4.026069;
    float3 v = inset * max(c, 1e-10);
    v = (clamp(log2(v), lo, hi) - lo) / (hi - lo);
    float3 x2 = v * v, x4 = x2 * x2;
    v = 15.5 * x4 * x2 - 40.14 * x4 * v + 31.96 * x4 - 6.868 * x2 * v + 0.4298 * x2 + 0.1191 * v - 0.00232;
    // "Medium High Contrast" look: a touch more contrast around mid grey
    v = clamp(v, 0.0, 1.0);
    v = mix(v, v * v * (3.0 - 2.0 * v), 0.25);
    return pow(max(outset * v, 0.0), 2.2);          // linear display light
}

struct Mix { float sun, low, cabin, ev; float3 sky; };

static Mix weights(float elev, float rain, float cloud) {
    float up = smoothstep(-6.0, 4.0, elev);
    float low = smoothstep(-2.0, 6.0, elev) * (1.0 - smoothstep(10.0, 22.0, elev));
    float high = smoothstep(8.0, 20.0, elev);
    // direct sun: gone under overcast or rain (it is far stronger than the sky, so any remainder
    // would still draw hard patches); partly cloudy (~0.6 cover) keeps about half
    float clear = 1.0 - smoothstep(0.3, 0.92, max(cloud, rain * 2.0));
    float3 warm = mix(float3(1.0), float3(1.0, 0.80, 0.60), low * clear);
    Mix m;
    m.sky = (0.08 * float3(0.75, 0.85, 1.0) * (1.0 - up) + up * warm * (0.4 + 0.6 * high))
          * (1.0 - 0.68 * rain) * mix(float3(1.0), float3(0.75, 0.78, 0.82), cloud * (1.0 - rain));
    m.sun = high * clear;
    m.low = low * clear;
    m.cabin = 1.0 + 1.2 * rain + 0.3 * cloud;
    m.ev = 3.2 * (1.0 - up) + up * (1.5 + 0.1 * low) + 0.45 * rain + 0.3 * cloud * (1.0 - rain);
    return m;
}

static float3 lit(float2 uv, Mix m, DSContext ctx) {
    float3 c = layer(ctx.asset0, ctx.smp, uv, 0.0, M_SUN) * m.sun
             + layer(ctx.asset0, ctx.smp, uv, 0.5, M_LOW) * m.low
             + layer(ctx.asset1, ctx.smp, uv, 0.0, M_SKY) * m.sky
             + layer(ctx.asset1, ctx.smp, uv, 0.5, M_CAB) * m.cabin;
    return c * exp2(m.ev);
}

// rain on the glass: beads and slow runnels. Returns the refraction offset (xy), the bead
// coverage (z) and a rim term (w): beads flip and magnify what's behind them, rims go dark.
static float4 drops(float2 uv, float aspect, float t, float amount) {
    float2 off = 0.0; float cover = 0.0, rim = 0.0;
    for (int i = 0; i < 3; i++) {
        float sc = i == 0 ? 46.0 : (i == 1 ? 26.0 : 13.0);
        float2 g = float2(uv.x * aspect, uv.y) * sc;
        float2 cell = floor(g);
        float h = dsHash(cell + float(i) * 7.1);
        if (h > amount * (i == 0 ? 0.8 : (i == 1 ? 0.45 : 0.3))) continue;
        float2 f = fract(g) - 0.5;
        float2 c = (dsHash2(cell + 3.3) - 0.5) * 0.45;
        if (i == 2) c.y = 0.55 - fract(t * (0.04 + 0.06 * h) + h * 9.0) * 1.3;   // a slow runnel
        float r = (i == 0 ? 0.12 : 0.15) + 0.08 * dsHash(cell + 1.7);
        float2 d = (f - c) / float2(1.0, 1.2);
        float l = length(d);
        float k = smoothstep(r, r * 0.8, l);
        off += -d / max(r, 1e-3) * k * (0.006 + 0.005 * float(i));
        cover = max(cover, k);
        rim = max(rim, k * smoothstep(r * 0.5, r, l));
        if (i == 2) {                                             // its wet trail above
            float trail = smoothstep(0.06, 0.0, abs(f.x - c.x)) * step(c.y, f.y) * (1.0 - smoothstep(0.0, 0.9, f.y - c.y));
            cover = max(cover, trail * 0.5);
            off += float2(0.0, -0.004) * trail;
        }
    }
    return float4(off, cover, rim);
}

float4 dsScene(float2 uv, DSContext ctx) {
    // cover the screen with the 16:10 frame
    float img = 1.6;
    float2 q = uv - 0.5;
    if (ctx.aspect > img) q.y *= img / ctx.aspect; else q.x *= ctx.aspect / img;
    float2 tuv = q + 0.5;

    // time of day: the real sun, or a one-minute day (dawn at 0 s, noon 15 s, dusk 30 s)
    float elev = ctx.sun.elevation;
    if (ctx.p[0] > 0.5) elev = 62.0 * sin(DS_TAU * fract(ctx.t / 60.0)) - 5.0;
    // weather: real, or forced
    float rain = ctx.weather.rain, cloud = max(ctx.weather.cloud, ctx.weather.fog);
    int w = int(ctx.p[1] + 0.5);
    if (w == 1) { rain = 0.0; cloud = 0.0; }
    if (w == 2) { rain = 0.0; cloud = 1.0; }
    if (w == 3) { rain = 1.0; cloud = 1.0; }
    Mix m = weights(elev, rain, cloud);

    float mask = ctx.asset2.sample(ctx.smp, tuv).r;
    float2 suv = tuv;
    float bead = 0.0, rimDark = 0.0;
    if (rain > 0.02 && mask > 0.01) {
        float4 d = drops(tuv, img, ctx.t, min(rain * 1.6, 1.0));
        suv += d.xy * mask;
        bead = d.z * mask;
        rimDark = d.w * mask;
    }
    float3 c = agx(lit(suv, m, ctx));
    // night: the city's lit windows, through the glass
    float night = 1.0 - smoothstep(-6.0, 4.0, elev);
    float3 nightPlate = dsToLinear(ctx.asset3.sample(ctx.smp, suv).rgb);
    c = mix(c, nightPlate * (1.0 - 0.5 * rain), mask * night);
    // wet glass: a cool veil, beads catch a little light
    c = mix(c, c * float3(0.86, 0.9, 0.96) + 0.015, mask * rain * 0.6);
    c *= 1.0 - (0.30 - 0.15 * night) * rimDark;
    c += bead * (0.025 + 0.02 * (1.0 - night)) * float3(0.9, 0.95, 1.0);
    float3 outc = dsToSrgb(c);
    outc = dsVignette(uv, 0.2) * outc;
    outc += dsGrain(uv, ctx, 0.012);
    return float4(outc, 1.0);
}
