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
python3 -I tools/film/dsfilm/encode.py --web OUT/frames OUT/commute-day --max-mb 4   # -> -web.webm (VP9) + -web.mp4
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

### The job driver (what the MCP server actually runs)

`job.py` is plain python3 (3.9+, no Blender). The MCP server (`DSFilmToolkit`, MCP/FilmToolkit.swift)
runs it detached and `nice`d, one process per job:

```
python3 -I job.py env | templates | validate SPEC.json          # JSON on stdout, instant
python3 -I job.py stills --blender B --spec SPEC --out DIR --work DIR --variants day,night \
    [--res 1280x720] [--samples 64] [--lock FILE] [--dry-run]   # -> DIR/<variant>.png (Cycles)
python3 -I job.py loop --blender B --spec SPEC --out DIR --work DIR --variants day \
    [--seconds 24] [--fps 24] [--res 3840x2160] [--quality draft|standard|final] [--lock FILE] [--keep-frames] [--dry-run]
    # -> WORK/<variant>/frames (resumable) -> DIR/<variant>.mov (HEVC Main10 hvc1, encode.py); frames deleted once encoded
python3 -I job.py loop … --variants layers [--res 1600x1000] [--still-frame N | --frames A-B]
    # the light-layer loop (see "Light layers"): --res is the TILE size (default 1600x1000)
    # -> WORK/layers/tiles/<tile>/####.exr (resumable) -> DIR/layers.mov + DIR/layers.json; EXRs deleted once packed
```

- It runs `run.py` once per variant and turns its `PROGRESS` lines into `{"fraction", "stage", "eta_s"}`
  in the file named by `$DSFILM_PROGRESS`; the last line is `RESULT {…}` (exit 1 on failure).
- One Blender at a time: each Blender process holds an exclusive lock on `--lock`, and it also waits
  while any other process named `Blender` runs on the Mac.
- Quality: `draft` = the spec's animation engine (EEVEE), 16 samples, half size (at least 960 px wide);
  `standard` = the spec's animation engine and samples (EEVEE, 64); `final` = Cycles, 128 samples.
- The `look` may use DotStudio's 0–1 sliders (`{"bloom": 0.25, "halation": 0.15, "grain": 0.2}`, the
  defaults equal `post.DEFAULT`) or `post`'s own blocks; the job converts sliders before rendering.
- A spec with `"scene": "local", "scene_dir": DIR` loads `DIR/scene.py` instead of `scenes/<scene>/`.
- `--dry-run` prints each Blender command line (`BLENDER …`) without running anything.
- Templates are `scenes/<id>/template.json` (name, summary, editable params) next to the spec.
  `templates` also lists each scene's `layers` (its `LAYERS` tiles; empty = no light layers).
- `layers` is a loop kind next to the variants (`--variants layers` or `day,layers`). Its progress
  stages read `layers: tile sky frame 12/576 (300/3456 tile-frames)` with run.py's `eta_s`; then
  `layers: packing frame i/N`. Packing needs numpy: the job uses its own python3 if it has numpy,
  else Blender's bundled interpreter (`Blender.app/Contents/Resources/<ver>/python/bin/python3.x`).
  The RESULT gains `"layers": {"tile": [w, h], "file": …/layers.mov, "manifest": …/layers.json}`.
  `--still-frame N` renders one frame (a relightable still, a one-frame `layers.mov`); `--frames A-B`
  a slice for timing (not a loop).

## Light layers (one render per light source; the app mixes them live)

The contract is `docs/film-layers.md` (DotStudio 1.6, film engine >= 1.1). Light adds up: render the
scene once per light source, and the app mixes those renders with weights from the sun's elevation
and the weather, live — every time of day and every weather from ONE render, changing smoothly
instead of crossfading clips.

| tile | lit by (everything else off; EEVEE probes re-baked per tile) |
|---|---|
| `sun` | the scene's day sun lamp |
| `sun_low` | a second, low sun (the `golden` preset's elevation/azimuth/strength), rendered **white**; the manifest's `tint` colours it |
| `sky` | the world (HDRI) only |
| `cabin` | the scene's own lamps and emitters (every lamp/emitter not claimed by another tile) |
| `city` | the outside's night emitters (lit windows, signs, street lamps, shop fronts) |
| `mask` | not light: glass = 1, else 0 (rain, fog and condensation are drawn live on the glass) |

```
Blender -b --factory-startup --python run.py -- SPEC.json --layers-still PREFIX --frame N [--full]
    # one frame, every tile -> PREFIX-<tile>.exr + PREFIX-layers.json (--full: + all lights, to check additivity)
Blender -b --factory-startup --python run.py -- SPEC.json --layers-anim DIR [--frames A-B]
    # tile by tile -> DIR/<tile>/####.exr (resumable: existing frames are skipped) + DIR/layers-render.json
    [--tiles sun,sky,…] [--tile-samples sky=64,city=16] [--res WxH (default 1600x1000)] [--samples N]
python3 -I dsfilm/layerpack.py pack DIR OUT [--quality 80] [--encoder auto|videotoolbox|x265]
    # -> OUT/layers.mov (3x2 grid, 8 px gutters, HEVC Main10 hvc1) + OUT/layers.json (the manifest's "layers" block)
python3 -I dsfilm/layerpack.py check DIR OUT/layers.mov [--frames 1,12,24]   # decode + compare with the EXRs
```

- Layers render the scene's layered build (`spec.build(…, layers=True)`, `ctx.layers`): the base
  variant's geometry and materials (day: dry streets, day facades) plus every source the tiles need,
  each switchable. Weather that changes geometry or materials (snow, wet streets, water on the
  glass) is not in the layers — see "Choosing" below.
- Everything else is the same for every tile: camera, motion, frame numbers, motion blur. No film
  look (bloom, halation, vignette, fog) and no exposure: half-float EXR, scene-linear Rec.709.
- Order: tile by tile (`sun` frames 1…N, then `sun_low` …), so the probes are re-baked 5 times per
  loop (~2.5 s each), not per frame.
- Packing: per light tile `scale` = the 99.95th percentile of the per-pixel max channel, pooled over
  the loop (an even sample of up to 96 frames), rounded up to 3 digits; `v = clamp(lin/scale, 0, 1)^(1/4)`;
  the mask as is. Tiles sit 8 px apart (manifest `"gutter": 8`; tile i at x = (i%3)·(w+8),
  y = (i//3)·(h+8); video 3w+16 × 2h+8, e.g. 4816×2008 for 1600×1000 tiles), each gutter
  edge-replicated half from each neighbour so 4:2:0 chroma never bleeds between tiles. The atlas
  becomes Y'CbCr **BT.709, video range, 4:2:0 (2x2-averaged chroma)** in numpy (exact), tagged
  BT.709 (matrix, primaries, transfer, `tv` range) — a reader must undo exactly that and apply no
  colour management. (Don't let ffmpeg's swscale convert RGB→YUV untagged: it defaults to BT.601.)
- The manifest needs `"engine": {"id": "film", "version": ">=1.1"}`; FilmPackage (MCP/Film.swift)
  writes it, copies `clips/layers.mov` and puts `layers.json` in as `layers`. For layered packages
  the app applies the whole look live (bloom, halation, vignette, grain) from `look`.
- Reading EXRs outside Blender: ffmpeg's decoder clamps to 0…1 whenever it converts float formats,
  so `layerpack.read_exr` asks for the file's native `gbrpf16le`; it can't read one-channel EXRs, so
  the mask is written RGB.

### Declaring light groups (a scene)

`build(ctx)` returns, when `ctx.layers` is set (see `dsfilm/layers.py`):

```python
out["layers"] = {
    "groups": {"sun": {"lights": [rig.sun]}, "sun_low": {"lights": [low_sun]}, "sky": {"world": True},
               "cabin": {}, "city": {"emitters": city_emitter_materials}},
    "other": "cabin",                  # every lamp / emitting material not listed goes here
    "glass": ["WindowGlass"],          # material names the mask marks as glass
    "tint": {"sun_low": [1.0, 0.52, 0.22]},   # colours of suns rendered white
    # "samples": {"city": 0.25}        # optional per-tile overrides (fraction of --samples, or a count)
}
```

and lists `LAYERS = ["sun", "sun_low", "sky", "cabin", "city", "mask"]` at module level (job.py
reads it without Blender). Emitters are switched through their emission-strength socket (an
Emission node's Strength, a Principled BSDF's Emission Strength, or the constant of a Math MULTIPLY
driving it, as in `materials.facade_grid`); lamps through energy + hide_render; the world through
its Background strength. `lighting.add_sun(coll, name, preset, color=(1, 1, 1))` makes the second
sun; give it the same periodic wobble as the first. Night-only emitters must exist in the layered
build at their night strength (Commute's city builds them whenever `P["layers"]` is set).

### Cost (M5 Pro, measured on Commute, EEVEE, 64 base samples)

| Tile | samples | s / frame, 1600×1000 | s / frame, 960×600 |
|---|---|---|---|
| `sun` | 32 (½) | 12.4 | 11.9 |
| `sun_low` | 32 (½) | ~12.4 | 11.6 |
| `sky` | 64 | 22.6 | 19.1 |
| `cabin` | 64 | 22.2 | 18.9 |
| `city` | 16 (¼) | 6.5 | 5.3 |
| `mask` | 8 (flat emission, no RT/GI/shadows) | ~1 | 0.3 |
| **all six** | | **72–77** (117 with every tile at 64) | **~67** |

- EEVEE's cost here is in the samples, not the pixels: a 960×600 tile costs the same as 1600×1000.
  Lower resolution for "soft" tiles saves nothing; fewer samples do (time is linear in samples,
  ~0.34 s per sample per tile + ~1 s). The 960×600 column is the median over a 24-frame animation
  (frames 1–24, `job.py loop --variants layers --res 960x600 --frames 1-24`); the 1600×1000 one is frame 1.
- Why those samples: the error a tile adds to the mixed picture, in 8-bit display levels (mean / 99th
  percentile) vs every tile at 64 — noise floor: the sky at 64 vs 128 differs by 0.27 / 2.3 by day.
  `sun` at 32: 0.09 / 0.9 (at 16: 0.19 / 2.1). `city` at 16: 0.06 / 1.3 at night (32: 0.03 / 0.6).
  `sky` at 32: 0.43 / 3.7 by day — visible, so 64. `cabin` at 32: 0.57 / 4.1 at night, 0.91 / 6.3
  on a rainy night (it's the main light then) — so 64. `mask` at 4 vs 32: 0.0015 mean.
- Probe re-bake: ~2.5 s per tile (~4 s the first). Build ~13–15 s. Packing (numpy + VideoToolbox): 11 s for 24 frames
  of 960×600 tiles, so roughly 10–15 min for a 576-frame loop at 1600×1000.
- **Full Commute loop (576 frames) at 1600×1000 tiles: 72–77 s × 576 ≈ 11.5–12.3 h** (18.7 h with every
  tile at 64), versus ~3.5–4 h per variant clip — i.e. one layered loop costs about as much as three
  variant loops and replaces all four (and every weather in between).
- Disk: half-float EXR (ZIP) per frame at 1600×1000 ≈ 4–5.5 MB per light tile (the mask compresses to
  almost nothing): ~14 GB for a 576-frame loop (9 MB per frame at 960×600), deleted after packing
  unless `--keep-frames`.
- The video, `--quality 80` (VideoToolbox HEVC Main10, the default): 6.2 MB per second at 960×600
  tiles (2896×1208), so ~150 MB for 24 s; at 1600×1000 tiles (4816×2008) expect ~300–400 MB (not
  measured). Round trip (decode -> pow4 -> linear vs the EXRs, frames 1/12/24 of the test): mean
  error 1.1–2.2 % of each tile's mean (city up to 2.6 %), the tile's outer 2 px no worse than the
  inside (the gutter works), mask 0.0002; pow4 10-bit quantisation alone is 0.16 %, 4:2:0 chroma
  alone 0.5–1.1 %. In the mixed picture (8-bit display levels, mean / p99, frame 12): q70 0.73 / 3.5
  (2.9 MB/s), **q80 0.46 / 2.0** (about the render's own noise floor), q90 0.21 / 0.8 (17 MB/s).
- Additivity (frame 1, 1600×1000): sun + sky + cabin + city vs an all-lights render of the same
  frame: mean absolute error **4.05 %** of the mean (3.97 % off the glass, 4.19 % on it), signed −2.5 %
  (the sum is a little darker: EEVEE's GI denoise/clamps aren't exactly linear); in display terms
  0.0066 of full range.

### Choosing: no render, layer stills, a layered loop, or variant loops

| What the user wants | Make | Cost |
|---|---|---|
| Stylised, graphic, abstract, or anything a shader can draw | **no render**: a shader scene (the `metal` engine) | seconds; lives with the sun and weather by construction |
| A photoreal set that may sit still (a room, a view), relit live by time and weather | **layer stills**: `--variants layers --still-frame N` (a one-frame `layers.mov`) | 98 s end to end at 1600×1000 (72 s of tiles + build + bakes + packing), measured |
| A photoreal set with motion, every time of day and weather | **a layered loop** (`--variants layers`) | overnight: ~12 h for 24 s at 1600×1000 tiles |
| Weather that changes geometry or materials: snow cover, wet reflective streets, water running on the glass, fog volumes, a different sky that must be seen sharply | **variant loops** (`--variants day,rain,…`), possibly together with layers | ~3.5–4 h per variant at 1920×1200 |

Always render the layer stills of a scene before its layered loop (show the mixes), and time 24
frames (`--frames 1-24`) before committing to the night.

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
| `encode` | `encode(frames_dir, out_base)`, `web(frames_dir, out_base, size, max_mb)`, `seam(frames_dir)` | HEVC main10 `hvc1` via VideoToolbox + an H.264 preview; two-pass VP9 webm + H.264 mp4 sized for the web; no grain (the app adds it live) |
| `spec` | `load(path)`, `scene_module(name)`, `build(spec, variant, engine, res, samples, layers=False)` | what run.py uses; `layers=True` = the light-layer build |
| `layers` | `Rig(scene, decl)`: `.use(tile, samples)`, `.render(path, frame)`, `.lights_on(set)`, `.rebake()`; `Rig.prepare(scene)`; `emission_controls(mat)`, `tile_samples(tile, base)`, `manifest_info(spec, decl)` | the light-layer renderer (see "Light layers") |
| `layerpack` | `pack(dir, out)`, `check(dir, mov)`, `scales(dir, tiles)`, `read_exr(path)`, `rgb_to_yuv420p10` / `yuv420p10_to_rgb` | plain python3 + numpy + ffmpeg |
| `lighting.add_sun` | `add_sun(coll, name, preset, color=None)` | a second sun lamp (light layers' `sun_low`) |

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
| Building Commute | ~15–30 s (a few hundred objects; the city is merged per material) |
| First Cycles render after a fresh start | +~60–90 s of Metal kernel compile (cached afterwards) |
| Cycles still, 1600×1000, 384 samples (adaptive + OIDN, 1024-px tiles) | 75–105 s per frame |
| Cycles still, 800×500, 64–128 samples (iteration) | ~7–10 s |
| Cycles animation frame, 2560×1600, 128 samples | ~76 s per frame (measured over 10 frames) |
| EEVEE animation frame (ray traced, probes baked), 2560×1600, 64 samples | ~20–30 s per frame (measured over 24 frames) |
| EEVEE animation frame, 1920×1200, 64 samples | ~26 s per frame: the cost is in the samples, not the resolution |
| EEVEE probe bake (volume + sphere) | ~8 s per process |
| Commute loop | 24 s × 24 fps = 576 frames: ~4 h with EEVEE at 64 samples, ~12 h with Cycles at 128 |
| Web encode (1280×800, two-pass VP9 + H.264) | about a minute for 24 s |

Always time 24 frames before a full loop. EEVEE needs the scene's baked volume probe to match
Cycles; without it an interior is lit by the whole sky and looks flat and washed out.

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
