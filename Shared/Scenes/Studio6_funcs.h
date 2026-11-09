//  Studio6_funcs.h — DIAL CLOCK (new-scene slot 6, shader id 72). Every symbol is "studio6_".
//
//  A watch dial seen square-on and filling the screen, like a macro photograph: a sunray-brushed
//  (or grained opaline) dial under one big soft key light, faceted applied batons, dauphine hands
//  and a sweeping seconds hand, every part lit by the same studio and casting its own shadow.
//  The key light's azimuth follows the time of day (low left in the morning, overhead at noon,
//  low right toward evening) and drifts a little, so the sunray's bow-tie of light turns slowly.
//
//  Frame: p in screen-height units from the centre, x right, y DOWN, z toward the viewer (the
//  dial is z = 0). Clock angles run clockwise from 12. Lengths in the geometry tables are in
//  dial radii R. Shading is in linear light; studio6_dialClock returns display sRGB.

constant float STUDIO6_TAU = 6.28318531;

// Hands: (tail, widest point, half-width, length) of the dauphine kite, × R.
// The tails stay inside the bosses (no spur behind the arbor).
constant float4 STUDIO6_HOUR = float4(0.045, 0.125, 0.050, 0.635);
constant float4 STUDIO6_MIN  = float4(0.038, 0.135, 0.037, 0.950);
constant float  STUDIO6_COLLAR_H = 0.058, STUDIO6_COLLAR_M = 0.045;   // their round bosses
// Heights above the dial (× R): what sets each part's shadow offset and softness.
constant float  STUDIO6_Z_IDX = 0.012, STUDIO6_Z_HOUR = 0.024, STUDIO6_Z_MIN = 0.036, STUDIO6_Z_SEC = 0.048;

/// Clock angle a → unit direction on screen.
static inline float2 studio6_dir(float a) { return float2(sin(a), -cos(a)); }

/// p as seen from a hand or index at clock angle a: x outward along it, y across it.
static inline float2 studio6_local(float2 p, float a) {
    float s = sin(a), c = cos(a);
    return float2(s * p.x - c * p.y, c * p.x + s * p.y);
}

static inline float studio6_box(float2 q, float2 b) {
    float2 e = abs(q) - b;
    return length(max(e, 0.0)) + min(max(e.x, e.y), 0.0);
}

/// A dauphine hand: a kite from its tail (x = −tl) through its widest point (xw, ±w) to the tip.
static inline float studio6_kite(float2 q, float4 K) {
    float2 a = float2(q.x, abs(q.y));
    float2 nT = normalize(float2(K.z, K.w - K.y)), nB = normalize(float2(-K.z, K.y + K.x));
    float d = max(dot(a - float2(K.w, 0.0), nT), dot(a - float2(-K.x, 0.0), nB));
    // cap the tip and tail: past a needle-sharp point the two edges' half-planes grow so slowly
    // along the axis that edge AA and the soft shadow would trail a hairline far beyond it
    return max(d, max(q.x - K.w, -K.x - q.x));
}

/// Signed distance (screen units) to the hour or minute hand at angle a, boss included.
static inline float studio6_handD(float2 p, float a, float4 K, float collar, float R) {
    float2 q = studio6_local(p, a) / R;
    return min(studio6_kite(q, K), length(q) - collar) * R;
}

/// The seconds hand: a needle tapering to its tip, a counterweight disc on the tail, a boss.
static inline float studio6_secD(float2 p, float a, float R, float hw) {
    float2 q = studio6_local(p, a);
    float w = hw * (1.0 - 0.35 * saturate(q.x / (0.97 * R)));
    float d = max(abs(q.x - 0.385 * R) - 0.585 * R, abs(q.y) - w);
    d = min(d, length(q + float2(0.150 * R, 0.0)) - 0.025 * R);
    return min(d, length(q) - 0.030 * R);
}

/// The studio as polished metal mirrors it (linear HDR; r = reflected ray). A dome that is dim at
/// the horizon and brighter overhead, the big warm softbox (the key, along L) and a cool strip
/// light 90° round (Lf). The softbox edge is widened by `lw` (how fast r turns across a pixel).
static inline float3 studio6_env(float3 r, float3 L, float3 Lf, float lw) {
    float up = saturate(r.z);
    float3 dome = float3(0.050, 0.052, 0.058) + float3(0.20, 0.21, 0.23) * up;
    float key = smoothstep(0.80 - lw, 0.95 + lw, dot(r, L));
    float fill = smoothstep(0.90 - lw, 0.985 + lw, dot(r, Lf));
    return dome + float3(1.0, 0.95, 0.88) * 3.4 * key + float3(0.80, 0.88, 1.0) * 0.55 * fill;
}

/// Polished metal with reflectance F0 (Schlick) at normal n.
static inline float3 studio6_metal(float3 n, float3 V, float3 L, float3 Lf, float3 F0) {
    float c = saturate(dot(n, V));
    float3 F = F0 + (1.0 - F0) * pow(1.0 - c, 5.0);
    return F * studio6_env(reflect(-V, n), L, Lf, 0.0);
}

/// The brightest glint a rounded ridge (or edge) along `along` can throw: of the normals its
/// curve holds (tilted across it by up to ±slope), the one nearest the key's half-vector.
static inline float3 studio6_ridge(float2 along, float slope, float3 V, float3 L, float3 Lf, float3 F0) {
    float2 across = float2(-along.y, along.x);
    float3 H = normalize(L + V);
    float k = clamp(dot(H.xy, across) / max(H.z, 1e-3), -slope, slope);
    return studio6_metal(normalize(float3(across * k, 1.0)), V, L, Lf, F0);
}

/// A polished two-facet hand (q local in R units, y across): facets tilted ±across, falling a
/// touch toward the tip, a bright line on the ridge, and its round boss.
static inline float3 studio6_handShade(float2 q, float a, float collar, float fpR,
                                       float3 V, float3 L, float3 Lf, float3 F0) {
    float2 dir = studio6_dir(a), perp = float2(cos(a), sin(a));
    const float sl = 0.42;
    float tl = sl * (0.80 + 0.45 * saturate(abs(q.y) / 0.045));         // facets a touch convex
    float3 nA = normalize(float3(perp * tl - dir * 0.05, 1.0));
    float3 nB = normalize(float3(-perp * tl - dir * 0.05, 1.0));
    float3 c = mix(studio6_metal(nB, V, L, Lf, F0), studio6_metal(nA, V, L, Lf, F0), saturate(0.5 + q.y / fpR));
    float rw = max(0.0035, 0.8 * fpR);                                   // ridge: ~0.35 % of R, ≥ a pixel
    float ridge = exp(-(q.y * q.y) / (rw * rw)) * smoothstep(0.0, 0.06, q.x);
    c = mix(c, studio6_ridge(dir, sl, V, L, Lf, F0), 0.55 * ridge);
    // the boss: a polished dome ring round the arbor, on top of the blade
    float rq = length(q);
    float inC = saturate(0.5 + (collar - rq) / fpR);
    if (inC > 0.0) {
        float2 g = q.x * dir + q.y * perp;                               // back to screen orientation
        float3 n = normalize(float3(g / max(rq, 1e-4) * (0.08 + 0.50 * rq / collar), 1.0));
        float3 cc = studio6_metal(n, V, L, Lf, F0);
        cc *= 1.0 - 0.25 * smoothstep(0.80, 1.0, rq / collar);           // its rim rolls away
        c = mix(c, cc, inC);
    }
    return c;
}

/// Day count of the month before (year y, month m 1–12).
static inline int studio6_prevMonthDays(int y, int m) {
    int pm = (m == 1) ? 12 : m - 1;
    if (pm == 2) return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28;
    return (pm == 4 || pm == 6 || pm == 9 || pm == 11) ? 30 : 31;
}

/// Ink coverage of the day number dd centred at q = 0 (caps, y down), cap px tall.
static inline float studio6_dayInk(texture2d<float> At, sampler s, int dd, float2 q, float4 fw, float bias, float capPx) {
    ClkRun r = clocks_run();
    if (dd >= 10) clocks_push(r, CLK_G_D0 + dd / 10);
    clocks_push(r, CLK_G_D0 + dd % 10);
    float w = clocks_runWidth(At, r, fw, 0.02);
    return clocks_cov(clocks_runDist(At, s, r, fw, 0.02, q + float2(0.5 * w, -0.5)) - bias, capPx);
}

/// Periodic 1D value noise (period n cells) — the brushing lines, seamless round the dial.
static inline float studio6_pnoise(float x, float n, float seed) {
    float i = floor(x), f = x - i;
    float a = hash21(float2(fmod(i, n), seed)), b = hash21(float2(fmod(i + 1.0, n), seed));
    return mix(a, b, f * f * (3.0 - 2.0 * f));
}

// ============================================================ the scene
//  p0 = (finish 0 Sunray / 1 Grained, hands 0 Steel / 1 Gold / 2 Blued, 24-hour ring, seconds)
//  p1 = (date, size, shine, follow the sun); colorA dial, colorB seconds hand.
static inline float3 studio6_dialClock(float2 px, float2 res, float t, constant FXUniforms& u,
                                       texture2d<float> At, sampler s) {
    const float TAU = STUDIO6_TAU;
    int finish = int(u.p0.x + 0.5), metalSel = int(u.p0.y + 0.5);
    bool h24 = u.p0.z > 0.5, secs = u.p0.w > 0.5, showDate = u.p1.x > 0.5;
    float size = clamp(u.p1.y, 0.3, 2.0), shine = saturate(u.p1.z);
    bool follow = u.p1.w > 0.5;

    float2 p = (px - 0.5 * res) / res.y;
    float aspect = res.x / res.y;
    float fp = 1.0 / res.y;                                          // one pixel
    float R = min(0.44 * size, 0.47 * aspect);                       // the minute track's outer edge
    float fpR = fp / R;                                              // one pixel, in dial radii
    float r = length(p);
    float ang = atan2(p.x, -p.y); if (ang < 0.0) ang += TAU;

    // ---- light and camera
    // 0 at 6:00 (low left) → 1 at 18:00 (low right), then back overnight: continuous all day,
    // so the light never jumps (not at midnight either)
    float hx6 = fmod(u.clock.x + 18.0, 24.0);
    float day = follow ? ((hx6 < 12.0) ? hx6 / 12.0 : (24.0 - hx6) / 12.0) : 0.30;
    float az = (212.0 + 116.0 * day + 7.0 * sin(t * 0.026) + 3.0 * sin(t * 0.0113 + 1.7)) * (TAU / 360.0);
    float2 L2 = float2(cos(az), sin(az));                            // toward the key (always above)
    float3 L = float3(L2 * 0.766, 0.643);                            // 40° up
    float3 Lf = normalize(float3(float2(-L2.y, L2.x) * 0.70, 0.71)); // the strip fill, 90° round
    float3 V = normalize(float3(-p, 2.4));                           // eye 2.4 screen heights out
    float2 sOff = L.xy / L.z;                                        // shadow shift per unit height
    float pen0 = 0.0022 * R;                                         // penumbra at contact…
    const float penK = 0.30;                                         // …and per unit height

    float3 dialC = saturate(u.colorA.rgb);
    float3 A = srgbToLinear(dialC);
    bool pale = luma(dialC) > 0.5;
    float3 F0 = (metalSel == 1) ? float3(1.0, 0.74, 0.36)             // gold
              : (metalSel == 2) ? float3(0.045, 0.080, 0.27)          // blued steel
              : float3(0.62, 0.63, 0.65);                             // steel
    float3 inkC = pale ? float3(0.010, 0.010, 0.012) : float3(0.60, 0.61, 0.63);

    // ---- the dial
    float lit = 0.80 + 0.28 * clamp(dot(p, L2), -1.0, 1.0);          // the key falls off across it
    float3 col;
    if (finish == 0) {
        // SUNRAY: tinted lacquer over metal brushed in fine radial lines. A line reflects only
        // where it runs across the light (an anisotropic lobe: smooth along the line, rough across
        // it), so the key draws a bow-tie of light through the centre, in the lacquer's colour.
        float2 Tr = (r > 1e-5) ? p / r : float2(0.0, -1.0), Bt = float2(-Tr.y, Tr.x);
        float3 H = normalize(L + V);
        const float aT = 0.085, aB = 0.60;
        float2 h1 = float2(dot(H.xy, Tr) / aT, dot(H.xy, Bt) / aB);
        float w1 = exp(-dot(h1, h1) / (H.z * H.z));
        // the brushing itself: two octaves of fine radial lines, each faded out where a pixel
        // can't hold it (so also toward the centre, where they converge)
        float angPx = fp / max(r, 1e-4);
        float f1 = smoothstep(1.5, 4.0, (TAU / 720.0) / angPx), f2 = smoothstep(1.5, 4.0, (TAU / 2400.0) / angPx);
        float br = 1.0 + 0.36 * f1 * (studio6_pnoise(ang / TAU * 720.0, 720.0, 1.0) - 0.5)
                       + 0.30 * f2 * (studio6_pnoise(ang / TAU * 2400.0, 2400.0, 3.0) - 0.5);
        float3 tint = A / max(max(A.r, A.g), max(A.b, 1e-4));       // the lacquer filters the metal
        float3 specC = mix(tint, float3(1.0), pale ? 0.80 : 0.22);
        col = A * (pale ? 0.66 : 0.62) * lit + specC * (0.80 * w1 * shine * br);
    } else {
        // GRAINED (opaline): matte, a fine grain where a pixel can hold it, a faint mottle; the
        // key lays a soft gradient across it
        float g = clocks_grain(p * 700.0) * smoothstep(1.1, 2.4, res.y / 700.0)
                + 0.5 * clocks_grain(p * 260.0 + 3.1) * smoothstep(1.1, 2.4, res.y / 260.0);
        float mott = 0.5 * clocks_noised(p * 2.6 + 4.0).x;
        col = A * (0.90 + 0.16 * clamp(dot(p, L2), -1.0, 1.0)) * (1.0 + 0.05 * g + 0.025 * mott);
    }

    // ---- the minute track, printed
    if (r > 0.93 * R && r < 1.01 * R) {
        float seg = TAU / 60.0, j = round(ang / seg);
        float2 q = studio6_local(p, j * seg);
        bool five = fmod(j, 5.0) < 0.5;
        float r0 = R * (five ? 0.946 : 0.961), r1 = R * 0.993;
        float hw = R * (five ? 0.0042 : 0.0027), hwd = max(hw, 0.5 * fp);
        float d = studio6_box(q - float2(0.5 * (r0 + r1), 0.0), float2(0.5 * (r1 - r0), hwd));
        col = mix(col, inkC * lit, saturate(0.5 - d / fp) * (hw / hwd) * 0.92);
    }

    // ---- 24-hour ring: 13–24 printed small inside the batons
    if (h24 && abs(r - 0.690 * R) < 0.06 * R) {
        float iN = round(ang / (TAU / 12.0));
        int n = 13 + (int(iN) + 11) % 12;                            // 12 o'clock → 24, 1 → 13
        float capN = 0.040 * R;
        ClkRun nr = clocks_run();
        clocks_push(nr, CLK_G_D0 + n / 10); clocks_push(nr, CLK_G_D0 + n % 10);
        float nb; float4 nfw = clocks_face(0, 0.30, nb);
        float w = clocks_runWidth(At, nr, nfw, 0.03);
        float2 q = (p - 0.690 * R * studio6_dir(iN * TAU / 12.0)) / capN + float2(0.5 * w, -0.5);
        float cov = clocks_cov(clocks_runDist(At, s, nr, nfw, 0.03, q) - nb, capN * res.y);
        col = mix(col, inkC * lit, cov * 0.85);
    }

    // ---- applied batons: polished, hip-roofed, each casting a short shadow
    if (r > 0.735 * R && r < 0.965 * R) {                            // their ring (+ shadow, contact shade)
        float iH = round(ang / (TAU / 12.0));
        int hi = int(iH) % 12;
        float aI = iH * TAU / 12.0;
        bool twelve = hi == 0;
        float mid = 0.850 * R;
        float2 bx = float2(0.075, 0.019) * R;
        float off12 = 1.30 * bx.y;
        if (twelve) bx.y *= 0.74;                                    // 12: a narrower pair
        float2 qs = studio6_local(p + sOff * (STUDIO6_Z_IDX * R), aI) - float2(mid, 0.0);
        float2 q = studio6_local(p, aI) - float2(mid, 0.0);
        float sgn = 1.0;
        if (twelve) { qs.y = abs(qs.y) - off12; sgn = (q.y < 0.0) ? -1.0 : 1.0; q.y = abs(q.y) - off12; }
        if (!(showDate && hi == 3)) {                                // the date window takes 3
            float pen = pen0 + penK * STUDIO6_Z_IDX * R;
            float d = studio6_box(q, bx);
            col *= 1.0 - 0.55 * smoothstep(pen, -pen, studio6_box(qs, bx));
            col *= 1.0 - 0.16 * exp(-max(d, 0.0) / (0.008 * R));    // contact shade at its foot
            float cov = saturate(0.5 - d / fp);
            if (cov > 0.0) {
                float2 dir = studio6_dir(aI), perp = float2(cos(aI), sin(aI)) * sgn;
                const float sl = 0.62;
                float2 e = bx - abs(q);                              // to the side, to the end
                float3 cS = mix(studio6_metal(normalize(float3(-perp * sl, 1.0)), V, L, Lf, F0),
                                studio6_metal(normalize(float3( perp * sl, 1.0)), V, L, Lf, F0), saturate(0.5 + q.y / fp));
                float3 cE = mix(studio6_metal(normalize(float3(-dir * sl, 1.0)), V, L, Lf, F0),
                                studio6_metal(normalize(float3( dir * sl, 1.0)), V, L, Lf, F0), saturate(0.5 + q.x / fp));
                float3 ic = mix(cS, cE, saturate(0.5 + (e.y - e.x) / (1.4 * fp)));
                float rw = max(0.0022 * R, 0.7 * fp);
                float ridge = exp(-(q.y * q.y) / (rw * rw)) * saturate(0.5 + (bx.x - bx.y - abs(q.x)) / fp);
                ic = mix(ic, studio6_ridge(dir, sl, V, L, Lf, F0), 0.5 * ridge);
                col = mix(col, ic, cov);
            }
        }
    }

    // ---- the date, in a framed window at 3
    if (showDate && abs(p.y) < 0.08 * R && abs(p.x - 0.850 * R) < 0.10 * R) {
        float2 hx = float2(0.060, 0.044) * R;
        float cr = 0.006 * R, fw0 = 0.0075 * R;
        float2 q = p - float2(0.850 * R, 0.0);
        float dA = studio6_box(q, hx - cr) - cr;                     // the aperture
        float pen = pen0 + penK * 0.008 * R;
        col *= 1.0 - 0.45 * smoothstep(pen, -pen, studio6_box(q + sOff * (0.008 * R), hx - cr + fw0) - cr);
        float covA = saturate(0.5 - dA / fp);
        if (covA > 0.0) {
            // a matte date disc below the dial (colour-matched on a dark dial), the aperture's
            // edge toward the light shading it
            float3 disc = pale ? float3(0.86, 0.85, 0.82) : A * 1.7 + 0.004;
            float dIn = studio6_box(q + sOff * (0.012 * R), hx - cr) - cr;
            float sh = smoothstep(-0.008 * R, 0.001 * R, dIn);
            // the day number; at midnight the wheel rolls the next one up into the window
            int yy = int(u.date.x), mo = clamp(int(u.date.y), 1, 12), dd = clamp(int(u.date.z), 1, 31);
            float e = clocks_ease(u.clock.x * 3600.0 / 1.4);
            float capD = 0.054 * R, pitch = 2.3 * hx.y / capD;
            float db; float4 dfw = clocks_face(0, 0.36, db);
            float2 dq = q / capD;
            float ink = studio6_dayInk(At, s, dd, dq - float2(0.0, (1.0 - e) * pitch), dfw, db, capD * res.y);
            if (e < 1.0) {
                int pd = (dd > 1) ? dd - 1 : studio6_prevMonthDays(yy, mo);
                ink = max(ink, studio6_dayInk(At, s, pd, dq + float2(0.0, e * pitch), dfw, db, capD * res.y));
            }
            disc = mix(disc, pale ? float3(0.012) : float3(0.78, 0.78, 0.76), ink);
            col = mix(col, disc * lit * (1.0 - 0.6 * sh), covA);
        }
        // the frame: polished, a crest round its middle, facets falling either side
        float covF = saturate(0.5 - (abs(dA - 0.5 * fw0) - 0.5 * fw0) / fp);
        if (covF > 0.0) {
            float2 ee = abs(q) - (hx - cr);
            float2 g = (ee.x > 0.0 && ee.y > 0.0) ? normalize(ee) * sign(q)
                     : ((ee.x > ee.y) ? float2(sign(q.x), 0.0) : float2(0.0, sign(q.y)));
            float3 fc = mix(studio6_metal(normalize(float3(-g * 0.55, 1.0)), V, L, Lf, F0),
                            studio6_metal(normalize(float3( g * 0.55, 1.0)), V, L, Lf, F0),
                            saturate(0.5 + (dA - 0.5 * fw0) / fp));
            col = mix(col, fc, covF);
        }
    }

    // ---- the hands: sweeping continuously (no tick at a minute or an hour)
    float aH = TAU * fmod(u.clock.x, 12.0) / 12.0;
    float aM = TAU * u.clock.y / 60.0;
    float aS = TAU * u.clock.z / 60.0;
    float hwS = 0.0042 * R, hwSd = max(hwS, 0.5 * fp);
    float zH = STUDIO6_Z_HOUR * R, zM = STUDIO6_Z_MIN * R, zS = STUDIO6_Z_SEC * R;
    // (everything here is gated by radius: the hands, their shadows and the bosses only reach so
    // far, and most of a wide screen lies outside the dial)
    bool nearH = r < 0.72 * R, nearM = r < 1.03 * R, nearS = secs && r < 1.05 * R;
    float dH = nearH ? studio6_handD(p, aH, STUDIO6_HOUR, STUDIO6_COLLAR_H, R) : 1.0;
    float dM = nearM ? studio6_handD(p, aM, STUDIO6_MIN, STUDIO6_COLLAR_M, R) : 1.0;
    float dS = nearS ? studio6_secD(p, aS, R, hwSd) : 1.0;
    if (nearM || nearS) {   // their shadows on the dial (and everything on it)
        float ph = pen0 + penK * zH, pm = pen0 + penK * zM, ps = pen0 + penK * zS;
        float shade = 1.0;
        if (nearH) shade *= 1.0 - 0.50 * smoothstep(ph, -ph, studio6_handD(p + sOff * zH, aH, STUDIO6_HOUR, STUDIO6_COLLAR_H, R));
        if (nearM) shade *= 1.0 - 0.50 * smoothstep(pm, -pm, studio6_handD(p + sOff * zM, aM, STUDIO6_MIN, STUDIO6_COLLAR_M, R));
        if (nearS) shade *= 1.0 - 0.40 * smoothstep(ps, -ps, studio6_secD(p + sOff * zS, aS, R, hwSd)) * (hwS / hwSd);
        col *= shade;
    }
    float covH = saturate(0.5 - dH / fp);
    if (covH > 0.0) {
        float3 hc = studio6_handShade(studio6_local(p, aH) / R, aH, STUDIO6_COLLAR_H, fpR, V, L, Lf, F0);
        float pm = pen0 + penK * (zM - zH), ps = pen0 + penK * (zS - zH);
        hc *= 1.0 - 0.50 * smoothstep(pm, -pm, studio6_handD(p + sOff * (zM - zH), aM, STUDIO6_MIN, STUDIO6_COLLAR_M, R));
        if (secs) hc *= 1.0 - 0.40 * smoothstep(ps, -ps, studio6_secD(p + sOff * (zS - zH), aS, R, hwSd));
        col = mix(col, hc, covH);
    }
    float covM = saturate(0.5 - dM / fp);
    if (covM > 0.0) {
        float3 mc = studio6_handShade(studio6_local(p, aM) / R, aM, STUDIO6_COLLAR_M, fpR, V, L, Lf, F0);
        float ps = pen0 + penK * (zS - zM);
        if (secs) mc *= 1.0 - 0.40 * smoothstep(ps, -ps, studio6_secD(p + sOff * (zS - zM), aS, R, hwSd));
        col = mix(col, mc, covM);
    }
    if (nearS) {
        // (a needle thinner than a pixel keeps its weight by fading, not by fattening)
        float covS = saturate(0.5 - dS / fp) * mix(hwS / hwSd, 1.0, saturate(0.5 - (r - 0.03 * R) / fp));
        if (covS > 0.0) {
            // lacquered: its colour, lit by the key's gradient; the boss a small dome
            float3 B = srgbToLinear(saturate(u.colorB.rgb));
            float2 q = studio6_local(p, aS);
            float3 sc = B * (0.62 + 0.38 * lit);
            float rb = length(q);
            if (rb < 0.03 * R) sc *= 0.85 + 0.35 * smoothstep(0.03 * R, 0.0, length(p - L2 * 0.010 * R));
            col = mix(col, sc, covS);
        }
    }
    {   // the cap: a polished dome over the arbor
        float rc = 0.016 * R;
        float covC = saturate(0.5 - (r - rc) / fp);
        if (covC > 0.0) {
            float3 n = normalize(float3(p / max(r, 1e-5) * (0.05 + 0.65 * r / rc), 1.0));
            col = mix(col, studio6_metal(n, V, L, Lf, F0), covC);
        }
    }

    // ---- lens: a gentle vignette, highlights rolling off instead of clipping
    col *= 1.0 - 0.30 * smoothstep(0.30, 1.05, length(p * float2(0.78, 1.0)));
    col = select(col, 0.80 + 0.20 * (1.0 - exp(-(col - 0.80) / 0.20)), col > 0.80);
    return linearToSrgb(col) + bandDither(px) * 2.0;
}

