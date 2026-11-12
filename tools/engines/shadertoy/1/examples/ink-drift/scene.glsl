// Ink Drift — two inks marbling slowly on warm paper.
// Shadertoy-style GLSL for DotStudio's `shadertoy` engine. Original code (MIT).
// dsCtx.p[0] = Flow, dsCtx.p[1] = Scale; dsCtx.colorA / colorB = the two inks.

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

const mat2 OCT = mat2(0.8578, 0.5140, -0.5140, 0.8578) * 2.03;   // rotate + scale per octave

// Two octaves: enough for the warps (they're blurred by what they bend).
float fbm2(vec2 p) {
    return (noise(p) * 0.5 + noise(OCT * p + 11.7) * 0.25) / 0.75 * 0.94;
}
// Three octaves for the ink itself. (Fixed counts unroll; a variable count costs a loop.)
float fbm3(vec2 p) {
    float v = noise(p) * 0.5;
    p = OCT * p + 11.7; v += noise(p) * 0.25;
    p = OCT * p + 11.7; v += noise(p) * 0.125;
    return v / 0.875 * 0.94;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    p = p * (1.8 + dsCtx.p[1] * 2.4) + vec2(31.7, 17.3);
    float t = iTime * 0.025 * (0.2 + dsCtx.p[0]);

    // domain warping, twice: the ink folds into itself like marbled paper
    vec2 q = vec2(noise(p * 0.8 + vec2(0.0, t)), noise(p * 0.8 + vec2(5.2, 1.3) - t));
    vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2) + 0.6 * t),
                  fbm2(p + 3.0 * q + vec2(8.3, 2.8) - 0.4 * t));
    float f = fbm3(p + 3.2 * r);

    vec3 paper = vec3(0.95, 0.93, 0.88);
    vec3 col = paper;
    // the main ink pools where the warped noise runs high, thinning to a wash at its edges
    col = mix(col, dsCtx.colorA, smoothstep(0.38, 0.70, f) * 0.9);
    // the accent ink only in threads, where the second warp runs high
    col = mix(col, dsCtx.colorB, smoothstep(0.60, 0.76, r.y) * smoothstep(0.30, 0.50, f) * 0.75);

    // fine darker veins where the warp folds tightest
    float vein = abs(fract(f * 7.0) - 0.5);
    col *= 1.0 - 0.10 * smoothstep(0.05, 0.0, vein) * smoothstep(0.42, 0.62, f);

    // paper tooth
    col *= 0.975 + 0.025 * hash(fragCoord);
    fragColor = vec4(col, 1.0);
}
