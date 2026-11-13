# A photoreal rainy café window (film scene)

> **You:** Can you make a photoreal one — looking out of a café window at night while it rains?

_Making film scenes needs DotStudio's film toolkit (Blender), which isn't in DotStudio yet. This session ran against the self-test's stand-in toolkit with DotStudio's real film engine: the job flow, packaging, install and playback are real; its stills and clips are placeholders, so they aren't shown, and the scene module below is illustrative — it has not been run in Blender._

```
→ film_status({})
```
```text
Blender: /Applications/Blender.app/Contents/MacOS/Blender (5.1.0). Film toolkit: installed v1. GPU: Apple M5 Pro.
test toolkit
Steps: list_film_templates → create_film_scene → render_film_stills (approve) → render_film_loop → film_job_status → create_style.
```

**Assistant:** Blender 5.1 is installed. This uses DotStudio's film toolkit: about a minute per approval still, then a background render of a few hours for a 24-second loop, and roughly 300 MB for the two variants (night, rain). Go ahead?

> **You:** Go ahead.

```
→ read_guide({"id": "film"})
```
```text
# Film scenes: the Blender toolkit (photoreal, ray-traced)

A film scene is a real 3D set — CC0 assets, physical materials and light — built in Blender by DotStudio's film toolkit (`dsfilm`), rendered with Cycles/EEVEE into seamless video loops (one per variant: `day`, `golden`, `night`, `rain`), an …
```

```
→ list_film_templates({})
```
```text
- commute: A Japanese commuter-train interior at real scale, city scrolling past on a viaduct; an original penguin in a suit dozes on the end seat.
```

**Assistant:** The only template is Commute (a train interior), so I'll write a new set with the toolkit: a café corner looking out through a rain-streaked window at a wet street. All assets CC0 (Poly Haven / ambientCG); every motion is a whole number of cycles per 24-second loop so it repeats seamlessly; the sign outside stays dim.

```
→ create_film_scene({"spec": {"scene": "local", "variant": "night", "loop": {"seconds": 24, "fps": 24}, "render": {"engine": "cycles", "res": [1600, 1000], "samples": 384, "motion_blur": true}, "stills": [{"name": "night_wide", "camera": "wide", "frame": 1, "variant": "night"}, {"name": "rain_wide", "camera": "wide", "frame": 1, "variant": "rain"}], "animation": {"camera": "wide", "engine": "eevee", "res": [2560, 1600], "samples": 64}}, "name": "Rainy Café", "variants": ["night", "rain"], "look": {"bloom": 0.3, "halation": 0.35, "grain": 0.25}, "scene_files": {"scene.py": "…below…", "assets.json": "…below…"}})
```
```text
Saved film draft film-8d225f17 (local, look: bloom 0.3, halation 0.35, grain 0.25). Next: render_film_stills(draft: "film-8d225f17") and show the stills to the user before animating.
```

`scene_files["scene.py"]`:

```python
"""Rainy Café — a corner table at a café window, night, rain on the glass. Original set; CC0 assets only."""
from dsfilm import geometry as G, materials as M, lighting as L, loop as LP

ASSETS = ["ph:hdri:kloppenheim_07_puresky", "ph:tex:wood_table_001", "ph:tex:concrete_wall_008",
          "ph:model:coffee_cup_01", "acg:Asphalt012", "acg:Facade005"]
VARIANTS = ["night", "rain"]
CAMERAS = ["wide", "close"]

def build(ctx):
    c = ctx.coll("cafe")
    loop = ctx.loop                                            # 24 s at 24 fps: everything below repeats exactly
    table = G.box("table", (1.2, 0.7, 0.04), (0, 0.9, 0.74), c)
    table.data.materials.append(M.ph_pbr("oak", "wood_table_001", 0.8))
    cup = G.instance("cup", "coffee_cup_01", (0.15, 0.85, 0.78), c)
    wall = G.slab([[(-2, 0), (2, 0), (2, 2.6), (-2, 2.6)], [(-1.3, 0.9), (1.3, 0.9), (1.3, 2.3), (-1.3, 2.3)]], 0.2)
    wall.data.materials.append(M.ph_pbr("plaster", "concrete_wall_008", 2.0, desat=True, tint=(0.82, 0.74, 0.66)))
    glass = G.box("pane", (2.6, 0.01, 1.4), (0, 1.6, 1.6), c)
    glass.data.materials.append(M.thin_glass("window", 0.06, rain=1.0 if ctx.light.get("rain") else 0.6))
    street = G.box("street", (40, 30, 0.1), (0, 18, -0.4), c)
    street.data.materials.append(M.acg_pbr("wet asphalt", "Asphalt012", 4.0, rough=0.08))
    L.setup(ctx.scene, c, ctx.variant, exposure=3.3)
    lamp = G.sphere("pendant", 0.08, (0.1, 0.8, 1.9), c)
    lamp.data.materials.append(M.emission("tungsten", (1.0, 0.62, 0.32), 6.0))
    # steam: three wisps rising and fading, one full cycle each per loop, phase-offset
    for i in range(3):
        w = G.smooth_tube(f"steam{i}", [(0.15, 0.85, 0.80), (0.16, 0.86, 0.95), (0.13, 0.84, 1.1)], 0.01, c, taper=True)
        loop.bake([w], lambda t, i=i: {"scale": 0.6 + 0.4 * loop.wave(t, 1, i / 3), "alpha": 0.25 * loop.wave(t, 1, i / 3)})
    # a car's headlights sweep the wall twice per loop (period 12 s divides 24 s)
    sweep = G.empty("headlights", (0, 12, 0.6), c)
    loop.pulse_train(sweep, 12.0, lambda u: {"x": -20 + 40 * u, "energy": 400 * LP.bump(u, 0.5, 0.35)}, offsets=[0])
    cams = {"wide": G.look_at(G.empty("cam_wide", (0, -1.6, 1.35), c), (0, -1.6, 1.35), (0, 2.0, 1.2)),
            "close": G.look_at(G.empty("cam_close", (0.5, 0.2, 1.05), c), (0.5, 0.2, 1.05), (0.1, 0.9, 0.85))}
    return {"cameras": cams}
```

```
→ render_film_stills({"draft": "film-8d225f17", "wait_seconds": 30})
```
```text
stills-e8fc3a66: done, 100% — stills sample 10/10. 2 still(s): night, rain. Show them to the user; when the base scene is approved, render_film_loop.
```

**Assistant:** Here are the night and rain stills. Happy with the framing and the light before I animate it? (Halation is up at 0.35 for the tungsten lamp against the dark window; grain is added live, so it won't repeat with the loop.)

> **You:** A touch brighter, a little less bloom. Then animate it.

```
→ update_film_scene({"draft": "film-8d225f17", "look": {"bloom": 0.2}, "spec_patch": {"render": {"exposure": 0.3}}})
```
```text
Updated film draft film-8d225f17 (local, look: bloom 0.2, halation 0.35, grain 0.25). Next: render_film_stills(draft: "film-8d225f17") and show the stills to the user before animating.
```

```
→ render_film_loop({"draft": "film-8d225f17"})
```
```text
Started loop-bb439d25 (night, rain). It runs in the background; check film_job_status(job: "loop-bb439d25").
```

```
→ film_job_status({"job": "loop-bb439d25"})
```
```text
loop-bb439d25: running, 40% — loop sample 4/10, about 0 min left.
```

```
→ film_job_status({"job": "loop-bb439d25"})
```
```text
loop-bb439d25: done, 100% — loop sample 10/10. Installed film scene film-8d225f17-6e58f0eb: create_style(effects: [{"kind": "custom", "scene": "film-8d225f17-6e58f0eb"}]).
```

```
→ create_style({"name": "Rainy Café", "fps": 24, "effects": [{"kind": "custom", "scene": "film-8d225f17-6e58f0eb", "params": {"ds.grain": 0.25}}]})
```
```text
Created “Rainy Café” (3E3598B6-7210-4152-9B2C-F15C5B70FC65). DotStudio isn't running: library.json was updated; the app shows it next time it opens.
Next: preview_style(style: "3E3598B6-7210-4152-9B2C-F15C5B70FC65") — and a contact sheet over time (frames: 6) to check the motion.
```

**Assistant:** “Rainy Café” is in your library. It's video, so it's light on the GPU — a good live wallpaper too.
