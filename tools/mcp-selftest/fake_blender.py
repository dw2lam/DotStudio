#!/usr/bin/env python3
"""A stand-in for Blender for the self-test (never launch the real one in tests: it's gigabytes, and
two at once have crashed a 24 GB Mac). It takes Blender's command line as job.py builds it,

    fake_blender.py -b --factory-startup --python <toolkit>/run.py -- SPEC.json [run.py options]

checks it, logs what it was asked ("FAKE_BLENDER ..." lines), speaks run.py's PROGRESS / RESULT
protocol, and writes what run.py would: --still FILE (a PNG in the variant's colour) or --anim DIR
(DIR/0001.png … for the spec's loop, resumable; made with ffmpeg). No bpy, no GPU.

    FAKE_BLENDER_FRAME_S   seconds per frame / still (default 0.01): slow it down to test cancel/queue
    FAKE_BLENDER_FAIL      "1": fail like run.py does (RESULT ok:false, exit 1)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

COLORS = {"day": "0x8cb8e6", "golden": "0xf29e52", "night": "0x0f1430", "rain": "0x6b7885"}


def emit(tag, obj):
    print(f"{tag} {json.dumps(obj, separators=(',', ':'))}", flush=True)


def fail(msg, code=1):
    emit("RESULT", {"ok": False, "error": msg})
    sys.exit(code)


def opt(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("--") else True
    return default


def ffmpeg(*args):
    exe = shutil.which("ffmpeg")
    if not exe:
        fail("fake Blender: no ffmpeg on PATH")
    subprocess.run([exe, "-y", "-loglevel", "error", *args], check=True)


def main():
    argv = sys.argv[1:]
    print("FAKE_BLENDER argv " + json.dumps(argv), flush=True)
    if argv[:2] != ["-b", "--factory-startup"] or "--python" not in argv or "--" not in argv:
        fail("fake Blender: expected -b --factory-startup --python run.py -- SPEC …", 2)
    run_py = argv[argv.index("--python") + 1]
    if os.path.basename(run_py) != "run.py" or not os.path.isfile(run_py):
        fail(f"fake Blender: no run.py at {run_py}", 2)
    rest = argv[argv.index("--") + 1:]
    with open(rest[0]) as f:
        spec = json.load(f)
    print("FAKE_BLENDER spec " + json.dumps({"look": spec.get("look"), "loop": spec.get("loop"), "scene": spec.get("scene")}), flush=True)
    variant = opt(rest, "--variant") or spec.get("variant", "day")
    w, h = (int(x) for x in (opt(rest, "--res") or "640x360").split("x"))
    dt = float(os.environ.get("FAKE_BLENDER_FRAME_S", "0.01"))
    emit("PROGRESS", {"stage": "build", "done": 0, "of": 1})
    time.sleep(dt)
    emit("PROGRESS", {"stage": "build", "done": 1, "of": 1, "elapsed_s": dt})
    if os.environ.get("FAKE_BLENDER_FAIL") == "1":
        print("Traceback (most recent call last):\n  ...\nRuntimeError: fake failure", flush=True)
        fail("RuntimeError: fake failure")
    outputs = []
    color = COLORS.get(variant, "0x808080")
    if opt(rest, "--still"):
        path = opt(rest, "--still")
        samples = int(opt(rest, "--samples") or 64)
        for d in (samples // 4, samples // 2, samples):
            emit("PROGRESS", {"stage": "sample", "of_what": "still", "done": d, "of": samples})
            time.sleep(dt)
        ffmpeg("-f", "lavfi", "-i", f"color=c={color}:s={w}x{h}", "-frames:v", "1", path)
        outputs.append(path)
    if opt(rest, "--anim"):
        d = opt(rest, "--anim")
        os.makedirs(d, exist_ok=True)
        loop = spec.get("loop", {})
        n = round(loop.get("seconds", 24) * loop.get("fps", 24))
        a, b = (int(x) for x in (opt(rest, "--frames") or f"1-{n}").split("-"))
        fps = loop.get("fps", 24)
        with tempfile.TemporaryDirectory() as td:
            # a band of light drifting across once per loop (seamless), over the variant's colour
            ffmpeg("-f", "lavfi", "-i", f"color=c={color}:s={w}x{h}:r={fps}", "-vf",
                   f"drawbox=x='mod(t*{w * fps / n},{w})':y=0:w={max(w // 10, 2)}:h={h}:color=white@0.25:t=fill",
                   "-frames:v", str(b - a + 1), "-start_number", str(a), os.path.join(td, "%04d.png"))
            for f in range(a, b + 1):
                p = os.path.join(d, f"{f:04d}.png")
                if os.path.exists(p):
                    continue
                time.sleep(dt)
                shutil.move(os.path.join(td, f"{f:04d}.png"), p)
                left = sum(1 for g in range(f + 1, b + 1) if not os.path.exists(os.path.join(d, f"{g:04d}.png")))
                emit("PROGRESS", {"stage": "frame", "frame": f, "done": f - a + 1, "of": b - a + 1,
                                  "frame_s": dt, "eta_s": round(dt * left, 2)})
        outputs.append(d)
    emit("RESULT", {"ok": True, "outputs": outputs, "timings": {}, "variant": variant, "spec": rest[0]})


if __name__ == "__main__":
    main()
