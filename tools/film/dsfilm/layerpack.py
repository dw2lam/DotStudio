"""Packs light-layer tiles (dsfilm.layers' EXRs) into a layered film package's video + manifest block
(docs/film-layers.md). Plain python3 + numpy + ffmpeg; no Blender. (No numpy in the system
python? Blender's bundled one has it: <Blender.app>/Contents/Resources/<ver>/python/bin/python3.x;
job.py picks it automatically.)

    python3 -I dsfilm/layerpack.py pack DIR OUT [--fps 24] [--quality 70] [--encoder auto|videotoolbox|x265]
                                       [--sample 96]
        DIR = run.py --layers-anim output (DIR/<tile>/####.exr + DIR/layers-render.json)
        -> OUT/layers.mov  HEVC Main10 (hvc1), the tiles in a 3x2 grid, pow4-coded, loops seamlessly
           OUT/layers.json the manifest's "layers" block
    python3 -I dsfilm/layerpack.py check DIR OUT/layers.mov [--frames 1,12,24]
        decodes the video and compares every tile with its EXR (after the pow4 decode)
    python3 -I dsfilm/layerpack.py scales DIR [--sample 96]      the per-tile scales only

Coding (the contract): light tiles store v = clamp(linear / scale, 0, 1) ^ (1/4) per channel,
decoded linear = scale * v^4; `scale` per tile = the 99.95th percentile of the per-pixel max
channel over the loop (every frame, or an even sample of --sample frames). The mask tile stores
the matte directly. The RGB atlas is converted to Y'CbCr here (BT.709 matrix, video range,
4:2:0 with 2x2-averaged chroma) and tagged BT.709 / video range: a reader must undo exactly
that matrix and range and apply no colour management (the values are data, not pictures).
"""
import glob
import json
import os
import shutil
import subprocess
import sys

import numpy as np

TILES = ("sun", "sun_low", "sky", "cabin", "city", "mask")
GRID = (3, 2)
PERCENTILE = 99.95
KR, KB = 0.2126, 0.0722
KG = 1 - KR - KB


# ------------------------------------------------------------------------------------------ io

def _size(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    w, h = r.stdout.strip().split(",")[:2]
    return int(w), int(h)


def read_exr(path, size=None, gray=False, half=True):
    """A scene-linear RGB EXR -> float32 (H, W, 3), or its red channel (H, W) with gray=True.

    Uses ffmpeg's EXR decoder in the file's NATIVE format: asking it for another float format runs
    swscale, which clamps to 0..1 (a half EXR read as gbrpf32le loses every highlight). It can't
    read Blender's one-channel "BW" EXRs either, so the mask is written RGB too. half=False for
    32-bit EXRs."""
    w, h = size or _size(path)
    fmt, dt = ("gbrpf16le", "<f2") if half else ("gbrpf32le", "<f4")
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", fmt, "-"],
                       capture_output=True, check=True)
    g, b, rr = np.frombuffer(r.stdout, dt).astype(np.float32).reshape(3, h, w)
    if gray:
        return rr.copy()
    return np.stack([rr, g, b], axis=-1)


def tile_frames(d, tile):
    return sorted(glob.glob(os.path.join(d, tile, "[0-9]" * 4 + ".exr")))


def render_info(d):
    p = os.path.join(d, "layers-render.json")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    return {}


# ------------------------------------------------------------------------------------------ coding

def round_up(x, digits=3):
    """x rounded UP to `digits` significant figures (so the stored scale never clips more)."""
    if x <= 0:
        return 1e-4
    e = np.floor(np.log10(x)) - (digits - 1)
    return float(np.ceil(x / 10 ** e) * 10 ** e)


def scales(d, tiles, sample=96, size=None):
    """Per light tile: the PERCENTILE of the per-pixel max channel over (a sample of) the loop."""
    out = {}
    for t in tiles:
        if t == "mask":
            continue
        fs = tile_frames(d, t)
        if not fs:
            raise SystemExit(f"no frames for tile {t} in {d}")
        if len(fs) > sample:
            fs = [fs[round(i * (len(fs) - 1) / (sample - 1))] for i in range(sample)]
        # exact pooled percentile: the k-th largest of all sampled pixels is among each frame's top k
        top, k = [], None
        for p in fs:
            m = read_exr(p, size).max(axis=-1).ravel()
            if k is None:
                k = max(1, int(np.ceil(len(m) * len(fs) * (100 - PERCENTILE) / 100)))
            kk = min(k, len(m))
            top.append(np.partition(m, len(m) - kk)[len(m) - kk:])
        allv = np.concatenate(top)
        out[t] = round_up(float(np.partition(allv, len(allv) - k)[len(allv) - k]))
    return out


def encode_tile(lin, scale):
    return np.clip(lin / scale, 0.0, 1.0) ** 0.25


def decode_tile(v, scale):
    return scale * v.astype(np.float32) ** 4


def atlas(d, tiles, frame_name, sc, size):
    """One frame's atlas, 0..1 float32 (2H, 3W, 3), tiles left->right then top->bottom."""
    w, h = size
    cols, rows = GRID
    a = np.zeros((rows * h, cols * w, 3), np.float32)
    for i, t in enumerate(tiles):
        p = os.path.join(d, t, frame_name)
        y, x = (i // cols) * h, (i % cols) * w
        if t == "mask":
            a[y:y + h, x:x + w, :] = np.clip(read_exr(p, size, gray=True), 0, 1)[..., None]
        else:
            a[y:y + h, x:x + w, :] = encode_tile(read_exr(p, size), sc[t])
    return a


def rgb_to_yuv420p10(a):
    """0..1 R'G'B' (H, W, 3) -> BT.709 video-range 10-bit planar 4:2:0 bytes (yuv420p10le)."""
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    y = KR * r + KG * g + KB * b
    cb = (b - y) / (2 * (1 - KB))
    cr = (r - y) / (2 * (1 - KR))
    h, w = y.shape
    cb = cb.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    cr = cr.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3))
    Y = np.clip(np.rint(64 + 876 * y), 0, 1023).astype("<u2")
    U = np.clip(np.rint(512 + 896 * cb), 0, 1023).astype("<u2")
    V = np.clip(np.rint(512 + 896 * cr), 0, 1023).astype("<u2")
    return Y.tobytes() + U.tobytes() + V.tobytes()


def yuv420p10_to_rgb(buf, w, h):
    """The inverse (what a reader does): yuv420p10le bytes -> 0..1 R'G'B' (H, W, 3), chroma upsampled
    by pixel replication."""
    a = np.frombuffer(buf, "<u2").astype(np.float32)
    Y = a[:w * h].reshape(h, w)
    U = a[w * h:w * h + w * h // 4].reshape(h // 2, w // 2)
    V = a[w * h + w * h // 4:].reshape(h // 2, w // 2)
    U = U.repeat(2, 0).repeat(2, 1)
    V = V.repeat(2, 0).repeat(2, 1)
    y = (Y - 64) / 876
    cb = (U - 512) / 896
    cr = (V - 512) / 896
    r = y + 2 * (1 - KR) * cr
    b = y + 2 * (1 - KB) * cb
    g = (y - KR * r - KB * b) / KG
    return np.clip(np.stack([r, g, b], -1), 0, 1)


def has_encoder(name):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True)
    return any(line.split()[1:2] == [name] for line in r.stdout.splitlines() if line.strip())


def encoder_args(encoder, quality):
    """VideoToolbox HEVC Main10 (constant quality, like encode.py) or libx265 main10 (crf)."""
    if encoder == "auto":
        encoder = "videotoolbox" if has_encoder("hevc_videotoolbox") else "x265"
    if encoder == "videotoolbox":
        return ["-pix_fmt", "p010le", "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-q:v", str(quality)]
    crf = max(0, min(51, round(40 - quality * 0.3)))          # q 70 -> crf 19
    return ["-pix_fmt", "yuv420p10le", "-c:v", "libx265", "-profile:v", "main10", "-crf", str(crf), "-preset", "medium",
            "-x265-params", "log-level=error"]


# ------------------------------------------------------------------------------------------ pack

def pack(d, out_dir, fps=None, quality=70, encoder="auto", sample=96, progress=None, file_in_package="clips/layers.mov"):
    info = render_info(d)
    tiles = [t for t in (info.get("tiles") or TILES) if os.path.isdir(os.path.join(d, t))]
    if len(tiles) > GRID[0] * GRID[1]:
        raise SystemExit(f"{len(tiles)} tiles don't fit a {GRID[0]}x{GRID[1]} grid")
    names = [os.path.basename(p) for p in tile_frames(d, tiles[0])]
    for t in tiles[1:]:
        have = {os.path.basename(p) for p in tile_frames(d, t)}
        missing = [n for n in names if n not in have]
        if missing or len(have) != len(names):
            raise SystemExit(f"tile {t}: {len(have)} frames, {tiles[0]} has {len(names)} (missing e.g. {missing[:3]})")
    if not names:
        raise SystemExit(f"no layer frames in {d}")
    size = _size(os.path.join(d, tiles[0], names[0]))
    w, h = size
    if w % 2 or h % 2:
        raise SystemExit(f"tile {w}x{h}: width and height must be even (4:2:0)")
    fps = fps or info.get("fps", 24)
    if progress:
        progress(0.0, "measuring tile scales")
    sc = scales(d, tiles, sample=sample, size=size)
    os.makedirs(out_dir, exist_ok=True)
    mov = os.path.join(out_dir, "layers.mov")
    tmp = mov + ".part.mov"
    W, H = GRID[0] * w, GRID[1] * h
    cmd = ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-s", f"{W}x{H}",
           "-framerate", str(fps), "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709",
           "-color_trc", "bt709", "-i", "-"] + encoder_args(encoder, quality) + [
           "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-tag:v", "hvc1", "-movflags", "+faststart", "-an", tmp]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    try:
        for i, n in enumerate(names):
            p.stdin.write(rgb_to_yuv420p10(atlas(d, tiles, n, sc, size)))
            if progress:
                progress((i + 1) / len(names), f"packing frame {i + 1}/{len(names)}")
        p.stdin.close()
    except BrokenPipeError:
        pass
    if p.wait() != 0:
        raise SystemExit(f"ffmpeg failed encoding {mov}")
    os.replace(tmp, mov)
    block = {"file": file_in_package, "grid": list(GRID), "tiles": tiles, "encoding": "pow4", "scale": sc}
    if info.get("exposure"):
        block["exposure"] = info["exposure"]
    if info.get("tint"):
        block["tint"] = info["tint"]
    with open(os.path.join(out_dir, "layers.json"), "w") as f:
        json.dump(block, f, indent=1)
    return mov, block


# ------------------------------------------------------------------------------------------ check

def decode_frames(mov, w, h, frames):
    """Decoded frames (1-based indices) of a video as yuv420p10le bytes, in one ffmpeg pass."""
    sel = "+".join(f"eq(n\\,{f - 1})" for f in frames)
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", mov, "-vf", f"select={sel}", "-vsync", "0",
                        "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"], capture_output=True, check=True)
    n = w * h * 3 // 2 * 2
    return [r.stdout[i * n:(i + 1) * n] for i in range(len(r.stdout) // n)]


def check(d, mov, frames=None, block=None):
    """Per tile and frame: mean |decoded - EXR| relative to the EXR's mean (light tiles, linear),
    and the mask's mean absolute error. Returns {tile: {"rel_err": .., "p99_rel": ..}}."""
    if block is None:
        with open(os.path.join(os.path.dirname(mov), "layers.json")) as f:
            block = json.load(f)
    tiles = block["tiles"]
    W, H = _size(mov)
    w, h = W // block["grid"][0], H // block["grid"][1]
    names = [os.path.basename(p) for p in tile_frames(d, tiles[0])]
    frames = frames or sorted({1, len(names) // 2 + 1, len(names)})
    res = {t: [] for t in tiles}
    for f, buf in zip(frames, decode_frames(mov, W, H, frames)):
        rgb = yuv420p10_to_rgb(buf, W, H)
        for i, t in enumerate(tiles):
            y, x = (i // block["grid"][0]) * h, (i % block["grid"][0]) * w
            v = rgb[y:y + h, x:x + w]
            p = os.path.join(d, t, names[f - 1])
            if t == "mask":
                ref = np.clip(read_exr(p, (w, h), gray=True), 0, 1)
                res[t].append({"frame": f, "mae": float(np.abs(v.mean(-1) - ref).mean())})
                continue
            sc = block["scale"][t]
            ref = read_exr(p, (w, h))
            dec = decode_tile(v, sc)
            clipped = np.minimum(ref, sc)               # what the coding can hold at best
            mean = max(float(ref.mean()), 1e-6)
            err = np.abs(dec - clipped)
            # quantisation alone (pow4, 10-bit video range), for comparison
            q = decode_tile(np.rint(encode_tile(ref, sc) * 876) / 876, sc)
            res[t].append({"frame": f, "rel_err": float(err.mean() / mean),
                           "rel_err_p99": float(np.percentile(err.mean(-1), 99) / mean),
                           "quant_rel_err": float(np.abs(q - clipped).mean() / mean),
                           "clipped_frac": float((ref.max(-1) > sc).mean())})
    return res


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
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg isn't installed")
    cmd = a.pop(0) if a else ""
    if cmd == "pack":
        kw = _opts(a, {"--fps": int, "--quality": int, "--encoder": str, "--sample": int})
        if "--progress" in a:           # job.py: machine-readable progress lines
            a.remove("--progress")
            last = [0.0]

            def report(fraction, stage):
                if fraction >= 1 or fraction - last[0] >= 0.01 or fraction == 0:
                    last[0] = fraction
                    print("PROGRESS " + json.dumps({"fraction": round(fraction, 4), "stage": stage}), flush=True)
            kw["progress"] = report
        mov, block = pack(a[0], a[1], **kw)
        print(json.dumps({"mov": mov, "layers": block}))
    elif cmd == "check":
        kw = _opts(a, {"--frames": lambda s: [int(x) for x in s.split(",")]})
        print(json.dumps(check(a[0], a[1], **kw), indent=1))
    elif cmd == "scales":
        kw = _opts(a, {"--sample": int})
        print(json.dumps(scales(a[0], render_info(a[0]).get("tiles") or TILES, **kw)))
    else:
        print(__doc__)
        sys.exit(2)
