//  Studio4_cases.h — `case 70: { … return float4(col, 1.0); }` for new-scene slot 4. Included inside fx_fragment's switch.

    case 70: { // DICHROIC — dichroic glass panes turning in a sunlit plaster cove: transmitted casts
               // multiply per wavelength, reflected patches add, and the glass shifts colour with
               // angle. Analytic ray tracing in linear light (studio4_scene), then ACES + dither.
               // p0 = (panes, turn speed, glass, shapes), p1 = (sun height °, sun direction °,
               // follow the sun, room); colorA room, colorB sunlight.
        float3 c = studio4_scene(px, res, t, u);
        // a gentle lens vignette
        float2 vq = (uv - 0.5) * float2(res.x / res.y * 0.625, 1.0);
        c *= 1.0 - 0.20 * dot(vq, vq);
        // Filmic: ACES on luminance (keeps the casts' hue), blended with per-channel ACES. A bright
        // saturated colour (sunlit floor through magenta glass) can push a channel past white:
        // pull it toward its own luminance until it fits, instead of clipping the channel.
        const float3 W = float3(0.2126, 0.7152, 0.0722);
        float Lm = dot(c, W);
        float3 th = c * (aces(float3(Lm)).x / max(Lm, 1e-5));
        float Lh = dot(th, W), mh = max(th.r, max(th.g, th.b));
        if (mh > 1.0) th = Lh + (th - Lh) * ((1.0 - Lh) / max(mh - Lh, 1e-5));
        float3 tm = mix(th, aces(c), 0.45);
        float3 o = linearToSrgb(saturate(tm));
        o += bandDither(px) * 1.5;
        return float4(o, 1.0);
    }
