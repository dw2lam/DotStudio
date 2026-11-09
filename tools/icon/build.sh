#!/bin/zsh
# Regenerates the DotStudio app icon concepts from the app's own renderer.
#
#   tools/icon/build.sh [outDir]                    renders the scenes, all 4 concepts + preview.png
#   tools/icon/build.sh [outDir] --install contour  …and installs that concept as the app icon
#                                                   (App/Assets.xcassets/AppIcon.appiconset + Saver/AppIcon.icns)
#
# Concepts: chrome (Liquid Chrome sphere), orbit (Universe sun + glass rings),
#           contour (Topography summit dot), lens (Liquid Glass lens over an Afterglow dot field).
# The gallery never touches the user's library; DOTSTUDIO_STORE_DIR points it at a throwaway dir anyway.
set -e
ROOT="${0:A:h:h:h}"
OUT="/tmp/dsicon"
INSTALL=""
while (( $# )); do
  case "$1" in
    --install) INSTALL="$2"; shift 2 ;;
    *) OUT="$1"; shift ;;
  esac
done
mkdir -p "$OUT/src" "$OUT/scenes"
export DOTSTUDIO_STORE_DIR="$(mktemp -d /tmp/dsicon-store.XXXXXX)"
BIN="${GALLERY_BUILD:-$ROOT/.dd/gallery}"

# 1. Scene renders at 1024×1024 (fixed times + params, so the icon is reproducible).
"$ROOT/tools/gallery/render.sh" "$OUT/scenes" --only "liquid chrome" --size 1024x1024 --times 8 >/dev/null
"$BIN/gallery" "$OUT/scenes" --only "universe" --size 1024x1024 --times 20 \
  --set scale=1.6,tilt=62,stars=1.6,orbits=0 >/dev/null
"$BIN/gallery" "$OUT/scenes" --only "afterglow" --size 1024x1024 --times 14 --set grain=0 >/dev/null
# (one --times value → no "@t" in the file names)
cp "$OUT/scenes/Liquid-Chrome.png" "$OUT/src/chrome.png"
cp "$OUT/scenes/Universe.png" "$OUT/src/universe.png"
cp "$OUT/scenes/Afterglow.png" "$OUT/src/afterglow.png"

# 2. Composite the icons + the preview sheet.
xcrun -sdk macosx swiftc -O "$ROOT/tools/icon/icon.swift" -o "$BIN/icon"
"$BIN/icon" render all "$OUT/src" "$OUT"
"$BIN/icon" preview "$OUT/preview.png" "$OUT"

# 3. Optionally install one concept as the app (and screen saver) icon.
if [[ -n "$INSTALL" ]]; then
  "$BIN/icon" sizes "$OUT/$INSTALL.png" "$ROOT/App/Assets.xcassets/AppIcon.appiconset"
  ICONSET="$(mktemp -d /tmp/dsicon-iconset.XXXXXX)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  "$BIN/icon" iconset "$OUT/$INSTALL.png" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/Saver/AppIcon.icns"
  echo "installed $INSTALL"
fi
rm -rf "$DOTSTUDIO_STORE_DIR"
