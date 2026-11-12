//  Bloom_funcs.h — the Bloom pack: Bloom (79). Every symbol is "bloom_". Uses Clocks_funcs.h for
//  the captions' type (TextAtlas face 0, SF Pro Light), and CellKit_funcs.h for the layers, the
//  glyphs and the LED cells it shares with Penguin (80).
//
//  One flower drawn procedurally — SDF petals with crinkled edges, a stamen boss, a stem and
//  leaves (or a sprig of gypsophila) — evaluated twice a pixel:
//    • at the centre of the pixel's cell, sharp (aa = one cell): what the cell shows — a glyph
//      coloured by it (Glyphs) or a rounded LED cell (Pixels);
//    • at the pixel itself, soft (aa = a few cells, no fine texture): the blurred haze behind the
//      glyphs and the glow around the LEDs.
//  Only the flower is celled; the sky is a smooth gradient. Time is stepped to 24 fps.
//
//  Frame: p in screen heights, x right from the centre, y UP from the bottom edge (the flower
//  grows from below the frame). Colours are linear inside, display sRGB out.

#include "CellKit_funcs.h"

constant float BLOOM_FPS = 24.0;

/// A slow, never-repeating breeze in −1…1 (three incommensurate swells).
static inline float bloom_wind(float t, float seed) {
    return 0.55 * sin(0.47 * t + seed) + 0.30 * sin(0.83 * t + 1.9 + 1.7 * seed)
         + 0.15 * sin(1.61 * t + 0.7 + 2.3 * seed);
}

/// Gusts: a slow swell 0…1 that sometimes lifts the breeze.
static inline float bloom_gust(float t) {
    float g = 0.5 + 0.5 * sin(0.13 * t + 0.4) * sin(0.071 * t + 2.0);
    return g * g;
}

static inline float3 bloom_lin(float r, float g, float b) { return srgbToLinear(float3(r, g, b) / 255.0); }

// ============================================================ stem + leaves (poppy, anemone)
struct BloomStem { float y0, y1, hx, bow; };

static inline float bloom_stemX(BloomStem s, float y, thread float& dxdy) {
    float L = s.y1 - s.y0;
    float v = clamp((y - s.y0) / L, 0.0, 1.0);
    dxdy = (2.0 * s.hx * v + s.bow * M_PI_F * cos(M_PI_F * v)) / L;
    return s.hx * v * v + s.bow * sin(M_PI_F * v);
}

/// A lanceolate leaf from `at`, `ang` from vertical (+ = to the right), length L, half-width W,
/// curling outward by `bend`. Returns distance; `v` across (− to + over its width), `x` 0…1 along.
static inline float bloom_leaf(float2 p, float2 at, float ang, float L, float W, float bend,
                               thread float& vv, thread float& xx) {
    float2 dir = float2(sin(ang), cos(ang));
    float2 nrm = float2(dir.y, -dir.x);
    float2 q = p - at;
    float u = dot(q, dir), v = dot(q, nrm) * sign(ang + 1e-4);
    v -= bend * u * u / L;
    float x = u / L;
    // (sin(M_PI_F) is a hair below 0 in float: clamp, or pow gives NaN at and past the tip)
    float hw = W * pow(max(sin(M_PI_F * pow(saturate(x), 0.72)), 0.0), 0.85);
    float d = abs(v) - hw;
    d = max(d, max(-u, u - L) * 0.7);
    vv = v / max(W, 1e-4); xx = x;
    return d * 0.85;
}

// ============================================================ the poppy (and the anemone)
/// Blue poppy (anemone = false: five crinkled, cupped sky-blue petals, a golden stamen boss) or
/// white anemone (six slimmer petals in `petal`, a dark boss). `br` breeze 0…1. `aa` edge width;
/// `lod` drops the fine texture (the haze / glow pass).
static inline CellLayer bloom_poppy(float2 p, float ts, float br, float3 petal, bool anemone,
                                   float aa, bool lod) {
    CellLayer o; o.c = 0.0; o.a = 0.0;
    float gust = bloom_gust(ts);
    float w0 = bloom_wind(ts, 0.0) * (0.6 + 0.6 * gust);
    float sway = br * w0 * 0.10;

    BloomStem st;
    st.y0 = -0.06; st.y1 = 0.60; st.hx = 0.012 + sway; st.bow = -0.016 + 0.3 * sway;
    float R = anemone ? 0.165 : 0.19;

    // head: centre at the top of the stem, a little forward of it; facing turns (yaw), nods
    // (pitch) and leans (roll) with the breeze
    float dTop;
    float hxTop = bloom_stemX(st, st.y1, dTop);
    float yaw = clamp(0.58 * sin(0.16 * ts + 0.5) + 0.16 * sin(0.41 * ts + 2.0) + br * 0.30 * w0, -0.92, 0.92);
    float pitch = 0.14 + 0.16 * sin(0.13 * ts + 2.2) + br * 0.16 * bloom_wind(ts * 1.1, 4.0);
    float roll = -atan(dTop) * 0.8 - sway * 2.0;
    float3 n = float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    float2 C = float2(hxTop, st.y1) + float2(n.x, n.y) * 0.035 + float2(0.0, 0.03);

    // ---- cheap bound: nothing near → transparent
    float2 dc = p - C;
    float stemDx;
    float sx = bloom_stemX(st, p.y, stemDx);
    bool nearHead = dot(dc, dc) < pow(1.45 * R + aa, 2.0);
    bool nearStem = p.y < st.y1 + 0.02 && abs(p.x - sx) < 0.012 + aa;
    bool nearLeaf = p.y < 0.46 && p.y > -0.05 && abs(p.x - sx) < 0.23 + aa;
    if (!nearHead && !nearStem && !nearLeaf) return o;

    // Front to back (the heart, the petals top-down, then leaves and stem), so a pixel stops as
    // soon as it is covered. `shade` carries the soft shadows the layers above cast just outside
    // their edges onto what lies under them.
    float shade = 1.0;
    if (nearHead) {
        // screen offset → the flower's plane (orthographic), with a cupped lift
        float cr = cos(roll), sr = sin(roll);
        float2 d0 = float2(cr * dc.x - sr * dc.y, sr * dc.x + cr * dc.y);
        float3 e1 = normalize(cross(float3(0, 1, 0), n));
        float3 e2 = cross(n, e1);
        float cup = anemone ? 0.22 : 0.36;
        float2 q = d0;
        {
            float2 d = d0;
            for (int k = 0; k < 2; ++k) {
                float3 P = float3(d, -(n.x * d.x + n.y * d.y) / n.z);
                q = float2(dot(P, e1), dot(P, e2));
                d = d0 - n.xy * (cup * dot(q, q) / R);
            }
        }
        float r = length(q);
        float t = saturate(r / R);
        float2 nq = q / R;
        const float3 Lp = float3(-0.5357, 0.7306, 0.4235);         // soft key from the upper left
        float2 Lq = normalize(float2(dot(Lp, e1), dot(Lp, e2)));    // ... in the plane's frame
        float facing = saturate(n.z * 1.3 - 0.1);                   // turned away: the cup darkens

        // ---- the heart: a raised boss (gold stamens, a green pistil; the anemone's is dark).
        // Raised toward the viewer: seen turned, it rides toward the side the flower faces.
        {
            float2 qb = q - float2(dot(n, e1), dot(n, e2)) * 0.10 * R;
            float rb = length(qb);
            float rs = (anemone ? 0.27 : 0.30) * R;
            float d = rb - rs;
            if (!lod && abs(d) < 0.08 * R + aa) d += 0.05 * R * gnoise(qb / R * 12.0 + 3.0);
            float a = cellkit_cov(d, aa);
            if (a > 0.0) {
                float tb = saturate(rb / rs);
                float lit = 0.88 + 0.22 * dot(qb / max(rs, 1e-5), Lq);
                float tx = lod ? 0.5 : vnoise(qb / R * 34.0);
                float3 c;
                if (anemone) {
                    c = mix(bloom_lin(30.0, 32.0, 52.0), bloom_lin(10.0, 10.0, 18.0), smoothstep(0.35, 0.9, tb));
                    c *= 0.7 + 0.6 * tx;
                    c = mix(c, bloom_lin(60.0, 72.0, 70.0), smoothstep(0.42, 0.30, tb));
                } else {
                    c = mix(bloom_lin(222.0, 194.0, 132.0), bloom_lin(150.0, 112.0, 56.0), smoothstep(0.55, 1.0, tb));
                    c *= 0.72 + 0.5 * tx;
                    c = mix(c, bloom_lin(150.0, 160.0, 82.0), smoothstep(0.24, 0.14, tb));
                }
                cellkit_under(o, c * lit, a);
            }
            shade *= 1.0 - 0.25 * smoothstep(0.08 * R, 0.0, d) * (1.0 - a);
        }

        int N = anemone ? 6 : 5;
        float spin = 0.35 + 0.06 * sin(0.11 * ts) + 0.03 * br * w0;
        for (int ii = 0; ii < 6; ++ii) {
            if (ii >= N || o.a > 0.996) break;
            int i = N - 1 - ii;                          // the last petal lies on top
            float fi = float(i);
            float hsh = hash21(float2(fi, anemone ? 7.0 : 3.0));
            // a petal now and then catches the air: lifts and flutters for a couple of seconds
            float ph = ts / 6.5 + fi * 0.37 + hsh;
            float ev = hash21(float2(floor(ph), fi + 11.0));
            float sp = sin(M_PI_F * fract(ph));
            float fl = (ev > 0.62 ? sp * sp : 0.0) * sin(ts * 6.3 + fi * 2.0) * (0.4 + 0.6 * br);
            float th = 6.2831853 * fi / float(N) + spin + (hsh - 0.5) * 0.35 + 0.08 * fl;
            float2 ax = float2(cos(th), sin(th)), pr = float2(-ax.y, ax.x);
            float len = (anemone ? 0.98 : 1.0) * (0.92 + 0.14 * hsh) * (1.0 - 0.05 * abs(fl));
            float rad = anemone ? 0.40 : 0.47;
            float2 qq = q - ax * (anemone ? 0.60 : 0.55) * R * len;
            float along = dot(qq, ax), acr = dot(qq, pr);
            // obovate: wider toward the tip, narrowing to the base
            float wid = (anemone ? 0.98 : 1.06) + 0.18 * saturate(along / (rad * R));
            float d = length(float2(along, acr / wid)) - rad * R * len;
            if (d > 0.20 * R + aa) continue;              // far outside: no edge, no shadow
            // crinkled, ruffled, gently scalloped edge (the noise rides with the petal)
            float pa = atan2(acr, along);
            float crink = 0.022 * sin(pa * 5.0 + fi * 1.7 + 0.3 * sin(ts * 0.7 + fi));
            if (!lod && abs(d) < 0.09 * R + aa)          // the noise only matters near the edge
                crink += 0.045 * gnoise(nq * 3.4 + float2(fi * 7.3, ts * 0.04)) + 0.02 * gnoise(nq * 8.5 + fi * 3.1);
            d += crink * R * (anemone ? 0.6 : 1.0) * smoothstep(0.2, 0.7, t);
            float a = cellkit_cov(d, aa);
            if (a > 0.0) {
                float3 c = petal;
                if (anemone) c *= mix(0.86, 1.0, smoothstep(0.15, 0.55, t));
                else c = mix(c * float3(0.42, 0.38, 0.70), c, smoothstep(0.15, 0.75, t));  // deep, violet heart
                // the cup: the inner wall facing the light is brighter
                float cupL = 1.0 - 0.30 * dot(nq / max(t, 1e-3), Lq) * t + 0.06 * fl;
                // crinkles: broad tonal ripples; creases: darker folds running out from the heart
                // (the haze pass keeps the shape and light, not the texture: the cells carry it)
                float tex = 1.0;
                if (!lod) {
                    tex = 0.80 + 0.55 * gnoise(nq * 4.2 + fi * 5.7 + float2(0.0, ts * 0.03));
                    float fold = 1.0 - abs(gnoise(float2(pa * 2.2 + fi * 3.0, t * 3.0)));
                    tex *= 1.0 - 0.40 * pow(fold, 5.0) * smoothstep(0.25, 0.6, t);
                }
                // translucent rim: the edge glows where the light comes through
                float rim = smoothstep(-0.10 * R, 0.0, d) * (anemone ? 0.25 : 0.45);
                c = mix(c * cupL * tex, petal * 1.25 + 0.06, rim) * mix(0.72, 1.0, facing);
                cellkit_under(o, c * shade, a);
            }
            shade *= 1.0 - 0.45 * smoothstep(0.13 * R, 0.0, d) * (1.0 - a);
        }
        if (o.a > 0.996) return o;
    }

    // ---- leaves: two long ones low on the stem, a small one higher, swaying a little more
    float3 green = bloom_lin(92.0, 128.0, 58.0);
    if (nearLeaf) {
        for (int i = 0; i < 3; ++i) {
            float fi = float(i);
            float ay = (i == 0) ? 0.13 : (i == 1) ? 0.19 : 0.30;
            float side = (i == 1) ? 1.0 : -1.0;
            float L = (i == 0) ? 0.17 : (i == 1) ? 0.19 : 0.11;
            float W = (i == 2) ? 0.016 : 0.023;
            float dd;
            float lx = bloom_stemX(st, ay, dd);
            float2 at = float2(lx, ay);
            float2 dl = p - at;
            if (dot(dl, dl) > pow(L + W + aa, 2.0)) continue;
            float ang = side * ((i == 2) ? 0.52 : 0.62) + br * 0.09 * bloom_wind(1.3 * ts, 2.1 * fi + 1.0) + dd * 0.5;
            float vv, xx;
            float d = bloom_leaf(p, at, ang, L, W, 0.22, vv, xx);
            float a = cellkit_cov(d, aa);
            if (a > 0.0) {
                float sh = 0.78 + 0.16 * (-vv * side * sign(ang)) + 0.12 * xx;
                float rib = lod ? 1.0 : 1.0 + 0.25 * exp(-vv * vv * 40.0);     // a paler midrib
                cellkit_under(o, green * float3(1.05, 1.08, 0.9) * sh * rib * shade, a);
            }
        }
    }
    // ---- stem
    if (nearStem) {
        float dist = abs(p.x - sx) / sqrt(1.0 + stemDx * stemDx) + max(p.y - st.y1, 0.0);
        float w = mix(0.0062, 0.0048, saturate((p.y - st.y0) / (st.y1 - st.y0)));
        float a = cellkit_line(dist, w, aa);
        if (a > 0.0) {
            float across = clamp((p.x - sx) / max(w, 1e-4), -1.0, 1.0);
            float3 c = green * (0.82 - 0.28 * across) * (0.9 + 0.1 * saturate(p.y));
            cellkit_under(o, c * shade, a);
        }
    }
    return o;
}

// ============================================================ baby's breath (gypsophila)
// A spray that forks three times: four stems part from the main stem low down, each forks in
// two, and each of those in two short twigs ending in a puff of florets (16 puffs), with a
// smaller puff in every fork and a bud partway up each stem (12 more). All of it bends with the
// breeze from the base. The skeleton is walked once a pixel for both points (the cell centre and
// the pixel) and the glow.
constant float2 BLOOM_GB = float2(0.0, 0.22);     // where the spray parts from the main stem

static inline float2 bloom_bend(float2 q, float sway) { return q + float2(sway * q.y * q.y * 1.4, 0.0); }
static inline float2 bloom_dir(float a) { return float2(sin(a), cos(a)); }

/// Where stem i leaves the main stem (they part at slightly different heights).
static inline float2 bloom_gypNode(int i) {
    return BLOOM_GB + float2(0.0, (i == 0) ? 0.05 : (i == 1) ? 0.0 : (i == 2) ? 0.08 : 0.025);
}
static inline float bloom_gypSway(float ts, float br) {
    return br * bloom_wind(ts, 1.0) * (0.6 + 0.6 * bloom_gust(ts)) * 0.09;
}

/// Puff of florets round c (radius scale sc), composited over o.
static inline void bloom_puff(thread CellLayer& o, float2 p, float2 c, float sc, float seed,
                              float3 white, float aa, bool lod) {
    float2 dc = p - c;
    if (dot(dc, dc) > pow(0.036 * sc + aa, 2.0)) return;
    float depth = 0.66 + 0.34 * hash21(float2(seed, 6.1));      // nearer puffs brighter
    int nf = 5 + int(hash21(float2(seed, 5.5)) * 4.0);
    for (int k = 0; k < 8; ++k) {
        if (k >= nf) break;
        float fk = float(k);
        float2 hh = hash22(float2(seed * 7.0 + fk, 9.1)) - 0.5;
        float rr = (0.0080 + 0.0040 * hash21(float2(seed, fk + 3.3))) * sc;
        float2 dq = dc - hh * float2(0.032, 0.027) * sc;
        float dist = length(dq);
        float a = cellkit_cov(dist - rr, aa);
        if (a <= 0.0) continue;
        // a floret: bright on the upper left, a cool grey under it, a faint green eye
        float lit = 0.84 + 0.22 * dot(dq / max(rr, 1e-4), float2(-0.6, 0.8));
        float3 col = white * clamp(lit, 0.66, 1.06) * depth;
        if (!lod) col = mix(col, col * float3(0.86, 0.90, 0.80), smoothstep(0.3, 0.0, dist / rr) * 0.3);
        cellkit_over(o, col, a);
    }
}

/// One spray element at both points: a twig from a to b (half-width w, colour col) and the puff
/// at b (scale sc, 0 = none).
struct BloomGyp { CellLayer sS, sW, fS, fW; float glow; };   // stems / florets, sharp / soft

static inline void bloom_gypPiece(thread BloomGyp& G, float2 ps, float2 pw, bool inS, bool inW, bool inG,
                                  float2 a, float2 b, float w, float3 col, float sc, float seed,
                                  float3 white, float aaS, float aaW) {
    float h;
    if (inS) {
        float c = cellkit_line(cellkit_seg(ps, a, b, h), w, aaS);
        if (c > 0.0) cellkit_over(G.sS, col, c);
        if (sc > 0.0) bloom_puff(G.fS, ps, b, sc, seed, white, aaS, false);
    }
    if (inW) {
        float c = cellkit_line(cellkit_seg(pw, a, b, h), w, aaW);
        if (c > 0.0) cellkit_over(G.sW, col, c);
        if (sc > 0.0) bloom_puff(G.fW, pw, b, sc, seed, white, aaW, true);
    }
    if (inG && sc > 0.0) {
        float2 d = pw - b;
        float k = 1.0 + dot(d, d) * 260.0 / (sc * sc);     // ≈ exp(−1000 d²/sc²), cheaper
        k *= k; G.glow += sc / (k * k);
    }
}

// The spray's fixed shape (tools: generated once from the hashes it was designed with):
// stem i: (direction, length, node height above BLOOM_GB), (bud direction, sway phase cos/sin)
constant float4 BLOOM_GS[8] = {
    float4(-0.32717, 0.94497, 0.16701, 0.05000), float4(-0.88351, 0.46841, 1.00000, 0.00000),
    float4(-0.07849, 0.99691, 0.25036, 0.00000), float4(0.62210, 0.78294, -0.12884, 0.99166),
    float4(0.13820, 0.99040, 0.30660, 0.08000), float4(-0.57398, 0.81887, -0.96680, -0.25554),
    float4(0.26170, 0.96515, 0.22669, 0.02500), float4(0.84936, 0.52781, 0.37798, -0.92581)
};
// fork i*2+j: (direction, length, puff seed), (sway phase cos/sin, 0, 0)
constant float4 BLOOM_GF[16] = {
    float4(-0.55163, 0.83409, 0.11446, 40.00000), float4(1.00000, 0.00000, 0.00000, 0.00000),
    float4(0.04272, 0.99909, 0.06552, 41.00000), float4(-0.66628, 0.74571, 0.00000, 0.00000),
    float4(-0.40878, 0.91263, 0.15326, 42.00000), float4(-0.11215, -0.99369, 0.00000, 0.00000),
    float4(0.31725, 0.94834, 0.14790, 43.00000), float4(0.81573, 0.57844, 0.00000, 0.00000),
    float4(-0.26776, 0.96348, 0.05118, 44.00000), float4(-0.97484, 0.22289, 0.00000, 0.00000),
    float4(0.44582, 0.89512, 0.12893, 45.00000), float4(0.48330, -0.87545, 0.00000, 0.00000),
    float4(-0.01354, 0.99991, 0.14333, 46.00000), float4(0.33081, 0.94370, 0.00000, 0.00000),
    float4(0.62199, 0.78303, 0.13865, 47.00000), float4(-0.92413, -0.38207, 0.00000, 0.00000)
};
// twig i*4+j*2+k: (direction, length, puff scale), (wobble phases: cos/sin 2.1k, cos/sin 1.3k)
constant float4 BLOOM_GT[32] = {
    float4(-0.78182, 0.62350, 0.09044, 0.95000), float4(1.00000, 0.00000, 1.00000, 0.00000),
    float4(-0.09467, 0.99551, 0.06990, 1.05658), float4(-0.50485, 0.86321, 0.26750, 0.96356),
    float4(-0.47231, 0.88143, 0.03319, 1.02132), float4(-0.49026, -0.87158, -0.85689, 0.51550),
    float4(0.36174, 0.93228, 0.03866, 0.99022), float4(0.99986, 0.01681, -0.72593, -0.68777),
    float4(-0.81171, 0.58406, 0.04279, 1.12720), float4(-0.51929, 0.85460, 0.46852, -0.88345),
    float4(-0.04051, 0.99918, 0.04964, 1.07584), float4(-0.47554, -0.87970, 0.97659, 0.21512),
    float4(-0.23656, 0.97162, 0.03191, 1.16011), float4(0.99943, 0.03362, 0.05396, 0.99854),
    float4(0.73655, 0.67638, 0.06561, 1.19825), float4(-0.53358, 0.84575, -0.94772, 0.31910),
    float4(-0.69132, 0.72255, 0.05600, 1.03789), float4(-0.46068, -0.88757, -0.56098, -0.82783),
    float4(0.14574, 0.98932, 0.07047, 1.00408), float4(0.99873, 0.05042, 0.64760, -0.76198),
    float4(0.03370, 0.99943, 0.07365, 1.02290), float4(-0.54773, 0.83666, 0.90745, 0.42017),
    float4(0.85884, 0.51224, 0.05256, 1.03455), float4(-0.44569, -0.89519, -0.16211, 0.98677),
    float4(-0.48756, 0.87309, 0.08965, 1.04116), float4(0.99774, 0.06721, -0.99418, 0.10775),
    float4(0.55095, 0.83454, 0.06722, 1.01472), float4(-0.56172, 0.82733, -0.36977, -0.92912),
    float4(0.34598, 0.93824, 0.03962, 0.99426), float4(-0.43058, -0.90255, 0.79635, -0.60483),
    float4(0.92057, 0.39058, 0.08971, 0.96160), float4(0.99647, 0.08397, 0.79581, 0.60554)
};

/// The spray at the cell centre ps (sharp, edge aaS) and at the pixel pw (soft, edge aaW; only
/// when wantSoft), and its glow at pw. The shape is fixed (BLOOM_GS/GF/GT); the breeze only turns
/// its directions a little, by angle addition on three global swells, so the walk costs no trig.
static inline float2 bloom_turn(float2 D, float d) {          // dir(a) → dir(a + d), d small
    float c = 1.0 - 0.5 * d * d;
    return float2(D.x * c + D.y * d, D.y * c - D.x * d);
}
static inline void bloom_gyp(float2 ps, float2 pw, float ts, float br, float3 white, float aaS,
                             float aaW, bool wantSoft, thread CellLayer& S, thread CellLayer& W,
                             thread float& glow) {
    BloomGyp G;
    G.sS.c = 0.0; G.sS.a = 0.0; G.sW = G.sS; G.fS = G.sS; G.fW = G.sS; G.glow = 0.0;
    S = G.sS; W = G.sS; glow = 0.0;
    float sway = bloom_gypSway(ts, br);
    float2 us = float2(ps.x - sway * ps.y * ps.y * 1.4, ps.y), uw = float2(pw.x - sway * pw.y * pw.y * 1.4, pw.y);
    bool inS = us.y > -0.06 && us.y < 0.86 && abs(us.x) < 0.36 + aaS;
    bool inW = wantSoft && uw.y > -0.06 && uw.y < 0.86 && abs(uw.x) < 0.36 + aaW;
    bool inG = uw.y > 0.26 && uw.y < 0.96 && abs(uw.x) < 0.42;       // the glow's reach
    if (!inS && !inW && !inG) return;

    float3 green = bloom_lin(84.0, 126.0, 52.0);
    float3 dark = bloom_lin(58.0, 90.0, 38.0);
    // the main stem, two together from below the frame
    for (int k = 0; k < 2; ++k) {
        float2 a0 = bloom_bend(float2(0.003 * (float(k) * 2.0 - 1.0), -0.06), sway);
        float2 a1 = bloom_bend(BLOOM_GB + float2(0.0, 0.08 - 0.03 * float(k)), sway);
        bloom_gypPiece(G, ps, pw, inS, inW, inG, a0, a1, 0.0024, mix(dark, green, 0.45), 0.0, 0.0, white, aaS, aaW);
    }
    // below the parting there is only the main stem
    inS = inS && (us.y > 0.2 || abs(us.x) < 0.03 + aaS);
    inW = inW && (uw.y > 0.2 || abs(uw.x) < 0.03 + aaW);
    if (inG || (inS && us.y >= 0.2) || (inW && uw.y >= 0.2)) {
        // three slow swells, shared by every stem, fork and twig (each takes its own phase)
        float2 sA = float2(sin(0.6 * ts), cos(0.6 * ts)) * (br * 0.06);
        float2 sB = float2(sin(0.8 * ts), cos(0.8 * ts)) * (br * 0.08);
        float2 sC = float2(sin(1.3 * ts), cos(1.3 * ts)), sD = float2(sin(1.1 * ts), cos(1.1 * ts));
        for (int i = 0; i < 4; ++i) {
            float4 g0 = BLOOM_GS[2 * i], g1 = BLOOM_GS[2 * i + 1];
            float d0 = sA.x * g1.z + sA.y * g1.w;                       // br·0.06·sin(0.6t + 1.7i)
            float2 N0 = BLOOM_GB + float2(0.0, g0.w);
            float2 E0 = N0 + g0.z * bloom_turn(g0.xy, d0);
            float2 bN0 = bloom_bend(N0, sway), bE0 = bloom_bend(E0, sway);
            bloom_gypPiece(G, ps, pw, inS, inW, inG, bN0, bE0, 0.0018, mix(dark, green, 0.7), 0.0, 0.0, white, aaS, aaW);
            // a bud partway up: a short twig and a small puff
            float2 sb = mix(N0, E0, 0.62);
            bloom_gypPiece(G, ps, pw, inS, inW, inG, bloom_bend(sb, sway),
                           bloom_bend(sb + 0.045 * bloom_turn(g1.xy, d0), sway), 0.0011, green,
                           0.7, float(i) + 60.0, white, aaS, aaW);
            // the whole stem's forks and twigs lie within ~0.33 of its tip
            float2 eS = ps - bE0, eW = pw - bE0;
            bool jS = inS && dot(eS, eS) < pow(0.33 + aaS, 2.0);
            bool jW = inW && dot(eW, eW) < pow(0.33 + aaW, 2.0);
            bool jG = inG && dot(eW, eW) < 0.16;
            if (!jS && !jW && !jG) continue;
            for (int j = 0; j < 2; ++j) {
                int fj = i * 2 + j;
                float4 f0 = BLOOM_GF[2 * fj], f1 = BLOOM_GF[2 * fj + 1];
                float d1 = d0 + sB.x * f1.x + sB.y * f1.y;               // + br·0.08·sin(0.8t + 2.3j)
                float2 E1 = E0 + f0.z * bloom_turn(f0.xy, d1);
                float2 bE1 = bloom_bend(E1, sway);
                bloom_gypPiece(G, ps, pw, jS, jW, jG, bE0, bE1, 0.0016, green, 0.62, f0.w, white, aaS, aaW);
                // the twigs and their puffs all lie within ~0.15 of the fork: skip them from afar
                float2 dS = ps - bE1, dW = pw - bE1;
                bool kS = jS && dot(dS, dS) < pow(0.15 + aaS, 2.0);
                bool kW = jW && dot(dW, dW) < pow(0.15 + aaW, 2.0);
                bool kG = jG && dot(dW, dW) < 0.05;
                if (!kS && !kW && !kG) continue;
                for (int k = 0; k < 2; ++k) {
                    int tk = fj * 2 + k;
                    float4 t0 = BLOOM_GT[2 * tk], t1 = BLOOM_GT[2 * tk + 1];
                    float2 T = E1 + t0.z * bloom_turn(t0.xy, d1)
                             + br * 0.008 * float2(sC.x * t1.x + sC.y * t1.y, 0.6 * (sD.y * t1.z - sD.x * t1.w));
                    bloom_gypPiece(G, ps, pw, kS, kW, kG, bE1, bloom_bend(T, sway), 0.0012, green * 1.08,
                                   t0.w, float(tk), white, aaS, aaW);
                }
            }
        }
    }
    // the florets over the stems
    S = G.sS; cellkit_over(S, G.fS.a > 1e-4 ? G.fS.c / G.fS.a : float3(0.0), G.fS.a);
    W = G.sW; cellkit_over(W, G.fW.a > 1e-4 ? G.fW.c / G.fW.a : float3(0.0), G.fW.a);
    glow = G.glow;
}

// ============================================================ glyphs (CellKit_funcs.h)
/// Which glyph a cell shows: by what it covers (stem greens set in letters, the golden heart in
/// rings and stars, petals by brightness — triangles where light, letters where deep).
static inline int bloom_pick(float3 s, float2 cell, float ts) {
    float h = hash21(cell * 0.913 + 17.0);
    float lum = dot(s, float3(0.3, 0.55, 0.15));
    bool tri = fmod(abs(cell.x + cell.y), 2.0) < 0.5;
    if (h > 0.8) tri = !tri;
    if (s.g > s.b * 1.08 && s.g >= s.r * 0.95) return (h < 0.42) ? 3 : (h < 0.95 ? 2 : 1);  // green
    if (s.r > s.b * 1.25) {                                                                // gold / warm
        if (h < 0.18) return 5;
        if (h < 0.5) return 4;
        if (h < 0.7) return 7;
        return tri ? 0 : 1;
    }
    if (lum < 0.13) return (h < 0.5) ? 6 : 7;
    float v = lum + (h - 0.5) * 0.16;
    if (v < 0.36) return (h < 0.5) ? 2 : 3;
    if (h > 0.975) return 5;
    if (v < 0.47) return (h < 0.35) ? 2 : (h < 0.6 ? 3 : (tri ? 0 : 1));
    if (h < 0.14) return 2;                    // a few letters among the bright triangles
    if (h < 0.22) return 3;
    return tri ? 0 : 1;
}

// ============================================================ captions
constant char BLOOM_CAP[10][16] = {
    "STUDY 01", "BLUE POPPY", "BABY'S BREATH", "WHITE ANEMONE", "24 FPS",
    "LIGHT AIR", "SET IN TYPE", "SET IN LIGHT", "NO HURRY", ""
};

static inline int bloom_capLen(int line) {
    int n = 0;
    for (int i = 0; i < 15; ++i) { if (BLOOM_CAP[line][i] == 0) break; n += 1; }
    return n;
}
static inline float bloom_capWidth(texture2d<float> A, int line, float track) {
    float w = 0.0;
    int n = bloom_capLen(line);
    for (int i = 0; i < n; ++i) {
        int g = clocks_gid(BLOOM_CAP[line][i], true);
        w += ((g < 0) ? CLK_SPACE : clocks_adv(A, g).x) + track;
    }
    return max(w - track, 0.0);
}
/// Distance (caps) to caption `line` whose pen starts at the origin.
static inline float bloom_capDist(texture2d<float> A, sampler s, int line, float track, float2 q) {
    if (q.y < -1.4 || q.y > 0.5) return CLK_FAR;
    float d = CLK_FAR, pen = 0.0;
    int n = bloom_capLen(line);
    const float4 fw = float4(1, 0, 0, 0);
    for (int i = 0; i < n; ++i) {
        int g = clocks_gid(BLOOM_CAP[line][i], true);
        float adv = (g < 0) ? CLK_SPACE : clocks_adv(A, g).x;
        if (g >= 0 && q.x > pen - 0.3 && q.x < pen + adv + 0.3)
            d = min(d, clocks_gdist(A, s, clocks_glyph(A, g, fw), q - float2(pen, 0.0), fw));
        pen += adv + track;
        if (pen > q.x + 0.5) break;
    }
    return d;
}

/// How far the flower reaches either side of the centre (scene units) at height y: the envelope
/// of every pose it sways, nods and turns through, at full breeze, with a margin — measured with
/// the gallery over 60 random frames per flower and render (poppy ≤ 0.386 wide, top 0.9155,
/// clipped at 0.92 by bloom_scene's guard; baby's breath ≤ 0.298, top 0.83; anemone ≤ 0.34,
/// top 0.84). A sideways-swept disc: (half-spread, centre height, radius); non-increasing in y.
static inline float bloom_reach(int flower, float y) {
    float3 k = (flower == 0) ? float3(0.18, 0.70, 0.22)
             : (flower == 1) ? float3(0.135, 0.68, 0.17)
             :                 float3(0.19, 0.68, 0.18);
    float dy = max(y - k.y, 0.0);
    return dy < k.z ? k.x + sqrt(k.z * k.z - dy * dy) : 0.0;
}

/// Ink of the corner captions at px (0 where there are none). On a tall screen or at a large
/// size the flower's head can rise into the caption band: a row shows only while both of its
/// lines (and every row above it) stay clear of the flower's reach, so rows drop from the bottom
/// up, and the whole block steps aside when even the first row would touch it.
static inline float bloom_captions(float2 px, float2 res, int flower, int render, float size,
                                   float cellPx, texture2d<float> A, sampler s) {
    float cap = max(0.0115 * res.y, 7.0);                // cap height, px
    float lead = 2.05 * cap;
    float mx = 0.05 * res.x, top = 0.11 * res.y + cap;
    const float track = 0.16;
    float rows = 3.0;
    bool left = px.x < 0.5 * res.x;
    if (px.y < top - 1.6 * cap || px.y > top + (rows - 1.0) * lead + 0.6 * cap) return 0.0;
    int row = clamp(int(floor((px.y - top + 1.3 * cap) / lead)), 0, 2);
    if (left ? (px.x > mx + 14.0 * cap * 1.1) : (px.x < res.x - mx - 14.0 * cap * 1.1)) return 0.0;
    // keep clear of the flower: this row and the rows above it
    float gap = 0.6 * cap + 0.5 * cellPx;                 // air, and the cells' own reach
    for (int r = 0; r <= row; ++r) {
        float yLow = top + float(r) * lead + gap;         // the row's lowest ink, + air (px down)
        float reach = bloom_reach(flower, (res.y - yLow) / res.y / size) * res.y * size + gap;
        int lineL = (r == 0) ? 0 : (r == 1) ? 1 + flower : 4;
        int lineR = (r == 0) ? 5 : (r == 1) ? 6 + min(render, 1) : 8;
        float w = max(bloom_capWidth(A, lineL, track), bloom_capWidth(A, lineR, track)) * cap;
        if (mx + w > 0.5 * res.x - reach) return 0.0;
    }
    int line = left ? ((row == 0) ? 0 : (row == 1) ? 1 + flower : 4)
                    : ((row == 0) ? 5 : (row == 1) ? 6 + min(render, 1) : 8);
    float x0 = left ? mx : res.x - mx - bloom_capWidth(A, line, track) * cap;
    float2 q = (px - float2(x0, top + float(row) * lead)) / cap;
    float d = bloom_capDist(A, s, line, track, q) - 0.035;  // a touch heavier than the Light master
    return clocks_cov(d, cap);
}

// ============================================================ 79 BLOOM
/// p0 = (flower 0 poppy / 1 baby's breath / 2 anemone, render 0 glyphs / 1 pixels / 2 dots, cell size per
/// 1000 px of height, breeze), p1 = (sky gradient, glow, captions, size); colorA the sky (top),
/// colorB the petals. Display sRGB out.
static inline float3 bloom_scene(float2 px, float2 res, float t, constant FXUniforms& u,
                                 texture2d<float> A, sampler s) {
    int flower = clamp(int(u.p0.x + 0.5), 0, 2);
    int render = clamp(int(u.p0.y + 0.5), 0, 2);
    float cellPx = max(u.p0.z * res.y / 1000.0, 4.0);
    float br = saturate(u.p0.w);
    float grad = saturate(u.p1.x), glow = saturate(u.p1.y);
    float size = clamp(u.p1.w, 0.5, 1.5);
    float ts = floor(t * BLOOM_FPS) / BLOOM_FPS;          // the 24 fps cadence

    // the sky: a smooth vertical gradient, top colour → a lighter, slightly greener bottom
    float3 top = u.colorA.rgb;
    float3 bot = saturate(top + grad * float3(0.318, 0.361, 0.333));
    float gy = px.y / res.y;
    float3 sky = mix(top, bot, gy);
    float3 bg = srgbToLinear(sky);
    float3 petal = srgbToLinear(u.colorB.rgb);

    // scene coordinates (screen heights; x from the centre, y up from the bottom), per size
    float2 anchor = float2(0.5 * res.x, res.y);
    float2 p = float2(px.x - anchor.x, anchor.y - px.y) / res.y / size;
    float cw = cellPx / res.y / size;                      // a cell, in scene units

    // the cell grid, anchored at the bottom centre (the stem rises up one column)
    float2 g = (px - anchor) / cellPx;
    float2 cell = floor(g + float2(0.5, 0.0));
    float2 cpx = (cell + float2(0.0, 0.5)) * cellPx + anchor;
    float2 pc = float2(cpx.x - anchor.x, anchor.y - cpx.y) / res.y / size;
    float2 lp = (g - cell - float2(-0.5, 0.0)) - 0.5;      // −0.5…0.5 in the cell
    lp.y = -lp.y;

    // soft pass (the haze / glow) at the pixel, sharp pass at the cell centre
    float softAA = cw * (render == 0 ? 1.5 : 2.6);
    CellLayer soft, sharp;
    float gypGlow = 0.0;
    sharp.c = 0.0; sharp.a = 0.0; soft = sharp;
    if (flower == 1) {
        bloom_gyp(pc, p, ts, br, petal, cw, softAA, render == 0, sharp, soft, gypGlow);
    } else if (abs(p.x) < 0.46 && p.y < 0.92) {             // (the flower never reaches further)
        sharp = bloom_poppy(pc, ts, br, petal, flower == 2, cw, false);
        soft = bloom_poppy(p, ts, br, petal, flower == 2, softAA, true);
    }
    float3 sc = sharp.a > 1e-4 ? sharp.c / sharp.a : float3(0.0);
    float3 hc = soft.a > 1e-4 ? soft.c / soft.a : float3(0.0);

    float3 col = bg;
    float cellPxAA = 1.0 / cellPx;
    if (render == 0) {
        // GLYPHS — the flower blurred into the sky, light glyphs coloured by it on top
        float3 hv = max(mix(float3(luma(hc)), hc, 1.3), 0.0);   // the haze a touch more vivid
        // a white flower's haze sits a step below white, so the light glyphs still read on it
        hv *= mix(1.0, 0.42, smoothstep(0.35, 0.8, luma(hc)));
        col = mix(col, hv, smoothstep(0.0, 0.7, soft.a));
        // a pale bloom where the flower meets the sky
        col += (hc * 0.6 + 0.05) * glow * 0.30 * soft.a * (1.0 - soft.a);
        if (flower == 1) col += petal * gypGlow * glow * 0.08;
        if (sharp.a > 0.02) {
            float3 ss = linearToSrgb(sc);
            int gi = bloom_pick(ss, cell, ts);
            float d = cellkit_glyph(gi, lp);
            float ink = saturate(0.5 - d / cellPxAA) * smoothstep(0.02, 0.45, sharp.a);
            float gl = dot(ss, float3(0.3, 0.55, 0.15));
            float3 gcol = srgbToLinear(saturate(mix(ss, float3(0.93, 0.96, 1.0), 0.55 + 0.3 * smoothstep(0.15, 0.6, gl))));
            col = mix(col, sc * mix(1.0, 0.5, smoothstep(0.35, 0.8, luma(sc))), 0.25 * sharp.a);
            col = mix(col, gcol, ink);
        }
    } else {
        // PIXELS — rounded LED cells with a gap — or DOTS — a round dot matrix, every dot the
        // same size (Nothing-style) — over a soft glow of their own light
        float3 gl = (flower == 1) ? petal * gypGlow * 0.17 : hc * soft.a * 0.22;
        col += gl * glow;
        if (sharp.a > 0.01) {
            float dd = cellkit_led(lp, render == 2);
            float m = saturate(0.5 - dd / cellPxAA);
            float led = cellkit_dome(lp);
            float3 lc = sc * led * (1.0 + 0.25 * glow);
            col = mix(col, lc, m * smoothstep(0.0, 0.6, sharp.a));
        }
    }

    float3 outc = linearToSrgb(max(col, 0.0));
    if (u.p1.z > 0.5 && A.get_width() == 4096) {
        float ink = bloom_captions(px, res, flower, render, size, cellPx, A, s);
        outc = mix(outc, float3(0.96, 0.97, 1.0), ink * 0.86);
    }
    return saturate(outc + bandDither(px));
}
