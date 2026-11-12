//  Penguin_funcs.h — the Penguin pack (80). Every symbol is "waddle_". Uses
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
//  The bottom edge of the screen is the floor. Behind it, in the same LED grid but dimmer, a
//  backdrop (Snowy Night or Day: drifts along the bottom, two pines, an igloo it can pass
//  behind or doze beside, distant peaks, a crescent moon and stars or the sun), and falling
//  snow.
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
    float spray;                 // snow kicked up behind a belly slide, 0…1
    float iglooX, iglooR;        // px (x from the centre)
    bool behind;                 // passing behind the igloo
    float night;                 // the backdrop: 0 day … 1 night
    float cam;                   // px the camera has followed it by (the layers' parallax)
    float burst, burstSeed;      // seconds into a burst of hearts and stars (< 0 none), its seed
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
    P.spray = saturate(u.scene[7].w);
    P.iglooX = u.scene[8].x; P.iglooR = u.scene[8].y;
    P.behind = u.scene[8].z > 0.5;
    P.night = saturate(u.scene[8].w);
    P.cam = u.scene[9].x;
    P.burst = u.scene[9].y; P.burstSeed = u.scene[9].z;
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
constant float3 WADDLE_CHEEK = float3(1.0, 0.34, 0.50);

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
    return waddle_limb(p, S, S + dir * (0.33 + 0.16 * P.slide), 0.074, 0.040);
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

/// The penguin at local point q (heights from its feet, y up), edges `aa` wide; `lod`: the glow
/// pass (no tuft). Back to front: far flipper and foot, body with its bib, near flippers and
/// feet, bill (the glow's only: the cells get theirs from waddle_face), tuft. The eyes and
/// cheeks are waddle_face's, on whole cells.
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
        lf[i] = -1.0; ld[i] = 1e3;
        if (!lod) ld[i] = waddle_foot(p, P, s, lf[i]);      // (the glow pass skips the feet)
    }
    // ---- behind the body
    for (int i = 0; i < 2; ++i) {
        if (ff[i] < -0.2) cellkit_over(o, dark * 0.75, cellkit_cov(fd[i], aa));
        if (!lod && lf[i] < -0.25) cellkit_over(o, WADDLE_FEET * 0.75, cellkit_cov(ld[i], aa));
    }
    // ---- the body
    float dB = waddle_body(p);
    float aB = cellkit_cov(dB, aa);
    if (aB > 0.0) {
        float pr = waddle_prof(p.y);
        float sphi = clamp(p.x / pr, -1.0, 1.0);
        float phi = asin(sphi), cphi = sqrt(max(1.0 - sphi * sphi, 0.0));
        // form shading, so it reads as a round body: a key light from the upper left front, the
        // far side and the underside falling off, a soft highlight on the shoulder
        float ny = clamp((p.y - 0.50) * 2.0, -1.0, 1.0);
        float3 nrm = normalize(float3(sphi, 0.75 * ny, cphi + 0.25));
        float dif = saturate(dot(nrm, float3(-0.50, 0.55, 0.67)));
        float lit = 0.42 + 0.78 * dif;
        float spec = pow(saturate(dot(nrm, normalize(float3(-0.50, 0.55, 1.67)))), 24.0);
        float3 c = body * lit + spec * 0.35 * (body + 0.25);
        // the bib: an oval round the front, from the chin to the feet
        float th = phi - P.psi;
        float dBib = waddle_ell(float2(th * 0.36, p.y - 0.305), float2(0.255, 0.318));
        dBib *= mix(1.0, max(cphi, 0.25), 0.6);
        c = mix(c, WADDLE_WHITE * (0.58 + 0.46 * dif) + spec * 0.15, cellkit_cov(dBib, aa));
        cellkit_over(o, c, aB);
    }
    // ---- in front of the body
    for (int i = 0; i < 2; ++i) {
        if (ff[i] >= -0.2) {                                 // darker over the body, bright out of it
            float a = cellkit_cov(fd[i], aa);
            cellkit_over(o, mix(mix(body, WADDLE_WHITE, 0.12), dark, aB), a);
        }
        if (!lod && lf[i] >= -0.25) cellkit_over(o, WADDLE_FEET, cellkit_cov(ld[i], aa));
    }
    // the bill: small, pointing down at the viewer, forward in profile
    if (lod) {
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

/// A point on the penguin (heights, its rest frame) → where it lands in the LED grid (cells from
/// the anchor, y down) through the pose: the inverse of waddle_penguin's head tilt, squash,
/// lean, slide and hop.
static inline float2 waddle_toGrid(float2 e, WaddlePose P, float2 anchor) {
    float2 p = e;
    if (abs(P.headTilt) > 1e-4) p = waddle_rot(p - float2(0.0, 0.62), -P.headTilt) + float2(0.0, 0.62);
    p *= float2(P.sx, P.sy);
    p = waddle_rot(p, -P.lean);
    if (P.slide > 0.001) {
        float2 c0 = float2(0.0, mix(0.42, 0.375, P.slide));
        p = waddle_rot(p - float2(0.0, 0.42), -P.slideDir * P.slide * 1.32) + c0;
    }
    p.y += P.hop;
    return (P.feet + float2(p.x, -p.y) * P.hp - anchor) / P.cellPx;
}

/// The face, on whole cells (pixel-art crisp at any cell size): this cell's LED if it is part of
/// an eye, a cheek or the bill (`col`; black = unlit), else false. Eyes: a white oval a few
/// cells across with a near-black pupil toward where it looks (and a catch-light when there's
/// room); ^ ^ happy, ‿ ‿ asleep, the lid coming down from the top when drowsy. Cheeks: a
/// pink cell. Bill: a small block, or a short beak pointing forward in profile or on the belly.
static inline bool waddle_face(float2 cell, WaddlePose P, float2 anchor, float cw, thread float3& col) {
    float sp = sin(P.psi);
    int cx = int(cell.x), cy = int(cell.y);
    // eyes
    int n = clamp(int(round(0.13 / cw)), 3, 8);
    for (int i = 0; i < 2; ++i) {
        float s = i == 0 ? -1.0 : 1.0;
        float pe = s * 0.52 + P.psi;
        float ce = cos(pe);
        if (ce < 0.15) continue;
        float2 g = waddle_toGrid(float2(waddle_prof(0.775) * sin(pe) * 0.95, 0.775), P, anchor);
        int w = max(2, int(round(float(n) * mix(0.55, 1.0, ce))));
        int h = n + (n >= 4 ? 1 : 0);
        int dx = cx - int(round(g.x - 0.5 * float(w))), dy = cy - int(round(g.y - 0.5 * float(h)));
        if (dx < 0 || dx >= w || dy < 0 || dy >= h) continue;
        int arm = int(floor(abs(float(dx) - 0.5 * float(w - 1))));      // 0 in the middle, out to the ends
        if (P.happy > 0.5) {                                             // ^
            int row = h / 2 - 1 + arm;
            if (dy == row || (n >= 6 && dy == row + 1)) { col = float3(0.0); return true; }
            return false;
        }
        if (P.eyeOpen < 0.2) {                                           // ‿
            int row = h / 2 + 1 - (arm >= w / 2 - 1 && w >= 3 ? 1 : 0);
            if (dy == row || (n >= 6 && dy == row + 1)) { col = float3(0.0); return true; }
            return false;
        }
        bool corner = w >= 4 && h >= 4 && (dx == 0 || dx == w - 1) && (dy == 0 || dy == h - 1);
        int lid = int(round(float(h) * (1.0 - saturate(P.eyeOpen))));
        if (corner || dy < lid) return false;
        int pw = max(2, int(round(float(w) * 0.5))), ph = max(2, int(round(float(h) * 0.5)));
        float lx = clamp(0.85 * P.look.x + 0.35 * sin(pe), -1.0, 1.0), ly = clamp(P.look.y, -1.0, 1.0);
        int px0 = clamp(int(round(float(w - pw) * (0.5 + 0.5 * lx))), 0, w - pw);
        int py0 = clamp(int(round(float(h - ph) * (0.6 - 0.5 * ly))), max(lid, 0), max(h - ph, 0));
        if (dx >= px0 && dx < px0 + pw && dy >= py0 && dy < py0 + ph) {
            bool glint = pw >= 3 && ph >= 3 && dx == px0 && dy == py0;     // a catch-light, when there's room
            col = glint ? WADDLE_WHITE : float3(0.0);
            return true;
        }
        col = WADDLE_WHITE;
        return true;
    }
    // cheeks: one pink cell each (a square of them at small cell sizes)
    int cs = max(1, int(round(0.035 / cw)));
    for (int i = 0; i < 2; ++i) {
        float s = i == 0 ? -1.0 : 1.0;
        float pc = s * 1.0 + P.psi;
        if (cos(pc) < 0.3 || P.slide > 0.5) continue;
        float2 g = waddle_toGrid(float2(waddle_prof(0.65) * sin(pc) * 0.90, 0.65), P, anchor);
        int dx = cx - int(floor(g.x - 0.5 * float(cs - 1))), dy = cy - int(floor(g.y - 0.5 * float(cs - 1)));
        if (dx >= 0 && dx < cs && dy >= 0 && dy < cs) { col = WADDLE_CHEEK * 0.9; return true; }
    }
    // the bill
    bool side = abs(sp) > 0.55 || P.slide > 0.5;
    // (on its belly: from the front of the head, which leads)
    // (in profile from the face's edge — the blended outline bulges past waddle_prof there)
    float2 B = waddle_toGrid(P.slide > 0.5 ? float2(0.31 * sp, 0.72)
                                           : float2(waddle_prof(0.68) * sp * (side ? 1.08 : 0.96), 0.68), P, anchor);
    if (!side) {
        int bw = max(2, int(round(0.065 / cw))), bh = max(1, int(round(0.05 / cw)));
        int dx = cx - int(round(B.x - 0.5 * float(bw))), dy = cy - int(round(B.y - 0.5));
        int open = P.beak > 0.35 ? 1 : 0;
        if (dx < 0 || dx >= bw || dy < 0 || dy >= bh + 2 * open) return false;
        if (open == 1 && dy == bh) { col = float3(0.0); return true; }     // the open mouth
        int r = dy > bh ? dy - bh - 1 : dy;                                  // (the lower half)
        int inset = (bw >= 4) ? r : 0;                                       // a point, when wide
        if (dx < inset || dx >= bw - inset) return false;
        col = WADDLE_BILL;
        return true;
    }
    float dir = P.slide > 0.5 ? P.slideDir : (sp >= 0.0 ? 1.0 : -1.0);
    int L = max(2, int(round(0.12 / cw))), th = max(1, int(round(0.035 / cw)));
    float f = (cell.x + 0.5 - B.x) * dir;                                   // cells forward of its base
    int dy = cy - int(floor(B.y)) + (th > 1 ? 1 : 0);
    if (f < -0.5 || f >= float(L) - 0.5 || dy < 0 || dy >= th) return false;
    if (th > 1 && dy == th - 1 && f >= float(L) - 1.5) return false;        // the tip tapers
    col = WADDLE_BILL;
    return true;
}

/// The custom character (slot 6): the user's image as a whole sprite, `half` = (half width,
/// height) in heights, standing on its feet, posed by the same hop, lean, squash and slide;
/// mirrored while it faces left. `soft`: blurred, for the glow — reaching into the texture's
/// clear margin, which fades it out before the texture's edge.
static inline float2 waddle_spriteUV(float2 p, WaddlePose P) {
    float2 uv = float2(p.x / (2.0 * P.spr.x) + 0.5, 1.0 - p.y / P.spr.y);
    return P.inset + uv * (1.0 - 2.0 * P.inset);
}
static inline CellLayer waddle_sprite(float2 q, WaddlePose P, texture2d<float> T, sampler s, bool soft, float cw) {
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
    float2 uv = waddle_spriteUV(p, P);
    if (any(uv < 0.0) || any(uv > 1.0)) return o;
    // the glow: blurred over a few cells (as the penguin's), fading out just past the sprite
    float e = max(abs(p.x) - hw.x, max(-p.y, p.y - hw.y));
    float fade = soft ? 1.0 - smoothstep(0.0, 0.10, e) : 1.0;
    if (fade <= 0.0) return o;
    float4 c;
    if (soft) {
        c = T.sample(s, uv, level(P.lod + 1.6));
    } else {
        // the cell's whole area, averaged (four taps a level finer): no shimmer as it moves
        float lv = max(P.lod - 1.0, 0.0);
        float2 o4 = float2(0.25 * cw) / float2(P.sx, P.sy);
        c = 0.25 * (T.sample(s, waddle_spriteUV(p + float2(-o4.x, -o4.y), P), level(lv))
                  + T.sample(s, waddle_spriteUV(p + float2(o4.x, -o4.y), P), level(lv))
                  + T.sample(s, waddle_spriteUV(p + float2(-o4.x, o4.y), P), level(lv))
                  + T.sample(s, waddle_spriteUV(p + float2(o4.x, o4.y), P), level(lv)));
    }
    float3 lin = srgbToLinear(c.rgb / max(c.a, 1e-4));
    lin = pow(max(mix(float3(luma(lin)), lin, 1.25), 0.0), float3(0.85));  // saturated, and the
                                                                          // darks lifted, on the LEDs
    o.a = (soft ? c.a : smoothstep(0.12, 0.55, c.a)) * fade;              // crisp edge cells
    o.c = lin * o.a;
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

// ============================================================ the backdrop
/// The distant peaks: (x, height) in units of U.
constant float2 WADDLE_PEAKS[6] = { float2(-1.50000, 0.20000), float2(-0.78306, 0.30139), float2(-0.38918, 0.20629), float2(0.43520, 0.26140), float2(1.00898, 0.24111), float2(1.48619, 0.24988) };

/// What the backdrop puts in a cell: its emission (linear; the penguin stays the hero), how near
/// the layer is (0 the sky … 1 the foreground: nearer layers get fatter, crisper dots), and
/// whether the igloo, the drifts the penguin stands in, or a foreground mound covers it.
struct WaddleBack { float3 c; float depth, igloo, ground, fore; };

/// The backdrop at a cell (centre cpx). Layers in parallax: the camera (P.cam px) follows the
/// penguin a little, and each layer moves by its own share of it — the sky hardly, the peaks a
/// quarter, the pines two thirds, the drifts most of it, the igloo with the penguin, the
/// foreground mounds more than it. Units of U (the penguin's scale), x from the centre, y up
/// from the bottom edge. Unlit cells stay dark: only shapes light up, the sky barely.
static inline WaddleBack waddle_backdrop(float2 cpx, float2 res, float ts, float2 cell, WaddlePose P) {
    WaddleBack o; o.c = 0.0; o.depth = 0.0; o.igloo = 0.0; o.ground = 0.0; o.fore = 0.0;
    float U = min(res.y, 1.3 * res.x);
    float X = (cpx.x - 0.5 * res.x) / U, Y = (res.y - cpx.y) / U;
    float halfW = 0.5 * res.x / U, top = res.y / U;
    float cam = P.cam / U;
    float night = P.night, day = 1.0 - night;
    float3 snowLo = mix(float3(0.040, 0.052, 0.095), float3(0.085, 0.100, 0.150), day);
    float3 snowHi = mix(float3(0.070, 0.085, 0.140), float3(0.140, 0.160, 0.215), day);
    // snow glints: now and then a cell flashes (more by day, under the sun)
    float gh = hash21(cell * 0.913 + floor(ts * 4.0) * 0.37);
    float glint = gh < mix(0.004, 0.014, day) ? sin(3.14159 * fract(ts * 4.0)) * 0.45 : 0.0;

    // ---- foreground mounds at the corners, nearer than the penguin (it passes behind them)
    {
        float xf = X + 1.35 * cam;
        float f1 = (xf + halfW + 0.02) / 0.20, f2 = (xf - halfW - 0.05) / 0.17;
        float hf = 0.085 * exp(-f1 * f1) + 0.075 * exp(-f2 * f2);
        if (Y < hf) {
            o.fore = 1.0; o.depth = 1.0;
            o.c = mix(snowLo, snowHi, smoothstep(hf - 0.03, hf, Y)) * 1.35 + glint;
            return o;
        }
    }
    // ---- drifts the penguin stands in, with its soft shadow (and a hint of its colour) under it
    {
        float xd = X + 0.8 * cam;
        float drift = 0.050 + 0.020 * sin(xd * 4.3 + 1.0) + 0.011 * sin(xd * 10.1 + 0.4);
        if (Y < drift) {
            o.ground = 1.0; o.depth = 0.75;
            o.c = mix(snowLo, snowHi, smoothstep(drift - 0.025, drift, Y)) + glint;
            float dx = (cpx.x - P.feet.x) / P.hp, w = 0.46 * (1.0 - min(P.hop * 2.5, 0.5));
            if (P.hp > 1.0 && abs(dx) < w) {
                float sh = 1.0 - smoothstep(0.55, 1.0, abs(dx) / w);
                o.c = mix(o.c, o.c * 0.25 + float3(0.0, 0.010, 0.035), sh);
            }
            return o;
        }
    }
    // ---- the igloo (moving with the penguin): blocks with dark joints, the doorway toward the middle
    {
        float R = P.iglooR / U;
        float2 d = float2(X + cam - P.iglooX / U, Y - 0.02);
        if (R > 0.0 && length(d / float2(R, 0.88 * R)) < 1.0) {
            o.igloo = 1.0; o.depth = 0.85;
            if (length(float2(d.x - 0.62 * R, d.y) / float2(0.24 * R, 0.46 * R)) < 1.0) return o;
            int ry = int(-cell.y);
            int bx = int(cell.x) + ((ry / 4) % 2) * 3;
            bool joint = (ry % 4) == 0 || ((bx % 6) + 6) % 6 == 0;
            float3 ice = mix(float3(0.075, 0.095, 0.150), float3(0.150, 0.180, 0.250), day);
            // lit from the upper left: rounder
            float sh = 0.55 + 0.6 * saturate(0.5 - 0.5 * d.x / R + 0.35 * d.y / R);
            o.c = ice * (joint ? 0.30 : 1.0) * sh;
            return o;
        }
    }
    // ---- two pines (mid distance)
    {
        float xm = X + 0.65 * cam;
        for (int i = 0; i < 2; ++i) {
            float xt = (i == 0 ? 0.34 : 0.66) * halfW, h = i == 0 ? 0.30 : 0.22;
            float b = 0.045;
            if (abs(xm - xt) > 0.2 * h + 0.01 || Y > b + h) continue;
            float3 green = mix(float3(0.005, 0.034, 0.016), float3(0.012, 0.072, 0.026), day);
            o.depth = 0.6;
            if (abs(xm - xt) < 0.035 * h + 0.004 && Y < b + 0.18 * h) {
                o.c = mix(float3(0.018, 0.009, 0.004), float3(0.040, 0.020, 0.009), day);
                return o;
            }
            for (int k = 2; k >= 0; --k) {
                float y0 = b + 0.15 * h + float(k) * 0.26 * h, y1 = y0 + 0.42 * h;
                float w = 0.30 * h * (1.0 - 0.2 * float(k));
                if (Y >= y0 && Y < y1 && abs(xm - xt) < w * (y1 - Y) / (y1 - y0)) {
                    float lit = 0.75 + 0.5 * saturate((xt - xm) / max(w, 1e-3));   // the lit side
                    o.c = (Y > y1 - 0.07 * h ? snowHi * 0.85 : green * lit);
                    return o;
                }
            }
        }
    }
    // ---- distant peaks (far: dim), snow along their ridges
    {
        float xp0 = X + 0.25 * cam;
        float m = 0.0;
        for (int i = 0; i < 6; ++i) m = max(m, WADDLE_PEAKS[i].y - abs(xp0 - WADDLE_PEAKS[i].x) * 0.62);
        m += 0.06;
        if (Y < m) {
            o.depth = 0.25;
            float3 rock = mix(float3(0.008, 0.012, 0.028), float3(0.015, 0.024, 0.050), day);
            float3 ridge = mix(float3(0.028, 0.034, 0.058), float3(0.055, 0.066, 0.095), day);
            o.c = Y > m - 0.035 ? ridge : rock;
            return o;
        }
    }
    // ---- the sky: dark. By day a deep blue band low down, the sun with slow turning rays; by
    // night an aurora rippling green → teal → violet, a crescent moon, twinkling stars and now and
    // then a shooting star.
    float xs = X + 0.05 * cam;
    float3 c = float3(0.010, 0.030, 0.095) * (1.0 - smoothstep(0.0, 0.40, Y - 0.12)) * day;
    float2 dm = float2(xs, Y) - float2(-0.45 * halfW, top - 0.21);
    float rm = length(dm);
    if (rm < 0.058) {
        float crescent = length(dm - float2(0.028, 0.014)) > 0.052 ? 1.0 : 0.0;
        o.c = c + float3(0.55, 0.48, 0.28) * crescent * night + float3(0.95, 0.62, 0.16) * 0.75 * day;
        return o;
    }
    if (day > 0.01 && rm < 0.26) {
        float ang = atan2(dm.y, dm.x);
        float rays = pow(0.5 + 0.5 * cos(12.0 * ang + ts * 0.25), 8.0);
        float fall = 1.0 - smoothstep(0.065, 0.26, rm);
        c += (float3(0.45, 0.28, 0.06) * rays * fall + float3(0.10, 0.06, 0.012) * (1.0 - smoothstep(0.058, 0.10, rm))) * day;
    }
    if (night > 0.01) {
        // the aurora: curtains hanging from a rippling lower edge, rayed, folds drifting along
        float ya = top * 0.66 + 0.07 * sin(xs * 1.7 + ts * 0.11) + 0.035 * sin(xs * 4.3 - ts * 0.17);
        float dy = Y - ya;
        if (dy > -0.02 && dy < 0.24) {
            float a = smoothstep(-0.02, 0.012, dy) * (1.0 - smoothstep(0.0, 0.24, dy));
            a *= 0.55 + 0.45 * sin(xs * 38.0 + 3.0 * sin(xs * 5.0 + ts * 0.3) + ts * 0.6);
            a *= 0.55 + 0.45 * sin(xs * 2.3 - ts * 0.25);
            float3 ac = mix(float3(0.10, 1.0, 0.42), float3(0.05, 0.75, 0.85), saturate(dy / 0.08));
            ac = mix(ac, float3(0.55, 0.22, 1.0), saturate((dy - 0.08) / 0.12));
            c += ac * a * 0.17 * night;
        }
        if (rm < 0.11) c += float3(0.05, 0.05, 0.04) * (1.0 - smoothstep(0.058, 0.11, rm)) * night;
        float h = hash21(cell * 0.71 + 3.1);
        if (h < 0.011 && Y > 0.30) {
            float tw = 0.5 + 0.5 * sin(ts * (1.3 + 180.0 * h) + h * 900.0);
            c += float3(0.85, 0.90, 1.0) * (0.04 + 0.22 * tw) * night;
        }
        // a shooting star, every so often: a bright head and a fading tail, gone in under a second
        float k = floor(ts / 17.0);
        float hk = hash21(float2(k, 7.7));
        if (hk < 0.6) {
            float u = (ts - (k * 17.0 + 2.0 + 12.0 * hk)) / 0.8;
            if (u >= 0.0 && u <= 1.0) {
                float2 st = float2((hash21(float2(k, 2.1)) * 1.4 - 0.7) * halfW, top * (0.80 + 0.12 * hash21(float2(k, 3.4))));
                float2 dir = normalize(float2(hash21(float2(k, 5.2)) < 0.5 ? -1.0 : 1.0, -0.42));
                float2 head = st + dir * (0.15 + 0.75 * u);
                float hh;
                float dd = cellkit_seg(float2(xs, Y), head - dir * 0.20, head, hh);
                float cu = P.cellPx / U;
                if (dd < 0.55 * cu) c += float3(1.0, 0.95, 0.80) * 0.7 * hh * hh * (1.0 - u * 0.5) * night;
            }
        }
    }
    o.c = c;
    return o;
}

/// A burst of little bright shapes popping round the penguin when it waves or dances: hearts,
/// stars and twinkles flung up and out, falling back and fading. In whole cells. This cell's
/// colour, or false.
static inline bool waddle_burst(float2 cell, float2 anchor, WaddlePose P, float ts, thread float3& col) {
    if (P.burst < 0.0 || P.burst > 1.4) return false;
    float2 o = P.feet + float2(0.0, -0.80 * P.hp);
    for (int i = 0; i < 7; ++i) {
        float fi = float(i);
        float h1 = hash21(float2(P.burstSeed, fi)), h2 = hash21(float2(P.burstSeed, fi + 9.0));
        float ang = mix(-2.6, -0.55, (fi + h1) / 7.0);                    // fanned up and out
        float sp = (0.70 + 0.55 * h2) * P.hp;
        float a = P.burst;
        float2 pos = o + float2(cos(ang), sin(ang)) * sp * a + float2(0.0, 0.55 * P.hp) * a * a;
        float fade = 1.0 - smoothstep(0.9, 1.4, a);
        int2 d = int2(cell) - int2(floor((pos - anchor) / P.cellPx));
        int kind = int(h1 * 3.0);
        bool on = false;
        if (kind == 0) {                                     // a heart, 5 × 4
            int x = d.x + 2, y = d.y + 1;
            if (x >= 0 && x < 5 && y >= 0 && y < 4) {
                int rows[4] = { 10, 31, 14, 4 };
                on = ((rows[y] >> (4 - x)) & 1) != 0;
            }
            if (on) col = float3(1.0, 0.22, 0.52) * fade;
        } else if (kind == 1) {                              // a star: a plus of five cells
            on = (abs(d.x) + abs(d.y) <= 1);
            if (on) col = float3(1.0, 0.82, 0.18) * fade;
        } else {                                             // a twinkle: + and × by turns
            bool plus = fract(ts * 6.0 + h2) < 0.5;
            on = (d.x == 0 && d.y == 0) || (plus ? (abs(d.x) + abs(d.y) == 1) : (abs(d.x) == 1 && abs(d.y) == 1));
            if (on) col = float3(0.45, 0.92, 1.0) * fade * (d.x == 0 && d.y == 0 ? 1.0 : 0.6);
        }
        if (on) return true;
    }
    return false;
}

// ============================================================ 80 PENGUIN
/// p0 = (render 0 LED dots / 1 pixels / 2 glyphs, cell size, glow, energy), p1 = (snow, size,
/// follow the clock, backdrop 0 none / 1 snowy night / 2 day); colorA the penguin, colorB the
/// background; the pose (and the backdrop's igloo and night) in u.scene. The
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

    // the LED grid, anchored on the floor (the bottom edge) at the centre
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
    if (abs(qp.x) < 1.3 && qp.y > -0.45 && qp.y < 1.95) {
        if (P.custom) {
            sharp = waddle_sprite(qc, P, A, s, false, cw);
            soft = waddle_sprite(qp, P, A, s, true, cw);
        } else {
            sharp = waddle_penguin(qc, P, body, cw, false);
            soft = waddle_penguin(qp, P, body, cw * 6.0, true);
            float3 fc;
            if (qc.y > -0.1 && abs(qc.x) < 1.0 && waddle_face(cell, P, anchor, cw, fc)) {
                sharp.c = fc; sharp.a = 1.0;
            }
        }
        if (P.zz >= 0.0) {
            float2 top = P.custom ? float2(0.35 * P.spr.x, P.spr.y * P.sy + P.hop)
                                  : float2(0.05, 0.98 * P.sy + P.hop);
            waddle_zz(sharp, qc, P.zz, top, cw);
        }
    }

    // behind it: the backdrop, and falling snow (each flake a dot stepping down its column,
    // drifting a column either way, gone where it lands: the drifts, or the bottom edge)
    int backdrop = clamp(int(u.p1.w + 0.5), 0, 2);
    WaddleBack B;
    B.c = 0.0; B.depth = 0.0; B.igloo = 0.0; B.ground = 0.0; B.fore = 0.0;
    // (the backdrop and the snow only where a dot and its rim are: their halos are faint, and a
    // cell's corners skip the work — at 5K a cell is over a thousand pixels)
    bool inDot = render == 2 || length(lp) < 0.42;
    if (backdrop > 0 && inDot) B = waddle_backdrop(cpx, res, ts, cell, P);
    float3 back = B.c;
    float igloo = B.igloo, ground = B.ground;
    float3 snowC = float3(0.72, 0.82, 1.0);
    float bgLvl = 0.0;
    if (inDot && ground < 0.5 && P.snow > 0.01) {
        for (int k = -1; k <= 1; ++k) {
            float c = cell.x + float(k);
            float h1 = hash21(float2(c, 13.7));
            if (h1 > 0.16 * P.snow) continue;
            float h2 = hash21(float2(c, 5.3)), h3 = hash21(float2(c, 9.1));
            // a column either way as it falls (and the sway itself drifts with time)
            float drift = round(1.1 * sin(ts * 0.9 + h2 * 6.2831 + cell.y * 0.23));
            if (abs(c + drift - cell.x) > 0.5) continue;
            float per = 13.0 + floor(h2 * 22.0);
            float head = floor(ts * (3.0 + 3.0 * h3) + h1 * 977.0);       // 3–6 cells a second
            float m = cell.y - head;
            m -= per * floor(m / per);
            if (m < 0.5) bgLvl = max(bgLvl, 0.09 + 0.14 * h3);
        }
    }
    // a belly slide kicks up a spray of snow behind it: a short fan of dim, flickering dots
    if (P.spray > 0.01 && cell.y < -0.5 && cell.y > -8.5) {
        float back = (P.feet.x - cpx.x) * P.slideDir / P.hp;              // heights behind its middle
        float up = (anchor.y - cpx.y) / P.hp;
        float reach = 0.9 * P.spray;
        float f = (back - (P.custom ? 0.85 * P.spr.x : 0.45)) / max(reach, 1e-3);
        if (f > 0.0 && f < 1.0 && up < 0.05 + 0.22 * f) {
            float hk = hash21(cell * 1.37 + floor(ts * 12.0) * 0.731);
            if (hk < 0.45 * (1.0 - f)) bgLvl = max(bgLvl, 0.30 * (1.0 - 0.6 * f));
        }
    }

    float3 sc = cellkit_color(sharp);
    float hide = max(P.behind ? igloo : 0.0, B.fore);               // the igloo, a mound in front of it
    float fig = smoothstep(0.0, 0.6, sharp.a) * (1.0 - hide);
    float3 E = mix(max(back, snowC * bgLvl), sc, fig) * P.bright;   // what this cell's LED emits
    float3 spill = soft.c * P.bright * (1.0 - 0.8 * hide);          // the figure, blurred
    float depth = max(B.depth, fig);                                // (nearer: fatter, crisper dots)
    float3 bc;
    if (waddle_burst(cell, anchor, P, ts, bc)) { E = bc; fig = 1.0; depth = 1.0; }
    float3 col = bg;
    if (render < 2) {
        // LED DOTS — a tight grid of round dots — or PIXELS — rounded cells: each lit one with a
        // soft halo of its own, the figure's light spilling round it, the dark ones faintly there
        // (fat dots, ≈ 80 % of the pitch, like a real panel's; the figure in a coloured halo a few
        // cells deep, kept out of the gaps inside it so the dots stay distinct)
        // (distance: the far layers' dots smaller and softer, their glow fainter)
        float dd = cellkit_led(lp, render == 0, mix(0.31, 0.40, depth));
        float m = saturate(0.5 - dd * cp * mix(0.35, 1.0, depth));
        float r = length(lp);
        col += spill * glow * (0.95 - 0.78 * fig);
        col += E * glow * 0.60 * (1.0 - smoothstep(0.30, 0.64, r)) * (0.12 + 0.88 * max(fig, 0.4 * depth));
        float3 led = E * cellkit_dome(lp) * (1.0 + 0.35 * glow);
        led += saturate(luma(E) - 0.25) * 0.25 * glow * (1.0 - smoothstep(0.0, 0.28, r));   // a hot core
        float3 ghost = bg + float3(0.0020, 0.0022, 0.0030);
        col = mix(col, max(led, ghost), m);
    } else {
        // GLYPHS — the figure blurred into the dark, glyphs in its colours on top
        col += spill * (0.06 + 0.08 * glow);
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
