//  Studio6_cases.h — new-scene slot 6. Included inside fx_fragment's switch.

    case 72: { // DIAL CLOCK (scene) — a lit watch dial filling the screen: sunray or grained dial,
               // faceted applied batons, dauphine hands and a sweeping seconds hand, all casting
               // shadows from one soft key light that follows the time of day.
               // p0 = (finish, hands metal, 24-hour ring, seconds), p1 = (date, size, shine,
               // follow the sun); colorA dial, colorB seconds hand. See Studio6_funcs.h.
        return float4(studio6_dialClock(px, res, t, u, textAtlas, samp), 1.0);
    }
