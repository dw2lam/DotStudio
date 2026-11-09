//  Weather_fragment.h — the weather copies of Ocean Horizon (59) and Shallows (67) as fragment
//  functions of their own, compiled in their own unit (Weather.metal, after Shaders.metal's
//  helpers and scene code).
//
//  Why separate entry points: the über-shader fx_fragment is allocated registers for its heaviest
//  path, so putting the weather copies anywhere inside it — even behind a uniform branch, even
//  out of line — doubled the cost of the scenes' own clear skies (Golden Hour 8.8 → 17.8 ms at
//  5120×2880). WeatherLink (Shared/Weather/WeatherFeed.swift) binds these pipelines for a pass
//  whose u.weather2.w is 1; every other pass keeps fx_fragment, so clear weather draws exactly the
//  scene it always was, at its old cost.

fragment float4 fx_wx_ocean(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    if (nature_live(u)) return nature_ocean(uv, res, px, u.time, u, true, true);
    return nature_ocean(uv, res, px, u.time, u, false, true);
}

fragment float4 fx_wx_shallows(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return studio1_shallows(uv, res, px, u.time, u, true);
}
