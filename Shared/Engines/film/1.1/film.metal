//  film.metal — the `film` engine's shaders. CustomFilm.swift drives them.
//
//  Variant clips (ds_fragment, u.scene[1].z == 0): the clip showing (dsA0), aspect-filled,
//  crossfading from the one before it (dsA1) in linear light, then a live film grain (and an
//  optional halation for clips that weren't graded).
//    u.scene[0] = (clip A width, height, clip B width, height)
//    u.scene[1] = (mix 0 = all A, the clip's frame rate, 0, 0)
//    u.scene[8] = (Grain 0…1, Halation 0…1, Weather menu, 0)   — the engine's params (engine.json)
//
//  Light layers (docs/film-layers.md):
//  1. ds_film_mix, at the tiles' own resolution, only when the video frame or the light changed:
//     the light tiles of the layers video (10-bit Y'CbCr planes, decoded pow4 × scale) summed with
//     their weights (sun, low sun, sky, cabin, city — from the real sun and the weather, the
//     exposure folded in) → HDR (rgb, mask in a) + the highlights over the bloom / halation
//     thresholds (glow: r, g); both mipmapped (the blurs are mip taps).
//    u.scene[0] = (video width, height, tile width, height)   — luma pixels
//    u.scene[1] = (columns, rows, halation threshold, bloom threshold)   — exposed units
//    (u.scene[0] = (video w, h, tile w, h); with a gutter, tiles sit (video − tile)/(n − 1) apart)
//    u.scene[2…4] = Y'CbCr → R'G'B' rows (rgb[i] = dot(row.xyz, (y, cb, cr)) + row.w)
//    u.scene[5…9] = weight rgb (scale, tint, exposure folded in) + tile index (−1: none) for
//                   sun, sun_low, sky, cabin, city
//    u.scene[10] = (mask tile index, sun gate (clear), cloud-shadow amount, cloud-shadow phase)
//  2. ds_film_look (half the tiles' size) and, while there's mist, ds_film_mist (the tiles' size),
//     right after the mix: what is a blur of the mix, so the screen pass reads it in one tap
//     instead of five — the halation + bloom light (rgb) | the misted view (AgX of mip 3, rgb) and
//     how far the mist creeps in from the glass's edges (a). Smooth over tens of tile pixels: one
//     bilinear tap of them is the light the mip taps made.
//    u.scene[0] = (halation, bloom, halation lod, bloom lod)
//  3. ds_film_grain, once per grain frame (the clip's frame rate), at the screen's size / grain
//     cell: the grain's lattice (film_hash of each cell corner), so the screen pass gathers four
//     corners instead of hashing them; below it, the glass's cell tables (see film_drop_hashes)
//     and the glass map (film_glass_map), redrawn only when the screen, rain, snow or wind change.
//     u.scene[0] = (the frame, the tables' first row, the HDR's aspect, 0),
//     u.scene[1] = (screen width, height, HDR width, height), u.scene[2] = (rain, snow, 0, wind).
//  4. the screen pass, at the screen's size: the HDR aspect-filled, the glass weather drawn live
//     through the mask (rain beads and runnels that refract, snow and sleet settling and melting,
//     falling flakes beyond the glass, fog and condensation), halation and bloom, vignette, AgX,
//     grain. Lean variants, picked only when the weather they leave out is 0 (the same pixels,
//     fewer registers and branches): ds_film_rain (no snow), ds_film_snow (no rain), ds_film_damp
//     (no rain, snow or lightning: overcast, fog), ds_film_dry (no glass code at all: clear,
//     partly cloudy); ds_fragment has everything (sleet).
//    dsA0 = HDR (mipped), dsA1 = look light, dsA2 = look mist, dsA3 = grain lattice
//    u.scene[0] = (HDR width, height, the lattice's grain frame (−1: none), its screen height)
//    u.scene[1] = (the lattice texture's first table row (0: none), frame rate, 1, bloom strength)
//    u.scene[2] = (rain 0…1, snow 0…1, fog 0…1, lightning flash 0…1)
//    u.scene[3] = (vignette, halation lod, bloom lod, wind 0…1)

static inline float3 film_cover(texture2d<float> t, sampler s, float2 uv, float2 res, float2 size) {
    float outA = res.x / max(res.y, 1.0);
    float srcA = size.x / max(size.y, 1.0);
    float2 scale = (srcA > outA) ? float2(outA / srcA, 1.0) : float2(1.0, srcA / outA);
    return t.sample(s, (uv - 0.5) * scale + 0.5).rgb;
}

/// An integer hash → 0…1 (cheaper than the float hashes for a per-pixel effect).
static inline float film_hash(uint2 p, uint frame) {
    uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ frame * 0xcb1ab31fu;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
    return float(h & 0xffffffu) / 16777216.0;
}

/// Grain: soft value noise on a grid of `cell` pixels, a new pattern every frame of the clip.
static inline float film_grain(float2 px, float cell, uint frame) {
    float2 g = px / cell;
    float2 fi = floor(g), f = g - fi;
    uint2 i = uint2(int2(fi) + 32768);
    f = f * f * (3.0 - 2.0 * f);
    float a = film_hash(i, frame), b = film_hash(i + uint2(1, 0), frame);
    float c = film_hash(i + uint2(0, 1), frame), d = film_hash(i + uint2(1, 1), frame);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) - 0.5;          // −0.5…0.5
}

/// film_grain from the grain pass's lattice (`lat`: film_hash of every cell corner for the frame):
/// the same four values, gathered instead of hashed — the same grain.
static inline float film_grain_lattice(float2 px, float cell, texture2d<float> lat, sampler s) {
    float2 g = px / cell;
    float2 fi = floor(g), f = g - fi;
    f = f * f * (3.0 - 2.0 * f);
    // the 2×2 texels around corner fi + 1: w = fi, z = fi + (1, 0), x = fi + (0, 1), y = fi + (1, 1)
    float4 q = lat.gather(s, (fi + 1.0) / float2(lat.get_width(), lat.get_height()));
    return mix(mix(q.w, q.z, f.x), mix(q.x, q.y, f.x), f.y) - 0.5;  // −0.5…0.5
}

/// Live grain on display sRGB `a` (both paths), then the finished pixel.
static inline float4 film_finish(float3 a, float2 px, float2 res, constant FXUniforms& u) {
    float grain = saturate(u.scene[8].x);
    if (grain > 0.0) {
        float fps = u.scene[1].y > 1.0 ? u.scene[1].y : 24.0;
        uint frame = uint(max(floor(u.time * fps), 0.0));
        float cell = max(res.y / 1100.0 * 1.4, 1.0);
        float l = dsLuma(a);
        float w = 0.25 + 0.75 * saturate(4.0 * l * (1.0 - l));
        a += film_grain(px, cell, frame) * grain * 0.16 * w;
        // (the grain dithers already: ds_finish's own dither would only cost a sin a pixel)
        uint3 e = as_type<uint3>(a) & 0x7f800000u;
        return float4(any(e == 0x7f800000u) ? float3(0.0) : saturate(a), 1.0);
    }
    return ds_finish(a, px);
}

// ================================================================================ light layers
// (compiled for packages with "layers" only: CustomSceneCompiler defines DS_FILM_LAYERS)
#ifdef DS_FILM_LAYERS

/// One tile's texel at tile-local pixel `p` (top-left origin) as R'G'B' (0…1 code values).
/// Clamped inside the tile — by half a luma texel, and a whole one for the half-size chroma
/// plane — so neither the bilinear taps nor 4:2:0 chroma reach into the neighbouring tile.
static inline float3 film_tile(texture2d<float> y, texture2d<float> c, sampler s, float idx, float2 p,
                               float2 tile, float2 video, float cols, constant FXUniforms& u) {
    // tile-to-tile pitch: tiles may sit apart by a gutter (video = n·tile + (n−1)·gutter)
    float2 counts = max(u.scene[1].xy, float2(1.0));
    float2 pitch = select(tile, (video - tile) / max(counts - 1.0, float2(1.0)), counts > 1.5);
    float2 origin = float2(fmod(idx, cols), floor(idx / cols)) * pitch;
    float2 py = origin + clamp(p, float2(0.5), tile - 0.5);
    float2 pc = origin + clamp(p, float2(1.0), tile - 1.0);
    float3 ycc = float3(y.sample(s, py / video).r, c.sample(s, pc / video).rg);
    return saturate(float3(dot(u.scene[2].xyz, ycc), dot(u.scene[3].xyz, ycc), dot(u.scene[4].xyz, ycc))
                    + float3(u.scene[2].w, u.scene[3].w, u.scene[4].w));
}

static inline float3 film_light(texture2d<float> y, texture2d<float> c, sampler s, float4 w, float2 p,
                                float2 tile, float2 video, float cols, constant FXUniforms& u) {
    if (w.w < 0.0 || all(w.xyz == 0.0)) return float3(0.0);
    float3 v = film_tile(y, c, s, w.w, p, tile, video, cols, u);
    float3 v2 = v * v;
    return v2 * v2 * w.xyz;                                          // pow4 decode × weight
}

struct FilmMixOut {
    float4 hdr [[color(0)]];      // exposed scene-linear rgb, glass mask in a
    float2 glow [[color(1)]];     // luminance over the halation / bloom thresholds
};

fragment FilmMixOut ds_film_mix(DS_FRAGMENT_PARAMS) {
    // dsA0 = luma (r16Unorm), dsA1 = chroma (rg16Unorm), both the whole grid
    float2 video = max(u.scene[0].xy, float2(1.0)), tile = max(u.scene[0].zw, float2(1.0));
    float cols = max(u.scene[1].x, 1.0);
    float2 p = in.pos.xy * tile / max(u.resolution, float2(1.0));
    float2 uv = p / tile;
    // partly cloudy: cloud shadows drift over the sun's light, so it comes and goes
    float gate = u.scene[10].y;
    if (u.scene[10].z > 0.0 && (any(u.scene[5].xyz != 0.0) || any(u.scene[6].xyz != 0.0))) {   // (at night: nothing to shade)
        float ph = u.scene[10].w;
        float n = dsNoise(float2(uv.x * 1.3 + ph, uv.y * 0.7 + ph * 0.37)) * 0.65
                + dsNoise(float2(uv.x * 2.9 - ph * 1.7, uv.y * 1.6 + 3.1)) * 0.35;
        float sh = smoothstep(0.38, 0.62, n);
        gate = mix(gate, sh, u.scene[10].z);
    }
    float3 c = (film_light(dsA0, dsA1, dsSmp, u.scene[5], p, tile, video, cols, u)
              + film_light(dsA0, dsA1, dsSmp, u.scene[6], p, tile, video, cols, u)) * gate
             + film_light(dsA0, dsA1, dsSmp, u.scene[7], p, tile, video, cols, u)
             + film_light(dsA0, dsA1, dsSmp, u.scene[8], p, tile, video, cols, u)
             + film_light(dsA0, dsA1, dsSmp, u.scene[9], p, tile, video, cols, u);
    float mask = 0.0;
    if (u.scene[10].x >= 0.0) mask = dot(film_tile(dsA0, dsA1, dsSmp, u.scene[10].x, p, tile, video, cols, u), float3(1.0 / 3.0));
    uint3 e = as_type<uint3>(c) & 0x7f800000u;
    if (any(e == 0x7f800000u)) c = float3(0.0);
    c = min(c, float3(60000.0));
    float l = dsLuma(c);
    FilmMixOut o;
    o.hdr = float4(c, saturate(mask));
    o.glow = float2(max(l - u.scene[1].z, 0.0), max(l - u.scene[1].w, 0.0));
    return o;
}

/// AgX (Blender's view transform, "Medium High Contrast" look), minimal fit, before its display
/// gamma (film_agx: display linear; film_agx_srgb: display sRGB).
static inline float3 film_agx_curve(float3 c) {
    const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                    float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                    float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                     float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                     float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float lo = -12.47393, hi = 4.026069;
    float3 v = inset * max(c, 1e-10);
    v = (clamp(log2(v), lo, hi) - lo) / (hi - lo);
    v = (((((15.5 * v - 40.14) * v + 31.96) * v - 6.868) * v + 0.4298) * v + 0.1191) * v - 0.00232;
    v = saturate(v);
    v = mix(v, v * v * (3.0 - 2.0 * v), 0.25);
    return max(outset * v, 0.0);
}

static inline float3 film_agx(float3 c) { return pow(film_agx_curve(c), 2.2); }

/// dsToSrgb(film_agx(c)) with one log2 + exp2 a channel instead of two of each: y^2.2 then
/// ^(1/2.4) is y^(2.2/2.4), and sRGB's linear toe (≤ 0.0031308) is y^2.2 · 12.92.
static inline float3 film_agx_srgb(float3 c) {
    float3 l = log2(film_agx_curve(c));
    bool3 toe = l * 2.2 <= log2(0.0031308);
    float3 e = exp2(l * select(float3(2.2 / 2.4), float3(2.2), toe));
    return select(1.055 * e - 0.055, e * 12.92, toe);
}

/// The HDR's uv for screen uv `uv`: aspect-filled.
static inline float2 film_fill(float2 uv, float2 res, float2 size) {
    float outA = res.x / res.y, img = size.x / size.y;
    float2 scale = (img > outA) ? float2(outA / img, 1.0) : float2(1.0, img / outA);
    return (uv - 0.5) * scale + 0.5;
}

// ------------------------------------------------------------------ the glass's cell tables
// Rain beads / runnels and settled flakes sit one per cell of fixed grids over the picture
// (per layer: `sc` cells down, aspect·sc across), each from a few hashes of its cell. The grain
// pass writes those hashes once per cell into rows below the grain lattice (FILM_TABLE_ROWS of
// them, from row u.scene[1].x of the screen pass); the screen pass gathers a cell's four instead
// of hashing per pixel. Same functions, same values: the picture doesn't change.
//   drops layer i: 2×2 texels a cell — (h, c.x | c.y, r) = film_drop_hashes<i>
//   flakes layer i: 2×3 texels a cell — the same four, then the clump's brightness hash
constant float FILM_TABLE_SC[6] = { 70.0, 44.0, 24.0, 13.0, 38.0, 21.0 };   // drops 0…3, flakes 0…1
constant int FILM_TABLE_BASE[6] = { 0, 142, 232, 282, 310, 427 };        // 2 or 3 rows a cell row
#define FILM_TABLE_ROWS 493

/// The share of drop layer i's cells that hold a bead (or runnel) for rain `amount`.
template <int i> static inline float film_drop_p(float amount) {
    return i == 0 ? 0.9 * amount : (i == 1 ? 0.75 * amount : (i == 2 ? 0.4 * amount * amount : 0.45 * amount * amount * amount));
}

template <int i> static inline float4 film_drop_hashes(float2 cell) {
    return float4(dsHash(cell + float(i) * 7.1), dsHash2(cell + 3.3), dsHash(cell + 1.7));
}
template <int i> static inline float film_flake_hash(float2 cell) { return dsHash(cell + 11.3 + float(i) * 5.7); }
static inline float3 film_flake_hashes(float2 cell) { return float3(dsHash2(cell + 9.1), dsHash(cell + 4.2)); }
static inline float film_flake_bright(float2 cell) { return dsHash(cell + 6.6); }

/// Where a screen pass reads the tables (row: 0 = none, hash per pixel).
struct FilmTable {
    float row;
    float2 inv;       // 1 / the texture's size
    float cols;       // texels across
};

/// The table's texel (x, y) of `layer` at `cell` (top-left of its block), or −1 off the table.
static inline float2 film_table_at(FilmTable tb, int layer, float2 cell, float aspect, int rowsPerCell) {
    float sc = FILM_TABLE_SC[layer];
    float2 n = float2(floor(aspect * sc) + 1.0, sc + 1.0);
    if (tb.row <= 0.0 || any(cell < 0.0) || any(cell >= n) || 2.0 * n.x > tb.cols) return float2(-1.0);
    return float2(2.0 * cell.x, tb.row + float(FILM_TABLE_BASE[layer]) + float(rowsPerCell) * cell.y);
}

/// The grain pass's texel (x, y) at or below row `row0` (its table rows): the hashes it holds.
static inline float film_table_texel(uint2 xy, float row0, float aspect) {
    int y = int(xy.y) - int(row0);
    int layer = 5;
    for (int k = 1; k < 6; k++) { if (y < FILM_TABLE_BASE[k]) { layer = k - 1; break; } }
    int per = layer < 4 ? 2 : 3;
    int ly = y - FILM_TABLE_BASE[layer];
    float2 cell = float2(float(xy.x / 2), float(ly / per));
    uint q = (xy.x & 1u) + 2u * uint(ly % per);                     // which of the cell's values
    if (cell.x > floor(aspect * FILM_TABLE_SC[layer])) return 0.0;
    float4 v;
    switch (layer) {
        case 0: v = film_drop_hashes<0>(cell); break;
        case 1: v = film_drop_hashes<1>(cell); break;
        case 2: v = film_drop_hashes<2>(cell); break;
        case 3: v = film_drop_hashes<3>(cell); break;
        case 4: v = float4(film_flake_hash<0>(cell), film_flake_hashes(cell)); break;
        default: v = float4(film_flake_hash<1>(cell), film_flake_hashes(cell)); break;
    }
    if (q >= 4u) return q == 4u ? film_flake_bright(cell) : 0.0;
    return v[q];
}

// The glass map, below the tables (FILM_MAP_BLOCK-pixel blocks of the screen): bit i set where
// drop layer i (bits 0…3) or flake layer i (bits 4, 5) may draw — a cell of it that holds a bead,
// runnel or flake reaches into the block (its whole reach: the bead's ellipse, a runnel's column
// over every wind skew, a flake's largest clump). The screen pass skips the layers whose bit is
// clear: they'd add nothing there. Made with the tables, for this screen and rain, snow and wind.
#define FILM_MAP_BLOCK 8u

template <int i>
static inline bool film_drop_reaches(float2 g0, float2 g1, float amount, float wind) {
    const float sc = i == 0 ? 70.0 : (i == 1 ? 44.0 : (i == 2 ? 24.0 : 13.0));
    g0 *= sc; g1 *= sc;
    float2 c0 = floor(g0), c1 = floor(g1);
    for (float y = c0.y; y <= c1.y; y += 1.0) {
        for (float x = c0.x; x <= c1.x; x += 1.0) {
            float2 cell = float2(x, y);
            float4 hv = film_drop_hashes<i>(cell);
            if (hv.x > film_drop_p<i>(amount)) continue;
            float2 c = (hv.yz - 0.5) * 0.45;
            float r = (i == 0 ? 0.10 : i == 1 ? 0.12 : 0.15) + 0.08 * hv.w;
            float2 lo, hi;                                            // its reach, in g (cell + 0.5 + f)
            if (i == 3) {                                             // a runnel: its column, the whole cell down
                float m = max(r, 0.06) + 0.02;
                lo = float2(cell.x + 0.5 + c.x + min(0.0, -0.015 * wind) - m, cell.y);
                hi = float2(cell.x + 0.5 + c.x + 0.375 * wind + m, cell.y + 1.0);
            } else {
                float2 e = float2(r, 1.2 * r) + 0.02;
                lo = cell + 0.5 + c - e; hi = cell + 0.5 + c + e;
            }
            if (all(hi >= g0) && all(lo <= g1)) return true;
        }
    }
    return false;
}

template <int i>
static inline bool film_flake_reaches(float2 g0, float2 g1, float amount) {
    const float sc = i == 0 ? 38.0 : 21.0;
    g0 *= sc; g1 *= sc;
    float2 c0 = floor(g0), c1 = floor(g1);
    for (float y = c0.y; y <= c1.y; y += 1.0) {
        for (float x = c0.x; x <= c1.x; x += 1.0) {
            float2 cell = float2(x, y);
            if (film_flake_hash<i>(cell) > amount * (i == 0 ? 0.8 : 0.5)) continue;
            float3 hv = film_flake_hashes(cell);
            float2 c = (hv.xy - 0.5) * 0.4;
            float e = (0.10 + 0.08 * hv.z) / 0.76 + 0.02;
            float2 lo = cell + 0.5 + c - e, hi = cell + 0.5 + c + e;
            if (all(hi >= g0) && all(lo <= g1)) return true;
        }
    }
    return false;
}

/// The map's texel for block `b`. u.scene[1] = (screen width, height, HDR width, height),
/// u.scene[2] = (rain, snow, 0, wind) as the screen pass reads them (its u.scene[2], [3].w).
static inline float film_glass_map(uint2 b, constant FXUniforms& u) {
    float2 res = max(u.scene[1].xy, float2(1.0)), size = max(u.scene[1].zw, float2(1.0));
    float aspect = size.x / size.y;
    // the block, a pixel wider each side (the screen's uv is interpolated), in the HDR's uv
    float2 p0 = float2(b * FILM_MAP_BLOCK) - 1.0, p1 = float2(b * FILM_MAP_BLOCK + FILM_MAP_BLOCK) + 1.0;
    float2 t0 = film_fill(p0 / res, res, size), t1 = film_fill(p1 / res, res, size);
    float2 g0 = float2(t0.x * aspect, t0.y), g1 = float2(t1.x * aspect, t1.y);
    float rain = saturate(u.scene[2].x), snow = saturate(u.scene[2].y), wind = saturate(u.scene[2].w);
    uint bits = 0u;
    if (rain > 0.02) {
        float amount = saturate(rain * 1.25 + 0.08);
        if (film_drop_reaches<0>(g0, g1, amount, wind)) bits |= 1u;
        if (film_drop_reaches<1>(g0, g1, amount, wind)) bits |= 2u;
        if (film_drop_reaches<2>(g0, g1, amount, wind)) bits |= 4u;
        if (film_drop_reaches<3>(g0, g1, amount, wind)) bits |= 8u;
    }
    if (snow > 0.02) {
        float amount = saturate(snow * 1.5);
        if (film_flake_reaches<0>(g0, g1, amount)) bits |= 16u;
        if (film_flake_reaches<1>(g0, g1, amount)) bits |= 32u;
    }
    return float(bits);
}

/// A screen pixel's tables (below the grain lattice, when the grain pass made one for this screen)
/// and its glass-map bits (63: every layer, without a map).
static inline FilmTable film_table_for(float2 px, float2 res, constant FXUniforms& u, texture2d<float> lat,
                                       thread uint& bits) {
    FilmTable tb;
    tb.row = u.scene[0].w == res.y ? u.scene[1].x : 0.0;
    tb.inv = 1.0 / float2(lat.get_width(), lat.get_height());
    tb.cols = float(lat.get_width());
    uint2 mb = uint2(px) / FILM_MAP_BLOCK;                            // this pixel's glass-map block
    if (tb.row + float(FILM_TABLE_ROWS) + float(mb.y) >= float(lat.get_height()) || float(mb.x) >= tb.cols) tb.row = 0.0;
    bits = tb.row > 0.0 ? uint(lat.read(uint2(mb.x, uint(tb.row) + FILM_TABLE_ROWS + mb.y)).r) : 63u;
    return tb;
}

/// Rain on the glass: beads and runnels. `amount` 0…1 (drizzle ≈ 0.35: fine sparse beads, hardly
/// a runnel; heavy ≈ 1: dense beads, many fast runnels). Returns the refraction offset (xy), the
/// bead coverage (z) and a rim term (w): beads flip and magnify what's behind, rims go dark.
template <int i>
static inline void film_drop_layer(float2 uv, float aspect, float t, float amount, float speed, float wind,
                                   texture2d<float> lat, sampler smp, FilmTable tb,
                                   thread float2& off, thread float& cover, thread float& rim) {
    const float sc = i == 0 ? 70.0 : (i == 1 ? 44.0 : (i == 2 ? 24.0 : 13.0));
    float2 g = float2(uv.x * aspect, uv.y) * sc;
    float2 cell = floor(g);
    float2 at = film_table_at(tb, i, cell, aspect, 2);
    bool table = at.x >= 0.0;
    float4 hv;
    if (table) {
        float4 q = lat.gather(smp, (at + 1.0) * tb.inv);
        hv = float4(q.w, q.z, q.x, q.y);
    } else {
        hv.x = dsHash(cell + float(i) * 7.1);
    }
    float h = hv.x;
    if (h > film_drop_p<i>(amount)) return;
    if (!table) hv = film_drop_hashes<i>(cell);
    float2 f = fract(g) - 0.5;
    float2 c = (hv.yz - 0.5) * 0.45;
    const bool runnel = i == 3;
    if (runnel) {                                                     // slides down (wind skews it)
        c.y = -0.55 + fract(t * (0.04 + 0.06 * h) * speed + h * 9.0) * 1.3;
        c.x += wind * 0.3 * (c.y + 0.5);
    }
    float r = (i == 0 ? 0.10 : i == 1 ? 0.12 : 0.15) + 0.08 * hv.w;
    float2 d = (f - c) / float2(1.0, 1.2);
    float l = length(d);
    // (outside the bead — and for a runnel off its trail's column too — nothing)
    if (l >= r && (!runnel || abs(f.x - c.x) >= 0.06)) return;
    float k = smoothstep(r, r * 0.8, l);
    off += -d / max(r, 1e-3) * k * (0.004 + 0.003 * float(i));
    cover = max(cover, k);
    rim = max(rim, k * smoothstep(r * 0.5, r, l));
    if (runnel) {                                                     // its wet trail above (y down)
        float trail = smoothstep(0.06, 0.0, abs(f.x - c.x)) * step(f.y, c.y) * (1.0 - smoothstep(0.0, 0.9, c.y - f.y));
        cover = max(cover, trail * 0.5);
        off += float2(0.0, 0.003) * trail;
    }
}

static inline float4 film_drops(float2 uv, float aspect, float t, float amount, float wind,
                                texture2d<float> lat, sampler smp, FilmTable tb, uint bits) {
    float2 off = 0.0; float cover = 0.0, rim = 0.0;
    float speed = 0.5 + 1.6 * amount * amount;
    if (bits & 1u) film_drop_layer<0>(uv, aspect, t, amount, speed, wind, lat, smp, tb, off, cover, rim);
    if (bits & 2u) film_drop_layer<1>(uv, aspect, t, amount, speed, wind, lat, smp, tb, off, cover, rim);
    if (bits & 4u) film_drop_layer<2>(uv, aspect, t, amount, speed, wind, lat, smp, tb, off, cover, rim);
    if (bits & 8u) film_drop_layer<3>(uv, aspect, t, amount, speed, wind, lat, smp, tb, off, cover, rim);
    return float4(off, cover, rim);
}

/// Snow (and sleet's slush) settling on the glass and melting away: (coverage, slush 0…1).
template <int i>
static inline void film_flake_layer(float2 uv, float aspect, float t, float amount, float slush,
                                    texture2d<float> lat, sampler smp, FilmTable tb,
                                    thread float& cover, thread float& wet) {
    const float sc = i == 0 ? 38.0 : 21.0;
    float2 g = float2(uv.x * aspect, uv.y) * sc;
    float2 cell = floor(g);
    float2 at = film_table_at(tb, 4 + i, cell, aspect, 3);
    bool table = at.x >= 0.0;
    float4 hv;
    if (table) {
        float4 q = lat.gather(smp, (at + 1.0) * tb.inv);
        hv = float4(q.w, q.z, q.x, q.y);
    } else {
        hv.x = film_flake_hash<i>(cell);
    }
    float h = hv.x;
    if (h > amount * (i == 0 ? 0.8 : 0.5)) return;
    if (!table) hv.yzw = film_flake_hashes(cell);
    float2 f = fract(g) - 0.5;
    float2 c = (hv.yz - 0.5) * 0.4;
    float2 d = f - c;
    float len = length(d);
    float r0 = 0.10 + 0.08 * hv.w;
    if (len * 0.76 >= r0) return;                                     // (r ≤ r0, lobes ≥ 0.77: outside it)
    float life = fract(t * (0.025 + 0.02 * h) + h * 13.0);           // lands, lingers, melts
    float a = smoothstep(0.0, 0.06, life) * (1.0 - smoothstep(0.55, 0.95, life));
    float r = r0 * mix(1.0, 0.55, smoothstep(0.4, 0.95, life));
    if (len * 0.76 >= r) return;
    float ang = atan2(d.y, d.x);
    // a soft, ragged clump of crystals (or a round slush blob), frosty at its edge
    float lobes = 1.0 + (0.14 * sin(ang * 5.0 + h * 40.0) + 0.09 * sin(ang * 3.0 - h * 17.0)) * (1.0 - slush);
    float bright = table ? lat.read(uint2(at + float2(0.0, 2.0))).r : film_flake_bright(cell);
    float k = smoothstep(r, r * 0.2, len * lobes) * a * (0.75 + 0.25 * bright);
    cover = max(cover, k * (1.0 - smoothstep(0.6, 0.95, life) * 0.6));
    wet = max(wet, k * max(slush, smoothstep(0.5, 0.9, life)));
}

static inline float2 film_flakes(float2 uv, float aspect, float t, float amount, float slush,
                                 texture2d<float> lat, sampler smp, FilmTable tb, uint bits) {
    float cover = 0.0, wet = 0.0;
    if (bits & 16u) film_flake_layer<0>(uv, aspect, t, amount, slush, lat, smp, tb, cover, wet);
    if (bits & 32u) film_flake_layer<1>(uv, aspect, t, amount, slush, lat, smp, tb, cover, wet);
    return float2(cover, wet);
}

/// Flakes falling beyond the glass (in the window): small soft dots drifting down with the wind.
static inline float film_falling(float2 uv, float aspect, float t, float amount, float wind) {
    float s = 0.0;
    for (int i = 0; i < 2; i++) {
        float sc = i == 0 ? 26.0 : 48.0;
        float sp = i == 0 ? 0.09 : 0.055;
        float2 g = float2(uv.x * aspect, uv.y) * sc + float2(-t * (0.3 + wind) * sp * sc, -t * sp * sc);
        float2 cell = floor(g);
        float h = dsHash(cell + 21.7 + float(i) * 3.3);
        if (h > amount * 0.55) continue;
        float2 c0 = (dsHash2(cell + 2.9) - 0.5) * 0.6;
        float r = i == 0 ? 0.09 : 0.07;
        float2 e = fract(g) - 0.5 - c0;
        if (dot(e, e) >= (r + 0.12) * (r + 0.12)) continue;          // (its wobble ≤ 0.08·√2: out of reach)
        float2 c = c0 + 0.08 * sin(float2(t * 1.3, t * 0.9) + h * 20.0);
        s = max(s, smoothstep(r, r * 0.3, length(fract(g) - 0.5 - c)) * (i == 0 ? 1.0 : 0.6));
    }
    return s;
}

/// film_finish for light layers: the grain from the grain pass's lattice when it was made for this
/// frame and screen (u.scene[0].zw), else hashed here — the same grain either way.
static inline float4 film_finish_layers(float3 a, float2 px, float2 res, constant FXUniforms& u,
                                        texture2d<float> lat, sampler s) {
    float grain = saturate(u.scene[8].x);
    if (grain > 0.0) {
        float fps = u.scene[1].y > 1.0 ? u.scene[1].y : 24.0;
        uint frame = uint(max(floor(u.time * fps), 0.0));
        float cell = max(res.y / 1100.0 * 1.4, 1.0);
        float l = dsLuma(a);
        float w = 0.25 + 0.75 * saturate(4.0 * l * (1.0 - l));
        uint2 need = uint2(floor((res - 0.5) / cell)) + 2u;          // the corners this screen reaches
        bool lattice = u.scene[0].z == float(frame) && u.scene[0].w == res.y
                    && lat.get_width() >= need.x && lat.get_height() >= need.y;
        a += (lattice ? film_grain_lattice(px, cell, lat, s) : film_grain(px, cell, frame)) * grain * 0.16 * w;
        // (the grain dithers already: ds_finish's own dither would only cost a sin a pixel)
        uint3 e = as_type<uint3>(a) & 0x7f800000u;
        return float4(any(e == 0x7f800000u) ? float3(0.0) : saturate(a), 1.0);
    }
    return ds_finish(a, px);
}

/// The vignette (in light, before the view transform, as the toolkit's look).
static inline float3 film_vignette(float3 c, float2 tuv, float vg) {
    if (vg > 0.0) {
        float rr = length((tuv - 0.5) / 0.625);
        float k = saturate((rr - 0.82) / 0.36);
        c *= 1.0 - vg * k * k;
    }
    return c;
}

/// Halation + bloom (rgb), at half the tiles' size: mip taps of the highlights, two levels each
/// for a softer falloff. dsA0 = HDR, dsA1 = highlights (both mipmapped).
fragment float4 ds_film_look(DS_FRAGMENT_PARAMS) {
    float2 uv = in.pos.xy / max(u.resolution, float2(1.0));
    float hal = u.scene[0].x, bloom = u.scene[0].y;
    float3 light = 0.0;
    if (hal > 0.0 || bloom > 0.0) {
        float lh = u.scene[0].z, lb = u.scene[0].w;
        float h = 0.5 * (dsA1.sample(dsSmp, uv, level(lh - 0.5)).r + dsA1.sample(dsSmp, uv, level(lh + 0.7)).r);
        float b = 0.5 * (dsA1.sample(dsSmp, uv, level(lb - 0.5)).g + dsA1.sample(dsSmp, uv, level(lb + 0.7)).g);
        float3 bc = dsA0.sample(dsSmp, uv, level(lb)).rgb;
        bc = bc / max(dsLuma(bc), 1e-4);
        light = hal * (0.35 / 0.15) * h * float3(1.0, 0.32, 0.10) + bloom * b * min(bc, float3(4.0));
    }
    return float4(light, 0.0);
}

/// Fog / condensation, at the tiles' size (only while there's mist): the misted view (rgb,
/// display linear) and how far the mist creeps in from the glass's edges (a). dsA0 = HDR.
fragment float4 ds_film_mist(DS_FRAGMENT_PARAMS) {
    float2 uv = in.pos.xy / max(u.resolution, float2(1.0));
    return float4(film_agx(dsA0.sample(dsSmp, uv, level(3.0)).rgb) * 0.92 + 0.03,
                  saturate((1.0 - dsA0.sample(dsSmp, uv, level(4.5)).a) * 2.2));
}

fragment float4 ds_film_grain(DS_FRAGMENT_PARAMS) {
    // texel (x, y) = the grain's lattice point (x, y) for the frame (film_grain's corners); from
    // row u.scene[0].y on, the glass's cell tables (aspect u.scene[0].z)
    uint2 xy = uint2(in.pos.xy);
    if (u.scene[0].y > 0.0 && in.pos.y >= u.scene[0].y + float(FILM_TABLE_ROWS))
        return float4(film_glass_map(xy - uint2(0, uint(u.scene[0].y) + FILM_TABLE_ROWS), u), 0.0, 0.0, 1.0);
    if (u.scene[0].y > 0.0 && in.pos.y >= u.scene[0].y)
        return float4(film_table_texel(xy, u.scene[0].y, u.scene[0].z), 0.0, 0.0, 1.0);
    return float4(film_hash(uint2(int2(in.pos.xy) + 32768), uint(u.scene[0].x)), 0.0, 0.0, 1.0);
}

/// The screen pass for dry glass (FilmLayers' `dry`: no rain, snow or lightning, fog ≤ 0.02 so no
/// mist): film_layered without the glass code it would skip.
fragment float4 ds_film_dry(DS_FRAGMENT_PARAMS) {
    float2 res = max(u.resolution, float2(1.0));
    float2 tuv = film_fill(in.uv, res, max(u.scene[0].xy, float2(1.0)));
    float4 base = dsA0.sample(dsSmp, tuv, level(0.0));
    float3 c = base.rgb;
    float fog = saturate(u.scene[2].z);
    if (fog > 0.01 && base.a > 0.01) {                                // (partly cloudy's haze)
        float3 amb = dsA0.sample(dsSmp, tuv, level(6.0)).rgb;
        c = mix(c, amb * 1.05, base.a * fog * 0.6);
    }
    c += dsA1.sample(dsSmp, tuv, level(0.0)).rgb;
    c = film_vignette(c, tuv, u.scene[3].x);
    return film_finish_layers(film_agx_srgb(c), in.pos.xy, res, u, dsA3, dsSmp);
}

/// The screen pass. `wetOn` / `snowOn`: rain and snow on the glass (false: compiled out, for the
/// lean variants — drawn only when that weather is 0, so the same pixels); lightning with either.
template <bool wetOn, bool snowOn>
static inline float4 film_layered(DSVOut in, constant FXUniforms& u, texture2d<float> hdrT,
                                  texture2d<float> lightT, texture2d<float> mistT, texture2d<float> latT,
                                  sampler smp) {
    float2 res = max(u.resolution, float2(1.0));
    float2 size = max(u.scene[0].xy, float2(1.0));
    float img = size.x / size.y;
    float2 tuv = film_fill(in.uv, res, size);

    const bool precip = wetOn || snowOn;
    float rain = wetOn ? saturate(u.scene[2].x) : 0.0, snow = snowOn ? saturate(u.scene[2].y) : 0.0;
    float fog = saturate(u.scene[2].z);
    float flash = precip ? saturate(u.scene[2].w) : 0.0, wind = saturate(u.scene[3].w);
    float t = u.time;
    float4 base = hdrT.sample(smp, tuv, level(0.0));
    float mask = base.a;
    // the glass's cell tables, below the grain lattice when the grain pass made one for this screen
    float2 suv = tuv;
    float bead = 0.0, rimDark = 0.0;
    if (rain > 0.02 && mask > 0.01) {
        uint bits;
        FilmTable tb = film_table_for(in.pos.xy, res, u, latT, bits);
        float4 d = film_drops(tuv, img, t, saturate(rain * 1.25 + 0.08), wind, latT, smp, tb, bits);
        suv += d.xy * mask;
        bead = d.z * mask;
        rimDark = d.w * mask;
    }
    float3 c = (rain > 0.02 && mask > 0.01) ? hdrT.sample(smp, suv, level(0.0)).rgb : base.rgb;

    // beyond the glass: fog hazes the view (lower contrast toward the ambient light)
    if (fog > 0.01 && mask > 0.01) {
        float3 amb = hdrT.sample(smp, suv, level(6.0)).rgb;
        c = mix(c, amb * 1.05, mask * fog * 0.6);
    }
    c += lightT.sample(smp, suv, level(0.0)).rgb;                    // halation and bloom (ds_film_look)
    c = film_vignette(c, tuv, u.scene[3].x);
    // off the glass nothing below applies: straight to sRGB (as ds_film_dry)
    if (mask <= 0.01) return film_finish_layers(film_agx_srgb(c), in.pos.xy, res, u, latT, smp);
    float3 o = film_agx(c);                                          // display linear

    // snow falling beyond the glass
    if (snow > 0.02 && mask > 0.01) {
        float f = film_falling(tuv, img, t, saturate(snow * 1.4), wind);
        float lit = saturate(dsLuma(o) * 1.6 + 0.06);
        o = mix(o, float3(0.9, 0.93, 0.97) * lit, f * mask * 0.9);
    }
    // the glass itself: a cool wet veil, condensation creeping in from its edges in fog / rain /
    // snow, bead rims dark, beads catching a little light, settled flakes and slush
    float night = 1.0 - smoothstep(-6.0, 4.0, u.scene[4].x);
    if (mask > 0.01) {
        float wetness = saturate(rain + 0.6 * snow);
        o = mix(o, o * float3(0.86, 0.9, 0.96) + 0.015, mask * wetness * 0.6);
        float damp = max(fog, max(0.5 * rain, 0.45 * snow));
        if (damp > 0.02) {
            float edge = mask * mistT.sample(smp, tuv, level(0.0)).a;    // (ds_film_look)
            float3 misted = mistT.sample(smp, suv, level(0.0)).rgb;
            o = mix(o, misted, saturate(edge * damp * 1.1 + mask * fog * 0.25));
        }
        o *= 1.0 - (0.30 - 0.15 * night) * rimDark;
        o += bead * (0.025 + 0.02 * (1.0 - night)) * float3(0.9, 0.95, 1.0);
        if (snow > 0.02) {
            float slush = saturate(rain / max(rain + snow, 1e-3));    // sleet: half slush
            uint bits;
            FilmTable tb = film_table_for(in.pos.xy, res, u, latT, bits);
            float2 fl = film_flakes(tuv, img, t, saturate(snow * 1.5), slush, latT, smp, tb, bits) * mask;
            float lit = saturate(dsLuma(o) * 1.4 + 0.1);
            o = mix(o, float3(0.92, 0.94, 0.97) * lit, fl.x * (1.0 - 0.5 * fl.y));
        }
        // lightning: a faint cool flicker on the glass, on top of the sky layer's own spike
        o += flash * mask * 0.03 * float3(0.8, 0.88, 1.0);
    }
    return film_finish_layers(dsToSrgb(o), in.pos.xy, res, u, latT, smp);
}

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    return film_layered<true, true>(in, u, dsA0, dsA1, dsA2, dsA3, dsSmp);
}

/// The screen pass for damp glass without rain, snow or lightning (overcast, fog): ds_fragment
/// without their code (FilmLayers picks it only when they're 0: the same pixels).
fragment float4 ds_film_damp(DS_FRAGMENT_PARAMS) {
    return film_layered<false, false>(in, u, dsA0, dsA1, dsA2, dsA3, dsSmp);
}

/// … with rain and lightning but no snow (drizzle, rain, heavy rain, storms).
fragment float4 ds_film_rain(DS_FRAGMENT_PARAMS) {
    return film_layered<true, false>(in, u, dsA0, dsA1, dsA2, dsA3, dsSmp);
}

/// … with snow (and lightning) but no rain.
fragment float4 ds_film_snow(DS_FRAGMENT_PARAMS) {
    return film_layered<false, true>(in, u, dsA0, dsA1, dsA2, dsA3, dsSmp);
}

#else

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    float2 res = max(u.resolution, float2(1.0));
    float2 sizeA = max(u.scene[0].xy, float2(1.0));
    float3 a = film_cover(dsA0, dsSmp, in.uv, res, sizeA);
    float k = saturate(u.scene[1].x);
    if (k > 0.0) {
        float3 b = film_cover(dsA1, dsSmp, in.uv, res, max(u.scene[0].zw, float2(1.0)));
        a = dsToSrgb(mix(dsToLinear(a), dsToLinear(b), k));
    }
    float halation = saturate(u.scene[8].y);

    // Halation: highlights bleed a warm glow into their surroundings, for clips that weren't
    // graded with it. One tap ~0.7 % of the screen's height away, its direction alternating per
    // pixel (the grain hides the dither): a soft ring at the cost of one extra sample.
    if (halation > 0.0) {
        float r = 0.007;
        float2 o = float2(r * res.y / res.x, r);
        uint2 ip = uint2(in.pos.xy);
        float2 dir = ((ip.x + ip.y) & 1u) != 0u ? float2(1.0, 1.0) : float2(-1.0, 1.0);
        if ((ip.y & 1u) != 0u) dir = -dir;
        float3 h = film_cover(dsA0, dsSmp, in.uv + o * dir, res, sizeA);
        float hl = smoothstep(0.62, 1.0, dsLuma(h));
        a += halation * 0.22 * hl * float3(1.0, 0.45, 0.25) * (1.0 - a);   // (a screen-blend: no pow)
    }
    return film_finish(a, in.pos.xy, res, u);
}
#endif
