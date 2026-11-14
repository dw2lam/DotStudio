#!/bin/zsh
# On-screen gallery scroll benchmark (App/ScrollBench.swift, DOTSTUDIO_PERF_PROBE=onscreen).
# SHOWS a click-through window on the main display for ~12 s per run (it never activates the
# app or takes focus). Each run starts from a COPY of a library in a fresh temp store.
#   tools/perf/scroll-bench.sh [path/to/DotStudio.app] [library dir to copy] [runs]
#   SCROLL_TRACE=out.trace   also record xctrace's Animation Hitches around the first run
# The library dir is a store folder (library.json + media/), e.g. a copy of a user's
# ~/Library/Application Support/DotStudio — never the real folder itself.
set -u
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/Build/Products/Release/DotStudio.app}"
LIB="${2:-}"
RUNS="${3:-1}"
BIN="$APP/Contents/MacOS/DotStudio"
[[ -x "$BIN" ]] || { echo "no app at $APP"; exit 2; }
REAL="$HOME/Library/Application Support/DotStudio"
for i in $(seq 1 $RUNS); do
  T="$(mktemp -d)"
  if [[ -n "$LIB" ]]; then
    [[ "${LIB:A}" == "${REAL:A}" ]] && { echo "refusing to run on the real library; pass a copy"; exit 2; }
    cp -R "$LIB/" "$T/"
  fi
  if [[ $i -eq 1 && -n "${SCROLL_TRACE:-}" ]]; then
    xcrun xctrace record --template 'Animation Hitches' --output "$SCROLL_TRACE" --no-prompt \
      --env DOTSTUDIO_STORE_DIR="$T" --env DOTSTUDIO_PERF_PROBE=onscreen --launch -- "$BIN" 2>&1 \
      | grep -E '^(GESTURE|TOTAL|scroll bench|    )'
  else
    DOTSTUDIO_STORE_DIR="$T" DOTSTUDIO_PERF_PROBE=onscreen "$BIN" 2>/dev/null \
      | grep -E '^(GESTURE|TOTAL|scroll bench|    )'
  fi
  rm -rf "$T"
done
