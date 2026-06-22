//  Shaders.metal
//  One fullscreen vertex + one über-fragment that switches on u.effect.
//  Each preset renders as a chain of these passes, ping-ponged between textures.

#include <metal_stdlib>
#include "EffectUniforms.h"
using namespace metal;

// ---------------------------------------------------------------- vertex

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// Fullscreen triangle from a single draw of 3 vertices.
vertex VOut fx_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = float2(p.x, 1.0 - p.y);   // flip Y so textures are top-left origin
    return o;
}

// ---------------------------------------------------------------- helpers

constant float3 LUMA = float3(0.299, 0.587, 0.114);

static inline float luma(float3 c) { return dot(c, LUMA); }

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n));
}

static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float a = 0.5, f = 0.0;
    for (int i = 0; i < 5; ++i) { f += a * vnoise(p); p *= 2.02; a *= 0.5; }
    return f;
}

// Ordered dither matrices, normalized to [-0.5, 0.5].
constant float bayer2[4] = {
    0.0/4-0.5, 2.0/4-0.5,
    3.0/4-0.5, 1.0/4-0.5
};
constant float bayer4[16] = {
     0.0/16-0.5,  8.0/16-0.5,  2.0/16-0.5, 10.0/16-0.5,
    12.0/16-0.5,  4.0/16-0.5, 14.0/16-0.5,  6.0/16-0.5,
     3.0/16-0.5, 11.0/16-0.5,  1.0/16-0.5,  9.0/16-0.5,
    15.0/16-0.5,  7.0/16-0.5, 13.0/16-0.5,  5.0/16-0.5
};
constant float bayer8[64] = {
     0/64.-0.5,32/64.-0.5, 8/64.-0.5,40/64.-0.5, 2/64.-0.5,34/64.-0.5,10/64.-0.5,42/64.-0.5,
    48/64.-0.5,16/64.-0.5,56/64.-0.5,24/64.-0.5,50/64.-0.5,18/64.-0.5,58/64.-0.5,26/64.-0.5,
    12/64.-0.5,44/64.-0.5, 4/64.-0.5,36/64.-0.5,14/64.-0.5,46/64.-0.5, 6/64.-0.5,38/64.-0.5,
    60/64.-0.5,28/64.-0.5,52/64.-0.5,20/64.-0.5,62/64.-0.5,30/64.-0.5,54/64.-0.5,22/64.-0.5,
     3/64.-0.5,35/64.-0.5,11/64.-0.5,43/64.-0.5, 1/64.-0.5,33/64.-0.5, 9/64.-0.5,41/64.-0.5,
    51/64.-0.5,19/64.-0.5,59/64.-0.5,27/64.-0.5,49/64.-0.5,17/64.-0.5,57/64.-0.5,25/64.-0.5,
    15/64.-0.5,47/64.-0.5, 7/64.-0.5,39/64.-0.5,13/64.-0.5,45/64.-0.5, 5/64.-0.5,37/64.-0.5,
    63/64.-0.5,31/64.-0.5,55/64.-0.5,23/64.-0.5,61/64.-0.5,29/64.-0.5,53/64.-0.5,21/64.-0.5
};
// Clustered-dot 4x4 (grows as round-ish clusters, like a print screen).
constant float cluster4[16] = {
    12/16.-0.5, 5/16.-0.5, 6/16.-0.5,13/16.-0.5,
     4/16.-0.5, 0/16.-0.5, 1/16.-0.5, 7/16.-0.5,
    11/16.-0.5, 3/16.-0.5, 2/16.-0.5, 8/16.-0.5,
    15/16.-0.5,10/16.-0.5, 9/16.-0.5,14/16.-0.5
};

// Interleaved Gradient Noise — a cheap blue-noise-spectrum threshold in [-0.5,0.5].
static inline float ign(float2 p) {
    return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y)) - 0.5;
}

// Threshold for a given dither algorithm at integer cell coords.
static inline float ditherThreshold(int mode, int2 c) {
    switch (mode) {
        case 0:  return bayer2[(c.y & 1) * 2 + (c.x & 1)];
        case 2:  return bayer8[(c.y & 7) * 8 + (c.x & 7)];
        case 3:  return cluster4[(c.y & 3) * 4 + (c.x & 3)];
        case 4:  return hash21(float2(c)) - 0.5;                 // white-noise
        default: return bayer4[(c.y & 3) * 4 + (c.x & 3)];       // Bayer 4x4
    }
}

// The classic NES (2C02) 64-entry palette, normalized.
constant float3 NES[64] = {
    float3(0.486,0.486,0.486), float3(0.0,0.0,0.988), float3(0.0,0.0,0.737), float3(0.267,0.157,0.737),
    float3(0.580,0.0,0.518),   float3(0.659,0.0,0.125),float3(0.659,0.063,0.0), float3(0.533,0.078,0.0),
    float3(0.314,0.188,0.0),   float3(0.0,0.471,0.0),  float3(0.0,0.408,0.0),   float3(0.0,0.345,0.0),
    float3(0.0,0.251,0.345),   float3(0.0,0.0,0.0),    float3(0.0,0.0,0.0),     float3(0.0,0.0,0.0),
    float3(0.737,0.737,0.737), float3(0.0,0.471,0.973),float3(0.0,0.345,0.973), float3(0.408,0.267,0.988),
    float3(0.847,0.0,0.800),   float3(0.894,0.0,0.345), float3(0.973,0.220,0.0), float3(0.894,0.361,0.063),
    float3(0.675,0.486,0.0),   float3(0.0,0.722,0.0),  float3(0.0,0.659,0.0),   float3(0.0,0.659,0.267),
    float3(0.0,0.533,0.533),   float3(0.0,0.0,0.0),    float3(0.0,0.0,0.0),     float3(0.0,0.0,0.0),
    float3(0.973,0.973,0.973), float3(0.235,0.737,0.988),float3(0.408,0.533,0.988),float3(0.596,0.471,0.973),
    float3(0.973,0.471,0.973), float3(0.973,0.345,0.596),float3(0.973,0.471,0.345),float3(0.988,0.627,0.267),
    float3(0.973,0.722,0.0),   float3(0.722,0.973,0.094),float3(0.345,0.847,0.329),float3(0.345,0.973,0.596),
    float3(0.0,0.910,0.847),   float3(0.471,0.471,0.471),float3(0.0,0.0,0.0),    float3(0.0,0.0,0.0),
    float3(0.988,0.988,0.988), float3(0.643,0.894,0.988),float3(0.722,0.722,0.973),float3(0.847,0.722,0.973),
    float3(0.973,0.722,0.973), float3(0.973,0.643,0.753),float3(0.941,0.816,0.690),float3(0.988,0.878,0.659),
    float3(0.973,0.847,0.471), float3(0.847,0.973,0.471),float3(0.722,0.973,0.722),float3(0.722,0.973,0.847),
    float3(0.0,0.988,0.988),   float3(0.737,0.737,0.737),float3(0.0,0.0,0.0),    float3(0.0,0.0,0.0)
};

// Nearest hexagon center (grid units) for hex mosaic.
static inline float2 hexCenter(float2 p) {
    float2 r = float2(1.0, 1.7320508);
    float2 h = r * 0.5;
    float2 a = fmod(p, r) - h;
    float2 b = fmod(p - h, r) - h;
    return (dot(a, a) < dot(b, b)) ? (p - a) : (p - b);
}

// Black-body-ish heatmap ramp for the Thermal effect.
static inline float3 heatRamp(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c = mix(float3(0.0, 0.0, 0.10), float3(0.5, 0.0, 0.6), smoothstep(0.0, 0.35, t));
    c = mix(c, float3(1.0, 0.25, 0.0), smoothstep(0.30, 0.65, t));
    c = mix(c, float3(1.0, 0.9, 0.2),  smoothstep(0.60, 0.85, t));
    c = mix(c, float3(1.0, 1.0, 1.0),  smoothstep(0.85, 1.0, t));
    return c;
}

// Sobel luminance gradient magnitude at uv.
static inline float sobelMag(texture2d<float> tex, sampler s, float2 uv, float2 res, float scale) {
    float2 o = scale / res;
    float gx = 0, gy = 0;
    const float kx[9] = {-1,0,1,-2,0,2,-1,0,1};
    const float ky[9] = {-1,-2,-1,0,0,0,1,2,1};
    int idx = 0;
    for (int j = -1; j <= 1; ++j)
    for (int i = -1; i <= 1; ++i) {
        float l = dot(tex.sample(s, uv + float2(i, j) * o).rgb, float3(0.299, 0.587, 0.114));
        gx += l * kx[idx]; gy += l * ky[idx]; ++idx;
    }
    return length(float2(gx, gy));
}

// ---------------------------------------------------------------- fragment

fragment float4 fx_fragment(VOut in [[stage_in]],
                            constant FXUniforms& u [[buffer(0)]],
                            texture2d<float> src   [[texture(0)]],
                            texture2d<float> glyphs[[texture(1)]],
                            texture2d<float> earthDay   [[texture(2)]],
                            texture2d<float> earthNight [[texture(3)]],
                            texture2d_array<float> planetTex [[texture(4)]],
                            sampler samp           [[sampler(0)]])
{
    float2 uv  = in.uv;
    float2 res = u.resolution;
    float2 px  = uv * res;                 // pixel coords
    float  t   = u.time;

    // -------- source generators ----------------------------------------
    if (u.effect == 0) {                   // image / video source with fill mode
        int mode = u.fillMode;
        if (mode == 2 || u.srcSize.x < 1.0 || u.srcSize.y < 1.0) {
            return src.sample(samp, uv);   // stretch (or unknown size)
        }
        float outA = res.x / res.y;
        float srcA = u.srcSize.x / u.srcSize.y;
        if (mode == 1) {                   // COVER — fill the screen, crop overflow
            float2 scale = (srcA > outA) ? float2(outA / srcA, 1.0)
                                         : float2(1.0, srcA / outA);
            return src.sample(samp, (uv - 0.5) * scale + 0.5);
        } else {                           // FIT — contain whole image, letterbox bars
            float2 scale = (srcA > outA) ? float2(1.0, outA / srcA)
                                         : float2(srcA / outA, 1.0);
            float2 suv = (uv - 0.5) / scale + 0.5;
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
            return src.sample(samp, suv);
        }
    }
    if (u.effect == 1) {                   // gradient generator
        float ang = u.p0.x;
        float2 dir = float2(cos(ang), sin(ang));
        float g = dot(uv - 0.5, dir) + 0.5;
        // subtle animated drift
        g += 0.04 * sin(uv.x * 6.2831 + t * 0.4) * u.p0.y;
        return mix(u.colorA, u.colorB, clamp(g, 0.0, 1.0));
    }

    // For all other effects, the input is the previous pass (fills screen 1:1).
    float4 base = src.sample(samp, uv);
    float  L    = luma(base.rgb);

    switch (u.effect) {

    case 2: {   // PIXELATE
        float cell = max(u.p0.x, 1.0);
        float2 quv = (floor(px / cell) + 0.5) * cell / res;
        return src.sample(samp, quv);
    }

    case 3: {   // DITHER — ordered (Bayer 2/4/8) or blue noise. Error-diffusion
                // and Riemersma are handled by the serial compute kernel + blit (effect 38).
        float cell = max(u.p0.x, 1.0);                 // pixel size
        float levels = max(u.p0.y, 2.0);
        bool mono = u.p0.z > 0.5;
        int method = int(u.p0.w + 0.5);
        int2 cellPx = int2(floor(px / cell));
        float2 quv = (float2(cellPx) + 0.5) * cell / res;
        float3 c = src.sample(samp, quv).rgb;
        float thr = (method == 3) ? ign(float2(cellPx)) : ditherThreshold(method, cellPx);
        if (mono) {
            float v = luma(c) + thr / (levels - 1.0);
            float q = floor(v * (levels - 1.0) + 0.5) / (levels - 1.0);
            return mix(u.colorA, u.colorB, clamp(q, 0.0, 1.0));
        } else {
            float3 v = c + thr / (levels - 1.0);
            float3 q = floor(v * (levels - 1.0) + 0.5) / (levels - 1.0);
            return float4(clamp(q, 0.0, 1.0), 1.0);
        }
    }

    case 4: {   // HALFTONE
        float cell = max(u.p0.x, 2.0);
        float ang  = u.p0.y;
        float2x2 R = float2x2(cos(ang), -sin(ang), sin(ang), cos(ang));
        float2 rp = R * px;
        float2 g = (floor(rp / cell) + 0.5) * cell;
        float2 cellCenterUV = (transpose(R) * g) / res;
        float lv = luma(src.sample(samp, cellCenterUV).rgb);
        float2 local = (rp - g) / cell;                // [-0.5,0.5]
        float d = length(local) * 2.0;                 // 0 center .. ~1.4
        float r = sqrt(1.0 - lv);                      // darker => bigger dot
        float dot_ = smoothstep(r + 0.05, r - 0.05, d);
        return mix(u.colorA, u.colorB, dot_);
    }

    case 5: {   // DOTS (round dot grid, brightness = dot fill)
        float cell = max(u.p0.x, 2.0);
        float2 g = (floor(px / cell) + 0.5) * cell;
        float lv = luma(src.sample(samp, g / res).rgb);
        float d = length(px - g) / (cell * 0.5);
        float r = mix(0.05, 1.0, pow(lv, 0.7));
        float dot_ = smoothstep(r, r - 0.12, d);
        return mix(u.colorA, mix(u.colorB, base, u.p0.z), dot_);
    }

    case 6: {   // THRESHOLD
        float thr = u.p0.x;
        float soft = max(u.p0.y, 0.001);
        float m = smoothstep(thr - soft, thr + soft, L);
        return mix(u.colorA, u.colorB, m);
    }

    case 7: {   // POSTERIZE
        float n = max(u.p0.x, 2.0);
        float3 q = floor(base.rgb * n) / (n - 1.0);
        return float4(clamp(q, 0.0, 1.0), base.a);
    }

    case 8: {   // PHOSPHOR (monochrome tint, e.g. green CRT)
        float amt = u.p0.x;
        float gain = u.p0.y;
        float3 tint = u.colorB.rgb * pow(L * gain, 0.9);
        return float4(mix(base.rgb, tint, amt), 1.0);
    }

    case 9: {   // NOISE FIELD (animated domain warp + grain)
        float warp = u.p0.x;
        float scale = max(u.p0.y, 1.0);
        float grain = u.p0.z;
        float2 q = uv * scale;
        float2 flow = float2(vnoise(q + t * 0.15), vnoise(q + 7.3 - t * 0.12)) - 0.5;
        float3 c = src.sample(samp, uv + flow * warp).rgb;
        float n = hash21(px + floor(t * 60.0));
        c += (n - 0.5) * grain;
        return float4(c, 1.0);
    }

    case 10: { // SCANLINES / CRT
        float spacing = max(u.p0.x, 1.0);
        float intensity = u.p0.y;
        float s = 0.5 + 0.5 * sin(px.y / spacing * 3.14159);
        float3 c = base.rgb * (1.0 - intensity * (1.0 - s));
        // slight rgb mask
        float m = 0.85 + 0.15 * cos(px.x * 2.094 + float(int(px.x) % 3));
        return float4(c * m, 1.0);
    }

    case 11: { // VIGNETTE
        float amt = u.p0.x;
        float rad = u.p0.y;
        float d = distance(uv, float2(0.5)) / 0.7071;
        float v = smoothstep(rad, rad - 0.45, d);
        return float4(base.rgb * mix(1.0, v, amt), 1.0);
    }

    case 12: { // EDGE DETECTION (Sobel)
        float2 o = 1.0 / res * max(u.p0.x, 1.0);
        float gx = 0, gy = 0;
        const float kx[9] = {-1,0,1,-2,0,2,-1,0,1};
        const float ky[9] = {-1,-2,-1,0,0,0,1,2,1};
        int idx = 0;
        for (int j = -1; j <= 1; ++j)
        for (int i = -1; i <= 1; ++i) {
            float s = luma(src.sample(samp, uv + float2(i, j) * o).rgb);
            gx += s * kx[idx]; gy += s * ky[idx]; ++idx;
        }
        float g = clamp(length(float2(gx, gy)) * u.p0.y, 0.0, 1.0);
        return mix(u.colorA, u.colorB, g);
    }

    case 13: { // CROSSHATCH
        float L2 = L;
        float spacing = max(u.p0.x, 2.0);
        float3 ink = u.colorB.rgb, paper = u.colorA.rgb;
        float c = 1.0;
        float2 p = px;
        if (L2 < 0.85) c = min(c, step(0.4, fract((p.x + p.y) / spacing)));
        if (L2 < 0.65) c = min(c, step(0.4, fract((p.x - p.y) / spacing)));
        if (L2 < 0.45) c = min(c, step(0.4, fract(p.x / spacing)));
        if (L2 < 0.25) c = min(c, step(0.4, fract(p.y / spacing)));
        return float4(mix(ink, paper, c), 1.0);
    }

    case 14: { // CONTOUR (iso-luminance lines)
        float bands = max(u.p0.x, 2.0);
        float v = L * bands;
        float f = abs(fract(v) - 0.5);
        float line = smoothstep(0.0, fwidth(v) * 1.5 + 0.001, f);
        float3 fillc = mix(u.colorA.rgb, u.colorB.rgb, floor(v) / bands);
        return float4(mix(u.colorB.rgb, fillc, line), 1.0);
    }

    case 15: { // WAVE LINES
        float spacing = max(u.p0.x, 2.0);
        float amp = u.p0.y;
        float speed = u.p0.z;
        float disp = (L - 0.5) * amp + sin(px.x * 0.02 + t * speed) * amp * 0.3;
        float y = px.y + disp;
        float line = abs(fract(y / spacing) - 0.5) * 2.0;
        float m = smoothstep(0.35, 0.65, line);
        return float4(mix(u.colorB.rgb, u.colorA.rgb, m), 1.0);
    }

    case 16: { // VORONOI (cellular mosaic, sampled from source)
        float scale = max(u.p0.x, 1.0);
        float2 g = uv * scale * float2(res.x / res.y, 1.0);
        float2 cell = floor(g);
        float best = 1e9; float2 bestCenter = g;
        for (int j = -1; j <= 1; ++j)
        for (int i = -1; i <= 1; ++i) {
            float2 nb = cell + float2(i, j);
            float2 center = nb + hash22(nb);
            float d = distance(g, center);
            if (d < best) { best = d; bestCenter = center; }
        }
        float2 cuv = bestCenter / (scale * float2(res.x / res.y, 1.0));
        float edge = smoothstep(0.0, 0.04, best);   // would need 2nd-closest for true edges
        return src.sample(samp, clamp(cuv, 0.0, 1.0));
    }

    case 17: { // VHS
        float amt = u.p0.x;
        float yJit = sin(uv.y * 120.0 + t * 8.0) * 0.0015 * amt;
        float wob = (vnoise(float2(uv.y * 30.0, t)) - 0.5) * 0.01 * amt;
        float off = (0.004 + 0.006 * vnoise(float2(t, uv.y * 8.0))) * amt;
        float2 d = float2(yJit + wob, 0.0);
        float r = src.sample(samp, uv + d + float2(off, 0)).r;
        float g = src.sample(samp, uv + d).g;
        float b = src.sample(samp, uv + d - float2(off, 0)).b;
        float3 c = float3(r, g, b);
        c *= 0.9 + 0.1 * sin(px.y * 1.4);                   // scanlines
        c += (hash21(px + floor(t * 50.0)) - 0.5) * 0.10 * amt; // noise
        float band = step(0.992, fract(uv.y * 1.3 - t * 0.4)); // roll bar
        c = mix(c, c + 0.25, band * amt);
        return float4(c, 1.0);
    }

    case 18: { // ASCII
        if (glyphs.get_width() == 0) return base;
        float cell = max(u.p0.x, 4.0);
        int2 cellPx = int2(floor(px / cell));
        float2 cellCenterUV = (float2(cellPx) + 0.5) * cell / res;
        float3 c = src.sample(samp, cellCenterUV).rgb;
        float lv = luma(c);
        int gi = clamp(int(lv * float(u.glyphCount)), 0, u.glyphCount - 1);
        float2 local = (px - float2(cellPx) * cell) / cell;     // [0,1]
        float2 auv = float2((float(gi) + local.x) / float(u.glyphCount), local.y);
        float ink = glyphs.sample(samp, auv).r;
        float3 fg = (u.p0.z > 0.5) ? c : u.colorB.rgb;          // tint or source color
        return float4(mix(u.colorA.rgb, fg, ink), 1.0);
    }

    case 19: { // MATRIX RAIN
        if (glyphs.get_width() == 0) return base;
        float cell = max(u.p0.x, 6.0);
        float speed = u.p0.y;
        int2 cellPx = int2(floor(px / cell));
        int cols = int(res.x / cell);
        float colSeed = hash21(float2(float(cellPx.x), 3.0));
        float colSpeed = 0.4 + colSeed * 1.6;
        float head = fract(colSeed + t * speed * 0.08 * colSpeed) * (res.y / cell + 12.0);
        float dist = head - float(cellPx.y);
        float bright = 0.0;
        if (dist >= 0.0) bright = exp(-dist * 0.18);
        float glyphSel = floor(hash21(float2(float(cellPx.x), float(cellPx.y) + floor(t * 6.0))) * float(u.glyphCount));
        int gi = clamp(int(glyphSel), 0, u.glyphCount - 1);
        float2 local = (px - float2(cellPx) * cell) / cell;
        float2 auv = float2((float(gi) + local.x) / float(u.glyphCount), local.y);
        float ink = glyphs.sample(samp, auv).r * bright;
        // modulate by source so it can reveal an image
        float srcMod = mix(1.0, luma(src.sample(samp, (float2(cellPx)+0.5)*cell/res).rgb) + 0.3, u.p0.z);
        float3 col = u.colorB.rgb;
        if (dist < 1.0 && dist >= 0.0) col = mix(col, float3(1.0), 0.7); // bright head
        return float4(u.colorA.rgb + col * ink * srcMod, 1.0);
    }

    case 20: { // PIXEL SORT (approximation: threshold-driven horizontal streaks)
        float thr = u.p0.x;
        float maxLen = max(u.p0.y, 1.0);
        // walk left until we exit the bright/dark region, sampling sparsely
        float2 dir = float2(1.0 / res.x, 0.0);
        float3 c = base.rgb;
        float startX = px.x;
        for (int i = 1; i < 64; ++i) {
            if (float(i) > maxLen) break;
            float2 suv = uv - dir * float(i);
            if (suv.x < 0.0) break;
            float sl = luma(src.sample(samp, suv).rgb);
            if (sl < thr) break;             // region boundary
            c = src.sample(samp, suv).rgb;   // smear the region's leading color
        }
        return float4(c, 1.0);
    }

    case 21: { // KALEIDOSCOPE
        float seg = max(u.p0.x, 2.0);
        float spin = u.p0.y;
        float2 c = uv - 0.5;
        float r = length(c);
        float a = atan2(c.y, c.x) + t * 0.15 * spin;
        float segAng = 6.2831853 / seg;
        a = fmod(a, segAng);
        a = min(a, segAng - a);
        float2 q = 0.5 + float2(cos(a), sin(a)) * r;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 22: { // CHROMATIC SHIFT
        float amt = u.p0.x / 100.0;
        float ang = u.p0.y;
        float2 d = float2(cos(ang), sin(ang)) * amt;
        float r = src.sample(samp, uv + d).r;
        float g = src.sample(samp, uv).g;
        float b = src.sample(samp, uv - d).b;
        return float4(r, g, b, 1.0);
    }

    case 23: { // BLOOM
        float thr = u.p0.x;
        float inten = u.p0.y;
        float rad = max(u.p0.z, 1.0);
        float3 sum = float3(0.0);
        float wsum = 0.0;
        for (int i = 0; i < 12; ++i) {
            float ang = float(i) / 12.0 * 6.2831853;
            for (int k = 1; k <= 2; ++k) {
                float2 off = float2(cos(ang), sin(ang)) * (rad * float(k)) / res;
                float3 s = src.sample(samp, uv + off).rgb;
                float b = max(luma(s) - thr, 0.0);
                sum += s * b; wsum += 1.0;
            }
        }
        float3 bloom = (sum / max(wsum, 1.0)) * inten * 6.0;
        return float4(base.rgb + bloom, 1.0);
    }

    case 24: { // HEX MOSAIC
        float s = max(u.p0.x, 4.0);
        float2 p = px / s;
        float2 ctr = hexCenter(p) * s / res;
        return src.sample(samp, clamp(ctr, 0.0, 1.0));
    }

    case 25: { // MIRROR
        int mode = int(u.p0.x + 0.5);
        float2 q = uv;
        if (mode == 0 || mode == 2) q.x = 0.5 - abs(q.x - 0.5);
        if (mode == 1 || mode == 2) q.y = 0.5 - abs(q.y - 0.5);
        return src.sample(samp, q);
    }

    case 26: { // GLITCH BLOCKS
        float amt = u.p0.x;
        float blockH = 0.05;
        float row = floor(uv.y / blockH);
        float slot = floor(t * 8.0);
        float h = hash21(float2(row, slot));
        float2 q = uv;
        if (h > 0.6) q.x += (hash21(float2(row, slot + 2.7)) - 0.5) * 0.3 * amt;
        float3 c = src.sample(samp, q).rgb;
        if (h > 0.85) {
            float sh = 0.02 * amt;
            c.r = src.sample(samp, q + float2(sh, 0)).r;
            c.b = src.sample(samp, q - float2(sh, 0)).b;
        }
        return float4(c, 1.0);
    }

    case 27: { // GAMEBOY (4-tone palette quantize)
        float3 p0c = float3(0.06, 0.22, 0.06);
        float3 p1c = float3(0.19, 0.38, 0.19);
        float3 p2c = float3(0.55, 0.67, 0.06);
        float3 p3c = float3(0.61, 0.74, 0.06);
        float l = luma(base.rgb);
        float thr = ditherThreshold(1, int2(px / max(u.p0.x, 1.0)));
        l = clamp(l + thr * 0.5, 0.0, 1.0);
        float3 c = (l < 0.25) ? p0c : (l < 0.5) ? p1c : (l < 0.75) ? p2c : p3c;
        return float4(c, 1.0);
    }

    case 28: { // NEON EDGES
        float gain = u.p0.x;
        float g = sobelMag(src, samp, uv, res, max(u.p0.y, 1.0));
        float e = pow(clamp(g * gain, 0.0, 1.0), 1.4);
        return float4(u.colorA.rgb + u.colorB.rgb * e, 1.0);
    }

    case 29: { // FISHEYE
        float amt = u.p0.x;
        float2 c = uv - 0.5;
        float r2 = dot(c, c);
        float2 q = c * (1.0 + amt * r2) + 0.5;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 30: { // SWIRL
        float amt = u.p0.x;
        float2 c = uv - 0.5;
        float r = length(c);
        float a = amt * (0.5 - r) + t * 0.1 * u.p0.y;
        float s = sin(a), co = cos(a);
        float2 q = float2(c.x * co - c.y * s, c.x * s + c.y * co) + 0.5;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 31: { // RIPPLE
        float amp = u.p0.x;
        float freq = u.p0.y;
        float speed = u.p0.z;
        float2 c = uv - 0.5;
        float r = length(c) + 1e-5;
        float off = sin(r * freq - t * speed) * amp * 0.01;
        float2 q = uv + (c / r) * off;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 32: { // TOON
        float bands = max(u.p0.x, 2.0);
        float3 c = floor(base.rgb * bands + 0.5) / bands;
        float g = sobelMag(src, samp, uv, res, 1.0);
        float edge = smoothstep(0.25, 0.55, g * u.p0.y);
        return float4(c * (1.0 - edge), 1.0);
    }

    case 33: { // THERMAL
        float l = luma(base.rgb) * u.p0.x;
        return float4(heatRamp(l), 1.0);
    }

    case 34: { // TRUCHET
        float s = max(u.p0.x, 4.0);
        float2 p = px / s;
        float2 id = floor(p);
        float2 f = fract(p);
        if (hash21(id) < 0.5) f.x = 1.0 - f.x;
        float d = min(length(f - float2(0.0, 0.0)), length(f - float2(1.0, 1.0)));
        float line = abs(d - 0.5);
        float m = smoothstep(0.12, 0.06, line);
        float lum = luma(src.sample(samp, (id + 0.5) * s / res).rgb);
        return float4(mix(u.colorA.rgb, u.colorB.rgb, m * smoothstep(0.15, 0.6, lum)), 1.0);
    }

    case 35: { // LED PANEL
        float cell = max(u.p0.x, 4.0);
        float gap = u.p0.y;
        float2 g = floor(px / cell);
        float3 c = src.sample(samp, (g + 0.5) * cell / res).rgb;
        float levels = 6.0;
        c = floor(c * levels + 0.5) / levels;
        float2 f = fract(px / cell) - 0.5;
        float d = length(f);
        float led = smoothstep(0.5 - gap, 0.5 - gap - 0.08, d);
        return float4(c * led * 1.25, 1.0);
    }

    case 36: { // NES 8-BIT (snap to the NES palette, chunky pixels, soft scanline)
        float cell = max(u.p0.x, 2.0);
        float scan = u.p0.y;
        float sat = max(u.p0.z, 0.0);
        int2 cellPx = int2(floor(px / cell));
        float2 quv = (float2(cellPx) + 0.5) * cell / res;
        float3 c = src.sample(samp, quv).rgb;
        // punch up saturation a touch before quantizing (NES look)
        float l = luma(c);
        c = clamp(mix(float3(l), c, sat), 0.0, 1.0);
        float3 best = NES[0]; float bd = 1e9;
        for (int i = 0; i < 64; ++i) {
            float3 d = c - NES[i];
            float dd = dot(d, d);
            if (dd < bd) { bd = dd; best = NES[i]; }
        }
        // subtle CRT scanline on the pixel rows
        float s = 1.0 - scan * (0.5 - 0.5 * cos(px.y / cell * 6.2831853));
        return float4(best * s, 1.0);
    }

    case 37: { // STARFIELD — flying through adjustable stars (generative)
        float speed = u.p0.x;
        float density = max(u.p0.y, 1.0);
        float warp = u.p0.z;
        float sz = max(u.p0.w, 0.2);
        float2 uv2 = (uv - 0.5) * float2(res.x / res.y, 1.0);
        float2 rd = normalize(uv2 + 1e-5);
        float3 acc = float3(0.0);
        const int LAYERS = 18;
        for (int i = 0; i < LAYERS; ++i) {
            float fi = (float(i) + 0.5) / float(LAYERS);
            float depth = fract(fi + t * speed * 0.08);     // 0..1, wraps (flying in)
            float scale = mix(density * 2.0, density * 0.25, depth);
            float fade = depth * (1.0 - depth) * 4.0;
            float2 p = uv2 * scale + float2(fi * 91.7, fi * 47.3);
            float2 cell = floor(p);
            float2 f = fract(p) - 0.5;
            float2 jit = (hash22(cell + fi * 71.0) - 0.5) * 0.7;
            float2 fd = f - jit;
            fd -= rd * dot(fd, rd) * warp;                  // streak along radial dir
            float d = length(fd);
            float star = smoothstep(0.06 * sz, 0.0, d);
            float b = hash21(cell + fi * 31.0);
            acc += star * fade * (0.35 + 0.65 * b);
        }
        acc = clamp(acc, 0.0, 1.0);
        return float4(mix(u.colorA.rgb, u.colorB.rgb, acc), 1.0);
    }

    case 39: { // UNIVERSE — textured day/night Earth + textured orbiting planets + stars.
               // p0=(earthSize,spin,starDensity,planetSpeed) p1.xyz=sun(view) p2.x=userLon
        float aspect = res.x / res.y;
        float2 sc = (uv - 0.5) * float2(aspect, 1.0);
        float earthR = max(u.p0.x, 0.05);
        float spin = u.p0.y;
        float starD = max(u.p0.z, 1.0);
        float pSpeed = u.p0.w;
        float3 sun = normalize(u.p1.xyz);
        bool haveTex = earthDay.get_width() > 4;
        const float INV2PI = 0.1591549, INVPI = 0.3183099;
        float3 col = float3(0.0);

        // ---- starfield backdrop (slowly rotating) ----
        {
            float ca = cos(t * 0.008), sa = sin(t * 0.008);
            float2 q = float2(ca * sc.x - sa * sc.y, sa * sc.x + ca * sc.y);
            for (int L = 0; L < 3; ++L) {
                float s = starD * (2.0 + float(L) * 2.5);
                float2 g = q * s;
                float2 cell = floor(g), f = fract(g) - 0.5;
                float2 j = (hash22(cell + float(L) * 17.0) - 0.5) * 0.8;
                float star = smoothstep(0.06, 0.0, length(f - j));
                col += star * (0.25 + 0.75 * hash21(cell + float(L) * 3.0)) * 0.5;
            }
        }

        float psz[8]   = {0.10, 0.16, 0.12, 0.32, 0.27, 0.20, 0.19, 0.09};
        float pspin[8] = {0.06, 0.04, 0.07, 0.10, 0.09, 0.05, 0.05, 0.08};

        // ---- faint orbit rings ----
        for (int i = 0; i < 8; ++i) {
            float orad = earthR + 0.09 + float(i) * 0.052;
            float ringp = length(float2(sc.x / orad, sc.y / (orad * 0.42)));
            col += float3(0.10, 0.2, 0.38) * smoothstep(0.010, 0.0, abs(ringp - 1.0)) * 0.16;
        }

        // Planets are drawn in two passes (behind Earth, then in front).
        for (int pass2 = 0; pass2 < 2; ++pass2) {
            for (int i = 0; i < 8; ++i) {
                float orad = earthR + 0.09 + float(i) * 0.052;
                float spd = (8.0 - float(i)) * 0.05 * pSpeed;
                float ph = hash21(float2(float(i), 7.0)) * 6.2831853;
                float a = t * spd * 0.1 + ph;
                bool front = sin(a) > 0.0;
                if ((pass2 == 0 && front) || (pass2 == 1 && !front)) continue;
                float2 pp = float2(cos(a) * orad, sin(a) * orad * 0.42);
                float pr = earthR * psz[i];

                if (i == 4) {  // Saturn rings (drawn before the body)
                    float2 rl = (sc - pp) / float2(pr * 2.3, pr * 2.3 * 0.36);
                    float rr = length(rl);
                    float ring = smoothstep(1.0, 0.93, rr) * smoothstep(0.62, 0.68, rr);
                    ring *= 1.0 - 0.7 * smoothstep(0.80, 0.815, rr) * smoothstep(0.86, 0.845, rr);
                    col = mix(col, float3(0.80, 0.72, 0.52), ring * 0.75);
                }

                float2 lp = (sc - pp) / pr;
                float r2 = dot(lp, lp);
                if (r2 < 1.0) {
                    float3 n; n.xy = lp; n.z = sqrt(1.0 - r2);
                    float aa = t * pspin[i];
                    float cs = cos(aa), sn = sin(aa);
                    float3 nw = float3(cs * n.x + sn * n.z, n.y, -sn * n.x + cs * n.z);
                    float lat = asin(clamp(nw.y, -1.0, 1.0));
                    float lon = atan2(nw.x, nw.z);
                    float2 tuv = float2(lon * INV2PI + 0.5, 0.5 - lat * INVPI);
                    float3 base = haveTex ? planetTex.sample(samp, tuv, i).rgb : float3(0.6, 0.55, 0.5);
                    float lit = max(dot(n, sun), 0.0) * 0.92 + 0.08;
                    col = mix(col, base * lit, smoothstep(1.0, 0.9, r2));
                }
            }

            if (pass2 == 0) {  // ---- Earth (between behind- and front-planets) ----
                float r = length(sc);
                if (r < earthR) {
                    float3 N; N.xy = sc / earthR;
                    N.z = sqrt(max(0.0, 1.0 - dot(N.xy, N.xy)));
                    float ea = u.p2.x + t * spin * 0.05;
                    float cs = cos(ea), sn = sin(ea);
                    float3 Nw = float3(cs * N.x + sn * N.z, N.y, -sn * N.x + cs * N.z);
                    float lat = asin(clamp(Nw.y, -1.0, 1.0));
                    float lon = atan2(Nw.x, Nw.z);
                    float2 tuv = float2(lon * INV2PI + 0.5, 0.5 - lat * INVPI);
                    float ndl = dot(N, sun);
                    float day = smoothstep(-0.10, 0.18, ndl);
                    float3 dayC, nightC;
                    if (haveTex) {
                        dayC = earthDay.sample(samp, tuv).rgb;
                        nightC = earthNight.sample(samp, tuv).rgb;
                    } else {
                        float land = fbm(float2(lon, lat) * 1.7 + 3.0);
                        float il = smoothstep(0.52, 0.57, land);
                        dayC = mix(float3(0.03, 0.16, 0.33), float3(0.10, 0.34, 0.16), il);
                        nightC = dayC * 0.05;
                    }
                    float3 ec = mix(nightC * 1.3, dayC * (0.3 + 0.8 * max(ndl, 0.0)), day);
                    ec *= mix(0.5, 1.0, N.z);                               // limb darkening
                    ec += float3(0.35, 0.6, 1.0) * smoothstep(0.8, 1.0, 1.0 - N.z) * 0.4 * day; // atmosphere
                    col = ec;
                } else {
                    float glow = smoothstep(earthR * 1.3, earthR, r);
                    float side = smoothstep(-0.2, 0.4, dot(normalize(float3(sc, 0.001)), sun));
                    col += float3(0.2, 0.45, 0.95) * glow * (0.2 + 0.5 * side);
                }
            }
        }
        return float4(col, 1.0);
    }

    case 38: { // BLIT — crisp nearest upscale of a precomputed dither grid
        float2 gridSize = u.p0.xy;
        float2 g = (floor(uv * gridSize) + 0.5) / gridSize;
        return src.sample(samp, g);
    }

    default:
        return base;
    }
}

// ---------------------------------------------------------------- serial dither

// Distribute quantization error to a neighbour (with bounds check). Single-threaded,
// so plain device memory is correct and faster than atomics.
static inline void spread(device float* err, int x, int y, int W, int H, float e) {
    if (x < 0 || x >= W || y < 0 || y >= H || e == 0.0) return;
    err[y * W + x] += e;
}

// Serial error-diffusion + Riemersma dither on a coarse grid, single thread.
// Kernel ids: 0 Floyd-Steinberg, 1 Atkinson, 2 Jarvis, 3 Stucki, 4 Burkes,
// 5 Sierra3, 6 Sierra2, 7 Sierra-Lite, 8 Fan, 9 Shiau-Fan, 10 Shiau-Fan2,
// 11 Simple2D, 100 Riemersma.
kernel void dither_serial(texture2d<float, access::sample> inTex [[texture(0)]],
                          texture2d<float, access::write>  outTex [[texture(1)]],
                          device float* err [[buffer(1)]],
                          constant FXUniforms& u [[buffer(0)]],
                          sampler samp [[sampler(0)]],
                          uint tid [[thread_position_in_grid]])
{
    if (tid != 0) return;
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5);
    int kid = int(u.p1.x + 0.5);
    float levels = max(u.p0.y, 2.0);
    bool mono = u.p0.z > 0.5;
    float3 cA = u.colorA.rgb, cB = u.colorB.rgb;

    for (int i = 0; i < W * H; ++i) err[i] = 0.0;

    // Traversal: raster for diffusion kernels, Hilbert order for Riemersma.
    int total = W * H;
    int side = 1; while (side < W || side < H) side <<= 1;   // power of two cover
    bool riem = (kid == 100);
    const int RN = 16;
    float w[RN]; float wsum = 0.0;
    for (int k = 0; k < RN; ++k) { w[k] = pow(1.0/16.0, float(RN-1-k)/float(RN-1)); wsum += w[k]; }
    for (int k = 0; k < RN; ++k) w[k] /= wsum;
    float histM[RN]; float3 histC[RN];
    for (int k = 0; k < RN; ++k) { histM[k] = 0.0; histC[k] = float3(0.0); }

    int count = riem ? side * side : total;
    for (int idx = 0; idx < count; ++idx) {
        int x, y;
        if (riem) {
            // Hilbert d -> (x,y)
            int rx, ry, t = idx; x = 0; y = 0;
            for (int s = 1; s < side; s <<= 1) {
                rx = 1 & (t / 2); ry = 1 & (t ^ rx);
                if (ry == 0) { if (rx == 1) { x = s - 1 - x; y = s - 1 - y; } int tmp = x; x = y; y = tmp; }
                x += s * rx; y += s * ry; t /= 4;
            }
            if (x >= W || y >= H) continue;
        } else {
            y = idx / W; x = idx % W;
        }

        float2 uv = (float2(x, y) + 0.5) / float2(W, H);
        float3 c = inTex.sample(samp, uv).rgb;

        if (mono) {
            float accM;
            if (riem) { accM = 0.0; for (int k = 0; k < RN; ++k) accM += histM[k] * w[k]; }
            else accM = err[y * W + x];
            float v = dot(c, float3(0.299, 0.587, 0.114)) + accM;
            float q = clamp(floor(v * (levels - 1.0) + 0.5) / (levels - 1.0), 0.0, 1.0);
            float e = v - q;
            outTex.write(float4(mix(cA, cB, q), 1.0), uint2(x, y));
            if (riem) { for (int k = 0; k < RN-1; ++k) histM[k] = histM[k+1]; histM[RN-1] = e; }
            else
            switch (kid) {
            case 0: spread(err,x+1,y,W,H,e*7.0/16); spread(err,x-1,y+1,W,H,e*3.0/16); spread(err,x,y+1,W,H,e*5.0/16); spread(err,x+1,y+1,W,H,e*1.0/16); break;
            case 1: { float a=e/8.0; spread(err,x+1,y,W,H,a); spread(err,x+2,y,W,H,a); spread(err,x-1,y+1,W,H,a); spread(err,x,y+1,W,H,a); spread(err,x+1,y+1,W,H,a); spread(err,x,y+2,W,H,a);} break;
            case 2: { float d=e/48.0; spread(err,x+1,y,W,H,d*7);spread(err,x+2,y,W,H,d*5);spread(err,x-2,y+1,W,H,d*3);spread(err,x-1,y+1,W,H,d*5);spread(err,x,y+1,W,H,d*7);spread(err,x+1,y+1,W,H,d*5);spread(err,x+2,y+1,W,H,d*3);spread(err,x-2,y+2,W,H,d*1);spread(err,x-1,y+2,W,H,d*3);spread(err,x,y+2,W,H,d*5);spread(err,x+1,y+2,W,H,d*3);spread(err,x+2,y+2,W,H,d*1);} break;
            case 3: { float d=e/42.0; spread(err,x+1,y,W,H,d*8);spread(err,x+2,y,W,H,d*4);spread(err,x-2,y+1,W,H,d*2);spread(err,x-1,y+1,W,H,d*4);spread(err,x,y+1,W,H,d*8);spread(err,x+1,y+1,W,H,d*4);spread(err,x+2,y+1,W,H,d*2);spread(err,x-2,y+2,W,H,d*1);spread(err,x-1,y+2,W,H,d*2);spread(err,x,y+2,W,H,d*4);spread(err,x+1,y+2,W,H,d*2);spread(err,x+2,y+2,W,H,d*1);} break;
            case 4: { float d=e/32.0; spread(err,x+1,y,W,H,d*8);spread(err,x+2,y,W,H,d*4);spread(err,x-2,y+1,W,H,d*2);spread(err,x-1,y+1,W,H,d*4);spread(err,x,y+1,W,H,d*8);spread(err,x+1,y+1,W,H,d*4);spread(err,x+2,y+1,W,H,d*2);} break;
            case 5: { float d=e/32.0; spread(err,x+1,y,W,H,d*5);spread(err,x+2,y,W,H,d*3);spread(err,x-2,y+1,W,H,d*2);spread(err,x-1,y+1,W,H,d*4);spread(err,x,y+1,W,H,d*5);spread(err,x+1,y+1,W,H,d*4);spread(err,x+2,y+1,W,H,d*2);spread(err,x-1,y+2,W,H,d*2);spread(err,x,y+2,W,H,d*3);spread(err,x+1,y+2,W,H,d*2);} break;
            case 6: { float d=e/16.0; spread(err,x+1,y,W,H,d*4);spread(err,x+2,y,W,H,d*3);spread(err,x-2,y+1,W,H,d*1);spread(err,x-1,y+1,W,H,d*2);spread(err,x,y+1,W,H,d*3);spread(err,x+1,y+1,W,H,d*2);spread(err,x+2,y+1,W,H,d*1);} break;
            case 7: { float d=e/4.0; spread(err,x+1,y,W,H,d*2);spread(err,x-1,y+1,W,H,d*1);spread(err,x,y+1,W,H,d*1);} break;
            case 8: { float d=e/16.0; spread(err,x+1,y,W,H,d*7);spread(err,x-1,y+1,W,H,d*1);spread(err,x,y+1,W,H,d*3);spread(err,x+1,y+1,W,H,d*5);} break;
            case 9: { float d=e/16.0; spread(err,x+1,y,W,H,d*8);spread(err,x-2,y+1,W,H,d*1);spread(err,x-1,y+1,W,H,d*1);spread(err,x,y+1,W,H,d*2);spread(err,x+1,y+1,W,H,d*4);} break;
            case 10:{ float d=e/16.0; spread(err,x+1,y,W,H,d*8);spread(err,x-3,y+1,W,H,d*1);spread(err,x-2,y+1,W,H,d*1);spread(err,x-1,y+1,W,H,d*2);spread(err,x,y+1,W,H,d*4);} break;
            case 11:{ float d=e/2.0; spread(err,x+1,y,W,H,d);spread(err,x,y+1,W,H,d);} break;
            case 100: spread(err,x+1,y,W,H,e*7.0/16); spread(err,x-1,y+1,W,H,e*3.0/16); spread(err,x,y+1,W,H,e*5.0/16); spread(err,x+1,y+1,W,H,e*1.0/16); break;
            default: break;
            }
        } else {
            float3 acc3;
            if (riem) { acc3 = float3(0.0); for (int k = 0; k < RN; ++k) acc3 += histC[k] * w[k]; }
            else acc3 = float3(err[y * W + x]);
            float3 v = c + acc3;
            float3 q = clamp(floor(v * (levels - 1.0) + 0.5) / (levels - 1.0), 0.0, 1.0);
            float3 e3 = v - q;
            outTex.write(float4(q, 1.0), uint2(x, y));
            if (riem) { for (int k = 0; k < RN-1; ++k) histC[k] = histC[k+1]; histC[RN-1] = e3; }
            else { float e = dot(e3, float3(0.333)); spread(err,x+1,y,W,H,e*7.0/16); spread(err,x-1,y+1,W,H,e*3.0/16); spread(err,x,y+1,W,H,e*5.0/16); spread(err,x+1,y+1,W,H,e*1.0/16); }
        }
    }
}
