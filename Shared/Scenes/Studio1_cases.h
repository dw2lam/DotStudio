//  Studio1_cases.h — `case 67` (SHALLOWS) for new-scene slot 1. Included inside fx_fragment's switch.

    case 67: { // SHALLOWS — clear knee-deep water over rippled sand, netted with caustics.
               // p0 = (speed, depth, sea state, clarity)  p1 = (sun height °, follow the sun,
               // time lapse, clouds); colorA sand, colorB sunlight. See Studio1_funcs.h.
        return studio1_shallows(uv, res, px, t, u);
    }
