//  Weather_funcs.h — live weather for Ocean Horizon (59) and Shallows (67): file-scope Metal
//  helpers, every symbol "wx_". Included from Nature_funcs.h (after its noise helpers), so
//  Studio1_funcs.h sees it too. Linear light throughout, like the scenes themselves.
//
//  Uniforms (filled by WeatherLink, Shared/Weather/WeatherFeed.swift; zero for other scenes):
//    u.weather  = (cloud cover 0–1, precipitation 0–1, snow share 0–1, wind m/s)
//    u.weather2 = (gusts m/s, fog 0–1 = visibility 20 km … 150 m on a log scale, storm 0–1,
//                  1 = differs from the scene's own clear sky → the weather copy of the shader)
//    u.weather3 = (cloud clock offset s — the wind's drift, lightning on 0/1, 0, 0)
//  WeatherMix.clear (cover 0.25, wind 4 m/s, nothing else) is the scene as it always looked.

#ifndef WEATHER_FUNCS_H
#define WEATHER_FUNCS_H

// The frame's weather, from the uniforms (uniform across the frame).
struct WxState {
    float cover;   // cloud cover 0…1
    float deck;    // share of the sky under one stratus deck 0…1 (overcast)
    float rain;    // liquid precipitation 0…1
    float snow;    // frozen precipitation 0…1
    float wet;     // either
    float wind;    // m/s
    float gust;    // m/s
    float fog;     // 0…1
    float storm;   // 0…1
};
static inline WxState wx_state(constant FXUniforms& u) {
    WxState w;
    w.cover = saturate(u.weather.x);
    float pr = saturate(u.weather.y), sn = saturate(u.weather.z);
    w.rain = pr * (1.0 - sn);
    w.snow = pr * sn;
    w.wet = pr;
    w.wind = max(u.weather.w, 0.0);
    w.gust = max(u.weather2.x, w.wind);
    w.fog = saturate(u.weather2.y);
    w.storm = saturate(u.weather2.z);
    w.deck = smoothstep(0.62, 0.97, w.cover);
    return w;
}
// Fog extinction beyond the scenes' own haze, 1/m (Koschmieder: β = 3.912 / visibility).
static inline float wx_fogBeta(float fog) {
    float vis = 20000.0 * exp2(fog * -7.0491);                // 20 km · (150 / 20000)^fog
    return max(3.912 / vis - 3.912 / 20000.0, 0.0);
}
// Sea state from the wind: the scene's own at 4 m/s, calmer in a lull, rough in a gale.
static inline float wx_seaState(float waves, float wind) {
    float calm = mix(0.55, 1.0, saturate(wind / 4.0));
    float x = saturate((wind - 5.0) / 13.0);
    return saturate(waves * calm + 0.8 * x * x * (3.0 - 2.0 * x) * (1.0 - 0.45 * waves));
}

// ---------------------------------------------------------------- lightning
//
// Deterministic from the scene clock. Time runs in slots of WX_SLOT s; a slot holds at most one
// event — a main stroke and maybe one restrike a quarter second later — so there are never more
// than two flashes in a second and seconds of calm between events (on average one every ~13 s
// in a full storm). Each pulse rises in ~40 ms and dies away over ~0.4 s: a believable flash
// that never strobes (a screensaver runs for hours in front of people).
constant float WX_SLOT = 7.0;
static inline float wx_pulse(float x) {
    return x <= 0.0 ? 0.0 : (1.0 - exp(-x * (1.0 / 0.035))) * exp(-x * (1.0 / 0.17)) * 1.78;
}
// Envelope 0…~1 at time t; ev = (azimuth −1…1 across the frame, distance 0…1, kind (< 0.4:
// a bolt down to the sea, else inside the cloud), seed).
static inline float wx_lightning(float t, float storm, thread float4 &ev) {
    float k = floor(t * (1.0 / WX_SLOT));
    float tl = t - k * WX_SLOT;
    float3 h = pcg3(float3(k, 911.0, 37.0));
    float3 h2 = pcg3(float3(k, 913.0, 41.0));
    ev = float4(h.y * 2.0 - 1.0, h.z, h2.x, h2.y);
    if (h.x > 0.45 * storm) return 0.0;
    float x = tl - (0.4 + h2.z * (WX_SLOT - 2.6));
    if (x < 0.0 || x > 1.8) return 0.0;
    float r = 0.22 + 0.16 * h2.y;                              // restrike delay ≥ 0.22 s
    return wx_pulse(x) + (h2.x < 0.65 ? 0.55 : 0.0) * wx_pulse(x - r);
}

// A cloud-to-sea bolt at azimuth az0 (radians), from the cloud base (elevation eTop) down to
// the horizon: a tortuous channel (linear-interpolated random walk — straight runs and sharp
// kinks, not a smooth wiggle) with a fainter branch. v: unit view ray; w: blur (radians) — the
// pixel for the sky, the rough mirror's spread for its reflection (pass |v.y| there).
static inline float wx_lin1(float x, float seed) {
    float i = floor(x), f = x - i;
    return mix(nature_h1(i + seed), nature_h1(i + 1.0 + seed), f) - 0.5;
}
// The channel's sideways offset down its length s (0 at the cloud base … 1 at the sea), in units
// of its height: a slow lean, then kinks at every scale (each octave a broken line).
static inline float wx_boltPath(float s, float seed) {
    return 0.30 * wx_lin1(s * 2.0, seed) + 0.16 * wx_lin1(s * 6.0, seed + 31.0)
         + 0.09 * wx_lin1(s * 15.0, seed + 57.0) + 0.045 * wx_lin1(s * 37.0, seed + 91.0)
         + 0.022 * wx_lin1(s * 90.0, seed + 17.0);
}
static inline float wx_bolt(float3 v, float az0, float eTop, float seed, float w) {
    float e = abs(v.y);
    if (e > eTop * 1.02) return 0.0;
    float az = atan2(v.x, v.z);
    if (abs(az - az0) > eTop * 0.8) return 0.0;
    float s = saturate(1.0 - e / eTop);                        // 0 at the cloud base … 1 at the sea
    float dx = az - (az0 + eTop * wx_boltPath(s, seed));
    // The channel (~1.5 px at 5K wide incl. its hot sheath), blurred by w with its energy kept.
    float w0 = eTop * 0.0022;
    float wc2 = w0 * w0 + w * w;
    float core = exp(-dx * dx / wc2) * (w0 / sqrt(wc2));
    float glow = exp(-abs(dx) / (eTop * 0.04)) * 0.015 + exp(-abs(dx) / (eTop * 0.008)) * 0.05;
    // Two branches fork off and die away to the sides.
    float b = 0.0;
    for (int k = 0; k < 2; ++k) {
        float s0 = k == 0 ? 0.28 : 0.55, len = k == 0 ? 0.35 : 0.22;
        float sb = s - s0;
        if (sb > 0.0 && sb < len) {
            float side = fract(seed * (k == 0 ? 7.13 : 3.71)) < 0.5 ? -1.0 : 1.0;
            float bx = az - (az0 + eTop * (wx_boltPath(s0, seed) + side * sb * 0.6 + 0.5 * wx_boltPath(sb * 1.7, seed + 13.0 * float(k + 1))));
            float ww = wc2 * 0.4;
            b += exp(-bx * bx / ww) * (w0 / sqrt(wc2)) * 0.5 * (1.0 - sb / len);
        }
    }
    float ends = smoothstep(0.0, 0.02, s);
    return (core + glow + b) * ends;
}

// ---------------------------------------------------------------- rain and snow on the lens side
//
// Drops on depth layers (z metres from the camera, near → far), in screen space: sp = (x right,
// y up), ±1 top to bottom, F = focal length in those units. One streak per cell, cells in
// columns that each fall at their own speed (no rows lining up). Each streak is the drop's path
// during a 1/50 s exposure — length from its angular speed, width from its size and its
// defocus (the lens is focused far away), drawn as an antialiased Gaussian line whose opacity
// keeps its energy (thin or blurred = fainter). Layers whose drops would be under the sea at
// that pixel are culled (camH: camera height, rdy: the pixel ray's y).
// Returns coverage 0…1: the caller blends toward the drops' own radiance.
// One cheap integer hash of a cell → three uniform floats (10, 10, 12 bits): the drops and rings
// evaluate one per layer per pixel, so pcg3's cost showed.
static inline float3 wx_hash3(float2 cell, uint salt) {
    uint2 ci = uint2(int2(cell) + 0x8000);
    uint n = (ci.x * 0x8da6b343u) ^ (ci.y * 0xd8163841u) ^ (salt * 0xcb1ab31fu);
    n = (n ^ (n >> 16u)) * 0x7feb352du;
    n ^= n >> 15u;
    n *= 0x846ca68bu;
    n ^= n >> 16u;
    return float3(float(n & 0x3ffu), float((n >> 10u) & 0x3ffu), float(n >> 20u))
         * float3(1.0 / 1024.0, 1.0 / 1024.0, 1.0 / 4096.0);
}
static inline float wx_streaks(float2 sp, float t, float pixS, float F, float rate, float slant,
                               float rdy, float camH, float drizzle) {
    float keep = 1.0;
    float c = cos(slant), s = sin(slant);
    float2 p = float2(sp.x * c - sp.y * s, sp.x * s + sp.y * c);
    float vd = mix(6.5, 2.2, drizzle);                         // fall speed, m/s
    float dd = mix(0.0018, 0.0006, drizzle);                   // drop size, m
    for (int L = 0; L < 3; ++L) {
        float z = L == 0 ? 1.8 : (L == 1 ? 4.6 : 12.0);
        float above = camH + z * rdy;
        if (above < -0.2) continue;                            // under the water here
        float cw = L == 0 ? 0.105 : (L == 1 ? 0.06 : 0.036);
        float col = floor(p.x / cw + float(L) * 0.37);
        float3 hc = wx_hash3(float2(col, float(L)), 7u);
        float spd = F * vd / z;                                // sp per second
        float len = spd * 0.02 + 2.0 * pixS;
        float ch = len * 2.4 + cw * 1.5;
        float y = p.y + t * spd * (0.85 + 0.3 * hc.x) + hc.y * 53.0;
        float row = floor(y / ch);
        float3 h = wx_hash3(float2(col, row), uint(L) + 11u);
        if (h.x > rate * (L == 0 ? 0.4 : (L == 1 ? 0.7 : 0.92))) continue;
        float w = F * dd / z;
        float def = 0.006 / z;
        float sig2 = w * w * 0.25 + def * def + pixS * pixS * 0.3;
        float dx = p.x - (col - float(L) * 0.37 + 0.2 + 0.6 * h.y) * cw;
        if (dx * dx > 9.0 * sig2) continue;
        float sig = sqrt(sig2);
        float y0 = row * ch + (ch - len) * h.z;
        float dy = max(y0 - y, y - (y0 + len));               // > 0 outside the streak
        float ends = saturate(1.0 - dy / (2.0 * pixS + sig));
        float a = min(1.0, w / (1.4 * sig)) * (L == 0 ? 0.5 : 0.75) * exp(-dx * dx / (2.0 * sig2)) * ends * ends;
        keep *= 1.0 - a * smoothstep(-0.2, 0.3, above);
    }
    return 1.0 - keep;
}

// Snowflakes: soft discs drifting down and swaying on depth layers, the near ones large and out
// of focus. Returns coverage 0…1.
static inline float wx_flakes(float2 sp, float t, float pixS, float F, float rate, float wind,
                              float rdy, float camH) {
    float keep = 1.0;
    for (int L = 0; L < 5; ++L) {
        float z = L == 0 ? 0.8 : (L == 1 ? 1.6 : (L == 2 ? 3.2 : (L == 3 ? 6.4 : 13.0)));
        if (camH + z * rdy < -0.2) continue;
        float spd = F * 1.0 / z;                               // ~1 m/s
        float r = F * 0.005 / z;                               // flake radius (1 cm flakes), sp
        float def = 0.010 / z;                                 // out of focus up close
        float sig = sqrt(r * r * 0.4 + def * def + pixS * pixS * 0.3);
        float len = spd * 0.02;                                // 1/50 s of fall
        float sigy = sqrt(sig * sig + len * len * 0.08);
        float a0 = min(1.0, (r * r * 1.3) / (sig * sigy)) * (L == 0 ? 0.55 : 0.9);
        float cs = L == 0 ? 0.30 : (L == 1 ? 0.16 : (L == 2 ? 0.085 : (L == 3 ? 0.045 : 0.026)));
        float2 p = sp + float2(t * F * (0.15 + wind * 0.06) / z, t * spd);
        p += float2(sin(p.y * 2.3 + float(L) * 1.7), cos(p.x * 1.9 + float(L))) * (0.012 / z);
        float2 cell = floor(p / cs);
        float3 h = wx_hash3(cell, uint(L) + 23u);
        if (h.x > rate * (L == 0 ? 0.35 : 0.7)) continue;
        float sw = sin(t * (0.7 + h.z) + h.y * 6.283) * 0.18;  // sway within the cell
        float2 c = (cell + float2(0.5 + sw, 0.2 + 0.6 * h.y)) * cs;
        float2 d = p - c;
        float a = a0 * exp(-0.5 * (d.x * d.x / (sig * sig) + d.y * d.y / (sigy * sigy)));
        a *= smoothstep(-0.2, 0.3, camH + z * rdy);
        keep *= 1.0 - a;
    }
    return 1.0 - keep;
}

// ---------------------------------------------------------------- rain on the water
//
// Raindrop rings on a horizontal water surface at w (metres): each cell of two incommensurate
// grids gets one drop at a time, at a random place and moment; its ring (a wave packet, ~8 cm
// crests — the big drops' rings, the ones that read from a few metres up) runs out at ~0.3 m/s
// and dies in about a second, kept inside its cell. Plus the pocking: the splash where each
// lands. Returns the surface slope (d/dx, d/dz), in .z the slope variance it adds that the pixel
// can't resolve (LEAN, like the waves), in .w the splash's coverage of the pixel.
// fp: the pixel's footprint on the water (m).
static inline float4 wx_rings(float2 w, float t, float fp, float rate) {
    float2 g = float2(0.0);
    float var = 0.0, spl = 0.0;
    for (int L = 0; L < 2; ++L) {
        float cs = L == 0 ? 0.93 : 0.67;
        float2 q = w / cs + float2(float(L) * 0.31, float(L) * 0.57);
        float2 cell = floor(q);
        float3 h = wx_hash3(cell, uint(L) + 101u);
        float per = mix(1.6, 0.7, rate) * (0.8 + 0.4 * h.z);   // a drop every `per` s in this cell
        float ph = t / per + h.x * 7.0;
        float k = floor(ph);
        float age = (ph - k) * per;                            // seconds since it landed
        float3 h2 = wx_hash3(cell + float2(k * 17.0, k * 3.0), uint(L) + 201u);
        if (h2.z > 0.35 + 0.6 * rate) continue;
        float2 c = (cell + 0.3 + 0.4 * h2.xy) - q;             // to the impact, in cells
        float2 d = -c * cs;                                    // from the impact, metres
        float r = length(d);
        float R = 0.02 + 0.32 * age;                           // ring radius
        if (r > R + 0.09 && r > 0.06) continue;                // (outside the ring and its splash)
        float amp = 0.0042 * exp(-age * 2.6) * (0.6 + 0.8 * h2.x);
        const float kr = 78.54;                                // 2π / 8 cm
        float x = r - R;
        float env = exp(-x * x * (1.0 / (0.03 * 0.03)));
        // Resolved fraction of an 8 cm wave over the footprint; the rest is roughness.
        float res = saturate(1.0 - fp * kr * (1.0 / 3.0));
        res *= res;
        float s = -amp * kr * sin(kr * x) * env;               // dη/dr
        float lim = smoothstep(0.5 * cs, 0.32 * cs, r);       // stays in its cell
        g += (d / max(r, 1e-4)) * s * lim * res;
        var += amp * amp * kr * kr * 0.5 * env * lim * (1.0 - res * res) * 0.6;
        // The splash: a crown of spray ~2 cm across for its first tenth of a second, a point of
        // light once the pixel is bigger than it (energy kept: coverage ∝ its area).
        float rs = 0.02;
        float sc = min(1.0, (rs * rs) / (fp * fp + 1e-6));
        spl += exp(-r * r / (rs * rs + fp * fp)) * exp(-age * 14.0) * sc;
    }
    return float4(g, var, spl);
}

// ---------------------------------------------------------------- whitecaps
//
// Cells of the sea (two offset grids, ~5 m) each break now and then: a crest of white water
// spreads across the wind in under a second, then thins into lace that drifts down-wind and
// fades over several seconds — sitting on the crests (crest: the waves' crest factor, ≈ −2…2).
// cov: the coverage to aim for (from the wind); fp: the pixel's footprint (m). Returns 0…1.
static inline float wx_whitecaps(float2 w, float t, float cov, float fp, float crest) {
    const float2 wd = float2(0.27, -0.96);                     // down-wind (toward the camera)
    float f = 0.0;
    for (int L = 0; L < 2; ++L) {
        float cs = L == 0 ? 6.0 : 4.3;
        float2 q = w / cs + float2(0.37, 0.71) * float(L);
        float2 cell = floor(q);
        float3 h = wx_hash3(cell, uint(L) + 501u);
        float per = 6.0 + 4.0 * h.z;
        float ph = t / per + h.x * 13.0;
        float k = floor(ph);
        float age = (ph - k) * per;
        float3 h2 = wx_hash3(cell + float2(k * 13.0, k * 7.0), uint(L) + 601u);
        if (h2.z > min(cov * 12.0, 0.85)) continue;
        // (It drifts down-wind, but never out of its cell: a cell boundary would cut it.)
        float2 d = (q - (cell + 0.3 + 0.4 * h2.xy)) * cs - wd * min(age * 0.3, 0.8);
        float2 dl = float2(d.x * wd.y - d.y * wd.x, dot(d, wd));   // (across, along the wind)
        // A breaking crest: long across the wind, short along it, its edge torn by a coarse field.
        float grow = 0.4 + 0.6 * smoothstep(0.0, 1.0, age);
        float Ra = (0.8 + 0.6 * h2.x) * grow, Rb = (0.3 + 0.3 * h2.y) * grow;
        float e = length(float2(dl.x / Ra, dl.y / Rb));
        if (e > 1.6) continue;
        e += 0.45 * nature_gnoise(w * 0.8 + h2.yx * 31.0);
        // Breaking (dense white) for about a second, then lace thinning and fading.
        float life = age < 1.0 ? 1.0 : exp(-(age - 1.0) * 0.5);
        float n = nature_gnoise(w * 4.3 + h2.xy * 61.0) + 0.55 * nature_gnoise(w * 9.7 + h2.yx * 17.0);
        float thr = mix(-0.6, 0.3, 1.0 - life) + 0.45 * e;
        float p = smoothstep(thr, thr + 0.16 + 3.0 * fp, n) * smoothstep(1.25, 0.85, e);
        f = max(f, p * mix(0.45, 1.0, life) * (0.75 + 0.25 * n));
    }
    return f * smoothstep(-1.6, 0.0, crest);
}

// ---------------------------------------------------------------- rain curtains
//
// Shafts of heavy rain hanging from the cloud base far off (several km): veils over the horizon,
// in bands along the azimuth, streaked vertically. az: azimuth (radians); e: elevation (≥ 0);
// eTop: the shafts' height; tc: the clouds' clock. Returns opacity 0…1.
static inline float wx_curtains(float az, float e, float eTop, float tc, float amount) {
    if (e > eTop) return 0.0;
    float b = nature_gnoise(float2(az * 5.0 + tc * 1.8, 3.7)) * 1.4 + 0.5;
    float band = smoothstep(0.42, 0.85, b);
    float streak = 0.75 + 0.25 * nature_gnoise(float2(az * 160.0 + e * 9.0, e * 4.0 + tc));
    float h = smoothstep(eTop, eTop * 0.25, e);
    return saturate(band * streak * h * amount);
}

#endif
