//  Studio3_funcs.h — PLEATS (scene 69): file-scope helpers. Every symbol is prefixed "studio3_".
//
//  A macro of accordion-pleated material under a raking key light. No raymarching: the
//  field is a smoothly warped 2D coordinate whose phase φ counts pleats across the folds
//  (an analytic S-bend, a fan and two noise terms, seen through a slight macro perspective),
//  and the pleat is an extruded cross-section — straight facets joined by circular crease
//  arcs — shaded in closed form:
//    · Lambert key, the light projected into the cross-section (elevation e); attached
//      shadow where the facet turns past e, softened over the light's angular size;
//    · the cast shadow of each ridge on the next facet: the line tangent to the ridge's
//      crease arc meets the lit facet at x_s (2H / (tan e + tan β) for a sharp ridge), with
//      a penumbra of (distance from the ridge × light size);
//    · hemispherical sky fill, occluded down in the V of each fold;
//    · one bounce from the facing facet (albedo × its irradiance × view factor ≈ 0.3) —
//      the warm, deeper valley colour that sells real material;
//    · translucency (light through the crest of paper; a lantern lit from behind);
//    · anisotropic GGX: a burnished hairline on paper creases, a sheen line + soft lobe on satin.
//  Anti-aliasing: taps across the pixel's footprint in φ, widened by the depth-of-field blur,
//  each pre-filtered over its own share (crease radius, NDF width and penumbra grow with it);
//  four where the footprint holds a crease or a shadow edge, one on open facet (exact there);
//  fading to the φ-independent period average beyond about half a pleat. The φ gradient is
//  analytic. Microtexture lives in material coordinates (φ, along) and fades by footprint.

constant float STUDIO3_PI = 3.14159265;

static inline float studio3_s01(float x) { x = saturate(x); return x * x * (3.0 - 2.0 * x); }
// sRGB → linear for colour wells (cubic fit, < 0.3% error; every pixel would pay for a pow).
static inline float3 studio3_lin(float3 c) {
    c = saturate(c);
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

// Integer lattice hashes (no sin, no fract precision games), values in [−1, 1].
static inline float2 studio3_h22(float2 p) {
    uint2 q = as_type<uint2>(int2(p));
    q = 1103515245u * ((q >> 1u) ^ q.yx);
    uint n = 1103515245u * (q.x ^ (q.y >> 3u));
    return float2(uint2(n, n * 48271u)) * (2.0 / 4294967295.0) - 1.0;
}
static inline float studio3_h11(float p) {
    uint n = as_type<uint>(int(p)) * 747796405u + 2891336453u;
    n = ((n >> ((n >> 28u) + 4u)) ^ n) * 277803737u;
    return float((n >> 22u) ^ n) * (2.0 / 4294967295.0) - 1.0;
}
// 2D gradient noise with its analytic gradient: (value, d/dx, d/dy), value in ~[−0.7, 0.7].
static inline float3 studio3_gnd(float2 p) {
    float2 i = floor(p), f = p - i;
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float2 ga = studio3_h22(i), gb = studio3_h22(i + float2(1.0, 0.0));
    float2 gc = studio3_h22(i + float2(0.0, 1.0)), gd = studio3_h22(i + float2(1.0, 1.0));
    float va = dot(ga, f), vb = dot(gb, f - float2(1.0, 0.0));
    float vc = dot(gc, f - float2(0.0, 1.0)), vd = dot(gd, f - float2(1.0, 1.0));
    float k = va - vb - vc + vd;
    return float3(va + w.x * (vb - va) + w.y * (vc - va) + w.x * w.y * k,
                  ga + w.x * (gb - ga) + w.y * (gc - ga) + w.x * w.y * (ga - gb - gc + gd)
                     + dw * (w.yx * k + float2(vb, vc) - va));
}
// 1-D gradient noise with its derivative: (value ~[−0.5, 0.5], d/dx).
static inline float2 studio3_n1d(float x) {
    float i = floor(x), f = x - i;
    float w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float ga = studio3_h11(i), gb = studio3_h11(i + 1.0);
    float va = ga * f, vb = gb * (f - 1.0);
    return float2(va + w * (vb - va), ga + w * (gb - ga) + dw * (vb - va));
}

// Per-pixel state for the cross-section shader. Pleat frame: x across (light arrives from −x),
// y along the folds, z out of the sheet. Lengths in pleat widths. Fields below the line
// depend on the tap width and are filled by studio3_prep.
struct Studio3P {
    float R0;           // crease radius (material)
    float sb, cb, tb;   // facet slope β
    float H, iH;        // ridge height above the valley (= tanβ / 2)
    float se, ce;       // key elevation e in the cross-section
    float ell;          // |key| projected into the cross-section
    float xb;           // along-fold microtilt × along key, in sin(e − ν) units
    float sdn, cdn;     // across microtilt (sin, cos)
    float sigL;         // key angular radius
    float kE;           // 1 when the ridge casts a shadow (e < β), fading as e → β
    float aoK;          // valley sky occlusion
    float Easc, Edesc;  // irradiance (× key) on the lit and the turned-away facet (bounce)
    float3 L, h;        // key, half vector (pleat frame)
    float sH, cH;       // the half vector's angle in the cross-section (sin, cos)
    float sc2;          // sheen core width² (rad²)
    float sg, cg;       // Lantern: back-light tilt γ
    int mat;            // 0 paper, 1 satin, 2 linen, 3 lantern
    // ---- per tap width
    float subw;
    float R, R2, iR, Rs, zv0, zr0;
    float Tx, igate;    // the ridge's terminator (tangent point) and its soft gate
    float xsh, ipen;    // cast-shadow line on the lit facet, 1 / penumbra
    float iwa;          // bounce side blend across the valley
    float rw0, irw;     // ridge band (paper burnish, lantern crease)
    float kH, iD, iA;   // parallax: screen phase u = x + k·z(x) → profile x (see studio3_par)
    float isb, icb, te, iteb, penK; // per-pixel constants for studio3_prep
    float iglow;        // paper: crest-glow ramp
};

// Parallax: seen obliquely (k = −V_a/V_z), a profile point x at height z lands at
// u = x + k·z(x) across the folds, so facets turned toward the camera look wider. The facets are
// straight, so the inverse is exact per facet (the crease arcs' tiny offset is ignored).
static inline float studio3_par(float f, thread const Studio3P& P) {
    float u = P.kH + fract(f - P.kH);          // one period, starting at the ridge
    return u <= 0.5 ? (u - P.kH) * P.iD : min((u + P.kH) * P.iA, 0.99999);
}

static inline void studio3_prep(thread Studio3P& P, float subw) {
    P.subw = subw;
    // A crease never resolves finer than the tap's own interval: blur widens it.
    float R = clamp(max(P.R0, 0.45 * subw * P.isb), 1e-4, 0.24 * P.isb);
    P.R = R; P.R2 = R * R; P.iR = 1.0 / R; P.Rs = R * P.sb;
    P.zv0 = R * P.icb; P.zr0 = P.H - P.zv0;
    // Tangent point of the shadow line on the ridge arc (normal at min(e, β)), then where the
    // line (slope −tan e) meets the lit facet z = tan β·(x − ½); its penumbra is the light's
    // angular size × the ridge's distance, across the facet (penK = 2σ·cos β / sin(e + β) / cos e).
    bool eLow = P.kE > 0.0;
    float sec = eLow ? P.se : P.sb, cec = eLow ? P.ce : P.cb;
    P.Tx = R * sec;
    float Ty = P.zr0 + R * cec;
    P.xsh = (Ty + P.te * P.Tx + 0.5 * P.tb) * P.iteb;
    P.ipen = 1.0 / (P.penK * max(P.xsh - P.Tx, 0.0) + 1.4 * subw + 0.004);
    P.igate = 1.0 / (0.024 + subw);
    P.iwa = 1.0 / (2.0 * P.Rs + 0.06);
    P.rw0 = P.Rs; P.irw = 1.0 / (0.6 * subw + 0.015);
    P.iglow = 1.0 / (P.Rs + subw + 0.01);
}

struct Studio3Tap { float key, sky, bounce, spec, trans; };

// Shading that depends only on the normal (sin ν, cos ν) and how fast it turns across the tap
// (dnu): Lambert key (box-filtered over the light's size and the tap — a C¹ ramp, so the
// terminator never snaps), the specular lobe, and the lantern's back-light.
struct Studio3N { float lam, spr, eb, cnT; };
static inline Studio3N studio3_shadeN(float sn, float cn, float dnu, thread const Studio3P& P, bool wantSpec) {
    Studio3N o;
    float snT = sn * P.cdn + cn * P.sdn;       // + microtexture tilt
    o.cnT = cn * P.cdn - sn * P.sdn;
    float w = P.sigL + 0.5 * dnu;
    float x = P.se * cn - P.ce * sn;           // sin(e − ν)
    // Microtexture shades what the key lights, relative to it (its tilt moves sin(e − ν) by
    // −cos(e − ν)·δν): texture rakes across lit paper but never flips shadow into speckle.
    float dx = P.xb - (P.ce * cn + P.se * sn) * P.sdn;
    float mk = 1.0 + clamp(dx / max(x, 0.25), -0.6, 0.6);
    o.lam = (x >= w ? x : (x <= -w ? 0.0 : (x + w) * (x + w) / (4.0 * w))) * P.ell * mk;
    o.spr = 0.0; o.eb = 0.0;
    if (wantSpec) {
        // Sheen in the cross-section: a lobe in (ν − ν_H), where ν_H is the half vector's
        // angle across the fold; along the fold it is broad (fibres scatter into a cone; the
        // along falloff is per pixel). GGX-shaped, its core widened — energy kept — by the
        // normal swing across the tap, so a thin line never aliases.
        float x = snT * P.cH - o.cnT * P.sH;   // sin(ν − ν_H)
        float nl = saturate(snT * P.L.x + o.cnT * P.L.z);
        float sc2 = P.sc2 + 0.25 * dnu * dnu;
        float u2 = 1.0 + x * x / sc2;
        float lobe = sqrt(P.sc2 / sc2) / (u2 * u2);
        if (P.mat == 1) {                      // satin: + a soft, wide lobe
            float b2 = 1.0 + x * x * 6.25;     // σ ≈ 0.4
            lobe += 0.20 / (b2 * b2);
        }
        o.spr = lobe * nl;
    }
    if (P.mat == 3) {                          // lantern: back-light through the sheet
        float xb = o.cnT * P.cg + snT * P.sg, wb = 0.06 + 0.5 * dnu;
        o.eb = xb >= wb ? xb : (xb <= -wb ? 0.0 : (xb + wb) * (xb + wb) / (4.0 * wb));
    }
    return o;
}

// One tap of the cross-section at f ∈ [0, 1) (0 = ridge, 0.5 = valley; light from −f).
// Facets reuse the per-pixel shading of their two flat sides (fA lit-facing, fD turned away).
static inline Studio3Tap studio3_tap(float f, thread const Studio3P& P,
                                     thread const Studio3N& fA, thread const Studio3N& fD) {
    Studio3Tap o;
    float s = f - 0.5;                         // from the valley: < 0 faces away, > 0 faces the key
    float as = abs(s);
    Studio3N n;
    float z;
    float h = 0.5 * P.subw;
    if (as < P.Rs + h || as > 0.5 - P.Rs - h) {   // a crease (or a tap reaching into one)
        bool valley = as < 0.25;
        float r = valley ? s : s - copysign(0.5, s);
        float rc = clamp(r, -P.Rs, P.Rs);      // beyond the arc: the facet's own normal
        float c = sqrt(max(P.R2 - rc * rc, 1e-9));
        z = abs(r) <= P.Rs ? (valley ? P.zv0 - c : P.zr0 + c) : P.tb * as;
        // How far the normal swings across the tap: continuous, so it fades to nothing as
        // the tap leaves the arc (sin ν moves 1/R per unit x on the arc, not at all beyond).
        float dnu = (clamp(r + h, -P.Rs, P.Rs) - clamp(r - h, -P.Rs, P.Rs)) / c;
        n = studio3_shadeN((valley ? -rc : rc) * P.iR, c * P.iR, dnu, P, P.mat != 2);
    } else {                                   // open facet
        n = s > 0.0 ? fA : fD;
        z = P.tb * as;
    }
    // Cast shadow, downstream of the ridge's terminator.
    float vs = studio3_s01((f - P.xsh) * P.ipen + 0.5);
    vs = max(vs, 1.0 - studio3_s01((f - P.Tx) * P.igate + 0.5));
    float vis = 1.0 - P.kE * (1.0 - vs);
    o.key = n.lam * vis;

    // Sky: hemispherical, occluded down in the fold.
    float dz = 1.0 - saturate(z * P.iH);
    o.sky = (0.5 + 0.5 * n.cnT) * (1.0 - P.aoK * dz * dz);
    // Bounce from the facing facet: the turned-away facet sees the lit one across the V,
    // more of it the deeper it sits.
    float wa = studio3_s01(s * P.iwa + 0.5);
    o.bounce = P.sb * dz * dz * 1.6 * mix(P.Easc, P.Edesc, wa);

    float ridgeW = 1.0 - studio3_s01((min(f, 1.0 - f) - P.rw0) * P.irw);
    // Paper: the hairline lives on the burnished ridge; satin shines everywhere.
    o.spec = n.spr * vis * (P.mat == 1 ? 1.0 : 0.12 + 0.88 * ridgeW);

    // Translucency.
    o.trans = 0.0;
    if (P.mat == 0) {                          // light through the crest into the shadow side
        // (rising from nothing at the crest, so the two sides of a ridge meet without a step)
        o.trans = studio3_s01(f * P.iglow) * exp2(-f * 32.0) * (1.0 - wa) * P.Easc;
    } else if (P.mat == 3) {                   // lantern: lit from behind; creases go dark
        float valleyW = 1.0 - studio3_s01((as - P.rw0) * P.irw);
        o.trans = n.eb * (1.0 - 0.85 * ridgeW) * (1.0 - 0.35 * valleyW);
    }
    return o;
}

static inline void studio3_acc(thread Studio3Tap& a, Studio3Tap b, float w) {
    a.key += b.key * w; a.sky += b.sky * w; a.bounce += b.bounce * w;
    a.spec += b.spec * w; a.trans += b.trans * w;
}

// Distance (in φ, periodic) from f to x.
static inline float studio3_pd(float f, float x) {
    float d = abs(f - x);
    return min(d, 1.0 - d);
}

static inline float3 studio3_pleats(float2 px, float2 res, float t, constant FXUniforms& u) {
    float N = clamp(u.p0.x, 20.0, 120.0);
    float depth = saturate(u.p0.y), breathe = saturate(u.p0.z), speed = clamp(u.p0.w, 0.0, 2.0);
    int mat = int(clamp(floor(u.p1.x + 0.5), 0.0, 3.0));
    float focus = saturate(u.p1.z);
    bool live = u.p1.w > 0.5 && u.sky.y > 0.5;

    // Time: every motion runs a whole number of cycles per hour, so the hourly wrap is seamless.
    float tau = fmod(max(t, 0.0), 3600.0) / 3600.0;
    float phB = 6.2831853 * fract(tau * round(120.0 * speed));   // compression wave, 30 s
    float phD = 6.2831853 * fract(tau * round(6.0 * speed));     // composition drift, 600 s
    float sD = sin(phD), cD = cos(phD);

    // ---- the warped field and its analytic gradient ----------------------------------
    float sPh = 0.9 + 0.55 * sD;
    float sAmp = 0.042 * (1.0 + 0.18 * (sD * -0.505 + cD * 0.863));    // sin(phD + 2.1)
    float g = -0.294 * (1.0 + 0.22 * (sD * -0.490 + cD * -0.872));     // fan, sin(phD + 4.2): wider left
    float2 o1 = float2(3.1, 7.7) + 0.35 * float2(cD, sD);
    float W0 = 1.6 / N;
    const float kap = 0.30;
    const float2 A0 = float2(0.9659258, -0.2588190);              // folds lean 15° off vertical
    const float2 B0 = float2(0.2588190, 0.9659258);

    float2 q = (px - 0.5 * res) / res.y;
    float yu = -q.y;
    float m = 1.0 / (1.0 - kap * yu);                             // the top of the sheet is farther
    float2 Ps = float2(q.x, yu) * m;
    float b = dot(Ps, B0);
    float sArg = 5.0265 * b + sPh;                                // one large S-bend
    float3 n1g = studio3_gnd(Ps * 1.9 + o1);                      // field noise: a gentle meander
    float a = dot(Ps, A0) + sAmp * sin(sArg) + 0.020 * n1g.x;
    float2 dadP = A0 + sAmp * 5.0265 * cos(sArg) * B0 + 0.038 * n1g.yz;
    float ega = exp(-g * a);
    float phi0 = (1.0 - ega) / (g * W0);                          // pleat width W0·e^{g·a}
    // ∂P/∂px: x → (m, 0)/res.y ; y (down) → −(q.x·κ·m², m²)/res.y
    float2 gpx = (ega / (W0 * res.y)) * float2(dadP.x * m, -(dadP.x * q.x * kap + dadP.y) * m * m);
    float fw = max(length(gpx), 1e-6);                            // pleats per pixel
    float2 A = float2(gpx.x, -gpx.y) / fw;                        // across, screen y-up
    float2 B = float2(-A.y, A.x);                                 // along

    // The compression wave rolls across the folds (and gives them a hair of lateral play).
    float wph = phB - 0.184800 * phi0 + 0.5 * sin(b * 2.4 + 0.7);  // 34 pleats per wave
    float wv = sin(wph);
    float phi = phi0 + 0.12 * breathe * cos(wph);

    // Per-pleat irregularity: smooth 1-D noise along φ (never per-pleat hashes, which step),
    // wandering along each fold with the field noise.
    float2 nd = studio3_n1d(phi * 0.43 + 1.7 * n1g.x + 11.0);
    float n1 = 2.0 * nd.x, n3 = clamp(0.6 * nd.y, -1.0, 1.0);

    Studio3P P;
    P.mat = mat;
    float d0 = mix(0.10, 1.15, depth);
    float tb0 = d0 * (15.0 - d0 * d0) / (15.0 - 6.0 * d0 * d0);   // tan (Padé)
    float sb0 = tb0 * rsqrt(1.0 + tb0 * tb0);
    float tb = tb0 * (1.0 + 0.5 * breathe * wv) * (1.0 + 0.06 * n1) * (1.0 + 0.14 * n1g.x);
    tb = max(tb, 0.02);
    float ib = rsqrt(1.0 + tb * tb);
    P.tb = tb; P.sb = tb * ib; P.cb = ib; P.H = 0.5 * tb; P.iH = 2.0 / tb;
    float Rm = mat == 1 ? 0.12 : (mat == 2 ? 0.15 : (mat == 3 ? 0.07 : 0.11));   // linen folds softly
    P.R0 = Rm * (1.0 + 0.2 * n3);
    P.aoK = 0.75 * P.sb;

    // ---- light ----------------------------------------------------------------------
    float thetaDeg = clamp(u.p1.y, -90.0, 90.0), e0 = 0.349;      // 20°
    float3 keyLin = studio3_lin(u.colorB.rgb);
    float keyI = 1.0, skyI = 1.0, expo = 1.0;
    if (live) {
        float sunEl = u.sun.x;
        float thSun = clamp(u.sun.y / max(u.sun.z, 0.05), -1.0, 1.0) * 75.0;  // morning from the left
        float wN = smoothstep(0.01, -0.07, sunEl);                // after sunset: a dim cool lamp
        thetaDeg = mix(thSun, 50.0, wN);
        e0 = mix(clamp(sunEl, 0.105, 0.698), 0.38, wN);
        keyLin = mix(nature_liveTint(u), float3(0.70, 0.80, 1.0), wN);
        keyI = mix(1.0, 0.20, wN);
        skyI = mix(mix(0.6, 1.0, smoothstep(0.0, 0.25, sunEl)), 0.22, wN);
        // the camera stops down under a high sun, and opens up only partly for the lamp
        expo = mix(mix(1.0, 0.72, smoothstep(0.3, 0.7, sunEl)), 1.15, wN);
    }
    float3 keyCol = keyLin / max(dot(keyLin, float3(0.2126, 0.7152, 0.0722)), 0.08);

    float th = thetaDeg * 0.0174533;
    float2 Lh = float2(sin(th), cos(th));                         // toward the key, screen y-up
    const float Dl = 2.4;
    float zL = Dl * e0 * (15.0 - e0 * e0) / (15.0 - 6.0 * e0 * e0);   // tan (Padé)
    float2 dv = Lh * Dl - Ps;
    float ir = rsqrt(dot(dv, dv) + zL * zL);
    float3 L3 = float3(dv, zL) * ir;
    // Light pool: inverse square from the lamp, aimed into the third of the frame on its side.
    float3 axis = float3(Lh * (0.45 - Dl), -zL);
    float ca = dot(-L3, axis) * rsqrt(dot(axis, axis));
    float pool = (Dl * Dl + zL * zL) * ir * ir * mix(0.40, 1.25, exp2((ca - 1.0) * 130.0));

    // Pleat frame, mirrored so the key always arrives from −φ.
    float La = dot(L3.xy, A), Lb = dot(L3.xy, B);
    float mir = La > 0.0 ? -1.0 : 1.0;
    La *= mir;
    float iell = rsqrt(La * La + L3.z * L3.z);
    P.ell = 1.0 / iell;
    P.se = L3.z * iell; P.ce = max(-La * iell, 1e-3);
    P.L = float3(La, Lb, L3.z);
    float3 V3 = normalize(float3(-q.x * 0.30, -0.32 - yu * 0.22, 1.0));
    float3 Vp = float3(dot(V3.xy, A) * mir, dot(V3.xy, B), V3.z);
    P.h = normalize(P.L + Vp);
    float kp = -Vp.x / Vp.z;                                      // parallax across the folds
    P.kH = kp * P.H; P.iD = 1.0 / (1.0 - kp * tb); P.iA = 1.0 / (1.0 + kp * tb);
    P.sigL = live ? 0.02 : 0.035;
    float ice = 1.0 / P.ce;
    float te = P.se * ice;
    P.te = te; P.iteb = 1.0 / (te + tb);
    P.isb = 1.0 / P.sb; P.icb = 1.0 / ib;
    P.kE = saturate((tb - te) * 12.0);                            // the ridge casts a shadow
    float xs = tb * P.iteb;                                       // 2H/(tan e + tan β), sharp ridge
    float sEB = P.se * P.cb + P.ce * P.sb;
    P.penK = 2.0 * P.sigL * P.cb * ice / max(sEB, 0.2);
    float sEmB = P.se * P.cb - P.ce * P.sb;
    P.Easc = P.ell * max(sEB, 0.0) * saturate((1.0 - xs) * 2.0);
    P.Edesc = P.ell * (sEmB >= 0.03 ? sEmB : (sEmB <= -0.03 ? 0.0 : (sEmB + 0.03) * (sEmB + 0.03) * 8.333));
    float ihz = rsqrt(P.h.x * P.h.x + P.h.z * P.h.z);
    P.sH = P.h.x * ihz; P.cH = P.h.z * ihz;
    P.sc2 = mat == 1 ? 0.0100 : 0.0064;                           // core σ: satin 0.10, paper 0.08
    float hbK = 1.0 / (1.0 + P.h.y * P.h.y * (mat == 1 ? 2.5 : 4.0));   // broad along the fold
    P.sg = 0.6816; P.cg = 0.7317;                                 // γ = 0.75: the lamp sits behind, key side

    // ---- depth of field + footprint ----------------------------------------------------
    float ramp = saturate((yu + 0.17) * 1.4925);
    float coc = focus * 0.032 * res.y * ramp * sqrt(ramp);        // px; the bottom third is sharp
    float blurPx = sqrt(1.5625 + 0.75 * coc * coc);
    float fwF = fw * blurPx;                                      // filter width in pleats

    // ---- microtexture (material coordinates, fades by footprint) ------------------------
    float mu = phi, mv = b / W0;
    float fuv = max(fw, m / (W0 * res.y)) * blurPx;               // texture units per pixel
    float3 alb = studio3_lin(u.colorA.rgb);
    float albK = 1.0, dnu, dbt = 0.0, specK = 1.0, transK = 1.0;
    dnu = 0.04 * nd.y * n1g.z;                                    // gentle cockle along each fold
    if (mat == 0 || mat == 3) {                                   // paper: formation + tooth
        float tf = 1.0 - smoothstep(0.20, 0.42, fuv * 5.0);
        float3 h1 = tf > 0.0 ? studio3_gnd(float2(mu * 4.8 + mv * 1.4, mv * 4.8 - mu * 1.4) + 3.7) : float3(0.0);
        float2 tilt = 0.009 * 5.0 * h1.yz * tf;
        dnu -= tilt.x; dbt = -tilt.y;
        albK = 1.0 + 0.04 * h1.x * tf + 0.03 * n1g.x;
        // seen through, paper shows its formation: fibre clouds, much stronger than in reflection
        transK = 1.0 + (0.32 * h1.x + 0.10 * nd.x) * (0.4 + 0.6 * tf) + 0.12 * n1g.x;
    } else if (mat == 2) {                                        // linen: plain weave with slubs
        float wf = 1.0 - smoothstep(0.20, 0.42, fuv * 7.0);
        if (wf > 0.0) {
            float2 c = float2(mu, mv) * 7.0;
            float2 fl = floor(c);
            float sx = sin(STUDIO3_PI * c.x), cx = cos(STUDIO3_PI * c.x);
            float sy = sin(STUDIO3_PI * c.y), cy = cos(STUDIO3_PI * c.y);
            float pU = fmod(abs(fl.x), 2.0) < 0.5 ? 1.0 : -1.0;   // (−1)^floor
            float pV = fmod(abs(fl.y), 2.0) < 0.5 ? 1.0 : -1.0;
            float slU = 0.85 + 0.6 * studio3_n1d(c.y * 0.23 + fl.x * 7.13).x;   // slubs along warp
            float slV = 0.85 + 0.6 * studio3_n1d(c.x * 0.23 + fl.y * 5.71 + 3.0).x;
            // Thread cross-sections sin² (flat at the gaps, so height and slope stay continuous
            // where a thread ends and its neighbour's slub begins); warp and weft trade places
            // under a soft max, never a hard switch.
            float wx = sx * sx * slU, wy = sy * sy * slV;
            float ow = pU * sy, of = -pV * sx;                    // over / under
            float hw = wx * (0.62 + 0.38 * ow), hf = wy * (0.62 + 0.38 * of);
            float2 gw = float2(STUDIO3_PI * 2.0 * sx * cx * slU * (0.62 + 0.38 * ow),
                               wx * 0.38 * pU * STUDIO3_PI * cy);
            float2 gf = float2(wy * 0.38 * -pV * STUDIO3_PI * cx,
                               STUDIO3_PI * 2.0 * sy * cy * slV * (0.62 + 0.38 * of));
            float tw = studio3_s01((hw - hf) * 3.0 + 0.5);
            float hC = mix(hf, hw, tw);
            float2 gh = mix(gf, gw, tw) * 7.0;                    // per pleat width
            albK = 1.0 + wf * (0.08 * (hC - 0.45) + 0.05 * mix(slV, slU, tw) - 0.042);
            dnu -= 0.008 * wf * gh.x; dbt = -0.008 * wf * gh.y;
        }
        albK += 0.03 * n1g.x;
    } else {                                                      // satin: fine streaks in the sheen
        float sf = 1.0 - smoothstep(0.15, 0.40, fuv * 23.0);
        float s1 = studio3_n1d(mu * 23.0 + 0.9 * sin(mv * 0.11)).x * 1.6 * sf;
        float sS = studio3_n1d(mu * 0.37 + mv * 0.045 + 9.0).x * 1.6;   // slow watering of the sheen
        specK = 1.0 + 0.25 * s1 + 0.18 * sS;
        dnu += 0.03 * s1;
        albK = 1.0 + 0.04 * sS;
    }
    dnu *= mir;
    P.sdn = dnu; P.cdn = 1.0 - 0.5 * dnu * dnu;                   // small angles
    P.xb = Lb * dbt * iell;

    // ---- filter ------------------------------------------------------------------------
    Studio3Tap acc = {0.0, 0.0, 0.0, 0.0, 0.0};
    float fm = mir * phi;
    float wAvg = smoothstep(0.45, 0.65, fwF);
    // The two flat facets (paper's hairline is negligible this far from its crease — under
    // 0.001 — so only satin shines on open facet).
    Studio3N fA = studio3_shadeN(-P.sb, P.cb, 0.0, P, mat == 1);
    Studio3N fD = studio3_shadeN(P.sb, P.cb, 0.0, P, mat == 1);
    // Three estimates of the box-filtered profile, blended by footprint (never switched, so a
    // pixel can't pop between them as the folds breathe):
    //  0 · fine — a crease spans several footprints (high resolution, in focus): one tap
    //      pre-filtered over the whole footprint is already a box filter (the terminator, the
    //      sheen width and the penumbra widen by what the footprint sweeps);
    //  1 · four taps across the footprint, each pre-filtered over its quarter — or one on open
    //      facet, where nothing inside the footprint bends;
    //  2 · beyond about half a pleat per footprint, the φ-independent period average.
    float fwT = min(fwF, 0.75);
    float thr = 0.42 * Rm * sb0;                                  // static, so the blend never flickers
    float wF = (1.0 - wAvg) * smoothstep(1.2 * thr, 0.8 * thr, fwT);
    float wQ = (1.0 - wAvg) - wF;
    for (int pass = 0; pass < 3; ++pass) {
        float pw = pass == 0 ? wF : (pass == 1 ? wQ : wAvg);
        if (pw <= 0.0) continue;
        studio3_prep(P, pass == 0 ? fwT : (pass == 1 ? 0.25 * fwT : 0.1667));
        int nT = 1;
        float fs = fm, stp = 0.0;
        if (pass == 1) {
            float f0 = studio3_par(fm, P);
            float hw = (0.5 * fwT + 0.006) * max(P.iD, P.iA);     // footprint in profile units
            bool open = studio3_pd(f0, 0.0) > P.Rs + 0.025 + hw
                     && studio3_pd(f0, 0.5) > P.Rs + 0.035 + hw
                     && (P.kE <= 0.0 || abs(f0 - P.xsh) > 0.5 / P.ipen + hw);
            if (!open) { nT = 4; stp = 0.25 * fwT; fs = fm - 0.375 * fwT; }
        } else if (pass == 2) {
            nT = 6; stp = 0.1667; fs = 0.0833;
        }
        float wt = pw / float(nT);
        for (int k = 0; k < nT; ++k) {
            studio3_acc(acc, studio3_tap(studio3_par(fs + stp * float(k), P), P, fA, fD), wt);
        }
    }

    // ---- light it ------------------------------------------------------------------------
    float3 albT = alb * albK;
    float3 skyCol = float3(0.62, 0.74, 1.0) * 0.16 * skyI;
    const float keyAmt = 1.6, bounceK = 0.38;
    float3 col;
    if (mat == 3) {                                               // lantern at dusk: dim front, lit behind
        // Dusk outside: a faint cool key and blue-hour sky on the front. The lamp inside is the
        // light: it reaches the eye through the paper, tinted warm by the fibres (alb²) — the
        // facets turned toward it glow, the others and the doubled creases stay dim.
        float3 front = mix(keyCol, float3(0.80, 0.86, 1.0), 0.6) * (keyI * pool * 0.05 * keyAmt);
        col = albT * (front * (acc.key + bounceK * albT * acc.bounce) + skyCol * 0.45 * acc.sky);
        col += front * 0.04 * acc.spec;
        float3 tint = alb * alb / max(dot(alb * alb, float3(0.2126, 0.7152, 0.0722)), 0.02);
        float3 lamp = studio3_lin(u.colorB.rgb);                  // its own lamp, whatever the sky does
        lamp /= max(dot(lamp, float3(0.2126, 0.7152, 0.0722)), 0.08);
        float3 trans = mix(float3(1.0), tint, 0.7) * lamp * (0.14 + 0.36 * pool);
        col += trans * (acc.trans * transK);
    } else {
        float3 E = keyCol * (keyI * pool * keyAmt);
        col = albT * (E * (acc.key + bounceK * albT * acc.bounce) + skyCol * acc.sky);
        float x5 = 1.0 - saturate(dot(Vp, P.h));
        float F = 1.0 + 6.0 * x5 * x5 * x5 * x5 * x5;               // Fresnel rise at grazing
        // Satin's floats make a bright fibre sheen (and mirror a little of the sky); paper's
        // burnished crease a faint hairline.
        float specAmt = (mat == 1 ? 0.85 : 0.07) * hbK;
        if (mat == 1) col += skyCol * (0.12 * acc.sky);
        float3 specCol = mat == 1 ? mix(float3(1.0), alb / max(max(alb.r, max(alb.g, alb.b)), 1e-3), 0.25)
                                  : float3(1.0);
        col += E * specCol * (specAmt * F * acc.spec * specK);
        if (mat == 0) col += E * alb * sqrt(alb) * (0.12 * acc.trans * transK);
    }
    // A touch of lens falloff.
    col *= (1.0 - 0.16 * dot(q, q)) * expo;
    return linearToSrgb(aces(col)) + bandDither(px) * 1.5;
}
