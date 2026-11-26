#!/bin/zsh
# Regenerates the Theme picture choices in Settings › General (App/ThemePreviews/*.jpg):
# the main window (library, 1440x900, with its title bar) in each theme, light and dark,
# rendered offscreen by UIShots from a fresh temp store, then cropped to its top-left
# (title bar, the Screensaver tile, the filters and a row of styles) so the theme reads
# at thumbnail size, and scaled to 720 px wide.
# Run after a build: tools/theme-previews.sh [path/to/DotStudio.app]
set -e
cd "${0:A:h}/.."
APP=${1:-build/dd/Build/Products/Debug/DotStudio.app}
OUT=App/ThemePreviews
TMP=$(mktemp -d)
for theme in classic console; do
  S=$(mktemp -d); H=$(mktemp -d)
  DOTSTUDIO_UI_SHOTS=$TMP/$theme DOTSTUDIO_STORE_DIR=$S CFFIXED_USER_HOME=$H \
  DOTSTUDIO_APPEARANCE=$theme DOTSTUDIO_UI_CHROME=1 DOTSTUDIO_UI_ONLY=library \
  DOTSTUDIO_UI_SIZES=1440x900 DOTSTUDIO_UI_TEXT=default DOTSTUDIO_UI_APPEARANCE=both \
    timeout 400 "$APP/Contents/MacOS/DotStudio" >/dev/null 2>&1 || true
  for mode in light dark; do
    src=$TMP/$theme/library@1440x900.png; [[ $mode == dark ]] && src=$TMP/$theme/library@1440x900-dark.png
    [[ -f $src ]] || { echo "missing $src" >&2; exit 1; }
    # Top-left 1120x694 pt of the 2x render (the picture's 0.62 aspect), scaled to 720 px.
    ffmpeg -loglevel error -y -i "$src" -vf "crop=2240:1388:0:0,scale=720:-1" -q:v 3 "$OUT/theme-$theme-$mode.jpg"
  done
done
ls -la $OUT
