//  Meadow_funcs.h — the Meadow pack (shader id 78, Meadow.swift): summer fields in the wind.
//  File-scope Metal helpers, every symbol "meadow_". Included by Shaders.metal after
//  Nature_funcs.h, whose sky it reuses (Tidewater's: single-scattering atmosphere, twilight, the
//  live sun and moon, stars, the weather's deck) with Shared/Weather/Weather_funcs.h (rain, snow,
//  fog, lightning). Linear light throughout, shown through nature_display's filmic shoulder, then
//  a soft grade and a fine ordered dither.
//
//  The view: a camera a metre up in a meadow, looking a little up across it. Front to back:
//   • grass blades and wildflowers on vertical depth layers (0.45 … 20 m), bending in the wind —
//     the gusts are a noise field carried downwind, so a gust is a patch of stronger bend that
//     travels across the field, and each blade flutters on its own. A ray only meets the three
//     or four layers where it is inside the grass (solved for, not searched). Blades thinner than a pixel
//     are drawn energy-kept (box-filtered) and the near ones are out of focus (the lens is focused
//     far off), so nothing shimmers and the foreground is soft;
//   • the meadow itself (a ground plane) under them: rolling swells, tufts, light running over it
//     where the gusts lay the grass over (its paler undersides catch the light), cloud shadows
//     drifting across, the wildflowers' tint;
//   • up to three hill layers drawn as silhouettes against the sky (a near rise — in Lone Tree
//     the hill with the tree — a patchwork of hedged fields, a far ridge), each lit by its slope,
//     with the same gusts and cloud shadows, fading into the air with distance;
//   • the sky: Tidewater's atmosphere, sun, moon and stars (Nature_funcs.h) under cumulus banks
//     heaped along the horizon.
//  Then the weather (deck, rain, snow, fog, lightning), fireflies on clear summer nights, a soft
//  veil of glow around the light, the live camera's exposure, the display shoulder, the grade and
//  the dither.
//
//  Cost (tools/gallery --gpubench, M5 Pro, 5120×2880): Meadow ~4.3 ms, Lone Tree ~4.7, Tall Grass
//  ~6.0 (Tidewater: 4.7); at the wallpaper's Balanced scale (1920×1080 on a 5K display) 0.6–1.0.
//  Per pixel it is plain arithmetic, a few gradient noises on a cheap hash, sines for the
//  silhouettes, and the sky restated for a pixel's cost (meadow_atmos). Compiled twice — clear and
//  weather — as fragment functions of their own (Weather_fragment.h), so the clear sky never pays
//  for the weather's registers. (Watch the registers: one more full sky evaluation held through the
//  grass once cost 6× the frame time.)

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
// Landscape: 0 Meadow (an open meadow, a gentle rise on the left), 1 Lone Tree (a grassy hill
// rising on the right with one broad tree on its shoulder), 2 Tall Grass (low in long grass).
struct MeadowLayout {
    int land;
    float camH;      // eye height above the ground, m
    float pitch;     // camera tilt up, radians
    float bladeH;    // tallest grass, m
    float space;     // blade spacing in the nearest layer, m
    float bladeW;    // blade half-width at its foot, m
    float aperture;  // defocus of the near grass: the blur circle, m (focused far off)
    float d1;        // the near rise's distance, m (0: none)
    float aspect;
};
static inline MeadowLayout meadow_layout(int land, float aspect) {
    MeadowLayout L;
    L.land = land;
    L.aspect = aspect;
    if (land == 1) {
        L.camH = 1.15; L.pitch = 0.13; L.bladeH = 0.50; L.space = 0.020; L.bladeW = 0.0050;
        L.aperture = 0.0025; L.d1 = 95.0;
    } else if (land == 2) {
        L.camH = 0.80; L.pitch = 0.12; L.bladeH = 1.05; L.space = 0.024; L.bladeW = 0.0050;
        L.aperture = 0.0040; L.d1 = 0.0;
    } else {
        L.camH = 1.20; L.pitch = 0.14; L.bladeH = 0.52; L.space = 0.020; L.bladeW = 0.0050;
        L.aperture = 0.0025; L.d1 = 320.0;
    }
    return L;
}
// Silhouette heights above the horizon line (screen units, the frame is 2 tall) at screen x X,
// with their slopes d/dX.
static inline float2 meadow_farTop(MeadowLayout L, float X) {
    float2 r = meadow_ridge(X * 0.8, 11.3);
    float k = L.land == 2 ? 0.5 : 1.0;
    float sr = sqrt(max(r.x, 0.0));
    return k * float2(0.05 + 0.17 * r.x * sr, 0.17 * 1.5 * sr * r.y * 0.8);
}
static inline float2 meadow_midTop(MeadowLayout L, float X) {
    float2 r = meadow_ridge(X * 1.5, 4.7);
    float a = L.land == 2 ? 0.03 : 0.065;
    return float2((L.land == 2 ? 0.004 : 0.010) + a * r.x, a * r.y * 1.5);
}
static inline float2 meadow_nearTop(MeadowLayout L, float X) {
    if (L.land == 1) {
        float w = 0.80 + 0.25 * L.aspect;
        float q = (X - 0.34 * L.aspect) / w;
        float e = 0.34 * exp(-q * q);
        float2 r = meadow_ridge(X * 3.0, 2.2);
        return float2(e - 0.035 + 0.012 * r.x, -2.0 * q / w * e + 0.036 * r.y);
    }
    if (L.land == 0) {
        float q = (X + 0.62 * L.aspect) / 0.95;
        float e = 0.11 * exp(-q * q);
        float2 r = meadow_ridge(X * 1.7, 8.1);
        return float2(e - 0.02 + 0.025 * r.x, -2.0 * q / 0.95 * e + 0.0425 * r.y);
    }
    return float2(-1.0, 0.0);
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
    float2 p = w * 0.0045 + sd.xz * (5.0 / max(sd.y, 0.06)) - MEADOW_WD * (tc * 8.0) + float2(3.7, 1.9);
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
    float3 pale = mix(alb, float3(luma(alb)) * float3(1.15, 1.12, 0.85), 0.55) * 1.9;
    col += (pale - alb) * bend * (sun * (0.22 + 0.10 * lam) + L.amb * 0.5);
    return col;
}

// ---------------------------------------------------------------- grass blades + flowers
//
// Vertical layers of blades in front of the camera, z = 0.45 · 1.2^j m (to ~20 m; tall grass ~3 m). A ray
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
    int j1 = min(Lo.land == 2 ? 5 : 21, int(floor(log(max(zB, 1e-3) / z0) / lrz)) + 1);
    if (rd.y > 0.0) j1 = min(j1, j0 + 3);                      // (above the horizon: the near stalks)
    if (j1 < j0) return float4(0.0);

    float3 acc = float3(0.0);
    float keep = 1.0;
    float hgB = nature_hg(L.c, 0.45);
    float3 sunB = L.sunE * (0.10 + 0.22 * saturate(L.sd.y + 0.25)) + L.amb * 0.62;   // a blade's diffuse light
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
        float by = 0.0, bsd = 0.0, bdh = 0.0, brh = 1.0;
        int kind = 0;                                          // 0 blade, 1 flower stem, 2 flower head
        for (int k = 0; k <= 1; ++k) {
            float id = i0 + float(k);
            float3 h = meadow_rand3((uint(int(id) + 0x40000) * 0x9E3779B1u) ^ salt);
            float hb = hs * (0.5 + 0.5 * h.y);
            float y01 = Y / hb;
            bool fl = h.z < flowers * 0.045;
            if (y01 > (fl ? 1.3 : 1.0)) continue;
            float dev = dmax * ((h.x - 0.5) * 1.1 + 0.45 * flut * nature_sinT(ts * (0.33 + 0.3 * h.x) + h.y * 6.4));
            float x0 = (id + 0.3 + 0.4 * h.x) * s;
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
                if (cov > best) { best = cov; bh = h; by = y01; bsd = sd01; kind = 0; }
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
                float cov = max(stem, head);
                if (cov > best) { best = cov; bh = h; by = y01; bdh = dh; brh = rh; kind = head >= stem ? 2 : 1; }
            }
        }
        if (best <= 0.0) continue;
        float3 a = alb * mix(float3(0.78, 0.92, 0.66), float3(1.30, 1.15, 0.74), bh.x);
        float3 cc;
        if (kind == 0) {
            // A blade: a touch of its own hue, paler and warmer toward the tip, dark at the foot
            // (the sward shades it), the sun through it, the gust's sheen; a seed head's own tan.
            a = mix(a, a * float3(1.55, 1.32, 0.62), by * by * 0.6);
            float ao = 0.24 + 0.76 * by;
            cc = a * ((sunB * (0.6 + 0.5 * bh.y) + transB * (0.15 + 0.85 * by)) * ao + L.amb * (g * 0.6 * by));
            if (bsd > 0.0) cc = mix(cc, float3(0.55, 0.47, 0.32) * (sunB * 0.9 + transB * float3(1.3, 1.1, 2.2)), smoothstep(0.0, 0.3, bsd));
        } else if (kind == 1) {
            cc = a * 0.8 * (sunB * (0.2 + 0.8 * min(by, 1.0)) + transB * 0.5);
        } else {
            float sel = fract(bh.x * 7.31 + bh.y * 3.7);
            float3 fc = sel < 0.40 ? float3(0.92, 0.90, 0.84)                       // daisy
                      : (sel < 0.68 ? float3(0.95, 0.70, 0.06)                      // buttercup
                      : (sel < 0.87 ? float3(0.82, 0.36, 0.62) : float3(0.32, 0.44, 0.94)));  // clover, cornflower
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

// ---------------------------------------------------------------- cumulus banks
//
// Summer cumulus heaped along the horizon, painted in (azimuth, sine of elevation): three rows at
// increasing distance — lower bases, smaller, hazier — each a run of heaps standing on a flat
// base where an envelope along the row says (how tall: its excess over a threshold that the
// Clouds slider and the weather's cover set), with billowed, cauliflower tops. Lit from the
// sun's side (a "puff" normal from the billows' gradient), bright on top, blue-grey underneath,
// silver-lined toward the sun, fading into the air. Rows drift with the wind, the near ones
// fastest. Returns (premultiplied colour, cover).
constant float4 MEADOW_ROWS[3] = {     // (base, size, drift rate, haze)
    float4(0.215, 0.120, 1.00, 0.03), float4(0.125, 0.078, 0.62, 0.10),
    float4(0.062, 0.046, 0.38, 0.25)
};
static inline float4 meadow_cumulus(float3 v, float3 sky, NatureOceanP P, float amount, float thrR,
                                    float pix, constant FXUniforms& u) {
    float e = v.y;
    float a = atan2(v.x, v.z);
    float3 sunC = P.esun * nature_sunAt(P, 1.8, u);
    float3 ambC = sky * 0.62 + P.amb * float3(0.0040, 0.0050, 0.0085);
    float fs = nature_hg(dot(v, P.sd), 0.6);
    float3 rgt = normalize(float3(v.z, 0.0, -v.x));
    float keep = 1.0;
    float3 acc = float3(0.0);
    float tcd = P.tc * 1.6;
    for (int k = 0; k < 3; ++k) {
        float4 R = MEADOW_ROWS[k];
        float b = R.x, S = R.y;
        if (e < b - 0.12 * S || e > b + 2.2 * S) continue;
        float x = a + tcd * R.z + 7.3 * float(k);
        float xr = x / (S * 2.4);
        float env = meadow_ridgeV(xr, 13.1 + 5.7 * float(k)) + 0.07 * sin(xr * 8.7 + 1.3 * float(k));
        float ht = saturate((env - thrR) / max(1.0 - thrR, 0.05));
        ht = 1.7 * ht * (1.6 - 0.6 * ht);                        // heap top above the base, in S (domed)
        float z = (e - b) / S;
        float bA = 0.30 * smoothstep(0.0, 0.35, ht);             // (small heaps: small billows)
        if (ht - z + bA < 0.0 || bA <= 0.0) continue;
        float2 q = float2(x * 1.15, e) / S * 2.6 + float2(3.1 * float(k), 1.7);
        float3 bn = meadow_gnoised(q);
        float fpq = pix / S * 2.6;                              // a pixel, in q
        float fine = k == 0 ? smoothstep(0.5, 0.15, fpq * 2.3) : 0.0;
        // Billows: rounded bumps with creases (cauliflower tops), stronger up the heap.
        float bill = 0.75 * bn.x + (fine > 0.0 ? 0.30 * fine * (0.25 - abs(meadow_gnoise(q * 2.3 + 5.1))) : 0.0);
        float D = ht - z + bA * (1.0 + 0.8 * saturate(z / max(ht, 0.1))) * bill;   // > 0 inside the heap
        float baseC = smoothstep(-0.04, 0.10, z + 0.05 * bill);  // the flat base
        float soft = 0.09 + fpq * 1.2;
        float ac = smoothstep(0.0, soft * 2.0, D) * baseC * amount;
        if (ac <= 0.0) continue;
        float hf = saturate(z / max(ht, 0.1));                  // 0 base … 1 top
        float2 no = normalize(float2(-0.42 * bn.y, 1.0 - 0.42 * bn.z) + float2(0.0, 0.2));
        float3 n = normalize(rgt * no.x + float3(0.0, no.y, 0.0) - v * (0.75 - 0.35 * hf));
        float lam = saturate(0.1 + 0.9 * dot(n, P.sd));
        float thin = saturate(1.0 - D / 0.4);
        float3 cc = sunC * (0.035 + 0.30 * lam) * (0.50 + 0.50 * hf) + ambC * (0.62 + 0.38 * hf);
        cc *= mix(0.62, 1.0, smoothstep(0.0, 0.45, hf));        // grey-blue undersides
        cc += sunC * fs * thin * (0.35 + 0.4 * (1.0 - hf));    // silver lining toward the sun
        cc = mix(cc, sky, R.w);
        acc += keep * ac * cc;
        keep *= 1.0 - ac;
        if (keep < 0.01) break;
    }
    return float4(acc, 1.0 - keep);                            // (premultiplied)
}

// ---------------------------------------------------------------- the lone tree (Lone Tree)
//
// A broad summer tree (an oak or a camphor): a rounded crown of overlapping masses with a leafy,
// broken edge, on a short trunk, swaying a little in the gusts. Drawn in its own frame q (its
// height = 1, its foot at the origin; x right, y up).
constant float3 MEADOW_CROWN[8] = {      // (centre, radius) of the crown's masses
    float3(0.00, 0.60, 0.31), float3(-0.32, 0.50, 0.23), float3(0.34, 0.52, 0.23),
    float3(-0.15, 0.79, 0.22), float3(0.18, 0.80, 0.22), float3(-0.52, 0.42, 0.14),
    float3(0.55, 0.44, 0.14), float3(0.02, 0.93, 0.15)
};
static inline float meadow_crownD(float2 q) {
    float d = 1e3;
    for (int i = 0; i < 8; ++i) {
        float di = length(q - MEADOW_CROWN[i].xy) - MEADOW_CROWN[i].z;
        float hk = saturate(0.5 + 0.5 * (d - di) / 0.09);       // smooth union
        d = mix(d, di, hk) - 0.09 * hk * (1.0 - hk);
    }
    return d;
}
// Tree colour (premultiplied) and coverage at screen point sp (foot at f, height ht screen units).
static inline float4 meadow_tree(float2 sp, float2 f, float ht, float pixS, float ts, float sway,
                                 float3 alb, MeadowLight L) {
    float2 q = (sp - f) / ht;
    if (q.y < -0.02 || q.y > 1.14 || abs(q.x) > 0.74) return float4(0.0);
    float pq = pixS / ht;                                       // a pixel, in q
    q.x -= sway * smoothstep(0.15, 1.0, q.y);
    // Trunk and two limbs (mostly hidden in the crown).
    float tx = 0.015 * sin(q.y * 4.0);
    float tw = mix(0.048, 0.026, saturate(q.y / 0.5));
    float dt = max(abs(q.x - tx) - tw, q.y - 0.62);
    float2 b1 = q - float2(0.0, 0.30), e1 = float2(-0.26, 0.20);
    float t1 = saturate(dot(b1, e1) / dot(e1, e1));
    dt = min(dt, length(b1 - e1 * t1) - mix(0.022, 0.009, t1));
    float2 e2 = float2(0.27, 0.22);
    float t2 = saturate(dot(b1, e2) / dot(e2, e2));
    dt = min(dt, length(b1 - e2 * t2) - mix(0.020, 0.009, t2));
    // Crown: smooth masses with a leafy edge (two octaves of noise).
    float dc0 = meadow_crownD(q);
    float leaf = meadow_gnoise(q * 13.0 + float2(ts * 0.15, 0.0)) * 0.045 + meadow_gnoise(q * 31.0 + 7.0) * 0.020;
    float dc = dc0 + leaf;
    float covC = saturate(0.5 - dc / pq);
    float covT = saturate(0.5 - dt / pq);
    float cov = max(covC, covT);
    if (cov <= 0.0) return float4(0.0);
    // Puff normal: from the crown's distance field (its slope sideways, its depth inside), with
    // the leaf clumps' own bumps.
    float e = 0.02;
    float2 gr = float2(meadow_crownD(q + float2(e, 0)) - meadow_crownD(q - float2(e, 0)),
                       meadow_crownD(q + float2(0, e)) - meadow_crownD(q - float2(0, e))) / (2.0 * e);
    float3 cl = meadow_gnoised(q * 7.0 + 3.0);
    float depth = saturate(-dc0 / 0.22);
    float3 n = normalize(float3(gr * (1.0 - 0.6 * depth) + cl.yz * 0.10, 0.35 + depth));
    float3 sdv = float3(L.sd.x, L.sd.y, -L.sd.z);               // the key light in this frame
    float lam = saturate(0.12 + 0.88 * dot(n, sdv));
    float occ = 0.68 + 0.32 * saturate(0.5 + cl.x * 1.2);      // pockets between the clumps
    float3 la = alb * float3(0.60, 0.78, 0.52);
    float3 leafC = la * (L.sunE * lam * 0.42 * occ + L.amb * (0.30 + 0.40 * saturate(n.y + 0.4)) * occ);
    // Sun through the crown's thin rim (backlit), stronger toward its edge.
    leafC += la * float3(1.2, 1.3, 0.5) * L.sunE * nature_hg(L.c, 0.5) * (0.20 + 1.6 * (1.0 - depth) * (1.0 - depth));
    float3 barkC = float3(0.085, 0.072, 0.06) * (L.sunE * 0.14 * saturate(sdv.x * sign(q.x - tx) + 0.4) + L.amb * 0.45);
    float3 col = covC >= covT ? leafC : barkC;
    return float4(col * cov, cov);
}

// ---------------------------------------------------------------- the scene
// wx: the weather copy (u.weather*: Shared/Weather/Weather_funcs.h) — compiled apart from the
// clear one (Weather_fragment.h: fx_meadow, fx_wx_meadow).
static inline float4 meadow_scene(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u,
                                  const bool wx) {
    const float F = MEADOW_F;
    float speed = u.p0.x, windP = clamp(u.p0.y, 0.0, 1.0), flowers = clamp(u.p0.z, 0.0, 1.0);
    float cloudP = clamp(u.p0.w, 0.0, 1.0);
    int land = clamp(int(u.p2.x + 0.5), 0, 2);
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
    float3 Tsun = exp(-P.tauT * nature_airmass(P.se));

    // Clouds: the Clouds slider, then the weather's cover (Clear = the scene's own sky).
    float thrS = mix(0.45, 0.05, cloudP);                       // (the cloud shadows)
    float thrR = mix(0.72, 0.36, cloudP);                       // (the banks' heaps)
    float cuAmt = smoothstep(0.0, 0.12, cloudP);
    // ---- weather (all uniform): Tidewater's deck, fog and lightning, in the same terms.
    float sunVis = 1.0, fogB = 0.0, fogH = 1.0, sunT = 1.0, flashE = 0.0;
    float3 fogA = float3(0.0), ambL = float3(0.0);
    float4 ev = float4(0.0);
    if (wx) {
        float cv = W.cover;
        thrS = cv < 0.25 ? mix(0.6, thrS, cv * 4.0) : mix(thrS, -0.3, smoothstep(0.25, 0.85, cv));
        thrR = cv < 0.25 ? mix(0.80, thrR, cv * 4.0) : mix(thrR, 0.12, smoothstep(0.25, 0.85, cv));
        cuAmt = cv < 0.25 ? cuAmt * mix(0.4, 1.0, cv * 4.0) : max(cuAmt, smoothstep(0.25, 0.45, cv));
        cuAmt *= 1.0 - smoothstep(0.35, 0.65, W.fog);
        P.deck = W.deck;
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
    L.beta = 0.00003 + 0.00011 * haze;
    L.shK = 0.75 * cuAmt * (1.0 - P.deck);
    float3 alb = srgbToLinear(u.colorA.rgb) * 0.45;            // the grass's albedo
    if (wx) alb = mix(alb, float3(luma(alb)) * float3(1.1, 1.15, 1.25) * 3.5, 0.35 * W.snow);
    float gwind = saturate(wind * 1.6);

    // Pixel → which surface, front to back: the grass in front, the meadow, the near rise (and
    // the lone tree on it), the meadow beyond, the fields, the far ridge, the sky. Silhouettes
    // are antialiased by coverage, and what lies behind an edge is only worked out there.
    float X = sp.x, y = sp.y;
    float3 acc = float3(0.0);
    float keep = 1.0;
    float dist = 1e5;                                           // distance of what's seen (fog)
    {
        float4 bl = meadow_blades(rd, Lo, pix, ts, tw, wind, flowers, alb, L);
        acc = bl.rgb;
        keep = 1.0 - bl.a;
        if (bl.a > 0.5) dist = 3.0;
    }
    float d1 = Lo.d1;
    const float d2 = 2200.0, d3 = 9000.0;
    float yb1 = d1 > 0.0 ? yh - F * Lo.camH / d1 : -10.0;      // the rise's foot (the meadow at d1)
    float yb2 = yh - F * Lo.camH / d2;
    // The meadow: all of it in front of the rise (nothing else can show there), and beyond it
    // wherever no hill stands.
    float2 nT = float2(-1.0, 0.0);
    float yN = -10.0;
    bool low = rd.y < -1e-4 && y < (d1 > 0.0 ? yb1 : yb2) - pixS;
    // Above every hill (and the tree) there is only sky: those pixels skip the land altogether.
    float yTop = yh + 0.21 + 2.0 * pixS;
    if (land == 1) yTop = max(yTop, yh + 0.36 + F * 19.0 / d1 * 1.15);
    else if (land == 0) yTop = max(yTop, yh + 0.14);
    bool sky = y > yTop;

    if (!low && !sky && d1 > 0.0 && keep > 0.002) { nT = meadow_nearTop(Lo, X); yN = yh + nT.x; }
    if (keep > 0.002 && rd.y < -1e-4 && (low || y > yN + pixS)) {
        float d = Lo.camH / -rd.y;
        float2 w = rd.xz * d;
        float bend = meadow_gust(w, tw);
        bend = bend * bend * gwind;
        // Rolling swells (shading only: two sines and their slopes), colour drifts.
        float2 sw1 = float2(w.x * 0.031 + w.y * 0.012, w.y * 0.027 - w.x * 0.009);
        float c1, c2, s1 = sincos(sw1.x + 1.3 * sin(sw1.y), c1), s2 = sincos(sw1.y * 1.7 + 0.6, c2);
        float3 gn = float3(0.25 * (s1 + s2), 0.25 * c1 * 0.031 * 18.0, 0.25 * c2 * 0.046 * 18.0);
        // Tufts a few metres across: a bump map a low sun rakes across, and their own shade —
        // faded to their mean where a pixel spans them.
        float fpx = d * pix;
        float tk = smoothstep(0.9, 0.25, fpx * 0.45);
        float3 tn = tk > 0.0 ? meadow_gnoised(w * float2(0.45, 0.32) + 11.0) * tk : float3(0.0);
        float3 n = normalize(float3(-gn.y * 0.55 - tn.y * 0.55, 1.0, -gn.z * 0.55 - tn.z * 0.4));
        float patch = gn.x * 1.4 + 0.25 * sin(w.x * 0.05 + w.y * 0.11) + tn.x * 0.5;
        float3 a = alb * mix(float3(0.74, 0.93, 0.60), float3(1.34, 1.17, 0.70), saturate(0.5 + patch));
        float sh = cuAmt > 0.0 ? meadow_cloudShadow(w, P.sd, P.tc, thrS) : 0.0;
        float3 g = meadow_sward(a, n, bend, sh, L);
        // The sward under the near blades sits deep in their shade.
        g *= mix(0.30, 1.0, smoothstep(1.2, 8.0, d));
        // Wildflowers too small to resolve: their tint, in drifts.
        float fa = flowers * 0.10 * smoothstep(4.0, 12.0, d) * saturate(0.4 + 1.5 * gn.x);
        g = mix(g, float3(0.90, 0.80, 0.55) * (L.sunE * 0.30 + L.amb * 0.9), fa);
        g = mix(g, L.hz, 1.0 - exp(-d * L.beta));
        acc += keep * g;
        keep = 0.0;
        dist = min(dist, d);
    }
    if (keep > 0.002 && !sky) {
        // The lone tree, then the rise it stands on (with the tree's shadow).
        float tht = F * 19.0 / max(d1, 1.0);
        float2 tf = float2(0.20 * aspect, 0.0);
        if (land == 1) {
            tf.y = yh + meadow_nearTop(Lo, tf.x).x - 0.006;
            float sway = 0.010 * wind * (0.5 + meadow_gust(float2(tf.x / F * d1, d1), tw)) + 0.004 * sin(ts * 0.8);
            float4 tr = meadow_tree(sp, tf, tht, pixS, ts, sway, alb, L);
            if (tr.a > 0.0) {
                float3 c = mix(tr.rgb / tr.a, L.hz, 1.0 - exp(-d1 * L.beta));
                acc += keep * tr.a * c;
                keep *= 1.0 - tr.a;
                dist = min(dist, d1);
            }
        }
        if (keep > 0.002 && d1 > 0.0 && y >= yb1 - pixS && y < yN + pixS) {
            float cov = saturate((yN - y) / pixS + 0.5);
            float s = saturate((yN - y) / max(yN - yb1, 1e-4));    // 0 at the crest … 1 at the foot
            float dl = d1 * (1.15 - 0.3 * s);
            float2 w = float2(X / F * dl, dl + s * 0.9 * d1);
            float3 tn = meadow_gnoised(w * float2(0.06, 0.035) + 2.0);
            float3 n = normalize(float3(-nT.y * 1.6 - tn.y * 0.5, 1.0, -0.75 * sin(3.14159 * s) - 0.1 - tn.z * 0.3));
            float bend = meadow_gust(w, tw);
            bend = bend * bend * gwind;
            float patch = tn.x * 1.2;
            float3 a = alb * mix(float3(0.80, 0.97, 0.64), float3(1.28, 1.14, 0.74), saturate(0.5 + patch));
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(w, P.sd, P.tc, thrS) : 0.0;
            float3 g = meadow_sward(a, n, bend, sh, L);
            if (land == 1) {
                float2 o = (sp - tf) / tht;
                float2 dir = normalize(float2(-P.sd.x, -0.10 * P.sd.z - 0.02));
                float len = clamp(0.5 / max(tan(max(P.se, 0.02)), 0.4), 0.3, 1.6);
                float2 o2 = float2(o.x, o.y * 4.0);           // (the ground is seen edge-on)
                float2 e2 = float2(dir.x, dir.y * 4.0) * len;
                float ts2 = saturate(dot(o2, e2) / dot(e2, e2));
                float rr = mix(0.30, 0.18, ts2);
                float tsh = smoothstep(rr * 1.3, rr * 0.5, length(o2 - e2 * ts2 - float2(0.0, 0.02))) * sunUp;
                g = mix(g, a * L.amb * (0.55 + 0.45 * n.y) * 0.9, tsh * 0.8);
            }
            g = mix(g, float3(0.90, 0.82, 0.58) * (L.sunE * 0.30 + L.amb * 0.9), flowers * 0.07);
            g = mix(g, L.hz, 1.0 - exp(-dl * L.beta));
            acc += keep * cov * g;
            keep *= 1.0 - cov;
            dist = min(dist, dl);
        }
        // The meadow beyond the rise, out to the fields (the rise's antialiased edge).
        if (keep > 0.002 && rd.y < -1e-4 && y < yb2) {
            float d = Lo.camH / -rd.y;
            float2 w = rd.xz * d;
            float3 a = alb * mix(float3(0.85, 0.97, 0.66), float3(1.2, 1.1, 0.75), saturate(0.5 + meadow_gnoise(w * 0.01)));
            float3 g = meadow_sward(a, float3(0, 1, 0), 0.3 * gwind * meadow_gust(w, tw), 0.0, L);
            g = mix(g, L.hz, 1.0 - exp(-d * L.beta));
            acc += keep * g;
            keep = 0.0;
            dist = min(dist, d);
        }
        float2 mT = float2(0.0), fT = float2(0.0);
        if (keep > 0.002) { mT = meadow_midTop(Lo, X); fT = meadow_farTop(Lo, X); }
        float yM = yh + mT.x, yF = yh + fT.x;
        // The fields: a patchwork of meadows, hay and crops between hedgerows.
        if (keep > 0.002 && y < yM + 2.0 * pixS) {
            float cov = saturate((yM - y) / pixS + 0.5);
            float s = saturate((yM - y) / max(yM - yb2, 1e-4));
            float dl = d2 * (1.1 - 0.25 * s);
            float2 w = float2(X / F * dl, s * 1400.0);
            float2 wr = float2(w.x * 0.95 + w.y * 0.31, w.y * 0.95 - w.x * 0.31);
            float2 cs = float2(150.0, 95.0);
            float2 cid = floor(wr / cs), cf = wr / cs - cid;
            float3 hc = meadow_rand3(uint(int(cid.x) + 0x4000) * 0x9E3779B1u ^ uint(int(cid.y) + 0x4000) * 0x85EBCA77u);
            float3 a = alb * (hc.x < 0.55 ? mix(float3(0.85, 1.0, 0.70), float3(1.15, 1.08, 0.70), hc.y)
                                          : (hc.x < 0.8 ? float3(1.55, 1.25, 0.55) : float3(1.05, 0.92, 0.55)));
            // Hedges: dark lines on the field edges (filtered by the pixel's footprint there).
            float fx = dl * pix * 1.2;
            float2 ed = min(cf, 1.0 - cf) * cs;
            float hw = 2.5;
            float hedge = max(smoothstep(hw + fx, hw - fx, ed.x), smoothstep(hw + fx * 3.0, hw - fx * 3.0, ed.y));
            hedge *= 0.75 * smoothstep(60.0, 8.0, fx);
            a = mix(a, alb * float3(0.45, 0.62, 0.40), hedge);
            float3 n = normalize(float3(-mT.y * 1.6, 1.0, -0.6 * sin(3.14159 * s) - 0.1));
            float sh = cuAmt > 0.0 ? meadow_cloudShadow(w + float2(0.0, d2), P.sd, P.tc, thrS) : 0.0;
            float3 g = meadow_sward(a, n, 0.12 * gwind, sh, L);
            g = mix(g, L.hz, 1.0 - exp(-dl * L.beta));
            acc += keep * cov * g;
            keep *= 1.0 - cov;
            dist = min(dist, dl);
        }
        // Hedgerow trees along the fields' crest: round crowns standing on the skyline.
        if (keep > 0.002 && land != 2 && y < yM + 0.03 && y > yM - 0.01) {
            float cw = 0.022;
            float ci = floor(X / cw);
            float tc = 0.0;
            for (int k = -1; k <= 1; ++k) {
                float3 h = meadow_rand3(uint(int(ci) + k + 0x40000) * 0x9E3779B1u + 77u);
                if (h.x > 0.45) continue;
                float cx = (ci + float(k) + 0.5 + 0.3 * (h.y - 0.5)) * cw;
                float r = 0.0045 + 0.006 * h.z;
                float base = yM + mT.y * (cx - X);
                float2 dv = float2(X - cx, (y - base - r * 0.9) * 0.9);
                tc = max(tc, saturate((r - length(dv)) / pixS + 0.5));
            }
            if (tc > 0.0) {
                float3 g = alb * float3(0.45, 0.62, 0.40) * (L.sunE * 0.12 + L.amb * 0.6);
                g = mix(g, L.hz, 1.0 - exp(-d2 * L.beta));
                acc += keep * tc * g;
                keep *= 1.0 - tc;
                dist = min(dist, d2);
            }
        }
        // The far ridge, blue with distance.
        if (keep > 0.002 && y < yF + 2.0 * pixS) {
            float cov = saturate((yF - y) / pixS + 0.5);
            float s = saturate((yF - y) / max(yF - yh, 1e-4));
            float3 n = normalize(float3(-fT.y * 2.5, 1.0, -0.9 * sin(3.14159 * s) - 0.1));
            float wood = smoothstep(0.1, 0.6, nature_sinT(X * 1.9 + 0.3 * nature_sinT(X * 0.7)) * 0.5 + 0.5 - 0.5 * s);
            float3 a = alb * mix(float3(0.78, 0.92, 0.78), float3(0.45, 0.62, 0.50), wood);
            float3 g = meadow_sward(a, n, 0.0, 0.0, L);
            float3 far = L.hz * float3(0.82, 0.92, 1.10);                    // (distance is blue)
            g = mix(g, far, 0.25 + 0.75 * (1.0 - exp(-d3 * L.beta * 1.4)));
            acc += keep * cov * g;
            keep *= 1.0 - cov;
            dist = min(dist, d3);
        }
    }
    // ---- the sky
    float3 stars = float3(0.0);
    if (keep > 0.002) {
        float3 v = rd;
        v.y = max(v.y, 0.002);
        v = normalize(v);
        float3 sky = meadow_atmos(v, P, u, meadow_lTs(P, u), wx);
        // A summer sky, as remembered: bluer and clearer overhead (by day).
        float dayK = nature_liveDay(u) * (wx ? 1.0 - P.deck : 1.0);
        sky *= mix(float3(1.0), float3(0.72, 1.0, 1.04), dayK * smoothstep(0.0, 0.5, v.y));
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
            sky += nature_oceanMoonNear(v, u, P.tauT, pix) * (wx ? (keyMoon ? sunVis * sunT : 1.0 - P.deck) : 1.0);
        float cov = 0.0;
        float3 col = sky;
        if (cuAmt > 0.0 && (!wx || P.deck < 0.995) && v.y > 0.004) {
            float4 cum = meadow_cumulus(v, sky, P, cuAmt * (wx ? 1.0 - P.deck : 1.0), thrR, pix, u);
            col = col * (1.0 - cum.w) + cum.rgb;
            cov = cum.w;
        }
        if (wx) {
            if (P.deck > 0.0) {
                // Under the deck: its rolls and lumps, darker in the cores.
                float tB = P.hb / v.y;
                float2 pb = v.xz * tB * 0.55 + float2(P.tc * 2.0, P.tc * 0.6);
                float nb = meadow_gnoise(pb) + 0.5 * meadow_gnoise(pb * 2.3 + 4.0);
                float under = P.deck * smoothstep(P.dx * 1.3, P.dx * 0.8, tB) * smoothstep(0.004, 0.05, v.y);
                col *= 1.0 + under * (0.22 + 0.3 * P.cdark) * nb * (1.0 - 0.6 * saturate(tB / 12.0));
                cov = max(cov, under);
            }
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
            stars = nature_oceanStars(v, u, pix, t) * ((1.0 - cov) * smoothstep(0.9, 0.6, cov) * keep);
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
            float lum = (exp(-r * r / (sz * sz)) + 0.10 * exp(-r / (sz * 5.0))) * pulse * ffK;
            col += float3(0.55, 0.85, 0.25) * lum * 0.08;
        }
    }
    // ---- glow: the light's soft veil over the whole frame (a dreamy lens), strongest toward it,
    // and a breath of the air's own colour over everything.
    {
        float3 E = P.esun * Tsun * (sunUp * sunVis * sunT);
        col += E * glow * (0.0012 * nature_hg(L.c, 0.96) + 0.006 * nature_hg(L.c, 0.80) + 0.0012);
        col = mix(col, L.hz * 1.1, glow * 0.06);
    }
    // White balance toward the low sun (gold, not red), as Tidewater.
    float wbAmt = 0.12 * smoothstep(-0.07, -0.02, u.sun.x);
    if (wbAmt > 0.0) {
        float3 TsunS = exp(-P.tauT * nature_airmass(u.sun.x));
        float3 wb = TsunS / max(max(TsunS.r, TsunS.g), 1e-4);
        col /= mix(float3(1.0), max(wb, 0.05), wbAmt);
    }
    col = col * nature_oceanExpo(u) * 1.35 + stars;
    // ---- display: the filmic shoulder, a soft dreamy grade, then the dither.
    float3 c = 1.0 - exp(-max(col, 0.0));
    c = min(1.13 * sqrt(c) - 0.13 * c, 12.92 * c);           // ≈ linear → sRGB (within ~3/255)
    // Summer colour: by day a little more vivid, warm in the light.
    float vib = 0.20 * smoothstep(0.02, 0.25, u.sun.x) * (wx ? 1.0 - 0.7 * P.deck : 1.0);
    float lc = luma(c);
    c = max(lc + (c - lc) * (1.0 + vib), 0.0);
    c *= mix(float3(1.0), float3(1.02, 1.0, 0.97), smoothstep(0.4, 0.9, lc) * vib * 3.0);
    float2 vq = (uv - 0.5) * float2(aspect / 1.6, 1.0);
    c *= 1.0 - (0.10 + 0.12 * glow) * dot(vq, vq) * 1.6;
    c = c * (1.0 - 0.035 * glow) + 0.035 * glow * float3(0.92, 0.95, 1.0);     // lifted, milky blacks
    // Fine ordered dither: an 8×8 Bayer threshold on cells ~1 px per 1200 px of height, quantising
    // to fewer levels as Dither rises (a fine film-like grain → a visible print stipple). At 0,
    // just enough to break 8-bit banding.
    float cell = max(1.0, floor(res.y / 1200.0 + 0.5));
    int2 ic = int2(px / cell);
    float th = bayer8[(ic.y & 7) * 8 + (ic.x & 7)];
    float lv = exp2(mix(7.0, 3.0, dith)) - 1.0;
    float3 q = floor(c * lv + 0.5 + th) / lv;
    c = dith > 0.001 ? mix(c + th / 255.0, q, smoothstep(0.0, 0.08, dith)) : c + bandDither(px) * 1.5;
    return float4(saturate(c), 1.0);
}
