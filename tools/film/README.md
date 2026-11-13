# tools/film — photoreal looping film scenes (Blender)

`dsfilm` is DotStudio's toolkit for building photoreal scenes in Blender 5.1 entirely from Python
and rendering them as seamless video loops for the saver and the wallpaper. A scene is a Python
module plus a JSON spec. This README is written for an LLM (for example, the DotStudio MCP add-in)
that builds and renders its own scenes with the toolkit. It covers what to call, what it costs,
and the rules that keep the Mac usable.

Commute (`scenes/commute/`) is the first scene: a Japanese commuter-train interior with a penguin
in a suit dozing on the end seat.

## Rules (read first)

- **Run Blender headless only:** `Blender -b --factory-startup --python …`. Never open its UI.
- **One Blender process at a time.** This is a 24 GB Mac, and a Cycles render running next to
  another Blender process or a build has crashed it. Always `nice -n 10`. Long renders go in the
  background, one after another.
- **No windows, sounds or screen captures.** Check results by reading the PNGs.
- **Assets are CC0 only** (Poly Haven, ambientCG). They download into
  `~/Library/Caches/DotStudio-film` (override with `$DOTSTUDIO_FILM_CACHE`), never into the repo.
  Every download is logged with its source page and licence in `<cache>/LICENSES.tsv`.
- **Commit only scripts.** No renders, no .blend files, no caches.
- **Keep motion periodic.** Everything that moves must repeat with the loop length, so that
  frame N+1 equals frame 1 (see `dsfilm.loop`).

## Quick start

```sh
B=/Applications/Blender.app/Contents/MacOS/Blender
python3 -I tools/film/fetch.py commute                     # CC0 assets -> cache (run.py also does this)
python3 -I tools/film/scenes/commute/posters.py            # poster textures (Pillow; run.py also does this)
nice -n 10 $B -b --factory-startup --python tools/film/run.py -- tools/film/scenes/commute/commute.json \
    --variant day --stills OUT/                            # the spec's "day" stills -> OUT/<name>.png
nice -n 10 $B -b --factory-startup --python tools/film/run.py -- tools/film/scenes/commute/commute.json \
    --variant golden --still OUT/g.png --camera close --frame 400 --res 800x500 --samples 128   # quick look
nice -n 10 $B -b --factory-startup --python tools/film/run.py -- tools/film/scenes/commute/commute.json \
    --anim OUT/frames --engine eevee                       # the loop as PNG frames (resumable)
python3 -I tools/film/dsfilm/encode.py OUT/frames OUT/commute-day   # -> .mov (HEVC 10-bit) + -preview.mp4
python3 -I tools/film/dsfilm/encode.py --seam OUT/frames            # loop-seam check (want ratio ~1)
```

## The CLI and its output (what the MCP server calls)

```
Blender -b --factory-startup --python tools/film/run.py -- SPEC.json
    (--stills DIR | --still FILE | --anim DIR [--frames A-B] | --build-sequence DIR)
    [--variant V] [--camera C] [--frame N] [--engine cycles|eevee] [--res WxH] [--samples N]
    [--no-post] [--save F.blend]
```

| Mode | Output |
|---|---|
| `--stills DIR` | Renders the spec's stills for the variant to `DIR/<name>.png`, with the look baked in. Also writes `<name>-grain.png` (preview grain, if the look has `grain`) and `<name>-nopost.png` (if the still has `"compare": true`). |
| `--anim DIR` | Writes `DIR/####.png`. Frames already on disk are skipped, so it is resumable. The look is baked in; grain is not. |
| `--build-sequence DIR` | The "how it's made" set for one camera. See the table below. |

The build sequence writes:

| File | What it shows |
|---|---|
| `1-clay.png` | Every surface except glass and lamps in neutral clay |
| `2-materials.png` | Fast flat light (EEVEE, no ray tracing, shadows or GI) |
| `3-raytraced.png` | Full Cycles, no post |
| `4-graded.png` | The look, plus `4-graded-grain.png` |

Machine-readable lines come on stdout; everything else is Blender's own log:

```
PROGRESS {"stage":"build","done":1,"of":1,"elapsed_s":26.8}
PROGRESS {"stage":"sample","of_what":"day_wide","done":128,"of":384}
PROGRESS {"stage":"frame","frame":12,"done":12,"of":1152,"frame_s":9.8,"eta_s":11172}
RESULT {"ok":true,"outputs":[...],"timings":{"build_s":..,"<file>":..,"s_per_frame":..,"total_s":..},"variant":"day","camera":"wide","spec":"..."}
RESULT {"ok":false,"error":"..."}          # exit code 1
```

`stage` is one of `fetch`, `build`, `still`, `sample` or `frame`.

## Packaging (the "film" engine pack)

`tools/film/package.sh [OUT]` zips the following into `film-engine-<version>.zip` and writes its
`.sha256` and an index entry (`{"id":"film","kind":"film","version","file","bytes","sha256"}`):

- `dsfilm/`
- `run.py` and `fetch.py`
- the templates (`scenes/*`)
- `engine.json`
- this README, as `guide.md`

Caches, renders and .blend files are never included. Assets are fetched on the user's Mac from CC0
sources.

## The spec (JSON)

```json
{
  "scene": "commute",                         // tools/film/scenes/<scene>/scene.py
  "variant": "day",                           // lighting preset (see dsfilm.lighting)
  "loop": {"seconds": 48, "fps": 24},
  "params": {"penguin_color": [0, 0.3, 0.47], "sway": 1.0,
             "lighting": {"day": {"sun_elev": 17}}},  // per-variant preset overrides
  "render": {"engine": "cycles", "res": [1600, 1000], "samples": 384, "exposure": 0.0},
  "look": {"bloom": {"strength": 0.08, "threshold": 3.0, "size": 0.55},            // dsfilm.post
           "halation": {"strength": 0.35, "threshold": 2.0, "size": 0.22, "tint": [1, 0.32, 0.1]},
           "vignette": 0.22, "grain": {"amount": 0.018}},                          // grain: stills preview only
  "stills": [{"name": "day_wide", "camera": "wide", "frame": 1, "variant": "day", "compare": true}],
  "animation": {"camera": "wide", "engine": "eevee", "res": [2560, 1600], "samples": 64}
}
```

## Writing a scene

Create `scenes/<name>/scene.py` and `scenes/<name>/assets.json`. The scene module provides:

```python
ASSETS = [...]            # refs from assets.json: "ph:hdri:<id>", "ph:tex:<id>", "ph:model:<id>", "acg:<id>"
VARIANTS = ["day", ...]   # lighting presets it supports
CAMERAS = ["wide", ...]
def prepare(): ...        # optional plain-python pre-step (e.g. Pillow textures via subprocess)
def build(ctx) -> {"cameras": {name: camera_object}, ...}
```

`ctx` provides:

| Field | What it is |
|---|---|
| `ctx.scene` | the bpy scene |
| `ctx.loop` | the `Loop` |
| `ctx.variant` | the variant name |
| `ctx.light` | the variant's preset dict (exposure, night/rain flags, sun angles, …) |
| `ctx.params` | the spec's `params` |
| `ctx.rng` | a seeded `random.Random` |
| `ctx.coll(name)` | makes a new collection |

The scene's own folder is on `sys.path`, so a scene can split itself into modules (as Commute
does).

## Toolkit API (`dsfilm`)

| module | call | notes |
|---|---|---|
| `assets` | `fetch(ref)`, `fetch_all(refs)`, `missing(refs)`; paths `hdri(id)`, `tex(id, "diff"/"nor_gl"/"rough")`, `model(id)`, `acg(id, "Color"/"NormalGL"/"Roughness"/"Emission")` | curl + md5, cache, licence log; works without Blender |
| `materials` | `principled(name, color, rough, metal, **inputs)`, `pbr(...)`, `ph_pbr(name, id, size_m, tint=, desat=)`, `acg_pbr(...)`, `noise_bump(mat, scale, strength, rough_var)`, `emission`, `image_mat(name, png)`, `thin_glass(name, refl, rain=)` | box-projected object coordinates at real-world scale (no UVs); keep object scale 1. `desat=True, tint=(r,g,b)` recolours a scan |
| `geometry` | `box`, `tube` (polyline), `smooth_tube` (bezier, `taper`), `slab(loops, depth)` (2D outline with holes, extruded; walls and doors), `rrect`, `plane_uv` (posters), `sphere`, `empty`, `instance`, `append_collection(blend, name)`, `no_shadow(obj)`, `look_at(obj, frm, to)` | metres, Z up; everything returns the object |
| `lighting` | `setup(scene, coll, "day"/"golden"/"night"/"rain", **overrides)` → `.sun`, `.mapping` (sky rotation), `.params`; `sun_euler(elev, az)` | the HDRI's own sun is clamped out and a sun lamp gives the direct light, so you choose its direction |
| `loop` | `Loop(seconds, fps)`: `.t(frame)`, `.wave(t, k, phase)` (k whole cycles per loop), `.fit(period)`, `.pulse_train(t, period, fn, offsets)`, `.bake(objects, fn)` (keyframes fn(t) every frame, linear), `.scroll(obj, distance)` (linear, extrapolated for motion blur), `Loop.strip(tile, coll, period, root, mirror_y=, mirror_scale_z=)`; `smoothstep`, `bump` | scenery: build one `period` of it into a collection that isn't linked to the scene, `strip` it, then `scroll` the root by `-period` |
| `render` | `setup(scene, engine, res, samples, exposure, motion_blur)`, `still(scene, path, frame, camera)`, `frames(scene, dir, a, b, camera)` | AgX Medium High Contrast; Cycles on Metal with OIDN, 1024-px tiles, textures capped at 2048 (memory); EEVEE ray-traced |
| `post` | `setup(scene, look)`, `enable(scene, on)`, `grain_preview(src_png, dst_png, amount)` | The spec's `look` block, baked in Blender 5's compositor: halation (warm glow around highlights), bloom, vignette. Thresholds are in scene-linear units before exposure (2–3 catches only real highlights). Grain is never baked into video; the app adds it at playback. |
| `geometry.Batch` | `Batch(name, coll)`: `.box(size, loc, mat, rot_z)`, `.cylinder(r, h, loc, mat)`, `.poly(verts, faces, mat, loc)`, `.finish()` | Thousands of parts merged into one mesh per material (a city is a few dozen objects) |
| `materials.facade_grid` | `facade_grid(name, wall, glass, pitch, floor_h, win_w, win_h, sill, curtain_prob, lit, lit_prob)` | A procedural building wall with recessed windows, curtains and, at night, lit rooms; no textures needed |
| `encode` | `encode(frames_dir, out_base, vignette=0.35, grain=0)`, `seam(frames_dir)` | HEVC main10 `hvc1` via VideoToolbox, plus an H.264 preview |
| `spec` | `load(path)`, `scene_module(name)`, `build(spec, variant, engine, res, samples)` | what run.py uses |

### Lighting presets

| preset | sky (Poly Haven HDRI) | sun | exposure |
|---|---|---|---|
| day | kloofendal_48d_partly_cloudy_puresky | 17°, 4.0 | +1.8 |
| golden | qwantani_sunset_puresky, sky tinted warm (`sky_tint`) | 9°, 3.2, orange | +1.6 |
| night | kloppenheim_07_puresky ×0.10 | off | +3.5 |
| rain | kloofendal_overcast_puresky | off | +1.8 |

The units are physical. The sun is about 4 W/m², the sky's horizontal irradiance is about 1.5,
and cabin lamps are a few hundred lux (an area light of about 1 W per 2.5 m of strip, with the
diffuser emitting at about 1.5). Interiors lit through windows therefore need roughly +1.5 to +2
EV by day and +3 to +4 EV at night, which is what the presets set. Don't brighten the lamps to
light the interior: that flattens the sun patches.

## Budgets (M5 Pro, 16-core GPU, 24 GB)

| What | Cost |
|---|---|
| Building Commute | ~12 s; about 2,000 objects |
| First Cycles render after a fresh start | +~60–90 s of Metal kernel compile (cached afterwards) |
| Cycles still, 1600×1000, 384 samples (adaptive + OIDN) | 52–68 s per frame (day_wide 52 s, day_close 68 s, golden_wide 57 s, night_wide 67 s), plus ~25 s of build/sync per process |
| Cycles still, 800×500, 128 samples (iteration) | ~8 s |
| EEVEE (ray traced), 800×500, 16 samples | ~30–40 s for the first frame, including shader compile |
| Commute loop | 48 s × 24 fps = 1152 frames |

The EEVEE animation and Cycles animation per-frame costs have not been measured yet. Measure them
on 24 frames before committing to a full render: at 2560×1600, 1152 Cycles frames would take
roughly 1–2 minutes each, i.e. a day or more.

## Commute scene

### Files

| File | Contents |
|---|---|
| `scene.py` | build, cameras (wide / close / aisle), all motion |
| `carriage.py` | the car, at real scale |
| `city.py` | the scenery tile on a viaduct |
| `penguin.py` | the passenger |
| `posters.py` | original posters, a route map, an LCD screen and signs (fictional brands; Pillow + Hiragino) |
| `commute.json` | the spec |
| `assets.json` | the CC0 assets the scene uses |

### Loop

48 s at 24 fps. The scenery strip is 650 m (26 rails of 25 m), scrolled exactly one strip per
loop, so the train runs at about 49 km/h.

Everything else that moves is built from whole-number harmonics of the loop:

- rail-joint "ta-tan" bumps
- carriage sway and roll (cameras)
- strap swing
- the sun's bearing (the line curving)
- breathing (11 breaths per loop)
- one dozing cycle per loop: he drifts off, jerks awake at 17 s with his eyes open and a blink,
  drifts off again, gives a heavy nod at 33 s, and settles

### Penguin design

Our own character, in generic penguin-cartoon vocabulary:

- one continuous chubby egg/pear body, with no separate head and a rounded crown (no pointed peak)
- teal, with a big white belly that stops at the chest
- gentle eyes set straight into the teal (no white face mask): small, set deep so the lids close flush,
  with big dark pupils, a soft catch-light and a thin lash line; sleepy half-lids when he stirs
- a wide, tapering orange bill with a smile
- short flipper wings out at the sides
- chunky flat feet
- a dark charcoal suit with cloth folds, a collar and a red tie

The head nods with a two-bone armature that bends the top of the egg.

What you can change without code (colours, variants, loop, cameras) is listed in
`scenes/commute/README.md`.

### Assets (all CC0)

Poly Haven:

- HDRIs: kloofendal_48d_partly_cloudy_puresky, qwantani_sunset_puresky, kloppenheim_07_puresky,
  kloofendal_overcast_puresky
- textures: velour_velvet, poly_wool_herringbone, asphalt_02, concrete_wall_008
- models: jacaranda_tree, shrub_02, shrub_04

ambientCG:

- Facade001, Facade005, Facade006, Facade009, Facade012, Facade014, Facade015, Facade016,
  Facade018A, Facade018C, Facade019A, Facade019C, Facade020A, Facade020C
- Gravel022, Grass004, RoofingTiles006

Houses and apartment blocks use the procedural `facade_grid` instead of textures.

The pages are `https://polyhaven.com/a/<id>` and `https://ambientcg.com/view?id=<id>`. The exact
list, with download dates, is in `<cache>/LICENSES.tsv` (`python3 -I tools/film/fetch.py --licences`).
