//  Retro_cases.h — switch cases for the Retro pack (shader ids 62–65). Included
//  INSIDE fx_fragment's switch(u.effect): write `case NN: { …; return float4(col, 1.0); }`.
//  In scope: uv, res, px, t (seconds), u (FXUniforms incl. u.clock / u.date), src, glyphs,
//  samp, base, L. Scenes ignore src/base.

    case 62: { // NEON HORIZON — a glossy black floor ruled by a neon grid, racing toward a
               // striped sun over two ranges of backlit mountains. The floor mirrors the sky
               // (Fresnel-weighted, glossy-blurred, sun stretched into a wet streak).
               // p0 = (speed, grid, mountains, sun), p1 = (haze, stars); A neon, B sun.
        float speed = u.p0.x, dens = max(u.p0.y, 0.2), sunK = max(u.p0.w, 0.2);
        float hazeK = u.p1.x;
        RetroSynth s;
        s.neon = srgbToLinear(u.colorA.rgb);
        float3 sunC = srgbToLinear(u.colorB.rgb);
        s.sunTop = mix(sunC, float3(1.0, 0.95, 0.7), 0.15) * 1.05;
        s.sunMid = sunC * 0.9;
        s.sunBot = mix(retro_hue(sunC, -1.0) * 0.55, s.neon * 0.8, 0.5);
        s.top = float3(0.0018, 0.002, 0.016) + s.neon * 0.002;
        s.haze = mix(s.sunBot, s.neon, 0.6) * (0.03 + 0.055 * hazeK);
        s.mtnDark = s.top * 0.5 + s.neon * 0.002;
        s.sunR = 0.25 * sunK; s.sunY = 0.13 * sunK + 0.02;
        s.mtn = u.p0.z; s.stripes = 1.0; s.stars = u.p1.y; s.clouds = 1.0; s.t = t;

        const float hy = -0.06;                                  // horizon, in screen units
        float pix = 1.0 / res.y;
        float2 p = float2(px.x - 0.5 * res.x, 0.5 * res.y - px.y) * pix;
        float2 q = p - float2(0.0, hy);

        // floor hit (computed unconditionally so derivatives stay valid at the horizon)
        const float camH = 0.55;
        float qy = min(q.y, -1e-4);
        float tf = camH / -qy;                                   // depth along z
        float travel = t * speed * 1.6;
        float sway = sin(t * 0.045) * 1.8;
        float2 g = float2((q.x * tf + sway) * dens, (tf + travel) * dens);
        float2 fw = fwidth(g);
        float2 dg = abs(fract(g + 0.5) - 0.5);
        const float lw = 0.018, hw = 0.06;
        float2 core = float2(retro_lineCov(dg.x, lw, fw.x), retro_lineCov(dg.y, lw, fw.y));
        core = mix(core, float2(2.0 * lw), smoothstep(0.35, 1.0, fw));
        float2 halo = exp(-dg / hw);
        halo = mix(halo, float2(2.0 * hw), smoothstep(0.15, 0.8, fw));
        // a soft pulse rolls down the grid toward the viewer
        float pulse = exp(-pow(fract(g.y * 0.08 - t * 0.12 * (0.5 + speed)) * 2.0 - 1.0, 2.0) * 18.0);
        float gridE = (core.x + core.y) * 6.0 + (halo.x + halo.y) * 0.5;
        gridE *= 1.0 + 0.8 * pulse;

        // floor material: dark wet gloss mirroring the sky
        float3 rd = normalize(float3(q.x, qy, 1.0));
        float cosT = -rd.y;
        float F = 0.04 + 0.96 * pow(1.0 - cosT, 5.0);
        // wet ripples break the mirror image into shimmering horizontal slivers
        float2 wp = float2(q.x * tf, tf + travel);
        float rip = gnoise(wp * float2(0.9, 3.2)) + 0.5 * gnoise(wp * float2(2.1, 7.5) + 3.1);
        float2 qr = float2(q.x + rip * 0.02 * -qy, -qy * (1.0 + 0.6 * rip));
        // one sky lookup per pixel: the sky itself above the horizon, its mirror image below
        bool up = q.y > 0.0;
        float3 sky = retro_synthSky(up ? q : qr, up ? pix : pix + 0.05 * -qy,
                                    up ? 1.0 : 1.0 + 1.2 * smoothstep(0.0, 0.25, -qy), up ? 1.0 : 0.0, s);
        float sliver = smoothstep(-0.25, 0.35, gnoise(wp * float2(0.35, 6.0) + float2(0.0, t * 0.3)));
        float3 floorC = s.top * 0.3 + sky * F * 0.5 * (0.35 + 0.9 * sliver);
        floorC += s.neon * gridE;
        float fog = 1.0 - exp(-tf * 0.035 * (0.4 + hazeK));
        floorC = mix(floorC, s.haze * 1.3, fog);

        float3 col = up ? sky : floorC;
        col += s.neon * exp(-abs(q.y) / 0.0035) * 0.45;            // horizon line
        col *= 1.0 - 0.28 * dot(p, p);
        return float4(retro_out(col, px), 1.0);
    }

    case 65: { // LIGHT TUNNEL — the demoscene tunnel as a ray-traced corridor: bevelled
               // brushed-metal panels, chasing neon rings and rails, and one analytic
               // reflection bounce (the reflected ray hits the tunnel again, lit the same way).
               // p0 = (speed, shape, twist, panels), p1 = (lights, gloss); A metal, B neon.
        RetroTun s;
        s.speed = u.p0.x; s.shape = int(u.p0.y + 0.5); s.twist = u.p0.z;
        float panelK = max(u.p0.w, 0.3);
        s.lights = u.p1.x; float gloss = clamp(u.p1.y, 0.0, 1.0);
        s.metal = srgbToLinear(u.colorA.rgb); s.neon = srgbToLinear(u.colorB.rgb);
        s.neon2 = retro_hue(s.neon, 0.5);
        s.nA = s.shape == 0 ? max(round(14.0 / panelK), 4.0) : (s.shape == 1 ? 4.0 : 6.0) * max(round(2.0 / panelK), 1.0);
        s.plen = 0.9 * panelK; s.ringEvery = 4.0; s.t = t;

        float pix = 1.0 / res.y;
        float2 p = float2(px.x - 0.5 * res.x, 0.5 * res.y - px.y) * pix;
        float zc = t * s.speed * 2.5;
        float3 ro = float3(0.28 * sin(t * 0.21), 0.22 * sin(t * 0.27 + 2.0), zc);
        float yaw = 0.16 * sin(t * 0.13) + 0.06 * sin(t * 0.31);
        float pit = 0.11 * sin(t * 0.17 + 1.0);
        float rol = t * 0.04 * s.twist + 0.35 * sin(t * 0.09);
        float3 rd = normalize(float3(p, 0.95));
        rd.xy = float2(rd.x * cos(rol) - rd.y * sin(rol), rd.x * sin(rol) + rd.y * cos(rol));
        rd.yz = float2(rd.y * cos(pit) - rd.z * sin(pit), rd.y * sin(pit) + rd.z * cos(pit));
        rd.xz = float2(rd.x * cos(yaw) + rd.z * sin(yaw), -rd.x * sin(yaw) + rd.z * cos(yaw));

        float3 n; float uu;
        float th = retro_tunHit(ro, rd, s.shape, n, uu);
        float3 P = ro + rd * th;
        float spiral = s.shape == 0 ? P.z * s.twist * 0.05 : 0.0;
        float U = uu * s.nA + spiral * s.nA;
        float V = P.z / s.plen;
        // seam-safe derivatives (U wraps at the atan seam)
        float fU = min(fwidth(U), fwidth(fract(U / s.nA + 0.5) * s.nA));
        float fV = fwidth(V);
        float fz = fV * s.plen;

        float2 id = floor(float2(U, V));
        float2 cu = float2(U, V) - id;
        id.x = fmod(id.x + 1000.0 * s.nA, s.nA);
        float3 h = pcg3(float3(id, 17.0));
        float cellW = 6.2831853 / s.nA * (s.shape == 0 ? 1.0 : (s.shape == 1 ? 1.2732 : 1.1027));
        float ex = min(cu.x, 1.0 - cu.x) * cellW, ev = min(cu.y, 1.0 - cu.y) * s.plen;
        float e = min(ex, ev);
        float fe = max(fU * cellW, fz) + 1e-5;
        float detail = smoothstep(0.25, 0.04, max(fU, fV));          // fade fine detail with distance

        // bevelled panel normal
        float3 T = normalize(cross(float3(0.0, 0.0, 1.0), n));
        float bw = 0.06;
        float tilt = (1.0 - smoothstep(0.0, bw, e)) * 0.7 * detail;
        float2 dir = ex < ev ? float2(sign(cu.x - 0.5), 0.0) : float2(0.0, sign(cu.y - 0.5));
        float3 nb = normalize(n + tilt * (T * dir.x + float3(0.0, 0.0, 1.0) * dir.y));

        // panel material: brushed metal, a few darker vented panels, a few light tiles
        float kind = h.x;
        float rough = mix(0.55, 0.12, gloss) * (0.7 + 0.6 * h.y);
        float3 alb = s.metal * (0.75 + 0.35 * h.z);
        float brush = vnoise(float2(cu.x * 90.0, P.z * 3.0 + h.y * 50.0));
        alb *= 1.0 + (brush - 0.5) * 0.25 * detail;
        float3 emit = float3(0.0);
        if (kind < 0.16) {                                            // vented panel
            alb *= 0.35;
            float sl = abs(fract(cu.y * 7.0) - 0.5);
            float inset = step(0.18, cu.x) * step(cu.x, 0.82) * step(0.15, cu.y) * step(cu.y, 0.85);
            alb *= 1.0 - inset * retro_lineCov(sl, 0.2, fwidth(cu.y * 7.0) + 1e-4) * 0.8 * detail;
            rough = 0.6;
        } else if (kind > 0.95) {                                     // light tile
            float2 c2 = abs(cu - 0.5);
            float2 bx = c2 * float2(cellW, s.plen) - float2(min(0.3, 0.36 * cellW), 0.045);
            float tile = clamp(-max(bx.x, bx.y) / fe + 0.5, 0.0, 1.0);
            float blink = 0.5 + 0.5 * sin(t * (1.5 + 2.0 * h.y) + h.z * 30.0);
            emit += mix(s.neon, s.neon2, h.y) * tile * (0.6 + 1.6 * blink) * s.lights * 1.4;
        }
        float seam = clamp((0.012 - e) / fe + 0.5, 0.0, 1.0) * detail;

        // direct light + one reflection bounce
        float3 lit = retro_tunLight(P, nb, ro, s);
        float3 col = alb * lit * 0.16 * (1.0 - seam * 0.85);
        col += emit + retro_tunEmit(uu, P.z, fz, 0.0, s);

        float3 rr = reflect(rd, nb);
        float3 n2; float u2;
        float3 P1 = P + nb * 1e-3;
        float t2 = retro_tunHit(P1, rr, s.shape, n2, u2);
        float3 Q = P1 + rr * t2;
        float widen = rough * t2 * 0.12;
        float3 rc = retro_tunEmit(u2, Q.z, fz * (1.0 + t2), widen, s);
        rc += s.metal * 0.75 * retro_tunLight(Q, n2, ro, s) * 0.12;
        rc *= exp(-t2 * 0.05);
        float cosv = clamp(dot(-rd, nb), 0.0, 1.0);
        float3 F = s.metal * 0.75 + (1.0 - s.metal * 0.75) * pow(1.0 - cosv, 5.0);
        col += rc * F * mix(0.35, 1.0, gloss) * (1.0 - seam * 0.7);

        // distance haze toward a glowing vanishing point
        float fog = 1.0 - exp(-th * 0.045);
        col = mix(col, s.neon * 0.06 * s.lights + s.metal * 0.01, fog);
        col *= 1.0 - 0.3 * dot(p, p);
        return float4(retro_out(col, px), 1.0);
    }

    case 63: { // PIPEWORKS — lacquered pipes grow along a lattice through a dark studio. Each
               // pipe is a deterministic random walk seeded by the cycle (stateless), on its own
               // sub-lattice offset so pipes never collide. Ray-traced capsules: two-layer
               // analytic edge AA, one reflection bounce, cone-traced soft shadows, capsule AO,
               // and a glossy floor. p0 = (speed, count, thick, joints), p1 = (gloss, orbit,
               // finish); A first pipe, B last pipe.
        RetroPipes s;
        float speed = max(u.p0.x, 0.05);
        s.count = clamp(int(u.p0.y + 0.5), 1, 6);
        s.r = min(clamp(u.p0.z, 0.2, 1.0) * 0.49 / float(s.count), 0.2);
        s.rb = u.p0.w > 0.5 ? min(s.r * 1.55, 0.5 / float(s.count) - 0.004) : 0.0;
        float gloss = clamp(u.p1.x, 0.0, 1.0), orbitK = u.p1.y;
        bool metal = u.p1.z > 0.5;
        s.G = float3(7.0, 4.0, 7.0);
        s.org = -(s.G - 1.0) * 0.5 - 0.5;
        s.rate = 2.2 * speed;
        float cycLen = 27.0 / s.rate + float(s.count) * 0.9 + 6.0;
        float cyc = floor(t / cycLen);
        s.lt = t - cyc * cycLen; s.cyc = cyc + 1.0;
        float fadeK = smoothstep(cycLen, cycLen - 1.6, s.lt) * smoothstep(0.0, 0.4, s.lt);

        float3 cA = u.colorA.rgb, cB = u.colorB.rgb;
        float kDen = s.count > 1 ? 1.0 / float(s.count - 1) : 0.0;

        // camera: a slow drift around the room
        float pix = 1.0 / res.y;
        float2 p = float2(px.x - 0.5 * res.x, 0.5 * res.y - px.y) * pix;
        const float foc = 1.75;
        float az = 0.75 + orbitK * (0.45 * sin(t * 0.031) + 0.25 * sin(t * 0.017 + 1.0));
        float el = 0.36 + 0.07 * orbitK * sin(t * 0.043 + 2.0);
        float3 tgt = float3(0.0, -0.45, 0.0);
        float3 ro = tgt + 9.2 * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
        float3 fwd = normalize(tgt - ro), rt = normalize(cross(float3(0.0, 1.0, 0.0), fwd)), upv = cross(fwd, rt);
        float3 rd = normalize(rt * p.x + upv * p.y + fwd * foc);
        float pixA = pix / foc;
        const float3 Lk = normalize(float3(-0.25, 1.0, 0.1));
        float3 Lf = normalize(-fwd + rt * 0.6 + float3(0.0, 0.2, 0.0));      // soft frontal fill

        // ---- the walk + culling. Every pixel needs the same pipes, so a full SIMD group
        // shares the work (see retro_pipeGather); any other group walks every pipe itself.
        ulong act = ulong(simd_vote::vote_t(simd_active_threads_mask()));
        bool shared = act == 0xffffffffull;
        uint lane = simd_prefix_exclusive_sum(1u);
        RetroSegs G; G.s0 = 0u; G.s1 = 0u; G.k0 = 0; G.k1 = 0;
        if (shared) G = retro_pipeGather(s, lane);
        bool two = s.count * RETRO_PIPE_RUNS > 32;
        float rMax = max(s.r, s.rb);
        // this lane's runs, decoded once for all the culling tests
        float3 sa0, sb0, sa1, sb1; int sx;
        retro_pipeDecode(G.s0, G.k0, s, sa0, sb0, sx);
        retro_pipeDecode(G.s1, G.k1, s, sa1, sb1, sx);
        bool sv0 = G.s0 != 0u, sv1 = G.s1 != 0u;
        // the palette: lane k holds pipe k's colour; pixels fetch theirs by shuffle
        float3 myCol = retro_palMix(cA, cB, float(min(int(lane), s.count - 1)) * kDen);

        // ---- primary: keep the two nearest surfaces with their edge coverage
        float3 ipr = retro_invPerp(rd);
        float aaM = pixA * 30.0;
        RetroPipeHit H;
        H.t1 = 1e9; H.a1 = 0.0; H.t2 = 1e9; H.a2 = 0.0; H.k1 = -1; H.k2 = -1;
        H.u1 = 0u; H.u2 = 0u;
        if (shared) {
            float3 rc = simd_broadcast_first(rd);
            float cA0 = simd_min(dot(rd, rc));
            float tanA = sqrt(max(1.0 - cA0 * cA0, 0.0)) / max(cA0, 0.05) + pixA;
            uint m0 = retro_ballot(retro_coneCull(sv0, sa0, sb0, ro, rc, tanA, rMax, 1e9));
            uint m1 = two ? retro_ballot(retro_coneCull(sv1, sa1, sb1, ro, rc, tanA, rMax, 1e9)) : 0u;
            for (int sl = 0; sl < 2; ++sl) {
                uint m = sl == 0 ? m0 : m1;
                uint v = sl == 0 ? G.s0 : G.s1;
                while (m != 0u) {
                    uint L = ctz(m); m &= m - 1u;
                    uint rk = simd_shuffle(v, ushort(L));
                    uint gi = L + 32u * uint(sl);
                    int k = int(gi / uint(RETRO_PIPE_RUNS));
                    uint jr = gi - uint(k) * uint(RETRO_PIPE_RUNS);
                    float3 a, b; int ax;
                    retro_pipeDecode(rk, k, s, a, b, ax);
                    retro_pipeP1(H, ro, rd, ipr, aaM, pixA, rk, a, b, ax, k, s.rb > 0.0 && jr > 0u, s);
                }
            }
        } else {
            for (int k = 0; k < s.count; ++k) {
                RetroWalk w = retro_walkInit(s, k);
                for (int j = 0; j < RETRO_PIPE_RUNS; ++j) {
                    uint rk = retro_walkStep(w, j, s.G);
                    if (rk == 0u) break;
                    float3 a, b; int ax;
                    retro_pipeDecode(rk, k, s, a, b, ax);
                    retro_pipeP1(H, ro, rd, ipr, aaM, pixA, rk, a, b, ax, k, s.rb > 0.0 && j > 0, s);
                }
            }
        }
        float t1 = H.t1, a1 = H.a1, t2 = H.t2, a2 = H.a2;
        int k1 = H.k1, k2 = H.k2;
        float3 col1, col2;
        if (shared) {
            col1 = simd_shuffle(myCol, ushort(max(k1, 0)));
            col2 = simd_shuffle(myCol, ushort(max(k2, 0)));
        } else {
            col1 = retro_palMix(cA, cB, float(max(k1, 0)) * kDen);
            col2 = retro_palMix(cA, cB, float(max(k2, 0)) * kDen);
        }

        // ---- the main surface (front pipe, or floor / backdrop) gets the full treatment
        float floorY = s.org.y + 0.05;
        bool pipeMain = k1 >= 0 && a1 >= 0.5;
        float tf = rd.y < 0.0 ? (floorY - ro.y) / rd.y : 1e9;
        float3 P, N, base = 0.0;
        if (pipeMain) {
            P = ro + rd * t1;
            N = retro_pipeNormal(P, H.u1, k1, s);
            base = col1;
        } else {
            P = ro + rd * min(tf, 60.0);
            N = float3(0.0, 1.0, 0.0);
        }
        float3 R = reflect(rd, N);
        float3 Po = P + N * 2e-3;

        // ---- secondary: reflection hit, soft shadow toward the key light, ambient occlusion
        float3 ipR = retro_invPerp(R), ipL = retro_invPerp(Lk);
        RetroPipeSec S;
        S.tr = 1e9; S.kr = -1; S.ur = 0u; S.sh = 1.0; S.occ = 0.0;
        if (shared) {
            // bound the group's shaded points, reflection directions and shadow rays
            float3 Pc = simd_broadcast_first(P);
            float spread = sqrt(simd_max(dot(P - Pc, P - Pc)));
            float3 Rc = simd_broadcast_first(R);
            float cR = simd_min(dot(R, Rc));
            float tanR = cR > 0.2 ? sqrt(max(1.0 - cR * cR, 0.0)) / cR : 1e4;
            float eR = s.r + spread + 0.01, eL = max(s.r + 0.04, 4.0 * s.r) + spread;   // the shadow cone also covers the AO ball
            uint ms0 = retro_ballot(retro_coneCull(sv0, sa0, sb0, Pc, Rc, tanR, eR, RETRO_REFL_MAX)
                                  || retro_coneCull(sv0, sa0, sb0, Pc, Lk, 0.07, eL, 1e9));
            uint ms1 = two ? retro_ballot(retro_coneCull(sv1, sa1, sb1, Pc, Rc, tanR, eR, RETRO_REFL_MAX)
                                  || retro_coneCull(sv1, sa1, sb1, Pc, Lk, 0.07, eL, 1e9)) : 0u;
            for (int sl = 0; sl < 2; ++sl) {
                uint m = sl == 0 ? ms0 : ms1;
                uint v = sl == 0 ? G.s0 : G.s1;
                while (m != 0u) {
                    uint L = ctz(m); m &= m - 1u;
                    uint rk = simd_shuffle(v, ushort(L));
                    int k = int((L + 32u * uint(sl)) / uint(RETRO_PIPE_RUNS));
                    float3 a, b; int ax;
                    retro_pipeDecode(rk, k, s, a, b, ax);
                    retro_pipeP2(S, P, N, Po, R, ipR, Lk, ipL, rk, a, b, ax, k, s);
                }
            }
        } else {
            for (int k = 0; k < s.count; ++k) {
                RetroWalk w = retro_walkInit(s, k);
                for (int j = 0; j < RETRO_PIPE_RUNS; ++j) {
                    uint rk = retro_walkStep(w, j, s.G);
                    if (rk == 0u) break;
                    float3 a, b; int ax;
                    retro_pipeDecode(rk, k, s, a, b, ax);
                    retro_pipeP2(S, P, N, Po, R, ipR, Lk, ipL, rk, a, b, ax, k, s);
                }
            }
        }
        float tr = S.tr; int kr = S.kr;
        float sh = S.sh, occ = S.occ;
        float3 colR = shared ? simd_shuffle(myCol, ushort(max(kr, 0))) : retro_palMix(cA, cB, float(max(kr, 0)) * kDen);
        sh = sh * sh * (3.0 - 2.0 * sh);
        float ao = clamp(1.0 - occ * (pipeMain ? 0.9 : 1.3), 0.0, 1.0);

        // reflected radiance
        float3 refl = retro_studio(R);
        if (kr >= 0) {
            float3 Q = Po + R * tr;
            float3 Nq = retro_pipeNormal(Q, S.ur, kr, s);
            float3 bq = colR;
            float3 rp = bq * (metal ? 0.15 : 1.0) * (max(dot(Nq, Lk), 0.0) * 1.1 + 0.05)
                      + retro_studio(reflect(R, Nq)) * (metal ? bq : float3(0.05));
            refl = mix(refl, rp, fadeK);
        }

        float3 col;
        if (pipeMain) {
            float cosv = clamp(dot(N, -rd), 0.0, 1.0);
            float3 F0 = metal ? base : float3(0.04);
            float3 F = F0 + (1.0 - F0) * pow(1.0 - cosv, 5.0);
            float ndl = max(dot(N, Lk), 0.0);
            float fill = max(dot(N, Lf), 0.0);
            float3 diff = base * (metal ? 0.12 : 1.0) * (ndl * sh * 1.2 + fill * 0.32 * mix(0.4, 1.0, ao) + (0.04 + 0.04 * N.y) * ao);
            float3 spec = refl * F * mix(0.25, 1.0, gloss) * mix(0.5, 1.0, ao);
            col = (diff + spec) * fadeK;
        } else if (tf < 1e8) {
            // glossy black floor: dim diffuse, contact shadows, reflections fading with distance
            float cosv = clamp(-rd.y, 0.0, 1.0);
            float F = 0.03 + 0.97 * pow(1.0 - cosv, 5.0);
            float3 fr = kr >= 0 ? refl * exp(-tr * 0.35) : retro_studio(R) * 0.12;
            col = float3(0.018, 0.018, 0.02) * (sh * 0.9 + 0.12) * ao + fr * (0.08 + F * 0.6) * mix(0.5, 1.0, gloss);
            col *= exp(-max(length(P.xz) - 6.0, 0.0) * 0.18);
        } else {
            col = float3(0.004, 0.0045, 0.006);
        }

        // ---- edge anti-aliasing: blend the front layer over whatever lies behind it
        if (k1 >= 0 && !pipeMain) {
            // the front pipe only partly covers this pixel: cheap-shade it over the main surface
            float3 Pe = ro + rd * t1;
            float3 Ne = retro_pipeNormal(Pe, H.u1, k1, s);
            float3 be = col1;
            float cv = clamp(dot(Ne, -rd), 0.0, 1.0);
            float3 F0 = metal ? be : float3(0.04);
            float3 ce = be * (metal ? 0.12 : 1.0) * (max(dot(Ne, Lk), 0.0) * 1.1 + 0.06)
                      + retro_studio(reflect(rd, Ne)) * (F0 + (1.0 - F0) * pow(1.0 - cv, 5.0)) * mix(0.25, 1.0, gloss);
            col = mix(col, ce * fadeK, a1 * fadeK);
        } else if (pipeMain && a1 < 1.0) {
            // silhouette of the main pipe: behind it is the second layer or the floor
            float3 behind = tf < 1e8 ? float3(0.012) : float3(0.004, 0.0045, 0.006);
            if (k2 >= 0 && a2 > 0.0) {
                float3 Pb = ro + rd * t2;
                float3 Nb = retro_pipeNormal(Pb, H.u2, k2, s);
                float3 bb = col2;
                behind = mix(behind, bb * (metal ? 0.12 : 1.0) * (max(dot(Nb, Lk), 0.0) * 1.1 + 0.06) * fadeK, a2);
            }
            col = mix(behind, col, a1);
        }

        col *= 1.0 - 0.3 * dot(p, p);
        return float4(retro_out(col, px), 1.0);
    }

    case 64: { // LIGHT RIBBONS — bouncing polygons (every vertex on its own path) leave a
               // trail of 32 echoes; each edge sweeps a translucent ribbon between echoes
               // (inverse-bilinear fill, colour ageing head → tail) with crisp glowing echo
               // lines on top. A full SIMD group: lane e owns echo e, culls every edge patch
               // against the group's pixel box, and a ballot hands each pixel the few
               // patches that reach it. p0 = (speed, shapes, sides, trail), p1 = (echoes, glow);
               // A leading edge, B trail.
        float speed = u.p0.x;
        int shapes = clamp(int(u.p0.y + 0.5), 1, 2), sides = clamp(int(u.p0.z + 0.5), 3, 6);
        float dT = max(u.p0.w, 0.1) * 0.16;                   // echo spacing (motion time)
        RetroRibbon s;
        s.head = srgbToLinear(u.colorA.rgb); s.tail = srgbToLinear(u.colorB.rgb);
        s.white = float3(1.0, 0.97, 0.94);
        s.pix = 1.0 / res.y; s.E = float(RETRO_RB_ECHOES);
        s.echoK = u.p1.x; s.glowK = u.p1.y; s.fillK = 0.12;
        s.sigma = 0.0035 * (0.6 + 0.4 * s.glowK);
        s.margin = s.sigma * 3.5 + 2.0 * s.pix;
        float margin = s.margin;

        float aspect = res.x / res.y;
        float2 q = (px - 0.5 * res) * s.pix;
        float2 lo = float2(-0.5 * aspect + 0.06, -0.44), hi = -lo;
        float tau0 = t * speed;

        // deep night backdrop
        float3 col = mix(float3(0.006, 0.006, 0.014), float3(0.0015, 0.0015, 0.004), smoothstep(0.0, 0.9, length(q)));

        ulong act = ulong(simd_vote::vote_t(simd_active_threads_mask()));
        float3 light = float3(0.0);
        if (act == 0xffffffffull) {
            uint lane = simd_prefix_exclusive_sum(1u);
            float2 tmin = simd_min(q), tmax = simd_max(q);
            float2 tc = 0.5 * (tmin + tmax);
            float trad = 0.5 * length(tmax - tmin) + margin;          // the group as a disc
            float te = tau0 - float(lane) * dT, te1 = te - dT;
            for (int sh = 0; sh < shapes; ++sh) {
                float hueSh = float(sh) * 2.1;
                RetroRibbon ss = s;
                if (sh == 1) { ss.head = retro_hueRGB(s.head, 0.9); ss.tail = retro_hueRGB(s.tail, 0.9); }
                float2 ph0, vl0; retro_rbParams(sh, 0, ph0, vl0);
                float2 pa = ph0, va = vl0;
                float2 F0 = retro_rbPos(ph0, vl0, te, lo, hi), F1 = retro_rbPos(ph0, vl0, te1, lo, hi);
                float2 A0 = F0, A1 = F1;
                for (int v = 0; v < sides; ++v) {
                    float2 pb, vb, B0, B1;
                    if (v + 1 == sides) { pb = ph0; vb = vl0; B0 = F0; B1 = F1; }
                    else {
                        retro_rbParams(sh, v + 1, pb, vb);
                        B0 = retro_rbPos(pb, vb, te, lo, hi); B1 = retro_rbPos(pb, vb, te1, lo, hi);
                    }
                    // the patch of this edge owned by this lane (echo lane to lane+1): does it reach the group?
                    // oriented box of the patch (along the edge / across it) vs the group disc
                    float2 ax = B0 - A0;
                    ax *= rsqrt(max(dot(ax, ax), 1e-10));
                    float2 ay = float2(-ax.y, ax.x);
                    float4 pu = float4(dot(A0, ax), dot(B0, ax), dot(A1, ax), dot(B1, ax));
                    float4 pv = float4(dot(A0, ay), dot(B0, ay), dot(A1, ay), dot(B1, ay));
                    float cu = dot(tc, ax), cv = dot(tc, ay);
                    bool hit = lane < uint(RETRO_RB_ECHOES - 1)
                            && cu > min(min(pu.x, pu.y), min(pu.z, pu.w)) - trad && cu < max(max(pu.x, pu.y), max(pu.z, pu.w)) + trad
                            && cv > min(min(pv.x, pv.y), min(pv.z, pv.w)) - trad && cv < max(max(pv.x, pv.y), max(pv.z, pv.w)) + trad;
                    uint m = uint(ulong(simd_vote::vote_t(simd_ballot(hit))));
                    uint prevL = 99u; float2 c0 = 0.0, c1 = 0.0;
                    while (m != 0u) {
                        uint L = ctz(m); m &= m - 1u;
                        float tl = tau0 - float(L) * dT, tl1 = tl - dT;
                        // consecutive echoes share an edge: reuse the previous far edge as this near one
                        float2 n0 = L == prevL + 1u ? c0 : retro_rbPos(pa, va, tl, lo, hi);
                        float2 n1 = L == prevL + 1u ? c1 : retro_rbPos(pb, vb, tl, lo, hi);
                        c0 = retro_rbPos(pa, va, tl1, lo, hi); c1 = retro_rbPos(pb, vb, tl1, lo, hi);
                        light += retro_rbPatch(q, n0, n1, c0, c1, float(L), hueSh, ss);
                        prevL = L;
                    }
                    pa = pb; va = vb; A0 = B0; A1 = B1;
                }
            }
        } else {
            // partial SIMD group: brute force every patch
            for (int sh = 0; sh < shapes; ++sh) {
                float hueSh = float(sh) * 2.1;
                RetroRibbon ss = s;
                if (sh == 1) { ss.head = retro_hueRGB(s.head, 0.9); ss.tail = retro_hueRGB(s.tail, 0.9); }
                for (int v = 0; v < sides; ++v) {
                    float2 pa, va, pb, vb;
                    retro_rbParams(sh, v, pa, va);
                    retro_rbParams(sh, v + 1 == sides ? 0 : v + 1, pb, vb);
                    for (int L = 0; L < RETRO_RB_ECHOES - 1; ++L) {
                        float tl = tau0 - float(L) * dT, tl1 = tl - dT;
                        float2 A0 = retro_rbPos(pa, va, tl, lo, hi), B0 = retro_rbPos(pb, vb, tl, lo, hi);
                        float2 A1 = retro_rbPos(pa, va, tl1, lo, hi), B1 = retro_rbPos(pb, vb, tl1, lo, hi);
                        float2 bmin = min(min(A0, A1), min(B0, B1)) - margin, bmax = max(max(A0, A1), max(B0, B1)) + margin;
                        if (all(q >= bmin) && all(q <= bmax))
                            light += retro_rbPatch(q, A0, B0, A1, B1, float(L), hueSh, ss);
                    }
                }
            }
        }
        col += light;
        col += filmGrain(px, t) * 0.0025;
        return float4(retro_out(col, px), 1.0);
    }
