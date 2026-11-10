//  Retro_funcs.h — file-scope Metal helpers for the Retro pack. Included by Shaders.metal
//  right above fx_fragment (shared helpers such as gfbm, luma, bandDither are visible).
//  Prefix every function/constant with "retro_" so packs can't collide.

// ---------------------------------------------------------------- shared

// Box-filtered coverage of a line of half-width lw at distance d (>= 0), for a pixel
// footprint w. Exact for one isolated line; energy-conserving when the line is sub-pixel.
static inline float retro_lineCov(float d, float lw, float w) {
    w = max(w, 1e-5);
    float lo = max(d - 0.5 * w, -lw), hi = min(d + 0.5 * w, lw);
    return max(hi - lo, 0.0) / w;
}

// Display-referred output: filmic shoulder on linear HDR, then sRGB encode + dither.
static inline float3 retro_out(float3 lin, float2 px) {
    float3 c = linearToSrgb(aces(lin));
    return c + bandDither(px) * 1.5;
}

// Hue-rotate a linear color in Oklab (keeps lightness and chroma).
static inline float3 retro_hue(float3 lin, float a) {
    return srgbToLinear(oklabToSrgb(oklabHue(srgbToOklab(linearToSrgb(lin)), a)));
}

// Cheap hue rotation: rotate the colour about the grey axis (no colour-space round trip).
static inline float3 retro_hueRGB(float3 c, float a) {
    const float3 k = float3(0.57735027);
    float cs = cos(a), sn = sin(a);
    return max(c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs), 0.0);
}

// ---------------------------------------------------------------- 62 Neon Horizon

// Cheap 1D gradient noise in ~[-0.5, 0.5].
static inline float retro_gn1(float x) {
    float i = floor(x), f = x - i;
    float g0 = fract(sin(i * 127.1) * 43758.5453) * 2.0 - 1.0;
    float g1 = fract(sin((i + 1.0) * 127.1) * 43758.5453) * 2.0 - 1.0;
    float w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(g0 * f, g1 * (f - 1.0), w);
}

// Ridged 1D mountain profile in ~[0, 1].
static inline float retro_ridge(float x, float seed) {
    float s = 0.0, a = 0.55, f = 1.0;
    for (int i = 0; i < 5; ++i) {
        float n = 1.0 - abs(retro_gn1(x * f + seed + float(i) * 17.3) * 1.9);
        s += a * n * n;
        f *= 2.07; a *= 0.47;
    }
    return s;
}

struct RetroSynth {
    float3 neon, sunTop, sunMid, sunBot, top, haze, mtnDark;
    float sunR, sunY, mtn, stripes, stars, clouds, t, sunGain, sunBlur;
};

// One mountain layer over sky colour `col`: dark body with haze at its foot, ridge-echo
// contour lines and a neon rim backlit by the sun. h = ridge height at this column.
static inline float3 retro_mtnLayer(float3 col, float2 q, float h, float aa, float hazeAmt,
                                    float lineAmt, float rimAmt, thread const RetroSynth& s) {
    float y = q.y;
    float cov = clamp((h - y) / aa + 0.5, 0.0, 1.0);
    float rel = clamp(y / max(h, 1e-4), 0.0, 1.0);
    float3 body = mix(s.haze * 0.9, s.mtnDark, smoothstep(0.0, 0.85, rel) * (1.0 - hazeAmt * 0.55));
    // ridge-echo contours: scaled copies of the silhouette, fading into the haze below
    float v = rel * 5.0;
    float fw = max(fwidth(v), 1e-4);
    float dl = abs(fract(v + 0.5) - 0.5);
    float ln = retro_lineCov(dl, 0.6 * fw, fw) * smoothstep(0.55, 0.12, fw) * smoothstep(0.05, 0.6, rel);
    body += s.neon * ln * lineAmt * (0.35 + 0.65 * rel);
    // backlit rim + a thin glow into the sky above the ridge
    float dr = h - y;
    float rim = retro_lineCov(abs(dr), 0.7 * aa, aa) * rimAmt;
    float halo = exp(-max(-dr, 0.0) / 0.006) * step(dr, 0.0) * rimAmt * 0.25;
    col = mix(col, body, cov);
    return col + s.neon * (rim * 2.2 + halo);
}

// The sky along tangent-plane coords q (x right, y up, 0 = horizon). `aa` is the edge width
// (one pixel, or wider for glossy reflections); `stretch` elongates the sun vertically.
static inline float3 retro_synthSky(float2 q, float aa, float stretch, float withStars,
                                    thread const RetroSynth& s) {
    float y = max(q.y, 0.0);
    float3 col = mix(s.top, s.haze, exp(-y / 0.16));

    if (withStars > 0.5 && s.stars > 0.0) {
        float k = 1.0 / 0.016;
        float2 c = floor(q * k);
        float3 h = pcg3(float3(c, 91.0));
        float2 sp = (c + 0.2 + 0.6 * h.xy) / k;
        float d = length(q - sp);
        float big = h.z * h.z * h.z;
        float tw = 0.65 + 0.35 * sin(s.t * (1.0 + 2.0 * h.x) + h.y * 40.0);
        float I = exp(-d * d / (aa * aa * (0.9 + 1.6 * big))) * step(h.z, 0.55) * (0.25 + 1.4 * big) * tw;
        col += mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.85, 0.75), h.x) * I * s.stars * smoothstep(0.06, 0.4, q.y);
    }

    // sun: vertical gradient disk, lower half cut by scrolling stripes that widen downward
    float2 d = q - float2(0.0, s.sunY);
    d.y /= stretch;
    float r = length(d);
    float sv = d.y / s.sunR;
    float aaS = aa + s.sunBlur;                       // glossy reflections blur the sun the most
    float disk = clamp((s.sunR - r) / aaS + 0.5, 0.0, 1.0);
    float ph = sv * 5.5 + s.t * 0.18;
    float fw = max(fwidth(ph), 5.5 * aaS / s.sunR);
    float gapW = clamp((0.3 - sv) * 0.62, 0.0, 0.8) * s.stripes;
    float dc = abs(fract(ph + 0.5) - 0.5);
    disk *= 1.0 - retro_lineCov(dc, 0.5 * gapW, fw);
    float3 sunCol = mix(s.sunBot, s.sunMid, smoothstep(-0.55, 0.35, sv));
    sunCol = mix(sunCol, s.sunTop, smoothstep(0.35, 0.95, sv));
    float rg = length(q - float2(0.0, s.sunY));
    col += s.sunBot * (exp(-max(rg - s.sunR, 0.0) * 14.0) * 0.22 + exp(-rg * 3.0) * 0.05) * (0.5 + 0.5 * s.sunGain);
    col = mix(col, sunCol * s.sunGain, disk);

    // horizon glow
    col += s.haze * exp(-y / 0.03) * 0.5;

    // thin streaks of cloud drifting across the sun, lit from behind at their edges
    float band = exp(-pow((q.y - s.sunY - 0.05) / 0.045, 2.0)) + 0.8 * exp(-pow((q.y - s.sunY - 0.2) / 0.03, 2.0));
    if (band * s.clouds > 0.02) {
        float2 cq = float2(q.x * 1.6 + s.t * 0.006, q.y * 18.0);
        float n = gfbm(cq + float2(0.0, 4.0), 4);
        float dens = smoothstep(0.0, 0.3, n + 0.3 * band - 0.12) * band * s.clouds;
        float edge = smoothstep(0.0, 0.25, dens) * (1.0 - smoothstep(0.25, 0.8, dens));
        float lit = exp(-rg * 3.5);
        float3 cc = s.top * 0.8 + s.haze * 0.7 + s.sunBot * edge * lit * 0.9;
        col = mix(col, cc, clamp(dens * 1.4, 0.0, 0.92));
    }

    // two mountain ranges; a valley in the middle keeps the sun in view
    float ax = abs(q.x);
    float hf = s.mtn * 0.16 * retro_ridge(q.x * 2.1 + 3.0, 1.7) * mix(0.14, 1.0, smoothstep(0.03, 0.6, ax));
    float hn = s.mtn * 0.12 * retro_ridge(q.x * 3.3 - 9.0, 5.1) * smoothstep(0.25, 0.9, ax);
    float rimK = mix(0.4, 1.0, withStars);                // rims seen in the floor: dimmer, so they read as reflections
    col = retro_mtnLayer(col, q, hf, aa, 0.8, 0.0, 0.45 * rimK, s);
    col = retro_mtnLayer(col, q, hn, aa, 0.2, withStars * 0.8, rimK, s);
    return col;
}

// ---------------------------------------------------------------- 65 Light Tunnel

// Ray vs the inside of the tunnel (axis = z, apothem 1). shape 0 = round, 1 = square,
// 2 = hexagon. Returns t; n = inward normal; u = perimeter coordinate in [0, 1).
static inline float retro_tunHit(float3 ro, float3 rd, int shape, thread float3& n, thread float& u) {
    if (shape == 0) {
        float a = dot(rd.xy, rd.xy), b = dot(ro.xy, rd.xy), c = dot(ro.xy, ro.xy) - 1.0;
        float t = (-b + sqrt(max(b * b - a * c, 0.0))) / max(a, 1e-6);
        float2 h = ro.xy + rd.xy * t;
        n = float3(-h / max(length(h), 1e-4), 0.0);
        u = atan2(h.y, h.x) * 0.15915494 + 0.5;
        return t;
    }
    int N = shape == 1 ? 4 : 6;
    float off = shape == 1 ? 0.0 : 1.5707963;
    float tb = 1e9; int kb = 0; float2 nb = float2(1.0, 0.0);
    for (int k = 0; k < N; ++k) {
        float ang = off + 6.2831853 * float(k) / float(N);
        float2 nk = float2(cos(ang), sin(ang));
        float dn = dot(rd.xy, nk);
        float tk = dn > 1e-5 ? (1.0 - dot(ro.xy, nk)) / dn : 1e9;
        if (tk < tb) { tb = tk; kb = k; nb = nk; }
    }
    float2 h = ro.xy + rd.xy * tb;
    float hw = tan(3.14159265 / float(N));
    float sTan = dot(h, float2(-nb.y, nb.x)) / hw;              // -1..1 across the face
    n = float3(-nb, 0.0);
    u = (float(kb) + 0.5 + 0.5 * sTan) / float(N);
    return tb;
}

struct RetroTun {
    float3 metal, neon, neon2;
    float nA, plen, ringEvery, lights, t, speed, twist;
    int shape;
};

// Ring chase brightness for ring index ri: a bright pulse runs forward down the tunnel.
static inline float retro_tunChase(float ri, float t) {
    return 0.3 + 0.7 * pow(0.5 + 0.5 * sin(ri * 0.7 - t * 3.0), 6.0);
}

// Emitted light at perimeter coord u (0..1) and depth z. `widen` blurs the lights (glossy
// reflections). Rings sit in every ringEvery-th seam and chase forward. Rails run along the
// tunnel: two spiralling ones in the round tunnel, one per corner in the polygonal ones.
// Every light is a glass tube: a white-hot filament core inside a saturated body, with a soft
// halo around it (all box-filtered by the pixel footprint, so they stay crisp, never jaggy).
static inline float3 retro_tunTube(float d, float w, float fd, float widen, float3 c) {
    float fp = max(fd, 1e-4);
    float wb = w + widen * 0.5;
    float body = retro_lineCov(d, wb, fp) * (w / wb);
    float core = retro_lineCov(d, w * 0.32 + widen * 0.15, fp) * (w / wb);
    float halo = exp(-d / (w * 2.5 + 0.04 + widen)) * 0.10 + exp(-d / (0.22 + widen)) * 0.025;
    return c * (body + halo) + (c * 0.35 + 0.65) * core * 1.4;
}

static inline float3 retro_tunEmit(float u, float z, float fz, float widen, thread const RetroTun& s) {
    float rs = s.ringEvery * s.plen;
    float ri = floor(z / rs + 0.5);
    float dz = abs(z - ri * rs);                                       // world distance to the ring
    float3 e = retro_tunTube(dz, 0.035, fz + 1e-4, widen, s.neon) * retro_tunChase(ri, s.t) * 5.0;

    float du, fu;
    if (s.shape == 0) {
        float ua = fract(u - z * s.twist * 0.012);
        du = min(abs(ua - 0.25), abs(ua - 0.75)) * 6.2831853;
        fu = fwidth(ua) * 6.2831853;
    } else {
        float N = s.shape == 1 ? 4.0 : 6.0;
        float f = fract(u * N);
        float faceW = 2.0 * tan(3.14159265 / N);
        du = min(f, 1.0 - f) * faceW;
        fu = min(fwidth(u * N), fwidth(fract(u * N + 0.5))) * faceW;   // u wraps 1 → 0 at one corner
    }
    float dash = smoothstep(0.3, 0.5, fract(z * 0.2 - s.t * (0.6 + s.speed))) * 0.85 + 0.15;
    e += retro_tunTube(du, 0.014, max(fu, 1e-4), widen, s.neon2) * dash * 3.0;
    return e * s.lights;
}

// Diffuse light reaching wall point P with normal n: a lamp on the camera plus the three
// nearest rings (each throws a pool of its colour onto the walls around it).
static inline float3 retro_tunLight(float3 P, float3 n, float3 cam, thread const RetroTun& s) {
    float3 Lv = cam - P;
    float d2 = dot(Lv, Lv);
    float3 c = float3(0.9, 0.93, 1.0) * max(dot(n, Lv * rsqrt(d2)), 0.0) * 0.9 / (1.0 + d2 * 0.18);
    float rs = s.ringEvery * s.plen;
    float r0 = floor(P.z / rs + 0.5);
    for (int k = -1; k <= 1; ++k) {
        float ri = r0 + float(k);
        float dz = P.z - ri * rs;
        c += s.neon * retro_tunChase(ri, s.t) * s.lights * 1.4 / (1.0 + dz * dz * 2.5);
    }
    return c;
}

// ---------------------------------------------------------------- 63 Pipeworks

#define RETRO_PIPE_RUNS 8
#define RETRO_REFL_MAX 3.6      // pipe-in-pipe reflections fade out toward this range (then the studio)

struct RetroPipes {
    float3 G;          // lattice size in cells
    float3 org;        // world position of cell (0,0,0)
    float r, rb;       // pipe radius; ball-joint radius (0 = rounded elbows)
    float rate;        // cells grown per second
    float lt;          // time into the current cycle
    float cyc;         // cycle seed
    int count;
};

// Two-multiply integer hash (lowbias32).
static inline uint retro_hashu(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}

// The walk of one pipe: deterministic from the cycle seed, identical for every pixel.
struct RetroWalk {
    float3 pos;        // current lattice cell
    int ax;            // axis of the previous run
    float used, grown; // cells walked so far / cells grown by now
    uint seed;
};
static inline RetroWalk retro_walkInit(thread const RetroPipes& s, int k) {
    RetroWalk w;
    w.seed = uint(s.cyc) * 7919u + uint(k) * 104729u;
    uint h0 = retro_hashu(w.seed ^ 0x9e3779b9u);
    w.pos = floor(float3(float(h0 & 1023u), float((h0 >> 10) & 1023u), float((h0 >> 20) & 1023u)) * (1.0 / 1024.0) * s.G);
    uint a0 = h0 >> 30;
    w.ax = a0 == 3u ? 0 : int(a0);
    w.used = 0.0;
    float x = max(s.lt - float(k) * 0.3, 0.0);
    w.grown = (x + 1.8 * (1.0 - exp(-x / 0.9))) * s.rate;     // a quick first burst, then steady growth
    return w;
}
// Next straight run, packed into a uint (0 = not grown yet): start cell (3×3 bits), axis
// (2 bits), direction (1 bit), grown length in 1/128 cells (10 bits), valid bit.
static inline uint retro_walkStep(thread RetroWalk& w, int j, float3 G) {
    if (w.grown <= w.used) return 0u;
    w.seed = w.seed * 1664525u + 1013904223u;            // sequential LCG: one multiply per step
    uint h = w.seed ^ (w.seed >> 16);
    int nax = w.ax + 1 + int(h & 1u);
    nax = j == 0 ? w.ax : (nax >= 3 ? nax - 3 : nax);
    float sg = (h & 2u) != 0u ? 1.0 : -1.0;
    float hz = float((h >> 8) & 1023u) * (1.0 / 1024.0);
    float L = 1.0 + floor(hz * hz * 6.5);
    float3 m = float3(nax == 0 ? 1.0 : 0.0, nax == 1 ? 1.0 : 0.0, nax == 2 ? 1.0 : 0.0);
    float p = dot(w.pos, m), hiR = dot(G, m) - 1.0 - p, loR = p;
    float room = sg > 0.0 ? hiR : loR, other = sg > 0.0 ? loR : hiR;
    if (room < L && other > room) { sg = -sg; room = other; }
    L = clamp(L, 1.0, max(room, 1.0));
    float g = min(L, w.grown - w.used);
    uint3 c = uint3(w.pos);
    uint packed = c.x | (c.y << 3) | (c.z << 6) | (uint(nax) << 9) | (sg > 0.0 ? 2048u : 0u)
                | (uint(clamp(g * 128.0, 1.0, 1023.0)) << 12) | (1u << 22);
    w.pos += m * (sg * L); w.ax = nax; w.used += L;
    return packed;
}

// Unpack a run of pipe k into world endpoints a → b and its axis.
static inline void retro_pipeDecode(uint u, int k, thread const RetroPipes& s,
                                    thread float3& a, thread float3& b, thread int& ax) {
    ax = int((u >> 9) & 3u);
    float g = float((u >> 12) & 1023u) * (1.0 / 128.0) * ((u & 2048u) != 0u ? 1.0 : -1.0);
    a = s.org + float3(float(u & 7u), float((u >> 3) & 7u), float((u >> 6) & 7u)) + (float(k) + 0.5) / float(s.count);
    b = a + float3(ax == 0 ? g : 0.0, ax == 1 ? g : 0.0, ax == 2 ? g : 0.0);
}

// Primary-ray state: the two nearest surfaces and their edge coverage.
struct RetroPipeHit {
    float t1, a1, t2, a2;
    int k1, k2;
    uint u1, u2;       // packed runs (bit 23 set = that run's ball joint)
};
static inline void retro_pipeInsert(thread RetroPipeHit& H, float tt, float al, int k, uint u) {
    if (tt < H.t1) {
        H.t2 = H.t1; H.a2 = H.a1; H.k2 = H.k1; H.u2 = H.u1;
        H.t1 = tt; H.a1 = al; H.k1 = k; H.u1 = u;
    } else if (tt < H.t2) {
        H.t2 = tt; H.a2 = al; H.k2 = k; H.u2 = u;
    }
}
static inline float3 retro_segClosest(float3 p, float3 pa, float3 pb);
// Surface normal at P on packed run u of pipe k.
static inline float3 retro_pipeNormal(float3 P, uint u, int k, thread const RetroPipes& s) {
    float3 a, b; int ax;
    retro_pipeDecode(u, k, s, a, b, ax);
    if (((u >> 23) & 1u) != 0u) b = a;
    return normalize(P - retro_segClosest(P, a, b));
}
// Distance from the ray (ro, rd) to the infinite axis-aligned line through a along axis ax.
// ip = 1 / |rd projected off each axis| (precomputed per ray). Cheap reject test.
static inline float retro_lineDist(float3 ro, float3 rd, float3 ip, float3 a, int ax) {
    float3 d = a - ro;
    if (ax == 0) return abs(d.y * rd.z - d.z * rd.y) * ip.x;
    if (ax == 1) return abs(d.z * rd.x - d.x * rd.z) * ip.y;
    return abs(d.x * rd.y - d.y * rd.x) * ip.z;
}
static inline float3 retro_invPerp(float3 rd) {
    return rsqrt(max(float3(rd.y * rd.y + rd.z * rd.z, rd.z * rd.z + rd.x * rd.x, rd.x * rd.x + rd.y * rd.y), 1e-8));
}
// Squared distance from point P to the infinite axis-aligned line through a along axis ax.
static inline float retro_lineDist2P(float3 P, float3 a, int ax) {
    float3 d = P - a;
    float3 dd = d * d;
    return ax == 0 ? dd.y + dd.z : (ax == 1 ? dd.z + dd.x : dd.x + dd.y);
}

// Ray vs capsule (segment pa–pb, radius r): exact hit t, or -1.
static inline float retro_capHit(float3 ro, float3 rd, float3 pa, float3 pb, float r) {
    float3 ba = pb - pa, oa = ro - pa;
    float baba = dot(ba, ba), bard = dot(ba, rd), baoa = dot(ba, oa), rdoa = dot(rd, oa), oaoa = dot(oa, oa);
    float a = baba - bard * bard, b = baba * rdoa - baoa * bard, c = baba * oaoa - baoa * baoa - r * r * baba;
    float h = b * b - a * c;
    if (a > 1e-6) {
        if (h < 0.0) return -1.0;                        // misses the infinite cylinder
        float t = (-b - sqrt(h)) / a;
        float y = baoa + t * bard;
        if (y > 0.0 && y < baba) return t;
    }
    // otherwise the hit (if any) is on one of the end spheres: keep the nearer
    float tb = -1.0;
    for (int e = 0; e < 2; ++e) {
        float3 o2 = e == 0 ? oa : ro - pb;
        float b2 = dot(rd, o2), c2 = dot(o2, o2) - r * r, h2 = b2 * b2 - c2;
        if (h2 > 0.0) { float t2 = -b2 - sqrt(h2); if (t2 > 0.0 && (tb < 0.0 || t2 < tb)) tb = t2; }
    }
    return tb;
}

// Closest approach of the ray to segment pa–pb: (t along ray, distance).
static inline float2 retro_segDist(float3 ro, float3 rd, float3 pa, float3 pb) {
    float3 ba = pb - pa, oa = ro - pa;
    float baba = max(dot(ba, ba), 1e-8), bard = dot(ba, rd), baoa = dot(ba, oa), rdoa = dot(rd, oa);
    float den = baba - bard * bard;
    float sP = den > 1e-6 ? clamp((baoa - rdoa * bard) / den, 0.0, 1.0) : 0.0;
    float t = max(sP * bard - rdoa, 0.0);
    sP = clamp(dot(ro + rd * t - pa, ba) / baba, 0.0, 1.0);
    return float2(t, length(oa + rd * t - ba * sP));
}

static inline float3 retro_segClosest(float3 p, float3 pa, float3 pb) {
    float3 ba = pb - pa;
    return pa + ba * clamp(dot(p - pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
}

// HSV helpers (cheap, trig-free) for the pipe palette.
static inline float3 retro_rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-6)), d / (q.x + 1e-6), q.x);
}
static inline float3 retro_hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}
// Blend two display colours for the pipe palette along the shorter way round the hue
// circle (red → blue passes through violet, not grey). Returns linear RGB.
static inline float3 retro_palMix(float3 a, float3 b, float f) {
    float3 ha = retro_rgb2hsv(a), hb = retro_rgb2hsv(b);
    if (ha.y < 0.05) ha.x = hb.x;
    if (hb.y < 0.05) hb.x = ha.x;
    float dh = hb.x - ha.x;
    dh -= floor(dh + 0.5);
    return srgbToLinear(retro_hsv2rgb(float3(fract(ha.x + dh * f), mix(ha.y, hb.y, f), mix(ha.z, hb.z, f))));
}

// Dark studio for reflections: a big overhead softbox, a tall strip light on the left and
// a faint warm bounce, over a near-black gradient. `soft` widens every light's falloff (what a
// glossy rather than mirror surface sees).
static inline float3 retro_studioS(float3 d, float soft) {
    float3 c = mix(float3(0.006, 0.007, 0.010), float3(0.020, 0.022, 0.028), smoothstep(-0.3, 0.8, d.y));
    // overhead softbox (rectangle in the direction's xz when looking up)
    float2 q = d.xz / max(d.y, 0.05);
    float bw = 0.08 + 0.45 * soft;
    float box = smoothstep(bw, 0.0, max(abs(q.x + 0.25) - 0.75, abs(q.y - 0.1) - 0.45)) * smoothstep(-0.05 * soft, 0.0, d.y);
    c += float3(1.0, 0.98, 0.95) * box * 3.2;
    // vertical strip on the left
    float az = atan2(d.x, d.z);
    float sw = 0.05 + 0.30 * soft;
    float strip = smoothstep(sw, 0.0, abs(az + 1.75) - 0.09) * smoothstep(0.75 + 0.3 * soft, 0.55 - 0.4 * soft, abs(d.y - 0.1));
    c += float3(0.85, 0.92, 1.0) * strip * 2.2 * (1.0 - 0.45 * soft);
    // small warm kicker behind-right
    float kick = smoothstep(0.06 + 0.3 * soft, 0.0, abs(az - 2.4) - 0.16) * smoothstep(0.35 + 0.2 * soft, 0.2 - 0.2 * soft, abs(d.y - 0.05));
    c += float3(1.0, 0.75, 0.5) * kick * 1.1 * (1.0 - 0.4 * soft);
    return c;
}
static inline float3 retro_studio(float3 d) { return retro_studioS(d, 0.0); }

// Primary-ray test of one run (capsule a→b) plus its ball joint.
static inline void retro_pipeP1(thread RetroPipeHit& H, float3 ro, float3 rd, float3 ipr, float aaM, float pixA,
                                uint u, float3 a, float3 b, int ax, int k, bool ball, thread const RetroPipes& s) {
    if (retro_lineDist(ro, rd, ipr, a, ax) < s.r + aaM) {
        float2 sd = retro_segDist(ro, rd, a, b);
        float al = clamp((s.r - sd.y) / (sd.x * pixA) + 0.5, 0.0, 1.0);
        if (al > 0.0) {
            float th = sd.y < s.r ? retro_capHit(ro, rd, a, b, s.r) : -1.0;
            retro_pipeInsert(H, th > 0.0 ? th : sd.x, al, k, u);
        }
    }
    if (ball) {
        float3 v = a - ro;
        float tc = dot(v, rd);
        float d = sqrt(max(dot(v, v) - tc * tc, 0.0));
        float al = clamp((s.rb - d) / (tc * pixA) + 0.5, 0.0, 1.0);
        if (al > 0.0) retro_pipeInsert(H, d < s.rb ? tc - sqrt(s.rb * s.rb - d * d) : tc, al, k, u | (1u << 23));
    }
}

// Secondary state at the shaded point: reflection hit, soft shadow, occlusion.
struct RetroPipeSec {
    float tr; int kr; uint ur;
    float sh, occ;
};
static inline void retro_pipeP2(thread RetroPipeSec& S, float3 P, float3 N, float3 Po, float3 R, float3 ipR,
                                float3 Lk, float3 ipL, uint u, float3 a, float3 b, int ax, int k, thread const RetroPipes& s) {
    if (retro_lineDist(Po, R, ipR, a, ax) < s.r) {
        float th = retro_capHit(Po, R, a, b, s.r);
        if (th > 0.0 && th < min(S.tr, RETRO_REFL_MAX)) { S.tr = th; S.kr = k; S.ur = u; }
    }
    if (retro_lineDist(Po, Lk, ipL, a, ax) < s.r + 0.4) {
        float2 ss = retro_segDist(Po, Lk, a, b);
        S.sh = min(S.sh, clamp((ss.y - s.r) / (0.03 + ss.x * 0.07), 0.0, 1.0));
    }
    if (retro_lineDist2P(P, a, ax) < 16.0 * s.r * s.r) {
        float3 v = retro_segClosest(P, a, b) - P;
        float dv = max(length(v), s.r);
        S.occ += s.r * s.r / (dv * dv) * max(dot(N, v / dv), 0.0) * smoothstep(4.0 * s.r, 3.0 * s.r, dv);
    }
}

// ---- SIMD-group culling for Pipeworks. A full 32-lane group cooperates: lanes 0…n-1 each
// walk one pipe; every lane then owns up to two runs (slot s holds run g = lane + 32·s,
// i.e. pipe g / RUNS, run g % RUNS), tests them against bounds of the whole group's rays,
// and a ballot tells every pixel which few runs can matter to it.
struct RetroSegs { uint s0, s1; int k0, k1; };

static inline RetroSegs retro_pipeGather(thread const RetroPipes& s, uint lane) {
    RetroWalk w = retro_walkInit(s, min(int(lane), s.count - 1));
    RetroSegs g; g.s0 = 0u; g.s1 = 0u;
    uint g0 = lane, g1 = lane + 32u;
    g.k0 = int(g0 / uint(RETRO_PIPE_RUNS)); g.k1 = int(g1 / uint(RETRO_PIPE_RUNS));
    uint j0 = g0 - uint(g.k0) * uint(RETRO_PIPE_RUNS), j1 = g1 - uint(g.k1) * uint(RETRO_PIPE_RUNS);
    ushort src0 = ushort(min(g.k0, 31)), src1 = ushort(min(g.k1, 31));
    // (the slot-count branch is uniform, so the second shuffle is really skipped)
    if (s.count * RETRO_PIPE_RUNS <= 32) {
        for (int j = 0; j < RETRO_PIPE_RUNS; ++j) {
            uint v0 = simd_shuffle(retro_walkStep(w, j, s.G), src0);
            if (uint(j) == j0) g.s0 = v0;
        }
    } else {
        for (int j = 0; j < RETRO_PIPE_RUNS; ++j) {
            uint mine = retro_walkStep(w, j, s.G);
            uint v0 = simd_shuffle(mine, src0), v1 = simd_shuffle(mine, src1);
            if (uint(j) == j0) g.s0 = v0;
            if (uint(j) == j1) g.s1 = v1;
        }
    }
    if (g.k0 >= s.count) g.s0 = 0u;
    if (g.k1 >= s.count) g.s1 = 0u;
    return g;
}

// Can a run (endpoints a, b; valid = grown) touch a cone from origin o along unit axis with
// half-angle slope tanA, inflated by `extra`? (Conservative: the run's farthest depth sets
// the cone radius.)
static inline bool retro_coneCull(bool valid, float3 a, float3 b, float3 o, float3 axis, float tanA, float extra,
                                  float maxT) {
    float2 sd = retro_segDist(o, axis, a, b);
    float ta = dot(a - o, axis), tb = dot(b - o, axis);
    float tmax = max(max(ta, tb), 0.0);
    return valid && sd.y < extra + tanA * tmax && min(ta, tb) < maxT + extra;
}
// Cheaper, looser version via the run's bounding sphere.
static inline bool retro_coneCullS(bool valid, float3 a, float3 b, float rr, float3 o, float3 axis, float tanA,
                                   float extra, float maxT) {
    float3 c = (a + b) * 0.5, v = c - o;
    float rho = length(b - a) * 0.5 + rr;
    float tc = dot(v, axis);
    float d = sqrt(max(dot(v, v) - tc * tc, 0.0));
    return valid && tc > -rho - extra && d < rho + extra + tanA * max(tc + rho, 0.0) && tc - rho < maxT + extra;
}
static inline bool retro_ballCull(bool valid, float3 a, float3 b, float3 c, float rad) {
    return valid && length_squared(retro_segClosest(c, a, b) - c) < rad * rad;
}
static inline uint retro_ballot(bool p) {
    return uint(ulong(simd_vote::vote_t(simd_ballot(p))));
}

// ---------------------------------------------------------------- 64 Light Ribbons

#define RETRO_RB_ECHOES 16      // echoes in a trail (one per SIMD lane; must be <= 32)

// Motion of one polygon vertex: a constant-velocity bounce inside the box [lo, hi] that
// eases slightly into each wall. (ph = start phase, vel = box-widths per unit time.)
static inline float2 retro_rbPos(float2 ph, float2 vel, float tau, float2 lo, float2 hi) {
    float2 u = ph + vel * tau;
    float2 tri = abs(fract(u * 0.5) * 2.0 - 1.0);
    tri = mix(tri, tri * tri * (3.0 - 2.0 * tri), 0.35);
    return lo + (hi - lo) * tri;
}
static inline void retro_rbParams(int sh, int v, thread float2& ph, thread float2& vel) {
    float n = float(sh * 8 + v) + 1.0;
    float3 h = fract(sin(n * float3(12.9898, 78.233, 37.719)) * 43758.5453);
    float3 g = fract(sin(n * float3(93.989, 27.534, 61.17)) * 24634.6345);
    ph = h.xy * 2.0;
    vel = (0.10 + 0.12 * float2(h.z, g.x)) * float2(g.y < 0.5 ? -1.0 : 1.0, g.z < 0.5 ? -1.0 : 1.0);
}

// Inverse bilinear: (u, v) of p in the quad a-b-c-d (a to b = u, a to d = v); outside the
// quad the values run past [0, 1] (or (-9, -9) when there is no solution).
static inline float2 retro_invBilinear(float2 p, float2 a, float2 b, float2 c, float2 d) {
    float2 e = b - a, f = d - a, g = a - b + c - d, h = p - a;
    float k2 = g.x * f.y - g.y * f.x;
    float k1 = (e.x * f.y - e.y * f.x) + (h.x * g.y - h.y * g.x);
    float k0 = h.x * e.y - h.y * e.x;
    float u, v;
    if (abs(k2) < 1e-6) {
        v = -k0 / k1;
        u = (h.x * k1 + f.x * k0) / (e.x * k1 - g.x * k0);
    } else {
        float w = k1 * k1 - 4.0 * k0 * k2;
        if (w < 0.0) return float2(-9.0);
        w = sqrt(w);
        float ik2 = 0.5 / k2;
        v = (-k1 - w) * ik2;
        float2 den = e + g * v;
        u = abs(den.x) > abs(den.y) ? (h.x - f.x * v) / den.x : (h.y - f.y * v) / den.y;
        if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
            v = (-k1 + w) * ik2;
            den = e + g * v;
            u = abs(den.x) > abs(den.y) ? (h.x - f.x * v) / den.x : (h.y - f.y * v) / den.y;
        }
    }
    return float2(u, v);                // unclamped: the caller antialiases the borders
}

static inline float retro_segDist2D(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9), 0.0, 1.0));
}

struct RetroRibbon {
    float3 head, tail, white;
    float pix, sigma, margin, echoK, glowK, fillK, E;
};

// Light from echo L's patch (between echoes L and L+1) of one edge, at point q.
static inline float3 retro_rbPatch(float2 q, float2 a0, float2 b0, float2 a1, float2 b1, float L,
                                   float shapeHue, thread const RetroRibbon& s) {
    float3 c = float3(0.0);
    float2 uv = retro_invBilinear(q, a0, b0, b1, a1);
    // box-filtered coverage of the patch: half-pixel ramps on all four borders. The borders
    // between consecutive echoes are shared, so their ramps sum to 1 (no seam); the outer ones
    // (the paths the vertices trace) get a clean antialiased edge.
    float lu = length(mix(b0 - a0, b1 - a1, clamp(uv.y, 0.0, 1.0)));
    float lv = length(mix(a1 - a0, b1 - b0, clamp(uv.x, 0.0, 1.0)));
    float2 cu = clamp(min(uv, 1.0 - uv) * float2(lu, lv) / s.pix + 0.5, 0.0, 1.0);
    float cov = cu.x * cu.y;
    if (cov > 0.0) {
        float vv = clamp(uv.y, 0.0, 1.0);
        float age = (L + vv) / s.E, fade = 1.0 - age;
        float3 tint = mix(s.head, s.tail, smoothstep(0.0, 0.85, age));
        float sheen = 0.75 + 0.25 * cos(clamp(uv.x, 0.0, 1.0) * 6.2831853 + shapeHue);
        c += tint * (fade * fade * s.fillK * sheen * cov);
    }
    // the echo line itself: crisp core + soft glow (cut off at the culling margin)
    float d = retro_segDist2D(q, a0, b0);
    if (d < s.margin) {
        float age0 = L / s.E, f0 = 1.0 - age0;
        bool lead = L < 0.5;
        float k = (lead ? 1.0 : s.echoK * 0.4) * f0 * f0;
        float core = retro_lineCov(d, 0.55 * s.pix * (lead ? 1.7 : 1.0), s.pix);
        float glow = exp(-d / s.sigma) * s.glowK * (1.0 - d / s.margin);
        float3 lc = mix(mix(s.head, s.tail, smoothstep(0.0, 0.85, age0)), s.white, lead ? 0.55 : 0.15);
        c += lc * k * (core * 2.2 + glow * (lead ? 0.5 : 0.3));
        if (lead) {                                    // a spark on each leading vertex
            float dv = length(q - a0);
            c += s.white * exp(-dv / (s.sigma * 0.8)) * 0.6 * s.glowK;
        }
    }
    return c;
}

// ---------------------------------------------------------------- 74 Bounce
//
// The logo, its trail and the corner flourish over a flat background. Everything that moves is
// worked out on the CPU once a frame (BounceLogo.prepare in Bounce.swift, layout of u.scene
// there); per pixel this is a box test and one texture tap per drawn copy of the logo.

// A full hue (turns) as display sRGB, a touch softened so no channel reads as neon-clipped.
static inline float3 retro_rainbow(float h) {
    float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return mix(float3(1.0), k, 0.86);
}

// Where px falls on the logo texture, for a logo centred at rect.xy with half size rect.zw
// (the texture holds it inside a clear margin of `inset` uv).
static inline float2 retro_bounceUV(float2 px, float4 rect, float2 inset) {
    return inset + ((px - rect.xy) / (2.0 * rect.zw) + 0.5) * (1.0 - 2.0 * inset);
}

// The logo's texel under px (premultiplied); 0 outside its rectangle. cardR > 0: an opaque
// image, clipped to a rounded card of that radius.
static inline float4 retro_bounceTap(texture2d<float> logo, sampler s, float2 px, float4 rect,
                                     float2 inset, float lod, float cardR) {
    float2 q = px - rect.xy;
    if (any(abs(q) > rect.zw + 1.0)) return float4(0.0);
    float4 c = logo.sample(s, retro_bounceUV(px, rect, inset), level(lod));
    if (cardR > 0.0) {
        float2 e = abs(q) - (rect.zw - cardR);
        float d = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - cardR;
        c = float4(c.rgb / max(c.a, 1e-4), 1.0) * saturate(0.5 - d);
    }
    return c;
}

// What a logo texel paints (premultiplied): its own colours (mode 3), or a fill of `tint` (the
// rainbow's hue across it in mode 1) shaded by its normalised luma — flat for a one-tone logo
// (hi < 0), so a white or a black logo both take the colour whole.
static inline float3 retro_bounceInk(float4 c, float x01, float3 tint, int mode, float lo, float hi, float hue) {
    if (mode == 3) return c.rgb;
    float3 st = c.rgb / max(c.a, 1e-4);
    float shade = hi < 0.0 ? 1.0 : mix(0.22, 1.0, saturate((luma(st) - lo) / max(hi - lo, 1e-3)));
    float3 t = mode == 1 ? retro_rainbow(hue + x01 * 0.35) : tint;
    return t * shade * c.a;
}

static inline float3 retro_bounce(float2 px, float2 res, constant FXUniforms& u,
                                  texture2d<float> logo, sampler s) {
    float3 col = u.colorA.rgb;
    float4 R = u.scene[0];
    if (R.z <= 0.0) return col;
    float3 tint = u.scene[1].xyz;
    int mode = int(u.scene[1].w + 0.5);
    float lo = u.scene[2].x, hi = u.scene[2].y, cardR = u.scene[2].z, lod = u.scene[2].w;
    float4 C = u.scene[3];
    float hue = u.scene[4].x;
    int ghosts = int(u.scene[4].y + 0.5);
    float2 inset = u.scene[4].zw;
    float H = res.y;

    // Corner flourish: for ~2 s after a perfect corner, a ring of light spreads from that corner
    // of the screen, the logo glows, and its colour runs once through the spectrum.
    float since = max(C.z, 0.0);
    float fl = C.w * exp(-1.7 * since);
    float cyc = C.w * (1.0 - smoothstep(0.8, 2.0, since));
    float3 glowTint = mode == 3 ? float3(1.0) : mode == 1 ? retro_rainbow(hue) : tint;
    if (fl > 0.003) {
        float dc = length(px - C.xy);
        float ringR = since * 0.8 * H;
        float ring = exp(-pow((dc - ringR) / (0.012 * H + 0.05 * ringR), 2.0));
        float bloom = exp(-dc / (0.2 * H));
        float3 fc = mix(glowTint, retro_rainbow(since * 0.7 + dc / H * 0.4), cyc * 0.6);
        col += fc * (0.30 * ring + 0.28 * bloom) * fl;
    }

    // The trail: earlier poses, oldest first, each a fainter copy.
    for (int k = ghosts - 1; k >= 0; --k) {
        float4 g = u.scene[5 + 2 * k];
        float4 c = retro_bounceTap(logo, s, px, float4(g.xy, R.zw), inset, lod, cardR);
        if (c.a > 0.0) {
            float x01 = (px.x - g.x) / (2.0 * R.z) + 0.5;
            float3 ink = retro_bounceInk(c, x01, u.scene[6 + 2 * k].xyz, mode, lo, hi, g.w);
            col = col * (1.0 - c.a * g.z) + ink * g.z;
        }
    }

    // The glow: the logo's own shape from a blurry mip, spilling into the texture's clear margin.
    if (fl > 0.003) {
        float2 uv = retro_bounceUV(px, R, inset);
        float2 edge = min(uv, 1.0 - uv);
        if (all(edge > 0.0)) {
            float gl = lod + 3.5;
            float2 o = exp2(gl) * 0.7 / float2(logo.get_width(), logo.get_height());
            float a = logo.sample(s, uv, level(gl)).a * 0.4
                    + (logo.sample(s, uv + float2(o.x, o.y), level(gl)).a + logo.sample(s, uv - float2(o.x, o.y), level(gl)).a
                     + logo.sample(s, uv + float2(o.x, -o.y), level(gl)).a + logo.sample(s, uv - float2(o.x, -o.y), level(gl)).a) * 0.15;
            float2 w = smoothstep(float2(0.0), inset * 0.6, edge);
            col += glowTint * a * w.x * w.y * fl * 0.9;
        }
    }

    float4 c = retro_bounceTap(logo, s, px, R, inset, lod, cardR);
    if (c.a > 0.0) {
        float x01 = (px.x - R.x) / (2.0 * R.z) + 0.5;
        float3 t = mode == 0 || mode == 2 ? mix(tint, retro_rainbow(since * 0.9 + x01 * 0.5), cyc * 0.8) : tint;
        float3 ink = retro_bounceInk(c, x01, t, mode, lo, hi, hue) * (1.0 + 0.3 * fl);
        col = col * (1.0 - c.a) + ink;
    }
    // (clamped: the flourish's boost over a white logo would otherwise reach past 1 on an
    // extended-range target)
    return saturate(col + bandDither(px) * 1.5);
}
