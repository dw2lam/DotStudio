"""Lighting rigs: an HDRI sky (Poly Haven, CC0) for the sky you see and its ambient light, plus a
sun lamp for the direct light. The HDRI's own sun is clamped out of the world (``hdri_clamp``) so
the sun lamp alone sets where shadows fall — you choose elevation/azimuth freely instead of being
stuck with the photo's sun. With ``hdri=None`` a Nishita physical sky is used instead.

    rig = lighting.setup(scene, coll, "day", sun_az=60)      # preset name + overrides
    rig.sun.rotation_euler = lighting.sun_euler(elev, az)    # animate (deg; az 0 = +X, 90 = +Y)
    rig.mapping.inputs["Rotation"]                           # world rotation node (z = turn sky)

Presets (override any key):
    day     clear midday, cumulus      kloofendal_48d_partly_cloudy_puresky
    golden  low warm sun, sunset sky   qwantani_sunset_puresky (its sun just off-frame), sky tinted warm
    night   overcast city-glow night   kloppenheim_07_puresky   (sun off; light from lamps)
    rain    overcast, soft light       kloofendal_overcast_puresky (sun off)

Keys: hdri, hdri_rot (deg), hdri_strength, hdri_clamp (max radiance kept), sky_tint (rgb multiplier), sun_elev, sun_az (deg),
sun_strength (W/m², ~4 for a clear day under AgX at exposure 0), sun_color, sun_angle (deg, disc
size -> shadow softness), exposure (EV over the scene-referred render; interiors lit through windows need +1.5..2 by day, +3..4 at night; applied by render.setup), cabin (interior lamp scale),
night (bool for scenes: switch on windows), rain (bool).
"""
import math
from types import SimpleNamespace

import bpy
from mathutils import Vector

from . import assets
from .materials import load_image

PRESETS = {
    "day": dict(hdri="kloofendal_48d_partly_cloudy_puresky", hdri_rot=200, hdri_strength=1.0, hdri_clamp=40,
                sun_elev=17, sun_az=62, sun_strength=4.0, sun_color=(1.0, 0.96, 0.90), sun_angle=0.55,
                exposure=1.8, cabin=1.0, night=False, rain=False),
    "golden": dict(hdri="qwantani_sunset_puresky", hdri_rot=34, hdri_strength=0.8, hdri_clamp=20,
                   sky_tint=(1.0, 0.74, 0.50), sun_elev=9, sun_az=65, sun_strength=3.2,
                   sun_color=(1.0, 0.52, 0.22), sun_angle=0.6, exposure=1.6, cabin=1.0, night=False, rain=False),
    "night": dict(hdri="kloppenheim_07_puresky", hdri_rot=90, hdri_strength=0.10, hdri_clamp=10,
                  sun_elev=-20, sun_az=60, sun_strength=0.0, sun_color=(1, 1, 1), sun_angle=0.5,
                  exposure=3.5, cabin=1.0, night=True, rain=False),
    "rain": dict(hdri="kloofendal_overcast_puresky", hdri_rot=120, hdri_strength=1.0, hdri_clamp=20,
                 sun_elev=40, sun_az=60, sun_strength=0.0, sun_color=(1, 1, 1), sun_angle=0.5,
                 exposure=1.8, cabin=1.0, night=False, rain=True),
}

HDRIS = sorted({p["hdri"] for p in PRESETS.values()})


def preset(name, **over):
    p = dict(PRESETS[name])
    p.update({k: v for k, v in over.items() if v is not None})
    return p


def sun_euler(elev, az):
    """Rotation for a sun lamp whose light comes FROM direction (elev, az) degrees."""
    el, a = math.radians(elev), math.radians(az)
    d = Vector((math.cos(el) * math.cos(a), math.cos(el) * math.sin(a), math.sin(el)))
    return d.to_track_quat("Z", "Y").to_euler()


def setup(scene, coll, name="day", **over):
    p = preset(name, **over)
    sun_d = bpy.data.lights.new("Sun", "SUN")
    sun_d.energy = p["sun_strength"]
    sun_d.color = p["sun_color"]
    sun_d.angle = math.radians(p["sun_angle"])
    sun = bpy.data.objects.new("Sun", sun_d)
    coll.objects.link(sun)
    sun.rotation_euler = sun_euler(p["sun_elev"], p["sun_az"])
    sun.hide_render = p["sun_strength"] <= 0

    w = bpy.data.worlds.new("Sky")
    scene.world = w
    if hasattr(w, "use_nodes") and not w.node_tree:
        w.use_nodes = True
    nt, ln = w.node_tree.nodes, w.node_tree.links
    for n in list(nt):
        if n.type != "OUTPUT_WORLD":
            nt.remove(n)
    bg = nt.new("ShaderNodeBackground")
    bg.inputs["Strength"].default_value = p["hdri_strength"]
    tc = nt.new("ShaderNodeTexCoord")
    mp = nt.new("ShaderNodeMapping")
    mp.inputs["Rotation"].default_value = (0, 0, math.radians(p["hdri_rot"]))
    ln.new(tc.outputs["Generated"], mp.inputs["Vector"])
    if p["hdri"]:
        env = nt.new("ShaderNodeTexEnvironment")
        env.image = load_image(assets.hdri(p["hdri"]), "Linear Rec.709")
        ln.new(mp.outputs["Vector"], env.inputs["Vector"])
        vm = nt.new("ShaderNodeVectorMath")
        vm.operation = "MINIMUM"
        vm.inputs[1].default_value = (p["hdri_clamp"],) * 3
        ln.new(env.outputs["Color"], vm.inputs[0])
        col = vm.outputs["Vector"]
        if p.get("sky_tint"):
            tm = nt.new("ShaderNodeVectorMath")
            tm.operation = "MULTIPLY"
            tm.inputs[1].default_value = tuple(p["sky_tint"])
            ln.new(col, tm.inputs[0])
            col = tm.outputs["Vector"]
        ln.new(col, bg.inputs["Color"])
    else:
        sky = nt.new("ShaderNodeTexSky")
        sky.sky_type = "NISHITA"
        sky.sun_elevation = math.radians(p["sun_elev"])
        sky.sun_rotation = math.radians(p["sun_az"])
        sky.sun_disc = False
        ln.new(mp.outputs["Vector"], sky.inputs["Vector"])
        ln.new(sky.outputs["Color"], bg.inputs["Color"])
        bg.inputs["Strength"].default_value = 0.25 * p["hdri_strength"]
    ln.new(bg.outputs[0], nt.get("World Output").inputs["Surface"])
    try:
        w.sun_threshold = 1e4   # EEVEE: don't extract a sun from the (clamped) HDRI
    except Exception:
        pass
    return SimpleNamespace(sun=sun, world=w, mapping=mp, background=bg, params=p)
