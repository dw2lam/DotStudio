#include <DotStudio.h>

// Aurora Lake — a ribbon of northern light folding over a mountain ridge, mirrored in a still lake.
//   p[0] Speed   p[1] Glow   p[2] Stars (toggle)   p[3] Curtains (menu: Quiet, Dancing)
//   colorA = the night sky, colorB = the aurora.
// Light is added up in LINEAR colour (dsToLinear / dsToSrgb), then tone-mapped, so the glow
// stays clean and never clips to a flat sheet.

// The ridge's height above the horizon (screen-height units) at x: sharp peaks from ridged noise.
static float ridge(float x, float seed) {
    float n = 1.0 - abs(dsGradientNoise(float2(x * 1.6 + seed * 13.0, 0.5)));
    float h = 0.09 * n * n * n + 0.018 * dsNoise(float2(x * 9.0, seed * 7.0)) + 0.04 * dsNoise(float2(x * 0.7 + 3.0, seed));
    return 0.004 + h;
}

// Smooth 1D value noise, 0…1: two hashes (dsNoise is 2D: four).
static float noise1(float x) {
    float i = floor(x), f = fract(x);
    return mix(dsHash(i), dsHash(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// One curtain: its foot is a slow fold across the sky; light rises from it in fine rays.
static float3 curtain(float2 p, float t, float k, float active, float3 green, float3 violet) {
    float x = p.x;
    float wave = 0.035 * sin(x * 2.3 + t * 0.11 + k * 2.0) + 0.02 * sin(x * 5.1 - t * 0.17 + k * 5.0);
    wave += (0.015 + 0.04 * active) * (noise1(x * 3.0 + t * 0.09 + k * 19.0) - 0.5);
    float foot = 0.36 - 0.12 * k + wave;
    float d = p.y - foot;
    if (d < -0.3 || d > 0.45) return 0.0;      // (beyond these it adds nothing visible)
    // patchy along its length, with fine vertical rays that drift sideways
    float patch = smoothstep(-0.4, 0.9, sin(x * 2.3 - t * 0.06 + k * 3.1) * cos(x * 0.9 + t * 0.04 + k));
    float rays = noise1(x * 48.0 + t * 0.6 + wave * 90.0 + k * 57.0);
    rays = 0.2 + 0.8 * rays * rays * rays;
    float hem = smoothstep(-0.045, 0.008, d);                           // the bright lower edge
    float body = hem * exp(-max(d, 0.0) * 11.0);                       // fading as it rises
    float haze = exp(-abs(d) * 22.0) * 0.16;                           // a soft glow along it
    float3 c = mix(green, violet, smoothstep(0.04, 0.22, d));          // green below, violet up high
    return c * (body * rays + haze) * (0.25 + 0.75 * patch);
}

static float stars(float2 p, float seed, float t) {
    float2 g = p * 70.0;
    float2 id = floor(g);
    float2 h = dsHash2(id + seed * 31.0);
    float pick = dsHash(id * 1.37 + seed);
    if (pick < 0.9) return 0.0;
    float2 c = id + 0.15 + 0.7 * h;
    float d = length(g - c);
    float twinkle = 0.75 + 0.25 * sin(t * (1.0 + 3.0 * h.x) + h.y * 6.28);
    return smoothstep(0.9, 1.0, pick) * exp(-d * d * 60.0) * twinkle;
}

float4 dsScene(float2 uv, DSContext ctx) {
    float t = ctx.t * mix(0.25, 2.0, ctx.p[0]);
    float glow = mix(0.35, 1.6, ctx.p[1]);
    float active = ctx.p[3];
    float2 p = dsCentered(uv, ctx);
    float horizon = -0.2;                        // the lake's far shore
    float2 q = float2(p.x, p.y - horizon);       // y above the horizon

    float3 night = dsToLinear(ctx.colorA);
    float3 green = dsToLinear(ctx.colorB);
    float3 violet = dsToLinear(float3(0.42, 0.20, 0.78));

    bool lake = q.y < 0.0;
    float2 s = q;
    if (lake) {
        // the mirror image, smeared by long low ripples that calm toward the far shore
        float depth = smoothstep(0.0, -0.3, q.y);
        float rip = dsNoise(float2(q.x * 3.0, q.y * 160.0 / (0.3 + depth) + t * 0.4)) - 0.5;
        s = float2(q.x + rip * 0.012 * depth, -q.y);
    }

    // the sky: deep at the top, a little lighter and bluer near the horizon
    float3 col = mix(night * 2.2 + float3(0.004, 0.006, 0.012), night * 0.7, smoothstep(0.0, 0.7, s.y));
    if (ctx.p[2] > 0.5 && s.y > 0.02) col += float3(0.85, 0.9, 1.0) * stars(s, ctx.seed, ctx.t) * smoothstep(0.02, 0.25, s.y);
    float3 aur = curtain(s, t, 0.0, active, green, violet) + 0.45 * curtain(s * float2(1.6, 1.0) + float2(0.9, 0.0), t * 0.8, 1.0, active, green, violet);
    col += aur * glow;
    // the aurora lights the air a little near the horizon
    col += green * 0.03 * glow * exp(-s.y * 7.0);

    // the ridge: near-black, faintly lit from the sky behind it
    float r = s.y < 0.15 ? ridge(s.x, ctx.seed) : 0.0;        // (never higher than ~0.13)
    if (s.y < r + 0.01) {
        float px = dsPixel(ctx) * 1.5;
        float land = smoothstep(r + px, r - px, s.y);
        float3 rock = night * 0.35 + green * 0.006 * glow;
        col = mix(col, rock, land);
    }

    if (lake) {
        float near = smoothstep(0.0, -0.3, q.y);
        col *= mix(0.62, 0.35, near);                                   // dark water
        col += green * glow * 0.05 * exp(-abs(q.y) * 220.0);            // the shoreline's glint
    }
    col = dsTonemap(col * 1.15);
    col *= dsVignette(uv, 0.4);
    return float4(dsToSrgb(col) + dsGrain(uv, ctx, 0.01), 1.0);
}
