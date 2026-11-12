"""Encoding (plain python3 + ffmpeg; no Blender needed).

    python3 -I tools/film/dsfilm/encode.py FRAMES_DIR OUT_BASE [--fps 24] [--vignette 0.35] [--grain 0]
        -> OUT_BASE.mov   HEVC (hvc1), VideoToolbox, 10-bit main10, constant quality, loop-ready
           OUT_BASE-preview.mp4   H.264 1280x800 preview
    python3 -I tools/film/dsfilm/encode.py --seam FRAMES_DIR       # how different the last frame is from the first
                                                        # vs a typical frame step (want ~1.0)

The loop is frames 1..N with frame N+1 == frame 1, so the encoded clip loops with no duplicate.
Vignette and grain are applied here (cheap, tunable) rather than in the render.
"""
import glob
import os
import subprocess
import sys


def _frames(d):
    fs = sorted(glob.glob(os.path.join(d, "[0-9]" * 4 + ".png")))
    if not fs:
        raise SystemExit(f"no frames in {d}")
    return fs


def encode(frames_dir, out_base, fps=24, vignette=0.35, grain=0, quality=62, preview_size="1280:800"):
    fs = _frames(frames_dir)
    first = int(os.path.basename(fs[0])[:4])
    vf = []
    if vignette:
        vf.append(f"vignette=angle={vignette}:mode=forward")
    if grain:
        vf.append(f"noise=alls={grain}:allf=t")
    common = ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-start_number", str(first),
              "-i", os.path.join(frames_dir, "%04d.png")]
    hevc = out_base + ".mov"
    subprocess.run(common + (["-vf", ",".join(vf + ["format=p010le"])] if vf else ["-vf", "format=p010le"]) +
                   ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-q:v", str(quality), "-tag:v", "hvc1",
                    "-movflags", "+faststart", "-an", hevc], check=True)
    prev = out_base + "-preview.mp4"
    subprocess.run(common + ["-vf", ",".join(vf + [f"scale={preview_size}:flags=lanczos", "format=yuv420p"]),
                             "-c:v", "libx264", "-crf", "20", "-preset", "slow", "-movflags", "+faststart", "-an", prev],
                   check=True)
    return hevc, prev


def seam(frames_dir):
    """Mean abs difference last->first vs. the median consecutive step (needs Pillow + numpy)."""
    import numpy as np
    from PIL import Image
    fs = _frames(frames_dir)

    def load(p):
        return np.asarray(Image.open(p).convert("RGB").resize((320, 200)), dtype=np.float32)

    steps = []
    idx = list(range(0, len(fs) - 1, max(len(fs) // 24, 1)))
    for i in idx:
        steps.append(np.abs(load(fs[i + 1]) - load(fs[i])).mean())
    wrap = np.abs(load(fs[0]) - load(fs[-1])).mean()
    med = float(np.median(steps))
    return wrap, med, wrap / max(med, 1e-6)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--seam":
        w, m, r = seam(a[1])
        print(f"seam diff {w:.3f}  median step {m:.3f}  ratio {r:.2f}")
    else:
        kw = {}
        for k in ("--fps", "--vignette", "--grain", "--quality"):
            if k in a:
                i = a.index(k)
                kw[k[2:]] = float(a[i + 1]) if k != "--fps" else int(a[i + 1])
                del a[i:i + 2]
        print(encode(a[0], a[1], **kw))
