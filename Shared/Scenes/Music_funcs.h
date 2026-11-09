//  Music_funcs.h — helpers for the Now Playing scene (66). See Shared/Scenes/Music.swift.
//  The scene draws only the background; MusicOverlayLayer draws the foreground at native
//  resolution. The artwork arrives mipmapped in slot 7 (musicArt), the previous track's in
//  slot 8 (musicArtPrev) while they cross-fade.

// Mirror-repeat: drifting, rotated copies of the artwork never show an edge.
static inline float2 musicMirror(float2 u) {
    float2 f = fract(u * 0.5) * 2.0;
    return 1.0 - abs(f - 1.0);
}

static inline float2 musicRot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// The mip level whose long edge is closest to `px` texels (a 1400 px cover → level 6 for 22).
static inline uint musicLod(texture2d<float> tex, float px) {
    float w = float(max(tex.get_width(0), tex.get_height(0)));
    float l = round(log2(max(w, 1.0) / max(px, 1.0)));
    return uint(clamp(l, 0.0, float(tex.get_num_mip_levels()) - 1.0));
}

// B-spline bicubic sample at one mip level from 4 bilinear taps: C2-smooth, so a 20-texel
// mip stretched across a 5K screen shows no bilinear creases or diamonds.
static inline float3 musicBicubic(texture2d<float> tex, sampler s, float2 uv, uint lod) {
    float2 ts = float2(max(tex.get_width(lod), 1u), max(tex.get_height(lod), 1u));
    float2 p = uv * ts - 0.5;
    float2 f = fract(p);
    p -= f;
    float4 nx = float4(1.0, 2.0, 3.0, 4.0) - f.x;
    float4 ny = float4(1.0, 2.0, 3.0, 4.0) - f.y;
    nx = nx * nx * nx; ny = ny * ny * ny;
    float4 wx = float4(nx.x, nx.y - 4.0 * nx.x, nx.z - 4.0 * nx.y + 6.0 * nx.x, 0.0);
    float4 wy = float4(ny.x, ny.y - 4.0 * ny.x, ny.z - 4.0 * ny.y + 6.0 * ny.x, 0.0);
    wx.w = 6.0 - wx.x - wx.y - wx.z;
    wy.w = 6.0 - wy.x - wy.y - wy.z;
    float4 c = float4(p.x - 0.5, p.x + 1.5, p.y - 0.5, p.y + 1.5);
    float4 sm = float4(wx.x + wx.y, wx.z + wx.w, wy.x + wy.y, wy.z + wy.w);
    float4 o = (c + float4(wx.y, wx.w, wy.y, wy.w) / sm) / float4(ts.x, ts.x, ts.y, ts.y);
    float lv = float(lod);
    float3 s0 = tex.sample(s, o.xz, level(lv)).rgb;
    float3 s1 = tex.sample(s, o.yz, level(lv)).rgb;
    float3 s2 = tex.sample(s, o.xw, level(lv)).rgb;
    float3 s3 = tex.sample(s, o.yw, level(lv)).rgb;
    float sx = sm.x / (sm.x + sm.y), sy = sm.z / (sm.z + sm.w);
    return mix(mix(s3, s2, sx), mix(s1, s0, sx), sy);
}

// Grade for legible white type: saturate in Oklab, then compress lightness into [lo, hi]
// (Oklab L; 0.52 ≈ sRGB 0.42 — white text keeps ≥ 5:1 everywhere), nudged toward `tint`.
static inline float3 musicGrade(float3 c, float sat, float lo, float hi, float3 tint, float tintAmt) {
    float3 lab = srgbToOklab(c);
    float3 tl = srgbToOklab(tint);
    lab.yz = mix(lab.yz * sat, tl.yz * max(sat, 1.0), tintAmt);
    // Near-neutral colour (white or grey covers) tops out lower: a pale grey field reads as
    // dull haze, a deeper graphite as intentional.
    float chroma = length(lab.yz);
    float top = mix(lo + (hi - lo) * 0.62, hi, smoothstep(0.015, 0.10, chroma));
    lab.x = lo + (top - lo) * smoothstep(0.0, 1.0, pow(clamp(lab.x, 0.0, 1.0), 0.9));
    return oklabToSrgb(lab);
}

// The slow domain warp under Living Art, in aspect-correct screen space (y = 1 tall):
// layered sines, so the colour fields flow rather than slide. Cheap (no noise hashing) and
// computed once per pixel even while two tracks cross-fade.
static inline float2 musicWarp(float2 p, float tm) {
    float2 w;
    w.x = sin(p.y * 1.9 + tm * 0.023) + 0.6 * sin(p.x * 2.7 - p.y * 1.3 + tm * 0.017 + 1.7);
    w.y = sin(p.x * 1.7 - tm * 0.019 + 0.8) + 0.6 * sin(p.y * 2.9 + p.x * 1.1 - tm * 0.021 + 2.9);
    return p + w * 0.16;
}

// "Living Art": the artwork as huge, slowly turning colour fields — a base copy plus two
// zoomed-in copies inside drifting soft blobs, sampled through the warped point `p`.
static inline float3 musicLivingArt(texture2d<float> art, sampler s, float2 p, float asp, float tm) {
    uint lod = musicLod(art, 22.0);
    // The blob copies are zoomed further in, so a coarser mip keeps them as soft as the base
    // (a sharp one turns a cover's sun or logo into a recognisable shape).
    uint lodZoom = musicLod(art, 15.0);
    float3 col = musicBicubic(art, s, musicMirror(musicRot(p, tm * 0.015) * 0.52 + 0.5), lod);
    for (int i = 1; i < 3; ++i) {
        float fi = float(i);
        float2 c = float2(sin(tm * (0.010 + 0.004 * fi) + fi * 1.9) * 0.42 * asp,
                          cos(tm * (0.008 + 0.003 * fi) + fi * 2.7) * 0.30);
        float r = 0.50 + 0.12 * fi;
        float m = smoothstep(r, r * 0.10, length(p - c));
        if (m <= 0.0) continue;                          // outside the blob: skip its 4 taps
        float dir = (i == 1) ? -1.0 : 1.0;
        float2 q = musicRot(p - c, dir * tm * (0.020 + 0.006 * fi) + fi * 2.1) * (0.40 - 0.05 * fi)
                 + 0.5 + float2(0.18, -0.14) * fi;
        float3 layer = musicBicubic(art, s, musicMirror(q), lodZoom);
        col = mix(col, layer, m * (0.92 - 0.12 * fi));
    }
    return col;
}

// Cover-fit artwork (aspect-correct, centred), zoomed by `zoom` and shifted by `pan`.
static inline float3 musicCoverArt(texture2d<float> art, sampler s, float2 uv, float asp,
                                   float zoom, float2 pan, uint lod) {
    float2 sz = float2(max(art.get_width(0), 1u), max(art.get_height(0), 1u));
    float srcA = sz.x / sz.y;
    float2 sc = (srcA > asp) ? float2(asp / srcA, 1.0) : float2(1.0, srcA / asp);
    float2 q = (uv - 0.5) * sc / zoom + 0.5 + pan;
    return musicBicubic(art, s, musicMirror(q), lod);
}

// Nothing playing (or no artwork): two calm, slowly drifting glows over a deep ground.
static inline float3 musicIdle(float2 uv, float asp, float tm, float3 deep, float3 c1, float3 c2) {
    float2 p = (uv - 0.5) * float2(asp, 1.0);
    float2 b1 = float2(-0.30 * asp + 0.10 * sin(tm * 0.031), -0.16 + 0.09 * cos(tm * 0.027));
    float2 b2 = float2(0.28 * asp + 0.09 * cos(tm * 0.023), 0.20 + 0.08 * sin(tm * 0.029));
    float g1 = exp(-dot(p - b1, p - b1) / 0.20);
    float g2 = exp(-dot(p - b2, p - b2) / 0.28);
    float3 col = srgbToLinear(deep) + srgbToLinear(c1) * g1 * 0.45 + srgbToLinear(c2) * g2 * 0.30;
    return linearToSrgb(col);
}

// One complete background for one artwork state (`has` = this slot holds artwork).
// layout 0 Album / 1 Stage / 2 Cover; bg 0 Living Art / 1 Blur / 2 Dark. `wp` = musicWarp
// of the aspect-correct point (shared by both backgrounds while they cross-fade).
static inline float3 musicBackground(texture2d<float> art, bool has, sampler s, float2 uv, float2 wp,
                                     float2 res, float tm, int layout, int bg, float4 rect,
                                     float3 vivid, float3 mean, float3 deep, float3 idleA, float3 idleB) {
    float asp = res.x / res.y;
    float3 col;
    if (!has) {
        // No artwork: the palette when there is one, else the scene's idle colours.
        col = musicIdle(uv, asp, tm, mix(idleA, deep * 0.35, 0.5), vivid, mean);
        return musicGrade(col, 1.0, 0.10, 0.40, vivid, 0.0);
    }
    if (layout == 2) {
        // COVER: the artwork itself fills the screen, drifting like a slow Ken Burns.
        float zoom = 1.08 + 0.04 * sin(tm * 0.019);
        float2 pan = float2(sin(tm * 0.013), cos(tm * 0.011)) * 0.012;
        float sharp = log2(float(max(art.get_width(0), art.get_height(0))) / max(res.x, res.y));
        uint lod = uint(clamp(round(sharp + (bg == 1 ? 4.0 : 1.0)), 0.0, float(art.get_num_mip_levels()) - 1.0));
        // Scrim for the type at the bottom left: a band along the bottom plus a deeper pool in
        // the corner (white type keeps ≈ 4.5:1 over bright sand or sky), gone by mid-screen.
        float up = 1.0 - uv.y;                                   // 0 at the bottom
        float band = 1.0 - smoothstep(0.0, 0.66, up);
        float pool = 1.0 - smoothstep(0.0, 1.05, length(float2(uv.x * asp * 0.7, up * 1.1)));
        col = musicCoverArt(art, s, uv, asp, zoom, pan, lod);
        // Progressive blur under the type, so lettering in the artwork never fights the title.
        float soft = smoothstep(0.10, 0.75, max(pool, band * 0.85));
        if (soft > 0.01) {
            uint lodSoft = min(lod + 3u, art.get_num_mip_levels() - 1u);
            col = mix(col, musicCoverArt(art, s, uv, asp, zoom, pan, lodSoft), soft);
        }
        if (bg == 1) col = musicGrade(col, 1.15, 0.16, 0.55, vivid, 0.0);
        if (bg == 2) col *= 0.48;
        float3 lin = srgbToLinear(col) * (1.0 - 0.64 * band) * (1.0 - 0.82 * pool) * 0.92;
        return linearToSrgb(lin);
    }
    float2 p = (uv - 0.5) * float2(asp, 1.0);
    if (bg == 0) {
        col = musicLivingArt(art, s, wp, asp, tm);
        col = musicGrade(col, 1.35, 0.17, 0.53, vivid, 0.10);
    } else if (bg == 1) {
        float zoom = 1.18 + 0.03 * sin(tm * 0.021);
        float2 pan = float2(sin(tm * 0.011), cos(tm * 0.009)) * 0.02;
        // ~16 texels across: colour and light only — lettering and faces never read through.
        col = musicCoverArt(art, s, uv, asp, zoom, pan, musicLod(art, 16.0));
        col = musicGrade(col, 1.20, 0.14, 0.48, vivid, 0.06);
    } else {
        // DARK: near-black ground with the artwork's colour glowing softly behind it.
        float2 c = (rect.xy + rect.zw * 0.5 - 0.5) * float2(asp, 1.0);
        float r = rect.w * 0.95;
        float d2 = dot(p - c, p - c) / (r * r);
        float breathe = 1.0 + 0.08 * sin(tm * 0.11);
        float3 lin = srgbToLinear(mix(float3(0.028, 0.028, 0.034), deep, 0.18))
                   + srgbToLinear(vivid) * exp(-d2 * 1.4) * 0.16 * breathe
                   + srgbToLinear(mean) * exp(-d2 * 0.35) * 0.045;
        col = linearToSrgb(lin);
    }
    // Vignette: holds the eye in the middle and deepens the corners behind the menu bar.
    float v = smoothstep(0.35, 1.30, length(p * float2(0.85, 1.0)));
    col *= 1.0 - 0.32 * v;
    return col;
}
