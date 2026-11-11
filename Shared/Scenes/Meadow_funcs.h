//  Meadow_funcs.h — the Meadow pack (shader id 78, Meadow.swift): summer hills in the wind.
//  File-scope Metal helpers, every symbol "meadow_". Included by Shaders.metal after
//  Nature_funcs.h, whose sky it reuses (Tidewater's: single-scattering atmosphere, twilight, the
//  live sun and moon, stars, the weather's cloud deck) with Shared/Weather/Weather_funcs.h (rain,
//  snow, fog, lightning). Linear light throughout, then a film finish.
//
//  The view, front to back:
//   • stems at the lens (wildflowers on tall stalks, seed heads), out of focus, backlit;
//   • grass blades on vertical depth layers out to ~5 m (Meadow, Tall Grass), bending in gusts that
//     travel across the field, each blade fluttering on its own; box-filtered and defocused up
//     close, so nothing shimmers;
//   • the ground: the meadow plane, or velvet ground swelling into dark hollows (Rolling Hills,
//     Hillside), with wind streaks and the gusts' sheen;
//   • five ridges receding to the horizon, drawn as silhouettes, each form-shaded (flanks to or
//     from the light, the face falling toward us, a dark hollow at its foot with mist pooled in
//     it), velvet up close, fields and hedges further off, cypresses or tree lines on a crest,
//     going blue and soft only with real distance; in Hillside the sea and blue mountains beyond;
//   • the sky: Tidewater's atmosphere, sun, moon and stars, big cumulus built of lit puffs (towering
//     in Hillside), high cirrus; with the weather, Tidewater's cloud deck.
//  Then the weather, fireflies on clear summer nights, the glow (bloom and halo round the light,
//  luminous air at the horizon), the live camera's exposure, a film grade (rich colour, deep
//  shadows, halation in the highlights) and grain with a fine ordered dither.
//
//  Cost: see Meadow.swift's header (tools/gallery --gpubench). Compiled twice — clear and weather —
//  as fragment functions of their own (Weather_fragment.h), so the clear sky never pays for the
//  weather's registers. (Watch the registers: one more full sky evaluation held through the grass
//  once cost 6× the frame time.)

constant float MEADOW_F = 1.65;                              // focal length, frame half-heights
constant float2 MEADOW_WD = float2(0.9439, 0.3304);          // the wind's heading (x right, z away)

// ---------------------------------------------------------------- cheap noise
//
// One multiply-xorshift finaliser; a 2D lattice hash whose row and column products are shared by
// the four corners of a cell (two multiplies per noise, plus one per corner); gradients from the
// two signed 16-bit halves of the hash.
static inline uint meadow_mixu(uint n) {
    n ^= n >> 16u;
    n *= 0x7feb352du;
    n ^= n >> 15u;
    return n;
}
static inline float3 meadow_rand3(uint n) {
    n = meadow_mixu(n);
    return float3(float(n & 0x3ffu), float((n >> 10u) & 0x3ffu), float(n >> 20u))
         * float3(1.0 / 1024.0, 1.0 / 1024.0, 1.0 / 4096.0);
}
static inline float2 meadow_grad(uint n) {
    n = meadow_mixu(n);
    return float2(int2(int(n << 16u), int(n)) >> 16) * (1.0 / 32768.0);
}
// Gradient noise ≈ −0.7…0.7 (as nature_gnoise).
static inline float meadow_gnoise(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    uint2 q = uint2(int2(i) + 0x10000);
    uint x0 = q.x * 0x9E3779B1u, x1 = x0 + 0x9E3779B1u;
    uint y0 = q.y * 0x85EBCA77u, y1 = y0 + 0x85EBCA77u;
    float a = dot(meadow_grad(x0 ^ y0), f);
    float b = dot(meadow_grad(x1 ^ y0), f - float2(1, 0));
    float c = dot(meadow_grad(x0 ^ y1), f - float2(0, 1));
    float d = dot(meadow_grad(x1 ^ y1), f - float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}
// The same with its gradient: (value, d/dx, d/dy).
static inline float3 meadow_gnoised(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    uint2 q = uint2(int2(i) + 0x10000);
    uint x0 = q.x * 0x9E3779B1u, x1 = x0 + 0x9E3779B1u;
    uint y0 = q.y * 0x85EBCA77u, y1 = y0 + 0x85EBCA77u;
    float2 ga = meadow_grad(x0 ^ y0), gb = meadow_grad(x1 ^ y0);
    float2 gc = meadow_grad(x0 ^ y1), gd = meadow_grad(x1 ^ y1);
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float k = va - vb - vc + vd;
    float v = va + w.x * (vb - va) + w.y * (vc - va) + w.x * w.y * k;
    float2 g = ga + w.x * (gb - ga) + w.y * (gc - ga) + w.x * w.y * (ga - gb - gc + gd)
             + dw * (w.yx * k + float2(vb - va, vc - va));
    return float3(v, g);
}

// Rolling silhouette, 0…1-ish, and its slope: three incommensurate sines (hills are smooth; sines
// cost a fraction of hashed noise and differentiate for free).
static inline float meadow_ridgeV(float x, float seed) {        // (the value alone)
    float3 s = sin(x * float3(1.0, 2.31, 5.13) + float3(seed, seed * 1.7, seed * 0.3));
    return 0.5 + dot(float3(0.22, 0.14, 0.08), s);
}
static inline float2 meadow_ridge(float x, float seed) {
    float3 f = float3(1.0, 2.31, 5.13);
    float3 a = float3(0.22, 0.14, 0.08);
    float3 c;
    float3 s = sincos(x * f + float3(seed, seed * 1.7, seed * 0.3), c);
    return float2(0.5 + dot(a, s), dot(a * f, c));
}

// ---------------------------------------------------------------- layout
//
// Landscape (the Landscape menu):
//   0 Meadow        a flowery slope at the lens, rolling hills overlapping beyond with a dark hollow
//                   between, cypresses on the far ridge, blue distance;
//   1 Rolling Hills smooth green domes overlapping into the distance, velvet in the light;
//   2 Tall Grass    low in long grass at golden hour, the meadow flat to the horizon;
//   3 Hillside      a steep wind-swept slope, a shadowed ridge above it, the sea and blue
//                   mountains beyond under a towering cloud.
struct MeadowLayout {
    int land;
    float camH;      // eye height above the ground, m
    float pitch;     // camera tilt up, radians (down: < 0)
    float bladeH;    // tallest grass, m
    float space;     // blade spacing in the nearest layer, m
    float bladeW;    // blade half-width at its foot, m
    float aperture;  // defocus of the near grass: the blur circle, m (focused far off)
    float aspect;
    bool blades;     // individual blades at the lens (Meadow, Tall Grass); else the velvet sward
    float stalks;    // tall stems at the lens (flowers, seed heads): how many
};
static inline MeadowLayout meadow_layout(int land, float aspect) {
    MeadowLayout L;
    L.land = land;
    L.aspect = aspect;
    L.bladeH = 0.50; L.space = 0.020; L.bladeW = 0.0050; L.aperture = 0.0025;
    if (land == 1) {
        L.camH = 36.0; L.pitch = -0.07; L.blades = false; L.stalks = 0.0;
    } else if (land == 2) {
        L.camH = 0.80; L.pitch = 0.12; L.bladeH = 1.05; L.space = 0.024; L.aperture = 0.0040;
        L.blades = true; L.stalks = 0.0;
    } else if (land == 3) {
        L.camH = 1.6; L.pitch = -0.02; L.blades = false; L.stalks = 0.0;
    } else {
        L.camH = 1.05; L.pitch = -0.05; L.blades = true; L.stalks = 1.0;
    }
    return L;
}

// The ridges: five silhouettes receding to the horizon (k = 0 nearest), each at its distance.
constant float MEADOW_RD[4][5] = {
    {150.0, 420.0, 1100.0, 3000.0, 9000.0},     // Meadow
    {45.0, 120.0, 300.0, 800.0, 9000.0},        // Rolling Hills
    {300.0, 900.0, 2400.0, 5000.0, 9000.0},     // Tall Grass
    {1e6, 1e6, 1e6, 1e6, 14000.0},              // Hillside (the slope and the sea: meadow_scene)
};
// A dome on the skyline (height h, half-width w, at c) and its slope.
static inline float2 meadow_dome(float X, float c, float w, float h) {
    float q = (X - c) / w;
    float e = h * exp(-q * q);
    return float2(e, -2.0 * q / w * e);
}
// Ridge k's top above the horizon line (screen units: the frame is 2 tall) at screen x X, and its
// slope d/dX. −1: no ridge there.
static inline float2 meadow_ridgeTop(MeadowLayout L, int k, float X) {
    float a = L.aspect;
    if (L.land == 1) {
        if (k == 0) return float2(-0.16, 0.0) + meadow_dome(X, -0.62 * a, 1.15, 0.40) + meadow_dome(X, 1.05 * a, 0.80, 0.17);
        if (k == 1) return float2(-0.06, 0.0) + meadow_dome(X, 0.05 * a, 0.85, 0.34) + meadow_dome(X, 0.95 * a, 0.9, 0.16);
        if (k == 2) return float2(-0.01, 0.0) + meadow_dome(X, 0.70 * a, 0.95, 0.28) + meadow_dome(X, -0.85 * a, 0.75, 0.18);
        if (k == 3) { float2 r = meadow_ridge(X * 1.2, 3.3); return float2(0.03 + 0.09 * r.x, 0.108 * r.y); }
        float2 r = meadow_ridge(X * 0.8, 11.3);
        return float2(0.015 + 0.03 * r.x, 0.024 * r.y);
    }
    if (L.land == 3) {
        float t = X / a;
        if (k == 4) {
            float2 r = meadow_ridge(X * 1.4, 9.7);
            float m = smoothstep(-0.25, 0.35, t);
            return float2((0.004 + 0.045 * r.x * r.x) * m - 0.002 * (1.0 - m), 0.09 * r.x * r.y * m);
        }
        return float2(-1.0, 0.0);
    }
    float kk = L.land == 2 ? 0.35 : 1.0;
    if (k == 0) {
        if (L.land == 2) { float2 r = meadow_ridge(X * 1.3, 8.1); return float2(-0.004 + 0.012 * r.x, 0.0156 * r.y); }
        float2 r = meadow_ridge(X * 2.0, 8.1);
        return float2(-0.06, 0.0) + meadow_dome(X, 0.55 * a, 1.2, 0.30) + float2(0.015 * r.x, 0.03 * r.y);
    }
    if (k == 1) return kk * (float2(-0.02, 0.0) + meadow_dome(X, -0.50 * a, 0.95, 0.26) + meadow_dome(X, 0.15 * a, 0.70, 0.16));
    if (k == 2) { float2 r = meadow_ridge(X * 1.1, 4.7); return kk * float2(0.04 + 0.07 * r.x, 0.077 * r.y); }
    if (k == 3) { float2 r = meadow_ridge(X * 1.7, 1.9); return kk * float2(0.03 + 0.045 * r.x, 0.0765 * r.y); }
    float2 r = meadow_ridge(X * 0.8, 11.3);
    float sr = sqrt(max(r.x, 0.0));
    return kk * float2(0.04 + 0.08 * r.x * sr, 0.08 * 1.5 * sr * r.y * 0.8);
}

// ---------------------------------------------------------------- wind
//
// Gusts over the ground (p in m), 0…1: patches tens of metres across carried downwind (tw: how
// far the wind has blown, m), and long rolling waves bent by them — light running across a field
// in the wind.
static inline float meadow_gust(float2 p, float tw) {
    float2 q = p - MEADOW_WD * tw;
    float g = meadow_gnoise(q * 0.034) * 1.3;
    float wave = sin(dot(q, MEADOW_WD) * 0.15 + 1.5 * g);
    return saturate(0.42 + g + 0.24 * wave);
}
// Cloud shadows on the ground at w (m): patches a kilometre or so across, drifting downwind,
// cast along the sun. 0…1 = in shadow; thr from the cover (higher: fewer).
static inline float meadow_cloudShadow(float2 w, float3 sd, float tc, float thr) {
    float2 p = w * 0.005 + sd.xz * (5.5 / max(sd.y, 0.06)) - MEADOW_WD * (tc * 9.0) + float2(3.7, 1.9);
    float n = meadow_gnoise(p);
    return smoothstep(thr - 0.04, thr + 0.10, n);
}

// ---------------------------------------------------------------- the sky
//
// Tidewater's sky radiance (nature_oceanAtmos: the same single scattering, multiple-scattering
// floor, live twilight and night, weather deck), restated for a pixel's cost: the view airmass
// from a fitted exponential instead of Kasten–Young's power, and the sunlight reaching the
// scatterers (nature_sunAt at 1…8 km up the view) interpolated in log space between three
// heights worked out once (lTs: uniform). Within a few percent of it; a third of the work.
static inline float3 meadow_atmos(float3 v, NatureOceanP P, constant FXUniforms& u, float3x3 lTs,
                                  const bool wx) {
    float ev = max(v.y, 0.0);
    float c = dot(v, P.sd);
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
    float pr = 0.0597 * (1.0 + c * c);
    float pm = nature_hg(c, 0.76) + 0.08 * nature_hg(c, 0.4) + 0.06 * nature_hg(c, 0.98);
    float mv = 1.0 / (ev + 0.025 * exp(-ev * 11.0));
    float r = sqrt(ev) * 2.0 - 1.0;                               // −1 … 1 across the three heights
    float3 Ts = exp(lTs[1] + r * 0.5 * (lTs[2] - lTs[0]) + r * r * 0.5 * (lTs[0] + lTs[2] - 2.0 * lTs[1]));
    float3 scat = (NATURE_RAYLEIGH * pr + P.mie * pm) / (NATURE_RAYLEIGH + P.mie);
    float3 L = P.esun * Ts * scat * (1.0 - exp(-P.tauS * mv));
    L += P.ms * float3(0.0011, 0.0042, 0.0165) * (1.0 - 0.35 * ev);
    L = nature_atmosLive(L, v, P, u, false);
    if (wx) L = mix(L, air, under);
    return L;
}

// The air's own radiance just above the horizon along vh (the haze colour the land fades into):
// meadow_atmos at a fixed low elevation, where all but the phase functions is the same for every
// pixel — hzA (the single scattering's scale) and hzB (the floor) are worked out once.
static inline float3 meadow_haze(float3 vh, NatureOceanP P, constant FXUniforms& u, float3 hzA, float3 hzB,
                                 const bool wx) {
    float c = dot(vh, P.sd);
    float pr = 0.0597 * (1.0 + c * c);
    float pm = nature_hg(c, 0.76) + 0.08 * nature_hg(c, 0.4) + 0.06 * nature_hg(c, 0.98);
    float3 L = hzA * (NATURE_RAYLEIGH * pr + P.mie * pm) + hzB;
    if (P.tw > 0.0) L += nature_twilight(vh, P.sh, P.tw, u, true);
    if (wx && P.deck > 0.0) {
        float tB = P.hb / 0.012;
        float under = P.deck * smoothstep(P.dx * 1.3, P.dx * 0.8, tB);
        float3 air = P.lb * 0.82 + P.aur * nature_hg(c, 0.7)
                   + P.eglow * exp(-max(P.dx - tB, 0.0) / (0.3 * P.dx)) * (0.4 + 2.0 * nature_hg(c, 0.6));
        L = mix(L, air, under);
    }
    return L;
}

static inline float3x3 meadow_lTs(NatureOceanP P, constant FXUniforms& u) {
    return float3x3(log(nature_sunAt(P, 1.0, u) + 1e-9), log(nature_sunAt(P, 4.5, u) + 1e-9),
                    log(nature_sunAt(P, 8.0, u) + 1e-9));
}

// ---------------------------------------------------------------- light
struct MeadowLight {
    float3 sd;       // key light (the sun; the moon by night)
    float3 sunE;     // its irradiance reaching the ground (air, deck, fog)
    float3 amb;      // mean skylight radiance (diffuse fill, × albedo)
    float3 hz;       // the air's own radiance toward the horizon along this pixel (haze colour)
    float c;         // cos(view, key light)
    float beta;      // aerial extinction, 1/m
    float shK;       // how deep the cloud shadows go 0…1
};

// A patch of meadow seen from afar, lit: albedo alb, normal n, how far the gusts lay it over
// (bend 0…1), in cloud shadow sh (0…1). Grass isn't a flat Lambertian: light gets in between
// the blades (a soft wrap), the sward glows where the sun shines through it (backlit, the
// golden-hour glow), and bent grass shows its paler, shinier undersides (the sheen that runs
// across a field in a gust).
static inline float3 meadow_sward(float3 alb, float3 n, float bend, float sh, MeadowLight L) {
    float lam = saturate(0.22 + 0.78 * dot(n, L.sd));
    float3 sun = L.sunE * (1.0 - L.shK * sh);
    float3 col = alb * (sun * lam * 0.32 + L.amb * (0.55 + 0.45 * n.y));
    col += alb * float3(1.25, 1.35, 0.55) * sun * (nature_hg(L.c, 0.55) * 1.6 + 0.02);
    float3 pale = mix(alb, float3(luma(alb)) * float3(1.15, 1.12, 0.85), 0.45) * 1.6;
    col += (pale - alb) * bend * (sun * (0.20 + 0.10 * lam) + L.amb * 0.22);
    return col;
}

// ---------------------------------------------------------------- grass blades + flowers
//
// Vertical layers of blades in front of the camera, z = 0.45 · 1.2^j m (to ~5 m; tall grass ~3 m). A ray
// is inside the grass (0 ≤ height ≤ the tallest blade) over one stretch of depth, so only the
// layers there are visited. In each, the ray's point (X across, Y up from the ground) is tested
// against the two nearest blades of a row: rooted at x0, height h, curving over by `lean`
// (offset lean·Y²/hRef: the gust here, plus its own tilt and flutter, kept within a blade
// spacing so the row — looked up sheared by the gust's lean — always finds it), tapering to its
// tip. Coverage is the pixel's footprint (widened by the defocus) overlapping the blade: a blade
// thinner than a pixel is faint, never a flicker. A few are flowers (a thin stem and a head:
// daisy, buttercup, clover, cornflower) or carry a seed head (tall grass). Front to back, until
// nothing shows through. Returns premultiplied colour, coverage.
static inline float4 meadow_blades(float3 rd, MeadowLayout Lo, float pix, float ts, float tw,
                                   float wind, float flowers, float3 alb, MeadowLight L) {
    float z0 = Lo.land == 2 ? 0.6 : 0.45;
    float rz = Lo.land == 2 ? 1.4 : 1.2, lrz = log(rz);
    float H = Lo.bladeH;
    float iz = 1.0 / max(rd.z, 1e-3);
    float zA, zB;                                               // the stretch inside the grass
    if (rd.y < -1e-5) {
        float k = rd.z / -rd.y;
        zA = (Lo.camH - H) * k;
        zB = Lo.camH * k;
    } else {
        if (H <= Lo.camH) return float4(0.0);
        zA = 0.0;
        zB = rd.y > 1e-5 ? (H - Lo.camH) * rd.z / rd.y : 1e3;
    }
    // (Each layer wanders ±9% in depth along its length — rows of grass aren't straight lines,
    // and their feet must not line up across the frame — so one more layer each side is looked at.)
    int j0 = max(0, int(ceil(log(max(zA, z0) / z0) / lrz)) - 1);
    int j1 = min(Lo.land == 2 ? 5 : 11, int(floor(log(max(zB, 1e-3) / z0) / lrz)) + 1);
    if (rd.y > 0.0) j1 = min(j1, j0 + 3);                      // (above the horizon: the near stalks)
    if (j1 < j0) return float4(0.0);

    float3 acc = float3(0.0);
    float keep = 1.0;
    float hgB = nature_hg(L.c, 0.45);
    float3 sunB = L.sunE * (0.15 + 0.28 * saturate(L.sd.y + 0.25)) + L.amb * 0.78;   // a blade's diffuse light
    float3 transB = L.sunE * float3(1.2, 1.3, 0.5) * (hgB * 2.4);                   // through it (backlit)
    // The gust along this ray (it changes over tens of metres: one look covers the layers).
    float g = meadow_gust(float2(rd.x * iz * 2.0, 2.0), tw);
    float hRef = H * 0.78;
    float stiff = Lo.land == 2 ? 0.6 : 1.0;                    // (tall stalks bend less)
    float seeds = Lo.land == 2 ? 0.35 : 0.0;                   // share of blades in seed
    float flut = saturate(wind * 1.5 + 0.2);
    float qx = rd.x * iz;                                      // (the ray's direction across)
    float zl = z0 * exp(float(j0) * lrz);
    for (int j = j0; j <= j1; ++j, zl *= rz) {
        float fj = float(j);
        float rf = fract(fj * 0.7548777), rp = fract(fj * 0.5698403);
        float z = zl * (1.0 + 0.085 * nature_sinT(qx * (2.2 + 3.1 * rf) + rp) * (0.6 + 0.4 * nature_sinT(qx * 0.9 + rf)));
        float tz = z * iz;
        float Y = Lo.camH + rd.y * tz;                         // height above the ground here
        if (Y < 0.0 || Y > H + 0.04) continue;
        float X = rd.x * tz;
        float s = Lo.space * sqrt(z / z0);
        float pw = tz * pix + Lo.aperture;                     // footprint + blur, m
        float ipw = 1.0 / pw;
        float lean0 = wind * stiff * (0.06 + 0.85 * g * g);
        float Y2 = Y * Y / hRef;
        float dmax = 0.3 * s * hRef / (H * H);                 // most a blade's own lean may add
        // The two rows' blades nearest the (sheared) point: a blade stays within its cell ± a
        // little (root jitter ±0.2, own lean ±0.3 of a spacing), so no other can reach it.
        float xs = (X - lean0 * Y2) / s - 0.5;
        float i0 = floor(xs);
        float hs = H * (1.0 - 0.22 * lean0 * lean0);          // a blade blown over is shorter
        uint salt = uint(j) * 0x85EBCA77u + 0x632BE5ABu;
        // The candidates' coverage only; the winner is shaded once, below.
        float best = 0.0;
        float3 bh = float3(0.0);
        float by = 0.0, bsd = 0.0, bdh = 0.0, brh = 1.0, bcl = 0.5;
        // (Beyond ~6 m the rows fade into the meadow below them: soft, not combed.)
        float far = smoothstep(3.6, 1.8, z);
        int kind = 0;                                          // 0 blade, 1 flower stem, 2 flower head
        for (int k = 0; k <= 1; ++k) {
            float id = i0 + float(k);
            float3 h = meadow_rand3((uint(int(id) + 0x40000) * 0x9E3779B1u) ^ salt);
            float x0 = (id + 0.3 + 0.4 * h.x) * s;
            // Clumps a metre or two across: taller and lusher here, short and sun-bleached there.
            float cl = 0.5 + 0.5 * nature_sinT(x0 * 0.37 + z * 0.23 + 0.2) * nature_sinT(x0 * 0.13 - z * 0.31 + 0.6);
            float hb = hs * (0.5 + 0.5 * h.y) * (0.58 + 0.42 * cl);
            float y01 = Y / hb;
            // (No flowers right at the lens in tall grass: they'd be big pale blurs.)
            bool fl = h.z < flowers * (Lo.land == 0 ? 0.10 : 0.045) && (Lo.land != 2 || z > 2.4);
            if (y01 > (fl ? 1.3 : 1.0)) continue;
            float dev = dmax * ((h.x - 0.5) * 1.1 + 0.45 * flut * nature_sinT(ts * (0.33 + 0.3 * h.x) + h.y * 6.4));
            if (!fl) {
                float cx = x0 + (lean0 + dev) * Y2;
                float hw = Lo.bladeW * (0.7 + 0.6 * fract(h.z * 13.7)) * (1.0 - y01) * (1.0 + 0.9 * y01);
                // Seed heads: a soft spindle at the top.
                float sd01 = (fract(h.z * 31.3) < seeds && y01 > 0.74) ? (y01 - 0.74) * (1.0 / 0.26) : 0.0;
                float cov;
                if (sd01 > 0.0) {
                    hw = max(hw, Lo.bladeW * 1.15 * sqrt(sin(3.14159 * sd01)));
                    float pws = pw + Lo.bladeW;
                    cov = 0.85 * saturate((min(cx + hw, X + 0.5 * pws) - max(cx - hw, X - 0.5 * pws)) / pws);
                } else {
                    cov = saturate((min(cx + hw, X + 0.5 * pw) - max(cx - hw, X - 0.5 * pw)) * ipw);
                }
                cov *= smoothstep(0.0, 0.4, y01) * far;               // (feet lost in the sward)
                if (cov > best) { best = cov; bh = h; by = y01; bsd = sd01; bcl = cl; kind = 0; }
            } else {
                // A flower: a stem, and the head at its top (swaying with it).
                float lf = (lean0 + dev) * 0.6;
                float y1 = min(Y, hb);
                float cx = x0 + lf * y1 * y1 / hRef;
                float hw = Lo.bladeW * 0.35;
                float stem = y01 < 1.0 ? saturate((min(cx + hw, X + 0.5 * pw) - max(cx - hw, X - 0.5 * pw)) * ipw) : 0.0;
                float rh = 0.014 + 0.012 * fract(h.y * 9.1);
                float dh = length(float2(X - (x0 + lf * hb * hb / hRef), (Y - hb) * 1.3));
                float head = saturate((rh - dh) * ipw + 0.5);
                float cov = max(stem * smoothstep(0.0, 0.4, y01), head) * far;
                if (cov > best) { best = cov; bh = h; by = y01; bdh = dh; brh = rh; kind = head >= stem ? 2 : 1; }
            }
        }
        if (best <= 0.0) continue;
        float3 a = alb * mix(float3(0.80, 0.94, 0.70), float3(1.25, 1.12, 0.76), bh.x)
                 * mix(float3(1.22, 1.08, 0.70), float3(0.88, 1.02, 0.92), bcl);
        float3 cc;
        if (kind == 0) {
            // A blade: a touch of its own hue, paler and warmer toward the tip, dark at the foot
            // (the sward shades it), the sun through it, the gust's sheen; a seed head's own tan.
            a = mix(a, a * float3(1.55, 1.32, 0.62), by * by * 0.6);
            float ao = 0.42 + 0.58 * by;
            cc = a * ((sunB * (0.6 + 0.5 * bh.y) + transB * (0.15 + 0.85 * by)) * ao + L.amb * (g * 0.6 * by));
            if (bsd > 0.0) cc = mix(cc, float3(0.50, 0.42, 0.28) * (sunB * 0.55 + transB * float3(1.3, 1.1, 2.2)), smoothstep(0.0, 0.3, bsd));
        } else if (kind == 1) {
            cc = a * 0.8 * (sunB * (0.2 + 0.8 * min(by, 1.0)) + transB * 0.5);
        } else {
            float sel = fract(bh.x * 7.31 + bh.y * 3.7);
            float3 fc = sel < 0.40 ? float3(0.92, 0.90, 0.84)                       // daisy
                      : (sel < 0.55 ? float3(0.95, 0.70, 0.06)                      // buttercup
                      : (sel < 0.80 ? float3(0.82, 0.07, 0.05)                      // poppy
                      : (sel < 0.92 ? float3(0.84, 0.24, 0.52) : float3(0.32, 0.44, 0.94))));  // campion, cornflower
            // A daisy's yellow eye, where the head is big enough to see it.
            if (sel < 0.40) fc = mix(fc, float3(0.95, 0.66, 0.08), smoothstep(brh * 0.42, brh * 0.30, bdh) * smoothstep(0.004, 0.012, brh - pw));
            cc = fc * (L.sunE * (0.20 + 0.22 * saturate(L.sd.y + 0.3)) + L.amb * 0.95 + L.sunE * fc * hgB * 0.6);
        }
        acc += keep * best * cc;
        keep *= 1.0 - best;
        if (keep < 0.03) break;
    }
    return float4(acc, 1.0 - keep);
}

// ---------------------------------------------------------------- cumulus
//
// Big summer cumulus, painted on the sky in (azimuth, sine of elevation) on three rows by distance
// (big near heaps high up, smaller ones toward the horizon). A heap is a dome on a flat base — a
// second dome stacked on it when it towers (Hillside, a storm) — whose outline boils with billows:
// two octaves of gradient noise displacing it (cauliflower, not circles). It is lit as the surface
// that density describes: its gradient tips a normal toward or away from the sun (lit flanks and
// tops, shaded creases between billows), the base sits in its own grey-blue shade, the thin outer
// edge is silver toward the sun; far rows fade into the air. `cover` 0…1: how many heaps; `tower`
// 0…1: how tall the near ones build. Returns (premultiplied colour, cover).
constant float4 MEADOW_CROWS[3] = {      // (base, size, cell width in sizes, haze)
    float4(0.150, 0.150, 3.2, 0.02), float4(0.075, 0.080, 3.0, 0.10), float4(0.030, 0.040, 2.8, 0.30)
};
static inline float4 meadow_cumulus(float3 v, float3 sky, NatureOceanP P, float cover, float tower,
                                    float pix, constant FXUniforms& u) {
    float e = v.y;
    float a = atan2(v.x, v.z);
    float3 sunC = P.esun * nature_sunAt(P, 1.8, u);
    float3 ambC = sky * 0.75 + P.amb * float3(0.0045, 0.0055, 0.0090);
    float fs = nature_hg(dot(v, P.sd), 0.55);
    float3 rgt = normalize(float3(v.z, 0.0, -v.x));
    float keep = 1.0;
    float3 acc = float3(0.0);
    for (int k = 0; k < 3; ++k) {
        float4 R = MEADOW_CROWS[k];
        float S = R.y * (k == 0 ? 1.0 + 0.4 * tower : 1.0);
        float b = R.x;
        if (e < b - 0.05 * S || e > b + (1.6 + 2.0 * tower) * S) continue;
        float x = a / S + P.tc * (1.6 - 0.4 * float(k)) / S + 17.3 * float(k);
        float cw = R.z;
        float c0 = floor(x / cw - 0.5);
        float best = 0.0;
        float3 bc = float3(0.0);
        for (int j = 0; j < 2; ++j) {
            float ci = c0 + float(j);
            float3 h = meadow_rand3(uint(int(ci) + 0x4000) * 0x9E3779B1u ^ (uint(k) * 0x85EBCA77u + 0x5bd1e995u));
            if (h.x > cover) continue;
            float xc = (ci + 0.5 + 0.3 * (h.y - 0.5)) * cw;
            float ws = 0.9 + 0.6 * h.z;                            // half-width, in S
            float hs = 0.70 + 0.50 * h.y;                          // height, in S
            float tw2 = k == 0 ? tower * step(0.4, h.z) : 0.0;     // (a tower on the bigger near ones)
            float2 p = float2((x - xc) / ws, (e - b) / S);         // across: half-widths; up: S
            if (abs(p.x) > 1.45 || p.y < -0.08 || p.y > hs * 1.5 + tw2 * 2.2) continue;
            // The dome (and the tower), then the billows.
            float2 q0 = float2(p.x, (p.y - 0.05) / hs);
            float D0 = 1.0 - length(q0 * float2(1.0, 0.85));
            float2 g0 = -q0 * float2(1.0, 0.72 / hs) / max(length(q0 * float2(1.0, 0.85)), 1e-3);
            if (tw2 > 0.0) {
                float2 qt = float2((p.x - 0.12) / 0.55, (p.y - hs * 0.7) / (1.6 * tw2 + 0.3));
                float Dt = 1.0 - length(qt);
                float2 gt = -qt / max(length(qt), 1e-3) * float2(1.0 / 0.55, 1.0 / (1.6 * tw2 + 0.3));
                float wa = 1.0 / (1.0 + exp(-6.0 * (Dt - D0)));        // (smooth union)
                D0 = max(D0, Dt) + 0.12 * wa * (1.0 - wa) * 4.0 * 0.5;
                g0 = mix(g0, gt, wa);
            }
            if (D0 < -0.45) continue;
            float2 pn = float2(p.x * ws, p.y) * 2.4 + h.yz * 40.0 + float2(P.tc * 3.0, 0.0);
            float3 n1 = meadow_gnoised(pn);
            float fpq = pix / S * 2.4;                             // a pixel, in noise units
            float fine = smoothstep(0.5, 0.15, fpq * 2.4);
            float n2 = fine > 0.0 ? meadow_gnoise(pn * 2.4 + 7.7) * fine : 0.0;
            float D = D0 + 0.42 * n1.x + 0.16 * n2;
            float al = smoothstep(0.0, 0.10 + fpq * 1.5, D) * smoothstep(-0.04, 0.10, p.y);   // (flat base)
            if (al <= best) continue;
            // Light: the density's gradient as the surface normal.
            float2 gd = g0 + 0.20 * 2.4 * n1.yz * float2(ws, 1.0);   // (billows soften the dome's light)
            float3 n = normalize(-rgt * gd.x - float3(0.0, gd.y, 0.0) - v * 1.6);
            float lam = saturate(0.10 + 0.90 * dot(n, P.sd));
            float lift = smoothstep(-0.02, 0.55, p.y);             // the base in its own shade
            float core = saturate(D / 0.6);
            float thin = saturate(1.0 - D / 0.2);
            float3 col = sunC * (0.06 + 0.52 * lam) * mix(0.38, 1.0, lift) * (1.0 - 0.12 * core)
                       + ambC * (0.48 + 0.32 * lift);
            col += sunC * fs * thin * thin * 0.45;                  // the silver edge toward the sun
            best = al;
            bc = mix(col, sky, R.w);
        }
        if (best > 0.0) {
            acc += keep * best * bc;
            keep *= 1.0 - best;
            if (keep < 0.01) break;
        }
    }
    return float4(acc, 1.0 - keep);
}
// High cirrus: faint streaks along the wind, far above the heaps (one noise).
static inline float4 meadow_cirrus(float3 v, float3 sky, NatureOceanP P, float amount, constant FXUniforms& u) {
    if (v.y < 0.12 || amount <= 0.0) return float4(0.0);
    float2 qq = v.xz * (8.0 / v.y);
    float2 qs = float2(qq.x * 0.6 + qq.y * 0.25, qq.y * 0.08 - qq.x * 0.1) * 0.22 + float2(P.tc * 0.25, 0.0);
    float ci = 0.55 * meadow_gnoise(qs) + 0.35;
    float al = smoothstep(0.32, 0.85, ci) * amount * 0.4 * smoothstep(0.12, 0.3, v.y);
    float3 col = P.esun * nature_sunAt(P, 8.0, u) * (0.10 + 1.6 * nature_hg(dot(v, P.sd), 0.7)) * 0.12 + sky * 0.75;
    return float4(col * al, al);
}

// ---------------------------------------------------------------- stems at the lens
//
// A few tall stems right in front of the lens (0.3–0.7 m away): wildflowers on long stalks —
// poppies, pink campion, daisies, buttercups — and grass seed heads, rising into the lower frame
// out of focus, swaying in the gusts, lit through from behind when they face the sun (a glowing
// rim). Two sparse rows; few and large, so cheap. Returns premultiplied colour, coverage.
static inline float4 meadow_stalks(float3 rd, MeadowLayout Lo, float pix, float ts, float tw, float wind,
                                   float flowers, float3 alb, MeadowLight L) {
    float iz = 1.0 / max(rd.z, 1e-3);
    float3 acc = float3(0.0);
    float keep = 1.0;
    float hgB = nature_hg(L.c, 0.35);
    float3 sunS = L.sunE * (0.16 + 0.30 * saturate(L.sd.y + 0.25)) + L.amb * 0.85;
    float3 trans = L.sunE * float3(1.3, 1.25, 0.55) * (hgB * 3.0);
    float hTop = Lo.land == 0 ? 0.95 : 0.85;                    // the tallest stem
    if (Lo.camH + rd.y * 0.45 * iz > hTop) return float4(0.0);  // (above them all)
    float g = 0.5 + 0.5 * nature_sinT(rd.x * iz * 0.9 - tw * 0.03);   // (the gust, here: one look)
    for (int j = 0; j < 2; ++j) {
        float z = j == 0 ? 0.45 : 0.75;
        float tz = z * iz;
        float Y = Lo.camH + rd.y * tz;
        if (Y < 0.0 || Y > hTop) continue;
        float X = rd.x * tz;
        const float s = 0.09;
        float pw = tz * pix + (j == 0 ? 0.006 : 0.0035);        // softly out of focus
        float lean0 = wind * (0.05 + 0.6 * g * g);
        float Y2 = Y * Y / 0.9;
        float i0 = floor((X - lean0 * Y2) / s - 0.5);
        float best = 0.0, by = 0.0, bk = 0.0, brim = 0.0;
        float3 bh = float3(0.0);
        for (int k = 0; k <= 1; ++k) {
            float id = i0 + float(k);
            float3 h = meadow_rand3(uint(int(id) + 0x40000) * 0x9E3779B1u ^ (uint(j) * 0x27d4eb2du + 0x165667b1u));
            if (h.z > 0.35 + 0.35 * Lo.stalks) continue;           // sparse
            float hb = (hTop - 0.03) * (0.45 + 0.55 * h.y);
            float y01 = Y / hb;
            if (y01 > 1.12) continue;
            float flut = 0.04 * nature_sinT(ts * (0.28 + 0.22 * h.x) + h.y * 5.0) * saturate(wind * 1.5 + 0.2);
            float x0 = (id + 0.3 + 0.4 * h.x) * s;
            float cx = x0 + (lean0 + flut) * Y2;
            float sel = fract(h.x * 5.31 + h.z * 2.17);
            bool isFlower = sel < flowers * 0.75 && j == 1;           // (none right at the lens)
            float hw = 0.0018 * (1.0 - 0.5 * min(y01, 1.0));
            // (A soft, tapering band, not a box: the stem is well out of focus.)
            float cov = y01 < 1.0 ? saturate(2.6 * hw / pw) * smoothstep(0.5 * pw + hw, 0.0, abs(X - cx))
                                    * smoothstep(1.0, 0.8, y01) : 0.0;
            float kind = 0.0;
            float rim = 0.0;
            if (isFlower) {
                // A flower head: a disc at the top, petals ruffled.
                float2 dv = float2(X - (x0 + (lean0 + flut) * hb * hb / 0.9), (Y - hb) * 1.25);
                float rh = 0.010 + 0.007 * fract(h.y * 9.1);
                float dh = length(dv);
                float hd = saturate((rh - dh) / pw + 0.5);
                if (hd > cov) { cov = hd; kind = 1.0 + floor(fract(h.y * 3.7 + h.x) * 4.0); rim = saturate(dh / rh); }
            } else if (y01 > 0.70 && Lo.land != 0) {
                // A seed head: a soft spindle.
                float sd = saturate((y01 - 0.70) / 0.30);
                float hs = 0.0055 * sqrt(sin(3.14159 * sd));
                float c2 = saturate((min(cx + hs, X + 0.5 * pw) - max(cx - hs, X - 0.5 * pw)) / pw) * 0.9;
                if (c2 > cov) { cov = c2; kind = 6.0; rim = saturate(abs(X - cx) / max(hs, 1e-4)); }
            }
            cov *= smoothstep(0.0, 0.25, y01);
            if (cov > best) { best = cov; by = y01; bk = kind; bh = h; brim = rim; }
        }
        if (best <= 0.0) continue;
        float3 col;
        if (bk < 0.5) {
            float3 a = alb * float3(1.10, 1.05, 0.75);
            col = a * (sunS * (0.4 + 0.6 * by) + trans * (0.4 + 0.6 * by));
        } else if (bk < 5.5) {
            float3 fc = bk < 1.5 ? float3(0.85, 0.06, 0.05)               // poppy
                      : (bk < 2.5 ? float3(0.86, 0.22, 0.48)              // campion
                      : (bk < 3.5 ? float3(0.95, 0.94, 0.90)              // daisy
                      : float3(0.98, 0.72, 0.05)));                       // buttercup
            col = fc * (sunS * 1.1 + trans * fc * (0.6 + 1.2 * brim));    // (petals glow at the rim)
        } else {
            float3 sc = float3(0.62, 0.55, 0.36);
            col = sc * (sunS * 0.8 + trans * (0.8 + 1.4 * brim));
        }
        acc += keep * best * col;
        keep *= 1.0 - best;
    }
    return float4(acc, 1.0 - keep);
}

// ---------------------------------------------------------------- the scene
// wx: the weather copy (u.weather*: Shared/Weather/Weather_funcs.h) — compiled apart from the
// clear one (Weather_fragment.h: fx_meadow, fx_wx_meadow).
// landC: the landscape, a constant in each copy (−1: from the uniforms — the über-shader's fallback).
static inline float4 meadow_scene(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u,
                                  const bool wx, const int landC = -1) {
    const float F = MEADOW_F;
    float speed = u.p0.x, windP = clamp(u.p0.y, 0.0, 1.0), flowers = clamp(u.p0.z, 0.0, 1.0);
    float cloudP = clamp(u.p0.w, 0.0, 1.0);
    const int land = landC >= 0 ? landC : clamp(int(u.p2.x + 0.5), 0, 3);
    float glow = clamp(u.p2.y, 0.0, 1.0), dith = clamp(u.p2.z, 0.0, 1.0);
    WxState W = wx ? wx_state(u) : WxState{};
    float ts = t * speed;
    float aspect = res.x / res.y;
    MeadowLayout Lo = meadow_layout(land, aspect);
    float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
    float cp, spt = sincos(Lo.pitch, cp);
    float3 fwd = float3(0.0, spt, cp), up = float3(0.0, cp, -spt);
    float3 rd = normalize(fwd * F + float3(1.0, 0.0, 0.0) * sp.x + up * sp.y);
    float pix = 2.0 / (res.y * F);                              // radians per pixel
    float pixS = 2.0 / res.y;                                   // screen units per pixel
    float yh = -F * spt / cp;                                   // the horizon line

    // Wind: the slider, and the weather's (4 m/s = the scene's own breeze).
    float wind = windP * (wx ? clamp((W.wind + 2.0) / 6.0, 0.35, 2.6) : 1.0);
    if (wx) wind += 0.25 * saturate((W.gust - W.wind - 3.0) / 10.0);
    float tw = ts * (2.5 + 5.0 * wind);                         // how far the gusts have travelled, m

    // ---- the sky's light (Tidewater's live sky, Nature_funcs.h: u.sun / u.moon / u.sky are
    // always filled for this scene — the real sky, or Time of Day's: MetalRenderer.fixedSky)
    NatureOceanP P;
    float haze = 0.15 + 0.30 * glow;                            // (the air: Glow thickens it)
    P.live = true;
    P.se = u.sun.x;
    P.sd = nature_oceanSunDir(u, true);
    P.esun = nature_liveTint(u) * 9.5;
    P.mie = 0.008 + 0.065 * haze;
    P.tauS = NATURE_RAYLEIGH + P.mie;
    P.tauT = P.tauS + float3(0.016, 0.047, 0.002) + 0.02 * haze;
    P.clouds = cloudP;
    P.tc = (t + u.weather3.x) * speed * 0.004;
    P.pix = pix;
    P.ms = length(P.esun) * (0.3 + 0.7 * smoothstep(-0.1, 0.15, P.se));
    P.amb = length(P.esun);
    P.tw = 0.0;
    P.sh = float2(0.0, 1.0);
    P.deck = 0.0; P.hb = 2.5; P.dx = 4000.0;
    P.lb = float3(0.0); P.aur = float3(0.0); P.cdark = 0.0; P.flash = float3(0.0);
    P.fd = float3(0.0, 1.0, 0.0); P.eglow = float3(0.0);
    float dd = nature_liveDD(u);
    bool keyMoon = false;
    {
        float fall = nature_liveFall(dd);
        P.ms *= fall;
        P.amb *= mix(0.25, 1.0, smoothstep(-6.0, 2.0, -dd)) * fall;
        if (dd > -2.0 && dd < 18.0) P.tw = length(P.esun) * smoothstep(18.0, 12.0, dd);
        P.sh = normalize(P.sd.xz + float2(0.0, 1e-5));
        P.mie *= (1.0 - 0.45 * nature_liveDay(u)) * (1.0 - 0.45 * smoothstep(4.0, 12.0, dd));
        P.tauS = NATURE_RAYLEIGH + P.mie;
        if (dd > 5.0) {
            keyMoon = true;
            float mel;
            P.sd = nature_oceanMoonDir(u, mel);
            P.se = mel;
            P.esun = nature_liveMoonE(u, dd);
            P.amb += 0.7 * length(P.esun);
        }
    }
    // Facing: Tidewater looks along the sun's arc (south, here). Meadow, Rolling Hills and Hillside
    // turn their back on it — the light comes from behind and to one side, the hills stand modelled
    // in it, the sky is deepest blue ahead — so the whole sky (sun, moon, stars) is turned by
    // `face` about the vertical; skyV takes a view direction into Tidewater's sky frame.
    // As the sun gets low the view swings round to face it — golden hour and dusk are backlit, the
    // grass glowing against the light — and stays facing the moon's arc through the night.
    float face = (land == 2 ? 0.0 : (land == 3 ? 2.15 : 2.45)) * smoothstep(0.06, 0.32, u.sun.x);
    float cfa, sfa = sincos(face, cfa);
    P.sd = float3(cfa * P.sd.x + sfa * P.sd.z, P.sd.y, -sfa * P.sd.x + cfa * P.sd.z);
    P.sh = normalize(P.sd.xz + float2(0.0, 1e-5));
    float3 Tsun = exp(-P.tauT * nature_airmass(P.se));

    // Clouds: the Clouds slider, then the weather's cover (Clear = the scene's own sky).
    // (Tidewater's clouds: its altocumulus deck and cirrus, nature_oceanClouds; with the weather its
    // fair-weather cumulus and overcast. Their shadows drift over the land.)
    float thrS = mix(0.35, -0.10, cloudP);                      // (the cloud shadows)
    float cuAmt = smoothstep(0.0, 0.12, cloudP);
    float cuCover = mix(0.22, 0.85, cloudP);                    // (the cumulus heaps)
    float tower = land == 3 ? 1.0 : 0.0;                        // (Hillside: a towering cloud)
    // ---- weather (all uniform): Tidewater's deck, fog and lightning, in the same terms.
    float sunVis = 1.0, fogB = 0.0, fogH = 1.0, sunT = 1.0, flashE = 0.0;
    float3 fogA = float3(0.0), ambL = float3(0.0);
    float4 ev = float4(0.0);
    if (wx) {
        float cv = W.cover;
        thrS = cv < 0.25 ? mix(0.6, thrS, cv * 4.0) : mix(thrS, -0.3, smoothstep(0.25, 0.85, cv));
        cuCover = cv < 0.25 ? cuCover * mix(0.4, 1.0, cv * 4.0) : mix(cuCover, 0.95, smoothstep(0.25, 0.7, cv));
        tower = max(max(tower, W.storm), 0.5 * smoothstep(0.4, 0.7, cv));
        cuAmt = cv < 0.25 ? cuAmt * mix(0.4, 1.0, cv * 4.0) : max(cuAmt, smoothstep(0.25, 0.45, cv));
        cuAmt *= 1.0 - smoothstep(0.35, 0.65, W.fog);
        float c0 = P.clouds;
        P.clouds = cv < 0.25 ? c0 * mix(0.3, 1.0, cv * 4.0) : mix(c0, 1.05, smoothstep(0.25, 0.9, cv));
        P.deck = W.deck;
        P.clouds = mix(P.clouds, c0 * 0.3, nature_wxCu(u)) + 0.6 * P.deck;
        float heavy = max(W.rain, W.storm);
        P.hb = mix(2.5, mix(1.6, 0.85, heavy), P.deck);
        P.dx = mix(4000.0, P.hb / 0.05, 1.0 - smoothstep(0.86, 0.995, cv));
        float tau = 9.0 + 22.0 * W.rain + 8.0 * W.snow + 50.0 * W.storm;
        float3 Ttop = nature_sunAt(P, P.hb + 1.0, u);
        float3 Etop = P.esun * Ttop * max(P.sd.y + 0.06, 0.0) + P.ms * float3(0.0011, 0.0042, 0.0165) * 1.5;
        P.lb = Etop * (0.24 / (1.0 + 0.11 * tau));
        P.lb = mix(P.lb, float3(luma(P.lb)), 0.6) + float3(0.0017, 0.0020, 0.0028);
        P.lb = mix(P.lb, luma(P.lb) * float3(0.95, 0.99, 1.07) * 1.3, W.snow);
        P.aur = P.esun * Ttop * exp(-tau * 0.11) * 0.08;
        P.cdark = 0.38 + 0.12 * W.rain + 0.55 * W.storm;
        float nk = smoothstep(3.0, 12.0, dd) * smoothstep(0.55, 0.95, cv);
        P.lb += float3(0.0034, 0.0031, 0.0030) * nk;
        if (keyMoon) P.aur += P.esun * (0.8 * nk * exp(-tau * 0.05) * smoothstep(-0.03, 0.06, P.sd.y));
        float tS = P.hb / max(P.sd.y, 0.002);
        sunVis = 1.0 - P.deck * smoothstep(P.dx * 1.3, P.dx * 0.8, tS);
        P.eglow = P.esun * Tsun * sunVis * 0.02 * P.deck;
        ambL = mix(P.esun * Tsun * max(P.sd.y, 0.0) * 0.035 + P.ms * float3(0.0011, 0.0042, 0.0165) * 2.5,
                   P.lb, P.deck);
        fogB = wx_fogBeta(W.fog);
        fogH = mix(mix(600.0, 220.0, smoothstep(0.3, 0.9, W.fog)), 180.0, saturate(W.wet * 2.0));
        fogA = luma(ambL) * float3(0.98, 1.0, 1.04) * (1.0 + 0.4 * smoothstep(0.4, 0.9, W.fog))
             + P.esun * Tsun * sunVis * 0.05 * smoothstep(0.5, 0.85, W.fog) * (1.0 - W.wet)
             + float3(1.0, 0.76, 0.56) * (0.0080 * nk * (1.0 - 0.5 * smoothstep(0.3, 0.8, W.fog)));
        sunT = exp(-min(fogB * min(fogH / max(P.sd.y, 0.004), 30000.0), 2.6));
        if (W.storm > 0.0 && u.weather3.y > 0.5) {
            flashE = wx_lightning(t, W.storm, ev);
            if (flashE > 0.0) {
                float az = ev.x * 0.7, d = 2.5 + 6.0 * ev.y;
                float el = atan(P.hb / d) * (ev.z < 0.4 ? 1.0 : 0.8);
                P.fd = float3(sin(az) * cos(el), sin(el), cos(az) * cos(el));
                P.flash = float3(0.80, 0.84, 1.0) * (flashE * 0.22 / nature_oceanExpo(u));
            }
        }
    }

    // ---- what lights the land (uniform: worked out once per pixel at next to no cost)
    MeadowLight L;
    L.sd = P.sd;
    float sunUp = smoothstep(-0.015, 0.03, P.se);
    L.sunE = P.esun * Tsun * (sunUp * sunVis * sunT);
    {
        // (Sunlight at the sky's scatterers, 1 · 4.5 · 8 km up: meadow_atmos interpolates them.
        // Worked out here and again for the sky, not held through the scene: registers.)
        float3x3 lTs = meadow_lTs(P, u);
        L.amb = meadow_atmos(normalize(float3(0.35 * P.sh.x, 0.55, 0.35 * P.sh.y)), P, u, lTs, wx) * 1.15;
        // The haze colour: the sky's own radiance just above the horizon, this way.
        const float mv0 = 1.0 / (0.012 + 0.025 * 0.876341);    // (meadow_atmos's airmass at 0.012)
        float3 hzA = P.esun * exp(lTs[1] - 0.2809 * (lTs[2] - lTs[0]) + 0.1578 * (lTs[0] + lTs[2] - 2.0 * lTs[1])) * (1.0 - exp(-P.tauS * mv0))
                   / (NATURE_RAYLEIGH + P.mie);
        float3 hzB = P.ms * float3(0.0011, 0.0042, 0.0165) * 0.9958
                   + float3(0.0007, 0.0012, 0.0028) * smoothstep(2.0, 12.0, dd) * 2.84;
        L.hz = meadow_haze(normalize(float3(rd.x, 0.012, rd.z)), P, u, hzA, hzB, wx);
    }
    if (wx) L.amb = mix(L.amb, ambL * 2.2, P.deck) + P.flash * 0.6;
    L.c = dot(rd, P.sd);
    L.beta = 0.00005 + 0.00020 * haze;
    L.shK = 0.85 * cuAmt * (1.0 - P.deck);
    float3 alb = srgbToLinear(u.colorA.rgb) * 0.45;            // the grass's albedo
    if (wx) alb = mix(alb, float3(luma(alb)) * float3(1.1, 1.15, 1.25) * 3.5, 0.35 * W.snow);
    float gwind = saturate(wind * 1.6);

    // Pixel → which surface, front to back: the stems at the lens and the grass (Meadow, Tall
    // Grass), then the land — the meadow plane and five ridges receding to the horizon, the first one
    // nearer than the plane along this ray winning — then the sky. Silhouettes are antialiased by
    // coverage; what lies behind an edge is only worked out there.
    float X = sp.x, y = sp.y;
    float3 acc = float3(0.0);
    float keep = 1.0;
    float dist = 1e5;                                           // distance of what's seen (fog)
    if (Lo.stalks > 0.0) {
        float4 st = meadow_stalks(rd, Lo, pix, ts, tw, wind, flowers, alb, L);
        acc = st.rgb;
        keep = 1.0 - st.a;
        if (st.a > 0.5) dist = 0.5;
    }
    if (Lo.blades && keep > 0.002) {
        float4 bl = meadow_blades(rd, Lo, pix, ts, tw, wind, flowers, alb, L);
        acc += keep * bl.rgb;
        keep *= 1.0 - bl.a;
        if (bl.a > 0.5) dist = min(dist, 3.0);
    }
    float3 hzFar = L.hz * float3(0.84, 0.93, 1.10);             // (distance is blue)
    float aerB = 0.00006 + 0.00010 * haze;
    // (Hillside: the plane is the sea, 110 m below the slope the camera stands on.)
    const float H0 = 110.0, thS = 0.30;
    float dpl = rd.y < -1e-4 ? (land == 3 ? H0 + Lo.camH : Lo.camH) / -rd.y : 1e9;   // the meadow plane along this ray
    if (land == 3 && keep > 0.002) {
        // Hillside: a long slope rising to the left (a tilted plane through the camera's feet),
        // falling to the sea on the right, where it is cut at the water line. Long wind streaks
        // run along it; its far reach lies under the cloud's shadow.
        float sT, cT = cos(thS); sT = sin(thS);
        float3 ng = float3(sT, cT, 0.0);
        float dn = dot(rd, ng);
        float tS = dn < -1e-5 ? Lo.camH * cT / -dn : 1e9;
        float3 hp = rd * tS;
        float hgt = H0 - hp.x * (sT / cT);
        if (tS < 1e8 && hgt > 0.0) {
            float fpx = tS * pix;
            float sk = smoothstep(1.0, 0.2, fpx * 0.1);
            float2 sc = float2(hp.z, -hp.x / cT);                 // along the slope, up it
            float2 sd2 = float2(sc.x * 0.6 + sc.y * 0.8, sc.y * 0.6 - sc.x * 0.8);   // (diagonal to the slope)
            float st = sk > 0.0 ? (meadow_gnoise(float2(sd2.x * 0.08, sd2.y * 0.9))
                                   + 0.5 * meadow_gnoise(float2(sd2.x * 0.3, sd2.y * 3.0) + 3.0) * smoothstep(0.4, 0.1, fpx)) * sk : 0.0;
            float sw = sin(sc.x * 0.018 + 1.5 * sin(sc.y * 0.025)), cw2 = cos(sc.x * 0.018 + 1.5 * sin(sc.y * 0.025));
            float3 n = normalize(ng + float3(0.0, 0.0, -0.22 * cw2) + float3(0.10 * st, 0.0, 0.0));
            float bend = meadow_gust(hp.xz, tw);
            bend = bend * bend * gwind;
            float3 a = alb * mix(float3(0.95, 1.0, 0.85), float3(1.22, 1.10, 0.62), saturate(0.5 + 0.4 * sw)) * (1.0 + 0.6 * st);
            bend = saturate(bend * 1.8);
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(hp.xz, P.sd, P.tc, thrS) : 0.0;
            sh = max(sh, smoothstep(90.0, 170.0, tS));            // (the far reach, under the cloud)
            float3 g = meadow_sward(a, n, bend, sh, L);
            g *= mix(0.6, 1.0, smoothstep(2.0, 25.0, tS)) * mix(1.0, 0.55, smoothstep(90.0, 170.0, tS));
            g = mix(g, hzFar, 1.0 - exp(-max(tS - 250.0, 0.0) * aerB));
            float cov = 1.0;
            acc += keep * cov * g;
            keep = 0.0;
            dist = min(dist, tS);
        }
    }
    if (keep > 0.002 && y < yh + 0.70) {
        for (int k = 0; k < 5; ++k) {
            float dk = MEADOW_RD[land][k];
            if (dk > 1e5) continue;                                  // (no such ridge here)
            if (dpl < dk || keep <= 0.002) break;
            float2 tp = meadow_ridgeTop(Lo, k, X);
            if (tp.x < -0.5) continue;
            float top = yh + tp.x;
            bool trees = (land == 0 && k == 2) || (land == 1 && k == 3);
            float th = trees ? F * (land == 0 ? 20.0 : 12.0) / dk : 0.0;   // tree height, screen
            if (y > top + th + 2.0 * pixS) continue;
            float yF = yh - F * Lo.camH / dk;
            // The air in front of it: only the far ridges go blue and soft (the near stay crisp).
            float aer = 1.0 - exp(-max(dk - 250.0, 0.0) * aerB);
            // Trees on the crest: cypresses (Meadow) or round crowns (Rolling Hills).
            if (trees && y > top - th * 0.3) {
                float cw = land == 0 ? 0.06 : 0.03;
                float ci = floor(X / cw);
                float tc = 0.0;
                for (int m = -1; m <= 1; ++m) {
                    float3 h = meadow_rand3(uint(int(ci) + m + 0x40000) * 0x9E3779B1u + uint(k) * 77u);
                    if (h.x > (land == 0 ? 0.20 : 0.45)) continue;
                    float cx = (ci + float(m) + 0.5 + 0.3 * (h.y - 0.5)) * cw;
                    float base = top + tp.y * (cx - X) - 0.002;
                    float hgt = th * (0.7 + 0.5 * h.z);
                    if (land == 0) {
                        float yy = (y - base) / hgt;                    // a cypress: a dark flame
                        float wdt = hgt * 0.13 * sqrt(saturate(yy * (1.0 - yy) * 4.0)) * pow(saturate(1.0 - yy), 0.3);
                        tc = max(tc, saturate((wdt - abs(X - cx)) / pixS + 0.5) * step(0.0, yy));
                    } else {
                        float r = hgt * 0.45;
                        float2 dv = float2(X - cx, (y - base - r * 0.9) * 0.9);
                        tc = max(tc, saturate((r - length(dv)) / pixS + 0.5));
                    }
                }
                if (tc > 0.0) {
                    float3 g = alb * float3(0.30, 0.45, 0.28) * (L.sunE * 0.10 + L.amb * 0.45);
                    g = mix(g, hzFar, aer);
                    acc += keep * tc * g;
                    keep *= 1.0 - tc;
                    dist = min(dist, dk);
                    if (keep <= 0.002) break;
                }
            }
            if (y > top + pixS) continue;
            float cov = saturate((top - y) / pixS + 0.5);
            float s = saturate((top - y) / max(top - yF, 1e-4));    // 0 at the crest … 1 at its foot
            float dl = dk * (1.0 + 0.3 * (1.0 - s));
            float2 w = float2(X / F * dl, dk + s * 0.5 * dk);
            // Form: the silhouette's slope turns the flanks toward the light or away; below the crest
            // the face falls toward us, then levels into the hollow at its foot.
            float face = sin(3.14159 * sqrt(s));
            float3 n = normalize(float3(-tp.y * 3.6, 1.0, -0.8 * face - 0.05));
            float3 a = alb * mix(float3(0.90, 1.0, 0.95), float3(1.15, 1.06, 0.72),
                                 0.5 + 0.5 * nature_sinT(w.x * 0.0035 + float(k) * 0.37));
            float bend = 0.0;
            if (k <= 1) {
                // Velvet: wind streaks along the slope, the gusts' sheen running over it.
                float fpx = dl * pix;
                float sk = smoothstep(1.0, 0.25, fpx * 0.12);
                float streak = sk > 0.0 ? meadow_gnoise(float2(w.x * 0.35 + w.y * 0.1, w.y * 0.6)) * sk : 0.0;
                bend = meadow_gust(w, tw);
                bend = bend * bend * gwind;
                float gk = smoothstep(0.10, 0.03, fpx);
                float grain = gk > 0.0 ? meadow_gnoise(w * float2(2.0, 1.4)) * gk : 0.0;
                a *= 1.0 + (land == 1 ? 0.15 : 0.30) * streak + 0.3 * grain;
            } else if (k <= 3 && land == 0) {
                // A patchwork of meadows, hay and crop between hedges.
                float2 wr = float2(w.x * 0.95 + w.y * 0.31, w.y * 0.95 - w.x * 0.31);
                float2 cs = float2(160.0, 100.0) * (k == 3 ? 1.6 : 1.0);
                float2 cid = floor(wr / cs), cf = wr / cs - cid;
                float3 hc = meadow_rand3(uint(int(cid.x) + 0x4000) * 0x9E3779B1u ^ uint(int(cid.y) + 0x4000) * 0x85EBCA77u);
                a = alb * (hc.x < 0.6 ? mix(float3(0.85, 1.0, 0.75), float3(1.15, 1.08, 0.70), hc.y)
                                      : (hc.x < 0.85 ? float3(1.5, 1.22, 0.55) : float3(1.05, 0.92, 0.55)));
                float fx = dl * pix * 1.2;
                float2 ed = min(cf, 1.0 - cf) * cs;
                float hedge = max(smoothstep(3.0 + fx, 3.0 - fx, ed.x), smoothstep(3.0 + fx * 3.0, 3.0 - fx * 3.0, ed.y));
                a = mix(a, alb * float3(0.40, 0.58, 0.38), hedge * 0.8 * smoothstep(60.0, 8.0, fx));
            }
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(w, P.sd, P.tc, thrS) : 0.0;
            if (land == 3 && k == 1) sh = max(sh, 0.9);                // (the ridge under the cloud)
            float3 g = meadow_sward(a, n, bend, sh, L);
            // The hollow at its foot lies in shade, with a little mist pooled in it.
            g *= mix(1.0, 0.42, smoothstep(0.5, 1.0, s) * (k == 0 ? (land == 1 ? 0.0 : 0.7) : 1.0));
            g = mix(g, L.hz * 1.05, smoothstep(0.75, 1.0, s) * (0.08 + 0.22 * glow) * (k == 0 ? 0.3 : 1.0));
            g = mix(g, hzFar, aer);
            acc += keep * cov * g;
            keep *= 1.0 - cov;
            dist = min(dist, dl);
        }
    }
    if (keep > 0.002 && dpl < 1e8) {
        float d = dpl;
        float2 w = rd.xz * d;
        float3 g;
        if (land == 3) {
            // The sea: dark blue water mirroring the sky at a grazing angle, a glitter path under
            // the sun, its swell drifting.
            float gr = -rd.y;
            float Fr = 0.02 + 0.98 * pow(1.0 - saturate(gr * 6.0), 5.0);
            float wv = meadow_gnoise(w * float2(0.004, 0.02) + float2(ts * 0.05, 0.0));
            float3 water = float3(0.010, 0.028, 0.050) * (L.amb * 3.0 + L.sunE * 0.04);
            g = mix(water, L.hz * 0.85, saturate(Fr * (0.85 + 0.3 * wv)));
            float3 rr = float3(rd.x, -rd.y, rd.z);
            float gl = exp(-(1.0 - dot(rr, P.sd)) * 900.0) * (0.6 + 0.8 * saturate(wv + 0.5));
            g += L.sunE * gl * 0.08;
            g = mix(g, hzFar, 1.0 - exp(-d * aerB * 1.2));
        } else if (Lo.blades) {
            // The meadow under the grass: swells, tufts, colour drifts, flowers' tint.
            float bend = meadow_gust(w, tw);
            bend = bend * bend * gwind;
            float2 sw1 = float2(w.x * 0.031 + w.y * 0.012, w.y * 0.027 - w.x * 0.009);
            float c1, c2, s1 = sincos(sw1.x + 1.3 * sin(sw1.y), c1), s2 = sincos(sw1.y * 1.7 + 0.6, c2);
            float3 gn = float3(0.25 * (s1 + s2), 0.25 * c1 * 0.031 * 18.0, 0.25 * c2 * 0.046 * 18.0);
            float fpx = d * pix;
            float tk = smoothstep(0.9, 0.25, fpx * 0.45);
            float3 tn = tk > 0.0 ? meadow_gnoised(w * float2(0.45, 0.32) + 11.0) * tk : float3(0.0);
            float3 n = normalize(float3(-gn.y * 0.8 - tn.y * 0.55, 1.0, -gn.z * 0.8 - tn.z * 0.4));
            float patch = gn.x * 1.4 + 0.25 * sin(w.x * 0.05 + w.y * 0.11) + tn.x * 0.5;
            float3 a = alb * mix(float3(0.74, 0.93, 0.60), float3(1.30, 1.15, 0.70), saturate(0.5 + patch));
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(w, P.sd, P.tc, thrS) : 0.0;
            g = meadow_sward(a, n, bend, sh, L);
            g *= mix(0.40, 1.0, smoothstep(1.2, 8.0, d)) * mix(0.55, 1.05, saturate(0.5 + gn.x * 1.6));
            // Wildflowers across the field: heads on cells a hand's breadth across, in rows by
            // log-distance (so their screen size is even), out to ~60 m; past that their tint.
            if (d < 60.0 && flowers > 0.0) {
                const float lk = 9.0, cxw = 0.30;
                float rowf = log(d) * lk, ri = floor(rowf);
                float colf = w.x / cxw, cj = floor(colf);
                float3 h = meadow_rand3(uint(int(ri) + 0x4000) * 0x85EBCA77u ^ uint(int(cj) + 0x40000) * 0x9E3779B1u);
                if (h.x < flowers * 0.5 * saturate(0.6 + 1.2 * gn.x)) {
                    float xc = (cj + 0.2 + 0.6 * h.y) * cxw, rc = ri + 0.2 + 0.6 * h.z;
                    float dd2 = exp(rc / lk);                        // (the flower's own distance)
                    float2 ds = float2((w.x / d - xc / dd2) * F, (rowf - rc) / lk * F * Lo.camH / d);
                    float rs = F * (0.016 + 0.012 * h.y) / d;
                    float fcov = saturate((rs - length(ds)) / pixS + 0.5) * smoothstep(60.0, 35.0, d);
                    float sel = fract(h.y * 7.3 + h.z * 3.1);
                    float3 fc = sel < 0.45 ? float3(0.82, 0.07, 0.05) : (sel < 0.75 ? float3(0.95, 0.93, 0.88)
                              : (sel < 0.9 ? float3(0.95, 0.72, 0.06) : float3(0.84, 0.26, 0.55)));
                    g = mix(g, fc * (L.sunE * 0.30 + L.amb * 0.9 + L.sunE * fc * nature_hg(L.c, 0.4) * 0.5), fcov);
                }
            }
            // Wildflowers too small to resolve: their colour, in drifts (poppy red, daisy white).
            float fa = flowers * 0.16 * smoothstep(3.0, 9.0, d) * saturate(0.3 + 1.8 * gn.x + tn.x);
            float3 fcol = mix(float3(0.80, 0.12, 0.08), float3(0.95, 0.92, 0.85), 0.5 + 0.5 * nature_sinT(w.x * 0.013 + w.y * 0.007));
            g = mix(g, fcol * (L.sunE * 0.30 + L.amb * 0.9), fa);
            g = mix(g, L.hz, 1.0 - exp(-d * aerB * 0.5));
        } else {
            // Velvet ground: big swells with dark hollows, wind streaks, the gusts' sheen.
            float2 sw1 = float2(w.x * 0.045 + w.y * 0.016, w.y * 0.05 - w.x * 0.012);
            float c1, c2, s1 = sincos(sw1.x + 1.1 * sin(sw1.y), c1), s2 = sincos(sw1.y * 1.4 + 0.6, c2);
            float3 gn = float3(0.25 * (s1 + s2), 0.25 * c1 * 0.045 * 40.0, 0.25 * c2 * 0.07 * 40.0);
            float fpx = d * pix;
            float sk = smoothstep(0.6, 0.12, fpx * 0.7);
            float streak = sk > 0.0 ? meadow_gnoise(float2(w.x * 0.7 + w.y * 0.2, w.y * 1.6)) * sk : 0.0;
            float3 n = normalize(float3(-gn.y, 1.0, -gn.z));
            float bend = meadow_gust(w, tw);
            bend = bend * bend * gwind;
            float gk = smoothstep(0.08, 0.02, fpx);
            float grain = gk > 0.0 ? meadow_gnoise(w * float2(3.0, 2.2)) * gk : 0.0;
            float3 a = alb * mix(float3(0.88, 1.0, 0.90), float3(1.18, 1.08, 0.72), saturate(0.5 + gn.x)) * (1.0 + 0.4 * streak + 0.35 * grain);
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(w, P.sd, P.tc, thrS) : 0.0;
            g = meadow_sward(a, n, bend, sh, L) * mix(0.55, 1.0, saturate(0.5 + gn.x * 1.4));
            g = mix(g, L.hz, 1.0 - exp(-d * aerB * 0.5));
        }
        acc += keep * g;
        keep = 0.0;
        dist = min(dist, d);
    }
    // ---- the sky
    float3 stars = float3(0.0);
    if (keep > 0.002) {
        float3 v = rd;
        v.y = max(v.y, 0.002);
        v = normalize(v);
        float3 sky = meadow_atmos(v, P, u, meadow_lTs(P, u), wx);
        // A summer sky: deep blue overhead by day — deepest in Hillside, under the storm's edge.
        float dayK = nature_liveDay(u) * (wx ? 1.0 - P.deck : 1.0);
        sky *= mix(float3(1.0), land == 3 ? float3(0.45, 0.62, 1.0) : float3(0.78, 0.96, 1.05),
                   dayK * smoothstep(0.0, 0.45, v.y) * (land == 3 ? 1.0 : 0.8));
        float3 discL = float3(0.0);
        if (!keyMoon && sunVis > 0.0) {
            float3 dv = v - P.sd;
            float flat = mix(0.82, 1.0, smoothstep(0.0, 0.08, P.se));
            float ad = length(float2(dv.x, dv.y / flat));
            const float R = 0.0075;
            float disc = smoothstep(R + pix, R - pix, ad);
            float limb = sqrt(max(1.0 - (ad / R) * (ad / R), 0.0));
            discL = P.esun * Tsun * disc * (0.45 + 0.55 * limb) * 60.0;
        }
        if (abs(v.y - sin(0.40 * tanh(u.moon.x / 0.40))) < 0.02)
            sky += nature_oceanMoonNear(float3(cfa * v.x - sfa * v.z, v.y, sfa * v.x + cfa * v.z), u, P.tauT, pix)
                 * (wx ? (keyMoon ? sunVis * sunT : 1.0 - P.deck) : 1.0);
        float cov = 0.0;
        // Tidewater's clouds (Nature_funcs.h): the lit altocumulus deck and cirrus; with the
        // weather, its fair-weather cumulus and the deck closing over.
        float3 col = sky;
        if (wx) col = nature_oceanClouds(v, sky, P, 5, cov, u, 0.0, true, false);
        else {
            float4 ci = meadow_cirrus(v, sky, P, cloudP, u);
            col = col * (1.0 - ci.a) + ci.rgb;
            cov = ci.a;
        }
        if (v.y > 0.004) {
            float4 cu4 = meadow_cumulus(v, sky, P, cuCover * (wx ? 1.0 - P.deck : 1.0), tower, pix, u);
            col = col * (1.0 - cu4.a) + cu4.rgb;
            cov = 1.0 - (1.0 - cov) * (1.0 - cu4.a);
        }
        if (wx) {
            float cu2 = max(W.rain, 0.8 * W.storm);
            if (cu2 > 0.45) {
                float a = wx_curtains(atan2(v.x, v.z), v.y, atan(P.hb / 7.0), P.tc, smoothstep(0.45, 0.95, cu2) * 0.85);
                col = mix(col, ambL * 0.5 + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(dot(v, P.sd), 0.8) * 0.08, a);
            }
            if (fogB > 0.0) {
                float cs = dot(v, P.sd);
                float3 fc = fogA + P.esun * Tsun * (sunVis * sqrt(sunT)) * (nature_hg(cs, 0.8) * 0.025 + nature_hg(cs, 0.97) * 0.0015)
                          + P.flash * (0.04 + 0.3 * exp(6.0 * (dot(v, P.fd) - 1.0)));
                col = mix(col, fc, 1.0 - exp(-fogB * min(fogH / max(v.y, 0.004), 30000.0)));
            }
            if (flashE > 0.0 && ev.z < 0.4) {
                float dB = 2.5 + 6.0 * ev.y;
                col += float3(0.85, 0.88, 1.0) * (P.flash.b * 60.0) * exp(-0.5 * min(fogB * dB * 1000.0, 3.0))
                     * wx_bolt(v, ev.x * 0.7, atan(P.hb / dB), ev.w * 97.0, pix * 0.7);
            }
            col += discL * ((1.0 - cov) * sunVis * sunVis * sunT * sqrt(sunT));
        } else {
            col += discL * (1.0 - cov);
        }
        if (dd > 8.5 && cov < 0.9)
            stars = nature_oceanStars(float3(cfa * v.x - sfa * v.z, v.y, sfa * v.x + cfa * v.z), u, pix, t)
                  * ((1.0 - cov) * smoothstep(0.9, 0.6, cov) * keep);
        acc += keep * col;
    }
    float3 col = acc;
    // ---- weather in front of everything: fog over the land, rain and snow, lightning's light.
    if (wx) {
        if (fogB > 0.0 && dist < 1e4) {
            float3 fc = fogA + L.sunE * nature_hg(L.c, 0.8) * 0.0026 + P.flash * 0.05;
            col = mix(col, fc, 1.0 - exp(-fogB * dist));
        }
        if (W.wet > 0.005) {
            float share = saturate(u.weather.z);
            float rk = 1.0 - smoothstep(0.62, 0.9, share), sk = smoothstep(0.2, 0.42, share);
            float cs = dot(rd, P.sd);
            if (rk > 0.0) {
                float sl = clamp(W.wind * 0.03, 0.0, 0.45) * (1.0 + 0.25 * sin(ts * 0.45));
                float ra = rk * wx_streaks(sp, ts, pixS, F, saturate(W.wet * 1.4) * (1.0 - 0.4 * sk), sl, rd.y, Lo.camH,
                                           max(smoothstep(0.35, 0.12, W.wet), 0.5 * share));
                col = mix(col, ambL * 1.8 + P.esun * Tsun * (sunVis * sqrt(sunT)) * nature_hg(cs, 0.8) * 0.08 + P.flash * 0.25, ra);
            }
            if (sk > 0.0) {
                float2 sa = sk * wx_flakes(sp, ts, pixS, F, min(W.wet * 1.55, 1.4) * (1.0 - 0.45 * rk), W.wind, rd.y, Lo.camH, rk);
                float vk = W.snow * (0.08 + 0.35 * exp(-abs(rd.y) * 28.0));
                col = mix(col, fogA * 1.05 + ambL * 0.1, vk);
                float3 fsun = P.esun * Tsun * (sunVis * sqrt(sqrt(sunT))) * (0.015 + 0.5 * nature_hg(cs, 0.65));
                float nK = smoothstep(3.0, 12.0, dd);
                float3 flakeL = mix(ambL, float3(luma(ambL)), 0.2 + 0.3 * nK) * (2.2 + 1.3 * nK) + mix(fsun, float3(luma(fsun)), 0.45);
                col *= 1.0 - 0.22 * sa.y;
                col = mix(col, flakeL, sa.x);
            }
        }
        col *= 1.0 + P.deck * (0.3 - 0.25 * W.storm);
    }
    // ---- fireflies: on a clear summer night, soft green-gold lights drifting low over the grass,
    // each glowing up and fading on its own slow rhythm (screen cells, one fly each).
    float ffK = smoothstep(6.0, 10.0, dd) * (wx ? (1.0 - saturate(W.wet * 4.0)) * (1.0 - P.deck * 0.5) : 1.0);
    if (ffK > 0.0 && y < yh + 0.05) {
        float2 cq = sp * float2(5.5, 7.0);
        float2 ci = floor(cq);
        float3 h = meadow_rand3(uint(int(ci.x) + 0x4000) * 0x9E3779B1u ^ uint(int(ci.y) + 0x4000) * 0x85EBCA77u);
        if (h.z < 0.45) {
            float ph = ts * (0.06 + 0.05 * h.x) + h.y;
            float2 c0 = ci + 0.5 + 0.32 * float2(nature_sinT(ph + h.z), nature_sinT(ph * 0.73 + 0.25));
            float r = length((cq - c0) / float2(5.5, 7.0)) / pixS;            // px from the fly
            float sz = max(1.2, 2.2 * res.y / 1600.0);
            float pulse = saturate(nature_sinT(ts * (0.11 + 0.08 * h.y) + h.x) * 1.6 - 0.35);
            float lum = (exp(-r * r / (sz * sz)) + 0.22 * exp(-r * r / (sz * sz * 9.0))) * pulse * ffK;   // (halo inside its cell)
            col += float3(0.55, 0.85, 0.25) * lum * 0.08;
        }
    }
    // ---- glow: what a soft lens and summer air do to light. A wide bloom and a tighter halo round
    // the light (it wraps round everything near it), a veil of scattered light over the frame,
    // and the air low down lit up toward the horizon — most toward the light.
    {
        float3 E = P.esun * Tsun * (sunUp * sunVis * sunT);
        col += E * glow * (0.0025 * nature_hg(L.c, 0.96) + 0.012 * nature_hg(L.c, 0.85)
                           + 0.004 * nature_hg(L.c, 0.6) + 0.0015);
        float lowK = exp(-abs(rd.y) * 8.0) * (1.0 - exp(-dist * 0.0004));   // (the near field stays clear)
        col = mix(col, L.hz * 1.15, glow * (0.02 + 0.22 * lowK));
    }
    // White balance toward the low sun (gold, not red), as Tidewater.
    float wbAmt = 0.12 * smoothstep(-0.07, -0.02, u.sun.x);
    if (wbAmt > 0.0) {
        float3 TsunS = exp(-P.tauT * nature_airmass(u.sun.x));
        float3 wb = TsunS / max(max(TsunS.r, TsunS.g), 1e-4);
        col /= mix(float3(1.0), max(wb, 0.05), wbAmt);
    }
    col = col * nature_oceanExpo(u) * (1.35 + 0.35 * nature_liveDay(u)) + stars;
    // ---- display: the filmic shoulder, a soft filmic grade, then the dither.
    float3 c = 1.0 - exp(-max(col, 0.0));
    c = min(1.13 * sqrt(c) - 0.13 * c, 12.92 * c);           // ≈ linear → sRGB (within ~3/255)
    float lc = luma(c);
    // Highlights bloom and halate: bright areas lift toward a warm white (a soft-focus glow).
    float hi = smoothstep(0.5, 1.0, lc);
    c += (1.0 - c) * hi * glow * float3(0.34, 0.27, 0.18);
    // Film colour: rich, warm in the light, deep in the shadows, a firm toe.
    lc = luma(c);
    c = max(lc + (c - lc) * 1.14, 0.0);
    c *= mix(float3(1.0), float3(1.035, 1.0, 0.94), smoothstep(0.35, 0.9, lc));
    c = mix(c, c * c * (3.0 - 2.0 * c), 0.25);
    c += (1.0 - lc) * (1.0 - lc) * 0.008 * float3(0.80, 0.88, 1.0);
    float2 vq = (uv - 0.5) * float2(aspect / 1.6, 1.0);
    c *= 1.0 - (0.10 + 0.12 * glow) * dot(vq, vq) * 1.6;
    // Fine dither: an 8×8 Bayer threshold blended with a fixed fine grain (ordered but not
    // mechanical — a film-like texture), on cells ~1 px per 1400 px of height, quantising to fewer
    // levels as Dither rises. At 0, just enough to break 8-bit banding.
    float cell = max(1.0, floor(res.y / 1400.0 + 0.5));
    int2 ic = int2(px / cell);
    float th = bayer8[(ic.y & 7) * 8 + (ic.x & 7)];
    th = mix(th, meadow_rand3(uint(ic.x) * 0x9E3779B1u ^ uint(ic.y) * 0x85EBCA77u).x - 0.5, 0.4);
    // Grain: fine, a little in every tone, renewed 12 times a second.
    float grn = meadow_rand3(uint(ic.x) * 0x27d4eb2du ^ uint(ic.y) * 0x165667b1u ^ uint(floor(t * 12.0)) * 0x9E3779B1u).y - 0.5;
    c += grn * 0.05 * dith * (0.5 + 0.5 * (1.0 - lc));
    float lv = exp2(mix(6.5, 2.6, dith)) - 1.0;
    float3 q = floor(c * lv + 0.5 + th) / lv;
    c = dith > 0.001 ? mix(c + th / 255.0, q, smoothstep(0.0, 0.08, dith)) : c + bandDither(px) * 1.5;
    return float4(saturate(c), 1.0);
}
