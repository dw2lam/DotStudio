//  Studio2_funcs.h — SAND GARDEN (shader id 68). File-scope helpers; prefix "studio2_".
//
//  A top-down view, with a little perspective, onto a round kinetic sand table: a chrome
//  ball ploughs theta-rho patterns at a steady 2.5 cm/s, ~20 min a sweep, alternating
//  outward and inward. Every frame is a pure function of (t, clock, date) — no state:
//    • each sweep is an Archimedean base spiral r_lin(θ) (outward; inward ones are its
//      mirror, so the ball keeps turning the same way) plus a lobe modulation
//      A·sin(kθ+φ0)·env — rosettes, precessing twists, petal weaves, now and then a plain
//      spiral that wipes the table clean;
//    • a pixel finds the passes near it in O(1) — along its own ray the turns cross in
//      order, so where they pass its radius is closed-form and only the two or three
//      within a footprint are tested — and composites them NEWEST FIRST: each pass's
//      footprint (a U trench + low berms) replaces whatever was under it;
//    • three sweeps deep: the one in progress (cut off at the ball, so the boundary
//      between the new pattern and the old is the ball's own front), the previous one,
//      and the one before, whose relief settles flat over the current sweep. That one
//      only shows through holes in BOTH later sweeps and is gone by the time it drops
//      out, so neither a sweep change nor the hourly wrap ever pops.
//  Relief normals are analytic (profile′(d)·∇d carried through the compositing), self-
//  shadow is a 3-tap march across the top grooves' own 1-D profiles, the sand is Oren–Nayar-
//  like (no specular, no glitter), the walnut is procedural grain under a GGX lacquer, the
//  ball a chrome mirror of a soft room with a window. Lengths are in cm; everything is
//  linear light, tone-mapped once. Cost at 5K ≈ 0.75–0.85 × Black Hole (the groove maths
//  runs in half precision; candidate windows are closed-form, so no turn is tested twice).

constant float STUDIO2_TAU = 6.28318531;
constant float STUDIO2_PI = 3.14159265;
constant float STUDIO2_RS = 40.0;                      // sand radius at the inner wall, cm
constant float STUDIO2_ST[3] = {0.30, 0.62, 1.05};     // self-shadow taps (× groove scale)
// the groove, × groove scale: trench half-width, berm centre, berm half-width; berm height × depth
constant float STUDIO2_TW = 0.52, STUDIO2_BU = 0.62, STUDIO2_BW = 0.30, STUDIO2_BH = 0.20;

struct studio2_Geo {
    float g;                         // groove scale (Groove Width)
    float rs, p, b, Th;              // hub loop radius, pitch, p/2π, sweep end θ (the hub loop ends at 2π)
    float D;                         // trench depth (the profile's other sizes scale with g)
    float fracCap, twK;              // lobe amplitude cap (A·N ≤ 6); twist bound × frac
    float iw, ibw, imk, isp, ip, ib; // reciprocals: trench half-width, berm half-width, mask
                                     // feather, patterned span (θ), pitch, p/2π
    // the groove's cross-section in half precision (cm-scale values; Apple GPUs run half at
    // twice the rate, in half the registers)
    half hg, hD, hiw, hibw, himk, ha;   // ha: the trench's crispness (see studio2_profile)
};

struct studio2_Sweep {
    float chi;                       // +1 outward (φ = θ), −1 inward (φ = −θ, mirrored)
    float k, frac, phi0, tw, shape;  // lobes, amplitude (a fraction of r), phase, twist, bulge
    float reach;                     // how far out (radially, cm) a pass's footprint can reach
    float eA;                        // where (in sweep fraction) the lobes start fading out
    float thf;                       // the front: θ where the ball is (or where it finished)
    float w;                         // relief weight (the settling sweep fades to flat)
};

struct studio2_Acc {
    half T; half2 gT;                // transmittance and its gradient
    half H; half2 gH;                // composited height and its gradient
    half4 top1, top2;                // the two most visible layers: (weight, u, light across, height)
};

// ---------------------------------------------------------------- small helpers

static inline uint studio2_hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
// smoothstep and its derivative; a > b runs it backwards.
static inline float2 studio2_ss(float a, float b, float x) {
    float k = 1.0 / (b - a);
    float t = clamp((x - a) * k, 0.0, 1.0);
    return float2(t * t * (3.0 - 2.0 * t), 6.0 * t * (1.0 - t) * k);
}
// A hash per integer lattice cell (stable at large coordinates, unlike fract(sin) under
// fast-math): the sand's finest grain and speckle, wood pores, brushed-steel lines.
static inline uint studio2_lattice(float2 i) {
    int2 c = int2(i) + int2(0x4000);
    return studio2_hash(uint(c.x) * 0x27d4eb2du + uint(c.y) * 0x165667b1u);
}
// Triangle wave in −1…1 (period 1): a cheap warp for the sine textures.
static inline float studio2_tri(float x) { return abs(fract(x) - 0.5) * 4.0 - 1.0; }
// sRGB → linear, the usual cubic fit (within ~0.5%: plenty for a picked colour, no pow).
static inline float3 studio2_lin(float3 c) { return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); }
// Filmic shoulder: linear to k, then a smooth roll-off to white.
static inline float studio2_shoulder(float x) {
    const float k = 0.56;
    float y = max(x - k, 0.0) * (1.0 / (1.0 - k));
    return min(x, k) + (1.0 - k) * y / (1.0 + y);
}

// ---------------------------------------------------------------- the track

// r(θ) and dr/dθ for a sweep. The base spiral starts with one closed loop at the hub
// (radius rs, θ ∈ [0, 2π]) so the centre is a clean ring, not a polar singularity, then
// eases into an Archimedean spiral of pitch p. The lobes fade in after the hub and out
// before the rim, so every sweep starts and ends on the plain spiral (the ball's path is
// continuous from one sweep to the next); their amplitude is a fraction of the radius.
// The lobe phase ψ(θ) = kθ + φ0 + tw·(θ − θc)/span is linear in θ, so successive turns
// differ by a fixed rotation: the candidate loop rotates (sin ψ, cos ψ) instead of calling
// sincos per turn. (Outside the patterned span the envelope is 0, so ψ there is moot.)
static inline float studio2_psi(thread const studio2_Sweep& s, thread const studio2_Geo& G, float th) {
    return s.k * th + s.phi0 + s.tw * (th - STUDIO2_TAU) * G.isp;
}
// Lobe envelope over the sweep (sn = 0 hub … 1 rim) and its derivative: fades in after the
// hub, out toward the rim (slowly enough that no turn folds back over the one before),
// optionally bulging mid-way.
static inline float2 studio2_env(thread const studio2_Sweep& s, float sn) {
    float2 e1 = studio2_ss(0.03, 0.17, sn), e2 = studio2_ss(0.97, s.eA, sn);
    float sh = 1.0, dsh = 0.0;
    if (s.shape > 0.5) { sh = 0.3 + 2.8 * sn * (1.0 - sn); dsh = 2.8 * (1.0 - 2.0 * sn); }
    return float2(e1.x * e2.x * sh, (e1.y * e2.x + e1.x * e2.y) * sh + e1.x * e2.x * dsh);
}
static inline float2 studio2_trackSC(thread const studio2_Sweep& s, thread const studio2_Geo& G, float th,
                                     float sp, float cp) {
    float x = th - STUDIO2_TAU;
    // the hub loop is an exact circle (θ ∈ [0, 2π]); the spiral eases out of it over a radian
    // either side of θ = 2π + 1, so the loop closes on itself without a seam
    float rp, drp;
    if (x <= 0.0)      { rp = 0.0;           drp = 0.0; }
    else if (x >= 2.0) { rp = x - 1.0;       drp = 1.0; }
    else               { rp = x * x * 0.25;  drp = x * 0.5; }
    float r = G.rs + G.b * rp, dr = G.b * drp;
    if (s.frac > 0.0) {
        float is = G.isp;
        float sn = clamp(x * is, 0.0, 1.0);
        float2 Ev = (s.shape < 0.5 && sn >= 0.17 && sn <= s.eA) ? float2(1.0, 0.0) : studio2_env(s, sn);
        float E = Ev.x, dE = Ev.y * is;
        float Ae = s.frac * r, dAe = s.frac * dr;
        r += Ae * E * sp;
        dr += (dAe * E + Ae * dE) * sp + Ae * E * cp * (s.k + s.tw * is);
    }
    return float2(r, dr);
}
static inline float2 studio2_track(thread const studio2_Sweep& s, thread const studio2_Geo& G, float th) {
    float cp, sp = sincos(studio2_psi(s, G, th), cp);
    return studio2_trackSC(s, G, th, sp, cp);
}

// Track position at θ, and the unit tangent along increasing θ.
static inline float2 studio2_pos(thread const studio2_Sweep& s, thread const studio2_Geo& G, float th,
                                 thread float2& tang) {
    float2 tr = studio2_track(s, G, th);
    float ph = s.chi * th;
    float2 er = float2(cos(ph), sin(ph)), ep = float2(-er.y, er.x);
    tang = normalize(tr.y * er + s.chi * tr.x * ep);
    return tr.x * er;
}

// Pattern for sweep g (deterministic). Pattern menu: 0 Surprise, 1 Rosette, 2 Twist,
// 3 Petals, 4 Spiral. Even sweeps run outward, odd ones inward.
// The sweep's own hash, from its index (callers pass it and the previous sweep's in).
static inline uint studio2_sweepHash(int g) { return studio2_hash(uint(g) * 0x9E3779B9u + 0x51ED27u); }

static inline studio2_Sweep studio2_sweepParams(int g, uint ha, uint hp, int menu, thread const studio2_Geo& G) {
    studio2_Sweep s;
    s.chi = (g & 1) == 0 ? 1.0 : -1.0;
    s.w = 1.0;
    s.thf = s.chi > 0.0 ? G.Th : 0.0;
    uint hb = (ha ^ (ha >> 13)) * 0x2C1B3C6Du;                        // a second, cheaper word
    hb ^= hb >> 16;
    const float k8 = 1.0 / 256.0;
    float h0 = float(ha & 0xffu) * k8, h1 = float((ha >> 8) & 0xffu) * k8, h5 = float(ha >> 16) * (1.0 / 65536.0);
    float h2 = float(hb & 0xffu) * k8, h3 = float((hb >> 8) & 0xffu) * k8, h4 = float((hb >> 16) & 0xffu) * k8;
    float h6 = float(hb >> 24) * k8;
    int type = menu - 1;
    if (menu <= 0 || menu > 4) {
        // Surprise: mostly rosettes and twists, a petal weave now and then, and a plain
        // spiral "erase" as a palate cleanser (never twice running).
        bool erase = h0 < 0.10 && float(hp & 0xffu) * k8 >= 0.10;
        type = erase ? 3 : (h1 < 0.50 ? 0 : (h1 < 0.89 ? 1 : 2));
    }
    // Lobe amplitude is a fraction of the radius (each ring a scaled copy, like a flower),
    // capped so it is at most 6 pitches at the rim (A·N ≤ 6: the candidate set stays small).
    s.phi0 = h5 * STUDIO2_TAU;
    s.k = 4.0; s.tw = 0.0; s.shape = 0.0;
    float frac = 0.0;
    if (type == 0) {                 // rosette: k nested lobes
        s.k = 4.0 + floor(h2 * 5.999);                        // 4…9
        frac = mix(0.11, 0.18, h3) * pow(5.0 / s.k, 0.75);    // flanks no steeper than ~1
        s.shape = h6 > 0.45 ? 1.0 : 0.0;                      // bulge: opens, then closes at the rim
    } else if (type == 1) {          // twist: the lobes precess as they grow
        s.k = 3.0 + floor(h2 * 3.999);                        // 3…6
        frac = mix(0.08, 0.13, h3);
        s.shape = 0.0;
    } else if (type == 2) {          // petals: half-integer lobes, so alternate turns cross
        s.k = 2.5 + floor(h2 * 3.999);                        // 2.5…5.5
        frac = mix(0.05, 0.085, h3);
        s.shape = 0.0;
    }
    s.frac = min(frac, G.fracCap);
    // Successive turns at any angle must stay in order (a "family" never folds over itself):
    // that bounds the twist, and how fast the lobes may shrink into the plain rim spiral.
    if (type == 1) s.tw = (h6 > 0.5 ? 1.0 : -1.0) * min(s.k * mix(0.6, 1.2, h4), G.twK / s.frac);
    s.eA = 0.97 - max(0.13, 2.2 * s.frac * (s.shape > 0.5 ? 0.66 : 1.0));
    // Radial reach of a pass's footprint (its half-width stretched by the steepest flank),
    // for the in-progress sweep's quick reject.
    float slope = s.frac * (s.k + abs(s.tw) * G.isp) + 0.1;
    s.reach = (1.3 * G.g) * (1.0 + 0.5 * slope * slope) + 0.1;   // ≥ √(1 + slope²)
    return s;
}

// ---------------------------------------------------------------- the groove

// Cross-section at distance u ≥ 0 from the ball's path: (height, d height/du), branch-free.
// A crisp U trench, c(x) = (1 − x²)²·(1 + a·x²): a flat floor the ball has pressed, walls
// steepening to ~55° just inside a rounded lip (a double root at x = 1, so it meets the sand
// without a crease); a → 0 softens it toward a plain bowl where a pixel spans a good part
// of the lip (G.ha), so it never aliases. Plus a low berm of pushed-up sand just outside.
static inline half2 studio2_profile(half u, thread const studio2_Geo& G) {
    half x = u * G.hiw, x2 = x * x;
    half q = max(1.0h - x2, 0.0h);
    half e = -G.hD * q * q * (1.0h + G.ha * x2);
    half de = -G.hD * 2.0h * x * q * ((G.ha - 2.0h) - 3.0h * G.ha * x2) * G.hiw;
    half y = (u - half(STUDIO2_BU) * G.hg) * G.hibw;
    half qb = max(1.0h - y * y, 0.0h), B = half(STUDIO2_BH) * G.hD;
    e += B * qb * qb;
    de -= 4.0h * B * y * qb * G.hibw;
    return half2(e, de);
}
// Footprint opacity: the pass fully replaces the sand within Wc (≥ half the pitch, so a
// finished sweep covers everything under it), feathering out to Wo.
static inline half2 studio2_mask(half u, thread const studio2_Geo& G) {
    half t = clamp((u - G.hg) * G.himk, 0.0h, 1.0h);
    return half2(1.0h - t * t * (3.0h - 2.0h * t), -6.0h * t * (1.0h - t) * G.himk);
}

// Composite one pass (signed distance d, gradient gd) under what's already in front of it.
// Heights and their gradients are carried analytically: no re-evaluation for normals.
static inline void studio2_layer(thread studio2_Acc& a, float d, float2 gd, float wgt,
                                 thread const studio2_Geo& G, float2 Lh) {
    half u = half(abs(d));
    half2 gu = half2(d < 0.0 ? -gd : gd);
    half2 m = studio2_mask(u, G);
    half2 p0 = studio2_profile(u, G), pr = p0 * half(wgt);
    half ea = m.x * pr.x, dea = m.y * pr.x + m.x * pr.y;
    a.H += a.T * ea;
    a.gH += a.gT * ea + (a.T * dea) * gu;
    // remember the two most visible layers: their self-shadow is marched afterwards (both
    // where two blend, so the shadow never jumps where one pass's feather crosses another)
    half4 me = half4(a.T * m.x * half(wgt), u, dot(half2(Lh), gu), p0.x);
    if (me.x > a.top1.x) { a.top2 = a.top1; a.top1 = me; }
    else if (me.x > a.top2.x) a.top2 = me;
    a.gT = a.gT * (1.0h - m.x) - (a.T * m.y) * gu;
    a.T *= 1.0h - m.x;
}

// Self-shadow of one layer: three taps toward the light along its own 1-D profile.
// L = (weight, u, light across the groove (signed)).
static inline half studio2_march(half4 L, thread const studio2_Geo& G, float tanEl, float fp) {
    half al = abs(L.z);
    if (L.x < 0.004h || al < 0.03h || G.D < 1e-3) return 1.0h;
    half sg = L.z > 0.0h ? 1.0h : -1.0h;
    half ial = 1.0h / al;
    half kr = half(tanEl) * ial;                                 // ray rise per cm across
    half e0 = L.w;
    half pk = half(1.4 * fp) * kr + 0.01h * G.hg;
    half vis = 1.0h;
    for (int i = 0; i < 3; ++i) {
        half st = half(STUDIO2_ST[i]) * G.hg;
        half eo = studio2_profile(abs(L.y + sg * st), G).x;
        half gap = e0 + st * kr - eo;                            // ray height over the occluder
        half pen = 0.10h * st * ial + pk;                        // window penumbra + pixel
        vis = min(vis, smoothstep(-pen, pen, gap));
    }
    return vis;
}

// Composite every pass of sweep s near the pixel, newest first. Ef/Tf: the sweep's front
// (where the ball is or stopped) and its tangent. Passes beyond the front don't exist yet;
// the one that reaches it ends in the ball's own round front (a cap: distance to Ef).
static inline void studio2_sweepComposite(thread studio2_Acc& a, thread const studio2_Sweep& s,
                                          thread const studio2_Geo& G, float2 x, float r, float phi,
                                          float2 er, float2 ep, float2 Ef, float2 Tf, float2 Lh, float ir) {
    if (a.T < 0.01) return;
    // Nothing of a sweep in progress reaches past its front's radius (out) or inside it (in).
    float rf = G.rs + G.b * max(s.thf - STUDIO2_TAU - 1.0, 0.0);
    if (s.chi > 0.0 ? r > rf * (1.0 + s.frac) + s.reach : r < rf * (1.0 - s.frac) - s.reach) return;
    float th0 = fract(s.chi * phi * (1.0 / STUDIO2_TAU)) * STUDIO2_TAU;          // [0, 2π)
    float thStart = s.chi > 0.0 ? 0.0 : G.Th;
    float2 v = x - Ef;
    float lv = length(v);
    bool ahead = dot(v, Tf) * s.chi > 0.0;                                       // past the front
    // The front first — the round end the ball leaves is this sweep's newest sand.
    if (ahead && lv < (1.3 * G.g)) {
        studio2_layer(a, lv, v / max(lv, 1e-4), s.w, G, Lh);
        if (a.T < 0.01) return;
    }
    // Candidate turns, O(1): at this pixel's angle the turns of a "family" (every turn for
    // whole k; alternate turns for half-integer k, whose neighbours mirror each other) cross
    // the pixel's ray in order, ρ(n) ≈ r_b(n)·(1 + frac·E·sin ψ_n) with sin ψ_n constant along
    // a family (a twist drifts it slowly), so where a family passes radius r is closed-form,
    // and only the turns within a footprint of that are tested.
    float isp = G.isp, kk = s.k + s.tw * isp;
    float nMax = (G.Th + STUDIO2_PI - th0) * (1.0 / STUDIO2_TAU);              // turns beyond: skipped below
    int F = (s.frac > 0.0 && fract(s.k) > 0.25) ? 2 : 1;
    float psi0 = s.k * th0 + s.phi0 + s.tw * (th0 - STUDIO2_TAU) * isp;          // ψ at turn 0
    float dpr = STUDIO2_TAU * float(F) * s.tw * isp;                             // ψ per family step (mod 2π)
    float nu = 1.0 + (1.0 + (r - G.rs) * G.ib - th0) * (1.0 / STUDIO2_TAU);   // unmodulated turn at r
    float baseHW = (1.3 * G.g) * 1.05;
    float margin = (dpr != 0.0 ? 0.95 : (F == 2 ? 0.85 : 0.7)) + (r < G.rs + 2.0 * G.p ? 1.0 : 0.0);
    // (where the lobes swell or fade, E itself varies turn to turn: allow for it)
    // family 0: the base radius rb* it crosses r from solves rb·(1 + frac·E(rb)·sin ψ) = r;
    // two fixed-point steps (E, and a twist's phase, change slowly from turn to turn)
    float c0 = 0.0, s0 = 0.0;
    if (s.frac > 0.0) s0 = sincos(psi0 + nu * dpr, c0);
    float fE = 0.0, fEd = 0.0, rbs = r;
    for (int it = 0; it < 2 && s.frac > 0.0; ++it) {
        float2 Ev = studio2_env(s, clamp((1.0 + (rbs - G.rs) * G.ib) * isp, 0.0, 1.0));
        fE = s.frac * Ev.x; fEd = s.frac * Ev.y * STUDIO2_TAU * isp;   // and per turn
        rbs = r / (1.0 + fE * s0);
        if (dpr != 0.0) s0 = sincos(psi0 + (nu + (rbs - r) * G.ip) * dpr, c0);
        else if (fEd == 0.0) break;                                   // on a plateau: converged
    }
    float m = nu + (rbs - r) * G.ip;
    // spacing between successive family members along the ray (the envelope's own slope
    // bunches them where the lobes fade out)
    float dm = max(float(F) * (G.p * (1.0 + fE * s0) + rbs * fEd * s0) + rbs * fE * c0 * dpr, 0.25 * float(F) * G.p);
    margin += min(1.5 * r * abs(fEd) * G.ip, 1.0);
    float bir = G.b * ir + 0.06;                                                 // the spiral's own slope
    float sl = fE * kk * abs(c0) + bir;
    float hw = baseHW * (1.0 + 0.5 * sl * sl) / dm + margin;                     // (1 + sl²/2 ≥ √(1 + sl²))
    float lo0 = max(ceil(m - hw), 0.0), hi0 = floor(min(m + hw, nMax));
    if (F == 2) {                    // even turns only; the odd family mirrors them
        lo0 = max(2.0 * ceil((m - hw) * 0.5), 0.0);
        hi0 = 2.0 * floor(min(m + hw, nMax) * 0.5);
    }
    float lo1 = 1e9, hi1 = -1e9, c1 = 0.0, s1 = 0.0;
    if (F == 2) {
        s1 = sincos(psi0 + STUDIO2_TAU * kk, c1);
        float fE1 = 0.0, fEd1 = 0.0, rb1 = r;
        for (int it = 0; it < 2; ++it) {
            float2 Ev = studio2_env(s, clamp((1.0 + (rb1 - G.rs) * G.ib) * isp, 0.0, 1.0));
            fE1 = s.frac * Ev.x; fEd1 = s.frac * Ev.y * STUDIO2_TAU * isp;
            rb1 = r / (1.0 + fE1 * s1);
            if (fEd1 == 0.0) break;                                   // on a plateau: converged
        }
        float m1 = nu + (rb1 - r) * G.ip;
        float dm1 = max(2.0 * (G.p * (1.0 + fE1 * s1) + rb1 * fEd1 * s1), 0.5 * G.p);
        float sl1 = fE1 * kk * abs(c1) + bir;
        float hw1 = baseHW * (1.0 + 0.5 * sl1 * sl1) / dm1 + margin;
        lo1 = max(2.0 * ceil((m1 - hw1 - 1.0) * 0.5) + 1.0, 1.0);
        hi1 = 2.0 * floor((min(m1 + hw1, nMax) - 1.0) * 0.5) + 1.0;
    }
    // Walk both families' windows merged, newest first (two pointers: no idle steps across
    // the gap between them). Family 0 steps by F turns; family 1 (odd turns) by 2.
    float st = float(F);
    float na = s.chi > 0.0 ? hi0 : lo0, nb = s.chi > 0.0 ? hi1 : lo1;            // next of each
    int cnt0 = max(int((hi0 - lo0) / st) + 1, 0), cnt1 = max(int((hi1 - lo1) * 0.5) + 1, 0);
    int cnt = cnt0 + cnt1;
    // (sin ψ, cos ψ) at family 0's first turn, rotated per step for a twist
    float cd = 1.0, sd = 0.0;
    if (dpr != 0.0) { s0 = sincos(psi0 + na * dpr, c0); sd = sincos(-s.chi * dpr, cd); }
    for (int j = 0; j < cnt; ++j) {
        bool odd = cnt1 > 0 && (cnt0 == 0 || s.chi * (nb - na) > 0.0);
        float n, sp, cp;
        if (odd) { n = nb; sp = s1; cp = c1; nb -= s.chi * 2.0; --cnt1; }
        else {
            n = na; sp = s0; cp = c0; na -= s.chi * st; --cnt0;
            float t2 = s0 * cd + c0 * sd; c0 = c0 * cd - s0 * sd; s0 = t2;   // ready for the next
        }
        float th = th0 + STUDIO2_TAU * n;
        if (s.chi * (th - thStart) < 0.0) continue;                              // before the sweep
        float past = s.chi * (th - s.thf);                                       // > 0: not drawn yet
        // Beyond the front: nothing, except right by the ball and behind its normal line, where
        // the path is extrapolated a couple of cm so the trench meets the cap. Under the cap
        // (ahead of that line, within its reach) the cap stands in for the path's last cm or two.
        // (Arc-length and distance gated: on a steep lobe the path soon swings back, and near
        // the hub the normal line runs on through the centre.)
        float arc = abs(past) * r;
        if (past > 0.0 ? (ahead || arc > 2.0 * G.g || lv > 2.6 * G.g) : (ahead && arc < 2.0 * G.g && lv < 1.3 * G.g)) continue;
        float2 tr = studio2_trackSC(s, G, th, sp, cp);
        float f = tr.x * rsqrt(tr.x * tr.x + tr.y * tr.y);
        float d = (r - tr.x) * f;                                                // ⟂ distance
        if (abs(d) >= (1.3 * G.g)) continue;
        float2 gd = f * (er - (s.chi * tr.y * ir) * ep);
        studio2_layer(a, d, gd, s.w, G, Lh);
        if (a.T < 0.01) return;
    }
}

// ---------------------------------------------------------------- materials

// Oiled walnut, linear albedo. gp = (along the grain, across it), cm; fpw = cm per pixel.
static inline float3 studio2_wood(float2 gp, float3 base, float fpw, float seed) {
    float2 a = gp + seed * float2(37.1, 11.3);
    // growth rings ~0.7 cm apart, wandering slowly along the grain; broad colour figure; fine
    // pore streaks (one hash per long thin cell)
    float wob = 0.9 * sin(a.x * 0.045 + 2.1 + 0.8 * sin(a.y * 0.31)) + 0.35 * studio2_tri(a.x * 0.021 + a.y * 0.16);
    float rp = fract(a.y * 1.45 + wob);
    float late = smoothstep(0.55, 0.84, rp) * (1.0 - smoothstep(0.86, 1.0, rp));
    float ringAA = 1.0 - 0.75 * smoothstep(0.05, 0.13, fpw);
    float fig = 0.5 * sin(a.x * 0.05 + a.y * 0.2 + 1.3 * studio2_tri(a.y * 0.027 - a.x * 0.005));
    float pores = float(studio2_lattice(floor(a * float2(0.7, 11.0))) & 0xffu) * (1.0 / 255.0) - 0.5;
    float poreAA = 1.0 - smoothstep(0.02, 0.045, fpw);
    float3 c = base * (0.86 + 0.36 * fig);
    c *= 1.0 - 0.30 * late * ringAA;
    c *= 1.0 - 0.22 * max(pores, 0.0) * poreAA;
    c = mix(c, c * float3(1.22, 1.08, 0.92), 0.35 * smoothstep(0.05, 0.45, fig));
    return c;
}

// The room as a metal sees it: dim ceiling, warmer walls, the window toward the light,
// the sand below. R = reflected direction (z up); Lh/el = the light.
static inline float3 studio2_room(float3 R, float2 Lh, float el, float3 sunC, float3 skyC, float3 sandLin) {
    float up = R.z;
    float3 c = mix(float3(0.14, 0.125, 0.11), float3(0.035, 0.035, 0.04), smoothstep(0.0, 0.75, up));
    c += skyC * 0.04;
    float2 rh = R.xy * rsqrt(max(dot(R.xy, R.xy), 1e-6));
    float az = 1.0 - dot(rh, Lh), de = asin(clamp(up, -1.0, 1.0)) - el;
    c += sunC * 2.2 * exp(-az * 9.0 - de * de * 28.0);
    float3 dn = sandLin * (sunC * 0.64 + skyC * 0.30);
    return mix(c, dn, smoothstep(0.02, -0.10, up));
}

// The room a chrome ball sees (z up): a white ceiling lit by bounce, walls, a tall window
// toward the light with glazing bars, the sand below with the ball's own shadow straight
// down, and the walnut rim on the horizon. Soft-edged (aa = the reflection's angular change
// per pixel widens the edges), so the window never aliases on a 10 px ball.
static inline float3 studio2_ballEnv(float3 R, float2 Lh, float el, float3 sunC, float3 skyC,
                                     float3 sandRad, float3 woodRad, float aa) {
    float up = clamp(R.z, -1.0, 1.0);
    float elv = up * (1.0 + 0.18 * up * up);                               // ≈ asin
    float2 rh = R.xy * rsqrt(max(dot(R.xy, R.xy), 1e-8));
    float caz = dot(rh, Lh), saz = rh.x * Lh.y - rh.y * Lh.x;             // toward the window: caz = 1
    float az = saz * (1.0 + 0.18 * saz * saz) * sign(caz + 1e-6);          // ≈ angle, near the window
    // walls (the window wall in its own shade) rolling up into a brighter ceiling
    float3 c = float3(0.17, 0.16, 0.15) * (1.0 - 0.3 * caz) + skyC * 0.03;
    c = mix(c, float3(0.30, 0.29, 0.28), smoothstep(0.35, 1.25, elv));
    // the window: soft-edged, sky-bright, with a cross of glazing bars
    float e = 0.035 + aa;
    float wy = elv - (el + 0.24);
    float box = (1.0 - smoothstep(0.46 - e, 0.46 + e, abs(az))) * (1.0 - smoothstep(0.36 - e, 0.36 + e, abs(wy)))
              * step(0.0, caz);
    float bars = max(1.0 - smoothstep(0.012, 0.012 + 1.5 * e, abs(az)), 1.0 - smoothstep(0.012, 0.012 + 1.5 * e, abs(wy)));
    c += (sunC * 6.0 + skyC * 1.5) * box * (1.0 - 0.85 * bars);
    // below the horizon: lit sand, darker straight down and on the ball's shadow side
    float3 fl = sandRad * (1.0 - 0.85 * smoothstep(-0.45, -0.95, up))
                        * (1.0 - 0.45 * smoothstep(0.2, -0.6, caz) * smoothstep(-0.05, -0.5, up));
    float hz = smoothstep(-0.015 - aa, 0.015 + aa, up);
    c = mix(fl, c, hz);
    float rimBand = smoothstep(-0.01 - aa, 0.012 + aa, up) * (1.0 - smoothstep(0.05 - aa, 0.085 + aa, up));
    return mix(c, woodRad, rimBand * 0.85);
}

// ---------------------------------------------------------------- the scene

static inline float4 studio2_scene(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u) {
    float speed = max(u.p0.x, 0.0);
    int menu = int(u.p0.y + 0.5);
    float g = clamp(u.p0.z, 0.5, 2.0);
    bool table = u.p0.w > 0.5;
    float relief = clamp(u.p1.x, 0.0, 1.0);
    bool live = u.p1.w > 0.5 && u.sky.y > 0.5;

    // ---- table geometry (cm). The outermost pass's footprint always ends 1.1 cm short of
    // the wall, where the sand banks up; 2·turns is an integer, so every sweep starts and
    // ends at the same two points and the ball's path joins up.
    studio2_Geo G;
    G.g = g;
    float pt = 1.67 * g;
    G.rs = 0.5 * pt;
    float R0 = STUDIO2_RS - 1.1 - 1.3 * g;
    float Ns = max(round(2.0 * (R0 - G.rs) / pt) * 0.5, 3.0);
    G.Th = STUDIO2_TAU + STUDIO2_TAU * Ns;
    G.b = (R0 - G.rs) / (G.Th - STUDIO2_TAU - 1.0);              // reaches R0 exactly at Θ
    G.p = G.b * STUDIO2_TAU;
    G.isp = 1.0 / (G.Th - STUDIO2_TAU);
    G.fracCap = 6.0 * G.p / R0;
    G.twK = 0.75 * G.p * (G.Th - STUDIO2_TAU) / (STUDIO2_TAU * R0);
    G.D = 0.55 * g * relief;                                     // 3.3 mm at the default relief
    // (a pass's footprint: opaque within g of its path, feathered out to 1.3·g)

    // ---- which sweep, and how far along. A global sweep index from the date and the
    // hour the t origin falls in, so the sequence runs on across the hourly wrap (the
    // outgoing renderer at t ≥ 3600 with the new hour computes the same index) and never
    // repeats hourly. Speed sets sweeps per hour (3 at 1×: P = 1200 s divides the hour).
    int day = int(u.date.x) * 366 + int(u.date.w);
    int hourIx = day * 24 + int(floor((u.clock.x * 3600.0 - t) * (1.0 / 3600.0) + 0.25));
    int gi; float phase;
    if (speed < 0.02) {
        gi = day * 72 + 1; phase = 0.62;
    } else if (speed * 3.0 >= 0.5) {
        int n = clamp(int(round(speed * 3.0)), 1, 9);
        float tp = t * float(n) * (1.0 / 3600.0);
        gi = hourIx * n + int(floor(tp)); phase = fract(tp);
    } else {
        int m = clamp(int(round(1.0 / (3.0 * speed))), 2, 24);
        int hh = hourIx + int(floor(t * (1.0 / 3600.0)));
        gi = hh / m;
        phase = (float(hh - gi * m) + fract(t * (1.0 / 3600.0))) / float(m);
    }
    uint hNow = studio2_sweepHash(gi), hPrev = studio2_sweepHash(gi - 1);
    studio2_Sweep sw0 = studio2_sweepParams(gi, hNow, hPrev, menu, G);
    float R0g = R0;                                              // the outermost turn's radius
    float cTh = fract(Ns) > 0.25 ? -1.0 : 1.0;                   // cos Θ (Θ = 2π(1 + Ns), 2Ns whole)
    float w2 = 1.0 - smoothstep(0.45, 1.0, phase);               // the sweep before last settles flat
    // The ball: constant speed along the base spiral, out on even sweeps, in on odd ones.
    // Arc length in closed form (r ≫ dr/dθ): the hub loop rs·θ, the ease-out rs·x + b·x³/12,
    // then rs·θ + b·((x − 1)²/2 + 1/6), x = θ − 2π — each inverted exactly (one Newton step
    // on the short cubic).
    float Lt = G.rs * G.Th + G.b * (0.5 * (G.Th - STUDIO2_TAU - 1.0) * (G.Th - STUDIO2_TAU - 1.0) + 1.0 / 6.0);
    float sArc = (sw0.chi > 0.0 ? phase : 1.0 - phase) * Lt;
    float hubL = G.rs * STUDIO2_TAU, easeL = G.rs * (STUDIO2_TAU + 2.0) + G.b * (2.0 / 3.0);
    if (sArc <= hubL) sw0.thf = sArc / G.rs;
    else if (sArc <= easeL) {
        float sx = sArc - hubL, xe = sx / G.rs;
        xe -= (G.rs * xe + G.b * xe * xe * xe / 12.0 - sx) / (G.rs + 0.25 * G.b * xe * xe);
        sw0.thf = STUDIO2_TAU + xe;
    } else {
        float z = (sqrt(G.rs * G.rs + 2.0 * G.b * (sArc - G.rs * (STUDIO2_TAU + 1.0) - G.b / 6.0)) - G.rs) / G.b;
        sw0.thf = STUDIO2_TAU + 1.0 + z;
    }

    // ---- camera: straight down from Hc, focal length f (screen height = 1).
    float aspect = res.x / res.y;
    float2 q = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);
    const float f = 3.0;
    float sS, Hc, hTop, eF;
    if (!table) {                    // Fill: the sand circle spans ~0.95 of the diagonal
        hTop = 2.2; eF = 0.55;
        sS = 0.477 * sqrt(aspect * aspect + 1.0) / STUDIO2_RS;
        Hc = f / sS;
    } else {                         // Table: the lip's outer edge 6% in from the frame
        hTop = 2.6; eF = 0.22;
        float sT = 0.44 / (STUDIO2_RS + 0.95);
        Hc = f / sT + hTop;
        sS = f / Hc;
    }
    float fp = 1.0 / (sS * res.y);                               // cm per pixel on the sand
    G.iw = 1.0 / (STUDIO2_TW * g); G.ibw = 1.0 / (STUDIO2_BW * g); G.imk = 1.0 / (0.3 * g);
    G.ip = 1.0 / G.p; G.ib = 1.0 / G.b;
    G.hg = half(g); G.hD = half(G.D); G.hiw = half(G.iw); G.hibw = half(G.ibw); G.himk = half(G.imk);
    G.ha = half(2.0 * (1.0 - smoothstep(0.06, 0.2, fp * G.iw)));   // the lip spans ≥ ~1.5 px
    float2 x = q / sS;

    // ---- light. Manual: Light Angle in screen degrees (y down: 215 = upper left), Light
    // Height. Live: the sun's hour angle swings it from the left (morning) over the top
    // (noon) to the right, its elevation (held to 8°…45° so the relief reads), warm when low; past
    // −4° it hands over to a dim cool lamp, low on the upper right. (Direction now; colour
    // after the composite, so it isn't held through the heavy part.)
    float azd = u.p1.y, el = clamp(u.p1.z, 5.0, 60.0) * 0.0174533;
    float wN = 0.0;
    if (live) {
        float se = u.sun.x;
        wN = smoothstep(-0.035, -0.105, se);
        float dAz = 270.0 + u.sun.y * 57.29578 - 300.0;
        dAz -= 360.0 * floor(dAz / 360.0 + 0.5);
        azd = 300.0 + dAz * (1.0 - wN);
        el = mix(clamp(se, 0.1396, 0.785), 0.1745, wN);          // 8°…45°: a window's light is never overhead
    }
    float az = azd * 0.0174533;
    float caz, saz = sincos(az, caz), cel, sel = sincos(el, cel);
    float2 Lh = float2(caz, -saz);
    float tanEl = sel / cel;

    // the ball's place: the end of the sweep in progress
    float2 Tb;
    float2 Pb = studio2_pos(sw0, G, sw0.thf, Tb);

    // ---- sand: composite the passes
    float qr = length(q);
    float edgePx = (qr - STUDIO2_RS * sS) * res.y;               // > 0: past the sand's edge
    studio2_Acc A;
    A.T = 1.0h; A.gT = half2(0.0h); A.H = 0.0h; A.gH = half2(0.0h); A.top1 = half4(0.0h); A.top2 = half4(0.0h);
    float r = length(x);
    float2 er = x / max(r, 1e-4);
    // The hub: every sweep starts or ends on the same closed loop round the centre, so inside
    // it the sand is always that loop's inner wall and the little mound it leaves — drawn
    // here directly (radially symmetric), blended into the composite across the wall.
    float hubIn = G.rs - 0.75 * STUDIO2_TW * g, hubOut = G.rs - 0.35 * STUDIO2_TW * g;
    float hubW = 1.0 - smoothstep(hubIn, hubOut, r);
    if (edgePx < 1.0 && r < STUDIO2_RS - 1.05 && hubW < 1.0) {
        float phi = atan2(x.y, x.x);
        float2 ep = float2(-er.y, er.x);
        float ir = 1.0 / max(r, 0.5 * G.rs);
        // newest first: the sweep in progress, the previous one, the one settling under both
        #pragma clang loop unroll(disable)
        for (int i = 0; i < 3; ++i) {
            if (A.T < 0.01) break;
            studio2_Sweep sw = sw0;
            float2 Ef = Pb, Tf = Tb;
            if (i > 0) {
                uint hOlder = studio2_sweepHash(gi - i - 1);           // (also the next one's own)
                sw = studio2_sweepParams(gi - i, hPrev, hOlder, menu, G);
                hPrev = hOlder;
                if (i == 2) sw.w = w2;
                // a finished sweep ends on the plain spiral: at the rim (θ = Θ ≡ π·2N, so on
                // the x axis) going out, or back at the hub's start (rs, 0) coming in
                if (sw.chi > 0.0) { Ef = float2(cTh * R0g, 0.0); Tf = normalize(float2(G.b, R0g)) * cTh; }
                else              { Ef = float2(G.rs, 0.0);      Tf = float2(0.0, -1.0); }
            }
            studio2_sweepComposite(A, sw, G, x, r, phi, er, ep, Ef, Tf, Lh, ir);
        }
    }
    if (hubW > 0.0) {
        half uh = half(max(G.rs - r, 0.0));
        half2 ph = studio2_profile(uh, G);
        half hw = half(hubW);
        half2 gh = -ph.y * half2(er) * half(smoothstep(0.0, 0.3 * g, r));   // a round top, not a cone
        A.H = mix(A.H * (1.0h - A.T) + A.T * ph.x, ph.x, hw);    // what shows through, then the loop
        A.gH = mix(A.gH, gh, hw);
        A.T = mix(A.T, 0.0h, hw);
        A.gT = mix(A.gT, half2(0.0h), hw);
        if (hw > 0.5h) { A.top1 = half4(1.0h, uh, dot(half2(Lh), -half2(er)), ph.x); A.top2 = half4(0.0h); }
    }

    // ---- light colour, materials
    float3 sunC = mix(float3(1.0, 0.80, 0.60), float3(1.0, 0.95, 0.90), smoothstep(0.30, 0.95, el));
    float3 skyC = float3(0.86, 0.95, 1.10);                      // room / sky fill, luma ≈ 1
    float bright = 1.0;
    if (live) {
        float se = u.sun.x;
        float3 sunTint = mix(float3(1.0, 0.74, 0.50), float3(0.98, 0.99, 1.0), 0.9 * smoothstep(0.06, 0.45, se));
        sunC = mix(sunTint, float3(0.60, 0.72, 1.0), wN);
        skyC = mix(skyC, float3(0.62, 0.80, 1.40), wN);
        bright = mix(mix(0.55, 1.0, smoothstep(-0.07, 0.07, se)), 0.22, wN);
    }
    float3 L3 = float3(Lh * cel, sel);
    float Esun = 0.64 / (0.785 * sel);                           // flat lit sand: 0.64 direct + ~0.34 fill
    float3 sandLin = studio2_lin(u.colorB.rgb);
    float3 rd = normalize(float3(q, -f));
    float3 V = -rd;
    float rb = 0.75 * g;
    float3 Cb = float3(Pb, rb - G.D);                            // the ball, resting in its trench

    float3 col = float3(0.0);
    float3 sandCol = float3(0.0);
    if (edgePx < 1.0) {
        // the sand banks up against the wall, under everything
        float2 bk = studio2_ss(STUDIO2_RS - 1.7, STUDIO2_RS, r);
        float hb = 0.30 * bk.x * bk.x, dhb = 0.60 * bk.x * bk.y;
        float H = float(A.H) + float(A.T) * hb;
        float2 gH = float2(A.gH) + float2(A.gT) * hb + (float(A.T) * dhb) * er;
        // Band-limit: as the pitch nears a few pixels, relief → its average tone (thumbnails
        // read as a smooth tonal rosette instead of aliasing stripes).
        float detail = smoothstep(4.0, 12.0, G.p / fp);
        float2 gHd = gH * detail;
        half Sraw = 1.0h - A.top1.x * (1.0h - studio2_march(A.top1, G, tanEl, fp));
        if (A.top2.x > 0.08h) Sraw -= A.top2.x * (1.0h - studio2_march(A.top2, G, tanEl, fp));
        half kk = half(clamp(0.36 * (G.D / (0.3 * g)) * (0.32 / tanEl), 0.0, 0.6));
        half S = mix(1.0h - kk * A.top1.z * A.top1.z, Sraw, half(detail));
        // fine grain: two octaves of normal perturbation, faded by the pixel footprint
        float gv1 = 1.0 - smoothstep(0.22, 0.55, fp / 0.10);
        float gv2 = 1.0 - smoothstep(0.22, 0.55, fp / 0.045);
        half2 gn = half2(0.0h);
        if (gv1 > 0.0) {             // warped sines at ~1 mm: irregular, and far cheaper than hashed noise
            float2 xw = x * 61.0;
            float wa = sin(xw.x * 0.83 + xw.y * 0.56 + 1.9 * studio2_tri(xw.y * 0.113 - xw.x * 0.059));
            float wb = sin(xw.y * 0.89 - xw.x * 0.47 + 1.7 * studio2_tri(xw.x * 0.107 + xw.y * 0.068 + 0.2));
            gn += half(gv1 * 0.035) * half2(wa, wb);
        }
        // the finest octave and a whisper of albedo speckle: one hash per ~pixel-sized cell
        uint hs = studio2_lattice(floor(x / max(0.045, 1.3 * fp)));
        half4 hj = half4(half(hs & 0xffu), half((hs >> 8) & 0xffu), half((hs >> 16) & 0xffu), half(hs >> 24))
                 * (2.0h / 255.0h) - 1.0h;
        gn += half(gv2 * 0.055) * hj.xy;
        half3 n = half3(normalize(float3(float2(gn) - gHd, 1.0)));
        // albedo: very subtle mottling + a whisper of sub-pixel speckle
        // (low-frequency interference of a few slow waves: organic, and far cheaper than noise)
        half mot = 1.0h + 0.05h * half(sin(x.x * 0.29 + x.y * 0.11 + 1.7 * studio2_tri(x.y * 0.037 - x.x * 0.021)));
        half3 alb = half3(sandLin) * mot * (1.0h + 0.0175h * (hj.z + hj.w));
        // shadows from the rim (the low light clips over the wall) and from the ball
        float hEdge = hTop - 0.3 * eF, visRim = 1.0;
        if (r > STUDIO2_RS - (hEdge + 0.3) / tanEl - 0.5) {     // only within a shadow's length of the wall
            float bw = dot(x, Lh), cw = r * r - STUDIO2_RS * STUDIO2_RS;
            float tw = -bw + sqrt(max(bw * bw - cw, 0.0));
            float penR = 0.05 + tw * 0.06;
            visRim = smoothstep(hEdge - penR, hEdge + penR, H + tw * tanEl);
        }
        float visBall = 1.0, aoBall = 1.0;
        float3 vC = Cb - float3(x, H);
        float rBall = rb * (2.5 + 1.2 / tanEl);
        if (length_squared(vC.xy) < rBall * rBall) {             // near the ball, and along its shadow
            float tcb = dot(vC, L3);
            float dpb = length(vC - tcb * L3);
            float penB = 0.03 * g + max(tcb, 0.0) * 0.06;
            visBall = mix(1.0, smoothstep(rb - penB, rb + penB, dpb), smoothstep(-0.2 * rb, 0.3 * rb, tcb));
            float dC = length(vC);
            aoBall = 1.0 - 0.9 * (rb * rb / max(dC * dC, rb * rb)) * clamp(dot(float3(n), vC / max(dC, 1e-4)) * 0.75 + 0.25, 0.0, 1.0);
        }
        // Oren–Nayar-ish diffuse (rough, matte: flatter than Lambert, no specular)
        half3 hL = half3(L3), hV = half3(V);
        half NL = dot(n, hL), NV = max(dot(n, hV), 0.0h);
        half sON = dot(hL, hV) - NL * NV;
        half on = max(NL, 0.0h) * (0.785h + 0.33h * (sON > 0.0h ? sON / max(max(NL, NV), 0.001h) : 0.0h));
        half3 direct = half3(sunC) * (half(Esun) * on * S * half(visRim * visBall));
        half aoT = 1.0h - 0.38h * half(clamp(-H / max(0.45 * g, 1e-3), 0.0, 1.0));   // the trench floor sees less sky
        half aoW = 1.0h - 0.18h * half(smoothstep(STUDIO2_RS - 1.2, STUDIO2_RS, r));
        // fill: the room (faintly cool, a touch more on the faces turned from the light) and
        // warm bounce off the lit sand around — strongest in a trench, off its lit far wall
        half3 sky = half3(skyC) * (0.22h * (0.62h + 0.38h * n.z) + 0.06h * max(dot(n.xy, -half2(Lh)), 0.0h));
        sky += half3(sunC * sandLin) * (0.15h + 0.08h * (1.0h - S));
        sky *= aoT * half(aoBall) * aoW;
        sandCol = float3(alb * (direct + sky));

        // ---- the ball: a mirror sphere resting in its trench (shaded only where it is)
        float Db = Hc - Cb.z;
        float pixA = 1.0 / (f * res.y);                          // radians per pixel
        if (length(q - Cb.xy * (f / Db)) < rb * f / (Db - rb) + 3.0 / res.y) {
            float3 oc = float3(0.0, 0.0, Hc) - Cb;
            float bq = dot(oc, rd);
            float3 perp = oc - bq * rd;
            float dperp = length(perp);
            float covB = clamp((rb - dperp) / (max(-bq, 1.0) * pixA) + 0.5, 0.0, 1.0);
            float hh = rb * rb - dperp * dperp;
            float3 nb = hh > 0.0 ? normalize(perp - sqrt(hh) * rd) : perp / max(dperp, 1e-5);
            float3 Rb = reflect(rd, nb);
            float NVb = max(dot(nb, V), 0.0);
            float aaB = 2.0 * pixA * Db / (rb * max(NVb, 0.12));  // the reflection's turn per pixel
            float3 sandRad = sandLin * (sunC * (0.64 + 0.15 * sandLin) + skyC * 0.22);
            float3 woodRad = studio2_lin(u.colorA.rgb) * (sunC * 0.35 + skyC * 0.25);
            float3 envBall = studio2_ballEnv(Rb, Lh, el, sunC, skyC, sandRad, woodRad, aaB);
            float fr = pow(1.0 - NVb, 5.0);
            float3 ballCol = envBall * (float3(0.60, 0.595, 0.59) + float3(0.40, 0.405, 0.41) * fr);
            sandCol = mix(sandCol, ballCol, covB);
        }
    }

    // ---- rim: oiled walnut (Fill), or a brushed-steel lip set into a walnut top (Table)
    float3 rimCol = float3(0.0);
    if (edgePx > -1.0) {
        float3 woodLin = studio2_lin(u.colorA.rgb);
        float m = qr / f;
        float2 dq = q / max(qr, 1e-5);
        float rho, z; float3 nr;
        float rhoT = m * (Hc - hTop);
        if (rhoT >= STUDIO2_RS + eF) { rho = rhoT; z = hTop; nr = float3(0.0, 0.0, 1.0); }
        else {
            float rcF = STUDIO2_RS + eF, zcF = hTop - eF;
            float k0 = m * Hc - rcF;
            float aq = m * m + 1.0, bh = k0 * m + zcF, cq = k0 * k0 + zcF * zcF - eF * eF;
            float disc = bh * bh - aq * cq;
            float zf = disc >= 0.0 ? (bh + sqrt(disc)) / aq : -1.0;
            if (zf >= zcF) {
                z = zf; rho = m * (Hc - z);
                float2 nn = float2(rho - rcF, z - zcF) / eF;
                nr = normalize(float3(dq * nn.x, nn.y));
            } else {
                z = clamp(Hc - STUDIO2_RS / max(m, 1e-5), 0.0, zcF);
                rho = STUDIO2_RS; nr = float3(-dq, 0.0);
            }
        }
        float fpw = (Hc - z) / (f * res.y);
        float NLw = max(dot(nr, L3), 0.0);
        float3 Hv = normalize(L3 + V);
        float NH = max(dot(nr, Hv), 0.0), VH = max(dot(V, Hv), 0.0);
        float3 Rr = reflect(rd, nr);
        float NVr = max(dot(nr, V), 0.0);
        float3 room = studio2_room(Rr, Lh, el, sunC, skyC, sandLin);
        float3 skyW = skyC * 0.28 * (0.62 + 0.38 * nr.z);
        bool steel = table && rho < STUDIO2_RS + 0.9;
        float3 c;
        if (steel) {
            // brushed steel: blurred room + a stretched key highlight, fine circumferential lines
            float along = atan2(dq.y, dq.x) * STUDIO2_RS;
            float br = 1.0 + 0.2 * (float(studio2_lattice(floor(float2(along * 0.4, (rho + z) * 30.0))) & 0xffu) * (1.0 / 255.0) - 0.5)
                           * (1.0 - smoothstep(0.015, 0.04, fpw));
            const float a2 = 0.09;
            float Dg = a2 / (STUDIO2_PI * pow(NH * NH * (a2 - 1.0) + 1.0, 2.0));
            float3 F0 = float3(0.60, 0.61, 0.62);
            float3 Fv = F0 + (1.0 - F0) * pow(1.0 - VH, 5.0);
            c = F0 * room * br + sunC * (Esun * NLw * STUDIO2_PI * 0.25 * Dg) * Fv;
        } else {
            float2 gp; float seed;
            if (table) {                         // straight-grained planks along x, 14 cm wide
                float2 P = dq * rho;
                float plank = floor(P.y / 14.0);
                seed = plank;
                gp = float2(P.x, P.y);
                float sd = abs(P.y - (plank + 0.5) * 14.0) - 7.0;      // ≤ 0 inside the plank
                float seam = smoothstep(-0.05 - fpw, -0.05 + fpw, sd);
                woodLin *= 1.0 - 0.55 * seam;
            } else {                             // a bent ring: grain runs round it
                seed = 0.0;
                gp = float2(atan2(dq.y, dq.x) * STUDIO2_RS, (rho - STUDIO2_RS) + (hTop - z));
            }
            float3 alb = studio2_wood(gp, woodLin, fpw, seed);
            const float a2 = 0.04;                                   // lacquer, α = 0.2
            float Dg = a2 / (STUDIO2_PI * pow(NH * NH * (a2 - 1.0) + 1.0, 2.0));
            float Fl = 0.04 + 0.96 * pow(1.0 - VH, 5.0);
            float Fe = 0.04 + 0.96 * pow(1.0 - NVr, 5.0);
            c = alb * (sunC * (Esun * 0.785 * NLw) + skyW)
              + sunC * (Esun * NLw * STUDIO2_PI * 0.25 * Dg * Fl) + room * Fe;
            if (table) {                         // the seam between steel and wood
                float sd = abs(rho - (STUDIO2_RS + 0.925)) - 0.03;
                c *= mix(0.25, 1.0, smoothstep(-fpw, fpw, sd));
            }
        }
        rimCol = c;
    }
    col = mix(sandCol, rimCol, clamp(edgePx + 0.5, 0.0, 1.0));

    // ---- finish: gentle lens falloff, exposure, filmic shoulder, sRGB, dither
    col *= bright * (1.0 - 0.10 * dot(q, q) / (0.25 * (aspect * aspect + 1.0)));
    float Ly = dot(col, float3(0.2126, 0.7152, 0.0722));
    float3 a = col * (studio2_shoulder(Ly) / max(Ly, 1e-5));
    // hue-preserving, with the hottest highlights (the ball's window) bleaching toward white
    float3 o = linearToSrgb(saturate(mix(a, float3(dot(a, float3(0.2126, 0.7152, 0.0722))), smoothstep(0.85, 1.6, Ly) * 0.6)));
    return float4(o + bandDither(px) * 1.5, 1.0);
}
