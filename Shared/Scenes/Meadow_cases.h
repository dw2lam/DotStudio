//  Meadow_cases.h — the Meadow pack (Meadow.swift). Included inside fx_fragment's switch.

    case 78: { // MEADOW — summer fields in the wind under a big sky (Tidewater's sun, moon, stars
               // and weather). p0 = (speed, wind, flowers, clouds), p1 = (follow the sun, hour,
               // time lapse, weather), p2 = (landscape, glow, dither); colorA grass, colorB
               // sunlight. See meadow_scene in Meadow_funcs.h. Only the fallback, and only the
               // clear sky (as cases 59 and 67): WeatherLink binds fx_meadow_<n> / fx_wx_meadow_<n>
               // (Weather_fragment.h), and the weather copy here would weigh on every effect.
        return meadow_scene(uv, res, px, t, u, false);
    }
