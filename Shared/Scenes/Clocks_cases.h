//  Clocks_cases.h — switch cases for the Clocks pack (shader ids 50–53). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L, textAtlas. Scenes ignore src/base.

    case 50: { // TYPE CLOCK — the time set huge in a real system face. Styles: Relief (raised,
               // tone-on-tone, lit by a light that follows the sun), Glass (clear numerals
               // refracting a drifting light field), Ink (flat, editorial).
               // p0 = (style, typeface, weight, size), p1 = (24h, seconds, date, depth);
               // colorA background, colorB numerals.
        int style = int(u.p0.x + 0.5), faceSel = int(u.p0.y + 0.5);
        float wgt = u.p0.z, size = max(u.p0.w, 0.3);
        bool h24 = u.p1.x > 0.5, secs = u.p1.y > 0.5, showDate = u.p1.z > 0.5;
        float depth = u.p1.w;
        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y;                       // screen-height units, y down

        float bias; float4 fw = clocks_face(faceSel, wgt, bias);
        ClkTypeLayout TL = clocks_typeLayout(textAtlas, u.clock, fw, h24, secs);
        float cap = min(0.30 * size, 0.84 * aspect / max(TL.width, 1.0));
        float capPx = cap * res.y;
        float dCap = max(cap * 0.075, 10.0 / res.y);
        float gap = cap * 0.46;
        float blockH = cap + (showDate ? gap + dCap : 0.0);
        float baseY = -0.5 * blockH + cap - 0.015;                // time baseline
        float2 q = (p - float2(0.0, baseY)) / cap;

        // light: azimuth follows the sun, ~33° above the surface
        float2 L2 = clocks_sunDir(u.clock.x, t);
        float3 L3 = normalize(float3(L2 * 0.84, 0.55));
        float lift = 0.035 + 0.065 * depth;                        // how far the figures stand off (caps)
        float off = lift * 0.84 / 0.55;
        float eps = 0.012;
        float blur = 0.0;
        float4 D = float4(CLK_FAR);
        if (abs(q.y + 0.5) < 0.62 + off && abs(q.x) < 0.5 * TL.width + 0.45 + off)   // only near the figures
            D = clocks_typeDist(textAtlas, samp, TL, fw, bias, q, eps, q + L2 * off, blur);
        float d = D.x;
        float2 grad = (D.yz - D.x) / eps;
        grad *= rsqrt(max(dot(grad, grad), 1e-6));
        float aw = 0.75 / capPx + blur;
        float cov = smoothstep(aw, -aw, d);
        float bw = 0.016 + 0.020 * depth;                         // bevel width (caps)
        float bx = clamp(-d / bw, 0.0, 1.0);
        float slope = pow(1.0 - bx, 1.4) * (0.55 + 0.55 * depth);  // soft rounded shoulder
        float3 n = normalize(float3(grad * slope, 1.0));
        float pen = 0.012 + 0.45 * off;
        float shadow = smoothstep(pen, -pen, D.w) * (1.0 - cov);
        float ao = exp(-max(d, 0.0) / 0.035) * (1.0 - cov);

        // a broad pool of light on the ground, drifting with the light direction
        float2 pc = p + L2 * 0.35;
        float pool = exp(-dot(pc, pc) * 1.1);
        float vig = 1.0 - 0.32 * dot(p * float2(0.8, 1.0), p * float2(0.8, 1.0));
        float3 col;
        if (style == 1) {                                          // GLASS — rounded glass rods
            float gw = 0.065 + 0.03 * depth;                       // rod radius (caps)
            float gx = clamp(-d / gw, 0.0, 1.0);
            float gr = 1.0 - gx;                                    // 1 at the silhouette → 0 on the crest
            float gs = gr * rsqrt(max(1.0 - gr * gr, 0.02));        // circular cross-section slope
            float3 gn = normalize(float3(grad * gs, 1.0));
            float3 bg = clocks_glassBg(p, t, A, B);
            float2 rofs = -gn.xy * (0.16 * cap);
            float3 refr = bg;
            if (cov > 0.0) {
                refr.r = clocks_glassBg(p + rofs * 0.94, t, A, B).r;
                refr.g = clocks_glassBg(p + rofs * 1.00, t, A, B).g;
                refr.b = clocks_glassBg(p + rofs * 1.08, t, A, B).b;
            }
            float3 rv = 2.0 * gn.z * gn - float3(0, 0, 1);
            float spec = pow(max(dot(rv, L3), 0.0), 90.0) * 1.4;
            float3 Lb = normalize(float3(-L2 * 0.8, 0.35));        // soft counter-light on the far edge
            float spec2 = pow(max(dot(rv, Lb), 0.0), 12.0) * 0.18;
            float fres = pow(1.0 - gn.z, 3.0);
            float3 glass = refr * 0.88 + 0.035 + mix(B, float3(1.0), 0.65) * (0.28 * fres + spec2) + spec;
            glass *= 1.0 - 0.45 * smoothstep(0.82, 0.97, gr) * (1.0 - fres);   // dark refraction ring
            // ground: soft shadow with a caustic focus inside it
            float caus = 0.0;
            float fakeD = D.w;
            caus = smoothstep(0.02, -0.03, fakeD) * smoothstep(-0.10, -0.02, fakeD);
            col = bg * (1.0 - 0.38 * shadow - 0.10 * ao) * vig + B * caus * 0.10 * (1.0 - cov);
            col = mix(col, glass * vig, cov);
        } else if (style == 2) {                                   // INK
            col = A * (0.94 + 0.10 * pool) * vig;
            col *= 1.0 - (0.16 * shadow + 0.08 * ao) * depth;
            float sAlpha = (secs && q.x > TL.x[5] - 0.25) ? 0.55 : 1.0;
            col = mix(col, B, cov * sAlpha);
        } else {                                                   // RELIEF
            float nl = dot(n, L3) / L3.z;                          // 1 on flat faces
            float shade = 1.0 + 0.55 * (nl - 1.0);                  // wrapped, matte
            float3 ground = A * (0.86 + 0.24 * pool) * vig;
            ground *= 1.0 - 0.42 * shadow * (0.5 + 0.5 * depth) - 0.16 * ao * depth;
            float3 face = B * (0.86 + 0.24 * pool) * vig * shade;
            col = mix(ground, face, cov);
        }

        float dBase = baseY + gap + dCap;
        if (showDate && abs(p.y - dBase + 0.5 * dCap) < 1.4 * dCap) {
            float db; float4 dfw = clocks_face(faceSel, wgt + 0.3, db);
            ClkRun dr = clocks_dateRun(u.date, u.clock, true, false);
            float track = 0.32;
            float dw = clocks_runWidth(textAtlas, dr, dfw, track);
            float2 dq = (p - float2(-0.5 * dw * dCap, dBase)) / dCap;
            float dd = clocks_runDist(textAtlas, samp, dr, dfw, track, dq) - db;
            float dc = clocks_cov(dd, dCap * res.y);
            float3 lab = (luma(A) > 0.45) ? A * 0.42 : mix(A, float3(1.0), 0.55);     // contrast tone
            float3 ink = (style == 1) ? float3(0.86)
                       : (style == 2 && abs(luma(B) - luma(A)) > 0.2) ? mix(A, B, 0.78) : lab;
            col = mix(col, ink, dc * 0.9);
        }
        col += bandDither(px) * 2.0;
        return float4(col, 1.0);
    }

    case 51: { // FLIP CLOCK — a split-flap clock, one card per figure. Each change releases the
               // upper flap: it falls through 180° in 3D (perspective, lit, casting its shadow
               // on the card below), lands with a small bounce and shows the new figure.
               // p0 = (typeface, 24h, seconds, date), p1.x = size; colorA cards, colorB numerals.
        int faceSel = int(u.p0.x + 0.5);
        bool h24 = u.p0.y > 0.5, secs = u.p0.z > 0.5, showDate = u.p0.w > 0.5;
        float size = max(u.p1.x, 0.3);
        float3 cardC = u.colorA.rgb, inkC = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y; p.y = -p.y;           // y up

        float bias;
        float4 fw = clocks_face(faceSel == 1 ? 2 : (faceSel == 2 ? 1 : 3), 0.5, bias);

        // ---- the figures, before and after their last change
        ClkTime T = clocks_time(u.clock);
        float pm = T.m - 1.0, ph = T.h;
        if (pm < 0.0) { pm = 59.0; ph = fmod(T.h + 23.0, 24.0); }
        float sN = floor(T.s), sP = fmod(sN + 59.0, 60.0);
        float hN = h24 ? T.h : clocks_hour12(T.h), hP = h24 ? ph : clocks_hour12(ph);
        int gN[6], gO[6];
        gN[0] = (h24 || hN >= 10.0) ? int(hN / 10.0) : -1;  gO[0] = (h24 || hP >= 10.0) ? int(hP / 10.0) : -1;
        gN[1] = int(fmod(hN, 10.0));  gO[1] = int(fmod(hP, 10.0));
        gN[2] = int(T.m / 10.0);      gO[2] = int(pm / 10.0);
        gN[3] = int(fmod(T.m, 10.0)); gO[3] = int(fmod(pm, 10.0));
        gN[4] = int(sN / 10.0);       gO[4] = int(sP / 10.0);
        gN[5] = int(fmod(sN, 10.0));  gO[5] = int(fmod(sP, 10.0));

        // ---- layout (screen-height units)
        const float KS = 0.5;                                       // seconds cards scale
        float H = 0.42 * size;
        float cw = CLK_FLIP_W, gi = 0.045, go = 0.20;               // in card heights
        float wMain = 4.0 * cw + 2.0 * gi + go;
        float wAll = wMain + (secs ? go * 0.8 + KS * (2.0 * cw + gi) : 0.0);
        H = min(H, 0.90 * aspect / wAll);
        float x0 = -0.5 * wAll * H;
        float cy = showDate ? 0.035 : 0.0;
        // nearest card along x
        int ci = 0; float best = 1e9;
        float cxs[6]; float cks[6];
        {
            float x = x0;
            for (int i = 0; i < 6; ++i) {
                float k = (i >= 4) ? KS : 1.0;
                if (i == 4) x += go * 0.8 * H;
                cxs[i] = x + 0.5 * cw * H * k; cks[i] = k;
                x += cw * H * k + ((i % 2 == 0) ? gi * H * k : (i == 1 ? go * H : 0.0));
            }
            int nc = secs ? 6 : 4;
            for (int i = 0; i < nc; ++i) {
                float dx = abs(p.x - cxs[i]) - 0.5 * cw * H * cks[i];   // distance to the card's edge
                if (dx < best) { best = dx; ci = i; }
            }
        }
        float k = cks[ci], Hk = H * k;
        float2 cc = float2(cxs[ci], cy - (1.0 - k) * 0.5 * H);   // seconds sit on the baseline
        float2 P = (p - cc) / Hk;
        float pxs = 1.0 / (res.y * Hk);                             // one pixel in card units

        float e = (gN[ci] == gO[ci]) ? 9.0 : ((ci >= 4) ? fract(T.s) : T.s);
        float th = clocks_flapAngle(e);
        bool flipping = e < 0.75;

        // ---- backdrop
        float3 Lw = normalize(float3(-0.35, 0.85, 0.75));
        float cl = luma(cardC);
        float3 back = (cl < 0.35) ? cardC * 0.55 + 0.004 : cardC * 0.86;
        float2 pv = p * float2(0.85, 1.0);
        back *= (0.84 + 0.24 * smoothstep(-0.6, 0.6, p.y)) * (1.0 - 0.22 * dot(pv, pv));
        float dCard = clocks_rrect(P, float2(cw * 0.5, 0.5), CLK_FLIP_R);
        float drop = 0.0;                                           // soft drop shadows of every card
        for (int i = 0; i < (secs ? 6 : 4); ++i) {
            float2 cq = (p - float2(cxs[i], cy - (1.0 - cks[i]) * 0.5 * H)) / (H * cks[i]);
            float ds = clocks_rrect(cq - float2(0.010, -0.040), float2(cw * 0.5, 0.5), CLK_FLIP_R);
            drop = max(drop, smoothstep(0.13, -0.05, ds));
        }
        float3 col = back * (1.0 - 0.42 * drop * drop);
        // the flap stack peeking out under the card
        for (int s2 = 1; s2 <= 2; ++s2) {
            float ds = clocks_rrect(P - float2(0.0, -0.007 * float(s2)), float2(cw * 0.5 - 0.004 * float(s2), 0.5), CLK_FLIP_R);
            col = mix(col, cardC * (0.55 - 0.12 * float(s2)), clamp(0.5 - ds / pxs, 0.0, 1.0) * step(P.y, 0.0));
        }

        // ---- static halves
        float cardCov = clamp(0.5 - dCard / pxs, 0.0, 1.0);
        bool top = P.y > 0.0;
        int gStatic = top ? gN[ci] : ((flipping && th < 3.1) ? gO[ci] : gN[ci]);
        float dInk = (dCard < 0.01) ? clocks_cardInk(textAtlas, samp, gStatic, P, fw, bias) : 1.0;
        float3 face = cardC * (top ? 1.03 : 0.95) * (1.0 + 0.05 * (abs(P.y) - 0.25) * (top ? 1.0 : -1.0));
        face = mix(face, inkC * (top ? 1.0 : 0.94), clamp(0.5 - dInk / pxs, 0.0, 1.0));
        face *= 1.0 - 0.22 * exp(-abs(P.y) / 0.018);                 // shade into the hinge
        // shadow of the falling flap on the static halves
        float3 fn = float3(0.0, -sin(th), cos(th));
        float3 fu = float3(0.0, cos(th), sin(th));
        if (flipping) {
            float tau = -dot(float3(P, 0.0), fn) / dot(Lw, fn);
            float3 hs = float3(P, 0.0) + tau * Lw;
            float dsh = clocks_flapShape(float2(hs.x, dot(hs, fu)));
            float soft = 0.01 + 0.10 * abs(tau);
            float shd = smoothstep(soft, -soft, dsh) * step(0.0, tau) * smoothstep(0.02, 0.12, th) * smoothstep(3.14, 3.0, th);
            face *= 1.0 - 0.55 * shd;
        }
        float slit = smoothstep(CLK_FLIP_GAP + pxs, CLK_FLIP_GAP - pxs, abs(P.y));
        face = mix(face, cardC * 0.18, slit);
        face += (top ? 0.05 : 0.02) * smoothstep(1.5 * pxs, 0.0, abs(dCard + 0.5 * pxs)) * step(0.2, abs(P.y));
        col = mix(col, face, cardCov);

        // ---- the falling flap (ray-plane in card space, perspective from a centred eye)
        if (flipping) {
            // each card is seen from straight in front (no sideways overhang into the next card),
            // from a little above the clock
            float3 eye = float3(0.0, (0.12 - cc.y) / Hk, 2.6 / Hk);
            float3 dir = float3(P, 0.0) - eye;
            float den = dot(dir, fn);
            float sh = -dot(eye, fn) / (abs(den) < 1e-5 ? 1e-5 : den);
            float3 hp = eye + sh * dir;
            float2 f = float2(hp.x, dot(hp, fu));
            float2 fwf = fwidth(f);
            float fpx = clamp(max(fwf.x, fwf.y), pxs, 12.0 * pxs);
            float dF = clocks_flapShape(f);
            float fCov = clamp(0.5 - dF / fpx, 0.0, 1.0) * step(0.0, sh) * step(sh, 1.0001);
            bool front = den < 0.0;
            float3 nf = front ? fn : -fn;
            float shade = min((0.30 + 0.70 * max(dot(nf, Lw), 0.0)) / (0.30 + 0.70 * Lw.z), 1.08);
            int gF = front ? gO[ci] : gN[ci];
            float2 fxy = front ? f : float2(f.x, -f.y);
            float dI = clocks_cardInk(textAtlas, samp, gF, fxy, fw, bias);
            float3 fc = cardC * (front ? 1.03 : 0.95);
            fc = mix(fc, inkC, clamp(0.5 - dI / fpx, 0.0, 1.0));
            fc *= shade * (1.0 - 0.18 * exp(-abs(f.y) / 0.02));
            col = mix(col, fc, fCov);
        }

        float dCap = max(H * 0.06, 10.0 / res.y);
        float ybD = cy - 0.5 * H - 0.13 * H - dCap;                    // date baseline, y up
        if (showDate && abs(p.y - ybD - 0.5 * dCap) < 1.4 * dCap) {
            float db; float4 dfw = clocks_face(faceSel == 1 ? 2 : (faceSel == 2 ? 1 : 0), 0.55, db);
            ClkRun dr = clocks_dateRun(u.date, u.clock, true, false);
            float track = 0.34;
            float dw = clocks_runWidth(textAtlas, dr, dfw, track);
            float2 dq = float2(p.x + 0.5 * dw * dCap, ybD - p.y) / dCap;
            float dd = clocks_runDist(textAtlas, samp, dr, dfw, track, dq) - db;
            float3 lab = (luma(back) < 0.4) ? mix(back, float3(0.92), 0.55) : back * 0.45;
            col = mix(col, lab, clocks_cov(dd, dCap * res.y));
        }
        col += bandDither(px) * 2.0;
        return float4(col, 1.0);
    }
    case 52: { // WORD CLOCK — the time spelled out in a letter grid; lit words glow and spill a
               // little light onto the panel, changes fade through in reading order.
               // p0 = (typeface, weight, glow, unlit letters), p1 = (time of day, size);
               // colorA panel, colorB lit letters.
        int faceSel = int(u.p0.x + 0.5);
        float wgt = u.p0.y, glowAmt = u.p0.z, unlit = u.p0.w;
        bool period = u.p1.x > 0.5;
        float size = max(u.p1.y, 0.3);
        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y;

        float pitch = min(0.80 / 11.0, 0.88 * aspect / 16.0) * size;
        float2 gp = p / pitch + float2(8.0, 5.5);                   // grid units, (0,0) top-left
        float capS = 0.40 * pitch, capPx = capS * res.y;
        float bias; float4 fw = clocks_face(faceSel, wgt, bias);

        ClkTime T = clocks_time(u.clock);
        float pmn = T.m - 1.0, phr = T.h;
        if (pmn < 0.0) { pmn = 59.0; phr = fmod(T.h + 23.0, 24.0); }
        uint mN = clocks_wordMask(T.h, T.m, period), mO = clocks_wordMask(phr, pmn, period);

        // per-word light level through a change (new words fade in left to right)
        float glow = 0.0, litHere = 0.0;
        int col = int(floor(gp.x)), row = int(floor(gp.y));
        bool inGrid = col >= 0 && col < 16 && row >= 0 && row < 11;
        for (int i = 0; i < 32; ++i) {
            bool on = (mN >> uint(i)) & 1u, was = (mO >> uint(i)) & 1u;
            if (!on && !was) continue;
            float a = 1.0;
            if (on && !was) a = smoothstep(0.15 + 0.07 * float(i), 1.55 + 0.07 * float(i), T.s);
            else if (!on && was) a = 1.0 - smoothstep(0.0, 1.1, T.s);
            uchar3 w = CLK_WORDS[i];
            // soft bloom around the word's centre line (no flat plateau → no visible boxes)
            float x0w = float(w.y) + 0.5, x1w = float(w.y + w.z) - 0.5;
            float2 dq = gp - float2(clamp(gp.x, x0w, x1w), float(w.x) + 0.5);
            glow += a * exp(-dot(dq, dq) * 0.9);
            if (inGrid && row == int(w.x) && col >= int(w.y) && col < int(w.y + w.z)) litHere = a;
        }

        float d = CLK_FAR;
        float apos = 0.0;
        if (inGrid) {
            float2 lc = (gp - float2(col, row) - 0.5) * (pitch / capS);   // caps from the cell centre
            int g = clocks_gid(CLK_WGRID[row][col], true);
            ClkGlyph G = clocks_glyph(textAtlas, g);
            d = clocks_gdist(textAtlas, samp, G, lc + float2(0.5 * dot(G.adv, fw), -0.5), fw) - bias;
            if (row == 8 && col <= 1) {                                   // the apostrophe in O'CLOCK
                ClkGlyph Ga = clocks_glyph(textAtlas, CLK_G_APOS);
                float2 la = (gp - float2(1.0, 8.5)) * (pitch / capS);
                float da = clocks_gdist(textAtlas, samp, Ga, la + float2(0.5 * dot(Ga.adv, fw), -0.5), fw) - bias;
                if (da < d) { d = da; apos = 1.0; }
            }
        }
        if (apos > 0.5) {
            bool on = (mN >> 24u) & 1u, was = (mO >> 24u) & 1u;
            litHere = on ? (was ? 1.0 : smoothstep(1.83, 3.23, T.s)) : (was ? 1.0 - smoothstep(0.0, 1.1, T.s) : 0.0);
        }
        float cov = clocks_cov(d, capPx);

        float2 pv = p * float2(0.75, 1.0);
        float3 panel = A * (1.0 - 0.28 * dot(pv, pv)) * (0.97 + 0.06 * smoothstep(0.5, -0.5, p.y));
        panel += B * glow * glowAmt * 0.055;                            // light spill on the panel
        float3 off = mix(A, B, unlit) + B * glow * glowAmt * 0.05;
        float3 lit = B * (1.0 + 0.18 * glowAmt);
        float3 ink = mix(off, lit, litHere);
        float3 colr = mix(panel, ink, cov);
        float hal = smoothstep(CLK_FAR, 0.0, d);                        // fades to 0 at the field's reach
        colr += B * litHere * glowAmt * 0.30 * hal * hal * hal * (1.0 - cov);   // letter halo
        colr += bandDither(px) * 2.0;
        return float4(colr, 1.0);
    }
    case 53: { // WINDOW LIGHT — a calm wall in sunlight: four-pane window light with swaying leaf
               // shadows that travels with the real sun, the time and date set on the wall in
               // New York. p0 = (typeface, layout, 24h, date), p1 = (leaves, follow sun, sway, size);
               // colorA wall, colorB sunlight.
        int faceSel = int(u.p0.x + 0.5), layout = int(u.p0.y + 0.5);
        bool h24 = u.p0.z > 0.5, showDate = u.p0.w > 0.5;
        float leaves = u.p1.x, sway = u.p1.z, size = max(u.p1.w, 0.3);
        bool follow = u.p1.y > 0.5;
        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y;                       // y down

        // sun: position across the day, strength (sunrise → sunset), moonlight after dark
        float hr = u.clock.x;
        float day = follow ? clamp((hr - 6.0) / 13.0, 0.0, 1.0) : 0.62 + 0.04 * sin(t * 0.004);
        float sunUp = follow ? smoothstep(5.6, 7.0, hr) * smoothstep(20.4, 19.0, hr) : 1.0;
        float warm = follow ? 1.0 - 4.0 * day * (1.0 - day) : 0.0;     // golden at the ends of the day
        if (!follow) day = 0.62 + 0.04 * sin(t * 0.004);
        float nightDay = fract(hr / 24.0 + 0.5);                        // the moon's patch drifts slowly too
        float pd = (sunUp > 0.01) ? day : clamp(nightDay * 1.6 - 0.3, 0.0, 1.0);
        float2 sun = clocks_windowLight(p, pd, t, leaves, sway, aspect);
        float cloud = 0.88 + 0.12 * smoothstep(-0.35, 0.35, sin(t * 0.021) + 0.6 * sin(t * 0.0137 + 1.3));
        float3 sunC = mix(B, B * float3(1.0, 0.80, 0.58), warm * 0.55);
        float3 moonC = float3(0.55, 0.66, 0.95) * 0.30;
        float3 lightC = mix(moonC, sunC, sunUp) * cloud;

        // plaster: albedo mottling + a fine bump that only shows in raking light
        float mott = gfbm(p * 7.0 + 2.0, 2);
        float3 alb = A * (1.0 + 0.05 * mott);
        float b0 = gnoise(p * 34.0), b1 = gnoise(p * 34.0 + float2(0.05, -0.03));
        float bump = 1.0 + 0.55 * (b1 - b0);
        float2 pv = p * float2(0.7, 1.0);
        float3 amb = mix(float3(1.0), float3(0.90, 0.95, 1.05), mix(0.7, 0.25, sunUp)) * mix(0.34, 0.86, sunUp)
                   * (1.0 - 0.30 * dot(pv, pv));                        // cool skylight fill

        // type, painted on the wall (all text work only inside its horizontal band)
        float cap = 0.15 * size;
        float baseY = (layout == 1) ? 0.06 : 0.36 - 0.10 * (1.0 - size);
        float dCap = max(cap * 0.19, 10.0 / res.y);
        float ink = 0.0;
        if (p.y > baseY - 1.45 * cap - 1.3 * dCap && p.y < baseY + 0.32 * cap) {   // text band only
            bool centered = layout == 1;
            float bias; float4 fw = clocks_face(faceSel == 0 ? 1 : (faceSel == 1 ? 0 : 2), faceSel == 1 ? 0.15 : 0.35, bias);
            float dbias; float4 dfw = clocks_face(faceSel == 0 ? 1 : (faceSel == 1 ? 0 : 2), 0.45, dbias);
            ClkTime T = clocks_time(u.clock);
            float hN = h24 ? T.h : clocks_hour12(T.h);
            ClkRun tr = clocks_run();
            if (h24 || hN >= 10.0) clocks_push(tr, int(hN / 10.0));
            clocks_push(tr, int(fmod(hN, 10.0)));
            clocks_push(tr, CLK_G_COLON);
            clocks_push(tr, int(T.m / 10.0));
            clocks_push(tr, int(fmod(T.m, 10.0)));
            float tw = clocks_runWidth(textAtlas, tr, fw, 0.02);
            float x0 = centered ? -0.5 * tw * cap : -0.5 * aspect + 0.085 * aspect;
            float d = clocks_runDist(textAtlas, samp, tr, fw, 0.02, (p - float2(x0, baseY)) / cap) - bias;
            ink = clocks_cov(d, cap * res.y);
            float dy = baseY - cap - 0.34 * cap;
            if (showDate && p.y < dy + 0.4 * dCap) {
                ClkRun dr = clocks_dateRun(u.date, u.clock, false, false);
                float dx0 = centered ? -0.5 * clocks_runWidth(textAtlas, dr, dfw, 0.04) * dCap : x0 + 0.012 * cap;
                float dd = clocks_runDist(textAtlas, samp, dr, dfw, 0.04, (p - float2(dx0, dy)) / dCap) - dbias;
                ink = max(ink, clocks_cov(dd, dCap * res.y) * 0.85);
            }
            if (!h24) {                                                 // small AM / PM after the time
                ClkRun ar = clocks_run();
                clocks_push(ar, CLK_G_A + ((T.h < 12.0) ? 0 : 15)); clocks_push(ar, CLK_G_A + 12);
                float aCap = cap * 0.17;
                float ax = x0 + tw * cap + (centered ? 0.05 : 0.07) * cap;
                float ad = clocks_runDist(textAtlas, samp, ar, dfw, 0.12, (p - float2(ax, baseY - cap + aCap)) / aCap) - dbias;
                ink = max(ink, clocks_cov(ad, aCap * res.y) * 0.85);
            }
        }
        float3 paint = (luma(A) > 0.32) ? A * 0.36 : mix(A, float3(1.0), 0.55);
        alb = mix(alb, paint, ink);

        float3 col = alb * amb;
        col += alb * lightC * sun.x * 0.80 * mix(1.0, bump, 1.0 - ink);
        col += alb * lightC * sun.y * 0.16;                             // bounce / bloom
        // after dark the painted type would vanish: let it glow faintly instead
        col = mix(col, mix(A, float3(0.80, 0.84, 0.92), 0.5) * 0.62, ink * (1.0 - sunUp));
        col = select(col, 0.82 + 0.18 * (1.0 - exp(-(col - 0.82) / 0.18)), col > 0.82);   // soft shoulder
        col += bandDither(px) * 2.0;
        return float4(col, 1.0);
    }
