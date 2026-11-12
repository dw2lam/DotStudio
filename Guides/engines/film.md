# Engine: film (photoreal, ray-traced scenes)

Placeholder. The film engine is DotStudio's Blender toolkit (`dsfilm`). Pull it with `pull_engine("film")`; its `guide.md` (the scene-spec schema, asset catalogue and examples) replaces this page when installed. Check `film_status` first.

## What it makes

A film scene is a real 3D set (CC0 assets, real materials and light) rendered with Cycles into seamless video loops — one per variant: `day`, `golden`, `night`, `rain` — that DotStudio plays as a scene and switches with the sun and the weather. Think: a rainy café window at night, a reading nook at golden hour, a harbour at dusk.

## Workflow

1. `film_status`: Blender installed? Film engine pulled? Which GPU?
2. `create_film_scene(spec)`: a scene spec in the toolkit's format (camera, set, assets, lighting, a motion that loops: rain on glass, steam, drifting light — never a camera move that has to "come back").
3. `render_film_stills(draft)`: Cycles stills per variant. Show them and get the user's approval of the base scene BEFORE animating.
4. `render_film_loop(draft)`: a background job (Blender headless, nice'd; survives the chat ending). Poll `film_job_status`; `cancel_film_job` stops it.
5. When done it's installed as a scene: `create_style(effects: [{"kind": "custom", "scene": "<id>"}])`.

## Costs — tell the user

- Renders are long: tens of minutes to hours per loop on Apple silicon; stills take a minute or two.
- Files are big: hundreds of MB per scene (HEVC clips at 4K).
- Playback is cheap (video decode), so film scenes suit the live wallpaper better than heavy shaders.

## Taste

Same rules as `style/dotstudio`: calm, slow, lived-in, not a tech demo. One idea per scene; motion that you could watch for an hour; no lens flares, no glossy CG sheen.
