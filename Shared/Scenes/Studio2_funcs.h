//  Studio2_funcs.h — SAND GARDEN (shader id 68). File-scope helpers; prefix "studio2_".
//
//  A top-down view, with a little perspective, onto a round kinetic sand table: a chrome
//  ball ploughs theta-rho patterns, half an hour a sweep at 1×, alternating outward and
//  inward. Every frame is a pure function of (t, clock, date) — no state:
//    • each sweep is a spiral whose every turn is a lobed curve, ρ = C(u) + A(u)·w(ψ):
//      a centre line C and an amplitude A that are piecewise linear in the turn count u
//      (a ramp out of the hub, self-similar growth A = a·C until the lobe tips reach the
//      rim, then a fill in which the tips hold at the rim while the hollows rise to it), and
//      a waveform w (sine lobes, sharp star tips, or pinched petal hollows). So every finished
//      sweep is a whole-table drawing — a star, a flower, a spiral galaxy, an interlaced
//      spirograph or a plain spiral erase — that covers the table edge to edge;
//    • a pixel finds the passes near it in O(1): along its own ray the turns of a "family"
//      (all turns for whole k; alternate turns for half-integer k, which interlace) cross in
//      order, and since C and A are linear in u, where they cross a radius is closed-form
//      (a log twist needs two fixed-point steps). Inverting r ± the footprint's reach gives
//      exactly the turns to test, NEWEST FIRST: each pass's footprint (a U trench + low
//      berms) replaces whatever was under it;
//    • three sweeps deep: the one in progress (cut off at the ball, so the boundary between
//      the new pattern and the old is the ball's own front), the previous one, and the one
//      before, whose relief settles flat over the current sweep (it only shows through the
//      rare gaps in BOTH later sweeps), so neither a sweep change nor the hourly wrap pops.
//  Relief normals are analytic (profile′(d)·∇d carried through the compositing), self-
//  shadow is a 3-tap march across the top grooves' own 1-D profiles, the sand is Oren–Nayar-
//  like (no specular, no glitter), the walnut is procedural figure under a GGX lacquer, the
//  ball a chrome mirror of a soft room with a window. Lengths are in cm; everything is
//  linear light, tone-mapped once.

constant float STUDIO2_TAU = 6.28318531;
constant float STUDIO2_PI = 3.14159265;
constant float STUDIO2_ITAU = 0.159154943;
constant float STUDIO2_RS = 40.0;                      // sand radius at the inner wall, cm
constant float STUDIO2_ST[3] = {0.30, 0.62, 1.05};     // self-shadow taps (× groove scale)
// the groove, × groove scale: trench half-width, berm centre, berm half-width; berm height × depth
constant float STUDIO2_TW = 0.52, STUDIO2_BU = 0.62, STUDIO2_BW = 0.30, STUDIO2_BH = 0.20;

struct studio2_Geo {
    float g;                         // groove scale (Groove Width)
    float pt, ipt, rs, R0, Ns, cpP;  // plain pitch (and 1/pitch), hub loop radius, outermost radius,
                                     // the plain spiral's turns and growth per turn
    float D;                         // trench depth (the profile's other sizes scale with g)
    // the groove's cross-section in half precision (cm-scale values; Apple GPUs run half at
    // twice the rate, in half the registers)
    half hg, hD, hiw, hibw, himk, ha;   // ha: the trench's crispness (see studio2_profile)
};

struct studio2_Sweep {
    float chi;                       // +1 outward (φ = θ), −1 inward (φ = −θ, mirrored)
    float k, a, X;                   // lobes, amplitude (a fraction of the centre line), log twist
    int wave, q;                     // waveform (0 sine, 1 star, 2 petal); families (2: half-integer k)
    float phi0;                      // lobe phase
    float cp, C0;                    // centre line C0 + cp·u past the hub ease (C0 = rs − cp/2π)
    float Cs, Cg;                    // the lobes start at C = Cs (A = a·(C − Cs)); C at the growth end
    float ug, N;                     // growth end, last turn (u = turns past the hub loop)
    float fC;                        // the fill: C′ = fC, A′ = −fC (the tips hold at the rim)
    float thf;                       // the front: θ where the ball is (or where it finished)
#ifdef SGX_DBG2
    int dbg;
#endif
    float rej;                       // nothing of the sweep reaches beyond (out) / inside (in) this radius
    float w;                         // relief weight (the settling sweep fades to flat)
    // (kept small — it is live through the heaviest loop; the rest is derived where used)
    float Th() const { return 6.28318531 * (1.0 + N); }           // the sweep's end, θ = 2π(1 + N)
};

struct studio2_Acc {
#ifdef SGX_DBG
    int it, ly, fp;
#endif
    half T; half2 gT;                // transmittance and its gradient
    half H; half2 gH;                // composited height and its gradient
    half4 top1, top2;                // the two most visible layers: (weight, u, light across, height)
    half sp;                         // the visible sweep's tightest groove spacing here, cm
#ifdef SGX_DBG2
    half src;
#endif
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
// fast-math): the sand's grain and speckle, wood pores, brushed-steel lines.
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

// The lobe waveform w(ψ) ∈ [−1, 1] (tips at w = 1) and dw/dψ, from (sin ψ, cos ψ):
// 0 sine lobes, 1 star (tips twice as sharp, broad hollows), 2 petals (round tips, pinched
// hollows). Polynomials in sin ψ, so a family that shares ψ shares w.
static inline float2 studio2_wave(int wave, float s, float c) {
    if (wave == 1) { float p = 1.0 + s; return float2(0.5 * p * p - 1.0, p * c); }
    if (wave == 2) { float p = 1.0 - s; return float2(1.0 - 0.5 * p * p, p * c); }
    return float2(s, c);
}

// Centre line and amplitude at u ≥ 0 turns past the hub loop: (C, dC/du, A, dA/du).
// The hub loop is an exact circle (u ∈ [−1, 0]); the centre line eases out of it over a
// radian either side of θ = 2π + 1 (so the loop closes on itself without a seam), then runs
// straight at cp per turn. The lobes rise out of the plain spiral once a lobe is several
// grooves wide (C = Cs), growing as A = a·(C − Cs) until the tips reach the rim at ug; then A
// shrinks while C grows the same amount: the tips hold at the rim and the hollows rise to
// meet it, so the sweep ends on a circle at R0 — the plain spiral every sweep starts and
// ends on.
static inline float4 studio2_env(thread const studio2_Sweep& s, thread const studio2_Geo& G, float u) {
    if (u >= s.ug) { float f = u - s.ug; return float4(s.Cg + s.fC * f, s.fC, s.a * (s.Cg - s.Cs) - s.fC * f, -s.fC); }
    float x = STUDIO2_TAU * u;
    float C, dC;
    if (x >= 2.0) { C = s.C0 + s.cp * u; dC = s.cp; }
    else          { C = G.rs + s.cp * STUDIO2_ITAU * x * x * 0.25; dC = s.cp * x * 0.5; }
    return C > s.Cs ? float4(C, dC, s.a * (C - s.Cs), s.a * dC) : float4(C, dC, 0.0, 0.0);
}
// The log twist: the lobes' phase turns with ln r between the lobes' start and the rim (an
// equiangular spiral arm, the same lean at every radius) — a warp of the lobe phase by the
// radius, so along any ray every turn of a family still shares one w. (phase, d phase/dr)
static inline float2 studio2_twist(thread const studio2_Sweep& s, float r) {
    float rc = clamp(r, s.Cs, s.Cg);
    return float2(s.X * log(rc / s.Cg), (r > s.Cs && r < s.Cg) ? s.X / r : 0.0);
}
// The turn u at which a family with waveform value w crosses radius y. Exact for the linear
// model of C (the hub ease bends it by at most b, which the caller's margin allows for):
// ρ(u) is piecewise linear in u and increasing (the fill's slope fC·(1 − w) only vanishes at
// the tips themselves, where every fill turn passes — the caller clamps to the last turn).
static inline float studio2_inv(thread const studio2_Sweep& s, float w, float y) {
    float aw = s.a * w, k1 = 1.0 + aw;
    float yG = k1 * s.Cg - aw * s.Cs;
    if (y <= s.Cs) return (y - s.C0) / s.cp;
    if (y <= yG) return ((y + aw * s.Cs) / k1 - s.C0) / s.cp;
    return s.ug + (y - yG) / max(s.fC * (1.0 - w), 1e-4);
}

// A sweep as the CPU worked it out for this frame (SandGarden.fill, in Studio2.swift: the
// sweep's design, its envelope and where its front is depend only on the uniforms, so they are
// found once a frame, not once a pixel). u.scene[4i…4i+3]: (chi, k, a, X), (wave + 4·(q − 1),
// φ0, cp, Cs), (Cg, ug, N, fC), (thf, rej, w, C0).
static inline studio2_Sweep studio2_load(constant FXUniforms& u, int i) {
    studio2_Sweep s;
    float4 a = u.scene[4 * i], b = u.scene[4 * i + 1], c = u.scene[4 * i + 2], d = u.scene[4 * i + 3];
    s.chi = a.x; s.k = a.y; s.a = a.z; s.X = a.w;
    int code = int(b.x + 0.5);
    s.wave = code & 3; s.q = 1 + (code >> 2);
    s.phi0 = b.y; s.cp = b.z; s.Cs = b.w;
    s.Cg = c.x; s.ug = c.y; s.N = c.z; s.fC = c.w;
    s.thf = d.x; s.rej = d.y; s.w = d.z; s.C0 = d.w;
#ifdef SGX_DBG2
    s.dbg = i * 10;
#endif
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
// Footprint opacity: the pass fully replaces the sand within g (≥ half the spacing of a
// sweep's turns, so a finished sweep covers everything under it), feathering out to 1.3·g.
static inline half2 studio2_mask(half u, thread const studio2_Geo& G) {
    half t = clamp((u - G.hg) * G.himk, 0.0h, 1.0h);
    return half2(1.0h - t * t * (3.0h - 2.0h * t), -6.0h * t * (1.0h - t) * G.himk);
}

// Composite one pass (signed distance d, gradient gd) under what's already in front of it.
// Heights and their gradients are carried analytically: no re-evaluation for normals.
#ifdef SGX_AI
__attribute__((always_inline))
#endif
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
#ifdef SGX_DBG2
    if (me.x > a.top1.x) a.src = half(wgt > 1.5 ? wgt : a.src);
#endif
    if (me.x > a.top1.x) { a.top2 = a.top1; a.top1 = me; }
    else if (me.x > a.top2.x) a.top2 = me;
    a.gT = a.gT * (1.0h - m.x) - (a.T * m.y) * gu;
    a.T *= 1.0h - m.x;
}

// Self-shadow of one layer, against the crest of the berm toward the light (the highest
// thing along its own 1-D profile, so the one that decides): the pixel is lit if the ray
// toward the light clears it. L = (weight, u, light across the groove (signed), height).
static inline half studio2_march(half4 L, thread const studio2_Geo& G, float tanEl, float fp) {
    half al = abs(L.z);
    if (L.x < 0.004h || al < 0.03h || G.D < 1e-3) return 1.0h;
#ifdef SGX_OLDMARCH
    half sg = L.z > 0.0h ? 1.0h : -1.0h;
    half ial = 1.0h / al;
    half kr = half(tanEl) * ial;
    half e0 = L.w;
    half pk = half(1.4 * fp) * kr + 0.01h * G.hg;
    half vis = 1.0h;
    for (int i = 0; i < 3; ++i) {
        half st = half(STUDIO2_ST[i]) * G.hg;
        half eo = studio2_profile(abs(L.y + sg * st), G).x;
        half gap = e0 + st * kr - eo;
        half pen = 0.10h * st * ial + pk;
        vis = min(vis, smoothstep(-pen, pen, gap));
    }
    return vis;
#else
    half bc = half(STUDIO2_BU) * G.hg;                           // the crests, ±bc from the path
    // light from further out (L.z > 0): this side's crest, if the pixel is inside it; from
    // the path's side: this side's crest if the pixel is beyond it, else the far one
    half ts = L.z > 0.0h ? bc - L.y : (L.y > bc ? L.y - bc : L.y + bc);
    if (ts <= 0.0h) return 1.0h;
    half ial = 1.0h / al;
    half kr = half(tanEl) * ial;                                 // ray rise per cm across
    half gap = L.w + ts * kr - half(STUDIO2_BH) * G.hD;          // ray height over the crest
    half pen = 0.10h * ts * ial + half(1.4 * fp) * kr + 0.01h * G.hg;   // window penumbra + pixel
    return smoothstep(-pen, pen, gap);
#endif
}

// Composite every pass of sweep s near the pixel, newest first. Ef/Tf: the sweep's front
// (where the ball is or stopped) and its tangent. Passes beyond the front don't exist yet;
// the one that reaches it ends in the ball's own round front (a cap: distance to Ef).
#ifdef SGX_AI
__attribute__((always_inline))
#endif
static inline void studio2_sweepComposite(thread studio2_Acc& a, thread const studio2_Sweep& s,
                                          thread const studio2_Geo& G, float2 x, float r, float phi,
                                          float2 er, float2 ep, float2 Ef, float2 Tf, float2 Lh, float ir) {
    if (a.T < 0.01h) return;
#ifdef SGX_NOFP0
    a.T = 0.0h; a.H = half(r) * 0.001h; return;
#endif
    if (s.chi > 0.0 ? r > s.rej : r < s.rej) return;
#ifdef SGX_NOFP1
    a.T = 0.0h; a.H = half(r) * 0.001h; return;
#endif
    float th0 = fract(s.chi * phi * STUDIO2_ITAU) * STUDIO2_TAU;               // [0, 2π)
    float nu = th0 * STUDIO2_ITAU;
    float2 v = x - Ef;
    float lv = length(v);
    bool ahead = dot(v, Tf) * s.chi > 0.0;                                       // past the front
    float hw = 1.3 * G.g;
    // The front first — the round end the ball leaves is this sweep's newest sand.
    if (ahead && lv < hw) {
        studio2_layer(a, lv, v / max(lv, 1e-4), s.w, G, Lh);
        if (a.T < 0.01h) return;
    }
    // Candidate turns, O(1). Along this pixel's ray the turns of a family share ψ (mod 2π) —
    // all turns for whole k, alternate ones for half-integer k (the odd family's lobes are the
    // even one's, half a lobe on) — so they share w, and where they cross radius r is the
    // closed-form studio2_inv. Inverting r ± the footprint's radial reach (its half-width
    // stretched by the family's lean) bounds exactly the turns that can touch the pixel.
#ifdef SGX_NOFP
    a.T = 0.0h; a.H = half(th0 + lv) * 0.001h; return;
#endif
    float2 tw = s.X != 0.0 ? studio2_twist(s, r) : float2(0.0);
    float cB, sB = sincos(s.k * th0 + s.phi0 + tw.x, cB);
    float nMax = floor(s.N + 1.0 - nu);                                          // u ≤ N
    float mg = (r < G.rs + 3.0 * s.cp ? 1.0 : 0.04);                             // (the hub ease bends C)
    float lo0, hi0, lo1 = 1.0, hi1 = -1.0;
    float st = float(s.q), spS = 100.0;
    for (int j = 0; j < s.q; ++j) {
        float sg = j == 0 ? 1.0 : -1.0;
        float2 ww = studio2_wave(s.wave, sg * sB, sg * cB);
        // the footprint's radial reach: its half-width times |∇(r − ρ)| (the lean of the
        // lobes across the ray, and the twist's along it), bounded over the family
        float aw = 1.0 / (1.0 + s.a * ww.x);
        float sl = s.a * (s.k + 0.3) * abs(ww.y) * aw + 0.06;
        float Dr = 1.0 + s.a * abs(ww.y * s.X) * aw;
        float reach = hw * sqrt(Dr * Dr + sl * sl) + 0.05;
        float uLo = studio2_inv(s, ww.x, r - reach), uHi = studio2_inv(s, ww.x, r + reach);
        // the family's groove spacing across the grooves here (for the band-limit)
        spS = min(spS, st * (2.0 * hw) / max(uHi - uLo, 1e-3));
        float lo = max(ceil(uLo - mg + 1.0 - nu), 0.0), hi = min(floor(uHi + mg + 1.0 - nu), nMax);
#ifdef SGX_BRUTE
        lo = 0.0; hi = nMax;
#endif
        if (s.q == 1) { lo0 = lo; hi0 = hi; }
        else if (j == 0) { lo0 = 2.0 * ceil(lo * 0.5); hi0 = 2.0 * floor(hi * 0.5); }
        else { lo1 = 2.0 * ceil((lo - 1.0) * 0.5) + 1.0; hi1 = 2.0 * floor((hi - 1.0) * 0.5) + 1.0; }
    }
    // Walk both families' windows merged, newest first (two pointers: no idle steps across
    // the gap between them). Family 0 steps by q turns; family 1 (odd turns) by 2.
#ifdef SGX_NOLOOP
    a.T = 0.0h; a.H = half(lo0 + hi0 + lo1 + hi1) * 0.001h; return;
#endif
    float na = s.chi > 0.0 ? hi0 : lo0, nb = s.chi > 0.0 ? hi1 : lo1;            // next of each
    int cnt0 = max(int((hi0 - lo0) / st) + 1, 0), cnt1 = max(int((hi1 - lo1) * 0.5) + 1, 0);
    int cnt = cnt0 + cnt1;
#ifdef SGX_DBG
    a.fp += 1;
#endif
    for (int j = 0; j < cnt; ++j) {
#ifdef SGX_DBG
        a.it += 1;
#endif
        bool odd = cnt1 > 0 && (cnt0 == 0 || s.chi * (nb - na) > 0.0);
        float n;
        if (odd) { n = nb; nb -= s.chi * 2.0; --cnt1; }
        else     { n = na; na -= s.chi * st; --cnt0; }
        float th = th0 + STUDIO2_TAU * n;
        float past = s.chi * (th - s.thf);                                       // > 0: not drawn yet
        // Beyond the front: nothing, except right by the ball and behind its normal line, where
        // the path is extrapolated a couple of cm so the trench meets the cap. Under the cap
        // (ahead of that line, within its reach) the cap stands in for the path's last cm or two.
        // (Arc-length and distance gated: on a steep lobe the path soon swings back, and near
        // the hub the normal line runs on through the centre.)
        float arc = abs(past) * r;
        if (past > 0.0 ? (ahead || arc > 2.0 * G.g || lv > 2.6 * G.g) : (ahead && arc < 2.0 * G.g && lv < hw)) continue;
        float u = n - 1.0 + nu;
        // this turn's radius here, ρ = C + A·w, and the gradient of r − ρ (polar: radial
        // 1 − A·w′·T′(r), across −(dρ/dθ)/r)
        float rho = G.rs, rt = 0.0, Dr = 1.0;
        if (u >= 0.0) {
            float4 e = studio2_env(s, G, u);
            float sg = odd ? -1.0 : 1.0;
            float2 ww = studio2_wave(s.wave, sg * sB, sg * cB);
            rho = e.x + e.z * ww.x;
            rt = ((e.y + e.w * ww.x) * STUDIO2_ITAU + e.z * ww.y * s.k) * ir;
            Dr = 1.0 - e.z * ww.y * tw.y;
        }
        float iG = rsqrt(Dr * Dr + rt * rt);
        float d = (r - rho) * iG;                                                // ⟂ distance
        if (abs(d) >= hw) continue;
        float2 gd = iG * (Dr * er - (s.chi * rt) * ep);
#ifdef SGX_DBG
        a.ly += 1;
#endif
        // the band-limit follows the sweep that shows here (one that draws, and isn't settled flat)
        if (a.T > 0.5h && s.w > 0.5) a.sp = min(a.sp, half(spS));
#ifdef SGX_DBG2
        studio2_layer(a, d, gd, s.w + 2.0 + float(s.dbg), G, Lh);
#else
        studio2_layer(a, d, gd, s.w, G, Lh);
#endif
        if (a.T < 0.01h) return;
    }
}

// ---------------------------------------------------------------- materials

// Oiled walnut, linear albedo. gp = (along the grain, across it), cm; fpw = cm per pixel;
// seed varies the board. Flat-sawn figure: the board's face cuts the log's growth rings at a
// slowly varying depth below the pith, so the rings show as nested cathedral arches running
// along the board, each with a darker band of late wood; streaks of colour along the grain
// (a few golden), and fine dark pores. Rings and pores fade to their average as they near a
// pixel, so the wood never shimmers.
static inline float3 studio2_wood(float2 gp, float3 base, float fpw, float seed) {
    float h = fract(seed * 0.6180339 + 0.31);
    float x = gp.x + seed * 53.7, y = gp.y;
    float yp = y - (2.2 * sin(x * 0.021 + 6.0 * h) + 0.8 * sin(x * 0.067 + 2.0));    // off the pith's line
    float dep = 2.6 + 2.0 * sin(x * 0.043 + 9.0 * h) + 1.1 * sin(x * 0.11 + 4.0 * h); // the cut below the pith
    float R = sqrt(yp * yp + dep * dep);                                               // from the pith, cm
    float rp = fract(R * 2.1 + 0.25 * sin(x * 0.17 + R * 0.9));                        // rings ~0.48 cm apart
    float late = smoothstep(0.5, 0.82, rp) * (1.0 - smoothstep(0.9, 1.0, rp));
    float ringAA = 1.0 - smoothstep(0.25, 0.6, fpw * 2.1);
    float st = 0.6 * sin(yp * 0.55 + 1.7 * sin(x * 0.013 + 3.0 * h)) + 0.4 * sin(yp * 1.3 + x * 0.008);
    float pores = float(studio2_lattice(floor(float2(x * 0.7, y * 11.0))) & 0xffu) * (1.0 / 255.0) - 0.5;
    float poreAA = 1.0 - smoothstep(0.02, 0.045, fpw);
    float3 c = base * (0.9 + 0.2 * st + 0.16 * (h - 0.5));
    c = mix(c, c * float3(1.3, 1.12, 0.88), 0.3 * smoothstep(0.25, 0.9, st));        // golden streaks
    c *= 1.0 - mix(0.09, 0.36 * late, ringAA);
    c *= 1.0 - 0.25 * max(pores, 0.0) * poreAA;
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
    // dark furniture and skirting along the horizon, walls (the window wall in its own shade)
    // rolling up into a bright, bounce-lit ceiling: the contrast that reads as chrome
    float3 c = float3(0.24, 0.225, 0.21) * (1.0 - 0.3 * caz) + skyC * 0.04;
    c *= 0.35 + 0.65 * smoothstep(0.04 - aa, 0.2 + aa, elv);
    c = mix(c, float3(0.62, 0.61, 0.59), smoothstep(0.45, 1.3, elv));
    // the window: soft-edged, sky-bright, with a cross of glazing bars
    float e = 0.035 + aa;
    float wy = elv - (el + 0.26);
    float box = (1.0 - smoothstep(0.56 - e, 0.56 + e, abs(az))) * (1.0 - smoothstep(0.42 - e, 0.42 + e, abs(wy)))
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

// ---- finish: gentle lens falloff, exposure, filmic shoulder (hue-preserving, with the hottest
// highlights — the ball's window — bleaching toward white), sRGB, dither
static inline float4 studio2_finish(float3 col, float2 q, float aspect, float bright, float2 px) {
    col *= bright * (1.0 - 0.10 * dot(q, q) / (0.25 * (aspect * aspect + 1.0)));
    float Ly = dot(col, float3(0.2126, 0.7152, 0.0722));
    float3 a = col * (studio2_shoulder(Ly) / max(Ly, 1e-5));
    float3 o = linearToSrgb(saturate(mix(a, float3(dot(a, float3(0.2126, 0.7152, 0.0722))), smoothstep(0.85, 1.6, Ly) * 0.6)));
    return float4(o + bandDither(px) * 1.5, 1.0);
}


static inline float4 studio2_scene(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u) {
    float g = clamp(u.p0.z, 0.5, 2.0);
    bool table = u.p0.w > 0.5;
    float relief = clamp(u.p1.x, 0.0, 1.0);
    bool live = u.p1.w > 0.5 && u.sky.y > 0.5;

    // ---- table geometry (cm). The outermost pass's footprint always ends 1.1 cm short of
    // the wall, where the sand banks up; 2·turns is an integer (and every pattern's turn count
    // ≡ the plain spiral's, mod 1), so every sweep starts and ends at the same two points and
    // the ball's path joins up.
    studio2_Geo G;
    G.g = g;
    G.pt = 1.67 * g;
    G.rs = 0.5 * G.pt;
    G.R0 = STUDIO2_RS - 1.1 - 1.3 * g;
    G.ipt = 1.0 / G.pt;
    G.Ns = max(round(2.0 * (G.R0 - G.rs) * G.ipt) * 0.5, 3.0);
    G.cpP = (G.R0 - G.rs) / (G.Ns - STUDIO2_ITAU);               // C(Ns) = R0 exactly
    G.D = 0.55 * g * relief;                                     // 3.3 mm at the default relief
    // (a pass's footprint: opaque within g of its path, feathered out to 1.3·g)

    // ---- the three sweeps on the table (the one in progress, the previous one, and the one
    // settling flat under both) and the ball, as worked out for this frame on the CPU
    studio2_Sweep sw0 = studio2_load(u, 0);
    float cTh = fract(G.Ns) > 0.25 ? -1.0 : 1.0;                 // cos Θ (Θ = 2π(1 + N), 2N whole)

    // ---- camera: straight down from Hc, focal length f (screen height = 1).
    float aspect = res.x / res.y;
    float2 q = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);
    const float f = 3.0;
    float sS, Hc, hTop, eF;
    if (!table) {                    // Fill: the sand circle nearly spans the width, cropped top and
                                     // bottom — the ball's path stays in frame ~80% of a sweep, and
                                     // the round wall gives the frame its shape
        hTop = 1.5; eF = 0.5;
        sS = clamp(0.45 * aspect + 0.04, 0.6, 1.0) / STUDIO2_RS;
        Hc = f / sS;
    } else {                         // Table: the lip's outer edge 6% in from the frame
        hTop = 1.9; eF = 0.22;
        float sT = 0.44 / (STUDIO2_RS + 0.95);
        Hc = f / sT + hTop;
        sS = f / Hc;
    }
    float fp = 1.0 / (sS * res.y);                               // cm per pixel on the sand
    float iw = 1.0 / (STUDIO2_TW * g);
    G.hg = half(g); G.hD = half(G.D); G.hiw = half(iw); G.hibw = half(1.0 / (STUDIO2_BW * g)); G.himk = half(1.0 / (0.3 * g));
    G.ha = half(2.0 * (1.0 - smoothstep(0.06, 0.2, fp * iw)));   // the lip spans ≥ ~1.5 px
    float2 x = q / sS;

    // ---- light. Manual: Light Angle in screen degrees (y down: 215 = upper left), Light
    // Height. Live: the sun's hour angle swings it from the left (morning) over the top
    // (noon) to the right, its elevation (held to 8°…26° so the relief reads), warm when low; past
    // −4° it hands over to a dim warm lamp, low on the upper right. (Direction now; colour
    // after the composite, so it isn't held through the heavy part.)
    float azd = u.p1.y, el = clamp(u.p1.z, 5.0, 60.0) * 0.0174533;
    float wN = 0.0;
    if (live) {
        float se = u.sun.x;
        wN = smoothstep(-0.035, -0.105, se);
        float dAz = 270.0 + u.sun.y * 57.29578 - 300.0;
        dAz -= 360.0 * floor(dAz / 360.0 + 0.5);
        azd = 300.0 + dAz * (1.0 - wN);
        el = mix(clamp(se, 0.1396, 0.45), 0.2, wN);              // 8°…26°: a window's light is never overhead,
                                                                 // and the relief always reads
    }
    float az = azd * 0.0174533;
    float caz, saz = sincos(az, caz), cel, sel = sincos(el, cel);
    float2 Lh = float2(caz, -saz);
    float tanEl = sel / cel;

    // the ball's place: the end of the sweep in progress, and its heading
    float2 Pb = u.scene[12].xy, Tb = u.scene[12].zw;

    // ---- light colour, materials
    float3 sunC = mix(float3(1.0, 0.80, 0.60), float3(1.0, 0.95, 0.90), smoothstep(0.30, 0.95, el));
    float3 skyC = float3(0.86, 0.95, 1.10);                      // room / sky fill, luma ≈ 1
    float bright = 1.0;
    if (live) {
        float se = u.sun.x;
        // warm and low in the morning and evening, a soft daylight at noon (never bleached), and
        // after dusk a warm table lamp in a dusk-blue room — still sand, not grey metal
        float3 sunTint = mix(float3(1.0, 0.74, 0.50), float3(1.0, 0.9, 0.78), smoothstep(0.06, 0.5, se));
        sunC = mix(sunTint, float3(1.0, 0.70, 0.43), wN);
        skyC = mix(skyC, float3(0.52, 0.60, 0.82), wN);
        bright = mix(mix(0.6, 1.0, smoothstep(-0.07, 0.07, se)), 0.45, wN);
    }
    // exposure: a dark sand (basalt) is metered up, as a photographer would, so its trenches
    // aren't crushed to black (pale sand is unchanged)
    bright *= clamp(pow(0.35 / max(dot(studio2_lin(u.colorB.rgb), float3(0.2126, 0.7152, 0.0722)), 1e-3), 0.4), 1.0, 1.9);
    float3 L3 = float3(Lh * cel, sel);
    float Esun = 0.64 / (0.785 * sel);                           // flat lit sand: 0.64 direct + ~0.34 fill
    float3 sandLin = studio2_lin(u.colorB.rgb);
    float3 rd = normalize(float3(q, -f));
    float3 V = -rd;
    float rb = 0.75 * g;
    float3 Cb = float3(Pb, rb - G.D);                            // the ball, resting in its trench

    float qr = length(q);
    float edgePx = (qr - STUDIO2_RS * sS) * res.y;               // > 0: past the sand's edge

    // ---- rim: oiled walnut (Fill), or a brushed-steel lip set into a walnut top (Table)
    half3 rimC = half3(0.0h);
#ifdef SGX_NORIM
    if (false) {
#else
    if (edgePx > -1.0) {
#endif
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
#ifdef SGX_NOROOM
        float3 room = Rr * 0.1 + 0.1;
#else
        float3 room = studio2_room(Rr, Lh, el, sunC, skyC, sandLin);
#endif
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
            if (table) {                         // flat-sawn planks along x, 14 cm wide, butt-jointed
                float2 P = dq * rho;
                float plank = floor(P.y / 14.0);
                float jx = P.x + 71.0 * fract(plank * 0.382);            // joints staggered plank to plank
                float board = floor(jx / 130.0);
                seed = plank * 7.0 + board;
                gp = float2(jx - board * 130.0, P.y - (plank + 0.5) * 14.0);
                float sd = max(abs(gp.y) - 7.0, abs(gp.x - 65.0) - 65.0);    // ≤ 0 inside the board
                float seam = smoothstep(-0.05 - fpw, -0.05 + fpw, sd);
                woodLin *= 1.0 - 0.55 * seam;
            } else {                             // a bent ring: grain runs round it
                seed = 0.0;
                gp = float2(atan2(dq.y, dq.x) * STUDIO2_RS, (rho - STUDIO2_RS) + (hTop - z));
            }
#ifdef SGX_NOWOOD
            float3 alb = woodLin * (1.0 + 0.1 * sin(gp.y));
#else
            float3 alb = studio2_wood(gp, woodLin, fpw, seed);
#endif
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
        if (edgePx >= 0.5) return studio2_finish(c, q, aspect, bright, px);
        rimC = half3(c);
    }

    half4 ballC = half4(0.0h);
// ---- the ball: a mirror sphere resting in its trench (shaded first, only where it is, and
// done with where it covers the pixel — so its heavy shading isn't held through the sand's)
    float Db = Hc - Cb.z;
    float pixA = 1.0 / (f * res.y);                          // radians per pixel
#ifdef SGX_NOBALL
    if (false) {
#else
    if (length(q - Cb.xy * (f / Db)) < rb * f / (Db - rb) + 3.0 / res.y) {
#endif
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
#ifdef SGX_NOBENV
        float3 envBall = Rb * 0.5 + 0.5;
#else
        float3 envBall = studio2_ballEnv(Rb, Lh, el, sunC, skyC, sandRad, woodRad, aaB);
#endif
        float fr = pow(1.0 - NVb, 5.0);
        float3 ballCol = envBall * (float3(0.60, 0.595, 0.59) + float3(0.40, 0.405, 0.41) * fr);
        ballC = half4(half3(ballCol), half(covB));
        if (covB >= 1.0) return studio2_finish(ballCol, q, aspect, bright, px);
    }

    // ---- sand: composite the passes
    studio2_Acc A;
#ifdef SGX_DBG
    A.it = 0; A.ly = 0; A.fp = 0;
#endif
    A.T = 1.0h; A.gT = half2(0.0h); A.H = 0.0h; A.gH = half2(0.0h); A.top1 = half4(0.0h); A.top2 = half4(0.0h); A.sp = 100.0h;
#ifdef SGX_DBG2
    A.src = 0.0h;
#endif
    float r = length(x);
    float2 er = x / max(r, 1e-4);
    // The hub: every sweep starts or ends on the same closed loop round the centre, so inside
    // it the sand is always that loop's inner wall and the little mound it leaves — drawn
    // here directly (radially symmetric), blended into the composite across the wall.
    float hubIn = G.rs - 0.75 * STUDIO2_TW * g, hubOut = G.rs - 0.35 * STUDIO2_TW * g;
    float hubW = 1.0 - smoothstep(hubIn, hubOut, r);
    if (edgePx < 1.0 && r < STUDIO2_RS - 1.05 && hubW < 1.0) {
#ifdef SGX_NOATAN
        float phi = x.y * 0.1;
#else
        float phi = atan2(x.y, x.x);
#endif
        float2 ep = float2(-er.y, er.x);
        float ir = 1.0 / max(r, G.rs);
        // newest first: the sweep in progress, the previous one, the one settling under both.
        // A finished sweep ends on a circle (A = 0): at the rim, θ = Θ ≡ π·2N (so on the x
        // axis), going out; back at the hub's start (rs, 0) coming in.
#ifdef SGX_FAKECOMP
        { float dd = (fract(r * G.ipt) - 0.5) * G.pt; studio2_layer(A, dd, er, 1.0, G, Lh); A.T = 0.0h; }
#endif
        studio2_sweepComposite(A, sw0, G, x, r, phi, er, ep, Pb, Tb, Lh, ir);
        if (A.T >= 0.01h) {
            studio2_Sweep sw = studio2_load(u, 1);
            bool out = sw.chi > 0.0;
            studio2_sweepComposite(A, sw, G, x, r, phi, er, ep, out ? float2(cTh * G.R0, 0.0) : float2(G.rs, 0.0),
                                   out ? float2(0.0, cTh) : float2(0.0, -1.0), Lh, ir);
            if (A.T >= 0.01h) {
                sw = studio2_load(u, 2);
                out = sw.chi > 0.0;
                studio2_sweepComposite(A, sw, G, x, r, phi, er, ep, out ? float2(cTh * G.R0, 0.0) : float2(G.rs, 0.0),
                                       out ? float2(0.0, cTh) : float2(0.0, -1.0), Lh, ir);
            }
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

#ifdef SGX_DBG
    return float4(float(A.it) / 16.0, float(A.ly) / 8.0, float(A.fp) / 4.0, 1.0);
#endif
#ifdef SGX_RET3
    return float4(float(A.H), float2(A.gH), float(A.top1.x + A.top2.y));
#endif
#ifdef SGX_DBG2
    { float sid = float(A.src) - 3.0; if (A.src < 0.5h) return float4(0.0, 0.0, 0.0, 1.0);
      return float4(sid < 5.0 ? 1.0 : 0.0, (sid > 5.0 && sid < 15.0) ? 1.0 : 0.0, sid > 15.0 ? 1.0 : 0.0, 1.0) * (0.4 + 0.6 * float(A.top1.x)); }
#endif
    float3 sandCol = float3(0.0);
    {
        float H = float(A.H);
        float2 gH = float2(A.gH);
        if (r > STUDIO2_RS - 1.7) {  // the sand banks up against the wall, under everything
            float2 bk = studio2_ss(STUDIO2_RS - 1.7, STUDIO2_RS, r);
            float hb = 0.30 * bk.x * bk.x, dhb = 0.60 * bk.x * bk.y;
            H += float(A.T) * hb;
            gH += float2(A.gT) * hb + (float(A.T) * dhb) * er;
        }
        // Band-limit: where the grooves' spacing — the pitch, or a dense lobe flank's — nears a
        // couple of pixels, the relief fades to its average tone, evenly (a thumbnail reads as a
        // smooth drawing, a dense flank as a smooth band; no stripes, no moiré, no wedges).
        float detail = smoothstep(1.8, 3.6, min(G.pt, float(A.sp)) / fp);
        float2 gHd = gH * detail;
        half kk = half(clamp(0.36 * (G.D / (0.3 * g)) * (0.32 / tanEl), 0.0, 0.6));
        half S = 1.0h - 0.5h * kk;
#ifdef SGX_NOMARCH
        if (false) {
#else
        if (detail > 0.0) {
#endif
            half v1 = studio2_march(A.top1, G, tanEl, fp);
            // the second layer's own march only where two passes really blend (elsewhere it
            // shares the first's), so the shadow never jumps across a feather
            half b2 = half(smoothstep(0.18, 0.32, float(A.top2.x)));
            half v2 = b2 > 0.0h ? mix(v1, studio2_march(A.top2, G, tanEl, fp), b2) : v1;
            S = mix(S, 1.0h - A.top1.x * (1.0h - v1) - A.top2.x * (1.0h - v2), half(detail));
        }
#ifdef SGX_RET5
        return float4(float(S), detail, gHd);
#endif
        // fine grain: one hash per ~pixel-sized cell on a lattice turned 27° (no regular weave,
        // no axis-aligned blocks); its tilt averages down as a cell spans more grains
        float cs = max(0.042, 1.25 * fp);
        float2 xr = float2(0.891 * x.x - 0.454 * x.y, 0.454 * x.x + 0.891 * x.y);
#ifdef SGX_NOGRAIN
        uint hs = 0x80808080u;
#else
        uint hs = studio2_lattice(floor(xr * (1.0 / cs)));
#endif
        half4 hj = half4(half(hs & 0xffu), half((hs >> 8) & 0xffu), half((hs >> 16) & 0xffu), half(hs >> 24))
                 * (2.0h / 255.0h) - 1.0h;
        // (the ball-pressed trench floor is compacted: smoother)
        half ga = half(0.042 / cs) * (1.0h - 0.55h * half(smoothstep(-0.55 * G.D, -0.9 * G.D, H)));
        half2 gn = (0.085h * ga) * hj.xy;
        half3 n = half3(normalize(float3(float2(gn) - gHd, 1.0)));
        // albedo: a very faint, slow mottling (a smoothed triangle-wave interference: organic,
        // and far cheaper than noise) and a whisper of grain-sized speckle
        float mt = studio2_tri(x.x * 0.046 + x.y * 0.018 + 0.3 * studio2_tri(x.y * 0.0061 - x.x * 0.0034));
        half mot = 1.0h + 0.045h * half(mt * (1.5 - 0.5 * mt * mt));
        // grains a shade lighter or darker, and now and then a dark one: texture that shows in
        // the shade too, not just on the lit slopes
        half3 alb = half3(sandLin) * mot * (1.0h + ga * (0.05h * hj.z - 0.16h * half(hj.w > 0.86h)));
        // shadows from the rim (the low light clips over the wall) and from the ball
        float hEdge = hTop - 0.3 * eF, visRim = 1.0;
        if (r > STUDIO2_RS - (hEdge + 0.3) / tanEl - 0.5) {     // only within a shadow's length of the wall
            float bw = dot(x, Lh), cw = r * r - STUDIO2_RS * STUDIO2_RS;
            float tw = -bw + sqrt(max(bw * bw - cw, 0.0));
            float penR = 0.05 + tw * 0.06;
            visRim = smoothstep(hEdge - penR, hEdge + penR, H + tw * tanEl);
        }
        float visBall = 1.0, aoBall = 1.0;
#ifdef SGX_NOBALLSH
        rBall = 0.0;
#endif
        float3 vC = Cb - float3(x, H);
        float rBall = rb * (2.5 + 1.2 / tanEl);
#ifdef SGX_NOBALLSH
        rBall = 0.0;
#endif
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
        // the trench floor sees less sky (its average where the relief is band-limited)
        half aoT = mix(0.88h, 1.0h - 0.38h * half(clamp(-H / max(0.45 * g, 1e-3), 0.0, 1.0)), half(detail));
        half aoW = 1.0h - 0.18h * half(smoothstep(STUDIO2_RS - 1.2, STUDIO2_RS, r));
        // fill: the room (faintly cool, a touch more on the faces turned from the light) and
        // warm bounce off the lit sand around — strongest in a trench, off its lit far wall
        half3 sky = half3(skyC) * (0.22h * (0.62h + 0.38h * n.z) + 0.06h * max(dot(n.xy, -half2(Lh)), 0.0h));
        sky += half3(sunC * sandLin) * (0.15h + 0.08h * (1.0h - S));
        sky *= aoT * half(aoBall) * aoW;
        sandCol = float3(alb * (direct + sky));
#ifdef SGX_RET4
        return float4(sandCol, 1.0);
#endif

    }
    float3 col = mix(sandCol, float3(ballC.rgb), float(ballC.a));
    col = mix(col, float3(rimC), clamp(edgePx + 0.5, 0.0, 1.0));
    return studio2_finish(col, q, aspect, bright, px);
}