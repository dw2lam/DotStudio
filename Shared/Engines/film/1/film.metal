//  film.metal — the `film` engine's fragment function: the clip showing (dsA0), aspect-filled,
//  crossfading from the one before it (dsA1) in linear light. CustomFilm.swift picks the clips.
//    u.scene[0] = (clip A width, height, clip B width, height)   u.scene[1].x = mix (0 = all A)

static inline float3 film_cover(texture2d<float> t, sampler s, float2 uv, float2 res, float2 size) {
    float outA = res.x / max(res.y, 1.0);
    float srcA = size.x / max(size.y, 1.0);
    float2 scale = (srcA > outA) ? float2(outA / srcA, 1.0) : float2(1.0, srcA / outA);
    return t.sample(s, (uv - 0.5) * scale + 0.5).rgb;
}

fragment float4 ds_fragment(DS_FRAGMENT_PARAMS) {
    float2 res = max(u.resolution, float2(1.0));
    float3 a = film_cover(dsA0, dsSmp, in.uv, res, max(u.scene[0].xy, float2(1.0)));
    float k = saturate(u.scene[1].x);
    if (k > 0.0) {
        float3 b = film_cover(dsA1, dsSmp, in.uv, res, max(u.scene[0].zw, float2(1.0)));
        a = dsToSrgb(mix(dsToLinear(a), dsToLinear(b), k));
    }
    return ds_finish(a, in.pos.xy);
}
