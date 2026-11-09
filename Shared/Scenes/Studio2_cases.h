//  Studio2_cases.h — SAND GARDEN (shader id 68). Included inside fx_fragment's switch.

    case 68: { // SAND GARDEN — a chrome ball ploughing slow theta-rho patterns through a round
               // kinetic sand table, seen from above under a low raking light. Stateless: a
               // pure function of t, clock and date. See studio2_scene in Studio2_funcs.h.
               // p0 = (speed, pattern, groove width, framing), p1 = (relief, light angle,
               // light height, follow the sun); colorA wood, colorB sand.
        return studio2_scene(uv, res, px, t, u);
    }
