#!/bin/zsh
# tools/guides/generate.sh [DotStudio.app] — regenerate Guides/settings/*.md (index, looks, one per
# scene) from the catalog compiled into the built dotstudio-mcp, so the bundled copies match the
# build. (The server also generates them live; tools/mcp-selftest fails when these are stale.)
# settings/app.md is hand-written and left alone.
set -e
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/Build/Products/Release/DotStudio.app}"
BIN="$APP/Contents/MacOS/dotstudio-mcp"
[[ -x "$BIN" ]] || { echo "no $BIN — build the app first"; exit 2; }
DIR="$ROOT/Guides/settings"
for f in "$DIR"/*.md(N); do [[ "${f:t}" == "app.md" ]] || rm "$f"; done
DOTSTUDIO_STORE_DIR="$(mktemp -d)" "$BIN" --write-settings-guides "$DIR"
