//  film.metal — the `film` engine's fragment function: the clip showing (dsA0), aspect-filled,
//  crossfading from the one before it (dsA1) in linear light, then a live film grain (and an
//  optional halation for clips that weren't graded). CustomFilm.swift picks the clips.
//    u.scene[0] = (clip A width, height, clip B width, height)
//    u.scene[1] = (mix 0 = all A, the clip's frame rate, 0, 0)
//    u.scene[8] = (Grain 0…1, Halation 0…1, 0, 0)   — the engine's params (engine.json)

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

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    float2 res = max(u.resolution, float2(1.0));
    float2 sizeA = max(u.scene[0].xy, float2(1.0));
    float3 a = film_cover(dsA0, dsSmp, in.uv, res, sizeA);
    float k = saturate(u.scene[1].x);
    if (k > 0.0) {
        float3 b = film_cover(dsA1, dsSmp, in.uv, res, max(u.scene[0].zw, float2(1.0)));
        a = dsToSrgb(mix(dsToLinear(a), dsToLinear(b), k));
    }
    float grain = saturate(u.scene[8].x), halation = saturate(u.scene[8].y);

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

    // Grain: fine, luminance-weighted (strongest in the mids, gentle in shadows and highlights),
    // stepped at the clip's frame rate; its size is in points (≈ 1.4 pt at any resolution).
    if (grain > 0.0) {
        float fps = u.scene[1].y > 1.0 ? u.scene[1].y : 24.0;
        uint frame = uint(max(floor(u.time * fps), 0.0));
        float cell = max(res.y / 1100.0 * 1.4, 1.0);
        float l = dsLuma(a);
        float w = 0.25 + 0.75 * saturate(4.0 * l * (1.0 - l));
        a += film_grain(in.pos.xy, cell, frame) * grain * 0.16 * w;
        // (the grain dithers already: ds_finish's own dither would only cost a sin a pixel)
        uint3 e = as_type<uint3>(a) & 0x7f800000u;
        return float4(any(e == 0x7f800000u) ? float3(0.0) : saturate(a), 1.0);
    }
    return ds_finish(a, in.pos.xy);
}
