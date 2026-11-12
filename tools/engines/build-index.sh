#!/bin/zsh
# Builds DotStudio's pullable engines for the GitHub release tagged `engines`:
#   <out>/<id>-<version>.dsengine.json   one per tools/engines/<id>/<version>/ (an EngineBundle:
#                                         {"format":1,"id","version","files":{path: base64}})
#   <out>/engines-index.json              {"format":1,"engines":[{id, version, url, sha256, size,
#                                         minApp, summary}]} — url relative to the index
# The app (CustomScenes.pullEngine) downloads the index, picks the newest compatible version,
# checks the bundle's size and SHA-256 against it, and installs it into <store>/engines/<id>/<version>/.
# Offline testing: DOTSTUDIO_ENGINES_INDEX=<out>/engines-index.json points the app at a local copy.
#
# usage: tools/engines/build-index.sh <outDir>
#   then: gh release upload engines <outDir>/* --clobber   (by hand: never run by this script)
set -e
ROOT="${0:A:h:h:h}"
OUT="${1:?usage: build-index.sh <outDir>}"
mkdir -p "$OUT"
python3 -I - "$ROOT/tools/engines" "$OUT" <<'EOF'
import base64, hashlib, json, os, sys

src, out = sys.argv[1], sys.argv[2]
allowed = {".json", ".h", ".metal", ".md", ".glsl", ".txt", ".png", ".jpg"}
entries = []
for eid in sorted(os.listdir(src)):
    edir = os.path.join(src, eid)
    if eid.startswith(".") or not os.path.isdir(edir):
        continue
    for ver in sorted(os.listdir(edir)):
        vdir = os.path.join(edir, ver)
        if ver.startswith(".") or not os.path.isdir(vdir):
            continue
        with open(os.path.join(vdir, "engine.json"), "rb") as f:
            manifest = json.load(f)
        if manifest.get("id") != eid or manifest.get("version") != ver:
            sys.exit(f"{vdir}: engine.json says {manifest.get('id')} {manifest.get('version')}")
        files = {}
        for dirpath, dirnames, filenames in os.walk(vdir):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.startswith("."):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, vdir).replace(os.sep, "/")
                if os.path.splitext(name)[1].lower() not in allowed:
                    sys.exit(f"{rel}: the app won't install a {os.path.splitext(name)[1]} file")
                if rel.count("/") > 3:
                    sys.exit(f"{rel}: nested too deep (4 levels at most)")
                if os.path.islink(path):
                    sys.exit(f"{rel}: symlinks aren't allowed")
                with open(path, "rb") as f:
                    files[rel] = base64.b64encode(f.read()).decode("ascii")
        bundle = {"format": 1, "id": eid, "version": ver, "files": files}
        data = json.dumps(bundle, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(data) > 4 * 1024 * 1024:
            sys.exit(f"{eid} {ver}: bundle is {len(data)} bytes (4 MB at most)")
        name = f"{eid}-{ver}.dsengine.json"
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        entries.append({
            "id": eid, "version": ver, "url": name,
            "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
            "minApp": manifest.get("minApp"), "summary": manifest.get("summary", ""),
        })
        print(f"{name}: {len(files)} files, {len(data)} bytes, sha256 {entries[-1]['sha256'][:16]}…")
with open(os.path.join(out, "engines-index.json"), "w") as f:
    json.dump({"format": 1, "engines": entries}, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"engines-index.json: {len(entries)} engine(s)")
EOF
