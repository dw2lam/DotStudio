//  Custom_cases.h — the Custom Scene's stand-in (EffectKind.custom, id 90). Included inside
//  fx_fragment's switch.
//
//  A custom scene is drawn by its package's own pipeline, compiled at runtime (CustomScenes.swift,
//  CustomSceneLink binds it over this one). This case draws while that pipeline compiles, and in
//  place of one that can't: a package that's missing, fails to compile, or faulted on the GPU.
//  Calm on purpose — the style's colour A, falling to a deeper shade of it — so a broken scene
//  never flashes or shows garbage on a screensaver.

    case 90: {
        float3 top = srgbToLinear(saturate(u.colorA.rgb));
        float3 bottom = top * 0.32;
        float k = smoothstep(0.0, 1.0, uv.y);              // uv.y = 0 at the top
        float3 c = mix(top, bottom, k);
        return float4(saturate(linearToSrgb(c) + bandDither(px)), 1.0);
    }
