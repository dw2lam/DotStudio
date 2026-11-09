#!/bin/zsh
# Writes Now Playing fixtures (MusicState JSON + artwork) for offscreen renders — no real
# player involved. Point DOTSTUDIO_MUSIC_FAKE at one of the JSON files:
#   playing · long · cjk · emoji · podcast · paused · noart · idle
#
#   tools/music-fixtures/make.sh /tmp/ds-fixtures
#   DOTSTUDIO_MUSIC_FAKE=/tmp/ds-fixtures/playing.json DOTSTUDIO_STORE_DIR=$(mktemp -d) \
#     DOTSTUDIO_UI_SHOTS=/tmp/ds-shots DOTSTUDIO_UI_ONLY=music <DotStudio.app>/Contents/MacOS/DotStudio
#   DOTSTUDIO_MUSIC_FAKE=/tmp/ds-fixtures/long.json tools/gallery/render.sh /tmp/ds-g --only "now playing" --overlay
#
# Times are "now" when written, so run this right before rendering (UIShots refreshes them).
# usage: tools/music-fixtures/make.sh [outDir]      (default: $TMPDIR/dotstudio-music-fixtures)
set -e
ROOT="${0:A:h:h:h}"
OUT="${1:-${TMPDIR:-/tmp}/dotstudio-music-fixtures}"
mkdir -p "$OUT"
xcrun swift "$ROOT/tools/music-fixtures/make.swift" "$OUT" "$ROOT/Shared/Photos"
