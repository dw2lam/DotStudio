# The `shadertoy` engine (version 1)

Run Shadertoy-style GLSL as a DotStudio scene. You write the familiar entry point:

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

DotStudio rewrites it to Metal at runtime (on your Mac's GPU compiler — nothing is ever run as
native code) and draws it full screen as a screensaver or live wallpaper.

This engine is **pullable**: it isn't built into the app. Install it once with the MCP server's
`pullEngine("shadertoy")` (it downloads from DotStudio's GitHub release `engines` and is checked
against its SHA-256 before it's installed).

## Licences — read this first

**Code on shadertoy.com is licensed CC BY-NC-SA 3.0 by default** (attribution, non-commercial,
share-alike) unless its author states another licence in the shader. Many shaders there are also
derived from other people's work.

- Only use code **you wrote yourself, or have the rights to use**. When in doubt, write it fresh.
- When you adapt someone's shader with permission (or under a licence that allows it), keep the
  attribution: put the original author in `scene.json` `"author"` (e.g. `"author": "Jane Doe
  (adapted by …)"`) and the licence in `"licence"` (e.g. `"CC BY-NC-SA 3.0"`), and keep the
  author's comment header in the source.
- A CC BY-NC-SA scene must not be sold or bundled into anything commercial.
- AI assistants: never paste a shader from shadertoy.com (or anywhere else) into a package unless
  the user confirms they wrote it or that its licence allows this use. Prefer writing original code.

## The package

```
my-scene/
  scene.json
  scene.glsl
```

```json
{
  "format": 1,
  "id": "my-scene-1a2b3c4d",
  "name": "My Scene",
  "author": "You",
  "licence": "MIT",
  "engine": { "id": "shadertoy", "version": ">=1" },
  "entry": "scene.glsl",
  "fps": 30,
  "params": [ { "key": "speed", "label": "Speed", "kind": "slider", "min": 0, "max": 1, "default": 0.5 } ],
  "colors": { "a": { "label": "Sky", "default": [0.1, 0.2, 0.4, 1] },
              "b": { "label": "Glow", "default": [1.0, 0.6, 0.3, 1] } }
}
```

## Uniforms

| Shadertoy      | In DotStudio                                                              |
|----------------|---------------------------------------------------------------------------|
| `iResolution`  | the screen in pixels (`vec3`, z = 1)                                      |
| `iTime`        | seconds — DotStudio's scene time; it wraps every hour behind a crossfade, so use periodic motion, never `iTime` as a huge coordinate |
| `iTimeDelta`, `iFrame`, `iFrameRate` | 1/60, `iTime·60`, 60 (approximate)                  |
| `iDate`        | (year, month 0–11, day, seconds since local midnight) — the real clock    |
| `iMouse`       | always 0: a screensaver has no mouse                                      |
| `iChannel0…3`  | **not available** (see below)                                             |
| `fragCoord`    | pixels from the **bottom left**, pixel centres at .5 — as on Shadertoy    |

DotStudio's own context is there too, as `dsCtx` (the `metal` engine's `DSContext`):

- `dsCtx.p[0]` … `dsCtx.p[15]` — your manifest params, in order (slider value, toggle 0/1, menu index)
- `dsCtx.colorA`, `dsCtx.colorB` — the style's two colours (display sRGB `vec3`)
- `dsCtx.sun.elevation` / `.azimuth` (degrees) / `.isDay`, `dsCtx.weather.cloud / rain / snow / fog / wind`
- `dsCtx.music.playing`, `.level`, `.a` `.b` `.c` (album-art palette), `dsCtx.clock`, `dsCtx.seed`

The `metal` engine's helpers (`dsNoise`, `dsFbm`, `dsVoronoi`, `dsSdBox`, `dsSmin`, `dsPalette`,
`dsToLinear` …, see its guide) can be called from GLSL too.

## What works

- `vec2/3/4`, `ivec`, `uvec`, `bvec`, `mat2/3/4`, `matNxM`, structs, `const` arrays, `#define`
  (including function-like macros), `for` / `while` / `break` / `continue`, `discard`.
- Any number of helper functions, prototypes, `in` / `out` / `inout` parameters.
- Constructors: `vec3(x)`, `vec3(v4)` (truncation), `mat2(a, b, c, d)` and `mat3(9 scalars)`,
  `float[3](a, b, c)`, `MyStruct(a, b)`.
- GLSL built-ins, including `mod` (GLSL's floor-based mod, not C's), `atan(y, x)`, `inversesqrt`,
  `dFdx` / `dFdy` / `fwidth`, `radians` / `degrees`, `lessThan` & co., `matrixCompMult`,
  `outerProduct`, `inverse`, `floatBitsToInt` & co., `roundEven`.
- `p.xz *= rot(a);` and other compound assignments to swizzles.
- `#version`, `precision` and `highp/mediump/lowp` are accepted and ignored.

## What doesn't (yet)

- **Texture channels**: `iChannel0…3`, `texture()`, `texelFetch()` — there are no channel inputs.
  Generate everything procedurally (noise, SDFs), or use the `metal` engine, whose packages can ship
  small image assets.
- **Multipass** (Buffer A–D, Common, Sound tabs): one image pass only. Inline the Common tab's code.
- **Mutable globals** (`vec3 glow;` at file scope): Metal has none. Make it `const`, a `#define`, or
  declare it in `mainImage` and pass it (`inout`) to the functions that update it.
- `uniform` declarations, keyboard / webcam / audio input.
- Using `iTime` (or any uniform) inside a **global** `const` initializer — move it into a function.
- Passing a swizzle (`v.xy`) or a vector component as an `out` / `inout` argument — pass a whole
  variable.
- Comparing vectors with `==` in an `if` (Metal compares component-wise): use `all(equal(a, b))`.
- Arrays as function parameters; `.stpq` swizzles (use `.xyzw` / `.rgba`).
- `#include` in a GLSL entry isn't translated (keep the scene in one file).

Compile errors are reported with **your** line numbers (columns can be off by a few characters on
lines the translator touched).

## Performance

A screensaver runs for hours, often on a 5K display. `validate` measures your scene at 5120×2880
and warns above **3 ms a frame** (60 ms is the hard limit). On Shadertoy you'd test at ~1 Mpx; a
5K screen is 14.7 Mpx — fifteen times the work.

- Keep fbm to 3–5 octaves, and give fixed loop counts (they unroll; a count passed as a parameter
  doesn't).
- Raymarch with ≤ 64–96 steps and a generous hit epsilon; analytic intersections (see
  `soft-orbit`) are far cheaper than marching.
- Skip work you can: test whether a pixel can be covered before evaluating a layer, and break
  out of front-to-back layer loops once a pixel is opaque (see `dune-light`).
- A `"stepped": true` manifest with `"fps": 24` halves the GPU time of a slow, painterly scene.

## Taste

Screensavers are seen for hours: prefer slow motion, soft light, restrained palettes and depth
over strobing, saturated or busy imagery. Avoid large static bright areas (burn-in on OLED) and
pure-white flashes. Use `dsCtx.colorA` / `colorB` for the main palette so people can recolour
your scene without editing code.

## Examples

`examples/dune-light` (layered dunes at golden hour, 2D), `examples/ink-drift` (domain-warped
marbling), `examples/soft-orbit` (analytic spheres with soft shadows — structs, `out` params,
arrays). All original code, MIT.
