#!/usr/bin/env python3
"""The film job driver: what the DotStudio MCP server runs (plain python3 3.9+, outside Blender).

It wraps run.py (Blender headless, one process per variant) and dsfilm/encode.py so a whole job
(all variants; for a loop, render then encode) is one process that the MCP server runs detached,
and it turns run.py's PROGRESS lines into the MCP's progress file.

    python3 -I job.py env                       {"python", "pillow", "ffmpeg", "toolkit"} as JSON
    python3 -I job.py templates                 the scene templates as JSON (scenes/*/template.json)
    python3 -I job.py validate SPEC.json        {"ok", "diagnostics": [...], "warnings": [...]} (no Blender)
    python3 -I job.py stills --blender B --spec SPEC --out DIR --work DIR --variants day,night
                            [--res 1280x720] [--samples 64] [--lock FILE] [--dry-run]
        -> DIR/<variant>.png (Cycles; the look baked in)
    python3 -I job.py loop   --blender B --spec SPEC --out DIR --work DIR --variants day
                            [--seconds 24] [--fps 24] [--res 3840x2160] [--quality draft|standard|final]
                            [--lock FILE] [--keep-frames] [--dry-run]
        -> DIR/<variant>.mov (HEVC Main10 hvc1); frames in WORK/<variant>/frames (resumable)

Progress: JSON {"fraction": 0..1, "stage": "...", "eta_s": seconds} written atomically to the path
in $DSFILM_PROGRESS. Blender's own log and run.py's PROGRESS/RESULT lines pass through to stdout.
The last line is "RESULT {json}" as in run.py; failures exit 1.

One Blender at a time: each Blender process holds an exclusive lock on --lock (jobs queue behind
each other), and waits while any other process named Blender runs on this Mac (a render someone
started by hand). --dry-run prints the Blender command lines ("BLENDER <argv>") without running.

The spec's "look" may use DotStudio's 0..1 sliders ({"bloom": 0.25, "halation": 0.15, "grain": 0.2})
or dsfilm.post's own blocks; sliders are converted here (resolve_spec) so that the defaults equal
post.DEFAULT. Grain is never baked into video (the app adds it live); for stills it only drives the
-grain.png preview.
"""
import ast
import contextlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(ROOT, "run.py")
VARIANTS = ["day", "golden", "night", "rain"]

# dsfilm.post.DEFAULT, and the slider value that maps to it (keep in step with MCP/Film.swift FilmLook).
POST_DEFAULT = {
    "bloom": {"strength": 0.08, "threshold": 3.0, "size": 0.55},
    "halation": {"strength": 0.35, "threshold": 2.0, "size": 0.22, "tint": [1.0, 0.32, 0.10]},
    "grain": {"amount": 0.018},
}
SLIDER_DEFAULT = {"bloom": 0.25, "halation": 0.15, "grain": 0.2}
QUALITY = {
    # engine None = the spec's animation engine (EEVEE unless it says otherwise)
    "draft": {"engine": None, "samples": 16, "scale": 0.5},
    "standard": {"engine": None, "samples": None, "scale": 1.0},
    "final": {"engine": "cycles", "samples": 128, "scale": 1.0},
}
CC0_PREFIXES = ("ph:hdri:", "ph:tex:", "ph:model:", "acg:")


class JobError(Exception):
    pass


def emit(tag, obj):
    print(f"{tag} {json.dumps(obj, separators=(',', ':'))}", flush=True)


# ------------------------------------------------------------------------------------------ look

def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def toolkit_look(look):
    """DotStudio sliders -> dsfilm.post blocks (dict values pass through; 0 turns an effect off)."""
    if not isinstance(look, dict):
        return look
    out = {}
    for k, v in look.items():
        if k in ("bloom", "halation") and _num(v):
            if v > 0:
                b = dict(POST_DEFAULT[k])
                b["strength"] = round(POST_DEFAULT[k]["strength"] * v / SLIDER_DEFAULT[k], 4)
                out[k] = b
        elif k == "grain" and _num(v):
            if v > 0:
                out[k] = {"amount": round(POST_DEFAULT["grain"]["amount"] * v / SLIDER_DEFAULT["grain"], 4)}
        else:
            out[k] = v
    return out


def slider_look(look):
    """dsfilm.post blocks -> DotStudio sliders (the inverse of toolkit_look; others kept)."""
    if not isinstance(look, dict):
        return dict(SLIDER_DEFAULT)
    out = dict(look)
    for k in ("bloom", "halation"):
        if isinstance(look.get(k), dict):
            s = look[k].get("strength", POST_DEFAULT[k]["strength"])
            out[k] = round(min(max(s / POST_DEFAULT[k]["strength"] * SLIDER_DEFAULT[k], 0), 1), 3)
    if isinstance(look.get("grain"), dict):
        a = look["grain"].get("amount", POST_DEFAULT["grain"]["amount"])
        out["grain"] = round(min(max(a / POST_DEFAULT["grain"]["amount"] * SLIDER_DEFAULT["grain"], 0), 1), 3)
    return out


def resolve_spec(sp, seconds=None, fps=None):
    """The spec run.py renders: the look in dsfilm.post's form, the loop as asked."""
    r = json.loads(json.dumps(sp))
    if "look" in r:
        r["look"] = toolkit_look(r["look"])
    if seconds is not None or fps is not None:
        loop = dict(r.get("loop") or {})
        if seconds is not None:
            loop["seconds"] = seconds
        if fps is not None:
            loop["fps"] = fps
        r["loop"] = loop
    return r


# ------------------------------------------------------------------------------------------ scenes

def scene_dir(sp):
    if sp.get("scene") == "local" or sp.get("scene_dir"):
        return sp.get("scene_dir")
    return os.path.join(ROOT, "scenes", str(sp.get("scene")))


def module_info(path):
    """ASSETS / VARIANTS / CAMERAS literals and whether build() is defined, from scene.py's AST."""
    with open(path, encoding="utf-8") as f:
        src = f.read()
    tree = ast.parse(src, filename=path)
    info = {"build": False, "prepare": False, "imports": set()}

    def module_level(body):
        """Module-level statements, including those inside with / if / try / for blocks."""
        for node in body:
            yield node
            for field in ("body", "orelse", "finalbody", "handlers"):
                sub = getattr(node, field, None)
                if isinstance(sub, list) and not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    yield from module_level(sub)

    for node in module_level(tree.body):
        if isinstance(node, ast.FunctionDef) and node.name in ("build", "prepare"):
            info[node.name] = True
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            for t in (node.targets if isinstance(node, ast.Assign) else [node.target]):
                if isinstance(t, ast.Name) and t.id in ("ASSETS", "VARIANTS", "CAMERAS"):
                    try:
                        info[t.id] = ast.literal_eval(node.value)
                    except Exception:
                        info[t.id] = None          # computed (e.g. read from assets.json): present, not checkable
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            info["imports"].update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            info["imports"].add(node.module.split(".")[0])
    return info


def templates():
    out = []
    root = os.path.join(ROOT, "scenes")
    for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        d = os.path.join(root, name)
        tp = os.path.join(d, "template.json")
        meta = {}
        if os.path.exists(tp):
            with open(tp) as f:
                meta = json.load(f)
        spec_file = os.path.join(d, meta.get("spec", f"{name}.json"))
        if not os.path.exists(spec_file) or not os.path.exists(os.path.join(d, "scene.py")):
            continue
        with open(spec_file) as f:
            sp = json.load(f)
        info = module_info(os.path.join(d, "scene.py"))
        sp["look"] = slider_look(sp.get("look"))
        sp.setdefault("name", meta.get("name", name.title()))
        params = []
        for p in meta.get("params", []):
            p = dict(p)
            if p["key"] in sp.get("params", {}):
                p["default"] = sp["params"][p["key"]]
            params.append(p)
        if not meta.get("params"):
            for k, v in sp.get("params", {}).items():
                if _num(v):
                    params.append({"key": k, "kind": "number", "default": v, "label": k.replace("_", " ")})
                elif isinstance(v, list) and len(v) == 3 and all(_num(x) for x in v):
                    params.append({"key": k, "kind": "rgb", "default": v, "label": k.replace("_", " ")})
        out.append({"id": meta.get("id", name), "name": meta.get("name", name.title()),
                    "summary": meta.get("summary", ""), "order": meta.get("order", 100),
                    "variants": info.get("VARIANTS") or VARIANTS, "cameras": info.get("CAMERAS") or [],
                    "loop": sp.get("loop", {"seconds": 24, "fps": 24}), "params": params, "spec": sp})
    out.sort(key=lambda t: (t.pop("order"), t["id"]))
    return out


# ------------------------------------------------------------------------------------------ validate

def validate(sp):
    diags, warns = [], []

    def err(msg, file=None, line=None, column=None):
        d = {"message": msg, "severity": "error"}
        if file:
            d["file"] = file
        if line:
            d["line"] = line
            d["column"] = column or 1
        diags.append(d)

    if not isinstance(sp, dict):
        err("the spec must be a JSON object")
        return diags, warns
    scene = sp.get("scene")
    if not isinstance(scene, str) or not scene:
        err("spec needs `scene`: a template id (list_film_templates) or \"local\" with scene_files")
        return diags, warns
    d = scene_dir(sp)
    info = None
    if scene == "local" and not d:
        err("a \"local\" scene needs `scene_dir` (create_film_scene sets it from scene_files)")
    elif scene != "local" and not re.match(r"^[a-z0-9_]{1,40}$", scene):
        err(f"scene \"{scene}\" isn't a template id")
    elif not os.path.isfile(os.path.join(d, "scene.py")):
        err(f"no scene module \"{scene}\" in the film toolkit (list_film_templates)" if scene != "local"
            else f"no scene.py in {d}")
    else:
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".py"):
                continue
            try:
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    compile(f.read(), fn, "exec", dont_inherit=True)
            except SyntaxError as e:
                err(f"{fn}: {e.msg}", file=fn, line=e.lineno, column=e.offset)
            except UnicodeDecodeError:
                err(f"{fn} isn't UTF-8 text", file=fn)
        if not diags:
            info = module_info(os.path.join(d, "scene.py"))
            if not info.get("build"):
                err("scene.py has no build(ctx)", file="scene.py", line=1)
            if "ASSETS" not in info:
                err("scene.py has no ASSETS list (CC0 refs, may be empty)", file="scene.py", line=1)
            for ref in info.get("ASSETS") or []:
                if not isinstance(ref, str) or not ref.startswith(CC0_PREFIXES):
                    err(f"asset {ref!r}: only CC0 sources — \"ph:hdri:<id>\", \"ph:tex:<id>\", \"ph:model:<id>\", \"acg:<id>\"",
                        file="scene.py")
            risky = info["imports"] & {"socket", "urllib", "requests", "http", "ftplib", "smtplib"}
            if scene == "local" and risky:
                warns.append(f"scene.py imports {', '.join(sorted(risky))}: downloads go through dsfilm.assets (CC0, logged), nothing else")
            aj = os.path.join(d, "assets.json")
            if os.path.exists(aj):
                try:
                    with open(aj) as f:
                        refs = json.load(f)
                    if not isinstance(refs, list):
                        err("assets.json must be a list of asset refs", file="assets.json")
                    else:
                        for ref in refs:
                            if not isinstance(ref, str) or not ref.startswith(CC0_PREFIXES):
                                err(f"assets.json: {ref!r} isn't a CC0 ref (ph:… or acg:…)", file="assets.json")
                except ValueError as e:
                    err(f"assets.json isn't JSON: {e}", file="assets.json")
    known_v = (info or {}).get("VARIANTS") or VARIANTS
    known_c = (info or {}).get("CAMERAS") or None
    vs = sp.get("variants")
    if vs is not None and (not isinstance(vs, list) or not vs):
        err("variants must be a non-empty list")
        vs = None
    for v in (vs or []) + ([sp["variant"]] if "variant" in sp else []):
        if v not in VARIANTS:
            err(f"variant \"{v}\" isn't one of {', '.join(VARIANTS)}")
        elif v not in known_v:
            err(f"the scene has no \"{v}\" lighting (it has {', '.join(known_v)})")
    loop = sp.get("loop", {})
    if not isinstance(loop, dict):
        err("loop must be {\"seconds\": s, \"fps\": n}")
    else:
        s, f = loop.get("seconds", 24), loop.get("fps", 24)
        if not _num(s) or not 1 <= s <= 600:
            err("loop.seconds must be 1–600")
        elif not isinstance(f, int) or isinstance(f, bool) or not 1 <= f <= 60:
            err("loop.fps must be a whole number 1–60")
        elif abs(s * f - round(s * f)) > 1e-6:
            err(f"loop.seconds × loop.fps = {s * f:g}: it must be a whole number of frames")
    for key in ("render", "animation"):
        r = sp.get(key)
        if r is None:
            continue
        if not isinstance(r, dict):
            err(f"{key} must be an object")
            continue
        if "engine" in r and r["engine"] not in ("cycles", "eevee"):
            err(f"{key}.engine must be \"cycles\" or \"eevee\"")
        if "res" in r and not (isinstance(r["res"], list) and len(r["res"]) == 2
                               and all(isinstance(x, int) and 16 <= x <= 8192 for x in r["res"])):
            err(f"{key}.res must be [width, height] in pixels")
        if "samples" in r and not (isinstance(r["samples"], int) and 1 <= r["samples"] <= 8192):
            err(f"{key}.samples must be 1–8192")
        if key == "animation" and known_c and r.get("camera") not in (None, *known_c):
            err(f"animation.camera \"{r.get('camera')}\" isn't one of {', '.join(known_c)}")
    stills = sp.get("stills", [])
    if not isinstance(stills, list):
        err("stills must be a list")
    else:
        for i, st in enumerate(stills):
            if not isinstance(st, dict) or not re.match(r"^[A-Za-z0-9_-]{1,60}$", str(st.get("name", ""))):
                err(f"stills[{i}] needs a \"name\" (letters, digits, _ or -)")
            elif known_c and st.get("camera") not in (None, *known_c):
                err(f"stills[{i}].camera \"{st.get('camera')}\" isn't one of {', '.join(known_c)}")
    look = sp.get("look")
    if look is not None:
        if not isinstance(look, dict):
            err("look must be an object")
        else:
            for k, v in look.items():
                if k in ("bloom", "halation", "grain", "vignette") and _num(v):
                    if not 0 <= v <= 1:
                        err(f"look.{k} must be 0–1")
                elif k in ("bloom", "halation", "grain") and isinstance(v, dict):
                    pass
                elif k == "vignette" and v is None:
                    pass
                else:
                    warns.append(f"look.{k}: unknown or malformed (bloom, halation, grain, vignette)")
    if "params" in sp and not isinstance(sp["params"], dict):
        err("params must be an object")
    return diags, warns


# ------------------------------------------------------------------------------------------ jobs

class Progress:
    def __init__(self):
        self.path = os.environ.get("DSFILM_PROGRESS")
        self.t0 = time.time()

    def __call__(self, fraction, stage, eta_s=None):
        fraction = min(max(fraction, 0.0), 1.0)
        if eta_s is None and fraction > 0.03:
            eta_s = (time.time() - self.t0) / fraction * (1 - fraction)
        obj = {"fraction": round(fraction, 4), "stage": stage}
        if eta_s is not None:
            obj["eta_s"] = round(max(eta_s, 0))
        if self.path:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(obj, f)
            os.replace(tmp, self.path)


CHILD = {"p": None}


def _terminate(signum, _frame):
    p = CHILD["p"]
    if p and p.poll() is None:
        p.terminate()
    sys.exit(128 + signum)


def other_blender_running(blender):
    """Another process named like our Blender (only checked for the real app's binary)."""
    if os.path.basename(blender) != "Blender":
        return False
    try:
        r = subprocess.run(["/usr/bin/pgrep", "-x", "Blender"], capture_output=True, text=True)
    except OSError:
        return False
    return bool(r.stdout.split())


@contextlib.contextmanager
def blender_slot(lock, blender, progress, fraction, label):
    fd = None
    if lock:
        import fcntl
        os.makedirs(os.path.dirname(lock), exist_ok=True)
        fd = open(lock, "a+")
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                progress(fraction, f"{label}: queued behind another film render (one Blender at a time)")
                time.sleep(5)
    try:
        while other_blender_running(blender):
            progress(fraction, f"{label}: waiting for another Blender on this Mac to finish (one at a time)")
            time.sleep(10)
        yield
    finally:
        if fd:
            fd.close()


def run_blender(argv, on_progress):
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace", bufsize=1)
    CHILD["p"] = p
    result = None
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        tag, _, rest = line.strip().partition(" ")
        if tag in ("PROGRESS", "RESULT"):
            try:
                obj = json.loads(rest)
            except ValueError:
                continue
            if tag == "PROGRESS":
                on_progress(obj)
            else:
                result = obj
    rc = p.wait()
    CHILD["p"] = None
    if result and not result.get("ok"):
        raise JobError(result.get("error") or "the render failed")
    if result and rc != 0:
        # run.py finished (its outputs are checked by the caller); Blender fell over on its way out
        print(f"job.py: Blender exited with status {rc} after a successful RESULT; keeping the outputs", flush=True)
        return result
    if rc != 0:
        raise JobError(f"Blender exited with status {rc}")
    if not result:
        raise JobError("Blender finished without a RESULT line (did run.py run?)")
    return result


def blender_argv(blender, spec_path, *opts):
    return [blender, "-b", "--factory-startup", "--python", RUN, "--", spec_path] + [str(o) for o in opts]


def parse_res(s):
    m = re.match(r"^(\d+)x(\d+)$", s or "")
    if not m:
        raise JobError(f"--res {s!r}: use WxH")
    return int(m.group(1)), int(m.group(2))


def still_shot(sp, variant):
    """Camera and frame for a variant's still: its first spec still, else the first still, else the anim camera."""
    stills = sp.get("stills") or []
    st = next((s for s in stills if s.get("variant", sp.get("variant", "day")) == variant), None) or (stills[0] if stills else {})
    return st.get("camera") or (sp.get("animation") or {}).get("camera"), int(st.get("frame", 1))


def write_spec(work, sp):
    os.makedirs(work, exist_ok=True)
    path = os.path.join(work, "spec.json")
    with open(path, "w") as f:
        json.dump(sp, f, indent=2)
    return path


def stage_label(variants, i, v):
    return v if len(variants) == 1 else f"{v} ({i + 1}/{len(variants)})"


def cmd_stills(a):
    progress = Progress()
    with open(a.spec) as f:
        sp = json.load(f)
    spec_path = write_spec(a.work, resolve_spec(sp))
    w, h = parse_res(a.res)
    os.makedirs(a.out, exist_ok=True)
    n, outputs = len(a.variants), []
    for i, v in enumerate(a.variants):
        label = stage_label(a.variants, i, v)
        cam, frame = still_shot(sp, v)
        png = os.path.join(a.out, f"{v}.png")
        argv = blender_argv(a.blender, spec_path, "--variant", v, "--still", png, "--frame", frame,
                            "--res", f"{w}x{h}", "--samples", a.samples, "--engine", "cycles",
                            *(["--camera", cam] if cam else []))
        if a.dry_run:
            print("BLENDER " + shlex.join(argv), flush=True)
            continue

        def on(o, i=i, label=label):
            st = o.get("stage")
            if st == "fetch":
                progress((i + 0.02) / n, f"{label}: downloading CC0 assets")
            elif st == "build":
                progress((i + (0.3 if o.get("done") else 0.05)) / n, f"{label}: building the scene")
            elif st == "sample" and o.get("of"):
                progress((i + 0.3 + 0.7 * o["done"] / o["of"]) / n, f"{label}: sample {o['done']}/{o['of']}")

        progress(i / n, f"{label}: starting Blender")
        with blender_slot(a.lock, a.blender, progress, i / n, label):
            run_blender(argv, on)
        if not os.path.exists(png):
            raise JobError(f"the render left no {os.path.basename(png)}")
        outputs.append(png)
        progress((i + 1) / n, f"{label}: done", 0 if i + 1 == n else None)
    if not a.dry_run:
        progress(1.0, "done", 0)
    emit("RESULT", {"ok": True, "outputs": outputs, "dry_run": bool(a.dry_run)})


def cmd_loop(a):
    progress = Progress()
    with open(a.spec) as f:
        sp = json.load(f)
    loop = sp.get("loop") or {}
    seconds = a.seconds if a.seconds is not None else loop.get("seconds", 24)
    fps = a.fps if a.fps is not None else loop.get("fps", 24)
    frames = round(seconds * fps)
    if abs(seconds * fps - frames) > 1e-6 or frames < 2:
        raise JobError(f"{seconds} s × {fps} fps isn't a whole number of frames")
    q = QUALITY.get(a.quality)
    if q is None:
        raise JobError(f"quality {a.quality!r}: draft, standard or final")
    anim = sp.get("animation") or {}
    engine = q["engine"] or anim.get("engine", "eevee")
    samples = q["samples"] or anim.get("samples", 64)
    w, h = parse_res(a.res)
    scale = max(q["scale"], min(1.0, 960 / w))          # a draft is half size, but never under 960 px wide
    w, h = max(2, int(w * scale) // 2 * 2), max(2, int(h * scale) // 2 * 2)
    spec_path = write_spec(a.work, resolve_spec(sp, seconds=seconds, fps=fps))
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg and not a.dry_run:
        raise JobError("ffmpeg isn't installed (it encodes the clips): ask the user to install it, e.g. `brew install ffmpeg`")
    sys.path.insert(0, ROOT)
    from dsfilm import encode
    os.makedirs(a.out, exist_ok=True)
    n, outputs, frame_s = len(a.variants), [], []
    for i, v in enumerate(a.variants):
        label = stage_label(a.variants, i, v)
        vd = os.path.join(a.work, v)
        fd = os.path.join(vd, "frames")
        argv = blender_argv(a.blender, spec_path, "--variant", v, "--anim", fd, "--frames", f"1-{frames}",
                            "--res", f"{w}x{h}", "--samples", samples, "--engine", engine)
        if a.dry_run:
            print("BLENDER " + shlex.join(argv), flush=True)
            continue
        os.makedirs(fd, exist_ok=True)

        def on(o, i=i, label=label):
            st = o.get("stage")
            later = n - i - 1
            if st == "fetch":
                progress((i + 0.005) / n, f"{label}: downloading CC0 assets")
            elif st == "build":
                progress((i + (0.03 if o.get("done") else 0.01)) / n, f"{label}: building the scene")
            elif st == "frame" and o.get("of"):
                if o.get("frame_s"):
                    frame_s.append(o["frame_s"])
                avg = sum(frame_s[-24:]) / max(len(frame_s[-24:]), 1)
                eta = (o.get("eta_s") or 0) + later * avg * frames if frame_s else None
                progress((i + 0.03 + 0.92 * o["done"] / o["of"]) / n, f"{label}: frame {o['done']}/{o['of']}", eta)
            elif st == "sample" and o.get("of"):
                pass                                    # per-frame lines are enough for a loop

        progress(i / n, f"{label}: starting Blender ({engine}, {w}×{h}, {samples} samples, {frames} frames)")
        with blender_slot(a.lock, a.blender, progress, i / n, label):
            run_blender(argv, on)
        have = len([f for f in os.listdir(fd) if re.match(r"^\d{4}\.png$", f)])
        if have < frames:
            raise JobError(f"{v}: {have} of {frames} frames rendered")
        progress((i + 0.96) / n, f"{label}: encoding HEVC")
        base = os.path.join(vd, "clip")
        hevc, _ = encode.encode(fd, base, fps=fps, preview=False)
        dst = os.path.join(a.out, f"{v}.mov")
        os.replace(hevc, dst)
        outputs.append(dst)
        if not a.keep_frames:
            shutil.rmtree(fd, ignore_errors=True)     # 4K PNG frames are ~10 GB a variant
        progress((i + 1) / n, f"{label}: done")
    if not a.dry_run:
        progress(1.0, "done", 0)
    emit("RESULT", {"ok": True, "outputs": outputs, "frames": frames, "engine": engine, "samples": samples,
                    "res": [w, h], "dry_run": bool(a.dry_run)})


def parse_args(argv):
    import argparse
    p = argparse.ArgumentParser(prog="job.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("env")
    sub.add_parser("templates")
    v = sub.add_parser("validate")
    v.add_argument("spec")
    for name in ("stills", "loop"):
        s = sub.add_parser(name)
        s.add_argument("--blender", required=True)
        s.add_argument("--spec", required=True)
        s.add_argument("--out", required=True)
        s.add_argument("--work", required=True)
        s.add_argument("--variants", required=True, type=lambda x: [y for y in x.split(",") if y])
        s.add_argument("--lock")
        s.add_argument("--dry-run", action="store_true")
        if name == "stills":
            s.add_argument("--res", default="1280x720")
            s.add_argument("--samples", type=int, default=64)
        else:
            s.add_argument("--seconds", type=float)
            s.add_argument("--fps", type=int)
            s.add_argument("--res", default="3840x2160")
            s.add_argument("--quality", default="standard")
            s.add_argument("--keep-frames", action="store_true")
    a = p.parse_args(argv)
    if getattr(a, "seconds", None) is not None and a.seconds == int(a.seconds):
        a.seconds = int(a.seconds)
    return a


def main(argv):
    a = parse_args(argv)
    if a.cmd == "env":
        import importlib.util
        with open(os.path.join(ROOT, "engine.json")) as f:
            ver = json.load(f).get("version")
        print(json.dumps({"python": sys.version.split()[0], "pillow": importlib.util.find_spec("PIL") is not None,
                          "ffmpeg": shutil.which("ffmpeg"), "toolkit": ver}))
        return 0
    if a.cmd == "templates":
        print(json.dumps(templates()))
        return 0
    if a.cmd == "validate":
        with open(a.spec) as f:
            sp = json.load(f)
        d, w = validate(sp)
        print(json.dumps({"ok": not any(x["severity"] == "error" for x in d), "diagnostics": d, "warnings": w}))
        return 0
    signal.signal(signal.SIGTERM, _terminate)
    for v in a.variants:
        if v not in VARIANTS:
            raise JobError(f"variant {v!r}: {', '.join(VARIANTS)}")
    if not a.dry_run and not os.path.exists(a.blender):
        raise JobError(f"no Blender at {a.blender}")
    (cmd_stills if a.cmd == "stills" else cmd_loop)(a)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (JobError, OSError, ValueError, subprocess.CalledProcessError) as e:
        emit("RESULT", {"ok": False, "error": f"{e}"})
        sys.exit(1)
