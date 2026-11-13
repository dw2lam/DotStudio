# Engine: film (photoreal, ray-traced scenes)

A film scene is a real 3D set — CC0 assets, physical materials and light — built in Blender by DotStudio's film toolkit (`dsfilm`), rendered with Cycles/EEVEE into seamless video loops (one per variant: `day`, `golden`, `night`, `rain`), and played by DotStudio as a scene that follows the sun and the weather. This page is the contract for an AI driving it through the MCP tools. When the film engine is pulled, its own `guide.md` (the full spec schema and each template's params) is listed as well; read both.

## The flow (every step is a tool)

1. `film_status` — Blender installed and new enough? Film engine pulled? Which GPU? If Blender is missing or too old, pass its install steps to the user **word for word and stop**: DotStudio never installs Blender, and you must not either (no scripts, no Homebrew, no downloads on the user's behalf). The user downloads Blender 5.1+ for Apple Silicon from blender.org, drags it to Applications, opens it once and quits.
2. `pull_engine("film")` — the toolkit pack (Python + scene templates + this guide; no native code). Tell the user first.
3. `list_film_templates` — start from a template. **Commute** is the first: a Japanese commuter-train interior at real scale, the city scrolling past on a viaduct, an original penguin in a suit dozing on the end seat. Templates list their params, cameras, variants and loop length.
4. `create_film_scene(template, params, variants, loop_seconds, look)` — a draft. Edit later with `update_film_scene` (`spec_patch` deep-merges into the spec) and read it back with `get_film_scene`.
5. `render_film_stills(draft)` — ray-traced stills per variant, returned as images. **Show them to the user and get an explicit yes on the base scene before animating.** Iterate on stills (cheap) — never on loops (expensive).
6. `render_film_loop(draft)` — a background job: Blender headless at low priority, one at a time, survives the chat ending. Returns a job id at once. Confirm the cost with the user first.
7. `film_job_status(job)` — progress, ETA and the log's tail; poll every few minutes, not in a tight loop. `cancel_film_job` stops it. When it finishes, the clips are packaged and installed as a scene and the status returns its id.
8. `create_style(effects: [{"kind": "custom", "scene": "<id>", "params": {"grain": 0.2}}])`, `preview_style`, and only if the user asks, `set_screensaver` / `set_wallpaper`.

## The look

`create_film_scene` / `update_film_scene` take a `look` block — first-class, always set it deliberately:

| Key | Range | Default | What it does | Applied |
|---|---|---|---|---|
| `bloom` | 0–1 | 0.25 | Soft glow around bright lights (lamps, sun on glass). Above 0.5 reads as cheap "dreamy". | at render |
| `halation` | 0–1 | 0.15 | The warm red-orange glow film stock gives bright edges against dark. Lovely at night and golden; keep ≤ 0.2 by day. | at render |
| `grain` | 0–1 | 0.2 | Live film grain added by DotStudio while it plays — never baked into the clips, so it never repeats with the loop. The package carries it as the default; the style's `grain` param overrides it. 0.1–0.3 is natural; 0 looks like CG. | at playback |

## Budgets (Apple Silicon, M5 Pro 16-core GPU, 24 GB — scale up for smaller GPUs)

| Work | Cost |
|---|---|
| First Cycles render after a restart | +60–90 s compiling Metal kernels (cached afterwards) |
| Building a template scene (Commute) | ~12 s, ~2,000 objects, plus ~25 s build/sync per Blender process |
| Cycles still 800×500, 128 samples (iteration) | ~8 s |
| Cycles still 1600×1000, 384 samples (approval) | 50–70 s each |
| EEVEE ray-traced loop frame 2560×1600 | measure on 24 frames first; expect tens of seconds per frame |
| A 48 s loop at 24 fps | 1,152 frames per variant: hours in EEVEE, a day or more in Cycles |
| Clip size | HEVC 10-bit 2560×1600, 25–40 Mb/s: 150–250 MB per variant per 48 s; four variants ≈ 0.6–1 GB |

Rules: quick stills at 800×500/128 while iterating; approval stills at full size; loops in EEVEE unless the user asks for Cycles and accepts a day-long render; render only the variants the user wants. Never run two renders at once (the job runner queues; don't start a second job while one runs). Tell the user the expected time and disk use before every loop.

## Assets: CC0 only, logged

- Only CC0 sources: Poly Haven (`https://polyhaven.com/a/<id>`) and ambientCG (`https://ambientcg.com/view?id=<id>`). No "free for personal use", no marketplace models, no scraped images, no logos.
- Every download is recorded with its source page and licence in the toolkit's licence log (`LICENSES.tsv` in the film cache); a scene whose assets aren't all in the log doesn't ship.
- Text, signs, posters and screens in a scene are original: fictional brands and route names (Commute draws its own posters).

## Seamless loops

- Everything that moves repeats exactly with the loop: frame N+1 equals frame 1. Use whole-number cycles per loop (`loop.wave(t, k)` with integer `k`), scenery scrolled by exactly one tile per loop, periodic events (`pulse_train`) whose period divides the loop.
- No camera move that has to "come back"; the camera holds or sways periodically.
- Prefer several incommensurate-looking but whole-number motions (e.g. 11 breaths, 26 rail joints, one doze per loop) so the loop never reads as a loop.
- Changing `loop_seconds` changes every period: re-check with stills at frames 1 and N/2 and let the toolkit's seam check run.

## Burn-in and static elements

A film scene is mostly static set; that's fine — light, reflections and passing scenery move. But: no bright static UI-like elements (an LCD sign at full white, a logo on a wall); keep emissive signs dim and let something cross or flicker them; avoid pure-white sky patches that sit for minutes; the live grain also breaks up static pixels. See `burn-in`.

## Characters: original only

Characters must be original. "Inspired by" is fine — a dozing commuter penguin, a cat on a windowsill — but never reproduce a specific trademarked or copyrighted character's distinctive design, costume, colours or name (no Pingu, Club Penguin, Pikachu, Hello Kitty, Totoro…), and never a real person's likeness. If the user asks for one, offer an original character in the same spirit and say why. Commute's penguin is the model: its own head shape, eye placement, colouring, bill and suit, documented in the template.

## Taste

The same as `style/dotstudio`: calm, lived-in, quiet light, one idea per scene, motion you could watch for an hour. Not a tech demo: no lens flares, no chrome, no glossy CG sheen, no dramatic camera.
