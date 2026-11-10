#!/bin/zsh
# Checks the guided setup's read-only parsers (App/SetupGuideStore.swift): synthetic wallpaper
# stores and pmset output, then — when present — a COPY of this Mac's real wallpaper store
# (the original is only ever copied; the copy is made read-only first).
# usage: tools/setup-guide-check/run.sh            (exit status 0 = all checks passed)
set -e
ROOT="${0:A:h:h:h}"
BIN="${SETUP_CHECK_BUILD:-${TMPDIR:-/tmp}/dotstudio-setup-check}"
mkdir -p "$BIN"
xcrun -sdk macosx swiftc -O "$ROOT/App/SetupGuideStore.swift" "$ROOT/tools/setup-guide-check/main.swift" \
  -o "$BIN/setup-guide-check"
REAL="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
if [[ -f "$REAL" ]]; then
  COPY="$BIN/Index-copy.plist"
  rm -f "$COPY"; cp "$REAL" "$COPY"; chmod 444 "$COPY"
  "$BIN/setup-guide-check" "$COPY"
else
  "$BIN/setup-guide-check"
fi
