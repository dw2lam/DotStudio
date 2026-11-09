//  Studio1_funcs.h — SHALLOWS (shader id 67). File-scope Metal helpers; every symbol "studio1_".
//
//  Clear knee-deep water over rippled sand, seen from 2.5 m up with the camera tipped 12° off
//  straight down. The bottom of the frame is 0.3 m deep and the top about 1.4 m, the depth
//  following the curve of a sandbar. Everything is linear-light optics, per pixel:
//    1. the view ray refracts through the wave slope (grad η) to the apparent floor point q;
//    2. two fixed-point steps find the surface point whose refracted sun ray lands on q (the
//       first reuses the view's wave sum, so the scene costs three wave sums);
//    3. the caustic irradiance there is the inverse Jacobian of that sun map,
//         E = √(1+σ²) / √(det(I + d·M·Hess)² + σ²),
//       σ = (the sun disc's blur at depth d + the pixel footprint) × how fast det changes right
//       there — the gradient of det comes analytically from the same wave sum (third derivatives
//       of η), so a filament is as thin as the sun and the pixel allow and no thinner: crisp at
//       5K, antialiased at 1600. M is the refraction's slope gain: (1 − 1/n) under a high sun,
//       stronger and anisotropic along the sun's azimuth under a low one (which is what
//       stretches twilight caustics). Dispersion: det at n = 1.331, 1.334 and 1.338.
//  The floor (ripples, caustics) is all evaluated at q, so it wobbles together as it is seen
//  through the moving surface. Light: Beer–Lambert absorption down to the floor and back up, the
//  sand's light returned by the underside of the surface, the water's own in-scatter, a Schlick
//  sky reflection and geometric sun glints on top. Exposed so lit sand sits at mid-tone and only
//  the caustics run into the tone curve's shoulder.

// Wave trains (frame space: x right, y up the frame; metres): direction, wavenumber k, slope A·k
// per unit of `amp` (0.5 + 2.4·Sea State). Swell to chop, λ 3.7 → 0.24 m, spread ±71° around a
// wind blowing toward the bottom of the frame (the shore), so the caustic net flows steadily one
// way. No two wavelengths in a simple ratio, and the directions are irregular, so the sum never
// shows a lattice.
constexpr constant float4 S1_WAVE[7] = {
    float4(-0.06976, -0.99756,   1.6982, 0.030),
    float4(-0.57358, -0.81915,   3.8547, 0.045),
    float4( 0.46947, -0.88295,   6.4775, 0.069),
    float4(-0.92718, -0.37461,  10.3003, 0.058),
    float4(-0.03490, -0.99939,  14.6121, 0.048),
    float4(-0.64279, -0.76604,  19.8208, 0.038),
    float4( 0.86603, -0.50000,  25.8567, 0.027)
};
// (cycles per hour at Speed 1 — periods 10.3 → 2.6 s, deep-water dispersion slowed 6.7× so the
//  sharp net drifts rather than races; each ω quantised to 2π·n/3600 so the hourly wrap of t is
//  seamless; phase) — inlined below.
constant float S1_N = 1.334;
// Manual sun azimuth on the frame (clockwise from straight up): behind the camera's left
// shoulder, across the ripple crests (so they catch it), with the sun's mirror point below the
// frame — glints show only when the waves tip far enough to send it into view.
// Follow the Sun sweeps the azimuth with the hour angle, through here at solar noon (setting
// toward the upper left).
constant float S1_PSI0 = -2.55;
// Cloud field phase (cells): see studio1_cloud.
constant float S1_CLOUD_PHASE = 6.8;

// (sin, cos) from parabolic segments with one refinement step: smooth and within 0.1% —
// plenty for the view and fixed-point sums, which only steer where the floor and the sun map
// are sampled. The caustic sum keeps the hardware sincos.
static inline float2 studio1_fsc(float x) {
    float2 t = fract(x * 0.15915494 + float2(0.0, 0.25)) * 2.0 - 1.0;
    float2 y = -4.0 * t * (1.0 - abs(t));
    return y + 0.225 * y * (abs(y) - 1.0);
}

// The gradient sum (the view's refraction and the sun map's fixed point). The chop rides the
// second-longest train: its phase is strained by that one's (crests bunch on its front and bend
// with it), so crossing trains make an irregular web of cells, never a lattice. Each sum takes
// only the trains it needs (FIRST…LAST−1). One step per train, by template index, so every
// constant folds and nothing is indexed at run time.
template <int I>
static inline void studio1_gstep(float2 p, float tp, float amp, thread float2 &g,
                                 thread float &sl, thread float2 &gl) {
    constexpr float4 W = S1_WAVE[I];
    float2 v = studio1_fsc(W.z * dot(W.xy, p) + tp + sl);
    float2 K = W.z * W.xy + gl;                            // local wavevector
    g += K * (W.w * amp / W.z * v.y);
    if (I == 1) { sl = 1.1 * v.x; gl = (1.1 * v.y * W.z) * W.xy; }
}
template <int FIRST, int LAST>
static inline float2 studio1_grad(float2 p, float4 ta, float3 tb, float amp) {
    float2 g = 0.0, gl = 0.0;
    float sl = 0.0;
    if (FIRST <= 0 && LAST > 0) studio1_gstep<0>(p, ta.x, amp, g, sl, gl);
    if (FIRST <= 1 && LAST > 1) studio1_gstep<1>(p, ta.y, amp, g, sl, gl);
    if (FIRST <= 2 && LAST > 2) studio1_gstep<2>(p, ta.z, amp, g, sl, gl);
    if (FIRST <= 3 && LAST > 3) studio1_gstep<3>(p, ta.w, amp, g, sl, gl);
    if (FIRST <= 4 && LAST > 4) studio1_gstep<4>(p, tb.x, amp, g, sl, gl);
    return g;
}

// The caustic sum: the Hessian of η and the gradients of its three entries (η's third
// derivatives), which give det's gradient across the floor for σ. (The strain's own curvature is
// left out — a few percent.) The 3.7 m swell's curvature is too slight to matter, so it starts at
// train 1.
struct Studio1C { float3 H; float2 gx, gy, gc; };
template <int I>
static inline void studio1_cstep(float2 p, float tp, float amp, thread Studio1C &w,
                                 thread float &sl, thread float2 &gl) {
    constexpr float4 W = S1_WAVE[I];
    float ph = W.z * dot(W.xy, p) + tp + sl;
    float2 K = W.z * W.xy + gl;
    float c, s = sincos(ph, c);
    float a = W.w * amp / W.z;
    float3 KK = float3(K.x * K.x, K.y * K.y, K.x * K.y);
    w.H -= (a * s) * KK;
    float2 aK = (a * c) * K;
    w.gx -= KK.x * aK;
    w.gy -= KK.y * aK;
    w.gc -= KK.z * aK;
    if (I == 1) { sl = 1.1 * s; gl = (1.1 * c * W.z) * W.xy; }
}
static inline Studio1C studio1_caustic(float2 p, float4 ta, float3 tb, float amp) {
    Studio1C w; w.H = 0.0; w.gx = 0.0; w.gy = 0.0; w.gc = 0.0;
    float sl = 0.0;
    float2 gl = 0.0;
    studio1_cstep<1>(p, ta.y, amp, w, sl, gl);
    studio1_cstep<2>(p, ta.z, amp, w, sl, gl);
    studio1_cstep<3>(p, ta.w, amp, w, sl, gl);
    studio1_cstep<4>(p, tb.x, amp, w, sl, gl);
    studio1_cstep<5>(p, tb.y, amp, w, sl, gl);
    studio1_cstep<6>(p, tb.z, amp, w, sl, gl);
    return w;
}

// Refraction slope gain M·g: Mpe across the sun's azimuth, Mpa along it.
static inline float2 studio1_M(float2 g, float2 sh, float Mpe, float Mpa) {
    return Mpe * g + (Mpa - Mpe) * dot(g, sh) * sh;
}

// The day as a phase for the azimuth: 0 at solar noon, ±π/2 at set/rise, ±π at midnight —
// linear in time within each half, so the light swings round steadily and never jumps.
static inline float studio1_dayPhase(float H, float H0) {
    H0 = clamp(H0, 1e-3, NATURE_PI - 1e-3);
    float a = abs(H);
    float ph = a <= H0 ? 0.5 * NATURE_PI * a / H0
                       : 0.5 * NATURE_PI * (1.0 + (a - H0) / (NATURE_PI - H0));
    return H < 0.0 ? -ph : ph;
}

// Direct light through the air at elevation e: reddens (by `red`) and dims toward the horizon.
static inline float3 studio1_air(float e, float red) {
    float m = nature_airmass(max(e, 0.0));
    return exp(-(NATURE_RAYLEIGH * red + 0.03) * (m - 1.0));
}

// The sandbar: depth (m) at a floor point. One low swing bends the contours into a curving bar,
// so warm shallows sweep into aquamarine rather than a straight ramp.
static inline float studio1_depth(float2 p, float scale) {
    float s = (p.y + 0.62) / 2.75 + 0.19 * sin(0.85 * p.x + 0.9) + 0.035 * p.x;
    float f = smoothstep(0.08, 0.95, s);
    return scale * (0.3 + 1.1 * f);
}

// A cheap C¹ sine for the smooth low-frequency fields: parabolic segments (within 6% of sin),
// returning (sin, cos) of x radians.
static inline float2 studio1_psc(float x) {
    float2 t = fract(x * 0.15915494 + float2(0.0, 0.25)) * 2.0 - 1.0;   // (sin, cos) phases, −1…1
    return -4.0 * t * (1.0 - abs(t));
}

// Wave-formed sand ripples, ~8 cm apart: crests along the bar's contours, meandering a little,
// with dislocations (Y-junctions where a ripple splits in two) from the winding of a smooth
// low-frequency field — warped sines, no noise. The spacing breathes ±12% and the relief comes
// and goes in patches, so the crests never read as ruled lines. Returns the gradient of the sand
// height; `trough` (0…1) marks the troughs (darker, coarser sand settles there, and they see less
// sky). Faded by the pixel footprint: no moiré.
static inline float2 studio1_ripples(float2 q, float fp, thread float &trough) {
    float a1 = 0.85 * q.x + 0.9;
    float2 sc2c = studio1_psc(2.2 * q.y + 0.4);
    float s2c = sc2c.x, c2c = sc2c.y;
    float a2 = 5.3 * q.x + 1.7 * s2c + 0.9 * q.y;
    float2 sc1a = studio1_psc(a1), sc2a = studio1_psc(a2);
    float s1a = sc1a.x, c1a = sc1a.y, s2a = sc2a.x, c2a = sc2a.y;
    float s = q.y + 0.30 * s1a + 0.024 * s2a;
    float2 gs = float2(0.255 * c1a, 1.0) + (0.024 * c2a) * float2(5.3, 1.7 * 2.2 * c2c + 0.9);
    float b1 = 6.1 * q.x + 0.4, b2 = 5.3 * q.y - 3.1 * q.x + 2.2;
    float b3 = 5.7 * q.y + 2.3 * q.x + 1.1, b4 = 6.7 * q.x - 1.9 * q.y + 0.3;
    float2 e1 = studio1_psc(b1), e2 = studio1_psc(b2), e3 = studio1_psc(b3), e4 = studio1_psc(b4);
    float sb1 = e1.x, cb1 = e1.y, sb2 = e2.x, cb2 = e2.y, sb3 = e3.x, cb3 = e3.y, sb4 = e4.x, cb4 = e4.y;
    float A = sb1 + 0.9 * sb2;
    float B = sb3 + 0.8 * sb4;
    float2 gA = float2(6.1 * cb1 - 2.79 * cb2, 4.77 * cb2);
    float2 gB = float2(2.3 * cb3 + 5.36 * cb4, 5.7 * cb3 - 1.52 * cb4);
    float m2 = A * A + B * B;
    // 2π / 8 cm, breathing with a slow field along the crests (wider where the bar is gentler).
    float2 kv = studio1_psc(1.3 * q.x - 0.7 * q.y + 2.0);
    float kr = 78.54 * (1.0 + 0.12 * kv.x);
    float2 gkr = 78.54 * 0.12 * kv.y * float2(1.3, -0.7);
    // atan2(B, A) by a minimax polynomial (≈0.001 rad): the winding is all that matters here.
    float mx = max(abs(A), abs(B)), mn = min(abs(A), abs(B));
    float z = mn / max(mx, 1e-6), z2 = z * z;
    float at = z * (0.99997726 + z2 * (-0.33262347 + z2 * (0.19354346 + z2 * (-0.11643287 + z2 * (0.05265332 - 0.01172120 * z2)))));
    at = abs(B) > abs(A) ? 1.5707963 - at : at;
    at = A < 0.0 ? 3.1415927 - at : at;
    at = B < 0.0 ? -at : at;
    float ph = kr * s + at;
    float2 gph = kr * gs + s * gkr + (A * gB - B * gA) / (m2 + 1e-3);
    float kf = length(gph) * fp;
    // (Patchy relief and crests that strengthen and fade along their length, from the sines
    // already in hand.)
    float patch = saturate(0.35 + 0.75 * sb2 * cb3) * (0.7 + 0.3 * c2a);
    float fade = exp(-kf * kf * 0.5) * m2 / (m2 + 0.15) * patch;
    float c1, s1 = sincos(ph, c1);
    // Profile cos φ + 0.09 cos 2φ: rounded crests, a little broader troughs — soft swells in the
    // light, not engraved lines.
    trough = (0.5 - 0.5 * c1) * fade;
    return (-0.0031 * fade * s1 * (1.0 + 0.36 * c1)) * gph;
}

// Value noise on an integer lattice hash (cheaper than gradient noise; fine for sand grain).
static inline float studio1_vnoise(float2 p) {
    float2 i = floor(p), f = p - i;
    f = f * f * (3.0 - 2.0 * f);
    uint2 c = uint2(int2(i) + 32768);
    uint4 n = ((c.x + uint4(0u, 1u, 0u, 1u)) * 73856093u) ^ ((c.y + uint4(0u, 0u, 1u, 1u)) * 19349663u);
    n *= 2654435761u;
    n ^= n >> 15u;
    float4 v = float4(n >> 8u) * (1.0 / 16777216.0);
    return mix(mix(v.x, v.y, f.x), mix(v.z, v.w, f.x), f.y) - 0.5;
}

// Sky radiance along R (relative to the key light's irradiance): horizon → zenith, plus the
// aureole around the key light.
static inline float3 studio1_sky(float3 R, float3 Ls, float3 skyZ, float3 skyH, float3 glow) {
    float3 s = mix(skyH, skyZ, sqrt(saturate(R.z)));
    float mu = dot(R, Ls);
    return s + glow * (0.06 * exp(6.0 * (mu - 1.0)) + 0.4 * exp(80.0 * (mu - 1.0)));
}

// Cloud shadow cover (0…1) at floor point q: one octave of gradient noise along the wind's path.
// A cell is ~120 m of cloud drifting over in ~86 s at Speed 1, and the frame spans 0.03 of one, so
// across it the field is one-dimensional: a shadow comes over the whole frame along the wind,
// taking 10–20 s to come over and as long to clear (a few times an hour at Clouds 0.3). Laps of
// 21 cells, a whole number per hour, so the hourly wrap of t is seamless. The phase puts the
// first shadow two minutes after t = 0 at Speed 1 (one at Speed 2) for Clouds up to 0.5, so a
// preview opens in sunshine.
static inline float studio1_cloud(float2 q, float t, float speed, float clouds) {
    const float2 wd = float2(-0.19081, -0.98163);
    float uc = 21.0 * fract(t * (round(2.0 * speed) * (1.0 / 3600.0))) - dot(q, wd) / 120.0 + S1_CLOUD_PHASE;
    float ci = floor(uc), cf = uc - ci;
    float g0 = nature_h1(ci - 21.0 * floor(ci / 21.0) + 101.0) * 2.0 - 1.0;
    float g1 = nature_h1(ci + 1.0 - 21.0 * floor((ci + 1.0) / 21.0) + 101.0) * 2.0 - 1.0;
    float cn = mix(g0 * cf, g1 * (cf - 1.0), cf * cf * cf * (cf * (cf * 6.0 - 15.0) + 10.0));
    float thr = 0.20 - 0.32 * clouds;
    return smoothstep(thr, thr + 0.34, cn);
}

// Inline (not out of line like Ocean Horizon's live path): inside fx_fragment the compiler sees
// that everything derived from `u` is uniform, which measured 18% faster here (10.2 → 8.3 ms at
// 5120×2880 at the time), with Liquid Chrome, Black Hole and Golden Hour unchanged.
static inline float4 studio1_shallows(float2 uv, float2 res, float2 px, float t, constant FXUniforms& u,
                                      const bool wx = false) {
    float speed = clamp(u.p0.x, 0.0, 2.0);
    float dScale = exp2((clamp(u.p0.y, 0.0, 1.0) - 0.5) * 1.6);
    float sea = clamp(u.p0.z, 0.0, 1.0);
    float clar = clamp(u.p0.w, 0.0, 1.0);
    float clouds = clamp(u.p1.w, 0.0, 1.0);
    // Weather (the fx_wx_shallows copy, Shared/Weather): the wind sets the sea, cloud cover the
    // shadows passing over — partly cloudy, cumulus shadows drifting across the frame; a full deck
    // puts the whole floor in soft shade (no sharp net) — rain rings the surface, snow falls past
    // the lens to the water, a storm flashes. See Shared/Weather/Weather_funcs.h.
    WxState W = wx ? wx_state(u) : WxState{};
    if (wx) {
        sea = wx_seaState(sea, W.wind);
        float cv = W.cover;
        clouds = cv < 0.25 ? clouds * mix(0.3, 1.0, cv * 4.0) : mix(clouds, 1.0, smoothstep(0.25, 0.9, cv));
    }
    bool live = u.p1.y > 0.5 && u.sky.y > 0.5;

    // ---- Key light (the sun; live, the arch of twilight once it has set, then the moon) and sky.
    float el, psi, keyMoon = 0.0, keyTw = 0.0, night = 0.0;
    float3 Ek, skyZ, skyH;
    float3 tint = live ? nature_liveTint(u) : srgbToLinear(u.colorB.rgb);
    if (live) {
        float dd = -u.sun.x * 57.29578;
        night = smoothstep(4.0, 12.0, dd);
        float hemi = u.sun.w < 0.0 ? -1.0 : 1.0;
        float fall = nature_liveFall(dd);
        float day = smoothstep(-0.06, 0.45, u.sun.x);
        if (dd < 5.0) {
            el = u.sun.x;
            psi = S1_PSI0 + hemi * studio1_dayPhase(u.sun.y, u.sun.z);
            float up = smoothstep(-0.012, 0.02, el);
            Ek = tint * studio1_air(el, 0.3) * up;
            // Blue hour: the bright arch of sky over the set sun is a broad, faint key of its own —
            // soft, slow caustics instead of a flat floor — warm at first, then blue, gone by 5°.
            keyTw = 1.0 - up;
            float3 arch = mix(tint * float3(1.0, 0.86, 0.80), float3(0.50, 0.62, 1.0), smoothstep(0.5, 3.5, dd));
            Ek += arch * (0.05 * keyTw * fall * (1.0 - smoothstep(3.0, 5.0, dd)));
        } else {
            keyMoon = 1.0;
            el = u.moon.x;
            psi = S1_PSI0 + hemi * studio1_dayPhase(u.moon.y, u.moon.z);
            Ek = nature_liveMoonE(u, dd) * (1.6 / 9.5) * studio1_air(el, 0.3) * smoothstep(-0.012, 0.03, el);
        }
        // Day sky, then the blue hour fading with the sun's depression, then moonlight and a
        // floor of starlight and airglow so the night never crushes to black.
        float3 dz = float3(0.10, 0.20, 0.42), dh = float3(0.40, 0.48, 0.58);
        float warm = (1.0 - smoothstep(0.0, 0.35, u.sun.x)) * smoothstep(-0.07, 0.0, u.sun.x);
        dh = mix(dh, dh * tint * 1.4, 0.6 * warm);
        float lvl = mix(0.22, 1.0, day) * fall;
        float3 mE = keyMoon > 0.5 ? Ek : float3(0.0);
        skyZ = dz * lvl + float3(0.10, 0.16, 0.30) * 0.05 * (1.0 - day) * fall
             + float3(0.35, 0.45, 0.70) * 0.6 * luma(mE) + float3(0.0020, 0.0034, 0.0072);
        skyH = dh * lvl + float3(0.20, 0.22, 0.34) * 0.05 * (1.0 - day) * fall
             + float3(0.40, 0.48, 0.70) * 0.7 * luma(mE) + float3(0.0026, 0.0040, 0.0078);
    } else {
        el = clamp(u.p1.x, 5.0, 85.0) * 0.0174533;
        psi = S1_PSI0;
        Ek = tint * studio1_air(el, 0.6);
        float day = mix(0.35, 1.0, smoothstep(0.05, 0.6, el));
        float warm = 1.0 - smoothstep(0.08, 0.4, el);
        skyZ = float3(0.10, 0.20, 0.42) * day;
        skyH = mix(float3(0.40, 0.48, 0.58), float3(0.40, 0.48, 0.58) * tint * 1.3, 0.6 * warm) * day;
    }
    if (wx) {
        // Under a deck the sky is a soft grey dome (its luminance from the light it lets through).
        float3 g = float3(luma(skyH) * 1.5 + luma(Ek) * 0.10) * float3(0.97, 1.0, 1.04);
        skyZ = mix(skyZ, g, W.deck);
        skyH = mix(skyH, g * 0.92, W.deck);
    }
    float2 sh = float2(sin(psi), cos(psi));                   // toward the key light, on the frame
    float elg = max(el, 0.05);                                 // (geometry: never quite grazing)
    float3 Ls = float3(sh * cos(elg), sin(elg));
    float sinTt = cos(elg) / S1_N, cosTt = sqrt(1.0 - sinTt * sinTt);
    float2 T0 = -sh * (sinTt / cosTt);                         // sun ray's run per metre of depth
    float Mpe = 1.0 - sin(elg) / (S1_N * cosTt);
    float Mpa = Mpe / (cosTt * cosTt);
    float Ts = 1.0 - nature_schlick(sin(elg));                 // into the water
    float3 Eamb = (skyZ * 0.5 + skyH * 0.5) * 0.42;          // skylight on a level surface
    // How warm the key is (a low sun, the twilight arch): the water's own colour leans toward
    // blue-cyan to match, so orange light through teal water never mixes to khaki.
    float warmK = saturate(((luma(Ek) - Ek.b) / max(luma(Ek), 1e-4) - 0.2) * 2.0);

    // ---- Camera: 2.5 m up, tipped 12° from straight down toward the top of the frame.
    float aspect = res.x / res.y;
    float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
    const float F = 2.0, Hc = 2.5;
    const float ct = 0.97815, st = 0.20791;                    // cos, sin 12°
    float3 r = normalize(float3(sp.x, st * F + ct * sp.y, -ct * F + st * sp.y));
    float cv = -r.z;
    float ds = Hc / cv;
    float2 P = r.xy * ds;                                      // where the ray meets the surface
    float pix = 2.0 / (res.y * F);
    float sv = length(r.xy);
    float ctv = sqrt(1.0 - sv * sv / (S1_N * S1_N));
    float2 Tv = r.xy / (S1_N * ctv);                           // the view's run per metre of depth
    float Mv = 1.0 - cv / (S1_N * ctv);
    float D = studio1_depth(P, dScale);
    D = studio1_depth(P + D * Tv, dScale);
    float fpS = ds * pix * rsqrt(cv);                          // pixel footprint on the surface
    float fpF = (ds + D * 0.75) * pix * rsqrt(cv);             // … and on the floor

    // ---- Waves: per-train time phase, ω quantised by Speed (seamless hourly wrap).
    float4 ta = float4(0.7000, 3.1000, 5.4999, 1.6167)
              - 6.2831853 * fract(t * round(float4(350.0, 527.0, 683.0, 861.0) * speed) * (1.0 / 3600.0));
    float3 tb = float3(4.0167, 0.1334, 2.5334)
              - 6.2831853 * fract(t * round(float3(1026.0, 1195.0, 1364.0) * speed) * (1.0 / 3600.0));
    float amp = 0.5 + 2.4 * sea;
    float2 g1 = studio1_grad<0, 5>(P, ta, tb, amp);
    float splash = 0.0;
    if (wx && W.rain > 0.01) {
        // Rain: rings running out over the surface (they refract the floor and mirror the sky),
        // and the splash where each lands. (Drawn at 1/3 scale, two cells' worth of drops a
        // second: up close, these are the small drops'.)
        float4 rg = wx_rings(P * 3.0, t * speed, fpS * 3.0, saturate(W.rain * 1.5));
        g1 += rg.xy * 1.8;
        splash = rg.w * W.rain;
    }
    float2 q = P + D * (Tv + Mv * g1);                         // (1) apparent floor point

    float cover = clouds > 0.001 ? studio1_cloud(q, t, speed, clouds) : 0.0;
    float coverE = cover;                                      // (what the exposure adapts to)
    if (wx) {
        cover = max(cover, W.deck);
        coverE = cover;
        // Partly cloudy: fair-weather cumulus overhead — their shadows (soft-edged: a heap a
        // kilometre up has a penumbra metres wide) drift over the shallows down-wind, so the frame
        // is part sun, part shade most of the time, the edge slowly crossing it.
        float cu = smoothstep(0.30, 0.48, W.cover) * (1.0 - smoothstep(0.80, 0.95, W.cover))
                 * (1.0 - smoothstep(0.35, 0.6, W.fog));            // (as nature_wxCu)
        if (cu > 0.0) {
            // (The offset puts an edge in the frame in the opening seconds.)
            float2 cq = q * (1.0 / 14.0) + float2(-0.19081, -0.98163) * (t * speed * (0.55 / 14.0)) + float2(4.5, 1.7);
            float sh = smoothstep(-0.10, 0.16, nature_gnoise(cq) + 0.225 * nature_gnoise(cq * 2.3 + 5.1) + 0.1);
            cover = max(cover, cu * sh);
        }
    }
    // Under a cloud the direct light (and with it the caustics) drops to 30%, the cloud's own
    // glow lifts the skylight, and the exposure adapts most of the rest of the way: under full
    // cover the frame as a whole dims by under 10% while the net softens to a third.
    float sunDim = 1.0 - (wx ? 0.7 + 0.27 * W.deck : 0.7) * cover;
    float3 EambC = Eamb + Ek * (0.22 * cover) * float3(0.94, 0.98, 1.04);

    // Exposure: like an eye, opens up as the light goes (low sun, twilight, moonlight, cloud), not
    // all the way — night stays night. Set so lit sand sits at mid-tone, out of the shoulder.
    // (Not to a passing cumulus' shadow: the eye takes in the whole frame, so its shade shows.)
    float sunDimE = wx ? 1.0 - (0.7 + 0.27 * W.deck) * coverE : sunDim;
    float Ebar = luma(Ek) * Ts * cosTt * smoothstep(-0.01, 0.06, el) * sunDimE
               + luma(wx ? Eamb + Ek * (0.22 * coverE) * float3(0.94, 0.98, 1.04) : EambC);
    float expo = 0.63 * clamp(pow(max(Ebar, 1e-6) / 0.95, -0.62), 0.7, 60.0);

    // ---- Surface: Schlick sky reflection (~2% straight down, more toward the top) and glints.
    // (Done here, while the view's wave sum is at hand, so the sky colours can go.)
    float3 Ns = normalize(float3(-g1, 1.0));
    float3 V = -r;
    float cNV = max(dot(Ns, V), 0.05);
    float Fv = nature_schlick(cNV);
    float3 surf = Fv * studio1_sky(reflect(r, Ns), Ls, skyZ, skyH, Ek * (1.0 - 0.8 * cover));
    {
        // Sun glints: a Beckmann lobe over the sun disc, residual chop and the slope change
        // across the pixel (so a glint is never a single-pixel dot), only where the geometry puts
        // the sun's reflection in view. Peak held to a few times the floor's brightness — a hot
        // core with a soft edge, not a flat white stroke — and dimmed in proportion as the
        // footprint widens the lobe; glints that need a steep facet (the rare ones) fade.
        float hv2 = 4.0 * amp * amp;                           // (the surface's typical curvature²)
        float s2b = 0.00005 + 0.00004 * sea + 2.2e-5;
        float s2 = s2b + fpS * fpS * hv2 * 2.0;
        float3 hh = normalize(Ls + V);
        float chn = max(dot(hh, Ns), 1e-3);
        float c2 = chn * chn;
        float t2 = (1.0 - c2) / c2;
        if (t2 < s2 * 160.0 && el > 0.0) {
            float2 greq = hh.xy / hh.z;
            float lobe = (exp(-t2 / s2) + 0.05 * exp(-t2 / (s2 * 16.0))) * (s2b / s2) * exp(-dot(greq, greq) * 16.0);
            surf += Ek * (nature_schlick(max(dot(hh, V), 0.0)) * 40.0 * lobe)
                  * ((1.0 - 0.9 * cover) * smoothstep(0.0, 0.05, el) * (1.0 - keyMoon * 0.5) * (1.0 - keyTw));
        }
    }

    // A low sun's slant makes the lens far stronger along its azimuth; past D·M ≈ 0.8 the inverse
    // map stops converging (and real caustics there blur into overlapping folds), so the depth
    // the sun map sees saturates there: still stretched along the azimuth, never noise.
    float kD = D * Mpa / 0.8;
    float Ds = D * rsqrt(sqrt(1.0 + kD * kD * kD * kD));
    // (2) the surface point whose refracted sun ray lands on q: two fixed-point steps.
    float2 x1 = q - D * T0 - Ds * studio1_M(g1, sh, Mpe, Mpa);
    float2 g2 = studio1_grad<1, 5>(x1, ta, tb, amp);
    float2 x2 = q - D * T0 - Ds * studio1_M(g2, sh, Mpe, Mpa);
    Studio1C C = studio1_caustic(x2, ta, tb, amp);
    float3 H = C.H;
    // Over the bar the chop shoals — steeper, more sharply curved — so in the shallows, where
    // these waves alone would barely bring light to a focus in 30 cm, the lens is as strong as a
    // metre down: the bar is netted too, crisper for the shallower water (the sun's blur below
    // still goes by the true depth).
    float Dc = max(D, (1.1 + 0.12 * D / dScale) * dScale);
    float kc = Dc * Mpa / 0.8;
    float Dsc = Dc * rsqrt(sqrt(1.0 + kc * kc * kc * kc));
    // (3) caustic irradiance: det(I + s·D·M·H) = 1 + s·D·tr(MH) + s²·D²·det(M)·det(H).
    float sxx = sh.x * sh.x, syy = sh.y * sh.y, sxy = 2.0 * sh.x * sh.y;
    float hss = sxx * H.x + syy * H.y + sxy * H.z;
    float trA = Dsc * (Mpe * (H.x + H.y) + (Mpa - Mpe) * hss);
    float dM = Dsc * Dsc * Mpa * Mpe;
    float dtA = dM * (H.x * H.y - H.z * H.z);
    // det's gradient across the floor, exactly, from the third derivatives.
    float2 gdet = Dsc * (Mpe * (C.gx + C.gy) + (Mpa - Mpe) * (sxx * C.gx + syy * C.gy + sxy * C.gc))
                + dM * (H.y * C.gx + H.x * C.gy - 2.0 * H.z * C.gc);
    // σ: det's change across the sun disc's blur (0.265° radius ÷ n in the water, run out along
    // the slant; a third of it, as the symmetric profile here is broader than a real fold's) and
    // across the pixel; moonlight and the twilight arch are broad sources, broader still; a little
    // forward scatter.
    float blur = D * 0.0012 / (cosTt * cosTt) + fpF * 0.75;
    float bs = 0.03 + 0.45 * (1.0 - clar);                     // scattering, /m
    float sig = 0.03 + length(gdet) * blur + keyMoon * 0.45 + keyTw * 0.4 + bs * D * 0.06;
    if (wx) sig += 1.5 * W.deck + 0.3 * W.fog;               // (a broad, dim source: no sharp net)
    float3 sc = float3(0.99329, 1.0, 1.00898);                 // n = 1.331, 1.334, 1.338
    float3 det = 1.0 + sc * trA + sc * sc * dtA;
    float3 Ec = sqrt(1.0 + sig * sig) * rsqrt(det * det + sig * sig);
    // Gentle knee: a filament's core runs on into the tone curve's shoulder (a white-hot line
    // with a soft glow either side), but a broad near-focus never blows out into a white slab.
    float3 ex = max(Ec - 1.0, 0.0);
    Ec = min(Ec, 1.0) + ex / (1.0 + ex * 0.11);
    Ec = mix(float3(1.0), Ec, exp(-bs * D * 0.5) * (1.0 - 0.55 * keyMoon));

    // ---- The floor at q: rippled sand.
    float trough;
    float2 gr = studio1_ripples(q, fpF, trough);
    float3 sand0 = srgbToLinear(u.colorA.rgb);
    float3 sand = sand0;
    // Fine grain and shell hash in floor space (so it wobbles with the floor), fading out
    // before it could alias.
    float fg = 200.0 * fpF;
    sand *= (1.0 - 0.07 * trough) * (0.95 + 0.05 * sin(0.7 * q.x + 1.3 * sin(0.5 * q.y + 1.0)))
          * (1.0 + 0.08 * studio1_vnoise(q * 200.0) * exp(-0.5 * fg * fg));
    float3 nf = normalize(float3(-gr, 1.0));
    float ao = 1.0 - 0.22 * trough;
    float3 Lw = float3(sh * sinTt, cosTt);                     // toward the key, in the water
    float ndl = max(dot(nf, Lw), 0.0);
    // Skylight: mostly even, part from the brighter half of the sky — the larger part when it is
    // all the light there is (blue hour, a moonless night), so the ripples still show in relief.
    float keyE = luma(Ek) * Ts * cosTt * sunDim;
    float onlySky = luma(EambC) / (luma(EambC) + keyE + 1e-5);
    float dirF = 0.3 + 0.6 * onlySky;
    float3 Lk = normalize(float3(sh * (0.8 + 1.4 * onlySky), 1.0));
    float ndk = 1.0 - dirF + dirF * max(dot(nf, Lk), 0.0) / Lk.z;

    // ---- Water: Beer–Lambert down to the floor and back up; murk adds yellow-green absorption.
    // (Red absorption graded with depth — 0.16/m over the bar, 0.52/m off it — so the bar keeps
    // its sand colour and the deep end comes up aquamarine; one coefficient can't do both.)
    // Under a warm key the ramp moves out and eases (gold light stays gold over the bar instead
    // of going olive through the red-absorbing water) while the water's own colour, below, leans
    // blue and comes up stronger: gold caustics on sand, then blue-teal, never khaki between.
    float sar = 0.16 + 0.36 * (1.0 - 0.35 * warmK) * smoothstep(0.35 + 0.45 * warmK, 1.3 + 0.4 * warmK, D);
    float3 sa = float3(sar, 0.07, 0.015) + (1.0 - clar) * float3(0.05, 0.07, 0.18);
    float3 aup = (sa + bs * 0.3) * (D / ctv);
    float3 Tdu = exp(-sa * (D / cosTt) - aup);                 // sunlight: down and back up
    float3 Tau = exp(-sa * (D * 1.2) - aup);                   // skylight: down and back up
    float3 Ed = Ek * (Ts * sunDim) * Tdu;                      // the key light on the floor
    // The sand's own light, sent back down by the underside of the surface (total internal
    // reflection past 48.6°): a warm fill that keeps the shade between the caustics luminous.
    float3 Efill = Ed * (0.16 * cosTt) * sand0 * exp(-sa * D);
    float3 Lf = sand * (Ed * Ec * ndl + EambC * (0.93 * ao * ndk) * Tau + Efill);
    // In-scatter: what the water column sends back up — the water's own colour, turquoise,
    // leaning blue as the key warms.
    float3 wcol = mix(float3(0.04, 0.66, 1.00), float3(0.02, 0.42, 1.10), warmK);
    float3 cext = sa + bs;
    float3 Lsc = (luma(Ek) * Ts * sunDim * 0.6 + luma(EambC) * 1.1) * (bs * 0.5 + 0.20 * (1.0 + 0.6 * warmK) * smoothstep(0.2, 1.0, D))
               * (1.0 - exp(-cext * (D / ctv))) / cext * wcol;
    float3 col = (Lf + Lsc) * (1.0 - Fv) + surf;
    if (wx) {
        col += (skyZ * 0.5 + skyH * 0.5) * (splash * 0.8);
        // Lightning: the whole shallow lit for a moment — gentle, and after the eye's exposure.
        float4 ev;
        float fl = (W.storm > 0.0 && u.weather3.y > 0.5) ? wx_lightning(t, W.storm, ev) : 0.0;
        if (fl > 0.0) col += (sand * 0.85 + float3(0.02, 0.06, 0.08)) * float3(0.8, 0.84, 1.0) * (fl * 0.18 / max(expo, 1e-3));
        // Snow (and sleet's wetter flakes): falling past the lens toward the water, lit by the
        // sky above them and what sun gets through — white over the sand and the water, with the
        // faint shadow ring that parts them from a pale floor. (Rain shows in its rings alone.)
        float share = saturate(u.weather.z), sk = smoothstep(0.2, 0.42, share);
        if (W.wet > 0.005 && sk > 0.0) {
            float2 fa = sk * wx_flakesDown(r, cv, t * speed, 2.0 / res.y, F, min(W.wet * 1.55, 1.4) * (1.0 - 0.45 * (1.0 - smoothstep(0.62, 0.9, share))),
                                           W.wind, Hc, 1.0 - smoothstep(0.62, 0.9, share));
            float3 flakeL = (EambC * 1.25 + Ek * (Ts * sunDim * 0.35)) * float3(0.97, 0.99, 1.02);
            col *= 1.0 - 0.2 * fa.y;
            col = mix(col, flakeL, fa.x);
        }
    }

    // Night: the eye loses colour and shifts blue (as a moonlit scene reads), gently.
    col = mix(col, luma(col) * float3(0.62, 0.84, 1.18), 0.55 * night);
    // Tone: linear to 0.72, then a soft shoulder 1 − 0.28·e^(−(x−0.72)/0.28) — keeps the bright
    // shallows' ripples and caustics in contrast where 1 − e^(−x) alone would flatten them.
    // Written as the input that lands nature_display's own 1 − e^(−x) there (C¹ at 0.72).
    float3 x = col * expo;
    x = select(1.27297 + 3.5714286 * (x - 0.72), -log(max(1.0 - x, 1e-4)), x < 0.72);
    return float4(nature_display(x, px), 1.0);
}
