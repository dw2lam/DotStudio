#include <DotStudio.h>

// Solar Dial — a 24-hour dial: noon at the top, midnight at the bottom, sunrise on the left
// (east, facing south). The sun is a glowing dot that walks round it with the wall clock
// (ctx.clock); the arc above the horizon chord is today's daylight, from the date. The dot burns
// warm while the real sun is up (ctx.sun.isDay), brighter the higher it stands, and cools to a
// pale moonlit point at night. Everything drifts a few pixels over the minutes, so no line sits
// on the same pixels for long (burn-in).
//   p[0] Size   p[1] Ticks (brightness)   p[2] Drift (toggle)
//   colorA = the background, colorB = the sun.

// Hours of daylight for the date, around 40° N (12 h at the equinoxes, ±3 h at the solstices).
static float dayLength(DSDate d) {
    float doy = float(d.month - 1) * 30.44 + float(d.day);
    return 12.0 + 3.0 * cos(DS_TAU * (doy - 172.0) / 365.25);
}

float4 dsScene(float2 uv, DSContext ctx) {
    float2 p = dsCentered(uv, ctx);
    float px = dsPixel(ctx);
    float R = mix(0.24, 0.4, ctx.p[0]);
    float2 c = 0.0;
    if (ctx.p[2] > 0.5) {
        c = 0.012 * float2(sin(ctx.clock / 517.0), cos(ctx.clock / 611.0));   // a slow wander
    }
    float2 q = p - c;
    float r = length(q);
    // θ: 0 at midnight (bottom), π at noon (top), going through sunrise on the left
    float th = atan2(-q.x, -q.y);
    if (th < 0.0) th += DS_TAU;

    float3 bg = dsToLinear(ctx.colorA);
    float3 sun = dsToLinear(ctx.colorB);
    float3 moon = dsToLinear(float3(0.62, 0.70, 0.86));
    bool day = ctx.sun.isDay;
    float lift = saturate(ctx.sun.elevation / 60.0);

    // the sun on the ring at the wall-clock hour (computed first: it lights the background)
    float a = ctx.clock / 86400.0 * DS_TAU;
    float2 sp = R * float2(-sin(a), -cos(a));
    float d = length(q - sp);

    // the background: a faint pool of the sun's (or the night's) light around it
    float3 col = bg * mix(1.15, 0.85, smoothstep(0.0, 0.9, length(p)));
    col += (day ? sun * (0.012 + 0.025 * lift) : moon * 0.008) * exp(-d * d / (R * R * 0.8));

    // the horizon chord: today's sunrise / sunset hours
    float D = dayLength(ctx.date);
    float rise = (12.0 - D * 0.5) / 24.0 * DS_TAU;
    float yh = -cos(rise) * R;                                  // the chord's height
    float above = q.y - yh;

    // the ring: daylight arc warm, night arc dim
    float ring = dsFill(abs(r - R) - px * 0.9, px);
    float dayArc = smoothstep(-px, px, above);
    float tickB = mix(0.25, 1.0, ctx.p[1]);
    float3 ringCol = mix(float3(0.16), mix(float3(0.35), sun * 0.8, 0.6), dayArc) * tickB;
    col = mix(col, ringCol, ring);
    // the chord itself, fading out past the ring
    float chord = dsFill(abs(above) - px * 0.6, px) * smoothstep(R * 1.25, R * 0.9, abs(q.x));
    col = mix(col, float3(0.22) * tickB, chord * 0.7);

    // 24 hour ticks inside the ring (longer every six hours)
    float h = th / DS_TAU * 24.0;
    float k = round(h);
    float major = (fmod(k, 6.0) < 0.5) ? 1.0 : 0.0;
    float along = abs(h - k) * DS_TAU / 24.0 * r;               // distance along the circle
    float inner = R * mix(0.92, 0.85, major);
    float tick = dsFill(along - px * mix(0.7, 1.1, major), px) * step(inner, r) * step(r, R * 0.96);
    col = mix(col, float3(mix(0.24, 0.42, major)) * tickB, tick);

    // the sun (or moon) itself, a short trail behind it
    float3 dot = day ? sun : moon;
    float trail = 0.0;
    float behind = a - th;
    if (behind < 0.0) behind += DS_TAU;
    if (behind < 0.6) trail = (1.0 - behind / 0.6) * ring;
    col += dot * trail * (day ? 0.5 : 0.25);
    col += dot * dsGlow(d - 0.012, day ? mix(0.02, 0.05, lift) : 0.015) * (day ? 0.55 : 0.25);
    col = mix(col, dot * (day ? 1.4 : 0.9), dsFill(d - mix(0.009, 0.013, lift), px * 1.2));

    return float4(dsToSrgb(col) + dsGrain(uv, ctx, 0.006), 1.0);
}
