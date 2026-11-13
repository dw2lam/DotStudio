#!/bin/zsh
# Builds the "film" engine pack for the DotStudio engines index:
#   dsfilm/ + run.py + job.py + fetch.py + templates (scenes/*) + guide.md (this folder's README) + engine.json
# as film-engine-<version>.zip plus its sha256. Caches, renders, .blend files and __pycache__ are
# never included (assets are fetched on the user's machine from CC0 sources).
#
# usage: tools/film/package.sh [OUT_DIR]        (default: tools/film/dist, git-ignored)
set -euo pipefail
HERE="${0:A:h}"
OUT="${1:-$HERE/dist}"
VER=$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$HERE/engine.json")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/film" "$OUT"
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '*.blend' --exclude '*.blend1' --exclude 'dist' \
  --exclude '*.png' --exclude '*.mov' --exclude '*.mp4' --exclude 'package.sh' --exclude '.gitignore' \
  "$HERE/dsfilm" "$HERE/scenes" "$HERE/run.py" "$HERE/job.py" "$HERE/fetch.py" "$HERE/engine.json" "$STAGE/film/"
cp "$HERE/README.md" "$STAGE/film/guide.md"
ZIP="$OUT/film-engine-$VER.zip"
rm -f "$ZIP"
(cd "$STAGE" && /usr/bin/zip -qrX "$ZIP" film)
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
BYTES=$(stat -f %z "$ZIP")
printf '{"id":"film","kind":"film","version":"%s","file":"%s","bytes":%s,"sha256":"%s"}\n' "$VER" "$(basename "$ZIP")" "$BYTES" "$SHA" > "$OUT/film-engine-$VER.index.json"
cat "$OUT/film-engine-$VER.index.json"
