//  Flowing_cases.h — switch cases for the Flowing pack (shader ids 54–57). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L. Scenes ignore src/base.

    case 54: { // CURRENTS — four depth layers of streamlines (isolines of a stream function),
               // gathered into luminous ribbons that follow the flow; each strand has its own
               // brightness and hue, light pulses travel along them, and layers away from the
               // focal plane defocus into soft glowing bands.
               // p0 = (speed, density, depth of field, glow), p1.x hue spread, p1.y pulses.
        float speed = u.p0.x, density = max(u.p0.y, 0.1), dof = u.p0.z, glowAmt = u.p0.w;
        float hueSpread = u.p1.x, pulseAmt = u.p1.y;
        float aspect = res.x / res.y, k = res.y / 1000.0;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float ts = t * speed;
        float3 bg = srgbToLinear(u.colorA.rgb);
        float3 Bk = srgbToOklab(u.colorB.rgb);
        float3 col = bg * (1.1 - 0.5 * dot(p, p));
        // three hue keys (−2H, 0, +2H around the Light color); strands blend between them
        float H = max(hueSpread, 1e-3);
        float3 Bs = float3(Bk.x, Bk.yz * 1.25);
        float3 kM = flowing_oklabToLinear(oklabHue(Bs, -2.0 * H));
        float3 k0 = flowing_oklabToLinear(Bs);
        float3 kP = flowing_oklabToLinear(oklabHue(Bs, 2.0 * H));
        const int NL = 3;
        const float focusZ = 0.42;
        for (int li = 0; li < NL; ++li) {
            float fl = float(li);
            float z = fl / float(NL - 1);                        // 0 far → 1 near
            float sc = mix(2.1, 0.75, z);
            float an = 0.18 + (fl - 1.4) * 0.05;
            float2 q = float2(cos(an) * p.x - sin(an) * p.y, sin(an) * p.x + cos(an) * p.y) * sc
                     + float2(ts * mix(0.016, 0.07, z) + 3.7 * fl, 1.3 * fl);
            float psi = flowing_stream(q, ts * 0.11, fl * 2.1);
            float v = psi * density * mix(80.0, 15.0, z * z);
            float fw = max(fwidth(v), 1e-5);                     // lines per pixel
            float wpx = max(0.7, k * (0.45 + 0.35 * z)) + k * dof * 22.0 * pow(abs(z - focusZ), 1.7);
            float energy = k / wpx;                              // defocus spreads the same light
            float atm = mix(0.38, 1.0, z);
            // ribbons: strands gather in bands that follow the streamlines and breathe slowly
            float wob = sin(q.x * 0.5 - ts * 0.03 + fl * 1.7);
            float rib = 0.5 + 0.5 * sin(psi * 2.4 + 1.2 * wob + fl * 2.0 + ts * 0.02);
            rib *= rib; rib *= rib; rib *= rib;
            float env = mix(0.01, 1.0, rib);
            float shift = (z - 0.5) * 0.4 + 0.8 * wob;          // hue drifts across the field, in units of 2H
            float sh = clamp(shift, -1.0, 1.0);
            float3 hz = sh < 0.0 ? mix(k0, kM, -sh) : mix(k0, kP, sh);
            col += hz * glowAmt * 0.05 * atm * rib * (0.3 + 0.7 * density);   // scattered haze
            float id0 = floor(v + 0.5);
            float idStep = v > id0 ? 1.0 : -1.0;
            bool both = wpx * fw > 0.1;                          // neighbour only matters when blurred
            for (int j = 0; j < 2; ++j) {
                if (j == 1 && !both) break;
                float id = id0 + float(j) * idStep;
                float dpx = abs(v - id) / fw;
                float h  = hash21(float2(id * 0.137 + 0.31, fl * 7.31 + 0.5));
                float h2 = hash21(float2(id * 0.291 + 3.1, fl * 3.7 + 1.1));
                float bright = 0.03 + 0.97 * h * h * h * h;          // a few bright strands, many faint
                float ph = q.x * 1.3 - ts * (0.22 + 0.4 * h2) + h2 * 40.0;
                float pulse = max(sin(ph), 0.0);
                pulse *= pulse; pulse *= pulse; pulse *= pulse;  // ^8
                pulse *= pulse * pulse;                          // ^24
                float I = bright * env * (5.0 + pulseAmt * 16.0 * pulse);
                float x2 = dpx * dpx / (wpx * wpx);
                float core = exp(-1.4 * x2);                     // hot centre …
                float bq = 1.0 / (1.0 + 0.25 * x2);
                float body = bq * bq * 0.32;                     // … inside a coloured sheath
                float hq = 1.0 / (1.0 + dpx / (wpx * 2.5 + 3.0 * k));
                float halo = glowAmt * 0.06 * hq * hq;
                float sl = clamp(shift + (h2 - 0.5) * 0.6, -1.0, 1.0);
                float3 lc = sl < 0.0 ? mix(k0, kM, -sl) : mix(k0, kP, sl);
                float e = I * energy * atm * mix(0.9, 1.15, h);
                col += (lc * (core * 0.9 + body + halo) + (lc * 0.5 + 0.5) * core * 0.35 * clamp(e, 0.0, 1.5)) * e;
            }
        }
        return flowing_out(col, px);
    }

    case 55: { // LAVA LAMP — metaball wax (analytic gradient → bevelled dome normals) lit by a
               // lamp below: wrap diffuse + thickness-dependent transmission, glossy reflections
               // of a window, a soft defocused back layer seen through, behind curved glass.
               // p0 = (speed, blobs, size, gloss), p1.x lamp glow, p1.y glass.
        float speed = u.p0.x, size = max(u.p0.z, 0.3), gloss = u.p0.w;
        int nb = clamp(int(u.p0.y + 0.5), 1, 10);
        float heat = u.p1.x, glassOn = u.p1.y;
        float aspect = res.x / res.y;
        float2 p = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);   // y up
        float xc = p.x / (0.5 * aspect);                          // −1 … 1 across the glass
        if (glassOn > 0.5) {                                      // cylinder: compress toward the rim
            p.x = asin(clamp(xc * 0.93, -1.0, 1.0)) / asin(0.93) * 0.5 * aspect;
        }
        float ts = t * speed * 0.16;
        float3 wax = srgbToLinear(u.colorB.rgb);
        float3 liq = srgbToLinear(u.colorA.rgb);
        float lamp = heat * (0.18 + 1.5 * exp(-(p.y + 0.5) * 2.6));       // bulb below the frame
        float3 warm = wax * 0.7 + float3(0.30, 0.18, 0.08);

        // ---- front wax
        float3 F = flowing_lavaField(p, ts, nb, size, 0.0, aspect * 0.86);
        float pool = 1.0 * exp((-0.50 - p.y + 0.015 * sin(p.x * 4.0 + ts * 2.0) + 0.008 * sin(p.x * 9.0 - ts * 3.0)) * 16.0);
        float cap  = 0.6 * exp((p.y - 0.53 + 0.010 * sin(p.x * 3.0 - ts * 1.5)) * 18.0);
        F.x += pool + cap;
        F.z += -16.0 * pool + 18.0 * cap;
        const float T = 0.32;
        float gl = length(F.yz) + 1.2;                            // floored: saddles stay stable
        float sd = (T - F.x) / gl;                                // ≈ signed distance, <0 inside
        float aa = 1.2 / res.y;
        float cover = smoothstep(aa, -aa, sd);
        float rho = 0.075 * size;
        float s = clamp(-sd / rho, 0.0, 1.0);
        float2 dir = -F.yz / (length(F.yz) + 1e-3);
        float3 n = normalize(float3(dir * (1.0 - s), sqrt(max(1.0 - (1.0 - s) * (1.0 - s), 0.0)) + 0.05));
        float thick = clamp(-sd / (0.16 * size), 0.0, 1.0);

        // ---- back layer, seen through the liquid (and refracted through the front wax)
        float2 pb = p * 1.18 + float2(0.21, 0.04) + n.xy * cover * 0.05;
        float3 Fb = flowing_lavaField(pb, ts * 0.8 + 11.0, max(nb / 2 + 1, 2), size * 1.1, 37.0, aspect * 1.1);
        float glb = length(Fb.yz) + 1.2;
        float sdb = (T - Fb.x) / glb;
        float coverB = smoothstep(0.018, -0.022, sdb);
        float thickB = clamp(-sdb / (0.2 * size), 0.0, 1.0);

        float3 col = liq * (0.35 + 0.9 * lamp);
        col += wax * lamp * 0.10 * smoothstep(0.0, T, F.x + Fb.x * 0.5);    // light scattered by wax
        float3 waxBack = pow(wax, float3(1.2 + 1.2 * thickB)) * lamp * 0.55;
        col = mix(col, waxBack + liq * 0.1, coverB * 0.85);

        // ---- shade front wax
        float3 ld = normalize(float3(-p.x * 0.25, -1.0, 0.45));
        float wrap = clamp((dot(n, ld) + 0.55) / 1.55, 0.0, 1.0);
        float hot = exp(-(p.y + 0.5) * 3.0);                       // wax near the bulb runs hotter
        float3 waxH = flowing_oklabToLinear(oklabHue(srgbToOklab(u.colorB.rgb), 0.35 * hot) + float3(0.06 * hot, 0.0, 0.0));
        float3 trans = pow(waxH, float3(0.8 + 1.8 * thick));      // thick wax deepens & saturates
        float rimLit = pow(1.0 - n.z, 1.5) * clamp(-dir.y * 0.8 + 0.3, 0.0, 1.0);
        float3 waxCol = lamp * (waxH * wrap * 0.55 + trans * (0.35 + 0.6 * wrap) + waxH * rimLit * 0.9)
                      + wax * 0.03;
        float3 r = float3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);
        float fres = 0.04 + 0.96 * pow(1.0 - n.z, 5.0);
        float3 spec = flowing_lavaEnv(r, warm) * mix(0.06, 1.0, fres) * gloss * 1.3;
        waxCol += spec;
        col = mix(col, waxCol, cover);

        // ---- curved glass: rim falloff, vertical reflections, faint caustic
        if (glassOn > 0.5) {
            float ax = abs(xc);
            col *= 1.0 - 0.55 * pow(ax, 4.0);
            float edgeY = 0.75 + 0.25 * smoothstep(-0.5, 0.5, p.y);
            col += float3(1.0, 0.97, 0.94) * edgeY * (0.07 * smoothstep(0.03, 0.0, abs(xc + 0.74))
                                                     + 0.035 * exp(-abs(xc + 0.58) * 9.0)
                                                     + 0.035 * smoothstep(0.02, 0.0, abs(xc - 0.86)));
            col += warm * 0.06 * heat * smoothstep(0.8, 1.0, ax) * smoothstep(0.2, -0.5, p.y);
        }
        return flowing_out(col, px);
    }

    case 56: { // INK BLOOM — drops of ink released at staggered times, carried by a slowly
               // changing divergence-free vortex flow (semi-Lagrangian back-trace, one shared
               // trace for all drops) so they stretch into filaments and curls exactly as dye
               // does. Texture lives in material space (the trace's end point), so it streaks
               // along the flow. Light water absorbs per Beer–Lambert; dark water glows like smoke.
               // p0 = (speed, scale, turbulence, ink), p1.x second ink.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), curl = u.p0.z, dens = u.p0.w, second = u.p1.x;
        float aspect = res.x / res.y;
        float zoom = 2.4 / sc;
        float2 q = (uv - 0.5) * float2(aspect, 1.0) * zoom;     // y down: ink sinks toward +y
        float ts = t * speed;
        const int NB = 5;                    // drops alive at once
        const int NS = 6;                    // trace steps over a drop's whole life
        const float life = 9.0;              // flow-time a drop lives
        float cyc0 = ts * 0.02;
        float age[NB]; float2 X[NB];
        for (int j = 0; j < NB; ++j) { age[j] = fract(cyc0 + float(j) / float(NB)); X[j] = q; }
        float tau = ts * 0.12;
        float dt = life / float(NS);
        float2 x = q;
        for (int k = 0; k < NS; ++k) {
            float2 v = flowing_inkVel(x, tau - float(k) * dt) * curl + float2(0.0, 0.05);   // + sinking
            float2 xn = x - v * dt;
            for (int j = 0; j < NB; ++j) {
                float sj = age[j] * float(NS) - float(k);
                if (sj >= 0.0 && sj < 1.0) X[j] = mix(x, xn, sj);
            }
            x = xn;
        }
        // material-space texture: billows + fine folds, stretched by the flow into streaks
        float2 m = x * 2.6;
        float bill = gfbm(m, 2);
        float fold = 1.0 - abs(gnoise(m * 3.1 + 5.0) * 1.7);
        fold = fold * fold * fold;
        float mfw = length(fwidth(x)) * 8.0;                     // fade detail that would alias
        float detail = mix(bill * 0.9 + fold * 0.35, 0.1, clamp(mfw, 0.0, 1.0));

        float3 inkA = srgbToLinear(u.colorB.rgb);
        float3 inkB = flowing_oklabToLinear(oklabHue(srgbToOklab(u.colorB.rgb), 1.15));
        float3 sigA = -log(clamp(inkA, 0.004, 0.98));
        float3 sigB = -log(clamp(inkB, 0.004, 0.98));
        float lightness = smoothstep(0.18, 0.55, luma(u.colorA.rgb));
        float dWarp = mix(0.6, 1.0, lightness), bodyPow = mix(1.1, 2.0, lightness);   // smoke is softer
        float3 tauI = float3(0.0), glowSum = float3(0.0);
        float dsum = 0.0;
        for (int j = 0; j < NB; ++j) {
            float a = age[j];
            float cyc = floor(cyc0 + float(j) / float(NB));
            float id = cyc * float(NB) + float(j);
            float2 hc = hash22(float2(id * 0.73 + 1.3, 4.1));
            float lane = fmod(float(j) + 2.0 * cyc, float(NB));            // spread drops across
            float2 c = float2(((lane + 0.15 + 0.7 * hc.x) / float(NB) - 0.5) * 0.95 * aspect,
                              (hc.y - 0.5) * 0.5 - 0.12) * zoom;
            float r0 = (0.36 + 0.16 * hc.y) * (0.3 + 0.7 * smoothstep(0.0, 0.10, a));  // blooms open
            float r = length((X[j] - c) * float2(1.0, 1.2)) / r0 + detail * (0.35 + 0.4 * a) * dWarp;
            float body = pow(clamp(1.0 - r, 0.0, 1.0), bodyPow);
            float amount = smoothstep(0.0, 0.04, a) * (1.0 - a) * (0.75 + 0.25 * (1.0 - a)) * (0.7 + 0.3 * smoothstep(0.0, 0.3, a));
            float dj = body * amount * (0.55 + 1.3 * clamp(detail + 0.35, 0.0, 1.2));
            bool alt = hash21(float2(id, 9.7)) < second;
            tauI += (alt ? sigB : sigA) * dj;
            glowSum += (alt ? inkB : inkA) * dj;
            dsum += dj;
        }
        tauI *= dens * 1.2;
        dsum *= dens;
        float3 water = srgbToLinear(u.colorA.rgb);
        float2 pc = uv - 0.5;
        float3 bgw = water * (1.04 - 0.10 * uv.y - 0.25 * dot(pc, pc));
        float3 absorbed = bgw * exp(-tauI);
        // dark water: ink scatters light like smoke — thin wisps faint, dense cores bloom
        float em = 1.0 - exp(-dsum * 1.1);
        float3 hue = glowSum / max(dsum / max(dens, 1e-3), 1e-4);
        float3 smoky = bgw + hue * (em * 0.55 + em * em * 0.9) + (hue * 0.4 + 0.3) * em * em * em * 0.5;
        float3 col = mix(smoky, absorbed, lightness);
        return flowing_out(col, px);
    }

    case 57: { // FIREFLIES — a dusk meadow photographed wide open: twilight sky, a soft
               // treeline, four depth layers of slowly flashing flies (bokeh discs away from the
               // focal plane), low mist and swaying foreground grass.
               // p0 = (fireflies, speed, focus, aperture), p1.x glow size, p1.y meadow.
        float countK = u.p0.x, speed = u.p0.y, focus = u.p0.z, blur = u.p0.w;
        float sizeK = max(u.p1.x, 0.2), meadow = u.p1.y;
        float aspect = res.x / res.y;
        float2 p = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);    // y up
        float pixel = 1.0 / res.y;
        float ts = t * speed;
        float3 Ak = srgbToOklab(u.colorA.rgb), Gk = srgbToOklab(u.colorB.rgb);
        float3 A = srgbToLinear(u.colorA.rgb);
        float3 glow = srgbToLinear(u.colorB.rgb) * 2.4;
        // twilight: zenith = Dusk color, a cooler violet band, then the warm afterglow
        float3 midK = oklabHue(float3(min(Ak.x + 0.10, 0.8), Ak.yz * 1.2), 0.35);
        float3 hzK = float3(min(Ak.x + 0.30, 0.82), 0.075, 0.055);   // peach afterglow, always warm
        hzK.yz = mix(hzK.yz, Gk.yz * 0.5, 0.15);
        float3 midC = flowing_oklabToLinear(midK), horizonC = flowing_oklabToLinear(hzK);
        const float horizonY = -0.10;
        float sy = p.y - horizonY;
        float3 col = mix(horizonC, midC, smoothstep(0.0, 0.28, sy));
        col = mix(col, A, smoothstep(0.15, 0.62, sy));
        col += horizonC * 0.35 * exp(-max(sy, 0.0) * 14.0);
        if (meadow > 0.5) {
            // treeline: overlapping round crowns over a slow height envelope, leafy edge
            float x = p.x;
            const float tw = 0.045;
            float ix = floor(x / tw);
            float tree = horizonY + 0.012;
            for (int k = -2; k <= 2; ++k) {
                float i = ix + float(k);
                float3 h = pcg3(float3(i + 2048.0, 21.0, 5.0));
                float rr = tw * (0.7 + 1.1 * h.y);
                float cx = (i + 0.5 + (h.x - 0.5) * 0.7) * tw;
                float cy = horizonY + 0.015 + 0.075 * vnoise(float2(i * 0.21, 2.0)) + 0.03 * h.z;
                float dx = x - cx;
                if (abs(dx) < rr) tree = max(tree, cy + sqrt(rr * rr - dx * dx) * 0.85);
            }
            tree += 0.004 * (vnoise(float2(x * 90.0, 1.0)) + vnoise(float2(x * 37.0, 4.0)) - 1.0);
            float tb = pixel * 1.5 + blur * abs(0.08 - focus) * 0.012;
            float treeCov = smoothstep(tree + tb, tree - tb, p.y);
            float3 treeC = mix(A * 0.22, horizonC * 0.10, 0.5);
            col = mix(col, treeC, treeCov);
            float fieldT = smoothstep(horizonY, -0.5, p.y);
            float3 field = mix(treeC * 1.6 + horizonC * 0.09, A * 0.10 + horizonC * 0.01, sqrt(fieldT));
            col = mix(col, field, smoothstep(horizonY + 0.003, horizonY - 0.003, p.y));
            float mist = exp(-abs(p.y - horizonY + 0.02) * 18.0) * (0.75 + 0.25 * vnoise(float2(x * 3.0 + ts * 0.02, 0.5)));
            col += horizonC * 0.10 * mist;
        }
        for (int li = 0; li < 3; ++li) {
            float z = 0.12 + 0.28 * float(li);
            float cs = mix(0.05, 0.17, z);
            col += flowing_fireflyLayer(p + float2(ts * 0.004 * (1.0 + z), 0.0), z, cs, ts, focus, blur,
                                        sizeK, countK * mix(0.30, 0.22, z), glow, pixel, 3.0 + float(li));
        }
        if (meadow > 0.5) {                                      // foreground grass, z ≈ 0.9
            float sp = 0.0095;
            float gb = pixel * 1.2 + blur * abs(0.9 - focus) * 0.006;
            float cov = 0.0;
            float i0 = floor(p.x / sp);
            for (int k = -3; k <= 3; ++k) {
                float i = i0 + float(k);
                float3 h = pcg3(float3(i + 4096.0, 11.0, 3.0));
                float hgt = 0.07 + 0.30 * h.x * h.x;
                float yr = (p.y + 0.5) / hgt;
                if (yr > 1.0) continue;
                float lean = (h.y - 0.5) * 0.045 + 0.006 * sin(ts * 0.5 + i * 0.37 + h.z * 6.0) * yr;
                float cx = (i + 0.5 + (h.z - 0.5) * 0.8) * sp + lean * yr * yr;
                float w = 0.0042 * (1.0 - yr) + 0.0004;
                cov = max(cov, smoothstep(w + gb, w - gb, abs(p.x - cx)));
            }
            float3 grassC = A * 0.02 + horizonC * 0.006;
            col = mix(col, grassC, cov);
        }
        col += flowing_fireflyLayer(p + float2(ts * 0.01, 0.0), 1.0, 0.32, ts, focus, blur,
                                    sizeK, countK * 0.16, glow, pixel, 9.0);
        return flowing_out(col, px);
    }
