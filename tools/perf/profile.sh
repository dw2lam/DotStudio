#!/bin/zsh
# Samples the perf harness (call stacks of every thread, 1 ms) while it runs one mode, and
# prints the heaviest stacks: where the CPU time goes, not just how much.
# usage: tools/perf/profile.sh <out.txt> <mode> [harness args…]   (builds first, like run.sh)
set -e
ROOT="${0:A:h:h:h}"
OUT="$1"; shift
"$ROOT/tools/perf/run.sh" "$@" --seconds 10 > "$OUT.run" 2>&1 &
RUNNER=$!
sleep 5
PID=$(pgrep -n -f "/perf $1" || true)
if [[ -n "$PID" ]]; then
  sample "$PID" 4 1 -mayDie -file "$OUT" >/dev/null 2>&1 || true
fi
wait $RUNNER || true
echo "samples: $OUT   run log: $OUT.run"
