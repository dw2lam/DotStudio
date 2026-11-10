//  ClockKit_funcs.h — pieces the clock scenes share. Every symbol is "clockkit_". Included by
//  Shaders.metal after Clocks_funcs.h (it uses the atlas access there) and before Studio6_funcs.h
//  (Dial Clock, 72) and Standby_funcs.h (StandBy 75, Minimal 76, Chronometer 77).
//
//  Frame (the analog helpers): p in screen units from the dial centre, x right, y DOWN, z toward
//  the viewer. Clock angles run clockwise from 12. Shading is in linear light.

// ============================================================ dial geometry + studio light
/// Clock angle a → unit direction on screen.
static inline float2 clockkit_dir(float a) { return float2(sin(a), -cos(a)); }

/// p as seen from a hand or index at clock angle a: x outward along it, y across it.
static inline float2 clockkit_local(float2 p, float a) {
    float s = sin(a), c = cos(a);
    return float2(s * p.x - c * p.y, c * p.x + s * p.y);
}

static inline float clockkit_box(float2 q, float2 b) {
    float2 e = abs(q) - b;
    return length(max(e, 0.0)) + min(max(e.x, e.y), 0.0);
}

/// A dauphine hand: a kite from its tail (x = −tl) through its widest point (xw, ±w) to the tip.
static inline float clockkit_kite(float2 q, float4 K) {
    float2 a = float2(q.x, abs(q.y));
    float2 nT = normalize(float2(K.z, K.w - K.y)), nB = normalize(float2(-K.z, K.y + K.x));
    float d = max(dot(a - float2(K.w, 0.0), nT), dot(a - float2(-K.x, 0.0), nB));
    // cap the tip and tail: past a needle-sharp point the two edges' half-planes grow so slowly
    // along the axis that edge AA and the soft shadow would trail a hairline far beyond it
    return max(d, max(q.x - K.w, -K.x - q.x));
}

/// Signed distance (screen units) to the hour or minute hand at angle a, boss included.
static inline float clockkit_handD(float2 p, float a, float4 K, float collar, float R) {
    float2 q = clockkit_local(p, a) / R;
    return min(clockkit_kite(q, K), length(q) - collar) * R;
}

/// The studio as polished metal mirrors it (linear HDR; r = reflected ray). A dome that is dim at
/// the horizon and brighter overhead, the big warm softbox (the key, along L) and a cool strip
/// light 90° round (Lf). The softbox edge is widened by `lw` (how fast r turns across a pixel).
static inline float3 clockkit_env(float3 r, float3 L, float3 Lf, float lw) {
    float up = saturate(r.z);
    float3 dome = float3(0.050, 0.052, 0.058) + float3(0.20, 0.21, 0.23) * up;
    float key = smoothstep(0.80 - lw, 0.95 + lw, dot(r, L));
    float fill = smoothstep(0.90 - lw, 0.985 + lw, dot(r, Lf));
    return dome + float3(1.0, 0.95, 0.88) * 3.4 * key + float3(0.80, 0.88, 1.0) * 0.55 * fill;
}

/// Polished metal with reflectance F0 (Schlick) at normal n.
static inline float3 clockkit_metal(float3 n, float3 V, float3 L, float3 Lf, float3 F0) {
    float c = saturate(dot(n, V));
    float3 F = F0 + (1.0 - F0) * pow(1.0 - c, 5.0);
    return F * clockkit_env(reflect(-V, n), L, Lf, 0.0);
}

/// The brightest glint a rounded ridge (or edge) along `along` can throw: of the normals its
/// curve holds (tilted across it by up to ±slope), the one nearest the key's half-vector.
static inline float3 clockkit_ridge(float2 along, float slope, float3 V, float3 L, float3 Lf, float3 F0) {
    float2 across = float2(-along.y, along.x);
    float3 H = normalize(L + V);
    float k = clamp(dot(H.xy, across) / max(H.z, 1e-3), -slope, slope);
    return clockkit_metal(normalize(float3(across * k, 1.0)), V, L, Lf, F0);
}

/// A polished two-facet hand (q local in R units, y across): facets tilted ±across, falling a
/// touch toward the tip, a bright line on the ridge, and its round boss.
static inline float3 clockkit_handShade(float2 q, float a, float collar, float fpR,
                                       float3 V, float3 L, float3 Lf, float3 F0) {
    float2 dir = clockkit_dir(a), perp = float2(cos(a), sin(a));
    const float sl = 0.42;
    float tl = sl * (0.80 + 0.45 * saturate(abs(q.y) / 0.045));         // facets a touch convex
    float3 nA = normalize(float3(perp * tl - dir * 0.05, 1.0));
    float3 nB = normalize(float3(-perp * tl - dir * 0.05, 1.0));
    float3 c = mix(clockkit_metal(nB, V, L, Lf, F0), clockkit_metal(nA, V, L, Lf, F0), saturate(0.5 + q.y / fpR));
    float rw = max(0.0035, 0.8 * fpR);                                   // ridge: ~0.35 % of R, ≥ a pixel
    float ridge = exp(-(q.y * q.y) / (rw * rw)) * smoothstep(0.0, 0.06, q.x);
    c = mix(c, clockkit_ridge(dir, sl, V, L, Lf, F0), 0.55 * ridge);
    // the boss: a polished dome ring round the arbor, on top of the blade
    float rq = length(q);
    float inC = saturate(0.5 + (collar - rq) / fpR);
    if (inC > 0.0) {
        float2 g = q.x * dir + q.y * perp;                               // back to screen orientation
        float3 n = normalize(float3(g / max(rq, 1e-4) * (0.08 + 0.50 * rq / collar), 1.0));
        float3 cc = clockkit_metal(n, V, L, Lf, F0);
        cc *= 1.0 - 0.25 * smoothstep(0.80, 1.0, rq / collar);           // its rim rolls away
        c = mix(c, cc, inC);
    }
    return c;
}

/// Day count of the month before (year y, month m 1–12).
static inline int clockkit_prevMonthDays(int y, int m) {
    int pm = (m == 1) ? 12 : m - 1;
    if (pm == 2) return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28;
    return (pm == 4 || pm == 6 || pm == 9 || pm == 11) ? 30 : 31;
}

/// Ink coverage of the day number dd centred at q = 0 (caps, y down), cap px tall.
static inline float clockkit_dayInk(texture2d<float> At, sampler s, int dd, float2 q, float4 fw, float bias, float capPx) {
    ClkRun r = clocks_run();
    if (dd >= 10) clocks_push(r, CLK_G_D0 + dd / 10);
    clocks_push(r, CLK_G_D0 + dd % 10);
    float w = clocks_runWidth(At, r, fw, 0.02);
    return clocks_cov(clocks_runDist(At, s, r, fw, 0.02, q + float2(0.5 * w, -0.5)) - bias, capPx);
}

/// Periodic 1D value noise (period n cells) — the brushing lines, seamless round the dial.
static inline float clockkit_pnoise(float x, float n, float seed) {
    float i = floor(x), f = x - i;
    float a = hash21(float2(fmod(i, n), seed)), b = hash21(float2(fmod(i + 1.0, n), seed));
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

// ============================================================ shared by the StandBy pack
/// Burn-in drift, in pixels: a slow Lissajous loop a few pixels across (≈ 0.25 % of the screen
/// height — 2½ px at 1000 px, 7 px at 5K; ~0.02 px a second), a pure function of the local time
/// of day so the saver, the wallpaper and a thumbnail agree, with periods that divide a day
/// (24 h / 31 and / 23) so it never jumps at midnight. Shift the whole picture by it.
static inline float2 clockkit_drift(float4 clock, float resY) {
    float ph = clock.x * (6.28318531 / 24.0);                      // the day, in radians
    float a = max(1.0, 0.0025 * resY);
    return a * float2(sin(ph * 31.0), sin(ph * 23.0 + 1.3));
}

/// How far into the night it is: 0 by day … 1 from a little after sunset until a little before
/// sunrise (a ~20-minute ramp as the sun sinks from the horizon to −3½°). From the live sun when
/// the renderer filled it (MetalRenderer.fillLiveSky: u.sky.y = 1), else a seasonal day at ~40° N
/// on the local clock (as Window Light's fallback).
static inline float clockkit_night(constant FXUniforms& u) {
    if (u.sky.y > 0.5) return smoothstep(0.01, -0.06, u.sun.x);  // sun elevation, radians
    float doy = u.date.w, hr = u.clock.x;
    float decl = -0.4091 * cos(6.2832 * (doy + 10.0) / 365.0);
    float hd = acos(clamp(-tan(0.698) * tan(decl), -1.0, 1.0)) * 3.8197;   // half the day, hours
    float noon = 12.2 + ((doy > 72.0 && doy < 307.0) ? 1.0 : 0.0);         // summer time
    float rise = noon - hd, set = noon + hd;
    return 1.0 - smoothstep(rise - 0.35, rise, hr) * smoothstep(set + 0.35, set, hr);
}

// ---- face 4 of the atlas (SF Pro Rounded Heavy): outside the one-hot `fw`, addressed directly.
// Its plane's top row is metrics quad 254 (.x), its advances quads 256 + g (.x) — TextAtlas.swift.
/// Advance (caps) of glyph g in face 4.
static inline float clockkit_advRH(texture2d<float> A, int g) {
    return clocks_quad(A, 256 + g).x / CLK_ADVS;
}
/// Glyph g of face 4 (as clocks_glyph; measure distance with clocks_gdist).
static inline ClkGlyph clockkit_glyphRH(texture2d<float> A, int g) {
    float4 r = clocks_quad(A, g);                       // cellX, cellY, cellW, originX
    float plane = clocks_quad(A, 254).x;
    float h = (g <= CLK_G_COLON) ? CLK_BIGH : CLK_SMALLH;
    ClkGlyph o;
    o.tpc = h * CLK_CAP;
    o.org = float2(r.x + r.w, plane + r.y + CLK_BASE * h);
    o.box = float4(1.0 - r.w, 1.0 - CLK_BASE * h, r.z - r.w - 1.0, (1.0 - CLK_BASE) * h - 1.0) / o.tpc;
    o.adv = float4(clockkit_advRH(A, g));
    return o;
}
