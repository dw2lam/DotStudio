//  Studio4_funcs.h — file-scope Metal helpers for new-scene slot 4: DICHROIC (case 70).
//  Prefix every symbol "studio4_".
//
//  World: metres, y up, the camera 1.6 m up at the origin looking along +z. The room is a
//  seamless sweep: floor y = 0 → a quarter-cylinder cove (radius 1.2 m) → the back wall
//  z = STUDIO4_ZW. Everything is analytic (ray–plane, ray–cylinder, 2D SDFs); nothing marches.
//
//  Dichroic coating: a quarter-wave stack's reflect band, ~90 nm wide, centred at
//  λ0·√(1 − sin²θ/n_eff²) (n_eff 1.7) — it slides blue as light comes in more obliquely.
//  T = 1 − R. Twelve wavelengths, 400–700 nm, folded to linear sRGB with CIE 1931 weights.
//
//  Anti-aliasing: a pane (or a cast) turned nearly edge-on is drawn as a band across its plane —
//  the ray's distance from the centre plane where its track crosses the outline, tent-filtered
//  in pixels (studio4_band and the pane loop) — so it stays an even fine line at any width.
//  Elsewhere the glass's and the casts' outlines are softened by analytic pixel footprints (not
//  fwidth, whose 2×2-quad steps bead thin bands).

constant float STUDIO4_ZW = 6.3;            // back wall
constant float STUDIO4_RC = 1.2;            // cove radius
constant float STUDIO4_ZC = 5.1;            // where the cove leaves the floor (ZW − RC)
constant float STUDIO4_TH = 0.005;          // half the glass thickness (10 mm panes)
constant float STUDIO4_PIN = 0.0065;        // steel pin radius
constant float STUDIO4_BASER = 0.095;       // base disc radius
constant float STUDIO4_BASEH = 0.011;       // base disc height

// 12 wavelength bins (centre nm, then linear-sRGB weights). CIE 1931 2° integrated over each
// 25 nm bin (the 380–400 and 700–780 tails folded into the end bins), XYZ → linear sRGB, each
// channel normalised to sum to 1, so a flat spectrum is white — chrome_reflectance's 8, at 12.
constant float4 STUDIO4_CMF[12] = {
    float4(412.5,  0.0137, -0.0141,  0.1072), float4(437.5,  0.0420, -0.0520,  0.4378),
    float4(462.5, -0.0078, -0.0146,  0.4176), float4(487.5, -0.0813,  0.0853,  0.1477),
    float4(512.5, -0.1575,  0.2494,  0.0109), float4(537.5, -0.1172,  0.3659, -0.0372),
    float4(562.5,  0.1151,  0.2963, -0.0410), float4(587.5,  0.3863,  0.1283, -0.0272),
    float4(612.5,  0.4584, -0.0093, -0.0111), float4(637.5,  0.2617, -0.0287, -0.0033),
    float4(662.5,  0.0752, -0.0074, -0.0011), float4(687.5,  0.0115,  0.0007, -0.0004) };

// Layout of the five panes: pin position (x, z), glass bottom height, start angle (rad).
// The first three are the default composition; four and five fill in behind.
constant float4 STUDIO4_SPOT[5] = {
    float4(-1.25, 4.00, 0.14,  0.62), float4( 0.45, 3.55, 0.30, -0.55),
    float4( 1.65, 4.40, 0.17,  0.42), float4(-0.15, 4.70, 0.22,  0.30),
    float4(-2.15, 4.55, 0.18, -0.85) };
// Turns per hour at Turn Speed 1 (periods 144, 225, 400, 240, 300 s — all divide the hour),
// signed by the sense of rotation.
constant float STUDIO4_TPH[5] = { 25.0, -16.0, 9.0, -15.0, 12.0 };
// Shapes per menu entry (Mixed, Rectangles, Discs, Arches): (kind, half width, half height).
// kind 0 = rectangle (rounded 12 mm corners), 1 = disc, 2 = arch (a round head on a rectangle).
constant float3 STUDIO4_SHAPES[20] = {
    float3(0, 0.30, 0.70), float3(1, 0.42, 0.42), float3(2, 0.36, 0.60), float3(0, 0.40, 0.40), float3(0, 0.24, 0.50),
    float3(0, 0.30, 0.70), float3(0, 0.40, 0.40), float3(0, 0.27, 0.58), float3(0, 0.48, 0.32), float3(0, 0.22, 0.62),
    float3(1, 0.45, 0.45), float3(1, 0.36, 0.36), float3(1, 0.50, 0.50), float3(1, 0.30, 0.30), float3(1, 0.40, 0.40),
    float3(2, 0.36, 0.68), float3(2, 0.30, 0.50), float3(2, 0.42, 0.70), float3(2, 0.28, 0.45), float3(2, 0.34, 0.58) };
// Reflect-band centre at normal incidence (nm) per Glass entry (Mixed, Magenta/Green,
// Cyan/Gold, Blue/Amber) and pane.
constant float STUDIO4_LAM[20] = {
    545.0, 612.0, 498.0, 580.0, 650.0,
    545.0, 535.0, 555.0, 540.0, 550.0,
    615.0, 605.0, 625.0, 610.0, 620.0,
    585.0, 575.0, 595.0, 580.0, 590.0 };

struct Studio4Pane {
    float3 c;       // centre of the glass
    float3 n;       // face normal (horizontal)
    float3 e;       // in-plane horizontal axis
    float2 hs;      // half extents
    int    kind;    // 0 rectangle, 1 disc, 2 arch
    float  lam0;    // reflect-band centre at normal incidence, nm
    float  w;       // angular rate, rad/s
    float2 b;       // pin (x, z)
    float  yb;      // bottom of the glass = top of the pin
};

// The group's lateral offset: its centroid sits a little left of centre (the casts fall right).
static inline float studio4_groupX(int N) {
    float cx = 0.0;
    for (int j = 0; j < 5; ++j) cx += j < N ? STUDIO4_SPOT[j].x : 0.0;
    return cx / float(N) + 0.10;
}

// Pane i's turn: (cos, sin) of its angle at time t. Whole turns per hour, so the hour-long
// wall clock wraps seamlessly; Turn Speed is quantised to whole turns per hour.
static inline float studio4_turns(int i, float speed) {
    return round(abs(STUDIO4_TPH[i]) * speed) * sign(STUDIO4_TPH[i]);
}
static inline float2 studio4_angle(int i, float t, float speed) {
    float ph = STUDIO4_SPOT[i].w + 6.2831853 * fract(fract(t / 3600.0) * studio4_turns(i, speed));
    return float2(cos(ph), sin(ph));
}
// Pane i, built from the tables and its angle (no trig here).
static inline Studio4Pane studio4_pane(int i, float2 cs, float cx, int shp, int glass, float speed) {
    Studio4Pane P;
    float4 s = STUDIO4_SPOT[i];
    float3 sh = STUDIO4_SHAPES[shp * 5 + i];
    P.w = 6.2831853 * studio4_turns(i, speed) / 3600.0;
    P.kind = int(sh.x + 0.5);
    P.hs = sh.yz;
    P.b = float2(s.x - cx, s.y);
    P.yb = s.z;
    P.c = float3(P.b.x, s.z + sh.z, P.b.y);
    P.n = float3(cs.y, 0.0, -cs.x);
    P.e = float3(cs.x, 0.0, cs.y);
    P.lam0 = STUDIO4_LAM[glass * 5 + i];
    return P;
}
// Does the ray X + s·L (s > 0) pass through the upright cylinder a pane sweeps as it turns
// (axis at b, radius r, y0…y1)? A tight, cheap bound for skipping the per-pane work.
static inline bool studio4_hitsCyl(float3 X, float3 L, float2 b, float r, float y0, float y1) {
    float2 o = X.xz - b, d = L.xz;
    float dd = max(dot(d, d), 1e-8);
    float cr = o.x * d.y - o.y * d.x;                 // |o × d|: horizontal miss distance × |d|
    float tn = -dot(o, d);                            // closest approach, × dd
    float id = rsqrt(dd);
    float yc = X.y + tn * id * id * L.y;              // height there
    float ey = r * abs(L.y) * id;                     // ± while inside the cylinder (at most)
    return cr * cr < r * r * dd && tn > -r * sqrt(dd) && yc + ey >= y0 && yc - ey <= y1;
}

// The same for two co-axial cylinders at once (a pane's sweep and its pin), sharing the work.
static inline bool2 studio4_hitsCyl2(float3 X, float3 L, float2 b, float ra, float ya0, float ya1,
                                     float rb, float yb0, float yb1) {
    float2 o = X.xz - b, d = L.xz;
    float dd = max(dot(d, d), 1e-8);
    float cr = o.x * d.y - o.y * d.x, cr2 = cr * cr;
    float tn = -dot(o, d);
    float id = rsqrt(dd);
    float yc = X.y + tn * id * id * L.y;
    float ay = abs(L.y) * id;
    bool front = tn > -max(ra, rb) * dd * id;
    return bool2(front && cr2 < ra * ra * dd && yc + ra * ay >= ya0 && yc - ra * ay <= ya1,
                 front && cr2 < rb * rb * dd && yc + rb * ay >= yb0 && yc - rb * ay <= yb1);
}

// 2D signed distance to the pane's outline (pane-local: x along e, y up, origin = centre).
static inline float studio4_sd(float2 p, float2 hs, int kind) {
    if (kind == 1) return length(p) - hs.x;
    if (kind == 2) {
        float a = hs.x, yc = hs.y - a;
        float dc = length(float2(p.x, p.y - yc)) - a;
        float2 q = abs(p - float2(0.0, 0.5 * (yc - hs.y))) - float2(a, 0.5 * (yc + hs.y)) + 0.012;
        return min(dc, length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.012);
    }
    float2 q = abs(p) - hs + 0.012;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.012;
}

// Distance to the 10 mm solid (the outline extruded through the thickness), exact outside.
static inline float studio4_sd3(float2 p, float w, float2 hs, int kind) {
    float2 q = float2(studio4_sd(p, hs, kind), abs(w) - STUDIO4_TH);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0));
}

// The 2D line o + t·d against an axis-aligned box (centre c, half extents h) / a disc: the
// interval of t inside (t_in > t_out when it misses).
static inline float2 studio4_clipBox(float2 o, float2 d, float2 c, float2 h) {
    float2 id = 1.0 / float2(abs(d.x) > 1e-6 ? d.x : 1e-6, abs(d.y) > 1e-6 ? d.y : 1e-6);
    float2 t1 = (c - h - o) * id, t2 = (c + h - o) * id;
    float2 tn = min(t1, t2), tf = max(t1, t2);
    return float2(max(tn.x, tn.y), min(tf.x, tf.y));
}
static inline float2 studio4_clipDisc(float2 o, float2 d, float2 c, float r) {
    float2 oc = o - c;
    float a = max(dot(d, d), 1e-10), b = dot(oc, d), k = b * b - a * (dot(oc, oc) - r * r);
    if (k < 0.0) return float2(1.0, -1.0);
    float s = sqrt(k);
    return float2(-b - s, -b + s) / a;
}
// … against the pane's outline grown by g (the rounded corners as square; the outline is convex,
// so an arch's rectangle and head give one interval).
static inline float2 studio4_clip(float2 o, float2 d, float2 hs, int kind, float g) {
    if (kind == 1) return studio4_clipDisc(o, d, float2(0.0), hs.x + g);
    if (kind == 2) {
        float a = hs.x, yc = hs.y - a;
        float2 r = studio4_clipBox(o, d, float2(0.0, 0.5 * (yc - hs.y)), float2(a + g, 0.5 * (yc + hs.y) + g));
        float2 c = studio4_clipDisc(o, d, float2(0.0, yc), a + g);
        if (r.x > r.y) return c;
        if (c.x > c.y) return r;
        return float2(min(r.x, c.x), max(r.y, c.y));
    }
    return studio4_clipBox(o, d, float2(0.0), hs + g);
}
// A tent filter's integral (radius 1 px): how much of a pixel lies left of x (in px). Bands
// filtered with it sum to their exact width across a row of pixels, so a fine line keeps an
// even weight wherever it falls on the grid — no beading, no crawl.
static inline float studio4_tentC(float x) {
    x = clamp(x, -1.0, 1.0);
    return x < 0.0 ? 0.5 * (x + 1.0) * (x + 1.0) : 1.0 - 0.5 * (1.0 - x) * (1.0 - x);
}

// A light's straight track from X along L (unit) past pane Q, in the pane's frame — the edge-on
// counterpart of testing where the light crosses the outline, for casts thrown by a pane turned
// nearly edge-on to the light (where that crossing races across the plane). How much of a tent
// kernel (half-width max(distance·kS, kP) across the plane: the light's penumbra, at least the
// receiving pixel) passes through the face (x) and through the polished edge band (y); ge is
// the softness of the cast's far ends.
static inline float2 studio4_band(float3 X, float3 L, Studio4Pane Q, float kS, float kP, float ge) {
    float3 xo = X - Q.c;
    float2 o2 = float2(dot(xo, Q.e), xo.y), d2 = float2(dot(L, Q.e), L.y);
    float ow = dot(xo, Q.n), dw = dot(L, Q.n);
    float2 iv = studio4_clip(o2, d2, Q.hs, Q.kind, 0.5 * ge);
    iv.x = max(iv.x, 0.0);
    if (iv.x >= iv.y) return float2(0.0);
    float dwS = abs(dw) > 1e-5 ? dw : (dw < 0.0 ? -1e-5 : 1e-5);
    float wi = ow + iv.x * dw, wo = ow + iv.y * dw;
    float mid = 0.5 * (wi + wo), hf = 0.5 * abs(wo - wi), R = hf + STUDIO4_TH;
    // where along the track the pane is: its plane crossing, but the track's middle when it runs
    // (nearly) in the plane — there the crossing flips end to end between neighbouring pixels
    float ss = mix(0.5 * (iv.x + iv.y), clamp(-ow / dwS, iv.x, iv.y), saturate(hf / (4.0 * STUDIO4_TH)));
    float ik = 1.0 / max(max(ss * kS, kP), 1e-5);
    float cov = studio4_tentC((R - mid) * ik) - studio4_tentC((-R - mid) * ik);
    float covF = studio4_tentC((hf - mid) * ik) - studio4_tentC((-hf - mid) * ik);
    float endA = saturate(0.5 - studio4_sd(o2 + 0.5 * (iv.x + iv.y) * d2, Q.hs, Q.kind) / ge);
    return float2(covF, max(cov - covF, 0.0)) * endA;
}

// The shoe: a stainless U-channel that grips the glass's bottom edge on top of the pin and turns
// with it. Half extents along e, up, and across the glass; it sits from 6 mm below the glass.
constant float3 STUDIO4_SHOE = float3(0.034, 0.017, 0.0095);
constant float  STUDIO4_SHOEY = 0.011;      // its centre above the bottom of the glass

// The outline distance's gradient (unit, pane-local), for analytic pixel footprints: sd changes
// per pixel by its gradient · the hit point's motion per pixel. (fwidth would do, but per 2×2
// quad: across a thin edge band its steps bead the band.)
static inline float2 studio4_boxGrad(float2 p, float2 q) {
    float2 sg = select(float2(-1.0), float2(1.0), p >= 0.0);
    if (q.x > 0.0 || q.y > 0.0) { float2 m = max(q, 0.0); return sg * m * rsqrt(max(dot(m, m), 1e-12)); }
    return q.x > q.y ? float2(sg.x, 0.0) : float2(0.0, sg.y);
}
static inline float2 studio4_sdGrad(float2 p, float2 hs, int kind) {
    if (kind == 1) return p * rsqrt(max(dot(p, p), 1e-12));
    if (kind == 2) {
        float a = hs.x, yc = hs.y - a;
        float2 pc = float2(p.x, p.y - yc);
        float2 c = float2(0.0, 0.5 * (yc - hs.y));
        float2 q = abs(p - c) - float2(a, 0.5 * (yc + hs.y)) + 0.012;
        float db = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.012;
        if (length(pc) - a < db) return pc * rsqrt(max(dot(pc, pc), 1e-12));
        return studio4_boxGrad(p - c, q);
    }
    return studio4_boxGrad(p, abs(p) - hs + 0.012);
}
// How fast a pane's outline distance at the light's crossing H moves per screen pixel, for a
// receiving point moving by dXx, dXy per pixel with the light along L (crossings slide along L).
static inline float studio4_castW(float2 h2, Studio4Pane Q, float3 L, float3 dXx, float3 dXy) {
    float2 g = studio4_sdGrad(h2, Q.hs, Q.kind);
    float3 g3 = Q.e * g.x + float3(0.0, g.y, 0.0);
    float dn = dot(L, Q.n);
    float idn = 1.0 / (abs(dn) > 1e-4 ? dn : 1e-4);
    float3 hx = dXx - dot(Q.n, dXx) * idn * L, hy = dXy - dot(Q.n, dXy) * idn * L;
    return abs(dot(g3, hx)) + abs(dot(g3, hy));
}

// The coating's band centre at incidence cosI.
static inline float studio4_lamC(float lam0, float cosI) {
    return lam0 * sqrt(max(1.0 - (1.0 - cosI * cosI) * 0.346021, 0.0));   // 1/1.7²
}
// Fresnel of the two glass faces outside the band (Schlick, n 1.5), → 1 at grazing.
static inline float studio4_fres(float cosI) {
    float f = 0.04 + 0.96 * pow(saturate(1.0 - cosI), 5.0);
    return 2.0 * f / (1.0 + f);
}
// Total reflectance at λ: the band (88 % in band, smooth 30 nm edges — wider than the 25 nm bin
// spacing, so the colour slides continuously as the band moves) plus the faces' Fresnel.
static inline float studio4_R(float lam, float lc, float F) {
    float b = 0.88 * (1.0 - smoothstep(30.0, 60.0, abs(lam - lc)));
    return b + (1.0 - b) * F;
}
// The band's reflectance folded to linear sRGB, Σ_k band(λ_k − λc)·cmf_k, tabulated every 5 nm
// of λc from 360 nm (tools: the same 12 bins and band shape as studio4_R, summed offline).
constant float3 STUDIO4_BAND[81] = {
    float3(0.0019, -0.0019, 0.0147), float3(0.0045, -0.0047, 0.0355), float3(0.0075, -0.0077, 0.0589),
    float3(0.0102, -0.0105, 0.0796), float3(0.0125, -0.0131, 0.1001), float3(0.0178, -0.0196, 0.1545),
    float3(0.0260, -0.0296, 0.2393), float3(0.0351, -0.0410, 0.3347), float3(0.0432, -0.0510, 0.4194),
    float3(0.0482, -0.0575, 0.4793), float3(0.0479, -0.0602, 0.5370), float3(0.0464, -0.0630, 0.6178),
    float3(0.0447, -0.0662, 0.7089), float3(0.0432, -0.0690, 0.7897), float3(0.0409, -0.0693, 0.8424),
    float3(0.0310, -0.0593, 0.8674), float3(0.0152, -0.0428, 0.8960), float3(-0.0027, -0.0239, 0.9263),
    float3(-0.0201, -0.0057, 0.9420), float3(-0.0352, 0.0116, 0.9392), float3(-0.0586, 0.0461, 0.9197),
    float3(-0.0917, 0.0971, 0.9011), float3(-0.1284, 0.1540, 0.8830), float3(-0.1642, 0.2088, 0.8306),
    float3(-0.1933, 0.2552, 0.7466), float3(-0.2192, 0.3148, 0.6469), float3(-0.2500, 0.3957, 0.5549),
    float3(-0.2805, 0.4819, 0.4870), float3(-0.3030, 0.5554, 0.4220), float3(-0.3135, 0.6073, 0.3360),
    float3(-0.3000, 0.6524, 0.2394), float3(-0.2763, 0.7126, 0.1507), float3(-0.2488, 0.7775, 0.0890),
    float3(-0.2166, 0.8248, 0.0561), float3(-0.1804, 0.8461, 0.0221), float3(-0.1142, 0.8481, -0.0141),
    float3(-0.0238, 0.8564, -0.0479), float3(0.0729, 0.8698, -0.0718), float3(0.1680, 0.8632, -0.0809),
    float3(0.2529, 0.8302, -0.0865), float3(0.3490, 0.7769, -0.0907), float3(0.4682, 0.7269, -0.0949),
    float3(0.5891, 0.6885, -0.0980), float3(0.6946, 0.6384, -0.0959), float3(0.7769, 0.5660, -0.0901),
    float3(0.8418, 0.4826, -0.0826), float3(0.9151, 0.4063, -0.0760), float3(0.9843, 0.3509, -0.0715),
    float3(1.0231, 0.3034, -0.0666), float3(1.0336, 0.2425, -0.0591), float3(1.0221, 0.1765, -0.0503),
    float3(1.0144, 0.1178, -0.0426), float3(1.0102, 0.0783, -0.0375), float3(0.9764, 0.0563, -0.0337),
    float3(0.9108, 0.0306, -0.0286), float3(0.8293, 0.0026, -0.0227), float3(0.7568, -0.0221, -0.0175),
    float3(0.7049, -0.0372, -0.0141), float3(0.6454, -0.0382, -0.0124), float3(0.5580, -0.0363, -0.0103),
    float3(0.4583, -0.0342, -0.0079), float3(0.3696, -0.0324, -0.0058), float3(0.3100, -0.0308, -0.0044),
    float3(0.2706, -0.0272, -0.0038), float3(0.2200, -0.0217, -0.0031), float3(0.1629, -0.0154, -0.0024),
    float3(0.1123, -0.0098, -0.0018), float3(0.0795, -0.0063, -0.0014), float3(0.0660, -0.0049, -0.0012),
    float3(0.0514, -0.0034, -0.0010), float3(0.0350, -0.0018, -0.0007), float3(0.0205, -0.0004, -0.0005),
    float3(0.0112, 0.0005, -0.0004), float3(0.0085, 0.0005, -0.0003), float3(0.0063, 0.0004, -0.0002),
    float3(0.0038, 0.0002, -0.0001), float3(0.0016, 0.0001, -0.0001), float3(0.0002, 0.0000, -0.0000),
    float3(0.0000, 0.0000, 0.0000), float3(0.0000, 0.0000, 0.0000), float3(0.0000, 0.0000, 0.0000) };
// The total reflectance in linear sRGB: R = band + (1 − band)·F, and the weights sum to 1 per
// channel, so Σ R·cmf = F + (1 − F)·Σ band·cmf. The same 12-wavelength model, folded once.
static inline float3 studio4_rgbR(float lc, float F) {
    float x = clamp((lc - 360.0) * 0.2, 0.0, 79.999);
    int i = int(x);
    float3 B = mix(STUDIO4_BAND[i], STUDIO4_BAND[i + 1], x - float(i));
    return saturate(F + (1.0 - F) * B);
}

// Seamless sweep: floor → cove → back wall. Returns t; n = surface normal, pr = distance along
// the profile (z on the floor, then arc length, then height), so textures run unbroken over it.
static inline float studio4_room(float3 ro, float3 rd, thread float3& n, thread float& pr) {
    if (rd.y < 0.0) {
        float tf = -ro.y / rd.y;
        float z = ro.z + tf * rd.z;
        if (z <= STUDIO4_ZC) { n = float3(0.0, 1.0, 0.0); pr = z; return tf; }
    }
    if (rd.z > 0.0) {
        float tw = (STUDIO4_ZW - ro.z) / rd.z;
        float y = ro.y + tw * rd.y;
        if (y >= STUDIO4_RC) {
            n = float3(0.0, 0.0, -1.0);
            pr = STUDIO4_ZC + STUDIO4_RC * 1.5707963 + (y - STUDIO4_RC);
            return tw;
        }
    }
    float2 oc = float2(ro.y - STUDIO4_RC, ro.z - STUDIO4_ZC), d = float2(rd.y, rd.z);
    float a = max(dot(d, d), 1e-8), b = dot(oc, d), c = dot(oc, oc) - STUDIO4_RC * STUDIO4_RC;
    float tc = (-b + sqrt(max(b * b - a * c, 0.0))) / a;              // far root: the concave side
    float2 q = oc + tc * d;
    n = float3(0.0, -q.x, -q.y) / STUDIO4_RC;
    pr = STUDIO4_ZC + STUDIO4_RC * atan2(max(q.y, 0.0), max(-q.x, 0.0));
    return tc;
}

// The rest of the gallery, for reflections: the sweep ahead, a rear wall behind the camera,
// side walls and a ceiling. Returns t and the surface normal.
static inline float studio4_envHit(float3 ro, float3 rd, thread float3& n) {
    float t = 1e4;
    n = float3(0.0, 1.0, 0.0);
    if (rd.y < 0.0 || rd.z > 0.0) {
        float pr;
        float3 nr;
        float tr = studio4_room(ro, rd, nr, pr);
        if (tr > 0.0) { t = tr; n = nr; }
    }
    if (rd.y > 0.0) { float tc = (4.6 - ro.y) / rd.y; if (tc < t) { t = tc; n = float3(0.0, -1.0, 0.0); } }
    if (rd.z < 0.0) { float tz = (-4.0 - ro.z) / rd.z; if (tz < t) { t = tz; n = float3(0.0, 0.0, 1.0); } }
    float sx = rd.x > 0.0 ? 6.5 : -6.5;
    float tx = (sx - ro.x) / (abs(rd.x) > 1e-5 ? rd.x : 1e-5);
    if (tx > 0.0 && tx < t) { t = tx; n = float3(-sign(sx), 0.0, 0.0); }
    return t;
}

// Light rig: the sun through a tall window behind the camera, its fill (window sky + the white
// room's bounce), and/or the gallery spot, as weights so Follow the Sun can crossfade them.
struct Studio4Light {
    float3 Ls;      // unit vector toward the sun (geometry; ≥ 10° up)
    float3 sunE;    // sun irradiance (colour × strength; 0 when it's down)
    float3 skyE;    // hemispherical fill: window sky + the white room's bounce
    float3 spotE;   // spot intensity (0 when off)
    float  sunOn, spotOn;
    float  expo;    // camera exposure (the spot's dark room is metered up)
};

constant float3 STUDIO4_SPOTPOS = float3(-0.8, 4.4, 0.9);
constant float3 STUDIO4_POOL = float3(0.15, 0.3, 4.6);
constant float3 STUDIO4_SPOTDIR = float3(0.1695, -0.7316, 0.6602);    // lamp → pool, unit
constant float3 STUDIO4_BEAMG = float3(0.0, 0.75, 4.0);                // the beam's axis passes here

static inline Studio4Light studio4_light(constant FXUniforms& u, bool live, int room, float albL) {
    Studio4Light Lt;
    float el = clamp(u.p1.x, 10.0, 70.0) * 0.0174533;
    float az = clamp(u.p1.y, -60.0, 60.0) * 0.0174533;
    float3 tint = srgbToLinear(u.colorB.rgb);
    float3 spotC = tint;
    float wSun = 1.0, wSky = 1.0, wSpot = 0.0;
    float3 skyC = float3(0.80, 0.90, 1.08);
    if (live) {
        float e = u.sun.x;
        // the day's progress across the room: morning light from the left, evening from the right
        float f = clamp(u.sun.y / max(u.sun.z, 0.15), -1.0, 1.0);
        az = 0.62 * f;                                   // ±36°: long low-sun casts still land on the back wall
        el = max(e, 0.1745);
        // warmer and weaker toward the horizon (the long path through the air)
        tint = nature_liveTint(u) * mix(float3(1.0, 0.62, 0.36), float3(1.0), smoothstep(0.0, 0.36, e));
        wSun = smoothstep(-0.014, 0.05, e) * mix(0.55, 1.0, smoothstep(0.0, 0.25, e));
        wSky = mix(0.06, 1.0, smoothstep(-0.105, 0.04, e));
        skyC = mix(float3(0.40, 0.56, 1.15), skyC, smoothstep(-0.07, 0.10, e));
        wSpot = 1.0 - smoothstep(-0.105, -0.015, e);
        spotC = srgbToLinear(u.colorB.rgb) * float3(1.0, 0.84, 0.64);    // warm gallery lamp
    }
    if (room == 2) { wSun = 0.0; wSky = 0.0; wSpot = 1.0; }
    Lt.Ls = float3(sin(az) * cos(el), sin(el), -cos(az) * cos(el));
    Lt.sunE = tint * 1.55 * wSun;
    // fill = cool window sky + warm bounce off the sunlit plaster
    Lt.skyE = (skyC * 0.17 * wSky + tint * 0.06 * wSun);
    Lt.spotE = spotC * 30.0 * wSpot;
    // the camera meters the spot's pool: a dark room is exposed up (part way, so a lighter
    // room still reads lighter)
    // By day it meters the light on the floor, gently (half the stops): a high sun stops down a
    // little, a low one and the blue hour open up.
    float Ef = luma(Lt.skyE + Lt.sunE * 0.6 * max(Lt.Ls.y, 0.0));
    float eDay = 0.64 * clamp(sqrt(0.62 / max(Ef, 1e-3)), 0.8, 2.0);
    Lt.expo = mix(eDay, pow(0.60 / albL, 0.8), wSpot);
    Lt.sunOn = wSun;
    Lt.spotOn = wSpot;
    return Lt;
}

// How much of the window's beam reaches X: a prism along the sun through the group's middle (so
// every transmitted cast lands in it), its edges softening with the distance back to the window.
static inline float2 studio4_beamQ(float3 Ls, float3 X) {
    float3 bu = float3(-Ls.z, 0.0, Ls.x) * rsqrt(max(Ls.x * Ls.x + Ls.z * Ls.z, 1e-6));
    float3 v = X - STUDIO4_BEAMG;
    return float2(dot(v, bu) + 0.35, dot(v, cross(Ls, bu)) - 0.8);
}
// The window's frame: two mullions (three tall lights) and a transom under a fanlight. Their
// shadows soften with the distance dw back to the glass — the sun's half-degree disc.
static inline float studio4_bars(float2 q, float dw) {
    float wm = 0.004 + 0.0052 * dw;
    float mx = abs(abs(q.x) - 1.04), my = abs(q.y - 1.02);
    return smoothstep(0.075 - wm, 0.075 + wm, mx) * smoothstep(0.065 - wm, 0.065 + wm, my);
}
static inline float studio4_barsAt(Studio4Light Lt, float3 X) {
    return studio4_bars(studio4_beamQ(Lt.Ls, X), 9.0 - dot(X - STUDIO4_BEAMG, Lt.Ls));
}
static inline float studio4_beam(Studio4Light Lt, float3 X, bool frame = true) {
    float3 v = X - STUDIO4_BEAMG;
    float2 q = studio4_beamQ(Lt.Ls, X);
    float dw = 9.0 - dot(v, Lt.Ls);                       // distance back to the window
    float w = 0.012 + 0.0065 * dw;
    float2 h = float2(3.1, 2.35);
    float2 m = smoothstep(h + w, h - w, abs(q));
    if (!frame) return m.x * m.y;
    return m.x * m.y * studio4_bars(q, dw);
}

// The sunlit patch's own glow: light bounced off it lifts the shade around it (a wide, very
// soft copy of the beam), the way a white room fills itself.
static inline float studio4_bounce(Studio4Light Lt, float3 X) {
    float2 q = studio4_beamQ(Lt.Ls, X);
    float2 m = exp(-max(abs(q) - float2(2.2, 1.2), 0.0) * float2(0.55, 0.65));
    return m.x * m.y;
}

// Spot cone (soft-edged, a little hotter in the middle) for light leaving the lamp along -Ld.
static inline float studio4_cone(float3 Sd, float3 Ld) {
    float c = dot(-Ld, Sd);
    return smoothstep(0.900, 0.975, c) * (0.78 + 0.22 * smoothstep(0.968, 0.998, c));
}

// The key light reaching P (irradiance at normal incidence) and its direction: the sun in
// the window's beam, and/or the spot.
static inline float3 studio4_key(Studio4Light Lt, float3 P, thread float3& Lk, bool frame = true) {
    float3 E = float3(0.0);
    Lk = Lt.Ls;
    if (Lt.sunOn > 0.0) E += Lt.sunE * studio4_beam(Lt, P, frame);
    if (Lt.spotOn > 0.0) {
        float3 v = STUDIO4_SPOTPOS - P;
        float d2 = max(dot(v, v), 0.25);
        float3 Ld = v * rsqrt(d2);
        E += Lt.spotE * studio4_cone(STUDIO4_SPOTDIR, Ld) / d2;
        if (Lt.sunOn <= 0.0) Lk = Ld;
    }
    return E;
}

// Albedo: plaster (or board-formed concrete) with mottling and a fine grain faded by footprint.
// Value noise on a small integer hash: cheap, and at a few percent it reads as plaster.
static inline float studio4_h(float2 p) {
    uint2 q = uint2(int2(p) + 4096);
    uint h = q.x * 0x27d4eb2du ^ q.y * 0x165667b1u;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12;
    return float(h) * (1.0 / 4294967296.0);
}
static inline float studio4_vn(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = studio4_h(i), b = studio4_h(i + float2(1, 0));
    float c = studio4_h(i + float2(0, 1)), d = studio4_h(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y) - 0.5;
}
static inline float3 studio4_albedo(float2 q, float2 px, float fp, int room, float3 base) {
    float mott = studio4_vn(q * 0.7 + float2(3.1, 7.7));
    // (the camera never moves, so a static per-pixel grain stays put on the plaster; it fades
    // as the pixel footprint outgrows a grain of plaster)
    float fine = smoothstep(0.012, 0.004, fp) * (studio4_h(px + 17.0) - 0.5);
    if (room == 1) {
        float mid = studio4_vn(q * 3.1 + 1.7);
        return base * (1.0 + 0.14 * mott + 0.07 * mid + 0.09 * fine);
    }
    return base * (1.0 + 0.05 * mott + 0.03 * fine);
}

// Soft occlusion of the fill: the cove's concavity as a smooth dip along the profile, and a
// slight fall-off up the wall (farther from the bounce off the floor).
static inline float studio4_coveAO(float pr, float y) {
    float m = STUDIO4_ZC + STUDIO4_RC * 0.785;
    float d = (pr - m) / 1.1;
    return (1.0 - 0.16 * exp(-d * d)) * (1.0 - 0.12 * smoothstep(1.2, 4.0, y));
}

// Radiance of the gallery seen in a reflection (no casts or grain: it's seen in tinted glass).
static inline float3 studio4_envRad(float3 X, float3 n, Studio4Light Lt, float3 alb) {
    // the far end of the gallery, behind the camera, is dimmer (farther from the light),
    // with a wide doorway through to the next room
    float3 E = Lt.skyE * (0.86 + 0.14 * n.y) * mix(0.66, 1.0, smoothstep(-4.0, 3.0, X.z));
    if (n.z > 0.5) {
        float2 dq = abs(float2(X.x - 1.1, X.y - 1.15)) - float2(0.75, 1.15);
        E *= 1.0 - 0.5 * smoothstep(0.04, -0.04, max(dq.x, dq.y));
    }
    if (Lt.sunOn > 0.0)
        // (the floor back under the window wall, behind the camera, is in that wall's shade)
        E += Lt.sunE * max(dot(n, Lt.Ls), 0.0) * studio4_beam(Lt, X) * smoothstep(-2.0, 5.5, X.z);
    if (Lt.spotOn > 0.0) {
        float3 v = STUDIO4_SPOTPOS - X;
        float d2 = max(dot(v, v), 0.25);
        float3 Ld = v * rsqrt(d2);
        float3 pv = X - STUDIO4_POOL;
        E += Lt.spotE * (studio4_cone(STUDIO4_SPOTDIR, Ld) * max(dot(n, Ld), 0.0) / d2
                         + 0.00055 + 0.0011 * exp(-dot(pv, pv) / 7.0));
    }
    return alb * E;
}

// The gist of the room for brushed steel's blurred reflection: the floor below (lit as it is
// around the hardware), plaster in shade above.
static inline float3 studio4_envSoft(float3 r, float3 Ekey, Studio4Light Lt, float3 alb) {
    float3 floorL = alb * (Lt.skyE + Ekey * 0.65);
    float3 wallL = alb * (Lt.skyE * 0.85 + Ekey * 0.25);
    return mix(wallL, floorL, smoothstep(0.15, -0.35, r.y));
}

// What a pane's face reflects along rr from XA: the sweep ahead exactly; behind the camera
// the gallery's other walls meet the floor in soft coves too, so the reflected room has no
// hard CG creases.
static inline float3 studio4_env(float3 XA, float3 rr, Studio4Light Lt, float3 alb) {
    float3 ne;
    float te = studio4_envHit(XA, rr, ne);
    float3 Xe = XA + te * rr;
    float3 L = studio4_envRad(Xe, ne, Lt, alb);
    if (abs(ne.y) < 0.5 && ne.z > -0.5) {                       // rear or side wall
        float k = smoothstep(0.0, 0.9, Xe.y);
        float3 Lf = studio4_envRad(float3(Xe.x, 0.0, Xe.z), float3(0.0, 1.0, 0.0), Lt, alb);
        L = mix(mix(Lf, L, 0.5), L, k);
    } else if (ne.y > 0.5 && Xe.z < STUDIO4_ZC) {               // floor, near those walls
        float dx = 6.5 - abs(Xe.x), dz = Xe.z + 4.0;
        float3 nw = dx < dz ? float3(-sign(Xe.x), 0.0, 0.0) : float3(0.0, 0.0, 1.0);
        float k = smoothstep(0.0, 0.9, min(dx, dz));
        L = mix(mix(studio4_envRad(Xe, nw, Lt, alb), L, 0.5), L, k);
    }
    return L;
}

// The whole frame, in linear light (before the vignette and tone mapping).
static inline float3 studio4_scene(float2 px, float2 res, float t, constant FXUniforms& u) {
    int   N     = clamp(int(u.p0.x + 0.5), 1, 5);
    float speed = clamp(u.p0.y, 0.0, 2.0);
    int   glass = clamp(int(u.p0.z + 0.5), 0, 3);
    int   shp   = clamp(int(u.p0.w + 0.5), 0, 3);
    int   room  = clamp(int(u.p1.w + 0.5), 0, 2);
    bool  live  = u.p1.z > 0.5 && u.sky.y > 0.5;

    // Camera: eye height 1.6 m, pitched 11° down (more floor for the casts, less bare wall),
    // 40° vertical field of view.
    const float tanV = 0.36397, c8 = 0.981627, s8 = 0.190809;
    float2 sp = float2(px.x - 0.5 * res.x, 0.5 * res.y - px.y) / (0.5 * res.y);
    float3 ro = float3(0.0, 1.6, 0.0);
    float3 fwd = float3(0.0, -s8, c8), cup = float3(0.0, c8, s8);
    float3 rd = normalize(fwd + (float3(sp.x, 0.0, 0.0) + sp.y * cup) * tanV);
    float pixAng = 2.0 * tanV / res.y;
    float frameW = 2.0 * tanV * res.x / res.y;           // frame width per metre of depth

    float3 A = srgbToLinear(u.colorA.rgb);
    // Room colour → albedo. Warm Concrete is a mid-tone; the Black Box colour is how its matte
    // black paint reads in the gloom, so its albedo sits higher than the swatch.
    float3 base = room == 1 ? A * float3(0.60, 0.56, 0.51) : (room == 2 ? min(A * 12.0, 0.9) : A);
    float albL = max(luma(base), 0.003);
    float gx = studio4_groupX(N);
    Studio4Light Lt = studio4_light(u, live, room, albL);


    // ---- the room behind everything
    float3 nR; float pr;
    float tR = studio4_room(ro, rd, nR, pr);
    float3 X = ro + tR * rd;
    float fpR = tR * pixAng;                                   // pixel footprint across the ray
    float cosV = max(abs(dot(rd, nR)), 0.12);
    float fpS = fpR / cosV;                                    // … along the surface
    float3 alb = studio4_albedo(float2(X.x, pr), px, fpS, room, base);
    bool onFloor = nR.y > 0.999;
    float3 dXx = dfdx(X), dXy = dfdy(X);                    // the receiving point's motion per pixel

    // Fill: window sky + bounce, with the cove's soft occlusion and contact shadows at the pins.
    float ao = studio4_coveAO(pr, X.y);
    if (onFloor) {
        for (int i = 0; i < 5; ++i) {
            float2 rv = X.xz - float2(STUDIO4_SPOT[i].x - gx, STUDIO4_SPOT[i].y);
            float r2 = dot(rv, rv);
            if (i < N && r2 < 0.5) {
                float r = sqrt(r2);
                ao *= 1.0 - 0.55 * exp(-max(r - STUDIO4_BASER, 0.0) / 0.012) - 0.10 * exp(-r2 / 0.06);
            }
        }
    }
    float3 E = (Lt.skyE + Lt.sunE * 0.10 * studio4_bounce(Lt, X)) * ao * (0.90 + 0.10 * nR.y);
    float depth = max(dot(X - ro, fwd), 0.5);

    // Sun: hard but not razor-sharp (0.53° disc + a little diffusion), through the panes.
    if (Lt.sunOn > 0.0) {
        const float tanPen = 0.0108;                         // tan(0.27° + 0.35°)
        float cosS = max(dot(nR, Lt.Ls), 0.0) * studio4_beam(Lt, X);
        float occ = 1.0;
        float3 refl = float3(0.0);
        // Up to two overlapping casts are kept per wavelength (a third is rare, and folds in RGB).
        int nT = 0;
        float m1 = 0.0, lc1 = 550.0, F1 = 0.0, m2 = 0.0, lc2 = 550.0, F2 = 0.0;
        float3 more = float3(1.0);
        _Pragma("clang loop unroll(disable)")
        for (int i = 0; i < 5; ++i) {
            if (i >= N) continue;
            Studio4Pane Q = studio4_pane(i, studio4_angle(i, t, speed), gx, shp, glass, speed);
            float dn = dot(Lt.Ls, Q.n);
            // bounding test: does the way to the sun (or to its mirror image), or the pin's or
            // base's shadow, pass near this pane at all?
            float3 vc = Q.c - X;
            float3 Lr0 = Lt.Ls - 2.0 * dn * Q.n;
            float3 av = abs(vc);
            float mg = 0.03 + 4.0 * fpS + 0.011 * (av.x + av.y + av.z);   // edge softness: penumbra, 1 px
            float y0 = Q.yb - mg, y1 = Q.yb + 2.0 * Q.hs.y + mg;
            // A cast lands only on the far side of the pane from the sun, a reflection only on
            // the sun's side: the side of the plane X is on settles which one to look for.
            float hv = dot(vc, Q.n) * dn;                    // > 0: X is in the pane's shadow side
            bool2 nTP = studio4_hitsCyl2(X, Lt.Ls, Q.b, Q.hs.x + mg, y0, y1, STUDIO4_BASER + mg, -1.0, Q.yb + mg);
            bool nearT = hv > 0.0 && nTP.x, nearP = nTP.y;
            bool nearR = hv < 0.0 && studio4_hitsCyl(X, Lr0, Q.b, Q.hs.x + mg, y0, y1);
            if (i < N) {
                float cI = abs(dn);
                float dnS = cI > 1e-4 ? dn : 1e-4;
                float sS = smoothstep(0.04, 0.12, cI);       // edge-on to the sun → face-on
                float qn = sqrt(max(1.0 - dot(Q.n, nR) * dot(Q.n, nR), 0.0));
                float s = dot(vc, Q.n) / dnS;                // along the sun to the pane's plane
                if (quad_any(nearT)) {
                    // transmitted: the way to the sun crosses the pane
                    float3 H = X + s * Lt.Ls - Q.c;
                    float d = studio4_sd(float2(dot(H, Q.e), H.y), Q.hs, Q.kind);
                    // the polished edge (10 mm, seen obliquely by the sun) throws a thin darker rim
                    float ew = 2.0 * STUDIO4_TH * sqrt(max(1.0 - cI * cI, 0.0)) / max(cI, 0.15);
                    // edge softness: the penumbra, at least the pixel (its footprint carried onto
                    // the pane — only worked out near the edge, where it shows)
                    float w = max(s * tanPen, 1.2 * fpS / max(cI, 0.04));
                    if (d > -ew - w && d < w)
                        w = max(s * tanPen, min(0.6 * studio4_castW(float2(dot(H, Q.e), H.y), Q, Lt.Ls, dXx, dXy), w));
                    float m = s > 0.002 ? 1.0 - smoothstep(-w, w, d) : 0.0;
                    float rimS = s > 0.002 ? saturate(smoothstep(-ew - w, -ew + w, d) - smoothstep(-w, w, d)) : 0.0;
                    // nearly edge-on to the sun, the cast is a sliver: the band across the plane
                    if (sS < 1.0) {
                        float2 bT = studio4_band(X, Lt.Ls, Q, tanPen, fpS * qn, max(length(vc) * tanPen, fpS));
                        m = mix(bT.x, m, sS);
                        rimS = mix(bT.y, rimS, sS);
                    }
                    if (m > 0.001) {
                        float lc = studio4_lamC(Q.lam0, cI), F = studio4_fres(cI);
                        if (nT == 0) { m1 = m; lc1 = lc; F1 = F; }
                        else if (nT == 1) { m2 = m; lc2 = lc; F2 = F; }
                        else more *= 1.0 - m * studio4_rgbR(lc, F);
                        nT += 1;
                    }
                    occ *= 1.0 - 0.55 * rimS;
                }
                if (quad_any(nearR)) {
                    // reflected: the sun mirrored in the pane, seen from the sun's side
                    float sr = -s;
                    float3 Hr = X + sr * Lr0 - Q.c;
                    float dr = studio4_sd(float2(dot(Hr, Q.e), Hr.y), Q.hs, Q.kind);
                    float wr = max(sr * tanPen, 1.2 * fpS / max(cI, 0.04));
                    if (abs(dr) < wr)
                        wr = max(sr * tanPen, min(0.6 * studio4_castW(float2(dot(Hr, Q.e), Hr.y), Q, Lr0, dXx, dXy), wr));
                    float cR = max(dot(nR, Lr0), 0.0);
                    // a patch thrown far sweeps fast (2ω × distance): fade it above ~0.15 frame widths/s
                    float spd = 2.0 * abs(Q.w) * sr / max(cR, 0.25) / (frameW * depth);
                    float mr = sr > 0.002 ? 1.0 - smoothstep(-wr, wr, dr) : 0.0;
                    if (sS < 1.0 && hv < 0.0)
                        mr = mix(studio4_band(X, Lr0, Q, tanPen, fpS * qn, max(length(vc) * tanPen, fpS)).x, mr, sS);
                    mr *= 1.0 - smoothstep(0.10, 0.20, spd);
                    if (mr > 0.002)
                        refl += mr * cR * studio4_beam(Lt, Q.c) * studio4_rgbR(studio4_lamC(Q.lam0, cI), studio4_fres(cI));
                }
                if (nearP) {
                    // the steel pin's thin shadow
                    float2 L2 = Lt.Ls.xz;
                    float sp2 = dot(Q.b - X.xz, L2) / max(dot(L2, L2), 1e-6);
                    float dp = length(X.xz + sp2 * L2 - Q.b);
                    float yp = X.y + sp2 * Lt.Ls.y;
                    float wp = max(sp2 * tanPen, 0.5 * fpS);
                    float mp = min(1.0, STUDIO4_PIN / wp) * (1.0 - smoothstep(max(STUDIO4_PIN - wp, 0.0), STUDIO4_PIN + wp, dp))
                             * smoothstep(-wp, wp, yp) * (1.0 - smoothstep(Q.yb - wp, Q.yb + wp, yp));
                    occ *= 1.0 - (sp2 > 0.0 ? mp : 0.0);
                    // the base disc's own sliver of shadow on the floor
                    if (onFloor) {
                        float2 sb = Lt.Ls.xz * (STUDIO4_BASEH / Lt.Ls.y);
                        float2 rel = X.xz - Q.b;
                        float hb = saturate(-dot(rel, sb) / max(dot(sb, sb), 1e-8));
                        float db = length(rel + hb * sb) - STUDIO4_BASER;
                        float wb = 0.004 + 0.5 * fpS;
                        occ *= 1.0 - 0.9 * (1.0 - smoothstep(-wb, wb, db));
                    }
                }
            }
        }
        float3 dir = float3(1.0);
        if (nT == 1) {                                     // one cast: T = 1 − R folds straight to RGB
            dir = max(1.0 - m1 * studio4_rgbR(lc1, F1), 0.0);
        } else if (nT > 1) {                               // overlapping casts multiply per wavelength
            float3 acc = float3(0.0);
            for (int k = 0; k < 12; ++k) {
                float lam = STUDIO4_CMF[k].x;
                acc += (1.0 - m1 * studio4_R(lam, lc1, F1)) * (1.0 - m2 * studio4_R(lam, lc2, F2)) * STUDIO4_CMF[k].yzw;
            }
            dir = max(acc, 0.0) * max(more, 0.0);
        }
        E += Lt.sunE * (cosS * occ * dir + refl);
    }

    // Spot (Black Box, and the night after Follow the Sun): a point lamp, so the band shifts per pixel.
    if (Lt.spotOn > 0.0) {
        float3 v = STUDIO4_SPOTPOS - X;
        float dist = length(v);
        float3 Ld = v / dist;
        float cosL = max(dot(nR, Ld), 0.0);
        float irr = studio4_cone(STUDIO4_SPOTDIR, Ld) / (dist * dist);
        float occ = 1.0;
        float3 refl = float3(0.0);
        int nT = 0;
        float m1 = 0.0, lc1 = 550.0, F1 = 0.0, m2 = 0.0, lc2 = 550.0, F2 = 0.0;
        float3 more = float3(1.0);
        const float ap = 0.07;                             // lamp aperture radius, m
        _Pragma("clang loop unroll(disable)")
        for (int i = 0; i < 5; ++i) {
            if (i >= N) continue;
            Studio4Pane Q = studio4_pane(i, studio4_angle(i, t, speed), gx, shp, glass, speed);
            float3 vc = Q.c - X;
            float mg = 0.04 + 4.0 * fpS + 0.03 * length(vc);
            float y0 = Q.yb - mg, y1 = Q.yb + 2.0 * Q.hs.y + mg;
            float3 Sm0 = STUDIO4_SPOTPOS - 2.0 * dot(STUDIO4_SPOTPOS - Q.c, Q.n) * Q.n;
            bool nearC = studio4_hitsCyl(X, Ld, Q.b, Q.hs.x + mg, y0, y1)
                      || studio4_hitsCyl(X, normalize(Sm0 - X), Q.b, Q.hs.x + mg, y0, y1);
            if (i < N && quad_any(nearC)) {
                float dn = dot(Ld, Q.n);
                float cI = abs(dn);
                float hp = dot(Q.c - X, Q.n);
                float s = hp / (cI > 1e-4 ? dn : 1e-4);
                float3 H = X + s * Ld - Q.c;
                float d = studio4_sd(float2(dot(H, Q.e), H.y), Q.hs, Q.kind);
                float ew = 2.0 * STUDIO4_TH * sqrt(max(1.0 - cI * cI, 0.0)) / max(cI, 0.15);
                float pS = s * ap / max(dist - s, 0.3);
                float w = max(pS, 1.2 * fpS / max(cI, 0.04));
                if (d > -ew - w && d < w)
                    w = max(pS, min(0.6 * studio4_castW(float2(dot(H, Q.e), H.y), Q, Ld, dXx, dXy), w));
                float m = (s > 0.002 && s < dist) ? 1.0 - smoothstep(-w, w, d) : 0.0;
                float rimS = (s > 0.002 && s < dist) ? saturate(smoothstep(-ew - w, -ew + w, d) - smoothstep(-w, w, d)) : 0.0;
                // nearly edge-on to the lamp, the cast is a sliver: the band across the plane
                float sS = smoothstep(0.04, 0.12, cI);
                float qn = sqrt(max(1.0 - dot(Q.n, nR) * dot(Q.n, nR), 0.0));
                if (sS < 1.0) {
                    float kS = ap / max(dist - max(dot(vc, Ld), 0.0), 0.3);
                    float2 bT = studio4_band(X, Ld, Q, kS, fpS * qn, max(length(vc) * kS, fpS));
                    m = mix(bT.x, m, sS);
                    rimS = mix(bT.y, rimS, sS);
                }
                if (m > 0.001) {
                    float lc = studio4_lamC(Q.lam0, cI), F = studio4_fres(cI);
                    if (nT == 0) { m1 = m; lc1 = lc; F1 = F; }
                    else if (nT == 1) { m2 = m; lc2 = lc; F2 = F; }
                    else more *= 1.0 - m * studio4_rgbR(lc, F);
                    nT += 1;
                }
                occ *= 1.0 - 0.55 * rimS;
                // reflected: the lamp's mirror image
                float hs = dot(STUDIO4_SPOTPOS - Q.c, Q.n);
                float3 Sm = STUDIO4_SPOTPOS - 2.0 * hs * Q.n;
                float3 vr = Sm - X;
                float dm = length(vr);
                float3 Lr = vr / dm;
                float dnr = dot(Lr, Q.n);
                float sr = hp / (abs(dnr) > 1e-4 ? dnr : 1e-4);
                float3 Hr = X + sr * Lr - Q.c;
                float dr = studio4_sd(float2(dot(Hr, Q.e), Hr.y), Q.hs, Q.kind);
                float pR = sr * ap / max(dm - sr, 0.3);
                float wr = max(pR, 1.2 * fpS / max(abs(dnr), 0.04));
                if (abs(dr) < wr)
                    wr = max(pR, min(0.6 * studio4_castW(float2(dot(Hr, Q.e), Hr.y), Q, Lr, dXx, dXy), wr));
                float spd = 2.0 * abs(Q.w) * sr / max(dot(nR, Lr), 0.25) / (frameW * depth);
                bool side = hs * hp < 0.0;                     // lamp and point on the same side
                float mr = (side && sr > 0.002 && sr < dm) ? 1.0 - smoothstep(-wr, wr, dr) : 0.0;
                float sR = smoothstep(0.04, 0.12, abs(dnr));
                if (sR < 1.0 && side) {
                    float kS = ap / max(dm - max(dot(vc, Lr), 0.0), 0.3);
                    mr = mix(studio4_band(X, Lr, Q, kS, fpS * qn, max(length(vc) * kS, fpS)).x, mr, sR);
                }
                mr *= 1.0 - smoothstep(0.10, 0.20, spd);
                if (mr > 0.002) {
                    float cIr = abs(dnr);
                    float cone = studio4_cone(STUDIO4_SPOTDIR, normalize(STUDIO4_SPOTPOS - (Hr + Q.c)));   // light leaving the lamp for the pane
                    refl += mr * cone * max(dot(nR, Lr), 0.0) / (dm * dm)
                          * studio4_rgbR(studio4_lamC(Q.lam0, cIr), studio4_fres(cIr));
                }
            }
        }
        float3 dir = float3(1.0);
        if (nT == 1) {
            dir = max(1.0 - m1 * studio4_rgbR(lc1, F1), 0.0);
        } else if (nT > 1) {
            float3 acc = float3(0.0);
            for (int k = 0; k < 12; ++k) {
                float lam = STUDIO4_CMF[k].x;
                acc += (1.0 - m1 * studio4_R(lam, lc1, F1)) * (1.0 - m2 * studio4_R(lam, lc2, F2)) * STUDIO4_CMF[k].yzw;
            }
            dir = max(acc, 0.0) * max(more, 0.0);
        }
        // stray light: the pool's bounce and haze keep the dark room just legible
        float3 pv = X - STUDIO4_POOL;
        float bounce = 0.00055 + 0.0011 * exp(-dot(pv, pv) / 7.0);
        E += Lt.spotE * (irr * cosL * occ * dir + refl + bounce * ao);
    }

    float3 col = alb * E;

    // ---- pins and base discs (opaque steel)
    float3 Ea = Lt.skyE + Lt.spotE * 0.0014;                 // what the steel sees of the room
    // the black box's hardware is blackened, so it doesn't glare against the dark room
    float hk = room == 2 ? 0.06 : 1.0;
    int nearBits = 0;                                        // panes the camera ray passes near
    _Pragma("clang loop unroll(disable)")
    for (int i = 0; i < 5; ++i) {
        if (i < N) {
            float2 b = float2(STUDIO4_SPOT[i].x - gx, STUDIO4_SPOT[i].y);
            float yb = STUDIO4_SPOT[i].z;
            float2 hsz = STUDIO4_SHAPES[shp * 5 + i].yz;
            float mq = 0.02 + 42.0 * pixAng;                  // 6 px at the far end of the group
            bool2 nQP = studio4_hitsCyl2(ro, rd, b, hsz.x + mq, yb - mq, yb + 2.0 * hsz.y + mq,
                                         STUDIO4_BASER + 0.03, -0.03, yb + 0.03);
            if (nQP.x) nearBits |= 1 << i;
            if (!quad_any(nQP.y)) continue;
            float2 o2 = ro.xz - b, d2 = rd.xz;
            float dd = max(dot(d2, d2), 1e-8);
            float tc = -dot(o2, d2) / dd;
            float dist = length(o2 + tc * d2);
            float y = ro.y + tc * rd.y;
            float fp = tc * pixAng, ifp = 1.0 / fp;
            // the pin, and the collar that grips the glass
            float cov = saturate(0.5 - (dist - STUDIO4_PIN) * ifp)
                      * saturate(0.5 + (y - STUDIO4_BASEH) * ifp) * saturate(0.5 + (yb + 0.004 - y) * ifp);
            cov = max(cov, saturate(0.5 - (dist - 0.0105) * ifp)
                         * saturate(0.5 + (y - yb + 0.028) * ifp) * saturate(0.5 + (yb + 0.002 - y) * ifp));
            // base disc: its top cap or its rim
            float tTop = (STUDIO4_BASEH - ro.y) / rd.y;
            float rTop = length(ro.xz + tTop * rd.xz - b);
            float rFl = length(ro.xz - (ro.y / rd.y) * rd.xz - b);
            float db = min(rTop, rFl) - STUDIO4_BASER;
            float bcov = rd.y < 0.0 ? saturate(0.5 - db / max(fwidth(db), 0.5 * tTop * pixAng)) : 0.0;
            if (bcov > 0.001 || cov > 0.001) {
                // the room around the hardware (for its blurred reflections: the window's bars
                // don't matter there), and the key light right where this pixel lands (the bars
                // do: a mullion's shadow crosses a pin or base as it does the floor)
                float3 Lk;
                float3 Eg = studio4_key(Lt, float3(b.x, 0.1, b.y), Lk, false);
                float3 Xb = ro + tTop * rd;
                float3 Ek = Eg * (Lt.sunOn > 0.0 ? studio4_barsAt(Lt, cov > 0.5 ? float3(b.x, y, b.y) : Xb) : 1.0);
                if (bcov > 0.001) {
                    float topLit = rTop < STUDIO4_BASER ? 1.0 : 0.0;
                    float3 envB = studio4_envSoft(float3(0.0, 0.6, 0.0), Eg, Lt, base);
                    float3 baseTop = 0.40 * mix(envB, float3(luma(envB)), 0.5) + 0.10 * Ek * max(Lk.y, 0.0);
                    // the turned rim: darker, with a fine bright line where the bevel catches the room
                    float rimHi = exp(-pow((rTop - STUDIO4_BASER + 0.004) / max(0.003, tTop * pixAng), 2.0));
                    float3 baseC = mix(0.30 * Ea + 0.12 * Ek * max(dot(normalize(float3(Xb.x - b.x, 0.0, Xb.z - b.y)), Lk), 0.0),
                                       baseTop * (1.0 + 0.5 * rimHi), topLit);
                    col = mix(col, baseC * hk, bcov);
                }
                if (cov > 0.001) {
                    // brushed steel: a blurred reflection of the room plus the key light's sheen
                    float rp = y > yb - 0.028 ? 0.0105 : STUDIO4_PIN;
                    float hh = sqrt(max(rp * rp - dist * dist, 0.0) / dd);
                    float2 hp = o2 + (tc - hh) * d2;
                    float3 np = normalize(float3(hp.x, 0.0, hp.y));
                    float3 r = reflect(rd, np);
                    float3 envP = studio4_envSoft(r, Eg, Lt, base);
                    // The sun's streak down the brushed pin: as tight as the pin's width in
                    // pixels allows (≥ 1.5 px, so it never stair-steps), its energy kept constant.
                    float rpx = rp / fp;
                    float nS = clamp(0.5 * rpx * rpx, 2.0, 64.0);
                    float steelK = room == 2 ? 0.25 : 1.0;
                    float3 steel = (0.40 * mix(envP, float3(luma(envP)), 0.5)
                                 + 0.05 * Ek * max(dot(np, Lk), 0.0)) * hk
                                 + Ek * steelK * (1.3 * sqrt(nS / 16.0) * pow(max(dot(r, Lk), 0.0), nS)
                                                  + 0.10 * pow(max(dot(r, Lk), 0.0), 2.0));
                    col = mix(col, steel, cov);
                }
            }
        }
    }

    // ---- the panes: 10 mm slabs of coated glass in their shoes, composited front to back
    float3 acc = float3(0.0), thr = float3(1.0);
    _Pragma("clang loop unroll(disable)")
    for (int k = 0; k < 5; ++k) {
        int i = k == 0 ? 1 : (k == 1 ? 0 : k);              // front to back: disc, tall pane, …
        Studio4Pane Q = studio4_pane(i, studio4_angle(i, t, speed), gx, shp, glass, speed);
        if (i < N && quad_any(((nearBits >> i) & 1) != 0)) {
            float3 o = ro - Q.c;
            float2 o2 = float2(dot(o, Q.e), o.y), d2 = float2(dot(rd, Q.e), rd.y);
            float ow = dot(o, Q.n), dw = dot(rd, Q.n);
            float dwS = abs(dw) > 1e-5 ? dw : (dw < 0.0 ? -1e-5 : 1e-5);
            float cV = abs(dw);
            float idw = 1.0 / (cV > 0.04 ? dw : (dw < 0.0 ? -0.04 : 0.04));
            float tP = max(dot(Q.c - ro, rd), 0.5);           // depth of the pane along the ray
            float fpE = tP * pixAng;

            float sF = smoothstep(0.04, 0.12, cV);           // edge-on → face-on

            // The shoe first: it wraps the glass's foot, so whatever of the glass lies behind it
            // is hidden. A rounded box in the pane's frame; its coverage from the box's distance
            // at the middle of the ray's slab crossings (continuous, so its outline doesn't crawl).
            float3 os = o - float3(0.0, Q.yb + STUDIO4_SHOEY - Q.c.y, 0.0);
            float3 xs = cross(os, rd);
            if (dot(xs, xs) < 0.0025 + 4.0 * fpE * fpE) {   // the ray passes within 5 cm of it
                float3 o3 = float3(dot(os, Q.e), os.y, dot(os, Q.n));
                float3 d3 = float3(d2.x, rd.y, dw);
                float3 id3 = 1.0 / select(d3, copysign(float3(1e-6), d3), abs(d3) < 1e-6);
                float3 t1 = (-STUDIO4_SHOE - o3) * id3, t2 = (STUDIO4_SHOE - o3) * id3;
                float3 tn = min(t1, t2), tf = max(t1, t2);
                float tN = max(max(tn.x, tn.y), tn.z), tF = min(min(tf.x, tf.y), tf.z);
                float tq = max(0.5 * (tN + tF), 0.5);
                float3 qs = abs(o3 + tq * d3) - (STUDIO4_SHOE - 0.002);
                float ds = length(max(qs, 0.0)) + min(max(qs.x, max(qs.y, qs.z)), 0.0) - 0.002;
                float covS = saturate(0.5 - ds / (tq * pixAng));
                if (covS > 0.001) {
                    // the face the ray enters (its slab entered last)
                    float3 nl = tn.x >= max(tn.y, tn.z) ? float3(-sign(d3.x), 0.0, 0.0)
                              : (tn.y >= tn.z ? float3(0.0, -sign(d3.y), 0.0) : float3(0.0, 0.0, -sign(d3.z)));
                    float3 ns = Q.e * nl.x + float3(0.0, nl.y, 0.0) + Q.n * nl.z;
                    float3 Lk;
                    float3 Eg = studio4_key(Lt, float3(Q.b.x, 0.1, Q.b.y), Lk, false);
                    float3 Ek = Eg * (Lt.sunOn > 0.0 ? studio4_barsAt(Lt, float3(Q.b.x, Q.yb + STUDIO4_SHOEY, Q.b.y)) : 1.0);
                    float3 rs = reflect(rd, ns);
                    float3 envS = studio4_envSoft(rs, Eg, Lt, base);
                    float steelK = room == 2 ? 0.25 : 1.0;
                    float3 shoe = (0.46 * mix(envS, float3(luma(envS)), 0.5)
                                + 0.06 * Ek * max(dot(ns, Lk), 0.0)) * hk
                                + Ek * steelK * (0.9 * pow(max(dot(rs, Lk), 0.0), 24.0)
                                                 + 0.08 * pow(max(dot(rs, Lk), 0.0), 3.0));
                    acc += thr * covS * shoe;
                    thr *= 1.0 - covS;
                }
            }

            // Edge-on, the slab is a band across the line of sight: where the ray's track in the
            // pane's plane lies inside the outline, its distance from the centre plane (w) runs
            // from wi to wo; the glass covers |w| ≤ TH. Measured in pixels (the ray swings w by
            // pxw per pixel), tent-filtered: a coverage-weighted line however thin it gets, its
            // brightness scaled by its width. The far ends of the line fade by how deep the track
            // runs into the outline.
            // Of that band, the part where the ray is already inside the slab where its track
            // enters the outline sees the polished edge itself; the rest sees the near face.
            float aL = 0.0, afL = 0.0, ts = tP, eu = 0.0;
            float2 iv = sF < 1.0 ? studio4_clip(o2, d2, Q.hs, Q.kind, 0.5 * fpE) : float2(1.0, 0.0);
            iv.x = max(iv.x, 0.0);
            if (iv.x < iv.y) {
                float wi = ow + iv.x * dw, wo = ow + iv.y * dw;
                float mid = 0.5 * (wi + wo), hf = 0.5 * abs(wo - wi), R = hf + STUDIO4_TH;
                // where along the ray the pane is: its plane crossing, but the track's middle when
                // the ray runs (nearly) in the plane — there the crossing flips end to end between
                // neighbouring pixels, which would bead the line
                ts = mix(0.5 * (iv.x + iv.y), clamp(-ow / dwS, iv.x, iv.y), saturate(hf / (4.0 * STUDIO4_TH)));
                float ipx = 1.0 / max(max(ts, 0.5) * pixAng * sqrt(max(1.0 - dw * dw, 1e-6)), 1e-7);
                float cov = studio4_tentC((R - mid) * ipx) - studio4_tentC((-R - mid) * ipx);
                float sh = dw >= 0.0 ? hf : -hf;              // where the near end's |w| ≤ TH lies
                float covE = studio4_tentC((sh + STUDIO4_TH - mid) * ipx) - studio4_tentC((sh - STUDIO4_TH - mid) * ipx);
                float pen = -studio4_sd(o2 + 0.5 * (iv.x + iv.y) * d2, Q.hs, Q.kind);
                float endA = saturate(0.5 + pen / fpE);
                aL = cov * endA;
                afL = max(cov - covE, 0.0) * endA;
                eu = clamp((mid - sh) / STUDIO4_TH, -1.0, 1.0);   // across the edge face
            }

            // Turned toward the camera, the faces' own outlines carry it: the near face, and the
            // far face showing past it (the polished edge between them).
            float tA = (sign(ow) * STUDIO4_TH - ow) / dwS;   // through the near face
            float tB = (-sign(ow) * STUDIO4_TH - ow) / dwS;  // … and out of the far one
            tA = clamp(tA, 0.0, 40.0); tB = clamp(tB, 0.0, 40.0);
            float fp = max(tA, 0.5) * pixAng;
            float aw = 1.5 * fp / max(cV, 0.04);             // the face's footprint, at most
            float2 pA = o2 + tA * d2;
            float dA = studio4_sd(pA, Q.hs, Q.kind);
            float af = 0.0, aF = 0.0;
            if (sF > 0.0) {
                float2 pB = o2 + tB * d2;
                float dB = studio4_sd(pB, Q.hs, Q.kind);
                // a face's hit point slides per pixel by t·pixAng·(the screen axis, carried along
                // the ray onto the plane); the outline distance by its gradient · that
                float3 sx = float3(1.0, 0.0, 0.0) - (Q.n.x * idw) * rd, sy = cup - dot(Q.n, cup) * idw * rd;
                float2 gA = studio4_sdGrad(pA, Q.hs, Q.kind), gB = studio4_sdGrad(pB, Q.hs, Q.kind);
                float3 gA3 = Q.e * gA.x + float3(0.0, gA.y, 0.0), gB3 = Q.e * gB.x + float3(0.0, gB.y, 0.0);
                float wA = max(tA, 0.5) * pixAng * (abs(dot(gA3, sx)) + abs(dot(gA3, sy)));
                float wB = max(tB, 0.5) * pixAng * (abs(dot(gB3, sx)) + abs(dot(gB3, sy)));
                af = saturate(0.5 - dA / clamp(wA, 0.5 * fp, aw));
                float ab = saturate(0.5 - dB / clamp(wB, 0.5 * fp, aw));
                aF = max(af, ab);
            }
            float a = mix(aL, aF, sF);
            af = mix(afL, min(af, aF), sF);
            if (a > 0.001) {
                float3 Rv = studio4_rgbR(studio4_lamC(Q.lam0, cV), studio4_fres(cV));
                // the face reflects the gallery
                float3 XA = ro + tA * rd;
                float3 rr = reflect(rd, Q.n * (-sign(dwS)));
                float3 Le = studio4_env(XA, rr, Lt, base);
                float3 face = Rv * Le;
                // polished arris: a hair-line of light around the face outline
                float wl = max(0.0015, 0.6 * fp / max(cV, 0.2));
                face += sF * exp(-(dA * dA) / (wl * wl)) * min(1.0, 0.0015 / wl) * 0.5 * (col + Le);
                float3 Lpane = af * face;
                if (a - af > 0.001) {
                    // The polished edge: light gathered by the faces and piped along the glass
                    // (it has passed the coating, so it glows in the transmitted colour, deeper
                    // for the long path), what lies beyond seen down the pane's length, and the
                    // key light's glint on the polish.
                    float3 Tc = saturate(1.0 - Rv);
                    float3 Tn = saturate(1.0 - studio4_rgbR(Q.lam0, 0.04));   // the coating's own colour
                    float3 Tp = 0.12 + 0.88 * Tn * Tn;
                    // a pencil-polished edge: the light gathers in its rounded middle, its arrises
                    // darker (seen edge-on; turned toward the camera it is too thin to show)
                    float prof = mix(0.55 + 0.6 * (1.0 - eu * eu), 1.0, sF);
                    float2 g = normalize((o2 + ts * d2) / (Q.hs * Q.hs) + 1e-6);
                    float3 nE = normalize(Q.e * g.x + float3(0.0, g.y, 0.0) - rd * 0.35);
                    float3 Lk;
                    // the light falling on the glass there (the window's bars cross it too)
                    float3 Ek = studio4_key(Lt, ro + ts * rd, Lk);
                    float3 hv = normalize(Lk - rd);
                    float lit = 0.35 + 0.65 * abs(dot(Q.n, Lk));
                    // (seen edge-on the whole edge glows; turned toward the camera it is only a
                    // sliver beside the face, so it glows less)
                    float3 pipe = Tp * (Lt.skyE * 1.6 + Ek * lit * (room == 2 ? 0.45 : 0.75)) * mix(1.0, 0.4, sF) * prof;
                    float3 rim = pipe + 0.30 * Tc * (0.5 * col + 0.5 * Le)
                               + Ek * (room == 2 ? 0.25 : 0.6) * pow(max(dot(nE, hv), 0.0), 40.0);
                    Lpane += (a - af) * rim;
                }
                acc += thr * Lpane;
                // what gets through: the face transmits T = 1 − R (exactly, for one pane: the
                // fold to RGB is linear); the edge is opaque
                thr *= max(1.0 - (a - af) - af * Rv, 0.0);
            }
        }
    }
    col = acc + thr * col;
    return col * Lt.expo;
}
