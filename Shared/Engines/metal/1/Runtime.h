//  Runtime.h — the `metal` engine's glue (not part of the API: see DotStudio.h). Builds the
//  DSContext from the renderer's uniforms. Layout (CustomSceneLink.fill, CustomScenes.swift):
//    u.scene[0…3]  p[0…15]                 u.scene[4]  sun (elevation°, azimuth°, isDay, live)
//    u.scene[5]    weather (cloud, rain, snow, fog)
//    u.scene[6]    (wind 0…1, seed 0…1, step fps (0 = smooth), 0)
//    u.scene[7]    music (playing, level, 0, 0)       u.scene[8]  the engine's own params
//    u.musicPal0…2 the album art's palette (.a = 1 when present)

#ifndef DOTSTUDIO_RUNTIME_H
#define DOTSTUDIO_RUNTIME_H

static inline DSContext ds_context(constant FXUniforms& u, texture2d<float> a0, texture2d<float> a1,
                                   texture2d<float> a2, texture2d<float> a3, sampler smp) {
    DSContext c;
    c.res = max(u.resolution, float2(1.0));
    c.aspect = c.res.x / c.res.y;
    float fps = u.scene[6].z;
    c.t = fps > 0.5 ? floor(u.time * fps) / fps : u.time;
    // Whole hours and minutes are exact (MetalRenderer.wallClock keeps their floor() exact); the
    // seconds stop 50 ms short of the next minute, so floor(clock / 60) and floor(clock / 3600)
    // are the minute and hour on screen at every instant, fast math and all (not clock.x · 3600,
    // which read hh:mm:00 as the minute before).
    c.clock = clamp(floor(u.clock.x), 0.0, 23.0) * 3600.0 + clamp(floor(u.clock.y), 0.0, 59.0) * 60.0
            + clamp(u.clock.z, 0.0, 59.95);
    c.date.year = int(u.date.x); c.date.month = int(u.date.y); c.date.day = int(u.date.z);
    c.date.weekday = int(u.clock.w);
    c.sun.elevation = u.scene[4].x; c.sun.azimuth = u.scene[4].y; c.sun.isDay = u.scene[4].z > 0.5;
    c.weather.cloud = saturate(u.scene[5].x); c.weather.rain = saturate(u.scene[5].y);
    c.weather.snow = saturate(u.scene[5].z); c.weather.fog = saturate(u.scene[5].w);
    c.weather.wind = saturate(u.scene[6].x);
    c.music.playing = u.scene[7].x > 0.5; c.music.level = saturate(u.scene[7].y);
    float3 grey = float3(0.5);
    c.music.a = u.musicPal0.a > 0.5 ? u.musicPal0.rgb : grey;
    c.music.b = u.musicPal1.a > 0.5 ? u.musicPal1.rgb : grey * 0.7;
    c.music.c = u.musicPal2.a > 0.5 ? u.musicPal2.rgb : grey * 0.4;
    for (int i = 0; i < 16; i++) c.p[i] = u.scene[i / 4][i % 4];
    c.colorA = saturate(u.colorA.rgb); c.colorB = saturate(u.colorB.rgb);
    c.seed = u.scene[6].y;
    c.asset0 = a0; c.asset1 = a1; c.asset2 = a2; c.asset3 = a3; c.smp = smp;
    return c;
}

/// The finished pixel: finite, dithered below one 8-bit step, clamped.
static inline float4 ds_finish(float3 rgb, float2 px) {
    // (by the bits: fast math may fold isfinite() to true)
    uint3 e = as_type<uint3>(rgb) & 0x7f800000u;
    if (any(e == 0x7f800000u)) rgb = float3(0.0);
    float n = fract(sin(dot(px, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    return float4(saturate(rgb + n / 255.0), 1.0);
}

#define DS_FRAGMENT_PARAMS                                                           \
    DSVOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]],                     \
    texture2d<float> dsA0 [[texture(9)]], texture2d<float> dsA1 [[texture(10)]],     \
    texture2d<float> dsA2 [[texture(11)]], texture2d<float> dsA3 [[texture(12)]],    \
    sampler dsSmp [[sampler(0)]]

#endif
