#!/bin/zsh
# tools/mcp-selftest/run.sh [DotStudio.app] — end-to-end test of dotstudio-mcp over stdio.
# Spawns the BUILT helper (default: build/Build/Products/Release/DotStudio.app, as
# `xcodebuild -configuration Release -derivedDataPath build` leaves it) against throwaway stores
# (DOTSTUDIO_STORE_DIR=$(mktemp -d) per scenario) and exercises: initialize/ping/errors, every
# tool's happy and error paths, PNG previews, resources, prompts, the custom-scene and film
# flows (stub and test fakes), detached film jobs (survive the server, cancel), routing through a
# stand-in running app that would clobber direct writes, lock contention, parallel servers, the
# Claude Desktop config merge (temp file only), and settings-guide drift.
# Silent: no windows, no sounds; never touches the real library or Claude's config.
set -e
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/Build/Products/Release/DotStudio.app}"
BIN="$APP/Contents/MacOS/dotstudio-mcp"
[[ -x "$BIN" ]] || { echo "no $BIN — build first: xcodebuild -scheme DotStudio -configuration Release -derivedDataPath build"; exit 2; }
OUT="${MCP_SELFTEST_OUT:-${TMPDIR:-/tmp}/ai-mcp/selftest}"
mkdir -p "$OUT"
exec python3 -I "$ROOT/tools/mcp-selftest/selftest.py" "$BIN" "$ROOT" "$OUT"
