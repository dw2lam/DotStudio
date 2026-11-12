// Dune Light — layers of sand dunes drifting under a low golden sun.
// Shadertoy-style GLSL for DotStudio's `shadertoy` engine. Original code (MIT).
// dsCtx.p[0] = Drift, dsCtx.p[1] = Haze; dsCtx.colorA = the sky, dsCtx.colorB = the sand.

float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

float noise1(float x) {
    float i = floor(x), f = fract(x);
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);     // quintic: smooth slopes, no banding
    return mix(hash(i), hash(i + 1.0), f);
}

// A dune's crest line: long smooth swells with one softly peaked ridge on top.
float crest(float x, float seed) {
    float s = seed * 13.1;
    float n = noise1(x * 0.55 + s) * 0.55 + noise1(x * 1.3 + s * 1.7) * 0.28 + noise1(x * 3.1 + s) * 0.07;
    float r = noise1(x * 0.8 + s * 0.3 + 4.0) * 2.0 - 1.0;
    float ridge = 1.0 - sqrt(r * r + 0.015);           // a soft |r|: peaked, never creased
    return n + ridge * 0.22;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float aspect = iResolution.x / iResolution.y;
    float t = iTime * 0.015 * (0.2 + dsCtx.p[0]);
    float haze = dsCtx.p[1];

    // the sky: the chosen colour overhead, warming to a pale gold at the horizon
    vec3 top = dsCtx.colorA;
    vec3 horizon = vec3(1.0, 0.78, 0.56);
    vec3 sky = mix(horizon, top, pow(clamp(uv.y * 1.1, 0.0, 1.0), 0.65));

    // a low sun, with a wide soft glow
    vec2 sp = vec2(0.70 * aspect, 0.50);
    float sd = length(vec2(uv.x * aspect, uv.y) - sp);
    sky += vec3(1.0, 0.72, 0.42) * exp(-sd * 7.0) * 0.45;
    sky = mix(sky, vec3(1.0, 0.95, 0.84), smoothstep(0.042, 0.036, sd));

    // dunes, near to far (front to back: once a pixel is covered, the dunes behind it are
    // never computed): lower, darker and sharper as they come closer
    vec3 sand = dsCtx.colorB;
    vec3 acc = vec3(0.0);
    float cover = 0.0;
    float edge = 1.5 / iResolution.y;
    for (int i = 3; i >= 0; i--) {
        float fi = float(i);
        float base = 0.38 - fi * 0.085;
        float amp = 0.20 + fi * 0.03;
        if (uv.y > base + 0.5 * amp + edge) continue;   // above this dune's highest crest
        float near = fi / 3.0;
        float x = uv.x * aspect * (0.8 + fi * 0.35) + t * (1.0 + fi * 1.6) + fi * 7.31;
        float c0 = crest(x, fi);
        float h = base + (c0 - 0.55) * amp;
        float m = smoothstep(-edge, edge, h - uv.y);
        if (m <= 0.0) continue;
        // light falls on the slopes that face the sun (to the right), shade on the others
        float slope = (crest(x + 0.05, fi) - c0) / 0.05;
        float lit = smoothstep(-0.25, 0.35, -slope);
        vec3 c = mix(sand * 1.05, sand * vec3(0.62, 0.46, 0.46), near * 0.7);
        c *= mix(0.72, 1.12, lit);
        // shading deepens away from the crest, down into each trough
        c *= 1.0 - 0.18 * smoothstep(0.0, 0.12, h - uv.y);
        // a little rim of light along each crest
        c += vec3(1.0, 0.8, 0.55) * 0.14 * lit * smoothstep(4.0 / iResolution.y, 0.0, h - uv.y);
        // distant dunes fade into the sky
        c = mix(c, sky, (1.0 - near) * (0.25 + 0.4 * haze));
        acc += (1.0 - cover) * m * c;
        cover += (1.0 - cover) * m;
        if (cover > 0.995) break;
    }
    vec3 col = acc + (1.0 - cover) * sky;

    // a soft vignette and the faintest grain
    vec2 v = uv - 0.5;
    col *= 1.0 - 0.25 * dot(v, v);
    col += (hash(dot(fragCoord, vec2(1.0, 113.0)) + iTime) - 0.5) * 0.012;
    fragColor = vec4(col, 1.0);
}
