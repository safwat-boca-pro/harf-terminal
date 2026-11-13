#!/bin/sh
# Idle RSS / footprint / CPU of a launched .app. Method is documented in docs/perf.md.
# Usage: bench/idle.sh macos/.build/Harf.app [seconds=60]
set -eu
APP=${1:?usage: idle.sh <path/to/App.app> [seconds]}
SECS=${2:-60}
NAME=$(basename "$APP" .app)

open -n "$APP"
sleep 5   # let the first frame land
PID=$(pgrep -x "$NAME" | head -1)
[ -n "$PID" ] || { echo "process $NAME not found" >&2; exit 1; }

echo "pid=$PID  machine=$(sysctl -n machdep.cpu.brand_string)  macOS=$(sw_vers -productVersion)"
echo "rss_kb_start=$(ps -o rss= -p "$PID" | tr -d ' ')  cputime_start=$(ps -o time= -p "$PID" | tr -d ' ')"
footprint "$PID" 2>/dev/null | grep -E 'Footprint|phys_footprint' | head -3 || true

# %cpu every 2 s for SECS seconds
SAMPLES=$(
  i=0
  while [ "$i" -lt $((SECS / 2)) ]; do
    ps -o %cpu= -p "$PID" | tr -d ' '
    sleep 2
    i=$((i + 1))
  done
)
echo "$SAMPLES" | awk '{s+=$1; if($1>m)m=$1; n++} END {printf "idle_cpu_mean=%.2f%% max=%.2f%% samples=%d\n", s/n, m, n}'
echo "rss_kb_end=$(ps -o rss= -p "$PID" | tr -d ' ')  cputime_end=$(ps -o time= -p "$PID" | tr -d ' ')"
footprint "$PID" 2>/dev/null | grep -E 'Footprint|phys_footprint' | head -3 || true

kill "$PID"
