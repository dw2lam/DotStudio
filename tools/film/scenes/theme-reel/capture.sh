#!/bin/zsh
# Captures the real UI parts the theme films are made of (UIShots' theme-layer-* screens), for
# Classic and Retro, light and dark, as transparent PNGs at the display's scale (2x on Retina):
#
#   capture.sh APP_BINARY OUT_DIR
#     -> OUT_DIR/<classic|retro>-<light|dark>/<window|deck|tiles|inspector|keys>.png
#
# Offscreen only (never shown), in a throwaway library and home: the real library is never touched.
# DOTSTUDIO_UI_SCALE=3 in the environment captures at 3 px per point (sharp close-ups). Scroll bars
# are the overlay kind whatever the Mac's setting (a legacy scroller narrows the layout by 17 pt).
set -euo pipefail
APP=${1:?app binary (…/DotStudio.app/Contents/MacOS/DotStudio)}
OUT=${2:?output dir}
mkdir -p "$OUT"
RAW=$(mktemp -d)
for theme in classic console; do
  STORE=$(mktemp -d); HOME_DIR=$(mktemp -d)
  DOTSTUDIO_UI_SHOTS="$RAW/$theme" DOTSTUDIO_STORE_DIR="$STORE" CFFIXED_USER_HOME="$HOME_DIR" \
  DOTSTUDIO_APPEARANCE=$theme DOTSTUDIO_UI_ONLY=theme-layer- DOTSTUDIO_UI_SIZES=1280x800 \
  DOTSTUDIO_UI_CHROME=1 DOTSTUDIO_UI_TEXT=default DOTSTUDIO_UI_APPEARANCE=both \
    timeout 300 "$APP" -AppleShowScrollBars WhenScrolling > "$RAW/$theme.log" 2>&1 || { cat "$RAW/$theme.log"; exit 1; }
  rm -rf "$STORE" "$HOME_DIR"
  name=$([[ $theme == console ]] && echo retro || echo classic)
  for f in "$RAW/$theme"/theme-layer-*.png; do
    b=${f:t:r}                         # theme-layer-deck@1040x291-dark
    part=${${b#theme-layer-}%%@*}      # deck
    tone=$([[ $b == *-dark ]] && echo dark || echo light)
    mkdir -p "$OUT/$name-$tone"
    cp "$f" "$OUT/$name-$tone/$part.png"
  done
done
rm -rf "$RAW"
ls "$OUT"/*/ | head -40
