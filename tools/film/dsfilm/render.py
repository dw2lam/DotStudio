"""Render setup and output.

    render.setup(scene, engine="cycles", res=(1600, 1000), samples=256, exposure=0.0,
                 motion_blur=True, look="AgX - Medium High Contrast")
    render.still(scene, path, frame=1, camera=None) -> seconds
    render.frames(scene, out_dir, first, last) -> seconds per frame

Engines:
  cycles  path traced on the Metal GPU, OpenImageDenoise. The reference look: real soft shadows,
          bounce light, glossy reflections. Budget on an M5 Pro: ~1-3 min per 1600x1000 still at
          256-512 samples for an interior lit through windows.
  eevee   Blender 5's ray-traced EEVEE (screen-space tracing + horizon-scan GI, virtual shadow
          maps with soft shadows). Seconds per frame; use for long animations once it is checked
          against a Cycles still of the same frame.
"""
import os
import time

import bpy


def setup(scene, engine="cycles", res=(1600, 1000), samples=None, exposure=0.0, motion_blur=True,
          shutter=0.5, look="AgX - Medium High Contrast", bit_depth="16"):
    r = scene.render
    r.resolution_x, r.resolution_y = res
    r.resolution_percentage = 100
    r.use_motion_blur = motion_blur
    r.motion_blur_shutter = shutter
    r.film_transparent = False
    r.image_settings.file_format = "PNG"
    r.image_settings.color_depth = bit_depth
    vs = scene.view_settings
    vs.view_transform = "AgX"
    try:
        vs.look = look
    except TypeError:
        pass
    vs.exposure = exposure
    if engine == "cycles":
        r.engine = "CYCLES"
        cy = scene.cycles
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            prefs.compute_device_type = "METAL"
            prefs.get_devices()
            for d in prefs.devices:
                d.use = d.type != "CPU"
            cy.device = "GPU"
        except Exception as e:
            print("cycles: GPU unavailable,", e)
        cy.samples = samples or 256
        cy.use_adaptive_sampling = True
        cy.adaptive_threshold = 0.01
        cy.use_denoising = True
        cy.denoiser = "OPENIMAGEDENOISE"
        try:
            cy.denoising_use_gpu = True
        except Exception:
            pass
        cy.max_bounces = 8
        cy.diffuse_bounces = 4
        cy.glossy_bounces = 4
        cy.transparent_max_bounces = 16
        cy.sample_clamp_indirect = 10.0
        cy.caustics_reflective = cy.caustics_refractive = False
        cy.blur_glossy = 1.0
        # memory: tile the frame and cap texture size (a 24 GB Mac shares RAM with the GPU)
        cy.use_auto_tile = True
        cy.tile_size = 1024
        try:
            cy.texture_limit_render = "2048"
        except Exception:
            pass
        try:
            cy.use_light_tree = True
        except Exception:
            pass
    else:
        r.engine = "BLENDER_EEVEE"
        e = scene.eevee
        e.taa_render_samples = samples or 64
        e.use_raytracing = True
        e.ray_tracing_method = "SCREEN"
        e.ray_tracing_options.resolution_scale = "1"
        e.ray_tracing_options.use_denoise = True
        e.ray_tracing_options.trace_max_roughness = 0.5
        e.use_fast_gi = True
        e.fast_gi_method = "GLOBAL_ILLUMINATION"
        e.fast_gi_resolution = "2"
        e.fast_gi_ray_count = 4
        e.fast_gi_step_count = 8
        e.fast_gi_distance = 3.0
        e.use_shadows = True
        e.shadow_ray_count = 2
        e.shadow_step_count = 8
        e.shadow_resolution_scale = 1.0
        e.motion_blur_steps = 1
        e.gi_diffuse_bounces = 3
        e.clamp_surface_indirect = 10.0


def eevee_probes(scene, volumes=(), spheres=()):
    """Adds and bakes EEVEE light probes. Interiors need a volume probe: without one EEVEE lights
    them with the unoccluded sky (flat, far too bright, no window light). volumes: [(centre,
    half_size, (rx, ry, rz))], spheres: [(centre, radius)]. The bake is static (taken at the current
    frame); moving sunlight still comes from the lamp's ray-traced shadows."""
    coll = scene.collection
    for i, (c, hs, res) in enumerate(volumes):
        d = bpy.data.lightprobes.new(f"Volume{i}", "VOLUME")
        d.resolution_x, d.resolution_y, d.resolution_z = res
        ob = bpy.data.objects.new(f"Volume{i}", d)
        ob.location, ob.scale = c, hs
        coll.objects.link(ob)
    for i, (c, r) in enumerate(spheres):
        d = bpy.data.lightprobes.new(f"Sphere{i}", "SPHERE")
        d.influence_distance = r
        ob = bpy.data.objects.new(f"Sphere{i}", d)
        ob.location = c
        coll.objects.link(ob)
    t = time.time()
    with bpy.context.temp_override(scene=scene):
        bpy.ops.object.lightprobe_cache_bake(subset="ALL")
    print(f"PROBES baked in {time.time() - t:.1f}s", flush=True)


def still(scene, path, frame=1, camera=None):
    if camera is not None:
        scene.camera = camera
    scene.frame_set(frame)
    scene.render.filepath = os.path.abspath(path)
    t = time.time()
    bpy.ops.render.render(write_still=True)
    dt = time.time() - t
    print(f"RENDER {os.path.basename(path)} frame={frame} {dt:.1f}s", flush=True)
    return dt


def frames(scene, out_dir, first, last, camera=None):
    """Renders frames into out_dir/####.png; skips frames already there (resumable)."""
    if camera is not None:
        scene.camera = camera
    scene.frame_start, scene.frame_end = first, last
    scene.render.filepath = os.path.join(os.path.abspath(out_dir), "")
    scene.render.use_overwrite = False
    scene.render.use_placeholder = True
    t = time.time()
    bpy.ops.render.render(animation=True)
    per = (time.time() - t) / max(last - first + 1, 1)
    print(f"ANIM {first}-{last} {per:.2f}s/frame", flush=True)
    return per
