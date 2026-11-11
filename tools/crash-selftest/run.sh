#!/bin/zsh
# The crash reporter's self-test: crashes a DEBUG build of the app on purpose (in a child
# process, against a throwaway store) and checks what the next launch finds — the crash
# marker, the signal, the exception's reason, the breadcrumbs, the matching macOS .ips
# report, the GitHub issue URL's length, and safe mode after two quick crashes.
#
# Crashing makes macOS write a real crash report and may show its "quit unexpectedly"
# dialog, so run it in a VM / test account, never on a Mac someone is using:
#   tools/crash-selftest/run.sh [path/to/Debug/DotStudio.app]     (exit status 0 = all passed)
set -u
ROOT="${0:A:h:h:h}"
APP="${1:-$ROOT/build/dd/Build/Products/Debug/DotStudio.app}"
BIN="$APP/Contents/MacOS/DotStudio"
[[ -x "$BIN" ]] || { echo "no app at $APP (build Debug first)"; exit 2; }
fails=0
check() {   # check <label> <file> <pattern>
  if grep -qE "$3" "$2"; then echo "  ok   $1"; else echo "  FAIL $1 (no /$3/ in $2)"; cat "$2"; fails=$((fails + 1)); fi
}
selftest() {   # selftest <store> <out>  → what the next launch found
  DOTSTUDIO_STORE_DIR="$1" DOTSTUDIO_CRASH_SELFTEST="$2" "$BIN" > "$2.txt" 2>/dev/null
}
crash() {   # crash <store> <kind>  → exit status of the crashing child
  DOTSTUDIO_STORE_DIR="$1" DOTSTUDIO_DEBUG_CRASH="$2" "$BIN" >/dev/null 2>&1
  echo $?
}

for kind in segv abort trap exception; do
  echo "== $kind"
  T="$(mktemp -d)"
  st=$(crash "$T" "$kind")
  [[ $st -ge 128 ]] && echo "  ok   child died by signal $((st - 128))" || { echo "  FAIL child exit $st"; fails=$((fails + 1)); }
  sleep 3   # ReportCrash writes the .ips a moment later
  selftest "$T" "$T/out"
  check "crash found on next launch" "$T/out.txt" "^pending: yes"
  check "breadcrumbs kept" "$T/out.txt" "^lastBreadcrumb: .*debug crash: $kind"
  case $kind in
    segv) check "signal named" "$T/out.txt" "SIGSEGV|SIGBUS" ;;
    abort) check "signal named" "$T/out.txt" "SIGABRT" ;;
    trap) check "signal named" "$T/out.txt" "SIGTRAP" ;;
    exception) check "exception reason recorded" "$T/out.txt" "^summary: NSGenericException: The window has been marked" ;;
  esac
  check "issue URL within limits" "$T/out.txt" "^issueURLLength: [0-9]{2,4}$"
  check "report written" "$T/out/report.txt" "Last actions"
  grep -E "^ips:" "$T/out.txt" | sed 's/^/  info /'
  selftest "$T" "$T/again"
  check "offered only once" "$T/again.txt" "^pending: no"
done

echo "== safe mode (two crashes within 60 s of launch)"
T="$(mktemp -d)"
crash "$T" abort >/dev/null
crash "$T" abort >/dev/null
selftest "$T" "$T/out"
check "safe mode on" "$T/out.txt" "^safeMode: true"
selftest "$T" "$T/after"
check "a clean launch after it: safe mode off" "$T/after.txt" "^safeMode: false"

echo
if [[ $fails -eq 0 ]]; then echo "crash self-test: PASS"; else echo "crash self-test: $fails FAILED"; fi
exit $(( fails > 0 ))
