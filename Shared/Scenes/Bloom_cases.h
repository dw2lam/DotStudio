//  Bloom_cases.h — the Bloom pack (Bloom.swift). Included inside fx_fragment's switch.

    case 79: { // BLOOM — one procedural flower (blue poppy, baby's breath, white anemone) set in
               // a grid of glyphs or LED cells over a smooth sky, swaying at 24 fps.
               // p0 = (flower, render, cell size, breeze), p1 = (sky gradient, glow, captions,
               // size); colorA the sky's top, colorB the petals. See Bloom_funcs.h.
        return float4(bloom_scene(px, res, t, u, textAtlas, samp), 1.0);
    }
