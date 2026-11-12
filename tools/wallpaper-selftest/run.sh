#!/bin/zsh
# Headless checks of the live wallpaper's power settings and the lock-screen picture:
# wallpaper.json migration (Freeze on battery → On Battery), WallpaperBudget, and
# LockScreenPicture's save / render / write / rotate / restore against a FAKE desktop —
# it never reads or sets the real desktop picture, and writes only under a temp dir.
# usage: tools/wallpaper-selftest/run.sh      (exit status 0 = all checks passed)
set -e
ROOT="${0:A:h:h:h}"
BIN="${WALLPAPER_SELFTEST_BUILD:-$ROOT/.dd/wallpaper-selftest}"
mkdir -p "$BIN"
# The shaders, for one real lock-screen still (render + HEIC write, timed).
xcrun -sdk macosx metal -w -O2 -ffast-math -I "$ROOT/Shared" -o "$BIN/default.metallib" \
  "$ROOT/Shared/Shaders.metal" "$ROOT/Shared/SceneEntries.metal" "$ROOT/Shared/Weather/Weather.metal"
# Custom Scene engines (CustomScenes.builtInEnginesDir: Resources/Engines next to the binary).
rm -rf "$BIN/Engines" && cp -R "$ROOT/Shared/Engines" "$BIN/Engines"
xcrun -sdk macosx swiftc -O -suppress-warnings -import-objc-header "$ROOT/Shared/Bridging.h" -I "$ROOT/Shared" \
  "$ROOT"/Shared/*.swift "$ROOT"/Shared/Scenes/*.swift "$ROOT"/Shared/Music/*.swift "$ROOT"/Shared/Weather/*.swift \
  "$ROOT/App/WallpaperPower.swift" "$ROOT/App/LockScreenPicture.swift" \
  "$ROOT/tools/wallpaper-selftest/main.swift" -o "$BIN/wallpaper-selftest"
TMP="$(mktemp -d)"
DOTSTUDIO_STORE_DIR="$TMP/store" "$BIN/wallpaper-selftest" "$TMP"
rm -rf "$TMP"
