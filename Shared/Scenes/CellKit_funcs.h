//  CellKit_funcs.h — what the cell-grid scenes share: Bloom (79, Bloom_funcs.h) and Penguin (80,
//  Penguin_funcs.h). A subject drawn as SDF layers, sampled once per cell, and shown as glyphs,
//  rounded LED cells or round LED dots. Every symbol is "cellkit_". Included by each scene's
//  funcs header (guarded, so whichever comes first defines it).
//
//    • layers: premultiplied colour + coverage, composited over / under (front to back);
//    • coverage of a shape or a line at a signed distance, never thinner than about a cell;
//    • the glyph set (△ ▽ C Z O ☆ · ( )) in cell-local coordinates;
//    • an LED cell's shape (a round dot, or a rounded square with a gap) and its faint dome.

#ifndef CELLKIT_FUNCS_H
#define CELLKIT_FUNCS_H

/// A layer: premultiplied linear colour and coverage.
struct CellLayer { float3 c; float a; };

static inline void cellkit_over(thread CellLayer& o, float3 col, float a) {
    o.c = col * a + o.c * (1.0 - a);
    o.a = a + o.a * (1.0 - a);
}
/// Front-to-back: `col` goes under what is already there.
static inline void cellkit_under(thread CellLayer& o, float3 col, float a) {
    o.c += (1.0 - o.a) * a * col;
    o.a += (1.0 - o.a) * a;
}
/// The layer's colour, un-premultiplied (black where it is empty).
static inline float3 cellkit_color(CellLayer o) { return o.a > 1e-4 ? o.c / o.a : float3(0.0); }

/// Coverage of a shape at signed distance d (scene units) for an edge `aa` wide.
static inline float cellkit_cov(float d, float aa) { return saturate(0.5 - d / aa); }

/// Coverage of a line `w` half-wide at distance `dist` from its axis: never thinner than about
/// a cell (a sub-cell twig still reads as a chain of dim cells, rather than flickering out).
static inline float cellkit_line(float dist, float w, float aa) {
    float we = max(w, 0.36 * aa);
    return cellkit_cov(dist - we, aa) * saturate(0.45 + 1.6 * w / aa);
}

static inline float cellkit_seg(float2 p, float2 a, float2 b, thread float& h) {
    float2 pa = p - a, ba = b - a;
    h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h);
}

// ============================================================ glyphs
static inline float cellkit_tri(float2 p, float r) {
    const float k = 1.7320508;
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if (p.x + k * p.y > 0.0) p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
    p.x -= clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}
static inline float cellkit_star(float2 p, float r, float rf) {
    const float2 k1 = float2(0.809016994375, -0.587785252292);
    const float2 k2 = float2(-k1.x, k1.y);
    p.x = abs(p.x);
    p -= 2.0 * max(dot(k1, p), 0.0) * k1;
    p -= 2.0 * max(dot(k2, p), 0.0) * k2;
    p.x = abs(p.x);
    p.y -= r;
    float2 ba = rf * float2(-k1.y, k1.x) - float2(0, 1);
    float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
    return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}
/// Stroke distance (cell units) of glyph g at g-local p (−0.5…0.5, y up):
/// 0 △  1 ▽  2 C  3 Z  4 O  5 ☆  6 ·  7 ( )
static inline float cellkit_glyph(int g, float2 p) {
    const float lw = 0.055;
    float h;
    switch (g) {
    case 0: return abs(cellkit_tri(p - float2(0.0, -0.05), 0.35)) - lw;
    case 1: return abs(cellkit_tri(float2(p.x, -p.y) - float2(0.0, -0.05), 0.35)) - lw;
    case 2: {
        float2 q = p * float2(1.0, 0.86);
        if (q.x > 0.0 && abs(q.y) < q.x * 0.95) {
            float2 e = 0.31 * float2(0.725, 0.689);
            return min(length(q - e), length(q - float2(e.x, -e.y))) - lw;
        }
        return abs(length(q) - 0.31) - lw;
    }
    case 3: {
        float d = cellkit_seg(p, float2(-0.25, 0.33), float2(0.25, 0.33), h);
        d = min(d, cellkit_seg(p, float2(0.25, 0.33), float2(-0.25, -0.33), h));
        d = min(d, cellkit_seg(p, float2(-0.25, -0.33), float2(0.25, -0.33), h));
        return d - lw;
    }
    case 4: return abs(length(p * float2(1.0, 0.84)) - 0.29) - lw;
    case 5: return abs(cellkit_star(p - float2(0.0, -0.02), 0.38, 0.45)) - lw * 0.85;
    case 6: return length(p) - 0.075;
    default: {
        float2 q = float2(abs(p.x) - 0.36, p.y * 0.8);
        return (q.x < 0.0) ? abs(length(q) - 0.24) - lw : length(q - float2(0.0, sign(q.y) * min(abs(q.y), 0.17))) - lw;
    }
    }
}

// ============================================================ LED cells
/// Signed distance (cells) to an LED cell's edge at cell-local lp (−0.5…0.5): a round dot, every
/// dot the same size, `radius` of the pitch (`round`, Nothing-style), or a rounded square with a
/// gap ≈ 18 % of the cell.
static inline float cellkit_led(float2 lp, bool round, float radius) {
    if (round) return length(lp) - radius;
    float2 q = abs(lp) - 0.5 + 0.09;
    float rr = 0.22;
    return length(max(q + rr, 0.0)) + min(max(q.x + rr, q.y + rr), 0.0) - rr;
}
/// …with Bloom's dots, ≈ 74 % of the pitch.
static inline float cellkit_led(float2 lp, bool round) { return cellkit_led(lp, round, 0.37); }
/// A faint dome on each cell: brighter at its middle.
static inline float cellkit_dome(float2 lp) { return 0.88 + 0.16 * (1.0 - dot(lp, lp) * 2.0); }

#endif
