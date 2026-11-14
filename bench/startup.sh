#!/bin/sh
# Time from process start to the end of the first drawn frame, N launches (default 10). Warm file cache: a cold cache needs
# root (`purge`), so run `sudo purge` first if you want that number. Starts the binary itself and tracks that pid only.
# Usage: bench/startup.sh [runs=10]
set -eu
RUNS=${1:-10}
APP="$(cd "$(dirname "$0")/.." && pwd)/macos/.build/Harf.app/Contents/MacOS/Harf"
[ -x "$APP" ] || { echo "build the app first: macos/build-app.sh" >&2; exit 1; }
OUT="${TMPDIR:-/tmp}/harf-startup.$$"
trap 'rm -f "$OUT"' EXIT
i=0
while [ "$i" -lt "$RUNS" ]; do
  : > "$OUT"
  HARF_TRACE=startup HARF_CONTENT_SIZE=700x420 "$APP" > "$OUT" 2>&1 &
  PID=$!
  t=0
  while ! grep -q startup_ms "$OUT" && [ "$t" -lt 100 ]; do sleep 0.1; t=$((t + 1)); done
  grep -o 'startup_ms=[0-9.]*' "$OUT" | head -1
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  i=$((i + 1))
done
