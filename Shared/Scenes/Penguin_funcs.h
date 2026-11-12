//  Penguin_funcs.h — the Penguin pack: Waddle (80). Every symbol is "waddle_". Uses
//  CellKit_funcs.h (shared with Bloom) for the layers, the glyphs and the LED cells.
//
//  A little penguin of our own, drawn procedurally and posed by the CPU (WaddleRig in
//  Penguin.swift fills u.scene once a frame: where it stands, which way it faces, its lean,
//  squash, flippers, eyes…). It is evaluated twice a pixel, as Bloom's flower is:
//    • at the centre of the pixel's cell, sharp (aa = one cell): what the cell's LED shows;
//    • at the pixel, soft (aa = a few cells, no features): the glow spilling round the figure.
//  The body is round, so it can turn: every marking (the bib, eyes, cheeks, bill, flippers,
//  feet) sits at an angle round its vertical axis and is drawn where that angle faces the
//  viewer — a turn from the front to a profile is just the yaw.
//  Behind it: falling snow and a faint row of ground dots, in the same LED grid.
//
//  Frame: q in penguin heights from its feet, x right, y UP. Colours linear inside, display
//  sRGB out. Time is stepped to 24 fps (the pose arrives stepped; the snow steps here).

#include "CellKit_funcs.h"

constant float WADDLE_FPS = 24.0;

struct WaddlePose {
    float2 feet;                 // px, y down (on whole cells)
    float hp, cellPx, groundY;   // penguin height, cell, ground (px)
    float yaw, psi, lean, sx, sy;
    float hop, slide, slideDir, flipL, flipR;
    float eyeOpen, happy, headTilt, zz;
    float2 look;
    float footL, footR;
    float snow, bright, tuft, beak;
    bool custom;
    float2 spr;                  // the custom character: (half width, height), heights
    float lod;
    float2 inset;
};

/// The pose WaddleRig.prepare packed into u.scene (Penguin.swift has the layout).
static inline WaddlePose waddle_pose(constant FXUniforms& u, float2 res) {
    WaddlePose P;
    float4 s0 = u.scene[0];
    P.hp = max(s0.z, 1.0);
    P.cellPx = max(s0.w, 2.0);
    P.groundY = s0.y;
    // whole cells, as a sprite moves on an LED panel (no shimmer as it walks)
    P.feet = float2(0.5 * res.x + round(s0.x / P.cellPx) * P.cellPx, s0.y);
    P.yaw = clamp(u.scene[1].x, -1.0, 1.0);
    P.psi = P.yaw * 1.5707963;
    P.lean = u.scene[1].y;
    P.sx = max(u.scene[1].z, 0.2); P.sy = max(u.scene[1].w, 0.2);
    P.hop = round(u.scene[2].x * P.hp / P.cellPx) * P.cellPx / P.hp;
    P.slide = saturate(u.scene[2].y);
    P.flipL = u.scene[2].z; P.flipR = u.scene[2].w;
    P.eyeOpen = u.scene[3].x; P.look = u.scene[3].yz; P.happy = u.scene[3].w;
    P.footL = u.scene[4].x; P.footR = u.scene[4].y; P.headTilt = u.scene[4].z; P.zz = u.scene[4].w;
    P.snow = saturate(u.scene[5].x); P.bright = saturate(u.scene[5].y);
    P.tuft = u.scene[5].z; P.beak = saturate(u.scene[5].w);
    P.custom = u.scene[6].x > 0.5;
    P.spr = max(u.scene[6].yz, float2(0.01));
    P.lod = u.scene[6].w;
    P.inset = u.scene[7].xy;
    P.slideDir = u.scene[7].z < 0.0 ? -1.0 : 1.0;
    return P;
}

static inline float2 waddle_rot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

/// Approximate signed distance to an ellipse of radii r.
static inline float waddle_ell(float2 p, float2 r) {
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-5);
}
static inline float waddle_smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}
static inline float waddle_halfW(float y, float cy, float rx, float ry) {
    float v = (y - cy) / ry;
    return rx * sqrt(max(1.0 - v * v, 0.0));
}

// The body: a round, chubby belly (centre 0.40, radii 0.375 × 0.40) and a head (centre 0.755,
// radii 0.262 × 0.245), blended at the neck. Feet at y = 0, the crown at 1.
static inline float waddle_body(float2 p) {
    return waddle_smin(waddle_ell(p - float2(0.0, 0.40), float2(0.375, 0.40)),
                       waddle_ell(p - float2(0.0, 0.755), float2(0.262, 0.245)), 0.10);
}
/// Its half width at height y (where a marking at an angle round the body lands on screen).
static inline float waddle_prof(float y) {
    float a = waddle_halfW(y, 0.40, 0.375, 0.40), b = waddle_halfW(y, 0.755, 0.262, 0.245);
    float h = saturate(0.5 + 0.5 * (a - b) / 0.06);
    return max(mix(b, a, h) + 0.06 * h * (1.0 - h), 1e-3);
}
/// A tapered capsule from a (radius r0) to b (r1).
static inline float waddle_limb(float2 p, float2 a, float2 b, float r0, float r1) {
    float h;
    float d = cellkit_seg(p, a, b, h);
    return d - mix(r0, r1, h);
}

constant float3 WADDLE_WHITE = float3(0.92, 0.94, 1.0);
constant float3 WADDLE_INK   = float3(0.006, 0.007, 0.016);
constant float3 WADDLE_BILL  = float3(1.0, 0.62, 0.07);
constant float3 WADDLE_FEET  = float3(1.0, 0.42, 0.05);
constant float3 WADDLE_CHEEK = float3(1.0, 0.36, 0.46);

/// A flipper (side s = −1 the viewer's left when it faces them, +1 right) at pose P: its
/// distance, and how far round toward the viewer its shoulder is (cos of its angle).
static inline float waddle_flipper(float2 p, WaddlePose P, float s, thread float& facing) {
    float ph = s * 1.45 + P.psi;
    facing = cos(ph);
    float o = sin(ph);
    float2 S = float2(waddle_prof(0.56) * o * 0.86, 0.56);
    // outward from the side it's on; seen side-on, back (away from the way it faces)
    float back = P.psi >= 0.0 ? -1.0 : 1.0;
    float ox = o + (1.0 - abs(o)) * back;
    float al = s < 0.0 ? P.flipL : P.flipR;
    float2 dir = float2(ox * sin(al), -cos(al));
    return waddle_limb(p, S, S + dir * 0.30, 0.066, 0.028);
}
/// A foot (f = ±1): distance, and its facing.
static inline float waddle_foot(float2 p, WaddlePose P, float f, thread float& facing) {
    float ph = f * 0.60 + P.psi;
    facing = cos(ph);
    float sp = sin(P.psi);
    float lift = f < 0.0 ? P.footL : P.footR;
    // on its belly the feet trail behind, soles up
    float2 c = float2(0.21 * sin(ph) + 0.10 * sp * (1.0 - P.slide), 0.018 + lift - 0.05 * P.slide);
    return waddle_ell(p - c, mix(float2(0.070 + 0.04 * abs(sp), 0.040), float2(0.04, 0.08), P.slide));
}

/// The penguin at local point q (heights from its feet, y up), edges `aa` wide; `lod` skips
/// the face (the glow pass). Back to front: far flipper and foot, body with its bib and face,
/// near flippers and feet, bill, tuft.
static inline CellLayer waddle_penguin(float2 q, WaddlePose P, float3 body, float aa, bool lod) {
    CellLayer o; o.c = 0.0; o.a = 0.0;
    float2 p = q;
    p.y -= P.hop;
    if (P.slide > 0.001) {                                   // on its belly, head first
        float2 c0 = float2(0.0, mix(0.42, 0.375, P.slide));
        p = waddle_rot(p - c0, P.slideDir * P.slide * 1.32) + float2(0.0, 0.42);
    }
    p = waddle_rot(p, P.lean);
    p /= float2(P.sx, P.sy);
    if (abs(p.x) > 0.80 + aa || p.y < -0.12 - aa || p.y > 1.18 + aa) return o;
    // the head (and everything on it) tilts about the neck
    float ht = P.headTilt * smoothstep(0.50, 0.70, p.y);
    if (abs(ht) > 1e-4) p = waddle_rot(p - float2(0.0, 0.62), ht) + float2(0.0, 0.62);

    float3 dark = body * 0.66;
    float ff[2], fd[2], lf[2], ld[2];
    for (int i = 0; i < 2; ++i) {
        float s = i == 0 ? -1.0 : 1.0;
        fd[i] = waddle_flipper(p, P, s, ff[i]);
        ld[i] = waddle_foot(p, P, s, lf[i]);
    }
    // ---- behind the body
    for (int i = 0; i < 2; ++i) {
        if (ff[i] < -0.2) cellkit_over(o, dark * 0.75, cellkit_cov(fd[i], aa));
        if (lf[i] < -0.25) cellkit_over(o, WADDLE_FEET * 0.75, cellkit_cov(ld[i], aa));
    }
    // ---- the body
    float dB = waddle_body(p);
    float aB = cellkit_cov(dB, aa);
    if (aB > 0.0) {
        float pr = waddle_prof(p.y);
        float sphi = clamp(p.x / pr, -1.0, 1.0);
        float phi = asin(sphi), cphi = sqrt(max(1.0 - sphi * sphi, 0.0));
        // soft light from the upper left; the far rim and the underside a little darker
        float ny = clamp((p.y - 0.55) * 1.8, -1.0, 1.0);
        float lit = 0.80 + 0.13 * (-0.6 * sphi + 0.5 * ny) + 0.10 * cphi;
        float3 c = body * lit;
        // the bib: an oval round the front, from the chin to the feet
        float th = phi - P.psi;
        float dBib = waddle_ell(float2(th * 0.36, p.y - 0.305), float2(0.255, 0.318));
        dBib *= mix(1.0, max(cphi, 0.25), 0.6);
        c = mix(c, WADDLE_WHITE * (0.86 + 0.14 * lit), cellkit_cov(dBib, aa));
        if (!lod) {
            // rosy cheeks
            for (int i = 0; i < 2; ++i) {
                float s = i == 0 ? -1.0 : 1.0;
                float pc = s * 0.98 + P.psi;
                if (cos(pc) < 0.15) continue;
                float2 cc = float2(waddle_prof(0.655) * sin(pc) * 0.94, 0.655);
                float dc = length((p - cc) / float2(mix(0.6, 1.0, cos(pc)), 1.0)) - 0.042;
                c = mix(c, WADDLE_CHEEK * 0.9, 0.85 * cellkit_cov(dc, aa));
            }
            // eyes: big dark ovals with a glint, looking about; ^ ^ when happy, a closed curve
            // asleep
            for (int i = 0; i < 2; ++i) {
                float s = i == 0 ? -1.0 : 1.0;
                float pe = s * 0.52 + P.psi;
                float ce = cos(pe);
                if (ce < 0.06) continue;
                float fx = mix(0.5, 1.0, ce);
                float2 ec = float2(waddle_prof(0.775) * sin(pe) * 0.95, 0.775);
                float2 d = p - ec;
                float h;
                if (P.happy > 0.5) {
                    float dl = min(cellkit_seg(d, float2(-0.058 * fx, -0.022), float2(0.0, 0.030), h),
                                   cellkit_seg(d, float2(0.0, 0.030), float2(0.058 * fx, -0.022), h));
                    c = mix(c, WADDLE_INK, cellkit_line(dl, 0.017, aa));
                } else if (P.eyeOpen < 0.16) {
                    float dl = min(cellkit_seg(d, float2(-0.060 * fx, 0.006), float2(0.0, -0.020), h),
                                   cellkit_seg(d, float2(0.0, -0.020), float2(0.060 * fx, 0.006), h));
                    c = mix(c, WADDLE_INK, cellkit_line(dl, 0.016, aa));
                } else {
                    // white, lit LEDs (a dark eye on the blue reads as a hole), a big pupil
                    // toward where it looks, a glint in it
                    float op = min(P.eyeOpen, 1.25);
                    float2 r = float2(0.068 * fx, 0.084 * op);
                    float2 dd = d + float2(0.0, (1.0 - min(op, 1.0)) * 0.03);   // the lid comes down
                    float dS = waddle_ell(dd, r);
                    c = mix(c, WADDLE_WHITE, cellkit_cov(dS, aa));
                    float2 po = float2(clamp(P.look.x, -1.0, 1.0) * 0.022 + sin(pe) * 0.016,
                                       clamp(P.look.y, -1.0, 1.0) * 0.020 - 0.008);
                    float2 pq = dd - po;
                    float dP = max(waddle_ell(pq, float2(0.046 * fx, min(0.060, r.y * 0.8))), dS + 0.012);
                    c = mix(c, WADDLE_INK, cellkit_cov(dP, aa));
                    float gl = cellkit_cov(length(pq - float2(-0.016 * fx, 0.022)) - 0.012, aa) * step(0.6, op);
                    c = mix(c, WADDLE_WHITE, gl);
                }
            }
        }
        cellkit_over(o, c, aB);
    }
    // ---- in front of the body
    for (int i = 0; i < 2; ++i) {
        if (ff[i] >= -0.2) {
            float a = cellkit_cov(fd[i], aa);
            cellkit_over(o, dark, a);
        }
        if (lf[i] >= -0.25) cellkit_over(o, WADDLE_FEET, cellkit_cov(ld[i], aa));
    }
    // the bill: small, pointing down at the viewer, forward in profile
    {
        float sp = sin(P.psi), cp = cos(P.psi);
        float2 B = float2(waddle_prof(0.675) * sp * 0.96, 0.675);
        float2 T = B + mix(float2(0.105 * sp, -0.030 - 0.022 * cp), float2(0.03 * sp, 0.09), P.slide);
        float2 up = float2(0.0, 0.022 * P.beak);
        float d = waddle_limb(p, B + up, T + up, 0.054, 0.016);
        float a = cellkit_cov(d, aa);
        if (P.beak > 0.05) {                                 // the lower half, opened
            float2 Tl = B + float2(0.085 * sp, -0.050 - 0.020 * cp) - float2(0.0, 0.030 * P.beak);
            a = max(a, cellkit_cov(waddle_limb(p, B - float2(0.0, 0.012), Tl, 0.034, 0.010), aa));
        }
        cellkit_over(o, WADDLE_BILL, a);
    }
    // the tuft on top
    if (!lod) {
        float h;
        float dt = 1e3;
        for (int k = -1; k <= 1; ++k) {
            float fk = float(k);
            float2 a = float2(0.028 * fk - 0.02 * sin(P.psi), 0.965);
            float2 b = a + float2(0.04 * fk + 0.035 * P.tuft, 0.085 - 0.022 * abs(fk));
            dt = min(dt, cellkit_seg(p, a, b, h));
        }
        cellkit_over(o, body * 1.08, cellkit_line(dt, 0.012, aa));
    }
    return o;
}

/// The custom character (slot 6): the user's image as a whole sprite, `half` = (half width,
/// height) in heights, standing on its feet, posed by the same hop, lean, squash and slide;
/// mirrored while it faces left. `soft`: blurred, for the glow — reaching into the texture's
/// clear margin, which fades it out before the texture's edge.
static inline CellLayer waddle_sprite(float2 q, WaddlePose P, texture2d<float> T, sampler s, bool soft) {
    CellLayer o; o.c = 0.0; o.a = 0.0;
    float2 p = q;
    // sliding: tipped forward (about its feet), a little lifted so a square corner dips less
    p.y -= P.hop + 0.12 * P.spr.x * P.slide;
    p = waddle_rot(p, P.lean + P.slideDir * P.slide * 0.45);
    p /= float2(P.sx, P.sy);
    float m = P.yaw < -0.42 ? -1.0 : 1.0;
    float sq = mix(0.15, 1.0, smoothstep(0.0, 0.3, abs(P.yaw + 0.42)));   // edge-on as it turns
    p.x *= m / sq;
    float2 hw = P.spr;
    if (!soft && (abs(p.x) > hw.x || p.y < 0.0 || p.y > hw.y)) return o;
    float2 uv = float2(p.x / (2.0 * hw.x) + 0.5, 1.0 - p.y / hw.y);
    uv = P.inset + uv * (1.0 - 2.0 * P.inset);
    if (any(uv < 0.0) || any(uv > 1.0)) return o;
    // the glow: blurred over a few cells (as the penguin's), fading out just past the sprite
    float e = max(abs(p.x) - hw.x, max(-p.y, p.y - hw.y));
    float fade = soft ? 1.0 - smoothstep(0.0, 0.10, e) : 1.0;
    if (fade <= 0.0) return o;
    float lodAdd = soft ? 1.6 : 0.0;
    float4 c = T.sample(s, uv, level(P.lod + lodAdd));
    o.a = c.a * fade;
    o.c = srgbToLinear(c.rgb / max(c.a, 1e-4)) * o.a;
    return o;
}

/// The Zz of a doze, rising from beside the head (`top` = its crown, heights), over o.
static inline void waddle_zz(thread CellLayer& o, float2 q, float zz, float2 top, float aa) {
    for (int k = 0; k < 3; ++k) {
        float age = zz - 1.1 * float(k);
        if (age < 0.0) continue;
        float cyc = fract(age / 3.3);
        float2 c = top + float2(0.18 + 0.34 * cyc + 0.03 * sin(age * 2.1), 0.06 + 0.55 * cyc);
        float sz = 0.045 + 0.045 * cyc;
        float fade = smoothstep(0.0, 0.10, cyc) * (1.0 - smoothstep(0.62, 1.0, cyc));
        float2 d = q - c;
        if (max(abs(d.x), abs(d.y)) > sz + aa) continue;
        float h;
        float dist = min(min(cellkit_seg(d, float2(-sz, sz), float2(sz, sz), h),
                             cellkit_seg(d, float2(sz, sz), float2(-sz, -sz), h)),
                         cellkit_seg(d, float2(-sz, -sz), float2(sz, -sz), h));
        cellkit_over(o, float3(0.62, 0.78, 1.0), cellkit_line(dist, 0.008, aa) * fade);
    }
}

/// Which glyph a cell shows (Glyphs): the bib in triangles, the blue in letters, the bill and
/// feet in rings and stars, the eyes and the snow in dots.
static inline int waddle_pick(float3 s, float2 cell, bool figure) {
    float h = hash21(cell * 0.913 + 5.0);
    if (!figure) return (h < 0.85) ? 6 : 5;
    float l = luma(s);
    bool tri = fmod(abs(cell.x + cell.y), 2.0) < 0.5;
    if (h > 0.8) tri = !tri;
    if (s.r > s.b * 1.4) return (h < 0.5) ? 4 : 5;
    if (l < 0.10) return 6;
    if (l > 0.62 && s.b < s.r * 1.35) return tri ? 0 : 1;
    return (h < 0.45) ? 2 : (h < 0.9 ? 3 : 7);
}

// ============================================================ 80 WADDLE
/// p0 = (render 0 LED dots / 1 pixels / 2 glyphs, cell size, glow, energy), p1 = (snow, size,
/// follow the clock); colorA the penguin, colorB the background; the pose in u.scene. The
/// custom character's texture is slot 6. Display sRGB out.
static inline float3 waddle_scene(float2 px, float2 res, float t, constant FXUniforms& u,
                                  texture2d<float> A, sampler s) {
    int render = clamp(int(u.p0.x + 0.5), 0, 2);
    float glow = saturate(u.p0.z);
    WaddlePose P = waddle_pose(u, res);
    float ts = floor(t * WADDLE_FPS) / WADDLE_FPS;
    float3 bg = srgbToLinear(u.colorB.rgb);
    // a body too dark to light an LED (a natural black penguin) shows as a dim slate
    float3 body = max(srgbToLinear(u.colorA.rgb), float3(0.030, 0.034, 0.050));

    // the LED grid, anchored on the ground line at the centre
    float cp = P.cellPx;
    float2 anchor = float2(0.5 * res.x, P.groundY);
    float2 g = (px - anchor) / cp;
    float2 cell = floor(g);
    float2 lp = g - cell - 0.5;
    lp.y = -lp.y;
    float2 cpx = (cell + 0.5) * cp + anchor;
    float2 qc = float2(cpx.x - P.feet.x, P.feet.y - cpx.y) / P.hp;    // the cell, heights from the feet
    float2 qp = float2(px.x - P.feet.x, P.feet.y - px.y) / P.hp;      // the pixel
    float cw = cp / P.hp;

    CellLayer sharp, soft;
    sharp.c = 0.0; sharp.a = 0.0; soft = sharp;
    if (abs(qp.x) < 1.15 && qp.y > -0.35 && qp.y < 1.85) {
        if (P.custom) {
            sharp = waddle_sprite(qc, P, A, s, false);
            soft = waddle_sprite(qp, P, A, s, true);
        } else {
            sharp = waddle_penguin(qc, P, body, cw, false);
            soft = waddle_penguin(qp, P, body, cw * 2.6, true);
        }
        if (P.zz >= 0.0) {
            float2 top = P.custom ? float2(0.35 * P.spr.x, P.spr.y * P.sy + P.hop)
                                  : float2(0.05, 0.98 * P.sy + P.hop);
            waddle_zz(sharp, qc, P.zz, top, cw);
        }
    }

    // behind it: falling snow (each flake a dot stepping down its column, drifting a column
    // either way), and the ground — one faint row of dots, a few more under it
    float3 snowC = float3(0.72, 0.82, 1.0);
    float bgLvl = 0.0;
    if (cell.y < -0.5 && P.snow > 0.01) {
        for (int k = -1; k <= 1; ++k) {
            float c = cell.x + float(k);
            float h1 = hash21(float2(c, 13.7));
            if (h1 > 0.16 * P.snow) continue;
            float h2 = hash21(float2(c, 5.3)), h3 = hash21(float2(c, 9.1));
            float drift = round(0.9 * sin(ts * 0.55 + h2 * 6.2831 + cell.y * 0.19));
            if (abs(c + drift - cell.x) > 0.5) continue;
            float per = 13.0 + floor(h2 * 22.0);
            float head = floor(ts * (1.5 + 2.0 * h3) + h1 * 977.0);
            float m = cell.y - head;
            m -= per * floor(m / per);
            if (m < 0.5) bgLvl = max(bgLvl, 0.07 + 0.12 * h3);
        }
    } else if (abs(cell.y) < 0.5) {
        bgLvl = 0.030 + 0.030 * hash21(float2(cell.x, 3.3));
    } else if (abs(cell.y - 1.0) < 0.5 && hash21(float2(cell.x, 4.4)) < 0.28) {
        bgLvl = 0.010;
    }

    float3 sc = cellkit_color(sharp);
    float fig = smoothstep(0.0, 0.6, sharp.a);
    float3 E = mix(snowC * bgLvl, sc, fig) * P.bright;              // what this cell's LED emits
    float3 spill = soft.c * P.bright;                               // the figure, blurred
    float3 col = bg;
    if (render < 2) {
        // LED DOTS — a tight grid of round dots — or PIXELS — rounded cells: each lit one with a
        // soft halo of its own, the figure's light spilling round it, the dark ones faintly there
        float dd = cellkit_led(lp, render == 0);
        float m = saturate(0.5 - dd * cp);
        float r = length(lp);
        col += spill * glow * 0.32;
        col += E * glow * 0.60 * (1.0 - smoothstep(0.28, 0.58, r));
        float3 led = E * cellkit_dome(lp) * (1.0 + 0.3 * glow);
        led += saturate(luma(E) - 0.25) * 0.35 * glow * (1.0 - smoothstep(0.0, 0.32, r));   // a hot core
        float3 ghost = bg + float3(0.0020, 0.0022, 0.0030);
        col = mix(col, max(led, ghost), m);
    } else {
        // GLYPHS — the figure blurred into the dark, glyphs in its colours on top
        col += spill * (0.12 + 0.14 * glow);
        float lit = max(fig, bgLvl > 0.0 ? 1.0 : 0.0);
        if (lit > 0.02) {
            int gi = waddle_pick(linearToSrgb(sc), cell, fig > 0.02);
            float d = cellkit_glyph(gi, lp);
            float ink = saturate(0.5 - d * cp) * lit;
            col = mix(col, E * (1.25 + 0.3 * glow), ink);
        }
    }
    return saturate(linearToSrgb(max(col, 0.0)) + bandDither(px));
}
