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

    case 55: { // LAVA LAMP — metaball wax lit by a lamp below. One smooth field holds the blobs,
               // the heaving pool they rise from and a thin layer under the cap; a glue term
               // (blob–pool harmonic mean) fillets every neck so no specks of liquid get trapped. Normals come
               // from the field itself (n ∝ (−K∇F, √(F−T))), so domes, necks and saddles all shade
               // smoothly. Wrap diffuse + thickness-dependent transmission, glossy reflections of a
               // soft studio, a hazy defocused back layer, behind curved glass.
               // p0 = (speed, blobs, size, gloss), p1.x lamp glow, p1.y glass.
        float speed = u.p0.x, size = max(u.p0.z, 0.3), gloss = u.p0.w;
        int nb = clamp(int(u.p0.y + 0.5), 1, 10);
        float heat = u.p1.x, glassOn = u.p1.y;
        float aspect = res.x / res.y;
        float pix = 1.0 / res.y;
        float2 p = float2((uv.x - 0.5) * aspect, 0.5 - uv.y);   // y up
        float xc = p.x / (0.5 * aspect);                          // −1 … 1 across the glass
        float dpx = 1.0;                                          // ∂p.x/∂screen x (for the AA footprint)
        if (glassOn > 0.5) {                                      // cylinder: compress toward the rim
            float sx = clamp(xc * 0.93, -0.999, 0.999);
            p.x = asin(sx) / asin(0.93) * 0.5 * aspect;
            dpx = 0.93 * rsqrt(1.0 - sx * sx) / asin(0.93);
        }
        float ts = t * speed * 0.16;
        float3 wax = srgbToLinear(u.colorB.rgb);
        float3 liq = srgbToLinear(u.colorA.rgb);
        float lamp = heat * (0.17 + 1.5 * exp(-(p.y + 0.5) * 2.6)) * (0.82 + 0.18 * exp(-p.x * p.x * 1.2));
        float3 warm = wax * 0.7 + float3(0.30, 0.18, 0.08);

        // ---- front wax: blobs + pool + cap (+ glue), with the analytic gradient
        float2 mound;
        float3 Fb = flowing_lavaField(p, ts, nb, size, 0.0, aspect * 0.86, mound);
        float H = -0.43 + 0.024 * sin(p.x * 2.3 + ts * 1.1) + 0.011 * sin(p.x * 5.3 - ts * 1.7 + 2.0)
                + 0.004 * sin(p.x * 11.0 + ts * 2.3 + 4.0);
        float dH = 0.0552 * cos(p.x * 2.3 + ts * 1.1) + 0.0583 * cos(p.x * 5.3 - ts * 1.7 + 2.0)
                 + 0.044 * cos(p.x * 11.0 + ts * 2.3 + 4.0);
        H += 0.045 * mound.x; dH += 0.045 * mound.y;              // the pool swells under settling blobs
        // pool profile in depth s below the surface: an exponential tail above it (a metaball
        // falloff, so blobs neck into it the way they neck into each other) and a long, gentle
        // rise below it (C¹ at the surface), so its rim never prints a ledge through a blob
        const float poolLa = 0.035, poolA = 0.8, poolLb = poolA * poolLa / 0.32;   // T / La = A / Lb
        float sP = H - p.y;
        float tailP = 0.32 * exp(min(sP, 0.0) / poolLa);
        float riseP = poolA * (1.0 - exp(-max(sP, 0.0) / poolLb));
        float pool = tailP + riseP;
        float dPool = sP < 0.0 ? tailP / poolLa : (poolA / poolLb) * (1.0 - riseP / poolA);
        float2 gPool = dPool * float2(dH, -1.0);
        float Hc = 0.505 + 0.006 * sin(p.x * 3.0 - ts * 1.5);
        float xq = clamp((p.y - Hc) / 0.12 + 0.47, 0.0, 1.0);
        float cap = 0.7 * xq * xq * (3.0 - 2.0 * xq);
        float2 gCap = (0.7 * 6.0 * xq * (1.0 - xq) / 0.12) * float2(-0.018 * cos(p.x * 3.0 - ts * 1.5), 1.0);
        // glue: a harmonic-mean bridge (≈ the smaller of the two near a junction, 0 away from
        // one), so a blob settling into the pool fills the gap instead of trapping a speck
        const float glueK = 1.6;
        float gS = Fb.x + pool + 0.08;
        float glue = glueK * Fb.x * pool / gS;
        float2 gGlue = glueK * (Fb.yz * pool * (gS - Fb.x) + gPool * Fb.x * (gS - pool)) / (gS * gS);
        float F = Fb.x + pool + cap + glue;
        float2 g = Fb.yz + gPool + gCap + gGlue;
        const float T = 0.32;
        float wF = pix * (length(g * float2(dpx, 1.0)) + 1.2);    // field change across ~a pixel
        float cover = clamp((F - T) / (1.3 * wF) + 0.5, 0.0, 1.0);
        // height h = C·√(e/(1+e/E)), e = F − T: a dome over each blob that saturates where fields
        // pile up (so the pool's rim doesn't print a ridge through the blobs merging into it); the
        // 2-pixel floor keeps the silhouette's last pixel from turning edge-on (no aliased rim).
        float e = max(F - T, 0.0) + 2.0 * wF;
        float sat = 1.0 / (1.0 + e / 0.6);
        float hgt = sqrt(e * sat);
        float K = 0.105 * size;
        float3 n = normalize(float3(-K * g * sat * sat, hgt + 0.01));
        float thick = clamp(hgt * 1.3, 0.0, 1.0);
        float2 dir = n.xy / max(length(n.xy), 1e-4);               // outward, in the image plane

        // ---- back layer, seen through the liquid (and refracted through the front wax)
        float2 pb = p * 1.18 + float2(0.21, 0.04) + n.xy * cover * 0.05;
        float2 moundB;
        float3 Fk = flowing_lavaField(pb, ts * 0.8 + 11.0, max(nb / 2 + 1, 2), size * 1.1, 37.0, aspect * 1.1, moundB);
        float glb = length(Fk.yz) + 1.2;
        float sdb = (T - Fk.x) / glb;
        float coverB = smoothstep(0.020, -0.026, sdb);
        float thickB = clamp(-sdb / (0.2 * size), 0.0, 1.0);
        float lowB = clamp(Fk.z / (length(Fk.yz) + 2.5), 0.0, 1.0);    // lower edges face the bulb

        float3 col = liq * (0.35 + 0.9 * lamp);
        col += wax * lamp * 0.10 * smoothstep(0.0, T, F + Fk.x * 0.5);   // light scattered by wax
        float3 waxBack = pow(wax, float3(1.05 + 0.5 * thickB)) * lamp * (0.40 + 0.45 * lowB * (1.0 - 0.6 * thickB));
        col = mix(col, waxBack + liq * 0.12, coverB * 0.82);

        // ---- shade front wax
        float3 ld = normalize(float3(-p.x * 0.25, -1.0, 0.45));
        float wrap = clamp((dot(n, ld) + 0.8) / 1.8, 0.0, 1.0);          // wax scatters: soft terminator
        float hot = exp(-(p.y + 0.5) * 3.0);                       // wax near the bulb runs hotter
        float3 waxH = flowing_oklabToLinear(oklabHue(srgbToOklab(u.colorB.rgb), 0.42 * hot) + float3(0.08 * hot, 0.0, 0.0));
        float3 trans = pow(waxH, float3(0.8 + 1.8 * thick));      // thick wax deepens & saturates
        float edge = max(1.0 - n.z, 0.0);                          // n.z can round above 1: no NaN
        float rimLit = pow(edge, 1.5) * clamp(-dir.y * 0.8 + 0.3, 0.0, 1.0);
        float thin = (1.0 - thick) * (1.0 - thick);                 // thin wax lets the lamp through
        float3 waxCol = lamp * (waxH * wrap * 0.55 + trans * (0.45 + 0.6 * wrap) + waxH * (rimLit * 0.9 + thin * 0.22))
                      + wax * 0.03;
        float3 r = float3(2.0 * n.z * n.xy, 2.0 * n.z * n.z - 1.0);
        float fres = 0.04 + 0.96 * pow(edge, 5.0);
        float3 spec = flowing_lavaEnv(r, warm) * mix(0.03, 1.0, fres) * gloss * 1.3;
        waxCol += spec;
        col = mix(col, waxCol, cover);

        // ---- curved glass: rim falloff, soft reflections of a window and a strip light, caustic
        if (glassOn > 0.5) {
            float ax = abs(xc);
            col *= 1.0 - 0.55 * pow(ax, 4.0);
            float pxc = pix / (0.5 * aspect);                     // one pixel in xc units
            float edgeY = 0.70 + 0.30 * smoothstep(-0.5, 0.45, p.y);
            float winY = smoothstep(-0.48, 0.05, p.y);
            float cL = (xc + 0.735) / max(0.009, 1.2 * pxc), bL = (xc + 0.70) / 0.075;
            float cR = (xc - 0.862) / max(0.005, 1.2 * pxc), bR = (xc - 0.845) / 0.035;
            float glint = (exp(-cL * cL) * 0.055 + exp(-bL * bL) * 0.030) * winY
                        + exp(-cR * cR) * 0.032 + exp(-bR * bR) * 0.010;
            col += float3(1.0, 0.97, 0.94) * edgeY * glint;
            col += warm * 0.06 * heat * smoothstep(0.8, 1.0, ax) * smoothstep(0.2, -0.5, p.y);
        }
        return flowing_out(col, px);
    }

    case 56: { // INK BLOOM — drops of ink falling through still, backlit water. Each drop sinks as
               // a vortex ring: in this side view a counter-rotating vortex pair rides with it,
               // rolling the edges of the cap up into curls (area-preserving Lamb–Oseen twirls,
               // so ink keeps its mass) and leaving a thin stem back to where it entered. Onion
               // layers in the drop become the fine spiral striations real curls show. A gentle
               // ambient flow bends every plume; drops sit at different depths (size, haze and
               // focus). Light water absorbs per Beer–Lambert; dark water glows like smoke.
               // p0 = (speed, scale, turbulence, ink), p1.x second ink.
        float speed = u.p0.x, sc = max(u.p0.y, 0.2), curl = u.p0.z, dens = u.p0.w, second = u.p1.x;
        float aspect = res.x / res.y;
        float2 P = (uv - 0.5) * float2(aspect, 1.0);            // y down: ink sinks toward +y
        float ts = t * speed;
        // ambient flow: a short back-trace through a slow divergence-free vortex field
        float tau = ts * 0.10;
        float2 x = P;
        x -= flowing_inkVel(x * 1.7 + 3.0, tau) * (0.08 * (0.35 + 0.65 * curl));

        float3 inkA = srgbToLinear(u.colorB.rgb);
        float3 inkB = flowing_oklabToLinear(oklabHue(srgbToOklab(u.colorB.rgb), 1.15));
        float3 sigA = -log(clamp(inkA, 0.004, 0.98));
        float3 sigB = -log(clamp(inkB, 0.004, 0.98));
        float lightness = smoothstep(0.18, 0.55, luma(u.colorA.rgb));
        const int NB = 7;                                       // drops alive at once
        float cyc0 = ts * 0.024;
        float3 tauI = float3(0.0), glowSum = float3(0.0);
        float dsum = 0.0;
        for (int j = 0; j < NB; ++j) {
            float ph = cyc0 + float(j) / float(NB);
            float a = fract(ph);
            float id = floor(ph) * float(NB) + float(j);
            float3 h = pcg3(float3(id + 4096.0, 17.0, 3.0));
            float z = fract(h.x + 0.37 * float(j));             // depth: 0 far … 1 near
            float S = 0.15 * sc * mix(0.58, 1.40, z) * (0.85 + 0.3 * h.y);
            // where each drop ends up: an R2 low-discrepancy walk, so the drops alive together
            // spread over the frame instead of lining up; released near the surface above it
            float2 r2 = fract(0.5 + id * float2(0.7548777, 0.5698403));
            float x0 = (r2.x - 0.5) * (aspect - 0.2);
            float fallT = 0.34 + 0.30 * h.z;
            float yEnd = -0.20 + 0.62 * r2.y;
            float2 c0 = float2(x0, min(yEnd - fallT, -0.36));
            fallT = yEnd - c0.y;
            float fall = fallT * (1.0 - exp(-2.2 * a)) * 1.12;
            float2 pos = c0 + float2((h.y - 0.5) * 0.12 * a, fall);
            float tilt = (h.y - 0.5) * 0.30;                     // plumes don't fall plumb
            float2 d = (x - pos) / S;                           // drop frame: cap at origin
            d = float2(cos(tilt) * d.x - sin(tilt) * d.y, sin(tilt) * d.x + cos(tilt) * d.y);
            float grow = 0.55 + 1.05 * sqrt(a);                 // the ring spreads as it entrains water
            float up = fall / S + 1.0;                          // stem reaches back to the surface
            float3 h2 = pcg3(float3(id + 4096.0, 61.0, 9.0));
            float split = smoothstep(0.30, 1.0, a) * smoothstep(0.35, 0.9, h2.y) * (0.5 + 0.5 * curl);
            bool nearCap = abs(d.x) < 2.3 * grow && d.y > -1.5 * grow && d.y < (1.45 + 1.1 * split) * grow;
            bool nearStem = abs(d.x) < 1.5 && d.y < 0.4 && d.y > -up;
            if (!quad_any(nearCap || nearStem)) continue;       // whole quads skip: fwidth stays valid
            float blur0 = 0.08 + 0.50 * abs(z - 0.55) + 0.45 * a * a;   // depth of field + diffusion
            float body = 0.0, layers = 1.0;
            if (quad_any(nearCap)) {
                // the vortex pair (ring cross-section), slightly behind the front, unequal strengths
                float G = (0.45 + 0.75 * curl) * (3.5 + 4.5 * h2.x) * (1.0 - exp(-4.0 * a));
                float rc2 = 0.30 * grow * grow;
                float sv = (0.82 + 0.22 * h2.x) * grow;
                float2 cL = float2(-sv, -0.32 * sv), cR = float2(sv, -0.32 * sv);
                float2 dc = d;
                if (split > 1e-3) {
                    // later the ring breaks up: each rolled rim sinks on as a lobe of its own,
                    // drawing a filament behind it (a localized drift of the core, undone first)
                    float2 DL = float2(-0.25, 1.0) * grow * split, DR = float2(0.25, 1.0 + 0.6 * (h2.z - 0.5)) * grow * split;
                    float2 vL = dc - (cL + DL), vR = dc - (cR + DR);
                    dc -= DL * exp(-dot(vL, vL) / rc2) + DR * exp(-dot(vR, vR) / rc2);
                }
                float2 e = flowing_untwirl(dc, cL, G * (0.9 + 0.2 * h.y), rc2);
                e = flowing_untwirl(e, cR, -G * (1.1 - 0.2 * h.y), rc2);
                // the ring grows unstable as it ages: turbulence frays the cap into wisps
                float2 wq = e * 1.6 + id * 5.31;
                float2 wn = float2(vnoise(wq), vnoise(wq + 17.7)) - 0.5;
                e += (0.10 + 0.30 * a) * grow * wn;
                // the cap: a dome-shaped shell, seen side on — denser where the sheet turns
                // edge-on (its rolled rim and its leading face), translucent across the middle
                float2 m = e / (float2(1.22 + 0.30 * (h2.y - 0.5), 0.74 + 0.24 * (h.z - 0.5)) * grow);
                float nz = vnoise(e * 2.3 + id * 7.13) + 0.5 * vnoise(e * 5.1 - id * 3.7) - 0.75;
                float r = length(m) + nz * 0.20;
                float blur = blur0 + 0.44 * (wn.x + 0.5) * (wn.y + 0.5);   // patchy: sharp sheets, soft billows
                float shell = min(0.34 * rsqrt(max(1.0 - r * r, 0.07)), 1.15);
                float front = 0.55 + 0.45 * smoothstep(-0.4, 0.7, m.y);
                body = smoothstep(1.0 + blur * 0.5, 1.0 - blur, r) * shell * front;
                // onion layers in the rim → spiral striations; faded where finer than a pixel
                float lr = r * 7.0 + id;
                float lf = fwidth(lr);
                layers = 1.0 + 0.24 * cos(lr * 6.2831853) * smoothstep(0.45, 0.12, lf) * (1.0 - 0.7 * blur)
                             * smoothstep(0.45, 0.85, r);
            }
            // stem: a thread of ink shed behind the ring, thinning toward the surface
            float sy = clamp(-d.y / up, 0.0, 1.0);
            float sw = (0.10 + 0.16 * grow) * (1.0 - 0.6 * sy) + 0.03 + 0.1 * blur0;
            float stem = exp(-d.x * d.x / (sw * sw)) * smoothstep(0.3, -0.5, d.y) * (1.0 - sy * sy)
                       * (0.22 + 0.22 * vnoise(float2(d.x * 3.0, d.y * 1.3 + id)));
            // mass conservation: the same ink over a growing area; haze far drops
            float amount = smoothstep(0.0, 0.025, a) * (1.0 - a) * sqrt(1.0 - a) / (grow * grow) * mix(0.55, 1.0, z);
            float dj = (body * layers * 1.5 + stem) * amount;
            bool alt = h2.z < second;
            tauI += (alt ? sigB : sigA) * dj;
            glowSum += (alt ? inkB : inkA) * dj;
            dsum += dj;
        }
        tauI *= dens * 1.35;
        dsum *= dens;
        float3 water = srgbToLinear(u.colorA.rgb);
        float2 pc = uv - 0.5;
        float3 bgw = water * (1.05 - 0.10 * uv.y - 0.22 * dot(pc, pc));
        float3 absorbed = bgw * exp(-tauI);
        // dark water: ink scatters light like smoke — thin wisps faint, dense cores bloom
        float em = 1.0 - exp(-dsum * 1.1);
        float3 hue = glowSum / max(dsum / max(dens, 1e-3), 1e-4);
        float3 smoky = bgw + hue * (em * 0.55 + em * em * 0.9) + (hue * 0.4 + 0.3) * em * em * em * 0.5;
        float3 col = mix(smoky, absorbed, lightness);
        return flowing_out(col, px);
    }

    case 57: { // FIREFLIES — a dusk meadow photographed wide open: twilight sky with the first
               // stars and a few afterglow-lit wisps of cloud, a hazy far ridge and a nearer
               // treeline of mixed conifers and broadleaf crowns with a porous, leafy edge, four
               // depth layers of slowly flashing flies (bokeh discs away from the focal plane; a
               // few drift up into the trees), low mist and swaying foreground grass.
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
        if (sy > 0.02) {
            // the first stars: brightest few only, fading into the afterglow; slow scintillation
            float2 sg = p * 42.0;
            float2 sc0 = floor(sg);
            float3 sh = pcg3(float3(sc0 + 300.0, 41.0));
            float2 spos = (sc0 + 0.15 + 0.7 * sh.xy) / 42.0;
            float sb = smoothstep(0.93, 1.0, sh.z);
            float sig = max(0.75 * pixel, 0.0005);
            float sd2 = dot(p - spos, p - spos);
            float tw = 0.75 + 0.25 * sin(t * (0.7 + 1.3 * sh.x) + sh.y * 40.0);
            float starV = (0.25 + sb * sb * 1.5) * step(0.93, sh.z) * exp(-sd2 / (2.0 * sig * sig)) * tw
                        * smoothstep(0.10, 0.45, sy) * (0.0006 / sig);
            col += float3(0.85, 0.90, 1.0) * starV * 3.0;
            // thin altostratus wisps, lit warm from below by the sun that has just set
            float band = smoothstep(0.04, 0.16, sy) * smoothstep(0.62, 0.30, sy);
            if (band > 0.0) {
                float2 cq = float2(p.x * 1.4 + ts * 0.004, sy * 7.5);
                float cn = vnoise(cq) * 0.55 + vnoise(cq * float2(2.3, 2.1) + 7.1) * 0.28 + vnoise(cq * float2(5.1, 4.3) - 3.3) * 0.17;
                float cd = smoothstep(0.48, 0.80, cn) * band;
                float lit = smoothstep(0.42, 0.06, sy);
                float3 cc = mix(midC * 0.85, horizonC * 1.25, lit) + A * 0.2;
                col = mix(col, cc, cd * 0.55);
            }
        }
        if (meadow > 0.5) {
            float x = p.x;
            float treeDof = blur * abs(0.08 - focus) * 0.012;
            float3 treeC = mix(A * 0.20, horizonC * 0.09, 0.5);
            // the ridge and the trees only live in a band above the horizon (tallest crown
            // ≈ 0.18): everything outside it skips their noise and the five-tree loop
            if (p.y > horizonY - 0.004 && p.y < horizonY + 0.19) {
                // a far ridge under the treeline, hazed toward the sky (aerial perspective)
                float ridge = horizonY + 0.028 + 0.030 * vnoise(float2(x * 2.2 + 11.0, 0.5))
                            + 0.006 * (vnoise(float2(x * 31.0, 2.5)) - 0.5);
                float rb = pixel * 1.2 + treeDof * 0.6;
                float ridgeCov = smoothstep(ridge + rb, ridge - rb, p.y);
                col = mix(col, mix(horizonC * 0.55, A * 0.35, 0.4), ridgeCov * 0.85);
                // the treeline: conifer spires and broadleaf crowns over a slow height envelope
                const float tw = 0.040;
                float ix = floor(x / tw);
                float tree = horizonY + 0.006;
                for (int k = -2; k <= 2; ++k) {
                    float i = ix + float(k);
                    float3 h = pcg3(float3(i + 2048.0, 21.0, 5.0));
                    float env = 0.040 + 0.060 * vnoise(float2(i * 0.16, 2.0));
                    float cx = (i + 0.5 + (h.x - 0.5) * 0.7) * tw;
                    float dx = x - cx;
                    if (h.z < 0.22) {                                    // conifer: a ragged spire
                        float ht = env * (0.95 + 0.55 * h.y) + 0.018;
                        float wb = tw * (0.60 + 0.40 * h.y);
                        float sp = horizonY + ht * (1.0 - pow(abs(dx) / wb, 0.85));
                        sp += 0.0035 * sin(dx * 900.0 + h.x * 30.0) * smoothstep(0.0, wb, abs(dx));   // branch tiers
                        tree = max(tree, sp);
                    } else {                                             // broadleaf: two lobed domes
                        float rr = tw * (0.70 + 0.85 * h.y);
                        float Hc = env + 0.012 * h.z + rr * 0.55;
                        float q1 = 1.0 - dx * dx / (rr * rr);
                        if (q1 > 0.0) tree = max(tree, horizonY + Hc * pow(q1, 0.38));
                        float dx2 = dx - rr * 0.55 * (h.x - 0.5) * 2.0;
                        float r2 = rr * 0.66;
                        float q2 = 1.0 - dx2 * dx2 / (r2 * r2);
                        if (q2 > 0.0) tree = max(tree, horizonY + (Hc * 0.82 + r2 * 0.45) * pow(q2, 0.38));
                    }
                }
                // a porous, leafy edge: 2D noise near the silhouette lets sky through the foliage
                // (the fine octave fades out before it gets smaller than a pixel)
                float near = tree - p.y;
                float tb = pixel * 1.3 + treeDof;
                if (abs(near) < 0.03) {
                    float2 lq = p * 150.0;
                    float fine = smoothstep(0.30, 0.10, pixel * 330.0);
                    float leaf = (vnoise(lq) - 0.5) + (vnoise(lq * 2.2 + 3.7) - 0.5) * 0.6 * fine;
                    near += leaf * 0.009 * smoothstep(horizonY + 0.004, horizonY + 0.022, p.y);
                }
                col = mix(col, treeC, smoothstep(-tb, tb, near));
            }
            // the meadow: darkening toward the camera, with rows of low tufts fading into mist
            if (p.y < horizonY + 0.003) {
                float fieldT = smoothstep(horizonY, -0.5, p.y);
                float3 field = mix(treeC * 1.6 + horizonC * 0.09, A * 0.10 + horizonC * 0.01, sqrt(fieldT));
                float rows = vnoise(float2(x * 9.0 / (0.15 + fieldT), p.y * 70.0 / (0.2 + fieldT)));
                field *= 0.88 + 0.24 * rows * smoothstep(0.0, 0.35, fieldT) * smoothstep(0.003, 0.0012, pixel / (0.2 + fieldT));
                col = mix(col, field, smoothstep(horizonY + 0.003, horizonY - 0.003, p.y));
            }
            if (abs(p.y - horizonY) < 0.36) {
                float mist = exp(-abs(p.y - horizonY + 0.02) * 18.0) * (0.75 + 0.25 * vnoise(float2(x * 3.0 + ts * 0.02, 0.5)));
                mist += 0.45 * exp(-abs(p.y - horizonY + 0.09) * 22.0) * vnoise(float2(x * 1.7 - ts * 0.015, 3.5));
                col += horizonC * 0.10 * mist;
            }
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

