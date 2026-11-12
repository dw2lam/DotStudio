#!/bin/zsh
# make-dmg.sh <DotStudio.app> <version> <out.dmg>
# Builds the designed installer disk image: DotStudio + an Applications link + "How to Install.txt",
# laid out over scripts/dmg/background.tiff (layout in scripts/dmg/settings.py). Used by
# .github/workflows/release.yml and for local testing. Never opens a Finder window.
#
# Needs dmgbuild (https://pypi.org/project/dmgbuild/): $DMGBUILD, else `dmgbuild` on PATH, else a
# pinned copy is installed into .dd/dmgbuild-venv on first run.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <DotStudio.app> <version> <out.dmg>" >&2
  exit 2
fi
APP="${1:A}"; VERSION="$2"; OUT="${3:A}"
ROOT="${0:A:h:h}"
DMGDIR="$ROOT/scripts/dmg"
DMGBUILD_VERSION=1.6.7

[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }
ICNS="$APP/Contents/Resources/AppIcon.icns"
[[ -f "$ICNS" ]] || { echo "error: $ICNS missing" >&2; exit 1; }
[[ -f "$DMGDIR/background.tiff" ]] || { echo "error: $DMGDIR/background.tiff missing" >&2; exit 1; }

DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || true)}"
if [[ -z "$DMGBUILD" ]]; then
  VENV="$ROOT/.dd/dmgbuild-venv"
  if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
  fi
  DMGBUILD="$VENV/bin/dmgbuild"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# Tag the text file as UTF-8 so TextEdit never guesses another encoding for the › and … in it
# (dmgbuild copies files with ditto, which keeps extended attributes).
cp "$DMGDIR/How to Install.txt" "$STAGE/How to Install.txt"
xattr -c "$STAGE/How to Install.txt"
xattr -w com.apple.TextEncoding "UTF-8;134217984" "$STAGE/How to Install.txt"

mkdir -p "${OUT:h}"
rm -f "$OUT"
"$DMGBUILD" --no-hidpi -s "$DMGDIR/settings.py" \
  -D app="$APP" -D dmgdir="$DMGDIR" -D howto="$STAGE/How to Install.txt" -D volume_icon="$ICNS" \
  ${DMG_FORMAT:+-D format=$DMG_FORMAT} \
  "DotStudio $VERSION" "$OUT"

hdiutil verify "$OUT" >/dev/null
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
