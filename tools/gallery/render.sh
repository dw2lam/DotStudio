#!/bin/zsh
# Builds the standalone gallery harness (Shared/* + main.swift + a metallib) and runs it.
# Renders DefaultPresets.makeLibrary() — never the user's library — to PNGs.
# usage: tools/gallery/render.sh <outDir> [--photo f.jpg] [--times 1.6,9] [--only name] [--pack]
set -e
ROOT="${0:A:h:h:h}"
BIN="${GALLERY_BUILD:-$ROOT/.dd/gallery}"
mkdir -p "$BIN"
xcrun -sdk macosx metal -O2 -ffast-math -I "$ROOT/Shared" -o "$BIN/default.metallib" "$ROOT/Shared/Shaders.metal"
cp "$ROOT"/Shared/PlanetTextures/*.jpg "$BIN/" 2>/dev/null || true
xcrun -sdk macosx swiftc -O -import-objc-header "$ROOT/Shared/Bridging.h" -I "$ROOT/Shared" \
  "$ROOT"/Shared/*.swift "$ROOT/tools/gallery/main.swift" -o "$BIN/gallery"
"$BIN/gallery" "$@"
