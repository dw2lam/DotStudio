#include <DotStudio.h>

// Ember Sun — a low sun sliced by drifting bands, its light shivering on a dark sea, drawn in
// LED cells. A cells scene returns colour + COVERAGE (alpha): 0 leaves a cell dark, and the
// engine draws each lit cell as a dot / pixel / glyph (the Render setting) over the sky.
//   p[0] Drift (band speed)   p[1] Shimmer
//   colorA = the sky (the engine's background gradient), colorB = the sun's heart.
// Shapes here are a few cells across at the least: anything finer than a cell just flickers.

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float horizon = -0.1;
    float3 heart = ctx.colorB;
    float3 rim = float3(0.96, 0.25, 0.36);                      // the sun's cooler lower edge

    // The sun: a disc sitting on the horizon, warm at the top, rose at its foot.
    float2 c = float2(0.0, horizon + 0.1);
    float r = 0.25;
    float d = dsSdCircle(p - c, r);
    float k = saturate((p.y - (c.y - r)) / (2.0 * r));          // 0 at its foot, 1 at its top
    float3 sunCol = mix(rim, heart, smoothstep(0.15, 0.8, k));
    // Bands drift down through it: each band's gap is wider the lower it is, so they open up as
    // they sink (the classic stepped sunset).
    float drift = ctx.t * mix(0.004, 0.03, ctx.p[0]);
    float bandY = (p.y + drift - (c.y - r)) * 9.0;              // band number counting up from the foot
    float band = fract(bandY);
    float gap = clamp(0.5 - 0.12 * (floor(bandY) - drift * 9.0), 0.0, 0.7);   // by the band's height on screen
    float cut = smoothstep(gap - 0.04, gap + 0.04, band);
    float sun = p.y > horizon ? dsFill(d, 0.004) * cut : 0.0;

    // The sea: long broken glints under the sun, wider and dimmer toward us, swaying slowly.
    float sea = 0.0;
    float3 seaCol = heart;
    if (p.y < horizon) {
        float depth = horizon - p.y;                            // 0 at the horizon
        float row = floor(depth * 45.0);                        // rows a few cells tall
        float tt = ctx.t * mix(0.15, 0.6, ctx.p[1]);
        float width = 0.1 + depth * 0.75;
        float sway = (dsNoise(float2(row * 1.7, tt)) - 0.5) * 0.35 * width;
        float streak = 1.0 - smoothstep(width * 0.35, width, abs(p.x - sway));
        // each row breaks into a few dashes that slide sideways
        float dash = smoothstep(0.35, 0.55, dsNoise(float2(p.x * 7.0 - tt * (0.5 + dsHash(row)), row * 3.3)));
        sea = streak * dash * mix(1.0, 0.25, saturate(depth * 2.2));
        seaCol = mix(heart, rim, saturate(depth * 2.8));
    }

    float3 col = p.y > horizon ? sunCol : seaCol;
    return float4(col, max(sun, sea));
}
