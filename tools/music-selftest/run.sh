#!/bin/zsh
# Headless end-to-end test of music detection (App/Music) — NO real player involved:
# synthetic distributed notifications on a private name prefix, Apple Events dry-run,
# real oEmbed / iTunes lookups. Writes music.json snapshots, covers and palette swatches
# to <outDir>/steps and the monitor's transition log to <outDir>/debug.log.
# usage: tools/music-selftest/run.sh [outDir]      (exit status 0 = all checks passed)
set -e
ROOT="${0:A:h:h:h}"
BIN="${MUSIC_SELFTEST_BUILD:-$ROOT/.dd/music-selftest}"
OUT="${1:-${TMPDIR:-/tmp}/dotstudio-music-selftest}"
mkdir -p "$BIN"
xcrun -sdk macosx swiftc -O -import-objc-header "$ROOT/Shared/Bridging.h" -I "$ROOT/Shared" \
  "$ROOT"/Shared/*.swift "$ROOT"/Shared/Scenes/*.swift "$ROOT"/Shared/Music/*.swift "$ROOT"/Shared/Weather/*.swift \
  "$ROOT"/App/Music/*.swift "$ROOT"/tools/music-selftest/*.swift -o "$BIN/music-selftest"
"$BIN/music-selftest" "$OUT"
