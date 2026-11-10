#!/bin/zsh
# Renders a fixed sample of the gallery (every default + pack style at two times, a pinned wall
# clock and weather, and the music presentations over Liquid Chrome from one fixture set) into
# <outDir>, each run on a fresh temp store, so a renderer change can be checked byte for byte:
#   tools/perf/gallery-sample.sh /tmp/before /tmp/fixtures      (on the old code)
#   tools/perf/gallery-sample.sh /tmp/after  /tmp/fixtures      (on the new code)
#   tools/perf/gallery-sample.sh --compare /tmp/before /tmp/after
# The fixtures dir is made once (tools/music-fixtures/make.sh) and reused, so the music renders match.
set -e
ROOT="${0:A:h:h:h}"
if [[ "$1" == "--compare" ]]; then
  n=0; bad=0; diffs=()
  for f in "$2"/*.png; do
    n=$((n + 1))
    if ! cmp -s "$f" "$3/${f:t}"; then bad=$((bad + 1)); diffs+=("${f:t}"); fi
  done
  echo "$n compared, $bad differ"
  # (Universe reads the real sun, and a music render the real clock: those two differ run to run.)
  [[ $bad -gt 0 ]] && xcrun swift "$ROOT/tools/perf/imgdiff.swift" "$2" "$3" "${diffs[@]}"
  [[ $bad -eq 0 ]]
  exit
fi
OUT="$1"; FIX="$2"
[[ -f "$FIX/playing.json" ]] || "$ROOT/tools/music-fixtures/make.sh" "$FIX" >/dev/null
mkdir -p "$OUT"
export GALLERY_BUILD="${GALLERY_BUILD:-$ROOT/.dd/gallery-sample}"
CLOCK=(--clock 10:30:15.25 --date 2026-06-21 --tz America/Toronto)
# the first run builds the gallery; the rest reuse its binary
run() { DOTSTUDIO_STORE_DIR="$(mktemp -d)" DOTSTUDIO_MUSIC_FAKE="$FIX/playing.json" "$GALLERY_BUILD/gallery" "$OUT" "$@" }
DOTSTUDIO_STORE_DIR="$(mktemp -d)" DOTSTUDIO_MUSIC_FAKE="$FIX/playing.json" "$ROOT/tools/gallery/render.sh" "$OUT" \
  --times 1.6,9 "${CLOCK[@]}" --weather rain --pack
run --times 2.5 "${CLOCK[@]}" --only "liquid chrome" --card bottomLeft --tag corner
run --times 2.5 "${CLOCK[@]}" --only "liquid chrome" --full veil --fade 0.5,1 --tag veil
run --times 2.5 "${CLOCK[@]}" --only "liquid chrome" --full art --tag art
run --times 1.6 "${CLOCK[@]}" --looks --only film --tag look
echo "$(ls "$OUT" | wc -l | tr -d ' ') renders in $OUT"
