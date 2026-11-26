#!/bin/zsh
# Settings › General › Theme's films, end to end: capture the app's real UI parts -> build the set
# in Blender -> render each loop -> encode -> copy into App/ThemeFilms.
#
#   tools/film/scenes/theme-reel/render-all.sh [options]
#     --variants a,b     default classic-light,classic-dark,retro-light,retro-dark
#     --work DIR         working folder (default: $TMPDIR/theme-reel); frames are resumable there
#     --skip-build       use the Debug app already in build/dd (else xcodegen + xcodebuild first)
#     --skip-capture     reuse WORK/parts (the UI hasn't changed)
#     --engine E         eevee (default here) | cycles (the default with --remote)
#     --samples N        samples (default: the spec's 64 for EEVEE; 128 for Cycles)
#     --quality Q        HEVC quality for encode.py (default 62: ~1.3 MB a film, ~41 dB)
#     --remote HOST      render on another machine over ssh (a GPU box): see below
#     --remote-blender P Blender there (default /home/stallion/blender/blender)
#     --remote-device D  Cycles' GPU backend there (default OPTIX; CUDA, HIP, METAL…)
#
# Output: App/ThemeFilms/theme-<variant>.mov (HEVC, 960x600, 8 s at 30 fps, seamless loop) and
# theme-<variant>.jpg (the poster: the loop's first frame, shown under Reduce Motion, in renders,
# and until the film plays).
#
# Rules (tools/film/README.md): headless Blender only, one Blender at a time, nice'd; nothing is
# shown on screen; the capture runs offscreen against a throwaway library and home.
#
# Rendering on another machine (--remote HOST, e.g. `--remote stallion`, a Linux box with an RTX
# 4090: Cycles + OptiX): the capture and the encode stay here (they need the app and
# VideoToolbox). The script makes ONE folder on HOST, /tmp/dotstudio-reel-<timestamp>, copies
# tools/film and each variant's work folder (parts, font, spec) into it with rsync, renders there
# with the same headless, nice'd Blender command (one at a time, after the GPU is idle), copies
# the frames back, and when it ends — finished, failed or interrupted — kills the Blender it
# started and deletes that folder, so nothing is left on HOST. HOST needs Blender 5.1+, rsync and
# key-based ssh from this Mac (`ssh HOST true` without a prompt); nothing is installed there.
# On a shared box, never `ps`/`pgrep` there (a process stuck on a stale mount hangs them).
set -euo pipefail
HERE=${0:A:h}
REPO=${HERE:h:h:h:h}
FILM=$REPO/tools/film
VARIANTS=(classic-light classic-dark retro-light retro-dark)
WORK=${TMPDIR:-/tmp}/theme-reel
BUILD=1; CAPTURE=1; ENGINE=""; SAMPLES=""; QUALITY=62
REMOTE=""; RBLENDER=/home/stallion/blender/blender; RDEVICE=OPTIX
B=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
while (( $# )); do
  case $1 in
    --variants) VARIANTS=(${(s:,:)2}); shift 2;;
    --work) WORK=$2; shift 2;;
    --skip-build) BUILD=0; shift;;
    --skip-capture) CAPTURE=0; shift;;
    --engine) ENGINE=$2; shift 2;;
    --samples) SAMPLES=$2; shift 2;;
    --quality) QUALITY=$2; shift 2;;
    --remote) REMOTE=$2; shift 2;;
    --remote-blender) RBLENDER=$2; shift 2;;
    --remote-device) RDEVICE=$2; shift 2;;
    *) echo "unknown option $1"; exit 2;;
  esac
done
mkdir -p "$WORK"
APP=$REPO/build/dd/Build/Products/Debug/DotStudio.app/Contents/MacOS/DotStudio

if (( CAPTURE )); then
  if (( BUILD )); then
    echo "== build"
    (cd "$REPO" && xcodegen generate >/dev/null && \
      xcodebuild -project DotStudio.xcodeproj -scheme DotStudio -configuration Debug -derivedDataPath build/dd build 2>&1 \
        | grep -E "error:|BUILD")
  fi
  echo "== capture"
  rm -rf "$WORK/parts"
  "$HERE/capture.sh" "$APP" "$WORK/parts" >/dev/null
fi

if [[ -n $REMOTE ]]; then
  ENGINE=${ENGINE:-cycles}
  [[ $ENGINE == cycles ]] && SAMPLES=${SAMPLES:-128}
  RD=/tmp/dotstudio-reel-$(date +%Y%m%d%H%M%S)
  cleanup() {
    # our Blender (by the pid it was started with — never by scanning other processes' command
    # lines, which hangs on a process stuck exiting), then the folder
    ssh -o BatchMode=yes "$REMOTE" "p=\$(cat '$RD/blender.pid' 2>/dev/null); \
      [ -n \"\$p\" ] && [ \"\$(cat /proc/\$p/comm 2>/dev/null)\" = blender ] && kill \$p; rm -rf '$RD'; \
      ls /tmp | grep -c dotstudio-reel || true" | sed 's/^/remote dotstudio-reel folders left: /'
  }
  trap cleanup EXIT INT TERM
  ssh -o BatchMode=yes "$REMOTE" "mkdir -p '$RD/work'"
  rsync -a --exclude '__pycache__' "$FILM/" "$REMOTE:$RD/film/"
fi

wait_for_blender() {     # one Blender at a time on this Mac
  while pgrep -x Blender >/dev/null; do sleep 5; done
}

wait_for_gpu() {         # a shared GPU: start only when it's idle
  while (( $(ssh -o BatchMode=yes "$REMOTE" 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo 0' | head -1) > 10 )); do
    echo "   (GPU busy, waiting)"; sleep 30
  done
}

for v in $VARIANTS; do
  echo "== $v"
  V=$WORK/$v
  python3 -I "$HERE/prep.py" "$WORK/parts/$v" "$V"
  cp "$REPO/App/Fonts/HankenGrotesk-Medium.ttf" "$V/"
  t0=$SECONDS
  if [[ -n $REMOTE ]]; then
    python3 -I "$HERE/spec.py" "$HERE/theme-reel.json" "$v" "$RD/work/$v" "$V/spec-remote.json" \
      ${ENGINE:+--engine $ENGINE} ${SAMPLES:+--samples $SAMPLES} --device "$RDEVICE"
    rsync -a --exclude frames --exclude 'spec*.json' "$V/" "$REMOTE:$RD/work/$v/"
    rsync -a "$V/spec-remote.json" "$REMOTE:$RD/work/$v/spec.json"
    wait_for_gpu
    ssh -o BatchMode=yes "$REMOTE" "cd '$RD' && { nice -n 10 '$RBLENDER' -b --factory-startup --python film/run.py -- \
      work/$v/spec.json --anim work/$v/frames --cycles-device $RDEVICE > work/$v/render.log 2>&1 & \
      echo \$! > blender.pid; wait \$!; rm -f blender.pid; }; \
      grep -E '^RESULT' work/$v/render.log || tail -20 work/$v/render.log"
    mkdir -p "$V/frames"
    rsync -a "$REMOTE:$RD/work/$v/frames/" "$V/frames/"
    ssh -o BatchMode=yes "$REMOTE" "rm -rf '$RD/work/$v/frames'"
  else
    python3 -I "$HERE/spec.py" "$HERE/theme-reel.json" "$v" "$V" "$V/spec.json" \
      ${ENGINE:+--engine $ENGINE} ${SAMPLES:+--samples $SAMPLES}
    wait_for_blender
    nice -n 10 "$B" -b --factory-startup --python "$FILM/run.py" -- "$V/spec.json" --anim "$V/frames" | grep -E '^RESULT'
  fi
  echo "render ${v}: $(( SECONDS - t0 )) s"
  python3 -I "$FILM/dsfilm/encode.py" "$V/frames" "$V/film" --fps 30 --quality "$QUALITY" --no-preview >/dev/null
  python3 -I "$FILM/dsfilm/encode.py" --seam "$V/frames"
  mkdir -p "$REPO/App/ThemeFilms"
  cp "$V/film.mov" "$REPO/App/ThemeFilms/theme-$v.mov"
  python3 -I -c "import sys; from PIL import Image; Image.open(sys.argv[1]).convert('RGB').save(sys.argv[2], quality=88, optimize=True, progressive=True)" \
    "$V/frames/0001.png" "$REPO/App/ThemeFilms/theme-$v.jpg"
  ls -l "$REPO/App/ThemeFilms/theme-$v".* | awk '{print $5, $NF}'
done
du -ch "$REPO"/App/ThemeFilms/* | tail -1
