"""Builds and renders a film scene from a spec — the stable CLI the DotStudio MCP server calls.
Headless only (never opens the Blender UI):

    Blender -b --factory-startup --python tools/film/run.py -- SPEC.json [options]

    --variant NAME        lighting variant (default: the spec's)
    --stills DIR          render the spec's stills for this variant -> DIR/<name>.png
                          (+ <name>-grain.png preview grain if the look has grain,
                           + <name>-nopost.png when the still has "compare": true)
    --still FILE          one still (with --camera, --frame)
    --build-sequence DIR  the camera's "how it's made" stills: 1-clay, 2-materials (fast flat
                          light), 3-raytraced (no post), 4-graded (look + preview grain)
    --anim DIR            frames DIR/####.png, resumable (existing frames are skipped); --frames A-B
    --camera NAME, --frame N, --engine cycles|eevee, --res WxH, --samples N, --no-post
    --save FILE.blend     save the built scene

  Light layers (dsfilm.layers; the layered build, no film look, scene-linear half-float EXR):
    --layers-still PREFIX one frame (--frame N), every tile -> PREFIX-<tile>.exr + PREFIX-layers.json
                          (--full also renders PREFIX-full.exr: all lights but sun_low, to check
                           that the tiles add up)
    --layers-anim DIR     the loop, tile by tile -> DIR/<tile>/####.exr, resumable; --frames A-B;
                          DIR/layers-render.json (exposures, tints, s/frame per tile)
    --tiles a,b,...       only these tiles (default: all the scene declares + mask)
    --tile-samples k=n,.. per-tile EEVEE samples (default: dsfilm.layers.SAMPLE_SCALE x --samples /
                          the animation's: sun, sun_low 1/2, city 1/4, sky, cabin 1; mask 8)
    --res                 the TILE size (default: the spec's "layers": {"tile": [w, h]}, else 1600x1000)

Machine-readable output (one JSON object per line, after the tag; everything else is Blender's
log):
    PROGRESS {"stage": "build"|"still"|"frame"|"sample", "done": i, "of": n, "eta_s": s, ...}
    RESULT   {"ok": true, "outputs": [...paths], "timings": {...}, "variant": ..., "spec": ...}
    RESULT   {"ok": false, "error": "..."}            (and a non-zero exit)
"""
import json
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name, default=None):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("--") else True
    return default


def emit(tag, obj):
    print(f"{tag} {json.dumps(obj, separators=(',', ':'))}", flush=True)


def main():
    import bpy
    from dsfilm import assets, post, render, spec

    t_start = time.time()
    outputs, timings = [], {}
    sp = spec.load(argv[0])
    mod = spec.scene_module(sp["scene"], sp.get("scene_dir"))
    miss = assets.missing(getattr(mod, "ASSETS", []))
    if miss:
        emit("PROGRESS", {"stage": "fetch", "assets": miss})
        assets.fetch_all(miss)
    if hasattr(mod, "prepare"):
        mod.prepare()
    anim = sp.get("animation", {})
    is_layers = bool(opt("--layers-still") or opt("--layers-anim"))
    is_anim = bool(opt("--anim")) or is_layers
    res = tuple(int(v) for v in opt("--res").split("x")) if opt("--res") else (tuple(anim["res"]) if is_anim and "res" in anim else None)
    if is_layers and not opt("--res"):
        res = tuple((sp.get("layers") or {}).get("tile", (1600, 1000)))     # the contract's default tile
    samples = int(opt("--samples")) if opt("--samples") else (anim.get("samples") if is_anim else None)
    engine = opt("--engine") or (anim.get("engine") if is_anim else None)
    emit("PROGRESS", {"stage": "build", "done": 0, "of": 1})
    t = time.time()
    ctx, out = spec.build(sp, variant=opt("--variant"), engine=engine, res=res, samples=samples, layers=is_layers)
    timings["build_s"] = round(time.time() - t, 1)
    emit("PROGRESS", {"stage": "build", "done": 1, "of": 1, "elapsed_s": timings["build_s"]})
    scene = ctx.scene
    if opt("--no-post"):
        post.enable(scene, False)
    cams = out.get("cameras", {})
    cam_name = opt("--camera") or (anim.get("camera") if is_anim else None) or next(iter(cams), None)
    grain = (ctx.look or {}).get("grain")

    # per-sample progress from Cycles/EEVEE's own status line
    state = {"what": None}

    def stats(s):
        if state["what"] is None:
            return
        txt = s if isinstance(s, str) else str(s)
        if "Sample" in txt:
            try:
                frag = txt.split("Sample")[1].strip().split()[0]
                d, n = frag.split("/")[:2]
                d, n = int(d), int(n.strip(",|"))
                if d != state.get("last") and (d == n or d - state.get("last", 0) >= max(n // 16, 1) or d < state.get("last", 0)):
                    state["last"] = d           # ~16 lines per render, not one per status update
                    emit("PROGRESS", {"stage": "sample", "of_what": state["what"], "done": d, "of": n})
            except Exception:
                pass
    bpy.app.handlers.render_stats.append(stats)

    def still(path, frame, cam, what):
        state["what"] = what
        dt = render.still(scene, path, frame, cams.get(cam))
        state["what"] = None
        outputs.append(path)
        timings[os.path.basename(path)] = round(dt, 1)
        return dt

    def with_grain(path):
        if grain:
            g = path[:-4] + "-grain.png"
            post.grain_preview(path, g, amount=grain.get("amount", 0.03))
            outputs.append(g)

    if opt("--save"):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(opt("--save")))
        outputs.append(os.path.abspath(opt("--save")))
    if opt("--still"):
        still(opt("--still"), int(opt("--frame", 1)), cam_name, "still")
        with_grain(opt("--still"))
    if opt("--stills"):
        d = opt("--stills")
        os.makedirs(d, exist_ok=True)
        todo = [s for s in sp.get("stills", []) if s.get("variant", sp.get("variant", "day")) == ctx.variant]
        for i, st in enumerate(todo):
            emit("PROGRESS", {"stage": "still", "done": i, "of": len(todo), "name": st["name"]})
            p = os.path.join(d, st["name"] + ".png")
            still(p, st.get("frame", 1), st.get("camera", cam_name), st["name"])
            with_grain(p)
            if st.get("compare") and ctx.look:
                post.enable(scene, False)
                still(os.path.join(d, st["name"] + "-nopost.png"), st.get("frame", 1), st.get("camera", cam_name),
                      st["name"] + "-nopost")
                post.enable(scene, True)
        emit("PROGRESS", {"stage": "still", "done": len(todo), "of": len(todo)})
    if opt("--build-sequence"):
        build_sequence(opt("--build-sequence"), scene, ctx, cams.get(cam_name), int(opt("--frame", 1)), still, with_grain)
    if is_layers:
        layers_mode(sp, scene, ctx, out, cams.get(cam_name), outputs, timings)
    elif is_anim:
        d = opt("--anim")
        os.makedirs(d, exist_ok=True)
        a, b = (opt("--frames") or f"1-{ctx.loop.frames}").split("-")
        a, b = int(a), int(b)
        post.enable(scene, bool(ctx.look) and not opt("--no-post"))
        done_t = []
        for f in range(a, b + 1):
            p = os.path.join(d, f"{f:04d}.png")
            if os.path.exists(p):
                continue
            state["what"] = f"frame {f}"
            dt = render.still(scene, p, f, cams.get(cam_name))
            state["what"] = None
            done_t.append(dt)
            left = sum(1 for g in range(f + 1, b + 1) if not os.path.exists(os.path.join(d, f"{g:04d}.png")))
            avg = sum(done_t[-24:]) / len(done_t[-24:])
            emit("PROGRESS", {"stage": "frame", "frame": f, "done": f - a + 1, "of": b - a + 1,
                              "frame_s": round(dt, 2), "eta_s": round(avg * left)})
        outputs.append(d)
        timings["frames_rendered"] = len(done_t)
        if done_t:
            timings["s_per_frame"] = round(sum(done_t) / len(done_t), 2)
    timings["total_s"] = round(time.time() - t_start, 1)
    emit("RESULT", {"ok": True, "outputs": outputs, "timings": timings, "variant": ctx.variant,
                    "camera": cam_name, "spec": os.path.abspath(argv[0])})


def layers_mode(sp, scene, ctx, out, cam, outputs, timings):
    """--layers-still / --layers-anim (see the module docstring and dsfilm.layers)."""
    from dsfilm import layers
    rig = layers.Rig(scene, out.get("layers"))
    layers.Rig.prepare(scene)
    if cam is not None:
        scene.camera = cam
    tiles = list(rig.tiles)
    if opt("--tiles"):
        want = [t for t in opt("--tiles").split(",") if t]
        bad = [t for t in want if t not in tiles + ["full"]]
        if bad:
            raise ValueError(f"--tiles: {', '.join(bad)} (the scene has {', '.join(tiles)})")
        tiles = want
    per = {}
    for kv in (opt("--tile-samples") or "").split(","):
        if "=" in kv:
            k, v = kv.split("=")
            per[k.strip()] = int(v)
    info = layers.manifest_info(sp, out["layers"], engine=ctx.engine)
    info.update({"tiles": [t for t in rig.tiles], "res": [scene.render.resolution_x, scene.render.resolution_y],
                 "engine": ctx.engine, "samples": {t: per.get(t) or rig.samples_for(t) for t in tiles},
                 "fps": ctx.loop.fps, "frames": ctx.loop.frames, "camera": scene.camera.name if scene.camera else None})
    if opt("--layers-still"):
        prefix = os.path.abspath(opt("--layers-still"))
        os.makedirs(os.path.dirname(prefix), exist_ok=True)
        frame = int(opt("--frame", 1))
        todo = tiles + (["full"] if opt("--full") and "full" not in tiles else [])
        for i, t in enumerate(todo):
            emit("PROGRESS", {"stage": "layer", "tile": t, "done": i, "of": len(todo)})
            bake = rig.use(t, per.get(t))
            p = f"{prefix}-{t}.exr"
            dt = rig.render(p, frame)
            outputs.append(p)
            timings[t] = round(dt, 1)
            timings[t + "_bake"] = round(bake, 1)
        emit("PROGRESS", {"stage": "layer", "done": len(todo), "of": len(todo)})
        info["frame"] = frame
        info["timings"] = timings
        with open(prefix + "-layers.json", "w") as f:
            json.dump(info, f, indent=1)
        outputs.append(prefix + "-layers.json")
        return
    d = os.path.abspath(opt("--layers-anim"))
    a, b = (opt("--frames") or f"1-{ctx.loop.frames}").split("-")
    frames = list(range(int(a), int(b) + 1))
    path = lambda t, f: os.path.join(d, t, f"{f:04d}.exr")
    todo = {t: [f for f in frames if not os.path.exists(path(t, f))] for t in tiles}
    total = sum(len(v) for v in todo.values())
    s_per = {}                      # measured seconds per frame, per tile
    done = 0
    t_layers = time.time()

    n_samples = info["samples"]

    def eta():
        # tiles not rendered yet: EEVEE's time is ~linear in samples (README "Light layers")
        per_sample = [v / n_samples[k] for k, v in s_per.items() if k != "mask"]
        if not per_sample:
            return None
        c = sum(per_sample) / len(per_sample)
        return sum(len(todo[t]) * s_per.get(t, 1.5 if t == "mask" else c * n_samples[t]) for t in tiles)

    for t in tiles:
        if not todo[t]:
            continue
        os.makedirs(os.path.join(d, t), exist_ok=True)
        emit("PROGRESS", {"stage": "layer", "tile": t, "done": done, "of": total})
        bake = rig.use(t, per.get(t))
        timings[t + "_bake"] = round(bake, 1)
        dts = []
        while todo[t]:
            f = todo[t][0]
            dt = rig.render(path(t, f), f)
            todo[t].pop(0)
            dts.append(dt)
            s_per[t] = sum(dts[-24:]) / len(dts[-24:])
            done += 1
            e = eta()
            emit("PROGRESS", {"stage": "frame", "tile": t, "frame": f, "done": done, "of": total,
                              "frame_s": round(dt, 2), **({"eta_s": round(e)} if e is not None else {})})
        timings[t + "_s_per_frame"] = round(sum(dts) / len(dts), 2)
    timings["layers_s"] = round(time.time() - t_layers, 1)
    info["timings"] = timings
    info["frames_range"] = [frames[0], frames[-1]]
    with open(os.path.join(d, "layers-render.json"), "w") as f:
        json.dump(info, f, indent=1)
    outputs.append(d)


def build_sequence(d, scene, ctx, cam, frame, still, with_grain):
    """1 clay, 2 materials under fast flat light, 3 full ray tracing without post, 4 graded."""
    import bpy
    from dsfilm import post, render
    os.makedirs(d, exist_ok=True)
    if cam is not None:
        scene.camera = cam
    rs = scene.render
    engine0, samples0 = rs.engine, scene.cycles.samples
    # 1 — clay: every surface but glass and lamps swapped for one neutral clay, sun + sky as is
    clay = bpy.data.materials.new("Clay")
    clay.node_tree.nodes.get("Principled BSDF").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)
    clay.node_tree.nodes.get("Principled BSDF").inputs["Roughness"].default_value = 0.7
    keep = lambda m: m is None or any(k in m.name for k in ("Glass", "Lamp", "Glint"))
    saved = []
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        for i, slot in enumerate(ob.material_slots):
            if not keep(slot.material):
                saved.append((ob, i, slot.material, slot.link))
                slot.link = "OBJECT"
                slot.material = clay
    post.enable(scene, False)
    scene.cycles.samples = 128
    still(os.path.join(d, "1-clay.png"), frame, None, "clay")
    for ob, i, m, link in saved:
        ob.material_slots[i].link = link
        if link == "OBJECT":
            ob.material_slots[i].material = m
    # 2 — materials, fast flat light: EEVEE without ray tracing, shadows or GI
    render.setup(scene, engine="eevee", res=(rs.resolution_x, rs.resolution_y), samples=16,
                 exposure=scene.view_settings.exposure)
    e = scene.eevee
    e.use_raytracing = False
    e.use_shadows = False
    e.use_fast_gi = False
    still(os.path.join(d, "2-materials.png"), frame, None, "materials")
    # 3 — full path tracing, no post; 4 — graded (look baked) + preview grain
    render.setup(scene, engine="cycles", res=(rs.resolution_x, rs.resolution_y), samples=samples0,
                 exposure=scene.view_settings.exposure)
    still(os.path.join(d, "3-raytraced.png"), frame, None, "raytraced")
    if ctx.look:
        post.enable(scene, True)
        p = os.path.join(d, "4-graded.png")
        still(p, frame, None, "graded")
        with_grain(p)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        traceback.print_exc()
        emit("RESULT", {"ok": False, "error": f"{type(e).__name__}: {e}"})
        sys.stdout.flush()
        os._exit(1)
