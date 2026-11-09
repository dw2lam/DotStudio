//  Clocks_funcs.h — file-scope Metal helpers for the Clocks pack. Included by Shaders.metal
//  right above fx_fragment (shared helpers such as gfbm, luma, bandDither are visible).
//  Prefix every function/constant with "clocks_" so packs can't collide.
//
//  Type comes from TextAtlas.swift: signed distance fields of the system faces, one plane per
//  face the scene uses (0 SF Pro Light, 1 SF Pro Bold, 2 New York, 3 SF Pro Rounded), picked
//  by a one-hot weight vector `fw` (clocks_face). Layout here works in "caps": 1.0 = the cap
//  height of the run, x right, y DOWN, origin at the pen on the baseline.

// ============================================================ atlas access
constant float CLK_SPREAD = 0.125;     // TextAtlas.spreadFrac
constant float CLK_CAP    = 0.5;       // TextAtlas.capFrac
constant float CLK_BASE   = 0.72;      // TextAtlas.baseFrac
constant float CLK_BIGH   = 512.0;     // TextAtlas.bigH (glyphs 0–10; the rest are smallH = 128)
constant float CLK_SMALLH = 128.0;
constant float CLK_ADVS   = 8192.0;    // TextAtlas.advScale
constant float CLK_FAR    = 0.25;      // reach of the field, in caps (SPREAD / CAP)
constant float CLK_SPACE  = 0.30;      // word space, in caps

constant int CLK_G_COLON = 10, CLK_G_A = 11, CLK_G_D0 = 37, CLK_G_COMMA = 47, CLK_G_PERIOD = 48,
             CLK_G_APOS = 49, CLK_G_MIDDOT = 50, CLK_G_DASH = 51, CLK_G_a = 54;

struct ClkGlyph {
    float2 org;      // atlas texel of the pen origin on the baseline, in the face's plane
    float4 box;      // usable cell, caps relative to the pen: (left, top, right, bottom)
    float  tpc;      // atlas texels per cap
    float4 adv;      // advance in caps, per face
};

/// Metrics quad q of the atlas (four integers, see TextAtlas.swift), in one gather.
static inline float4 clocks_quad(texture2d<float> A, int q) {
    constexpr sampler gs(coord::normalized, filter::nearest, address::clamp_to_edge);
    float2 sz = float2(A.get_width(), A.get_height());
    return round(A.gather(gs, float2(2.0 * float(q) + 1.0, sz.y - 1.0) / sz) * 65535.0);
}

static inline ClkGlyph clocks_glyph(texture2d<float> A, int g, float4 fw) {
    float4 r = clocks_quad(A, g);                       // cellX, cellY, cellW, originX
    float plane = dot(clocks_quad(A, 255), fw);         // top row of the face's plane
    float h = (g <= CLK_G_COLON) ? CLK_BIGH : CLK_SMALLH;
    ClkGlyph o;
    o.tpc = h * CLK_CAP;
    o.org = float2(r.x + r.w, plane + r.y + CLK_BASE * h);
    o.box = float4(1.0 - r.w, 1.0 - CLK_BASE * h, r.z - r.w - 1.0, (1.0 - CLK_BASE) * h - 1.0) / o.tpc;
    o.adv = clocks_quad(A, 128 + g) / CLK_ADVS;
    return o;
}

/// Advance (caps, per face) of glyph g — one gather.
static inline float4 clocks_adv(texture2d<float> A, int g) {
    return clocks_quad(A, 128 + g) / CLK_ADVS;
}

/// Signed distance (caps, + outside) of glyph G at q (caps from its pen origin). (The face is
/// already in G: fw is kept for the call sites.)
static inline float clocks_gdist(texture2d<float> A, sampler s, ClkGlyph G, float2 q, float4 fw) {
    if (q.x < G.box.x || q.y < G.box.y || q.x > G.box.z || q.y > G.box.w) return CLK_FAR;
    float2 t = (G.org + q * G.tpc) / float2(A.get_width(), A.get_height());
    float v = A.sample(s, t, level(0.0)).x;            // explicit LOD: safe in divergent loops
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
            d = min(d, clocks_gdist(A, s, clocks_glyph(A, g, fw), q - float2(pen, 0.0), fw));
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

// ============================================================ surface grain
/// Gradient noise with its derivative: (value ~[-0.7, 0.7], d/dx, d/dy). Integer-hashed (no
/// sin; the four corners share their row/column products, one multiply each to finish), so
/// the full-screen plaster and paper grain stay cheap at 5K.
static inline float2 clocks_grad(uint h) {
    h ^= h >> 15u; h *= 0x2c1b3c6du; h ^= h >> 13u;
    return float2(float(h & 0xffffu), float(h >> 16u)) * (2.0 / 65535.0) - 1.0;
}
static inline float3 clocks_noised(float2 x) {
    float2 i = floor(x), f = x - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    uint2 c = uint2(int2(i) + int2(1 << 20));
    uint x0 = c.x * 0x8da6b343u, x1 = x0 + 0x8da6b343u;
    uint y0 = c.y * 0xd8163841u, y1 = y0 + 0xd8163841u;
    float2 ga = clocks_grad(x0 ^ y0), gb = clocks_grad(x1 ^ y0);
    float2 gc = clocks_grad(x0 ^ y1), gd = clocks_grad(x1 ^ y1);
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k = va - vb - vc + vd;
    return float3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                  ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
                     + du * (u.yx * k + float2(vb, vc) - va));
}
/// Value-only grain in [-0.5, 0.5]: one hash per corner, smoothstep blend (paper tooth).
static inline float clocks_grain(float2 x) {
    float2 i = floor(x), f = x - i;
    f = f * f * (3.0 - 2.0 * f);
    uint2 c = uint2(int2(i) + int2(1 << 20));
    uint x0 = c.x * 0x8da6b343u, x1 = x0 + 0x8da6b343u;
    uint y0 = c.y * 0xd8163841u, y1 = y0 + 0xd8163841u;
    float4 h = float4(clocks_grad(x0 ^ y0).x, clocks_grad(x1 ^ y0).x, clocks_grad(x0 ^ y1).x, clocks_grad(x1 ^ y1).x);
    return 0.5 * mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

// ============================================================ TYPE CLOCK
//  Slots: hour tens, hour ones, colon, minute tens, minute ones, [second tens, second ones].
//  Each slot carries its outgoing and incoming glyph. A change never blends the two shapes
//  (a morphed distance field crumples): the outgoing figure sinks back into the surface —
//  relief flattening, glass melting flat, ink fading out of focus — while drifting up a touch,
//  and the incoming one rises out of it, the two overlapping mid-way like real surfaces.
struct ClkTypeLayout {
    int   gOld[7], gNew[7];
    float x[7];          // slot centre (caps)
    float k[7];          // slot scale (1 = main figures)
    float e[7];          // transition progress 0 → 1, linear in time (1 = settled)
    int   n;
    float width;
};

static inline float clocks_typeSlotsWidth(float w[7], int n) { float s = 0; for (int i = 0; i < n; ++i) s += w[i]; return s; }

static inline ClkTypeLayout clocks_typeLayout(texture2d<float> A, float4 clock, float4 fw, bool h24, bool secs) {
    ClkTime T = clocks_time(clock);
    const float DUR = 1.1, SDUR = 0.55;
    // previous minute / second (what was showing before the last change)
    float pm = T.m - 1.0, ph = T.h;
    if (pm < 0.0) { pm = 59.0; ph = fmod(T.h + 23.0, 24.0); }
    float sNow = floor(T.s), sPrev = fmod(sNow + 59.0, 60.0);
    float eMin = clamp(T.s / DUR, 0.0, 1.0);
    float eSec = clamp(fract(T.s) / SDUR, 0.0, 1.0);

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
    float eL = clocks_ease(L.e[0]);
    for (int i = 0; i < L.n; ++i) {
        float cn = xn + wN[i] * 0.5, co = xo + wO[i] * 0.5;
        if (i == 5) { cn += 0.08; co += 0.08; }
        L.x[i] = mix(co, cn, eL);
        xn += wN[i]; xo += wO[i];
    }
    L.width = mix(WO, WN, eL);
    return L;
}

/// Presence (0 gone … 1 standing) of a slot's incoming (st 0) or outgoing (st 1) figure at
/// transition progress e: the old one sinks over the first half, the new one rises over the
/// last three quarters — a breath of overlap, never two half-figures muddled together.
static inline float clocks_typePresence(int st, float e) {
    return (st == 0) ? clocks_ease((e - 0.25) / 0.75) : 1.0 - clocks_ease(e / 0.5);
}

/// Profile height 0 → 1 inward from the silhouette over width w (caps): a rounded bevel
/// shoulder (relief) or a circular rod (glass).
static inline float clocks_typeProfile(float d, float w, bool rod) {
    float x = clamp(-d / w, 0.0, 1.0);
    return rod ? sqrt(max(1.0 - (1.0 - x) * (1.0 - x), 0.0)) : 1.0 - pow(1.0 - x, 2.4);
}

/// The figures as a surface, at pixel q (caps). `top` is the topmost figure there (or the
/// nearest one, off the figures), everything else is a union over every standing figure.
struct ClkTypeField {
    float  d;        // top figure: signed distance (caps, + outside)
    float2 g;        //             outward gradient: unit, fading to 0 on a stroke's crest
    float  pres;     //             presence 0..1
    float  m;        // the figures' share of the pixel (anti-aliased, × presence)
    float  shadow;   // shadow they cast on the ground 0..1 (penumbra hardens toward contact)
    float  caus;     // light a glass figure focuses inside its shadow 0..1
    float  ao;       // contact darkening around their feet 0..1
    float  dim;      // the top figure is a seconds figure
};

/// `sh` = shadow offset (caps, toward the light) of a standing figure, `pen` its penumbra,
/// `aw` the edge half-width (≥ half a pixel), `pw` the profile width, `blurK` how far a
/// leaving figure goes out of focus.
static inline ClkTypeField clocks_typeField(texture2d<float> A, sampler s, thread const ClkTypeLayout& L,
                                            float4 fw, float bias, float2 q, float eps, float2 sh,
                                            float pen, float aw, float pw, bool rod, float blurK) {
    ClkTypeField F;
    F.d = CLK_FAR; F.g = float2(0.0); F.pres = 0.0; F.m = 0.0;
    F.shadow = 0.0; F.caus = 0.0; F.ao = 0.0; F.dim = 0.0;
    // The top surface and the runner-up: where two figures cross mid-change the surface is
    // filleted between them over KF (in height units) instead of creasing — a hard switch
    // there drew aliased dotted seams in the glass.
    float best = -1e9, best2 = -1e9;
    float d2 = CLK_FAR, pres2 = 0.0; float2 g2 = float2(0.0);
    const float KF = 0.08;
    float shl = max(length(sh), 1e-4);
    const float RISE = 0.06;
    for (int i = 0; i < L.n; ++i) {
        float k = L.k[i];
        float cx = L.x[i];
        float reach = 0.95 * k + 0.35;
        if (abs(q.x - cx) > reach && abs(q.x + sh.x * k - cx) > reach) continue;
        float e = L.e[i];
        for (int st = 0; st < 2; ++st) {
            int g = (st == 0) ? L.gNew[i] : L.gOld[i];
            if (g < 0 || (st == 1 && e >= 1.0)) continue;
            float pr = clocks_typePresence(st, e);
            if (pr <= 0.002) continue;
            ClkGlyph G = clocks_glyph(A, g, fw);
            float adv = dot(G.adv, fw);
            float ee = clocks_ease(e);
            float yo = (st == 0) ? RISE * (1.0 - ee) : -RISE * ee;
            float2 o = float2(cx - adv * 0.5 * k, yo * k);
            float d0 = (clocks_gdist(A, s, G, (q - o) / k, fw) - bias) * k;
            // central differences: the gradient's length drops smoothly to 0 across a stroke's
            // crest (forward differences flipped its direction there pixel by pixel)
            float2 qo = (q - o) / k, ex = float2(eps / k, 0.0), ey = float2(0.0, eps / k);
            float2 gr = float2(clocks_gdist(A, s, G, qo + ex, fw) - clocks_gdist(A, s, G, qo - ex, fw),
                               clocks_gdist(A, s, G, qo + ey, fw) - clocks_gdist(A, s, G, qo - ey, fw)) * (k / (2.0 * eps));
            gr *= 1.0 / max(length(gr), 1.0);
            float ds = (clocks_gdist(A, s, G, (q + sh * (pr * k) - o) / k, fw) - bias) * k;   // small figures stand off less

            float soft = aw + (1.0 - pr) * blurK * k;
            F.m = max(F.m, smoothstep(soft, -soft, d0) * pr);
            // topmost surface wins (inside: presence × profile height; outside: the nearest)
            float key = (d0 < 0.0) ? pr * clocks_typeProfile(d0, pw * k, rod) + 1e-4 : -d0;
            if (key > best) {
                best2 = best; d2 = F.d; g2 = F.g; pres2 = F.pres;
                best = key;
                F.d = d0; F.g = gr; F.pres = pr;
                F.dim = (i >= 5) ? 1.0 : 0.0;
            } else if (key > best2) {
                best2 = key; d2 = d0; g2 = gr; pres2 = pr;
            }
            // contact-hardening shadow: sharp at the figure's foot, softer the further it falls
            float far = clamp(max(d0, 0.0) / (shl * k), 0.25, 1.5);
            float pe = (0.004 + pen * far) * k * mix(0.6, 1.0, pr);
            F.shadow = max(F.shadow, pr * smoothstep(pe, -pe, ds));
            // focused light: a soft line down the middle of a stroke's shadow, not a lighter copy of it
            F.caus = max(F.caus, pr * smoothstep(-0.025 * k, -0.068 * k, ds) * smoothstep(-0.14 * k, -0.078 * k, ds));
            F.ao = max(F.ao, pr * exp(-max(d0, 0.0) / (0.035 * k)));
        }
    }
    // fillet toward the runner-up only where both are figures (inside) and close in height
    if (best2 > 0.0 && best - best2 < KF) {
        float w = (0.5 - 0.5 * (best - best2) / KF) * saturate(best2 * 50.0);   // 0.5 on the seam → 0 at KF apart
        F.d = mix(F.d, d2, w); F.g = mix(F.g, g2, w); F.pres = mix(F.pres, pres2, w);
    }
    return F;
}

/// Soft drifting light for the Glass style (also what the glass refracts). B2, B3: hue turns of B.
static inline float3 clocks_glassBg(float2 p, float t, float3 A, float3 B, float3 B2, float3 B3) {
    float ts = t * 0.035;
    float2 c1 = float2(-0.55 + 0.25 * sin(ts * 1.3), -0.18 + 0.16 * cos(ts * 1.1));
    float2 c2 = float2(0.62 + 0.2 * cos(ts * 0.9 + 1.0), 0.24 + 0.14 * sin(ts * 1.4 + 2.0));
    float2 c3 = float2(0.05 + 0.35 * sin(ts * 0.7 + 4.0), 0.42 + 0.1 * cos(ts * 1.2));
    // lights add like light on a dark ground and "screen" on a light one, so a pale backdrop
    // takes their colour instead of blowing out to white
    float3 col = A * (1.0 - 0.35 * dot(p, p));
    col += (1.0 - 0.85 * col) * B  * 0.60 * exp(-dot(p - c1, p - c1) * 3.0);
    col += (1.0 - 0.85 * col) * B2 * 0.42 * exp(-dot(p - c2, p - c2) * 3.6);
    col += (1.0 - 0.85 * col) * B3 * 0.30 * exp(-dot(p - c3, p - c3) * 5.0);
    return col;
}

/// What the glass mirrors (r = reflected view ray, z toward the viewer): the backdrop it lies
/// on below the horizon, a dim studio above it, a big soft key light along the sun direction
/// L and a weaker fill opposite. HDR: the key is ~20× the room. `lw` = fwidth of dot(r, L).
static inline float3 clocks_glassEnv(float3 r, float3 L, float3 ground, float3 room, float lw) {
    float up = clamp(r.z, -1.0, 1.0);
    float hz = smoothstep(-0.05, 0.05, up);                       // a soft horizon, never a seam
    float3 env = mix(ground * 0.85, mix(room * 1.25, room * 0.55, max(up, 0.0)), hz);
    float c = dot(r, L);
    // ~10° soft disc, ~19° falloff; where the surface turns faster than a pixel can hold the
    // disc's edge, it is widened and dimmed in step (its energy kept), so a sliver of the
    // highlight on a tight curve fades instead of breaking into bright dots
    float key = smoothstep(0.945 - lw, 0.985 + lw, c) * (0.05 / (0.05 + 2.0 * max(lw - 0.025, 0.0)));
    float3 Lf = normalize(float3(-L.xy, 0.25));
    float fill = smoothstep(0.80, 0.97, dot(r, Lf));
    // the studio wall on the key's side, lit by it: a broad bright band just above the horizon
    // that the rods' shoulders catch as a rim on the lit side
    float side = smoothstep(0.2, 0.9, dot(normalize(r.xy + 1e-5), normalize(L.xy + 1e-5)));
    float wall = side * smoothstep(0.55, 0.12, abs(up - 0.18)) * hz;
    return env + float3(1.0, 0.98, 0.95) * (22.0 * key + 1.6 * wall) + room * (4.0 * fill);
}

// ============================================================ FLIP CLOCK
//  Card-local space: card height = 1, x right, y UP, z toward the viewer, hinge on y = 0.
constant float CLK_FLIP_W   = 0.70;      // card width / height
constant float CLK_FLIP_R   = 0.07;      // corner radius
constant float CLK_FLIP_GAP = 0.0055;    // half the hinge slit
constant float CLK_FLIP_CAP = 0.60;      // numeral cap height
constant float CLK_FLIP_TH  = 0.016;     // flap thickness — it shows as a lit edge when edge-on
constant float CLK_FLIP_AP  = 0.054;     // AM / PM cap height

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
/// What's printed on a card, as a distance (card units) at card point xy (centred on the
/// hinge): numeral g (−1 = blank) and, on the hour card in 12-hour time, a small AM (ap 1) or
/// PM (ap 2) in the upper-left corner, set in the date face (afw, abias).
static inline float clocks_cardInk(texture2d<float> A, sampler s, int g, int ap, float2 xy,
                                   float4 fw, float bias, float4 afw, float abias) {
    float d = 1.0;
    if (g >= 0) {
        ClkGlyph G = clocks_glyph(A, g, fw);
        float adv = dot(G.adv, fw);
        float2 q = float2(xy.x / CLK_FLIP_CAP + adv * 0.5, -0.5 - xy.y / CLK_FLIP_CAP);
        d = (clocks_gdist(A, s, G, q, fw) - bias) * CLK_FLIP_CAP;
    }
    if (ap > 0 && xy.y > 0.33 && xy.y < 0.46 && xy.x < -0.06) {
        ClkRun r = clocks_run();
        clocks_push(r, CLK_G_A + ((ap == 1) ? 0 : 15)); clocks_push(r, CLK_G_A + 12);
        float2 lq = float2(xy.x + 0.265, 0.365 - xy.y) / CLK_FLIP_AP;     // caps, y down
        d = min(d, (clocks_runDist(A, s, r, afw, 0.08, lq) - abias) * CLK_FLIP_AP);
    }
    return d;
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
//  Sunlight through a four-pane window falls on a plaster wall; a leafy branch outside throws
//  its shadow into it. The patch rides the real sun (live position when the renderer has it,
//  else a seasonal day from the date): low from the east in the morning, sliding across and
//  lengthening the other way toward evening; after dark the moon (or the sky's glow) leaves a
//  dim, cool patch.

/// "H:MM" as five slots (h-tens, h, :, m-tens, m); the hour's tens are blank (−1) below ten in
/// 12-hour time.
static inline ClkRun clocks_timeRun(float h, float m, bool h24) {
    float hN = h24 ? h : clocks_hour12(h);
    ClkRun r = clocks_run();
    clocks_push(r, (h24 || hN >= 10.0) ? int(hN / 10.0) : -1);
    clocks_push(r, int(fmod(hN, 10.0)));
    clocks_push(r, CLK_G_COLON);
    clocks_push(r, int(m / 10.0));
    clocks_push(r, int(fmod(m, 10.0)));
    return r;
}

/// Ink coverage of a five-slot time (h-tens, h, :, m-tens, m; glyph −1 = blank) at q (caps,
/// y down, origin on the baseline at x = 0) while it changes from `ro` to `rn`: the run slides
/// from the old layout to the new one (proportional figures move), figures that change fade
/// out (wO) and then in (wN), and figures that stay put stay solid. leftX: the start of a
/// left-set run (caps), or centred when `centered`. endX returns the pen at the end (caps).
static inline float clocks_timeCov(texture2d<float> A, sampler s, thread const ClkRun& ro, thread const ClkRun& rn,
                                   float4 fw, float bias, float track, bool centered, float leftX,
                                   float slide, float wO, float wN, float2 q, float capPx, thread float& endX) {
    float Wo = 0.0, Wn = 0.0;
    for (int i = 0; i < 5; ++i) {
        int go = clocks_runGlyph(ro, i), gn = clocks_runGlyph(rn, i);
        if (go >= 0) Wo += dot(clocks_adv(A, go), fw) + track;
        if (gn >= 0) Wn += dot(clocks_adv(A, gn), fw) + track;
    }
    float po = centered ? -0.5 * (Wo - track) : leftX, pn = centered ? -0.5 * (Wn - track) : leftX;
    float ink = 0.0;
    for (int i = 0; i < 5; ++i) {
        int go = clocks_runGlyph(ro, i), gn = clocks_runGlyph(rn, i);
        float ao = (go < 0) ? 0.0 : dot(clocks_adv(A, go), fw);
        float an = (gn < 0) ? 0.0 : dot(clocks_adv(A, gn), fw);
        float x = mix(po, pn, slide);
        if (q.x > x - 0.5 && q.x < x + max(ao, an) + 0.5) {
            float2 lq = q - float2(x, 0.0);
            if (go == gn) {
                if (gn >= 0) ink = max(ink, clocks_cov(clocks_gdist(A, s, clocks_glyph(A, gn, fw), lq, fw) - bias, capPx));
            } else {
                float c = 0.0;
                if (go >= 0 && wO > 0.0) c += wO * clocks_cov(clocks_gdist(A, s, clocks_glyph(A, go, fw), lq, fw) - bias, capPx);
                if (gn >= 0 && wN > 0.0) c += wN * clocks_cov(clocks_gdist(A, s, clocks_glyph(A, gn, fw), lq, fw) - bias, capPx);
                ink = max(ink, c);
            }
        }
        po += (go < 0) ? 0.0 : ao + track;
        pn += (gn < 0) ? 0.0 : an + track;
    }
    endX = mix(po, pn, slide) - track;
    return ink;
}

/// Signed distance to a leaf blade along +y from its stalk at the origin: a pointed ovate lens
/// (two circle arcs) of length len and width wid, its midrib curved by `bend`.
static inline float clocks_leaf(float2 p, float len, float wid, float bend) {
    float a = 0.5 * len, w = 0.5 * wid;
    float stalk = length(float2(p.x, p.y - clamp(p.y, 0.0, 0.16 * len))) - 0.0011;   // the petiole
    p.x -= bend * p.y * p.y / len;                         // curve the blade
    p.y -= a + 0.12 * len;                                 // a short stalk, then the blade
    p.y *= 1.0 + 0.18 * clamp(p.y / a, -1.0, 1.0);         // widest a little below the middle
    float r = 0.5 * (a * a / w + w), dd = r - w;
    p = abs(p);
    float blade = ((p.y - a) * dd > p.x * a) ? length(p - float2(0.0, a)) : length(p + float2(dd, 0.0)) - r;
    return min(blade, stalk);
}

/// A leafy twig's silhouette at q: x = signed distance (screen units), y = how soft the nearest
/// leaf's shadow is (leaves hang at different depths, so their penumbrae differ). It enters at
/// `base` heading `ang` (radians, y down), runs `len` and curls by `bend`; leaves every ~sp,
/// alternate sides, about ll long, angled off the twig and drooping. The breeze rocks the twig
/// about its base and flutters each leaf on its own.
static inline float2 clocks_twig(float2 q, float2 base, float ang, float len, float bend, float sp,
                                 float ll, float t, float sway, float seed) {
    float a = ang + sway * (0.030 * sin(0.47 * t + seed * 5.1) + 0.012 * sin(1.31 * t + seed * 9.7));
    float2 dir = float2(cos(a), sin(a)), nrm = float2(-dir.y, dir.x);
    float2 l = q - base;
    float u = dot(l, dir), v = dot(l, nrm);
    float uc = clamp(u, 0.0, len);
    float vc = bend * uc * uc / len, sl = 2.0 * bend * uc / len;
    if (u < -1.3 * ll || u > len + 1.3 * ll || abs(v - vc) > 1.3 * ll) return float2(1.0, 1.0);   // out of reach
    float d = length(float2(u - uc, (v - vc) * rsqrt(1.0 + sl * sl))) - mix(0.0042, 0.0014, uc / len);
    float soft = 1.0;
    float2 grav = float2(dir.y, nrm.y);                    // screen-down in twig coordinates
    int i0 = int(floor(u / sp));
    for (int j = -2; j <= 2; ++j) {
        int i = i0 + j;
        if (i < 1) continue;
        float h0 = hash21(float2(float(i), seed)), h1 = hash21(float2(float(i) * 1.7 + 3.0, seed + 11.0));
        float h2 = hash21(float2(float(i) + 9.0, seed * 1.3 + 2.0));
        float ui = (float(i) + 0.35 * (h0 - 0.5)) * sp;
        if (ui > len) continue;
        float vi = bend * ui * ui / len, ti = 2.0 * bend * ui / len;
        float side = ((i & 1) == 0) ? 1.0 : -1.0;
        float2 tdir = normalize(float2(1.0, ti)), tn = float2(-tdir.y, tdir.x);
        float2 ld = normalize(tdir * 0.62 + tn * side * (0.78 + 0.3 * h1));   // ~50° off the twig
        ld = normalize(ld + 0.35 * grav);                                     // droop
        float fl = sway * 0.10 * sin(1.9 * t + h2 * 40.0);                    // flutter
        ld = normalize(ld + fl * float2(-ld.y, ld.x));                        // (small turn)
        float L = ll * (0.72 + 0.5 * h2) * mix(1.0, 0.65, ui / len);
        float2 lp = float2(u - ui, v - vi);
        float2 lq = float2(dot(lp, float2(ld.y, -ld.x)), dot(lp, ld));       // (across, along)
        float dl = clocks_leaf(lq, L, L * (0.36 + 0.10 * h1), 0.12 * side);
        if (dl < d) { d = dl; soft = 0.7 + 0.9 * h0; }
    }
    return float2(d, soft);
}

/// The light on the wall at p (screen-height units, y down) for a light at `day` (0 = rising,
/// 1 = setting): x = direct light 0..1 (through the panes, past the leaves), y = a wide soft
/// version of the patch (bloom / bounce), z = light the leaves let through (it comes out green).
/// px = one pixel; diffuse = extra blur for a diffuse light (moon, sky glow).
static inline float3 clocks_windowLight(float2 p, float day, float t, float leaves, float sway, float aspect,
                                        float px, float diffuse) {
    // patch placement from the time of day
    float2 c = float2(mix(0.42, -0.40, day) * aspect, mix(-0.02, 0.06, 4.0 * day * (1.0 - day)));
    float k = mix(-0.75, 0.75, day);                               // shear: the sun's azimuth
    float w = 0.50 + 0.10 * abs(k), h = 0.86;
    float2 l = p - c;
    float2 uv = float2((l.x - k * l.y) / w, l.y / h) + 0.5;
    // soft rectangle + mullions; the penumbra widens away from the sill (bottom edge)
    float soft = 0.008 + 0.03 * (1.0 - clamp(uv.y, 0.0, 1.0)) + diffuse;
    float2 e = (abs(uv - 0.5) - 0.5) * float2(w, h);
    float rect = smoothstep(soft, -soft, max(e.x, e.y));
    float mull = min(abs(uv.x - 0.5) * w, abs(uv.y - 0.47) * h) - 0.012;
    float frame = smoothstep(-soft, soft, mull);
    float wide = smoothstep(0.22, -0.10, max(e.x, e.y));
    float pane = rect * frame;
    if (pane < 0.002 || leaves < 0.001) return float3(pane, wide, 0.0);
    // the branch outside, in the window's frame of reference, drifting a little against it
    // through the day (it's further away). Each layer's shadow is as soft as its distance makes
    // it: the sun's disc is half a degree wide, so the near twig is crisp and the far ones blur.
    float2 lq = float2(l.x - k * l.y, l.y) + float2(0.10 * (day - 0.5), 0.0);
    float pn = max(0.0035, px) + diffuse, pf = 0.011 + diffuse;
    float occ = 0.0;
    float a0 = smoothstep(0.0, 0.15, leaves), a1 = smoothstep(0.30, 0.50, leaves), a2 = smoothstep(0.60, 0.85, leaves);
    float2 dn = clocks_twig(lq, float2(-0.40, -0.52), 0.62, 0.78, 0.22, 0.040, 0.085, t, sway, 1.0);
    occ = a0 * smoothstep(pn * dn.y, -pn * dn.y, dn.x);
    if (a1 > 0.0) {
        float2 d1 = clocks_twig(lq, float2(0.30, -0.56), 1.95, 0.60, -0.25, 0.036, 0.072, t * 0.8, sway, 2.0);
        occ = max(occ, 0.80 * a1 * smoothstep(pf * d1.y, -pf * d1.y, d1.x));
    }
    if (a2 > 0.0) {
        float2 d2 = clocks_twig(lq, float2(-0.44, 0.10), -0.15, 0.40, 0.30, 0.036, 0.060, t * 0.9, sway, 3.0);
        occ = max(occ, 0.80 * a2 * smoothstep(pf * d2.y, -pf * d2.y, d2.x));
    }
    return float3(pane * (1.0 - 0.93 * occ), wide, pane * occ);
}
