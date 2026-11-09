//  Studio3_cases.h — `case 69` (PLEATS) for new-scene slot 3. Included inside fx_fragment's switch.
//  p0 = (pleats, depth, breathe, speed)  p1 = (material, light angle °, depth of field, follow the sun)
//  colorA material, colorB light. See studio3_pleats in Studio3_funcs.h.

    case 69: {
        return float4(studio3_pleats(px, res, t, u), 1.0);
    }
