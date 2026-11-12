"""CC0 asset fetching with a local cache and a licence log.

Runs both from plain python3 (``python3 -I tools/film/fetch.py <scene>``) and inside Blender. Every
download goes into the cache (``$DOTSTUDIO_FILM_CACHE`` or ``~/Library/Caches/DotStudio-film``),
never into the repo, is md5-checked when the source publishes a hash, and is recorded in
``<cache>/LICENSES.tsv`` (path, source page, licence, date).

Sources (both CC0, no attribution required, but we log them anyway):
  Poly Haven  https://polyhaven.com  — HDRIs, PBR textures, models (public API: api.polyhaven.com)
  ambientCG   https://ambientcg.com  — PBR materials (zip per material)

Asset references are short strings a scene lists in its ASSETS:
  "ph:hdri:<id>[@4k]"           -> <cache>/hdri/<id>_4k.hdr
  "ph:tex:<id>[@2k]"            -> <cache>/tex/<id>/<id>_{diff,nor_gl,rough}_2k.jpg
  "ph:model:<id>[@1k]"          -> <cache>/models/<id>/<id>_1k.blend (+ textures/)
  "acg:<id>[@2K]"               -> <cache>/acg/<id>/<id>_2K-JPG_{Color,NormalGL,Roughness,...}.jpg
"""
import datetime
import hashlib
import json
import os
import subprocess
import zipfile

CACHE = os.environ.get("DOTSTUDIO_FILM_CACHE", os.path.expanduser("~/Library/Caches/DotStudio-film"))
UA = "dotstudio-film/1.0"


def cache(*p):
    return os.path.join(CACHE, *p)


# ------------------------------------------------------------------------------------------ paths

def hdri(aid, res="4k"):
    return cache("hdri", f"{aid}_{res}.hdr")


def tex(aid, mp, res="2k"):
    """Poly Haven texture map path; mp in diff, nor_gl, rough, ao, disp, arm."""
    return cache("tex", aid, f"{aid}_{mp}_{res}.jpg")


def model(aid, res="1k"):
    return cache("models", aid, f"{aid}_{res}.blend")


def acg(aid, mp, res="2K"):
    """ambientCG map path; mp in Color, NormalGL, Roughness, Displacement, Emission, Metalness."""
    return cache("acg", aid, f"{aid}_{res}-JPG_{mp}.jpg")


# ------------------------------------------------------------------------------------------ fetch

# curl rather than urllib: python.org builds ship without CA certificates.
def _get_json(url):
    out = subprocess.run(["curl", "-fsSL", "-A", UA, "--max-time", "60", url], check=True, capture_output=True)
    return json.loads(out.stdout)


def _md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def _download(url, dest, md5=None):
    if os.path.exists(dest) and (md5 is None or _md5(dest) == md5):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    print("  get", url, flush=True)
    subprocess.run(["curl", "-fsSL", "-A", UA, "--retry", "3", "-o", tmp, url], check=True)
    if md5 and _md5(tmp) != md5:
        os.remove(tmp)
        raise RuntimeError(f"md5 mismatch for {url}")
    os.replace(tmp, dest)
    return dest


def _log(path, page, licence="CC0"):
    log = cache("LICENSES.tsv")
    rows = {}
    if os.path.exists(log):
        for line in open(log):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                rows[parts[0]] = parts
    rows[path] = [path, page, licence, datetime.date.today().isoformat()]
    os.makedirs(CACHE, exist_ok=True)
    with open(log, "w") as f:
        for r in sorted(rows.values()):
            f.write("\t".join(r) + "\n")


def fetch(ref):
    """Fetches one asset reference (see module doc). Returns the main local path."""
    ref, _, res = ref.partition("@")
    kind = ref.split(":")
    if kind[0] == "ph" and kind[1] == "hdri":
        aid, res = kind[2], res or "4k"
        f = _get_json(f"https://api.polyhaven.com/files/{aid}")["hdri"][res]["hdr"]
        p = _download(f["url"], hdri(aid, res), f["md5"])
        _log(os.path.relpath(p, CACHE), f"https://polyhaven.com/a/{aid}")
        return p
    if kind[0] == "ph" and kind[1] == "tex":
        aid, res = kind[2], res or "2k"
        files = _get_json(f"https://api.polyhaven.com/files/{aid}")
        for key, mp in (("Diffuse", "diff"), ("nor_gl", "nor_gl"), ("Rough", "rough")):
            if key in files:
                f = files[key][res]["jpg"]
                _download(f["url"], tex(aid, mp, res), f["md5"])
        _log(f"tex/{aid}/", f"https://polyhaven.com/a/{aid}")
        return cache("tex", aid)
    if kind[0] == "ph" and kind[1] == "model":
        aid, res = kind[2], res or "1k"
        b = _get_json(f"https://api.polyhaven.com/files/{aid}")["blend"][res]["blend"]
        root = cache("models", aid)
        p = _download(b["url"], os.path.join(root, os.path.basename(b["url"])), b["md5"])
        for rel, inc in b.get("include", {}).items():
            if ".." in rel or rel.startswith("/"):
                continue
            _download(inc["url"], os.path.join(root, rel), inc["md5"])
        _log(f"models/{aid}/", f"https://polyhaven.com/a/{aid}")
        return p
    if kind[0] == "acg":
        aid, res = kind[1], res or "2K"
        z = _download(f"https://ambientcg.com/get?file={aid}_{res}-JPG.zip", cache("acg", f"{aid}_{res}-JPG.zip"))
        out = cache("acg", aid)
        if not os.path.exists(acg(aid, "Color", res)):
            os.makedirs(out, exist_ok=True)
            with zipfile.ZipFile(z) as zf:
                for n in zf.namelist():   # flat image files only
                    if "/" in n or "\\" in n or n.startswith(".") or not n.lower().endswith((".jpg", ".png")):
                        continue
                    with zf.open(n) as src, open(os.path.join(out, n), "wb") as dst:
                        dst.write(src.read())
        _log(f"acg/{aid}/", f"https://ambientcg.com/view?id={aid}")
        return out
    raise ValueError(f"unknown asset ref {ref}")


def fetch_all(refs):
    for r in refs:
        fetch(r)
    return CACHE


def missing(refs):
    """The refs whose files are not in the cache yet (cheap, no network)."""
    out = []
    for r in refs:
        ref, _, res = r.partition("@")
        k = ref.split(":")
        if k[:2] == ["ph", "hdri"]:
            ok = os.path.exists(hdri(k[2], res or "4k"))
        elif k[:2] == ["ph", "tex"]:
            ok = os.path.exists(tex(k[2], "diff", res or "2k"))
        elif k[:2] == ["ph", "model"]:
            ok = os.path.exists(model(k[2], res or "1k"))
        elif k[0] == "acg":
            ok = os.path.exists(acg(k[1], "Color", res or "2K"))
        else:
            ok = False
        if not ok:
            out.append(r)
    return out
