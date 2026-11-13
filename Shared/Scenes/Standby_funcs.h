//  Standby_funcs.h — the StandBy pack: StandBy (75), Minimal (76), Chronometer (77). Every symbol
//  is "standby_". Uses Clocks_funcs.h (atlas, runs, time) and ClockKit_funcs.h (dial geometry,
//  studio light, burn-in drift, night, atlas face 4).
//
//  Frame: p in screen heights from the centre, x right, y DOWN. Every scene is a pure function of
//  u.clock / u.date (and u.sun for the night): no state, so every renderer agrees.

// ============================================================ 75 STANDBY
constant float STANDBY_ROLL = 0.6;          // seconds a changing figure takes to roll over
constant float STANDBY_TRACK = -0.012;      // tight, as display figures are set (caps)

/// Coverage of glyph distance d (caps): filled, or (outline) a stroke `sw` caps wide just inside
/// the figure's edge.
static inline float standby_shape(float d, bool outline, float sw, float capPx) {
    if (outline) d = abs(d + 0.5 * sw) - 0.5 * sw;
    return clocks_cov(d, capPx);
}

/// Advance (caps) of slot i of a time run in face 4; 0 for a blank slot.
static inline float standby_adv(texture2d<float> A, thread const ClkRun& r, int i) {
    int g = clocks_runGlyph(r, i);
    return (g < 0) ? 0.0 : clockkit_advRH(A, g);
}

/// StandBy: p0 = (style 0 Solid / 1 Outline / 2 Gradient, night 0 Auto / 1 On / 2 Off, 24-hour,
/// seconds), p1.x = size; colorA figures, colorB the gradient's lower end. Display sRGB out.
static inline float3 standby_standby(float2 px, float2 res, constant FXUniforms& u,
                                     texture2d<float> A, sampler s) {
    int style = int(u.p0.x + 0.5), nightSel = int(u.p0.y + 0.5);
    bool h24 = u.p0.z > 0.5, secs = u.p0.w > 0.5, outline = style == 1;
    float size = clamp(u.p1.x, 0.3, 1.2);
    float aspect = res.x / res.y;
    float2 p = (px - clockkit_drift(u.clock, res.y) - 0.5 * res) / res.y;

    // size from a fixed reference ("00:00"), so the figures never resize as the time changes
    float a0 = clockkit_advRH(A, 0), aC = clockkit_advRH(A, CLK_G_COLON);
    float refW = 4.0 * a0 + aC + 4.0 * STANDBY_TRACK;
    float cap = size * min(0.50, 0.88 * aspect / refW);
    float capPx = cap * res.y;
    float lift = secs ? 0.10 : 0.0;                                   // room for the seconds line
    float2 q = p / cap + float2(0.0, -0.5 + lift);                    // caps; baseline y = 0, cap top −1

    ClkTime T = clocks_time(u.clock, u.still.x);
    float3 C = saturate(u.colorA.rgb), C2 = saturate(u.colorB.rgb);
    float night = (nightSel == 1) ? 1.0 : (nightSel == 2) ? 0.0 : clockkit_night(u);

    float ink = 0.0;
    bool changing = T.a < STANDBY_ROLL;
    const float D = 0.26;                                             // roll distance, caps
    if (q.y > (changing ? -1.15 - D : -1.15) && q.y < (changing ? 0.12 + D : 0.12)) {   // the figures' band only
        // a changing figure rolls up out of view as the next one rises into place (both fading),
        // while the run slides into its new spacing; figures that stay put stay solid
        float pm = T.m - 1.0, ph = T.h;
        if (pm < 0.0) { pm = 59.0; ph = fmod(T.h + 23.0, 24.0); }
        float x = saturate(T.a / STANDBY_ROLL);                       // time through the roll
        float e = clocks_easeOut(x);                                  // its travel: quick, then settling
        ClkRun rN = clocks_timeRun(T.h, T.m, h24);
        ClkRun rO = changing ? clocks_timeRun(ph, pm, h24) : rN;
        // the slots' advances, fetched once (a blank slot: 0)
        float4 aN = float4(standby_adv(A, rN, 0), standby_adv(A, rN, 1), standby_adv(A, rN, 2), standby_adv(A, rN, 3));
        float aN4 = standby_adv(A, rN, 4);
        float4 aO = aN; float aO4 = aN4;
        if (changing) {
            aO = float4(standby_adv(A, rO, 0), standby_adv(A, rO, 1), standby_adv(A, rO, 2), standby_adv(A, rO, 3));
            aO4 = standby_adv(A, rO, 4);
        }
        float4 kN = select(float4(0.0), float4(STANDBY_TRACK), aN > 0.0), kO = select(float4(0.0), float4(STANDBY_TRACK), aO > 0.0);
        float Wn = dot(aN + kN, float4(1.0)) + aN4, Wo = dot(aO + kO, float4(1.0)) + aO4;
        float xo = -0.5 * Wo, xn = -0.5 * Wn;
        float sw = max(0.034, 1.4 / capPx);                           // outline stroke, caps
        float wO = 1.0 - smoothstep(0.0, 0.40, x), wN = smoothstep(0.22, 0.80, x);
        for (int i = 0; i < 5; ++i) {
            float ao = (i < 4) ? aO[i] : aO4, an = (i < 4) ? aN[i] : aN4;
            float xs = mix(xo, xn, e);
            if (q.x > xs - 0.3 && q.x < xs + max(ao, an) + 0.3) {
                int go = clocks_runGlyph(rO, i), gn = clocks_runGlyph(rN, i);
                float2 lq = q - float2(xs, 0.0);
                if (go == gn) {
                    if (gn >= 0) ink = max(ink, standby_shape(clocks_gdist(A, s, clockkit_glyphRH(A, gn), lq, float4(0)), outline, sw, capPx));
                } else {
                    if (go >= 0 && wO > 0.0)
                        ink = max(ink, wO * standby_shape(clocks_gdist(A, s, clockkit_glyphRH(A, go), lq + float2(0.0, D * e), float4(0)), outline, sw, capPx));
                    if (gn >= 0 && wN > 0.0)
                        ink = max(ink, wN * standby_shape(clocks_gdist(A, s, clockkit_glyphRH(A, gn), lq - float2(0.0, D * (1.0 - e)), float4(0)), outline, sw, capPx));
                }
            }
            if (ao > 0.0) xo += ao + STANDBY_TRACK;
            if (an > 0.0) xn += an + STANDBY_TRACK;
        }
    }

    // colour: flat, or a soft vertical gradient through the figures' height; at night all of it
    // goes over to a deep red at its own relative brightness
    float3 fill = C;
    if (style == 2) fill = mix(C, C2, smoothstep(-1.0, 0.05, q.y));
    float rel = clamp(luma(fill) / max(luma(C), 0.05), 0.25, 1.0);
    fill = mix(fill, float3(0.58, 0.035, 0.025) * rel, night);
    float3 col = fill * ink;

    // seconds: a short hairline under the figures, filling across the minute
    if (secs) {
        float y = 0.30, hw = 0.55;                                    // caps below the baseline, half length
        float th = max(0.010, 1.1 / capPx);                           // half thickness
        float d = clockkit_box(q - float2(0.0, y), float2(hw, th)) - th;
        float line = clocks_cov(d, capPx);
        if (line > 0.0) {
            float f = (floor(T.s) + clocks_easeOut(fract(T.s) / 0.35)) / 60.0;
            float on = clocks_cov(q.x - (-hw + 2.0 * hw * f), capPx);
            col = max(col, fill * line * mix(0.16, 0.70, on));
        }
    }
    if (style == 2) col += bandDither(px) * min(ink, 1.0);
    return saturate(col);
}

// ============================================================ 76 MINIMAL
/// Coverage of the two small seconds figures (tabular, pen at q = 0 on the baseline), each one
/// cross-fading into the next as it changes.
static inline float standby_secondsInk(texture2d<float> A, sampler s, float sec, float af, float4 fw, float bias,
                                       float2 q, float capPx, float cell) {
    float sN = floor(sec), sP = fmod(sN + 59.0, 60.0);
    float w = clocks_ease(af / 0.35);                    // af: ClkTime.af (settled in a still)
    float ink = 0.0;
    for (int i = 0; i < 2; ++i) {
        float2 lq = q - float2(float(i) * cell, 0.0);
        if (lq.x < -0.3 || lq.x > cell + 0.3) continue;
        int gn = int(i == 0 ? sN / 10.0 : fmod(sN, 10.0));
        int gp = int(i == 0 ? sP / 10.0 : fmod(sP, 10.0));
        float an = dot(clocks_adv(A, gn), fw), ap = dot(clocks_adv(A, gp), fw);
        float cn = clocks_cov(clocks_gdist(A, s, clocks_glyph(A, gn, fw), lq - float2(0.5 * (cell - an), 0.0), fw) - bias, capPx);
        if (gn == gp) { ink = max(ink, cn); continue; }
        float cp = clocks_cov(clocks_gdist(A, s, clocks_glyph(A, gp, fw), lq - float2(0.5 * (cell - ap), 0.0), fw) - bias, capPx);
        ink = max(ink, max(w * cn, (1.0 - w) * cp));
    }
    return ink;
}

/// Minimal: p0 = (background 0 Black / 1 Paper / 2 Soft Gradient, time size, date, 24-hour),
/// p1 = (seconds, alignment 0 Center / 1 Lower Left); colorA text, colorB the gradient's tone.
static inline float3 standby_minimal(float2 px, float2 res, constant FXUniforms& u,
                                     texture2d<float> A, sampler s) {
    int bgSel = int(u.p0.x + 0.5), align = int(u.p1.y + 0.5);
    float size = clamp(u.p0.y, 0.3, 2.0);
    bool showDate = u.p0.z > 0.5, h24 = u.p0.w > 0.5, secs = u.p1.x > 0.5;
    float aspect = res.x / res.y;
    float2 pf = (px - 0.5 * res) / res.y;                             // the ground stays put
    float2 p = (px - clockkit_drift(u.clock, res.y) - 0.5 * res) / res.y;   // the type drifts
    float3 TA = saturate(u.colorA.rgb), TB = saturate(u.colorB.rgb);

    // ---- the ground
    float3 bg, ink;
    if (bgSel == 1) {                                                 // paper: warm, a faint tooth
        float g = clocks_grain(pf * 820.0) * smoothstep(1.2, 2.4, res.y / 820.0);
        bg = float3(0.938, 0.930, 0.905) * (1.0 - 0.035 * dot(pf * float2(0.8, 1.0), pf * float2(0.8, 1.0)))
           + 0.010 * g;
        ink = luma(TA) > 0.5 ? float3(0.105, 0.105, 0.115) : TA;
    } else if (bgSel == 2) {                                          // a soft gradient that drifts over hours
        float ph = u.clock.x * (6.28318531 / 24.0);
        float2 c1 = float2(-0.55 * aspect * 0.5 + 0.20 * sin(ph * 7.0), -0.45 + 0.12 * cos(ph * 5.0));
        float2 c2 = float2(0.50 * aspect * 0.5 + 0.18 * cos(ph * 6.0 + 1.0), 0.55 + 0.10 * sin(ph * 4.0 + 2.0));
        float3 Bl = srgbToLinear(TB);
        float3 deep = Bl * 0.30, glow = Bl * 2.3 + float3(0.030, 0.012, 0.026);   // the same hue, lit
        float3 c = mix(deep, Bl, smoothstep(0.9, -0.6, pf.y + 0.25 * pf.x));
        c = mix(c, glow, 0.85 * exp(-dot(pf - c1, pf - c1) / 0.42));
        c = mix(c, deep * 0.7, 0.55 * exp(-dot(pf - c2, pf - c2) / 0.30));
        bg = linearToSrgb(c);
        ink = luma(TA) < 0.25 ? float3(0.96) : TA;
    } else {
        bg = float3(0.0);
        ink = luma(TA) < 0.25 ? float3(0.93, 0.92, 0.90) : TA;
    }

    // ---- layout: the time, then (a gap) the date line, as one block
    float capT = 0.15 * size;
    float bias; float4 fw = clocks_face(0, 0.06, bias);               // SF Pro Light, a touch thinner
    float tabW = dot(clocks_adv(A, 0), fw);
    float colW = dot(clocks_adv(A, CLK_G_COLON), fw);
    const float track = 0.0;
    float refW = 4.0 * tabW + colW + 4.0 * track;
    const float ks = 0.34;                                            // seconds: this much of the time's size
    float secW = secs ? 0.16 + 2.0 * tabW * ks : 0.0;                 // in time caps
    capT = min(capT, 0.84 * aspect / (refW + secW));
    float capD = max(0.0175, 7.0 / res.y);
    float gap = 0.40 * capT + 0.010;
    float m = 0.085;                                                  // lower left: the margin
    float xL = -0.5 * aspect + m;
    bool centered = align == 0;
    float baseT, baseD;
    if (centered) {
        float h = capT + (showDate ? gap + capD : 0.0);
        baseT = -0.5 * h + capT - 0.012;                              // (optically a hair above centre)
        baseD = baseT + gap + capD;
    } else {
        baseD = 0.5 - m;
        baseT = showDate ? baseD - capD - gap : baseD;
    }

    float cov = 0.0;
    // the time
    if (p.y > baseT - 1.3 * capT && p.y < baseT + 0.3 * capT) {
        ClkTime T = clocks_time(u.clock, u.still.x);
        float pmn = T.m - 1.0, phr = T.h;
        if (pmn < 0.0) { pmn = 59.0; phr = fmod(T.h + 23.0, 24.0); }
        bool changing = T.a < 1.1;
        float slide = clocks_ease(T.a / 1.1);
        float wN = clocks_ease((T.a - 0.40) / 0.70), wO = 1.0 - clocks_ease(T.a / 0.50);
        ClkRun rNew = clocks_timeRun(T.h, T.m, h24);
        ClkRun rOld = changing ? clocks_timeRun(phr, pmn, h24) : rNew;
        float2 tq = (p - float2(centered ? 0.0 : xL, baseT)) / capT;
        if (centered) tq.x += 0.5 * secW;                             // centre time + seconds together
        float endX;
        cov = clocks_timeCov(A, s, rOld, rNew, fw, bias, track, centered, 0.0,
                             slide, wO, wN, tq, capT * res.y, endX);
        if (secs) {
            float2 sq = (tq - float2(endX + 0.16, 0.0)) / ks;
            float sb; float4 sfw = clocks_face(0, 0.22, sb);
            cov = max(cov, 0.55 * standby_secondsInk(A, s, T.s, T.af, sfw, sb, sq, ks * capT * res.y, tabW));
        }
    }
    // the date: "TUESDAY · NOVEMBER 10" in small tracked capitals
    if (showDate && p.y > baseD - 1.4 * capD && p.y < baseD + 0.4 * capD) {
        float db; float4 dfw = clocks_face(0, 0.40, db);
        const float dtrack = 0.20;
        float2 dq0 = (p - float2(centered ? 0.0 : xL, baseD)) / capD;
        ClkRun dr = clocks_dateRun(u.date, u.clock, true, false);
        float w = clocks_runWidth(A, dr, dfw, dtrack);
        float2 dq = dq0 + float2(centered ? 0.5 * w : 0.0, 0.0);
        float secOfDay = u.still.x > 0.5 ? 1000.0 : clocks_secOfDay(u.clock);   // (the date settled in a still)
        float wN = clocks_ease((secOfDay - 0.40) / 0.70);             // at midnight: yesterday fades out,
        float dc = wN * clocks_cov(clocks_runDist(A, s, dr, dfw, dtrack, dq) - db, capD * res.y);
        if (secOfDay < 1.1) {                                         // today fades in (as the time does)
            int yy = int(u.date.x), mo = clamp(int(u.date.y), 1, 12), dd = clamp(int(u.date.z), 1, 31);
            float4 pdate = (dd > 1) ? float4(float(yy), float(mo), float(dd - 1), 0.0)
                         : float4(float(mo == 1 ? yy - 1 : yy), float(mo == 1 ? 12 : mo - 1),
                                  float(clockkit_prevMonthDays(yy, mo)), 0.0);
            float4 pclock = float4(0.0, 0.0, 0.0, fmod(u.clock.w + 5.0, 7.0) + 1.0);
            ClkRun pr = clocks_dateRun(pdate, pclock, true, false);
            float pw = clocks_runWidth(A, pr, dfw, dtrack);
            float2 pq = dq0 + float2(centered ? 0.5 * pw : 0.0, 0.0);
            float wO = 1.0 - clocks_ease(secOfDay / 0.50);
            dc = max(dc, wO * clocks_cov(clocks_runDist(A, s, pr, dfw, dtrack, pq) - db, capD * res.y));
        }
        cov = max(cov, 0.62 * dc);
    }
    float3 col = mix(bg, ink, cov);
    if (bgSel != 0) col += bandDither(px);
    return saturate(col);
}

// ============================================================ 77 CHRONOMETER
// Geometry, × R (the dial's radius, where it meets the rehaut).
constant float  WATCH_REHAUT = 1.075, WATCH_BEZEL = 1.205;            // rehaut's outer edge; the case's
// Hands: (tail, widest point, half-width, length) of the dauphine kite; their lume inlays.
constant float4 WATCH_HOUR   = float4(0.050, 0.125, 0.054, 0.610);
constant float4 WATCH_MIN    = float4(0.045, 0.135, 0.042, 0.935);
constant float4 WATCH_HOUR_L = float4(-0.165, 0.215, 0.019, 0.525);
constant float4 WATCH_MIN_L  = float4(-0.165, 0.235, 0.014, 0.845);
constant float  WATCH_COLLAR_H = 0.060, WATCH_COLLAR_M = 0.047;
// Heights above the dial: shadow offsets and softness.
constant float  WATCH_Z_IDX = 0.014, WATCH_Z_HOUR = 0.026, WATCH_Z_MIN = 0.038, WATCH_Z_SEC = 0.050;
// The batons: centre radius, half length, half width; the lume strip's half width.
constant float  WATCH_IDX_MID = 0.790, WATCH_IDX_HL = 0.105, WATCH_IDX_HW = 0.0215, WATCH_IDX_LW = 0.0072;

/// Polished or satin metal: the studio reflected with its lights widened by `lw`.
static inline float3 standby_metalLw(float3 n, float3 V, float3 L, float3 Lf, float3 F0, float lw,
                                     ClockKitStudio S) {
    float c = saturate(dot(n, V));
    float3 F = F0 + (1.0 - F0) * pow(1.0 - c, 5.0);
    return F * clockkit_env(reflect(-V, n), L, Lf, lw, S);
}

/// The watch's studio: a dark room (polished steel reads deep, with crisp highlights), one big
/// warm softbox and a cool strip.
static inline ClockKitStudio standby_watchStudio() {
    ClockKitStudio S;
    S.domeLo = float3(0.006, 0.0065, 0.0075); S.domeHi = float3(0.055, 0.058, 0.064);
    S.key = 3.2; S.fill = 0.65;
    return S;
}

/// The seconds hand (screen units): a needle to near the rehaut, a lume disc ringed in steel
/// toward its tip, a slim counterweight on the tail, its boss. `disc` returns the distance to
/// the lume disc's inside.
static inline float standby_secD(float2 p, float a, float R, float hw, thread float& disc) {
    float2 q = clockkit_local(p, a);
    float w = hw * (1.0 - 0.30 * saturate(q.x / (0.97 * R)));
    float d = max(abs(q.x - 0.380 * R) - 0.590 * R, abs(q.y) - w);       // −0.21 R … 0.97 R
    float2 lq = q - float2(0.735 * R, 0.0);
    float dl = length(lq) - 0.030 * R;
    disc = length(lq) - 0.021 * R;
    d = min(d, dl);
    d = min(d, clockkit_box(q + float2(0.155 * R, 0.0), float2(0.050 * R, 0.0105 * R)) - 0.006 * R);
    return min(d, length(q) - 0.032 * R);
}

/// Chronometer: p0 = (dial 0 Black / 1 Blue / 2 Silver / 3 Green / 4 Champagne, date window,
/// seconds 0 Sweep / 1 Off, lume 0 Auto (glows after dark) / 1 Off). Display sRGB out.
static inline float3 standby_watch(float2 px, float2 res, float t, constant FXUniforms& u,
                                   texture2d<float> At, sampler s) {
    const float TAU = 6.28318531;
    int dialSel = int(u.p0.x + 0.5);
    bool showDate = u.p0.y > 0.5, secs = u.p0.z < 0.5;
    float glow = (u.p0.w < 0.5) ? clockkit_night(u) : 0.0;

    float aspect = res.x / res.y;
    float fp = 1.0 / res.y;
    float2 p = (px - clockkit_drift(u.clock, res.y) - 0.5 * res) / res.y;
    float R = min(0.478 / WATCH_BEZEL, 0.47 * aspect / WATCH_BEZEL);  // the case just inside the screen
    float fpR = fp / R;
    float r = length(p), rr = r / R;
    float ang = atan2(p.x, -p.y); if (ang < 0.0) ang += TAU;
    float2 rad = (r > 1e-6) ? p / r : float2(0.0, -1.0);

    // ---- light and camera: one big soft key whose azimuth follows the day (as Dial Clock)
    float hx6 = fmod(u.clock.x + 18.0, 24.0);
    float day = (hx6 < 12.0) ? hx6 / 12.0 : (24.0 - hx6) / 12.0;
    float ph = u.clock.x * (TAU / 24.0);
    float az = (212.0 + 116.0 * day + 5.0 * sin(ph * 37.0) + 2.0 * sin(ph * 61.0 + 1.7)) * (TAU / 360.0);
    float2 L2 = float2(cos(az), sin(az));
    float3 L = float3(L2 * 0.766, 0.643);
    float3 Lf = normalize(float3(float2(-L2.y, L2.x) * 0.70, 0.71));
    ClockKitStudio S = standby_watchStudio();
    float3 V = normalize(float3(-p, 2.4));
    float2 sOff = L.xy / L.z;
    float pen0 = 0.0022 * R;
    const float penK = 0.30;

    // dial colour (display sRGB) and the metal of the hands and batons
    float3 dialC = (dialSel == 0) ? float3(0.032, 0.032, 0.036)
                 : (dialSel == 2) ? float3(0.80, 0.80, 0.79)
                 : (dialSel == 3) ? float3(0.045, 0.150, 0.100)
                 : (dialSel == 4) ? float3(0.80, 0.70, 0.52)
                 : float3(0.035, 0.090, 0.250);
    float3 Ad = srgbToLinear(dialC);
    bool pale = luma(dialC) > 0.5;
    float3 F0 = (dialSel == 4) ? float3(0.96, 0.78, 0.50) : float3(0.62, 0.63, 0.65);   // champagne: gold
    float3 steel = float3(0.62, 0.63, 0.65);
    float3 inkC = pale ? float3(0.012, 0.012, 0.014) : float3(0.62, 0.63, 0.64);       // printing
    float3 lumeDay = float3(0.80, 0.82, 0.74);                        // the paint, by day (linear)
    float3 lumeGlow = float3(0.30, 1.00, 0.55) * 1.15;                // its glow (C3-ish green)
    // after dark the room dims and the lume glows: everything lit is scaled by `dim` at the end,
    // so the glow is added pre-divided by it
    float dim = mix(1.0, 0.30, glow);
    float3 lumeE = lumeGlow * (glow / dim);

    float3 col;
    if (rr < 1.0 + 3.0 * fpR) {
        // ---- the dial: sunburst — tinted lacquer over metal brushed in fine radial lines; a
        // line reflects only where it runs across the light, so the key draws a bow-tie
        float2 Bt = float2(-rad.y, rad.x);
        float3 H = normalize(L + V);
        const float aT = 0.080, aB = 0.62;
        float2 h1 = float2(dot(H.xy, rad) / aT, dot(H.xy, Bt) / aB);
        float w1 = exp(-dot(h1, h1) / (H.z * H.z));
        float angPx = fp / max(r, 1e-4);
        float f1 = smoothstep(1.5, 4.0, (TAU / 900.0) / angPx), f2 = smoothstep(1.5, 4.0, (TAU / 2800.0) / angPx);
        float br = 1.0 + 0.30 * f1 * (clockkit_pnoise(ang / TAU * 900.0, 900.0, 5.0) - 0.5)
                       + 0.26 * f2 * (clockkit_pnoise(ang / TAU * 2800.0, 2800.0, 7.0) - 0.5);
        float3 tint = Ad / max(max(Ad.r, Ad.g), max(Ad.b, 1e-4));
        float3 specC = mix(tint, float3(1.0), pale ? 0.75 : 0.18);
        float lit = 0.82 + 0.24 * clamp(dot(p / R, L2), -1.0, 1.0);
        float deg = pale ? mix(1.0, 0.86, smoothstep(0.30, 1.0, rr))  // dégradé: deeper toward the edge
                         : mix(1.0, 0.50, smoothstep(0.25, 1.0, rr));
        float sp = pale ? 0.50 : (dialSel == 0 ? 0.26 : 0.36);         // (black shows the sheen most)
        col = (Ad * (pale ? 0.62 : 0.60) * lit + specC * (sp * w1 * br)) * deg;

        // the rehaut's shadow on the dial's rim (the dial sits below the flange)
        float zr = 0.05 * R;
        float dRim = length(p + sOff * zr) - R;
        col *= 1.0 - 0.45 * smoothstep(-0.020 * R, 0.010 * R, dRim) * smoothstep(-0.06 * R, 0.0, r - R);

        // ---- applied batons: polished, hip-roofed, a lume strip down each; a short shadow
        if (rr > 0.66 && rr < 0.92) {
            float iH = round(ang / (TAU / 12.0));
            int hi = int(iH) % 12;
            float aI = iH * TAU / 12.0;
            bool twelve = hi == 0;
            float2 bx = float2(WATCH_IDX_HL, WATCH_IDX_HW) * R;
            float off12 = 1.32 * bx.y;
            if (twelve) bx.y *= 0.78;
            float2 qs = clockkit_local(p + sOff * (WATCH_Z_IDX * R), aI) - float2(WATCH_IDX_MID * R, 0.0);
            float2 q = clockkit_local(p, aI) - float2(WATCH_IDX_MID * R, 0.0);
            float sgn = 1.0;
            if (twelve) { qs.y = abs(qs.y) - off12; sgn = (q.y < 0.0) ? -1.0 : 1.0; q.y = abs(q.y) - off12; }
            if (!(showDate && hi == 3)) {                             // the date window takes 3
                float pen = pen0 + penK * WATCH_Z_IDX * R;
                float d = clockkit_box(q, bx);
                col *= 1.0 - 0.55 * smoothstep(pen, -pen, clockkit_box(qs, bx));
                col *= 1.0 - 0.18 * exp(-max(d, 0.0) / (0.008 * R));
                float cov = saturate(0.5 - d / fp);
                if (cov > 0.0) {
                    float2 dir = clockkit_dir(aI), perp = float2(cos(aI), sin(aI)) * sgn;
                    const float sl = 0.62;
                    float2 e = bx - abs(q);
                    float3 cS = mix(clockkit_metal(normalize(float3(-perp * sl, 1.0)), V, L, Lf, F0, S),
                                    clockkit_metal(normalize(float3( perp * sl, 1.0)), V, L, Lf, F0, S), saturate(0.5 + q.y / fp));
                    float3 cE = mix(clockkit_metal(normalize(float3(-dir * sl, 1.0)), V, L, Lf, F0, S),
                                    clockkit_metal(normalize(float3( dir * sl, 1.0)), V, L, Lf, F0, S), saturate(0.5 + q.x / fp));
                    float3 ic = mix(cS, cE, saturate(0.5 + (e.y - e.x) / (1.4 * fp)));
                    // the lume strip: a channel along the roof, the paint set a touch below it
                    float lw = (twelve ? 0.72 : 1.0) * WATCH_IDX_LW * R;
                    float dL = clockkit_box(q, float2(bx.x - 0.020 * R, lw));
                    float covL = saturate(0.5 - dL / fp);
                    float3 lumeC = lumeDay * (0.30 + 0.30 * saturate(dot(float3(-perp * 0.2, 1.0), L))) + lumeE;
                    float edge = exp(-max(dL + 0.0025 * R, 0.0) / max(0.003 * R, fp)) * (1.0 - covL);
                    ic *= 1.0 - 0.35 * edge;                          // the channel's wall
                    ic = mix(ic, lumeC, covL);
                    col = mix(col, ic, cov);
                }
            }
        }

        // ---- the date: a white disc in a framed window at 3; it rolls at midnight
        if (showDate && abs(p.y) < 0.09 * R && abs(p.x - WATCH_IDX_MID * R) < 0.11 * R) {
            float2 hx = float2(0.064, 0.047) * R;
            float cr = 0.006 * R, fw0 = 0.0085 * R;
            float2 q = p - float2(WATCH_IDX_MID * R, 0.0);
            float dA = clockkit_box(q, hx - cr) - cr;
            float pen = pen0 + penK * 0.010 * R;
            col *= 1.0 - 0.45 * smoothstep(pen, -pen, clockkit_box(q + sOff * (0.010 * R), hx - cr + fw0) - cr);
            float covA = saturate(0.5 - dA / fp);
            if (covA > 0.0) {
                float3 disc = srgbToLinear(float3(0.925, 0.920, 0.895));
                float dIn = clockkit_box(q + sOff * (0.014 * R), hx - cr) - cr;
                float sh = smoothstep(-0.009 * R, 0.001 * R, dIn);
                int yy = int(u.date.x), mo = clamp(int(u.date.y), 1, 12), dd = clamp(int(u.date.z), 1, 31);
                float e = u.still.x > 0.5 ? 1.0 : clocks_ease(clocks_secOfDay(u.clock) / 1.4);   // settled in a still
                float capD = 0.058 * R, pitch = 2.3 * hx.y / capD;
                float db; float4 dfw = clocks_face(0, 0.45, db);
                float2 dq = q / capD;
                float ink = clockkit_dayInk(At, s, dd, dq - float2(0.0, (1.0 - e) * pitch), dfw, db, capD * res.y);
                if (e < 1.0) {
                    int pd = (dd > 1) ? dd - 1 : clockkit_prevMonthDays(yy, mo);
                    ink = max(ink, clockkit_dayInk(At, s, pd, dq + float2(0.0, e * pitch), dfw, db, capD * res.y));
                }
                disc = mix(disc, float3(0.006), ink);
                float lit = 0.86 + 0.18 * clamp(dot(q / (0.1 * R), L2), -1.0, 1.0);
                col = mix(col, disc * lit * (1.0 - 0.55 * sh), covA);
            }
            float covF = saturate(0.5 - (abs(dA - 0.5 * fw0) - 0.5 * fw0) / fp);
            if (covF > 0.0) {
                float2 ee = abs(q) - (hx - cr);
                float2 g = (ee.x > 0.0 && ee.y > 0.0) ? normalize(ee) * sign(q)
                         : ((ee.x > ee.y) ? float2(sign(q.x), 0.0) : float2(0.0, sign(q.y)));
                float3 fc = mix(clockkit_metal(normalize(float3(-g * 0.55, 1.0)), V, L, Lf, F0, S),
                                clockkit_metal(normalize(float3( g * 0.55, 1.0)), V, L, Lf, F0, S),
                                saturate(0.5 + (dA - 0.5 * fw0) / fp));
                col = mix(col, fc, covF);
            }
        }
    } else {
        col = float3(0.0);
    }

    // ---- the rehaut: a sloped flange from the dial up to the crystal, the minute track on it
    if (rr >= 1.0 - 3.0 * fpR && rr < WATCH_REHAUT + 3.0 * fpR) {
        float3 n = normalize(float3(-rad * 0.85, 1.0));
        float u0 = saturate((rr - 1.0) / (WATCH_REHAUT - 1.0));
        float3 rc = Ad * (pale ? 0.55 : 0.75) * (0.30 + 0.85 * saturate(dot(n, L)))
                  + 0.04 * standby_metalLw(n, V, L, Lf, float3(0.04), 0.25, S);
        rc *= 0.80 + 0.20 * u0;
        // the minute track: 60 fine strokes, every fifth longer and bolder
        float seg = TAU / 60.0, j = round(ang / seg);
        float2 q = clockkit_local(p, j * seg);
        bool five = fmod(j, 5.0) < 0.5;
        float r0 = R * (five ? 1.010 : 1.022), r1 = R * 1.058;
        float hw = R * (five ? 0.0046 : 0.0024), hwd = max(hw, 0.5 * fp);
        float d = clockkit_box(q - float2(0.5 * (r0 + r1), 0.0), float2(0.5 * (r1 - r0), hwd));
        rc = mix(rc, inkC * (0.45 + 0.55 * saturate(dot(n, L) + 0.3)), saturate(0.5 - d / fp) * (hw / hwd) * 0.95);
        float cov = saturate(0.5 + (rr - 1.0) / fpR) * saturate(0.5 + (WATCH_REHAUT - rr) / fpR);
        col = mix(col, rc, cov);
    }

    // ---- the case: a thin dark gasket, then the polished bezel, its top a satin band
    if (rr >= WATCH_REHAUT - 3.0 * fpR) {
        float3 cc;
        float x = (rr - WATCH_REHAUT) / (WATCH_BEZEL - WATCH_REHAUT); // 0 inner … 1 outer edge
        if (rr < WATCH_REHAUT + 0.006) {
            cc = float3(0.004);                                       // the gasket
        } else {
            // profile: a polished inner bevel, a flat satin top, then rounding away outward
            float th = (x < 0.22) ? mix(-0.95, -0.15, x / 0.22)
                     : (x < 0.62) ? mix(-0.06, 0.08, (x - 0.22) / 0.40)
                     : mix(0.20, 1.35, (x - 0.62) / 0.38);
            float3 n = normalize(float3(rad * sin(th), cos(th)));
            float satin = (x >= 0.22 && x < 0.62) ? 1.0 : 0.0;
            float lwPx = fpR * 4.0;
            cc = standby_metalLw(n, V, L, Lf, steel, satin * 0.18 + lwPx, S);
            if (satin > 0.0) {                                        // circular graining on the satin top
                float fb = smoothstep(1.5, 4.0, (R / 1600.0) / fp);
                cc *= 1.0 + 0.45 * fb * (clockkit_pnoise(rr * 1600.0, 4096.0, 11.0) - 0.5)
                          + 0.25 * (clockkit_pnoise(rr * 380.0, 4096.0, 13.0) - 0.5);
            }
            // the bevel's edges catch a hairline of light
            cc += 0.25 * steel * exp(-abs(x - 0.22) / max(0.012, fpR * 3.0)) * saturate(dot(rad, L2) * 0.5 + 0.6);
        }
        float covC = saturate(0.5 + (rr - WATCH_REHAUT) / fpR) * saturate(0.5 + (WATCH_BEZEL - rr) / fpR);
        // beyond: a dark surround, the case's soft shadow on it
        float3 sur = float3(0.0055, 0.0058, 0.0065) * (1.0 - 0.4 * smoothstep(0.4, 1.2, length(p * float2(0.75, 1.0))));
        float dS = length(p - sOff * 0.06 * R) - WATCH_BEZEL * R;
        sur *= 0.35 + 0.65 * smoothstep(-0.01 * R, 0.10 * R, dS);
        float inner = saturate(0.5 + (WATCH_BEZEL - rr) / fpR);
        col = mix(sur, col, inner);
        col = mix(col, cc, covC);
    }

    // ---- the hands, sweeping continuously
    float aH = TAU * fmod(u.clock.x, 12.0) / 12.0;
    float aM = TAU * u.clock.y / 60.0;
    float aS = TAU * u.clock.z / 60.0;
    float hwS = 0.0040 * R, hwSd = max(hwS, 0.5 * fp);
    float zH = WATCH_Z_HOUR * R, zM = WATCH_Z_MIN * R, zS = WATCH_Z_SEC * R;
    bool nearH = rr < 0.70, nearM = rr < 1.02, nearS = secs && rr < 1.04;
    float discS;
    float dH = nearH ? clockkit_handD(p, aH, WATCH_HOUR, WATCH_COLLAR_H, R) : 1.0;
    float dM = nearM ? clockkit_handD(p, aM, WATCH_MIN, WATCH_COLLAR_M, R) : 1.0;
    float dS = nearS ? standby_secD(p, aS, R, hwSd, discS) : 1.0;
    if (nearM || nearS) {
        float ph1 = pen0 + penK * zH, pm = pen0 + penK * zM, ps = pen0 + penK * zS, dmy;
        float shade = 1.0;
        if (nearH) shade *= 1.0 - 0.50 * smoothstep(ph1, -ph1, clockkit_handD(p + sOff * zH, aH, WATCH_HOUR, WATCH_COLLAR_H, R));
        if (nearM) shade *= 1.0 - 0.50 * smoothstep(pm, -pm, clockkit_handD(p + sOff * zM, aM, WATCH_MIN, WATCH_COLLAR_M, R));
        if (nearS) shade *= 1.0 - 0.40 * smoothstep(ps, -ps, standby_secD(p + sOff * zS, aS, R, hwSd, dmy)) * (hwS / hwSd);
        col *= shade;
    }
    // a dauphine hand: two polished facets with a ridge, its lume inlay down the middle
    float covH = saturate(0.5 - dH / fp);
    if (covH > 0.0) {
        float2 q = clockkit_local(p, aH) / R;
        float3 hc = clockkit_handShade(q, aH, WATCH_COLLAR_H, fpR, V, L, Lf, F0, S);
        float dl = clockkit_kite(q, WATCH_HOUR_L);
        float covL = saturate(0.5 - dl / fpR);
        hc *= 1.0 - 0.40 * exp(-max(dl, 0.0) / max(0.004, 1.5 * fpR)) * (1.0 - covL);
        hc = mix(hc, lumeDay * 0.55 + lumeE, covL);
        float pm = pen0 + penK * (zM - zH), ps = pen0 + penK * (zS - zH), dmy;
        hc *= 1.0 - 0.50 * smoothstep(pm, -pm, clockkit_handD(p + sOff * (zM - zH), aM, WATCH_MIN, WATCH_COLLAR_M, R));
        if (secs) hc *= 1.0 - 0.40 * smoothstep(ps, -ps, standby_secD(p + sOff * (zS - zH), aS, R, hwSd, dmy));
        col = mix(col, hc, covH);
    }
    float covM = saturate(0.5 - dM / fp);
    if (covM > 0.0) {
        float2 q = clockkit_local(p, aM) / R;
        float3 mc = clockkit_handShade(q, aM, WATCH_COLLAR_M, fpR, V, L, Lf, F0, S);
        float dl = clockkit_kite(q, WATCH_MIN_L);
        float covL = saturate(0.5 - dl / fpR);
        mc *= 1.0 - 0.40 * exp(-max(dl, 0.0) / max(0.004, 1.5 * fpR)) * (1.0 - covL);
        mc = mix(mc, lumeDay * 0.55 + lumeE, covL);
        float ps = pen0 + penK * (zS - zM), dmy;
        if (secs) mc *= 1.0 - 0.40 * smoothstep(ps, -ps, standby_secD(p + sOff * (zS - zM), aS, R, hwSd, dmy));
        col = mix(col, mc, covM);
    }
    if (nearS) {
        float covS = saturate(0.5 - dS / fp) * mix(hwS / hwSd, 1.0, saturate(0.5 - (r - 0.032 * R) / fp));
        covS = max(covS, saturate(0.5 - dS / fp) * saturate(0.5 - (discS - 0.012 * R) / fp));
        if (covS > 0.0) {
            float2 q = clockkit_local(p, aS);
            float3 sc = mix(clockkit_ridge(clockkit_dir(aS), 0.5, V, L, Lf, steel, S), steel * 0.42, 0.55);   // rhodium, a satin glint
            float covL = saturate(0.5 - discS / fp);
            sc = mix(sc, lumeDay * 0.55 + lumeE, covL);
            if (length(q) < 0.032 * R) sc = clockkit_metal(normalize(float3(q / (0.032 * R) * 0.5, 1.0)), V, L, Lf, steel, S);
            col = mix(col, sc, covS);
        }
    }
    {   // the cap over the arbor: a small polished dome
        float rc = 0.018 * R;
        float covC = saturate(0.5 - (r - rc) / fp);
        if (covC > 0.0) {
            float3 n = normalize(float3(p / max(r, 1e-5) * (0.05 + 0.65 * r / rc), 1.0));
            col = mix(col, clockkit_metal(n, V, L, Lf, secs ? steel : F0, S), covC);
        }
    }

    // ---- the crystal: a domed sapphire, the faintest reflection of the window across it
    if (rr < WATCH_REHAUT) {
        float2 c = -L2 * 0.30 * R;                                    // (a dome mirrors the light behind you)
        float2 dq = (p - c) / R;
        float band = exp(-dot(dq * float2(1.0, 1.0), dq) / 0.30) * smoothstep(1.0, 0.55, rr);
        float rim = exp(-(WATCH_REHAUT - rr) / 0.035) * (0.5 + 0.5 * dot(rad, -L2));
        col += float3(0.70, 0.76, 0.90) * (0.022 * band + 0.030 * rim);
    }
    col *= dim;

    // ---- lens: a gentle vignette, highlights rolling off instead of clipping
    col *= 1.0 - 0.22 * smoothstep(0.35, 1.05, length(p * float2(0.78, 1.0)));
    col = select(col, 0.80 + 0.20 * (1.0 - exp(-(col - 0.80) / 0.20)), col > 0.80);
    return saturate(linearToSrgb(col) + bandDither(px) * 2.0);
}
