//  Nature_cases.h — switch cases for the Nature pack (shader ids 58–61). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L. Scenes ignore src/base.

    case 59: { // OCEAN HORIZON — golden-hour sea and sky; Follow the Sun: the real day and night.
               // See nature_ocean in Nature_funcs.h.
        if (nature_live(u)) return nature_oceanLive(uv, res, px, t, u);
        return nature_ocean(uv, res, px, t, u, false);
    }

    case 60: { // NIGHT SKY — tonight's sky from 40°N: real sidereal orientation from the
               // clock/date (plus a time-lapse turn), Milky Way in galactic coordinates,
               // today's moon phase, meteors. See nature_milkyWay / nature_galStars.
               // p0 = (rotation, milky way, stars, moon)  p1.x = meteors
               // colorA night sky, colorB horizon glow (a distant town).
        float rot = u.p0.x, mwAmt = u.p0.y, starAmt = u.p0.z, moonAmt = u.p0.w, meteorAmt = u.p1.x;
        float aspect = res.x / res.y;
        float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
        const float F = 1.05, pitch = 0.56;
        // Local frame: x east, y up, z north. Facing south, so screen-right is west.
        float3 fwd = float3(0.0, sin(pitch), -cos(pitch));
        float3 up = float3(0.0, cos(pitch), sin(pitch));
        float3 rgt = float3(-1.0, 0.0, 0.0);
        float3 rd = normalize(fwd * F + rgt * sp.x + up * sp.y);
        float pix = 2.0 / (res.y * F);

        // Days since J2000 from the local date/time → local sidereal time (observer on the
        // time zone's meridian), then the time-lapse turn (1× ≈ 1° every 4 s).
        float dJ = 365.25 * (u.date.x - 2000.0) + u.date.w - 1.5 + u.clock.x / 24.0;
        float lst = fmod(100.46 + 0.985647 * dJ + 15.0 * u.clock.x, 360.0) * 0.0174533 + t * rot * 0.0044;
        const float lat = 0.698;                                   // 40°N
        const float3 E = float3(1, 0, 0), N = float3(0, 0, 1), U = float3(0, 1, 0);
        float3 Pp = cos(lat) * N + sin(lat) * U;                   // celestial pole
        float3 Mm = -sin(lat) * N + cos(lat) * U;                  // equator on the meridian
        // Ray → equatorial (RA, Dec) → J2000 unit vector → galactic.
        float dec = asin(clamp(dot(rd, Pp), -1.0, 1.0));
        float ha = atan2(-dot(rd, E), dot(rd, Mm));
        float ra = lst - ha;
        float3 q = float3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec));
        float3 g = NATURE_EQ2GAL * q;

        float e = asin(clamp(rd.y, -1.0, 1.0));
        float az = atan2(rd.x, rd.z);                              // 0 north, ±π south
        float azS = az < 0.0 ? az + 6.2831853 : az;                // continuous around south
        float land = nature_nightLand(azS, e, pix);

        float3 skyC = nature_lin(u.colorA.rgb);
        float3 glowC = srgbToLinear(u.colorB.rgb);
        float he = max(e, 0.0);
        float ext = exp(-0.06 / (max(rd.y, 0.0) + 0.04));        // extinction toward the horizon

        // Moon: art-placed high on the right, lit from the sun's true side for today's phase.
        float age = fmod(dJ - 5.26, 29.530589);
        float elong = 6.2831853 * age / 29.530589;                // 0 new … π full … 2π
        float illum = 0.5 - 0.5 * cos(elong);
        float3 mDir = normalize(fwd * F + rgt * (aspect * 0.55) + up * 0.55);
        float3 tgt = elong < 3.14159 ? normalize(float3(-1.0, -0.35, -0.15))     // waxing: sun set in the west
                                     : normalize(float3(1.0, -0.35, -0.15));     // waning: sun about to rise east
        float3 perp = normalize(tgt - mDir * dot(tgt, mDir));
        float psi = elong < 3.14159 ? elong : 6.2831853 - elong;
        float3 sunD = mDir * cos(psi) + perp * sin(psi);
        float md = acos(clamp(dot(rd, mDir), -1.0, 1.0));
        float moonSky = moonAmt * illum * illum;

        // Sky: base colour, horizon glow (distant town + airglow), moonlit brightening.
        float3 col = skyC * (1.0 + 2.2 * exp(-he * 5.0));
        float dz = (azS - 3.6) / 0.5;
        col += glowC * 0.05 * exp(-he * 10.0) * (0.3 + 0.7 * exp(-dz * dz));
        col += float3(0.10, 0.35, 0.16) * 0.004 * exp(-he * 9.0);           // green airglow
        col += float3(0.30, 0.45, 0.85) * 0.010 * moonSky * (0.6 + 0.4 * exp(-he * 3.0));
        col += float3(0.85, 0.88, 1.0) * moonSky * (0.020 * exp(-md * 9.0) + 0.06 * exp(-md * 40.0));

        if (land < 0.999) {
            float wash = 1.0 / (1.0 + 2.5 * moonSky);                 // moonlight eats contrast
            float4 mw = nature_milkyWay(g);
            col += mw.rgb * 0.055 * mwAmt * ext * wash;
            float band = exp(-(g.z * g.z) / 0.02);
            float twk = smoothstep(0.5, 0.0, rd.y);
            col += nature_galStars(g, pix, band * min(mwAmt, 1.0), mix(1.0, mw.w, 0.85), t, twk)
                   * 0.55 * starAmt * ext * mix(1.0, wash, 0.5);

            // The moon.
            // Drawn in screen space so the lens never stretches it into an oval.
            const float rS = 0.034;
            float2 dp = (sp - float2(aspect * 0.55, 0.55)) / rS;
            float r2 = dot(dp, dp);
            if (r2 < 2.0 && moonAmt > 0.0) {
                float edgeW = 2.0 / (res.y * rS);
                float disc = smoothstep(1.0 + edgeW, 1.0 - edgeW, sqrt(r2));
                if (disc > 0.0) {
                    float zc = sqrt(max(1.0 - r2, 0.0));
                    float3 nrm = normalize(dp.x * rgt + dp.y * up - zc * mDir);
                    // Maria: dark low-frequency patches; fine highland texture.
                    float3 s3 = float3(dp * 2.2, zc * 2.2);
                    float maria = smoothstep(0.45, 0.7, nature_dirNoise(s3 + 5.0, 3));
                    float alb = (0.85 - 0.38 * maria) * (0.92 + 0.16 * noise3(s3 * 9.0));
                    float mu0 = dot(nrm, sunD), mu = max(dot(nrm, -rd), 0.05);
                    float ls = mu0 > 0.0 ? mu0 / (mu0 + mu) : 0.0;     // Lommel–Seeliger
                    float shine = 0.006 * (1.0 - illum);                 // earthshine
                    float3 mc = float3(1.0, 0.97, 0.92) * alb * (ls * 1.8 + shine);
                    col = mix(col, mc * moonAmt + col * 0.2, disc);
                }
            }

            // Meteors: now and then a short streak with a fading tail.
            if (meteorAmt > 0.0) {
                const float per = 7.0;
                float k = floor(t / per);
                float3 hm = pcg3(float3(k, 3.0, 77.0));
                float lt = (t - k * per) / 0.9;                          // life over 0.9 s
                if (hm.z < meteorAmt * 0.8 && lt < 1.0) {
                    float2 s0 = float2((hm.x * 2.0 - 1.0) * aspect * 0.8, 0.15 + hm.y * 0.7);
                    float ang = 0.5 + hm.y * 0.8;
                    float2 dir = normalize(float2(cos(ang) * (hm.x > 0.5 ? 1.0 : -1.0), -sin(ang)));
                    float len = 0.35 + 0.3 * hm.z;
                    float2 rel = sp - (s0 + dir * len * lt);
                    float along = -dot(rel, dir);
                    float across = abs(dir.x * rel.y - dir.y * rel.x);
                    float wpx = 2.4 / res.y;
                    float a = smoothstep(wpx, 0.0, across) * step(0.0, along) * exp(-along / (0.09 * len))
                            * sin(3.14159 * lt);
                    col += float3(0.85, 0.95, 1.0) * a * 1.2;
                }
            }
        }
        // Ground: near-black, catching a little glow and moonlight.
        float3 gcol = skyC * 0.08 + glowC * 0.002 + float3(0.4, 0.5, 0.7) * 0.004 * moonSky;
        col = mix(col, gcol, land);
        return float4(nature_display(col, px), 1.0);
    }

    case 58: { // RAIN ON GLASS — mist, beads and runners on a window over a defocused street.
               // p0 = (speed, rain, condensation, city blur); colorA night, colorB lamp light.
               // See nature_rainGlass in Nature_funcs.h.
        return float4(nature_display(nature_rainGlass(uv, res, t, u), px), 1.0);
    }

    case 61: { // SNOWFALL — flakes on depth layers through lamplight at a forest edge.
               // p0 = (speed, snow, wind, lamp)  p1.x = depth of field
               // colorA dusk (sky + ambient), colorB lamplight.
        float aspect = res.x / res.y;
        float2 sp = float2((uv.x - 0.5) * 2.0 * aspect, (0.5 - uv.y) * 2.0);
        NatureSnowP P;
        P.ts = t * u.p0.x * 0.55;
        P.amount = 0.12 + 0.7 * clamp(u.p0.y, 0.0, 1.0);
        P.wind = u.p0.z;
        P.lampI = u.p1.x * 0.0 + u.p0.w;
        P.aperture = 0.035 * clamp(u.p1.x, 0.0, 1.0);
        P.zf = 3.5;
        P.aspect = aspect;
        P.pix = 2.0 / res.y;
        P.sky = nature_lin(u.colorA.rgb);
        P.lampC = srgbToLinear(u.colorB.rgb);
        P.fogC = P.sky * 2.2 + P.lampC * 0.004 * P.lampI;
        P.h0 = -0.42;
        P.L = float3(aspect * 0.42 * 7.0, 3.2, 7.0);
        float zb;
        float3 col = nature_snowBack(sp, P, zb);
        col += nature_snowFlakes(sp, P, zb);
        return float4(nature_display(col, px), 1.0);
    }
