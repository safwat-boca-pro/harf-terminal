#!/bin/zsh
# Launches fresh Terminal.app + fresh Harf instance, runs bench.sh in each, prints side by side.
d=${0:A:h}; rm -f /tmp/bench-Terminal.txt /tmp/bench-Harf.txt
osascript -e "tell application \"Terminal\" to do script \"$d/bench.sh Terminal; exit\"" >/dev/null
open -n -a Harf --args 2>/dev/null; sleep 4   # new instance; type the command below into it if it doesn't autorun
echo "In the NEW Harf window run:  $d/bench.sh Harf"
until [ -f /tmp/bench-Terminal.txt ] && grep -q final /tmp/bench-Terminal.txt && [ -f /tmp/bench-Harf.txt ] && grep -q final /tmp/bench-Harf.txt; do sleep 2; done
paste -d'|' /tmp/bench-Terminal.txt /tmp/bench-Harf.txt | column -t -s'|'
