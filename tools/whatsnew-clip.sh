#!/bin/zsh
# The animated preview a CHANGELOG release's media line points at, for GitHub's release notes
# and the README: an animated WebP of one of the app's bundled films.
#
#   tools/whatsnew-clip.sh <version> <film.mov> [--width 720] [--fps 15] [--max-mb 2.5]
#   tools/whatsnew-clip.sh 1.7.0 App/ThemeFilms/theme-retro-dark.mov
#
# Writes web/public/media/whatsnew/<version>.webp, served by the site at
#   https://dotstudio.davidlam.online/media/whatsnew/<version>.webp
# which is what the release's line in CHANGELOG.md names:
#   ![Retro, assembled](https://dotstudio.davidlam.online/media/whatsnew/1.7.0.webp)
# (The app never loads that URL: it plays its own bundled film — WhatsNewClip.films in
# App/Changelog.swift maps the version to the film.)
#
# Loops forever; quality steps down from 82 until the file is under --max-mb. Uses ffmpeg's
# libwebp encoder when the ffmpeg build has it, else ffmpeg → PNG frames → img2webp (brew
# install webp). Re-run it after the films are re-rendered.
set -e
ROOT="${0:A:h:h}"
VERSION="$1"; MOV="$2"
if [[ -z "$VERSION" || -z "$MOV" ]]; then
  echo "usage: $0 <version> <film.mov> [--width 720] [--fps 15] [--max-mb 2.5]" >&2; exit 2
fi
shift 2
WIDTH=720; FPS=15; MAXMB=2.5
while (( $# )); do
  case "$1" in
    --width) WIDTH="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --max-mb) MAXMB="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -f "$MOV" ]] || { echo "no such film: $MOV" >&2; exit 1; }
OUTDIR="$ROOT/web/public/media/whatsnew"
OUT="$OUTDIR/$VERSION.webp"
mkdir -p "$OUTDIR"
MAXBYTES=$(printf "%.0f" $(( MAXMB * 1024 * 1024 )))
FILTER="fps=$FPS,scale=$WIDTH:-2:flags=lanczos"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/whatsnew-clip.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libwebp; then
  encode() {
    ffmpeg -v error -y -i "$MOV" -vf "$FILTER" -an -c:v libwebp -lossless 0 -q:v "$1" \
      -compression_level 6 -loop 0 "$WORK/out.webp"
  }
else
  command -v img2webp >/dev/null || { echo "needs ffmpeg with libwebp, or img2webp (brew install webp)" >&2; exit 1; }
  ffmpeg -v error -y -i "$MOV" -vf "$FILTER" -an "$WORK/f%04d.png"
  DELAY=$(( 1000 / FPS ))
  encode() {
    img2webp -loop 0 -min_size -lossy -q "$1" -m 6 -d "$DELAY" "$WORK"/f*.png -o "$WORK/out.webp" >/dev/null 2>&1
  }
fi

for Q in 82 76 70 64 58 52 46 40; do
  encode "$Q"
  SIZE=$(stat -f%z "$WORK/out.webp")
  echo "q=$Q → $(( SIZE / 1024 )) KB"
  (( SIZE <= MAXBYTES )) && break
done
mv "$WORK/out.webp" "$OUT"
DIMS=$(webpmux -info "$OUT" 2>/dev/null | awk '/Canvas size/{print $3 $4 $5}')
FRAMES=$(webpmux -info "$OUT" 2>/dev/null | awk '/Number of frames/{print $4}')
echo "wrote ${OUT#$ROOT/}  ($(( $(stat -f%z "$OUT") / 1024 )) KB, ${DIMS:-?}, ${FRAMES:-?} frames @ ${FPS} fps, q=$Q)"
