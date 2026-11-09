#!/bin/zsh
# Times a renderer from nothing to its first frame — what the screensaver pays before it shows
# anything — cold (MTL_SHADER_CACHE_SIZE=0: the system shader cache off, as on the first start
# after an update, when the new metallib is in no cache) and warm. Each case is a fresh process.
# Builds Shared/* + main.swift + a metallib (like tools/gallery/render.sh), never the app.
#
# usage: tools/startup/run.sh [--only name] [--size 3024x1964] [--runs 3]
#   STARTUP_SOURCES=<dir holding a Shared/ tree> times other sources, e.g. the commit before
#   this harness (git archive <rev> Shared | tar -x -C <dir>): "before" numbers (blocking only).
# The store is a fresh temp folder (DOTSTUDIO_STORE_DIR): the real library is never touched.
set -e
ROOT="${0:A:h:h:h}"
SRC="${STARTUP_SOURCES:-$ROOT}"
BIN="${STARTUP_BUILD:-$ROOT/.dd/startup}"
RUNS=3
PASS=()
while (( $# )); do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    *) PASS+=$1; shift ;;
  esac
done
mkdir -p "$BIN"
metals=("$SRC"/Shared/*.metal "$SRC"/Shared/Weather/*.metal)
xcrun -sdk macosx metal -O2 -ffast-math -I "$SRC/Shared" -o "$BIN/default.metallib" $metals 2>/dev/null
# The saver bundle layout PipelineArchive.refresh reads (harvest mode).
mkdir -p "$BIN/Harness.saver/Contents/Resources"
cp "$BIN/default.metallib" "$BIN/Harness.saver/Contents/Resources/default.metallib"
rm -rf "$BIN/Photos" && mkdir -p "$BIN/Photos"
cp "$SRC"/Shared/Photos/*.jpg "$BIN/Photos/" 2>/dev/null || true
FLAGS=()
[[ -f "$SRC/Shared/FXPipelines.swift" ]] && FLAGS=(-D FASTSTART)
xcrun -sdk macosx swiftc -O $FLAGS -import-objc-header "$SRC/Shared/Bridging.h" -I "$SRC/Shared" \
  "$SRC"/Shared/*.swift "$SRC"/Shared/Scenes/*.swift "$SRC"/Shared/Music/*.swift "$SRC"/Shared/Weather/*.swift \
  "$ROOT/tools/startup/main.swift" -o "$BIN/startup"

STORE=$(mktemp -d /tmp/dotstudio-startup.XXXXXX)
export DOTSTUDIO_STORE_DIR="$STORE"
cold() { MTL_SHADER_CACHE_SIZE=0 "$BIN/startup" "$@" $PASS }
warm() { "$BIN/startup" "$@" $PASS >/dev/null; "$BIN/startup" "$@" $PASS }

for i in $(seq 1 $RUNS); do
  echo "— run $i"
  echo -n "cold  "; cold blocking
  echo -n "warm  "; warm blocking
  if (( ${#FLAGS} )); then
    rm -rf "$STORE/PipelineCache"
    echo -n "cold  no archive  "; cold fast
    echo -n "cold  "; cold harvest
    echo -n "cold  archive  "; cold fast
    echo -n "warm  archive  "; warm fast
  fi
done
rm -rf "$STORE"
