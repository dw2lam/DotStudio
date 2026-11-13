# DotStudio AI scenes — shared contract (Engine agent ⇄ MCP agent)

Two agents build this in parallel from `next` @ 1bb159f. This file is the interface between them. If you must
change it, keep the change additive and say so in your report.

## 1. Custom scene in a style
- New `EffectKind.custom` (shader id 90, display name "Custom Scene", Retro? no — its own tag "Custom").
- `EffectInstance` gains one optional, add-only field: `custom: CustomSceneRef?` (nil and never written for every
  other kind, like `logoFile`). `struct CustomSceneRef: Codable, Hashable { var id: String }` — the folder name of an
  installed scene package.
- The style's slider/toggle/menu values live in `EffectInstance.params` as usual, keyed by the package manifest's
  param keys. Colours use `colorA` / `colorB` (labels from the manifest).

## 2. Scene package (on disk, in the shared store so the sandboxed saver can read it)
`<store>/scenes/<id>/` where `<id>` = `[a-z0-9-]{1,48}` + "-" + 8 hex (unique).
- `scene.json` (manifest):
  ```json
  { "format": 1, "id": "aurora-lake-1a2b3c4d", "name": "Aurora Lake", "author": "…", "licence": "…",
    "engine": { "id": "metal", "version": ">=1" },
    "entry": "scene.metal",
    "fps": 30, "stepped": false,
    "params": [ { "key": "speed", "label": "Speed", "kind": "slider", "min": 0, "max": 1, "default": 0.5 },
                { "key": "stars", "label": "Stars", "kind": "toggle", "default": 1 },
                { "key": "mood",  "label": "Mood",  "kind": "menu", "options": ["Calm","Vivid"], "default": 0 } ],
    "colors": { "a": { "label": "Sky", "default": [0.1,0.2,0.5,1] }, "b": { "label": "Glow", "default": [0.3,1,0.7,1] } },
    "uses": ["sun", "weather", "music"],
    "description": "…", "guides": ["style/dotstudio"] }
  ```
  Max 16 params (they map to p[0…15] in manifest order). Unknown fields are kept.
- The entry source file(s) + optional small assets (`assets/*.png|jpg`, ≤ 8 MB total).

## 3. Engines
An engine turns a package's entry source into a render pipeline.
- Built-in (ship in the app bundle, always present): `metal` (v1) and `cells` (v1).
- Pullable (downloaded on demand): e.g. `shadertoy` (GLSL compat, v1), later `film`.
- Installed engines live in `<store>/engines/<id>/<version>/` with `engine.json`
  `{ "id","version","kind":"metal-source"|"glsl-source"|"cells"|"film","headers":[…],"guide":"guide.md","examples":[…],"minApp":"1.5.0" }`.
- Index of pullable engines: `engines-index.json` published as an asset on a GitHub release of dw2lam/DotStudio
  (tag `engines`); each entry `{id, version, url, sha256, size, minApp, summary}`. Downloads are verified by sha256
  before install; never executed as native code — engines are only shader headers/translators data + docs.

### `metal` engine API (what the LLM writes)
```metal
#include <DotStudio.h>          // provided by the engine: DSContext, noise/fbm, sdf, palette, sky, text-free helpers
float4 dsScene(float2 uv, DSContext ctx) { … }   // uv 0…1, y up; return display-sRGB rgb + alpha 1
```
`DSContext` fields (read-only): `res` (px), `aspect`, `t` (seconds, stepped if manifest.stepped), `clock`
(seconds since local midnight), `date` (y,m,d,weekday), `sun` (elevation°, azimuth°, isDay), `weather`
(cloud, rain, snow, fog, wind 0…1), `music` (playing, level 0…1, art colours a/b/c), `p[16]` (params),
`colorA`, `colorB`, `seed`. The engine wraps `dsScene` into a fragment function and compiles at runtime.
`cells` engine: same signature but returns colour + coverage, and the engine renders it as LED dots /
pixels / glyphs (CellKit look) with params Render / Cell Size / Glow added automatically.

## 4. Swift API the MCP server calls (Engine agent implements in Shared/CustomScenes.swift)
```swift
enum CustomScenes {
  static func validate(packageAt url: URL, device: MTLDevice) -> CustomSceneReport      // manifest + compile, no install
  static func install(packageAt url: URL, into store: URL) throws -> String              // returns id; copies into <store>/scenes
  static func remove(id: String, store: URL) throws
  static func installed(store: URL) -> [CustomSceneManifest]
  static func engines(store: URL) -> [EngineInfo]                                        // built-in + installed
  static func pullEngine(id: String, store: URL) async throws -> EngineInfo              // download + verify + install
  static func availableEngines() async throws -> [EngineIndexEntry]                      // reads engines-index.json
}
struct CustomSceneReport { var ok: Bool; var diagnostics: [Diagnostic] /* line, column, message, severity */;
                           var gpuMsAt5K: Double?; var warnings: [String] }
```
Rendering a preview of any style (built-in or custom) is done with the existing MetalRenderer path that
tools/gallery uses; the MCP agent owns a small `PreviewRenderer` wrapper around it.

## 5. Guides (MCP agent owns content + delivery; Engine agent writes its engines' `guide.md`)
Bundled in the app: `Resources/Guides/` — `style/dotstudio.md` (taste), `settings/*.md` (generated from
SceneCatalog so it never drifts), `engines/<id>.md` (from engine packages), `power.md`, `burn-in.md`.
User guides: any `.md` in `<store>/guides/` (brand/style guides the user adds) are listed too.

## 6. Film (added by the MCP agent — additive)
Photoreal, ray-traced scenes from the Blender toolkit (`dsfilm`, branch commute-film, shipped as the pullable
`film` engine). The MCP server drives it through this seam (Swift, MCP/Film.swift on ai-mcp):
```swift
protocol FilmToolkitAPI {
  var isAvailable: Bool { get }                          // toolkit in this build AND pulled
  func status() -> FilmStatus                            // blenderPath/version, toolkitPulled/version, gpu, notes
  func validate(spec: [String: Any]) -> CSReport         // spec in dsfilm's own format; no render
  func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand
  func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int,
                   quality: String /* draft|standard|final */) throws -> FilmCommand
  func package(loopOutput: URL, spec: [String: Any], sceneID: String, into package: URL) throws
}
struct FilmCommand { var executable: String; var arguments: [String]; var environment: [String: String] }
```
- The toolkit's commands are plain processes (Blender headless + dsfilm). The MCP server runs them as detached jobs:
  own session (setsid), `nice -n 10`, stdin /dev/null, stdout+stderr → `<store>/jobs/<job>/log.txt`, exit status →
  `exit_code`; cancel = SIGTERM to the process group, SIGKILL after 5 s. Jobs outlive the MCP process.
- Progress: the command writes JSON `{"fraction": 0…1, "stage": "…", "eta_s": seconds}` to the path in env
  `DSFILM_PROGRESS` (atomically, as often as it likes).
- Stills: one `<outDir>/<variant>.png` per variant. Variants: `day`, `golden`, `night`, `rain`.
- Loop → package: a scene package (§2) with `"engine": {"id": "film", …}` and a `clips` list
  `[{ "variant": "day", "file": "clips/day.mov", "codec": "hevc" }, …]` (+ the clip files), installed with
  `CustomScenes.install`; styles use it as `{kind: "custom", custom: {id}}` like any custom scene.
- Drafts (create_film_scene) live in `<store>/film/<draft>/spec.json`.

## 7. MCP side's view of §4 (added by the MCP agent — additive)
The MCP target codes against `protocol CustomScenesAPI` (MCP/CustomScenesAPI.swift) with its own value types
(`CSReport`, `CSDiagnostic`, `CSEngine`, `CSEngineIndexEntry`, manifests as JSON objects), not the engine's types,
so the two branches don't define the same names. At merge, add a small `CustomScenesBridge: CustomScenesAPI`
(device = `MTLCreateSystemDefaultDevice()`, store = the MCP's store dir) mapping `CustomScenes.*` onto it, and
return it from `makeCustomScenesAPI(store:)` instead of `UnavailableCustomScenes`. `pullEngine` /
`availableEngines` are called synchronously from a tool call (wrap the async API with a semaphore).
Style JSON for a custom scene is written exactly per §1 (`"kind": "custom"`, `"custom": {"id": …}`, params by
manifest key, colours colorA/colorB); before `EffectKind.custom` exists it round-trips as an unknown effect.

## 8. Engine side as built (added by the Engine agent — additive; branch ai-engines)
Everything in §1–§4 is implemented as written (Shared/CustomScenes.swift, CustomSceneCompiler.swift,
CustomSceneLink.swift, GLSLTranslator.swift, CustomFilm.swift). Additions, none of which change a §1–§4 shape:
- **Film engine is built in** (`Resources/Engines/film/1/`, kind `film`), not pulled: the clip player is the app's
  own video path (VideoSource / AVPlayerLooper), and the engine is just its aspect-fill + crossfade shader. A §6
  package (`"engine": {"id": "film"}`, `clips: [{variant, file, loop?, codec?}]`) installs and plays as is.
  Variants: `day` (sun > 8°), `golden` (−4°…8°), `night` (< −4°), `rain` (while it rains), `any` (fallback);
  re-checked every 5 s, 3 s crossfade, seamless loops, aspect-fill; thumbnails/previews show each clip's first
  frame; the wallpaper holds a still on battery Efficient / Still and in Low Power. Clips ≤ 400 MB per package.
- `CustomScenes.validate(packageAt:device:store:)` overload (the contract's 2-argument form uses
  `CustomScenes.defaultStore` = the app's store, honouring DOTSTUDIO_STORE_DIR). `CustomSceneReport` adds
  `manifest` and `engine` ("metal 1"). `Diagnostic` = `{line, column, message, severity: error|warning|note,
  file}` — `file` is the package file (`scene.metal`, an `#include`d file, `scene.json`) or an engine header.
- Manifest extras: `"assets": ["assets/x.png", …]` (≤ 4, 8 MB → `ctx.asset0…3`), `"clips"` (film). Unknown
  fields are kept (install copies scene.json verbatim, replacing only a missing/invalid id).
- `engine.json` extras: `name`, `summary`, `base` ({id, version}: headers of another engine come first — cells,
  shadertoy and film build on metal), `wrapper` (defines `ds_fragment`), `params` (engine-added params, ≤ 4 —
  cells: `ds.render` menu Glyphs/Pixels/Dots, `ds.cell` 6…32, `ds.glow` 0…1; stored in the style's `params`
  under those keys), `entryExtensions`.
- Pullable engines download as one JSON bundle, `<id>-<version>.dsengine.json` =
  `{"format":1,"id","version","files":{relpath: base64}}` (no archive to unpack), listed in `engines-index.json`
  `{"format":1,"engines":[{id, version, url (relative to the index), sha256, size, minApp, summary}]}`; built by
  `tools/engines/build-index.sh <outDir>` from `tools/engines/<id>/<version>/`. `DOTSTUDIO_ENGINES_INDEX` (URL or
  path) overrides the index location for offline tests. Only https (or file) URLs; size + SHA-256 verified before
  anything is written; installed atomically into `<store>/engines/<id>/<version>/`; a pulled engine never shadows a
  built-in id. Built-in engines resolve from `Resources/Engines` (DOTSTUDIO_ENGINES_DIR overrides, for tools).
- Helpers for the MCP side: `EffectInstance.customScene(manifest)` / `Preset.customScene(manifest)` (a style at
  the manifest's defaults, its name and fps); `EffectInstance.paramSpecs` / `defaultColorAValue` / `colorALabelText`
  (the Inspector's view of a custom effect); `CustomScenes.manifest(id:store:)` (cached);
  `CustomSceneLink.shared(store:).status(id)` → `.ready | .compiling | .missing | .failed([Diagnostic]) |
  .disabled(reason)` (what a style is showing right now).
- Preview: `MetalRenderer.renderThumbnail` waits for a custom scene's compile (it's off the main thread in the
  app's Thumbnailer); live renderers never wait (they draw the calm stand-in, shader 90, until it's built) except
  the screensaver's first frame. tools/gallery: `--scene <packageDir>` (validate + install into the temp store +
  render / `--gpubench`), and `--checks` runs the Custom Scene checks.

## 9. As merged (branch ai-integrate — additive)
- `makeCustomScenesAPI` returns `CustomScenesBridge` (MCP/CustomScenesAPI.swift): §4 on `MTLCreateSystemDefaultDevice()`
  and the MCP's store, diagnostics carry `file` (nil = the entry; the tools show source lines only for the entry),
  the async engine calls are waited on from the tool call. `CustomScenesAPI.effect(scene:)` hands the tools the
  engine's own starting effect (`EffectInstance.customScene`) and every param it takes (manifest + engine), so
  custom styles are built exactly as the app builds them. `DOTSTUDIO_MCP_TEST_FAKES=1` keeps the structural stand-in.
- Guides: `engines/<id>` is served from each engine's own `guide.md` (built-in: Resources/Engines; pulled: the store).
  The bundled `Guides/engines/*` placeholders are gone; the Blender toolkit's flow (§6) is the bundled guide `film`.
- Film (§6 vs §8): the `film` *engine* is built in (it plays clips); the Blender *toolkit* is separate and not merged
  yet, so `makeFilmToolkit` returns `UnavailableFilmToolkit` (TODO + seam in MCP/Film.swift). `FilmPackage.make`
  writes a loop's output in the engine's format (no `entry`; `clips` by variant; the spec's `look`). A package's
  `look.grain` is its styles' starting `ds.grain`; `ds.halation` starts at 0 (the toolkit bakes halation).
  `DOTSTUDIO_MCP_TEST_FAKES=film` = the real engines with the stand-in toolkit (real H.264 loops).
- Clocks: `FXUniforms.still` (x = 1 in a still) settles a clock's minute changeover; `ctx.clock` is exact on every
  minute (`floor(clock / 60)` is the minute on screen). Manifests may list `"clock"` in `uses`.
