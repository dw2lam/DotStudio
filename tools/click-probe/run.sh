#!/bin/zsh
# The gallery click-path crash harness (App/ClickProbe.swift) over a matrix of libraries and
# conditions, each in a throwaway store. Exit status 0 = every run passed.
#   tools/click-probe/run.sh [path/to/DotStudio.app] [fixture store dir]
# A fixture store is a library folder to start from (e.g. one migrated 1.3 → 1.4.0 → 1.4.1 →
# 1.4.2 with the released builds' DOTSTUDIO_MIGRATE_ONLY). Pass sanitizer and malloc options
# through the environment (ASAN_OPTIONS, TSAN_OPTIONS, MallocScribble=1, MallocGuardEdges=1).
# On macOS 26 this reproduces the 1.4.1–1.4.3 crash on an unfixed build; macOS 27 only logs it.
set -u
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/dd/Build/Products/Debug/DotStudio.app}"
FIXTURE="${2:-}"
BIN="$APP/Contents/MacOS/DotStudio"
[[ -x "$BIN" ]] || { echo "no app at $APP"; exit 2; }
fails=0
run() {   # run <name> <env…>
  local name=$1; shift
  local T="$(mktemp -d)"
  [[ -n "$FIXTURE" && "$name" == chain* ]] && cp -R "$FIXTURE/" "$T/"
  local log="$T.log"
  env DOTSTUDIO_STORE_DIR="$T" DOTSTUDIO_CLICK_PROBE=1 "$@" "$BIN" > "$log" 2>&1
  local st=$?
  local summary="$(grep -E 'click probe: (PASS|FAIL)' "$log" | tail -1)"
  if [[ $st -eq 0 ]]; then
    echo "ok    $name — $summary"
  else
    [[ $st -ge 128 ]] && summary="crashed (signal $((st - 128)))"
    echo "FAIL  $name — $summary (log: $log)"
    grep -E '^(FAIL|MISS)' "$log" | head -5 | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}
run default X=1
[[ -n "$FIXTURE" ]] && run chain DOTSTUDIO_CLICK_SCENARIO=retired,dupes,bounceimage
run scenarios DOTSTUDIO_CLICK_SCENARIO=retired,dupes,bounceimage,music,menubar,screens
run small DOTSTUDIO_CLICK_SCENARIO=fullscreen DOTSTUDIO_CLICK_SIZE=880x600
run wide DOTSTUDIO_CLICK_SIZE=1900x1150 "DOTSTUDIO_CLICK_ONLY=Liquid Chrome|Aurora|Bounce|StandBy|Film|Riso Duotone"
run runloop-timing DOTSTUDIO_CLICK_TIMING=runloop "DOTSTUDIO_CLICK_ONLY=Liquid Chrome|Aurora|Film"
echo
if [[ $fails -eq 0 ]]; then echo "click probe matrix: PASS"; else echo "click probe matrix: $fails FAILED"; fi
exit $(( fails > 0 ))
