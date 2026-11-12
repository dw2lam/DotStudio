# Engine: shadertoy (GLSL compatibility, pullable)

Placeholder. Pull it with `pull_engine("shadertoy")`; the installed engine's `guide.md` replaces this page.

It accepts a Shadertoy-style `void mainImage(out vec4 fragColor, in vec2 fragCoord)` as the package entry (`scene.glsl`) with `iTime`, `iResolution` and `iDate` mapped from DotStudio's context; params arrive as uniforms.

Only port shaders the user owns or whose licence allows it (put it in the manifest's `licence`), and bring them in line with `style/dotstudio`: slow the time down, calm the palette, cut cost to the 5K budget (`power`).
