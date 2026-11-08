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
// Liquid Chrome height field: a few domain-warped sines (cheap, smooth, glossy).
static inline float chromeHeight(float2 p, float ts) {
    float2 q = p + 0.65 * float2(sin(p.y * 0.83 + ts), cos(p.x * 0.71 - ts * 0.8));
    q += 0.35 * float2(sin(q.y * 1.7 - ts * 0.6), cos(q.x * 1.5 + ts * 0.7));
    return sin(q.x * 1.15 + ts * 0.6) * 0.5
         + sin(q.y * 1.45 - ts * 0.5) * 0.4
         + sin((q.x + q.y) * 0.9 + ts * 0.9) * 0.3;
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
    float sz = (0.6 + 1.5 * big) * sizeK * pix;
    float I = exp(-ang * ang / (sz * sz)) * (0.2 + 0.7 * h2.z) * (0.6 + 1.1 * big);
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
        float g = fbm3(nr * 9.0 + float3(0.0, ts * 0.015, 0.0), 2.0, 0.5);
        float limb = sqrt(mu);
        return mix(float3(1.0, 0.38, 0.06), float3(1.0, 0.90, 0.70), limb) * (0.74 + 0.45 * g) * mix(0.75, 1.12, limb);
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

// Glass (49) LIQUID: the surface of a slowly flowing sheet of hand-rolled glass, in
// units of one ripple. Warped sines for the broad swell + gradient noise for the
// irregular, hand-made unevenness.
static inline float liquidGlassHeight(float2 p, float ts) {
    float2 q = p + 0.55 * float2(sin(p.y * 0.61 + ts), cos(p.x * 0.53 - ts * 0.7));
    q += 0.30 * float2(sin(q.y * 1.31 - ts * 0.5), cos(q.x * 1.17 + ts * 0.6));
    float h = sin(q.x * 0.9 + q.y * 0.4) * cos(q.y * 0.8 - q.x * 0.3);
    return h + 0.45 * gnoise(q * 0.8 + float2(ts * 0.4, -ts * 0.3));
}

// ---------------------------------------------------------------- fragment

fragment float4 fx_fragment(VOut in [[stage_in]],
                            constant FXUniforms& u [[buffer(0)]],
                            texture2d<float> src   [[texture(0)]],
                            texture2d<float> glyphs[[texture(1)]],
                            texture2d<float> earthDay   [[texture(2)]],
                            texture2d<float> earthNight [[texture(3)]],
                            texture2d_array<float> planetTex [[texture(4)]],
                            texture2d<float> fadePrev [[texture(5)]],   // outgoing preset during a crossfade
                            texture2d<float> textAtlas [[texture(6)]],  // Clocks pack SDF type (TextAtlas.swift)
                            sampler samp           [[sampler(0)]])
{
    float2 uv  = in.uv;
    float2 res = u.resolution;
    float2 px  = uv * res;                 // pixel coords
    float  t   = u.time;

    // -------- source generators ----------------------------------------
    if (u.effect == 0) {                   // image / video source with fill mode
        int mode = u.fillMode;
        if (mode == 3) {                   // SLIDESHOW — Ken Burns-framed photo A (src)
                                           // cross-fading into photo B (fadePrev slot)
            float outA = res.x / res.y;
            float3 a = kenBurnsSample(src, samp, uv, outA, u.srcSize, u.p0);
            if (u.p0.w <= 0.0) return float4(a, 1.0);
            float3 b = kenBurnsSample(fadePrev, samp, uv, outA, u.p2.xy, u.p1);
            float3 m = mix(srgbToLinear(a), srgbToLinear(b), u.p0.w);   // linear-light dissolve
            return float4(linearToSrgb(m), 1.0);
        }
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
        float lv0 = luma(c), lv = lv0;
        // The atlas runs dense → sparse. Light ink on a dark ground must put the densest
        // glyphs on the brightest areas (otherwise highlights render as empty space);
        // the gamma keeps mid-tones legible instead of collapsing to dots.
        bool colorMode = u.p0.z > 0.5;
        float inkL = colorMode ? 1.0 : luma(u.colorB.rgb);
        if (inkL > luma(u.colorA.rgb)) lv = 1.0 - pow(lv0, 0.6);
        int gi = clamp(int(lv * float(u.glyphCount)), 0, u.glyphCount - 1);
        float2 local = (px - float2(cellPx) * cell) / cell;     // [0,1]
        float2 auv = float2((float(gi) + local.x) / float(u.glyphCount), local.y);
        float ink = glyphs.sample(samp, auv).r;
        // Source-color mode: the glyph carries the source hue at near-full brightness
        // (density already encodes luminance), so dark-but-colorful areas still read.
        float3 fg = colorMode
            ? min(c / max(max(c.r, max(c.g, c.b)), 0.08), 1.0) * (0.3 + 0.7 * sqrt(lv0))
            : u.colorB.rgb;
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
            float r = 0.05 * sz;
            float star = smoothstep(r, r * 0.28, d);        // tight core (crisper, no cell seams)
            float b = hash21(cell + fi * 31.0);
            acc += star * fade * (0.55 + 0.55 * b);
        }
        acc = clamp(acc, 0.0, 1.0);
        return float4(mix(u.colorA.rgb, u.colorB.rgb, acc), 1.0);
    }

    case 39: { // UNIVERSE — the solar system in 3D. A perspective camera above the ecliptic
               // slowly orbits the Sun's axis (with a gentle precession), so occlusion, phases,
               // foreshortened orbits and a two-shell parallax starfield all read as depth.
               // Analytic only (sphere/plane hits, no ray-march): ~10 sphere tests + 8 orbit
               // rings per pixel; fbm only on the Sun's disc; all-register compositing.
               // p0=(scale,speed,stars,planetSpeed)  p1.xyz=live sun dir (Earth view frame)
               // p2=(userLon,userLat,hasLoc,orbitsOn)  colorB=(tilt°, cameraOrbit)  colorA=space
        float scale = max(u.p0.x, 0.3);
        float speed = u.p0.y;
        float starsAmt = max(u.p0.z, 0.0);
        float planetSpeed = u.p0.w;
        float tilt = clamp(u.colorB.x, 4.0, 86.0) * 0.01745329;
        float camSpin = u.colorB.y;
        bool haveTex = earthDay.get_width() > 4;
        float ts = t * speed;
        float ta = ts * 0.07 * planetSpeed;                  // orbital clock (Earth year ≈ 90 s)

        // ---- camera: orbit the Sun's axis; elevation precesses a few degrees ----
        float elev = clamp(tilt + 0.06 * sin(ts * 0.023), 0.03, 1.52);
        float az = 0.65 - ts * 0.028 * camSpin;           // retrograde vs the planets: the system visibly turns
        float dist = 15.0 / scale;
        float3 ro = dist * float3(cos(elev) * sin(az), sin(elev), cos(elev) * cos(az));
        float3 fwd = normalize(float3(0.0, -0.9, 0.0) / scale - ro);   // aim a little below the Sun
        float3 camR = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
        float3 camU = cross(camR, fwd);
        const float FOCAL = 2.5;                         // ~44° vertical FOV: depth without stretched limbs
        float2 sp = (uv - 0.5) * 2.0; sp.y = -sp.y; sp.x *= res.x / res.y;
        float3 rd = normalize(fwd * FOCAL + camR * sp.x + camU * sp.y);
        float pix = 2.0 / (res.y * FOCAL);                   // radians per pixel

        // ---- ecliptic plane + Saturn's ring plane (derivatives taken in uniform flow) ----
        float rdy = abs(rd.y) < 1e-5 ? -1e-5 : rd.y;
        float tP = -ro.y / rdy;
        float3 hp = ro + rd * tP;
        float pr = length(hp.xz);
        float fw = max(fwidth(pr), 1e-5);
        float3 pE = uniOrbitPos(3, ta), pS = uniOrbitPos(6, ta), pM = uniBodyPos(9, ta);
        const float RT = 0.466;                              // Saturn's obliquity, fixed in space,
        float3 ringN = float3(0.0, cos(RT), sin(RT));        // so the rings open and close over its year
        float dn = dot(rd, ringN);
        dn = abs(dn) < 1e-5 ? 1e-5 : dn;
        float tR = dot(pS - ro, ringN) / dn;
        float3 qR = ro + rd * tR;
        float rr = length(qR - pS) / UNI_RAD[6];
        float rfw = max(fwidth(rr), 1e-4);

        // ---- bodies: nearest two hits (two, so a Moon crossing Earth keeps a clean edge) ----
        int i1 = -1, i2 = -1; float t1 = 1e9, t2 = 1e9, c1 = 0.0, c2 = 0.0;
        for (int i = 0; i < 10; ++i) {
            float3 c = i == 3 ? pE : i == 6 ? pS : i == 9 ? pM : uniBodyPos(i, ta);
            float2 h = uniSphere(ro, rd, c, UNI_RAD[i], pix);
            if (h.y <= 0.0) continue;
            if (h.x < t1) { i2 = i1; t2 = t1; c2 = c1; i1 = i; t1 = h.x; c1 = h.y; }
            else if (h.x < t2) { i2 = i; t2 = h.x; c2 = h.y; }
        }

        // ---- background: space colour, far + near star shells, Milky Way ----
        float3 col = u.colorA.rgb;
        if (c1 < 0.999 && starsAmt > 0.0) {
            float bri = min(starsAmt, 1.0);
            float3 gN = normalize(float3(0.46, 0.84, -0.29));      // galactic pole, ~60° off the ecliptic's
            float gl = dot(rd, gN);
            float band = exp(-gl * gl * 30.0);                     // the Milky Way: denser stars + soft glow
            col += uniStars(rd * 100.0, 100.0, 0.9, float3(0.0), rd, pix, 0.0,
                            (0.035 + 0.11 * band) * starsAmt, 1.0) * bri;
            float b = dot(ro, rd), cq = dot(ro, ro) - 1600.0;      // near shell (radius 40): parallax
            float3 q = ro + rd * (-b + sqrt(max(b * b - cq, 0.0)));
            col += uniStars(q, 40.0, 0.45, ro, rd, pix, 101.0, 0.07 * starsAmt, 1.3) * bri;
            if (band > 0.03) {
                float3 gC = normalize(float3(0.84, -0.46, 0.0));      // galactic centre, in the band
                float2 gp = float2(dot(rd, gC), dot(rd, cross(gN, gC)));
                float n = 0.62 * vnoise(gp * 3.0 + gl * 4.0 + 5.0) + 0.38 * vnoise(gp * 7.0 - gl * 9.0 + 1.0);
                float lane = smoothstep(0.0, 0.05, abs(gl + 0.03 * (n - 0.5)));   // dark dust lane
                float core = max(dot(rd, gC), 0.0);
                core *= core;
                float3 mw = mix(float3(0.55, 0.62, 0.85), float3(1.0, 0.86, 0.68), core);
                col += mw * band * (0.35 + 0.65 * n) * mix(0.35, 1.0, lane) * (0.035 + 0.06 * core) * bri;
            }
        }

        // ---- layers: bodies + rings (alpha), glow + plane (additive). Kept in scalars
        //      (dynamically indexed arrays would spill to stack memory). depth < 0 = absent.
        float4 LA = float4(0.0), LB = float4(0.0), LC = float4(0.0);
        float dA = -1.0, dB = -1.0, dC = -1.0;
        float3 G = float3(0.0), PL = float3(0.0); float dG = -1.0, dPl = -1.0;
        float3 eL = normalize(-pE);                        // Earth's frame from the live sun vector
        float decl = asin(clamp(u.p1.y, -1.0, 1.0));
        float subLon = u.p2.x + atan2(u.p1.x, u.p1.z);
        float3 eN = cos(decl) * float3(0.0, 1.0, 0.0) + sin(decl) * eL;
        float3 eM = normalize(eL - sin(decl) * eN);
        float3 eE = cross(eN, eM);
        float3 moonM = normalize((pE - pM) * float3(1.0, 0.0, 1.0));
        for (int k = 0; k < 2; ++k) {
            int bi = k == 0 ? i2 : i1;
            if (bi < 0) continue;
            float bt = k == 0 ? t2 : t1, bc = k == 0 ? c2 : c1;
            float3 c = bi == 3 ? pE : bi == 6 ? pS : bi == 9 ? pM : uniBodyPos(bi, ta);
            float3 n0 = normalize(ro + rd * bt - c);
            float3 sc = uniShade(bi, c, n0, rd, bt * pix / UNI_RAD[bi], camR, camU, ts, t,
                                 eE, eN, eM, subLon, u.p2, moonM, ringN,
                                 earthDay, earthNight, planetTex, samp, haveTex);
            if (k == 0) { LA = float4(sc * bc, bc); dA = bt; } else { LB = float4(sc * bc, bc); dB = bt; }
        }

        float tc = -dot(ro, rd);                             // Sun glow, at its closest approach
        if (tc > 0.0) {
            float ds = length(ro + rd * tc);
            float x = max(ds - UNI_RAD[0], 0.0);
            float3 glow = float3(1.0, 0.60, 0.26) * (0.60 * exp(-x * 6.0) + 0.20 * exp(-x * 1.3))
                        + float3(1.0, 0.45, 0.18) * 0.05 * exp(-ds * 0.32);
            G = glow; dG = tc;
        }

        if (tP > 0.0) {                                      // the ecliptic: dust disk, belt, orbits
            float3 pc = float3(0.0);
            float pth = atan2(-hp.z, hp.x);
            float path = min(0.06 / abs(rdy), 0.9);          // thin slab: brighter where we graze it
            float dens = exp(-pr * 0.42) * smoothstep(UNI_RAD[0], 1.5, pr) * (0.7 + 0.6 * vnoise(hp.xz * 1.3));
            float belt = exp(-(pr - 4.18) * (pr - 4.18) * 30.0);
            float3 dustC = mix(float3(1.0, 0.60, 0.30), float3(0.42, 0.52, 0.85), smoothstep(1.0, 7.0, pr));
            pc += dustC * (dens * 0.9 + belt * 0.16) * path * 0.55;
            if (belt > 0.03) {                               // asteroid belt, orbiting as one
                const float NA = 300.0, DR = 0.06, R0 = 3.84;
                float rot = ta * 0.62;
                float th = (pth - rot) * 0.1591549;
                float2 cell = floor(float2((th - floor(th)) * NA, (pr - R0) / DR));
                float3 h = pcg3(float3(cell, 57.0));
                if (h.x < 0.28) {
                    float aa = (cell.x + 0.2 + 0.6 * h.y) / NA * 6.2831853 + rot;
                    float3 pa = float3(cos(aa), 0.0, -sin(aa)) * (R0 + (cell.y + 0.2 + 0.6 * h.z) * DR);
                    float3 v = pa - ro;
                    float tv = dot(v, rd);
                    float dpx = length(v - rd * tv) / (tv * pix);
                    float sz = 0.5 + 0.5 * h.y;
                    pc += float3(0.78, 0.72, 0.66) * exp(-dpx * dpx / (sz * sz)) * (0.25 + 0.45 * h.z) * belt;
                }
            }
            if (u.p2.w > 0.5) {                              // orbit lines, with a trail behind each planet
                for (int i = 1; i < 9; ++i) {
                    float line = smoothstep(1.4, 0.3, abs(pr - UNI_ORB[i]) / fw);
                    if (line <= 0.0) continue;
                    float da = uniAngle(i, ta) - pth;
                    da -= 6.2831853 * floor(da * 0.1591549);
                    float trail = exp(-da * 2.2);
                    pc += mix(float3(0.55, 0.62, 0.78) * 0.17, UNI_TINT[i] * 0.9, trail) * line;
                }
            }
            pc *= exp(-max(tP - dist, 0.0) * 0.035);         // far side recedes
            PL = pc; dPl = tP;
        }

        if (tR > 0.0) {                                      // Saturn's rings, with Saturn's shadow
            float ra = uniRingAlpha(rr, rfw);
            if (ra > 0.002) {
                float3 L6 = normalize(-qR);
                float3 oc = qR - pS;
                float b = dot(oc, L6);
                float sd = sqrt(max(dot(oc, oc) - b * b, 0.0)) / UNI_RAD[6];
                float shadow = b < 0.0 ? smoothstep(1.03, 0.97, sd) : 0.0;
                float lit = (0.35 + 0.65 * abs(dot(ringN, L6))) * (1.0 - 0.8 * shadow);
                float3 rc = mix(float3(0.60, 0.53, 0.43), float3(0.93, 0.85, 0.68), smoothstep(1.5, 2.2, rr)) * lit;
                LC = float4(rc * ra, ra); dC = tR;
            }
        }

        // sort the three alpha layers far → near, then lay the additive ones into the gaps
        if (dA < dB) { float4 l = LA; LA = LB; LB = l; float d = dA; dA = dB; dB = d; }
        if (dB < dC) { float4 l = LB; LB = LC; LC = l; float d = dB; dB = dC; dC = d; }
        if (dA < dB) { float4 l = LA; LA = LB; LB = l; float d = dA; dA = dB; dB = d; }
        col += uniAddIn(G, dG, PL, dPl, dA, 1e30);
        col = col * (1.0 - LA.a) + LA.rgb;
        col += uniAddIn(G, dG, PL, dPl, dB, dA);
        col = col * (1.0 - LB.a) + LB.rgb;
        col += uniAddIn(G, dG, PL, dPl, dC, dB);
        col = col * (1.0 - LC.a) + LC.rgb;
        col += uniAddIn(G, dG, PL, dPl, -1e30, dC);
        col += bandDither(px);
        return float4(col, 1.0);
    }

    case 40: { // BLACK HOLE — gravitational lensing + accretion disk raymarch
        float mass = max(u.p0.x, 0.05);
        float brightness = u.p0.y;
        float rotSpeed = u.p0.z;
        float diskScale = max(u.p0.w, 0.3);
        float speed = max(u.p1.x, 0.0);
        float starsAmt = max(u.p1.y, 0.0);
        float angle = clamp(u.p1.z, 0.03, 1.45);   // viewing elevation: low = edge-on, high = top-down
        float ts = t * speed;
        float rs = mass * 2.0;
        float innerR = 4.1 * diskScale, outerR = 14.5 * diskScale;
        const float diskTemp = 49.78, tempFalloff = 5.22, turbScale = 1.81, turbStretch = 0.75;
        const float turbSharp = 7.4, turbCycle = 5.0, turbLac = 2.5, turbPers = 0.8;
        const float edgeIn = 0.18, edgeOut = 0.5, lensing = 2.4, dopplerStr = 1.0, stepSize = 1.0;

        float2 sp = (uv - 0.5) * 2.0; sp.y = -sp.y; sp.x *= res.x / res.y;
        // gentle slow azimuth orbit at the chosen elevation angle (no fast tumble)
        float ce = cos(angle), se = sin(angle);
        float ct = ts * 0.025;
        float3 camPos = float3(sin(ct) * 20.0 * ce, -se * 20.0, -cos(ct) * 20.0 * ce);
        float3 fwd = normalize(-camPos);
        float3 right = normalize(cross(float3(0, 1, 0), fwd));
        float3 cup = cross(fwd, right);
        float3 rayDir = normalize(fwd + right * sp.x + cup * sp.y);
        float3 rayPos = camPos, prevPos = camPos;
        float3 acc = float3(0.0);
        float alpha = 0.0;
        int state = 0;

        for (int s = 0; s < 32; ++s) {
            if (alpha > 0.99) break;
            float r = length(rayPos);
            if (r < rs * 1.01) { state = 2; break; }
            if (r > 100.0) { state = 1; break; }
            float3 toC = -rayPos / r;
            rayDir = normalize(rayDir + toC * (rs / (r * r) * stepSize * lensing));
            prevPos = rayPos;
            rayPos += rayDir * stepSize;
            if (prevPos.y * rayPos.y < 0.0) {
                float tt = -prevPos.y / (rayPos.y - prevPos.y);
                float3 hit = mix(prevPos, rayPos, tt);
                float hitR = sqrt(hit.x * hit.x + hit.z * hit.z);
                if (hitR > innerR && hitR < outerR) {
                    float ang = atan2(hit.z, hit.x);
                    float normR = clamp((hitR - innerR) / (outerR - innerR), 0.0, 1.0);
                    float tf = pow(innerR / hitR, tempFalloff);
                    float3 dc = blackbody(mix(1500.0, diskTemp * 1000.0, tf));
                    float rotSign = sign(rotSpeed);
                    float3 velDir = float3(-sin(ang) * rotSign, 0.0, cos(ang) * rotSign);
                    float beta = (1.0 / sqrt(hitR / innerR)) * 0.3;
                    float dopp = 1.0 / (1.0 - beta * dot(velDir, rayDir));
                    dc *= clamp(pow(dopp, 3.0 * dopplerStr), 0.1, 5.0);
                    float dlum = dot(dc, float3(0.3, 0.59, 0.11));
                    dc = mix(dc, float3(dlum, dlum * 0.9, dlum * 0.74), 0.4);   // softer, warmer palette
                    float edge = smoothstep(0.0, edgeIn, normR) * smoothstep(1.0, 1.0 - edgeOut, normR);
                    float cyc = fmod(ts, turbCycle);
                    float blend = cyc / turbCycle;
                    float kp1 = cyc * rotSpeed / pow(hitR, 1.5);
                    float kp2 = (cyc + turbCycle) * rotSpeed / pow(hitR, 1.5);
                    float ra1 = ang + kp1, ra2 = ang + kp2;
                    float3 nc1 = float3(hitR * turbScale, cos(ra1) / max(turbStretch, 0.1), sin(ra1) / max(turbStretch, 0.1));
                    float3 nc2 = float3(hitR * turbScale, cos(ra2) / max(turbStretch, 0.1), sin(ra2) / max(turbStretch, 0.1));
                    float tb = mix(fbm3(nc2, turbLac, turbPers), fbm3(nc1, turbLac, turbPers), blend);
                    float opacity = pow(clamp(tb, 0.0, 1.0), turbSharp) * edge;
                    float rem = 1.0 - alpha;
                    acc += dc * brightness * opacity * rem;
                    alpha += rem * opacity;
                }
            }
        }

        if (state != 2 && alpha < 0.99) {
            float3 bg = float3(0.0);
            float theta = atan2(rayDir.z, rayDir.x), phi = asin(clamp(rayDir.y, -1.0, 1.0));
            float2 scd = float2(theta, phi) * 50.0;
            float2 cell = floor(scd), cuv = fract(scd);
            float sprob = step(1.0 - 0.1 * starsAmt, hash21(cell));
            float2 spos = hash22(cell + 42.0) * 0.8 + 0.1;
            float dts = length(cuv - spos);
            float bsv = hash21(cell + 100.0) * 0.03 + 0.012;
            float si = (smoothstep(bsv, 0.0, dts) + smoothstep(bsv * 3.0, 0.0, dts) * 0.3) * sprob;
            bg += mix(float3(0.8, 0.9, 1.0), float3(1.0, 0.95, 0.8), hash21(cell + 200.0)) * si * 0.7 * starsAmt;
            float n1 = fbm3(rayDir * 2.0, 2.0, 0.5) * 2.0 - 1.0;
            bg += float3(0.027, 0.122, 0.267) * clamp(n1 + 0.5, 0.0, 1.0) * 0.06;
            float n2 = fbm3(rayDir * 5.5, 2.0, 0.5) * 2.0 - 1.0;
            bg += float3(0.004, 0.024, 0.082) * clamp(n2 + 0.05, 0.0, 1.0) * 0.22;
            acc += bg * (1.0 - alpha);
        }
        return float4(aces(acc), 1.0);
    }

    // ================================================================ modern pack

    case 42: { // MESH GRADIENT (scene) — five drifting color points blended in Oklab,
               // domain-warped for organic edges, finished with film grain.
               // p0 = (speed, softness, hueSpread, grain); colorA deep, colorB light.
        float speed = u.p0.x, soft = max(u.p0.y, 0.3), spread = u.p0.z, grainAmt = u.p0.w;
        float ts = t * speed * 0.09;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float2 w = float2(vnoise(p * 1.5 + float2(ts * 1.3, -ts)),
                          vnoise(p * 1.5 + float2(4.1 - ts, 2.7 + ts * 1.1))) - 0.5;
        p += w * 0.5;

        float3 A = srgbToOklab(u.colorA.rgb), B = srgbToOklab(u.colorB.rgb);
        float3 st[5];
        st[0] = A;
        st[1] = B;
        // Accents are analogous neighbours of the two key colors, so any A/B pair
        // yields a coherent five-color field (no muddy complementary midpoints).
        st[2] = oklabHue(B, -spread * 2.0);
        st[2].x = mix(A.x, B.x, 0.75); st[2].yz *= 1.1;
        st[3] = oklabHue(B, spread * 1.2);
        st[3].x = min(B.x + 0.07, 0.97); st[3].yz *= 0.85;
        st[4] = oklabHue(A, -spread * 1.5);
        st[4].x = mix(A.x, B.x, 0.25); st[4].yz *= 1.2;

        float expo = 1.5 / soft;
        float3 acc = float3(0.0); float wsum = 0.0;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i);
            float2 c = float2(cos(fi * 1.2566 + ts * (0.55 + 0.11 * fi)),
                              sin(fi * 1.6336 + ts * (0.47 + 0.17 * fi))) * float2(0.40 * aspect, 0.36);
            float2 d = p - c;
            float wi = pow(dot(d, d) + 0.012, -expo);
            acc += st[i] * wi; wsum += wi;
        }
        float3 col = oklabToSrgb(acc / wsum);
        col += filmGrain(px, t) * grainAmt;
        return float4(col, 1.0);
    }

    case 43: { // AURORA (scene) — volumetric auroral curtains over a mountain lake at night.
               // Curtains are thin vertical sheets 150–520 km away, traced in top view so
               // hem altitude, Earth curvature, fold brightening and field-aligned rays are
               // geometric, not painted (see nature_curtains in Scenes/Nature_funcs.h).
               // p0 = (speed, glow, height, stars)  p1 = (lake, activity)
               // colorA sky, colorB aurora (the green; tops and fringe are derived from it).
        float aspect = res.x / res.y;
        float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
        const float F = 1.3, pitch = 0.30;
        float3 fwd = float3(0.0, sin(pitch), cos(pitch));
        float3 up = float3(0.0, cos(pitch), -sin(pitch));
        float3 rd = normalize(fwd * F + float3(1.0, 0.0, 0.0) * sp.x + up * sp.y);

        NatureAuroraP P;
        P.ts = t * u.p0.x;
        P.inten = u.p0.y;
        P.height = max(u.p0.z, 0.2);
        P.stars = u.p0.w;
        P.act = clamp(u.p1.y, 0.0, 1.0);
        P.pix = 2.0 / (res.y * F);
        P.t = t;
        P.soft = 0.0;
        P.sky = nature_lin(u.colorA.rgb);
        float3 gS = u.colorB.rgb;
        P.cG = srgbToLinear(gS);
        float3 gL = srgbToOklab(gS);
        P.cTop = srgbToLinear(oklabToSrgb(mix(gL, srgbToOklab(float3(0.92, 0.22, 0.66)), 0.85)));
        P.cPink = srgbToLinear(oklabToSrgb(mix(gL, srgbToOklab(float3(1.0, 0.32, 0.62)), 0.9)));
        float lake = clamp(u.p1.x, 0.0, 1.0);

        float3 col;
        if (rd.y >= 0.0 || lake <= 0.0) {
            float3 r = rd; r.y = max(r.y, 0.0);
            col = nature_auroraView(rd, u, P);
            if (rd.y < 0.0) {           // no lake: snowy shore, faintly lit by the sky
                col = P.sky * 0.35 + P.cG * 0.004 * P.inten;
            }
        } else {
            // Lake: mirror of the view, roughened by slow ripples (world-space sines,
            // faded out where a ripple would be smaller than a pixel).
            float camH = 1.6;                                   // metres above the water
            float dist = camH / -rd.y;
            float2 w = rd.xz * dist;
            float foot = dist * P.pix / max(-rd.y, 0.02);       // pixel footprint, metres
            float2 grad = float2(0.0);
            float ts = t * 0.35;
            for (int i = 0; i < 6; ++i) {
                float fi = float(i);
                float lam = 0.3 * pow(1.65, fi);
                float ang = 1.5708 + (fi - 2.5) * 0.33 + 0.25 * sin(fi * 3.7);
                float2 dir = float2(cos(ang), sin(ang));
                float k = 6.2831853 / lam;
                float amp = 0.0013 * smoothstep(foot * 3.0, foot * 8.0, lam);
                grad += dir * cos(dot(w, dir) * k + ts * sqrt(9.8 * k) * 0.6 + fi * 2.3) * amp;
            }
            float3 n = normalize(float3(-grad.x, 1.0, -grad.y));
            float3 rr = reflect(rd, n);
            rr.y = max(rr.y, 0.0005);
            float fres = nature_schlick(dot(-rd, n));
            P.soft = 5.0;
            float3 refl = nature_auroraView(rr, u, P);
            float3 body = P.sky * 0.05;
            col = mix(body, refl, mix(0.0, fres, lake));
            col = mix(col, P.sky * 0.35 + P.cG * 0.004 * P.inten, 1.0 - lake);
        }
        return float4(nature_display(col * 1.0, px), 1.0);
    }

    case 44: { // TOPOGRAPHY (scene) — isolines of a slowly evolving warped-fbm terrain,
               // every 5th an index contour, with optional hillshade relief.
               // p0 = (lines, scale, speed, relief); colorA ground, colorB lines.
        float lines = max(u.p0.x, 2.0), sc = max(u.p0.y, 0.2), speed = u.p0.z, fillAmt = u.p0.w;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * sc * 1.5;
        float ts = t * speed * 0.03;
        float2 w = float2(gfbm(p * 0.6 + float2(0.0, ts), 3), gfbm(p * 0.6 + float2(5.2, 1.3 - ts), 3));
        float h = gfbm(p + 1.1 * w + float2(ts * 0.5, -ts * 0.3) + 3.7, 4);
        h = h * 0.75 + 0.5;                                       // ≈ 0..1, no clamping (no plateaus)

        float v = h * lines;
        float fw = max(fwidth(v), 1e-4);
        float lw = max(res.y / 1000.0, 0.8);
        float d = abs(fract(v + 0.5) - 0.5) / fw;                // distance to isoline, in px
        bool major = fmod(floor(v + 0.5) + 1000.0, 5.0) < 0.5;
        float width = major ? lw * 1.8 : lw * 1.0;
        float line = clamp(width * 0.5 + 0.5 - d, 0.0, 1.0);
        line *= smoothstep(0.6, 0.25, fw);                        // fade where lines would crowd
        float alpha = major ? 0.95 : 0.62;

        float gk = res.y * 0.5 / sc;
        float3 n = normalize(float3(-dfdx(h) * gk, dfdy(h) * gk, 1.0));
        float shade = dot(n, normalize(float3(-0.55, 0.55, 0.63)));
        float3 ground = u.colorA.rgb;
        float3 tinted = mix(ground, u.colorB.rgb, 0.04 + 0.10 * clamp(h, 0.0, 1.0));
        float3 col = mix(ground, tinted * (0.72 + 0.45 * shade), fillAmt);
        col = mix(col, u.colorB.rgb, line * alpha);
        col += bandDither(px);
        return float4(col, 1.0);
    }

    case 45: { // LIQUID CHROME (scene) — a rippling mirror surface reflecting a studio
               // environment (hard horizon + softboxes), optional thin-film iridescence.
               // p0 = (speed, scale, iridescence); colorA shadow, colorB highlight.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), iris = u.p0.z;
        float ts = t * speed * 0.2;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * sc * 3.0;
        const float e = 0.015;
        float h  = chromeHeight(p, ts);
        float hx = chromeHeight(p + float2(e, 0.0), ts);
        float hy = chromeHeight(p + float2(0.0, e), ts);
        float3 n = normalize(float3(-(hx - h) / e * 0.8, (hy - h) / e * 0.8, 1.0));
        // Camera looks slightly down, so flat metal mirrors the bright sky above the horizon;
        // every tilt sweeps the reflection across horizon, strip lights and ground.
        float3 r = reflect(normalize(float3(0.0, 0.28, -1.0)), n);

        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float ey = r.y;
        float3 skyc = mix(B, mix(A, B, 0.45), smoothstep(0.02, 0.9, ey));
        float3 grnd = mix(mix(A, B, 0.22), A, smoothstep(-0.01, -0.35, ey));
        float3 c = mix(grnd, skyc, smoothstep(-0.008, 0.008, ey));
        c = mix(c, A, smoothstep(0.035, 0.0, abs(ey - 0.55)) * 0.85);          // dark rafter band
        c += B * smoothstep(0.025, 0.0, abs(ey - 0.30)) * 0.8;                  // strip light
        c += B * smoothstep(0.05, 0.0, abs(ey + 0.42)) * 0.35;                  // floor bounce
        c += B * 0.6 * pow(max(dot(r, normalize(float3(-0.55, 0.45, 0.70))), 0.0), 64.0);
        float fres = pow(1.0 - n.z, 2.0);
        c = mix(c, mix(A, B, 0.6), fres * 0.3);

        float ph = h * 0.35 + dot(n.xy, float2(0.9, 0.5)) * 1.1 + ts * 0.15;
        float3 irc = 0.5 + 0.5 * cos(6.2831853 * (ph + float3(0.0, 0.33, 0.67)));
        c = mix(c, c * (0.35 + 1.25 * irc) + irc * 0.06, iris);
        c += bandDither(px) * 2.0;
        return float4(c, 1.0);
    }

    case 46: { // SILK (scene) — flow field rendered by animated line-integral convolution:
               // fine noise smeared along a slowly turning vector field, with pulses
               // travelling down the streamlines. p0 = (speed, scale, sheen); A ground, B strands.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), sheen = u.p0.z;
        float k = res.y / 1000.0;
        float aspect = res.x / res.y;
        float ts = t * speed;
        float2 q = (uv - 0.5) * float2(aspect, 1.0);
        const int M = 7;                     // 2×7 taps ≈ Black Hole's per-pixel budget
        float stepPx = 3.5 * k;              // step ≲ noise feature size, or strands bead
        float fieldScale = 1.6 / sc;
        float noiseScale = 1.0 / (3.5 * k);
        float acc = 0.0, wsum = 0.0;
        for (int dir = -1; dir <= 1; dir += 2) {
            float2 pp = px;
            float2 v = float2(1.0, 0.0);
            for (int i = 0; i < M; ++i) {
                if ((i & 1) == 0) {          // the field is smooth: re-evaluate every other step
                    float2 fq = (pp / res.y - float2(0.5 * aspect, 0.5)) * fieldScale;
                    float th = sin(fq.x * 1.3 + sin(fq.y * 1.9 + ts * 0.05) * 1.4 + ts * 0.03)
                             + 0.8 * cos(fq.y * 1.1 - sin(fq.x * 2.3 - ts * 0.04) + 0.6)
                             + 0.35 * sin((fq.x + fq.y) * 3.1 + ts * 0.07);
                    v = float2(cos(th * 1.7), sin(th * 1.7));
                }
                float fi = float(i) / float(M);
                float wgt = (1.0 - fi) * (0.6 + 0.4 * sin(6.2831853 * (fi * float(dir) * 0.5 - ts * 0.18)));
                acc += vnoise(pp * noiseScale) * wgt; wsum += wgt;
                pp += v * stepPx * float(dir);
            }
        }
        float lic = acc / max(wsum, 1e-4);
        float s = smoothstep(0.32, 0.70, lic);
        // broad folds of light across the cloth
        float tone = smoothstep(0.15, 0.85, gnoise(q * 1.4 + float2(ts * 0.02, -ts * 0.015)) * 0.9 + 0.5);
        float3 Bl = srgbToOklab(u.colorB.rgb);
        float3 strand = oklabToSrgb(oklabHue(Bl, (tone - 0.5) * sheen * 1.4));
        float3 col = mix(u.colorA.rgb, strand, s * mix(0.25, 1.0, tone));
        col += bandDither(px);
        return float4(col, 1.0);
    }

    case 47: { // RISOGRAPH — separates the source into two spot inks (least-squares on
               // absorbance), screens each (stochastic grain or rotated halftone),
               // misregisters ink 2, then overprints both on textured paper.
               // p0 = (screen, dotSize, misregistration, paper); colorA ink 1, colorB ink 2.
        int screenMode = int(u.p0.x + 0.5);
        float k = res.y / 1000.0;
        float cell = max(u.p0.y * k, 1.0);
        float misreg = u.p0.z * k;
        float paperAmt = u.p0.w;
        float3 inkA = u.colorA.rgb, inkB = u.colorB.rgb;
        float3 kA = 1.0 - inkA, kB = 1.0 - inkB;
        float a11 = dot(kA, kA) + 0.03, a12 = dot(kA, kB), a22 = dot(kB, kB) + 0.03;
        float det = max(a11 * a22 - a12 * a12, 1e-4);
        float2 offB = float2(misreg, -misreg * 0.6)
                    + float2(sin(t * 0.21), cos(t * 0.17)) * misreg * 0.15;   // slow drum drift
        float2 pB = px - offB;

        float mA, mB;
        if (screenMode == 1) {   // HALFTONE: 15° and 75° screens
            float2x2 RA = float2x2(cos(0.26), -sin(0.26), sin(0.26), cos(0.26));
            float2x2 RB = float2x2(cos(1.31), -sin(1.31), sin(1.31), cos(1.31));
            float cs = cell * 1.6;
            float2 rpA = RA * px, rpB = RB * pB;
            float2 gA = (floor(rpA / cs) + 0.5) * cs, gB = (floor(rpB / cs) + 0.5) * cs;
            float3 DA = 1.0 - src.sample(samp, (transpose(RA) * gA) / res).rgb;
            float3 DB = 1.0 - src.sample(samp, (transpose(RB) * gB) / res).rgb;
            float bAA = dot(kA, DA), bBA = dot(kB, DA), bAB = dot(kA, DB), bBB = dot(kB, DB);
            float covA = smoothstep(0.06, 0.94, (a22 * bAA - a12 * bBA) / det);
            float covB = smoothstep(0.06, 0.94, (a11 * bBB - a12 * bAB) / det);
            float rough = (vnoise(px / (1.3 * k)) - 0.5) * 0.10;
            float rA = sqrt(covA) * 0.74 + rough, rB = sqrt(covB) * 0.74 - rough;
            float aa = 1.2 / cs;
            mA = smoothstep(rA + aa, rA - aa, length((rpA - gA) / cs));
            mB = smoothstep(rB + aa, rB - aa, length((rpB - gB) / cs));
        } else {                 // GRAIN: stochastic screen, clumped like riso masters
            float2 cA = floor(px / cell), cB = floor(pB / cell);
            float3 DA = 1.0 - src.sample(samp, (cA + 0.5) * cell / res).rgb;
            float3 DB = 1.0 - src.sample(samp, (cB + 0.5) * cell / res).rgb;
            float bAA = dot(kA, DA), bBA = dot(kB, DA), bAB = dot(kA, DB), bBB = dot(kB, DB);
            float covA = smoothstep(0.06, 0.94, (a22 * bAA - a12 * bBA) / det);
            float covB = smoothstep(0.06, 0.94, (a11 * bBB - a12 * bAB) / det);
            float tA = fract(ign(cA) + 0.5 + (pcg3(float3(cA, 3.0)).x - 0.5) * 0.25);
            float tB = fract(ign(cB + 31.0) + 0.5 + (pcg3(float3(cB, 9.0)).x - 0.5) * 0.25);
            mA = step(tA, covA * 0.98);
            mB = step(tB, covB * 0.98);
        }
        // uneven ink laydown (drum pressure) + overprint (inks are translucent → multiply)
        float dA = 0.86 + 0.14 * vnoise(px / (160.0 * k) + 3.0);
        float dB = 0.86 + 0.14 * vnoise(px / (160.0 * k) + 11.0);
        float3 paper = float3(0.965, 0.952, 0.918);
        paper *= 1.0 + (vnoise(px / (2.2 * k)) - 0.5) * 0.07 * paperAmt
                     + (vnoise(px / (14.0 * k)) - 0.5) * 0.05 * paperAmt;
        float3 col = paper * mix(float3(1.0), inkA, mA * dA) * mix(float3(1.0), inkB, mB * dB);
        float fleck = step(0.9994, hash21(floor(px / (1.6 * k)) + 0.5)) * paperAmt;
        col = mix(col, col * inkB, fleck);
        return float4(col, 1.0);
    }

    case 48: { // GRAIN WASH — big soft-focus blur (spiral taps, noise-rotated), optional
               // Oklab color wash from shadows (A) to highlights (B), then film grain.
               // p0 = (softness, grain, wash)
        float soft = u.p0.x, grainAmt = u.p0.y, tint = u.p0.z;
        float R = soft * soft * 0.11 * res.y;
        float3 c = base.rgb;
        if (R > 0.75) {
            const int N = 18;                // grain hides the undersampling
            // Rotation jitter shared by 2×2 pixel quads: keeps neighbouring taps on
            // nearby texels (texture-cache friendly) while still breaking up ghosting.
            float rot = (ign(floor(px * 0.5)) + 0.5) * 6.2831853;
            float3 sum = float3(0.0);
            for (int i = 0; i < N; ++i) {
                float fi = float(i) + 0.5;
                float r = sqrt(fi / float(N)) * R;
                float a = fi * 2.39996323 + rot;
                sum += src.sample(samp, uv + float2(cos(a), sin(a)) * r / res).rgb;
            }
            // Soft focus, not out of focus: keep part of the sharp image under the blur
            // and let the blurred highlights bloom over it (Orton-style halation).
            float3 blur = sum / float(N);
            float keep = 0.45 * smoothstep(0.75, 4.0, R) ;
            c = mix(blur, base.rgb, keep);
            float3 glow = blur * blur;
            c += glow * (1.0 - c) * 0.45 * soft;
        }
        float l = luma(c);
        float3 washed = oklabToSrgb(mix(srgbToOklab(u.colorA.rgb), srgbToOklab(u.colorB.rgb),
                                        smoothstep(0.02, 0.98, l)));
        c = mix(c, washed, tint);
        c += filmGrain(px, t) * grainAmt * (0.35 + 2.6 * l * (1.0 - l));
        return float4(c, 1.0);
    }

    case 49: { // GLASS — refract the source through fluted reeds, pillow tiles, or a
               // drifting liquid-glass lens; with dispersion, frost and specular.
               // p0 = (style, size, refraction, frost)
        int style = int(u.p0.x + 0.5);
        float k = res.y / 1000.0;
        float S = max(u.p0.y * k, 4.0);
        float refr = u.p0.z, frost = u.p0.w;
        float2 off = float2(0.0);
        float hl = 0.0, shade = 0.0, inside = 1.0;
        if (style == 0) {                // FLUTED — vertical cylindrical reeds
            float f = fract(px.x / S) - 0.5;
            float nx = sin(f * 3.14159265);
            off = float2(-nx * refr * S * 1.1, 0.0);
            hl = smoothstep(0.09, 0.0, abs(f + 0.24)) * 0.16 + smoothstep(0.05, 0.0, abs(f - 0.38)) * 0.06;
            shade = smoothstep(0.32, 0.5, abs(f)) * 0.16;
        } else if (style == 1) {         // TILES — square pillow lenses
            float2 f = fract(px / S) - 0.5;
            off = -sin(f * 3.14159265) * refr * S * 1.1;
            hl = smoothstep(0.18, 0.0, length(f + 0.2)) * 0.14;
            shade = smoothstep(0.34, 0.5, max(abs(f.x), abs(f.y))) * 0.2;
        } else {                         // LIQUID — looking through a slowly flowing sheet of
                                         // hand-rolled glass: the whole frame swims and bends,
                                         // with soft caustic light where the surface focuses
            float2 q = px / S;
            float ts = t * 0.07;
            float e = 0.04;
            float h0 = liquidGlassHeight(q, ts);
            float hx = liquidGlassHeight(q + float2(e, 0.0), ts);
            float hy = liquidGlassHeight(q + float2(0.0, e), ts);
            float2 g = float2(hx - h0, hy - h0) / e;               // surface slope
            off = -g * refr * S * 0.3;
            float3 n = normalize(float3(-g * 0.35, 1.0));
            float spec = pow(max(dot(n, normalize(float3(-0.45, -0.6, 0.66))), 0.0), 40.0);
            float hxx = liquidGlassHeight(q - float2(e, 0.0), ts);
            float hyy = liquidGlassHeight(q - float2(0.0, e), ts);
            float curv = (hx + hxx + hy + hyy - 4.0 * h0) / (e * e);   // < 0 on crests → light focuses
            hl = spec * 0.16 + smoothstep(0.3, 2.5, -curv) * 0.09;
            shade = smoothstep(0.3, 2.5, curv) * 0.12;
        }
        float disp = 0.03 + frost * 0.08;
        float fr = frost * S * 0.14;
        float jr = (ign(px) + 0.5) * 6.2831853;
        float3 c = float3(0.0);
        if (style == 0) {
            // Reeds frost along their curvature: a stratified horizontal smear, so each
            // reed shows soft colour bands instead of a sharp, mosaic-like strip.
            // The scene behind sits out of focus too: a softer vertical spread.
            float span = frost * S * 1.2;
            float jx = hash21(px), jy = hash21(px + 17.31);   // white jitter: no IGN diagonals
            for (int j = 0; j < 8; ++j) {
                float sx = (float(j & 3) + jx) / 4.0 - 0.5;
                float sy = (float(j >> 2) + jy) / 2.0 - 0.5;
                float2 o = off + float2(sx * span, sy * span * 0.7);
                c.r += src.sample(samp, uv + o * (1.0 + disp) / res).r;
                c.g += src.sample(samp, uv + o / res).g;
                c.b += src.sample(samp, uv + o * (1.0 - disp) / res).b;
            }
            c /= 8.0;
        } else {
            for (int j = 0; j < 4; ++j) {
                float a = jr + float(j) * 1.5707963;
                float2 o = off + float2(cos(a), sin(a)) * fr * (0.5 + 0.5 * float(j & 1));
                c.r += src.sample(samp, uv + o * (1.0 + disp) / res).r;
                c.g += src.sample(samp, uv + o / res).g;
                c.b += src.sample(samp, uv + o * (1.0 - disp) / res).b;
            }
            c *= 0.25;
        }
        c = mix(c, c * 0.95 + 0.025, inside);      // glass body
        c = c * (1.0 - shade) + hl;
        return float4(c, 1.0);
    }

    case 38: { // BLIT — crisp nearest upscale of a precomputed dither grid
        float2 gridSize = u.p0.xy;
        float2 g = (floor(uv * gridSize) + 0.5) / gridSize;
        return src.sample(samp, g);
    }

    // ---- scene packs (ids 50–65), one file each
#include "Scenes/Clocks_cases.h"
#include "Scenes/Flowing_cases.h"
#include "Scenes/Nature_cases.h"
#include "Scenes/Retro_cases.h"

    case 41: { // INTERNAL crossfade — set by the renderer during preset rotation,
               // never by an EffectInstance. src = incoming frame, fadePrev = outgoing.
        float k = smoothstep(0.0, 1.0, u.p0.x);
        return float4(mix(fadePrev.sample(samp, uv).rgb, base.rgb, k), 1.0);
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
