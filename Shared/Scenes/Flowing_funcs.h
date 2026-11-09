//  Flowing_funcs.h — file-scope Metal helpers for the Flowing pack. Included by Shaders.metal
//  right above fx_fragment (shared helpers such as gfbm, luma, bandDither are visible).
//  Prefix every function/constant with "flowing_" so packs can't collide.
//
//  The Flowing scenes light in linear RGB, then go through flowing_out (soft shoulder,
//  sRGB encode, dither), so colors add like light and gradients never band.

// Oklab → LINEAR rgb (the shared oklabToSrgb returns display sRGB).
static inline float3 flowing_oklabToLinear(float3 c) {
    float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float q = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    l = l * l * l; m = m * m * m; q = q * q * q;
    return max(float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * q,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * q,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * q), 0.0);
}

// Linear up to `knee`, then an exponential shoulder that approaches 1 (per channel, so
// hot lights desaturate toward white the way film does).
static inline float3 flowing_tone(float3 x) {
    const float k = 0.62;
    x = max(x, 0.0);
    float3 s = k + (1.0 - k) * (1.0 - exp(-(x - k) / (1.0 - k)));
    return select(x, s, x > k);
}

// Linear light → display value with a dither that hides 8-bit steps in dark gradients.
static inline float4 flowing_out(float3 lin, float2 px) {
    return float4(linearToSrgb(flowing_tone(lin)) + bandDither(px) * 1.5, 1.0);
}

// ---------------------------------------------------------------- Currents (54)

// Stream function: its isolines are the streamlines of a divergence-free flow, so drawing
// them gives long, unbroken, never-crossing filaments (LIC would smear into fur).
// Returns (ψ, ∂ψ/∂q) with the gradient analytic, so strand widths are measured from the
// exact line spacing (a 2×2-quad fwidth stair-stepped the strand edges, which crawled).
static inline float3 flowing_stream(float2 q, float ts, float s) {
    float A1 = q.y * 1.15 + ts * 0.9 + s, A2 = q.x * 0.80 - ts * 0.7 + s * 1.7;
    float2 w = q + 0.45 * float2(sin(A1), sin(A2));
    float B1 = w.x * 1.1 + ts * 0.4 + s * 3.1, B2 = w.x * 2.7 - w.y * 1.9 + ts * 0.5 + s * 2.3;
    float psi = w.y + 0.25 * sin(B1) + 0.07 * sin(B2);
    float cB2 = cos(B2);
    float2 pw = float2(0.275 * cos(B1) + 0.189 * cB2, 1.0 - 0.133 * cB2);       // ∂ψ/∂w
    float2 g = float2(pw.x + pw.y * 0.36 * cos(A2), pw.x * 0.5175 * cos(A1) + pw.y);
    // two slow eddies the strands wrap around (Gaussian vortices, opposite spin)
    float sn = sin(ts * 0.19 + s), cs = cos(ts * 0.19 + s);
    float2 c1 = float2(1.2 * sn, 0.45 * cs);
    float2 c2 = float2(-1.4 * cs, -0.5 * sn) + float2(0.3, 0.0);
    float e1 = 0.30 * exp(-dot(q - c1, q - c1) * 2.2), e2 = 0.24 * exp(-dot(q - c2, q - c2) * 2.6);
    psi += e1 - e2;
    g += -4.4 * e1 * (q - c1) + 5.2 * e2 * (q - c2);
    return float3(psi, g);
}

// ---------------------------------------------------------------- Lava Lamp (55)

// Sum of compact (1 - r²/R²)³ kernels, one per blob, with its analytic gradient.
// p is y-up. Returns (field, ∂f/∂x, ∂f/∂y). `mound` gets (height, ∂/∂x) of the bulge the pool
// raises under blobs settling into it: wider than the blob, so two blobs resting side by side
// sit on one swell of wax instead of trapping a pocket of liquid between them.
static inline float3 flowing_lavaField(float2 p, float ts, int n, float size, float seed, float spanX,
                                       thread float2& mound) {
    float f = 0.0;
    float2 g = float2(0.0);
    mound = float2(0.0);
    for (int i = 0; i < 10; ++i) {
        if (i >= n) break;
        float fi = float(i) + seed;
        float h1 = hash21(float2(fi, 1.7)), h2 = hash21(float2(fi, 9.2));
        float h3 = hash21(float2(fi * 1.3, 4.4)), h4 = hash21(float2(fi, 6.1));
        float w = 0.55 + 0.6 * h1;
        float ph = ts * w + h2 * 6.2831853;
        // near-constant rise/sink speed with eased turns (a pure sine would dwell at the ends)
        float tri = 1.0 - 4.0 * abs(fract(ph * 0.15915494 + 0.25) - 0.5);   // = asin(sin ph)·2/π
        float yy = mix(sin(ph), tri, 0.65);
        float vy = cos(ph);
        float lane = (float(i) + 0.5) / float(n) - 0.5 + (h3 - 0.5) * 0.6 / float(n);
        float2 c = float2(lane * spanX + 0.05 * sin(ts * 0.7 * w + h4 * 6.0), yy * (0.26 + 0.17 * h3) - 0.02);
        float r = size * (0.085 + 0.075 * h4);
        float sy = 1.0 + 0.45 * abs(vy) * (1.0 - 0.5 * h1);   // stretch along the motion
        float sx = rsqrt(sy);                                  // keep the area
        float2 d = p - c;
        float lowK = smoothstep(-0.10, -0.34, c.y);
        float Wb = 2.6 * r, xb = d.x / Wb;
        if (lowK > 0.0 && abs(xb) < 1.0) {
            float kb = 1.0 - xb * xb;
            mound += lowK * float2(kb * kb, -4.0 * kb * xb / Wb);
        }
        float2 e = float2(d.x / sx, d.y / sy);
        float R2 = r * r * 4.0;
        float q = dot(e, e) / R2;
        if (q < 1.0) {
            float a = 1.0 - q;
            f += a * a * a;
            g += -6.0 * a * a * float2(e.x / sx, e.y / sy) / R2;
        }
    }
    return float3(f, g);
}

// Studio-ish environment seen in the glossy wax: a large soft window upper-left, a tall thin
// strip right, and the warm lamp glow from below. Softboxes have a hot plateau and a soft
// shoulder (1 / (1 + d⁶)), so highlights read as light sources, not cut-out shapes.
// r is a reflection vector (y up, z to viewer).
static inline float3 flowing_lavaEnv(float3 r, float3 warm) {
    float2 d1 = (r.xy - float2(-0.36, 0.42)) / float2(0.24, 0.29);
    float q1 = dot(d1, d1);
    float win = 1.0 / (1.0 + q1 * q1 * q1);
    float2 d2 = (r.xy - float2(0.55, 0.15)) / float2(0.05, 0.36);
    float q2 = dot(d2, d2);
    float strip = 1.0 / (1.0 + q2 * q2 * q2);
    float bulb = smoothstep(-0.25, -0.85, r.y);
    float3 c = float3(1.0, 0.97, 0.93) * (win * (1.25 + 0.35 * smoothstep(0.0, -0.6, d1.y)) + strip * 0.45);
    return c + warm * bulb * 0.8;
}

// ---------------------------------------------------------------- Ink Bloom (56)

// Velocity of the water: the curl of a stream function built from two drifting cellular
// vortex lattices plus a gentle shear, so it is divergence-free (area-preserving) — ink
// carried by it stretches into filaments and spirals instead of smearing. y down.
static inline float2 flowing_inkVel(float2 x, float tau) {
    float ax = 2.1 * x.x + 1.1 * sin(tau * 0.23), by = 1.8 * x.y + tau * 0.17;
    float sa = sin(ax), ca = cos(ax), sb = sin(by), cb = cos(by);
    float2 v = 0.30 * float2(1.8 * sa * cb, -2.1 * ca * sb);
    float cx = 3.9 * x.x - 1.1 * x.y - tau * 0.21 + 1.3, dy = 3.4 * x.y + 0.8 * x.x + 1.2 * cos(tau * 0.19);
    float sc = sin(cx), cc = cos(cx), sd = sin(dy), cd = cos(dy);
    // ψ2 = A sin(cx) sin(dy): ∂ψ/∂x = A(3.9 cc sd + 0.8 sc cd), ∂ψ/∂y = A(−1.1 cc sd + 3.4 sc cd)
    v += 0.085 * float2(-1.1 * cc * sd + 3.4 * sc * cd, -(3.9 * cc * sd + 0.8 * sc * cd));
    v.x += 0.12 * sin(x.y * 0.9 + tau * 0.13);
    return v;
}

// Where did the water now at d sit before a vortex core at c turned it by the integrated
// angle G·e^{−ρ²/rc²}? Rotation about a centre by any θ(ρ) is area-preserving, so ink carried
// through it keeps its mass and rolls into spirals; the Gaussian keeps the swirl local (a
// pair's far fields cancel). (Inverse = rotate by −θ.)
static inline float2 flowing_untwirl(float2 d, float2 c, float G, float rc2) {
    float2 v = d - c;
    float r2 = dot(v, v);
    float th = G * exp(-r2 / rc2);
    float s = sin(th), co = cos(th);
    return c + float2(co * v.x + s * v.y, co * v.y - s * v.x);
}

// ---------------------------------------------------------------- Fireflies (57)

// One depth layer of fireflies: a jittered grid, one candidate fly per cell, each wandering
// within its cell so only the 2×2 nearest cells can reach a pixel. Out-of-focus flies spread
// into bokeh discs (with the brighter rim real lenses give them); in-focus ones are a hot
// core plus halo. Returns linear light.
static inline float3 flowing_fireflyLayer(float2 p, float z, float cs, float t, float focus, float blur,
                                          float sizeK, float countK, float3 glow, float pixel, float seed) {
    float2 g = p / cs;
    float2 cell0 = floor(g - 0.5);                              // 2×2 block around the pixel
    float3 acc = float3(0.0);
    for (int dy = 0; dy <= 1; ++dy)
    for (int dx = 0; dx <= 1; ++dx) {
        float2 c = cell0 + float2(dx, dy);
        float3 h = pcg3(float3(c + 512.0, seed));
        // meadow flies stay low; the near (bokeh) layer can be anywhere
        float cy = (c.y + 0.5) * cs;
        float lowBias = mix(smoothstep(0.30, -0.15, cy), 1.0, smoothstep(0.75, 1.0, z));
        lowBias = max(lowBias, 0.20 * smoothstep(0.30, 0.0, cy));   // a few wander up into the trees
        if (h.z > countK * lowBias) continue;
        float zf = clamp(z + (fract(h.y * 17.3) - 0.5) * 0.22, 0.0, 1.0);   // each fly its own depth
        float coc = blur * abs(zf - focus) * 0.075;             // circle of confusion (p units)
        float rc = sizeK * mix(0.0016, 0.0042, zf);             // in-focus core radius
        float R = clamp(sqrt(coc * coc + rc * rc), pixel, cs * 0.30);
        float defocus = smoothstep(rc * 0.8, rc * 3.0, coc);
        float soft = max(pixel * 1.2, R * 0.08);
        float energy = mix(1.0, clamp(2.0 * rc / R, 0.06, 1.0), defocus);
        float haloW = min(rc * 4.0 + coc * 0.4, cs * 0.12);
        float2 pos = (c + 0.5) * cs + cs * float2(0.16 * sin(t * (0.13 + 0.12 * h.x) + h.y * 6.2831853),
                                                  0.16 * sin(t * (0.11 + 0.10 * h.y) + h.x * 6.2831853 + 1.3))
                   + cs * 0.12 * (h.xy - 0.5);
        float d = length(p - pos);
        // a slow glow-up/fade-down flash with long dim stretches between
        float ph = t * (0.20 + 0.16 * h.y) + h.x * 50.0;
        float flash = smoothstep(0.35, 0.97, sin(ph));
        flash *= flash;
        float lum = (0.03 + flash) * (0.35 + 0.65 * fract(h.x * 13.7));
        float core = exp(-d * d / (rc * rc)) * 1.8;
        float disc = smoothstep(R, R - soft, d) * (0.62 + 0.5 * smoothstep(R * 0.3, R * 0.97, d));
        float shape = mix(core, disc, defocus) * energy;
        float edge = smoothstep(cs * 0.45, cs * 0.25, d);          // keep the halo inside the 2×2
        float halo = exp(-d / haloW) * mix(0.22, 0.05, defocus) * edge;
        float3 tint = glow * (1.0 + float3(0.10, -0.03, -0.12) * (fract(h.z * 7.0) * 2.0 - 1.0));
        acc += tint * (shape + halo) * lum;
    }
    return acc;
}
