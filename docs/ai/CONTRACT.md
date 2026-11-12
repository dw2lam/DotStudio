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
