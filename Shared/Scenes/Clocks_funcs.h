//  Clocks_funcs.h — file-scope Metal helpers for the Clocks pack. Included by Shaders.metal
//  right above fx_fragment (shared helpers such as gfbm, luma, bandDither are visible).
//  Prefix every function/constant with "clocks_" so packs can't collide.
//
//  Type comes from TextAtlas.swift: signed distance fields of the system faces, one face per
//  channel (R SF Pro Light, G SF Pro Bold, B New York, A SF Pro Rounded). Layout here works
//  in "caps": 1.0 = the cap height of the run, x right, y DOWN, origin at the pen on the baseline.

// ============================================================ atlas access
constant float CLK_SPREAD = 0.125;     // TextAtlas.spreadFrac
constant float CLK_CAP    = 0.5;       // TextAtlas.capFrac
constant float CLK_BASE   = 0.72;      // TextAtlas.baseFrac
constant float CLK_FAR    = 0.25;      // reach of the field, in caps (SPREAD / CAP)
constant float CLK_SPACE  = 0.30;      // word space, in caps

constant int CLK_G_COLON = 10, CLK_G_A = 11, CLK_G_D0 = 37, CLK_G_COMMA = 47, CLK_G_PERIOD = 48,
             CLK_G_APOS = 49, CLK_G_MIDDOT = 50, CLK_G_DASH = 51, CLK_G_a = 54;

struct ClkGlyph {
    float2 org;      // atlas texel of the pen origin on the baseline
    float4 box;      // usable cell, caps relative to the pen: (left, top, right, bottom)
    float  tpc;      // atlas texels per cap
    float4 adv;      // advance in caps, per face
};

static inline ClkGlyph clocks_glyph(texture2d<float> A, int g) {
    uint my = A.get_height() - 3;
    float4 r  = round(A.read(uint2(g, my)) * 65535.0);
    float  ox = round(A.read(uint2(g, my + 1)).x * 65535.0);
    float4 ad = A.read(uint2(g, my + 2)) * (65535.0 / 8.0);
    ClkGlyph o;
    o.tpc = r.w * CLK_CAP;
    o.org = float2(r.x + ox, r.y + CLK_BASE * r.w);
    o.box = float4(1.0 - ox, 1.0 - CLK_BASE * r.w, r.z - ox - 1.0, (1.0 - CLK_BASE) * r.w - 1.0) / o.tpc;
    o.adv = ad / o.tpc;
    return o;
}

/// Advance (caps, per face) of glyph g — one texel read (cells are bigH = 512 for 0–10, else 128).
static inline float4 clocks_adv(texture2d<float> A, int g) {
    float tpc = ((g <= CLK_G_COLON) ? 512.0 : 128.0) * CLK_CAP;
    return A.read(uint2(g, A.get_height() - 1)) * (65535.0 / 8.0) / tpc;
}

/// Signed distance (caps, + outside) of glyph G at q (caps from its pen origin), face mix fw.
static inline float clocks_gdist(texture2d<float> A, sampler s, ClkGlyph G, float2 q, float4 fw) {
    if (q.x < G.box.x || q.y < G.box.y || q.x > G.box.z || q.y > G.box.w) return CLK_FAR;
    float2 t = (G.org + q * G.tpc) / float2(A.get_width(), A.get_height());
    float v = dot(A.sample(s, t, level(0.0)), fw);   // explicit LOD: safe in divergent loops
    return (0.5 - v) * (2.0 * CLK_SPREAD / CLK_CAP);
}

/// Typeface menu → channel weights + a weight `bias` (caps, subtract from d) that thickens or
/// thins the master.
/// sel: 0 Sans, 1 Serif, 2 Rounded, 3 Sans Bold (flip clock).
static inline float4 clocks_face(int sel, float w, thread float& bias) {
    w = clamp(w, 0.0, 1.0);
    if (sel == 1) { bias = (w - 0.35) * 0.06; return float4(0, 0, 1, 0); }
    if (sel == 2) { bias = (w - 0.45) * 0.06; return float4(0, 0, 0, 1); }
    if (sel == 3) { bias = (w - 0.5) * 0.05;  return float4(0, 1, 0, 0); }
    // Sans: thicken the Light master up to ~Medium, then switch to a thinned Bold master
    // (blending the two masters' fields makes lumpy joins where their skeletons differ).
    if (w < 0.5) { bias = -0.012 + 0.074 * w; return float4(1, 0, 0, 0); }
    bias = -0.03 + 0.08 * (w - 0.5);
    return float4(0, 1, 0, 0);
}

static inline float clocks_cov(float dCaps, float capPx) { return clamp(0.5 - dCaps * capPx, 0.0, 1.0); }

// ============================================================ text runs
// A run is never a private array (big per-thread arrays get spilled — and miscompiled under
// register pressure, dropping glyphs in whole SIMD tiles). Literal runs pack up to 8 glyph ids
// as bytes in two uints (0xFF = space); date runs are generated from the constant name tables.
struct ClkRun {
    uint lo, hi; int n;
    int kind;                          // 0 literal, 1 date
    int wd, mo, dd, nDay, nMon, nNum;
    bool caps, dayFirst;
};

constant char CLK_DAYS[7][10] = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
constant char CLK_MONTHS[12][10] = { "January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December" };

static inline int clocks_gid(char c, bool caps) {
    if (c >= 'a' && c <= 'z') return caps ? CLK_G_A + (c - 'a') : CLK_G_a + (c - 'a');
    if (c >= 'A' && c <= 'Z') return CLK_G_A + (c - 'A');
    if (c >= '0' && c <= '9') return CLK_G_D0 + (c - '0');
    if (c == ',') return CLK_G_COMMA;
    if (c == '.') return CLK_G_PERIOD;
    if (c == '\'') return CLK_G_APOS;
    if (c == '*') return CLK_G_MIDDOT;
    if (c == '-') return CLK_G_DASH;
    return -1;                                         // space
}
static inline ClkRun clocks_run() {
    ClkRun r;
    r.lo = 0u; r.hi = 0u; r.n = 0; r.kind = 0;
    r.wd = 0; r.mo = 0; r.dd = 1; r.nDay = 0; r.nMon = 0; r.nNum = 1;
    r.caps = false; r.dayFirst = false;
    return r;
}
static inline void clocks_push(thread ClkRun& r, int g) {
    uint b = (g < 0) ? 0xFFu : uint(g);
    if (r.n < 4)      r.lo |= b << (8u * uint(r.n));
    else if (r.n < 8) r.hi |= b << (8u * uint(r.n - 4));
    r.n = min(r.n + 1, 8);
}
static inline int clocks_strlen(constant char* s) {
    int n = 0;
    for (int i = 0; i < 10; ++i) { if (s[i] == 0) break; n += 1; }
    return n;
}
/// "SUNDAY · NOVEMBER 8" (caps: for tracked small caps), or "Sunday, November 8" / "Sunday, 8 November".
static inline ClkRun clocks_dateRun(float4 date, float4 clock, bool caps, bool dayFirst) {
    ClkRun r = clocks_run();
    r.kind = 1; r.caps = caps; r.dayFirst = dayFirst;
    r.wd = clamp(int(clock.w) - 1, 0, 6); r.mo = clamp(int(date.y) - 1, 0, 11); r.dd = clamp(int(date.z), 1, 31);
    r.nDay = clocks_strlen(CLK_DAYS[r.wd]); r.nMon = clocks_strlen(CLK_MONTHS[r.mo]); r.nNum = r.dd >= 10 ? 2 : 1;
    r.n = r.nDay + (caps ? 3 : 2) + r.nMon + 1 + r.nNum;
    return r;
}
static inline int clocks_runGlyph(thread const ClkRun& r, int i) {
    if (r.kind == 0) {
        uint b = (((i < 4) ? r.lo : r.hi) >> (8u * uint(i & 3))) & 0xFFu;
        return (b == 0xFFu) ? -1 : int(b);
    }
    if (i < r.nDay) return clocks_gid(CLK_DAYS[r.wd][i], r.caps);
    i -= r.nDay;
    int ns = r.caps ? 3 : 2;
    if (i < ns) return r.caps ? ((i == 1) ? CLK_G_MIDDOT : -1) : ((i == 0) ? CLK_G_COMMA : -1);
    i -= ns;
    bool numFirst = r.dayFirst;
    int nA = numFirst ? r.nNum : r.nMon;
    bool isNum;
    if (i < nA) isNum = numFirst;
    else { i -= nA; if (i == 0) return -1; i -= 1; isNum = !numFirst; }
    if (isNum) return CLK_G_D0 + ((r.nNum == 2 && i == 0) ? r.dd / 10 : r.dd % 10);
    return clocks_gid(CLK_MONTHS[r.mo][i], r.caps);
}

static inline float clocks_runWidth(texture2d<float> A, thread const ClkRun& r, float4 fw, float track) {
    float w = 0.0;
    for (int i = 0; i < r.n; ++i) {
        int g = clocks_runGlyph(r, i);
        w += ((g < 0) ? CLK_SPACE : dot(clocks_adv(A, max(g, 0)), fw)) + track;
    }
    return max(w - track, 0.0);
}
/// Distance (caps) to a run whose pen starts at the origin.
static inline float clocks_runDist(texture2d<float> A, sampler s, thread const ClkRun& r, float4 fw,
                                   float track, float2 q) {
    if (q.y < -1.75 || q.y > 0.75) return CLK_FAR;
    float d = CLK_FAR, pen = 0.0;
    for (int i = 0; i < r.n; ++i) {
        int g = clocks_runGlyph(r, i);
        float adv = (g < 0) ? CLK_SPACE : dot(clocks_adv(A, max(g, 0)), fw);
        if (g >= 0 && q.x > pen - 0.5 && q.x < pen + adv + 0.5)
            d = min(d, clocks_gdist(A, s, clocks_glyph(A, g), q - float2(pen, 0.0), fw));
        pen += adv + track;
    }
    return d;
}

// ============================================================ time
struct ClkTime { float h, m, s; };
static inline ClkTime clocks_time(float4 c) {
    ClkTime t;
    t.h = clamp(floor(c.x), 0.0, 23.0);
    t.m = clamp(floor(c.y), 0.0, 59.0);
    t.s = clamp(c.z, 0.0, 59.999);
    return t;
}
static inline float clocks_hour12(float h) { float x = fmod(h, 12.0); return x < 0.5 ? 12.0 : x; }
static inline float clocks_ease(float x) { x = clamp(x, 0.0, 1.0); return x * x * (3.0 - 2.0 * x); }
static inline float clocks_easeOut(float x) { x = clamp(x, 0.0, 1.0); return 1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x); }

/// Direction the light comes from (y down, unit) — it travels with the sun: low from the left in
/// the morning, overhead at noon, low from the right in the evening; a slow sway keeps it alive.
static inline float2 clocks_sunDir(float hour, float t) {
    float a = clamp((hour - 6.0) / 12.0, 0.0, 1.0);
    float ang = (212.0 + 116.0 * a + 4.0 * sin(t * 0.05)) * 0.0174533;
    return float2(cos(ang), sin(ang));
}

// ============================================================ TYPE CLOCK
//  Slots: hour tens, hour ones, colon, minute tens, minute ones, [second tens, second ones].
//  Each slot carries its outgoing and incoming glyph; a change morphs one distance field into
//  the other while both glide up a touch, softly blurred mid-way.
struct ClkTypeLayout {
    int   gOld[7], gNew[7];
    float x[7];          // slot centre (caps)
    float k[7];          // slot scale (1 = main figures)
    float e[7];          // transition progress 0 → 1 (1 = settled)
    int   n;
    float width;
};

static inline float clocks_typeSlotsWidth(float w[7], int n) { float s = 0; for (int i = 0; i < n; ++i) s += w[i]; return s; }

static inline ClkTypeLayout clocks_typeLayout(texture2d<float> A, float4 clock, float4 fw, bool h24, bool secs) {
    ClkTime T = clocks_time(clock);
    const float DUR = 0.6, SDUR = 0.42;
    // previous minute / second (what was showing before the last change)
    float pm = T.m - 1.0, ph = T.h;
    if (pm < 0.0) { pm = 59.0; ph = fmod(T.h + 23.0, 24.0); }
    float sNow = floor(T.s), sPrev = fmod(sNow + 59.0, 60.0);
    float eMin = clocks_ease(T.s / DUR);
    float eSec = clocks_ease(fract(T.s) / SDUR);

    float hN = h24 ? T.h : clocks_hour12(T.h), hP = h24 ? ph : clocks_hour12(ph);
    float tabW = dot(clocks_adv(A, 0), fw);
    float colW = dot(clocks_adv(A, CLK_G_COLON), fw);
    const float SK = 0.36;                          // seconds scale

    ClkTypeLayout L;
    L.n = secs ? 7 : 5;
    // glyphs (−1 = blank)
    L.gNew[0] = (h24 || hN >= 10.0) ? int(hN / 10.0) : -1;
    L.gOld[0] = (h24 || hP >= 10.0) ? int(hP / 10.0) : -1;
    L.gNew[1] = int(fmod(hN, 10.0));             L.gOld[1] = int(fmod(hP, 10.0));
    L.gNew[2] = CLK_G_COLON;                     L.gOld[2] = CLK_G_COLON;
    L.gNew[3] = int(T.m / 10.0);                 L.gOld[3] = int(pm / 10.0);
    L.gNew[4] = int(fmod(T.m, 10.0));            L.gOld[4] = int(fmod(pm, 10.0));
    L.gNew[5] = int(sNow / 10.0);                L.gOld[5] = int(sPrev / 10.0);
    L.gNew[6] = int(fmod(sNow, 10.0));           L.gOld[6] = int(fmod(sPrev, 10.0));
    for (int i = 0; i < 7; ++i) {
        bool isSec = i >= 5;
        L.k[i] = isSec ? SK : 1.0;
        L.e[i] = (L.gOld[i] == L.gNew[i]) ? 1.0 : (isSec ? eSec : eMin);
    }
    // widths in the old and new states → centres, interpolated by the hour slot's progress
    float wN[7], wO[7];
    for (int i = 0; i < 7; ++i) {
        float base = (i == 2) ? colW : tabW * L.k[i];
        wN[i] = (L.gNew[i] < 0) ? 0.0 : base;
        wO[i] = (L.gOld[i] < 0) ? 0.0 : base;
    }
    if (secs) { wN[5] += 0.16; wO[5] += 0.16; }    // gap before the seconds
    float WN = clocks_typeSlotsWidth(wN, L.n), WO = clocks_typeSlotsWidth(wO, L.n);
    float xn = -WN * 0.5, xo = -WO * 0.5;
    float eL = L.e[0];
    for (int i = 0; i < L.n; ++i) {
        float cn = xn + wN[i] * 0.5, co = xo + wO[i] * 0.5;
        if (i == 5) { cn += 0.08; co += 0.08; }
        L.x[i] = mix(co, cn, eL);
        xn += wN[i]; xo += wO[i];
    }
    L.width = mix(WO, WN, eL);
    return L;
}

/// Union distance of the time at four probe points at once (shared metric reads):
/// q, q+dx, q+dy and the shadow probe qs. Returns (d, dx, dy, ds) in caps; blur = transition softness.
static inline float4 clocks_typeDist(texture2d<float> A, sampler s, thread const ClkTypeLayout& L,
                                     float4 fw, float bias, float2 q, float eps, float2 qs, thread float& blur) {
    float4 d = float4(CLK_FAR);
    blur = 0.0;
    const float RISE = 0.10;
    for (int i = 0; i < L.n; ++i) {
        float k = L.k[i];
        float cx = L.x[i];
        if (abs(q.x - cx) > 0.95 * k + 0.35 && abs(qs.x - cx) > 0.95 * k + 0.35) continue;
        float e = L.e[i];
        // a change morphs the outgoing figure's field into the incoming one while both glide up
        float4 ds[2];
        for (int st = 0; st < 2; ++st) {
            int g = (st == 0) ? L.gNew[i] : L.gOld[i];
            ds[st] = float4(CLK_FAR);
            if (g < 0 || (st == 1 && e >= 1.0)) continue;
            ClkGlyph G = clocks_glyph(A, g);
            float adv = dot(G.adv, fw);
            float yo = (st == 0) ? RISE * (1.0 - e) : -RISE * e;
            float2 o = float2(cx - adv * 0.5 * k, yo * k);
            ds[st].x = clocks_gdist(A, s, G, (q - o) / k, fw);
            ds[st].y = clocks_gdist(A, s, G, (q + float2(eps, 0) - o) / k, fw);
            ds[st].z = clocks_gdist(A, s, G, (q + float2(0, eps) - o) / k, fw);
            ds[st].w = clocks_gdist(A, s, G, (qs - o) / k, fw);
        }
        float4 dg = (mix(ds[1], ds[0], e) - bias) * k;
        if (dg.x < d.x) blur = sin(3.14159 * e) * 0.035 * k;
        d = min(d, dg);
    }
    return d;
}

/// Soft drifting light for the Glass style (also what the glass refracts).
static inline float3 clocks_glassBg(float2 p, float t, float3 A, float3 B) {
    float ts = t * 0.035;
    float2 c1 = float2(-0.55 + 0.25 * sin(ts * 1.3), -0.18 + 0.16 * cos(ts * 1.1));
    float2 c2 = float2(0.62 + 0.2 * cos(ts * 0.9 + 1.0), 0.24 + 0.14 * sin(ts * 1.4 + 2.0));
    float2 c3 = float2(0.05 + 0.35 * sin(ts * 0.7 + 4.0), 0.42 + 0.1 * cos(ts * 1.2));
    float3 Bl = srgbToOklab(B);
    float3 B2 = oklabToSrgb(oklabHue(Bl, 0.75));
    float3 B3 = oklabToSrgb(oklabHue(Bl, -0.6));
    float3 col = A * (1.0 - 0.35 * dot(p, p));
    col += B  * 0.60 * exp(-dot(p - c1, p - c1) * 3.0);
    col += B2 * 0.42 * exp(-dot(p - c2, p - c2) * 3.6);
    col += B3 * 0.30 * exp(-dot(p - c3, p - c3) * 5.0);
    return col;
}

// ============================================================ FLIP CLOCK
//  Card-local space: card height = 1, x right, y UP, z toward the viewer, hinge on y = 0.
constant float CLK_FLIP_W   = 0.70;      // card width / height
constant float CLK_FLIP_R   = 0.07;      // corner radius
constant float CLK_FLIP_GAP = 0.0055;    // half the hinge slit
constant float CLK_FLIP_CAP = 0.60;      // numeral cap height

static inline float clocks_rrect(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
/// Signed distance to the upper half-card (a flap), y measured up from the hinge.
static inline float clocks_flapShape(float2 f) {
    return max(clocks_rrect(f - float2(0.0, 0.25), float2(CLK_FLIP_W * 0.5, 0.25), CLK_FLIP_R),
               CLK_FLIP_GAP - f.y);
}
/// Flap angle (radians) e seconds after release: a gravity fall, then a small damped bounce.
static inline float clocks_flapAngle(float e) {
    const float T = 0.32;
    if (e <= 0.0) return 0.0;
    if (e < T) { float s = e / T; return 3.14159265 * s * s; }
    float b = e - T;
    return 3.14159265 - 0.17 * exp(-b * 12.0) * abs(sin(b * 24.0));
}
/// Numeral distance (card units) of glyph g at card point xy (centred on the hinge).
static inline float clocks_cardInk(texture2d<float> A, sampler s, int g, float2 xy, float4 fw, float bias) {
    if (g < 0) return 1.0;
    ClkGlyph G = clocks_glyph(A, g);
    float adv = dot(G.adv, fw);
    float2 q = float2(xy.x / CLK_FLIP_CAP + adv * 0.5, -0.5 - xy.y / CLK_FLIP_CAP);
    return (clocks_gdist(A, s, G, q, fw) - bias) * CLK_FLIP_CAP;
}

// ============================================================ WORD CLOCK
//  An original 16 × 11 grid. Phrases read "IT IS [JUST AFTER | NEARLY] <minutes> PAST|TO <hour>
//  [O'CLOCK] [IN THE MORNING | AFTERNOON | EVENING | AT NIGHT]" — the qualifiers give the time
//  to the minute without corner dots. Lower-case letters are unlit filler.
constant char CLK_WGRID[11][17] = {
    "ITlISwJUSTxAFTER",
    "zNEARLYoTWENTYpu",
    "FIVEnTENsQUARTER",
    "HALFbPASTgTOwONE",
    "vTWOdTHREEyFOURk",
    "rFIVEjSIXqSEVENb",
    "EIGHTcNINEkwTENz",
    "hELEVENtTWELVEsq",
    "OCLOCKbINmTHEyAT",
    "fMORNINGuEVENING",
    "AFTERNOONzpNIGHT" };
// word id → (row, col, length); ids are bits of the lit mask, roughly in reading order
constant uchar3 CLK_WORDS[32] = {
    uchar3(0, 0, 2), uchar3(0, 3, 2), uchar3(0, 6, 4), uchar3(0, 11, 5),         // IT IS JUST AFTER
    uchar3(1, 1, 6), uchar3(1, 8, 6),                                             // NEARLY TWENTY
    uchar3(2, 0, 4), uchar3(2, 5, 3), uchar3(2, 9, 7),                            // FIVE TEN QUARTER
    uchar3(3, 0, 4), uchar3(3, 5, 4), uchar3(3, 10, 2),                           // HALF PAST TO
    uchar3(3, 13, 3), uchar3(4, 1, 3), uchar3(4, 5, 5), uchar3(4, 11, 4),         // ONE TWO THREE FOUR
    uchar3(5, 1, 4), uchar3(5, 6, 3), uchar3(5, 10, 5),                           // FIVE SIX SEVEN
    uchar3(6, 0, 5), uchar3(6, 6, 4), uchar3(6, 12, 3),                           // EIGHT NINE TEN
    uchar3(7, 1, 6), uchar3(7, 8, 6),                                             // ELEVEN TWELVE
    uchar3(8, 0, 6), uchar3(8, 7, 2), uchar3(8, 10, 3), uchar3(8, 14, 2),         // OCLOCK IN THE AT
    uchar3(9, 1, 7), uchar3(9, 9, 7), uchar3(10, 0, 9), uchar3(10, 11, 5) };      // MORNING EVENING AFTERNOON NIGHT

static inline uint clocks_wordMask(float hour, float minute, bool period) {
    int mi = int(minute), r = mi % 5, mm = mi - r, hh = int(hour);
    uint m = 0x3u;                                                  // IT IS
    if (r == 1 || r == 2) m |= 0xCu;                                // JUST AFTER
    else if (r >= 3) { m |= 0x10u; mm += 5; }                       // NEARLY (the next five)
    if (mm == 60) { mm = 0; hh = (hh + 1) % 24; }
    int ref = (mm > 30) ? (hh + 1) % 24 : hh;
    const uint FIVE = 1u << 6, TEN = 1u << 7, QUARTER = 1u << 8, TWENTY = 1u << 5;
    const uint HALF = 1u << 9, PAST = 1u << 10, TO = 1u << 11;
    switch (mm) {
        case 5:  m |= FIVE | PAST; break;
        case 10: m |= TEN | PAST; break;
        case 15: m |= QUARTER | PAST; break;
        case 20: m |= TWENTY | PAST; break;
        case 25: m |= TWENTY | FIVE | PAST; break;
        case 30: m |= HALF | PAST; break;
        case 35: m |= TWENTY | FIVE | TO; break;
        case 40: m |= TWENTY | TO; break;
        case 45: m |= QUARTER | TO; break;
        case 50: m |= TEN | TO; break;
        case 55: m |= FIVE | TO; break;
        default: m |= 1u << 24; break;                              // O'CLOCK
    }
    int h12 = ref % 12; if (h12 == 0) h12 = 12;
    m |= 1u << (11 + h12);
    int now = int(hour);                                            // the period follows the real hour
    if (period && !(mm == 0 && (ref == 0 || ref == 12))) {          // no "twelve o'clock in the afternoon"
        if (now >= 5 && now < 12)       m |= (1u << 25) | (1u << 26) | (1u << 28);
        else if (now >= 12 && now < 17) m |= (1u << 25) | (1u << 26) | (1u << 30);
        else if (now >= 17 && now < 21) m |= (1u << 25) | (1u << 26) | (1u << 29);
        else                            m |= (1u << 27) | (1u << 31);
    }
    return m;
}

// ============================================================ WINDOW LIGHT
//  Sunlight through a four-pane window falls on a plaster wall; leaves outside sway in it.
//  The patch rides the real sun: low from the east in the morning, sliding across and
//  lengthening the other way toward evening; after dark a dim, cool moonlit patch remains.

/// Returns the sun on the wall at p (screen-height units, y down): x = direct light 0..1,
/// y = a wide soft version of the patch (bloom / bounce).
static inline float2 clocks_windowLight(float2 p, float day, float t, float leaves, float sway, float aspect) {
    // patch placement from the time of day (0 = sunrise, 1 = sunset)
    float2 c = float2(mix(0.42, -0.40, day) * aspect, mix(-0.02, 0.06, 4.0 * day * (1.0 - day)));
    float k = mix(-0.75, 0.75, day);                               // shear: the sun's azimuth
    float w = 0.50 + 0.10 * abs(k), h = 0.86;
    float2 l = p - c;
    float2 uv = float2((l.x - k * l.y) / w, l.y / h) + 0.5;
    // soft rectangle + mullions; the penumbra widens away from the sill (bottom edge)
    float soft = 0.008 + 0.03 * (1.0 - clamp(uv.y, 0.0, 1.0));
    float2 e = (abs(uv - 0.5) - 0.5) * float2(w, h);
    float rect = smoothstep(soft, -soft, max(e.x, e.y));
    float mull = min(abs(uv.x - 0.5) * w, abs(uv.y - 0.47) * h) - 0.012;
    float frame = smoothstep(-soft, soft, mull);
    float wide = smoothstep(0.22, -0.10, max(e.x, e.y));
    if (rect * frame < 0.002 || leaves < 0.001) return float2(rect * frame, wide);
    // leaves: a canopy edge drifting in from one side, dappled, swaying
    float ts = t * 0.35 * sway;
    float2 q = p * 2.6 + float2(0.05 * sin(ts + p.y * 3.0), 0.04 * cos(ts * 0.8 + p.x * 2.0));
    q += 0.06 * float2(gnoise(float2(ts * 0.6, 1.7)), gnoise(float2(3.1, ts * 0.5)));
    float canopy = smoothstep(-0.30, 0.15, gfbm(q * 0.45 + float2(3.0, 7.0), 2) - 0.30 * (uv.y - 0.35) + 0.25 * (uv.x - 0.5) * sign(k));
    // leaf clusters with crisp-ish dapples (near leaves) over a softer mass (far ones)
    float lf = gfbm(q * 1.9 + float2(11.0, 4.0), 4) + 0.22 * gnoise(q * 9.0 + ts * 0.15);
    float leaf = smoothstep(-0.06, 0.02, lf) * 0.85 + 0.15 * smoothstep(-0.3, 0.2, lf);
    float shade = 1.0 - leaves * canopy * leaf;
    return float2(rect * frame * shade, wide);
}
