# Port a Shadertoy I wrote

> **You:** Port my Shadertoy “Slow Tide” (I wrote it, MIT) into DotStudio.

_The shadertoy engine was pulled from a local copy of DotStudio's engines index (tools/engines/build-index.sh), as the app downloads it from the `engines` release._

```
→ list_engines({"include_available": true})
```
```text
- cells v1 (cells), built in
- film v1 (film), built in
- metal v1 (metal-source), built in
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
# The `shadertoy` engine (version 1)

Run Shadertoy-style GLSL as a DotStudio scene. You write the familiar entry point:

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

DotStudio  …
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
    vec3 col = mix(dsCtx.colorA, dsCtx.colorB, sea * (0.6 + 0.4 * uv.y));
    fragColor = vec4(col, 1.0);
}
```
```text
Compiles.
GPU ≈ 1.18 ms per frame at 5K.
Installed as slow-tide-ce5f8fe7. Use it: create_style(effects: [{"kind": "custom", "scene": "slow-tide-ce5f8fe7"}]).
```

```
→ create_style({"name": "Slow Tide", "fps": 30, "effects": [{"kind": "custom", "scene": "slow-tide-ce5f8fe7"}]})
```
```text
Created “Slow Tide” (5DE423A9-D4C4-47E0-9827-8D0A5D269D6F). DotStudio isn't running: library.json was updated; the app shows it next time it opens.
Next: preview_style(style: "5DE423A9-D4C4-47E0-9827-8D0A5D269D6F") — and a contact sheet over time (frames: 6) to check the motion.
```

```
→ preview_style({"style": "5DE423A9-D4C4-47E0-9827-8D0A5D269D6F", "t": 30, "width": 1280, "height": 800})
```
```text
“Slow Tide” at t = 30.0 s.
```

![port-shadertoy.jpg](img/port-shadertoy.jpg)
