//  DotStudio.h — the `metal` engine, version 1: everything a scene package can use.
//
//  A scene is one function:
//
//      #include <DotStudio.h>
//      float4 dsScene(float2 uv, DSContext ctx) { … }
//
//  uv runs 0…1 across the screen, y UP (0 = bottom). Return display-sRGB colour (what you'd pick
//  in a colour picker) with alpha 1. The engine adds a sub-LSB dither, clamps to 0…1, and replaces
//  NaN / infinity with black, so a stray division never shows garbage.
//
//  Everything here is prefixed `ds` (functions) or `DS` (types) so it never collides with your own
//  names. All of it is plain Metal Shading Language (metal_stdlib is already included, and
//  `using namespace metal;` is in effect).

#ifndef DOTSTUDIO_H
#define DOTSTUDIO_H

// ================================================================================ context

/// The real sun where the Mac is (or at 40° N on its time zone's meridian without a location).
struct DSSun {
    float elevation;    // degrees above the horizon, −90…90 (negative = below)
    float azimuth;      // degrees clockwise from north, 0…360 (90 = east, 180 = south)
    bool  isDay;        // elevation > −0.833° (the sun's upper edge is up)
};

/// The live weather (eased over 90 s when it changes), all 0…1. Clear sky when unknown.
struct DSWeather {
    float cloud;        // cloud cover
    float rain;         // rain intensity (0 when it's snowing)
    float snow;         // snow intensity
    float fog;          // 0 = 20 km visibility … 1 = ~150 m
    float wind;         // 0 = calm … 1 = gale (≈ 20 m/s)
};

/// What's playing in Spotify / Music. `a`, `b`, `c` = the album art's palette (display sRGB,
/// brightest first; grey when there's no artwork).
struct DSMusic {
    bool   playing;
    float  level;       // a smooth 0…1 envelope: rises over ~1.5 s while music plays, falls when
                        // it stops (not an audio meter: DotStudio never listens to the sound)
    float3 a, b, c;
};

struct DSDate {
    int year, month, day;   // month 1–12, day 1–31
    int weekday;            // 1 = Sunday … 7 = Saturday
};

/// Everything a scene can read. Read-only; passed by value.
struct DSContext {
    float2    res;          // output size in pixels
    float     aspect;       // res.x / res.y
    float     t;            // seconds since the scene started (stepped to the manifest's fps if
                            // "stepped": true); wraps every hour behind a crossfade — use
                            // periodic motion, never t as a huge coordinate
    float     clock;        // local wall-clock seconds since midnight, 0…86400
    DSDate    date;
    DSSun     sun;
    DSWeather weather;
    DSMusic   music;
    float     p[16];        // your manifest params in order: p[0] = the first param, …
                            // (slider = its value, toggle = 0 / 1, menu = the option's index)
    float3    colorA;       // the style's two colours (manifest "colors" a / b), display sRGB
    float3    colorB;
    float     seed;         // 0…1, fixed per style: vary layouts between copies of a scene
    // Assets (manifest "assets"; transparent black when there's no such asset). Sample with
    // `ctx.asset0.sample(ctx.smp, uv)` — uv 0…1, y up, colours display sRGB.
    texture2d<float> asset0;
    texture2d<float> asset1;
    texture2d<float> asset2;
    texture2d<float> asset3;
    sampler   smp;          // linear, clamp to edge
};

// ================================================================================ constants

constant float DS_PI  = 3.14159265358979;
constant float DS_TAU = 6.28318530717959;

// ================================================================================ coordinates

/// Screen-height units centred on the screen: x −aspect/2…aspect/2, y −0.5…0.5. Shapes stay round
/// on any display, and "0.1" is a tenth of the screen's height everywhere.
static inline float2 dsCentered(float2 uv, DSContext ctx) {
    return (uv - 0.5) * float2(ctx.aspect, 1.0);
}
/// One pixel in the units of dsCentered — the width to antialias an edge over.
static inline float dsPixel(DSContext ctx) { return 1.0 / ctx.res.y; }

/// A 2D rotation by `a` radians: `p = dsRotate(a) * p`.
static inline float2x2 dsRotate(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

static inline float dsRemap(float x, float a, float b, float c, float d) {
    return c + (d - c) * saturate((x - a) / (b - a));
}

/// A smooth 0→1→0 pulse over [a, b] with soft edges `w` wide.
static inline float dsBand(float x, float a, float b, float w) {
    return smoothstep(a - w, a + w, x) * (1.0 - smoothstep(b - w, b + w, x));
}

// ================================================================================ hashing & noise

/// Hash: a float2 / float3 → 0…1 (deterministic, no texture).
static inline float dsHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static inline float dsHash(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}
static inline float dsHash(float x) { return dsHash(float2(x, 17.17)); }
/// Two independent hashes, 0…1.
static inline float2 dsHash2(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
static inline float3 dsHash3(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

/// Value noise, smooth, 0…1.
static inline float dsNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = dsHash(i), b = dsHash(i + float2(1, 0)), c = dsHash(i + float2(0, 1)), d = dsHash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static inline float dsNoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = dsHash(i), n100 = dsHash(i + float3(1, 0, 0));
    float n010 = dsHash(i + float3(0, 1, 0)), n110 = dsHash(i + float3(1, 1, 0));
    float n001 = dsHash(i + float3(0, 0, 1)), n101 = dsHash(i + float3(1, 0, 1));
    float n011 = dsHash(i + float3(0, 1, 1)), n111 = dsHash(i + float3(1, 1, 1));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

/// Gradient (Perlin-style) noise, smooth, about −1…1 — fewer grid artefacts than dsNoise.
static inline float dsGradientNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 ga = dsHash2(i) * 2.0 - 1.0, gb = dsHash2(i + float2(1, 0)) * 2.0 - 1.0;
    float2 gc = dsHash2(i + float2(0, 1)) * 2.0 - 1.0, gd = dsHash2(i + float2(1, 1)) * 2.0 - 1.0;
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0)), vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    return 1.4 * mix(mix(va, vb, u.x), mix(vc, vd, u.x), u.y);
}

/// Fractal noise: `octaves` (1…8) of dsNoise, each twice the frequency and half the amplitude.
/// 0…1. Every octave costs a noise call — 4–5 is plenty on a 5K screen.
static inline float dsFbm(float2 p, int octaves) {
    float v = 0.0, a = 0.5, n = 0.0;
    float2x2 r = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    for (int i = 0; i < clamp(octaves, 1, 8); i++) {
        v += a * dsNoise(p); n += a;
        p = r * p * 2.02 + 17.0;
        a *= 0.5;
    }
    return v / n;
}
static inline float dsFbm(float3 p, int octaves) {
    float v = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < clamp(octaves, 1, 8); i++) {
        v += a * dsNoise(p); n += a;
        p = p * 2.03 + float3(17.0, 9.0, 3.0);
        a *= 0.5;
    }
    return v / n;
}

/// Domain warp: p pushed along fbm, `amount` in p's units (organic marble / smoke / ink).
static inline float2 dsWarp(float2 p, float amount, float t) {
    float2 q = float2(dsFbm(p + float2(0.0, 0.13 * t), 4), dsFbm(p + float2(5.2, 1.3) - float2(0.11 * t, 0.0), 4));
    return p + amount * (q - 0.5) * 2.0;
}

/// Voronoi (cellular) noise at p: .x = distance to the nearest cell point, .y = to the second
/// nearest (edges where y − x ≈ 0), .z = the nearest cell's id hash 0…1. `jitter` 0…1 (0 = a grid).
static inline float3 dsVoronoi(float2 p, float jitter) {
    float2 i = floor(p), f = fract(p);
    float d1 = 8.0, d2 = 8.0, id = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(x, y);
            float2 o = 0.5 + (dsHash2(i + g) - 0.5) * jitter;
            float d = length(g + o - f);
            if (d < d1) { d2 = d1; d1 = d; id = dsHash(i + g + 0.37); }
            else if (d < d2) { d2 = d; }
        }
    }
    return float3(d1, d2, id);
}

// ================================================================================ 2D SDFs
// Signed distance: negative inside, positive outside, in p's units. Draw an edge with
// `smoothstep(px, -px, d)` (px = dsPixel(ctx) in dsCentered units) — crisp at any resolution.

static inline float dsSdCircle(float2 p, float r) { return length(p) - r; }
static inline float dsSdBox(float2 p, float2 halfSize) {
    float2 d = abs(p) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
static inline float dsSdRoundBox(float2 p, float2 halfSize, float r) {
    return dsSdBox(p, halfSize - r) - r;
}
/// A segment a→b (a line r wide when you subtract r).
static inline float dsSdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h);
}
static inline float dsSdRing(float2 p, float r, float thickness) { return abs(length(p) - r) - thickness * 0.5; }
static inline float dsSdEquilateralTriangle(float2 p, float r) {
    const float k = 1.7320508;
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if (p.x + k * p.y > 0.0) p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}
static inline float dsSdHexagon(float2 p, float r) {
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    p = abs(p);
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    p -= float2(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y);
}
/// A five-pointed star (r = outer radius, inner = 0.4–0.6).
static inline float dsSdStar(float2 p, float r, float inner) {
    const float2 k1 = float2(0.809016994375, -0.587785252292);
    const float2 k2 = float2(-k1.x, k1.y);
    p.x = abs(p.x);
    p -= 2.0 * max(dot(k1, p), 0.0) * k1;
    p -= 2.0 * max(dot(k2, p), 0.0) * k2;
    p.x = abs(p.x);
    p.y -= r;
    float2 ba = inner * float2(-k1.y, k1.x) - float2(0, 1);
    float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
    return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}

/// Antialiased fill of an SDF: 1 inside, 0 outside, a `px`-wide edge.
static inline float dsFill(float d, float px) { return saturate(0.5 - d / px); }
/// A soft glow around an SDF: 1 at the edge, falling off over `radius`.
static inline float dsGlow(float d, float radius) { return exp(-max(d, 0.0) / max(radius, 1e-5)); }

// ================================================================================ 3D SDFs
static inline float dsSdSphere(float3 p, float r) { return length(p) - r; }
static inline float dsSdBox(float3 p, float3 halfSize) {
    float3 q = abs(p) - halfSize;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
static inline float dsSdTorus(float3 p, float major, float minor) {
    return length(float2(length(p.xz) - major, p.y)) - minor;
}
static inline float dsSdPlane(float3 p, float3 n, float h) { return dot(p, n) + h; }
static inline float dsSdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - r;
}

// ================================================================================ SDF operators
/// Smooth union / subtraction / intersection, blending over `k` (in distance units).
static inline float dsSmin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / max(k, 1e-6);
    return min(a, b) - h * h * k * 0.25;
}
static inline float dsSmax(float a, float b, float k) { return -dsSmin(-a, -b, k); }
static inline float dsSubtract(float d, float cut, float k) { return dsSmax(d, -cut, k); }
/// Repeat space every `cell` (returns the local coordinate, centred).
static inline float2 dsRepeat(float2 p, float2 cell) { return p - cell * round(p / cell); }
static inline float3 dsRepeat(float3 p, float3 cell) { return p - cell * round(p / cell); }

/// Sphere-tracing helper pieces: a camera ray for screen point `c` (dsCentered units).
/// ro = eye, ta = target, zoom ≈ 1.5 (higher = narrower field of view).
static inline float3 dsCameraRay(float2 c, float3 ro, float3 ta, float zoom) {
    float3 f = normalize(ta - ro);
    float3 r = normalize(cross(float3(0, 1, 0), f));
    float3 u = cross(f, r);
    return normalize(c.x * r + c.y * u + zoom * f);
}

// ================================================================================ colour
/// sRGB ⇄ linear. Mix, light and blur in LINEAR, return sRGB: gradients look right and glows
/// don't go muddy.
static inline float3 dsToLinear(float3 c) {
    c = max(c, 0.0);
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}
static inline float3 dsToSrgb(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}
static inline float dsLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// Iñigo Quilez's cosine palette: a + b·cos(2π(c·t + d)). Try
/// dsPalette(t, 0.5, 0.5, 1.0, float3(0.0, 0.33, 0.67)) for a rainbow.
static inline float3 dsPalette(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(DS_TAU * (c * t + d));
}
static inline float3 dsHsv(float h, float s, float v) {
    float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(float3(1.0), k, s);
}
static inline float3 dsRgbToHsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}
/// Shift a colour's hue (turns) and scale its saturation, keeping its value.
static inline float3 dsAdjust(float3 rgb, float hueShift, float saturation) {
    float3 h = dsRgbToHsv(rgb);
    return dsHsv(h.x + hueShift, saturate(h.y * saturation), h.z);
}
/// Filmic tone map (ACES fit) for linear HDR → linear 0…1. Lets highlights roll off softly.
static inline float3 dsTonemap(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}
/// Darken the corners: multiply your colour by this (amount 0…1).
static inline float dsVignette(float2 uv, float amount) {
    float2 q = uv - 0.5;
    return 1.0 - amount * smoothstep(0.25, 0.85, dot(q, q) * 2.0);
}
/// Fine film grain, ±amount, changing every frame.
static inline float dsGrain(float2 uv, DSContext ctx, float amount) {
    return (dsHash(float3(uv * ctx.res, floor(ctx.t * 24.0))) - 0.5) * amount;
}

// ================================================================================ sky
/// A simple daylight-aware sky for a view direction `dir` (y up), lit by the real sun (ctx.sun):
/// blue by day, warm near the horizon at sunrise/sunset, deep blue-black at night, with a sun disc
/// and glow. LINEAR colour. Pass a fixed elevation/azimuth instead with dsSkyAt.
static inline float3 dsSkyAt(float3 dir, float sunElevationDeg, float sunAzimuthDeg) {
    float el = sunElevationDeg * DS_PI / 180.0, az = sunAzimuthDeg * DS_PI / 180.0;
    // x = east, z = north
    float3 sd = normalize(float3(sin(az) * cos(el), sin(el), cos(az) * cos(el)));
    float day = smoothstep(-0.12, 0.10, sd.y);          // 0 night … 1 day
    float dusk = exp(-abs(sd.y) * 9.0);                  // the golden hour
    float h = max(dir.y, 0.0);
    float3 zenith = mix(float3(0.004, 0.006, 0.018), float3(0.10, 0.28, 0.75), day);
    float3 horizon = mix(float3(0.010, 0.014, 0.030), float3(0.55, 0.70, 0.90), day);
    horizon = mix(horizon, float3(1.0, 0.45, 0.18), dusk * 0.85);
    float3 sky = mix(horizon, zenith, pow(h, 0.45));
    float mu = saturate(dot(normalize(dir), sd));
    sky += float3(1.0, 0.75, 0.45) * pow(mu, 8.0) * (0.25 + 0.6 * dusk) * smoothstep(-0.2, 0.02, sd.y);
    sky += float3(1.0, 0.92, 0.8) * smoothstep(0.9993, 0.9997, mu) * 6.0 * smoothstep(-0.05, 0.02, sd.y);
    return sky;
}
static inline float3 dsSky(float3 dir, DSContext ctx) { return dsSkyAt(dir, ctx.sun.elevation, ctx.sun.azimuth); }
/// The sky behind a flat 2D scene: uv.y = 0 at the horizon … 1 at the top, looking toward the sun.
static inline float3 dsSky2D(float2 uv, DSContext ctx) {
    float3 dir = normalize(float3((uv.x - 0.5) * 1.2, max(uv.y, 0.0) * 0.9 + 0.001, 1.0));
    return dsSkyAt(dir, ctx.sun.elevation, 0.0);
}

#endif
