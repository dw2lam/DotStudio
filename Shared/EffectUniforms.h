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
} FXUniforms;

#endif /* EffectUniforms_h */
