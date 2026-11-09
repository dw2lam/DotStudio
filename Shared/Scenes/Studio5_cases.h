//  Studio5_cases.h — new-scene slot 5. Included inside fx_fragment's switch.

    case 71: { // SOAP FILM (scene) — a draining vertical soap film (or an oil slick) in soft
               // light: spectral thin-film interference over a flow-advected thickness field.
               // p0 = (speed, turbulence, drainage, plumes)  p1 = (film 0 soap / 1 oil, scale,
               // light size); colorA ground (velvet / water), colorB light. See Studio5_funcs.h.
        return studio5_soapFilm(uv, res, px, t, u);
    }
