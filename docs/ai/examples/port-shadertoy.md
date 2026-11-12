# Port a Shadertoy I wrote

> **You:** Port my Shadertoy “Slow Tide” (I wrote it, MIT) into DotStudio.

_Recorded against the self-test's stand-in engine (the shadertoy engine is pullable once the scene-engine update ships); no preview image._

```
→ list_engines({"include_available": true})
```
```text
- metal v1 (metal-source), built in
- cells v1 (cells), built in
```

```
→ pull_engine({"id": "shadertoy"})
```
```text
Installed engine shadertoy v1. Read its guide: read_guide("engines/shadertoy").
```

```
→ read_guide({"id": "engines/shadertoy"})
```
```text
# shadertoy engine (test)

Fake guide.

```

```
→ create_custom_scene({"manifest": {"name": "Slow Tide", "engine": {"id": "shadertoy"}, "entry": "scene.glsl", "fps": 30, "licence": "MIT (user's own)", "author": "the user", "colors": {"a": {"label": "Sky", "default": [0.03, 0.05, 0.1, 1]}, "b": {"label": "Sea", "default": [0.1, 0.35, 0.45, 1]}}}, "source": "…below…"})
```
`source`:

```glsl
// Slow Tide — (c) the user, MIT. Ported to DotStudio: time slowed 4x, palette from the scene's colours.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float t = iTime * 0.25;
    float w = sin(uv.x * 6.0 + t) * 0.03 + sin(uv.x * 13.0 - t * 1.3) * 0.015;
    float sea = smoothstep(0.45 + w, 0.44 + w, uv.y);
    vec3 col = mix(colorA.rgb, colorB.rgb, sea * (0.6 + 0.4 * uv.y));
    fragColor = vec4(col, 1.0);
}
```
```text
Compiles.
GPU ≈ 2.50 ms per frame at 5K.
Installed as slow-tide-cde85544. Use it: create_style(effects: [{"kind": "custom", "scene": "slow-tide-cde85544"}]).
```
