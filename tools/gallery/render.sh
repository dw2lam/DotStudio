#!/bin/zsh
# Builds the standalone gallery harness (Shared/* + main.swift + a metallib) and runs it.
# Renders DefaultPresets.makeLibrary() — never the user's library — to PNGs.
# usage: tools/gallery/render.sh <outDir> [--photo f.jpg] [--times 1.6,9] [--only name] [--pack]
#        [--weather rain,thunderstorm] [--clock 19:30 --date 2026-06-21] — see main.swift's header
set -e
ROOT="${0:A:h:h:h}"
BIN="${GALLERY_BUILD:-$ROOT/.dd/gallery}"
mkdir -p "$BIN"
xcrun -sdk macosx metal -O2 -ffast-math -I "$ROOT/Shared" -o "$BIN/default.metallib" \
  "$ROOT/Shared/Shaders.metal" "$ROOT/Shared/SceneEntries.metal" "$ROOT/Shared/Weather/Weather.metal"
cp "$ROOT"/Shared/PlanetTextures/*.jpg "$BIN/" 2>/dev/null || true
# Custom Scene engines (CustomScenes.builtInEnginesDir: Resources/Engines next to the binary).
rm -rf "$BIN/Engines" && cp -R "$ROOT/Shared/Engines" "$BIN/Engines"
# Built-in slideshow photos (the default Looks canvas), found via Bundle.main/Photos.
rm -rf "$BIN/Photos" && mkdir -p "$BIN/Photos"
cp "$ROOT"/Shared/Photos/*.jpg "$BIN/Photos/" 2>/dev/null || true
xcrun -sdk macosx swiftc -O -import-objc-header "$ROOT/Shared/Bridging.h" -I "$ROOT/Shared" \
  "$ROOT"/Shared/*.swift "$ROOT"/Shared/Scenes/*.swift "$ROOT"/Shared/Music/*.swift "$ROOT"/Shared/Weather/*.swift \
  "$ROOT/tools/gallery/main.swift" -o "$BIN/gallery"
"$BIN/gallery" "$@"
