"""Relight test, phase 1: render Commute's wide camera (frame 1, EEVEE, the loop's settings) as
separate light layers — sun only, sky only, cabin lamps only, everything — plus a window mask.
Linear EXRs into OUT. Run:
  nice -n 10 Blender -b --factory-startup --python passes.py -- OUT [WxH]
"""
import os
import sys
import time

FILM = os.path.expanduser("~/Developer/DotStudio/tools/film")
sys.path.insert(0, FILM)
argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
RES = tuple(int(v) for v in argv[1].split("x")) if len(argv) > 1 else (1920, 1200)
os.makedirs(OUT, exist_ok=True)

import bpy
from dsfilm import post, spec

sp = spec.load(os.path.join(FILM, "scenes/commute/commute.json"))
mod = spec.scene_module(sp["scene"])
mod.prepare()
t0 = time.time()
ctx, out = spec.build(sp, variant="day", engine="eevee", res=RES, samples=sp["animation"]["samples"])
print(f"BUILD {time.time() - t0:.1f}s", flush=True)
scene = ctx.scene
post.enable(scene, False)
scene.camera = out["cameras"]["wide"]
scene.frame_set(1)
rs = scene.render
rs.image_settings.file_format = "OPEN_EXR"
rs.image_settings.color_depth = "16"
rs.image_settings.exr_codec = "ZIP"

rig = out["rig"]
sun_energy = rig.sun.data.energy
sky_strength = rig.background.inputs["Strength"].default_value
cabin_lights = [o for o in bpy.data.objects if o.type == "LIGHT" and o.name.startswith("CabinLight")]
cabin_energy = {o.name: o.data.energy for o in cabin_lights}
emitters = []          # (socket, value): every unlinked emission strength > 0 (diffusers, door screen, glint)
for m in bpy.data.materials:
    if not m.node_tree:
        continue
    for n in m.node_tree.nodes:
        for key in ("Emission Strength", "Strength"):
            s = n.inputs.get(key) if n.type in ("BSDF_PRINCIPLED", "EMISSION") else None
            if s is not None and not s.is_linked and s.default_value > 0:
                emitters.append((s, s.default_value))
print("EMITTERS", [(s.node.id_data.name if hasattr(s.node, "id_data") else "?", v) for s, v in emitters], flush=True)


def lights(sun, sky, cabin):
    rig.sun.data.energy = sun_energy * sun
    rig.sun.hide_render = sun == 0
    rig.background.inputs["Strength"].default_value = sky_strength * sky
    for o in cabin_lights:
        o.data.energy = cabin_energy[o.name] * cabin
        o.hide_render = cabin == 0
    for s, v in emitters:
        s.default_value = v * cabin


def rebake():
    t = time.time()
    with bpy.context.temp_override(scene=scene):
        bpy.ops.object.lightprobe_cache_bake(subset="ALL")
    print(f"REBAKE {time.time() - t:.1f}s", flush=True)


def shot(name):
    rs.filepath = os.path.join(OUT, name + ".exr")
    t = time.time()
    bpy.ops.render.render(write_still=True)
    print(f"RENDER {name} {time.time() - t:.1f}s", flush=True)


ONLY = argv[2] if len(argv) > 2 else None
if ONLY != "sun_low":
    for name, (a, b, c) in {"full": (1, 1, 1), "sun": (1, 0, 0), "sky": (0, 1, 0), "cabin": (0, 0, 1)}.items():
        lights(a, b, c)
        rebake()
        shot(name)
# a second sun layer: the golden preset's low warm sun (elevation 9, azimuth 65, its colour and strength)
from dsfilm import lighting
g = lighting.PRESETS["golden"]
rig.sun.animation_data_clear()
rig.sun.rotation_euler = lighting.sun_euler(g["sun_elev"], g["sun_az"])
rig.sun.data.color = g["sun_color"]
sun_energy = g["sun_strength"]
lights(1, 0, 0)
rebake()
shot("sun_low")
if ONLY == "sun_low":
    print("DONE", flush=True)
    raise SystemExit

# window mask: glass white, everything else black, no lights, black world
lights(0, 0, 0)
white = bpy.data.materials.new("MaskWhite")
black = bpy.data.materials.new("MaskBlack")
for mat, v in ((white, 1.0), (black, 0.0)):
    nt = mat.node_tree.nodes
    nt.remove(nt.get("Principled BSDF"))
    em = nt.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (v, v, v, 1)
    mat.node_tree.links.new(em.outputs[0], nt.get("Material Output").inputs["Surface"])
glass = set()
for ob in bpy.data.objects:
    if ob.type != "MESH":
        continue
    for slot in ob.material_slots:
        is_glass = slot.material is not None and "Glass" in slot.material.name
        if is_glass:
            glass.add(slot.material.name)
        slot.link = "OBJECT"
        slot.material = white if is_glass else black
print("GLASS", sorted(glass), flush=True)
scene.eevee.use_raytracing = False
scene.eevee.use_fast_gi = False
scene.eevee.taa_render_samples = 16
rs.use_motion_blur = True
shot("mask")
print("DONE", flush=True)
