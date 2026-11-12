//  FXFragment_body.h — the body of the fragment function that draws an effect or scene by id:
//  the image/gradient sources, then one switch over every effect and scene (the scene packs'
//  cases: Scenes/*_cases.h). Included by Shaders.metal only:
//    • fx_fragment, the über-shader, with FX_EFFECT = u.effect: draws any id;
//    • fx_scene_<id> (FX_SCENE_ENTRY below; the list: SceneEntries.metal), with FX_EFFECT the
//      literal id: the switch folds to that one case, so the function is compiled for that
//      scene's code alone — its registers and occupancy sized for it, not for the heaviest
//      case of the über-shader (ScenePipelines.swift: which scenes get one, and why).
//  The parameters (FX_FRAGMENT_PARAMS) are fx_fragment's, so a renderer only swaps pipelines.
//  Nothing here may depend on FX_EFFECT being a runtime value.

    float2 uv  = in.uv;
    float2 res = u.resolution;
    float2 px  = uv * res;                 // pixel coords
    float  t   = u.time;

    // -------- source generators ----------------------------------------
    if (FX_EFFECT == 0) {                   // image / video source with fill mode
        int mode = u.fillMode;
        if (mode == 3) {                   // SLIDESHOW — Ken Burns-framed photo A (src)
                                           // cross-fading into photo B (fadePrev slot)
            float outA = res.x / res.y;
            float3 a = kenBurnsSample(src, samp, uv, outA, u.srcSize, u.p0);
            if (u.p0.w <= 0.0) return float4(a, 1.0);
            float3 b = kenBurnsSample(fadePrev, samp, uv, outA, u.p2.xy, u.p1);
            float3 m = mix(srgbToLinear(a), srgbToLinear(b), u.p0.w);   // linear-light dissolve
            return float4(linearToSrgb(m), 1.0);
        }
        if (mode == 2 || u.srcSize.x < 1.0 || u.srcSize.y < 1.0) {
            return src.sample(samp, uv);   // stretch (or unknown size)
        }
        float outA = res.x / res.y;
        float srcA = u.srcSize.x / u.srcSize.y;
        if (mode == 1) {                   // COVER — fill the screen, crop overflow
            float2 scale = (srcA > outA) ? float2(outA / srcA, 1.0)
                                         : float2(1.0, srcA / outA);
            return src.sample(samp, (uv - 0.5) * scale + 0.5);
        } else {                           // FIT — contain whole image, letterbox bars
            float2 scale = (srcA > outA) ? float2(1.0, outA / srcA)
                                         : float2(srcA / outA, 1.0);
            float2 suv = (uv - 0.5) / scale + 0.5;
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
            return src.sample(samp, suv);
        }
    }
    if (FX_EFFECT == 1) {                   // gradient generator
        float ang = u.p0.x;
        float2 dir = float2(cos(ang), sin(ang));
        float g = dot(uv - 0.5, dir) + 0.5;
        // subtle animated drift
        g += 0.04 * sin(uv.x * 6.2831 + t * 0.4) * u.p0.y;
        return mix(u.colorA, u.colorB, clamp(g, 0.0, 1.0));
    }

    // For all other effects, the input is the previous pass (fills screen 1:1).
    float4 base = src.sample(samp, uv);
    float  L    = luma(base.rgb);

    switch (FX_EFFECT) {

    case 2: {   // PIXELATE
        float cell = max(u.p0.x, 1.0);
        float2 quv = (floor(px / cell) + 0.5) * cell / res;
        return src.sample(samp, quv);
    }

    case 3: {   // DITHER — ordered (Bayer 2/4/8) or blue noise. Error-diffusion
                // and Riemersma are handled by the serial compute kernel + blit (effect 38).
        float cell = max(u.p0.x, 1.0);                 // pixel size
        float levels = max(u.p0.y, 2.0);
        bool mono = u.p0.z > 0.5;
        int method = int(u.p0.w + 0.5);
        int2 cellPx = int2(floor(px / cell));
        float2 quv = (float2(cellPx) + 0.5) * cell / res;
        float3 c = src.sample(samp, quv).rgb;
        float thr = (method == 3) ? ign(float2(cellPx)) : ditherThreshold(method, cellPx);
        if (mono) {
            float v = luma(c) + thr / (levels - 1.0);
            float q = floor(v * (levels - 1.0) + 0.5) / (levels - 1.0);
            return mix(u.colorA, u.colorB, clamp(q, 0.0, 1.0));
        } else {
            float3 v = c + thr / (levels - 1.0);
            float3 q = floor(v * (levels - 1.0) + 0.5) / (levels - 1.0);
            return float4(clamp(q, 0.0, 1.0), 1.0);
        }
    }

    case 4: {   // HALFTONE
        float cell = max(u.p0.x, 2.0);
        float ang  = u.p0.y;
        float2x2 R = float2x2(cos(ang), -sin(ang), sin(ang), cos(ang));
        float2 rp = R * px;
        float2 g = (floor(rp / cell) + 0.5) * cell;
        float2 cellCenterUV = (transpose(R) * g) / res;
        float lv = luma(src.sample(samp, cellCenterUV).rgb);
        float2 local = (rp - g) / cell;                // [-0.5,0.5]
        float d = length(local) * 2.0;                 // 0 center .. ~1.4
        float r = sqrt(1.0 - lv);                      // darker => bigger dot
        float dot_ = smoothstep(r + 0.05, r - 0.05, d);
        return mix(u.colorA, u.colorB, dot_);
    }

    case 5: {   // DOTS (round dot grid, brightness = dot fill)
        float cell = max(u.p0.x, 2.0);
        float2 g = (floor(px / cell) + 0.5) * cell;
        float lv = luma(src.sample(samp, g / res).rgb);
        float d = length(px - g) / (cell * 0.5);
        float r = mix(0.05, 1.0, pow(lv, 0.7));
        float dot_ = smoothstep(r, r - 0.12, d);
        return mix(u.colorA, mix(u.colorB, base, u.p0.z), dot_);
    }

    case 6: {   // THRESHOLD
        float thr = u.p0.x;
        float soft = max(u.p0.y, 0.001);
        float m = smoothstep(thr - soft, thr + soft, L);
        return mix(u.colorA, u.colorB, m);
    }

    case 7: {   // POSTERIZE
        float n = max(u.p0.x, 2.0);
        float3 q = floor(base.rgb * n) / (n - 1.0);
        return float4(clamp(q, 0.0, 1.0), base.a);
    }

    case 8: {   // PHOSPHOR — a single-colour CRT (amber, green…), in linear light: the beam
                // excites the phosphor's own colour, the brightest areas saturate toward a hot
                // near-white core, and black is the tube's faintly lit glass, not #000.
        float amt = u.p0.x;
        float gain = u.p0.y;
        float I = pow(max(L * gain, 0.0), 1.98);          // the old sRGB-space response, in linear
        float3 ph = srgbToLinear(u.colorB.rgb);
        float3 lin = ph * I + (1.0 - ph) * (max(I - 0.8, 0.0) * max(I - 0.8, 0.0)) * 0.05 + ph * 0.006 + 0.0015;
        return float4(mix(base.rgb, linearToSrgb(lin), amt), 1.0);
    }

    case 9: {   // NOISE FIELD (animated domain warp + grain)
        float warp = u.p0.x;
        float scale = max(u.p0.y, 1.0);
        float grain = u.p0.z;
        float2 q = uv * scale;
        float2 flow = float2(vnoise(q + t * 0.15), vnoise(q + 7.3 - t * 0.12)) - 0.5;
        float3 c = src.sample(samp, uv + flow * warp).rgb;
        float n = pcg3(float3(px, floor(t * 60.0))).x;   // integer hash: exact at any t
        c += (n - 0.5) * grain;
        return float4(c, 1.0);
    }

    case 10: { // SCANLINES / CRT — the picture as beam lines: a fixed count per screen height
               // (spacing 3 ≈ 280 lines), each line sampled at its centre and drawn as a Gaussian
               // spot that widens with brightness (bright lines bloom into the gaps, dark ones
               // thin out), in linear light so the average brightness holds. The profile is
               // filtered by the pixel footprint: thumbnails fade to a flat image, never moiré.
               // A faint aperture grille, also footprint-filtered.
        float k = res.y / 1000.0;
        float P = max(u.p0.x * 1.2 * k, 0.5);            // line pitch, px
        float inten = u.p0.y;
        float tl = px.y / P - 0.5;                        // in lines; line i's centre at i
        float i0 = floor(tl), fr = tl - i0;
        float3 a = srgbToLinear(src.sample(samp, float2(uv.x, (i0 + 0.5) * P / res.y)).rgb);
        float3 b = srgbToLinear(src.sample(samp, float2(uv.x, (i0 + 1.5) * P / res.y)).rgb);
        float fp2 = 1.0 / (12.0 * P * P);                 // pixel footprint variance, in lines²
        float3 sa = mix(0.16, 0.31, sqrt(saturate(a))), sb = mix(0.16, 0.31, sqrt(saturate(b)));
        float3 va = sa * sa + fp2, vb = sb * sb + fp2;
        // Each spot integrates to its line's brightness (amplitude 1 / (σ√2π)).
        float3 beam = a * exp(-fr * fr / (2.0 * va)) * rsqrt(6.2831853 * va)
                    + b * exp(-(1.0 - fr) * (1.0 - fr) / (2.0 * vb)) * rsqrt(6.2831853 * vb);
        // The tube is dimmer than the signal: as dim on average as the old sRGB-multiply
        // scanlines with their RGB mask (×(1 − inten/2)·0.85 in sRGB), so saved presets keep
        // their exposure.
        float fs = (1.0 - 0.5 * inten) * mix(1.0, 0.85, saturate(inten * 4.0));
        float3 lin = mix(srgbToLinear(base.rgb), beam, inten) * pow(fs, 1.75);
        // Aperture grille: vertical stripes at 2/3 of the line pitch, faded out once a
        // stripe is under ~2.5 px.
        float gp = P * 0.667;
        float g = 0.5 + 0.5 * cos(px.x / gp * 6.2831853);
        lin *= 1.0 - 0.10 * inten * smoothstep(2.0, 3.5, gp) * (1.0 - g);
        return float4(linearToSrgb(lin) + bandDither(px), 1.0);
    }

    case 11: { // VIGNETTE
        float amt = u.p0.x;
        float rad = u.p0.y;
        float d = distance(uv, float2(0.5)) / 0.7071;
        float v = smoothstep(rad, rad - 0.45, d);
        return float4(base.rgb * mix(1.0, v, amt), 1.0);
    }

    case 12: { // EDGE DETECTION (Sobel)
        float2 o = 1.0 / res * max(u.p0.x, 1.0);
        float gx = 0, gy = 0;
        const float kx[9] = {-1,0,1,-2,0,2,-1,0,1};
        const float ky[9] = {-1,-2,-1,0,0,0,1,2,1};
        int idx = 0;
        for (int j = -1; j <= 1; ++j)
        for (int i = -1; i <= 1; ++i) {
            float s = luma(src.sample(samp, uv + float2(i, j) * o).rgb);
            gx += s * kx[idx]; gy += s * ky[idx]; ++idx;
        }
        float g = clamp(length(float2(gx, gy)) * u.p0.y, 0.0, 1.0);
        return mix(u.colorA, u.colorB, g);
    }

    case 13: { // CROSSHA0.0
        float L2 = L;
        float spacing = max(u.p0.x, 2.0);
        float3 ink = u.colorB.rgb, paper = u.colorA.rgb;
        float c = 1.0;
        float2 p = px;
        if (L2 < 0.85) c = min(c, step(0.4, fract((p.x + p.y) / spacing)));
        if (L2 < 0.65) c = min(c, step(0.4, fract((p.x - p.y) / spacing)));
        if (L2 < 0.45) c = min(c, step(0.4, fract(p.x / spacing)));
        if (L2 < 0.25) c = min(c, step(0.4, fract(p.y / spacing)));
        return float4(mix(ink, paper, c), 1.0);
    }

    case 14: { // CONTOUR (iso-luminance lines)
        float bands = max(u.p0.x, 2.0);
        float v = L * bands;
        float f = abs(fract(v) - 0.5);
        float line = smoothstep(0.0, fwidth(v) * 1.5 + 0.001, f);
        float3 fillc = mix(u.colorA.rgb, u.colorB.rgb, floor(v) / bands);
        return float4(mix(u.colorB.rgb, fillc, line), 1.0);
    }

    case 15: { // WAVE LINES
        float spacing = max(u.p0.x, 2.0);
        float amp = u.p0.y;
        float speed = u.p0.z;
        float disp = (L - 0.5) * amp + sin(px.x * 0.02 + t * speed) * amp * 0.3;
        float y = px.y + disp;
        float line = abs(fract(y / spacing) - 0.5) * 2.0;
        float m = smoothstep(0.35, 0.65, line);
        return float4(mix(u.colorB.rgb, u.colorA.rgb, m), 1.0);
    }

    case 16: { // VORONOI (cellular mosaic, sampled from source)
        float scale = max(u.p0.x, 1.0);
        float2 g = uv * scale * float2(res.x / res.y, 1.0);
        float2 cell = floor(g);
        float best = 1e9; float2 bestCenter = g;
        for (int j = -1; j <= 1; ++j)
        for (int i = -1; i <= 1; ++i) {
            float2 nb = cell + float2(i, j);
            float2 center = nb + hash22(nb);
            float d = distance(g, center);
            if (d < best) { best = d; bestCenter = center; }
        }
        float2 cuv = bestCenter / (scale * float2(res.x / res.y, 1.0));
        return src.sample(samp, clamp(cuv, 0.0, 1.0));
    }

    case 17: { // VHS
        float amt = u.p0.x;
        float yJit = sin(uv.y * 120.0 + t * 8.0) * 0.0015 * amt;
        float wob = (vnoise(float2(uv.y * 30.0, t)) - 0.5) * 0.01 * amt;
        float off = (0.004 + 0.006 * vnoise(float2(t, uv.y * 8.0))) * amt;
        float2 d = float2(yJit + wob, 0.0);
        float r = src.sample(samp, uv + d + float2(off, 0)).r;
        float g = src.sample(samp, uv + d).g;
        float b = src.sample(samp, uv + d - float2(off, 0)).b;
        float3 c = float3(r, g, b);
        c *= 0.9 + 0.1 * sin(px.y * 1.4);                   // scanlines
        c += (pcg3(float3(px, floor(t * 50.0))).x - 0.5) * 0.10 * amt; // noise (exact at any t)
        float band = step(0.992, fract(uv.y * 1.3 - t * 0.4)); // roll bar
        c = mix(c, c + 0.25, band * amt);
        return float4(c, 1.0);
    }

    case 18: { // ASCII — monospace cells (the atlas's 28×40 aspect), sized per 1000 px of
               // height so the type keeps its scale from a thumbnail to 5K. Each cell takes its
               // area-averaged colour (steady glyph choice as the photo drifts) and picks from a
               // ramp ordered by measured ink coverage; glyphs are 2×2 supersampled.
               // p0 = (cell, 0, use source color, 0)
        if (glyphs.get_width() == 0) return base;
        float k = res.y / 1000.0;
        float cw = max(u.p0.x * k, 3.0);
        float2 cs = float2(cw, cw / 0.7);
        float2 cellF = floor(px / cs);
        float2 c0 = (cellF + 0.5) * cs;
        float2 qd = cs * 0.25;
        float3 c = (src.sample(samp, (c0 + float2(-qd.x, -qd.y)) / res).rgb + src.sample(samp, (c0 + float2(qd.x, -qd.y)) / res).rgb
                  + src.sample(samp, (c0 + float2(-qd.x, qd.y)) / res).rgb + src.sample(samp, (c0 + qd) / res).rgb) * 0.25;
        float lv0 = luma(c);
        bool colorMode = u.p0.z > 0.5;
        float inkL = colorMode ? 1.0 : luma(u.colorB.rgb);
        // Light ink on a dark ground puts the densest glyphs on the brightest areas.
        float lv = inkL > luma(u.colorA.rgb) ? lv0 : 1.0 - lv0;
        int gi;
        if (u.glyphCount == 28) {
            // Sparse → dense by ink coverage: " .,:-;!+=?c7124a5$b8#0W@"
            const int ramp[24] = {27, 25, 24, 20, 23, 19, 15, 21, 22, 14, 18, 6,
                                  12, 11, 9, 16, 8, 3, 17, 5, 1, 13, 2, 0};
            gi = ramp[clamp(int(pow(saturate(lv), 0.85) * 23.0 + 0.5), 0, 23)];
        } else {
            gi = clamp(int((1.0 - lv) * float(u.glyphCount)), 0, u.glyphCount - 1);
        }
        // Glyphs drawn 1.25× their atlas size: they fill the cell like a terminal font.
        float2 local = ((px - cellF * cs) / cs - 0.5) * 0.8 + 0.5;
        float2 hp = 0.2 / cs;                                   // a quarter pixel, in atlas-cell units
        float gn = float(u.glyphCount), lo = 0.5 / 28.0;
        float ink = 0.0;
        for (int j = 0; j < 4; ++j) {
            float2 lp = local + float2((j & 1) ? hp.x : -hp.x, (j & 2) ? hp.y : -hp.y);
            ink += glyphs.sample(samp, float2((float(gi) + clamp(lp.x, lo, 1.0 - lo)) / gn, saturate(lp.y))).r;
        }
        ink *= 0.25;
        // Source-colour mode: the glyph carries the source hue at near-full brightness
        // (density already encodes luminance), over a faint backlight of the cell's own
        // colour, so the picture reads from across the room and up close.
        float3 hue = min(c / max(max(c.r, max(c.g, c.b)), 0.06), 1.0);
        float3 fg = colorMode ? hue * (0.55 + 0.45 * sqrt(lv0)) : u.colorB.rgb;
        float3 ground = colorMode ? u.colorA.rgb + c * 0.2 : u.colorA.rgb;
        return float4(mix(ground, fg, ink) + bandDither(px), 1.0);
    }

    case 19: { // MATRIX RAIN
        if (glyphs.get_width() == 0) return base;
        float cell = max(u.p0.x, 6.0);
        float speed = u.p0.y;
        int2 cellPx = int2(floor(px / cell));
        float colSeed = hash21(float2(float(cellPx.x), 3.0));
        float colSpeed = 0.4 + colSeed * 1.6;
        float head = fract(colSeed + t * speed * 0.08 * colSpeed) * (res.y / cell + 12.0);
        float dist = head - float(cellPx.y);
        float bright = 0.0;
        if (dist >= 0.0) bright = exp(-dist * 0.18);
        float glyphSel = floor(pcg3(float3(float(cellPx.x), float(cellPx.y), floor(t * 6.0))).x * float(u.glyphCount));
        int gi = clamp(int(glyphSel), 0, u.glyphCount - 1);
        float2 local = (px - float2(cellPx) * cell) / cell;
        float2 auv = float2((float(gi) + local.x) / float(u.glyphCount), local.y);
        float ink = glyphs.sample(samp, auv).r * bright;
        // modulate by source so it can reveal an image
        float srcMod = mix(1.0, luma(src.sample(samp, (float2(cellPx)+0.5)*cell/res).rgb) + 0.3, u.p0.z);
        float3 col = u.colorB.rgb;
        if (dist < 1.0 && dist >= 0.0) col = mix(col, float3(1.0), 0.7); // bright head
        return float4(u.colorA.rgb + col * ink * srcMod, 1.0);
    }

    case 20: { // PIXEL SORT (approximation: threshold-driven horizontal streaks)
        float thr = u.p0.x;
        float maxLen = max(u.p0.y, 1.0);
        // walk left until we exit the bright/dark region, sampling sparsely
        float2 dir = float2(1.0 / res.x, 0.0);
        float3 c = base.rgb;
        for (int i = 1; i < 64; ++i) {
            if (float(i) > maxLen) break;
            float2 suv = uv - dir * float(i);
            if (suv.x < 0.0) break;
            float sl = luma(src.sample(samp, suv).rgb);
            if (sl < thr) break;             // region boundary
            c = src.sample(samp, suv).rgb;   // smear the region's leading color
        }
        return float4(c, 1.0);
    }

    case 21: { // KALEIDOSCOPE
        float seg = max(u.p0.x, 2.0);
        float spin = u.p0.y;
        float2 c = uv - 0.5;
        float r = length(c);
        float a = atan2(c.y, c.x) + t * 0.15 * spin;
        float segAng = 6.2831853 / seg;
        a = fmod(a, segAng);
        a = min(a, segAng - a);
        float2 q = 0.5 + float2(cos(a), sin(a)) * r;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 22: { // CHROMATIC SHIFT
        float amt = u.p0.x / 100.0;
        float ang = u.p0.y;
        float2 d = float2(cos(ang), sin(ang)) * amt;
        float r = src.sample(samp, uv + d).r;
        float g = src.sample(samp, uv).g;
        float b = src.sample(samp, uv - d).b;
        return float4(r, g, b, 1.0);
    }

    case 23: { // BLOOM
        float thr = u.p0.x;
        float inten = u.p0.y;
        float rad = max(u.p0.z, 1.0);
        float3 sum = float3(0.0);
        float wsum = 0.0;
        for (int i = 0; i < 12; ++i) {
            float ang = float(i) / 12.0 * 6.2831853;
            for (int k = 1; k <= 2; ++k) {
                float2 off = float2(cos(ang), sin(ang)) * (rad * float(k)) / res;
                float3 s = src.sample(samp, uv + off).rgb;
                float b = max(luma(s) - thr, 0.0);
                sum += s * b; wsum += 1.0;
            }
        }
        float3 bloom = (sum / max(wsum, 1.0)) * inten * 6.0;
        return float4(base.rgb + bloom, 1.0);
    }

    case 24: { // HEX MOSAIC
        float s = max(u.p0.x, 4.0);
        float2 p = px / s;
        float2 ctr = hexCenter(p) * s / res;
        return src.sample(samp, clamp(ctr, 0.0, 1.0));
    }

    case 25: { // MIRROR
        int mode = int(u.p0.x + 0.5);
        float2 q = uv;
        if (mode == 0 || mode == 2) q.x = 0.5 - abs(q.x - 0.5);
        if (mode == 1 || mode == 2) q.y = 0.5 - abs(q.y - 0.5);
        return src.sample(samp, q);
    }

    case 26: { // GLI0.0 BLOCKS
        float amt = u.p0.x;
        float blockH = 0.05;
        float row = floor(uv.y / blockH);
        float slot = floor(t * 8.0);
        float2 hh = pcg3(float3(row, slot, 26.0)).xy;     // integer hash: hash21 froze past t ≈ 40 min
        float h = hh.x;
        float2 q = uv;
        if (h > 0.6) q.x += (hh.y - 0.5) * 0.3 * amt;
        float3 c = src.sample(samp, q).rgb;
        if (h > 0.85) {
            float sh = 0.02 * amt;
            c.r = src.sample(samp, q + float2(sh, 0)).r;
            c.b = src.sample(samp, q - float2(sh, 0)).b;
        }
        return float4(c, 1.0);
    }

    case 27: { // GAMEBOY (4-tone palette quantize)
        float3 p0c = float3(0.06, 0.22, 0.06);
        float3 p1c = float3(0.19, 0.38, 0.19);
        float3 p2c = float3(0.55, 0.67, 0.06);
        float3 p3c = float3(0.61, 0.74, 0.06);
        float l = luma(base.rgb);
        float thr = ditherThreshold(1, int2(px / max(u.p0.x, 1.0)));
        l = clamp(l + thr * 0.5, 0.0, 1.0);
        float3 c = (l < 0.25) ? p0c : (l < 0.5) ? p1c : (l < 0.75) ? p2c : p3c;
        return float4(c, 1.0);
    }

    case 28: { // NEON EDGES
        float gain = u.p0.x;
        float g = sobelMag(src, samp, uv, res, max(u.p0.y, 1.0));
        float e = pow(clamp(g * gain, 0.0, 1.0), 1.4);
        return float4(u.colorA.rgb + u.colorB.rgb * e, 1.0);
    }

    case 29: { // FISHEYE
        float amt = u.p0.x;
        float2 c = uv - 0.5;
        float r2 = dot(c, c);
        float2 q = c * (1.0 + amt * r2) + 0.5;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 30: { // SWIRL
        float amt = u.p0.x;
        float2 c = uv - 0.5;
        float r = length(c);
        float a = amt * (0.5 - r) + t * 0.1 * u.p0.y;
        float s = sin(a), co = cos(a);
        float2 q = float2(c.x * co - c.y * s, c.x * s + c.y * co) + 0.5;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 31: { // RIPPLE
        float amp = u.p0.x;
        float freq = u.p0.y;
        float speed = u.p0.z;
        float2 c = uv - 0.5;
        float r = length(c) + 1e-5;
        float off = sin(r * freq - t * speed) * amp * 0.01;
        float2 q = uv + (c / r) * off;
        return src.sample(samp, clamp(q, 0.0, 1.0));
    }

    case 32: { // TOON
        float bands = max(u.p0.x, 2.0);
        float3 c = floor(base.rgb * bands + 0.5) / bands;
        float g = sobelMag(src, samp, uv, res, 1.0);
        float edge = smoothstep(0.25, 0.55, g * u.p0.y);
        return float4(c * (1.0 - edge), 1.0);
    }

    case 33: { // THERMAL
        float l = luma(base.rgb) * u.p0.x;
        return float4(heatRamp(l), 1.0);
    }

    case 34: { // TRUCHET
        float s = max(u.p0.x, 4.0);
        float2 p = px / s;
        float2 id = floor(p);
        float2 f = fract(p);
        if (hash21(id) < 0.5) f.x = 1.0 - f.x;
        float d = min(length(f - float2(0.0, 0.0)), length(f - float2(1.0, 1.0)));
        float line = abs(d - 0.5);
        float m = smoothstep(0.12, 0.06, line);
        float lum = luma(src.sample(samp, (id + 0.5) * s / res).rgb);
        return float4(mix(u.colorA.rgb, u.colorB.rgb, m * smoothstep(0.15, 0.6, lum)), 1.0);
    }

    case 35: { // LED PANEL
        float cell = max(u.p0.x, 4.0);
        float gap = u.p0.y;
        float2 g = floor(px / cell);
        float3 c = src.sample(samp, (g + 0.5) * cell / res).rgb;
        float levels = 6.0;
        c = floor(c * levels + 0.5) / levels;
        float2 f = fract(px / cell) - 0.5;
        float d = length(f);
        float led = smoothstep(0.5 - gap, 0.5 - gap - 0.08, d);
        return float4(c * led * 1.25, 1.0);
    }

    case 36: { // NES 8-BIT (snap to the NES palette, chunky pixels, soft scanline)
        float cell = max(u.p0.x, 2.0);
        float scan = u.p0.y;
        float sat = max(u.p0.z, 0.0);
        int2 cellPx = int2(floor(px / cell));
        float2 quv = (float2(cellPx) + 0.5) * cell / res;
        float3 c = src.sample(samp, quv).rgb;
        // punch up saturation a touch before quantizing (NES look)
        float l = luma(c);
        c = clamp(mix(float3(l), c, sat), 0.0, 1.0);
        float3 best = NES[0]; float bd = 1e9;
        for (int i = 0; i < 64; ++i) {
            float3 d = c - NES[i];
            float dd = dot(d, d);
            if (dd < bd) { bd = dd; best = NES[i]; }
        }
        // subtle CRT scanline on the pixel rows
        float s = 1.0 - scan * (0.5 - 0.5 * cos(px.y / cell * 6.2831853));
        return float4(best * s, 1.0);
    }

    case 37: { // STARFIELD — a flight through a 3D star field (model: see sf_ncdf above).
               // p0 = (speed, density, warp = shutter → streak length, star size)
               // colorA space, colorB starlight.
        float speed = max(u.p0.x, 0.0);
        float density = clamp(u.p0.y, 1.0, 60.0);
        float warp = clamp(u.p0.z, 0.0, 1.0);
        float sz = clamp(u.p0.w, 0.2, 3.0);
        float pxs = res.y * 0.5;                              // pixels per screen unit
        float2 s = (uv - 0.5) * float2(res.x / res.y, 1.0) * 2.0;
        float rp = max(length(s), 1e-4);
        float rpx = rp * pxs;
        float thp = atan2(s.y, s.x);
        float rho = log(rp);
        // Star PSF: σ ∝ size and frame height (same look at any resolution), but never under
        // ~0.7 px so a point is always sampled. Flux is what's conserved: ∝ size² for big
        // stars, ∝ size below 1 (small stars stay visible as finer, dimmer points), and a σ
        // clamped up to 0.7 px spreads the same flux thinner — a thumbnail or a tiny star
        // looks like a downscale, not a snowstorm of 1 px dots.
        float sig1 = res.y * 0.0008;
        float sig = max(0.7, sz * sig1);
        float thumb = (sz < 1.0 ? sz : sz * sz) * sig1 * sig1 / (sig * sig);
        float M0 = exp2(floor(log2(512.0 / max(sz, 1.0))));  // sectors in q's octave 0
        const float LQ = 0.34657359;                          // ln 2 / 2: two q-cells per octave
        const int NL = 8;
        float v = 0.08 * speed;                               // depth units per second
        float w2 = warp * warp;
        float vT = v * max(w2 * w2 * 0.8, 1.0 / 60.0);        // flown while the shutter is open (≥ 180°)
        float Dk = density * 10.0;                            // stars per pattern area / e^{2q}
        float m = 3.0 * sig / rpx;                            // PSF reach, in ln r
        float3 acc = float3(0.0);
        for (int i = 0; i < NL; ++i) {
            float ph = float(i) / float(NL) + t * v + 0.37;
            float z = 1.0 - fract(ph);
            float fade = smoothstep(1.0, 0.8, z) * smoothstep(0.0, 0.05, z);
            if (fade <= 0.0) continue;
            float seed = float(i) * 7.0 + floor(ph) * 71.0;   // a fresh pattern every pass
            float vz = min(vT, z);                            // streaks capped at half the radius
            float qa = rho + log(z) - m, qb = rho + log(z + vz) + m;
            float ia = floor(qa / LQ), ib = min(floor(qb / LQ), ia + 3.0);
            float flux = fade * rsqrt(z * (z + vz)) / z;      // ~1/z^1.5: far stars stay visible
            for (float iq = ia; iq <= ib; iq += 1.0) {
                float M = clamp(M0 * exp2(floor(iq * 0.5)), 8.0, 16384.0);
                float eq0 = exp(iq * LQ);
                // Expected stars per cell = density × ∫ e^{2q} dq dθ (e^{2·LQ} = 2). Where that
                // passes 1 (dense fields, big stars → few wide sectors) a cell holds several
                // stars, so the density stays uniform out to the frame edge (no central clump).
                float lam = Dk * eq0 * eq0 * 3.14159265 / M;
                int K = int(min(ceil(lam), 6.0));
                float cth = (thp + 3.14159265) * M * 0.15915494;
                float ith = floor(cth), fth = cth - ith;
                float w = 6.2831853 / M * rpx;                // sector width here, px
                int nn = (3.0 * sig > min(fth, 1.0 - fth) * w + 0.15 * w) ? 2 : 1;
                float over = max(lam / float(K), 1.0);
                for (int k = 0; k < nn; ++k) {
                    float cell = ith + (k == 0 ? 0.0 : (fth < 0.5 ? -1.0 : 1.0));
                    cell -= M * floor(cell / M);
                    acc += sf_star(cell, iq, seed, lam, M, thp, rpx, sig, eq0, pxs, z, vz, flux, over);
                    for (int j = 1; j < K; ++j)                   // the j-th star: P = clamp(λ − j, 0, 1)
                        acc += sf_star(cell, iq + 64.0 * float(j), seed, lam - float(j), M, thp, rpx, sig,
                                       eq0, pxs, z, vz, flux, over);
                }
            }
        }
        float3 A = srgbToLinear(u.colorA.rgb), B = srgbToLinear(u.colorB.rgb);
        // Exposure follows the shutter: long streaks spread each star's light thin, so warp
        // opens up (as a camera would) to keep light-speed bright.
        // Starlight covers the background (linear mix), so light-ground palettes keep their stars.
        float3 col = mix(A, B, 1.0 - exp(-acc * 1.8 * thumb * (1.0 + 6.0 * w2 * w2)));
        return float4(linearToSrgb(col) + bandDither(px), 1.0);
    }

    case 39: { // UNIVERSE — the solar system in 3D. A perspective camera above the ecliptic
               // slowly orbits the Sun's axis (with a gentle precession), so occlusion, phases,
               // foreshortened orbits and a two-shell parallax starfield all read as depth.
               // Analytic only (sphere/plane hits, no ray-march): ~10 sphere tests + 8 orbit
               // rings per pixel; fbm only on the Sun's disc; all-register compositing.
               // p0=(scale,speed,stars,planetSpeed)  p1.xyz=live sun dir (Earth view frame)
               // p2=(userLon,userLat,hasLoc,orbitsOn)  colorB=(tilt°, cameraOrbit)  colorA=space
        float scale = max(u.p0.x, 0.3);
        float speed = u.p0.y;
        float starsAmt = max(u.p0.z, 0.0);
        float planetSpeed = u.p0.w;
        float tilt = clamp(u.colorB.x, 4.0, 86.0) * 0.01745329;
        float camSpin = u.colorB.y;
        bool haveTex = earthDay.get_width() > 4;
        float ts = t * speed;
        float ta = ts * 0.07 * planetSpeed;                  // orbital clock (Earth year ≈ 90 s)

        // ---- camera: orbit the Sun's axis; elevation precesses a few degrees ----
        float elev = clamp(tilt + 0.06 * sin(ts * 0.023), 0.03, 1.52);
        float az = 0.65 - ts * 0.028 * camSpin;           // retrograde vs the planets: the system visibly turns
        float dist = 15.0 / scale;
        float3 ro = dist * float3(cos(elev) * sin(az), sin(elev), cos(elev) * cos(az));
        float3 fwd = normalize(float3(0.0, -0.9, 0.0) / scale - ro);   // aim a little below the Sun
        float3 camR = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
        float3 camU = cross(camR, fwd);
        const float FOCAL = 2.5;                         // ~44° vertical FOV: depth without stretched limbs
        float2 sp = (uv - 0.5) * 2.0; sp.y = -sp.y; sp.x *= res.x / res.y;
        float3 rd = normalize(fwd * FOCAL + camR * sp.x + camU * sp.y);
        float pix = 2.0 / (res.y * FOCAL);                   // radians per pixel

        // ---- ecliptic plane + Saturn's ring plane (derivatives taken in uniform flow) ----
        float rdy = abs(rd.y) < 1e-5 ? -1e-5 : rd.y;
        float tP = -ro.y / rdy;
        float3 hp = ro + rd * tP;
        float pr = length(hp.xz);
        float fw = max(fwidth(pr), 1e-5);
        float3 pE = uniOrbitPos(3, ta), pS = uniOrbitPos(6, ta), pM = uniBodyPos(9, ta);
        const float RT = 0.466;                              // Saturn's obliquity, fixed in space,
        float3 ringN = float3(0.0, cos(RT), sin(RT));        // so the rings open and close over its year
        float dn = dot(rd, ringN);
        dn = abs(dn) < 1e-5 ? 1e-5 : dn;
        float tR = dot(pS - ro, ringN) / dn;
        float3 qR = ro + rd * tR;
        float rr = length(qR - pS) / UNI_RAD[6];
        float rfw = max(fwidth(rr), 1e-4);

        // ---- bodies: nearest two hits (two, so a Moon crossing Earth keeps a clean edge) ----
        int i1 = -1, i2 = -1; float t1 = 1e9, t2 = 1e9, c1 = 0.0, c2 = 0.0;
        for (int i = 0; i < 10; ++i) {
            float3 c = i == 3 ? pE : i == 6 ? pS : i == 9 ? pM : uniBodyPos(i, ta);
            float2 h = uniSphere(ro, rd, c, UNI_RAD[i], pix);
            if (h.y <= 0.0) continue;
            if (h.x < t1) { i2 = i1; t2 = t1; c2 = c1; i1 = i; t1 = h.x; c1 = h.y; }
            else if (h.x < t2) { i2 = i; t2 = h.x; c2 = h.y; }
        }

        // ---- background: space colour, far + near star shells, Milky Way ----
        float3 col = u.colorA.rgb;
        float spix = pix * max(1.0, res.y / 1300.0);         // star size: the same share of the frame at 5K
        if (c1 < 0.999 && starsAmt > 0.0) {
            float bri = min(starsAmt, 1.0) * clamp(res.y / 900.0, 0.3, 1.0);   // thumbnails: a downscaled sky
            float3 gN = normalize(float3(0.46, 0.84, -0.29));      // galactic pole, ~60° off the ecliptic's
            float gl = dot(rd, gN);
            float band = exp(-gl * gl * 30.0);                     // the Milky Way: denser stars + soft glow
            col += uniStars(rd * 100.0, 100.0, 0.9, float3(0.0), rd, spix, 0.0,
                            (0.035 + 0.11 * band) * starsAmt, 1.0) * bri;
            float b = dot(ro, rd), cq = dot(ro, ro) - 1600.0;      // near shell (radius 40): parallax
            float3 q = ro + rd * (-b + sqrt(max(b * b - cq, 0.0)));
            col += uniStars(q, 40.0, 0.45, ro, rd, spix, 101.0, 0.07 * starsAmt, 1.3) * bri;
            if (band > 0.03) {
                float3 gC = normalize(float3(0.84, -0.46, 0.0));      // galactic centre, in the band
                float2 gp = float2(dot(rd, gC), dot(rd, cross(gN, gC)));
                float n = 0.62 * vnoise(gp * 3.0 + gl * 4.0 + 5.0) + 0.38 * vnoise(gp * 7.0 - gl * 9.0 + 1.0);
                float lane = smoothstep(0.0, 0.05, abs(gl + 0.03 * (n - 0.5)));   // dark dust lane
                float core = max(dot(rd, gC), 0.0);
                core *= core;
                float3 mw = mix(float3(0.55, 0.62, 0.85), float3(1.0, 0.86, 0.68), core);
                col += mw * band * (0.35 + 0.65 * n) * mix(0.35, 1.0, lane) * (0.035 + 0.06 * core) * bri;
            }
        }

        // ---- layers: bodies + rings (alpha), glow + plane (additive). Kept in scalars
        //      (dynamically indexed arrays would spill to stack memory). depth < 0 = absent.
        float4 LA = float4(0.0), LB = float4(0.0), LC = float4(0.0);
        float dA = -1.0, dB = -1.0, dC = -1.0;
        float3 G = float3(0.0), PL = float3(0.0); float dG = -1.0, dPl = -1.0;
        float3 eL = normalize(-pE);                        // Earth's frame from the live sun vector
        float decl = asin(clamp(u.p1.y, -1.0, 1.0));
        float subLon = u.p2.x + atan2(u.p1.x, u.p1.z);
        float3 eN = cos(decl) * float3(0.0, 1.0, 0.0) + sin(decl) * eL;
        float3 eM = normalize(eL - sin(decl) * eN);
        float3 eE = cross(eN, eM);
        float3 moonM = normalize((pE - pM) * float3(1.0, 0.0, 1.0));
        for (int k = 0; k < 2; ++k) {
            int bi = k == 0 ? i2 : i1;
            if (bi < 0) continue;
            float bt = k == 0 ? t2 : t1, bc = k == 0 ? c2 : c1;
            float3 c = bi == 3 ? pE : bi == 6 ? pS : bi == 9 ? pM : uniBodyPos(bi, ta);
            // Shade a limb pixel at the middle of the strip of it the disc covers (not at the
            // silhouette, where μ = 0): the edge then carries the limb's true average colour
            // instead of a darker, redder 1 px rim.
            float3 oc = ro - c;
            float tca = -dot(oc, rd);
            float3 pp = oc + rd * tca;
            float dd = length(pp), R = UNI_RAD[bi];
            float de = min(dd, R - 0.5 * bc * tca * pix);
            float3 n0 = (pp / max(dd, 1e-6) * de - rd * sqrt(max(R * R - de * de, 0.0))) / R;
            float3 sc = uniShade(bi, c, n0, rd, bt * pix / UNI_RAD[bi], camR, camU, ts, t,
                                 eE, eN, eM, subLon, u.p2, moonM, ringN,
                                 earthDay, earthNight, planetTex, samp, haveTex);
            if (k == 0) { LA = float4(sc * bc, bc); dA = bt; } else { LB = float4(sc * bc, bc); dB = bt; }
        }

        float tc = -dot(ro, rd);                             // Sun glow, at its closest approach
        if (tc > 0.0) {
            float ds = length(ro + rd * tc);
            float x = max(ds - UNI_RAD[0], 0.0);
            float3 glow = float3(1.0, 0.60, 0.26) * (0.60 * exp(-x * 6.0) + 0.20 * exp(-x * 1.3))
                        + float3(1.0, 0.45, 0.18) * 0.05 * exp(-ds * 0.32);
            G = glow; dG = tc + UNI_RAD[0] * 0.05;           // the corona sits behind the disc's silhouette
        }

        if (tP > 0.0) {                                      // the ecliptic: dust disk, belt, orbits
            float3 pc = float3(0.0);
            float pth = atan2(-hp.z, hp.x);
            float path = min(0.06 / abs(rdy), 0.9);          // thin slab: brighter where we graze it
            float dens = exp(-pr * 0.42) * smoothstep(UNI_RAD[0], 1.5, pr) * (0.7 + 0.6 * vnoise(hp.xz * 1.3));
            float belt = exp(-(pr - 4.18) * (pr - 4.18) * 30.0);
            float3 dustC = mix(float3(1.0, 0.60, 0.30), float3(0.42, 0.52, 0.85), smoothstep(1.0, 7.0, pr));
            pc += dustC * (dens * 0.9 + belt * 0.16) * path * 0.55;
            if (belt > 0.03) {                               // asteroid belt, orbiting as one
                const float NA = 300.0, DR = 0.06, R0 = 3.84;
                float rot = ta * 0.62;
                float th = (pth - rot) * 0.1591549;
                float2 cell0 = floor(float2((th - floor(th)) * NA, (pr - R0) / DR));
                // Cells are only a few pixels deep when foreshortened: gather the radial
                // neighbours too, so a rock is never clipped by its cell's edge.
                for (int j = -1; j <= 1; ++j) {
                    float2 cell = cell0 + float2(0.0, float(j));
                    float3 h = pcg3(float3(cell, 57.0));
                    if (h.x >= 0.28) continue;
                    float aa = (cell.x + 0.2 + 0.6 * h.y) / NA * 6.2831853 + rot;
                    float3 pa = float3(cos(aa), 0.0, -sin(aa)) * (R0 + (cell.y + 0.2 + 0.6 * h.z) * DR);
                    float3 v = pa - ro;
                    float tv = dot(v, rd);
                    float dpx = length(v - rd * tv) / (tv * spix);
                    float sz = 1.05 + 0.45 * h.y;                 // σ ≥ 0.75 px
                    float rb = exp(-(R0 + (cell.y + 0.5) * DR - 4.18) * (R0 + (cell.y + 0.5) * DR - 4.18) * 30.0);
                    pc += float3(0.78, 0.72, 0.66) * exp(-dpx * dpx / (sz * sz)) * (0.18 + 0.32 * h.z) * rb
                        * clamp(res.y / 900.0, 0.3, 1.0);
                }
            }
            if (u.p2.w > 0.5) {                              // orbit lines, with a trail behind each planet
                for (int i = 1; i < 9; ++i) {
                    float line = smoothstep(1.4, 0.3, abs(pr - UNI_ORB[i]) / fw);
                    if (line <= 0.0) continue;
                    float da = uniAngle(i, ta) - pth;
                    da -= 6.2831853 * floor(da * 0.1591549);
                    float trail = exp(-da * 2.2);
                    pc += mix(float3(0.55, 0.62, 0.78) * 0.17, UNI_TINT[i] * 0.9, trail) * line;
                }
            }
            pc *= exp(-max(tP - dist, 0.0) * 0.035);         // far side recedes
            PL = pc; dPl = tP;
        }

        if (tR > 0.0) {                                      // Saturn's rings, with Saturn's shadow
            float ra = uniRingAlpha(rr, rfw);
            if (ra > 0.002) {
                float3 L6 = normalize(-qR);
                float3 oc = qR - pS;
                float b = dot(oc, L6);
                float sd = sqrt(max(dot(oc, oc) - b * b, 0.0)) / UNI_RAD[6];
                float shadow = b < 0.0 ? smoothstep(1.03, 0.97, sd) : 0.0;
                float lit = (0.35 + 0.65 * abs(dot(ringN, L6))) * (1.0 - 0.8 * shadow);
                float3 rc = mix(float3(0.60, 0.53, 0.43), float3(0.93, 0.85, 0.68), smoothstep(1.5, 2.2, rr)) * lit;
                LC = float4(rc * ra, ra); dC = tR;
            }
        }

        // sort the three alpha layers far → near, then lay the additive ones into the gaps
        if (dA < dB) { float4 l = LA; LA = LB; LB = l; float d = dA; dA = dB; dB = d; }
        if (dB < dC) { float4 l = LB; LB = LC; LC = l; float d = dB; dB = dC; dC = d; }
        if (dA < dB) { float4 l = LA; LA = LB; LB = l; float d = dA; dA = dB; dB = d; }
        col += uniAddIn(G, dG, PL, dPl, dA, 1e30);
        col = col * (1.0 - LA.a) + LA.rgb;
        col += uniAddIn(G, dG, PL, dPl, dB, dA);
        col = col * (1.0 - LB.a) + LB.rgb;
        col += uniAddIn(G, dG, PL, dPl, dC, dB);
        col = col * (1.0 - LC.a) + LC.rgb;
        col += uniAddIn(G, dG, PL, dPl, -1e30, dC);
        col += bandDither(px);
        return float4(col, 1.0);
    }

    case 40: { // BLACK HOLE — a Schwarzschild hole and its accretion disk, traced along true
               // null geodesics (see bh_planck / bh_disk above). The shadow edge is anti-aliased
               // analytically from the ray's impact parameter; disk crossings are shaded after
               // the march so their texture can be filtered by the pixel's footprint.
               // p0 = (mass, brightness, rotation, disk size)  p1 = (speed, stars, angle)
        float mass = max(u.p0.x, 0.05);
        float brightness = u.p0.y;
        float rotSpeed = u.p0.z;
        float diskScale = max(u.p0.w, 0.3);
        float speed = max(u.p1.x, 0.0);
        float starsAmt = max(u.p1.y, 0.0);
        float angle = clamp(u.p1.z, 0.03, 1.45);   // viewing elevation: low = edge-on, high = top-down
        float ts = t * speed;
        float rs = mass * 3.2;                      // Schwarzschild radius
        float rin = max(4.1 * diskScale, 3.0 * rs); // never inside the last stable orbit
        float rout = max(14.5 * diskScale, rin * 1.6);

        // Camera: a slow azimuth orbit at the chosen elevation.
        const float D = 30.0, F = 2.0;
        float ce = cos(angle), se = sin(angle);
        float ct = ts * 0.025;
        float3 ro = D * float3(sin(ct) * ce, se, -cos(ct) * ce);
        float3 fwd = normalize(-ro);
        float3 rgt = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
        float3 cup = cross(fwd, rgt);
        float2 sp = (uv - 0.5) * 2.0; sp.y = -sp.y; sp.x *= res.x / res.y;
        float3 rd = normalize(fwd * F + rgt * sp.x + cup * sp.y);
        float pix = 2.0 / (res.y * F);

        float b = length(cross(ro, rd));            // impact parameter: conserved, decides capture
        float fb = max(fwidth(b), 1e-6);
        // Capture threshold: √27/2·rs, as the drift-kick-drift march realises it (0.75 %
        // inside the exact value), so the shadow edge and the photon ring agree.
        float bc = 2.5980762 * rs * 0.9926;
        float shadow = clamp((bc - b) / fb + 0.5, 0.0, 1.0);
        // Images that reach the camera only after the ray has rounded the hole (the photon
        // ring, and the far side lensed under it) are squeezed into a band of b whose width
        // shrinks like (b − bc). Once that band is narrower than this pixel's footprint in b
        // the image is sub-pixel: point-sampling it would give a row of stray dots, so it is
        // faded by its coverage instead.
        float wRing = clamp((b - bc) * 0.6 / fb, 0.0, 1.0);
        float sgn = rotSpeed < 0.0 ? -1.0 : 1.0;

        // ---- march ----
        BHRay R = bh_march(ro, rd, b, rs, rin, rout, D, sgn, wRing);
        float3 dOut = normalize(R.v);

        // ---- shade (uniform control flow again: footprints from screen derivatives) ----
        float T0 = 4400.0;
        float f0 = fwidth(R.H0.x), f1 = max(fwidth(R.H1.x), f0), f2 = max(fwidth(R.H2.x), 0.5);
        float2 gb = float2(dfdx(b), dfdy(b));
        float3 acc = float3(0.0);
        float A = 0.0;
        // Where the photon ring is narrower than ~1.2 px (thumbnails, light holes) one sample
        // per pixel would hit or miss it from pixel to pixel — a dashed ring. Those pixels
        // trace four sub-rays across their footprint in b and average them instead.
        bool ss = fb > 0.012 * bc && b > bc - fb && b < bc * 1.12 + fb;
        int nS = ss ? 4 : 1;
        float2 gdir = gb / max(length(gb), 1e-9) * (2.0 / res.y);
        for (int k = 0; k < nS; ++k) {
            BHRay S = R;
            if (ss) {
                float2 o = gdir * ((float(k) - 1.5) * 0.25);
                float3 rk = normalize(fwd * F + rgt * (sp.x + o.x) + cup * (sp.y - o.y));
                float bk = length(cross(ro, rk));
                S = bh_march(ro, rk, bk, rs, rin, rout, D, sgn, clamp((bk - bc) * 2.4 / fb, 0.0, 1.0));
            }
            float4 d0 = bh_disk(S.H0.xyz, f0, ts, rin, rout, rotSpeed, T0) * S.H0.w;
            float4 d1 = bh_disk(S.H1.xyz, f1, ts, rin, rout, rotSpeed, T0) * S.H1.w;
            float4 d2 = bh_disk(S.H2.xyz, f2, ts, rin, rout, rotSpeed, T0) * S.H2.w;
            float3 ak = d0.rgb + (1.0 - d0.a) * d1.rgb;
            float Ak = d0.a + (1.0 - d0.a) * d1.a;
            ak += (1.0 - Ak) * d2.rgb; Ak += (1.0 - Ak) * d2.a;
            acc += ak; A += Ak;
        }
        acc /= float(nS); A /= float(nS);
        // Lensing Jacobian (sky radians per image pixel) in a tangent frame at dOut.
        float3 e1 = normalize(cross(dOut, abs(dOut.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
        float3 e2 = cross(dOut, e1);
        float3 jx = dfdx(dOut), jy = dfdy(dOut);
        float ja = dot(jx, e1), jc = dot(jx, e2), jb = dot(jy, e1), jd = dot(jy, e2);
        float det = ja * jd - jb * jc;
        det = abs(det) < 1e-12 ? 1e-12 : det;
        float2x2 Ji = float2x2(float2(jd, -jc) / det, float2(-jb, ja) / det);
        float mu = clamp(pix * pix / abs(det), 0.0, 5.0);
        float expo = brightness * 0.24;
        float3 bg = bh_sky(dOut, e1, e2, Ji, mu, starsAmt * clamp(res.y / 900.0, 0.3, 1.0)) * expo;
        bg = 0.25 * (1.0 - exp(-bg * 4.0));         // stars stay under a bloom pass's threshold
        float3 col = aces(acc * expo + (1.0 - A) * (1.0 - shadow) * bg);
        return float4(col + bandDither(px), 1.0);
    }

    // ================================================================ modern pack

    case 42: { // MESH GRADIENT (scene) — five drifting color points blended in Oklab,
               // domain-warped for organic edges, finished with film grain.
               // p0 = (speed, softness, hueSpread, grain); colorA deep, colorB light.
        float speed = u.p0.x, soft = max(u.p0.y, 0.3), spread = u.p0.z, grainAmt = u.p0.w;
        float ts = t * speed * 0.09;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        // Organic edges from a smooth gradient-noise warp (value noise left faint
        // axis-aligned creases in the blends) plus a finer ripple carried by it, drifting slowly.
        float2 wq = p * 1.15;
        float2 w = float2(gnoise(wq + float2(ts * 1.1, -ts * 0.8)), gnoise(wq + float2(4.1 - ts * 0.9, 2.7 + ts)));
        w += 0.12 * float2(sin(wq.y * 2.3 + w.x * 3.0 - ts * 1.4), sin(wq.x * 2.1 - w.y * 3.0 + ts * 1.3 + 3.1));
        p += w * 0.62;

        float3 A = srgbToOklab(u.colorA.rgb), B = srgbToOklab(u.colorB.rgb);
        float3 st[5];
        st[0] = A;
        st[1] = B;
        // Accents are analogous neighbours of the two key colors, so any A/B pair
        // yields a coherent five-color field (no muddy complementary midpoints).
        st[2] = oklabHue(B, -spread * 2.0);
        st[2].x = mix(A.x, B.x, 0.75); st[2].yz *= 1.1;
        st[3] = oklabHue(B, spread * 1.2);
        st[3].x = min(B.x + 0.07, 0.97); st[3].yz *= 0.85;
        st[4] = oklabHue(A, -spread * 1.5);
        st[4].x = mix(A.x, B.x, 0.25); st[4].yz *= 0.95;

        float expo = 1.9 / soft;
        float3 acc = float3(0.0); float wsum = 0.0, csum = 0.0;
        for (int i = 0; i < 5; ++i) {
            float fi = float(i);
            float2 c = float2(cos(fi * 1.2566 + ts * (0.55 + 0.11 * fi)),
                              sin(fi * 1.6336 + ts * (0.47 + 0.17 * fi))) * float2(0.40 * aspect, 0.36);
            float2 d = p - c;
            float wi = pow(dot(d, d) + 0.04, -expo);   // finite at the point: no flat spot or bullseye
            acc += st[i] * wi; wsum += wi; csum += length(st[i].yz) * wi;
        }
        float3 lab = acc / wsum;
        // Keep most of the chroma through a blend (as an OkLCh mix would): two far-apart
        // hues meet through a vivid in-between hue instead of a greyed, muddy midpoint.
        float cAvg = csum / wsum, cNow = length(lab.yz);
        lab.yz *= mix(1.0, cAvg / max(cNow, 1e-4), 0.55 * smoothstep(0.0, 0.03, cNow));
        float3 col = oklabToSrgb(lab);
        // Grain like film: strongest in the midtones, quieter in deep shadow and highlight
        // (flat additive noise read as a dirty screen in the darks), and a touch stronger
        // per pixel on dense displays so it reads the same from viewing distance.
        float gw = 0.45 + 2.2 * lab.x * (1.0 - lab.x);
        float gk = clamp(sqrt(res.y / 1000.0), 1.0, 1.6);
        col += filmGrain(px, t) * grainAmt * 0.8 * gw * gk + bandDither(px);
        return float4(col, 1.0);
    }

    case 43: { // AURORA (scene) — volumetric auroral curtains over a mountain lake at night.
               // Curtains are thin vertical sheets 150–520 km away, traced in top view so
               // hem altitude, Earth curvature, fold brightening and field-aligned rays are
               // geometric, not painted (see nature_curtains in Scenes/Nature_funcs.h).
               // p0 = (speed, glow, height, stars)  p1 = (lake, activity)
               // colorA sky, colorB aurora (the green; tops and fringe are derived from it).
        float aspect = res.x / res.y;
        float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
        const float F = 1.3, pitch = 0.30;
        float3 fwd = float3(0.0, sin(pitch), cos(pitch));
        float3 up = float3(0.0, cos(pitch), -sin(pitch));
        float3 rd = normalize(fwd * F + float3(1.0, 0.0, 0.0) * sp.x + up * sp.y);

        NatureAuroraP P;
        P.ts = t * u.p0.x;
        P.inten = u.p0.y;
        P.height = max(u.p0.z, 0.2);
        P.stars = u.p0.w;
        P.act = clamp(u.p1.y, 0.0, 1.0);
        P.pix = 2.0 / (res.y * F);
        P.t = t;
        P.soft = 0.0;
        P.sky = nature_lin(u.colorA.rgb);
        float3 gS = u.colorB.rgb;
        P.cG = srgbToLinear(gS);
        float3 gL = srgbToOklab(gS);
        P.cTop = srgbToLinear(oklabToSrgb(mix(gL, srgbToOklab(float3(0.92, 0.22, 0.66)), 0.85)));
        P.cPink = srgbToLinear(oklabToSrgb(mix(gL, srgbToOklab(float3(1.0, 0.32, 0.62)), 0.9)));
        float lake = clamp(u.p1.x, 0.0, 1.0);

        float3 col;
        if (rd.y >= 0.0 || lake <= 0.0) {
            float3 r = rd; r.y = max(r.y, 0.0);
            col = nature_auroraView(rd, u, P);
            if (rd.y < 0.0) {           // no lake: snowy shore, faintly lit by the sky
                col = P.sky * 0.35 + P.cG * 0.004 * P.inten;
            }
        } else {
            // Lake: mirror of the view, roughened by slow ripples (world-space sines,
            // faded out where a ripple would be smaller than a pixel).
            float camH = 1.6;                                   // metres above the water
            float dist = camH / -rd.y;
            float2 w = rd.xz * dist;
            float foot = dist * P.pix / max(-rd.y, 0.02);       // pixel footprint, metres
            float2 grad = float2(0.0);
            float ts = t * 0.35;
            for (int i = 0; i < 6; ++i) {
                float fi = float(i);
                float lam = 0.3 * pow(1.65, fi);
                float ang = 1.5708 + (fi - 2.5) * 0.33 + 0.25 * sin(fi * 3.7);
                float2 dir = float2(cos(ang), sin(ang));
                float k = 6.2831853 / lam;
                float amp = 0.0013 * smoothstep(foot * 3.0, foot * 8.0, lam);
                grad += dir * cos(dot(w, dir) * k + ts * sqrt(9.8 * k) * 0.6 + fi * 2.3) * amp;
            }
            float3 n = normalize(float3(-grad.x, 1.0, -grad.y));
            float3 rr = reflect(rd, n);
            rr.y = max(rr.y, 0.0005);
            float fres = nature_schlick(dot(-rd, n));
            P.soft = 5.0;
            float3 refl = nature_auroraView(rr, u, P);
            float3 body = P.sky * 0.05;
            col = mix(body, refl, mix(0.0, fres, lake));
            col = mix(col, P.sky * 0.35 + P.cG * 0.004 * P.inten, 1.0 - lake);
        }
        return float4(nature_display(col * 1.0, px), 1.0);
    }

    case 44: { // TOPOGRAPHY (scene) — isolines of a slowly evolving warped-fbm terrain,
               // every 5th an index contour, with optional hillshade relief.
               // p0 = (lines, scale, speed, relief); colorA ground, colorB lines.
        float lines = max(u.p0.x, 2.0), sc = max(u.p0.y, 0.2), speed = u.p0.z, fillAmt = u.p0.w;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * sc * 1.5;
        float ts = t * speed * 0.03;
        // Same terrain as ever, now with its exact gradient: analytic through the detailed
        // fbm, chain rule through the warp. The warp is broad and smooth, so its Jacobian
        // from screen derivatives is accurate to ~1% and costs nothing.
        float wxv = gfbm(p * 0.6 + float2(0.0, ts), 3);
        float wyv = gfbm(p * 0.6 + float2(5.2, 1.3 - ts), 3);
        float pixW = sc * 1.5 / res.y;
        float2 jx = float2(dfdx(wxv), dfdy(wxv)) / pixW, jy = float2(dfdx(wyv), dfdy(wyv)) / pixW;
        float2 gsm;
        float3 g = topo_fbmd(p + 1.1 * float2(wxv, wyv) + float2(ts * 0.5, -ts * 0.3) + 3.7, 4, gsm);
        float2 gp = g.yz + 1.1 * (g.y * jx + g.z * jy);
        float2 hps = (gsm + 1.1 * (gsm.x * jx + gsm.y * jy)) * 0.75;   // broad landforms only
        float h = g.x * 0.75 + 0.5;                               // ≈ 0..1, no clamping (no plateaus)
        float2 hp = gp * 0.75;                                    // dh/dp

        float pix = sc * 1.5 / res.y;                             // p units per pixel
        float v = h * lines;
        float fw = max(length(hp) * lines * pix, 1e-4);           // contour levels per pixel, exact
        float lw = max(res.y / 1000.0, 0.8);
        float d = abs(fract(v + 0.5) - 0.5) / fw;                // distance to isoline, in px
        bool major = fmod(floor(v + 0.5) + 1000.0, 5.0) < 0.5;
        // The shipped widths were measured with fwidth's |dx|+|dy|, which runs ~4/π (1.27×)
        // wider than the true distance on average; scale by that so the ink weight and the
        // index-line hierarchy stay exactly as they were, just without the beading.
        float width = major ? lw * 2.29 : lw * 1.27;
        float line = clamp(width * 0.5 + 0.5 - d, 0.0, 1.0);
        line *= smoothstep(0.5, 0.2, fw);                         // fade where lines would crowd
        float alpha = major ? 0.95 : 0.62;

        // Hillshade from the exact normal (the old 2×2-quad derivative faceted the relief),
        // lit from the upper left like a printed relief map, mixed in linear light.
        float3 n = normalize(float3(-hp.x, hp.y, 1.0) * float3(0.75, 0.75, 1.0));
        float3 Ld = normalize(float3(-0.55, 0.55, 0.63));
        float r = dot(n, Ld) - Ld.z;                              // vs flat ground: <0 shade, >0 lit
        // faint hypsometric tint, mixed perceptually as before so the ground keeps its tone
        float3 base = srgbToLinear(mix(u.colorA.rgb, u.colorB.rgb, (0.04 + 0.10 * saturate(h)) * fillAmt));
        float3 ink = srgbToLinear(u.colorB.rgb);
        float darkGround = 1.0 - smoothstep(0.02, 0.25, dot(base, float3(0.2126, 0.7152, 0.0722)));
        float3 col = base * max(1.0 + 1.1 * fillAmt * r, 0.2);
        // On a dark map the relief also reads as faint moonlit slopes in the line colour
        // (shading a near-black ground alone left it invisible). Centred on zero, so the
        // ground keeps its tone; paper maps keep the printed shading.
        float3 ns = normalize(float3(-hps.x, hps.y, 1.0) * float3(0.75, 0.75, 1.0));
        float rs = dot(ns, Ld) - Ld.z;
        col = max(col + ink * darkGround * fillAmt * 0.008 * (smoothstep(-0.4, 0.4, rs) - 0.4), 0.0);
        // ink composited in display space, as before, so line weights keep their look
        float3 outc = mix(linearToSrgb(col), u.colorB.rgb, line * alpha);
        return float4(outc + bandDither(px), 1.0);
    }

    case 45: { // LIQUID CHROME (scene) — a rippling mirror surface reflecting a studio
               // environment (hard horizon + softboxes), optional thin-film iridescence.
               // p0 = (speed, scale, iridescence, fine ripples); p1 = (roughness, brushed,
               // film tone); colorA shadow (black point), colorB highlight.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), iris = u.p0.z;
        float ripple = u.p0.w, rough = u.p1.x, aniso = u.p1.y, film = u.p1.z;
        float ts = t * speed * 0.2;
        float aspect = res.x / res.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * sc * 3.0;
        // Surface at the pixel and two neighbours a few px away: a smooth screen gradient
        // of the reflection (dfdx would quantise it to 2x2 quads), which tells the studio
        // where the reflection is near-stationary: saddles and small crests.
        const float e = 0.012;
        float3 hs = chrome_surface(p, ts, ripple);
        float3 hx = chrome_surface(p + float2(e, 0.0), ts, ripple);
        float3 hy = chrome_surface(p + float2(0.0, e), ts, ripple);
        float3 r = chrome_reflect(hs.yz);
        float2 dry = float2(chrome_reflect(hx.yz).y, chrome_reflect(hy.yz).y) - r.y;
        float gys = length(dry) / e * sc * 3.0;            // change in r.y per screen height
        // Camera looks slightly down, so flat metal mirrors the cyclorama above the horizon;
        // every tilt sweeps the reflection across horizon, strip lights, flags and floor.
        float3 n = normalize(float3(-hs.y * 0.8, hs.z * 0.8, 1.0));
        float3 v = normalize(float3(0.0, 0.28, -1.0));

        float3 Bl = srgbToLinear(u.colorB.rgb);
        float3 c = chrome_env(r, Bl, rough, aniso, res.y, gys);
        // Film thickness (nm). A soft pearl (low iridescence) takes a broad, slow field much
        // larger than the forms, so a whole swell shares one or two pastel hues. A holographic
        // foil (high iridescence) takes it from the reflected direction instead, mostly its
        // sideways swing: like a foil's colour, which depends on how each facet catches the
        // studio, so every swell carries one smooth sweep of hue from flank to flank that
        // turns with the form and travels with it (no blotches, no rings around the crests).
        float hv = smoothstep(0.15, 0.6, iris);
        float broad = 0.0;
        if (hv < 1.0) {                                    // (a uniform: the branch is free)
            float2 fq = p * (0.42 / sc) + float2(ts * 0.06, -ts * 0.045);
            broad = gnoise(fq) * 1.3 + 0.22 * sin(fq.x * 2.3 - fq.y * 1.9 + hs.x * 0.4 + ts * 0.2);
        }
        float slope = r.x * 0.6 - (r.y - 0.27) * 0.25;            // 0 on flat metal
        float thick = mix(200.0, 600.0, film) + 100.0 * (1.0 - hv) * broad
                    + 190.0 * hv * slope + mix(14.0, 8.0, hv) * hs.x;
        c *= chrome_reflectance(saturate(dot(n, -v)), thick, iris);
        // poured-metal depth: troughs sit slightly in their own shadow
        c *= mix(0.8, 1.0, smoothstep(-1.1, 0.5, hs.x));
        float2 vq = uv - 0.5;
        c *= 1.0 - 0.22 * dot(vq, vq);
        // Filmic: ACES on luminance (hue-preserving, so tinted highlights keep their tint),
        // blended with per-channel ACES so the hottest lights still burn to white.
        c *= 1.35;
        float L = dot(c, float3(0.2126, 0.7152, 0.0722));
        float3 tm = mix(c * (aces(float3(L)).x / max(L, 1e-5)), aces(c), 0.3);
        float3 o = linearToSrgb(saturate(tm));
        float3 A = u.colorA.rgb;                       // shadow colour = the black point
        o = A + (1.0 - A) * o;
        o += bandDither(px) * 1.5;
        return float4(o, 1.0);
    }

    case 46: { // SILK (scene) — a sheet of satin drifting in a slow breeze, lit by a large
               // soft key. Folds are an analytic height field (silk_surface); the weave makes
               // the sheen anisotropic (Kajiya–Kay along the weft, which runs across the folds),
               // so light gathers in long liquid bands down each fold's flank, with a dimmer
               // dyed second lobe and a soft cloth sheen at grazing. Linear light, soft shoulder.
               // p0 = (speed, fold size, sheen); colorA shadow, colorB silk.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), sheen = saturate(u.p0.z);
        float aspect = res.x / res.y;
        float ts = t * speed * 0.55;
        float2 p = float2((uv.x - 0.5) * aspect, 0.5 - uv.y) * (2.6 / sc);   // y up
        float3 hs = silk_surface(p, ts);
        const float relief = 0.42;
        float3 n = normalize(float3(-hs.yz * relief, 1.0));
        // weft direction: across the folds, lying in the surface
        const float2 Dp = float2(0.447, 0.894);
        float3 T = normalize(float3(Dp, dot(hs.yz, Dp) * relief));
        const float3 V = float3(0.0, 0.0, 1.0);
        float3 L = normalize(float3(-0.50, 0.62, 0.62));          // key: big softbox, upper left
        float3 Lf = normalize(float3(0.75, -0.25, 0.60));         // fill: low right
        float3 H = normalize(L + V), Hf = normalize(Lf + V);

        float3 silk = srgbToLinear(u.colorB.rgb);
        float3 shadow = srgbToLinear(u.colorA.rgb);
        // shot silk: the sheen takes a slightly different hue than the body
        float3 Bk = srgbToOklab(u.colorB.rgb);
        float3 shot = srgbToLinear(oklabToSrgb(float3(min(Bk.x + 0.12, 0.98), oklabHue(Bk, sheen * 0.5).yz * 0.6)));

        // Kajiya–Kay: highlight where the thread is perpendicular to the half vector.
        // Exponent limited by the pixel footprint so the bands never alias.
        float TH = dot(T, H), THf = dot(T, Hf);
        float fp = fwidth(TH) * 1.5 + 1e-4;
        float m1 = min(70.0, 1.2 / (fp * fp));
        float sinTH = sqrt(saturate(1.0 - TH * TH));
        float spec = pow(sinTH, m1) * 0.9 + pow(sinTH, m1 * 0.18) * 0.18;
        float specF = pow(sqrt(saturate(1.0 - THf * THf)), 24.0) * 0.18;
        // second lobe, shifted toward the root and dyed by the fibre (silk's warm glow)
        float3 T2 = normalize(T + n * 0.22);
        float TH2 = dot(T2, H);
        float spec2 = pow(sqrt(saturate(1.0 - TH2 * TH2)), 18.0);

        float ndl = dot(n, L), ndf = dot(n, Lf);
        float wrap = saturate((ndl + 0.35) / 1.35);
        float diff = wrap * wrap * wrap;
        float fill = saturate((ndf + 0.2) / 1.2) * 0.12;
        // cavities: the valleys between folds sit in their own shadow
        float ao = mix(0.35, 1.0, smoothstep(-1.25, 0.55, hs.x));
        // cloth sheen at grazing (fibres catching the light edge-on)
        float graze = pow(1.0 - saturate(n.z), 2.0);

        // Slubs: the faint streaks real silk yarn leaves in the sheen, running along the
        // warp. Fixed in cloth units, so they only appear once a display resolves them
        // (≥ ~2.5 px per streak) and never shimmer on smaller screens.
        float a0 = dot(p, float2(0.894, -0.447)), b0 = dot(p, Dp) + 0.36 * sin(0.9 * a0 + ts * 0.23);
        float streakPx = res.y * sc / (2.6 * 190.0);
        float slub = gnoise(float2(b0 * 190.0, a0 * 5.0)) * smoothstep(2.0, 4.0, streakPx);
        spec *= 1.0 + 0.22 * slub;
        float key = 1.3 * (0.45 + 0.55 * smoothstep(-1.0, 0.8, -p.x * 0.14 * sc + p.y * 0.2 * sc));  // pool of light, upper left
        float3 col = shadow * (0.6 + 0.4 * ao);
        col += silk * (diff * key + fill) * ao * 0.5;
        col += shot * spec2 * key * ao * 0.22 * (0.4 + sheen);
        // the sheen is near-white but keeps a breath of the dye (pale gold, pale blue…)
        float3 specCol = srgbToLinear(oklabToSrgb(float3(0.94, Bk.yz * 0.5)));
        col += specCol * (spec * key + specF) * mix(0.30, 1.25, sheen) * mix(0.55, 1.0, ao);
        col += silk * graze * 0.25 * ao * (0.4 + diff);
        float2 vq = uv - 0.5;
        col *= 1.0 - 0.35 * dot(vq, vq);
        return float4(linearToSrgb(flowing_tone(col)) + bandDither(px) * 1.5, 1.0);
    }

    case 47: { // RISOGRAPH — separates the source into two spot inks (least-squares on
               // absorbance), screens each (stochastic grain or rotated halftone),
               // misregisters ink 2, then overprints both on textured paper.
               // p0 = (screen, dotSize, misregistration, paper); colorA ink 1, colorB ink 2.
        int screenMode = int(u.p0.x + 0.5);
        float k = res.y / 1000.0;
        float cell = max(u.p0.y * k, 1.0);
        float misreg = u.p0.z * k;
        float paperAmt = u.p0.w;
        float3 inkA = u.colorA.rgb, inkB = u.colorB.rgb;
        float3 kA = 1.0 - inkA, kB = 1.0 - inkB;
        float a11 = dot(kA, kA) + 0.03, a12 = dot(kA, kB), a22 = dot(kB, kB) + 0.03;
        float det = max(a11 * a22 - a12 * a12, 1e-4);
        float2 offB = float2(misreg, -misreg * 0.6)
                    + float2(sin(t * 0.21), cos(t * 0.17)) * misreg * 0.15;   // slow drum drift
        float2 pB = px - offB;

        float mA, mB;
        if (screenMode == 1) {   // HALFTONE: 15° and 75° screens
            float2x2 RA = float2x2(cos(0.26), -sin(0.26), sin(0.26), cos(0.26));
            float2x2 RB = float2x2(cos(1.31), -sin(1.31), sin(1.31), cos(1.31));
            float cs = cell * 1.6;
            float2 rpA = RA * px, rpB = RB * pB;
            float2 gA = (floor(rpA / cs) + 0.5) * cs, gB = (floor(rpB / cs) + 0.5) * cs;
            float3 DA = 1.0 - src.sample(samp, (transpose(RA) * gA) / res).rgb;
            float3 DB = 1.0 - src.sample(samp, (transpose(RB) * gB) / res).rgb;
            float bAA = dot(kA, DA), bBA = dot(kB, DA), bAB = dot(kA, DB), bBB = dot(kB, DB);
            float covA = smoothstep(0.06, 0.94, (a22 * bAA - a12 * bBA) / det);
            float covB = smoothstep(0.06, 0.94, (a11 * bBB - a12 * bAB) / det);
            float rough = (vnoise(px / (1.3 * k)) - 0.5) * 0.10;
            float rA = sqrt(covA) * 0.74 + rough, rB = sqrt(covB) * 0.74 - rough;
            float aa = 1.2 / cs;
            mA = smoothstep(rA + aa, rA - aa, length((rpA - gA) / cs));
            mB = smoothstep(rB + aa, rB - aa, length((rpB - gB) / cs));
        } else {                 // GRAIN: stochastic (FM) screen, like a riso master's
            mA = risoInk(src, samp, px, cell, res, kA, kB, a11, a12, a22, det, false);
            mB = risoInk(src, samp, pB, cell, res, kA, kB, a11, a12, a22, det, true);
        }
        // uneven ink laydown (drum pressure) + overprint (inks are translucent → multiply)
        float dA = 0.86 + 0.14 * vnoise(px / (160.0 * k) + 3.0);
        float dB = 0.86 + 0.14 * vnoise(px / (160.0 * k) + 11.0);
        float3 paper = float3(0.965, 0.952, 0.918);
        paper *= 1.0 + (vnoise(px / (2.2 * k)) - 0.5) * 0.07 * paperAmt
                     + (vnoise(px / (14.0 * k)) - 0.5) * 0.05 * paperAmt;
        float3 col = paper * mix(float3(1.0), inkA, mA * dA) * mix(float3(1.0), inkB, mB * dB);
        float fleck = step(0.9994, hash21(floor(px / (1.6 * k)) + 0.5)) * paperAmt;
        col = mix(col, col * inkB, fleck);
        return float4(col, 1.0);
    }

    case 48: { // GRAIN WASH — big soft-focus blur (spiral taps, noise-rotated), optional
               // Oklab color wash from shadows (A) to highlights (B), film halation, a static
               // paper texture (prints), then film grain sized per 1000 px of height.
               // p0 = (softness, grain, wash, halation), p1.x = paper
        float soft = u.p0.x, grainAmt = u.p0.y, tint = u.p0.z, halo = u.p0.w, paperAmt = u.p1.x;
        float k = res.y / 1000.0;
        float R = soft * soft * 0.11 * res.y;
        float3 c = base.rgb;
        if (R > 0.75) {
            const int N = 18;                // grain hides the undersampling
            // Rotation jitter shared by 2×2 pixel quads: keeps neighbouring taps on
            // nearby texels (texture-cache friendly) while still breaking up ghosting.
            float rot = (ign(floor(px * 0.5)) + 0.5) * 6.2831853;
            float3 sum = float3(0.0);
            for (int i = 0; i < N; ++i) {
                float fi = float(i) + 0.5;
                float r = sqrt(fi / float(N)) * R;
                float a = fi * 2.39996323 + rot;
                sum += src.sample(samp, uv + float2(cos(a), sin(a)) * r / res).rgb;
            }
            // Soft focus, not out of focus: keep part of the sharp image under the blur
            // and let the blurred highlights bloom over it (Orton-style halation).
            float3 blur = sum / float(N);
            float keep = 0.45 * smoothstep(0.75, 4.0, R) ;
            c = mix(blur, base.rgb, keep);
            float3 glow = blur * blur;
            c += glow * (1.0 - c) * 0.45 * soft;
        }
        if (halo > 0.0) {
            // Halation: light from a near-clipping source scatters back off the film base and
            // re-exposes the red (a little green) layer just around it — the warm ring round a
            // street lamp or a lit window at night. Only light past ~0.7 linear luminance
            // counts, and the halo is what the neighbourhood gathers minus what this pixel
            // already has, so it lands outside small bright sources while a large bright area
            // (snow, sky, sand, a sunlit petal) never lifts or tints itself. Never touches blue.
            float hr = 9.0 * k;
            float rot = (ign(floor(px * 0.5)) + 0.5) * 6.2831853;
            float3 sl = base.rgb * base.rgb;                       // ≈ linear light (cheap)
            float e0 = smoothstep(0.7, 1.0, dot(sl, float3(0.2126, 0.7152, 0.0722)));
            float hsum = 0.0, wsum = 0.0;
            for (int i = 0; i < 10; ++i) {
                float a = float(i) * 2.39996323 + rot;
                float rr = sqrt((float(i) + 0.5) / 10.0);
                float3 s = src.sample(samp, uv + float2(cos(a), sin(a)) * rr * hr / res).rgb;
                s *= s;
                float w = exp(-2.5 * rr * rr);                     // most of the glow close in
                hsum += w * smoothstep(0.7, 1.0, dot(s, float3(0.2126, 0.7152, 0.0722)));
                wsum += w;
            }
            float h = max(hsum / wsum - e0, 0.0);
            float3 lin = srgbToLinear(c) + float3(1.0, 0.30, 0.0) * h * halo * 5.0;
            c = linearToSrgb(lin);
        }
        float l = luma(c);
        float3 washed = oklabToSrgb(mix(srgbToOklab(u.colorA.rgb), srgbToOklab(u.colorB.rgb),
                                        smoothstep(0.02, 0.98, l)));
        c = mix(c, washed, tint);
        if (paperAmt > 0.0) {
            // A print, not a film frame: static paper — fine fibres laid mostly one way and a
            // slow mottle in how the pigment took — strongest in the light, unpigmented areas.
            float2 p = px / k;
            float fib = gnoise(float2(p.x * 0.35 + p.y * 0.12, p.y * 1.1) * 0.55) * 0.6
                      + (vnoise(p * 0.9 + 17.0) - 0.5) * 0.5;
            float mot = gnoise(p / 70.0 + 3.1) * 1.3;
            float paperL = smoothstep(0.25, 0.9, l);
            c *= 1.0 + paperAmt * (fib * mix(0.035, 0.07, paperL) + mot * mix(0.12, 0.04, paperL));
        }
        // Grain, strongest in the midtones: on an in-focus (film) image, clumps about 1.2 px
        // wide per 1000 px of height (per-pixel noise vanishes at 5K); over a soft-focus blur,
        // fine per-pixel grain (coarse clumps on a blurred picture read as noise, not film).
        // Grain already dithers away banding; without it, a static ±½ LSB dither does.
        float g = R > 0.75 ? filmGrain(px, t) : grainK(px, t, k);
        c += g * grainAmt * (0.35 + 2.6 * l * (1.0 - l));
        return float4(grainAmt > 0.0 ? c : c + bandDither(px), 1.0);
    }

    case 49: { // GLASS — the source seen through reeded glass, glass blocks or a flowing sheet
               // of hand-rolled glass. Each pixel takes 8 (Tiles 5, Liquid 4) stratified samples:
               // sub-pixel positions (so the reed seams and highlights are antialiased), the
               // frost blur, and per-channel dispersion that grows with the refraction angle.
               // Shading is in linear light: transmission loss at steep faces and grooves, plus
               // a soft window highlight. p0 = (style, size, refraction, frost)
        int style = int(u.p0.x + 0.5);
        float k = res.y / 1000.0;
        float S = max(u.p0.y * k, 4.0);
        float refr = u.p0.z, frost = u.p0.w;
        float2 jit = float2(hash21(px), hash21(px + 17.31));   // white jitter: no IGN diagonals
        float2 offC = float2(0.0);
        float specC = 0.0, shadeC = 0.0;
        if (style == 2) {
            // LIQUID: the surface varies over ~S, so one evaluation per pixel is plenty.
            float2 q = px / S;
            float ts = t * 0.07, e = 0.04;
            float h0 = liquidGlassHeight(q, ts);
            float hx = liquidGlassHeight(q + float2(e, 0.0), ts);
            float hy = liquidGlassHeight(q + float2(0.0, e), ts);
            float2 g = float2(hx - h0, hy - h0) / e;              // surface slope
            offC = -g * refr * S * 0.3;
            // Light: a sharp glint where a ripple faces the window (a reflection, so it
            // tracks the surface, not the photo), and caustics — the glass gathers light
            // under convex swells and spreads it under hollows, so brightness follows the
            // focusing (never a milky veil laid on top).
            float3 n = normalize(float3(-g * 0.35, 1.0));
            // The window's reflection: a small, hard-edged light (~2° across), so the glint is
            // a crisp streak on a ripple's flank, never a soft smear over gently tilted glass.
            float ndl = dot(n, normalize(float3(-0.22, -0.30, 0.93)));
            float glint = smoothstep(0.99970, 0.99988, ndl);
            float hxx = liquidGlassHeight(q - float2(e, 0.0), ts);
            float hyy = liquidGlassHeight(q - float2(0.0, e), ts);
            float curv = (hx + hxx + hy + hyy - 4.0 * h0) / (e * e);   // < 0 on crests
            specC = glint * 0.12;
            shadeC = clamp(curv * 0.035, -0.10, 0.10);              // < 0 brightens (focus)
        }
        float disp = 0.025 + frost * 0.05;
        int NT = style == 0 ? 8 : (style == 1 ? 5 : 4);   // reed seams need the most AA
        int m1 = NT == 8 ? 5 : (NT == 5 ? 2 : 3);           // multipliers coprime with NT
        float3 acc = float3(0.0);
        float spec = 0.0, shade = 0.0;
        for (int j = 0; j < NT; ++j) {
            // Latin-hypercube strata: sub-pixel x, sub-pixel y and the blur position each
            // use a different permutation of j, so they never line up into a pattern.
            float a = (float(j) + jit.x) / float(NT);
            float b = (float((j * m1 + 3) % NT) + jit.y) / float(NT);
            float cpos = (float((j * 3 + 1) % NT) + fract(jit.x + jit.y)) / float(NT);
            float2 sp = px + float2(a, b) - 0.5;
            float2 off = offC, blur;
            float sh = shadeC, spc = specC;
            if (style == 0) {
                // FLUTED: vertical half-round reeds (a ~50° arc). Seen from a distance the
                // scene behind lies past each reed's focus, so a reed shows it mirrored and
                // squeezed — the slices that make reeded glass read as glass.
                float f = fract(sp.x / S) - 0.5;
                float sn = 1.54 * f;                                  // sin of the surface angle
                // Deviation ∝ tan of the surface angle, capped where the reed turns steep
                // at its edges (no spikes). Refraction is a saturating curve, 2r / (1 + 5r):
                // the 0.2 the Fluted Glass look is tuned on stays put, while 0.5 (the
                // default) and 1.0 bend at most ~2 and ~2.4 reed widths, so any setting still
                // reads as the photo through glass rather than as slivers.
                float tn = clamp(sn * rsqrt(1.0 - sn * sn), -1.0, 1.0);
                float rf = 2.0 * refr / (1.0 + 5.0 * refr);
                off = float2(-tn * rf * S * 6.0, 0.0);
                // Window light to the upper left: one soft highlight down each reed where it
                // faces the light, a faint sheen around it, and a dark line in each groove.
                spc = 0.10 * exp(-(sn + 0.30) * (sn + 0.30) * 81.0) + 0.018 * exp(-(sn + 0.30) * (sn + 0.30) * 4.84);
                spc *= 0.75 + 0.25 * (1.0 - uv.y);
                sh = 0.08 * sn * sn + 0.20 * smoothstep(0.42, 0.5, abs(f));
                // Behind fluted glass things blur sideways, barely up and down.
                blur = float2((cpos - 0.5) * frost * S * 3.2, (b - 0.5) * frost * S * 0.2);
            } else if (style == 1) {
                // TILES: glass blocks — flat, faintly wavy faces that bend sharply into
                // rounded edges, with a thin dark joint between blocks.
                float2 f = fract(sp / S) - 0.5;
                float2 f2 = 2.0 * f;
                float2 sn = f2 * f2 * f2 * 0.80 + 0.035 * sin(f2 * 9.42478 + float2(0.0, 1.3));
                float2 tn = sn * rsqrt(1.0 - sn * sn);
                off = -tn * refr * S * 0.9;
                float e = max(abs(f.x), abs(f.y));
                spc = 0.07 * exp(-dot(sn + float2(0.45, 0.50), sn + float2(0.45, 0.50)) * 18.0)
                    + 0.015 * exp(-dot(sn, sn) * 2.0);
                sh = 0.08 * dot(sn, sn) + 0.30 * smoothstep(0.47, 0.5, e);
                float ang = cpos * 6.2831853;
                blur = float2(cos(ang), sin(ang)) * sqrt(b) * frost * S * 0.30;
            } else {
                float ang = cpos * 6.2831853;
                blur = float2(cos(ang), sin(ang)) * sqrt(b) * frost * S * 0.14;
            }
            // Dispersion: red bends least, blue most, in proportion to the deviation.
            float2 o = sp + blur;
            acc.r += src.sample(samp, (o + off * (1.0 - disp)) / res).r;
            acc.g += src.sample(samp, (o + off) / res).g;
            acc.b += src.sample(samp, (o + off * (1.0 + disp)) / res).b;
            spec += spc; shade += sh;
        }
        float inv = 1.0 / float(NT);
        float3 lin = acc * inv;
        lin *= lin;                                       // ≈ linear light (gamma 2: cheap at 5K)
        lin = lin * (1.0 - clamp(shade * inv, -0.2, 1.0)) * float3(0.955, 0.975, 0.965);   // faint green glass body
        // Tiles and Liquid: highlights read as light on the glass where there is light behind
        // it; over a dark background (a night sky, shadowed foliage) they stay a faint sheen,
        // never grey smoke or grey blocks.
        if (style != 0) spec *= mix(0.15, 1.0, smoothstep(0.01, 0.2, dot(lin, float3(0.2126, 0.7152, 0.0722))));
        lin += spec * inv;
        return float4(sqrt(lin) + bandDither(px), 1.0);
    }

    case 38: { // BLIT — crisp nearest upscale of a precomputed dither grid. p0 = (grid W, H,
               // cell px): whole-pixel cells, so every dot is the same size (no beat pattern).
        float2 gridSize = u.p0.xy;
        if (u.p0.z >= 1.0) {
            uint2 g = uint2(min(floor(px / u.p0.z), gridSize - 1.0));
            return float4(src.read(g).rgb, 1.0);
        }
        float2 g = (floor(uv * gridSize) + 0.5) / gridSize;
        return src.sample(samp, g);
    }

    // ---- scene packs (ids 50–66), one file each
#include "Scenes/Clocks_cases.h"
#include "Scenes/Flowing_cases.h"
#include "Scenes/Nature_cases.h"
#include "Scenes/Retro_cases.h"
#include "Scenes/Music_cases.h"
#include "Scenes/Studio1_cases.h"
#include "Scenes/Studio2_cases.h"
#include "Scenes/Studio3_cases.h"
#include "Scenes/Studio4_cases.h"
#include "Scenes/Studio5_cases.h"
#include "Scenes/Studio6_cases.h"
#include "Scenes/Standby_cases.h"
#include "Scenes/Meadow_cases.h"
#include "Scenes/Bloom_cases.h"
#include "Scenes/Penguin_cases.h"

    case 41: { // INTERNAL crossfade — set by the renderer during preset rotation,
               // never by an EffectInstance. src = incoming frame, fadePrev = outgoing.
        float k = smoothstep(0.0, 1.0, u.p0.x);
        return float4(mix(fadePrev.sample(samp, uv).rgb, base.rgb, k), 1.0);
    }

    default:
        return base;
    }
