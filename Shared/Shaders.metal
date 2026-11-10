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
// Other units re-include this file for its helpers and scene code, with its entry points compiled
// out: Shared/Weather/Weather.metal, Shared/SceneEntries.metal.
#if defined(DOTSTUDIO_WEATHER_UNIT) || defined(DOTSTUDIO_SCENE_UNIT)
#define DOTSTUDIO_HELPERS_ONLY 1
#endif

#ifndef DOTSTUDIO_HELPERS_ONLY
vertex VOut fx_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv  = float2(p.x, 1.0 - p.y);   // flip Y so textures are top-left origin
    return o;
}
#endif

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


// 3D value noise + fbm (for the black-hole accretion disk & nebula).
static inline float hash31(float3 p) {
    return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453);
}
static inline float noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = hash31(i),               b = hash31(i + float3(1, 0, 0));
    float c = hash31(i + float3(0, 1, 0)), d = hash31(i + float3(1, 1, 0));
    float e = hash31(i + float3(0, 0, 1)), f2 = hash31(i + float3(1, 0, 1));
    float g = hash31(i + float3(0, 1, 1)), h = hash31(i + float3(1, 1, 1));
    return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
               mix(mix(e, f2, u.x), mix(g, h, u.x), u.y), u.z);
}
static inline float fbm3(float3 p, float lac, float pers) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 4; ++i) { v += noise3(p) * amp; p *= lac; amp *= pers; }
    return v;
}
static inline float3 blackbody(float tempK) {
    float t = clamp((tempK - 1000.0) / 9000.0, 0.0, 1.0);
    float red = clamp(1.0 - (t - 0.8) * 2.0, 0.5, 1.0);
    float green = smoothstep(0.0, 0.5, t) * (1.0 - max((t - 0.7) * 0.3, 0.0));
    float blue = smoothstep(0.3, 1.0, t) * t;
    return float3(red, green, blue);
}
static inline float3 aces(float3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// ---- Oklab: perceptual color mixing for gradients/palettes (inputs are display sRGB).
static inline float3 srgbToLinear(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}
static inline float3 linearToSrgb(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}
static inline float3 srgbToOklab(float3 s) {
    float3 c = srgbToLinear(s);
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float q = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    l = pow(max(l, 0.0), 1.0 / 3.0); m = pow(max(m, 0.0), 1.0 / 3.0); q = pow(max(q, 0.0), 1.0 / 3.0);
    return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * q,
                  1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * q,
                  0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * q);
}
static inline float3 oklabToSrgb(float3 c) {
    float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float q = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    l = l * l * l; m = m * m * m; q = q * q * q;
    return linearToSrgb(float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * q,
                               -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * q,
                               -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * q));
}
// Rotate an Oklab color's hue by `a` radians (keeps lightness and chroma).
static inline float3 oklabHue(float3 c, float a) {
    float cs = cos(a), sn = sin(a);
    return float3(c.x, cs * c.y - sn * c.z, sn * c.y + cs * c.z);
}
// PCG3D integer hash → three uniform floats in [0,1). No lattice artifacts, unlike
// the fract-based hash21, so it's the one to use for per-pixel grain/dither.
static inline float3 pcg3(float3 pf) {
    uint3 v = uint3(int3(floor(pf)) + int3(1 << 20));
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return float3(v) * (1.0 / 4294967296.0);
}
// Film grain: triangular-distributed, animated at 24 fps, in [-1, 1].
static inline float filmGrain(float2 px, float t) {
    float3 h = pcg3(float3(px, floor(t * 24.0)));
    return h.x + h.y - 1.0;
}
// Film grain sized to the frame: clumps ~1.2 px wide per 1000 px of height (per-pixel grain
// vanishes at 5K and looks coarse and digital in a thumbnail), animated at 24 fps, with about
// filmGrain's spread. Two rotated layers of smoothly interpolated cell noise: no lattice.
static inline float grainK(float2 px, float t, float k) {
    float g = 1.2 * k;
    if (g < 1.3) return filmGrain(px, t);     // ~1 px clumps: per-pixel noise is the right size
    float fr = floor(t * 24.0);
    float2 q = px / g;
    float n = 0.0;
    for (int l = 0; l < 2; ++l) {
        float2 ql = (l == 0) ? q : float2(q.x * 0.8 - q.y * 0.6, q.x * 0.6 + q.y * 0.8) * 1.37 + 7.3;
        float2 i = floor(ql), f = ql - i;
        float2 w = f * f * (3.0 - 2.0 * f);
        float z = fr + float(l) * 977.0;
        float a = pcg3(float3(i, z)).x, b = pcg3(float3(i + float2(1, 0), z)).x;
        float c = pcg3(float3(i + float2(0, 1), z)).x, d = pcg3(float3(i + float2(1, 1), z)).x;
        n += mix(mix(a, b, w.x), mix(c, d, w.x), w.y) - 0.5;
    }
    return n * 1.6;
}
// Tiny static dither (±0.5 LSB-ish) to break 8-bit banding in smooth dark gradients.
static inline float bandDither(float2 px) {
    float3 h = pcg3(float3(px, 7.0));
    return (h.x + h.y - 1.0) / 255.0;
}
// Gradient (Perlin-style) noise in ~[-0.7, 0.7]: smooth, isotropic contours
// (value noise contours look boxy).
static inline float2 ghash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}
static inline float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(ghash(i), f);
    float b = dot(ghash(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(ghash(i + float2(0, 1)), f - float2(0, 1));
    float d = dot(ghash(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static inline float gfbm(float2 p, int oct) {
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    float a = 0.5, s = 0.0;
    for (int i = 0; i < oct; ++i) { s += a * gnoise(p); p = R * p * 2.03; a *= 0.5; }
    return s;
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

// ---------------------------------------------------------------- Starfield (37)
// A flight through a uniform 3D star field. Stars live on depth layers; a star on the layer
// at depth z with pattern coordinates (θ, q = ln(r·z)) shows at screen radius r = e^q / z, so
// flying forward just slides each layer's pattern outward along ln r and every motion-blur
// streak is exactly radial. Cells are angular sectors × q-steps; the sector count doubles
// every octave of q, so a cell is never narrower than a star's footprint wherever it can
// show (no clipped stars, no hole at the vanishing point), and stars are accepted and placed
// ∝ e^{2q}, which keeps their on-screen density uniform. Each star is an energy-conserving
// Gaussian swept along its streak (erf ends): long streaks are dimmer per pixel, exactly
// as a camera's shutter would record them.

// Standard normal CDF (erf via the Winitzki approximation, |error| < 2e-3).
static inline float sf_ncdf(float x) {
    float a2 = x * x * 0.5;
    float e = sqrt(max(1.0 - exp(-a2 * (1.2732395 + 0.147 * a2) / (1.0 + 0.147 * a2)), 0.0));
    return 0.5 + 0.5 * (x < 0.0 ? -e : e);
}
// One star of cell `cell` (j-th of the cell via jq), accepted with probability pj: its
// energy-conserving Gaussian streak at this pixel (screen polar rpx, thp), × over.
static inline float3 sf_star(float cell, float jq, float seed, float pj, float M, float thp, float rpx,
                             float sig, float eq0, float pxs, float z, float vz, float flux, float over) {
    float3 h = pcg3(float3(cell, jq, seed));
    if (h.x >= pj) return float3(0.0);
    float ths = (cell + 0.15 + 0.7 * h.y) * 6.2831853 / M - 3.14159265;
    float dth = thp - ths;
    dth -= 6.2831853 * floor(dth * 0.15915494 + 0.5);
    float perp = rpx * dth;                   // (the angle is tiny wherever it counts)
    if (abs(perp) > 3.7 * sig) return float3(0.0);
    float g = exp(-perp * perp / (2.0 * sig * sig));
    float rs = eq0 * sqrt(1.0 + h.z) * pxs;   // ∝ e^{2q} inside the cell
    float rh = rs / z, rt = rs / (z + vz);
    float ell = rh - rt;
    float along = rh - rpx * (1.0 - 0.5 * dth * dth);
    float a = ell > 0.02 * sig
            ? (sf_ncdf(along / sig) - sf_ncdf((along - ell) / sig)) * 2.5066283 * sig / ell
            : exp(-along * along / (2.0 * sig * sig));
    float3 h2 = pcg3(float3(cell + 9137.0, jq, seed + 3.0));
    float L2 = h2.x * h2.x * h2.x;
    float L = (0.03 + 0.10 * h2.x + 1.4 * L2 * L2) * over;
    float3 tint = mix(float3(0.82, 0.90, 1.10), float3(1.10, 0.96, 0.82), h2.y);
    return tint * (L * flux * g * a);
}

// ---------------------------------------------------------------- Black Hole (40)
// Light around a Schwarzschild black hole, followed along its true null geodesics: with
// h = |x × v| conserved, x'' = −(3/2)·rs·h²·x/|x|⁵ in flat Cartesian coordinates bends
// light exactly as GR does, so the shadow (impact parameter √27/2·rs), the far side of the
// disk lensed over and under the hole, the thin photon ring and the warped sky behind all
// come out of one integrator. The disk is thin and Novikov–Thorne-like (T ∝ r^−¾ with a
// soft inner edge); each crossing is seen at g·T, g = Doppler × gravitational redshift,
// and a black body at g·T is exactly what reaches the camera — so the approaching side's
// beaming (brighter, bluer) needs no fudge.

// Linear-RGB radiance of a black body at T kelvin (at ~610/550/465 nm), relative to a
// 6500 K body (= 1, 1, 1).
static inline float3 bh_planck(float T) {
    float3 x = min(14388.0 / (float3(0.610, 0.550, 0.465) * max(T, 600.0)), 80.0);
    return float3(36.665764, 54.958782, 115.780694) / (exp(x) - 1.0);
}
// Value noise on an integer-hashed 3D lattice (no sin: stable and cheap).
static inline float bh_vn3(float3 p) {
    float3 i = floor(p), f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    uint3 c = uint3(int3(i) + int3(1 << 16));
    uint bx = c.x * 0x8da6b343u, by = c.y * 0xd8163841u, bz = c.z * 0xcb1ab31fu;
    const uint X1 = 0x8da6b343u, Y1 = 0xd8163841u, Z1 = 0xcb1ab31fu;
    #define BH_H(h) (float(((h) ^ ((h) >> 15u)) * 0x2c1b3c6du >> 8u) * (1.0 / 16777216.0))
    float a = BH_H(bx ^ by ^ bz),               b = BH_H((bx + X1) ^ by ^ bz);
    float cc = BH_H(bx ^ (by + Y1) ^ bz),       d = BH_H((bx + X1) ^ (by + Y1) ^ bz);
    float e = BH_H(bx ^ by ^ (bz + Z1)),        g = BH_H((bx + X1) ^ by ^ (bz + Z1));
    float h = BH_H(bx ^ (by + Y1) ^ (bz + Z1)), k = BH_H((bx + X1) ^ (by + Y1) ^ (bz + Z1));
    #undef BH_H
    return mix(mix(mix(a, b, f.x), mix(cc, d, f.x), f.y), mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}
// Gas density at disk radius r, angle a (already advected): filaments sheared along the
// orbit (log-radial so they thin toward the hole), octaves faded by the pixel's footprint
// fr (radius units) so the compressed inner images never alias.
static inline float bh_gas(float r, float a, float fr) {
    float3 p = float3(cos(a) * 1.5, sin(a) * 1.5, log(r) * 10.0);
    float lod = fr * 10.0 / r;                       // noise units per pixel, radially
    float v = 0.0, amp = 0.5, wsum = 0.0;
    for (int o = 0; o < 4; ++o) {
        float k = 1.0 - smoothstep(0.25, 0.6, lod);
        v += (bh_vn3(p) - 0.5) * amp * k;
        wsum += amp;
        p = p * float3(2.0, 2.0, 2.3) + float3(3.1, 1.7, 5.3);
        amp *= 0.55; lod *= 2.3;
    }
    return 0.5 + v / wsum * 2.0;
}
// Emission (rgb) and opacity (a) of one disk crossing H = (r, φ, g).
static inline float4 bh_disk(float3 H, float fr, float ts, float rin, float rout, float rot, float T0) {
    float r = H.x;
    if (r <= 0.0) return float4(0.0);
    float nr = (r - rin) / (rout - rin);
    float edge = smoothstep(-0.04, 0.06, nr) * smoothstep(1.0, 0.45, nr);
    if (edge <= 0.0) return float4(0.0);
    float q = rin / max(r, rin * 0.96);
    float f = pow(q, 0.75) * pow(max(1.0 - sqrt(q), 0.004), 0.25) * 2.0497;   // = 1 at r = 1.36 rin
    f = max(f, 0.75 * smoothstep(-0.04, 0.03, nr));                            // the hot inner rim
    // Keplerian flow, two phases cross-faded so the shear never winds up.
    float Om = rot * pow(r, -1.5);
    const float P = 9.0;
    float c = fmod(ts, P), w = c / P;
    float n = mix(bh_gas(r, H.y - Om * (c + P), fr), bh_gas(r, H.y - Om * c, fr), w);
    n = mix(n, 0.5, 0.5 * w * (1.0 - w));                  // (the cross-fade dims contrast a little; even it out)
    float tau = edge * (0.5 + 4.0 * max(n, 0.0) * max(n, 0.0));
    float alpha = 1.0 - exp(-tau);
    // Colour from the black body at the observed temperature; brightness ∝ (f·g)³ — the
    // bolometric g⁴ tempered — so the receding side dims without vanishing.
    float Tobs = T0 * f * H.z;
    float3 B = bh_planck(Tobs);
    B /= max(dot(B, float3(0.2126, 0.7152, 0.0722)), 1e-6);
    float I = f * H.z;
    return float4(B * (I * I * I) * alpha * (0.25 + 0.75 * smoothstep(0.15, 0.95, n)), alpha);
}
// Total bending of a ray that never comes near the disk, from the camera (distance D) out to
// the sky, for the same orbit equation the march integrates (u'' + u = 3/2·rs·u², with the
// march's energy 1/b² − rs/D³). The swept angle is ∫du/√(…) on both legs; with u = u0(1−t²)
// the integrand is 2√u0/√g(t), smooth, so a 4-point Gauss rule is exact to ~0.1 mrad — the
// marched and analytic skies meet without a seam.
static inline float bh_weakBend(float b, float rs, float D) {
    float C = 1.0 / (b * b) - rs / (D * D * D);
    float u0 = 1.0 / b;
    for (int i = 0; i < 3; ++i)
        u0 -= (C - u0 * u0 + rs * u0 * u0 * u0) / (-2.0 * u0 + 3.0 * rs * u0 * u0);
    float tc = sqrt(max(1.0 - 1.0 / (D * u0), 0.0));
    const float4 gx = float4(0.06943184, 0.33000948, 0.66999052, 0.93056816);
    const float4 gw = float4(0.17392742, 0.32607258, 0.32607258, 0.17392742);
    float s = 0.0;
    for (int k = 0; k < 2; ++k) {
        float4 tt = gx * (k == 0 ? 1.0 : tc);
        float4 uu = u0 * (1.0 - tt * tt);
        float4 g = (u0 + uu) - rs * (u0 * u0 + u0 * uu + uu * uu);
        s += dot(gw, rsqrt(max(g, 1e-12))) * (k == 0 ? 1.0 : tc);
    }
    return 2.0 * sqrt(u0) * s - (3.14159265 - asin(min(b / D, 1.0)));
}
// The rest of the bending after the march stops at radius ~1.5 D (first order, straight
// line from the exit point to infinity), so marched rays land on the same sky.
static inline float3 bh_bendTail(float3 x, float3 d, float rs) {
    float s0 = dot(x, d);
    float3 cp = x - d * s0;
    float be = max(length(cp), 1e-4);
    float q = s0 * (2.0 * s0 * s0 + 3.0 * be * be) * pow(s0 * s0 + be * be, -1.5);
    float al = rs / (2.0 * be) * (2.0 - q);
    return d * cos(al) - (cp / be) * sin(al);
}
// One ray from the camera: up to three disk crossings (r, φ, g, weight) and the direction it
// leaves along. Drift-kick-drift with a step ∝ r; outbound crossings (past periapsis) are the
// lensed images and carry the coverage weight wRing (see case 40).
struct BHRay { float4 H0, H1, H2; float3 v; };
static inline BHRay bh_march(float3 ro, float3 rd, float b, float rs, float rin, float rout,
                             float D, float sgn, float wRing) {
    BHRay R;
    R.H0 = float4(0.0); R.H1 = float4(0.0); R.H2 = float4(0.0);
    float3 x = ro, v = rd;
    float h2 = b * b;
    int nh = 0;
    if (b > rout + 3.0 * rs) {
        // Never reaches the disk: the same bending, integrated in closed form.
        float3 cp = ro - rd * dot(ro, rd);
        float al = bh_weakBend(b, rs, D);
        R.v = rd * cos(al) - normalize(cp) * sin(al);
        return R;
    }
    for (int i = 0; i < 120; ++i) {
        float r = length(x);
        if (r < rs || (r > D * 1.5 && dot(x, v) > 0.0)) break;
        float dt = clamp(0.115 * r, 0.02, 3.0);   // 2nd order: as accurate as 0.04·r kick-drift
        float3 xm = x + v * (0.5 * dt);
        float rm2 = dot(xm, xm);
        v -= (1.5 * rs * h2 * dt * rsqrt(rm2) / (rm2 * rm2)) * xm;
        float3 xn = xm + v * (0.5 * dt);
        if (x.y * xn.y < 0.0 && nh < 3) {
            float3 hp = mix(x, xn, x.y / (x.y - xn.y));
            float hr = length(hp.xz);
            if (hr > rin * 0.9 && hr < rout) {
                float phi = atan2(hp.z, hp.x);
                float beta = min(sqrt(rs / (2.0 * max(hr - rs, 0.5 * rs))), 0.7);
                float3 vdir = float3(-sin(phi), 0.0, cos(phi)) * sgn;
                float g = sqrt(max(1.0 - rs / hr, 0.02)) * sqrt(1.0 - beta * beta)
                        / (1.0 + beta * dot(vdir, normalize(v)));   // photon leaves along −v
                g = pow(g, 0.6);                    // beaming tempered: still clearly lopsided
                float4 H = float4(hr, phi, g, dot(hp, v) > 0.0 ? wRing : 1.0);
                if (nh == 0) R.H0 = H; else if (nh == 1) R.H1 = H; else R.H2 = H;
                ++nh;
            }
        }
        x = xn;
    }
    R.v = dot(x, x) > D * D ? bh_bendTail(x, normalize(v), rs) : v;
    return R;
}
// Point stars + a faint galactic band on the sky, for a ray leaving along d. Lensing maps
// image pixels to the sky through the Jacobian whose inverse is Ji (sky offset in the
// tangent frame e1, e2 → image pixels): each star is splatted as a round ~1 px point in the
// IMAGE, so magnified stars stay points (not smeared arcs) and get brighter by the
// magnification mu, while the compressed sky at the photon ring fades as it should.
static inline float3 bh_sky(float3 d, float3 e1, float3 e2, float2x2 Ji, float mu, float amt) {
    float3 acc = float3(0.0);
    float az = atan2(d.x, d.z);
    for (int L = 0; L < 2; ++L) {
        float sc = L == 0 ? 90.0 : 240.0;
        float2 g = float2(az, d.y) * sc;
        float2 cell = floor(g);
        float3 h = pcg3(float3(cell, 11.0 + float(L) * 17.0));
        if (h.z < (L == 0 ? 0.80 : 0.86)) continue;
        float2 sg = (cell + 0.2 + 0.6 * h.xy) / sc;                         // the star's (az, y)
        float cs = sqrt(max(1.0 - sg.y * sg.y, 0.0));
        float3 s = float3(sin(sg.x) * cs, sg.y, cos(sg.x) * cs);
        float3 ds = s - d;
        float2 o = Ji * float2(dot(ds, e1), dot(ds, e2));                  // pixels in the image
        float rr = dot(o, o);
        if (rr > 12.0) continue;
        float3 h2 = pcg3(float3(cell + 401.0, 5.0 + float(L)));
        float b = L == 0 ? 0.03 + 0.9 * pow(h2.x, 7.0) : 0.012 + 0.05 * h2.x * h2.x;
        float3 tint = mix(float3(0.70, 0.80, 1.0), float3(1.0, 0.82, 0.62), h2.y);
        acc += tint * b * exp(-rr / 1.3);
    }
    acc *= amt * mu;
    // Galactic band, tilted across the view, lensed with everything else.
    float3 gN = normalize(float3(0.25, 0.92, 0.30));
    float gl = dot(d, gN);
    float band = exp(-gl * gl * 22.0);
    if (band > 0.01) {
        float3 p = d * 6.0;
        float n = bh_vn3(p) * 0.6 + bh_vn3(p * 2.7 + 4.1) * 0.4;
        float dust = smoothstep(0.02, 0.09, abs(gl + 0.05 * (n - 0.5)));
        acc += mix(float3(0.30, 0.36, 0.55), float3(0.62, 0.50, 0.40), n) * band * (0.4 + 0.8 * n) * mix(0.3, 1.0, dust) * 0.035 * min(amt, 1.5);
    }
    return acc;
}

// ---------------------------------------------------------------- Universe (3D solar system)
// World space: the Sun sits at the origin, the ecliptic is the y = 0 plane, +y is
// ecliptic north. Body 0 = Sun, 1…8 = Mercury…Neptune, 9 = the Moon.
// Sizes and spacing are artistic (a true-scale system is invisible dots).

constant float  UNI_ORB[9]   = {0.0, 1.55, 2.15, 2.85, 3.5, 4.9, 6.05, 7.15, 8.1};
constant float  UNI_RAD[10]  = {0.46, 0.10, 0.18, 0.19, 0.14, 0.42, 0.35, 0.25, 0.24, 0.05};
constant float  UNI_OSPD[9]  = {0.0, 1.60, 1.18, 1.00, 0.81, 0.44, 0.32, 0.23, 0.18};
constant float  UNI_SPIN[10] = {0.0, 0.05, -0.03, 0.0, 0.25, 0.60, 0.55, -0.40, 0.40, 0.0};
constant int    UNI_LAYER[10] = {-2, 0, 1, -1, 2, 3, 4, 5, 6, 7};   // planetTex layer, −1 Earth, −2 Sun
constant float3 UNI_TINT[10] = {float3(1.0, 0.7, 0.35),
    float3(0.6, 0.6, 0.62), float3(0.85, 0.75, 0.5), float3(0.25, 0.5, 0.9), float3(0.85, 0.42, 0.25),
    float3(0.85, 0.68, 0.48), float3(0.88, 0.78, 0.55), float3(0.6, 0.85, 0.9), float3(0.4, 0.5, 0.92),
    float3(0.6, 0.6, 0.6)};
constant float  UNI_MOON_ORB = 0.40;
constant float  UNI_RING_IN = 1.24, UNI_RING_OUT = 2.27;   // Saturn's rings, in Saturn radii

// Orbital angle (prograde = counter-clockwise seen from +y). `ta` is the orbital clock.
static inline float uniAngle(int i, float ta) {
    return ta * UNI_OSPD[i] + hash21(float2(float(i - 1), 7.0)) * 6.2831853;
}
static inline float3 uniOrbitPos(int i, float ta) {
    float a = uniAngle(i, ta);
    return float3(cos(a), 0.0, -sin(a)) * UNI_ORB[i];
}
static inline float3 uniBodyPos(int i, float ta) {
    if (i == 0) return float3(0.0);
    if (i == 9) {                                            // the Moon, slightly inclined orbit
        float a = ta * 6.0 + 1.3;
        return uniOrbitPos(3, ta) + float3(cos(a), 0.16 * sin(a), -sin(a)) * UNI_MOON_ORB;
    }
    return uniOrbitPos(i, ta);
}

// Ray vs sphere with an analytic ~1 px edge: returns (t, coverage); coverage 0 = miss.
static inline float2 uniSphere(float3 ro, float3 rd, float3 c, float r, float pix) {
    float3 oc = ro - c;
    float b = dot(oc, rd);
    if (b > 0.0) return float2(0.0);                         // behind the camera
    float d2 = max(dot(oc, oc) - b * b, 0.0);
    float tca = -b;
    float cov = clamp((r - sqrt(d2)) / (tca * pix) + 0.5, 0.0, 1.0);
    float h = r * r - d2;
    return float2(h > 0.0 ? tca - sqrt(h) : tca, cov);
}

// Saturn's ring opacity at rr (in Saturn radii): banded, with the Cassini division.
static inline float uniRingAlpha(float rr, float aa) {
    float edge = smoothstep(UNI_RING_IN - aa, UNI_RING_IN + aa, rr) * smoothstep(UNI_RING_OUT + aa, UNI_RING_OUT - aa, rr);
    float bands = 0.45 + 0.55 * vnoise(float2(rr * 22.0, 3.7));
    bands *= mix(0.55, 1.0, smoothstep(1.3, 1.55, rr));                 // faint inner C ring
    float cassini = 1.0 - 0.85 * smoothstep(1.93 - aa, 1.95, rr) * smoothstep(2.01 + aa, 1.99, rr);
    return edge * bands * cassini * 0.88;
}

// One shell of point stars. q = the ray's point on a sphere of radius R about the Sun,
// k = cells per world unit. A star is kept only when its own spot on the shell falls in
// the sampled cell, so stars are never cut in half by the cell grid.
static inline float3 uniStars(float3 q, float R, float k, float3 eye, float3 rd, float pix,
                              float seed, float density, float sizeK) {
    float3 cell = floor(q * k);
    float3 h2 = pcg3(cell + seed + 31.0);
    if (h2.x > density) return float3(0.0);
    float3 h = pcg3(cell + seed);
    float3 s = R * normalize((cell + 0.15 + 0.7 * h) / k);
    if (any(floor(s * k) != cell)) return float3(0.0);
    float ang = length(normalize(s - eye) - rd);              // ≈ angle in radians
    float big = h2.y * h2.y * h2.y * h2.y;
    float sz = (1.06 + 0.5 * big) * sizeK * pix;              // σ ≥ 0.75 px: no shimmer as the camera turns
    float I = exp(-ang * ang / (sz * sz)) * (0.2 + 0.7 * h2.z) * (0.6 + 1.6 * big);
    return mix(float3(0.70, 0.80, 1.0), float3(1.0, 0.86, 0.68), h.z) * I;
}

// Additive layers (glow, plane) whose depth falls in (lo, hi].
static inline float3 uniAddIn(float3 g, float dg, float3 p, float dp, float lo, float hi) {
    return (dg > lo && dg <= hi ? g : float3(0.0)) + (dp > lo && dp <= hi ? p : float3(0.0));
}

static inline float2 uniUV(float3 n, float3 E, float3 N, float3 M, float lon0) {
    float lat = asin(clamp(dot(n, N), -1.0, 1.0));
    float lon = lon0 + atan2(dot(n, E), dot(n, M));
    return float2(fract(lon * 0.1591549 + 0.5), 0.5 - lat * 0.3183099);
}

// Shade body i (centre c) at surface normal n0, lit by the Sun at the origin.
// fp = pixel footprint in body radii (drives a 4-tap texture supersample, since the
// planet maps have no mips). (eE, eN, eM, subLon) orient the Earth so its day/night
// matches the wall clock.
static inline float3 uniShade(int i, float3 c, float3 n0, float3 rd, float fp, float3 camR, float3 camU,
                              float ts, float t, float3 eE, float3 eN, float3 eM, float subLon, float4 p2,
                              float3 moonM, float3 ringN,
                              texture2d<float> earthDay, texture2d<float> earthNight,
                              texture2d_array<float> planetTex, sampler samp, bool haveTex) {
    float mu = clamp(dot(n0, -rd), 0.0, 1.0);
    if (i == 0) {                                                // the Sun: emissive, granulated, limb-darkened
        float s = ts * 0.02, cs = cos(s), sn = sin(s);
        float3 nr = float3(cs * n0.x - sn * n0.z, n0.y, sn * n0.x + cs * n0.z);
        // Granulation: fine cells, octaves faded by the pixel's footprint (fp, in solar radii)
        // so the disc never sparkles; faint large-scale mottling under it.
        float3 p = nr * 34.0 + float3(0.0, ts * 0.02, 0.0);
        float lod = fp * 34.0, g = 0.0, a = 0.5, wsum = 0.0;
        for (int o = 0; o < 3; ++o) {
            g += (bh_vn3(p) - 0.5) * a * (1.0 - smoothstep(0.3, 0.7, lod));
            wsum += a; p = p * 2.13 + 1.7; a *= 0.5; lod *= 2.13;
        }
        g /= wsum;
        float big = bh_vn3(nr * 3.2 + float3(7.0, ts * 0.004, 0.0)) - 0.5;
        // Limb darkening, stronger toward blue (the limb is cooler: darker and redder).
        float3 I = 1.0 - float3(0.48, 0.62, 0.80) * (1.0 - mu);
        return float3(1.0, 0.90, 0.74) * I * (1.32 + 0.34 * g + 0.10 * big);
    }
    float3 E, N = float3(0.0, 1.0, 0.0), M; float lon0 = 0.0;
    if (i == 3)      { E = eE; N = eN; M = eM; lon0 = subLon; }
    else if (i == 9) { M = moonM; E = cross(N, M); }             // tidally locked: near side faces Earth
    else { float s = ts * UNI_SPIN[i]; M = float3(sin(s), 0.0, cos(s)); E = float3(cos(s), 0.0, -sin(s)); }

    const float2 o[4] = {float2(-0.125, -0.375), float2(0.375, -0.125), float2(0.125, 0.375), float2(-0.375, 0.125)};
    float3 base = float3(0.0), night = float3(0.0);
    int layer = UNI_LAYER[i];
    for (int k = 0; k < 4; ++k) {
        float3 n = normalize(n0 + (camR * o[k].x + camU * o[k].y) * fp);
        float2 tuv = uniUV(n, E, N, M, lon0);
        if (!haveTex) { base += UNI_TINT[i]; continue; }
        if (layer < 0) { base += earthDay.sample(samp, tuv).rgb; night += earthNight.sample(samp, tuv).rgb; }
        else           { base += planetTex.sample(samp, tuv, layer).rgb; }
    }
    base *= 0.25; night *= 0.25;

    float3 L = normalize(-c);
    float ndl = dot(n0, L);
    float lit = smoothstep(-0.10, 1.0, ndl);
    float3 col = base * (lit * 1.25 + 0.03 + 0.06 * mu);          // + faint camera-side fill on the night side

    if (i == 3) {                                                // city lights + location marker
        float day = smoothstep(-0.15, 0.15, ndl);
        col += night * (1.0 - day) * float3(1.0, 0.82, 0.6) * 1.3;
        if (p2.z > 0.5) {
            float lat = asin(clamp(dot(n0, N), -1.0, 1.0));
            float lon = lon0 + atan2(dot(n0, E), dot(n0, M));
            float dlon = atan2(sin(lon - p2.x), cos(lon - p2.x));
            float md = length(float2(dlon * cos(p2.y), lat - p2.y));
            float pulse = 0.5 + 0.5 * sin(t * 3.0);
            col = mix(col, float3(0.3, 1.0, 0.45), smoothstep(0.22, 0.0, md) * (0.55 + 0.45 * pulse) * step(0.05, mu));
        }
    }
    if (i == 6) {                                                // the rings' shadow on Saturn
        float3 P = c + n0 * UNI_RAD[6];
        float dl = dot(L, ringN);
        float s = dot(c - P, ringN) / (abs(dl) < 1e-4 ? 1e-4 : dl);
        if (s > 0.0) col *= 1.0 - 0.7 * uniRingAlpha(length(P + L * s - c) / UNI_RAD[6], 0.02);
    }
    // atmosphere: a thin rim on the lit side
    float3 atm = (i == 3) ? float3(0.35, 0.62, 1.0) * 0.9
               : (i == 2) ? float3(1.0, 0.85, 0.6) * 0.45
               : (i >= 5 && i <= 8) ? UNI_TINT[i] * 0.35 : float3(0.0);
    float rim = 1.0 - mu; rim *= rim * rim;
    col += atm * rim * smoothstep(-0.25, 0.45, ndl);
    col += float3(0.30, 0.40, 0.60) * rim * rim * 0.10;          // faint cool backlight keeps dark limbs round
    return col;
}

// ---------------------------------------------------------------- scene packs (helpers)
#include "Scenes/Clocks_funcs.h"
#include "Scenes/Flowing_funcs.h"
#include "Scenes/Nature_funcs.h"
#include "Scenes/Retro_funcs.h"
#include "Scenes/Music_funcs.h"
#include "Scenes/Studio1_funcs.h"
#include "Scenes/Studio2_funcs.h"
#include "Scenes/Studio3_funcs.h"
#include "Scenes/Studio4_funcs.h"
#include "Scenes/Studio5_funcs.h"
#include "Scenes/Studio6_funcs.h"

// ---------------------------------------------------------------- slideshow source

// Cover-fit a photo, then zoom (kb.x ≥ 1) and pan (kb.yz in −1…1 of the travel the
// zoom leaves free), so the frame never shows past the photo's edge.
static inline float3 kenBurnsSample(texture2d<float> tex, sampler s, float2 uv, float outA,
                                    float2 size, float4 kb) {
    float srcA = size.x / max(size.y, 1.0);
    float2 cover = (srcA > outA) ? float2(outA / srcA, 1.0) : float2(1.0, srcA / outA);
    float2 span = cover / max(kb.x, 1.0);
    float2 center = 0.5 + clamp(kb.yz, -1.0, 1.0) * 0.5 * (1.0 - span);
    return tex.sample(s, center + (uv - 0.5) * span).rgb;
}

// Risograph (47) FM screen: one screen cell of ink A (or B) — the cell's ink coverage from the
// two-ink separation of the source at its centre, against a dispersed per-cell threshold
// (interleaved gradient noise, lightly jittered: missing ink spreads out as fine specks).
static inline float risoDot(texture2d<float> src, sampler samp, float2 c, float cell, float2 res,
                            float3 kA, float3 kB, float a11, float a12, float a22, float det, bool inkB) {
    float3 D = 1.0 - src.sample(samp, (c + 0.5) * cell / res).rgb;
    float bA = dot(kA, D), bB = dot(kB, D);
    float cov = smoothstep(0.06, 0.94, (inkB ? a11 * bB - a12 * bA : a22 * bA - a12 * bB) / det);
    float th = inkB ? fract(ign(c + 31.0) + 0.5 + (pcg3(float3(c, 9.0)).x - 0.5) * 0.25)
                    : fract(ign(c) + 0.5 + (pcg3(float3(c, 3.0)).x - 0.5) * 0.25);
    return step(th, cov * 0.98);
}
// The same screen with rounded dots for cells ≥ 3 px: the 2×2 nearest cells' dots, smoothly
// interpolated and thresholded, so ink lands as soft blobs that merge like real ink instead
// of square pixels (smaller cells keep crisp whole-cell dots: detail first).
static inline float risoInk(texture2d<float> src, sampler samp, float2 p, float cell, float2 res,
                            float3 kA, float3 kB, float a11, float a12, float a22, float det, bool inkB) {
    if (cell < 3.0)
        return risoDot(src, samp, floor(p / cell), cell, res, kA, kB, a11, a12, a22, det, inkB);
    float2 g = p / cell - 0.5, i = floor(g), f = g - i;
    float2 w = f * f * (3.0 - 2.0 * f);
    float d00 = risoDot(src, samp, i, cell, res, kA, kB, a11, a12, a22, det, inkB);
    float d10 = risoDot(src, samp, i + float2(1, 0), cell, res, kA, kB, a11, a12, a22, det, inkB);
    float d01 = risoDot(src, samp, i + float2(0, 1), cell, res, kA, kB, a11, a12, a22, det, inkB);
    float d11 = risoDot(src, samp, i + float2(1, 1), cell, res, kA, kB, a11, a12, a22, det, inkB);
    float m = mix(mix(d00, d10, w.x), mix(d01, d11, w.x), w.y);
    float aa = clamp(fwidth(m), 0.02, 0.5);
    return smoothstep(0.5 - aa, 0.5 + aa, m);
}

// Glass (49) LIQUID: the surface of a slowly flowing sheet of hand-rolled glass, in
// units of one ripple. Warped sines for the broad swell + gradient noise for the
// irregular, hand-made unevenness.
static inline float liquidGlassHeight(float2 p, float ts) {
    float2 q = p + 0.55 * float2(sin(p.y * 0.61 + ts), cos(p.x * 0.53 - ts * 0.7));
    q += 0.30 * float2(sin(q.y * 1.31 - ts * 0.5), cos(q.x * 1.17 + ts * 0.6));
    float h = sin(q.x * 0.9 + q.y * 0.4) * cos(q.y * 0.8 - q.x * 0.3);
    return h + 0.45 * gnoise(q * 0.8 + float2(ts * 0.4, -ts * 0.3));
}

// ---- Liquid Chrome (45) -------------------------------------------------------------
// Surface: the original two-stage domain-warped swell (same sculptural forms), plus
// travelling fine ripples carried by the warp. Returns (h, dh/dx, dh/dy) with the
// gradient ANALYTIC (chain rule through both warps), so normals are exact at any
// resolution: no finite-difference smear, no stepping. Both warps have |Jacobian| > 0.5,
// so the surface never folds or pinches.
static inline float3 chrome_surface(float2 p, float ts, float ripple) {
    float s1 = p.y * 0.83 + ts, s2 = p.x * 0.71 - ts * 0.8;
    float2 q1 = p + 0.65 * float2(sin(s1), cos(s2));
    float a1 = 0.5395 * cos(s1), b1 = -0.4615 * sin(s2);        // dq1.x/dy, dq1.y/dx
    float t1 = q1.y * 1.7 - ts * 0.6, t2 = q1.x * 1.5 + ts * 0.7;
    float2 q = q1 + 0.35 * float2(sin(t1), cos(t2));
    float a2 = 0.595 * cos(t1), b2 = -0.525 * sin(t2);
    float A = q.x * 1.15 + ts * 0.6, B = q.y * 1.45 - ts * 0.5, C = (q.x + q.y) * 0.9 + ts * 0.9;
    float h = sin(A) * 0.5 + sin(B) * 0.4 + sin(C) * 0.3;
    float cC = 0.27 * cos(C);
    float2 g = float2(0.575 * cos(A) + cC, 0.58 * cos(B) + cC);
    // Fine ripples: three slow wave trains in warped space, so they follow the flow.
    // Swell-modulated so they gather on the broad crests instead of tiling evenly.
    float env = ripple * (0.65 + 0.35 * sin(h * 1.7 + ts * 0.4));
    const float2 d1 = float2(0.8, 0.6), d2 = float2(-0.447, 0.894), d3 = float2(0.958, -0.287);
    float w1 = dot(q, d1) * 3.3 - ts * 2.2;
    float w2 = dot(q, d2) * 4.6 + ts * 2.6;
    float w3 = dot(q, d3) * 6.1 - ts * 3.1;
    h += env * (0.090 * sin(w1) + 0.055 * sin(w2) + 0.034 * sin(w3));
    g += env * (0.297 * cos(w1) * d1 + 0.253 * cos(w2) * d2 + 0.2074 * cos(w3) * d3);
    // grad_p = J1^T J2^T grad_q, with J = [[1, a], [b, 1]]
    float2 g2 = float2(g.x + b2 * g.y, a2 * g.x + g.y);
    return float3(h, g2.x + b1 * g2.y, a1 * g2.x + g2.y);
}

// Reflected view ray off the height field with gradient g (camera looks slightly down).
static inline float3 chrome_reflect(float2 g) {
    float3 n = normalize(float3(-g.x * 0.8, g.y * 0.8, 1.0));
    return reflect(normalize(float3(0.0, 0.28, -1.0)), n);
}

// A softbox seen from the origin: c is its centre direction, R/U its axes, hsz its
// half-size (gnomonic, so it keeps a softbox's straight-ish frame). Emission is a hot
// diffusion-cloth core falling smoothly to a soft rounded frame (never a flat fill),
// and roughness/brushing widen that frame. Glints whose on-screen area is tiny (a small
// bump catching the light in a dark field) fade out instead of showing as specks.
// resY = render height, so the area test is resolution independent.
static inline float chrome_softbox(float3 r, float3 c, float3 R, float3 U, float2 hsz,
                                   float2 blur, float resY) {
    float facing = dot(r, c);
    float2 l = float2(dot(r, R), dot(r, U)) / max(facing, 0.08);
    float2 ln = l / hsz;                                     // -1..1 across the box
    float2 dx = dfdx(l), dy = dfdy(l);
    float pxw = (length(dx) + length(dy)) * 0.5 / min(hsz.x, hsz.y);   // box units per pixel
    float2 a = abs(ln);
    float e = pow(a.x * a.x * a.x * a.x + a.y * a.y * a.y * a.y + 1e-8, 0.25);  // rounded frame
    float edge = 0.22 + length(blur / hsz) + pxw;
    float body = 1.0 - smoothstep(1.0 - edge, 1.0 + edge * 0.35, e);
    float core = exp(-2.4 * dot(ln, ln));
    // on-screen area of the glint, in (screen height)^2
    float det = abs(dx.x * dy.y - dx.y * dy.x) * resY * resY;
    float area = 4.0 * hsz.x * hsz.y / max(det, 1e-7);
    float vis = smoothstep(0.0012, 0.004, area);
    return body * (0.28 + 0.72 * core) * vis * smoothstep(0.0, 0.25, facing);
}

// Procedural photo studio, in linear light (HDR). r = reflected direction (y up,
// +z = behind the camera). Bands in r.y read as horizon / strip light / black flag:
// the crisp light-and-dark contour lines that make chrome look like chrome.
static inline float3 chrome_env(float3 r, float3 B, float rough, float aniso, float resY,
                                 float gys) {
    float y = r.y;
    // Prefilter widths: pixel footprint (AA) combined with surface roughness; brushing
    // smears reflections along y (grain runs horizontally).
    float aay = fwidth(y) * 0.6;
    float by = rough * 0.09 + aniso * 0.22;
    float bx = rough * 0.09;
    float wy = sqrt(aay * aay + by * by) + 0.0015;
    float2 blur = float2(bx, by);

    // Near-stationary reflection (gys small: saddles, or a small ripple crest just
    // peeking over a threshold). The horizon there lifts and goes soft, so a crest that
    // barely clears it stays a faint swell instead of an isolated speck; the contour
    // lines (below) use a tighter test so they stay crisp everywhere but true saddles.
    float stillH = 1.0 - smoothstep(0.6, 2.6, gys);
    float sad = 1.0 - smoothstep(0.1, 0.8, gys);
    float sky = smoothstep(-wy + 0.02 * stillH, wy + 0.06 * stillH, y);
    float yu = max(y, 0.0), yd = max(-y, 0.0);
    // cyclorama: a hot horizon rolling off into a dim ceiling
    float3 up = B * (0.20 + 0.45 * exp(-yu * 1.8) + 0.9 * exp(-yu * 9.0))
                  * (1.0 - 0.55 * smoothstep(0.45, 1.0, yu));
    // floor: falls away to deep black, with a soft bounce under the horizon so the
    // dark faces still model their form
    float3 dn = B * (0.003 + 0.05 * exp(-yd * 3.5) + 0.07 * exp(-yd * 14.0));
    float3 c = mix(dn, up, sky);
    // Contour lines. A line is a band in r.y, so where the surface flattens toward a
    // saddle its on-screen width balloons and the level set crosses itself: a fat
    // X/Y junction. Capping the band at a screen width (half-width in r.y <= k * gys)
    // keeps the calligraphic thick-thin of the lines but no flaring, so at a saddle the
    // two branches stay slender smooth curves that kiss and fade at the crossing point.
    // strip light (the signature white contour)
    float sw = min(0.010, 0.0035 * gys);
    c += B * 5.0 * (1.0 - 0.6 * sad) * smoothstep(sw + wy, sw - wy, abs(y - 0.30));
    c += B * 0.16 * exp(-abs(y - 0.30) * 22.0);
    // black flag (the signature dark contour)
    float fw = min(0.019, 0.0065 * gys);
    float flag = smoothstep(fw + wy, fw - wy, abs(y - 0.56));
    c *= 1.0 - 0.96 * (1.0 - 0.6 * sad) * flag;

    // key softbox, upper left: the broad glints on the crests
    float3 kc = normalize(float3(-0.55, 0.45, 0.70));
    float3 kR = normalize(cross(float3(0, 1, 0), kc)), kU = cross(kc, kR);
    c += B * 1.7 * chrome_softbox(r, kc, kR, kU, float2(0.34, 0.20), blur, resY);
    return c;
}

// Metal reflectance: Schlick Fresnel on a bright chrome F0, optionally through a thin
// interference film (oil slick / anodised titanium). The film is spectral: eight
// wavelengths through the Airy reflectance of a film on metal, summed with CIE→sRGB
// weights, so colours progress like real interference orders (bronze, magenta, blue,
// gold, green…) and fade at higher orders instead of looping a rainbow.
static inline float3 chrome_reflectance(float cosI, float thicknessNm, float iris) {
    const float F0 = 0.66;
    float fr = pow(1.0 - cosI, 5.0);
    float3 metal = float3(F0 + (1.0 - F0) * fr);
    // perceptual: the shipped 0.12 already reads as a broad pearly wash
    float amt = pow(max(iris, 0.0), 0.3);
    if (amt <= 0.001) return metal;
    const float nf = 1.9, r1 = 0.50, r2 = 0.85;
    float sinT = sqrt(max(1.0 - cosI * cosI, 0.0)) / nf;
    float cosT = sqrt(max(1.0 - sinT * sinT, 0.0));
    float opd = 2.0 * nf * thicknessNm * cosT;
    const float4 cmf[8] = {
        float4(410.0,  0.0163, -0.0132,  0.0973), float4(450.0,  0.0539, -0.0766,  0.8467),
        float4(490.0, -0.1409,  0.1506,  0.2016), float4(530.0, -0.2591,  0.5745, -0.0547),
        float4(570.0,  0.3225,  0.4023, -0.0667), float4(610.0,  0.7637, -0.0117, -0.0207),
        float4(650.0,  0.2326, -0.0269, -0.0030), float4(690.0,  0.0109,  0.0010, -0.0005) };
    float3 film = 0.0;
    for (int i = 0; i < 8; ++i) {
        float cp = 2.0 * r1 * r2 * cos(6.2831853 * opd / cmf[i].x);
        float R = (r1 * r1 + r2 * r2 + cp) / (1.0 + r1 * r1 * r2 * r2 + cp);
        film += R * cmf[i].yzw;
    }
    film = max(film, 0.0);
    // keep chrome's brightness, take the film's hue; grazing angles still go white
    float fl = dot(film, float3(0.2126, 0.7152, 0.0722));
    // pastel pearl at low iridescence, richer holographic colour toward 1
    film = max(fl + (film - fl) * mix(1.0, 1.3, saturate(iris)), 0.0);
    film *= F0 / max(dot(film, float3(0.2126, 0.7152, 0.0722)), 0.05);
    // At equal luminance a yellow tint reads darker than its pink and blue neighbours
    // (they gain brightness from their colourfulness), so on the dim faces of a strongly
    // iridescent foil the yellow orders went khaki. Lift them into the pale gold a real
    // interference yellow shows.
    float yel = saturate((film.r + film.g) * 0.5 - film.b) / F0;
    film *= 1.0 + 1.2 * smoothstep(0.15, 0.6, iris) * yel;
    film = film + (1.0 - film) * fr;
    return mix(metal, film, amt);
}

// ---- Topography (44) ---------------------------------------------------------------
// gnoise / gfbm with their analytic gradients (identical values), so contour widths and
// hillshade come from the exact slope instead of 2×2-quad derivatives (which stair-step
// the line edges and facet the relief).
static inline float3 topo_gnoised(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = ghash(i), gb = ghash(i + float2(1, 0));
    float2 gc = ghash(i + float2(0, 1)), gd = ghash(i + float2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k = va - vb - vc + vd;
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    float2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
             + du * (float2(vb - va, vc - va) + u.yx * k);
    return float3(v, d);
}
// gs = the same gradient with the fine octaves rolled off: the broad landforms only, for
// relief shading that reads as terrain instead of crinkled foil when the map is downscaled.
static inline float3 topo_fbmd(float2 p, int oct, thread float2 &gs) {
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    float a = 0.5, s = 0.0, ws = 1.0;
    float2 g = float2(0.0);
    gs = float2(0.0);
    float2x2 M = float2x2(1.0, 0.0, 0.0, 1.0);             // d(p_k)/d(p_0)
    for (int i = 0; i < oct; ++i) {
        float3 n = topo_gnoised(p);
        s += a * n.x;
        float2 gi = a * (transpose(M) * n.yz);
        g += gi; gs += gi * ws;
        p = R * p * 2.03; M = (R * 2.03) * M; a *= 0.5; ws *= 0.4;
    }
    return float3(s, g);
}

// ---- Silk (46) ---------------------------------------------------------------------
// A sheet of satin drifting in a slow breeze. Folds run along D (a = along, b = across),
// meander with a, and travel slowly; a long swell rolls under them. Returns (h, dh/dx,
// dh/dy) in p units with the gradient analytic (so highlights are exact at any size).
static inline float3 silk_surface(float2 p, float ts) {
    const float2 D = float2(0.894, -0.447), Dp = float2(0.447, 0.894);
    float a = dot(p, D), b = dot(p, Dp);
    // meander: the fold lines drift sideways along their length
    float m1 = 0.9 * a + ts * 0.23, m2 = 1.7 * a - ts * 0.31 + 1.3;
    float w = 0.36 * sin(m1) + 0.14 * sin(m2);
    float wa = 0.324 * cos(m1) + 0.238 * cos(m2);
    // folds fan out and gather along their length (cloth hangs from a few points)
    float fa = 0.42 * a + ts * 0.07 + 0.8;
    float fan = 1.0 + 0.32 * sin(fa);
    float bb = (b + w) * fan;
    float bba = wa * fan + (b + w) * 0.1344 * cos(fa);       // d(bb)/da
    float bbb = fan;                                         // d(bb)/db
    // three fold families: broad, medium and a few fine creases, each travelling
    float s1 = 0.6 * a + ts * 0.17;
    float f1 = 2.2 * bb + 0.45 * sin(s1) + ts * 0.28;
    float f2 = 3.7 * bb + 0.30 * a - ts * 0.36 + 2.0;
    float f3 = 6.6 * bb - 0.55 * a + ts * 0.47 + 4.1;
    float f4 = 0.55 * a + 0.35 * b + ts * 0.12;            // long swell under everything
    // cloth folds: rounded crests, tighter valleys (a sine pushed toward its crest)
    float c1 = sin(f1), c2 = sin(f2), c3 = sin(f3);
    float h = 0.62 * (c1 - 0.18 * c1 * c1) + 0.30 * (c2 - 0.12 * c2 * c2) + 0.085 * c3 + 0.45 * sin(f4);
    float d1 = 0.62 * (1.0 - 0.36 * c1) * cos(f1);
    float d2 = 0.30 * (1.0 - 0.24 * c2) * cos(f2);
    float d3 = 0.085 * cos(f3), d4 = 0.45 * cos(f4);
    float ha = d1 * (2.2 * bba + 0.27 * cos(s1)) + d2 * (3.7 * bba + 0.30) + d3 * (6.6 * bba - 0.55) + d4 * 0.55;
    float hb = (d1 * 2.2 + d2 * 3.7 + d3 * 6.6) * bbb + d4 * 0.35;
    return float3(h, ha * D + hb * Dp);
}

// ---------------------------------------------------------------- fragment

// The bindings of every fragment function that draws by effect id (fx_fragment, fx_scene_<id>).
#define FX_FRAGMENT_PARAMS                                                                        \
    VOut in [[stage_in]],                                                                         \
    constant FXUniforms& u [[buffer(0)]],                                                         \
    texture2d<float> src   [[texture(0)]],                                                        \
    texture2d<float> glyphs[[texture(1)]],                                                        \
    texture2d<float> earthDay   [[texture(2)]],                                                   \
    texture2d<float> earthNight [[texture(3)]],                                                   \
    texture2d_array<float> planetTex [[texture(4)]],                                              \
    texture2d<float> fadePrev [[texture(5)]],      /* outgoing preset during a crossfade */       \
    texture2d<float> textAtlas [[texture(6)]],     /* Clocks pack SDF type (TextAtlas.swift) */   \
    texture2d<float> musicArt  [[texture(7)]],     /* Now Playing artwork (mipmapped) */          \
    texture2d<float> musicArtPrev [[texture(8)]],  /* the previous track's, while cross-fading */ \
    sampler samp           [[sampler(0)]]

#ifndef DOTSTUDIO_HELPERS_ONLY   // (the entry points below belong to this unit only)
// The über-shader: any effect or scene, by u.effect (FXFragment_body.h). The heavy scenes also
// have entries of their own (fx_scene_<id>: SceneEntries.metal), which the renderer prefers.
fragment float4 fx_fragment(FX_FRAGMENT_PARAMS)
{
#define FX_EFFECT u.effect
#include "FXFragment_body.h"
#undef FX_EFFECT
}

// ---------------------------------------------------------------- music veil (internal pass 73)
//
// Behind Full Screen music (MetalRenderer.encodeVeil), never set by an EffectInstance. Its own
// small fragment functions rather than a case of fx_fragment: the über-shader's register
// footprint made even a two-tap pass cost ~1 ms at 5K; these run at full occupancy.
// Same bindings as fx_fragment (slots 0, 5, 8), so the renderer only swaps pipelines.

// Kawase dual-filter downsample: the target is half the source; the taps sit one source texel
// off-centre, each a bilinear 2×2 — a 4×4 tent, so moving scenes don't alias into the blur.
fragment float4 fx_veil_down(VOut in [[stage_in]],
                             constant FXUniforms& u [[buffer(0)]],
                             texture2d<float> src [[texture(0)]],
                             sampler samp [[sampler(0)]])
{
    float2 uv = in.uv;
    float2 hp = 1.0 / max(u.srcSize, float2(1.0));
    float3 s = src.sample(samp, uv).rgb * 4.0;
    s += src.sample(samp, uv - hp).rgb;
    s += src.sample(samp, uv + hp).rgb;
    s += src.sample(samp, uv + float2(hp.x, -hp.y)).rgb;
    s += src.sample(samp, uv - float2(hp.x, -hp.y)).rgb;
    return float4(s * 0.125, 1.0);
}

// Composite. src = blur level ⌊b⌋ (p1.x = 1: the sharp frame), next = level ⌊b⌋ + 1;
// p0 = (amount, blend toward the next level, Album Art present, —); art = the Album Art.
fragment float4 fx_veil(VOut in [[stage_in]],
                        constant FXUniforms& u [[buffer(0)]],
                        texture2d<float> src  [[texture(0)]],
                        texture2d<float> next [[texture(5)]],
                        texture2d<float> art  [[texture(8)]],
                        sampler samp [[sampler(0)]])
{
    float2 uv = in.uv;
    float2 res = u.resolution;
    float a = u.p0.x;
    float3 c = (u.p1.x > 0.5) ? src.sample(samp, uv).rgb : musicBicubic(src, samp, uv, 0u);
    if (u.p0.y > 0.0) c = mix(c, musicBicubic(next, samp, uv, 0u), u.p0.y);
    // Dim in (≈) linear light with a soft highlight compression: a dark scene keeps ~55 % of
    // its light, a white one lands near L 0.15, so white type keeps ≥ 5:1 over any style.
    float3 lin = c * c;                                       // gamma 2: cheap at 5K
    float Y = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float k = mix(1.0, 0.55 / (1.0 + 2.6 * Y), a);
    // A gentle vignette holds the eye in the middle.
    float2 q = (uv - 0.5) * float2(res.x / res.y, 1.0);
    k *= 1.0 - a * 0.34 * smoothstep(0.30, 1.25, length(q * float2(0.85, 1.0)));
    float3 col = c * sqrt(k);                                 // = sqrt(lin · k)
    if (u.p0.z > 0.5) col = mix(col, art.sample(samp, uv).rgb, a);
    return float4(col + bandDither(in.pos.xy), 1.0);
}

// ---------------------------------------------------------------- error-diffusion dither (compute)
//
// Error diffusion (Floyd–Steinberg, Atkinson, Jarvis… and Riemersma) on a grid of whole-pixel
// cells, as parallel GPU passes (it used to be one serial GPU thread: 100+ ms a frame):
//   1. dither_prep, one thread per cell: the cell's area-averaged, lightly sharpened input,
//      and how "sticky" the cell is this frame (its input barely moved since the last one).
//   2. dither_wave, one threadgroup: a wavefront — row y runs `lag` cells behind row y − 1, so
//      every error a cell gathers from its quantised neighbours is already final. Each cell
//      only ever writes itself, so there are no races. (Riemersma: dither_riem.)
//   3. dither_relax, 9 interleaved phases: a few steps of direct binary search.
//   4. dither_final: writes the grid and keeps the levels for the next frame.
//
// Temporal stability: error diffusion is chaotic — a 0.1 px Ken Burns drift used to re-roll
// the whole pattern every frame (≈ 40 % of the pixels flickering at 30 fps). A cell whose
// input barely changed keeps last frame's level unless its value leaves a hysteresis band.
// Held on its own that drifts within seconds: as the photo moves under the fixed grid, held
// cells carry up to 1.5× the usual error, the error field runs hot, and the dots fuse into
// dashes and worms. So:
//   • a held cell passes on at most half a level of error, like any freshly quantised cell;
//     the excess isn't lost but spread thinly over its 5×5 neighbourhood's input next frame
//     (low-frequency, so it shifts tone, never texture);
//   • the relax pass then toggles any cell whose toggle clearly lowers the eye-filtered error
//     of the pattern around it (two dots side by side read as a bright dash: one lets go).
//     The margin keeps it from touching a fresh error-diffused pattern, so each algorithm
//     keeps its character, and from oscillating frame to frame.
// Measured on the slideshow, 130 frames at 30 fps: ≈ 0.6 % of pixels change per frame and the
// pattern keeps fresh error diffusion's statistics (it used to fuse into dashes within 4 s).
//
// st (5·N half4):  S0 = st[i]       this frame's error (rgb)
//                  S1 = st[N + i]   persistent: (final level rgb, last input luma + 1; 0 = none)
//                  S2 = st[2N + i]  this frame's input (rgb), stickiness (w)
//                  S3 = st[3N + i]  this frame's level (rgb)
//                  S4 = st[4N + i]  persistent: error a held cell couldn't pass on (rgb)
// Uniforms: p0 = (cell, levels, mono, algo) as packed; p1 = (kernel id, W, H, cell px);
//           p2 = (hysteresis in levels, sharpen, threshold jitter, relax margin).

// Gather taps (dx, dy, weight): cell (x, y) receives weight × error of (x − dx, y − dy), the
// transpose of each kernel's scatter. Kernel ids: 0 Floyd–Steinberg, 1 Atkinson, 2 Jarvis-
// Judice-Ninke, 3 Stucki, 4 Burkes, 5 Sierra, 6 Sierra 2-row, 7 Sierra Lite, 8 Fan,
// 9 Shiau-Fan, 10 Shiau-Fan 2, 11 Simple 2D (same weights as the old serial kernel).
constant int EDN[12] = {4, 6, 12, 12, 7, 10, 7, 3, 4, 5, 5, 2};
constant float3 EDK[12][12] = {
    {float3(1,0,7./16), float3(-1,1,3./16), float3(0,1,5./16), float3(1,1,1./16)},
    {float3(1,0,.125), float3(2,0,.125), float3(-1,1,.125), float3(0,1,.125), float3(1,1,.125), float3(0,2,.125)},
    {float3(1,0,7./48), float3(2,0,5./48), float3(-2,1,3./48), float3(-1,1,5./48), float3(0,1,7./48), float3(1,1,5./48),
     float3(2,1,3./48), float3(-2,2,1./48), float3(-1,2,3./48), float3(0,2,5./48), float3(1,2,3./48), float3(2,2,1./48)},
    {float3(1,0,8./42), float3(2,0,4./42), float3(-2,1,2./42), float3(-1,1,4./42), float3(0,1,8./42), float3(1,1,4./42),
     float3(2,1,2./42), float3(-2,2,1./42), float3(-1,2,2./42), float3(0,2,4./42), float3(1,2,2./42), float3(2,2,1./42)},
    {float3(1,0,8./32), float3(2,0,4./32), float3(-2,1,2./32), float3(-1,1,4./32), float3(0,1,8./32), float3(1,1,4./32),
     float3(2,1,2./32)},
    {float3(1,0,5./32), float3(2,0,3./32), float3(-2,1,2./32), float3(-1,1,4./32), float3(0,1,5./32), float3(1,1,4./32),
     float3(2,1,2./32), float3(-1,2,2./32), float3(0,2,3./32), float3(1,2,2./32)},
    {float3(1,0,4./16), float3(2,0,3./16), float3(-2,1,1./16), float3(-1,1,2./16), float3(0,1,3./16), float3(1,1,2./16),
     float3(2,1,1./16)},
    {float3(1,0,.5), float3(-1,1,.25), float3(0,1,.25)},
    {float3(1,0,7./16), float3(-1,1,1./16), float3(0,1,3./16), float3(1,1,5./16)},
    {float3(1,0,8./16), float3(-2,1,1./16), float3(-1,1,1./16), float3(0,1,2./16), float3(1,1,4./16)},
    {float3(1,0,8./16), float3(-3,1,1./16), float3(-2,1,1./16), float3(-1,1,2./16), float3(0,1,4./16)},
    {float3(1,0,.5), float3(0,1,.5)},
};

kernel void dither_prep(texture2d<float, access::sample> inTex [[texture(0)]],
                        device half4* st [[buffer(1)]],
                        constant FXUniforms& u [[buffer(0)]],
                        sampler samp [[sampler(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5);
    int x = int(gid.x), y = int(gid.y);
    if (x >= W || y >= H) return;
    int N = W * H, i = y * W + x;
    float cp = u.p1.w;
    float2 ires = 1.0 / u.resolution;
    float2 c0 = (float2(gid) + 0.5) * cp;
    // The cell's area average (four bilinear taps a quarter cell from its centre cover it),
    // instead of one point: fine detail no longer aliases into the pattern or flickers.
    float q = 0.25 * cp;
    float3 a = (inTex.sample(samp, (c0 + float2(-q, -q)) * ires).rgb + inTex.sample(samp, (c0 + float2(q, -q)) * ires).rgb
              + inTex.sample(samp, (c0 + float2(-q, q)) * ires).rgb + inTex.sample(samp, (c0 + float2(q, q)) * ires).rgb) * 0.25;
    // Mild unsharp mask against the surrounding cells: dithering costs local contrast, so
    // give a little back first (edges and textures stay crisp in 1-bit).
    float r = 1.5 * cp;
    float3 ring = (inTex.sample(samp, (c0 + float2(-r, 0)) * ires).rgb + inTex.sample(samp, (c0 + float2(r, 0)) * ires).rgb
                 + inTex.sample(samp, (c0 + float2(0, -r)) * ires).rgb + inTex.sample(samp, (c0 + float2(0, r)) * ires).rgb) * 0.25;
    float3 c = saturate(a + (a - ring) * u.p2.y);
    float lum = luma(c);
    float prev = float(st[N + i].w);
    float stick = prev > 0.5 ? 1.0 - smoothstep(0.015, 0.08, abs(lum - (prev - 1.0))) : 0.0;
    // Last frame's held-back error, spread over the 5×5 cells around each holder.
    float3 xs = float3(0.0);
    for (int dy = -2; dy <= 2; ++dy) {
        int yy = y + dy;
        if (yy < 0 || yy >= H) continue;
        for (int dx = -2; dx <= 2; ++dx) {
            int xx = x + dx;
            if (xx >= 0 && xx < W) xs += float3(st[4 * N + yy * W + xx].xyz);
        }
    }
    float3 inp = (u.p0.z > 0.5 ? float3(lum, 0.0, 0.0) : c) + xs * (1.0 / 25.0);
    st[2 * N + i] = half4(half3(inp), half(stick));
    st[N + i].w = half(lum + 1.0);
}

// Quantise v to the nearest of `levels`, or keep last frame's level `pq` while v stays within
// its band widened by `hyst` levels (`stick` = how still this cell's input has been).
static inline float3 ditherQuant(float3 v, float3 pq, float L1, float jit, float stick, float hyst) {
    float3 qn = clamp(floor((v + jit / L1) * L1 + 0.5) / L1, 0.0, 1.0);
    float3 keep = step(abs(v - pq) * L1, 0.5 + hyst * stick);
    return mix(qn, pq, keep * step(0.001, stick));
}

// A quantised cell's outputs: its level, at most half a level of error to diffuse, and the
// rest held back for next frame's input (S4).
static inline void ditherStore(device half4* st, int N, int i, float3 v, float3 q, float L1) {
    float3 e = v - q, ec = clamp(e, -0.5 / L1, 0.5 / L1);
    st[i] = half4(half3(ec), 0.0h);
    st[3 * N + i] = half4(half3(q), 0.0h);
    st[4 * N + i] = half4(half3(e - ec), 0.0h);
}

kernel void dither_wave(device half4* st [[buffer(1)]],
                        constant FXUniforms& u [[buffer(0)]],
                        uint tid [[thread_index_in_threadgroup]],
                        uint tn [[threads_per_threadgroup]])
{
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5), N = W * H;
    int kid = clamp(int(u.p1.x + 0.5), 0, 11);
    float L1 = max(u.p0.y, 2.0) - 1.0;
    bool mono = u.p0.z > 0.5;
    float hyst = u.p2.x, jamp = u.p2.z;
    int n = EDN[kid];
    int T = int(tn), lag = (kid == 10) ? 4 : 3;     // Shiau-Fan 2 reaches 3 cells back
    for (int y0 = 0; y0 < H; y0 += T) {
        int y = y0 + int(tid);
        int steps = W + lag * (T - 1);
        for (int s = 0; s < steps; ++s) {
            int x = s - lag * int(tid);
            if (y < H && x >= 0 && x < W) {
                int i = y * W + x;
                float4 in4 = float4(st[2 * N + i]);
                float3 acc = float3(0.0);
                for (int k = 0; k < n; ++k) {
                    float3 tap = EDK[kid][k];
                    int xx = x - int(tap.x), yy = y - int(tap.y);
                    if (xx >= 0 && xx < W && yy >= 0) acc += float3(st[yy * W + xx].xyz) * tap.z;
                }
                float3 v = in4.xyz + acc;
                // A little static threshold jitter breaks Floyd–Steinberg's worms and the
                // regular checker/stripe textures it settles into in flat midtones.
                float jit = (pcg3(float3(float(x), float(y), 41.0)).x - 0.5) * jamp;
                float3 q = ditherQuant(v, float3(st[N + i].xyz), L1, jit, in4.w, hyst);
                if (mono) { v.yz = 0.0; q.yz = 0.0; }
                ditherStore(st, N, i, v, q, L1);
            }
            threadgroup_barrier(mem_flags::mem_device);
        }
    }
}

// Riemersma: error diffusion along a Hilbert curve with a 16-cell memory. That memory is
// short, so the curve splits into chunks that run in parallel, each first replaying the
// cells just before it (without writing; with the same hysteresis and error limit the owning
// chunk used) to fill its history. The replay only reads S1 and S2, which no chunk writes.
kernel void dither_riem(device half4* st [[buffer(1)]],
                        constant FXUniforms& u [[buffer(0)]],
                        uint tid [[thread_position_in_grid]])
{
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5), N = W * H;
    int side = 1; while (side < W || side < H) side <<= 1;
    int total = side * side;
    const int CH = 256, WARM = 64, RN = 16;
    int start = int(tid) * CH;
    if (start >= total) return;
    float L1 = max(u.p0.y, 2.0) - 1.0;
    bool mono = u.p0.z > 0.5;
    float hyst = u.p2.x, jamp = u.p2.z;
    float w[RN]; float wsum = 0.0;
    for (int k = 0; k < RN; ++k) { w[k] = pow(1.0 / 16.0, float(RN - 1 - k) / float(RN - 1)); wsum += w[k]; }
    float3 hist[RN];
    for (int k = 0; k < RN; ++k) hist[k] = float3(0.0);
    int end = min(start + CH, total);
    for (int d = max(start - WARM, 0); d < end; ++d) {
        int rx, ry, t = d, x = 0, y = 0;
        for (int s = 1; s < side; s <<= 1) {
            rx = 1 & (t / 2); ry = 1 & (t ^ rx);
            if (ry == 0) { if (rx == 1) { x = s - 1 - x; y = s - 1 - y; } int tmp = x; x = y; y = tmp; }
            x += s * rx; y += s * ry; t /= 4;
        }
        if (x >= W || y >= H) continue;
        int i = y * W + x;
        float4 in4 = float4(st[2 * N + i]);
        float3 acc = float3(0.0);
        for (int k = 0; k < RN; ++k) acc += hist[k] * (w[k] / wsum);
        float3 v = in4.xyz + acc;
        float jit = (pcg3(float3(float(x), float(y), 41.0)).x - 0.5) * jamp;
        float3 q = ditherQuant(v, float3(st[N + i].xyz), L1, jit, in4.w, hyst);
        if (mono) { v.yz = 0.0; q.yz = 0.0; }
        for (int k = 0; k < RN - 1; ++k) hist[k] = hist[k + 1];
        hist[RN - 1] = clamp(v - q, -0.5 / L1, 0.5 / L1);
        if (d >= start) ditherStore(st, N, i, v, q, L1);
    }
}

// Direct binary search, one step per cell, in 9 interleaved phases (cells 3 apart never read
// each other: no races, the same result every run). The eye-filtered error of the pattern
// around a cell is a Gaussian (σ ≈ 0.8 cells, so a pair of dots weighs clearly more than one)
// over 5×5 cells of level − input; toggling the cell one level toward its input changes the
// error energy by 2·d·c + d²·h(0). The cell toggles only when that drops by more than the
// margin: fresh error diffusion barely moves, chained dots come apart.
kernel void dither_relax(device half4* st [[buffer(1)]],
                         constant FXUniforms& u [[buffer(0)]],
                         constant uint& phase [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]])
{
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5);
    int x = int(gid.x) * 3 + int(phase % 3), y = int(gid.y) * 3 + int(phase / 3);
    if (x >= W || y >= H) return;
    int N = W * H, i = y * W + x;
    float L1 = max(u.p0.y, 2.0) - 1.0;
    float3 q = float3(st[3 * N + i].xyz);
    float3 c = float3(0.0);
    for (int dy = -2; dy <= 2; ++dy) {
        int yy = y + dy;
        if (yy < 0 || yy >= H) continue;
        for (int dx = -2; dx <= 2; ++dx) {
            int xx = x + dx;
            if (xx < 0 || xx >= W) continue;
            int j = yy * W + xx;
            c += exp(-float(dx * dx + dy * dy) * 0.78) * (float3(st[3 * N + j].xyz) - float3(st[2 * N + j].xyz));
        }
    }
    float3 d = -sign(c) / L1;
    float3 qn = q + d;
    float3 ok = step(-0.001, qn) * step(qn, 1.001);
    if (u.p0.z > 0.5) ok.yz = 0.0;
    float3 better = step(2.0 * d * c + d * d * (1.0 + u.p2.w), float3(0.0)) * ok;
    if (any(better > 0.5)) st[3 * N + i].xyz = half3(mix(q, qn, better));
}

// Write the grid and keep the final levels for the next frame.
kernel void dither_final(device half4* st [[buffer(1)]],
                         texture2d<float, access::write> outTex [[texture(1)]],
                         constant FXUniforms& u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    int W = int(u.p1.y + 0.5), H = int(u.p1.z + 0.5);
    if (int(gid.x) >= W || int(gid.y) >= H) return;
    int N = W * H, i = int(gid.y) * W + int(gid.x);
    float3 q = float3(st[3 * N + i].xyz);
    st[N + i].xyz = half3(q);
    outTex.write(float4(u.p0.z > 0.5 ? mix(u.colorA.rgb, u.colorB.rgb, q.x) : q, 1.0), gid);
}
#endif // DOTSTUDIO_HELPERS_ONLY
