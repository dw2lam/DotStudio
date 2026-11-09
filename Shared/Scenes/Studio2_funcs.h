//  Studio2_funcs.h — ZEN GARDEN (shader id 68). File-scope helpers; prefix "studio2_".
//
//  A karesansui from above, with a little perspective: pale raked gravel in a low dark-wood
//  frame, three groups of stones (two on moss), and a little rake cart re-raking it. Which
//  composition is on the bed and where the cart is follow from (t, clock, date) alone; the
//  cart's path is planned and traced on the CPU (SandGarden in Studio2.swift) into a data
//  texture (slot 6): the track as a polyline with the rake's lifts and drops, a grid over
//  the bed whose cells list the newest raked segments whose footprint reaches them, and the
//  stones. A pixel walks its cell's list newest first, grouping consecutive segments of one
//  pass (their union is the pass: five tine grooves across it), and composites each pass
//  under the ones in front of it until the gravel is opaque — so the rake replaces whatever
//  was under it, the newest pass on top. A pass's ends are cut square, as a lifted rake
//  leaves them. The head of the track (its last vertex to the rake) comes in u.scene.
//  Relief normals are analytic (profile′(d)·∇d carried through the compositing); self-shadow
//  tests the light's ray against the crest on the light's side; the stones' shadows and the
//  gravel's darkening round them are baked on the CPU for the light (rows 258…, sampled
//  bilinearly, and flagging where a pixel need look for stones at all); the cart casts its
//  own by a short march. The light itself is worked out on the CPU too (u.scene[12…15]).
//  Lengths in cm; linear light, tone-mapped once.

constant float STUDIO2_PI = 3.14159265;
constant uint STUDIO2_ROW_COUNT = 0, STUDIO2_ROW_RING = 1, STUDIO2_ROW_STONE = 257, STUDIO2_ROW_SHADOW = 258;
constant int STUDIO2_K = 32;
constant float STUDIO2_TINES = 5.0;

struct studio2_Geo {
    float wr, sp, D;                 // rake width, tine pitch, groove depth (crest to trough)
    half hhw, hfe, hisp, hD, hsp;    // half-width, mask feather, 1/pitch, depth, pitch
};

struct studio2_Acc {
    half T; half2 gT;                // transmittance and its gradient
    half H; half2 gH;                // composited height and its gradient
    half4 top;                       // the most visible layer: (weight, d, light across, height)
};

// ---------------------------------------------------------------- small helpers

static inline uint studio2_hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
static inline uint studio2_lattice(float2 i) {
    int2 c = int2(i) + int2(0x4000);
    return studio2_hash(uint(c.x) * 0x27d4eb2du + uint(c.y) * 0x165667b1u);
}
// Value noise in [−1, 1] with its gradient (quintic fade): (n, dn/dx, dn/dy).
static inline float3 studio2_vnoise(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    const float k = 2.0 / 4294967295.0;
    float a = float(studio2_lattice(i)) * k - 1.0;
    float b = float(studio2_lattice(i + float2(1, 0))) * k - 1.0;
    float c = float(studio2_lattice(i + float2(0, 1))) * k - 1.0;
    float d = float(studio2_lattice(i + float2(1, 1))) * k - 1.0;
    float e = a - b - c + d;
    return float3(a + (b - a) * w.x + (c - a) * w.y + e * w.x * w.y,
                  dw.x * ((b - a) + e * w.y), dw.y * ((c - a) + e * w.x));
}
static inline float studio2_fbm(float2 p) {
    return studio2_vnoise(p).x * 0.55 + studio2_vnoise(p * 2.07 + 13.1).x * 0.3 + studio2_vnoise(p * 4.3 + 7.7).x * 0.15;
}
// Round specks: one jittered disc per cell of a lattice (cell size c, turned by the caller),
// radius r·c, anti-aliased over fp. Returns (coverage, hash 0…1, offset from its centre / r).
static inline float4 studio2_speck(float2 p, float c, float r, float fp, float salt) {
    float2 xr = p / c;
    uint h = studio2_lattice(floor(xr) + salt);
    float2 jc = float2(float(h & 0xffu), float((h >> 8) & 0xffu)) * ((1.0 - 2.0 * r) / 255.0) + r;
    float2 v = (fract(xr) - jc) * c;
    float rr = r * c * (0.7 + 0.3 * float((h >> 24) & 0xffu) / 255.0);
    float cov = 1.0 - smoothstep(rr - 0.6 * fp, rr + 0.6 * fp, length(v));
    return float4(cov, float((h >> 16) & 0xffu) / 255.0, v / max(rr, 1e-3));
}
// sRGB → linear, the usual cubic fit.
static inline float3 studio2_lin(float3 c) { return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); }
// Filmic shoulder: linear to k, then a smooth roll-off to white.
static inline float studio2_shoulder(float x) {
    const float k = 0.6;
    float y = max(x - k, 0.0) * (1.0 / (1.0 - k));
    return min(x, k) + (1.0 - k) * y / (1.0 + y);
}
// Distance outside the rectangle |x| ≤ b (Chebyshev: its level sets have mitred corners).
static inline float studio2_rect(float2 p, float2 b) { float2 d = abs(p) - b; return max(d.x, d.y); }

// ---------------------------------------------------------------- the raked groove

// Cross-section at signed distance d across a pass: five tine furrows, crest to crest, the
// crests at the pass's edges (so passes laid side by side, a rake-width apart, continue each
// other's rhythm). h = D·(cos⁴(πφ) − ⅜): narrow rounded crests, broad troughs, zero mean.
static inline half2 studio2_profile(half d, thread const studio2_Geo& G) {
    half ph = (d + G.hhw) * G.hisp;
    half c, s = sincos(ph * half(STUDIO2_PI), c);
    half c2 = c * c;
    return half2(G.hD * (c2 * c2 - 0.375h), -G.hD * 4.0h * c2 * c * s * half(STUDIO2_PI) * G.hisp);
}
// The pass replaces the gravel across its whole width, feathered just beyond it (so two
// passes side by side each cover their own side of the crest between them fully).
static inline half2 studio2_mask(half u, thread const studio2_Geo& G) {
    half k = 1.0h / (2.0h * G.hfe);
    half t = clamp((u - G.hhw) * k, 0.0h, 1.0h);
    return half2(1.0h - t * t * (3.0h - 2.0h * t), -6.0h * t * (1.0h - t) * k);
}

// Composite one pass (signed distance d, gd = ∇d, cov = how much of it is here: a cut end
// fades it) under what's already in front of it.
static inline void studio2_layer(thread studio2_Acc& a, half d, half2 gd, half cov,
                                 thread const studio2_Geo& G, float2 Lh) {
    half u = abs(d);
    half2 gu = d < 0.0h ? -gd : gd;
    half2 m = studio2_mask(u, G);
    m *= cov;
    half2 p0 = studio2_profile(d, G);
    half ea = m.x * p0.x;
    half2 dea = m.y * p0.x * gu + m.x * p0.y * gd;
    a.H += a.T * ea;
    a.gH += a.gT * ea + a.T * dea;
    half wv = a.T * m.x;
    if (wv > a.top.x) a.top = half4(wv, d, dot(half2(Lh), gd), p0.x);
    a.gT = a.gT * (1.0h - m.x) - (a.T * m.y) * gu;
    a.T *= 1.0h - m.x;
}

// Self-shadow of one layer: the crest on the light's side, the highest thing along the
// furrow's own profile, decides. L = (weight, d, light across (signed, along ∇d), height).
static inline half studio2_selfShadow(half4 L, thread const studio2_Geo& G, float tanEl, float fp) {
    half al = abs(L.z);
    if (L.x < 0.004h || al < 0.03h || G.D < 1e-3) return 1.0h;
    half ph = (L.y + G.hhw) * G.hisp;
    half ts = (L.z > 0.0h ? ceil(ph) - ph : ph - floor(ph)) * G.hsp;    // to that crest, cm
    half kr = half(tanEl) / al;                                          // ray rise per cm across
    half gap = L.w + ts * kr - 0.625h * G.hD;
    half pen = 0.12h * ts / al + half(1.2 * fp) * kr + 0.01h;
    return smoothstep(-pen, pen, gap);
}

// ---------------------------------------------------------------- the track

// Composite every raked pass near x, newest first: the head of the track (its last vertex
// to the rake, if the rake is down), then the cell's ring of segment indices, back from the
// newest. Runs of segments that follow on along the track (no lifted hop between them) are
// one pass, the nearest of them deciding (round joins); each pass is layered under the ones
// before it. Where a pass's run reaches the stroke's own end (the rake lifted, or the rake
// itself) or start (dropped), it is cut square across the track there.
struct studio2_Run {
    float best, side; float2 v;              // nearest segment: squared distance, side, offset
    float3 endPl;                            // cut plane at the run's newest end (heading, offset); 0: not cut
    float2 begA, begB; bool begCut;          // its oldest segment, and whether the rake dropped there
    bool open;
};
static inline void studio2_flush(thread studio2_Acc& A, thread studio2_Run& R, float2 x, float reach2,
                                 float aaE, thread const studio2_Geo& G, float2 Lh) {
    if (R.open && R.best < reach2) {
        float cov = 1.0;
        if (R.endPl.x != 0.0 || R.endPl.y != 0.0) cov *= 1.0 - saturate((dot(x, R.endPl.xy) - R.endPl.z) * aaE);
        if (R.begCut) {
            float2 bd = normalize(R.begB - R.begA);
            cov *= 1.0 - saturate(dot(R.begA - x, bd) * aaE);
        }
        if (cov > 0.0) {
            float d = sqrt(R.best);
            float sg = R.side < 0.0 ? -1.0 : 1.0;
            studio2_layer(A, half(sg * d), half2(sg * R.v / max(d, 1e-4)), half(cov), G, Lh);
        }
    }
    R.open = false; R.best = 1e9;
}
// Adds a segment to the run; true when the pixel is squarely inside it (its foot inside the
// segment, well within the pass's width): nothing else of this pass can matter here.
static inline bool studio2_addSeg(thread studio2_Run& R, float2 x, float2 a, float2 b, bool begCut, bool endCut,
                                  float solid2) {
    float2 ba = b - a, pa = x - a;
    float L2 = dot(ba, ba);
    if (!R.open) {
        R.open = true;
        float2 dir = L2 > 1e-10 ? ba * rsqrt(L2) : float2(1.0, 0.0);
        R.endPl = endCut ? float3(dir, dot(b, dir)) : float3(0.0);
    }
    R.begA = a; R.begB = b; R.begCut = begCut;
    float hu = dot(pa, ba) / max(L2, 1e-10), h = clamp(hu, 0.0, 1.0);
    float2 v = pa - ba * h;
    float d2 = dot(v, v);
    if (d2 < R.best) { R.best = d2; R.v = v; R.side = ba.x * pa.y - ba.y * pa.x; }
    // (past its end the pass goes on into the newer segment already seen, unless the rake
    // lifted there; past its start lies an older one not read yet, so that can't count)
    return d2 < solid2 && hu > 0.0 && !(hu >= 1.0 && endCut);
}
static inline void studio2_track(thread studio2_Acc& A, texture2d<float> data, constant FXUniforms& u,
                                 float2 x, thread const studio2_Geo& G, float2 Lh, float fp) {
    float reach = 0.5 * G.wr + 2.0 * float(G.hfe);
    float reach2 = reach * reach, gap = 0.6 * G.wr;
    float solid = 0.5 * G.wr, solid2 = solid * solid;
    float aaE = 1.0 / (1.2 * fp);
    studio2_Run R; R.open = false; R.best = 1e9; R.side = 1.0; R.v = float2(1, 0);
    R.endPl = float3(0.0); R.begA = R.begB = float2(0.0); R.begCut = false;
    float4 hd = u.scene[1];
    float runS = hd.z;
    float2 hb = u.scene[0].xy;
    float hl = length(hb - hd.xy) + reach;
    if (u.scene[2].y > 0.5 && length_squared(x - hb) < hl * hl) {   // the rake is down: the head, cut at the rake
        float2 b = hb;
        if (length_squared(b - hd.xy) < 1e-6) b = hd.xy + u.scene[0].zw * 0.01;
        if (studio2_addSeg(R, x, hd.xy, b, false, true, solid2)) {
            studio2_flush(A, R, x, reach2, aaE, G, Lh);
            if (A.T < 0.01h) return;
        }
    }
    float4 gd = u.scene[3];                                      // grid: origin, cell, columns
    int gx = int(gd.w);
    int gy = int(ceil(-2.0 * gd.y / gd.z));
    int2 c = clamp(int2(floor((x - gd.xy) / gd.z)), int2(0), int2(gx - 1, gy - 1));
    int cell = c.y * gx + c.x;
    int cnt = int(data.read(uint2(uint(cell) >> 2, STUDIO2_ROW_COUNT))[cell & 3]);
    int n = min(cnt, STUDIO2_K);
    int base = cell * STUDIO2_K;
    for (int j = 0; j < n; ++j) {
        uint e = uint(base + (cnt - 1 - j) % STUDIO2_K) * 2u;
        float4 sg = data.read(uint2(e & 1023u, STUDIO2_ROW_RING + (e >> 10)));        // (a, b)
        float4 sm = data.read(uint2((e + 1u) & 1023u, STUDIO2_ROW_RING + (e >> 10)));  // (s at a, s at b, cut)
        if (runS - sm.y > gap) {                                 // a different pass: the last one is done
            studio2_flush(A, R, x, reach2, aaE, G, Lh);
            if (A.T < 0.01h) return;
        }
        runS = sm.x;
        int cut = int(sm.z);
        if (studio2_addSeg(R, x, sg.xy, sg.zw, (cut & 1) != 0, (cut & 2) != 0, solid2)) {
            studio2_flush(A, R, x, reach2, aaE, G, Lh);
            if (A.T < 0.01h) return;
        }
    }
    studio2_flush(A, R, x, reach2, aaE, G, Lh);
}

// ---------------------------------------------------------------- stones and moss

struct studio2_Stone { float2 c; float r, h, ca, sa, el, moss, seed, a2, a3, a4; };
// Stone k: (x, y, bounding radius, height) from u.scene[6 + k], its shape (angle,
// elongation, moss, seed) and radius from the data texture's row 97.
static inline studio2_Stone studio2_loadStone(constant FXUniforms& u, texture2d<float> data, int k) {
    float4 a = u.scene[6 + k];
    float4 b = data.read(uint2(uint(k), STUDIO2_ROW_STONE));
    studio2_Stone s; s.c = a.xy; s.r = data.read(uint2(uint(8 + k), STUDIO2_ROW_STONE)).x; s.h = a.w;
    s.sa = sincos(b.x, s.ca); s.el = b.y; s.moss = b.z; s.seed = b.w;
    float sd = floor(b.w);
    s.a2 = 0.08 + 0.07 * fract(sd * 0.37); s.a3 = 0.05 + 0.05 * fract(sd * 0.61); s.a4 = 0.03 + 0.03 * fract(sd * 0.83);
    return s;
}
// The stone in its own frame: (t = how far out, 1 at the outline; outline radius R). The
// outline is a few harmonics of the angle round it, from the unit vector (no trig).
static inline float2 studio2_stoneT(thread const studio2_Stone& s, float2 p) {
    float2 v = p - s.c;
    float2 l = float2(s.ca * v.x + s.sa * v.y, (-s.sa * v.x + s.ca * v.y)) / float2(s.el, 1.0);
    float rr = length(l);
    float2 e = l / max(rr, 1e-5);
    float c2 = e.x * e.x - e.y * e.y, s2 = 2.0 * e.x * e.y;
    float c3 = e.x * (4.0 * e.x * e.x - 3.0), s3 = e.y * (3.0 - 4.0 * e.y * e.y);
    float c4 = c2 * c2 - s2 * s2, s4 = 2.0 * c2 * s2;
    float R = s.r * (1.0 + s.a2 * (0.6 * c2 + 0.8 * s2) + s.a3 * (0.8 * c3 - 0.6 * s3) + s.a4 * (0.28 * c4 + 0.96 * s4));
    return float2(rr / R, R);
}
// The stone's height at p (0 outside): a boulder, steep at the foot, its top cut by four
// planes in its own frame (so every stone, turned and stretched its own way, has its own
// facets, with ridges where they meet), lumpy if `lumpy`.
static inline float studio2_stoneH(thread const studio2_Stone& s, float2 p, bool lumpy) {
    float2 tr = studio2_stoneT(s, p);
    if (tr.x >= 1.0) return 0.0;
    float q = 1.0 - tr.x * tr.x;
    float2 v = p - s.c;
    float2 l = float2(s.ca * v.x + s.sa * v.y, -s.sa * v.x + s.ca * v.y) / (s.r * float2(s.el, 1.0));
    float o = fract(s.seed * 0.37);
    float fa = 1.0 + 0.10 * o - 0.62 * dot(l, float2(0.82, 0.57));
    float fb = 1.06 - 0.55 * dot(l, float2(-0.31, 0.95));
    float fc = 1.1 - 0.12 * o - 0.5 * dot(l, float2(-0.9, -0.42));
    float fd = 1.02 + 0.08 * o - 0.58 * dot(l, float2(0.45, -0.89));
    float sq = sqrt(q);
    float z = min(sq * (1.0 - 0.1 * q), min(min(fa, fb), min(fc, fd)) * (0.3 + 0.7 * sq));
    if (lumpy) z *= 1.0 + 0.07 * studio2_vnoise(v * 0.25 + s.seed).x * q;
    return s.h * z;
}
// The moss cushion's height at p (a mound round the foot, its edge ragged).
static inline float studio2_mossH(thread const studio2_Stone& s, float2 p, float t, float R) {
    if (s.moss <= 0.0) return 0.0;
    float out = (t - 1.0) * R;                                   // cm beyond the stone's outline
    float edge = s.moss * (0.78 + 0.32 * studio2_vnoise((p - s.c) * 0.35 + s.seed * 3.0).x);
    float k = 1.0 - smoothstep(edge - 1.2, edge, out);
    return k * (1.3 - 0.8 * saturate(out / max(edge, 0.1))) * (0.85 + 0.15 * studio2_vnoise(p * 2.2).x);
}

// ---------------------------------------------------------------- the cart

// The cart in its own frame: x along its heading from the body's centre, y across. Returns
// (height of the top surface here, part: 0 none, 1 body, 2 wheel, 3 tow bar, 4 rake, 5 knob).
static inline float2 studio2_cartAt(float2 l, float wr, float lift) {
    float2 res = float2(0.0, 0.0);
    // rake bar, behind on the track's end
    float2 rb = abs(l - float2(-5.5, 0.0)) - float2(0.32, 0.5 * wr + 0.25);
    if (max(rb.x, rb.y) < 0.0) res = float2(1.5 + 0.8 * lift, 4.0);
    // tow bars
    float2 tb = float2(abs(l.x + 4.2) - 1.3, abs(abs(l.y) - 1.4) - 0.14);
    if (max(tb.x, tb.y) < 0.0 && res.x < 1.6) res = float2(1.6, 3.0);
    // wheels
    float2 wl = float2(abs(abs(l.x) - 1.9) - 1.1, abs(abs(l.y) - 2.95) - 0.42);
    if (max(wl.x, wl.y) < 0.0) res = float2(2.3, 2.0);
    // body: a rounded box
    float2 bq = abs(l) - float2(3.0, 2.35) + 1.0;
    float bd = length(max(bq, 0.0)) + min(max(bq.x, bq.y), 0.0) - 1.0;
    if (bd < 0.0) res = float2(2.7 * (0.55 + 0.45 * sqrt(saturate(-bd / 0.7))), 1.0);
    if (length(l - float2(0.4, 0.0)) < 0.55) res = float2(3.1, 5.0);
    return res;
}

// ---------------------------------------------------------------- materials

// Old dark-stained cedar, linear albedo: gp = (along the grain, across it), cm; fpw = cm per
// pixel; seed varies the beam. The face cuts the growth rings at a depth that wanders along
// the beam, so they show as long runs and nested arches; noise warps it all; late wood
// darker; streaks along the grain; pores as fine dashes. Fades to its average near a pixel.
static inline float3 studio2_wood(float2 gp, float3 base, float fpw, float seed) {
    float h = fract(seed * 0.6180339 + 0.31);
    float x = gp.x + seed * 53.7, y = gp.y;
    float3 n1 = studio2_vnoise(float2(x * 0.018, y * 0.11 + seed * 7.1));
    float3 n2 = studio2_vnoise(float2(x * 0.061 + 11.0, y * 0.37));
    float yw = y + 1.9 * n1.x + 0.55 * n2.x;
    float yp = yw - (3.0 * sin(x * 0.017 + 6.0 * h) + 1.2 * sin(x * 0.051 + 2.0 + 4.0 * h));
    float dep = max(2.2 + 1.9 * sin(x * 0.037 + 9.0 * h) + 0.9 * sin(x * 0.093 + 4.0 * h), 0.35);
    float R = sqrt(yp * yp + dep * dep);
    float sp = 1.6 + 0.5 * n1.x;
    float rp = fract(R * sp + 0.18 * n2.x);
    float late = smoothstep(0.55, 0.86, rp) * (1.0 - smoothstep(0.9, 1.0, rp));
    float ringAA = 1.0 - smoothstep(0.2, 0.55, fpw * sp * 2.0);
    float3 s1 = studio2_vnoise(float2(x * 0.008 + 3.0, yw * 0.9));
    float3 s2 = studio2_vnoise(float2(x * 0.02 + 7.0, yw * 2.6));
    float st = 0.65 * s1.x + 0.35 * s2.x;
    float3 pn = studio2_vnoise(float2(x * 1.6, yw * 16.0));
    float pores = smoothstep(0.35, 0.8, pn.x);
    float poreAA = 1.0 - smoothstep(0.015, 0.04, fpw);
    float3 c = base * (0.86 + 0.34 * st + 0.12 * (h - 0.5));
    c = mix(c, c * float3(0.78, 0.76, 0.78), smoothstep(-0.2, -0.7, st));
    c = mix(c, c * float3(1.3, 1.16, 1.0), 0.5 * smoothstep(0.3, 0.75, st));
    c *= 1.0 - mix(0.12, 0.42 * late, ringAA);
    c *= 1.0 - 0.45 * pores * poreAA;
    return c;
}

// Weathered granite, linear albedo: grey with warm and cool patches, round dark (mica) and
// pale (quartz) specks, lichen; moss in the hollows of its top (mossy = 0…1).
static inline float3 studio2_stoneAlb(float2 p, float seed, float fp, float up, float mossy) {
    float m = studio2_vnoise(p * 0.16 + seed).x * 0.65 + studio2_vnoise(p * 0.47 + seed * 1.7).x * 0.35;
    float3 c = mix(float3(0.085, 0.082, 0.08), float3(0.19, 0.18, 0.165), 0.5 + 0.55 * m);
    c = mix(c, c * float3(1.18, 1.03, 0.84), smoothstep(0.1, 0.6, studio2_vnoise(p * 0.07 + seed * 2.0).x));
    float aa = 1.0 - smoothstep(0.06, 0.2, fp);
    float4 sk = studio2_speck(float2(0.94 * p.x - 0.34 * p.y, 0.34 * p.x + 0.94 * p.y), 0.3, 0.3, fp, 51.0 + seed);
    c *= 1.0 + aa * sk.x * (sk.y < 0.35 ? -0.45 : (sk.y > 0.75 ? 0.5 : 0.0));
    float li = smoothstep(0.3, 0.65, m * 0.7 + 0.3 * studio2_vnoise(p * 0.9 + seed).x);
    c = mix(c, float3(0.30, 0.31, 0.26), 0.3 * li);
    float mn = studio2_vnoise(p * 0.6 + seed * 4.0).x * 0.6 + studio2_vnoise(p * 1.7 + seed).x * 0.4;
    float mo = mossy * smoothstep(0.8, 0.97, up) * smoothstep(0.15, 0.5, mn - 0.6 * m) * 0.85;
    return mix(c, float3(0.045, 0.085, 0.022) * (0.85 + 0.3 * mn), mo);
}

// ---------------------------------------------------------------- the scene

static inline float4 studio2_finish(float3 col, float2 q, float aspect, float bright, float2 px) {
    col *= bright * (1.0 - 0.10 * dot(q, q) / (0.25 * (aspect * aspect + 1.0)));
    float Ly = dot(col, float3(0.2126, 0.7152, 0.0722));
    float3 a = col * (studio2_shoulder(Ly) / max(Ly, 1e-5));
    float3 o = linearToSrgb(saturate(mix(a, float3(dot(a, float3(0.2126, 0.7152, 0.0722))), smoothstep(0.9, 1.6, Ly) * 0.5)));
    return float4(o + bandDither(px) * 1.5, 1.0);
}

// The light, the same for every pixel, worked out on the CPU (SandGarden.light) and read
// where it's needed (so it isn't held through the heavy middle of the shader).
struct studio2_Light { float2 Lh; float tanEl; float3 L3, sun, sky; float Esun; };
static inline studio2_Light studio2_light(constant FXUniforms& u) {
    studio2_Light L;
    float4 a = u.scene[12];
    L.Lh = a.xy; L.tanEl = a.z; L.L3 = float3(a.xy * u.scene[15].x, a.w);
    L.sun = u.scene[13].rgb; L.sky = u.scene[14].rgb; L.Esun = u.scene[14].w;
    return L;
}

// ---- the frame: dark beams round the bed (top at hB), mitred at the corners; beyond them
// (Garden framing) a dark slate floor
constant float STUDIO2_HB = 2.0;
static inline float3 studio2_frame(constant FXUniforms& u, float2 xg, float Hc, float f, float res_y, float fp,
                                   float2 B, float3 V) {
    studio2_Light L = studio2_light(u);
    const float hB = STUDIO2_HB, bw = 7.0, eF = 0.6;
    float2 xt = xg * (Hc - hB) / Hc;                             // the ray at the frame's top
    float et = studio2_rect(xt, B), eg = studio2_rect(xg, B), eo = studio2_rect(xt, B + bw);
    if (eo > 0.0) {                                              // the floor beyond the frame
        float n0 = studio2_fbm(xg * 0.05), n1 = studio2_vnoise(xg * 0.9).x;
        float3 alb = float3(0.035, 0.036, 0.04) * (1.0 + 0.25 * n0 + 0.08 * n1);
        float2 tl = fract(xg / 40.0 + 0.5);
        float jt = min(min(tl.x, 1.0 - tl.x), min(tl.y, 1.0 - tl.y)) * 40.0;
        alb *= mix(0.55, 1.0, smoothstep(0.1, 0.25 + fp, jt));
        return alb * (L.sun * (L.Esun * 0.785 * L.L3.z) + L.sky * 0.25);
    }
    float z; float3 nr; float2 P;
    if (et >= eF) { z = hB; nr = float3(0, 0, 1); P = xt; }
    else if (et > 0.0) {                                         // the rounded inner edge
        float k = 1.0 - et / eF;
        z = hB - eF * (1.0 - sqrt(max(1.0 - k * k, 0.0)));
        P = xt;
        float2 ax = (abs(xt.x) - B.x > abs(xt.y) - B.y) ? float2(-sign(xt.x), 0.0) : float2(0.0, -sign(xt.y));
        nr = normalize(float3(ax * k, sqrt(max(1.0 - k * k, 0.0))));
    } else {                                                     // the inner face
        z = hB * eg / max(eg - et, 1e-4);
        P = xg * (Hc - z) / Hc;
        float2 ax = (abs(P.x) - B.x > abs(P.y) - B.y) ? float2(-sign(P.x), 0.0) : float2(0.0, -sign(P.y));
        nr = float3(ax, 0.0);
    }
    float fpw = (Hc - z) / (f * res_y);
    bool vert = abs(P.x) - B.x > abs(P.y) - B.y;
    float2 gp = vert ? float2(P.y, abs(P.x) - B.x) : float2(P.x, abs(P.y) - B.y);
    float seed = (vert ? (P.x > 0.0 ? 1.0 : 2.0) : (P.y > 0.0 ? 3.0 : 4.0)) * 5.3;
    float3 alb = studio2_wood(gp, studio2_lin(u.colorA.rgb), fpw, seed);
    float mj = abs((abs(P.x) - B.x) - (abs(P.y) - B.y)) * 0.7071;  // the mitre joint
    alb *= mix(0.35, 1.0, smoothstep(0.02, 0.06 + fpw, mj));
    float NL = max(dot(nr, L.L3), 0.0);
    float3 Hv = normalize(L.L3 + V);
    float NH = max(dot(nr, Hv), 0.0);
    const float a2 = 0.12;                                       // oiled, satin
    float Dg = a2 / (STUDIO2_PI * pow(NH * NH * (a2 - 1.0) + 1.0, 2.0));
    return alb * (L.sun * (L.Esun * 0.785 * NL) + L.sky * 0.26 * (0.6 + 0.4 * nr.z))
         + L.sun * (L.Esun * NL * 0.04 * STUDIO2_PI * 0.25 * Dg);
}

// ---- the cart: where it covers the pixel, its colour (a = 1)
static inline float4 studio2_cart(constant FXUniforms& u, float2 xg, float Hc, float wr, float3 V) {
    float2 cartP = u.scene[5].xy, cartD = u.scene[5].zw;
    float2 cartN = float2(-cartD.y, cartD.x);
    float lift = u.scene[2].w;
    float2 xc = xg * (Hc - 2.5) / Hc;                            // near the cart's top
    float2 v = xc - cartP;
    float2 l = float2(dot(v, cartD), dot(v, cartN));
    if (dot(l, l) > 90.0 || max(abs(l.x + 1.5) - 4.8, abs(l.y) - (0.5 * wr + 0.6)) > 0.0) return float4(0.0);
    float2 pa = studio2_cartAt(l, wr, lift);
    if (pa.y < 0.5) return float4(0.0);
    studio2_Light L = studio2_light(u);
    float e = 0.05;
    float hx = studio2_cartAt(l + float2(e, 0), wr, lift).x - studio2_cartAt(l - float2(e, 0), wr, lift).x;
    float hy = studio2_cartAt(l + float2(0, e), wr, lift).x - studio2_cartAt(l - float2(0, e), wr, lift).x;
    float3 nl = normalize(float3(-hx / (2.0 * e), -hy / (2.0 * e), 1.0));
    if (abs(hx) > 0.5 || abs(hy) > 0.5) nl = float3(0, 0, 1);    // a part's edge, not a slope
    float3 nw = float3(cartD * nl.x + cartN * nl.y, nl.z);
    float3 alb; float rough = 0.5, spec = 0.04;
    int part = int(pa.y + 0.5);
    if (part == 1) { alb = float3(0.42, 0.28, 0.15) * (1.0 + 0.12 * studio2_vnoise(float2(l.x * 0.6, l.y * 9.0)).x); rough = 0.35; }
    else if (part == 2) { alb = float3(0.02, 0.02, 0.022); float cyl = abs(fract(l.x) - 0.5); alb *= 1.0 + 0.4 * cyl;
                          nw = normalize(float3(cartD * clamp((abs(l.x) - 1.9) / 1.15, -1.0, 1.0) * sign(l.x), 0.9)); rough = 0.6; }
    else if (part == 5) { alb = float3(0.55, 0.40, 0.16); spec = 0.6; rough = 0.25;
                          float2 kv = (l - float2(0.4, 0.0)) / 0.55; nw = normalize(float3(cartD * kv.x + cartN * kv.y, sqrt(max(1.0 - dot(kv, kv), 0.05)))); }
    else { alb = float3(0.06, 0.06, 0.065); spec = 0.35; rough = 0.3; }
    float NL = max(dot(nw, L.L3), 0.0);
    float3 Hv = normalize(L.L3 + V);
    float NH = max(dot(nw, Hv), 0.0);
    float a2 = rough * rough * rough * rough;
    float Dg = a2 / (STUDIO2_PI * pow(NH * NH * (a2 - 1.0) + 1.0, 2.0));
    return float4(alb * (L.sun * (L.Esun * 0.785 * NL) + L.sky * 0.3 * (0.5 + 0.5 * nw.z))
                + L.sun * (L.Esun * NL * spec * STUDIO2_PI * 0.25 * Dg), 1.0);
}

// ---- the stones (and the moss at their feet): what this pixel's ray meets. Returns the
// stone's colour and coverage (rgb, a: 1 = done), and the mossiest stone here (index, height).
struct studio2_StoneHit { half4 c; int mossI; half mossH; };
static inline studio2_StoneHit studio2_stones(constant FXUniforms& u, texture2d<float> data, float2 xg, float Hc,
                                               float fp, int nStones) {
    studio2_StoneHit R; R.c = half4(0.0h); R.mossI = -1; R.mossH = 0.0h;
        for (int i = 0; i < nStones; ++i) {
        float4 sa = u.scene[6 + i];
        // (the stone, seen from the camera's height, leans out from the screen's centre)
        float ext = sa.z + max(5.0, length(xg) * sa.w / (Hc - sa.w)) + 0.3;
        float2 dv = xg - sa.xy;
        if (dot(dv, dv) > ext * ext) continue;
        studio2_Stone s = studio2_loadStone(u, data, i);
        // where the ray is at the stone's mid-height: well outside its outline there, the
        // stone can't be under this pixel (a cheap test before the fixed point)
        float2 tm = studio2_stoneT(s, xg * (Hc - 0.5 * s.h) / Hc);
        if (tm.x < 1.25) {
            float z = 0.5 * s.h; float2 p = xg;
                        for (int k = 0; k < 3; ++k) { p = xg * (Hc - z) / Hc; z = studio2_stoneH(s, p, false); }
            float2 tr = studio2_stoneT(s, p);
            if (tr.x < 1.0) {
                studio2_Light L = studio2_light(u);
                float e = 0.06;
                float hx = studio2_stoneH(s, p + float2(e, 0), false) - z;
                float hy = studio2_stoneH(s, p + float2(0, e), false) - z;
                float3 ln = studio2_vnoise((p - s.c) * 0.5 + s.seed);   // weathering: a lumpy bump
                float lw = 0.18 * s.h / s.r * (1.0 - tr.x * tr.x);
                float3 n = normalize(float3(-hx / e - lw * ln.y, -hy / e - lw * ln.z, 1.0));
                float3 alb = studio2_stoneAlb(p - s.c, s.seed, fp, n.z, s.moss > 0.0 ? 1.0 : 0.3);
                float vis = 1.0;                                 // its own ridges toward the light
                                for (int k = 1; k <= 2; ++k) {
                    float tt = float(k) * 1.2;
                    vis = min(vis, smoothstep(-0.3, 0.3, z + tt * L.tanEl - studio2_stoneH(s, p + L.Lh * tt, false)));
                }
                float NL = max(dot(n, L.L3), 0.0);
                float foot = 0.55 + 0.45 * smoothstep(0.98, 0.7, tr.x);  // the foot, in its own gloom
                float3 c = alb * (L.sun * (L.Esun * 0.785 * NL * vis) + (L.sky * 0.24 * (0.45 + 0.55 * n.z)
                                  + L.sun * studio2_lin(u.colorB.rgb) * 0.14 * (1.0 - n.z)) * foot);
                R.c = half4(half3(c), half(saturate((1.0 - tr.x) * tr.y / (1.2 * fp))));
                if (R.c.a >= 1.0h) return R;
            }
        }
        if (s.moss > 0.0) {
            float2 t0 = studio2_stoneT(s, xg);
            float mh = studio2_mossH(s, xg, t0.x, t0.y);
            if (mh > 0.02 && half(mh) > R.mossH) { R.mossH = half(mh); R.mossI = i; }
        }
    }
    return R;
}

static inline float4 studio2_scene(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u,
                                   texture2d<float> data) {
    bool haveTrack = data.get_width() == 1024 && u.scene[2].z > 0.5;
    float aspect = res.x / res.y;
    float2 B = haveTrack ? u.scene[4].xy : float2(max(50.0 * clamp(aspect, 0.5, 3.0) - 4.0, 30.0), 46.0);
    float wr = haveTrack ? u.scene[4].z : 8.0 * clamp(u.p0.z, 0.6, 1.6);
    int nStones = haveTrack ? int(u.scene[4].w) : 0;
    float bright = haveTrack ? u.scene[13].w : 1.0;

    // ---- camera: straight down from Hc, focal length f (screen height = 1). Fill: the bed and
    // a sliver of its frame fill the screen; Garden: pulled back to show the whole frame.
    float2 q = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);
    const float f = 3.0;
    float halfH = u.p0.w > 0.5 ? 60.0 : 50.0;                    // cm of the sand plane in half the screen
    if (aspect < 1.0) halfH /= aspect;
    float Hc = f * halfH / 0.5;
    float fp = halfH * 2.0 / res.y;                              // cm per pixel on the sand
    float2 xg = q * (Hc / f);                                    // the ray at the sand
    float3 V = -normalize(float3(q, -f));

    if (haveTrack) {                                             // the cart (in front of the frame's inner face)
        float4 cart = studio2_cart(u, xg, Hc, wr, V);
        if (cart.a > 0.5) return studio2_finish(cart.rgb, q, aspect, bright, px);
    }
    if (studio2_rect(xg * (Hc - STUDIO2_HB) / Hc, B) > 0.0 || studio2_rect(xg, B) > 0.0)
        return studio2_finish(studio2_frame(u, xg, Hc, f, res.y, fp, B, V), q, aspect, bright, px);
    if (!haveTrack)
        return studio2_finish(studio2_lin(u.colorB.rgb) * 0.8, q, aspect, bright, px);
    // the stones' shadows and contact darkening, baked on the CPU for this light
    // (SandGarden.State.bakeShadows): bilinear between the four samples round x. A sample is
    // negative near a stone: only there need a pixel look for stones and moss.
    float2 shade;
    {
        float res = u.scene[15].y; int nx = int(u.scene[15].z);
        float2 g = (xg + B) / res;
        float2 g0 = floor(g), fr = g - g0;
        int k = int(g0.y) * nx + int(g0.x);
        float4 a = data.read(uint2(uint(k >> 1) & 1023u, STUDIO2_ROW_SHADOW + uint(k >> 11)));
        float4 b = data.read(uint2(uint((k + nx) >> 1) & 1023u, STUDIO2_ROW_SHADOW + uint((k + nx) >> 11)));
        float2 s00 = (k & 1) ? a.zw : a.xy, s10, s01 = ((k + nx) & 1) ? b.zw : b.xy, s11;
        if ((k & 1) == 0) s10 = a.zw;
        else s10 = data.read(uint2(uint((k + 1) >> 1) & 1023u, STUDIO2_ROW_SHADOW + uint((k + 1) >> 11))).xy;
        if (((k + nx) & 1) == 0) s11 = b.zw;
        else s11 = data.read(uint2(uint((k + nx + 1) >> 1) & 1023u, STUDIO2_ROW_SHADOW + uint((k + nx + 1) >> 11))).xy;
        if (min(min(s00.y, s10.y), min(s01.y, s11.y)) >= 0.0) nStones = 0;
        shade = mix(mix(abs(s00), abs(s10), fr.x), mix(abs(s01), abs(s11), fr.x), fr.y);
    }
    studio2_StoneHit SH = studio2_stones(u, data, xg, Hc, fp, nStones);
    if (SH.c.a >= 1.0h) return studio2_finish(float3(SH.c.rgb), q, aspect, bright, px);

    // ---- gravel: composite the raked passes
    studio2_Geo G;
    G.wr = wr; G.sp = wr / STUDIO2_TINES;
    G.D = 0.62 * G.sp * clamp(u.p1.x, 0.0, 1.0);                 // ~6 mm crest to trough at the default relief
    G.hhw = half(0.5 * wr); G.hfe = half(max(0.035 * wr, 0.6 * fp)); G.hisp = half(1.0 / G.sp);
    G.hD = half(G.D); G.hsp = half(G.sp);
    studio2_Acc A;
    A.T = 1.0h; A.gT = half2(0.0h); A.H = 0.0h; A.gH = half2(0.0h); A.top = half4(0.0h);
    if (SH.mossH < 0.9h) studio2_track(A, data, u, xg, G, u.scene[12].xy, fp);
    float H = float(A.H);
    studio2_Light L = studio2_light(u);
    float3 sandLin = studio2_lin(u.colorB.rgb);
    float2 x = xg;
    // Band-limit: as the tine pitch nears a couple of pixels (a small card), the relief fades
    // to its average tone, evenly — a soft drawing, never moiré.
    float detail = smoothstep(1.6, 3.2, G.sp / fp);
    float2 gHd = float2(A.gH) * detail;
    half S = 1.0h - 0.30h * half(clamp(u.p1.x, 0.0, 1.0)) * half(1.0 - detail);
    if (detail > 0.0) {
        half v1 = studio2_selfShadow(A.top, G, L.tanEl, fp);
        S = mix(S, 1.0h - A.top.x * (1.0h - v1), half(detail));
    }
    // Grain: fine granite gravel — on each of two lattices turned against each other and the
    // screen, one jittered grain per cell (pale, mid or dark: quartz, feldspar, mica), each a
    // tiny dome — fading to their average as they near a pixel; and a faint, slow mottling
    // (a folded triangle-wave interference: organic, and far cheaper than noise).
    float2 gb = float2(0.0); float gt = 1.0;
    for (int o = 0; o < 2; ++o) {
        float gc = o == 0 ? 0.24 : 0.47;
        float2 xr = (o == 0 ? float2(0.966 * x.x - 0.259 * x.y, 0.259 * x.x + 0.966 * x.y)
                            : float2(0.574 * x.x + 0.819 * x.y, -0.819 * x.x + 0.574 * x.y) + 31.0) / gc;
        uint hg = studio2_lattice(floor(xr) + (o == 0 ? 911.0 : 377.0));
        float2 jc = float2(float(hg & 0xffu), float((hg >> 8) & 0xffu)) * (0.44 / 255.0) + 0.28;
        float2 gv = (fract(xr) - jc) * gc;
        float gsel = float((hg >> 16) & 0xffu) / 255.0;
        float gr = gc * (0.29 + 0.15 * float((hg >> 24) & 0xffu) / 255.0);
        float inG = (1.0 - smoothstep(gr - 0.6 * fp, gr + 0.6 * fp, length(gv))) * (1.0 - smoothstep(0.3 * gc, 0.65 * gc, fp));
        float tone = gsel < 0.10 ? 0.6 : (gsel < 0.30 ? 1.13 : (gsel < 0.42 ? 0.88 : 1.0));
        gt *= mix(1.0, tone, inG * (o == 0 ? 1.0 : 0.6));
        gb += gv / max(gr, 0.03) * (0.4 * inG);
    }
    half3 n = half3(normalize(float3(gb - gHd, 1.0)));
    float m1 = abs(fract(x.x * 0.031 + x.y * 0.012 + 0.35 * abs(fract(x.y * 0.0071 - x.x * 0.0043) - 0.5)) - 0.5) * 4.0 - 1.0;
    float m2 = abs(fract(x.y * 0.043 - x.x * 0.017 + 0.3 * m1) - 0.5) * 4.0 - 1.0;
    float3 alb = sandLin * (1.0 + 0.025 * m1 + 0.02 * m2) * gt;

    // ---- shadows on the gravel: the frame (the low light clips over it), the stones, the cart
    float vis;
    {
        float2 sgn = sign(L.Lh);
        float2 tx = (B * sgn - x) / max(abs(L.Lh), 1e-4) * sgn;   // distance along Lh to each wall
        float tw = min(tx.x, tx.y);
        float pen = 0.05 + tw * 0.04;
        vis = smoothstep(STUDIO2_HB - pen, STUDIO2_HB + pen, H + tw * L.tanEl);
    }
    vis = min(vis, shade.x);
    float ao = shade.y;
    {
        float2 cartP = u.scene[5].xy, cartD = u.scene[5].zw;
        float tmax = 3.2 / L.tanEl;
        float2 v = x - cartP;
        if (dot(v, v) < (tmax + 9.0) * (tmax + 9.0)) {
            float2 cartN = float2(-cartD.y, cartD.x);
                        for (int k = 0; k < 5; ++k) {
                float tt = (float(k) + 0.5) / 5.0 * tmax;
                float2 w = x + L.Lh * tt - cartP;
                float hh = studio2_cartAt(float2(dot(w, cartD), dot(w, cartN)), wr, u.scene[2].w).x;
                float pn = 0.08 + 0.05 * tt;
                vis = min(vis, smoothstep(-pn, pn, H + tt * L.tanEl - hh));
            }
            ao *= 1.0 - 0.35 * exp(-dot(v, v) / 30.0);
        }
    }

    // ---- light the gravel: rough, matte (Oren–Nayar-ish: flatter than Lambert, no specular)
    half3 hL = half3(L.L3), hV = half3(V);
    half NL = dot(n, hL), NV = max(dot(n, hV), 0.0h);
    half sON = dot(hL, hV) - NL * NV;
    half on = max(NL, 0.0h) * (0.785h + 0.33h * (sON > 0.0h ? sON / max(max(NL, NV), 0.001h) : 0.0h));
    half3 direct = half3(L.sun) * (half(L.Esun) * on * S * half(vis));
    half aoT = mix(0.9h, 1.0h - 0.30h * half(clamp(-H / max(G.D, 1e-3) - 0.1, 0.0, 1.0)), half(detail));
    half dark = half(1.0 - smoothstep(0.06, 0.25, dot(sandLin, float3(0.2126, 0.7152, 0.0722))));
    half3 sky = half3(L.sky) * ((0.22h + 0.10h * dark) * (0.62h + 0.38h * n.z) + 0.05h * max(dot(n.xy, -half2(L.Lh)), 0.0h));
    sky += half3(L.sun * sandLin) * (0.12h + 0.08h * (1.0h - S));
    sky *= aoT * half(ao);
    float3 col = float3(half3(alb) * (direct + sky));

    // ---- moss over the gravel at the stones' feet
    if (SH.mossI >= 0) {
        studio2_Stone s = studio2_loadStone(u, data, SH.mossI);
        float mH = float(SH.mossH);
        float e = 0.12;
        float2 t1 = studio2_stoneT(s, x + float2(e, 0)), t2 = studio2_stoneT(s, x + float2(0, e));
        float2 t0 = studio2_stoneT(s, x);
        float mx = studio2_mossH(s, x + float2(e, 0), t1.x, t1.y) - mH, my = studio2_mossH(s, x + float2(0, e), t2.x, t2.y) - mH;
        // cushion moss: round tufts at two sizes, each a little dome, between them shadow
        float fine = 1.0 - smoothstep(0.05, 0.16, fp);
        float4 t1a = studio2_speck(float2(0.8 * x.x - 0.6 * x.y, 0.6 * x.x + 0.8 * x.y), 0.42, 0.42, fp, 7.0);
        float4 t2a = studio2_speck(float2(0.26 * x.x + 0.97 * x.y, -0.97 * x.x + 0.26 * x.y), 0.19, 0.4, fp, 19.0);
        float2 tb = (t1a.zw * t1a.x * 0.9 + t2a.zw * t2a.x * 0.6) * fine;
        float3 nm = normalize(float3(-mx / e + tb.x, -my / e + tb.y, 1.0));
        float blob = studio2_vnoise(x * 0.55 + s.seed).x;
        float tone = (0.8 + 0.3 * blob) * mix(1.0, 0.72 + 0.4 * t1a.x * (0.7 + 0.3 * t2a.x) + 0.15 * t1a.y, fine);
        float3 malb = mix(float3(0.030, 0.060, 0.016), float3(0.085, 0.12, 0.03), saturate(0.5 + 0.6 * blob)) * tone;
        float NLm = max(dot(nm, L.L3), 0.0);
        float aom = 1.0 - 0.5 * exp(-max(t0.x - 1.0, 0.0) * t0.y / 1.0);
        float3 mc = malb * (L.sun * (L.Esun * 0.785 * NLm * vis) + L.sky * 0.3 * aom);
        col = mix(col, mc, saturate(mH / 0.12));
    }
    if (SH.c.a > 0.0h) col = mix(col, float3(SH.c.rgb), float(SH.c.a));
    return studio2_finish(col, q, aspect, bright, px);
}
