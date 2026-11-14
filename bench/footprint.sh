#!/bin/sh
# phys_footprint of Harf at 700x420 pt content, the way docs/perf.md defines it: Release build, one window, measured
# 12 to 20 s after launch. Starts the binary itself and tracks that pid; it never looks a process up by name and
# only ever kills the process it started.
#
# Exits 1 if the footprint is over the target (30 MB, or MAX_MB=<n> in the environment), so it can guard a change.
# Usage: bench/footprint.sh [settle_seconds=15] [mode=settled|scrollback|flood]
#   settled     an empty session at the shell prompt
#   scrollback  the shell first prints 6000 lines (enough to fill the 1 MiB scrollback), then settles
#   flood       the shell first prints 100 MB, then settles
set -eu
SETTLE=${1:-15}
MODE=${2:-settled}
APP="$(cd "$(dirname "$0")/.." && pwd)/macos/.build/Harf.app/Contents/MacOS/Harf"
[ -x "$APP" ] || { echo "build the app first: macos/build-app.sh" >&2; exit 1; }
DONE="${TMPDIR:-/tmp}/harf-footprint-done.$$"
rm -f "$DONE"
case "$MODE" in
  settled) CMD="" ;;
  scrollback) CMD="i=0; while [ \$i -lt 6000 ]; do echo scrollback line \$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=\$((i+1)); done; touch $DONE" ;;
  flood) CMD="yes 'flood flood flood flood flood flood flood flood flood flood flood flood flood' | head -c 100000000; touch $DONE" ;;
  *) echo "unknown mode $MODE" >&2; exit 1 ;;
esac

HARF_CONTENT_SIZE=700x420 HARF_CHILD_CMD="$CMD" "$APP" >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; rm -f "$DONE"' EXIT
kill -0 "$PID" 2>/dev/null || { echo "Harf did not start" >&2; exit 1; }

if [ -n "$CMD" ]; then
  i=0
  while [ ! -e "$DONE" ] && [ $i -lt 600 ]; do sleep 1; i=$((i + 1)); done
  [ -e "$DONE" ] || { echo "the child did not finish within 10 minutes" >&2; exit 1; }
  echo "child finished after about ${i}s"
fi
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "Harf exited early" >&2; exit 1; }

echo "mode=$MODE settle=${SETTLE}s pid=$PID machine=$(sysctl -n machdep.cpu.brand_string) macOS=$(sw_vers -productVersion) commit=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo ?)"
REPORT=$(footprint "$PID" 2>/dev/null)
printf '%s\n' "$REPORT" | sed -n '2p;5,24p'
MB=$(printf '%s\n' "$REPORT" | sed -n 's/.*Footprint: \([0-9][0-9]*\) MB.*/\1/p' | head -1)
[ -n "$MB" ] || { echo "could not read the footprint from: $(printf '%s\n' "$REPORT" | head -3)" >&2; exit 1; }
LIMIT=${MAX_MB:-30}
echo "rss_kb=$(ps -o rss= -p "$PID" | tr -d ' ')  cputime=$(ps -o time= -p "$PID" | tr -d ' ')"
if [ "$MB" -gt "$LIMIT" ]; then echo "FOOTPRINT OVER BUDGET: ${MB} MB > ${LIMIT} MB (mode $MODE)" >&2; exit 1; fi
echo "footprint ${MB} MB is within ${LIMIT} MB"
