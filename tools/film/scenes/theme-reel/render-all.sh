#!/bin/zsh
# Settings › General › Theme's films, end to end: capture the app's real UI -> take it apart
# (prep.py) -> build the assembly in Blender -> render each loop -> encode -> copy into
# App/ThemeFilms. Optionally, from the same scene, the website's pictures: hero stills and the
# one-way scroll assembly.
#
#   tools/film/scenes/theme-reel/render-all.sh [options]
#     --variants a,b     default classic-light,classic-dark,retro-light,retro-dark
#     --work DIR         working folder (default: $TMPDIR/theme-reel); frames are resumable there
#     --skip-build       use the Debug app already in build/dd (else xcodegen + xcodebuild first)
#     --skip-capture     reuse WORK/parts (the UI hasn't changed)
#     --no-films         don't render the films (only --hero / --scroll)
#     --engine E         cycles (default) | eevee
#     --samples N        the films' samples (default: the spec's 512)
#     --res WxH          the films' render size (default: the spec's 1600x1000)
#     --size W:H         the app copies' size (default 1280:800: crisp at 2x in Settings)
#     --quality Q        HEVC quality for encode.py (default 70: ~2.5 MB a film, text stays crisp)
#     --hero DIR         also the hero stills, per variant: DIR/<variant>-flat.png (the assembled
#                        app straight from above, orthographic) and DIR/<variant>-3d.png (the 3/4
#                        view); --hero-res (3840x2400), --hero-samples (1024)
#     --scroll DIR       also the one-way assembly for the site, per variant: DIR/<variant>/####.png
#                        (180 frames = 6 s at 30 fps, close-up of the empty chassis -> assembled,
#                        flat from above, the orange edge light closed)
#                        and the site's WebPs DIR/<variant>-webp/hi/000.webp… (1600 px, q80) and
#                        …/lo/ (800 px, q72); --scroll-res (1920x1200), --scroll-samples (384)
#     --remote HOST      render on another machine over ssh (a GPU box): see below
#     --remote-blender P Blender there (default /home/stallion/blender/blender)
#     --remote-device D  Cycles' GPU backend there (default OPTIX; CUDA, HIP, METAL…)
#     --remote-root DIR  where the remote work folder goes (default /tmp; e.g. an external drive
#                        on a Mac: /Volumes/<drive>) — only <DIR>/dotstudio-reel-<timestamp> is
#                        ever written or removed there
#     --threads N       Blender's CPU threads (default 8: the GPU does the work; a box under full
#                        GPU + CPU load has dropped off the network)
#
# Output: App/ThemeFilms/theme-<variant>.mov (HEVC, 1280x800, 8 s at 30 fps, seamless loop) and
# theme-<variant>.jpg (the poster: the assembled app, frame POSTER of the loop — shown under Reduce
# Motion, in renders, and until the film plays).
#
# Rules (tools/film/README.md): headless Blender only, one Blender at a time, nice'd; nothing is
# shown on screen; the capture runs offscreen against a throwaway library and home.
#
# Rendering on another machine (--remote HOST, e.g. `--remote stallion`, a Linux box with an RTX
# 4090: Cycles + OptiX; or another Mac with --remote-device METAL): the capture and the encode stay
# here (they need the app and VideoToolbox). The script makes ONE folder on HOST,
# <remote root>/dotstudio-reel-<timestamp>, copies
# tools/film and each variant's work folder (parts, spec) into it with rsync, renders there with
# the same headless, nice'd Blender command (one at a time, after the GPU is idle — NVIDIA — or the
# Mac's load is low and no Blender runs — Metal), copies the
# results back, and when it ends — finished, failed or interrupted — kills the Blender it started
# and deletes that folder, so nothing is left on HOST. HOST needs Blender 5.1+, rsync and key-based
# ssh from this Mac (`ssh HOST true` without a prompt); nothing is installed there.
# On a shared box, never `ps`/`pgrep` there (a process stuck on a stale mount hangs them).
set -euo pipefail
HERE=${0:A:h}
REPO=${HERE:h:h:h:h}
FILM=$REPO/tools/film
VARIANTS=(classic-light classic-dark retro-light retro-dark)
WORK=${TMPDIR:-/tmp}/theme-reel
BUILD=1; CAPTURE=1; FILMS=1; ENGINE=cycles; SAMPLES=""; RES=""; SIZE=1280:800; QUALITY=70
HERO=""; HERO_RES=3840x2400; HERO_SAMPLES=1024; SCROLL=""; SCROLL_RES=1920x1200; SCROLL_SAMPLES=384
POSTER=147                       # the loop's frame the poster is cut from: assembled, before the hold's moves
REMOTE=""; RBLENDER=/home/stallion/blender/blender; RDEVICE=OPTIX; THREADS=8; RROOT=/tmp
B=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
while (( $# )); do
  case $1 in
    --variants) VARIANTS=(${(s:,:)2}); shift 2;;
    --work) WORK=$2; shift 2;;
    --skip-build) BUILD=0; shift;;
    --skip-capture) CAPTURE=0; shift;;
    --no-films) FILMS=0; shift;;
    --engine) ENGINE=$2; shift 2;;
    --samples) SAMPLES=$2; shift 2;;
    --res) RES=$2; shift 2;;
    --size) SIZE=$2; shift 2;;
    --quality) QUALITY=$2; shift 2;;
    --hero) HERO=${2:A}; shift 2;;
    --hero-res) HERO_RES=$2; shift 2;;
    --hero-samples) HERO_SAMPLES=$2; shift 2;;
    --scroll) SCROLL=${2:A}; shift 2;;
    --scroll-res) SCROLL_RES=$2; shift 2;;
    --scroll-samples) SCROLL_SAMPLES=$2; shift 2;;
    --remote) REMOTE=$2; shift 2;;
    --remote-blender) RBLENDER=$2; shift 2;;
    --remote-device) RDEVICE=$2; shift 2;;
    --remote-root) RROOT=${2%/}; shift 2;;
    --threads) THREADS=$2; shift 2;;
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
  rm -rf "${WORK:?}/parts"
  "$HERE/capture.sh" "$APP" "$WORK/parts" >/dev/null
fi

if [[ -n $REMOTE ]]; then
  RD=$RROOT/dotstudio-reel-$(date +%Y%m%d%H%M%S)
  cleanup() {
    # our Blender (by the pid it was started with — never by scanning other processes' command
    # lines, which hangs on a process stuck exiting; its name from /proc on Linux, ps on a Mac),
    # then the folder
    ssh -o BatchMode=yes "$REMOTE" "p=\$(cat '$RD/blender.pid' 2>/dev/null); \
      if [ -n \"\$p\" ]; then c=\$(cat /proc/\$p/comm 2>/dev/null || ps -p \$p -o comm= 2>/dev/null); \
        case \"\$c\" in *[Bb]lender) kill \$p;; esac; fi; rm -rf '$RD'; \
      ls '$RROOT' | grep -c dotstudio-reel || true" | sed 's/^/remote dotstudio-reel folders left: /'
  }
  trap cleanup EXIT INT TERM
  ssh -o BatchMode=yes "$REMOTE" "mkdir -p '$RD/work'"
  rsync -a --exclude '__pycache__' "$FILM/" "$REMOTE:$RD/film/"
fi

wait_for_blender() {     # one Blender at a time on this Mac
  while pgrep -x Blender >/dev/null; do sleep 5; done
}

wait_for_gpu() {         # a shared machine: start only when it's idle
  if [[ $RDEVICE == METAL ]]; then
    # a Mac: no other Blender running, and a quiet 1-minute load average
    while ! ssh -o BatchMode=yes "$REMOTE" '! pgrep -x Blender >/dev/null && [ $(sysctl -n vm.loadavg | awk "{printf \"%d\", \$2}") -lt 4 ]'; do
      echo "   (Mac busy, waiting)"; sleep 30
    done
    return
  fi
  while (( $(ssh -o BatchMode=yes "$REMOTE" 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo 0' | head -1) > 10 )); do
    echo "   (GPU busy, waiting)"; sleep 30
  done
}

# blender V TAG OUT SPEC_ARGS -- RUN_ARGS: one Blender run for variant V with a spec made by
# spec.py SPEC_ARGS; RUN_ARGS go to run.py, with @OUT standing for the output path (a frames
# folder or a still) as the rendering machine sees it; the result lands at OUT here.
# zsh skips the EXIT trap when errexit fires inside a function, so every step here returns its
# failure and the caller exits (`|| exit 1`): the remote folder is always cleaned up.
blender() {
  local v=$1 tag=$2 out=$3; shift 3
  local -a sargs rargs; local sep=0
  for a in "$@"; do
    if [[ $a == -- ]]; then sep=1; continue; fi
    if (( sep )); then rargs+=("$a"); else sargs+=("$a"); fi
  done
  local V=$WORK/$v
  if [[ -n $REMOTE ]]; then
    python3 -I "$HERE/spec.py" "$HERE/theme-reel.json" "$v" "$RD/work/$v" "$V/spec-$tag.json" \
      --engine "$ENGINE" --device "$RDEVICE" "${sargs[@]}" || return 1
    rsync -a --exclude 'frames*' --exclude 'spec*.json' --exclude '*.mov' "$V/" "$REMOTE:$RD/work/$v/" || return 1
    rsync -a "$V/spec-$tag.json" "$REMOTE:$RD/work/$v/spec-$tag.json" || return 1
    local rout=$RD/out/$v-$tag
    [[ $out == *.png ]] && rout=$rout.png
    rargs=("${(@)rargs//@OUT/$rout}")
    ssh -o BatchMode=yes "$REMOTE" "mkdir -p '$RD/out'" || return 1
    # frames already here (an earlier, interrupted run): send them, so --anim resumes after them
    if [[ $out != *.png && -d $out ]] && (( $(ls "$out" | wc -l) )); then
      rsync -a "$out/" "$REMOTE:$rout/" || return 1
      echo "   (resuming after $(ls "$out" | wc -l | tr -d ' ') frames)"
    fi
    wait_for_gpu
    # Up to 3 tries, each started DETACHED there (nohup; on a Mac also `caffeinate -i -w PID`, so
    # the machine stays awake while it runs and an idle sleep or a dropped ssh doesn't stop it)
    # and watched from here with short ssh polls: Blender 5.3 has crashed (segfault) and hung
    # (after a frame's samples, one CPU thread spinning) at random. A try whose log hasn't moved
    # for 5 minutes is killed (our own PID only) and the next resumes from the last saved frame
    # (--anim skips frames on disk). A poll that can't reach HOST is retried for 20 minutes
    # before giving up (the render goes on meanwhile).
    local try p state fails ok=0
    for try in 1 2 3; do
      p=$(ssh -o BatchMode=yes "$REMOTE" "cd '$RD' && { nohup nice -n 10 '$RBLENDER' -b -t $THREADS --factory-startup \
        --python film/run.py -- work/$v/spec-$tag.json ${(j: :)${(@q)rargs}} > work/$v/$tag.log 2>&1 < /dev/null & \
        p=\$!; echo \$p > blender.pid; \
        command -v caffeinate >/dev/null && { nohup caffeinate -i -w \$p > /dev/null 2>&1 < /dev/null & }; echo \$p; }") || return 1
      fails=0
      while true; do
        sleep 20
        # alive|dead, and seconds since the log last moved
        state=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" "cd '$RD' && \
          if kill -0 $p 2>/dev/null; then a=alive; else a=dead; fi; \
          echo \$a \$(( \$(date +%s) - \$(stat -c %Y work/$v/$tag.log 2>/dev/null || stat -f %m work/$v/$tag.log) ))" 2>/dev/null) || {
          (( ++fails > 60 )) && { echo "   ($REMOTE unreachable for 20 min)"; return 1; }
          continue
        }
        fails=0
        [[ $state == dead* ]] && break
        if (( ${state#alive } > 300 )); then
          echo "   (Blender $p: no progress for 5 min, killing it, try $try)"
          ssh -o BatchMode=yes "$REMOTE" "kill $p; sleep 10; kill -9 $p 2>/dev/null; true"
        fi
      done
      if ssh -o BatchMode=yes "$REMOTE" "cd '$RD' && rm -f blender.pid && grep -E '^RESULT' work/$v/$tag.log | grep -q '\"ok\":true'"; then
        ok=1; break
      fi
      echo "   (Blender stopped without a result, try $try)"
    done
    ssh -o BatchMode=yes "$REMOTE" "cd '$RD' && { grep -E '^RESULT' work/$v/$tag.log || tail -20 work/$v/$tag.log; }"
    (( ok )) || return 1
    if [[ $out == *.png ]]; then
      mkdir -p "${out:h}"
      rsync -a "$REMOTE:$rout" "$out" || return 1
    else
      mkdir -p "$out"
      rsync -a "$REMOTE:$rout/" "$out/" || return 1
    fi
    ssh -o BatchMode=yes "$REMOTE" "rm -rf '$rout'" || return 1
  else
    python3 -I "$HERE/spec.py" "$HERE/theme-reel.json" "$v" "$V" "$V/spec-$tag.json" --engine "$ENGINE" "${sargs[@]}" || return 1
    rargs=("${(@)rargs//@OUT/$out}")
    wait_for_blender
    # the same watched tries as on a remote machine (see above)
    local log=$V/$tag.log p rc=1 try
    for try in 1 2 3; do
      nice -n 10 "$B" -b -t $THREADS --factory-startup --python "$FILM/run.py" -- "$V/spec-$tag.json" "${rargs[@]}" > "$log" 2>&1 &
      p=$!
      while kill -0 $p 2>/dev/null; do
        sleep 20
        if (( $(date +%s) - $(stat -f %m "$log") > 300 )); then
          echo "   (Blender $p: no progress for 5 min, killing it, try $try)"; kill $p 2>/dev/null || true; sleep 10; kill -9 $p 2>/dev/null || true
        fi
      done
      wait $p && rc=0 || rc=$?
      (( rc == 0 )) && break
      echo "   (Blender exited $rc, try $try)"
    done
    grep -E '^RESULT' "$log" || { tail -20 "$log"; return 1; }
  fi
}

for v in $VARIANTS; do
  echo "== $v"
  V=$WORK/$v
  python3 -I "$HERE/prep.py" "$WORK/parts/$v" "$V"
  if (( FILMS )); then
    t0=$SECONDS
    blender $v loop "$V/frames" ${SAMPLES:+--samples $SAMPLES} -- --anim @OUT ${RES:+--res $RES} || exit 1
    echo "render ${v}: $(( SECONDS - t0 )) s"
    python3 -I "$FILM/dsfilm/encode.py" "$V/frames" "$V/film" --fps 30 --quality "$QUALITY" --size "$SIZE" --no-preview >/dev/null
    python3 -I "$FILM/dsfilm/encode.py" --seam "$V/frames"
    mkdir -p "$REPO/App/ThemeFilms"
    cp "$V/film.mov" "$REPO/App/ThemeFilms/theme-$v.mov"
    python3 -I -c "import sys; from PIL import Image; Image.open(sys.argv[1]).convert('RGB').resize(tuple(int(x) for x in sys.argv[3].split(':')), Image.LANCZOS).save(sys.argv[2], quality=86, optimize=True, progressive=True)" \
      "$V/frames/$(printf %04d $POSTER).png" "$REPO/App/ThemeFilms/theme-$v.jpg" "$SIZE"
    ls -l "$REPO/App/ThemeFilms/theme-$v".* | awk '{print $5, $NF}'
  fi
  if [[ -n $HERO ]]; then
    t0=$SECONDS
    blender $v flat "$HERO/$v-flat.png" --mode flat -- --still @OUT --frame 1 --res $HERO_RES --samples $HERO_SAMPLES || exit 1
    blender $v 3d "$HERO/$v-3d.png" --mode 3d -- --still @OUT --frame 1 --res $HERO_RES --samples $HERO_SAMPLES || exit 1
    echo "hero ${v}: $(( SECONDS - t0 )) s"
  fi
  if [[ -n $SCROLL ]]; then
    t0=$SECONDS
    blender $v scroll "$SCROLL/$v" --mode scroll -- --anim @OUT --res $SCROLL_RES --samples $SCROLL_SAMPLES || exit 1
    echo "scroll ${v}: $(( SECONDS - t0 )) s"
    # the site's copies: WebP frames 000.webp… at 1600 px (q80) and 800 px (q72)
    python3 -I -c "import sys, glob, os; from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
for sub, w, q in (('hi', 1600, 80), ('lo', 800, 72)):
    os.makedirs(os.path.join(dst, sub), exist_ok=True)
    for i, f in enumerate(sorted(glob.glob(os.path.join(src, '[0-9]' * 4 + '.png')))):
        im = Image.open(f).convert('RGB')
        im.resize((w, round(im.height * w / im.width)), Image.LANCZOS).save(
            os.path.join(dst, sub, f'{i:03d}.webp'), quality=q, method=6)" \
      "$SCROLL/$v" "$SCROLL/$v-webp"
    du -sh "$SCROLL/$v" "$SCROLL/$v-webp" | awk '{print "   " $1, $2}'
  fi
done
if (( FILMS )); then du -ch "$REPO"/App/ThemeFilms/* | tail -1; fi
