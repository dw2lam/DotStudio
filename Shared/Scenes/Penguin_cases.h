//  Penguin_cases.h — the Penguin pack (Penguin.swift). Included inside fx_fragment's switch.

    case 80: { // WADDLE — a little penguin on an LED panel (or the user's own character), posed
               // by the CPU (WaddleRig.prepare, Penguin.swift: u.scene), drawn as LED dots,
               // rounded cells or glyphs over falling snow, at 24 fps.
               // p0 = (render, cell size, glow, energy), p1 = (snow, size, follow the clock);
               // colorA the penguin, colorB the background; slot 6 the custom character.
        return float4(waddle_scene(px, res, t, u, textAtlas, samp), 1.0);
    }
