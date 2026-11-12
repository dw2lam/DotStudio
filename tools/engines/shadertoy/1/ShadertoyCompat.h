//  ShadertoyCompat.h — the `shadertoy` engine, version 1: GLSL's types and built-ins in Metal.
//
//  A package's GLSL (`void mainImage(out vec4 fragColor, in vec2 fragCoord)`) is first rewritten
//  by DotStudio's translator (GLSLTranslator.swift) for what a header can't cover — out / inout
//  parameters, array and matrix constructors, struct constructors, `const` globals — then compiled
//  after this header, DotStudio.h (the `metal` engine) and before wrapper.metal.
//
//  Metal has no global variables, so Shadertoy's uniforms (iTime, iResolution, …) live in a
//  struct, DSShadertoy, that the translator passes to every function of the package as a hidden
//  first parameter `_st`; the macros below read it. DotStudio's own context (params, colours,
//  sun, weather, music) is there too: `dsCtx.p[0]`, `dsCtx.colorA`, `dsCtx.sun.elevation`, …

#ifndef DS_SHADERTOY_COMPAT_H
#define DS_SHADERTOY_COMPAT_H

// ================================================================================ types
typedef float2 vec2;     typedef float3 vec3;     typedef float4 vec4;
typedef int2 ivec2;      typedef int3 ivec3;      typedef int4 ivec4;
typedef uint2 uvec2;     typedef uint3 uvec3;     typedef uint4 uvec4;
typedef bool2 bvec2;     typedef bool3 bvec3;     typedef bool4 bvec4;
typedef float2x2 mat2;   typedef float3x3 mat3;   typedef float4x4 mat4;
typedef float2x2 mat2x2; typedef float2x3 mat2x3; typedef float2x4 mat2x4;
typedef float3x2 mat3x2; typedef float3x3 mat3x3; typedef float3x4 mat3x4;
typedef float4x2 mat4x2; typedef float4x3 mat4x3; typedef float4x4 mat4x4;

// ================================================================================ uniforms
struct DSShadertoy {
    float3    st_iResolution;      // viewport (px), z = 1
    float     st_iTime;            // seconds (DotStudio's scene time: wraps hourly behind a crossfade)
    float     st_iTimeDelta;
    int       st_iFrame;
    float     st_iFrameRate;
    float4    st_iMouse;           // always 0: a screensaver has no mouse
    float4    st_iDate;            // (year, month 0–11, day 1–31, seconds since midnight)
    float     st_iSampleRate;
    DSContext ctx;                 // DotStudio's context (DotStudio.h)
};
#define iResolution (_st.st_iResolution)
#define iTime       (_st.st_iTime)
#define iGlobalTime (_st.st_iTime)
#define iTimeDelta  (_st.st_iTimeDelta)
#define iFrame      (_st.st_iFrame)
#define iFrameRate  (_st.st_iFrameRate)
#define iMouse      (_st.st_iMouse)
#define iDate       (_st.st_iDate)
#define iSampleRate (_st.st_iSampleRate)
/// DotStudio's DSContext: dsCtx.p[0…15] (the manifest's params), dsCtx.colorA / colorB,
/// dsCtx.sun, dsCtx.weather, dsCtx.music, dsCtx.clock, dsCtx.seed.
#define dsCtx       (_st.ctx)

// ================================================================================ built-ins
/// GLSL's mod: x − y·floor(x / y) (Metal's fmod truncates instead: different for negatives).
template <typename T, typename U> static inline T mod(T x, U y) { return x - y * floor(x / y); }
/// GLSL's two-argument atan is atan2.
template <typename T> static inline T atan(T y, T x) { return atan2(y, x); }
static inline float atan(float y, int x) { return atan2(y, float(x)); }
static inline float atan(int y, float x) { return atan2(float(y), x); }
template <typename T> static inline T radians(T d) { return d * 0.017453292519943295; }
template <typename T> static inline T degrees(T r) { return r * 57.29577951308232; }
#define inversesqrt rsqrt
#define dFdx dfdx
#define dFdy dfdy
#define dFdxFine dfdx
#define dFdyFine dfdy
#define dFdxCoarse dfdx
#define dFdyCoarse dfdy
#define roundEven rint
#define discard discard_fragment()

template <typename T> static inline auto lessThan(T a, T b) { return a < b; }
template <typename T> static inline auto lessThanEqual(T a, T b) { return a <= b; }
template <typename T> static inline auto greaterThan(T a, T b) { return a > b; }
template <typename T> static inline auto greaterThanEqual(T a, T b) { return a >= b; }
template <typename T> static inline auto equal(T a, T b) { return a == b; }
template <typename T> static inline auto notEqual(T a, T b) { return a != b; }

static inline float2x2 matrixCompMult(float2x2 a, float2x2 b) { return float2x2(a[0] * b[0], a[1] * b[1]); }
static inline float3x3 matrixCompMult(float3x3 a, float3x3 b) { return float3x3(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }
static inline float4x4 matrixCompMult(float4x4 a, float4x4 b) {
    return float4x4(a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3]);
}
static inline float2x2 outerProduct(float2 c, float2 r) { return float2x2(c * r.x, c * r.y); }
static inline float3x3 outerProduct(float3 c, float3 r) { return float3x3(c * r.x, c * r.y, c * r.z); }
static inline float4x4 outerProduct(float4 c, float4 r) { return float4x4(c * r.x, c * r.y, c * r.z, c * r.w); }

static inline float2x2 inverse(float2x2 m) {
    float d = m[0][0] * m[1][1] - m[1][0] * m[0][1];
    return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0 / d);
}
static inline float3x3 inverse(float3x3 m) {
    float3 a = m[0], b = m[1], c = m[2];
    float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
    float d = dot(a, r0);
    return transpose(float3x3(r0, r1, r2)) * (1.0 / d);
}
static inline float4x4 inverse(float4x4 m) {
    float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];
    float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];
    float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];
    float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];
    float b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
    float b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
    float b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
    float b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    return float4x4(
        float4(a11 * b11 - a12 * b10 + a13 * b09, a02 * b10 - a01 * b11 - a03 * b09, a31 * b05 - a32 * b04 + a33 * b03, a22 * b04 - a21 * b05 - a23 * b03),
        float4(a12 * b08 - a10 * b11 - a13 * b07, a00 * b11 - a02 * b08 + a03 * b07, a32 * b02 - a30 * b05 - a33 * b01, a20 * b05 - a22 * b02 + a23 * b01),
        float4(a10 * b10 - a11 * b08 + a13 * b06, a01 * b08 - a00 * b10 - a03 * b06, a30 * b04 - a31 * b02 + a33 * b00, a21 * b02 - a20 * b04 - a23 * b00),
        float4(a11 * b07 - a10 * b09 - a12 * b06, a00 * b09 - a01 * b07 + a02 * b06, a31 * b01 - a30 * b03 - a32 * b00, a20 * b03 - a21 * b01 + a22 * b00)) * (1.0 / det);
}

static inline int floatBitsToInt(float v) { return as_type<int>(v); }
static inline int2 floatBitsToInt(float2 v) { return as_type<int2>(v); }
static inline int3 floatBitsToInt(float3 v) { return as_type<int3>(v); }
static inline int4 floatBitsToInt(float4 v) { return as_type<int4>(v); }
static inline uint floatBitsToUint(float v) { return as_type<uint>(v); }
static inline uint2 floatBitsToUint(float2 v) { return as_type<uint2>(v); }
static inline uint3 floatBitsToUint(float3 v) { return as_type<uint3>(v); }
static inline uint4 floatBitsToUint(float4 v) { return as_type<uint4>(v); }
static inline float intBitsToFloat(int v) { return as_type<float>(v); }
static inline float2 intBitsToFloat(int2 v) { return as_type<float2>(v); }
static inline float3 intBitsToFloat(int3 v) { return as_type<float3>(v); }
static inline float4 intBitsToFloat(int4 v) { return as_type<float4>(v); }
static inline float uintBitsToFloat(uint v) { return as_type<float>(v); }
static inline float2 uintBitsToFloat(uint2 v) { return as_type<float2>(v); }
static inline float3 uintBitsToFloat(uint3 v) { return as_type<float3>(v); }
static inline float4 uintBitsToFloat(uint4 v) { return as_type<float4>(v); }
#define bitCount popcount

// Single-argument vector constructors (the translator routes vecN(x) here): GLSL truncates a
// longer vector (vec3(v4) = v4.xyz) and splats a scalar; Metal's constructors only splat.
template <typename T> static inline float2 ds_vec2(T x) { return float2(x); }
static inline float2 ds_vec2(float3 v) { return v.xy; }
static inline float2 ds_vec2(float4 v) { return v.xy; }
static inline float2 ds_vec2(int3 v) { return float2(v.xy); }
static inline float2 ds_vec2(int4 v) { return float2(v.xy); }
template <typename T> static inline float3 ds_vec3(T x) { return float3(x); }
static inline float3 ds_vec3(float4 v) { return v.xyz; }
static inline float3 ds_vec3(int4 v) { return float3(v.xyz); }
template <typename T> static inline float4 ds_vec4(T x) { return float4(x); }

#endif
