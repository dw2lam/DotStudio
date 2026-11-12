#!/bin/zsh
# Builds the perf harness (Shared/*, the saver's view, the wallpaper's render loop, main.swift, a
# counters dylib and a metallib) and runs it against a fresh temp store and music fixtures.
# Nothing is shown on screen and the user's library is never read (see main.swift's header).
#
# usage: tools/perf/run.sh <renderer|saver|wallpaper|idle> [--fps 30,120] [--seconds 4]
#                          [--only chrome,zen] [--size 3024x1964] [--power ac|battery|lowpower]
#   --power (saver, wallpaper): the real power policy picks fps and drawable (see main.swift)
#   PERF_BUILD=dir   build directory (default .dd/perf)      PERF_DEBUG=1   -Onone build
set -e
ROOT="${0:A:h:h:h}"
BIN="${PERF_BUILD:-$ROOT/.dd/perf}"
mkdir -p "$BIN"
OPT=(-O)
[[ -n "$PERF_DEBUG" ]] && OPT=(-Onone)
if [[ -z "$PERF_SKIP_BUILD" ]]; then
  xcrun -sdk macosx metal -w -O2 -ffast-math -I "$ROOT/Shared" -o "$BIN/default.metallib" \
    "$ROOT/Shared/Shaders.metal" "$ROOT/Shared/SceneEntries.metal" "$ROOT/Shared/Weather/Weather.metal"
  cp "$ROOT"/Shared/PlanetTextures/*.jpg "$BIN/" 2>/dev/null || true
# Custom Scene engines (CustomScenes.builtInEnginesDir: Resources/Engines next to the binary).
rm -rf "$BIN/Engines" && cp -R "$ROOT/Shared/Engines" "$BIN/Engines"
  rm -rf "$BIN/Photos" && mkdir -p "$BIN/Photos"
  cp "$ROOT"/Shared/Photos/*.jpg "$BIN/Photos/" 2>/dev/null || true
  xcrun -sdk macosx clang -O2 -dynamiclib -install_name @rpath/libperfhooks.dylib \
    -o "$BIN/libperfhooks.dylib" "$ROOT/tools/perf/hooks.c"
  xcrun -sdk macosx swiftc "${OPT[@]}" -suppress-warnings -D DOTSTUDIO_PERF -import-objc-header "$ROOT/tools/perf/PerfBridging.h" -I "$ROOT/Shared" \
    "$ROOT"/Shared/*.swift "$ROOT"/Shared/Scenes/*.swift "$ROOT"/Shared/Music/*.swift "$ROOT"/Shared/Weather/*.swift \
    "$ROOT/Saver/DotSaverView.swift" "$ROOT/App/WallpaperRenderLoop.swift" "$ROOT/App/WallpaperPower.swift" \
    "$ROOT/App/WallpaperPacingStats.swift" "$ROOT/tools/perf/main.swift" \
    -L "$BIN" -lperfhooks -Xlinker -rpath -Xlinker "$BIN" -framework ScreenSaver -o "$BIN/perf"
fi
FIX="$(mktemp -d)"
"$ROOT/tools/music-fixtures/make.sh" "$FIX" >/dev/null
STORE="$(mktemp -d)"
DOTSTUDIO_STORE_DIR="$STORE" DOTSTUDIO_MUSIC_FAKE="$FIX/playing.json" PERF_FIXTURES="$FIX" "$BIN/perf" "$@"
rm -rf "$STORE" "$FIX"
