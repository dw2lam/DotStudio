#!/bin/zsh
# tools/mcp-selftest/run.sh [DotStudio.app] — end-to-end test of dotstudio-mcp over stdio.
# Spawns the BUILT helper (default: build/Build/Products/Release/DotStudio.app, as
# `xcodebuild -configuration Release -derivedDataPath build` leaves it) against throwaway stores
# (DOTSTUDIO_STORE_DIR=$(mktemp -d) per scenario) and exercises: initialize/ping/errors, every
# tool's happy and error paths, PNG previews, resources, prompts, the custom-scene and film
# flows (this build, the structural fakes, and END TO END on the real engines: a pulled engine from
# a local index, metal / cells / shadertoy scenes compiled, installed, previewed (pixels checked),
# benchmarked and played, compile errors with their line numbers, film loops from the toolkit's
# stand-in installed and played by the real film engine), detached film jobs (survive the server,
# cancel), routing through a
# stand-in running app that would clobber direct writes, lock contention, parallel servers, the
# Claude Desktop config merge (temp file only), and settings-guide drift.
# Silent: no windows, no sounds; never touches the real library or Claude's config.
set -e
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/Build/Products/Release/DotStudio.app}"
BIN="$APP/Contents/MacOS/dotstudio-mcp"
[[ -x "$BIN" ]] || { echo "no $BIN — build first: xcodebuild -scheme DotStudio -configuration Release -derivedDataPath build"; exit 2; }
OUT="${MCP_SELFTEST_OUT:-${TMPDIR:-/tmp}/ai-mcp/selftest}"
# Fresh every run: preview_style never overwrites a file, so last run's PNGs would block it.
rm -rf "$OUT"; mkdir -p "$OUT"
exec python3 -I "$ROOT/tools/mcp-selftest/selftest.py" "$BIN" "$ROOT" "$OUT"
