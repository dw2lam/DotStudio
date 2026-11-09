//  Nature_funcs.h — file-scope Metal helpers for the Nature pack. Included by Shaders.metal
//  right above fx_fragment (shared helpers such as gfbm, luma, bandDither are visible).
//  Prefix every function/constant with "nature_" so packs can't collide.
//
//  Everything here works in LINEAR light and is tone-mapped once at the end
//  (nature_display), so sky gradients, glows and reflections add up like light does.

// ---------------------------------------------------------------- shared

constant float NATURE_PI = 3.14159265;
// Rayleigh optical depth at zenith, at the sRGB primaries' dominant wavelengths (~610/550/465 nm).
constant float3 NATURE_RAYLEIGH = float3(0.056, 0.115, 0.245);

// Integer hash of an integer lattice coordinate → [0,1). Stable at large arguments
// (fract(sin) is not under fast-math).
static inline float nature_h1(float x) {
    uint n = uint(int(floor(x)) + 0x20000);
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x00ffffffu) * (1.0 / 16777216.0);
}
// Smooth 1D value noise in [0,1].
static inline float nature_n1(float x) {
    float i = floor(x), f = x - i;
    f = f * f * (3.0 - 2.0 * f);
    return mix(nature_h1(i), nature_h1(i + 1.0), f);
}
// Exposure → soft filmic shoulder (per channel, so very bright light bleaches toward
// white like film/sensor) → display sRGB. Near black it is the identity, so a dark
// colour picked by the user comes back out as itself.
static inline float3 nature_display(float3 lin, float2 px) {
    float3 c = 1.0 - exp(-max(lin, 0.0));
    return linearToSrgb(c) + bandDither(px) * 1.5;
}
// Inverse of the shoulder, for "this display colour, as scene light".
static inline float3 nature_lin(float3 srgb) {
    float3 c = min(srgbToLinear(srgb), 0.98);
    return -log(1.0 - c);
}
static inline float nature_schlick(float cosI) {
    float m = clamp(1.0 - cosI, 0.0, 1.0);
    float m2 = m * m;
    return 0.02 + 0.98 * m2 * m2 * m;
}

// Point-sprite starfield in (azimuth, sin elevation) — an equal-area map, so density is
// uniform over the sky. Stars are ~1–2.5 px Gaussians whatever the output size;
// brightness follows a steep power law (many faint, a few bright), tints from cool
// blue-white to warm orange. `pix` = radians per pixel.
static inline float3 nature_stars(float3 rd, float pix, float amount, float t, float seed, int NL = 3) {
    float az = atan2(rd.x, rd.z);
    float ce = max(sqrt(max(1.0 - rd.y * rd.y, 0.0)), 0.05);
    float3 acc = float3(0.0);
    // Below ~1000 px tall (a thumbnail) the sky is shown as a downscale would show it: the
    // fine layers fade out and the rest dim, instead of a snowstorm of 1 px dots.
    float ratio = max(pix * (1000.0 * 1.3 / 2.0), 1.0);            // = 1000 / frame height
    float dimR = ratio > 1.0 ? pow(ratio, -1.6) : 1.0;
    float lod1 = smoothstep(3.0, 1.5, ratio) * dimR, lod2 = smoothstep(2.0, 1.1, ratio) * dimR;
    for (int L = 0; L < NL; ++L) {
        float sc = L == 0 ? 70.0 : (L == 1 ? 150.0 : 330.0);       // cells per radian
        float lodF = L == 0 ? dimR : (L == 1 ? lod1 : lod2);
        if (lodF <= 0.0) continue;
        float2 g = float2(az, rd.y) * sc;
        float2 cell = floor(g);
        // Few cells hold a star (and most pixels are far from it): skip the rest early,
        // on a cheap integer hash.
        uint hh = (uint(int(cell.x) + 65536) * 0x8da6b343u) ^ (uint(int(cell.y) + 65536) * 0xd8163841u)
                ^ (uint(seed + float(L) * 17.0) * 0xcb1ab31fu);
        hh = (hh ^ (hh >> 15u)) * 0x2c1b3c6du; hh ^= hh >> 13u;
        if (float(hh >> 22u) * (1.0 / 1024.0) < (L == 0 ? 0.80 : (L == 1 ? 0.72 : 0.62))) continue;
        float2 hxy = float2(float((hh >> 11u) & 2047u), float(hh & 2047u)) * (1.0 / 2048.0);
        float2 off = (g - cell) - (0.2 + 0.6 * hxy);
        float2 dAng = float2(off.x * ce, off.y / ce) / sc;          // radians on the sky
        float r = length(dAng) / pix;                                // pixels
        if (r > 4.0) continue;
        float3 h2 = pcg3(float3(cell + 913.0, seed + 5.0));
        // Magnitude follows a steep power law.
        float m = h2.x;
        float b = L == 0 ? 0.7 * pow(m, 6.0) + 0.025 : (L == 1 ? 0.08 * pow(m, 4.0) + 0.008 : 0.012 * m + 0.002);
        float sig = 0.5 + 0.55 * sqrt(min(b, 1.0));
        float tw = 1.0 + 0.35 * sin(t * (2.0 + 5.0 * h2.y) + h2.y * 50.0) * smoothstep(0.35, 0.0, rd.y);
        float3 tint = mix(float3(0.62, 0.74, 1.0), float3(1.0, 0.72, 0.45), h2.z * h2.z);
        tint = mix(tint, float3(1.0), 0.35);
        acc += tint * b * tw * exp(-r * r / (2.0 * sig * sig)) * lodF;
    }
    return acc * amount;
}

// ---------------------------------------------------------------- aurora (case 43)
//
// A camera stands on a lake shore looking north. Each curtain is a thin vertical sheet of
// light standing on a meandering line on the ground plane, 150–520 km away, its lower
// hem at ~100 km altitude. A pixel's ray is followed in top view: wherever its
// horizontal track crosses a sheet, the hit altitude follows exactly from the ray's
// elevation (with Earth curvature), and the light it collects scales with the path
// length through the sheet — so folds seen edge-on blaze, and the striations (which
// live along the sheet, constant with height) are true field-aligned rays that
// converge toward the zenith in perspective. Green oxygen light at the hem gives way
// to red/magenta above ~200 km and a pink nitrogen fringe below.

struct NatureAuroraP {
    float ts;        // animation clock (speed applied)
    float height;    // curtain vertical extent multiplier
    float act;       // activity 0..1 (fold amplitude, fringe, ray motion)
    float inten;     // glow
    float stars;
    float pix;       // radians per pixel
    float t;         // raw time (twinkle)
    float soft;      // extra hem softness, km (ripple-blurred reflections)
    float3 sky;      // linear zenith colour
    float3 cG;       // linear green (curtain base) colour
    float3 cTop;     // linear high-altitude colour
    float3 cPink;    // linear lower fringe colour
};

static inline float nature_fold(float x, float k, float ts, thread float &d) {
    float a1 = x * 0.0105 + k * 2.1 + ts * 0.020;
    float a2 = x * 0.0315 - k * 1.3 - ts * 0.034;
    float a3 = x * 0.0630 + k * 4.7 + ts * 0.052;
    d = 0.55 * 0.0105 * cos(a1) + 0.30 * 0.0315 * cos(a2) + 0.15 * 0.0630 * cos(a3);
    return 0.55 * sin(a1) + 0.30 * sin(a2) + 0.15 * sin(a3);
}
// Small curls (~20–40 km) on top of the big folds; only used to refine a found crossing.
static inline float nature_curl(float x, float k, float ts, thread float &d) {
    float a4 = x * 0.170 + k * 1.7 + ts * 0.11;
    float a5 = x * 0.290 - k * 3.1 - ts * 0.17;
    d = 0.050 * 0.170 * cos(a4) + 0.025 * 0.290 * cos(a5);
    return 0.050 * sin(a4) + 0.025 * sin(a5);
}

// Emission collected where the ray crosses curtain k at along-sheet coordinate x,
// altitude alt (km). Returns linear radiance before the path-length factor. fx = the
// pixel's footprint along the sheet (km): where a fold is seen nearly edge-on it spans
// many rays, so the finer ray octaves fade to their mean instead of aliasing into moiré.
static inline float3 nature_curtainLight(float x, float alt, float k, constant FXUniforms& u,
                                         NatureAuroraP P, float fx) {
    float ts = P.ts;
    // Brightness gathers in patches along the sheet, breathing slowly.
    float patch = smoothstep(0.18, 0.78, nature_n1(x * 0.011 + k * 13.0 - ts * 0.022));
    if (patch <= 0.0) return float3(0.0);
    patch *= 0.75 + 0.25 * sin(ts * 0.21 + x * 0.004 + k * 2.0);
    float hb = 96.0 + 5.0 * sin(x * 0.021 + k * 7.3 + ts * 0.01) + 3.0 * sin(x * 0.067 - k * 2.1);  // lower hem
    float dy = alt - hb;
    // Light scattered in the air around the sheet: a soft halo, also below the hem.
    float3 halo = P.cG * exp(dy < 10.0 ? (dy - 10.0) / 10.0 : (10.0 - dy) / 45.0) * 0.07;
    if (dy < -10.0) return halo * patch;
    // Field-aligned rays: three octaves of 1D noise along the sheet, drifting sideways.
    float drift = ts * (0.35 + 0.5 * P.act);
    float r1 = mix(nature_n1(x * 0.32 + drift + k * 31.0), 0.5, smoothstep(0.25, 0.6, fx * 0.32));
    float r2 = mix(nature_n1(x * 0.95 - drift * 1.6 + k * 17.0), 0.5, smoothstep(0.25, 0.6, fx * 0.95));
    float r3 = mix(nature_n1(x * 0.085 + drift * 0.3 + k * 5.0), 0.5, smoothstep(0.25, 0.6, fx * 0.085));
    float q = 0.5 * r1 + 0.32 * r2 + 0.18 * r3;
    float ray = 0.30 + 1.6 * q * q * q;
    // Broad brightness swells along the sheet (tens of km), under the fine rays.
    float swell = 1.0 + 0.4 * sin(x * 0.11 - drift * 0.5 + k * 3.0) + 0.25 * sin(x * 0.043 + k);
    // Rays reach different heights: a ragged, picket-fence top.
    float rh = r3 * (0.55 + 0.45 * r1);
    float Ht = 40.0 * P.height * (0.3 + 1.4 * rh * rh);
    float edge = smoothstep(-1.4 - P.soft, 0.8 + P.soft, dy);
    float dp = max(dy, 0.0);
    float g = edge * (0.75 * exp(-dp / (7.0 + 5.0 * r2)) + 0.4 * exp(-dp / Ht));
    float red = smoothstep(40.0, 150.0, dy) * exp(-max(dy - 110.0, 0.0) / (60.0 * P.height)) * 0.14;
    red *= 0.25 + 1.5 * rh;
    float pink = exp(-((dy - 0.5) * (dy - 0.5)) / 5.0) * smoothstep(0.3, 1.0, P.act) * smoothstep(0.45, 0.9, patch) * 0.3;
    // The hem glows fairly evenly; striations sharpen with height.
    float rr = mix(0.6 + 0.4 * ray, ray, smoothstep(2.0, 30.0, dy)) * swell;
    return ((P.cG * g + P.cTop * red + P.cPink * pink) * rr + halo) * patch;
}

static inline float3 nature_curtains(float3 rd, constant FXUniforms& u, NatureAuroraP P) {
    float hl = length(rd.xz);
    float2 d2 = rd.xz / hl;
    if (d2.y < 0.06 || rd.y < -0.01) return float3(0.0);
    float tanE = rd.y / hl;
    float cosE = hl;
    float3 acc = float3(0.0);
    for (int k = 0; k < 3; ++k) {
        float fk = float(k);
        // Each sheet stands on z = Z − tilt·x + A·fold(x): tilted lines recede to the
        // horizon on one side and sweep overhead on the other, like real arcs.
        float Z = (k == 0 ? 280.0 : (k == 1 ? 440.0 : 680.0)) + 25.0 * sin(P.ts * 0.013 + fk * 2.0);
        float tilt = (k == 0 ? 0.42 : (k == 1 ? -0.28 : 0.12)) + 0.18 * sin(P.ts * 0.007 + fk * 2.4);
        float A = (40.0 + 16.0 * fk) * (0.5 + P.act);
        float D = d2.y + tilt * d2.x;
        if (D < 0.03) continue;
        float s0 = max((Z - A) / D, 5.0);
        float s1 = min((Z + A) / D, 2200.0);
        if (s1 <= s0) continue;
        // Steps scale with how much fold the bracket spans (few near the centre column).
        int N = int(clamp(ceil((s1 - s0) * abs(d2.x) / 24.0), 2.0, 7.0));
        float ds = (s1 - s0) / float(N);
        // Cull sheets this ray passes entirely above or below.
        float a0 = s0 * tanE - s0 * s0 * (1.0 / 12742.0);
        float a1 = s1 * tanE - s1 * s1 * (1.0 / 12742.0);
        float sm = clamp(tanE * 6371.0, s0, s1);
        float amax = max(max(a0, a1), sm * tanE - sm * sm * (1.0 / 12742.0));
        if (amax < 35.0 || min(a0, a1) > 120.0 + 330.0 * P.height) continue;
        // March the fold by rotating its three phasors (no trig inside the loop).
        float x0 = s0 * d2.x, dx = ds * d2.x;
        // Fold frequencies are locked at 1 : 3 : 6, so every phasor and step rotation is a
        // power of the first one (complex products instead of trig).
        float c1 = fk * 2.1 + P.ts * 0.020, c2 = -fk * 1.3 - P.ts * 0.034, c3 = fk * 4.7 + P.ts * 0.052;
        float ph1 = x0 * 0.0105 + c1;
        float2 z1 = float2(cos(ph1), sin(ph1));
        float2 e1 = float2(z1.x * z1.x - z1.y * z1.y, 2.0 * z1.x * z1.y);            // z1²
        float2 e3 = float2(e1.x * z1.x - e1.y * z1.y, e1.x * z1.y + e1.y * z1.x);    // z1³
        float2 e6 = float2(e3.x * e3.x - e3.y * e3.y, 2.0 * e3.x * e3.y);            // z1⁶
        float o2a = c2 - 3.0 * c1, o3a = c3 - 6.0 * c1;
        float2 o2 = float2(cos(o2a), sin(o2a)), o3 = float2(cos(o3a), sin(o3a));
        float2 z2 = float2(e3.x * o2.x - e3.y * o2.y, e3.x * o2.y + e3.y * o2.x);
        float2 z3 = float2(e6.x * o3.x - e6.y * o3.y, e6.x * o3.y + e6.y * o3.x);
        float2 r1 = float2(cos(dx * 0.0105), sin(dx * 0.0105));
        float2 r1s = float2(r1.x * r1.x - r1.y * r1.y, 2.0 * r1.x * r1.y);
        float2 r2 = float2(r1s.x * r1.x - r1s.y * r1.y, r1s.x * r1.y + r1s.y * r1.x);
        float2 r3 = float2(r2.x * r2.x - r2.y * r2.y, 2.0 * r2.x * r2.y);
        float gp = s0 * D - Z - A * (0.55 * z1.y + 0.30 * z2.y + 0.15 * z3.y);
        float3 ck = float3(0.0);
        for (int i = 1; i <= N; ++i) {
            float s = s0 + ds * float(i);
            float2 q1 = z1, q2 = z2, q3 = z3;
            z1 = float2(z1.x * r1.x - z1.y * r1.y, z1.y * r1.x + z1.x * r1.y);
            z2 = float2(z2.x * r2.x - z2.y * r2.y, z2.y * r2.x + z2.x * r2.y);
            z3 = float2(z3.x * r3.x - z3.y * r3.y, z3.y * r3.x + z3.x * r3.y);
            float g = s * D - Z - A * (0.55 * z1.y + 0.30 * z2.y + 0.15 * z3.y);
            if (g * gp <= 0.0) {
                float f = gp / (gp - g);
                float sc = s - ds + ds * f;
                // One Newton step on the full sheet (big folds + curls). The big folds come
                // from the marched phasors, interpolated to the crossing (no extra trig).
                float2 w1 = normalize(mix(q1, z1, f)), w2 = normalize(mix(q2, z2, f)), w3 = normalize(mix(q3, z3, f));
                float fd = 0.55 * 0.0105 * w1.x + 0.30 * 0.0315 * w2.x + 0.15 * 0.0630 * w3.x;
                float cd, x = sc * d2.x;
                float fz = 0.55 * w1.y + 0.30 * w2.y + 0.15 * w3.y + nature_curl(x, fk, P.ts, cd);
                float dg = D - A * (fd + cd) * d2.x;
                sc -= (sc * D - Z - A * fz) / (abs(dg) > 0.05 ? dg : (dg < 0.0 ? -0.05 : 0.05));
                sc = clamp(sc, s - ds * 1.5, s + ds * 0.5);
                x = sc * d2.x;
                float sl = tilt - A * (fd + cd);
                // |cos| between the ray and the sheet's horizontal normal (sl, 1) → path length.
                float isl = rsqrt(1.0 + sl * sl);
                float cosH = abs(d2.x * sl + d2.y) * isl;           // in top view
                float cosT = cosH * cosE;
                // Edge-on folds blaze, but a real sheet has thickness: right at the tangent
                // the two crossings merge and the light falls off smoothly, not as a 1 px
                // hard edge (which aliased into dotted diagonal lines).
                float path = smoothstep(0.0, 0.13, cosT) / max(cosT, 0.11);
                float alt = sc * tanE - sc * sc * (1.0 / 12742.0);   // Earth curvature drop
                float fx = P.pix * sc * isl / max(cosT, 0.02);       // the pixel's footprint in x, km
                if (alt > 40.0 && alt < 140.0 + 300.0 * P.height)    // skip crossings that see nothing
                    ck += nature_curtainLight(x, alt, fk, u, P, fx) * path;
            }
            gp = g;
        }
        acc += ck * (k == 0 ? 1.0 : (k == 1 ? 0.8 : 0.62));
    }
    return acc;
}

// Landscape silhouettes in (azimuth, elevation) radians. Returns coverage of the far
// snow-capped range (x), the near forested hills + spruce skyline (y), and a 0..1 height
// within the far range (z) for snow lighting.
static inline float3 nature_auroraLand(float az, float e, float pix) {
    if (e > 0.10) return float3(0.0);
    // Far range, ~40 km off: ridged noise for sharp peaks, gathered into a massif.
    float massif = 0.25 + 0.75 * smoothstep(-0.7, 0.8, sin(az * 2.1 + 1.1));
    float mElev = 1.0, mtn = 0.0;
    if (e < 0.010 + 0.110 * massif + pix) {                 // (no peak can reach higher: n² ≤ 1.44)
        float x = az * 7.0 + 3.0;
        float m = 0.0, a = 0.5, f = 1.0;
        for (int i = 0; i < 4; ++i) {
            float n = 1.0 - abs(gnoise(float2(x * f, 1.7 + float(i) * 3.1)) * 2.2);
            m += a * n * n; a *= 0.47; f *= 2.13;
        }
        mElev = 0.010 + 0.085 * m * massif;
        mtn = smoothstep(mElev + pix, mElev - pix, e);
    }
    // Near hills a few km off, rolling, forested.
    float hill = 0.006 + 0.020 * nature_n1(az * 9.0 + 4.0) * nature_n1(az * 3.0 + 1.3) + 0.004 * nature_n1(az * 40.0);
    float forest = smoothstep(hill + pix, hill - pix, e);
    // Spruce skyline on the hills: tiered cones, clustered with clearings.
    const float tw = 0.0065;
    float ci = floor(az / tw);
    for (int j = -1; j <= 1; ++j) {
        float id = ci + float(j);
        float dens = smoothstep(0.25, 0.6, nature_n1(id * 0.05 + 3.0));
        if (nature_h1(id * 1.37 + 11.0) < 0.1 + 0.85 * (1.0 - dens)) continue;
        float pxc = (id + 0.5 + (nature_h1(id + 5.0) - 0.5) * 0.7) * tw;
        float base = 0.006 + 0.020 * nature_n1(pxc * 9.0 + 4.0) * nature_n1(pxc * 3.0 + 1.3) - 0.002;
        float H = (0.010 + 0.016 * nature_h1(id + 77.0)) * (0.65 + 0.5 * dens);
        float y = e - base;
        float rel = clamp(1.0 - y / H, 0.0, 1.0);
        float tier = fract((H - y) / (H * 0.12) + nature_h1(id + 9.0));
        float hw = H * 0.24 * rel * (0.55 + 0.45 * tier) + pix * 0.4;
        float dx = abs(az - pxc);
        float cov = smoothstep(hw + pix, hw - pix, dx) * step(y, H);
        forest = max(forest, cov);
    }
    return float3(mtn, forest, clamp(e / max(mElev, 1e-3), 0.0, 1.0));
}

// Full radiance arriving along rd above the water: sky glow, stars, curtains, land.
static inline float3 nature_auroraView(float3 rd, constant FXUniforms& u, NatureAuroraP P) {
    float e = asin(clamp(rd.y, -1.0, 1.0));
    float az = atan2(rd.x, rd.z);
    float3 land = nature_auroraLand(az, e, P.pix);

    // Night sky: zenith colour, brightening toward the horizon (longer airmass), with a
    // faint airglow band and light scattered from the aurora into the lower sky.
    float he = max(e, 0.0);
    float3 col = P.sky * (1.0 + 5.5 * exp(-he * 11.0));
    col += P.cG * 0.010 * exp(-he * 10.0) * P.inten;
    float ext = exp(-0.10 / (max(rd.y, 0.0) + 0.035));             // atmospheric extinction

    if (land.x < 0.999 && land.y < 0.999) {
        float3 sky = float3(0.0);
        sky += nature_stars(rd, P.pix, P.stars, P.t, 3.0, P.soft > 0.0 ? 1 : 3) * ext;
        float3 aur = nature_curtains(rd, u, P) * P.inten * 0.3;
        sky += aur * mix(0.55, 1.0, ext);
        col += sky;
    }
    // Mountains: hazy blue-black, snowfields catching the green light from above.
    if (land.x > 0.0 && land.y < 1.0) {
        float snow = smoothstep(0.5, 0.75, land.z + 0.25 * (gnoise(float2(az * 160.0, e * 90.0)) + gnoise(float2(az * 420.0, e * 300.0)) * 0.5));
        float3 mcol = P.sky * (0.45 + 1.3 * snow) + P.cG * 0.006 * P.inten * snow;
        mcol = mix(mcol, col, 0.1);
        col = mix(col, mcol, land.x);
    }
    float3 fcol = P.sky * 0.10;
    col = mix(col, fcol, land.y);
    return col;
}

// ---------------------------------------------------------------- ocean horizon (case 59)
//
// Sky: single scattering through an exponential atmosphere (Rayleigh + Mie + ozone),
// sunlight reddened by the real airmass at the sun's elevation (Kasten–Young), so the
// palette comes out of the physics: orange horizon, ozone-blue zenith, warm sun glow.
// Clouds: a lit altocumulus deck at 2.5 km plus high cirrus. Sea: 21 dispersion-correct
// wave trains (swell to 6 cm wind ripples), each filtered by the pixel's footprint on the
// water; what a pixel can't resolve is folded into a microfacet slope variance (LEAN /
// Beckmann), which is what turns the sun's reflection into a long glitter column near the
// horizon and sharp glints near the camera — and keeps the far sea from aliasing.
// Follow the Sun (live) adds the real sun and moon, twilight and night; see nature_ocean.

struct NatureOceanP {
    float3 sd;       // unit sun direction
    float se;        // sun elevation, radians
    float3 esun;     // sun irradiance (linear, tinted)
    float3 tauS;     // scattering optical depth at zenith (Rayleigh + Mie)
    float3 tauT;     // total (with ozone)
    float mie;       // Mie share of scattering optical depth
    float clouds;
    float tc;        // cloud clock
    float pix;
    float ms;        // multiple-scattering skylight scale (≈ |esun|; live: fades with the twilight)
    float amb;       // cloud ambient scale (|esun|; live: twilight + moonlight)
    bool live;       // Follow the Sun
    float tw;        // live: twilight glow scale (0 unless the sun is 2°…18° down)
    float2 sh;       // live: the sun's horizontal direction (the key light may be the moon)
    // Weather (the wx copies only; Shared/Weather/Weather_funcs.h). Unused fields cost nothing.
    float deck;      // stratus deck over the sky 0…1 (overcast)
    float hb;        // the cloud layer's height, km (2.5 = the scene's altocumulus; a deck is lower)
    float dx;        // how far out the deck reaches, km (beyond it, the clear gap at the horizon)
    float3 lb;       // radiance of the deck's base (diffuse light through it)
    float3 aur;      // forward-scattered glow through the deck toward the sun (× phase)
    float cdark;     // the deck's contrast: thick, dark cores (storm billows)
    float3 flash;    // lightning: light added inside the cloud (envelope × colour)
    float3 fd;       // … from this direction
    float3 eglow;    // light the deck's underside catches near its edge, from the clear gap
};

// Follow the Sun state. Derived from the uniforms where it is needed rather than carried in
// NatureOceanP: the sea and sky are register-bound, and the manual mode must not pay for it.
static inline bool nature_live(constant FXUniforms& u) { return u.p1.y > 0.5 && u.sky.y > 0.5; }
static inline float nature_liveDD(constant FXUniforms& u) { return -u.sun.x * 57.29578; }   // sun depression, °
// Sunlight tint: the warm one the user picked at a low sun, relaxing toward white daylight as
// the sun climbs (sunlight above the air is white; the warmth is the low sun's).
static inline float3 nature_liveTint(constant FXUniforms& u) {
    float3 tint = srgbToLinear(u.colorB.rgb);
    return mix(tint, float3(luma(tint)) * float3(0.98, 1.0, 1.03), 0.9 * smoothstep(0.06, 0.4, u.sun.x));
}
// Skylight after sunset: the blue hour fades ~e× per 2.3° of depression.
static inline float nature_liveFall(float dd) { return exp(-max(dd - 0.5, 0.0) / 2.3); }
// Moonlight as the night's key light: the real phase (≈ opposition surge), fading in once the
// sun's own light has left even the cirrus (5° down), so nothing pops at the hand-over.
static inline float3 nature_liveMoonE(constant FXUniforms& u, float dd) {
    if (dd <= 5.0) return float3(0.0);
    float illum = 0.5 - 0.5 * cos(u.moon.w);
    float pf = illum * (0.35 + 0.65 * illum);
    return float3(0.62, 0.80, 1.0) * 9.5 * 0.0042 * pf * smoothstep(5.0, 10.0, dd);
}

// Fast sine of a phase in turns (≈2e-3 error): a corrected parabola per half period. The 21
// wave trains below were mostly sin/cos — this halves their cost, with no visible change.
static inline float nature_sinT(float x) {
    float y = x - floor(x + 0.5);                       // [-0.5, 0.5)
    float a = 8.0 * y - 16.0 * y * abs(y);
    return 0.225 * (a * abs(a) - a) + a;
}
static inline float nature_sincosT(float x, thread float &c) {
    c = nature_sinT(x + 0.25);
    return nature_sinT(x);
}

// Ocean wave trains: (direction toward the camera ± spread, phase, wavelength m), from
// 80 m swell down to 0.5 m (ratio 0.73), then four wind ripples down to 6 cm (ratio 0.53),
// spread wider and riding the swells.
constant float4 NATURE_WAVES[21] = {
    float4(0.00807, -0.99997, 6.10883, 80.00000), float4(0.96510, -0.26189, 4.07102, 58.40000),
    float4(-0.16502, -0.98629, 1.39632, 42.63200), float4(-0.56280, -0.82659, 5.88731, 31.12136),
    float4(-0.52702, -0.84985, 0.80283, 22.71859), float4(-0.21676, -0.97622, 5.53007, 16.58457),
    float4(0.48458, -0.87475, 5.48773, 12.10674), float4(0.32469, -0.94582, 2.09701, 8.83792),
    float4(0.53841, -0.84269, 6.00753, 6.45168), float4(0.83512, -0.55007, 5.19055, 4.70973),
    float4(-0.55720, -0.83038, 5.68147, 3.43810), float4(-0.94312, -0.33245, 5.66172, 2.50981),
    float4(-0.94794, -0.31846, 1.93828, 1.83216), float4(-0.25430, -0.96713, 5.55347, 1.33748),
    float4(0.82914, -0.55904, 5.75483, 0.97636), float4(0.27277, -0.96208, 2.29456, 0.71274),
    float4(0.00787, -0.99997, 1.99348, 0.52030),
    float4(-0.47533, -0.87981, 3.51715, 0.37982), float4(0.50720, -0.86183, 3.21642, 0.20241),
    float4(-0.32492, -0.94574, 4.98242, 0.10786), float4(0.28481, -0.95858, 0.26314, 0.05748)
};
// (wavenumber k = 2π/λ, angular frequency ω = √(gk + (σ/ρ)k³): gravity waves, capillaries)
constant float2 NATURE_WAVEK[21] = {
    float2(0.07854, 0.87777), float2(0.10759, 1.02735), float2(0.14738, 1.20242), float2(0.20189, 1.40733),
    float2(0.27657, 1.64715), float2(0.37886, 1.92785), float2(0.51898, 2.25638), float2(0.71093, 2.64089),
    float2(0.97388, 3.09093), float2(1.33409, 3.61767), float2(1.82752, 4.23419), float2(2.50345, 4.95580),
    float2(3.42938, 5.80044), float2(4.69778, 6.78917), float2(6.43532, 7.94669), float2(8.81550, 9.30215),
    float2(12.07603, 10.89011), float2(16.54250, 12.75196), float2(31.04242, 17.51313), float2(58.25186, 24.20496),
    float2(109.31106, 34.17148)
};

static inline float nature_airmass(float e) {
    float ec = max(e, -0.025);
    return 1.0 / (sin(ec) + 0.50572 * pow(max(ec * 57.29578 + 6.07995, 0.5), -1.6364));
}
static inline float nature_hg(float c, float g) {
    float r = rsqrt(1.0 + g * g - 2.0 * g * c);
    return (1.0 - g * g) / (4.0 * NATURE_PI) * r * r * r;
}

// Sunlight reaching altitude h km: the sun sits higher above that point's own horizon
// (dip ≈ √(2h/R)) and the path runs through thinner air (× e^(−h/8)). This is what keeps
// clouds glowing pink and red for a while after the sun has set at sea level.
static inline float3 nature_sunAt(NatureOceanP P, float h, constant FXUniforms& u) {
    float dip = sqrt(2.0 * h / 6371.0);
    float se = P.se + dip;
    float vis = smoothstep(P.live ? -0.03 : -0.012, 0.006, se);          // live: a softer terminator
    return exp(-P.tauT * nature_airmass(se) * exp(-h / 8.0)) * vis;
}

// Screen azimuth (radians, + = right) for a body at hour angle H (0 = due south, + west)
// whose rise→set half-arc is H0. The day is a phase φ running 0 (noon) → ±π/2 (set/rise)
// → ±π (midnight), linear in time within each half; the frame position is a triangle wave
// of it: the body crosses left → right while it is up (rising at −A, setting at +A) and
// drifts back right → left below the horizon, through the centre at midnight. Toward polar
// day the set phase moves out to π (the midnight sun swings back to centre, low and gold)
// and toward polar night in to 0, so no latitude or date ever makes it jump.
static inline float nature_arcAz(float H, float H0, float A) {
    float P0 = 0.5 * NATURE_PI * min(H0 / 0.6, 1.0);
    P0 = mix(P0, NATURE_PI, smoothstep(2.4, NATURE_PI, H0));
    float aH = abs(H);
    float ph = aH <= H0 ? P0 * aH / max(H0, 1e-4)
                        : P0 + (NATURE_PI - P0) * (aH - H0) / max(NATURE_PI - H0, 1e-4);
    float f = A * (ph <= 0.5 * NATURE_PI ? ph : NATURE_PI - ph) / (0.5 * NATURE_PI);
    return H < 0.0 ? -f : f;
}

// Ocean Horizon's composed sun and moon (case 59), from the uniforms. Manual mode: the Sun
// Height param, a little right of centre. Live: the real elevation, with the azimuth mapping
// the day's progress across the frame (nature_arcAz); the moon likewise, its height eased so
// a high moon stays in the frame with its glitter path.
static inline float nature_liveDay(constant FXUniforms& u) { return smoothstep(0.08, 0.5, u.sun.x); }   // clear-day grade
static inline float nature_oceanArcA(constant FXUniforms& u) {
    return atan(0.62 * u.resolution.x / (u.resolution.y * 1.65));
}
static inline float nature_oceanSunEl(constant FXUniforms& u, const bool live) {
    return live ? u.sun.x : u.p0.y * 0.0174533;
}
static inline float3 nature_oceanSunDir(constant FXUniforms& u, const bool live) {
    float se = nature_oceanSunEl(u, live);
    float saz = 0.16;
    if (live) saz = nature_arcAz(u.sun.y, u.sun.z, nature_oceanArcA(u));
    return float3(sin(saz) * cos(se), sin(se), cos(saz) * cos(se));
}
static inline float3 nature_oceanMoonDir(constant FXUniforms& u, thread float &moonEl) {
    moonEl = 0.40 * tanh(u.moon.x / 0.40);
    float maz = nature_arcAz(u.moon.y, u.moon.z, nature_oceanArcA(u));
    return float3(sin(maz) * cos(moonEl), sin(moonEl), cos(maz) * cos(moonEl));
}
static inline float3 nature_oceanTint(constant FXUniforms& u, const bool live) {
    if (live) return nature_liveTint(u);
    return srgbToLinear(u.colorB.rgb);
}
// Live camera: exposure opens up through twilight (as an eye or a long exposure would), and
// stops down a little under a high sun.
static inline float nature_oceanExpo(constant FXUniforms& u) {
    float dd = nature_liveDD(u);
    return exp2(1.0 * smoothstep(-2.0, 9.0, dd) + 1.6 * smoothstep(6.0, 16.0, dd)
                - 0.6 * smoothstep(0.08, 0.7, u.sun.x));
}

// Twilight and night light the single-scattering model above can't make once the sun is
// down (Follow the Sun only): the afterglow arch over the set sun (gold → red as it sinks),
// the purple light high above it (stratospheric dust, ~3–7° depression), the pink
// anti-twilight band low all round, and the deep blue of the blue hour. Called for a sun
// 2°…18° down only (every term here is 0 at both ends).
static inline float3 nature_twilight(float3 v, float2 hs, float tw, constant FXUniforms& u,
                                               const bool refl) {
    float ev = max(v.y, 0.0);
    float dd = nature_liveDD(u);
    float2 hv = v.xz * rsqrt(max(dot(v.xz, v.xz), 1e-8));
    float away = 1.0 - dot(hv, hs);                              // 0 toward the sun … 2 opposite
    float3 L = float3(0.0);
    {
        float dp = max(dd, 0.0);
        // Blue hour: the clear, deep blue the sky keeps for half an hour after the sun has
        // gone (ozone absorbs the orange from light grazing through the high atmosphere).
        float Ih = smoothstep(-1.5, 2.5, dd) * exp(-max(dd - 2.5, 0.0) / 2.6);
        L += mix(float3(0.050, 0.085, 0.20), float3(0.012, 0.035, 0.16), sqrt(ev)) * Ih * 0.07;
        // Afterglow: hugs the horizon under the sun, shrinking and reddening with depth.
        float Ia = smoothstep(-2.0, 1.0, dd) * exp(-dp / 2.4);
        float ha = mix(0.10, 0.035, smoothstep(0.0, 10.0, dp));
        float3 ca = mix(float3(1.0, 0.52, 0.20), float3(0.80, 0.17, 0.06), smoothstep(0.5, 8.0, dp));
        L += ca * Ia * exp(-ev / ha - away * mix(2.5, 4.0, smoothstep(0.0, 8.0, dp))) * 0.12;
        // Purple light: a soft rose-violet patch ~15–25° up over the sun's azimuth.
        // (Each term below is skipped once the sun is too deep for it to show: those are
        // uniform branches, and the night sky is the scene's costliest.)
        float pd = (dd - 4.0) / 2.2;
        if (!refl && abs(pd) < 2.7) {
            float pe = (ev - 0.32 + 0.02 * dp) / 0.20;
            L += float3(0.70, 0.36, 0.72) * exp(-pd * pd - pe * pe - away * 1.2) * 0.0025;
        }
        // Pink belt: low and all round, strongest away from the sun.
        float Ib = smoothstep(-2.0, 0.5, dd) * exp(-dp / 2.0);
        if (!refl && Ib > 0.004) {
            float be = (ev - 0.07 - 0.008 * dp) / 0.07;
            float bb = max(1.0 - be * be * (1.0 / 3.0), 0.0);         // ≈ exp(−be²), no exp
            L += float3(0.85, 0.48, 0.55) * Ib * (bb * bb * bb) * (0.25 + 0.75 * saturate(away * 0.6)) * 0.004;
        }
    }
    return L * tw;
}

// Follow the Sun's sky on top of the single scattering: a deep-blue clear midday zenith, the
// twilight glows (out of line), and the airglow/starlight floor.
static inline float3 nature_atmosLive(float3 L, float3 v, NatureOceanP P, constant FXUniforms& u,
                                                const bool refl) {
    float ev = max(v.y, 0.0);
    float dd = nature_liveDD(u);
    // Clear midday: the zenith deepens to the saturated blue a polariser-free eye sees,
    // over a pale white-blue horizon.
    float day = nature_liveDay(u);
    if (day > 0.0) L *= mix(float3(1.0), float3(0.62, 0.80, 1.06), day * smoothstep(0.02, 0.6, ev));
    if (P.tw > 0.0) L += nature_twilight(v, P.sh, P.tw, u, refl);
    // Airglow + starlight: deep navy, so moonless nights still have a horizon.
    L += float3(0.0007, 0.0012, 0.0028) * smoothstep(2.0, 12.0, dd) * (1.0 + 2.0 * exp(-ev * 7.0));
    return L;
}

// Sky radiance along v (no sun disc, no clouds).
// `refl`: seen in the sea's rough mirror, where the faint purple light and pink belt don't
// survive the blur (they are skipped there).
static inline float3 nature_oceanAtmos(float3 v, NatureOceanP P, constant FXUniforms& u,
                                                 const bool refl = false, const bool wx = false) {
    float ev = max(v.y, 0.0);
    float c = dot(v, P.sd);
    // Weather: under a deck the air is lit by the deck, not the sun — grey, a little brighter
    // overhead, with whatever glow the deck lets through toward the sun, its rim's light near a
    // gap, and the lightning inside it. Past the deck's edge (the gap at the horizon) the clear
    // sky shows. (Wholly under it, the clear sky isn't worked out at all.)
    float under = 0.0;
    float3 air = float3(0.0);
    if (wx && P.deck > 0.0) {
        float tB = P.hb / max(v.y, 0.002);
        under = P.deck * smoothstep(P.dx * 1.3, P.dx * 0.8, tB);
        air = P.lb * (0.80 + 0.2 * sqrt(ev)) + P.aur * nature_hg(c, 0.7)
            + P.eglow * exp(-max(P.dx - tB, 0.0) / (0.3 * P.dx)) * (0.4 + 2.0 * nature_hg(c, 0.6))
            + P.flash * (0.04 + 0.5 * exp(6.0 * (dot(v, P.fd) - 1.0)));
        if (under > 0.999) return air;
    }
    float3 betaR = NATURE_RAYLEIGH;
    float pr = 0.0597 * (1.0 + c * c);
    float pm = nature_hg(c, 0.76) + 0.08 * nature_hg(c, 0.4) + 0.06 * nature_hg(c, 0.98);
    // (Kasten–Young of the view elevation, straight from its sine: asin(ev) ≈ ev(1 + ev²/6)
    // only matters in the small horizon term, where it is exact enough.)
    float mv = 1.0 / (ev + 0.50572 * pow(ev * (1.0 + ev * ev * (1.0 / 6.0)) * 57.29578 + 6.07995, -1.6364));
    float3 tauV = P.tauS * mv;
    // Light reaching the scatterers: views near the zenith scatter higher up, where the
    // sun's path is shorter (so the zenith stays blue after the horizon turns red).
    float3 Ts = nature_sunAt(P, 1.0 + 7.0 * sqrt(ev), u);
    float vis = 1.0;
    float3 scat = (betaR * pr + P.mie * pm) / (betaR + P.mie);
    float3 L = P.esun * Ts * vis * scat * (1.0 - exp(-tauV));
    // Multiple scattering, roughly: a soft skylight that survives after sunset.
    // (Kept bluish: it is mostly light that scattered high up, before the sun reddened.)
    L += P.ms * float3(0.0011, 0.0042, 0.0165) * (1.0 - 0.35 * ev);
    if (P.live) L = nature_atmosLive(L, v, P, u, refl);
    if (wx) L = mix(L, air, under);
    return L;
}

// Gradient noise as gnoise, on an integer hash (no sin, and cheaper than the fract hash it
// replaced): the sky's clouds evaluate ~8 of these per pixel, most of the scene's cost.
static inline float2 nature_ghash(float2 p) {
    uint2 q = uint2(int2(p) + 0x10000) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float2(uint2(n, n * 48271u)) * (2.0 / 4294967296.0) - 1.0;
}
static inline float nature_gnoise(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(nature_ghash(i), f);
    float b = dot(nature_ghash(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(nature_ghash(i + float2(0, 1)), f - float2(0, 1));
    float d = dot(nature_ghash(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// The same noise with its analytic gradient: (value, d/dx, d/dy). The gradient comes almost
// free with the value, and stands in for a second noise (the cloud warp) and for a whole
// second density lookup (the clouds' self-shadowing).
static inline float3 nature_gnoised(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = nature_ghash(i), gb = nature_ghash(i + float2(1, 0));
    float2 gc = nature_ghash(i + float2(0, 1)), gd = nature_ghash(i + float2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k = va - vb - vc + vd;
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    float2 g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
             + du * (u.yx * k + float2(vb - va, vc - va));
    return float3(v, g);
}

#include "../Weather/Weather_funcs.h"

// Cloud density noise: soft large-scale cover + billowy detail (rounded puffs with creases).
// `fp` is the pixel's footprint in noise units: each detail octave fades to its mean as it
// approaches a cycle per pixel (filtered, not aliased, and skipped once gone). `grad`
// returns the two large-scale octaves' value (.x) and gradient (.yz): the shape the light
// falls across.
static inline float nature_cloudNoise(float2 p, int oct, float fp, thread float3 &grad) {
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    float3 n0 = nature_gnoised(p);
    float3 n1 = nature_gnoised(R * p * 2.03 + 1.7);
    float s = 0.55 * n0.x + 0.28 * n1.x;
    // d/dp of g(R·p·2.03) = 2.03·Rᵀ·∇g
    grad = float3(s, 0.55 * n0.yz + 0.28 * 2.03 * (transpose(R) * n1.yz));
    float a = 0.22, fr = 4.1;
    float2 q = R * R * p * 4.1 + 3.3;
    for (int i = 2; i < oct; ++i) {
        float k = smoothstep(0.55, 0.22, fr * fp);
        if (k <= 0.0) { s += 0.21 * a * (2.0 - exp2(float(i + 1 - oct))); break; }   // (E[0.35 − |g|] ≈ 0.21)
        s += a * mix(0.21, 0.35 - abs(nature_gnoise(q)), k);
        q = R * q * 2.07; a *= 0.5; fr *= 2.07;
    }
    return s;
}

// Partly cloudy (weather): how far the cloud layer has gathered into fair-weather cumulus, 0…1
// (from the cover; gone again as an overcast closes in, or in fog). Uniform: from the uniforms,
// not held in NatureOceanP (the sea and sky are register-bound). WeatherLink.cumulus matches it.
static inline float nature_wxCu(constant FXUniforms& u) {
    return smoothstep(0.30, 0.48, u.weather.x) * (1.0 - smoothstep(0.80, 0.95, u.weather.x))
         * (1.0 - smoothstep(0.35, 0.6, u.weather2.y));
}
// Partly cloudy (weather): fair-weather cumulus — heaps a kilometre or two across with flat bases
// at 1.1 km and domed, billowed tops up to ~1.2 km above, blue sky between. A 2D field over the
// base plane (km) says where they stand and how tall (> 0 inside a heap, more = taller); .yz its
// slope (which flank faces where). `bill`: the billows (rounded bumps with creases), faded out
// as they near a cycle per pixel (fp: the pixel's footprint, km).
static inline float3 nature_wxCuField(float2 p, float thr, float fp, int bill) {
    float3 a = nature_gnoised(p * 0.38);
    float v = 0.8 * a.x - thr;
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    if (bill > 0) v += 0.15 * smoothstep(0.45, 0.15, fp * 1.9) * (0.3 - abs(nature_gnoise(p * 1.9 + 1.9)));
    if (bill > 1) v += 0.075 * smoothstep(0.45, 0.15, fp * 4.1) * (0.3 - abs(nature_gnoise(R * p * 4.1 + 7.3)));
    return float3(v, a.yz * 0.304);
}
static inline float2 nature_wxCuDrift(NatureOceanP P) { return float2(P.tc * 2.2 + 31.7, P.tc * 0.7 + 12.4); }
static inline float nature_wxCuThr(constant FXUniforms& u) { return mix(0.22, -0.03, smoothstep(0.3, 0.85, u.weather.x)); }
// The heaps along v (v.y > 0), drawn as a height field over the base, its relief found by slices
// up through it front to back — the base (a ray meeting the heaps' flat undersides), then higher,
// where only the taller heaps reach — so low in the sky their sides crowd into a bank and a heap
// hides what lies behind it. Sunlit on the flank facing the sun, grey beneath, silver-lined toward
// it, fading into the haze with distance. (High up, the slices all but coincide: the base alone.)
// Returns (colour, cover).
static inline float4 nature_wxCumulus(float3 v, float3 sky, NatureOceanP P, float cu, float thr,
                                      constant FXUniforms& u) {
    const float hb = 1.1, H = 1.2;
    float c = dot(v, P.sd);
    float3 sunE = P.esun * nature_sunAt(P, 1.8, u);
    float3 amb = sky * 0.45 + P.amb * float3(0.0040, 0.0050, 0.0085);
    float fs = nature_hg(c, 0.6);
    float2 drift = nature_wxCuDrift(P), toSun = normalize(P.sd.xz + 1e-4);
    float keep = 1.0;
    float3 acc = float3(0.0);
    float up = smoothstep(0.6, 0.4, v.y);                      // (the flanks fade out overhead)
    int nS = up > 0.0 ? 3 : 1;
    for (int i = 0; i < nS; ++i) {
        float hf = i == 0 ? 0.0 : (i == 1 ? 0.4 : 0.8);       // how far up the heaps
        float tt = (hb + hf * H) / v.y;                        // km along the ray
        float fp = tt * P.pix / max(v.y, 0.02);
        float3 f = nature_wxCuField(v.xz * tt + drift, thr, fp, i == 0 ? 2 : 1);
        float x = f.x - 0.16 * hf;                             // (a heap this tall reaches here)
        float a = smoothstep(0.0, 0.03 + 0.6 * fp, x) * exp(-tt * 0.010) * cu * (i == 0 ? 1.0 : up);
        if (a <= 0.0) continue;
        float thin = saturate(1.0 - x * 7.0);                  // the rims
        float3 L;
        if (i == 0) {
            // The flat base: grey, lit by the light diffused down through the heap (rims brighter).
            L = amb * 0.8 + sunE * ((0.03 + 0.2 * thin) * (0.3 + 2.0 * fs));
        } else {
            // A flank: -grad points out of the heap; the higher, the more it faces up (the dome).
            float2 gd = -f.yz * rsqrt(dot(f.yz, f.yz) + 0.01);
            float lam = saturate(0.35 + 0.65 * dot(normalize(float3(gd.x, 0.25 + 1.3 * hf, gd.y)), P.sd));
            float sh = exp(-3.0 * max(dot(f.yz, toSun), 0.0) - 1.2 * saturate(x));
            L = amb + sunE * (0.30 * lam * sh + 0.9 * fs * thin);
        }
        acc += keep * a * L;
        keep *= 1.0 - a;
        if (keep < 0.01) break;
    }
    float cov = 1.0 - keep;
    return float4(acc / max(cov, 1e-4), cov);
}
// The heaps' shadow at sea point w (m): their outline toward the sun, through the middle of the
// layer (soft: the sun's penumbra, and their thin rims). 0…1 = in shadow.
static inline float nature_wxCuShadow(float2 w, NatureOceanP P, float thr) {
    float2 p = w * 0.001 + P.sd.xz * (1.6 / max(P.sd.y, 0.035)) + nature_wxCuDrift(P);
    return smoothstep(-0.03, 0.08, nature_wxCuField(p, thr, 1.0, 0).x);
}

// Altocumulus deck + cirrus over the atmosphere along v (v.y > 0). `oct` trades detail
// for speed (reflections use fewer octaves).
static inline float3 nature_oceanClouds(float3 v, float3 sky, NatureOceanP P, int oct, thread float &cov,
                                        constant FXUniforms& u, float ang = 0.0, const bool wx = false,
                                        const bool cu = false) {
    cov = 0.0;                                                        // (how much sky they hide)
    // Live, deep night: cirrus and the clouds' reflections fade out (dark on dark, unseen).
    // (Weather: a deck lit by lightning shows in the sea too, for the flash.)
    float nf = P.live ? smoothstep(8.5, 5.5, nature_liveDD(u)) : 1.0;
    if (wx && P.flash.b > 0.0) nf = 1.0;
    if (v.y < 0.004) return sky;
    // Partly cloudy: the cumulus is the lowest layer, in front of the rest (behind a solid heap
    // nothing else is worked out).
    // (Only the cumulus copy, fx_wx_ocean_cu, carries this: see Weather_fragment.h. The sky's
    // only: in the sea's rough mirror the high layer's reflection stands in for them.)
    float4 cum = float4(0.0);
    if (wx && cu && oct >= 5) {
        float cuA = nature_wxCu(u);
        if (cuA > 0.0) {
            cum = nature_wxCumulus(v, sky, P, cuA, nature_wxCuThr(u), u);
            if (cum.w > 0.995) { cov = 1.0; return cum.rgb; }
        }
    }
    if (P.clouds <= 0.0 || (oct < 5 && nf <= 0.0)) {
        if (wx && cu) { cov = cum.w; return mix(sky, cum.rgb, cum.w); }
        return sky;
    }
    float c = dot(v, P.sd);
    float vis = 1.0;
    float3 Tc = nature_sunAt(P, 2.5, u);                                 // sunlight at the deck
    // Cirrus at 8 km: streaks stretched along the wind (sky only, not reflections).
    float3 col = sky;
    float kc = 0.0;
    if (oct >= 5 && nf > 0.0 && (!wx || P.deck < 0.99)) {
        float tC = 8.0 / v.y;
        float2 q = v.xz * tC;
        float2 qs = float2(q.x * 0.6 + q.y * 0.25, q.y * 0.08 - q.x * 0.1) * 0.22 + float2(P.tc * 0.25, 0.0);
        const float2x2 Rc = float2x2(0.8, 0.6, -0.6, 0.8);
        // (One noise: its gradient across the streaks stands in for the finer octave.)
        float3 cn = nature_gnoised(qs);
        float ci = 0.5 * cn.x + 0.1 * dot(cn.yz, Rc[1]) + 0.35;
        float cir = smoothstep(0.30, 0.85, ci) * P.clouds * exp(-tC * 0.006);
        float3 cirC = P.esun * nature_sunAt(P, 8.0, u) * (0.10 + 1.6 * nature_hg(c, 0.7)) * 0.12 + sky * 0.6;
        kc = cir * 0.55 * nf * (wx ? 1.0 - P.deck : 1.0);
        col = mix(sky, cirC, kc);
    }
    cov = kc;
    // Altocumulus at 2.5 km (weather: a lower deck as it closes in).
    float tA = (wx ? P.hb : 2.5) / v.y;
    // (The offset picks where on the deck the opening frame sits: a broad, textured bank
    // across the top with open sky around the sun, as the presets have always opened.)
    float2 p = v.xz * tA * 0.32 + float2(P.tc + 78.12, P.tc * 0.3 + 37.75);
    // Pixel footprint in noise units: where the deck is too foreshortened to resolve,
    // fade texture into its average (no venetian-blind aliasing at the horizon).
    // (ang: the angle a reflected pixel spans — the rough, curved mirror's spread — which
    // softens the clouds it sees exactly as distance does.)
    float fp = tA * max(P.pix, ang) * 0.32 / max(v.y, 0.004);
    // Domain warp: one noise and its gradient (a second, independent noise cost as much).
    // (Reflections skip it: through the rough mirror the warp's shapes don't survive.)
    float2 w = float2(0.0);
    if (oct >= 5) {
        float3 wq = nature_gnoised(p * 0.35 + 3.1);
        w = float2(wq.x, 0.28 * (0.6 * wq.y - 0.8 * wq.z));
    }
    float3 gl;
    // Live, deep night: only the moon lights the deck, and its finest billows don't read —
    // the detail filter's floor rises (smoothly, no pop) until the last octave is skipped.
    float fpd = (P.live && oct >= 5) ? max(fp, 0.032 * smoothstep(7.0, 10.0, nature_liveDD(u))) : fp;
    // (Weather: a full deck is soft; its finest billows go — they'd be lost in the rain haze. In
    // rain or snow the next-finest too: the falling rain and snow veil them.)
    float n = nature_cloudNoise(p + w * 0.6, (wx && oct >= 5 && P.deck > 0.99) ? (u.weather.y > 0.05 ? 3 : 4) : oct, fpd, gl);
    float cover = P.clouds;
    float lo = 0.78 - 0.45 * cover;
    float resolved = smoothstep(0.5, 0.12, fp);
    float soft = (oct < 5 ? 0.32 : 0.0) + 0.3 * (1.0 - resolved) + (wx ? 0.15 * P.deck : 0.0);
    float nv = n * 0.75 + 0.5 + 0.18 * w.x;
    // Reflections: where a pixel spans more cloud than it can resolve (a grazing or rough
    // mirror), it sees the deck's average, not a magnified sliver of its edges.
    if (oct < 5) nv = mix(nv, 0.5, smoothstep(0.3, 2.0, fp));
    // Partly cloudy (weather): the layer gathers into separate heaps, crisp-edged, blue between.
    float dens = smoothstep(lo - soft, lo + 0.28 + soft, nv);
    float fade = exp(-tA * 0.012);                                  // aerial perspective
    if (oct < 5) fade *= smoothstep(0.02, 0.2, v.y);                // no grazing streaks in reflections
    if (dens > 0.0) {
        // Self-shadowing: how much cloud lies a little way toward the sun — estimated from
        // the large-scale density and its gradient (no second lookup). Half a cycle away the
        // noise has mostly decorrelated, so the estimate leans on the slope (lit and shadowed
        // flanks) and regresses the value toward the mean: the same shade, on average, as
        // sampling the deck there (so the Clouds slider keeps its old cover and brightness).
        float shade = 1.0;
        // (Unlit, nothing to shade; under the moon (live, sun > 5° down) the faint key light
        // doesn't earn it.)
        if (oct >= 5 && P.esun.b > 0.0 && !(P.live && nature_liveDD(u) > 5.0)) {
            float2 toSun = normalize(P.sd.xz + 1e-4) * 0.55;
            float n2 = 0.2 * gl.x + clamp(0.3 * dot(gl.yz, toSun), -0.35, 0.35);
            float d2 = smoothstep(lo, lo + 0.28, n2 * 0.75 + 0.5 + 0.18 * w.x);
            shade = exp(-2.2 * d2) * 0.85 + 0.15;
        }
        // (Reflections: no bright thin-edge rim — blurred by the rough mirror it would draw
        // contour lines on the water.)
        float thin = oct < 5 ? 0.45 : 1.0 - dens;
        // Low sun: the undersides we see catch reddened light; thin edges toward the sun
        // silver-line (strong forward scattering); thick cores fall to blue-grey skylight.
        float3 lit = P.esun * Tc * vis * (0.25 + 3.4 * nature_hg(c, 0.62) * (0.2 + thin)) * (0.12 + 0.35 * thin) * shade;
        float3 amb = sky * 0.30 + P.amb * float3(0.0025, 0.0035, 0.0085);
        float3 cc = lit + amb;
        float a = smoothstep(0.0, 0.55, dens) * fade * (oct < 5 ? nf : 1.0);
        if (wx && P.deck > 0.0) {
            // The deck's base: the light through it, darker where it is thicker (lumps and rolls
            // of the base), the glow toward the sun, the lightning inside it (brightest in the
            // thick cores). Its edge is ragged; beyond it, the clear gap.
            float th = nv - 0.55;
            float3 dl = P.lb * min(exp(-4.0 * P.cdark * (oct < 5 ? 0.3 : 1.0) * (nv - 0.52)), 2.2) + P.aur * nature_hg(c, 0.7) * (1.0 - 0.6 * saturate(th * 2.0))
                      + P.eglow * exp(-max(P.dx - tA, 0.0) / (0.3 * P.dx)) * (0.4 + 2.0 * nature_hg(c, 0.6)) * (1.2 - saturate(th * 2.0))
                      + P.flash * (0.04 + exp(6.0 * (dot(v, P.fd) - 1.0))) * (0.3 + 1.4 * saturate(nv - 0.35));
            float edge = smoothstep(P.dx * 1.3, P.dx * 0.75, tA + (nv - 0.5) * P.dx * 0.6);
            cc = mix(cc, dl, P.deck * edge);
            a *= mix(1.0, edge, P.deck);
        }
        col = mix(col, cc, a);
        cov = 1.0 - (1.0 - kc) * (1.0 - a);
    }
    if (wx && cu) {
        col = mix(col, cum.rgb, cum.w);
        cov = 1.0 - (1.0 - cov) * (1.0 - cum.w);
    }
    return col;
}

// ---------------------------------------------------------------- night sky (case 60)
//
// The sky is real geometry: a horizon frame at 40°N is rotated to equatorial coordinates
// by local sidereal time (from the Mac's clock and date, plus a time-lapse turn), then
// to galactic coordinates (J2000 matrix), where the Milky Way lives: a thin disc with a
// bulge toward Sagittarius, star clouds, and dust lanes that dim both glow and stars.
// The moon's phase is the real one for today (mean synodic month); its lit limb faces
// the sun's true side for a waxing (evening, west) or waning (morning, east) moon.

// J2000 equatorial → galactic (columns, as Metal's float3x3 takes them).
constant float3x3 NATURE_EQ2GAL = float3x3(float3(-0.0548756, 0.4941094, -0.8676661),
                                           float3(-0.8734371, -0.4448296, -0.1980764),
                                           float3(-0.4838350, 0.7469822, 0.4559838));

// Value noise on a direction (seamless on the sphere), normalised to ~0..1.
static inline float nature_dirNoise(float3 p, int oct) {
    float v = 0.0, a = 0.5, s = 0.0;
    for (int i = 0; i < oct; ++i) { v += a * noise3(p); s += a; p = p * 2.07 + 1.3; a *= 0.5; }
    return v / s;
}

// Stars on galactic coordinates, more numerous along the band, dimmed by dust.
static inline float3 nature_galStars(float3 g, float pix, float band, float dust, float t, float twk) {
    float az = atan2(g.x, g.y);
    float sz = g.z;
    float ce = max(sqrt(max(1.0 - sz * sz, 0.0)), 0.05);
    float3 acc = float3(0.0);
    for (int L = 0; L < 3; ++L) {
        float sc = L == 0 ? 60.0 : (L == 1 ? 140.0 : 320.0);
        float2 q = float2(az, sz) * sc;
        float2 cell = floor(q);
        float3 h = pcg3(float3(cell, 41.0 + float(L) * 17.0));
        float2 off = (q - cell) - (0.15 + 0.7 * h.xy);
        float r = length(float2(off.x * ce, off.y / ce) / sc) / pix;
        float thr = (L == 0 ? 0.80 : (L == 1 ? 0.70 : 0.62)) - (L == 0 ? 0.05 : 0.22) * band;
        if (h.z < thr || r > 4.0) continue;
        float3 h2 = pcg3(float3(cell + 517.0, 9.0 + float(L)));
        float m = h2.x;
        float b = L == 0 ? 0.8 * pow(m, 8.0) + 0.02 : (L == 1 ? 0.07 * pow(m, 4.0) + 0.008 : 0.012 * m + 0.003);
        float sig = 0.48 + 0.4 * sqrt(min(b, 1.0));
        float tw = 1.0 + twk * 0.45 * sin(t * (3.0 + 6.0 * h2.y) + h2.y * 60.0);
        float3 tint = h2.z < 0.5 ? mix(float3(0.62, 0.74, 1.0), float3(1.0), h2.z * 2.0)
                                 : mix(float3(1.0), float3(1.0, 0.70, 0.42), (h2.z - 0.5) * 2.0);
        acc += tint * b * tw * exp(-r * r / (2.0 * sig * sig)) * dust;
    }
    return acc;
}

// Milky Way surface brightness (linear, before exposure) at galactic direction g; .w is
// the dust transmission, for dimming the stars behind it. `pix` = radians per pixel: the
// star clouds carry a grain a few pixels across — the countless stars a camera just
// resolves — so the band reads as stars, not smoke, at any output size.
static inline float4 nature_milkyWay(float3 g, float pix) {
    if (abs(g.z) > 0.42) return float4(0.0, 0.0, 0.0, 1.0);   // far off the band: nothing to add
    float l = atan2(g.y, g.x);                    // galactic longitude, 0 = centre
    float b = asin(clamp(g.z, -1.0, 1.0));
    float cl = cos(l);
    // The disc thickens and brightens toward the centre; a bulge sits on it.
    float width = 0.075 + 0.05 * max(cl, 0.0);
    float disc = exp(-(b * b) / (width * width)) * (0.35 + 0.65 * (0.5 + 0.5 * cl));
    float bulge = exp(-(l * l + b * b * 2.4) / (0.30 * 0.30)) * 1.6;
    float n1 = nature_dirNoise(g * 9.0, 4);                  // star clouds
    float n2 = nature_dirNoise(g * 26.0 + 7.0, 3);           // fine mottling
    float n3 = nature_dirNoise(g * 70.0 + 2.0, 2);           // knots
    float gf = 0.42 / pix;                                   // grain cells ≈ 2.4 px
    float grain = bh_vn3(g * gf);
    grain = grain * grain * grain * 3.2;                     // sparse bright specks, like stars
    float clouds = smoothstep(0.35, 0.8, n1) * (0.3 + 1.0 * n2) * (0.6 + 0.8 * n3 * n3);
    float halo = exp(-(b * b) / (width * width * 9.0)) * 0.08;  // unresolved glow around the band
    float glow = disc * (0.12 + 1.8 * clouds * (0.55 + 0.6 * grain))
               + bulge * (0.5 + 0.9 * n1) * (0.7 + 0.6 * n3) * (0.8 + 0.3 * grain) + halo;
    // Dust: the Great Rift just above the plane from Cygnus to the centre — broken into
    // lobes and patches, its edge wandering — plus lanes.
    float rn = nature_dirNoise(g * 16.0 + 9.0, 3);
    float rb = (b - 0.025 - 0.02 * sin(l * 3.0) - 0.045 * (rn - 0.5)) / (0.020 + 0.022 * n1);
    float rift = exp(-rb * rb) * smoothstep(1.4, 0.2, abs(l - 0.6)) * smoothstep(0.22, 0.62, rn + 0.3 * (n2 - 0.5));
    float lanes = abs(b) < 0.3 ? smoothstep(0.45, 0.8, nature_dirNoise(g * 14.0 + 3.0, 3)) * exp(-(b * b) / 0.012) : 0.0;
    float T = exp(-(2.0 * rift * (0.5 + n2) + 1.1 * lanes));
    float3 warm = float3(1.0, 0.78, 0.55), cool = float3(0.64, 0.75, 1.0);
    float3 c = mix(cool, warm, clamp(smoothstep(-0.2, 0.9, cl) * 0.8 + bulge * 0.25, 0.0, 1.0));
    c = mix(c, float3(0.86, 0.66, 0.50), (1.0 - T) * 0.5);      // light through thin dust reddens
    // Faint pink emission nebulae, sparse, right on the plane.
    float hii = abs(b) < 0.12 ? smoothstep(0.78, 0.95, nature_dirNoise(g * 30.0 + 11.0, 2)) * exp(-(b * b) / 0.0016) : 0.0;
    return float4(c * glow * T + float3(1.0, 0.35, 0.45) * hii * 0.6 * T, T);
}

// The foreground as a matte in SCREEN space: X across (the frame is 2 tall), y up from the
// true horizon line, pw = half a pixel. Verticals stay vertical however far the camera
// tilts up (drawn in (azimuth, elevation), the tilted wide lens leaned every pine toward the
// zenith). Returns (near hill + spruces, far ridge) coverage; the far ridge is drawn
// hazier, for depth.
static inline float nature_nightHill(float X) {
    return 0.030 + 0.25 * smoothstep(-0.2, -1.6, X) * (0.86 + 0.14 * nature_n1(X * 11.0 + 3.0));
}
static inline float2 nature_nightLand(float X, float y, float pw) {
    if (y > 0.50) return float2(0.0);
    // Far ridge: a long, low range.
    float x = X * 2.3 + 11.0;
    float m = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 4; ++i) { m += a * gnoise(float2(x * f, 0.5 + float(i))); a *= 0.5; f *= 2.2; }
    float farH = 0.060 + 0.080 * m;
    float far = smoothstep(farH + pw, farH - pw, y);
    // Near hill rising toward the left edge, a few metres of rough ground in front.
    float hill = nature_nightHill(X) + 0.005 * nature_n1(X * 70.0) + 0.0025 * nature_n1(X * 190.0);
    float near = smoothstep(hill + pw, hill - pw, y);
    // Spruces along the hill: narrow crowns of irregular, drooping branch whorls,
    // each side ragged on its own, a thin leader at the top.
    const float tw = 0.026;
    float ci = floor(X / tw);
    for (int j = -2; j <= 2; ++j) {
        float id = ci + float(j);
        float base = nature_nightHill((id + 0.5) * tw) - 0.006;
        if (base < 0.075 || nature_h1(id * 3.1 + 2.0) < 0.30) continue;
        float pxc = (id + 0.5 + (nature_h1(id + 8.0) - 0.5) * 0.7) * tw;
        float H = (0.060 + 0.080 * nature_h1(id + 31.0)) * smoothstep(0.07, 0.16, base);
        float yy = y - base;
        if (yy < -pw || yy > H + pw) continue;
        float rel = clamp(yy / H, 0.0, 1.0);
        float dx = X - pxc;
        float side = dx < 0.0 ? 0.0 : 1.0;
        // Whorls, irregular in spacing and reach, each side on its own; fine tufts on top.
        float tierF = 11.0 + 6.0 * nature_h1(id + 3.0);
        float sd = id * 1.7 + side * 13.0;
        float tp = rel * tierF + nature_h1(id + 5.0 + side * 7.0) + 0.6 * nature_n1(rel * 9.0 + sd);
        float tier = tp - floor(tp);                        // 0 at a whorl … 1 just under the next
        float reach = 0.55 + 0.45 * nature_h1(floor(tp) * 1.3 + id * 2.1 + side * 5.0);
        float prof = mix(0.62, 1.0, reach * sqrt(tier));    // branch tips sweep out and droop
        prof *= 0.86 + 0.14 * nature_n1(rel * 70.0 + sd * 3.0);   // needle tufts
        float taper = (1.0 - rel) * (0.75 + 0.25 * (1.0 - rel)); // a slimmer spire
        float hw = H * 0.26 * taper * prof + pw * 0.35;     // + the leader
        float cov = smoothstep(hw + pw, hw - pw, abs(dx)) * smoothstep(H + pw, H - pw, yy);
        near = max(near, cov);
    }
    return float2(near, far);
}

// The Moon's near side, so the face reads as the real one: the main maria as soft-edged
// caps at their selenographic (lon, lat, radius) in degrees, ragged by noise, plus
// highland mottling and Tycho's bright rays. P = unit vector in the Moon's frame
// (x toward the sky's west / right, y lunar north / up, z toward the viewer).
constant float4 NATURE_MARIA[12] = {
    float4(-16.0, 33.0, 17.0, 1.0),   // Imbrium
    float4( 17.0, 28.0, 10.0, 1.0),   // Serenitatis
    float4( 31.0,  8.0, 12.0, 1.0),   // Tranquillitatis
    float4( 59.0, 17.0,  7.5, 1.0),   // Crisium
    float4( 51.0, -8.0,  9.0, 0.9),   // Fecunditatis
    float4( 35.0,-15.0,  5.0, 0.9),   // Nectaris
    float4(-57.0, 18.0, 20.0, 0.85),  // Procellarum (north)
    float4(-45.0, -4.0, 16.0, 0.8),   // Procellarum (south)
    float4(-17.0,-21.0, 10.0, 0.85),  // Nubium
    float4(-39.0,-24.0,  6.0, 0.9),   // Humorum
    float4(  3.0, 13.0,  6.0, 0.8),   // Vaporum / Medii
    float4(  5.0, 56.0,  7.0, 0.7)};  // Frigoris
static inline float nature_moonAlbedo(float3 P) {
    float wob = nature_dirNoise(P * 3.2 + 3.0, 3) - 0.5;            // ragged mare shores
    float mare = 0.0;
    for (int i = 0; i < 12; ++i) {
        float4 m = NATURE_MARIA[i];
        float lo = m.x * 0.0174533, la = m.y * 0.0174533;
        float3 C = float3(sin(lo) * cos(la), sin(la), cos(lo) * cos(la));
        float d = acos(clamp(dot(P, C), -1.0, 1.0)) / (m.z * 0.0224);
        mare = max(mare, m.w * smoothstep(1.25, 0.62, d + wob * 1.1));
    }
    float hi = nature_dirNoise(P * 11.0 + 7.0, 3);                    // highland mottling, craters
    float alb = (0.86 - 0.40 * mare) * (0.90 + 0.20 * hi);
    // Tycho (−11°, −43°): a bright crater with long rays; Copernicus a smaller bright splash.
    float3 T = float3(sin(-0.192) * cos(-0.750), sin(-0.750), cos(-0.192) * cos(-0.750));
    float dt = acos(clamp(dot(P, T), -1.0, 1.0));
    float3 ax = normalize(cross(T, float3(0.0, 1.0, 0.0)));
    float ra = atan2(dot(P, cross(T, ax)), dot(P, ax));
    float rays = smoothstep(0.45, 1.0, nature_n1(ra * 5.0 + 3.0)) * exp(-dt * 2.6) * smoothstep(0.03, 0.15, dt) * 0.10;
    float3 Co = float3(sin(-0.349) * cos(0.175), sin(0.175), cos(-0.349) * cos(0.175));
    float dc = acos(clamp(dot(P, Co), -1.0, 1.0));
    alb += exp(-dt * dt * 700.0) * 0.22 + rays + exp(-dc * dc * 1200.0) * 0.12;
    return alb;
}

// Follow the Sun, the moon over the sea: a phase-lit sphere (Lommel–Seeliger) lit from the
// sun's side of the frame for the real elongation, maria and earthshine. Called only for
// pixels near it, out of line so the rest of the sea doesn't carry its registers.
static inline float3 nature_oceanMoon(float3 rd, float3 moonD, float3 sunD, float moonEl, float elong,
                                      float illum, float3 tauT, float pix, float dd) {
    const float Rm = 0.0105;
    float3 dm = rd - moonD;
    float3 ex = normalize(cross(float3(0.0, 1.0, 0.0), moonD));
    float3 ey = cross(moonD, ex);
    float flatM = mix(0.82, 1.0, smoothstep(0.0, 0.08, moonEl));   // refraction squash, low down
    float2 dp = float2(dot(dm, ex), dot(dm, ey) / flatM) / Rm;
    float r2 = dot(dp, dp);
    float ew = pix / Rm;
    float mdisc = smoothstep(1.0 + ew, 1.0 - ew, sqrt(r2));
    if (mdisc <= 0.0) return float3(0.0);
    float zc = sqrt(max(1.0 - r2, 0.0));
    float3 nrm = dp.x * ex + dp.y * ey - zc * moonD;
    float el = elong < NATURE_PI ? elong : 6.2831853 - elong;
    float3 tow = sunD - moonD * dot(sunD, moonD);
    float3 perp = dot(tow, tow) > 1e-8 ? normalize(tow) : ey;
    float3 sunL3 = moonD * cos(el) + perp * sin(el);
    float3 s3 = float3(dp * 2.2, zc * 2.2);
    float maria = smoothstep(0.45, 0.7, nature_dirNoise(s3 + 5.0, 3));
    float alb = (0.85 - 0.38 * maria) * (0.92 + 0.16 * noise3(s3 * 9.0));
    float mu0 = dot(nrm, sunL3), mu = max(zc, 0.05);
    float ls = mu0 > 0.0 ? mu0 / (mu0 + mu) : 0.0;
    float shine = 0.006 * (1.0 - illum);                               // earthshine
    float3 Tm = exp(-tauT * nature_airmass(moonEl));
    float3 mc = float3(1.0, 0.97, 0.92) * alb * (ls * 1.8 + shine) * Tm;
    // Same surface by day and night; the eye adapts, so by day it reads pale.
    return mc * mdisc * mix(0.6, 0.20, smoothstep(2.0, 12.0, dd));
}

static inline float3 nature_oceanMoonNear(float3 rd, constant FXUniforms& u, float3 tauT, float pix) {
    float moonEl;
    float3 moonD = nature_oceanMoonDir(u, moonEl);
    float3 dm = rd - moonD;
    if (dot(dm, dm) > 0.0003 || moonEl < -0.03) return float3(0.0);
    return nature_oceanMoon(rd, moonD, nature_oceanSunDir(u, true), moonEl, u.moon.w,
                            0.5 - 0.5 * cos(u.moon.w), tauT, pix, nature_liveDD(u));
}

// Gradient noise on the galactic plane, p = (longitude, latitude) in cells, seamless in
// longitude (nx cells per turn, a power of two), on an integer hash (no sin); ≈ 0..1. The
// Milky Way's structure lies along the plane, so its noise is 2D (half a 3D lattice's cost)
// and a little drawn out along it.
static inline float nature_galGrad(uint h, float2 d) {
    h = (h ^ (h >> 15u)) * 0x2c1b3c6du;
    h ^= h >> 13u;
    return dot(float2(float(h >> 16u), float(h & 0xffffu)) * (2.0 / 65535.0) - 1.0, d);
}
static inline float nature_galNoise(float2 p, uint nx, uint seed) {
    float2 i = floor(p), f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    uint m = nx - 1u, ix = uint(int(i.x));
    uint x0 = (ix & m) * 0x8da6b343u, x1 = ((ix + 1u) & m) * 0x8da6b343u;
    uint y0 = uint(int(i.y) + 0x10000) * 0xd8163841u + seed * 0x9e3779b9u, y1 = y0 + 0xd8163841u;
    float a = nature_galGrad(x0 ^ y0, f), b = nature_galGrad(x1 ^ y0, f - float2(1.0, 0.0));
    float c = nature_galGrad(x0 ^ y1, f - float2(0.0, 1.0)), d = nature_galGrad(x1 ^ y1, f - 1.0);
    return 0.5 + 1.2 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// The Milky Way over the sea at night (galactic direction g, longitude l): a thin disc with
// a bulge toward Sagittarius, as nature_milkyWay, but built along the plane: the disc's
// mid-line and width wander, so its edges are ragged rather than ruled; its light breaks into
// star clouds, mottling and knots; and the Great Rift is a ragged chain of dark clouds just
// above the plane from Cygnus to the centre, among thinner lanes — not one dark stripe
// splitting the band into two searchlight beams. .w is the dust's transmission.
static inline float4 nature_milkyWayLite(float3 g, float l) {
    float ab = abs(g.z);
    if (ab > 0.36) return float4(0.0, 0.0, 0.0, 1.0);
    float b = g.z * (1.0 + g.z * g.z * (1.0 / 6.0));          // asin, to 6e-4 rad here
    float cl = g.x * rsqrt(max(g.x * g.x + g.y * g.y, 1e-8));  // cos l
    float lt = l * (1.0 / 6.2831853);                           // longitude, turns
    float nw = nature_galNoise(float2(lt * 32.0, b * 8.0), 32u, 1u);
    float bw = b - 0.035 * (nw - 0.5);                          // the wandering mid-line
    float width = (0.07 + 0.05 * max(cl, 0.0)) * (0.7 + 0.6 * saturate(nw));
    float iw2 = 1.0 / (width * width);
    float3 c = mix(float3(0.66, 0.76, 1.0), float3(1.0, 0.80, 0.58),
                   clamp(smoothstep(-0.2, 0.9, cl) * 0.8, 0.0, 1.0));
    float halo = exp(-(bw * bw) * iw2 * (1.0 / 9.0)) * 0.08 * smoothstep(0.36, 0.24, ab);
    // Off the plane only the unresolved halo is left: no more noise to evaluate.
    if (ab > 0.3) return float4(c * halo, 1.0);
    float disc = exp(-(bw * bw) * iw2) * (0.35 + 0.65 * (0.5 + 0.5 * cl)) * smoothstep(0.3, 0.2, ab);
    // (The bulge, flattened, is gone by the cut: nothing steps where the noise stops.)
    float bulge = exp(-(l * l + bw * bw * 4.0) / (0.30 * 0.30)) * 1.6 * smoothstep(0.3, 0.22, ab);
    float n1 = nature_galNoise(float2(lt * 64.0, b * 12.0), 64u, 2u);     // star clouds
    float n2 = nature_galNoise(float2(lt * 128.0, b * 24.0), 128u, 3u);   // mottling
    float n3 = nature_galNoise(float2(lt * 256.0, b * 46.0), 256u, 4u);   // knots
    float sc = n1 + 0.45 * (n2 - 0.5);
    float clouds = smoothstep(0.32, 0.85, sc) * (0.45 + 0.8 * n2) * (0.55 + 0.9 * n3);
    float glow = disc * (0.10 + 1.9 * clouds) + bulge * (0.5 + 0.9 * n1) * (0.7 + 0.6 * n3) + halo;
    // Dust: the rift's dark clouds (gated into a chain by the lane noise) and the thin lanes.
    float nl = nature_galNoise(float2(lt * 128.0, b * 30.0), 128u, 5u) + 0.35 * (n3 - 0.5);
    float rb = (bw - 0.025 - 0.02 * sin(l * 3.0) - 0.025 * (n1 - 0.5)) / (0.026 * (0.65 + 0.7 * saturate(nw)));
    float rift = exp(-rb * rb) * smoothstep(1.4, 0.2, abs(l - 0.6)) * smoothstep(0.2, 0.7, nl);
    float lanes = smoothstep(0.5, 0.95, nl) * exp(-(bw * bw) / 0.012);
    float T = exp(-(1.5 * rift * (0.6 + n2) + 0.9 * lanes));
    c = mix(float3(0.66, 0.76, 1.0), float3(1.0, 0.80, 0.58),
            clamp(smoothstep(-0.2, 0.9, cl) * 0.8 + bulge * 0.2, 0.0, 1.0));
    return float4(c * glow * T, T);
}

// Stars over the sea: nature_galStars' three layers and magnitude law on one cheap integer
// hash per cell (pcg3 twice per layer was most of the night sky's cost over the water), on
// a (galactic longitude, sin latitude) grid. `faint` weights the faintest layer (skipped at
// 0: while the stars fade in it can't show).
static inline float3 nature_seaStars(float3 g, float az, float pix, float band, float dust, float t, float twk,
                                     float faint) {
    float sz = g.z;
    float ce = max(sqrt(max(1.0 - sz * sz, 0.0)), 0.05);
    float3 acc = float3(0.0);
    int NL = faint > 0.0 ? 3 : 2;
    for (int L = 0; L < NL; ++L) {
        float sc = L == 0 ? 60.0 : (L == 1 ? 140.0 : 320.0);
        float2 q = float2(az, sz) * sc;
        float2 cell = floor(q);
        uint2 ci = uint2(int2(cell) + 0x10000);
        uint n = (ci.x * 0x8da6b343u) ^ (ci.y * 0xd8163841u) ^ (uint(L) * 0xcb1ab31fu);
        n = (n ^ (n >> 16u)) * 0x7feb352du;
        n ^= n >> 15u;
        float3 h = float3(float(n & 0x3ffu), float((n >> 10u) & 0x3ffu), float(n >> 20u)) * float3(1.0 / 1024.0, 1.0 / 1024.0, 1.0 / 4096.0);
        float2 off = (q - cell) - (0.15 + 0.7 * h.xy);
        float r = length(float2(off.x * ce, off.y / ce) / sc) / pix;
        float thr = (L == 0 ? 0.80 : (L == 1 ? 0.70 : 0.62)) - (L == 0 ? 0.05 : 0.22) * band;
        // (Reach: the faint layers' Gaussians are gone by ~2–3 px; a tight cut keeps whole
        // SIMD groups from running the star body for pixels that see nothing.)
        if (h.z < thr || r > (L == 0 ? 4.0 : (L == 1 ? 3.0 : 2.2))) continue;
        n = n * 0x2c1b3c6du;
        float3 h2 = float3(float(n >> 22u), float((n >> 12u) & 0x3ffu), float((n >> 2u) & 0x3ffu)) * (1.0 / 1024.0);
        float m = h2.x, m2 = m * m, m4 = m2 * m2;
        float b = L == 0 ? 0.8 * m4 * m4 + 0.02 : (L == 1 ? 0.07 * m4 + 0.008 : 0.012 * m + 0.003);
        float sig = 0.48 + 0.4 * sqrt(min(b, 1.0));
        float tw = 1.0 + twk * 0.45 * nature_sinT(t * (0.477 + 0.955 * h2.y) + h2.y * 9.55);
        float3 tint = h2.z < 0.5 ? mix(float3(0.62, 0.74, 1.0), float3(1.0), h2.z * 2.0)
                                 : mix(float3(1.0), float3(1.0, 0.70, 0.42), (h2.z - 0.5) * 2.0);
        acc += tint * b * tw * exp(-r * r / (2.0 * sig * sig)) * dust * (L == 2 ? faint : 1.0);
    }
    return acc;
}

// Follow the Sun, stars and a faint Milky Way on the real sidereal sky (local sidereal time
// and latitude from u.sky / u.sun), fading in as the twilight deepens and washed by a
// bright moon. Added after the clouds, scaled by what they leave uncovered — and after the
// exposure (the eye's adaptation doesn't brighten them; the caller adds them last).
static inline float3 nature_oceanStars(float3 rd, constant FXUniforms& u, float pix, float t) {
    float dd = nature_liveDD(u);
    float illum = 0.5 - 0.5 * cos(u.moon.w);
    // (The moon's eased elevation is its own within this little range: no tanh.)
    float moonSky = illum * illum * smoothstep(-0.05, 0.1, u.moon.x);
    // Facing the equator-side sky: x west (right), z toward the equator, y up. (South of
    // the equator the frame is mirrored to keep the sun moving left → right; so is the sky.)
    float cLat, sLat = sincos(abs(u.sun.w), cLat);
    const float3 E = float3(-1, 0, 0), N = float3(0, 0, -1), U = float3(0, 1, 0);
    float3 Pp = cLat * N + sLat * U;
    float3 Mq = -sLat * N + cLat * U;
    // Hour angle → right ascension is a rotation by the sidereal time, so the equatorial
    // vector comes straight from the ray's components (no asin/atan2 per pixel):
    // cos δ·cos H = rd·Mq, cos δ·sin H = −rd·E, sin δ = rd·P, and ra = lst − H.
    float ca = dot(rd, Mq), sa = -dot(rd, E), sd = dot(rd, Pp);
    float cl, sl = sincos(u.sky.x, cl);                         // (Metal: returns sin, writes cos)
    float3 q = float3(cl * ca + sl * sa, sl * ca - cl * sa, u.sun.w < 0.0 ? -sd : sd);
    float3 g = NATURE_EQ2GAL * q;
    float gl = atan2(g.y, g.x);                                  // galactic longitude
    // Extinction: stars dim a little toward the horizon; the Milky Way's faint glow, low
    // contrast against the brighter low sky, fades out well before it (no beam of light
    // standing on the sea).
    float ext = exp(-0.06 / (rd.y + 0.04));
    float extM = exp(-0.2 / (rd.y + 0.03));
    float wash = 1.0 / (1.0 + 2.5 * moonSky);
    float vis = smoothstep(8.5, 15.0, dd);
    float mwv = smoothstep(10.0, 17.0, dd);
    // (Below ~3% the band is invisible over the sea: not worth its noise.)
    float4 mw = mwv > 0.03 ? nature_milkyWayLite(g, gl) : float4(0.0, 0.0, 0.0, 1.0);
    float band = exp(-(g.z * g.z) / 0.02);
    float twk = smoothstep(0.5, 0.0, rd.y);
    float3 st = nature_seaStars(g, gl, pix, band * mwv, mix(1.0, mw.w, 0.85), t, twk, smoothstep(0.45, 0.7, vis)) * 0.5 * mix(1.0, wash, 0.5);
    return st * vis * ext + mw.rgb * 0.04 * mwv * wash * extM;
}

// ---------------------------------------------------------------- case 59 itself
// OCEAN HORIZON — golden-hour sea and sky.
//  p0 = (speed, sun elevation °, sea state, clouds)  p1 = (haze, follow the sun, time lapse)
//  colorA deep water, colorB sunlight tint.
//  Follow the Sun: u.sun / u.moon / u.sky carry the real sun and moon (MetalRenderer.liveSky);
//  the day's arc maps across the frame, and once the sun is well down the moon takes over as
//  the key light (sky glow, clouds, glitter path), with stars.
//  Compiled twice: `live` is a constant in each copy, so the manual mode (Golden Hour,
//  Afterlight) carries none of the live code — this shader is register-bound — and the
//  live copy sits behind one out-of-line call.
//  Weather (`wx`, u.weather*): more copies, compiled in their own unit and drawn by their own
//  pipelines (fx_wx_ocean, Shared/Weather/Weather.metal) only while the sky differs from the
//  scene's clear one: cloud cover from fair-weather cumulus (`cu`: the partly-cloudy copy,
//  fx_wx_ocean_cu, with their shadows on the sea) to a full, lower stratus deck lit by the light it
//  lets through (in the manual mode it ends just above the low sun, which shines in under it; live,
//  by night, it carries a coast's skyglow and the moon behind it), fog by visibility, rain and
//  snow on depth layers (snow: bokeh flakes up close, a veil far off, a calm sea), rain rings and
//  whitecaps on the water, rain curtains, lightning. The clear-sky copies above are untouched
//  (and cost what they did).
static inline float4 nature_ocean(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u,
                                 const bool live, const bool wx = false, const bool cu = false) {
    float speed = u.p0.x, waves = clamp(u.p0.z, 0.0, 1.0), haze = clamp(u.p1.x, 0.0, 1.0);
    // Weather (wx copies): the wind sets the sea; see Shared/Weather/Weather_funcs.h.
    WxState W = wx ? wx_state(u) : WxState{};
    if (wx) waves = wx_seaState(waves, W.wind) * (1.0 - 0.45 * smoothstep(0.0, 0.4, W.snow));   // (snow: a calm sea)
    float aspect = res.x / res.y;
    float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
    const float F = 1.65, pitch = 0.055;
    float3 fwd = float3(0.0, sin(pitch), cos(pitch));
    float3 up = float3(0.0, cos(pitch), -sin(pitch));
    float3 rd = normalize(fwd * F + float3(1.0, 0.0, 0.0) * sp.x + up * sp.y);

    NatureOceanP P;
    P.se = nature_oceanSunEl(u, live);
    P.sd = nature_oceanSunDir(u, live);
    P.esun = nature_oceanTint(u, live) * 9.5;
    P.mie = 0.008 + 0.065 * haze;
    P.tauS = NATURE_RAYLEIGH + P.mie;
    P.tauT = P.tauS + float3(0.016, 0.047, 0.002) + 0.02 * haze;
    P.clouds = clamp(u.p0.w, 0.0, 1.0);
    P.tc = t * speed * 0.004;
    P.pix = 2.0 / (res.y * F);
    P.live = live;
    P.ms = length(P.esun) * (0.3 + 0.7 * smoothstep(-0.1, 0.15, P.se));
    P.amb = length(P.esun);
    P.tw = 0.0;
    P.sh = float2(0.0, 1.0);
    bool keyMoon = false;
    if (live) {
        float dd = nature_liveDD(u);
        float fall = nature_liveFall(dd);
        // Skylight after sunset (the blue hour's), and the clouds' ambient, fade with depth.
        P.ms *= fall;
        P.amb *= mix(0.25, 1.0, smoothstep(-6.0, 2.0, -dd)) * fall;
        // Twilight glows over the set sun (all their terms are 0 at both ends of 2°…18°).
        if (dd > -2.0 && dd < 18.0) P.tw = length(P.esun) * smoothstep(18.0, 12.0, dd);
        P.sh = normalize(P.sd.xz + float2(0.0, 1e-5));
        // Clear air: less milky haze under a high sun, and on a night sky.
        P.mie *= (1.0 - 0.55 * nature_liveDay(u)) * (1.0 - 0.45 * smoothstep(4.0, 12.0, dd));
        P.tauS = NATURE_RAYLEIGH + P.mie;
        // Night: the moon becomes the key light once the sun's own light has left even
        // the cirrus (below ~5°), fading in so nothing pops at the hand-over.
        if (dd > 5.0) {
            keyMoon = true;
            float mel;
            P.sd = nature_oceanMoonDir(u, mel);
            P.se = mel;
            P.esun = nature_liveMoonE(u, dd);
            P.amb += 0.7 * length(P.esun);
        }
    }
    float3 Tsun = exp(-P.tauT * nature_airmass(P.se));

    // Weather: more or less cloud, a deck closing over the sky and its light, the gap at the
    // horizon, fog, lightning. (All uniform: branches here cost nothing per pixel.)
    float sunVis = 1.0;                 // how much of the key light gets through the deck
    float fogB = 0.0, fogH = 1.0;       // fog extinction (1/m) and layer depth (m)
    float3 fogA = float3(0.0);          // the fog's own light (in-scattered, all round)
    float sunT = 1.0;                   // the fog's transmission toward the sun
    float3 ambL = float3(0.0);          // the diffuse light everything is bathed in
    float flashE = 0.0;
    float4 ev = float4(0.0);
    if (wx) {
        float c0 = P.clouds, cv = W.cover;
        P.clouds = cv < 0.25 ? c0 * mix(0.3, 1.0, cv * 4.0) : mix(c0, 1.05, smoothstep(0.25, 0.9, cv));
        P.deck = W.deck;
        // (Partly cloudy: the high layer thins round the cumulus heaps, so blue shows between.)
        P.clouds = mix(P.clouds, c0 * 0.3, nature_wxCu(u)) + 0.6 * P.deck;
        P.tc = (t + u.weather3.x) * speed * 0.004;
        float heavy = max(W.rain, W.storm);
        P.hb = mix(2.5, mix(1.6, 0.85, heavy), P.deck);
        if (live) {
            // A real overcast reaches the horizon; as it breaks up, a band of clear sky opens there.
            P.dx = mix(4000.0, P.hb / 0.05, 1.0 - smoothstep(0.86, 0.995, W.cover));
        } else {
            // Golden Hour keeps its low sun: the deck ends just above it, so it shines in under
            // the edge (the light under a storm at sunset). A sun raised high (Sun Height) gets a
            // sky that closes over like a real one.
            float se0 = nature_oceanSunEl(u, false);
            P.dx = mix(P.hb / tan(clamp(se0 + 0.035, 0.03, 0.6)), 4000.0, smoothstep(0.12, 0.22, se0));
        }
        // The deck's base: the light on its top (sun or moon, reddened along the way; and the
        // skylight), diffused through it (thicker in rain, thickest in a storm).
        float tau = 9.0 + 22.0 * W.rain + 8.0 * W.snow + 50.0 * W.storm;
        float3 Ttop = nature_sunAt(P, P.hb + 1.0, u);
        float3 Etop = P.esun * Ttop * max(P.sd.y + 0.06, 0.0) + P.ms * float3(0.0011, 0.0042, 0.0165) * 1.5;
        P.lb = Etop * (0.24 / (1.0 + 0.11 * tau));
        // (Cloud scatters every colour alike: the light under it is the top light's, much
        // greyed — a touch warm under a low sun, cool by day and in snow.)
        P.lb = mix(P.lb, float3(luma(P.lb)), 0.6) + float3(0.0017, 0.0020, 0.0028);
        P.lb = mix(P.lb, luma(P.lb) * float3(0.95, 0.99, 1.07) * 1.3, W.snow);    // snow: pale, bright
        P.aur = P.esun * Ttop * exp(-tau * 0.11) * 0.08;
        P.cdark = 0.38 + 0.12 * W.rain + 0.55 * W.storm;
        // By night under cloud (live) the deck isn't black: its base carries the faint skyglow
        // of a distant coast (warmer still in the haze along the horizon: the fog's light, below)
        // and, while the moon is up, the moon diffusing through — a soft bright patch in thin
        // cloud (the aureole), none through a storm's. All in the deck's own terms: no cost.
        float nk = live ? smoothstep(3.0, 12.0, nature_liveDD(u)) * smoothstep(0.55, 0.95, cv) : 0.0;
        if (live) {
            P.lb += float3(0.0034, 0.0031, 0.0030) * nk;
            if (keyMoon) P.aur += P.esun * (0.8 * nk * exp(-tau * 0.05) * smoothstep(-0.03, 0.06, P.sd.y));
        }
        float tS = P.hb / max(P.sd.y, 0.002);
        sunVis = 1.0 - P.deck * smoothstep(P.dx * 1.3, P.dx * 0.8, tS);
        // Near its edge the deck's underside catches the bright gap and the light diffusing
        // in through its thin rim — warm toward the sun.
        P.eglow = P.esun * Tsun * sunVis * 0.02 * P.deck;
        ambL = mix(P.esun * Tsun * max(P.sd.y, 0.0) * 0.035 + P.ms * float3(0.0011, 0.0042, 0.0165) * 2.5,
                   P.lb, P.deck);
        fogB = wx_fogBeta(W.fog);
        fogH = mix(mix(600.0, 220.0, smoothstep(0.3, 0.9, W.fog)), 180.0, saturate(W.wet * 2.0));
        // Fog's own light: the diffuse light all round, whitened (droplets scatter every colour).
        fogA = luma(ambL) * float3(0.98, 1.0, 1.04) * (1.0 + 0.4 * smoothstep(0.4, 0.9, W.fog))
             + P.esun * Tsun * sunVis * 0.05 * smoothstep(0.5, 0.85, W.fog) * (1.0 - W.wet)
             + float3(1.0, 0.76, 0.56) * (0.0080 * nk * (1.0 - 0.5 * smoothstep(0.3, 0.8, W.fog)));   // (the coast's glow, in the haze)
        // The low sun through it: dimmed, never quite gone (a pale disc in fog, a glow in rain).
        sunT = exp(-min(fogB * min(fogH / max(P.sd.y, 0.004), 30000.0), 2.6));
        // Lightning: inside the cloud, or a bolt to the sea; as bright after the live camera's
        // exposure by night as by day (gentle either way).
        P.flash = float3(0.0);
        P.fd = float3(0.0, 1.0, 0.0);
        if (W.storm > 0.0 && u.weather3.y > 0.5) {
            flashE = wx_lightning(t, W.storm, ev);
            if (flashE > 0.0) {
                float az = ev.x * 0.7, d = 2.5 + 6.0 * ev.y;
                float el = atan(P.hb / d) * (ev.z < 0.4 ? 1.0 : 0.8);
                P.fd = float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
                P.flash = float3(0.80, 0.84, 1.0) * (flashE * 0.22 / (live ? nature_oceanExpo(u) : 1.0));
            }
        }
    }

    // Rain and snow on their depth layers: their coverage of this pixel, worked out now while
    // little else is live (the shader is register-bound), composited at the end.
    float rainA = 0.0;
    float2 snowA = float2(0.0);
    if (wx && W.wet > 0.005) {
        float pixS = 2.0 / res.y, ts = t * speed;
        // Rain falls as streaks, snow as flakes, sleet as both: icy pellets streaking down
        // through fewer, smaller, wetter flakes.
        float share = saturate(u.weather.z);
        float rk = 1.0 - smoothstep(0.62, 0.9, share), sk = smoothstep(0.2, 0.42, share);
        if (rk > 0.0) {
            float sl = clamp(W.wind * 0.03, 0.0, 0.45) * (1.0 + 0.25 * sin(ts * 0.45) * (1.0 - W.wind / max(W.gust, 0.1)));
            rainA = rk * wx_streaks(sp, ts, pixS, F, saturate(W.wet * 1.4) * (1.0 - 0.4 * sk), sl, rd.y, 4.0,
                                    max(smoothstep(0.35, 0.12, W.wet), 0.5 * share));
        }
        if (sk > 0.0)
            snowA = sk * wx_flakes(sp, ts, pixS, F, min(W.wet * 1.55, 1.4) * (1.0 - 0.45 * rk), W.wind, rd.y, 4.0, rk);
    }

    // The horizon pixel row is shared: sky covers the part of the pixel above it, sea the
    // rest (one row of pixels evaluates both), so the horizon is crisp but antialiased.
    float hcov = saturate(0.5 + rd.y / P.pix);
    float3 col = float3(0.0), colSea = float3(0.0), stars = float3(0.0);
    // (Sea first, then sky: the sky's last step, the night stars, needs none of P, so
    // nothing of the sea's state is held through it — the shader is register-bound.)
    if (hcov < 1.0) {
        // Sea: the sum of 21 wave trains, each filtered by the pixel's footprint on the water.
        float3 rw = rd;
        rw.y = min(rw.y, -0.3 * P.pix);                    // (horizon row: the part below it)
        rw = normalize(rw);
        const float camH = 4.0;
        float dist = camH / -rw.y;
        float2 w = rw.xz * dist;
        // Footprint: one pixel spans dist·pix across the view, and dist·pix/sin(grazing)
        // along it on the water.
        float fx = dist * P.pix;
        float fz = fx / max(-rw.y, 1e-4);
        float2 vh = normalize(rw.xz);
        float ts = t * speed;
        float2 slope = float2(0.0), rslope = float2(0.0);  // swell + chop; wind ripples
        float rvar = 0.0;                                   // resolved ripple slope variance
        float sharp = 0.0;                                  // Gerstner crest sharpening
        float unres = 0.0;                                  // slope variance filtered out (LEAN)
        float steep = 0.028 + 0.07 * waves;
        float rip = sqrt(0.0006 * waves + 0.00008);        // wind-ripple slopes
        float swell = 1.0, warp = 0.0, prev = 0.0;
        // Live: the wind ripples' own slopes only show in the sun's glints. Once the sun is
        // down they fade into roughness with its glitter (their slope variance kept, LEAN, so
        // the mirror neither sharpens nor brightens), and are then skipped; under the moon
        // they stay roughness (its path is all but identical — the near facets give it its
        // sparkle).
        float rk = live ? (keyMoon ? 0.0 : smoothstep(-0.012, 0.004, P.se)) : 1.0;
        // (Weather: no sun through the deck, no glints — the ripples are just roughness then.)
        if (wx) rk *= smoothstep(0.01, 0.2, sunVis * sunT);
        for (int i = 0; i < 21; ++i) {
            float4 W = NATURE_WAVES[i];                     // direction, phase, wavelength
            float2 KW = NATURE_WAVEK[i];                    // wavenumber, angular frequency
            float s = i < 3 ? steep * (0.5 + 0.8 * waves) : (i < 11 ? steep * 0.62 : (i < 17 ? steep * 0.55 : rip));
            // Ripples ride the swells (strongest on the crests); below, each is also gated by
            // its neighbour's phase (wave groups) and bent by the chop and the next-longer
            // ripple, so crossing trains make short irregular wavelets, not a lattice.
            if (i >= 17) {
                s *= swell;
                if (live || wx) {
                    unres += s * s * (1.0 - rk * rk) * 0.22;
                    if (rk <= 0.0) continue;                // (uniform: the whole frame skips)
                    s *= rk;
                }
            }
            // Pixel-footprint filter: a sinusoid averaged over the footprint f along its
            // direction (an ellipse: dist·pix across, stretched by 1/sin(grazing) along the
            // view) keeps ≈ (1 − (k·f/3)²)² of its amplitude — gone by λ ≈ 2f (Nyquist).
            // What is filtered out is kept as slope variance (LEAN), not lost, and costs no trig.
            float a = dot(W.xy, vh), b = W.x * vh.y - W.y * vh.x;
            float q = KW.x * KW.x * (a * a * fz * fz + b * b * fx * fx) * (1.0 / 9.0);
            if (q >= 1.0) { unres += s * s * (i >= 17 ? 0.22 : 0.5); continue; }
            if (i >= 17) s *= 0.6 + 0.4 * prev;
            float rs = (1.0 - q) * (1.0 - q);
            float ph = dot(w, W.xy) * KW.x - KW.y * ts + W.z;
            float cph, sph = 0.0;
            if (i < 10) sph = nature_sincosT(ph * 0.15915494, cph);
            else cph = nature_sinT(ph * 0.15915494 + (i >= 17 ? 0.15915494 * (warp * (1.0 + 0.26 * float(i - 17)) + 2.2 * prev) : 0.0) + 0.25);
            if (i < 17) slope += W.xy * (cph * s * rs);
            else { rslope += W.xy * (cph * s * rs); rvar += s * s * rs * rs * 0.5; }
            // Gerstner: normals tip faster over the crests and lie flatter in the troughs.
            sharp += sph * s * rs * 1.3;
            unres += (1.0 - rs * rs) * s * s * 0.5;
            if (i == 2) swell = clamp(1.0 + 0.6 * sharp / (1.3 * steep * (0.5 + 0.8 * waves)), 0.35, 1.8);
            if (i >= 4) warp += 1.6 * sph;
            prev = cph;
        }
        // Weather on the water: rain roughens it all over (what the pixel can't resolve), and
        // near the camera its rings run out across the waves; whitecaps on the crests.
        float splash = 0.0, foam = 0.0;
        if (wx) {
            unres += 0.010 * W.rain;
            if (W.rain > 0.01 && fz < 0.05) {
                float4 rg = wx_rings(w, ts, fz, W.rain);
                slope += rg.xy;                             // (both normals see them)
                unres += rg.z;
                splash = rg.w * W.rain;
            }
            if (W.wind > 6.0) {
                // Whitecaps: the steepest crests break where a patchy field says so (it drifts
                // down-wind and churns), bubbly and streaked; far off, their mean coverage.
                float cov = min(1e-5 * pow(W.wind, 3.4), 0.3);     // (Monahan-like, ×2.5)
                float crest = sharp / (1.3 * steep * (0.5 + 0.8 * waves));
                float far = smoothstep(0.15, 1.5, fz);
                foam = far < 1.0 ? wx_whitecaps(w, ts, cov, fz, crest) : 0.0;
                foam = mix(foam, cov * 0.8, far);
            }
        }
        // Two normals: the full one (swell, chop and ripples) catches the sun's glints; the
        // sky is mirrored by a smoothed one, where the ripples count mostly as roughness —
        // a mirror wrinkled finer than the swells blurs what it reflects instead of crazing
        // it into hard-edged islands of cloud and sky.
        float ny = max(1.0 - sharp, 0.4);
        float3 n = normalize(float3(-(slope.x + rslope.x), ny, -(slope.y + rslope.y)));
        float3 nr = normalize(float3(-(slope.x + 0.25 * rslope.x), ny, -(slope.y + 0.25 * rslope.y)));
        float3 v = -rw;
        float3 rr = reflect(rw, nr);
        // Rough-mirror average: facets tilted toward the eye dominate what we see, so a
        // rough patch mirrors sky from higher up (darker, bluer) than a flat mirror would.
        // (A smooth max, so the reflected elevation never folds into hard bands, and never
        // dips below the horizon.)
        float sig = sqrt(unres + 0.94 * rvar + 0.0004);
        float ry = rr.y;
        rr.y = 0.5 * (ry + sqrt(ry * ry + (sig + 0.004) * (sig + 0.004))) + 0.3 * sig;
        rr = normalize(rr);
        float F0 = nature_schlick(max(dot(nr, v), 0.0));
        float3 sky = nature_oceanAtmos(rr, P, u, true, wx);
        float rcov;
        // The reflected sky is seen through a rough, curved mirror: each pixel spans about
        // 2σ of slope plus however fast the mirror turns from pixel to pixel.
        float spread = 2.0 * sig + length(fwidth(rr));
        // (Weather: under a closed deck that reaches the horizon its lumps don't survive the rough
        // mirror — the deck's own light, the atmosphere's 'air', stands in for them; not while
        // lightning lights the deck from inside.)
        float3 refl = (wx && P.deck > 0.99 && P.dx > 1000.0 && P.flash.b <= 0.0)
                    ? sky : nature_oceanClouds(rr, sky, P, 2, rcov, u, spread, wx, cu);
        if (wx) {
            if (flashE > 0.0 && ev.z < 0.4)
                refl += float3(0.85, 0.88, 1.0) * (P.flash.b * 60.0) * wx_bolt(rr, ev.x * 0.7, atan(P.hb / (2.5 + 6.0 * ev.y)), ev.w * 97.0, spread * 0.5 + P.pix);
            // The mirrored sky lies behind the same fog as the sky itself.
            if (fogB > 0.0)
                refl = mix(refl, fogA + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(dot(rr, P.sd), 0.8) * 0.035,
                           1.0 - exp(-fogB * min(fogH / max(rr.y, 0.004), 30000.0)));
        }
        // Sun glitter: Beckmann lobe over the filtered slope variance, so the sun's path
        // widens and softens into a glitter column with distance.
        float sig2 = 0.0005 + 0.0010 * waves + unres + 0.006 * (1.0 - exp(-dist / 150.0));
        float3 h = normalize(P.sd + v);
        float hn = max(dot(h, n), 1e-3);
        float t2 = (1.0 - hn * hn) / (hn * hn);
        float D = exp(-t2 / sig2) / (NATURE_PI * sig2 * hn * hn * hn * hn);
        float Fh = nature_schlick(max(dot(h, v), 0.0));
        // (Partly cloudy: the heaps' shadows drift over the sea — no glitter, no sunlit water.)
        float cuSh = 1.0;
        if (wx && cu) {
            float cuA = nature_wxCu(u);
            if (cuA > 0.0) cuSh = 1.0 - 0.88 * cuA * nature_wxCuShadow(w, P, nature_wxCuThr(u));
        }
        float sunUp = smoothstep(-0.012, 0.004, P.se) * (sunVis * sunT) * cuSh;
        float3 glint = P.esun * Tsun * sunUp * Fh * D * 0.775 / (4.0 * max(dot(n, v), 0.08)) * 0.1;
        // Near the camera the glitter resolves into separate glints: one capillary facet per
        // cell of water, its slope rocking slowly as the ripples pass, flashing where it sweeps
        // through the sun's mirror slope. Facets hold the sun's own radiance, drift with the
        // wind, live several frames (no per-frame flicker) and are drawn as dots filtered by
        // the pixel footprint. Cells scale with the output, so thumbnails sparkle like 5K.
        float cs = 0.07 * max(P.pix * 2380.0, 1.0);
        float near = smoothstep(cs * 0.55, cs * 0.25, fz);
        if (near > 0.0 && sunUp > 0.0) {
            float2 sh = h.xz / h.y - n.xz / n.y;              // mirror slope − surface slope
            const float sm = 0.10;                            // capillary facet slope spread
            if (dot(sh, sh) < 9.0 * sm * sm) {
                float2 wc = w - float2(0.25, -0.9) * ts * 0.18;   // facets drift down-wind
                float2 cid = floor(wc / cs);
                float3 h1 = pcg3(float3(cid, 17.0)), h2 = pcg3(float3(cid, 29.0));
                float2 m = (h1.xy - 0.5) * 1.6 * sm
                         + 0.75 * sm * float2(sin(ts * (0.9 + 0.9 * h1.z) + h2.x * 6.283),
                                              cos(ts * (0.7 + 0.9 * h2.x) + h1.z * 6.283));
                float2 dl = sh + m;
                float flash = exp(-dot(dl, dl) * (1.0 / 0.0012));
                if (flash > 0.002) {
                    float2 dd = wc - (cid + 0.25 + 0.5 * h2.yz) * cs;
                    // A short dash along the crest (facets are longer across the view).
                    float rg = cs * 0.09, rgx = rg * (1.6 + 0.8 * h1.x);
                    float ra = max(rg / fz, 0.7), rb = max(rgx / fx, 0.8);    // radii, pixels
                    float da = dot(dd, vh) / fz, db = (dd.x * vh.y - dd.y * vh.x) / fx;
                    float dot2 = exp(-(da * da) / (ra * ra) - (db * db) / (rb * rb));
                    float en = min((rg / fz) * (rgx / fx) / (ra * rb), 1.0);
                    glint += P.esun * Tsun * sunUp * Fh * 40.0 * flash * dot2 * en * near;
                }
            }
        }
        // Light scattered up out of the water body.
        float3 deep = srgbToLinear(u.colorA.rgb);
        // (Weather: under a deck the sea turns grey-green; snow greys it.)
        if (wx) deep = mix(deep, mix(deep * float3(0.85, 1.18, 0.88), float3(luma(deep)) * 1.1, W.snow), P.deck * 0.7);
        // Skylight on the water ≈ the sky it reflects (already in hand), a bit bluer.
        // Haze colour: the horizon's own. (Live: far off, the roughened reflection already
        // looks at the horizon sky, so it doubles as that — one sky evaluation fewer.)
        float3 hz = sky;
        if (!live) hz = nature_oceanAtmos(normalize(float3(rw.x, 0.004, rw.z)), P, u);
        float bodySun = (live ? smoothstep(-0.07, 0.0, P.se) : 1.0) * (sunVis * sunT) * cuSh;
        float day = live ? nature_liveDay(u) : 0.0;
        // (A high sun lights the water column itself: the sea turns blue, not grey.)
        float3 body = deep * (sky * float3(0.9, 1.0, 1.15) + P.esun * Tsun * (0.04 + 0.8 * day) * max(P.sd.y + 0.1, 0.0) * bodySun);
        if (wx) body += deep * ambL * (2.5 * P.deck);           // (the deck's diffuse light, into the water)
        // Smith-style masking: on rough water at grazing angles, much of the mirror is
        // hidden behind wave crests, so the far sea sits darker than the sky it reflects.
        float G = 1.0 / (1.0 + 0.5 * sqrt(unres + 0.0015) / max(-rw.y, 0.004));
        colSea = refl * F0 * G + body * (1.0 - F0 * G) + glint;
        if (wx) {
            // Foam: white water lit by the whole sky (and the sun, where it gets through).
            // (Foam is a heap of bubbles, not a flat sheet: it catches a low sun too.)
            float3 foamC = ambL * 1.3 + P.esun * Tsun * (sunVis * sunT) * (max(P.sd.y, 0.0) + 0.15 * smoothstep(-0.02, 0.05, P.se)) * 0.2
                         + P.flash * 0.15;
            // (Brighter heaped on the crests, greyer where it lies thin in the troughs.)
            foamC *= 0.7 + 0.3 * saturate(sharp / (1.3 * steep * (0.5 + 0.8 * waves)) * 0.5 + 0.5);
            colSea = mix(colSea, foamC, foam * 0.85) + ambL * (splash * 1.5);
        }
        // Haze over distance, toward the horizon's own colour.
        colSea = mix(colSea, hz, 1.0 - exp(-dist * (0.00004 + 0.00012 * haze)));
        if (wx && max(W.rain, 0.8 * W.storm) > 0.45 && dist > 2500.0) {
            // The rain curtains stand on the sea out there and hide what lies beyond.
            float a = wx_curtains(atan2(rd.x, rd.z), 0.0, atan(P.hb / 7.0), P.tc,
                                  smoothstep(0.45, 0.95, max(W.rain, 0.8 * W.storm)) * 0.85) * smoothstep(2500.0, 6000.0, dist);
            colSea = mix(colSea, ambL * 0.5 + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(dot(rd, P.sd), 0.8) * 0.08, a);
        }
        if (wx && fogB > 0.0) {
            float3 fc = fogA + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(dot(rd, P.sd), 0.8) * 0.025 + P.flash * 0.05;
            colSea = mix(colSea, fc, 1.0 - exp(-fogB * dist));
        }
    }
    if (hcov > 0.0) {
        float3 sky = nature_oceanAtmos(rd, P, u, false, wx);
        // (Weather: the disc goes on after the fog, dimmed once by it — a pale disc in fog.)
        float3 discL = float3(0.0);
        if (!keyMoon && sunVis > 0.0) {
            // Sun disc (flattened by refraction near the horizon), limb-darkened.
            float3 dv = rd - P.sd;
            float flat = mix(0.82, 1.0, smoothstep(0.0, 0.08, P.se));
            float ad = length(float2(dv.x, dv.y / flat));
            const float R = 0.0075;
            float disc = smoothstep(R + P.pix, R - P.pix, ad);
            float limb = sqrt(max(1.0 - (ad / R) * (ad / R), 0.0));
            discL = P.esun * Tsun * disc * (0.45 + 0.55 * limb) * 60.0;
            if (!wx) sky += discL;
        }
        // (The moon: only rows within its reach call out to draw it. Weather: hidden by the deck.)
        if (live && abs(rd.y - sin(0.40 * tanh(u.moon.x / 0.40))) < 0.02)
            sky += nature_oceanMoonNear(rd, u, P.tauT, P.pix) * (wx ? (keyMoon ? sunVis * sunT : 1.0 - P.deck) : 1.0);
        float cov;
        col = nature_oceanClouds(rd, sky, P, 5, cov, u, 0.0, wx, cu);
        if (wx) {
            // Rain curtains hanging off the deck far out; fog; a bolt down to the sea (in front
            // of the curtains, seen through the rain — it is bright enough to show through a lot).
            float az = atan2(rd.x, rd.z);
            float cu = max(W.rain, 0.8 * W.storm);
            if (cu > 0.45) {
                float a = wx_curtains(az, max(rd.y, 0.0), atan(P.hb / 7.0), P.tc, smoothstep(0.45, 0.95, cu) * 0.85);
                float3 cC = ambL * 0.5 + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(dot(rd, P.sd), 0.8) * 0.08
                          + P.flash * (0.04 + 0.5 * exp(6.0 * (dot(rd, P.fd) - 1.0)));
                col = mix(col, cC, a);
            }
            if (fogB > 0.0) {
                float cs = dot(rd, P.sd);
                float3 fc = fogA + P.esun * Tsun * (sunVis * sqrt(sunT)) * (nature_hg(cs, 0.8) * 0.025 + nature_hg(cs, 0.97) * 0.0015)
                          + P.flash * (0.04 + 0.3 * exp(6.0 * (dot(rd, P.fd) - 1.0)));
                col = mix(col, fc, 1.0 - exp(-fogB * min(fogH / max(rd.y, 0.004), 30000.0)));
            }
            // (Through a mostly-closed deck the disc is diffused away — only its glow shows; in
            // fog it is a pale disc in a bright halo.)
            col += discL * ((1.0 - cov) * sunVis * sunVis * sunT * sqrt(sunT));
            if (flashE > 0.0 && ev.z < 0.4) {
                float dB = 2.5 + 6.0 * ev.y;
                col += float3(0.85, 0.88, 1.0) * (P.flash.b * 60.0) * exp(-0.5 * min(fogB * dB * 1000.0, 3.0))
                     * wx_bolt(rd, ev.x * 0.7, atan(P.hb / dB), ev.w * 97.0, P.pix * 0.7);
            }
        }
        // Stars behind the clouds: only what the clouds leave open is worth computing.
        if (live && nature_liveDD(u) > 8.5 && cov < 0.9)
            stars = nature_oceanStars(rd, u, P.pix, t) * ((1.0 - cov) * smoothstep(0.9, 0.6, cov) * hcov);
    }
    col = mix(colSea, col, hcov);
    if (wx && W.wet > 0.005) {
        float cs = dot(rd, P.sd);
        if (W.snow > 0.0) {
            // Snow too far off to see as flakes: a pale veil, thickest along the horizon (a
            // softer, lower-contrast line), lit like the flakes.
            float vk = W.snow * (0.10 + 0.42 * exp(-abs(rd.y) * 28.0));
            col = mix(col, fogA * 1.05 + ambL * 0.1, vk);
        }
        // Rain or snow between the camera and everything (coverage found up front, above).
        // (A drop is a tiny wide-angle lens: it shows the whole bright sky, and glints backlit.)
        float3 dropL = ambL * 1.8 + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(cs, 0.8) * 0.08 + P.flash * 0.25;
        col = mix(col, dropL, rainA);
        // Flakes: lit by the whole sky above them — white over the sea, and still brighter than a
        // pale sky, which their faint shadow ring parts them from — and by the sun where it gets
        // in under the cloud, most of all toward it (snow backlit by a low sun glows).
        // (By night they catch the glow of the cloud and the coast, a little whiter than it.)
        float nK = live ? smoothstep(3.0, 12.0, nature_liveDD(u)) : 0.0;
        // (Snow is white: the low sun's red is half lost in it — gold-white, brightest toward it.)
        float3 fsun = P.esun * Tsun * (sunVis * sqrt(sqrt(sunT))) * (0.015 + 0.5 * nature_hg(cs, 0.65));
        float3 flakeL = mix(ambL, float3(luma(ambL)), 0.2 + 0.3 * nK) * (2.2 + 1.3 * nK)
                      + mix(fsun, float3(luma(fsun)), 0.45) + P.flash * 0.3;
        col *= 1.0 - 0.22 * snowA.y;
        col = mix(col, flakeL, snowA.x);
    }
    // Partial white balance toward the low sun (as a camera would): gold, not red.
    // (Live: only while the sun is up, so the hand-over to moonlight is seamless — and
    // skipped outright once it has nothing to do.)
    float seS = nature_oceanSunEl(u, live);
    float wbAmt = live ? 0.12 * smoothstep(-0.07, -0.02, seS) : 0.12;
    if (wbAmt > 0.0) {
        float3 TsunS = exp(-P.tauT * nature_airmass(seS));
        float3 wb = TsunS / max(max(TsunS.r, TsunS.g), 1e-4);
        col /= mix(float3(1.0), max(wb, 0.05), wbAmt);
    }
    // Weather: a camera opens up a little under a deck (a grey day reads grey, not murky);
    // less in a storm, which should stay dark.
    if (wx) col *= 1.0 + P.deck * (0.3 - 0.25 * W.storm);
    if (live) col = col * nature_oceanExpo(u) + stars;
    return float4(nature_display(col, px), 1.0);
}
__attribute__((noinline))
static float4 nature_oceanLive(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u) {
    return nature_ocean(uv, res, px, t, u, true);
}
// The weather copies (u.weather2.w = 1) are drawn by their own fragment function, fx_wx_ocean
// (Shared/Weather/Weather_fragment.h): anywhere inside fx_fragment they doubled the clear sky's
// cost (the über-shader allocates registers for its heaviest path).


// ---------------------------------------------------------------- rain on glass (case 58)
//
// Behind the glass: a night street, entirely out of focus — lamps, lit windows, traffic —
// drawn as bokeh discs whose size and brightness follow the blur (energy-conserving: a
// light defocused to twice the radius is a quarter as bright).
// On the glass, the three kinds of water a real window carries in the rain:
//  • mist — a film of tiny droplets (what makes glass look fogged): it veils the street into
//    a soft haze and gives the glass its fine stippled texture;
//  • beads — drops at two scales that land, linger and evaporate, each clearing a little
//    ring of mist around itself;
//  • runners — big drops that slide down in stop-go jerks, wiping a clear, wet trail through
//    the mist and leaving a line of small beads behind.
// Every drop is a real lens: a spherical cap (contact angle ~45–75°) refracting by Snell's
// law, so it shows a sharp, inverted, wide-angle picture of the street (its lights become
// bright points), darkens toward the rim where the light is totally internally reflected,
// and carries a small highlight of the street lamp above. Drop outlines, the refracted
// picture (sampled with a blur at least as wide as the pixel's footprint in it) and the
// mist droplets are all filtered by the pixel footprint, so nothing crawls at any size.

// The water on the glass as one height field (screen units): the smooth union of every
// drop's spherical cap, so drops that touch merge through a curved neck of water instead
// of meeting on a hard seam. It goes negative outside the drops (continuing the rim's
// slope), which gives each outline its antialiased coverage.
struct NatureRainDrop {
    float  H;      // water height (screen units); < 0 outside, by the distance to the rim × slope
    float2 G;      // its gradient (the surface slope; points uphill, toward the drop centre)
    float  r;      // radius of the tallest drop here (screen units)
    float  near;   // distance to the nearest drop rim, in its radii (mist clears around drops)
    float  trail;  // wet streak / cleared mist 0..1
    float  tdx;    // signed position across the streak, -1..1
};

// A cheap integer hash of a 2D lattice point (+ seed) → three floats in [0,1): one multiply
// round instead of pcg3's two, for the many per-cell lookups the glass makes per pixel.
static inline float3 nature_hash3(float2 id, uint seed) {
    uint2 ui = uint2(int2(id) + 0x8000);
    uint n = (ui.x * 0x8da6b343u) ^ (ui.y * 0xd8163841u) ^ (seed * 0x9e3779b9u);
    n = (n ^ (n >> 16u)) * 0x7feb352du;
    n ^= n >> 15u;
    return float3(float(n & 0x3ffu), float((n >> 10u) & 0x3ffu), float(n >> 20u))
         * float3(1.0 / 1024.0, 1.0 / 1024.0, 1.0 / 4096.0);
}

// Polynomial smooth max of two water surfaces (heights a, b; gradients ga, gb), blend k.
static inline void nature_waterUnion(thread float &H, thread float2 &G, float h, float2 g, float k) {
    float w = saturate(0.5 + 0.5 * (h - H) / k);
    H = mix(H, h, w) + k * w * (1.0 - w);
    G = mix(G, g, w);
}

// Add one drop (centre c, radii r, outline irregularity `shape`, seed k → contact angle).
// Water on glass is never a perfect circle: `shape` gives each its own slightly irregular
// outline, heavier toward the bottom.
static inline void nature_dropTake(thread NatureRainDrop &D, float2 p, float2 c, float2 r, float2 shape,
                                   float k, float pix) {
    float2 o = (p - c) / r;
    float l2 = dot(o, o);
    if (l2 > 3.3) return;                                  // beyond 1.6 radii even after `shape`
    float l = sqrt(l2);
    float2 n = o / max(l, 1e-4);
    float rf = 1.0 + 0.09 * (n.x * n.x - n.y * n.y) * shape.x + 0.07 * n.x * n.y * shape.y + 0.06 * n.y
             + 0.05 * n.x * (n.x * n.x - 3.0 * n.y * n.y) * shape.y;
    o /= rf;
    l /= rf;
    D.near = min(D.near, l);
    // Spherical cap, sin(contact angle) st (30°–53°: rain on window glass): sphere radius
    // Rs = 1/st drop radii, rim slope tan θc = 1/√(Rs² − 1).
    float st = mix(0.50, 0.80, k);
    float Rs2 = 1.0 / (st * st);
    float c0 = sqrt(Rs2 - 1.0), tEdge = 1.0 / c0;
    float2 dl = float2(o.x / r.x, o.y / r.y) / max(l, 1e-4);             // ∂l/∂p
    float h;
    float2 g;
    if (l < 1.0) {
        float s = sqrt(Rs2 - l * l);
        h = r.x * (s - c0);
        g = -r.x * (l / s) * dl;
    } else {
        h = (1.0 - l) * r.x * tEdge;
        g = -r.x * tEdge * dl;
    }
    if (h > D.H) D.r = r.x;
    nature_waterUnion(D.H, D.G, h, g, 0.3 * r.x * (sqrt(Rs2) - c0) + 0.5 * pix);
}

// Static beads on a grid of cell size `cs`; they grow in, linger, then evaporate.
// Static beads on a grid of cell size `cs`; they grow in, linger, then evaporate. Rain lands
// unevenly — some patches of glass carry more beads than others — judged at each bead's own
// centre (judged per pixel, a bead could be half there, cut along the patch's contour).
// `one`: small beads kept well inside their own cell, so only that cell is looked up.
static inline void nature_beads(thread NatureRainDrop &D, float2 p, float cs, float density, float t,
                                float seed, float pix, const bool one = false) {
    float2 g = p / cs;
    float2 ci = floor(g);
    float2 dir = one ? float2(0.0) : float2(g.x - ci.x < 0.5 ? -1.0 : 0.0, g.y - ci.y < 0.5 ? -1.0 : 0.0);
    uint sd = uint(seed) * 0x9e3779b9u;
    for (int k = 0; k < (one ? 1 : 4); ++k) {
        float2 id = ci + dir + float2(float(k & 1), float(k >> 1));
        uint2 ui = uint2(int2(id) + 0x8000);
        uint n = (ui.x * 0x8da6b343u) ^ (ui.y * 0xd8163841u) ^ sd;
        n = (n ^ (n >> 16u)) * 0x7feb352du;
        n ^= n >> 15u;
        float3 h = float3(float(n & 0x3ffu), float((n >> 10u) & 0x3ffu), float(n >> 20u))
                 * float3(1.0 / 1024.0, 1.0 / 1024.0, 1.0 / 4096.0);
        float2 c = (id + (one ? 0.32 + 0.36 * h.xy : 0.2 + 0.6 * h.xy)) * cs;
        // Too far to touch p (even with its mist ring: a small bead is ≤ 0.25 cells across)?
        // Checked first, so most of the glass skips the patchiness below.
        float2 dv = p - c;
        if (dot(dv, dv) > cs * cs * (one ? 0.2 : 0.49)) continue;
        float patch = 0.5 + 0.5 * nature_sinT(c.x * 0.61 + seed * 0.37) * nature_sinT(c.y * 0.83 + 0.11 * seed)
                    + 0.25 * nature_sinT(c.x * 1.7 - c.y * 1.3 + seed);
        if (h.z > density * (0.35 + 0.9 * saturate(patch))) continue;
        float3 h2 = fract(h.yzx * 91.37 + h.zxy * 17.13 + 0.31);     // second draw, no rehash
        float life = fract(t * (0.03 + 0.05 * h2.y) + h2.x);
        float grow = smoothstep(0.0, 0.05, life) * smoothstep(1.0, 0.7, life);
        // (Water gathers as it runs down: beads are bigger low on the glass. Capped so the
        // bead, its irregular outline and its mist ring stay inside the 2×2 cells searched.)
        float r = min(cs * (0.11 + 0.31 * h2.z * h2.z) * grow * (0.85 + 0.3 * saturate(c.y)), (one ? 0.25 : 0.40) * cs);
        if (r <= 0.5 * pix) continue;
        nature_dropTake(D, p, c, float2(r, r * (0.92 + 0.14 * h2.x)), h.xy * 2.0 - 1.0, h2.y, pix);
    }
}

// Running drops: one per column, sliding down in jerks along a meandering path.
static inline void nature_runners(thread NatureRainDrop &D, float2 p, float cw, float density, float t,
                                  float pix) {
    float col = floor(p.x / cw);
    for (int k = -1; k <= 1; ++k) {
        float id = col + float(k);
        float3 h = nature_hash3(float2(id, 5.0), 19u);
        if (h.z > density) continue;
        float tau = t * (0.05 + 0.07 * h.x) + h.y * 7.0;
        float cyc = floor(tau);
        float seedx = nature_hash3(float2(id, cyc), 31u).x;
        float x0 = (id + 0.25 + 0.5 * seedx) * cw;
        if (abs(p.x - x0) > 0.6 * cw) continue;            // path, drop and trail stay within this
        float3 h2 = nature_hash3(float2(id, 8.0), 23u);
        float ft = fract(tau);
        // Stop-go: the drop gathers, lurches, gathers again.
        float steps = 7.0;
        float st = ft * steps;
        float jerk = (floor(st) + pow(smoothstep(0.35, 1.0, fract(st)), 1.5)) / steps;
        float y = -0.25 + 1.5 * jerk;
        // The path wanders where the glass is slightly greasier: smooth noise, not a sine.
        float sx = seedx * 50.0, sx2 = h2.x * 40.0;
        float px0 = x0 + cw * (0.30 * (nature_n1(p.y * 4.0 + sx) - 0.5) + 0.07 * (nature_n1(p.y * 16.0 + sx2) - 0.5));
        float yd = y;
        float xd = x0 + cw * (0.30 * (nature_n1(yd * 4.0 + sx) - 0.5) + 0.07 * (nature_n1(yd * 16.0 + sx2) - 0.5));
        float r = cw * (0.14 + 0.08 * h2.y);
        // The drop: a little wider at the bottom (teardrop), stretched along its run.
        float2 dc = float2(xd, yd);
        float2 q = p - dc;
        float ry = r * (q.y < 0.0 ? 1.45 : 1.05);
        nature_dropTake(D, p, dc, float2(r, ry), float2(0.5, h2.x - 0.5), 0.75 + 0.25 * h2.z, pix);
        // The trail above it: a wet streak and a line of tiny droplets left behind.
        float above = yd - p.y;
        float tl = 0.35 + 0.3 * h2.z;
        if (above > 0.0 && above < tl) {
            float dx = abs(p.x - px0);
            float fade = 1.0 - above / tl;
            float tw = r * (0.7 + 0.2 * fade);
            float tr = smoothstep(tw, tw * 0.6, dx) * (0.4 + 0.6 * fade);
            if (tr > D.trail) { D.trail = tr; D.tdx = (p.x - px0) / tw; }
            float cs = r * 0.9;
            float yi = floor(p.y / cs);
            float3 hb = nature_hash3(float2(id * 131.0 + cyc, yi), 47u);
            if (hb.z < 0.55 * fade + 0.15) {
                float rr = r * (0.18 + 0.25 * hb.x) * (0.5 + 0.5 * fade);
                float cy = (yi + 0.5) * cs;
                float cx = x0 + cw * (0.30 * (nature_n1(cy * 4.0 + sx) - 0.5) + 0.07 * (nature_n1(cy * 16.0 + sx2) - 0.5))
                         + (hb.y - 0.5) * r * 0.6;
                nature_dropTake(D, p, float2(cx, cy), float2(rr, rr), hb.xy - 0.5, hb.y, pix);
            }
        }
    }
}

// One bokeh layer: lights on a grid (cell `cs`), radius grows with blur, brightness falls
// as 1/r² so the light's energy is conserved, with a faint glow skirt (lens veiling).
// `kind` picks colours/placement; `pres` is the share of cells holding a light. `minR`
// floors the disc radius (a refracted view is filtered by its own pixel footprint).
static inline float3 nature_bokehLayer(float2 p, float cs, float r0, float blur, float2 drift,
                                       float yLo, float yHi, int kind, float3 lamp, float seed, float pres,
                                       float minR = 0.0, float halo = 0.0, bool cheap = false) {
    float reach = 0.65 + 0.35 * halo;
    if (p.y < yLo - cs * reach || p.y > yHi + cs * reach) return float3(0.0);   // outside the band
    float2 q = (p + drift) / cs;
    float2 ci = floor(q);
    // Only the 2×2 cells nearest p can reach it: radii stay under ~0.48 cell (with the
    // glow skirt, under 0.65), and centres sit at least 0.15 cell inside their cell.
    float2 dir = float2(q.x - ci.x < 0.5 ? -1.0 : 0.0, q.y - ci.y < 0.5 ? -1.0 : 0.0);
    // (Capped so disc, edge and glow stay inside the 2×2 cells searched: ≤ 0.65 cell.)
    float R = min(max(r0 * (0.08 + 1.0 * blur), minR), 0.36 * cs);
    // (Through mist (halo) the disc's edge dissolves into a glow.)
    float soft = min(R * (0.06 + 0.22 * blur + 0.45 * halo) + 0.0012 + minR * 0.5, 0.09 * cs);
    float3 acc = float3(0.0);
    for (int k = 0; k < 4; ++k) {
        float2 id = ci + dir + float2(float(k & 1), float(k >> 1));
        // (The refracted views inside drops are tiny and inverted: no one can tell their
        // lights from the street's, so they take the cheap hash.)
        float3 h = cheap ? nature_hash3(id, uint(seed)) : pcg3(float3(id, seed));
        if (h.z > pres) continue;
        float2 c = (id + 0.15 + 0.7 * h.xy) * cs - drift;
        if (c.y < yLo || c.y > yHi) continue;
        float3 h2 = fract(h.yzx * 91.37 + h.zxy * 17.13 + 0.31);     // second draw, no rehash
        float d = length(p - c);
        float rr = R * (0.55 + 0.9 * h2.z);
        float rh = min(rr * (1.35 + 1.4 * halo) + soft, 0.65 * cs);
        if (d > rh) continue;
        float3 col;
        if (kind == 0) {          // lit windows: warm, cool and the odd coloured one
            col = h2.x < 0.55 ? float3(1.0, 0.72, 0.42) : (h2.x < 0.85 ? float3(0.70, 0.82, 1.0) : float3(0.30, 0.95, 0.85));
        } else if (kind == 1) {   // street lamps: the user's light colour
            col = lamp;
        } else if (kind == 2) {   // traffic: red tail lights / warm-white headlights
            col = h2.x < 0.55 ? float3(1.0, 0.10, 0.06) : float3(1.0, 0.88, 0.70);
        } else {                  // neon signs
            col = h2.x < 0.5 ? float3(1.0, 0.15, 0.55) : float3(0.15, 0.75, 1.0);
        }
        col *= 0.15 + 0.85 * h2.y * h2.y;                              // a wide range of brightness
        float disc = smoothstep(rr + soft, rr - soft, d);
        // A real lens's defocused disc: a little brighter toward its rim.
        float rim = 1.0 + 0.22 * smoothstep(rr * 0.5, rr, d) * blur;
        float energy = (r0 * 0.45) * (r0 * 0.45) / max(rr * rr, 1e-6);
        // Veiling glow: the lens's, and (halo > 0) the mist's, which spreads each light into a
        // soft corona.
        float skirt = exp(-max(d - rr, 0.0) / (rr * (0.12 + 0.55 * halo) + 1e-4)) * (0.12 + 0.30 * halo)
                    * smoothstep(rh, rr, d);
        acc += col * (disc * rim + skirt) * min(energy, 30.0);
    }
    return acc;
}

// The street behind the glass at blur 0..1 (0 = sharp pinpoints).
static inline float3 nature_street(float2 p, float aspect, float blur, float t, float3 night, float3 lamp,
                                   bool lite = false, float minR = 0.0, float halo = 0.0) {
    float y = p.y;
    float3 col = night * (0.55 + 1.5 * smoothstep(0.1, 0.95, y));                // sky → street glow
    // Big defocused colour washes: lamp-lit street low down, a neon glow, cool sky light.
    float wx = p.x / aspect;
    col += lamp * 0.030 * smoothstep(0.35, 1.0, y) * (0.6 + 0.4 * sin(wx * 4.0 + 1.0));
    float2 nd = (p - float2(aspect * 0.78, 0.42)) / float2(0.35, 0.22);
    col += float3(0.9, 0.18, 0.55) * 0.020 * exp(-dot(nd, nd));
    float2 cd = (p - float2(aspect * 0.18, 0.2)) / float2(0.4, 0.25);
    col += float3(0.25, 0.55, 0.9) * 0.012 * exp(-dot(cd, cd));
    if (!lite) col += nature_bokehLayer(p, 0.055, 0.016, blur, float2(0.0), 0.05, 0.60, 0, lamp, 3.0, 0.22, minR, halo, lite) * 0.6;
    col += nature_bokehLayer(p, 0.165, 0.050, blur, float2(0.0), 0.10, 0.58, 0, lamp, 5.0, 0.30, minR, halo, lite) * 0.7;
    if (!lite) col += nature_bokehLayer(p, 0.165, 0.050, blur, float2(0.0), 0.30, 0.50, 3, lamp, 11.0, 0.18, minR, halo, lite) * 0.9;
    col += nature_bokehLayer(p, 0.31, 0.095, blur, float2(0.0), 0.24, 0.58, 1, lamp, 9.0, 0.85, minR, halo, lite) * 1.6;
    col += nature_bokehLayer(p, 0.105, 0.032, blur, float2(t * 0.020, 0.0), 0.62, 0.74, 2, lamp, 15.0, 0.62, minR, halo, lite) * 1.5;
    col += nature_bokehLayer(p, 0.14, 0.042, blur, float2(-t * 0.035, 0.0), 0.70, 0.90, 2, lamp, 21.0, 0.55, minR, halo, lite) * 1.3;
    return col;
}

// asin to ~7e-5 (Abramowitz & Stegun 4.4.45), x in [0, 1].
static inline float nature_asin01(float x) {
    return 1.5707963 - sqrt(max(1.0 - x, 0.0)) * (1.5707288 + x * (-0.2121144 + x * (0.0742610 - 0.0187293 * x)));
}

// The mist droplet nearest p on a jittered grid: (coverage, radial position in its radii).
// Sizes spread widely, as condensation's do; cells scale with the output (at least ~6 px),
// so the stipple stays a fine stipple at any size.
static inline float2 nature_mist(float2 p, float pix, float density) {
    float cs = max(0.0062, 6.0 * pix);
    float2 g = p / cs;
    float2 ci = floor(g);
    float3 h = nature_hash3(ci, 61u);
    if (h.z > density) return float2(0.0, 1.0);
    float sz = h.z / max(density, 1e-3);                      // 0..1, uniform among the present
    float r = cs * (0.08 + 0.26 * sz * sz);
    float2 c = (ci + 0.5 + (h.xy - 0.5) * (0.92 - 2.0 * r / cs)) * cs;
    float rho = length(p - c) / r;
    return float2(saturate((1.0 - rho) * r / pix + 0.5), rho);
}

// RAIN ON GLASS. p0 = (speed, rain, condensation, city blur); colorA night, colorB lamp light.
static inline float3 nature_rainGlass(float2 uv, float2 res, float t, constant FXUniforms& u) {
    float speed = u.p0.x, rain = clamp(u.p0.y, 0.0, 1.0), fogAmt = clamp(u.p0.z, 0.0, 1.0);
    float blur = clamp(u.p0.w, 0.0, 1.0);
    float aspect = res.x / res.y;
    float2 p = float2(uv.x * aspect, uv.y);
    float pix = 1.0 / res.y;
    float ts = t * speed;
    float3 night = nature_lin(u.colorA.rgb);
    float3 lamp = srgbToLinear(u.colorB.rgb);

    NatureRainDrop D;
    D.H = -1.0; D.G = float2(0.0); D.r = 0.01; D.near = 9.0; D.trail = 0.0; D.tdx = 0.0;
    nature_runners(D, p, 0.11, 0.25 + 0.6 * rain, ts, pix);
    float trail = D.trail;
    NatureRainDrop B = D;
    B.H = -1.0; B.G = float2(0.0);
    nature_beads(B, p, 0.075, 0.14 + 0.50 * rain, ts, 2.0, pix);
    // Small beads on two lattices of unrelated pitch and offset: one lattice, filled up in
    // heavy rain, would line its beads up in rows and columns.
    nature_beads(B, p, 0.029, 0.10 + 0.31 * rain, ts, 7.0, pix, true);
    nature_beads(B, p + float2(0.0071, 0.0123), 0.0205, 0.10 + 0.31 * rain, ts, 11.0, pix, true);
    // Beads and runners are one body of water: where they touch, they merge.
    if (B.H > D.H) D.r = B.r;
    nature_waterUnion(D.H, D.G, B.H, B.G, 0.002);
    D.near = B.near;

    // Mist (condensation): patchy, thinner near the warm middle, wiped clean along trails,
    // and thinned in a ring around each drop (the drop drew those droplets in).
    float fogN = 0.7 + 0.5 * nature_gnoise(p * 3.0 + 1.7);
    float clearRing = smoothstep(1.0, 1.5, D.near);
    float fog = fogAmt * clamp(fogN, 0.0, 1.0) * (1.0 - 0.8 * trail) * (0.75 + 0.25 * clearRing);

    // The refracted view through the water under p (computed for every pixel, so the
    // footprint derivative below is well defined): the ray leaving the water bends by
    // Snell's law toward the uphill side — an inverted, wide-angle picture of the street.
    float sl = length(D.G);
    float2 gd = D.G / max(sl, 1e-5);
    float sa = sl * rsqrt(1.0 + sl * sl);                   // sine of the surface tilt
    float x = min(1.333 * sa, 1.0);
    float dev = nature_asin01(x) - nature_asin01(sa);       // deviation, radians
    float2 smp = p + gd * dev * 0.9;
    float fw = length(fwidth(smp));
    // Drop outline coverage: signed distance to the rim (height / slope), in pixels.
    float cov = saturate(D.H / (max(sl, 0.25) * pix) + 0.5);

    // (Each view is only evaluated where it shows: inside a drop the street behind the
    // glass is hidden, so whole SIMD groups inside drops skip it.)
    float3 col = float3(0.0);
    float bBack = blur * (0.7 + 0.3 * fog) + 0.06 + 0.25 * fog;
    if (cov < 1.0) {
        // A runner's wet streak is a thin cylindrical lens: it squeezes the street sideways.
        float2 sp = p + float2(D.tdx * 0.008 * trail, 0.0);
        col = nature_street(sp, aspect, bBack, ts, night, lamp, false, 0.0, fog);
        // The mist scatters light: lifts and flattens the street behind it, a cool veil.
        float3 fogC = night * 2.0 + lamp * 0.010;
        col = mix(col, fogC + col * 0.55, fog * 0.6);
        // Its droplets: each a tiny lens, a little brighter where it gathers the light behind
        // it and a little darker at its rim.
        float2 m = nature_mist(p, pix, 0.55 + 0.35 * fogAmt);
        if (m.x > 0.0) {
            float3 mc = col * (0.90 + 0.22 * smoothstep(0.85, 0.0, m.y))
                      + (night * 0.6 + lamp * 0.008) * smoothstep(0.4, 0.0, m.y) * 0.3;
            col = mix(col, mc, m.x * smoothstep(0.08, 0.35, fog) * clearRing);
        }
        // The streak's water film: a faint sheen along its edges.
        float ae = abs(D.tdx);
        col += (night * 0.9 + lamp * 0.01) * smoothstep(0.35, 0.95, ae) * trail * 0.5;
    }
    if (cov > 0.0) {
        // Through the water: sharp (a drop's focal length is tiny), filtered by the pixel's
        // footprint in the refracted picture.
        float3 seen = nature_street(smp, aspect, 0.10, ts, night, lamp, true, clamp(fw * 0.5, 0.0, 0.05));
        // Fresnel loss on the way out, rising to total internal reflection where the surface
        // is steepest. There the rim mirrors the drop's own far side back — the dark room
        // behind the camera and a dim, twice-bent copy of the street — a thin darker edge,
        // not an inked outline. The water and glass also scatter a little of the soft view in.
        float ct = sqrt(max(1.0 - x * x, 0.0));
        float Tr = (1.0 - nature_schlick(ct)) * smoothstep(0.0, 0.16, ct);
        float3 dc = (seen * 1.05 + night * 0.9 + lamp * 0.006) * Tr + (seen * 0.35 + night * 0.8) * (1.0 - Tr);
        // Light gathered into the lower edge, where the surface turns down (a caustic).
        float lower = smoothstep(0.2, 0.6, sl) * smoothstep(0.2, 0.9, -gd.y) * Tr;
        dc += (seen * 0.5 + night * 1.2 + lamp * 0.025) * lower;
        // The street lamp above-left mirrored in the water: a soft highlight with a hot core
        // where the surface faces it, faded out once smaller than a pixel.
        float2 hl = (D.G - float2(0.17, 0.25)) * 4.0;
        float hs = smoothstep(1.0, 3.0, D.r * 0.25 / pix);
        dc += (night * 3.0 + lamp * 0.10) * (exp(-dot(hl, hl) * 1.6) + 2.5 * exp(-dot(hl, hl) * 12.0)) * hs;
        col = mix(col, dc, cov);
    }
    return col;
}

// ---------------------------------------------------------------- snowfall (case 61)
//
// A real camera space (metres): eye 1.7 m up, the horizon a little below centre, a lamp
// post 7 m away, pines receding into fog. Snowflakes live on depth layers from 0.6 m to
// ~25 m; each layer's grid, size, fall speed and drift are divided by its depth, so
// parallax is exact. Every flake is lit by the lamp with inverse-square falloff and a
// strong forward-scattering lobe (flakes between you and the lamp sparkle), fogged by
// its depth, and drawn with a physically scaled circle of confusion: near flakes open
// into dim bokeh discs, far ones shrink to points, energy conserved.

struct NatureSnowP {
    float ts, wind, amount, aperture, zf, lampI, aspect, pix;
    float3 sky, lampC, fogC;
    float3 L;        // lamp position, metres (x right, y up from the eye, z forward)
    float h0;        // horizon height in screen units
};

constant float NATURE_SNOW_CAMH = 1.7;

// The forest edge stands on rolling ground, not a ruled line: each tree row sits on its own
// snowbank — a ridge of drifted snow and buried scrub whose height (metres) wanders along
// the row — which hides the trunks and the ground behind it.
// (1D value noise on a well-mixed integer hash: nature_h1's neighbours run correlated, which
// left long stretches of ridge flat.)
static inline float nature_nr(float x) {
    float i = floor(x), f = x - i;
    uint2 n = uint2(int2(int(i), int(i) + 1) + 0x8000) * 0x9e3779b9u;
    n ^= n >> 16u; n *= 0x7feb352du; n ^= n >> 15u; n *= 0x846ca68bu; n ^= n >> 16u;
    float2 h = float2(n >> 8u) * (1.0 / 16777216.0);
    return mix(h.x, h.y, f * f * (3.0 - 2.0 * f));
}
// The bank's mounds (what a tree stands on) and, on top, the scrub along its crest.
static inline float nature_snowMound(float wx, float seed, float amp) {
    float m = nature_nr(wx * 0.05 + seed);
    return amp * (0.25 + 1.1 * m * m) + 0.4 * amp * nature_nr(wx * 0.15 + seed * 1.7);
}
static inline float nature_snowRidge(float wx, float seed, float amp) {
    return nature_snowMound(wx, seed, amp) + 0.22 * nature_nr(wx * 0.9 + seed * 3.1) + 0.10 * nature_nr(wx * 2.7 + seed);
}

// Spruce silhouettes in a row at depth z, standing on its ridge: .x = coverage, .y = snow
// lying on the branches, .z = −1…1 across the tree (for the lamp-side light). Each tree is
// a stack of drooping branch tiers, widest at each tier's foot and narrowing to a spire,
// with needle clumps ragging the outline differently on each side.
static inline float3 nature_pineRow(float2 sp, float z, float h0, float seed, float pix, float amp) {
    float wx = sp.x * z;                              // metres across at that depth
    float wyE = (sp.y - h0) * z;                      // metres relative to the eye there
    const float sp_ = 4.2;
    float ci = floor(wx / sp_);
    float cov = 0.0, snow = 0.0, side = 0.0;
    float aa = pix * z * 1.2;                         // a pixel, in metres at that depth
    for (int j = -1; j <= 1; ++j) {
        float id = ci + float(j);
        float3 h = nature_hash3(float2(id, 5.0), uint(seed));
        if (h.z < 0.14) continue;
        float cx = (id + 0.2 + 0.6 * h.x) * sp_;
        // (Tall enough over their banks that the forest holds the frame, as it always has.)
        float H = 10.0 + 14.0 * h.y * h.y + 4.0 * h.z;
        if (h.z < 0.30) H *= 0.4;                     // young trees and scrub at the edge
        // (Cheap bounds first — the mound lies between 0.25 and 1.8 × amp — so the sky above
        // the forest and the bank below it skip the tree.)
        float wb = wyE + NATURE_SNOW_CAMH + 0.6;
        if (wb < 0.25 * amp || wb > 1.75 * amp + H + 0.6) continue;
        float base = nature_snowMound(cx, seed, amp) - NATURE_SNOW_CAMH - 0.6;
        float wy = wyE - base;                        // metres above this tree's foot
        if (wy < 0.0 || wy > H + 0.6) continue;
        float rel = saturate(1.0 - wy / H);           // 1 at the foot, 0 at the tip
        float nT = 7.0 + floor(5.0 * h.x);
        float env = H * 0.25 * rel + 0.05;
        float dx = wx - cx;
        float sgn = dx < 0.0 ? -1.0 : 1.0;
        float u0 = saturate(abs(dx) / env);
        // Needle clumps: ragged, and different on each side.
        float rag = nature_n1(wy * 3.1 + sgn * 7.3 + id * 1.37) - 0.5;
        float rag2 = nature_n1(wy * 9.0 + sgn * 3.1 + id * 2.11) - 0.5;
        // Tiers: each a drooping skirt, widest at its foot; the branches sag toward their tips,
        // so each tier's lower edge curves down and out (no ruled horizontal steps).
        float tt = fract(wy / H * nT + h.z * 3.0 + 0.32 * u0 * u0 + 0.10 * rag2);   // 0 foot … 1 top
        float w = env * (0.48 + 0.52 * pow(1.0 - tt, 0.7)) * (1.0 - 0.14 * smoothstep(0.10, 0.0, tt));
        w *= 1.0 + 0.30 * rag * smoothstep(0.0, 0.25, rel) + 0.14 * rag2;
        w = max(w, 0.06 + 0.06 * rel);               // the stem
        float c = smoothstep(w + aa, w - aa, abs(dx)) * step(wy, H + 0.6 * (1.0 - smoothstep(0.0, 0.08, abs(dx))));
        c *= smoothstep(H + 0.6, H - 0.2, wy + abs(dx) * 3.0);   // the spire
        if (c > cov) {
            cov = c;
            float u = abs(dx) / max(w, 1e-3);
            // Snow lies on each tier's upper face, out toward the branch tips, in clumps.
            float clump = nature_n1(wx * 2.3 + wy * 1.7 + id * 5.0);
            snow = smoothstep(0.45, 0.08, tt) * smoothstep(0.2, 0.75, u) * (0.45 + 0.75 * clump)
                 * (0.55 + 0.45 * h.y) * smoothstep(0.02, 0.2, rel);
            side = dx / max(w, 1e-3);
        }
    }
    return float3(cov, snow, side);
}

// The lamp is shaded: it throws a cone of light downward (soft-edged, ~55° half-angle).
static inline float nature_lampCone(float3 fromLamp) {
    float c = -fromLamp.y / max(length(fromLamp), 1e-4);
    return 0.06 + 0.94 * smoothstep(0.42, 0.70, c);
}

// Lamp light (both lamps) landing on snow at world point W (metres, eye-relative), facing up.
static inline float nature_snowPool(float3 W, NatureSnowP P) {
    float3 toL = P.L - W;
    float d2 = dot(toL, toL);
    float pool = P.lampI * max(toL.y, 0.0) / (d2 * sqrt(d2) + 0.5) * nature_lampCone(-toL);
    float3 toL2 = float3(-9.5, 3.0, 19.5) - W;                    // the far lamp's pool
    float e2 = dot(toL2, toL2);
    pool += P.lampI * max(toL2.y, 0.0) / (e2 * sqrt(e2) + 0.5) * nature_lampCone(-toL2) * 0.8;
    return pool;
}

// The path: trodden snow winding from the near lamp to the far one.
static inline float nature_snowPath(float x, float z) {
    float xc = mix(3.2, -9.0, smoothstep(5.0, 19.5, z)) + 0.7 * sin(z * 0.31 + 1.0);
    float w = 0.75 + 0.012 * z;
    return smoothstep(w, w * 0.45, abs(x - xc)) * smoothstep(20.5, 18.5, z) * smoothstep(1.5, 3.0, z);
}

// Everything behind the snow: sky, the forest edge on its snowbanks in fog, the lamp posts,
// the lit snowy ground with its path. Returns colour; `zb` is the depth of the first opaque
// surface (for flake occlusion).
static inline float3 nature_snowBack(float2 sp, NatureSnowP P, thread float &zb) {
    float3 col;
    zb = 1e4;
    float y = sp.y - P.h0;
    float2 lampS = float2(P.L.x / P.L.z, P.h0 + P.L.y / P.L.z);
    float dl = length(sp - lampS);
    if (y < 0.0) {
        // Ground: depth from the ground plane; the lamps' pools of light on the snow.
        float z = NATURE_SNOW_CAMH / max(-y, 1e-4);
        float3 W = float3(sp.x * z, -NATURE_SNOW_CAMH, z);
        float pool = nature_snowPool(W, P);
        // Soft drifts: their slopes face the sky (and the lamp) a little more or less.
        float drift = nature_gnoise(float2(W.x * 0.35, z * 0.5)) * 0.18 + nature_gnoise(float2(W.x * 1.3, z * 2.0)) * 0.07;
        float path = nature_snowPath(W.x, z);
        float3 snow = P.sky * 2.2 * (0.92 + drift) + P.lampC * pool * 2.6 * (0.9 + drift * 1.5);
        // Trodden snow: packed flatter (fewer drifts) and a touch darker in its trough, its
        // berms catching the light.
        float berm = path * (1.0 - path) * 4.0;
        snow = mix(snow, (P.sky * 1.55 + P.lampC * pool * 2.0), path * 0.85) + (P.sky * 0.35 + P.lampC * pool * 0.6) * berm * 0.6;
        // Glitter: ice crystals catching the lamp, fixed in the snow (world-space cells, at
        // least ~2 px), each a soft point, only where the lamp reaches.
        float fx = z * P.pix, fz = fx * z / NATURE_SNOW_CAMH;   // a pixel on the snow, metres
        float2 cs = max(float2(0.04), 2.6 * float2(fx, fz));
        float2 gc = float2(W.x, z) / cs;
        float2 gi = floor(gc);
        float3 g = nature_hash3(gi, 3u);
        if (g.z > 0.965) {
            float2 gd = (gc - gi - (0.25 + 0.5 * g.xy)) * cs / float2(fx, fz);   // pixels
            snow += P.lampC * pool * 9.0 * exp(-dot(gd, gd) * 1.4) * smoothstep(12.0, 3.0, z) * (1.0 - path);
        }
        float fogF = 1.0 - exp(-z * 0.045);
        col = mix(snow, P.fogC, fogF);
        zb = z;
    } else {
        // Sky: dusk gradient, brighter toward the horizon where the fog thickens.
        col = P.sky * (0.9 + 1.4 * exp(-y * 3.0));
        col = mix(col, P.fogC, exp(-y * 7.0));
    }
    // The forest edge, near to far: each row behind its snowbank, veiled by its depth's fog,
    // composited front to back so whatever a nearer bank or tree hides is never evaluated.
    float3 acc = float3(0.0);
    float T = 1.0, zr = 1e4;
    for (int r = 2; r >= 0 && T > 0.004; --r) {
        float z = r == 0 ? 70.0 : (r == 1 ? 38.0 : 21.0);
        if (z > zb) continue;
        float amp = r == 0 ? 7.0 : (r == 1 ? 3.6 : 2.2);
        float seed = float(r) * 13.0 + 1.0;
        float fogF = 1.0 - exp(-z * 0.042);
        float wx = sp.x * z;
        // The snowbank in front of the row (hiding the trunks): its crest silhouette, then its
        // face — snow at that depth, the crest's lip catching the sky.
        // (Above the highest the bank can reach, skip it: ridge ≤ 1.75·amp + 0.32 m.)
        float rc = 0.0, yr = 0.0;
        if ((sp.y - P.h0) * z + NATURE_SNOW_CAMH < 1.75 * amp + 0.35) {
            float ridge = nature_snowRidge(wx, seed, amp);
            yr = P.h0 + (ridge - NATURE_SNOW_CAMH) / z;
            rc = smoothstep(yr + P.pix * 0.7, yr - P.pix * 0.7, sp.y);
        }
        if (rc > 0.0) {
            float3 W = float3(wx, (sp.y - P.h0) * z, z);
            float pool = nature_snowPool(W, P);
            float crest = smoothstep(0.6, 0.0, (yr - sp.y) * z);
            float under = smoothstep(0.4, 2.2, (yr - sp.y) * z);          // its shaded face below
            float3 bank = P.sky * (2.2 + 0.5 * crest - 0.35 * under) + P.lampC * pool * 2.4;
            acc += T * rc * mix(bank, P.fogC, fogF * 0.92);
            T *= 1.0 - rc;
            if (rc > 0.5) zr = min(zr, z);
        }
        if (T <= 0.004) break;
        float3 pr = nature_pineRow(sp, z, P.h0, seed, P.pix, amp);
        float cov = pr.x;
        if (cov > 0.0) {
            // Needles: dark blue-green in the dusk, lifted on the side facing the lamp by its
            // light at that distance; snow on the tiers lit by sky and lamp.
            float3 W = float3(wx, (sp.y - P.h0) * z, z);
            float3 toL = P.L - W;
            float lampAt = P.lampI * 6.0 / (dot(toL, toL) + 4.0);
            float facing = saturate(0.5 + 0.5 * pr.z * (toL.x > 0.0 ? 1.0 : -1.0));
            float3 tc = P.sky * 0.20 * (0.85 + 0.3 * facing) + P.lampC * lampAt * (0.02 + 0.10 * facing * facing);
            tc = mix(tc, P.sky * 3.0 + P.lampC * lampAt * (0.45 + 0.4 * facing), saturate(pr.y) * 0.75);
            acc += T * cov * mix(tc, P.fogC, fogF);
            T *= 1.0 - cov;
            if (cov > 0.5) zr = min(zr, z);
        }
    }
    col = acc + T * col;
    zb = min(zb, zr);
    // A second lamp far down the path, mostly lost in the snow: depth, and somewhere to go.
    {
        const float3 L2 = float3(-9.5, 3.0, 19.5);
        float2 l2s = float2(L2.x / L2.z, P.h0 + L2.y / L2.z);
        float d2l = length(sp - l2s);
        float fog2 = exp(-L2.z * 0.03);
        float pw2 = max(0.05 / L2.z, P.pix * 0.6);
        float pole2 = smoothstep(pw2 + P.pix, pw2 - P.pix * 0.5, abs(sp.x - l2s.x));
        if (pole2 > 0.0 && sp.y < l2s.y && sp.y > P.h0 - NATURE_SNOW_CAMH / L2.z && L2.z < zb)
            col = mix(col, P.sky * 0.1, fog2 * pole2);
        col += P.lampC * P.lampI * (0.00006 / (d2l * d2l + 0.00002) + 0.02 * exp(-d2l * 8.0)) * (0.4 + 0.6 * fog2);
    }
    // The lamp post (7 m away): a slim iron pole, lit along the side facing... its own lamp
    // above barely reaches it; its base sits in a little drift.
    float poleX = lampS.x;
    float poleTop = lampS.y - 0.02;
    float groundAt = P.h0 - NATURE_SNOW_CAMH / P.L.z;
    float pw = (0.055 + 0.012 * smoothstep(poleTop, groundAt, sp.y)) / P.L.z;     // tapered
    float pc = smoothstep(pw + P.pix, pw - P.pix, abs(sp.x - poleX));
    if (pc > 0.0 && sp.y < poleTop && sp.y > groundAt - P.pix) {
        float glint = exp(-pow((sp.x - poleX) / pw + 0.45, 2.0) * 10.0);      // a soft specular line
        float3 pcol = P.sky * 0.06 + P.lampC * P.lampI * 0.02 * glint * smoothstep(groundAt, poleTop, sp.y);
        col = mix(col, pcol, pc);
        zb = P.L.z;
    }
    // Lantern: a dark cap (with a little snow on it) over a glowing glass bowl.
    float2 lq = (sp - lampS) * P.L.z;                     // metres around the lamp head
    float capY = 0.16 - 0.55 * lq.x * lq.x;
    float ea = P.pix * P.L.z;                             // a pixel in metres there
    float capC = smoothstep(0.42 + ea, 0.42 - ea, abs(lq.x)) * smoothstep(capY - 0.05 - ea, capY - 0.05 + ea, lq.y)
               * smoothstep(capY + 0.04 + ea, capY + 0.04 - ea, lq.y);
    if (capC > 0.0) {
        float snowCap = smoothstep(capY + 0.0, capY + 0.035, lq.y) * smoothstep(0.40, 0.2, abs(lq.x));
        col = mix(col, mix(P.sky * 0.08, P.sky * 1.6, snowCap), capC);
        zb = P.L.z;
    }
    float2 bq = lq / float2(0.24, 0.17);
    float bowl = smoothstep(1.0 + ea * 6.0, 1.0 - ea * 6.0, length(bq)) * step(lq.y, capY - 0.05);
    if (bowl > 0.0) { col = mix(col, P.lampC * P.lampI * 7.0 + 0.5, bowl); zb = P.L.z; }
    // Glow of the lamp in the falling snow and mist (single scattering around a point light).
    float glow = P.lampI * (0.0014 / (dl * dl + 0.0005) + 0.035 * exp(-dl * 3.5));
    // The cone of light in the snowy air: brightest near the lamp, soft-edged.
    float2 rel = sp - lampS;
    float ca = -rel.y / max(length(rel), 1e-4);
    float cone = smoothstep(0.45, 0.75, ca) * exp(-length(rel) * 1.6) * smoothstep(lampS.y + 0.01, lampS.y - 0.03, sp.y);
    col += P.lampC * (glow + P.lampI * 0.06 * cone);
    return col;
}

// Snowflakes in front of depth zb, summed over depth layers.
static inline float3 nature_snowFlakes(float2 sp, NatureSnowP P, float zb) {
    float3 acc = float3(0.0);
    for (int i = 0; i < 9; ++i) {
        float z = 0.55 * pow(1.47, float(i));
        if (z > zb) break;
        float cell = 0.32 / z;                                   // 0.32 m world spacing
        float r = 0.011 / z;                                     // ~1 cm flakes
        float fall = (0.9 + 0.08 * float(i & 3)) * P.ts / z;
        float drift = P.wind * P.ts * 0.9 / z;
        float2 off = float2(drift + 0.37 * float(i), -fall + 0.61 * float(i));
        float2 q = (sp + off) / cell;
        float2 ci = floor(q);
        float2 fq = q - ci;
        float coc = P.aperture * abs(1.0 / z - 1.0 / P.zf);
        float R = sqrt(r * r + coc * coc + P.pix * P.pix * 0.5);
        // Far layers: flakes stay within [0.2, 0.8] of their cell and their discs are capped
        // at 0.19 cell, so only their own cell can reach p. Near layers check the nearest 2×2.
        bool one = i >= 3;
        float2 dir = one ? float2(0.0) : float2(fq.x < 0.5 ? -1.0 : 0.0, fq.y < 0.5 ? -1.0 : 0.0);
        int nk = one ? 1 : 4;
        float energy = (r * r + P.pix * P.pix * 0.25) / (R * R);
        float fogT = exp(-z * 0.045);
        for (int k = 0; k < nk; ++k) {
            float2 id = ci + dir + float2(float(k & 1), float(k >> 1));
            float3 h = nature_hash3(id, uint(i) * 7u + 1u);
            if (h.z > P.amount) continue;
            float3 h2 = fract(h.yzx * 91.37 + h.zxy * 17.13 + 0.31);     // second draw, no rehash
            float jit = one ? 0.4 : 0.5;
            float2 c = (id + (1.0 - jit) * 0.5 + jit * h.xy) * cell - off;
            float rr = R * (0.6 + 0.8 * h2.z);
            if (one) rr = min(rr, 0.19 * cell / 1.6);
            float fa = cell * (one ? 0.1 : 0.15);                          // flutter amplitude
            // (Coarse reject before the flutter's sine: most cells' flakes are far from p.)
            float2 dq = sp - c;
            if (abs(dq.y) > rr * 1.6 || abs(dq.x) > rr * 1.6 + fa) continue;
            c.x += nature_sinT(P.ts * (0.143 + 0.127 * h2.x) + h2.y) * fa;   // flutter
            float d = length(sp - c);
            if (d > rr * 1.6) continue;
            // World position → lamp light (inverse square, forward-scattering lobe).
            float3 W = float3(c.x * z, (c.y - P.h0) * z, z);
            if (W.y < -NATURE_SNOW_CAMH) continue;                 // under the snow line
            float3 toL = P.L - W;
            float d2 = dot(toL, toL);
            float3 v = normalize(W);
            float fwd = max(dot(normalize(-toL), -v), 0.0);
            float phase = 0.35 + 3.0 * pow(fwd, 8.0);
            float3 lit = P.sky * 4.5 + P.lampC * P.lampI * phase * 9.0 * nature_lampCone(-toL) / (d2 + 0.6);
            // Focused flakes: soft gaussian points; defocused: flat bokeh discs.
            float shape = coc < r * 1.5 ? exp(-d * d / (rr * rr * 0.5))
                                        : smoothstep(rr, rr * 0.82, d) * (0.85 + 0.25 * smoothstep(rr * 0.5, rr, d));
            float3 fc = lit * shape * energy * (0.5 + 0.7 * h2.z);
            acc += mix(P.fogC * shape * energy * 0.6, fc, fogT);
        }
    }
    return acc;
}
