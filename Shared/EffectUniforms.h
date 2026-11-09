//  EffectUniforms.h
//  Shared struct between Swift and Metal. The same file is included by the
//  .metal shader (via __METAL_VERSION__) and exposed to Swift via the bridging
//  header, so the memory layout is guaranteed identical on both sides.

#ifndef EffectUniforms_h
#define EffectUniforms_h

#ifdef __METAL_VERSION__
    #define FX_FLOAT2 float2
    #define FX_FLOAT4 float4
    #define FX_INT    int
#else
    #include <simd/simd.h>
    #define FX_FLOAT2 simd_float2
    #define FX_FLOAT4 simd_float4
    #define FX_INT    int
#endif

typedef struct {
    FX_FLOAT2 resolution;   // output size in pixels
    float     time;         // seconds since start
    FX_INT    effect;       // shader effect id (see EffectKind.shaderID)

    FX_FLOAT4 p0;           // generic params, meaning is per-effect
    FX_FLOAT4 p1;
    FX_FLOAT4 p2;

    FX_FLOAT4 colorA;       // primary / background / dark
    FX_FLOAT4 colorB;       // secondary / ink / light

    FX_FLOAT2 srcSize;      // source texture size in pixels (for cover-fit)
    FX_INT    fillMode;     // 0 = fit, 1 = cover, 2 = stretch
    FX_INT    glyphCount;   // number of glyphs in the ascii atlas

    FX_FLOAT4 clock;        // local wall time: (hour 0–24 with fraction, minute 0–60 with fraction,
                            //                   second 0–60 with fraction, weekday 1=Sun…7)
    FX_FLOAT4 date;         // (year, month 1–12, day 1–31, day of year 1–366)

    // Live sky for Ocean Horizon's "Follow the Sun" mode (filled per frame by MetalRenderer
    // .liveSky; zero otherwise). Angles in radians, apparent (refracted) elevations.
    FX_FLOAT4 sun;          // (elevation, hour angle −π…π (0 = solar noon), rise→set half-arc 0…π, latitude)
    FX_FLOAT4 moon;         // (elevation, hour angle, rise→set half-arc, elongation 0…2π: < π waxing)
    FX_FLOAT4 sky;          // (local sidereal time, 1 = live values present, 0, 0)

    // Now Playing (scene 66; filled per frame by MetalRenderer.fillMusic, zero otherwise).
    // The artwork itself is texture slot 7 (musicArt, mipmapped), the previous track's
    // artwork slot 8 (musicArtPrev) while they cross-fade.
    FX_FLOAT4 musicPal0;    // artwork palette, display sRGB, brightest first; .a = 1 when present
    FX_FLOAT4 musicPal1;
    FX_FLOAT4 musicPal2;
    FX_FLOAT4 music;        // (has artwork 0/1, progress 0–1 or −1 = unknown, playing 0/1,
                            //  seconds since the artwork changed — cross-fade clock)
    FX_FLOAT4 musicRect;    // where the foreground draws the artwork, in uv (x, y from the top, w, h)
} FXUniforms;

#endif /* EffectUniforms_h */
