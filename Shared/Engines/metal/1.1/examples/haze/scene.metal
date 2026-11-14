#include <DotStudio.h>

// Haze — layered ridges under a calm evening sky, and one live input: Air quality (US AQI,
// 0…300). The style connects it to a signal (Inspector, or MCP bind_signal); the air itself then
// shows the reading. Clean air: a crisp blue sky, the far ridges sharp. Smoky air: the sky warms
// toward the Haze colour, contrast sinks, the low glow dims and reddens and the distant ridges
// dissolve into the murk. Nothing on screen is a number — the input only moves colour and depth
// (a static readout would burn in), and the engine eases it over ~20 s so a new reading drifts in.
// Unconnected (or stale), ctx.input[0] is its default, 0: clean air.
//   p[0] Drift   p[1] Ridges (toggle)   input[0] aqi
//   colorA = the clear sky, colorB = the haze.

// A ridge's height at x: one value-noise octave over a few slow sines (cheap: four of these a
// pixel, and only below the horizon).
static float ridgeLine(float x, float i, float t, float seed) {
    float f = 1.3 + 0.9 * i;
    float u = x * f + t * (0.3 + 0.4 * i) + seed * 17.0 + i * 3.7;
    return 0.05 * (dsNoise(float2(u * 1.6, i * 7.1)) - 0.5) * 2.0
         + 0.022 * sin(u * 2.1 + i) + 0.012 * sin(u * 4.7 + 2.0 * i) + 0.006 * sin(u * 9.3 - i);
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float px = dsPixel(ctx);
    float t = ctx.t * mix(0.004, 0.03, ctx.p[0]);
    // 0 clean … 1 very unhealthy, gently curved so "moderate" already reads as a soft haze
    float h = smoothstep(0.0, 1.0, saturate(ctx.input[0] / 220.0));

    float3 sky = dsToLinear(ctx.colorA);
    float3 haze = dsToLinear(ctx.colorB);
    const float horizon = -0.06;
    float y = p.y - horizon;

    // The sky: deep overhead, paler toward the horizon, warmer and flatter as the haze thickens.
    float3 low = mix(sky * 1.7 + 0.015, haze * 0.9, 0.15 + 0.7 * h);
    float3 top = mix(sky * 0.45, haze * 0.36, 0.6 * h);
    float3 col = mix(low, top, smoothstep(-0.05, mix(0.55, 0.85, h), y));

    // A soft glow low on the horizon (the light behind the haze), wandering over the hours.
    float2 gp = float2(0.32 * ctx.aspect * sin(ctx.clock / 5400.0 + ctx.seed * DS_TAU), horizon + 0.05);
    float g = length((p - gp) * float2(0.55, 1.0));
    float3 glowCol = mix(float3(1.0, 0.86, 0.66), float3(1.0, 0.48, 0.24), h);
    col += glowCol * exp(-g * mix(5.0, 8.0, h)) * mix(0.16, 0.07, h);

    // Haze veils: slow, soft bands, hugging the ground and thickening with the reading.
    float n = dsFbm(float2(p.x * 1.1 + t, p.y * 3.2 - t * 0.4), 2);
    float veil = smoothstep(0.3, 0.85, n) * exp(-max(y, 0.0) * mix(7.0, 2.2, h));
    col = mix(col, haze * (0.85 + 0.35 * n), veil * mix(0.05, 0.5, h));

    // Ridges: the far ones take the air's colour (aerial perspective) — and in haze they all but
    // vanish. Composited near to far, stopping once a ridge covers the pixel; a ridge never rises
    // more than 0.09 above its base, so higher pixels skip it.
    if (ctx.p[1] > 0.5 && y < 0.08) {
        float3 acc = float3(0.0);
        float left = 1.0;                                                  // coverage still open
        for (int i = 3; i >= 0 && left > 0.002; i--) {
            float base = horizon - 0.015 - 0.085 * float(i);
            if (p.y > base + 0.095) continue;
            float k = float(i) / 3.0;                                      // 0 far … 1 near
            float inside = dsFill(p.y - (base + ridgeLine(p.x, float(i), t, ctx.seed)), px);
            float3 rc = mix(sky * 0.22, sky * 0.04, k);
            float air = (1.0 - k) * mix(0.45, 0.95, h) + 0.12 * h;
            rc = mix(rc, low * 0.92, saturate(air));
            acc += rc * inside * left;
            left *= 1.0 - inside;
        }
        col = col * left + acc;
    }

    // Haze flattens everything a little; grain keeps the dark gradients from banding.
    float l = dsLuma(col);
    col = mix(col, haze * l * 1.6, 0.18 * h);
    col = max(col + dsGrain(uv, ctx, 0.006), 0.0);
    return float4(dsToSrgb(col), 1.0);
}
