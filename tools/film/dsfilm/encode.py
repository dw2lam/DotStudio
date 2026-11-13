"""Encoding (plain python3 + ffmpeg; no Blender needed).

    python3 -I tools/film/dsfilm/encode.py FRAMES_DIR OUT_BASE [--fps 24] [--quality 62] [--no-preview]
        -> OUT_BASE.mov            HEVC Main10 (hvc1), VideoToolbox, constant quality: the app's clip
           OUT_BASE-preview.mp4    H.264 1280x800 preview (not with --no-preview)
    python3 -I tools/film/dsfilm/encode.py --web FRAMES_DIR OUT_BASE [--size 1280:800] [--max-mb 4]
        -> OUT_BASE-web.webm (VP9) and OUT_BASE-web.mp4 (H.264), two-pass to fit --max-mb each
    python3 -I tools/film/dsfilm/encode.py --seam FRAMES_DIR
        -> last->first frame difference vs the typical frame-to-frame step (a seamless loop is ~1x)

The loop is frames 1..N with frame N+1 == frame 1, so the encoded clip loops with no duplicate.
The film look (halation, bloom, vignette) is baked by the render (dsfilm.post); grain is never
encoded — the app adds it live. --vignette/--grain exist for one-off experiments only.
"""
import glob
import os
import subprocess
import sys
import tempfile


def _frames(d):
    fs = sorted(glob.glob(os.path.join(d, "[0-9]" * 4 + ".png")))
    if not fs:
        raise SystemExit(f"no frames in {d}")
    return fs


def _input(frames_dir, fps):
    fs = _frames(frames_dir)
    first = int(os.path.basename(fs[0])[:4])
    return ["-framerate", str(fps), "-start_number", str(first), "-i", os.path.join(frames_dir, "%04d.png")], len(fs)


def encode(frames_dir, out_base, fps=24, vignette=0.0, grain=0, quality=62, preview_size="1280:800", preview=True):
    inp, _ = _input(frames_dir, fps)
    vf = []
    if vignette:
        vf.append(f"vignette=angle={vignette}:mode=forward")
    if grain:
        vf.append(f"noise=alls={grain}:allf=t")
    common = ["ffmpeg", "-y", "-loglevel", "error"] + inp
    hevc = out_base + ".mov"
    subprocess.run(common + ["-vf", ",".join(vf + ["format=p010le"]), "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                             "-q:v", str(quality), "-tag:v", "hvc1", "-movflags", "+faststart", "-an", hevc], check=True)
    if not preview:
        return hevc, None
    prev = out_base + "-preview.mp4"
    subprocess.run(common + ["-vf", ",".join(vf + [f"scale={preview_size}:flags=lanczos", "format=yuv420p"]),
                             "-c:v", "libx264", "-crf", "20", "-preset", "slow", "-movflags", "+faststart", "-an", prev],
                   check=True)
    return hevc, prev


def web(frames_dir, out_base, fps=24, size="1280:800", max_mb=4.0):
    """Two-pass VP9 .webm and H.264 .mp4 for a web page, each aimed at ~92% of max_mb."""
    inp, n = _input(frames_dir, fps)
    seconds = n / fps
    kbps = int(max_mb * 8 * 1024 * 0.92 / seconds)
    vf = f"scale={size}:flags=lanczos,format=yuv420p"
    out = []
    with tempfile.TemporaryDirectory() as td:
        log = os.path.join(td, "pass")
        webm = out_base + "-web.webm"
        base = ["ffmpeg", "-y", "-loglevel", "error"] + inp + ["-vf", vf, "-c:v", "libvpx-vp9", "-b:v", f"{kbps}k",
                                                              "-row-mt", "1", "-deadline", "good", "-tile-columns", "2",
                                                              "-g", "240", "-an", "-passlogfile", log]
        subprocess.run(base + ["-pass", "1", "-cpu-used", "4", "-f", "null", os.devnull], check=True)
        subprocess.run(base + ["-pass", "2", "-cpu-used", "1", webm], check=True)
        out.append(webm)
        mp4 = out_base + "-web.mp4"
        base = ["ffmpeg", "-y", "-loglevel", "error"] + inp + ["-vf", vf, "-c:v", "libx264", "-preset", "slow",
                                                              "-b:v", f"{kbps}k", "-maxrate", f"{int(kbps * 1.6)}k",
                                                              "-bufsize", f"{kbps * 2}k", "-profile:v", "high", "-an",
                                                              "-passlogfile", log + "x"]
        subprocess.run(base + ["-pass", "1", "-f", "null", os.devnull], check=True)
        subprocess.run(base + ["-pass", "2", "-movflags", "+faststart", mp4], check=True)
        out.append(mp4)
    return out


def seam(frames_dir):
    """Mean abs difference last->first vs. the median consecutive step (needs Pillow + numpy)."""
    import numpy as np
    from PIL import Image
    fs = _frames(frames_dir)

    def load(p):
        return np.asarray(Image.open(p).convert("RGB").resize((320, 200)), dtype=np.float32)

    steps = []
    for i in range(0, len(fs) - 1, max(len(fs) // 48, 1)):
        steps.append(np.abs(load(fs[i + 1]) - load(fs[i])).mean())
    wrap = np.abs(load(fs[0]) - load(fs[-1])).mean()
    med = float(np.median(steps))
    return wrap, med, wrap / max(med, 1e-6), float(max(steps))


def _opts(a, spec):
    kw = {}
    for k, cast in spec.items():
        if k in a:
            i = a.index(k)
            kw[k[2:].replace("-", "_")] = cast(a[i + 1])
            del a[i:i + 2]
    return kw


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--seam":
        w, m, r, mx = seam(a[1])
        print(f"seam diff {w:.3f}  median step {m:.3f}  max step {mx:.3f}  ratio {r:.2f}")
    elif a and a[0] == "--web":
        kw = _opts(a, {"--fps": int, "--size": str, "--max-mb": float})
        print(web(a[1], a[2], **kw))
    else:
        kw = _opts(a, {"--fps": int, "--vignette": float, "--grain": float, "--quality": int})
        if "--no-preview" in a:
            a.remove("--no-preview")
            kw["preview"] = False
        print(encode(a[0], a[1], **kw))
