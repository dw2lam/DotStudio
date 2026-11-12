// Soft Orbit — three matte spheres circling over a pale floor, lit by a low sun.
// Shadertoy-style GLSL for DotStudio's `shadertoy` engine. Original code (MIT).
// Analytic ray–sphere intersections (no raymarching), so it stays cheap on a 5K display.
// dsCtx.p[0] = Speed; dsCtx.colorA = the floor and sky, dsCtx.colorB = the spheres.

struct Scene { vec4 s0; vec4 s1; vec4 s2; };       // centre (xyz) and radius (w)
struct Hit { float t; vec3 n; int id; };

vec4 sphere(int i) {
    float a = iTime * 0.18 * (0.2 + dsCtx.p[0]) + float(i) * 2.0944;
    float r = 0.42 + 0.12 * float(i);
    return vec4(cos(a) * 1.35, r + 0.08 * sin(iTime * 0.4 + float(i) * 1.7), sin(a) * 1.35, r);
}

vec4 pick(Scene sc, int i) { return i == 0 ? sc.s0 : (i == 1 ? sc.s1 : sc.s2); }

float hitSphere(vec3 ro, vec3 rd, vec4 s) {
    vec3 oc = ro - s.xyz;
    float b = dot(oc, rd);
    float h = b * b - (dot(oc, oc) - s.w * s.w);
    if (h < 0.0) return -1.0;
    return -b - sqrt(h);
}

// Nearest hit along the ray: a sphere (id 0–2) or the floor (id 3); -1 = sky.
void trace(Scene sc, vec3 ro, vec3 rd, out Hit h) {
    h.t = 1e9; h.n = vec3(0.0, 1.0, 0.0); h.id = -1;
    for (int i = 0; i < 3; i++) {
        vec4 s = pick(sc, i);
        float t = hitSphere(ro, rd, s);
        if (t > 0.0 && t < h.t) { h.t = t; h.n = (ro + rd * t - s.xyz) / s.w; h.id = i; }
    }
    float tp = -ro.y / rd.y;
    if (rd.y < 0.0 && tp < h.t) { h.t = tp; h.n = vec3(0.0, 1.0, 0.0); h.id = 3; }
}

// Soft shadow and ambient occlusion from the spheres, in one pass: how close the shadow ray
// passes each sphere against how far it has gone, and how much of the sky each one hides.
void occlude(Scene sc, vec3 p, vec3 n, vec3 l, out float shadow, out float ao) {
    shadow = 1.0; ao = 1.0;
    for (int i = 0; i < 3; i++) {
        vec4 sp = pick(sc, i);
        vec3 c = sp.xyz - p;
        float d2 = dot(c, c);
        ao *= 1.0 - max(0.0, dot(n, c)) * inversesqrt(d2) * (sp.w * sp.w) / d2;
        float along = dot(c, l);
        if (along > 0.0) {
            float miss = sqrt(max(d2 - along * along, 0.0)) - sp.w;
            shadow = min(shadow, clamp(miss / (0.18 * along) + 0.5, 0.0, 1.0));
        }
    }
    shadow = shadow * shadow * (3.0 - 2.0 * shadow);
}

vec3 shade(Scene sc, Hit h, vec3 rd, vec3 l, vec3 p) {
    vec3 tints[4] = vec3[4](dsCtx.colorB, mix(dsCtx.colorB, dsCtx.colorA, 0.55),
                            dsCtx.colorB * vec3(0.78, 0.86, 1.0), dsCtx.colorA * 1.15);
    vec3 base = tints[h.id];
    base *= base;                                      // ≈ linear light (cheaper than pow 2.2)
    float shadow, ao;
    occlude(sc, p + h.n * 0.002, h.n, l, shadow, ao);
    float dif = max(dot(h.n, l), 0.0) * shadow;
    float sky = 0.5 + 0.5 * h.n.y;
    vec3 sun = vec3(1.0, 0.86, 0.70) * 2.2;
    vec3 amb = dsCtx.colorA * dsCtx.colorA * 0.9 + 0.08;
    vec3 col = base * (sun * dif + amb * sky * ao);
    // a soft sheen on the spheres
    if (h.id < 3) {
        float s = max(dot(reflect(rd, h.n), l), 0.0);
        s *= s; s *= s; s *= s;                        // ^8
        col += 0.06 * s;
    }
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    vec3 ro = vec3(0.0, 1.9, -5.2);
    vec3 ta = vec3(0.0, 0.45, 0.0);
    vec3 fw = normalize(ta - ro);
    vec3 rt = normalize(cross(vec3(0.0, 1.0, 0.0), fw));
    vec3 up = cross(fw, rt);
    vec3 rd = normalize(uv.x * rt + uv.y * up + 1.9 * fw);
    vec3 l = normalize(vec3(-0.75, 0.6, -0.35));
    Scene sc = Scene(sphere(0), sphere(1), sphere(2));

    vec3 skyCol = mix(dsCtx.colorA * 1.2, vec3(1.0, 0.95, 0.9), 0.35);
    skyCol *= skyCol;
    vec3 col = skyCol;
    Hit h;
    trace(sc, ro, rd, h);
    if (h.id >= 0) {
        vec3 p = ro + rd * h.t;
        col = shade(sc, h, rd, l, p);
        // the floor fades into the haze far away
        col = mix(col, skyCol, 1.0 - exp(-0.012 * h.t * h.t));
    }
    col = col / (1.0 + col * 0.35);                    // gentle highlight roll-off
    fragColor = vec4(sqrt(col), 1.0);                  // back to display (≈ gamma 2)
}
