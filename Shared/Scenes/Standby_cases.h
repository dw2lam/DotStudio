//  Standby_cases.h — the StandBy pack (Standby.swift). Included inside fx_fragment's switch.

    case 75: { // STANDBY — huge rounded figures on black (SF Pro Rounded Heavy, atlas face 4);
               // a changing figure rolls up softly; deep red after sunset in night mode.
               // p0 = (style, night mode, 24-hour, seconds), p1.x = size; colorA figures,
               // colorB the gradient's lower end. See Standby_funcs.h.
        return float4(standby_standby(px, res, u, textAtlas, samp), 1.0);
    }
    case 76: { // MINIMAL — thin SF Pro Light time, the weekday and date in tracked capitals.
               // p0 = (background, size, date, 24-hour), p1 = (seconds, alignment); colorA text,
               // colorB the soft gradient's tone.
        return float4(standby_minimal(px, res, u, textAtlas, samp), 1.0);
    }
    case 77: { // CHRONOMETER — a wristwatch dial filling the screen height: sunburst dial,
               // applied faceted batons, dauphine hands, sweeping seconds, date at 3, lume.
               // p0 = (dial, date window, seconds, lume).
        return float4(standby_watch(px, res, t, u, textAtlas, samp), 1.0);
    }
