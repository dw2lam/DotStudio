//  Music_cases.h — the Now Playing scene (66). See Shared/Scenes/Music.swift.

    case 66: { // NOW PLAYING — background only. p0 = (layout, background, motion, show album),
               // p1.x = show progress (both read by the overlay); music* uniforms per frame.
        int layout = int(u.p0.x + 0.5), bg = int(u.p0.y + 0.5);
        float tm = t * u.p0.z;
        float flags = u.music.x;                          // +1 artwork, +2 previous artwork
        bool hasArt = fmod(flags, 2.0) >= 0.5;
        bool hasPrev = flags >= 1.5;
        // Palette (brightest first); without one, the artwork's own mean or the idle colours.
        float3 vivid = u.musicPal0.a > 0.5 ? u.musicPal0.rgb : u.colorB.rgb;
        float3 mean  = u.musicPal1.a > 0.5 ? u.musicPal1.rgb : mix(u.colorA.rgb, u.colorB.rgb, 0.45);
        float3 deep  = u.musicPal2.a > 0.5 ? u.musicPal2.rgb : u.colorA.rgb;
        float asp = res.x / res.y;
        float2 wp = (layout != 2 && bg == 0) ? musicWarp((uv - 0.5) * float2(asp, 1.0), tm) : float2(0.0);
        float3 col = musicBackground(musicArt, hasArt, samp, uv, wp, res, tm, layout, bg, u.musicRect,
                                     vivid, mean, deep, u.colorA.rgb, u.colorB.rgb);
        // A new track: cross-fade from the previous background over 1.6 s.
        float fade = smoothstep(0.0, 1.6, u.music.w);
        if (fade < 1.0) {
            float3 old = musicBackground(musicArtPrev, hasPrev, samp, uv, wp, res, tm, layout, bg, u.musicRect,
                                         vivid, mean, deep, u.colorA.rgb, u.colorB.rgb);
            col = mix(old, col, fade);
        }
        col += filmGrain(px, t) * 0.011 + bandDither(px);
        return float4(saturate(col), 1.0);
    }
