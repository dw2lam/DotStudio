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
//    · translucency: light through the crest of paper; a paper lantern lit from inside by a
//      lamp close behind the sheet (inverse-square hot spot, the facets whose backs face the
//      lamp glowing, the doubled creases dark);
//    · anisotropic GGX: a burnished hairline on paper creases, a sheen line + soft lobe on satin.
//  Anti-aliasing: every tap is a box over an interval of the profile — the screen interval
//  mapped through the parallax exactly — and a tap reaching into a crease is split into its arc
//  part (the normal's swing across it box-filters the terminator) and the flat parts beside it.
//  One tap covers the footprint where it is small or on open facet, four where it holds a
//  crease and a shadow edge, and the profile's four quarters give the period average below
//  ~4 px a pleat. Taps are tone-mapped one by one and averaged in display light (averaging
//  radiance first washes fine pleats out bright). The creases' sheen lines — far thinner than
//  a pixel at gallery-card size, where a box filter makes a thin line step as it crosses the
//  footprint's edge (beading, beat bands) — are not tapped at all: each is placed analytically
//  (exact energy over the arc's normals, position and height through the parallax) and drawn
//  as a band-limited bump, a smooth function of where it falls. The footprint is at least
//  1.6 px, widened by depth of field. Microtexture lives in material coordinates (φ, along)
//  and fades by footprint.

constant float STUDIO3_PI = 3.14159265;

static inline float studio3_s01(float x) { x = saturate(x); return x * x * (3.0 - 2.0 * x); }
// sRGB → linear for colour wells (cubic fit, < 0.3% error; every pixel would pay for a pow).
static inline float3 studio3_lin(float3 c) {
    c = saturate(c);
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}
// max(x, 0) box-filtered over [x − w, x + w]: a C¹ ramp, so a terminator never snaps.
static inline float studio3_ramp(float x, float w) {
    return x >= w ? x : (x <= -w ? 0.0 : (x + w) * (x + w) / (4.0 * w));
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
    float R, R2, iR, Rs; // crease radius (material), its square, inverse, and half-chord (R sin β)
    float zv0, zr0;     // crease arc centres' heights (valley, ridge)
    float sb, cb, tb;   // facet slope β
    float H, iH;        // ridge height above the valley (= tanβ / 2)
    float se, ce;       // key elevation e in the cross-section
    float ell;          // |key| projected into the cross-section
    float xb;           // along-fold microtilt × along key, in sin(e − ν) units (bounded)
    float sdn, cdn;     // across microtilt (sin, cos)
    float sigL;         // key angular radius
    float kE;           // 1 when the ridge casts a shadow (e < β), fading as e → β
    float aoK;          // valley sky occlusion
    float Easc, Edesc;  // irradiance (× key) on the lit and the turned-away facet (bounce)
    float3 L, h;        // key, half vector (pleat frame)
    float sH, cH;       // the half vector's angle in the cross-section (sin, cos)
    float sc, isc;      // sheen core width (rad) and its inverse
    float lbx, lbz;     // Lantern: toward the lamp behind the sheet, in the cross-section
    int mat;            // 0 paper, 1 satin, 2 linen, 3 lantern
    float Tx, xsh;      // the ridge's terminator (tangent point); the cast-shadow line on the lit facet
    float kH, iD, iA;   // parallax: screen phase u = x + k·z(x) → profile x (see studio3_par)
    float isb, te, iteb, penK; // per-pixel constants for studio3_prep
    // ---- per tap width
    float subw;
    float igate, ipen;  // the terminator's soft gate, 1 / cast-shadow penumbra
    float iwa;          // bounce side blend across the valley
    float rw0, irw;     // crease band (paper burnish, lantern's doubled creases)
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
    P.ipen = 1.0 / (P.penK * max(P.xsh - P.Tx, 0.0) + 1.4 * subw + 0.004);
    P.igate = 1.0 / (0.024 + subw);
    P.iwa = 1.0 / (2.0 * P.Rs + 0.06);
    P.rw0 = P.Rs; P.irw = 1.0 / (0.6 * subw + 0.015);
    P.iglow = 1.0 / (P.Rs + subw + 0.01);
}

struct Studio3Tap { float key, sky, bounce, spec, trans; };

// Shading that depends only on the normal (sin ν, cos ν) and how far it swings across the tap
// (dnu): Lambert key and the lantern's back-light (box-filtered over the light's size and the
// swing), and — on the flat facets only (dnu = 0) — the sheen lobe.
struct Studio3N { float lam, spr, eb, cnT; };
static inline Studio3N studio3_shadeN(float sn, float cn, float dnu, thread const Studio3P& P, bool wantSpec) {
    Studio3N o;
    float snT = sn * P.cdn + cn * P.sdn;       // + microtexture tilt
    o.cnT = cn * P.cdn - sn * P.sdn;
    float w = P.sigL + 0.5 * dnu;
    float x = P.se * cn - P.ce * sn;           // sin(e − ν)
    // Microtexture shades what the key lights, relative to it (its tilt moves sin(e − ν) by
    // −cos(e − ν)·δν): texture rakes across lit paper but never flips shadow into speckle, and
    // its gain is bounded, so the tooth stays fine when the key runs along the folds.
    float dx = P.xb - (P.ce * cn + P.se * sn) * P.sdn;
    float mk = 1.0 + clamp(dx / max(x, 0.3), -0.45, 0.45);
    o.lam = studio3_ramp(x, w) * P.ell * mk;
    o.spr = 0.0; o.eb = 0.0;
    if (wantSpec) {
        // Sheen in the cross-section: a lobe in (ν − ν_H), where ν_H is the half vector's
        // angle across the fold; along the fold it is broad (fibres scatter into a cone; the
        // along falloff is per pixel). GGX-shaped, 1 / (1 + x²/s²)². (On the crease arcs the
        // same lobe is a thin line, drawn analytically: studio3_bump.)
        float x = snT * P.cH - o.cnT * P.sH;   // sin(ν − ν_H)
        float nl = saturate(snT * P.L.x + o.cnT * P.L.z);
        float u2 = 1.0 + x * x * P.isc * P.isc;
        float lobe = 1.0 / (u2 * u2);
        if (P.mat == 1) {                      // satin: + a soft, wide lobe
            float b2 = 1.0 + x * x * 6.25;     // σ ≈ 0.4
            lobe += 0.20 / (b2 * b2);
        }
        o.spr = lobe * nl;
    }
    if (P.mat == 3) {                          // lantern: the lamp through the sheet, seen on
        // the facet's back: −n · (toward the lamp)
        // (plus a floor: light scattered round the inside reaches every facet's back)
        float xb = -(snT * P.lbx + o.cnT * P.lbz);
        o.eb = 0.16 + 0.84 * studio3_ramp(xb, 0.06 + 0.5 * dnu);
    }
    return o;
}

// G(t) = ∫ 1/(1 + t²)² dt: the sheen lobe's antiderivative.
static inline float studio3_G(float t) { return 0.5 * (t / (1.0 + t * t) + atan(t)); }

// Visibility of the key at profile point f (cast shadow, past the ridge's terminator).
static inline float studio3_vis(float f, thread const Studio3P& P) {
    float vs = studio3_s01((f - P.xsh) * P.ipen + 0.5);
    vs = max(vs, 1.0 - studio3_s01((f - P.Tx) * P.igate + 0.5));
    return 1.0 - P.kE * (1.0 - vs);
}

// A crease's sheen line, band-limited: energy E (exact over the arc's normals) at signed
// screen-phase distance d ∈ [−½, ½) from the pixel. Its own GGX shape (variance w²) convolved
// with the pixel's filter (variance vk) is approximated by a bump of the summed variance, shaped
// like the line where the line resolves and like a compact smooth kernel where it doesn't (so
// an unresolved line neither steps nor bleeds its tails into the dark facet beside it); it and
// the next line over, settling to the period average E as it widens past a pleat. A smooth
// function of where the line falls, however much thinner than a pixel it is.
static inline float studio3_bump(float d, float E, float w, float vk) {
    float s2 = w * w + vk, is2 = 1.0 / s2, al = w * w * is2;
    float ir2 = is2 * 0.14285714;                                  // quartic: r² = 7 s²
    float d1 = d - copysign(1.0, d);
    float t0 = d * d * is2, t1 = d1 * d1 * is2;
    float c = 1.0 / ((1.0 + t0) * (1.0 + t0)) + 1.0 / ((1.0 + t1) * (1.0 + t1));
    float q0 = max(1.0 - d * d * ir2, 0.0), q1 = max(1.0 - d1 * d1 * ir2, 0.0);
    float qn = 0.35435 * sqrt(is2);                                // 15 / (16 r)
    float v = mix((q0 * q0 + q1 * q1) * qn, c * 0.63661977 * sqrt(is2), al) * E;
    return mix(v, E, smoothstep(0.05, 0.2, s2));                   // s ≈ 0.22 … 0.45 of a pleat
}

// One tap of the cross-section: the box [f − h, f + h] of the profile (f ∈ [0, 1); 0 = ridge,
// 0.5 = valley; light from −f). Facets reuse the per-pixel shading of their two flat sides
// (fA lit-facing, fD turned away); a tap reaching into a crease is split into the arc part —
// shaded at its mid-normal with the normal's swing across it — and the flat parts either side.
static inline Studio3Tap studio3_tap(float f, float h, thread const Studio3P& P,
                                     thread const Studio3N& fA, thread const Studio3N& fD) {
    Studio3Tap o;
    float s = f - 0.5;                         // from the valley: < 0 faces away, > 0 faces the key
    float as = abs(s);
    Studio3N n;
    float z;
    if (as < P.Rs + h || as > 0.5 - P.Rs - h) {   // a crease (or a tap reaching into one)
        bool valley = as < 0.25;
        float r = valley ? s : s - copysign(0.5, s);   // across, from the crease centre
        float lo = clamp(r - h, -P.Rs, P.Rs), hi = clamp(r + h, -P.Rs, P.Rs);
        float i2h = 0.5 / h;
        float wArc = (hi - lo) * i2h;
        float wNeg = saturate((-P.Rs - (r - h)) * i2h);
        float wPos = max(1.0 - wArc - wNeg, 0.0);
        float rm = 0.5 * (lo + hi);
        float c = sqrt(max(P.R2 - rm * rm, 1e-9));
        // (no sheen on the arc part: the crease's sheen line is analytic, per pixel — see
        // studio3_bump — so it never steps as it crosses a tap edge)
        Studio3N a = studio3_shadeN((valley ? -rm : rm) * P.iR, c * P.iR, (hi - lo) / c, P, false);
        // beyond the arc: x < −Rs is the lit-facing facet at a ridge, the turned-away one in a valley
        Studio3N fN = valley ? fD : fA, fP = valley ? fA : fD;
        n.lam = wArc * a.lam + wNeg * fN.lam + wPos * fP.lam;
        n.spr = wArc * a.spr + wNeg * fN.spr + wPos * fP.spr;
        n.eb  = wArc * a.eb  + wNeg * fN.eb  + wPos * fP.eb;
        n.cnT = wArc * a.cnT + wNeg * fN.cnT + wPos * fP.cnT;
        float rc = clamp(r, -P.Rs, P.Rs);
        float cc = sqrt(max(P.R2 - rc * rc, 1e-9));
        z = abs(r) <= P.Rs ? (valley ? P.zv0 - cc : P.zr0 + cc) : P.tb * as;
    } else {                                   // open facet
        n = s > 0.0 ? fA : fD;
        z = P.tb * as;
    }
    float vis = studio3_vis(f, P);              // cast shadow, past the ridge's terminator
    o.key = n.lam * vis;

    // Sky: hemispherical, occluded down in the fold.
    float dz = 1.0 - saturate(z * P.iH);
    o.sky = (0.5 + 0.5 * n.cnT) * (1.0 - P.aoK * dz * dz);
    // Bounce from the facing facet: the turned-away facet sees the lit one across the V,
    // more of it the deeper it sits.
    float wa = studio3_s01(s * P.iwa + 0.5);
    o.bounce = P.sb * dz * dz * 1.6 * mix(P.Easc, P.Edesc, wa);

    float ridgeW = 1.0 - studio3_s01((min(f, 1.0 - f) - P.rw0) * P.irw);
    // Satin's open facets shine where the half vector lies beyond the crease's normals.
    o.spec = n.spr * vis;

    // Translucency.
    o.trans = 0.0;
    if (P.mat == 0) {                          // light through the crest into the shadow side
        // (rising from nothing at the crest, so the two sides of a ridge meet without a step)
        o.trans = studio3_s01(f * P.iglow) * exp2(-f * 32.0) * (1.0 - wa) * P.Easc;
    } else if (P.mat == 3) {                   // lantern: lit from behind; the doubled paper at
        // every crease (ridge and valley alike) stays dark
        float valleyW = 1.0 - studio3_s01((as - P.rw0) * P.irw);
        o.trans = n.eb * (1.0 - 0.82 * max(ridgeW, valleyW));
    }
    return o;
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
    // A slow camera drift over the sheet (a gentle ellipse, one per 600 s at speed 1: about
    // a pixel a second at 1000 px tall), the light and the lantern's lamp travelling with it.
    float2 Ps = float2(q.x, yu) * m + float2(0.10 * sD, 0.045 * (cD * 0.8 - sD * 0.6));
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
    float phi = phi0 + 0.16 * breathe * cos(wph);

    // Per-pleat irregularity: smooth 1-D noise along φ (never per-pleat hashes, which step),
    // wandering along each fold with the field noise.
    float2 nd = studio3_n1d(phi * 0.43 + 1.7 * n1g.x + 11.0);
    float n1 = 2.0 * nd.x, n3 = clamp(0.6 * nd.y, -1.0, 1.0);

    Studio3P P;
    P.mat = mat;
    float d0 = mix(0.10, 1.15, depth);
    float tb0 = d0 * (15.0 - d0 * d0) / (15.0 - 6.0 * d0 * d0);   // tan (Padé)
    float sb0 = tb0 * rsqrt(1.0 + tb0 * tb0);
    float tb = tb0 * (1.0 + 0.6 * breathe * wv) * (1.0 + 0.06 * n1) * (1.0 + 0.14 * n1g.x);
    tb = max(tb, 0.02);
    float ib = rsqrt(1.0 + tb * tb);
    P.tb = tb; P.sb = tb * ib; P.cb = ib; P.H = 0.5 * tb; P.iH = 2.0 / tb;
    P.isb = 1.0 / P.sb;
    float Rm = mat == 1 ? 0.12 : (mat == 2 ? 0.15 : (mat == 3 ? 0.07 : 0.11));   // linen folds softly
    float R = clamp(Rm * (1.0 + 0.2 * n3), 1e-4, 0.24 * P.isb);
    P.R = R; P.R2 = R * R; P.iR = 1.0 / R; P.Rs = R * P.sb;
    P.zv0 = R / ib; P.zr0 = P.H - P.zv0;
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
    P.kE = saturate((tb - te) * 12.0);                            // the ridge casts a shadow
    float xs = tb * P.iteb;                                       // 2H/(tan e + tan β), sharp ridge
    float sEB = P.se * P.cb + P.ce * P.sb;
    P.penK = 2.0 * P.sigL * P.cb * ice / max(sEB, 0.2);
    // Tangent point of the shadow line on the ridge arc (normal at min(e, β)), then where the
    // line (slope −tan e) meets the lit facet z = tan β·(x − ½); its penumbra is the light's
    // angular size × the ridge's distance, across the facet (penK = 2σ·cos β / sin(e + β) / cos e).
    {
        bool eLow = P.kE > 0.0;
        float sec = eLow ? P.se : P.sb, cec = eLow ? P.ce : P.cb;
        P.Tx = R * sec;
        float Ty = P.zr0 + R * cec;
        P.xsh = (Ty + te * P.Tx + 0.5 * tb) * P.iteb;
    }
    float sEmB = P.se * P.cb - P.ce * P.sb;
    P.Easc = P.ell * max(sEB, 0.0) * saturate((1.0 - xs) * 2.0);
    P.Edesc = P.ell * (sEmB >= 0.03 ? sEmB : (sEmB <= -0.03 ? 0.0 : (sEmB + 0.03) * (sEmB + 0.03) * 8.333));
    float ihz = rsqrt(P.h.x * P.h.x + P.h.z * P.h.z);
    P.sH = P.h.x * ihz; P.cH = P.h.z * ihz;
    P.sc = mat == 1 ? 0.10 : 0.08; P.isc = 1.0 / P.sc;             // core σ: satin 0.10, paper 0.08
    float hbK = 1.0 / (1.0 + P.h.y * P.h.y * (mat == 1 ? 2.5 : 4.0));   // broad along the fold

    // Lantern: the lamp hangs a short way behind the sheet, on the light angle's side of the
    // frame. Inverse square from it (1 at the hot spot); the cos at each facet's back is per tap.
    float lampE = 0.0;
    P.lbx = 0.0; P.lbz = -1.0;
    if (mat == 3) {
        float thL = clamp(u.p1.y, -90.0, 90.0) * 0.0174533;   // the lamp stays put when Live
        float sL = sin(thL);
        float2 hot = float2(0.48 * sL, 0.04 - 0.10 * sL * sL);
        const float DL = 0.38;
        float2 dl = hot - Ps;
        float d2 = dot(dl, dl) + DL * DL;
        float il = rsqrt(d2);
        P.lbx = dot(dl, A) * mir * il; P.lbz = -DL * il;
        lampE = DL * DL / d2;
    }

    // ---- depth of field + footprint ----------------------------------------------------
    float ramp = saturate((yu + 0.17) * 1.4925);
    float coc = focus * 0.032 * res.y * ramp * sqrt(ramp);        // px; the bottom third is sharp
    float blurPx = sqrt(2.56 + 0.75 * coc * coc);                 // ≥ 1.6 px
    float fwF = fw * blurPx;                                      // filter width in pleats

    // ---- microtexture (material coordinates, fades by footprint) ------------------------
    float mu = phi, mv = b / W0;
    float fuv = max(fw, m / (W0 * res.y)) * blurPx;               // texture units per filter
    float3 alb = studio3_lin(u.colorA.rgb);
    float albK = 1.0, dnu, dbt = 0.0, specK = 1.0, transK = 1.0;
    dnu = 0.04 * nd.y * n1g.z;                                    // gentle cockle along each fold
    if (mat == 0 || mat == 3) {
        // Paper. Formation: soft fibre clouds a few to the pleat, in the albedo and — much
        // stronger — seen through. Tooth: fine relief, ~26 to the pleat, raking across the lit
        // facets where the screen resolves it.
        float3 hF = studio3_gnd(float2(mu * 4.6 + mv * 1.3, mv * 4.6 - mu * 1.3) + 3.7);
        float tf = 1.0 - smoothstep(0.25, 0.5, fuv * 26.0);
        if (tf > 0.0) {
            float2 tilt = 0.032 * tf * studio3_gnd(float2(mu * 26.0 + mv * 7.0, mv * 26.0 - mu * 7.0) + 5.3).yz;
            dnu -= tilt.x; dbt = -tilt.y;
        }
        albK = 1.0 + 0.035 * hF.x + 0.03 * n1g.x;
        // seen through, paper shows its formation: fibre clouds, much stronger than in reflection
        transK = 1.0 + 0.20 * hF.x + 0.08 * nd.x;
    } else if (mat == 2) {
        // Linen: ~40 threads to the pleat. Slubs — thicker runs of yarn a few threads wide and
        // tens long, in the warp (along the folds) and the weft (across) — lift and catch the
        // rake: the cue that reads as linen from across the room. Where the screen resolves the
        // threads, the plain weave's over-under bumps, then the grooves between threads.
        const float NT = 40.0;
        float sk = NT / 3.5, sl = NT / 45.0;                      // slub cells: 3.5 threads × 45
        float slf = 1.0 - smoothstep(0.35, 0.75, fuv * sk);
        float2 tilt = float2(0.0);
        float slub = 0.0;
        if (slf > 0.0) {
            // thick-thin yarn: slubs swell (lighter, raised), thin runs sink (darker)
            float3 nw = studio3_gnd(float2(mu * sk, mv * sl) + float2(2.3, 8.1));
            float3 nf = studio3_gnd(float2(mu * sl, mv * sk) + float2(6.7, 1.4));
            float xw = saturate((nw.x - 0.04) * 3.0), yw = saturate((-nw.x - 0.22) * 3.0);
            float xf = saturate((nf.x - 0.08) * 3.0), yf = saturate((-nf.x - 0.26) * 3.0);
            float hw = xw * xw * (3.0 - 2.0 * xw) - 0.6 * yw * yw * (3.0 - 2.0 * yw);
            float hf = xf * xf * (3.0 - 2.0 * xf) - 0.6 * yf * yf * (3.0 - 2.0 * yf);
            float dw = 18.0 * (xw * (1.0 - xw) + 0.6 * yw * (1.0 - yw));   // d h / d noise
            float df = 18.0 * (xf * (1.0 - xf) + 0.6 * yf * (1.0 - yf));
            tilt += 0.0020 * slf * (dw * nw.yz * float2(sk, sl) + df * nf.yz * float2(sl, sk));
            slub = slf * (hw + hf);
        }
        float2 c = float2(mu, mv) * NT;
        float fa = 1.0 - smoothstep(0.30, 0.55, fuv * NT * 0.71);
        float wvA = 0.0;
        if (fa > 0.0) {
            float sx = sin(STUDIO3_PI * c.x), cx = cos(STUDIO3_PI * c.x);
            float sy = sin(STUDIO3_PI * c.y), cy = cos(STUDIO3_PI * c.y);
            // over-under: warp and weft swap at every crossing (a checker of bumps)
            tilt += 0.030 * fa * STUDIO3_PI * float2(cx * sy, sx * cy);
            float fb = 1.0 - smoothstep(0.30, 0.55, fuv * NT);
            // the grooves between threads, both ways
            tilt += 0.022 * fb * STUDIO3_PI * float2(2.0 * sx * cx, 2.0 * sy * cy);
            wvA = fa * (0.5 * sx * sy * sx * sy - 0.125 + 0.5 * fb * (sx * sx + sy * sy - 1.0));   // zero-mean
        }
        dnu -= tilt.x; dbt = -tilt.y;
        albK = 0.97 + 0.09 * (slub - 0.2 * slf) + 0.05 * wvA + 0.03 * n1g.x + 0.025 * nd.x;
    } else {                                                      // satin: fine streaks in the sheen
        float sf = 1.0 - smoothstep(0.15, 0.40, fuv * 23.0);
        float s1 = sf > 0.0 ? studio3_n1d(mu * 23.0 + 2.2 * n1g.x).x * 1.6 * sf : 0.0;
        // a slow watering of the sheen, wandering with the field, faded where the blur spans it
        float wf = 1.0 - smoothstep(0.25, 0.9, fuv * 0.4);
        float sS = studio3_n1d(mu * 0.34 + mv * 0.05 + 1.6 * n1g.x + 9.0).x * 2.0 * wf;
        specK = 1.0 + 0.25 * s1 + 0.12 * sS;
        dnu += 0.03 * s1;
        albK = 1.0 + 0.03 * sS;
    }
    dnu *= mir;
    P.sdn = dnu; P.cdn = 1.0 - 0.5 * dnu * dnu;                   // small angles
    // along-fold tilt over the key's share in the cross-section — bounded, or a key running
    // along the folds (ell → small) would blow the tooth up into a coarse relief
    P.xb = clamp(Lb * dbt * iell, -0.12, 0.12);

    // The two flat facets (paper's hairline is negligible this far from its crease — under
    // 0.001 — so only satin shines on open facet).
    Studio3N fA = studio3_shadeN(-P.sb, P.cb, 0.0, P, mat == 1);
    Studio3N fD = studio3_shadeN(P.sb, P.cb, 0.0, P, mat == 1);

    // ---- the creases' sheen lines (paper's burnished hairline, satin's sheen) -------------
    // On a crease arc the normal sweeps [−β, β]; the lobe peaks where it meets the half vector
    // (less the microtilt), on the ridge and in the valley. Energy over the arc in closed form;
    // position and height on the arc through the parallax to screen phase; the cast shadow at
    // the line; then a band-limited bump at the pixel (studio3_bump), added to every tap.
    float lineSpec = 0.0;
    float fwT = min(fwF, 0.75);
    float fm = mir * phi;
    if (mat <= 1) {
        // the half vector's angle across the fold, less the microtilt, as (sin, cos) — then its
        // spot on the arc (clamped to the arc's normals ±β) and the lobe's argument
        // sin(±β − ν_H) at the arc's two ends: no trig but the antiderivative's atan
        float sh = P.sH * P.cdn - P.cH * P.sdn, ch = P.cH * P.cdn + P.sH * P.sdn;
        float sC = clamp(sh, -P.sb, P.sb), cC = sqrt(1.0 - sC * sC);
        float xHi = P.sb * ch - P.cb * sh, xLo = -P.sb * ch - P.cb * sh;
        float nl = saturate(P.sH * P.L.x + P.cH * P.L.z);
        float k0 = nl * R * cC;
        float E = k0 * P.sc * (studio3_G(xHi * P.isc) - studio3_G(xLo * P.isc));
        float sk = 0.0833 * fwF * fwF;                            // the footprint's variance (box)
        float rr = R * sC, hh = R * cC;
        // the ridge (f = 0 ≡ 1) and the valley (f = ½): position, height → screen phase
        float fR = rr - floor(rr), fV = 0.5 - rr;
        float uR = fR + kp * (P.zr0 + hh), uV = fV + kp * (P.zv0 - hh);
        float wC = P.sc * R * cC;
        float dR = fm - uR;
        dR -= floor(dR + 0.5);
        // the cast shadow at the lines (only its footprint-wide softening is needed here)
        P.ipen = 1.0 / (P.penK * max(P.xsh - P.Tx, 0.0) + 1.4 * fwT + 0.004);
        P.igate = 1.0 / (0.024 + fwT);
        float vR = studio3_vis(fR, P);
        lineSpec = vR * studio3_bump(dR, E, wC, sk);
        if (mat == 1) {
            // satin: the soft, wide lobe too, and the valley's line (paper's valley is matte)
            float E2 = k0 * 0.08 * (studio3_G(xHi * 2.5) - studio3_G(xLo * 2.5));
            float wW = 0.4 * R * cC;
            float dV = fm - uV;
            dV -= floor(dV + 0.5);
            lineSpec += vR * studio3_bump(dR, E2, wW, sk);
            float vV = studio3_vis(fV, P);                        // (the valley is often in shadow)
            if (vV > 0.002) lineSpec += vV * (studio3_bump(dV, E, wC, sk) + studio3_bump(dV, E2, wW, sk));
        }
    }

    // ---- light it: each tap's colour is linear in its five terms ------------------------
    // (taps are tone-mapped one by one and averaged in display light — what the eye averages
    // over stripes too fine to see; averaging radiance first would wash fine pleats out bright)
    float3 albT = alb * albK;
    float3 skyCol = float3(0.62, 0.74, 1.0) * 0.16 * skyI;
    const float keyAmt = 1.6, bounceK = 0.38;
    float lens = (1.0 - 0.16 * dot(q, q)) * expo;                // a touch of lens falloff
    float3 cKey, cBounce, cSky, cSpec, cTrans;
    if (mat == 3) {                                               // lantern at dusk: dim front, lit inside
        // Dusk outside: a faint cool key and the blue-hour sky on the front. The lamp inside is
        // the light: it reaches the eye through the paper, tinted warm by the fibres (alb²) —
        // brightest round the hot spot, on the facets whose backs face the lamp; the creases,
        // where the paper doubles, stay dark.
        float3 front = mix(keyCol, float3(0.70, 0.80, 1.0), 0.7) * (keyI * pool * 0.03 * keyAmt);
        cKey = albT * front; cBounce = cKey * bounceK * albT; cSky = albT * skyCol * 0.32;
        cSpec = float3(0.0);
        float3 tint = alb * alb / max(dot(alb * alb, float3(0.2126, 0.7152, 0.0722)), 0.02);
        float3 lamp = studio3_lin(u.colorB.rgb);                  // its own lamp, whatever the sky does
        lamp /= max(dot(lamp, float3(0.2126, 0.7152, 0.0722)), 0.08);
        // the glow inside the lantern: the lamp's inverse square, steepened by the sheet curving
        // away from it, plus a little light scattered round the inside
        float glow = 3.0 * lampE * lampE * sqrt(lampE) + 0.006;
        cTrans = mix(float3(1.0), tint, 0.75) * lamp * (glow * transK);
    } else {
        float3 E = keyCol * (keyI * pool * keyAmt);
        cKey = albT * E; cBounce = cKey * bounceK * albT;
        // satin's floats mirror a little of the sky
        cSky = albT * skyCol + (mat == 1 ? skyCol * 0.12 : float3(0.0));
        float x5 = 1.0 - saturate(dot(Vp, P.h));
        float F = 1.0 + 6.0 * x5 * x5 * x5 * x5 * x5;               // Fresnel rise at grazing
        // Satin's floats make a bright fibre sheen; paper's burnished crease a faint hairline.
        float specAmt = (mat == 1 ? 0.85 : (mat == 0 ? 0.07 : 0.0)) * hbK;
        float3 specCol = mat == 1 ? mix(float3(1.0), alb / max(max(alb.r, max(alb.g, alb.b)), 1e-3), 0.25)
                                  : float3(1.0);
        cSpec = E * specCol * (specAmt * F * specK);
        cTrans = mat == 0 ? E * alb * sqrt(alb) * (0.12 * transK) : float3(0.0);
    }
    cKey *= lens; cBounce *= lens; cSky *= lens; cSpec *= lens; cTrans *= lens;

    // ---- filter ------------------------------------------------------------------------
    float3 acc = float3(0.0);
    float wAvg = smoothstep(0.40, 0.65, fwF);
    // Three estimates of the box-filtered profile, blended by footprint (never switched, so a
    // pixel can't pop between them as the folds breathe):
    //  0 · fine — the footprint is small beside a crease: one tap over all of it;
    //  1 · four taps across the footprint — or one on open facet, where nothing in it bends;
    //  2 · below ~4 px a pleat, the φ-independent period average: the profile's four quarters.
    float thr = 0.42 * Rm * sb0;                                  // static, so the blend never flickers
    float wF = (1.0 - wAvg) * smoothstep(1.2 * thr, 0.8 * thr, fwT);
    float wQ = (1.0 - wAvg) - wF;
    for (int pass = 0; pass < 2; ++pass) {
        float pw = pass == 0 ? wF : wQ;
        if (pw <= 0.0) continue;
        int nT = 1;
        float du = fwT;
        if (pass == 1) {
            studio3_prep(P, 0.25 * fwT);
            float f0 = studio3_par(fm, P);
            float hw = (0.5 * fwT + 0.006) * max(P.iD, P.iA);     // footprint in profile units
            bool open = studio3_pd(f0, 0.0) > P.Rs + 0.025 + hw
                     && studio3_pd(f0, 0.5) > P.Rs + 0.035 + hw
                     && (P.kE <= 0.0 || abs(f0 - P.xsh) > 0.5 / P.ipen + hw);
            if (!open) { nT = 4; du = 0.25 * fwT; }
            else studio3_prep(P, fwT);
        } else {
            studio3_prep(P, fwT);
        }
        float wt = pw / float(nT);
        // Each tap: the screen interval [u, u + du] mapped through the parallax to the profile.
        float u0 = fm - 0.5 * fwT;
        float xl = studio3_par(u0, P);
        for (int k = 0; k < nT; ++k) {
            float xr = studio3_par(u0 + du * float(k + 1), P);
            float xe = xr < xl ? xr + 1.0 : xr;                   // the interval crosses the ridge
            float xc = 0.5 * (xl + xe);
            Studio3Tap tp = studio3_tap(xc - floor(xc), max(0.5 * (xe - xl), 1e-5), P, fA, fD);
            float3 c = cKey * tp.key + cBounce * tp.bounce + cSky * tp.sky + cSpec * (tp.spec + lineSpec)
                     + cTrans * tp.trans;
            acc += aces(c) * wt;
            xl = xr;
        }
    }
    if (wAvg > 0.0) {
        // The period average: four quarters of the profile, ridge to valley to ridge, each
        // weighted by the screen width it covers (the facets turned to the camera look wider).
        studio3_prep(P, 0.25);
        for (int k = 0; k < 4; ++k) {
            float wk = 0.25 * (k < 2 ? 1.0 / P.iD : 1.0 / P.iA);
            Studio3Tap tp = studio3_tap(0.125 + 0.25 * float(k), 0.125, P, fA, fD);
            float3 c = cKey * tp.key + cBounce * tp.bounce + cSky * tp.sky + cSpec * (tp.spec + lineSpec)
                     + cTrans * tp.trans;
            acc += aces(c) * (wAvg * wk);
        }
    }
    return linearToSrgb(acc) + bandDither(px) * 1.5;
}
