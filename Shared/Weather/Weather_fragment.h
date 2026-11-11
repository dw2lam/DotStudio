//  Weather_fragment.h — Ocean Horizon (59) and Shallows (67) as fragment functions of their own,
//  compiled in their own unit (Weather.metal, after Shaders.metal's helpers and scene code): the
//  weather copies, and the scenes' own clear skies.
//
//  Why separate entry points: the über-shader fx_fragment is allocated registers for its heaviest
//  path, so putting the weather copies anywhere inside it — even behind a uniform branch, even
//  out of line — doubled the cost of the scenes' own clear skies (Golden Hour 8.8 → 17.8 ms at
//  5120×2880). The same holds the other way round: inside fx_fragment the clear skies pay for the
//  heaviest of every other scene's registers (Golden Hour 9.0 ms there, ~4.7 ms in a function of
//  its own). And within one function, two copies (Follow the Sun's live sky and the fixed one) pay
//  for each other's: one copy per entry point halved the weather (Tidewater in fog 14.4 → 6.5 ms).
//  So every combination is a function: clear or weather, fixed or live, with or without cumulus.
//  WeatherLink (Shared/Weather/WeatherFeed.swift: functionName) binds the one a pass needs in
//  place of fx_fragment; fx_fragment's own cases 59 and 67 stay as the fallback (a pipeline that
//  failed to build) and draw the same frames (±1 level on a few pixels: compiled apart).

// The scenes' clear skies (u.weather2.w is 0: the weather is the scene's own).
fragment float4 fx_ocean(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, false);
}
fragment float4 fx_ocean_live(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, true);
}
fragment float4 fx_shallows(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return studio1_shallows(uv, res, px, u.time, u);
}

// Weather (u.weather2.w is 1).
fragment float4 fx_wx_ocean(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, false, true);
}
fragment float4 fx_wx_ocean_live(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, true, true);
}

// Partly cloudy: the same, with the fair-weather cumulus (nature_wxCumulus) and their shadows on
// the sea. A copy of its own for the same reason: the heaps' registers would otherwise be
// allocated to every weather (overcast, rain, snow and storm each lost ~1.5 ms at 5K with the
// cumulus compiled in, idle). WeatherLink binds it while the cover is in the cumulus' range
// (WeatherLink.cumulus), where its heaps are > 0; at either end of it they fade to nothing, so
// the hand-over between the two copies is seamless.
fragment float4 fx_wx_ocean_cu(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, false, true, true);
}
fragment float4 fx_wx_ocean_cu_live(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return nature_ocean(uv, res, px, u.time, u, true, true, true);
}

// Meadow (78): its clear sky and its weather, each a function of its own for the same reasons — and
// one per landscape (the Landscape menu: fx_meadow_<n>, fx_wx_meadow_<n>), so each carries only its
// own land's code and registers.
#define MEADOW_FX(N) \
fragment float4 fx_meadow_##N(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) { \
    float2 uv = in.uv, res = u.resolution, px = uv * res; \
    return meadow_scene(uv, res, px, u.time, u, false, N); \
} \
fragment float4 fx_wx_meadow_##N(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) { \
    float2 uv = in.uv, res = u.resolution, px = uv * res; \
    return meadow_scene(uv, res, px, u.time, u, true, N); \
}
MEADOW_FX(0)
MEADOW_FX(1)
MEADOW_FX(2)
MEADOW_FX(3)
#undef MEADOW_FX

fragment float4 fx_wx_shallows(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv, res = u.resolution, px = uv * res;
    return studio1_shallows(uv, res, px, u.time, u, true);
}
