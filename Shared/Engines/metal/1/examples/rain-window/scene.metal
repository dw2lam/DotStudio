#include <DotStudio.h>

// Rain Window — city lights out of focus behind a rainy pane. Drops sit on the glass and every
// so often one runs down it; each drop bends the lights behind it like a little lens. How wet
// the glass is follows the real rain (ctx.weather.rain), never drier than the Rain setting.
//   p[0] Rain (the least it ever is)   p[1] Bokeh (size of the lights)   p[2] Speed
//   colorA = the night outside, colorB = the main colour of the lights.

// One layer of bokeh: a soft disc of light per grid cell (some cells empty). The disc stays
// inside its own cell, so only that cell is looked at — cheap even at 5K.
static float3 bokehLayer(float2 p, float cell, float rMax, float3 warm, float3 cool, float seed) {
    float2 g = p / cell;
    float2 id = floor(g);
    float2 h = dsHash2(id + seed);
    float on = dsHash(id + seed * 1.7);
    // more lights low in the frame (the street) than high up (judged at the cell, not the pixel)
    float density = mix(0.55, 0.12, smoothstep(-0.45, 0.45, (id.y + 0.5) * cell));
    if (on > density) return 0.0;
    float r = mix(0.5, 1.0, h.x) * rMax;                          // in cells, < 0.5
    float2 c = 0.5 + (h - 0.5) * (1.0 - 2.0 * r) * 0.9;
    float d = length(g - id - c);
    float disc = smoothstep(r, r * 0.78, d);
    disc *= 0.8 + 0.2 * smoothstep(r * 0.4, r * 0.95, d);        // a lens's slightly brighter rim
    float pick = dsHash(id + seed * 3.1);
    float3 white = mix(warm, float3(1.0, 0.95, 0.9), 0.6);
    float3 col = mix(warm, white, step(0.72, pick));
    col = mix(col, cool, step(0.92, pick));
    return col * disc * mix(0.15, 0.6, h.y * h.y);
}

static float3 city(float2 p, DSContext ctx, float size) {
    float3 night = dsToLinear(ctx.colorA);
    float3 warm = dsToLinear(ctx.colorB);
    float3 cool = dsToLinear(dsAdjust(ctx.colorB, 0.55, 0.35));
    // the street's glow along the bottom, the sky above
    float3 col = mix(night * 2.2 + warm * 0.04, night * 0.6, smoothstep(-0.5, 0.35, p.y));
    col += bokehLayer(p, 0.22 * size, 0.46, warm, cool, 1.0);
    col += bokehLayer(p + 0.37, 0.14 * size, 0.42, warm, cool, 7.0) * 0.8;
    col += bokehLayer(p - 0.21, 0.085 * size, 0.36, warm, cool, 13.0) * 0.45;
    return col;
}

// The glass: how far each pixel's view is bent by a drop (0 outside drops), and the drop mask.
static float3 drops(float2 p, float t, float wet) {
    float3 o = 0.0;                                               // (offset.xy, mask)
    // resting drops
    float cell = 0.034;
    float2 g = p / cell;
    float2 id = floor(g);
    float2 h = dsHash2(id + 4.0);
    if (dsHash(id + 9.0) < wet * 0.8) {
        float r = mix(0.12, 0.38, h.x * h.x);
        float2 c = 0.5 + (h - 0.5) * (1.0 - 2.0 * r);
        float2 d = g - id - c;
        float m = smoothstep(r, r * 0.8, length(d));
        o = float3(-d / r * cell * 0.9 * m, m);
    }
    // running drops: one per column now and then, sliding down with a short trail
    float colW = 0.11;
    float cx = floor(p.x / colW);
    float ch = dsHash(float2(cx, 2.0));
    if (ch < wet) {
        float speed = 0.05 + 0.08 * dsHash(float2(cx, 5.0));
        float y = 0.6 - fract(t * speed + ch * 7.0) * 1.3;        // top to bottom
        float x = (cx + 0.5 + 0.25 * sin(p.y * 9.0 + ch * 20.0) * 0.4) * colW;
        float2 d = (p - float2(x, y)) / float2(1.0, 1.25);
        float r = 0.012 + 0.006 * ch;
        float m = smoothstep(r, r * 0.75, length(d));
        if (m > o.z) o = float3(-d / r * 0.03 * m, m);
        // the wet trail above it
        float trail = smoothstep(0.004, 0.001, abs(p.x - x)) * step(y, p.y) * exp(-(p.y - y) * 6.0);
        o.xy += float2(0.004, 0.0) * trail;
        o.z = max(o.z, trail * 0.35);
    }
    return o;
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float wet = max(ctx.p[0], ctx.weather.rain);
    float size = mix(0.6, 1.6, ctx.p[1]);
    float t = ctx.t * mix(0.3, 1.6, ctx.p[2]);

    float3 dr = drops(p, t, wet);
    // seen through a drop: the lights a little magnified and inverted
    float3 col = city(p + dr.xy, ctx, size);
    // drops are a touch brighter (they gather light) with a thin darker edge
    float edge = dr.z * (1.0 - dr.z) * 4.0;
    col *= (1.0 + dr.z * 0.3) * (1.0 - edge * 0.35);
    // a faint mist of condensation over the dry glass
    col = mix(col, dsToLinear(ctx.colorA) * 2.0 + 0.01, (1.0 - dr.z) * 0.12 * wet);
    col *= dsVignette(uv, 0.5);
    col = dsTonemap(col * 1.3);
    return float4(dsToSrgb(col) + dsGrain(uv, ctx, 0.01), 1.0);
}
