//  Studio2_cases.h — ZEN GARDEN (shader id 68). Included inside fx_fragment's switch.

    case 68: { // ZEN GARDEN — a little rake cart re-raking a dry garden (karesansui) of pale
               // gravel, stones and moss, seen from above in raking light. Stateless: a pure
               // function of t, clock and date. See studio2_scene in Studio2_funcs.h; the
               // cart's path and the stones arrive in slot 6 (SandGarden in Studio2.swift).
               // p0 = (speed, pattern, rake width, framing), p1 = (relief, light angle,
               // light height, follow the sun); colorA wood, colorB gravel.
        return studio2_scene(uv, res, px, t, u, textAtlas);
    }
