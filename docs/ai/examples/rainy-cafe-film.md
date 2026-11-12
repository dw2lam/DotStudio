# A photoreal rainy café window (film scene)

> **You:** Can you make a photoreal one — looking out of a café window at night while it rains?

_Film scenes arrive with the film engine (DotStudio's Blender toolkit). This session was recorded against the self-test's stand-in toolkit: the job flow, progress and install are real; the stills it returned were placeholders, so they aren't shown._

```
→ film_status({})
```
```text
Blender: /fake/Blender (Blender 4.5.0 (test)). Film engine: not pulled (pull_engine "film"). GPU: Apple M5 Pro.
test toolkit
```

**Assistant:** This needs Blender and the film engine, a render of roughly an hour, and a few hundred MB. Shall I go ahead?

> **You:** Go ahead.

```
→ pull_engine({"id": "film"})
```
```text
Installed engine film v1. Read its guide: read_guide("engines/film").
```

```
→ read_guide({"id": "engines/film"})
```
```text
# Engine: film (photoreal, ray-traced scenes)

Placeholder. The film engine is DotStudio's Blender toolkit (`dsfilm`). Pull it with `pull_engine("film")`; its `guide.md` (the scene-spec schema, asset catalogue and examples) replaces this page when installed. Check `film_status` first.

## What it ma …
```

```
→ create_film_scene({"spec": {"scene": {"set": "cafe-window", "camera": {"lens_mm": 35, "height_m": 1.2, "look": "street"}, "assets": ["cc0:polyhaven/wooden_table_02", "cc0:polyhaven/coffee_cup", "cc0:ambientcg/Glass_Rain"], "lighting": {"interior": "warm tungsten 2700K, low", "exterior": "sodium street lamps, wet asphalt"}, "motion": [{"type": "rain_on_glass", "loop": true}, {"type": "steam", "source": "coffee_cup", "loop": true}, {"type": "passing_headlights", "every_s": 14}]}, "variants": ["night", "rain"]}, "name": "Rainy Café"})
```
```text
Saved film draft film-dcbf190c. Next: render_film_stills(draft: "film-dcbf190c") and show the stills to the user before animating.
```

```
→ render_film_stills({"draft": "film-dcbf190c", "variants": ["night", "rain"], "samples": 64, "wait_seconds": 30})
```
```text
stills-dd325407: done, 100% — stills sample 10/10. 2 still(s): night, rain. Show them to the user; when the base scene is approved, render_film_loop.
```

**Assistant:** Here are the base stills. Happy with the framing and the light before I animate it?

> **You:** Love it. Animate it.

```
→ render_film_loop({"draft": "film-dcbf190c", "variants": ["night", "rain"], "seconds": 20, "fps": 24})
```
```text
Started loop-e1552998 (night, rain). It runs in the background; check film_job_status(job: "loop-e1552998").
```

```
→ film_job_status({"job": "loop-e1552998"})
```
```text
loop-e1552998: running, 40% — loop sample 4/10, about 0 min left.
```

```
→ film_job_status({"job": "loop-e1552998"})
```
```text
loop-e1552998: done, 100% — loop sample 10/10. Installed film scene film-dcbf190c-7ba5b5fd: create_style(effects: [{"kind": "custom", "scene": "film-dcbf190c-7ba5b5fd"}]).
```

```
→ create_style({"name": "Rainy Café", "fps": 24, "effects": [{"kind": "custom", "scene": "film-dcbf190c-7ba5b5fd"}]})
```
```text
Created “Rainy Café” (67B42AA9-538A-47A8-8BD2-0395AA7AE676). DotStudio isn't running: library.json was updated; the app shows it next time it opens.
Next: preview_style(style: "67B42AA9-538A-47A8-8BD2-0395AA7AE676") — and a contact sheet over time (frames: 6) to check the motion.
```
