//  Clocks_cases.h — switch cases for the Clocks pack (shader ids 50–53). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L, textAtlas. Scenes ignore src/base.

    case 50: { // TYPE CLOCK — the time set huge in a real system face. Styles: Relief (raised
               // plaster, tone-on-tone, lit by a light that follows the sun), Glass (clear
               // glass numerals on a drifting light field: refraction, absorption, a mirrored
               // studio key light, tinted shadows with focused light in them), Ink (flat, editorial).
               // p0 = (style, typeface, weight, size), p1 = (24h, seconds, date, depth);
               // colorA background, colorB numerals.
        int style = int(u.p0.x + 0.5), faceSel = int(u.p0.y + 0.5);
        float wgt = u.p0.z, size = max(u.p0.w, 0.3);
        bool h24 = u.p1.x > 0.5, secs = u.p1.y > 0.5, showDate = u.p1.z > 0.5;
        float depth = u.p1.w;
        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y;                       // screen-height units, y down
        bool glassS = style == 1, inkS = style == 2;

        float bias; float4 fw = clocks_face(faceSel, wgt, bias);
        ClkTypeLayout TL = clocks_typeLayout(textAtlas, u.clock, fw, h24, secs);
        float cap = min(0.30 * size, 0.84 * aspect / max(TL.width, 1.0));
        float capPx = cap * res.y;
        float fp = 1.0 / capPx;                                    // one pixel, in caps
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
        // profile width: bevel shoulder or glass rod radius, never under ~1.5 px (no sparkle when small)
        float pw = max(glassS ? 0.065 + 0.03 * depth : 0.016 + 0.020 * depth, 1.5 * fp);
        float aw = 0.75 * fp;
        float pen = (0.012 + 0.45 * off) * (glassS ? 1.7 : 1.0);   // glass: a lighter, softer shadow
        ClkTypeField F;
        F.d = CLK_FAR; F.g = float2(0.0); F.pres = 0.0; F.m = 0.0;
        F.shadow = 0.0; F.caus = 0.0; F.ao = 0.0; F.dim = 0.0;
        if (abs(q.y + 0.5) < 0.62 + off && abs(q.x) < 0.5 * TL.width + 0.45 + off)   // only near the figures
            F = clocks_typeField(textAtlas, samp, TL, fw, bias, q, eps, L2 * off, pen, aw, pw, glassS,
                                 inkS ? 0.05 : 0.025);

        // a broad pool of light on the ground, drifting with the light direction
        float2 pc = p + L2 * 0.35;
        float pool = exp(-dot(pc, pc) * 1.1);
        float vig = 1.0 - 0.32 * dot(p * float2(0.8, 1.0), p * float2(0.8, 1.0));
        float3 col;
        float3 dateGround;
        if (glassS) {                                              // GLASS — rounded glass rods
            float3 Bl = srgbToOklab(B);
            float3 B2 = oklabToSrgb(oklabHue(Bl, 0.75)), B3 = oklabToSrgb(oklabHue(Bl, -0.6));
            float3 bg = clocks_glassBg(p, t, A, B, B2, B3);
            dateGround = bg;
            float bm = max(max(B.r, B.g), max(B.b, 1e-3));
            float3 tint = mix(float3(1.0), B / bm, 0.32);          // the glass's own (faint) colour
            // rod cross-section: circular over pw from the silhouette, flat across the middle
            float r1 = 1.0 - clamp(-F.d / pw, 0.0, 1.0);
            float slope = r1 * rsqrt(max(1.0 - r1 * r1, 0.035)) * F.pres;
            float3 n = normalize(float3(F.g * slope, 1.0));
            float hgt = sqrt(max(1.0 - r1 * r1, 0.0)) * F.pres;
            float3 rv = float3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);   // mirrored view ray
            float lw = fwidth(dot(rv, L3));
            // the ground: a tinted, lighter shadow (light gets through) with focused light in it
            float3 ground = bg * vig * mix(float3(1.0), tint * 0.55, 0.55 * F.shadow) * (1.0 - 0.10 * F.ao)
                          + mix(bg, float3(1.0), 0.35) * tint * (0.13 * F.caus);
            col = ground;
            if (F.m > 0.0) {
                // refraction (IOR ≈ 1.5, slight dispersion): the backdrop under the glass, shifted
                // by how high the glass surface stands above it
                float th = (hgt * pw + lift) * cap;
                float3 tR = refract(float3(0, 0, -1), n, 1.0 / 1.48);
                float3 tG = refract(float3(0, 0, -1), n, 1.0 / 1.50);
                float3 tB = refract(float3(0, 0, -1), n, 1.0 / 1.53);
                float3 trn;
                trn.r = clocks_glassBg(p + tR.xy / max(-tR.z, 0.25) * th, t, A, B, B2, B3).r;
                trn.g = clocks_glassBg(p + tG.xy / max(-tG.z, 0.25) * th, t, A, B, B2, B3).g;
                trn.b = clocks_glassBg(p + tB.xy / max(-tB.z, 0.25) * th, t, A, B, B2, B3).b;
                trn *= vig * mix(float3(1.0), tint * 0.55, 0.55 * F.shadow * (1.0 - hgt));
                trn += mix(bg, float3(1.0), 0.35) * tint * (0.20 * F.caus);
                float3 absorb = pow(tint, float3(0.4 + 0.9 * hgt));            // thicker → deeper colour
                float edge = mix(1.0, 0.6, smoothstep(0.6, 0.98, r1) * F.pres);   // light lost at grazing exits
                float fres = 0.04 + 0.96 * pow(1.0 - n.z, 5.0);
                float3 room = mix(float3(luma(bg)), bg, 0.5) * 0.9 + 0.02;
                float3 env = clocks_glassEnv(rv, L3, bg * 0.8, room, lw);
                float3 glass = (1.0 - fres) * trn * absorb * edge + fres * env;
                // highlights roll off softly instead of clipping hard
                glass = select(glass, 0.86 + 0.14 * (1.0 - exp(-(glass - 0.86) / 0.14)), glass > 0.86);
                col = mix(ground, glass, F.m);
            }
        } else if (inkS) {                                         // INK
            col = A * (0.94 + 0.10 * pool) * vig;
            col *= 1.0 - (0.16 * F.shadow + 0.08 * F.ao) * depth;
            dateGround = col;
            col = mix(col, B, F.m * (F.dim > 0.5 ? 0.55 : 1.0));
        } else {                                                   // RELIEF — matte plaster
            // lime plaster: a faint cloudy tone, plus a fine grain (tone and micro-relief) that
            // only shows where a pixel can hold it (no shimmer in a small preview)
            float gs = 300.0, ms = 38.0;
            float gfade = smoothstep(0.30, 0.12, gs / res.y), mfade = smoothstep(0.30, 0.12, ms / res.y);
            float3 gn = clocks_noised(p * gs);
            float mn = clocks_grain(p * ms + 7.3);
            float2 bump = gn.yz * (0.016 * gfade);
            float grain = 1.0 + 0.008 * gfade * gn.x + 0.012 * mfade * mn;
            // the face's shading is held at its silhouette value just outside it, so a pixel the
            // edge only partly covers mixes the shoulder's own tone into the wall (never a flat-lit
            // fleck along the contour)
            float x = clamp(-F.d / pw, 0.0, 1.0);
            float slope = pow(1.0 - x, 1.4) * (0.55 + 0.55 * depth) * F.pres;   // soft rounded shoulder
            float3 n = normalize(float3(F.g * slope + bump, 1.0));
            float3 ng = normalize(float3(bump, 1.0));
            float nl = dot(n, L3) / L3.z, ngl = dot(ng, L3) / L3.z;           // 1 on flat faces
            float lit = 0.86 + 0.24 * pool;
            float3 ground = A * grain * lit * vig * (1.0 + 0.55 * (ngl - 1.0));
            ground *= 1.0 - 0.42 * F.shadow * (0.5 + 0.5 * depth) - 0.16 * F.ao * depth;
            dateGround = ground;
            float3 face = B * grain * lit * vig * (1.0 + 0.55 * (nl - 1.0));
            col = mix(ground, face, F.m);
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
            float gl = luma(dateGround);
            float3 lab = (gl > 0.45) ? dateGround * 0.42 : mix(dateGround, float3(1.0), 0.62);   // contrast tone
            float3 ink = (inkS && abs(luma(B) - luma(A)) > 0.2) ? mix(A, B, 0.78) : lab;
            col = mix(col, ink, dc * 0.9);
        }
        col += bandDither(px) * 2.0;
        return float4(col, 1.0);
    }


    case 51: { // FLIP CLOCK — a split-flap clock, one card per figure. Each change releases the
               // upper flap: a real slab with thickness, it falls through 180° in 3D (perspective,
               // lit, its edge catching the light as it passes edge-on, casting its shadow on the
               // card below), lands with a small bounce and shows the new figure. In 12-hour time
               // the hour card carries a small AM / PM that flips with it.
               // p0 = (typeface, 24h, seconds, date), p1.x = size; colorA cards, colorB numerals.
        int faceSel = int(u.p0.x + 0.5);
        bool h24 = u.p0.y > 0.5, secs = u.p0.z > 0.5, showDate = u.p0.w > 0.5;
        float size = max(u.p1.x, 0.3);
        float3 cardC = u.colorA.rgb, inkC = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y; p.y = -p.y;           // y up

        float bias;
        float4 fw = clocks_face(faceSel == 1 ? 2 : (faceSel == 2 ? 1 : 3), 0.5, bias);
        float db; float4 dfw = clocks_face(faceSel == 1 ? 2 : (faceSel == 2 ? 1 : 0), 0.55, db);

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
        int apN = h24 ? 0 : ((T.h < 12.0) ? 1 : 2), apO = h24 ? 0 : ((ph < 12.0) ? 1 : 2);

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

        int aN = (ci == 0) ? apN : 0, aO = (ci == 0) ? apO : 0;     // AM / PM rides the hour card
        bool changed = gN[ci] != gO[ci] || aN != aO;
        float e = changed ? ((ci >= 4) ? fract(T.s) : T.s) : 9.0;
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
        // the spindle the flaps hang on: short pins at each side of the hinge
        {
            float2 pp = float2(abs(P.x) - cw * 0.5 - 0.006, P.y);
            float dPin = length(float2(max(abs(pp.x) - 0.014, 0.0), pp.y)) - 0.012;
            float pinCov = clamp(0.5 - dPin / pxs, 0.0, 1.0);
            float3 pinC = mix(cardC, float3(0.5), 0.35) * 0.32 + 0.025;
            pinC *= 0.55 + 0.9 * smoothstep(-0.012, 0.010, pp.y);   // round: lit on top
            col = mix(col, pinC, pinCov);
        }
        // the flap stack peeking out under the card
        for (int s2 = 1; s2 <= 2; ++s2) {
            float ds = clocks_rrect(P - float2(0.0, -0.007 * float(s2)), float2(cw * 0.5 - 0.004 * float(s2), 0.5), CLK_FLIP_R);
            col = mix(col, cardC * (0.55 - 0.12 * float(s2)), clamp(0.5 - ds / pxs, 0.0, 1.0) * step(P.y, 0.0));
        }

        // ---- static halves
        float cardCov = clamp(0.5 - dCard / pxs, 0.0, 1.0);
        bool top = P.y > 0.0;
        bool showOld = !top && flipping && th < 3.1;
        int gStatic = showOld ? gO[ci] : gN[ci];
        int aStatic = top ? aN : 0;
        float dInk = (dCard < 0.01) ? clocks_cardInk(textAtlas, samp, gStatic, aStatic, P, fw, bias, dfw, db) : 1.0;
        // satin plastic: the upper half stands upright under the light, the lower one leans back
        float3 face = cardC * (top ? 1.03 : 0.95) * (1.0 + 0.05 * (abs(P.y) - 0.25) * (top ? 1.0 : -1.0));
        face *= 1.0 + (top ? 0.045 : 0.015) * smoothstep(0.05, 0.48, abs(P.y)) * (top ? 1.0 : -1.0);
        face = mix(face, inkC * (top ? 1.0 : 0.94), clamp(0.5 - dInk / pxs, 0.0, 1.0));
        // the hinge: the upper flap's lip rolls away into the slit, and the flap stands a hair
        // proud of the lower one, laying a soft contact shadow across its top (light from above)
        face *= top ? 1.0 - 0.20 * exp(-P.y / 0.014)
                    : (1.0 - 0.16 * exp(P.y / 0.010)) * (1.0 - 0.13 * exp(P.y / 0.055));
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

        // ---- the falling flap: a slab CLK_FLIP_TH thick, ray-traced in card space from a centred
        // eye a little above the clock (each card seen straight on: no overhang into the next one)
        if (flipping) {
            float3 eye = float3(0.0, (0.12 - cc.y) / Hk, 2.6 / Hk);
            float3 dir = float3(P, 0.0) - eye;
            float den = dot(dir, fn);
            den = (abs(den) < 1e-5) ? ((den < 0.0) ? -1e-5 : 1e-5) : den;
            float e0 = dot(eye, fn);
            bool front = e0 > 0.0;                                  // which face looks at the eye
            float ht = 0.5 * CLK_FLIP_TH;
            float sNear = ((front ? ht : -ht) - e0) / den, sFar = ((front ? -ht : ht) - e0) / den;
            float3 hN = eye + sNear * dir, hF = eye + sFar * dir;
            float2 f = float2(hN.x, dot(hN, fu)), ff = float2(hF.x, dot(hF, fu));
            float2 fwf = fwidth(f);
            float fpx = clamp(max(fwf.x, fwf.y), pxs, 12.0 * pxs);
            float dN = clocks_flapShape(f), dFar = clocks_flapShape(ff);
            float cN = clamp(0.5 - dN / fpx, 0.0, 1.0) * step(0.0, sNear) * step(sNear, 1.0001);
            float cF = clamp(0.5 - dFar / fpx, 0.0, 1.0) * step(0.0, sFar) * step(sFar, 1.05);
            float cRim = max(cF - cN, 0.0);                         // seen through the slab's edge
            if (cRim > 0.0) {
                float2 fm = 0.5 * (f + ff);
                const float h1 = 0.003;
                float2 gS = float2(clocks_flapShape(fm + float2(h1, 0.0)) - clocks_flapShape(fm - float2(h1, 0.0)),
                                   clocks_flapShape(fm + float2(0.0, h1)) - clocks_flapShape(fm - float2(0.0, h1)));
                gS *= rsqrt(max(dot(gS, gS), 1e-12));
                float3 nR = normalize(float3(gS.x, 0.0, 0.0) + gS.y * fu);
                float3 hv = normalize(Lw + normalize(-dir));
                float3 rimC = cardC * (0.40 + 0.80 * max(dot(nR, Lw), 0.0)) + 0.10 * pow(max(dot(nR, hv), 0.0), 24.0);
                col = mix(col, rimC, cRim);
            }
            float3 nf = front ? fn : -fn;
            float shade = min((0.30 + 0.70 * max(dot(nf, Lw), 0.0)) / (0.30 + 0.70 * Lw.z), 1.08);
            int gF = front ? gO[ci] : gN[ci];
            int aF = front ? aO : 0;
            float2 fxy = front ? f : float2(f.x, -f.y);
            float dI = clocks_cardInk(textAtlas, samp, gF, aF, fxy, fw, bias, dfw, db);
            float3 fc = cardC * (front ? 1.03 : 0.95);
            fc = mix(fc, inkC, clamp(0.5 - dI / fpx, 0.0, 1.0));
            fc *= shade * (1.0 - 0.18 * exp(-abs(f.y) / 0.02));
            col = mix(col, fc, cN);
        }

        float dCap = max(H * 0.06, 10.0 / res.y);
        float ybD = cy - 0.5 * H - 0.13 * H - dCap;                    // date baseline, y up
        if (showDate && abs(p.y - ybD - 0.5 * dCap) < 1.4 * dCap) {
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

    case 52: { // WORD CLOCK — the time spelled out in a letter grid. The letters are cut into the
               // panel (a stencilled faceplate, or a blind letterpress impression in paper): their
               // walls catch a soft top-left light. Lit words glow from behind, haloed in their
               // own shapes, and spill a little light around; changes fade through in reading order.
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
            // light spilling round the word: a tight and a wide falloff along its centre line
            // (no plateau, no visible edge)
            float x0w = float(w.y) + 0.5, x1w = float(w.y + w.z) - 0.5;
            float2 dq = gp - float2(clamp(gp.x, x0w, x1w), float(w.x) + 0.5);
            float r2 = dot(dq, dq);
            float fall = 1.0 / (1.0 + 0.45 * r2);
            glow += a * fall * fall;
            if (inGrid && row == int(w.x) && col >= int(w.y) && col < int(w.y + w.z)) litHere = a;
        }

        // the letter in this cell, with its gradient (for the cut walls)
        float d = CLK_FAR;
        float2 dg = float2(0.0);
        float apos = 0.0;
        const float ge = 0.02;                                         // caps
        float fpC = 1.0 / capPx;                                       // one pixel, in caps
        float ww = max(0.04, 1.3 * fpC);                               // the cut wall's width
        if (inGrid) {
            float2 lc = (gp - float2(col, row) - 0.5) * (pitch / capS);   // caps from the cell centre
            int g = clocks_gid(CLK_WGRID[row][col], true);
            ClkGlyph G = clocks_glyph(textAtlas, g, fw);
            float2 lq = lc + float2(0.5 * dot(G.adv, fw), -0.5);
            d = clocks_gdist(textAtlas, samp, G, lq, fw) - bias;
            if (d < fpC && d > -ww - fpC)                                 // only on the walls
                dg = float2(clocks_gdist(textAtlas, samp, G, lq + float2(ge, 0.0), fw) - bias - d,
                            clocks_gdist(textAtlas, samp, G, lq + float2(0.0, ge), fw) - bias - d);
            if (row == 8 && col <= 1) {                                   // the apostrophe in O'CLOCK
                ClkGlyph Ga = clocks_glyph(textAtlas, CLK_G_APOS, fw);
                float2 la = (gp - float2(1.0, 8.5)) * (pitch / capS) + float2(0.5 * dot(Ga.adv, fw), -0.5);
                float da = clocks_gdist(textAtlas, samp, Ga, la, fw) - bias;
                if (da < d) {
                    d = da; apos = 1.0;
                    dg = float2(clocks_gdist(textAtlas, samp, Ga, la + float2(ge, 0.0), fw) - bias - da,
                                clocks_gdist(textAtlas, samp, Ga, la + float2(0.0, ge), fw) - bias - da);
                }
            }
        }
        if (apos > 0.5) {
            bool on = (mN >> 24u) & 1u, was = (mO >> 24u) & 1u;
            litHere = on ? (was ? 1.0 : smoothstep(1.83, 3.23, T.s)) : (was ? 1.0 - smoothstep(0.0, 1.1, T.s) : 0.0);
        }
        float cov = clocks_cov(d, capPx);

        // the cut: a wall ~0.04 caps (at least ~1.3 px) wide inside each letter, its slope lit
        // from the top left; deeper letters read darker at their foot
        float wall = smoothstep(-ww, 0.0, d) * cov;                     // 1 at the rim → 0 on the floor
        float2 gn = dg * rsqrt(max(dot(dg, dg), 1e-10));
        float facing = dot(-gn, normalize(float2(-0.55, -0.83)));        // inward slope · light (y down)
        float cut = 1.0 + wall * (0.30 * facing - 0.06) * smoothstep(12.0, 30.0, capPx);   // too small to read: flat

        // the panel: a soft top light, and a fine grain (paper tooth / powder coat) where a pixel holds it
        float2 pv = p * float2(0.75, 1.0);
        float gs = 420.0;
        float gfade = smoothstep(0.30, 0.12, gs / res.y);
        float tooth = 1.0 + gfade * 0.04 * clocks_grain(p * gs);
        float3 panel = A * tooth * (1.0 - 0.28 * dot(pv, pv)) * (0.97 + 0.06 * smoothstep(0.5, -0.5, p.y));
        panel += B * glow * glowAmt * 0.042;                             // light spill on the panel
        float3 off = (mix(A, B, unlit) * tooth + B * glow * glowAmt * 0.04) * cut;
        float led = 1.0 + 0.025 * (hash21(float2(col, row) + 7.1) - 0.5) * glowAmt;   // LED-to-LED variance
        float3 lit = B * (1.0 + 0.18 * glowAmt) * led * mix(cut, 1.0, glowAmt);
        // a backlit diffuser seen through the cut: it burns hottest (whiter) down the middle of a
        // stroke and a touch deeper and warmer toward the faceplate's edge
        float gl = smoothstep(0.0, 0.35, glowAmt);
        float core = smoothstep(0.0, -max(1.3 * ww, 2.5 * fpC), d);
        lit = mix(lit * (1.0 - 0.08 * gl), lit + max(1.0 - lit, 0.0) * (0.34 * gl), core);
        float3 ink = mix(off, lit, litHere);
        float3 colr = mix(panel, ink, cov);
        float hal = smoothstep(CLK_FAR, 0.0, d);                        // fades to 0 at the field's reach
        colr += B * litHere * glowAmt * (0.30 * hal * hal * hal + 0.10 * hal) * (1.0 - cov);   // letter halo: hot rim, soft skirt
        colr += bandDither(px) * 2.0;
        return float4(colr, 1.0);
    }

    case 53: { // WINDOW LIGHT — a calm wall in sunlight: four-pane window light with a leafy
               // branch's shadow swaying in it, travelling with the real sun (and the moon after
               // dark), the time and date set on the wall in New York.
               // p0 = (typeface, layout, 24h, date), p1 = (leaves, follow sun, sway, size);
               // colorA wall, colorB sunlight.
        int faceSel = int(u.p0.x + 0.5), layout = int(u.p0.y + 0.5);
        bool h24 = u.p0.z > 0.5, showDate = u.p0.w > 0.5;
        float leaves = u.p1.x, sway = u.p1.z, size = max(u.p1.w, 0.3);
        bool follow = u.p1.y > 0.5;
        float3 A = u.colorA.rgb, B = u.colorB.rgb;
        float aspect = res.x / res.y;
        float2 p = (px - 0.5 * res) / res.y;                       // y down

        // the sun across the day (0 rising … 1 setting), how far up it is, how golden; the moon
        float hr = u.clock.x;
        float day = 0.62 + 0.04 * sin(t * 0.004), sunUp = 1.0, warm = 0.0;
        float mday = 0.5, moon = 0.0;
        if (follow && u.sky.y > 0.5) {                              // live sun and moon
            float arc = max(u.sun.z, 0.05), marc = max(u.moon.z, 0.05);
            day = clamp((u.sun.y + arc) / (2.0 * arc), 0.0, 1.0);
            sunUp = smoothstep(-0.035, 0.05, u.sun.x);
            warm = 1.0 - smoothstep(0.03, 0.45, u.sun.x);           // golden when it's low
            mday = clamp((u.moon.y + marc) / (2.0 * marc), 0.0, 1.0);
            moon = smoothstep(-0.02, 0.08, u.moon.x) * (0.25 + 0.75 * (0.5 - 0.5 * cos(u.moon.w)));
        } else if (follow) {                                        // a seasonal day at ~40° N
            float doy = u.date.w;
            float decl = -0.4091 * cos(6.2832 * (doy + 10.0) / 365.0);
            float hd = acos(clamp(-tan(0.698) * tan(decl), -1.0, 1.0)) * 3.8197;   // hours
            float noon = 12.2 + ((doy > 72.0 && doy < 307.0) ? 1.0 : 0.0);         // summer time
            float rise = noon - hd, set = noon + hd;
            day = clamp((hr - rise) / (set - rise), 0.0, 1.0);
            sunUp = smoothstep(rise - 0.3, rise + 0.5, hr) * smoothstep(set + 0.3, set - 0.5, hr);
            warm = 1.0 - 4.0 * day * (1.0 - day);
            mday = clamp(fract((hr - set) / 24.0) * 2.0 - 0.15, 0.0, 1.0);
            moon = 0.6;
        }
        // after dark: the moon's patch, or a dim, blurred one from the sky's glow when it's down
        float glowSky = 0.22;
        float night = max(moon, glowSky);
        float pd = (sunUp > 0.01) ? day : mday;
        float diffuse = (sunUp > 0.01) ? 0.0 : mix(0.03, 0.0, smoothstep(glowSky, 0.6, moon));
        float3 sun = clocks_windowLight(p, pd, t, leaves, sway, aspect, 1.0 / res.y, diffuse);
        float cloud = 0.88 + 0.12 * smoothstep(-0.35, 0.35, sin(t * 0.021) + 0.6 * sin(t * 0.0137 + 1.3));
        float3 sunC = mix(B, B * float3(1.0, 0.80, 0.58), warm * 0.55);
        float3 moonC = float3(0.55, 0.66, 0.95) * 0.30 * night / 0.6;
        float3 lightC = mix(moonC, sunC, sunUp) * cloud;

        // plaster: albedo mottling + a fine bump that only shows in raking light
        float mott = 0.5 * clocks_noised(p * 7.0 + 2.0).x + 0.25 * clocks_noised(float2(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 14.2 + 2.0).x;
        float3 alb = A * (1.0 + 0.05 * mott);
        float2 bg = clocks_noised(p * 34.0).yz;                          // slope of the fine bump
        float bump = 1.0 + 0.55 * dot(bg, float2(0.05, -0.03));
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
            float pmn = T.m - 1.0, phr = T.h;
            if (pmn < 0.0) { pmn = 59.0; phr = fmod(T.h + 23.0, 24.0); }
            // a new minute never cuts in: the run slides into its new layout, figures that change
            // fade away and the new ones fade up (~1.1 s), figures that stay put stay solid
            bool changing = T.s < 1.1;
            float slide = clocks_ease(T.s / 1.1);
            float wN = clocks_ease((T.s - 0.40) / 0.70), wO = 1.0 - clocks_ease(T.s / 0.50);
            float xL = -0.5 * aspect + 0.085 * aspect;
            float x0 = xL;
            ClkRun rNew = clocks_timeRun(T.h, T.m, h24);
            ClkRun rOld = changing ? clocks_timeRun(phr, pmn, h24) : rNew;
            float endX;
            float2 tq = (p - float2(0.0, baseY)) / cap;
            ink = clocks_timeCov(textAtlas, samp, rOld, rNew, fw, bias, 0.02, centered, xL / cap,
                                 slide, wO, wN, tq, cap * res.y, endX);
            if (!h24) {                                                 // small AM / PM after the time
                float aCap = cap * 0.17;
                float ax = endX * cap + (centered ? 0.05 : 0.07) * cap;
                bool pmN = T.h >= 12.0, pmO = (changing ? phr : T.h) >= 12.0;
                for (int st = 0; st < 2; ++st) {
                    bool pmS = (st == 0) ? pmN : pmO;
                    float w = (pmN == pmO) ? ((st == 0) ? 1.0 : 0.0) : ((st == 0) ? wN : wO);
                    if (w <= 0.0) continue;
                    ClkRun ar = clocks_run();
                    clocks_push(ar, CLK_G_A + (pmS ? 15 : 0)); clocks_push(ar, CLK_G_A + 12);
                    float ad = clocks_runDist(textAtlas, samp, ar, dfw, 0.12, (p - float2(ax, baseY - cap + aCap)) / aCap) - dbias;
                    ink = max(ink, clocks_cov(ad, aCap * res.y) * 0.85 * w);
                }
            }

            float dy = baseY - cap - 0.34 * cap;
            if (showDate && p.y < dy + 0.4 * dCap) {
                ClkRun dr = clocks_dateRun(u.date, u.clock, false, false);
                float dx0 = centered ? -0.5 * clocks_runWidth(textAtlas, dr, dfw, 0.04) * dCap : x0 + 0.012 * cap;
                float dd = clocks_runDist(textAtlas, samp, dr, dfw, 0.04, (p - float2(dx0, dy)) / dCap) - dbias;
                ink = max(ink, clocks_cov(dd, dCap * res.y) * 0.85);
            }
        }
        float3 paint = (luma(A) > 0.32) ? A * 0.36 : mix(A, float3(1.0), 0.55);
        alb = mix(alb, paint, ink);

        float3 col = alb * amb;
        col += alb * lightC * sun.x * 0.80 * mix(1.0, bump, 1.0 - ink);
        col += alb * lightC * sun.y * 0.16;                             // bounce / bloom
        col += alb * lightC * sun.z * float3(0.055, 0.075, 0.030);     // light through the leaves
        // after dark the painted type would vanish: let it glow faintly instead
        col = mix(col, mix(A, float3(0.80, 0.84, 0.92), 0.5) * 0.62, ink * (1.0 - sunUp));
        col = select(col, 0.82 + 0.18 * (1.0 - exp(-(col - 0.82) / 0.18)), col > 0.82);   // soft shoulder
        col += bandDither(px) * 2.0;
        return float4(col, 1.0);
    }
