//  film.metal — the `film` engine's shaders. CustomFilm.swift drives them.
//
//  Variant clips (ds_fragment, u.scene[1].z == 0): the clip showing (dsA0), aspect-filled,
//  crossfading from the one before it (dsA1) in linear light, then a live film grain (and an
//  optional halation for clips that weren't graded).
//    u.scene[0] = (clip A width, height, clip B width, height)
//    u.scene[1] = (mix 0 = all A, the clip's frame rate, 0, 0)
//    u.scene[8] = (Grain 0…1, Halation 0…1, Weather menu, 0)   — the engine's params (engine.json)
//
//  Light layers (docs/film-layers.md), two passes:
//  1. ds_film_mix, at the tiles' own resolution, only when the video frame or the light changed:
//     the light tiles of the layers video (10-bit Y'CbCr planes, decoded pow4 × scale) summed with
//     their weights (sun, low sun, sky, cabin, city — from the real sun and the weather, the
//     exposure folded in) → HDR (rgb, mask in a) + the highlights over the bloom / halation
//     thresholds (glow: r, g); both mipmapped (the blurs are mip taps).
//    u.scene[0] = (video width, height, tile width, height)   — luma pixels
//    u.scene[1] = (columns, rows, halation threshold, bloom threshold)   — exposed units
//    u.scene[2…4] = Y'CbCr → R'G'B' rows (rgb[i] = dot(row.xyz, (y, cb, cr)) + row.w)
//    u.scene[5…9] = weight rgb (scale, tint, exposure folded in) + tile index (−1: none) for
//                   sun, sun_low, sky, cabin, city
//    u.scene[10] = (mask tile index, sun gate (clear), cloud-shadow amount, cloud-shadow phase)
//  2. ds_fragment (u.scene[1].z == 1) at the screen's size: the HDR aspect-filled, the glass
//     weather drawn live through the mask (rain beads and runnels that refract, snow and sleet
//     settling and melting, falling flakes beyond the glass, fog and condensation), halation and
//     bloom from the mips, vignette, AgX, grain.
//    u.scene[0] = (HDR width, height, 0, 0)
//    u.scene[1] = (0, frame rate, 1, bloom strength)
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

struct FilmMixOut {
    float4 hdr [[color(0)]];      // exposed scene-linear rgb, glass mask in a
    float2 glow [[color(1)]];     // luminance over the halation / bloom thresholds
};

/// One tile's texel at tile-local pixel `p` (top-left origin) as R'G'B' (0…1 code values).
/// Clamped inside the tile — by half a luma texel, and a whole one for the half-size chroma
/// plane — so neither the bilinear taps nor 4:2:0 chroma reach into the neighbouring tile.
static inline float3 film_tile(texture2d<float> y, texture2d<float> c, sampler s, float idx, float2 p,
                               float2 tile, float2 video, float cols, constant FXUniforms& u) {
    float2 origin = float2(fmod(idx, cols), floor(idx / cols)) * tile;
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

fragment FilmMixOut ds_film_mix(DS_FRAGMENT_PARAMS) {
    // dsA0 = luma (r16Unorm), dsA1 = chroma (rg16Unorm), both the whole grid
    float2 video = max(u.scene[0].xy, float2(1.0)), tile = max(u.scene[0].zw, float2(1.0));
    float cols = max(u.scene[1].x, 1.0);
    float2 p = in.pos.xy * tile / max(u.resolution, float2(1.0));
    float2 uv = p / tile;
    // partly cloudy: cloud shadows drift over the sun's light, so it comes and goes
    float gate = u.scene[10].y;
    if (u.scene[10].z > 0.0) {
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

/// AgX (Blender's view transform, "Medium High Contrast" look), minimal fit → display linear.
static inline float3 film_agx(float3 c) {
    const float3x3 inset = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                    float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                    float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 outset = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                     float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                     float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float lo = -12.47393, hi = 4.026069;
    float3 v = inset * max(c, 1e-10);
    v = (clamp(log2(v), lo, hi) - lo) / (hi - lo);
    float3 x2 = v * v, x4 = x2 * x2;
    v = 15.5 * x4 * x2 - 40.14 * x4 * v + 31.96 * x4 - 6.868 * x2 * v + 0.4298 * x2 + 0.1191 * v - 0.00232;
    v = saturate(v);
    v = mix(v, v * v * (3.0 - 2.0 * v), 0.25);
    return pow(max(outset * v, 0.0), 2.2);
}

/// Rain on the glass: beads and runnels. `amount` 0…1 (drizzle ≈ 0.35: fine sparse beads, hardly
/// a runnel; heavy ≈ 1: dense beads, many fast runnels). Returns the refraction offset (xy), the
/// bead coverage (z) and a rim term (w): beads flip and magnify what's behind, rims go dark.
static inline float4 film_drops(float2 uv, float aspect, float t, float amount, float wind) {
    float2 off = 0.0; float cover = 0.0, rim = 0.0;
    float speed = 0.5 + 1.6 * amount * amount;
    for (int i = 0; i < 4; i++) {
        float sc = i == 0 ? 70.0 : (i == 1 ? 44.0 : (i == 2 ? 24.0 : 13.0));
        float2 g = float2(uv.x * aspect, uv.y) * sc;
        float2 cell = floor(g);
        float h = dsHash(cell + float(i) * 7.1);
        float p = i == 0 ? 0.9 * amount : (i == 1 ? 0.75 * amount : (i == 2 ? 0.4 * amount * amount : 0.45 * amount * amount * amount));
        if (h > p) continue;
        float2 f = fract(g) - 0.5;
        float2 c = (dsHash2(cell + 3.3) - 0.5) * 0.45;
        bool runnel = i == 3;
        if (runnel) {                                                 // slides down (wind skews it)
            c.y = -0.55 + fract(t * (0.04 + 0.06 * h) * speed + h * 9.0) * 1.3;
            c.x += wind * 0.3 * (c.y + 0.5);
        }
        float r = (i == 0 ? 0.10 : i == 1 ? 0.12 : 0.15) + 0.08 * dsHash(cell + 1.7);
        float2 d = (f - c) / float2(1.0, 1.2);
        float l = length(d);
        float k = smoothstep(r, r * 0.8, l);
        off += -d / max(r, 1e-3) * k * (0.004 + 0.003 * float(i));
        cover = max(cover, k);
        rim = max(rim, k * smoothstep(r * 0.5, r, l));
        if (runnel) {                                                 // its wet trail above (y down)
            float trail = smoothstep(0.06, 0.0, abs(f.x - c.x)) * step(f.y, c.y) * (1.0 - smoothstep(0.0, 0.9, c.y - f.y));
            cover = max(cover, trail * 0.5);
            off += float2(0.0, 0.003) * trail;
        }
    }
    return float4(off, cover, rim);
}

/// Snow (and sleet's slush) settling on the glass and melting away: (coverage, slush 0…1).
static inline float2 film_flakes(float2 uv, float aspect, float t, float amount, float slush) {
    float cover = 0.0, wet = 0.0;
    for (int i = 0; i < 2; i++) {
        float sc = i == 0 ? 38.0 : 21.0;
        float2 g = float2(uv.x * aspect, uv.y) * sc;
        float2 cell = floor(g);
        float h = dsHash(cell + 11.3 + float(i) * 5.7);
        if (h > amount * (i == 0 ? 0.8 : 0.5)) continue;
        float life = fract(t * (0.025 + 0.02 * h) + h * 13.0);       // lands, lingers, melts
        float a = smoothstep(0.0, 0.06, life) * (1.0 - smoothstep(0.55, 0.95, life));
        float2 f = fract(g) - 0.5;
        float2 c = (dsHash2(cell + 9.1) - 0.5) * 0.4;
        float2 d = f - c;
        float r = (0.10 + 0.08 * dsHash(cell + 4.2)) * mix(1.0, 0.55, smoothstep(0.4, 0.95, life));
        float ang = atan2(d.y, d.x);
        // a soft, ragged clump of crystals (or a round slush blob), frosty at its edge
        float lobes = 1.0 + (0.14 * sin(ang * 5.0 + h * 40.0) + 0.09 * sin(ang * 3.0 - h * 17.0)) * (1.0 - slush);
        float k = smoothstep(r, r * 0.2, length(d) * lobes) * a * (0.75 + 0.25 * dsHash(cell + 6.6));
        cover = max(cover, k * (1.0 - smoothstep(0.6, 0.95, life) * 0.6));
        wet = max(wet, k * max(slush, smoothstep(0.5, 0.9, life)));
    }
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
        float2 c = (dsHash2(cell + 2.9) - 0.5) * 0.6 + 0.08 * sin(float2(t * 1.3, t * 0.9) + h * 20.0);
        float r = i == 0 ? 0.09 : 0.07;
        s = max(s, smoothstep(r, r * 0.3, length(fract(g) - 0.5 - c)) * (i == 0 ? 1.0 : 0.6));
    }
    return s;
}

static inline float4 film_layered(DSVOut in, constant FXUniforms& u, texture2d<float> hdrT,
                                  texture2d<float> glowT, sampler smp) {
    float2 res = max(u.resolution, float2(1.0));
    float2 size = max(u.scene[0].xy, float2(1.0));
    float outA = res.x / res.y, img = size.x / size.y;
    float2 scale = (img > outA) ? float2(outA / img, 1.0) : float2(1.0, img / outA);
    float2 tuv = (in.uv - 0.5) * scale + 0.5;

    float rain = saturate(u.scene[2].x), snow = saturate(u.scene[2].y), fog = saturate(u.scene[2].z);
    float flash = saturate(u.scene[2].w), wind = saturate(u.scene[3].w);
    float t = u.time;
    float4 base = hdrT.sample(smp, tuv, level(0.0));
    float mask = base.a;
    float2 suv = tuv;
    float bead = 0.0, rimDark = 0.0;
    if (rain > 0.02 && mask > 0.01) {
        float4 d = film_drops(tuv, img, t, saturate(rain * 1.25 + 0.08), wind);
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
    // halation and bloom: mip taps of the highlights (two levels each, for a softer falloff)
    float hal = saturate(u.scene[8].y), bloom = u.scene[1].w;
    if (hal > 0.0 || bloom > 0.0) {
        float lh = u.scene[3].y, lb = u.scene[3].z;
        float h = 0.5 * (glowT.sample(smp, suv, level(lh - 0.5)).r + glowT.sample(smp, suv, level(lh + 0.7)).r);
        float b = 0.5 * (glowT.sample(smp, suv, level(lb - 0.5)).g + glowT.sample(smp, suv, level(lb + 0.7)).g);
        float3 bc = hdrT.sample(smp, suv, level(lb)).rgb;
        bc = bc / max(dsLuma(bc), 1e-4);
        c += hal * (0.35 / 0.15) * h * float3(1.0, 0.32, 0.10) + bloom * b * min(bc, float3(4.0));
    }
    // vignette (in light, before the view transform, as the toolkit's look)
    float vg = u.scene[3].x;
    if (vg > 0.0) {
        float rr = length((tuv - 0.5) / 0.625);
        float m = 1.0 - pow(saturate((rr - 0.82) / 0.36), 2.0);
        c *= 1.0 - vg * (1.0 - m);
    }
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
            float edge = mask * saturate((1.0 - hdrT.sample(smp, tuv, level(4.5)).a) * 2.2);
            float3 misted = film_agx(hdrT.sample(smp, suv, level(3.0)).rgb) * 0.92 + 0.03;
            o = mix(o, misted, saturate(edge * damp * 1.1 + mask * fog * 0.25));
        }
        o *= 1.0 - (0.30 - 0.15 * night) * rimDark;
        o += bead * (0.025 + 0.02 * (1.0 - night)) * float3(0.9, 0.95, 1.0);
        if (snow > 0.02) {
            float slush = saturate(rain / max(rain + snow, 1e-3));    // sleet: half slush
            float2 fl = film_flakes(tuv, img, t, saturate(snow * 1.5), slush) * mask;
            float lit = saturate(dsLuma(o) * 1.4 + 0.1);
            o = mix(o, float3(0.92, 0.94, 0.97) * lit, fl.x * (1.0 - 0.5 * fl.y));
        }
        // lightning: a faint cool flicker on the glass, on top of the sky layer's own spike
        o += flash * mask * 0.03 * float3(0.8, 0.88, 1.0);
    }
    return film_finish(dsToSrgb(o), in.pos.xy, res, u);
}

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    return film_layered(in, u, dsA0, dsA1, dsSmp);
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
