#!/bin/zsh
# Before/after: runs two already-built harnesses (PERF_BUILD dirs, see run.sh) back to back,
# alternating, `rounds` times each, on the same fixtures — so clock-speed drift hits both alike.
# Compare per row: the lowest CPU of the rounds; allocation counts are exact.
# usage: tools/perf/ab.sh <baseDir> <newDir> <mode> [rounds] [harness args…]
set -e
ROOT="${0:A:h:h:h}"
BASE="$1"; NEW="$2"; MODE="$3"; ROUNDS="${4:-2}"
shift 4 || shift $#
FIX="$(mktemp -d)"
"$ROOT/tools/music-fixtures/make.sh" "$FIX" >/dev/null
for r in $(seq 1 $ROUNDS); do
  for which in BASE NEW; do
    dir=${(P)which}
    STORE="$(mktemp -d)"
    echo "== $which round $r"
    DOTSTUDIO_STORE_DIR="$STORE" DOTSTUDIO_MUSIC_FAKE="$FIX/playing.json" PERF_FIXTURES="$FIX" "$dir/perf" "$MODE" "$@" \
      | grep -v "^warning: the saver"
    rm -rf "$STORE"
  done
done
rm -rf "$FIX"
