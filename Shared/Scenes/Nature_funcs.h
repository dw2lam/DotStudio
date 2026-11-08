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
    for (int L = 0; L < NL; ++L) {
        float sc = L == 0 ? 70.0 : (L == 1 ? 150.0 : 330.0);       // cells per radian
        float2 g = float2(az, rd.y) * sc;
        float2 cell = floor(g);
        float3 h = pcg3(float3(cell, seed + float(L) * 17.0));
        float2 off = (g - cell) - (0.2 + 0.6 * h.xy);
        float2 dAng = float2(off.x * ce, off.y / ce) / sc;          // radians on the sky
        float r = length(dAng) / pix;                                // pixels
        // Few cells hold a star (and most pixels are far from it): skip the rest early.
        if (h.z < (L == 0 ? 0.80 : (L == 1 ? 0.72 : 0.62)) || r > 4.0) continue;
        float3 h2 = pcg3(float3(cell + 913.0, seed + 5.0));
        // Magnitude follows a steep power law.
        float m = h2.x;
        float b = L == 0 ? 0.7 * pow(m, 6.0) + 0.025 : (L == 1 ? 0.08 * pow(m, 4.0) + 0.008 : 0.012 * m + 0.002);
        float sig = 0.5 + 0.55 * sqrt(min(b, 1.0));
        float tw = 1.0 + 0.35 * sin(t * (2.0 + 5.0 * h2.y) + h2.y * 50.0) * smoothstep(0.35, 0.0, rd.y);
        float3 tint = mix(float3(0.62, 0.74, 1.0), float3(1.0, 0.72, 0.45), h2.z * h2.z);
        tint = mix(tint, float3(1.0), 0.35);
        acc += tint * b * tw * exp(-r * r / (2.0 * sig * sig));
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
    float a2 = x * 0.0260 - k * 1.3 - ts * 0.034;
    float a3 = x * 0.0590 + k * 4.7 + ts * 0.052;
    d = 0.55 * 0.0105 * cos(a1) + 0.30 * 0.0260 * cos(a2) + 0.15 * 0.0590 * cos(a3);
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
// altitude alt (km). Returns linear radiance before the path-length factor.
static inline float3 nature_curtainLight(float x, float alt, float k, constant FXUniforms& u,
                                         NatureAuroraP P) {
    float ts = P.ts;
    // Brightness gathers in patches along the sheet, breathing slowly.
    float patch = smoothstep(0.18, 0.78, nature_n1(x * 0.011 + k * 13.0 - ts * 0.022));
    if (patch <= 0.0) return float3(0.0);
    patch *= 0.75 + 0.25 * sin(ts * 0.21 + x * 0.004 + k * 2.0);
    float hb = 96.0 + 14.0 * (nature_n1(x * 0.012 + k * 7.3 + ts * 0.01) - 0.5);    // lower hem
    float dy = alt - hb;
    // Light scattered in the air around the sheet: a soft halo, also below the hem.
    float3 halo = P.cG * exp(dy < 10.0 ? (dy - 10.0) / 10.0 : (10.0 - dy) / 35.0) * 0.035;
    if (dy < -10.0) return halo * patch;
    // Field-aligned rays: three octaves of 1D noise along the sheet, drifting sideways.
    float drift = ts * (0.35 + 0.5 * P.act);
    float r1 = nature_n1(x * 0.32 + drift + k * 31.0);
    float r2 = nature_n1(x * 0.95 - drift * 1.6 + k * 17.0);
    float r3 = nature_n1(x * 0.085 + drift * 0.3 + k * 5.0);
    float q = 0.5 * r1 + 0.32 * r2 + 0.18 * r3;
    float ray = 0.30 + 1.6 * q * q * q;
    // Broad brightness swells along the sheet (tens of km), under the fine rays.
    float swell = 0.45 + 1.1 * nature_n1(x * 0.035 - drift * 0.15 + k * 3.0);
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
        float ph1 = x0 * 0.0105 + fk * 2.1 + P.ts * 0.020;
        float ph2 = x0 * 0.0260 - fk * 1.3 - P.ts * 0.034;
        float ph3 = x0 * 0.0590 + fk * 4.7 + P.ts * 0.052;
        float2 z1 = float2(cos(ph1), sin(ph1)), z2 = float2(cos(ph2), sin(ph2)), z3 = float2(cos(ph3), sin(ph3));
        float2 r1 = float2(cos(dx * 0.0105), sin(dx * 0.0105));
        float2 r2 = float2(cos(dx * 0.0260), sin(dx * 0.0260));
        float2 r3 = float2(cos(dx * 0.0590), sin(dx * 0.0590));
        float gp = s0 * D - Z - A * (0.55 * z1.y + 0.30 * z2.y + 0.15 * z3.y);
        float3 ck = float3(0.0);
        for (int i = 1; i <= N; ++i) {
            float s = s0 + ds * float(i);
            z1 = float2(z1.x * r1.x - z1.y * r1.y, z1.y * r1.x + z1.x * r1.y);
            z2 = float2(z2.x * r2.x - z2.y * r2.y, z2.y * r2.x + z2.x * r2.y);
            z3 = float2(z3.x * r3.x - z3.y * r3.y, z3.y * r3.x + z3.x * r3.y);
            float g = s * D - Z - A * (0.55 * z1.y + 0.30 * z2.y + 0.15 * z3.y);
            if (g * gp <= 0.0) {
                float sc = s - ds + ds * gp / (gp - g);
                // One Newton step on the full sheet (big folds + curls).
                float fd, cd, x = sc * d2.x;
                float fz = nature_fold(x, fk, P.ts, fd) + nature_curl(x, fk, P.ts, cd);
                float dg = D - A * (fd + cd) * d2.x;
                sc -= (sc * D - Z - A * fz) / (abs(dg) > 0.05 ? dg : (dg < 0.0 ? -0.05 : 0.05));
                sc = clamp(sc, s - ds * 1.5, s + ds * 0.5);
                x = sc * d2.x;
                float sl = tilt - A * (fd + cd);
                // |cos| between the ray and the sheet's horizontal normal (sl, 1) → path length.
                float cosT = abs(d2.x * sl + d2.y) * rsqrt(1.0 + sl * sl) * cosE;
                float path = 1.0 / max(cosT, 0.11);
                float alt = sc * tanE - sc * sc * (1.0 / 12742.0);   // Earth curvature drop
                ck += nature_curtainLight(x, alt, fk, u, P) * path;
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
    float x = az * 7.0 + 3.0;
    float m = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 4; ++i) {
        float n = 1.0 - abs(gnoise(float2(x * f, 1.7 + float(i) * 3.1)) * 2.2);
        m += a * n * n; a *= 0.47; f *= 2.13;
    }
    float massif = 0.25 + 0.75 * smoothstep(-0.7, 0.8, sin(az * 2.1 + 1.1));
    float mElev = 0.010 + 0.085 * m * massif;
    float mtn = smoothstep(mElev + pix, mElev - pix, e);
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
        sky += nature_stars(rd, P.pix, P.stars, P.t, 3.0, P.soft > 0.0 ? 2 : 3) * ext;
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
// Clouds: a lit altocumulus deck at 2.5 km plus high cirrus. Sea: sum of ten
// dispersion-correct wave trains; trains too small for a pixel are folded into a
// microfacet slope variance (Beckmann), which is what turns the sun's reflection into a
// long glitter path near the horizon and sharp sparkles near the camera.

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
};

static inline float nature_airmass(float e) {
    float ec = max(e, -0.025);
    return 1.0 / (sin(ec) + 0.50572 * pow(max(ec * 57.29578 + 6.07995, 0.5), -1.6364));
}
static inline float nature_hg(float c, float g) {
    float d = 1.0 + g * g - 2.0 * g * c;
    return (1.0 - g * g) / (4.0 * NATURE_PI * d * sqrt(d));
}

// Sky radiance along v (no sun disc, no clouds).
static inline float3 nature_oceanAtmos(float3 v, NatureOceanP P) {
    float ev = max(v.y, 0.0);
    float c = dot(v, P.sd);
    float3 betaR = NATURE_RAYLEIGH;
    float pr = 0.0597 * (1.0 + c * c);
    float pm = nature_hg(c, 0.76) + 0.08 * nature_hg(c, 0.4) + 0.06 * nature_hg(c, 0.98);
    float mv = nature_airmass(asin(ev));
    float3 tauV = P.tauS * mv;
    // Light reaching the scatterers: views near the zenith scatter higher up, where the
    // sun's path is shorter (so the zenith stays blue after the horizon turns red).
    float k = mix(1.0, 0.22, sqrt(ev));
    float3 Ts = exp(-P.tauT * nature_airmass(P.se) * k);
    float vis = smoothstep(-0.05, 0.01, P.se);
    float3 scat = (betaR * pr + P.mie * pm) / (betaR + P.mie);
    float3 L = P.esun * Ts * vis * scat * (1.0 - exp(-tauV));
    // Multiple scattering, roughly: a soft skylight that survives after sunset.
    // (Kept bluish: it is mostly light that scattered high up, before the sun reddened.)
    L += length(P.esun) * float3(0.0011, 0.0042, 0.0165) * (0.3 + 0.7 * smoothstep(-0.1, 0.15, P.se)) * (1.0 - 0.35 * ev);
    return L;
}

// Cloud density noise: soft large-scale cover + billowy detail (rounded puffs with creases).
static inline float nature_cloudNoise(float2 p, int oct) {
    const float2x2 R = float2x2(0.8, 0.6, -0.6, 0.8);
    float s = 0.55 * gnoise(p) + 0.28 * gnoise(R * p * 2.03 + 1.7);
    float a = 0.22;
    float2 q = R * R * p * 4.1 + 3.3;
    for (int i = 2; i < oct; ++i) { s += a * (0.35 - abs(gnoise(q))); q = R * q * 2.07; a *= 0.5; }
    return s;
}

// Altocumulus deck + cirrus over the atmosphere along v (v.y > 0). `oct` trades detail
// for speed (reflections use fewer octaves).
static inline float3 nature_oceanClouds(float3 v, float3 sky, NatureOceanP P, int oct) {
    if (v.y < 0.004 || P.clouds <= 0.0) return sky;
    float c = dot(v, P.sd);
    float vis = smoothstep(-0.05, 0.0, P.se);
    float3 Tc = exp(-P.tauT * nature_airmass(P.se) * 0.82);          // sunlight at cloud height
    // Cirrus at 8 km: streaks stretched along the wind.
    float tC = 8.0 / v.y;
    float2 q = v.xz * tC;
    float2 qs = float2(q.x * 0.6 + q.y * 0.25, q.y * 0.08 - q.x * 0.1) * 0.22 + float2(P.tc * 0.25, 0.0);
    float ci = gfbm(qs, 3) + 0.35;
    float cir = smoothstep(0.30, 0.85, ci) * P.clouds * exp(-tC * 0.006);
    float3 cirC = P.esun * Tc * vis * (0.10 + 1.6 * nature_hg(c, 0.7)) * 0.12 + sky * 0.6;
    float3 col = mix(sky, cirC, cir * 0.55 * (oct < 5 ? 0.0 : 1.0));
    // Altocumulus at 2.5 km.
    float tA = 2.5 / v.y;
    float2 p = v.xz * tA * 0.32 + float2(P.tc, P.tc * 0.3);
    float2 w = float2(gnoise(p * 0.35 + 3.1), gnoise(p * 0.35 + 7.7));
    float n = nature_cloudNoise(p + w * 0.6, oct);
    float cover = P.clouds;
    float lo = 0.78 - 0.45 * cover;
    // Pixel footprint in noise units: where the deck is too foreshortened to resolve,
    // fade texture into its average (no venetian-blind aliasing at the horizon).
    float fp = tA * P.pix * 0.32 / max(v.y, 0.004);
    float resolved = smoothstep(0.5, 0.12, fp);
    float soft = (oct < 5 ? 0.32 : 0.0) + 0.3 * (1.0 - resolved);
    float dens = smoothstep(lo - soft, lo + 0.28 + soft, n * 0.75 + 0.5 + 0.18 * w.x);
    float fade = exp(-tA * 0.012);                                  // aerial perspective
    if (oct < 5) fade *= smoothstep(0.02, 0.2, v.y);                // no grazing streaks in reflections
    if (dens > 0.0) {
        // Self-shadowing: how much cloud lies a little way toward the sun.
        float shade = 1.0;
        if (oct >= 5) {
            float2 toSun = normalize(P.sd.xz + 1e-4) * 0.55;
            float n2 = nature_cloudNoise(p + toSun + w * 0.6, 2);
            float d2 = smoothstep(lo, lo + 0.28, n2 * 0.75 + 0.5 + 0.18 * w.x);
            shade = exp(-2.2 * d2) * 0.85 + 0.15;
        }
        float thin = 1.0 - dens;
        // Low sun: the undersides we see catch reddened light; thin edges toward the sun
        // silver-line (strong forward scattering); thick cores fall to blue-grey skylight.
        float3 lit = P.esun * Tc * vis * (0.25 + 3.4 * nature_hg(c, 0.62) * (0.2 + thin)) * (0.12 + 0.35 * thin) * shade;
        float3 amb = sky * 0.30 + length(P.esun) * float3(0.0025, 0.0035, 0.0085);
        float3 cc = lit + amb;
        float a = smoothstep(0.0, 0.55, dens) * fade;
        col = mix(col, cc, a);
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
// the dust transmission, for dimming the stars behind it.
static inline float4 nature_milkyWay(float3 g) {
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
    float clouds = smoothstep(0.35, 0.8, n1) * (0.3 + 1.0 * n2) * (0.6 + 0.8 * n3 * n3);
    float halo = exp(-(b * b) / (width * width * 9.0)) * 0.08;  // unresolved glow around the band
    float glow = disc * (0.12 + 1.8 * clouds) + bulge * (0.5 + 0.9 * n1) * (0.7 + 0.6 * n3) + halo;
    // Dust: the Great Rift just above the plane from Cygnus to the centre, plus lanes.
    float rb = (b - 0.025 - 0.02 * sin(l * 3.0)) / 0.028;
    float rift = exp(-rb * rb) * smoothstep(1.4, 0.2, abs(l - 0.6));
    float lanes = abs(b) < 0.3 ? smoothstep(0.45, 0.8, nature_dirNoise(g * 14.0 + 3.0, 3)) * exp(-(b * b) / 0.012) : 0.0;
    float T = exp(-(1.6 * rift * (0.5 + n2) + 1.1 * lanes));
    float3 warm = float3(1.0, 0.80, 0.58), cool = float3(0.66, 0.76, 1.0);
    float3 c = mix(cool, warm, clamp(smoothstep(-0.2, 0.9, cl) * 0.8 + bulge * 0.2, 0.0, 1.0));
    // Faint pink emission nebulae, sparse, right on the plane.
    float hii = abs(b) < 0.12 ? smoothstep(0.78, 0.95, nature_dirNoise(g * 30.0 + 11.0, 2)) * exp(-(b * b) / 0.0016) : 0.0;
    return float4(c * glow * T + float3(1.0, 0.35, 0.45) * hii * 0.6 * T, T);
}

// Silhouette coverage of the ridge, hill and pines, in (azimuth from north, elevation).
static inline float nature_nightLand(float az, float e, float pix) {
    if (e > 0.20) return 0.0;
    float x = az * 5.0 + 11.0;
    float m = 0.0, a = 0.5, f = 1.0;
    for (int i = 0; i < 3; ++i) { m += a * gnoise(float2(x * f, 0.5 + float(i))); a *= 0.5; f *= 2.2; }
    float ridge = 0.035 + 0.045 * m;
    // A near hill rising on the left of the frame (east of south).
    float hill = 0.02 + 0.12 * smoothstep(-0.15, -0.95, az - 3.14159) * (0.85 + 0.15 * nature_n1(az * 25.0))
               + 0.006 * nature_n1(az * 90.0);
    float top = max(ridge, hill);
    float land = smoothstep(top + pix, top - pix, e);
    // Pines along the hill's crest.
    const float tw = 0.012;
    float ci = floor(az / tw);
    for (int j = -1; j <= 1; ++j) {
        float id = ci + float(j);
        if (nature_h1(id * 3.1 + 2.0) < 0.45) continue;
        float pxc = (id + 0.5 + (nature_h1(id + 8.0) - 0.5) * 0.6) * tw;
        float base = 0.02 + 0.12 * smoothstep(-0.15, -0.95, pxc - 3.14159) - 0.004;
        if (base < 0.05) continue;
        float H = 0.03 + 0.04 * nature_h1(id + 31.0);
        float y = e - base;
        float rel = clamp(1.0 - y / H, 0.0, 1.0);
        float tier = fract((H - y) / (H * 0.11) + nature_h1(id));
        float hw = H * 0.2 * rel * (0.5 + 0.5 * tier) + pix * 0.5;
        land = max(land, smoothstep(hw + pix, hw - pix, abs(az - pxc)) * step(y, H));
    }
    return land;
}

// ---------------------------------------------------------------- rain on glass (case 58)
//
// Behind the glass: a night street, entirely out of focus — lamps, lit windows, traffic —
// drawn as bokeh discs whose size and brightness follow the blur (energy-conserving: a
// light defocused to twice the radius is a quarter as bright). On the glass: beads at
// two scales that appear and evaporate, and drops that run down in stop-go jerks,
// leaving a trail of droplets and a clear streak through the condensation. Each drop is
// a tiny lens: it shows a sharp, inverted, wide-angle image of the street.

struct NatureRainDrop {
    float2 o;      // offset from the drop centre in drop radii (|o| < 1 inside)
    float2 c;      // drop centre (screen units)
    float  h;      // cap height 0..1 (0 = no drop)
    float  trail;  // wet streak / cleared fog 0..1
    float  tdx;    // signed position across the streak, -1..1
};

// Keep the tallest cap at p. `shape` gives each drop its own slightly irregular outline
// (water on glass is never a perfect circle), heavier toward the bottom.
static inline void nature_dropTake(thread NatureRainDrop &D, float2 p, float2 c, float2 r, float2 shape) {
    float2 o = (p - c) / r;
    float l = length(o);
    if (l > 1.25) return;
    float2 n = o / max(l, 1e-4);
    float rf = 1.0 + 0.09 * (n.x * n.x - n.y * n.y) * shape.x + 0.07 * n.x * n.y * shape.y + 0.06 * n.y;
    o /= rf;
    float d2 = dot(o, o);
    if (d2 < 1.0) {
        float h = sqrt(1.0 - d2);
        if (h > D.h) { D.h = h; D.o = o; D.c = c; }
    }
}

// Static beads on a grid of cell size `cs`; they grow in, linger, then evaporate.
static inline void nature_beads(thread NatureRainDrop &D, float2 p, float cs, float density, float t, float seed) {
    float2 g = p / cs;
    float2 ci = floor(g);
    float2 dir = float2(g.x - ci.x < 0.5 ? -1.0 : 0.0, g.y - ci.y < 0.5 ? -1.0 : 0.0);
    // Rain lands unevenly: patches of glass carry more beads than others.
    float patchy = smoothstep(-0.25, 0.35, gnoise(p * 2.5 + seed));
    float dens = density * (0.35 + 0.9 * patchy);
    for (int k = 0; k < 4; ++k) {
        float2 id = ci + dir + float2(float(k & 1), float(k >> 1));
        float3 h = pcg3(float3(id, seed));
        if (h.z > dens) continue;
        float2 c = (id + 0.2 + 0.6 * h.xy) * cs;
        float2 dv = p - c;
        if (dot(dv, dv) > cs * cs * 0.3) continue;                      // too far to touch p
        float3 h2 = fract(h.yzx * 91.37 + h.zxy * 17.13 + 0.31);     // second draw, no rehash
        float life = fract(t * (0.03 + 0.05 * h2.y) + h2.x);
        float grow = smoothstep(0.0, 0.06, life) * smoothstep(1.0, 0.7, life);
        float r = cs * (0.12 + 0.30 * h2.z * h2.z) * grow;
        if (r <= 1e-4) continue;
        nature_dropTake(D, p, c, float2(r, r * (0.9 + 0.15 * h2.x)), h.xy * 2.0 - 1.0);
    }
}

// Running drops: one per column, sliding down in jerks along a meandering path.
static inline void nature_runners(thread NatureRainDrop &D, float2 p, float cw, float density, float t) {
    float col = floor(p.x / cw);
    for (int k = -1; k <= 1; ++k) {
        float id = col + float(k);
        float3 h = pcg3(float3(id, 5.0, 19.0));
        if (h.z > density) continue;
        float tau = t * (0.05 + 0.07 * h.x) + h.y * 7.0;
        float cyc = floor(tau);
        float seedx = pcg3(float3(id, cyc, 31.0)).x;
        float x0 = (id + 0.25 + 0.5 * seedx) * cw;
        if (abs(p.x - x0) > 0.55 * cw) continue;           // path, drop and trail stay within this
        float3 h2 = pcg3(float3(id, 8.0, 23.0));
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
        // The drop: a little wider at the bottom (teardrop).
        float2 dc = float2(xd, yd);
        float2 q = p - dc;
        float ry = r * (q.y < 0.0 ? 1.35 : 1.0);
        nature_dropTake(D, p, dc, float2(r, ry), float2(0.5, h2.x - 0.5));
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
            float3 hb = pcg3(float3(id, yi, cyc + 47.0));
            if (hb.z < 0.55 * fade + 0.15) {
                float rr = r * (0.18 + 0.25 * hb.x) * (0.5 + 0.5 * fade);
                float cy = (yi + 0.5) * cs;
                float cx = x0 + cw * (0.30 * (nature_n1(cy * 4.0 + sx) - 0.5) + 0.07 * (nature_n1(cy * 16.0 + sx2) - 0.5))
                         + (hb.y - 0.5) * r * 0.6;
                nature_dropTake(D, p, float2(cx, cy), float2(rr, rr), hb.xy - 0.5);
            }
        }
    }
}

// One bokeh layer: lights on a grid (cell `cs`), radius grows with blur, brightness falls
// as 1/r² so the light's energy is conserved, with a faint glow skirt (lens veiling).
// `kind` picks colours/placement; `pres` is the share of cells holding a light.
static inline float3 nature_bokehLayer(float2 p, float cs, float r0, float blur, float2 drift,
                                       float yLo, float yHi, int kind, float3 lamp, float seed, float pres) {
    if (p.y < yLo - cs * 0.65 || p.y > yHi + cs * 0.65) return float3(0.0);   // outside the band
    float2 q = (p + drift) / cs;
    float2 ci = floor(q);
    // Only the 2×2 cells nearest p can reach it: radii stay under ~0.48 cell (with the
    // glow skirt, under 0.65), and centres sit at least 0.15 cell inside their cell.
    float2 dir = float2(q.x - ci.x < 0.5 ? -1.0 : 0.0, q.y - ci.y < 0.5 ? -1.0 : 0.0);
    float R = r0 * (0.08 + 1.0 * blur);
    float soft = R * (0.06 + 0.22 * blur) + 0.0012;
    float3 acc = float3(0.0);
    for (int k = 0; k < 4; ++k) {
        float2 id = ci + dir + float2(float(k & 1), float(k >> 1));
        float3 h = pcg3(float3(id, seed));
        if (h.z > pres) continue;
        float2 c = (id + 0.15 + 0.7 * h.xy) * cs - drift;
        if (c.y < yLo || c.y > yHi) continue;
        float3 h2 = fract(h.yzx * 91.37 + h.zxy * 17.13 + 0.31);     // second draw, no rehash
        float d = length(p - c);
        float rr = R * (0.55 + 0.9 * h2.z);
        if (d > rr * 1.35 + soft) continue;
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
        float rim = 1.0 + 0.3 * smoothstep(rr * 0.6, rr, d) * blur;   // brighter, slightly ringed edge
        float energy = (r0 * 0.45) * (r0 * 0.45) / max(rr * rr, 1e-6);
        float skirt = exp(-max(d - rr, 0.0) / (rr * 0.12 + 1e-4)) * 0.12 * smoothstep(rr * 1.35 + soft, rr, d);
        acc += col * (disc * rim + skirt) * min(energy, 30.0);
    }
    return acc;
}

// The street behind the glass at blur 0..1 (0 = sharp pinpoints).
static inline float3 nature_street(float2 p, float aspect, float blur, float t, float3 night, float3 lamp,
                                   bool lite = false) {
    float y = p.y;
    float3 col = night * (0.55 + 1.5 * smoothstep(0.1, 0.95, y));                // sky → street glow
    // Big defocused colour washes: lamp-lit street low down, a neon glow, cool sky light.
    float wx = p.x / aspect;
    col += lamp * 0.030 * smoothstep(0.35, 1.0, y) * (0.6 + 0.4 * sin(wx * 4.0 + 1.0));
    float2 nd = (p - float2(aspect * 0.78, 0.42)) / float2(0.35, 0.22);
    col += float3(0.9, 0.18, 0.55) * 0.020 * exp(-dot(nd, nd));
    float2 cd = (p - float2(aspect * 0.18, 0.2)) / float2(0.4, 0.25);
    col += float3(0.25, 0.55, 0.9) * 0.012 * exp(-dot(cd, cd));
    if (!lite) col += nature_bokehLayer(p, 0.055, 0.016, blur, float2(0.0), 0.05, 0.60, 0, lamp, 3.0, 0.22) * 0.6;
    col += nature_bokehLayer(p, 0.165, 0.050, blur, float2(0.0), 0.10, 0.58, 0, lamp, 5.0, 0.30) * 0.7;
    col += nature_bokehLayer(p, 0.165, 0.050, blur, float2(0.0), 0.30, 0.50, 3, lamp, 11.0, 0.18) * 0.9;
    col += nature_bokehLayer(p, 0.31, 0.095, blur, float2(0.0), 0.24, 0.58, 1, lamp, 9.0, 0.85) * 1.6;
    col += nature_bokehLayer(p, 0.105, 0.032, blur, float2(t * 0.020, 0.0), 0.62, 0.74, 2, lamp, 15.0, 0.62) * 1.5;
    col += nature_bokehLayer(p, 0.14, 0.042, blur, float2(-t * 0.035, 0.0), 0.70, 0.90, 2, lamp, 21.0, 0.55) * 1.3;
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

// Silhouette of a pine row at depth z: 1 where a trunk/canopy covers the pixel.
static inline float nature_pineRow(float2 sp, float z, float h0, float seed, float pix) {
    float wx = sp.x * z;                              // metres across at that depth
    float gy = h0 - NATURE_SNOW_CAMH / z;             // ground line at that depth (screen)
    float wy = (sp.y - gy) * z;                       // metres above the ground there
    if (wy < 0.0) return 1.0;
    if (wy > 22.0) return 0.0;
    const float sp_ = 4.2;
    float ci = floor(wx / sp_);
    float cov = 0.0;
    for (int j = -1; j <= 1; ++j) {
        float id = ci + float(j);
        float3 h = pcg3(float3(id, seed, 5.0));
        if (h.z < 0.18) continue;
        float cx = (id + 0.2 + 0.6 * h.x) * sp_;
        float H = 9.0 + 12.0 * h.y;
        if (wy > H) continue;
        float rel = 1.0 - wy / H;
        float tier = fract(wy / (H * 0.13) + h.z * 3.0);
        float hw = H * 0.26 * rel * (0.72 + 0.28 * (1.0 - tier)) + 0.12;
        float aa = pix * z * 1.5;
        cov = max(cov, smoothstep(hw + aa, hw - aa, abs(wx - cx)));
    }
    return cov;
}

// The lamp is shaded: it throws a cone of light downward (soft-edged, ~55° half-angle).
static inline float nature_lampCone(float3 fromLamp) {
    float c = -fromLamp.y / max(length(fromLamp), 1e-4);
    return 0.06 + 0.94 * smoothstep(0.42, 0.70, c);
}

// Everything behind the snow: sky, pine rows in fog, the lamp post, lit snowy ground.
// Returns colour; `zb` is the depth of the first opaque surface (for flake occlusion).
static inline float3 nature_snowBack(float2 sp, NatureSnowP P, thread float &zb) {
    float3 col;
    zb = 1e4;
    float y = sp.y - P.h0;
    float2 lampS = float2(P.L.x / P.L.z, P.h0 + P.L.y / P.L.z);
    float dl = length(sp - lampS);
    if (y < 0.0) {
        // Ground: depth from the ground plane; the lamp's pool of light on the snow.
        float z = NATURE_SNOW_CAMH / max(-y, 1e-4);
        float3 W = float3(sp.x * z, -NATURE_SNOW_CAMH, z);
        float3 toL = P.L - W;
        float d2 = dot(toL, toL);
        float pool = P.lampI * (P.L.y + NATURE_SNOW_CAMH) / (d2 * sqrt(d2) + 0.5) * nature_lampCone(-toL);
        float3 snow = P.sky * 2.2 + P.lampC * pool * 2.6;
        // Soft drifts and the odd glint near the lamp.
        float drift = gnoise(float2(W.x * 0.35, z * 0.5)) * 0.15 + gnoise(float2(W.x * 1.3, z * 2.0)) * 0.06;
        snow *= 0.92 + drift;
        float3 g = pcg3(float3(floor(sp * 1100.0), 3.0));
        snow += P.lampC * pool * 12.0 * step(0.9985, g.x) * smoothstep(12.0, 3.0, z);
        float fogF = 1.0 - exp(-z * 0.045);
        col = mix(snow, P.fogC, fogF);
        zb = z;
    } else {
        // Sky: dusk gradient, brighter toward the horizon where the fog thickens.
        col = P.sky * (0.9 + 1.4 * exp(-y * 3.0));
        col = mix(col, P.fogC, exp(-y * 6.0) * 0.6);
    }
    // Pine rows, far to near, each veiled by its depth's fog.
    for (int r = 0; r < 3; ++r) {
        float z = r == 0 ? 70.0 : (r == 1 ? 38.0 : 21.0);
        float cov = nature_pineRow(sp, z, P.h0, float(r) * 13.0 + 1.0, P.pix);
        if (cov > 0.0 && z < zb) {
            float3 tc = P.sky * 0.22 + P.lampC * P.lampI * 0.002 / (r == 2 ? 1.0 : 3.0);
            float fogF = 1.0 - exp(-z * 0.045);
            col = mix(col, mix(tc, P.fogC, fogF), cov);
            if (cov > 0.5) zb = z;
        }
    }
    // The lamp post (7 m away): a dark pole and the lantern.
    float poleX = lampS.x;
    float poleTop = lampS.y - 0.02;
    float groundAt = P.h0 - NATURE_SNOW_CAMH / P.L.z;
    float pw = 0.06 / P.L.z;
    if (sp.y < poleTop && sp.y > groundAt && abs(sp.x - poleX) < pw) { col = P.sky * 0.06; zb = P.L.z; }
    // Lantern: a dark cap over a glowing glass bowl.
    float2 lq = (sp - lampS) * P.L.z;                     // metres around the lamp head
    float capY = 0.16 - 0.55 * lq.x * lq.x;
    if (abs(lq.x) < 0.42 && lq.y > capY - 0.05 && lq.y < capY + 0.04) { col = P.sky * 0.08; zb = P.L.z; }
    float2 bq = lq / float2(0.24, 0.17);
    if (dot(bq, bq) < 1.0 && lq.y < capY - 0.05) { col = P.lampC * P.lampI * 7.0 + 0.5; zb = P.L.z; }
    // Glow of the lamp in the falling snow and mist (single scattering around a point light).
    float glow = P.lampI * (0.0014 / (dl * dl + 0.0005) + 0.035 * exp(-dl * 3.5));
    // The cone of light in the snowy air: brightest near the lamp, soft-edged.
    float2 rel = sp - lampS;
    float ca = -rel.y / max(length(rel), 1e-4);
    float cone = smoothstep(0.45, 0.75, ca) * exp(-length(rel) * 1.6) * step(sp.y, lampS.y);
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
            float3 h = pcg3(float3(id, float(i) * 7.0 + 1.0));
            if (h.z > P.amount) continue;
            float3 h2 = pcg3(float3(id, float(i) * 7.0 + 4.0));
            float jit = one ? 0.4 : 0.5;
            float2 c = (id + (1.0 - jit) * 0.5 + jit * h.xy) * cell - off;
            c.x += sin(P.ts * (0.9 + 0.8 * h2.x) + h2.y * 6.28) * cell * (one ? 0.1 : 0.15);  // flutter
            float d = length(sp - c);
            float rr = R * (0.6 + 0.8 * h2.z);
            if (one) rr = min(rr, 0.19 * cell / 1.6);
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
