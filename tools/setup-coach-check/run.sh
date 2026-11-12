#!/bin/zsh
# Checks the setup coach's matcher (App/SetupCoachMatch.swift) against fixture System Settings
# accessibility trees (Fixtures.swift + any fixtures/*.json captures), plus its geometry and
# label loading. Never opens or reads System Settings itself.
# usage: tools/setup-coach-check/run.sh                 (exit status 0 = all checks passed)
#        tools/setup-coach-check/run.sh dump.json …     (what the coach finds in DOTSTUDIO_AX_DUMP
#                                                        captures: the .json written next to the dump)
set -e
ROOT="${0:A:h:h:h}"
BIN="${SETUP_COACH_BUILD:-${TMPDIR:-/tmp}/dotstudio-setup-coach-check}"
mkdir -p "$BIN"
xcrun -sdk macosx swiftc -O "$ROOT/App/SetupCoachMatch.swift" "$ROOT/tools/setup-coach-check/Fixtures.swift" \
  "$ROOT/tools/setup-coach-check/main.swift" -o "$BIN/setup-coach-check"
if [[ $# -gt 0 ]]; then
  "$BIN/setup-coach-check" "$@"
  exit $?
fi
"$BIN/setup-coach-check"
# Recorded captures (DOTSTUDIO_AX_DUMP .json) kept as fixtures: each must at least parse and match.
for f in "$ROOT"/tools/setup-coach-check/fixtures/*.json(N); do
  "$BIN/setup-coach-check" "$f"
done
