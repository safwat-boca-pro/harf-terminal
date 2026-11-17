#!/bin/zsh
# Opens a fresh Harf instance, waits for you to run `seq 1 2000000` in it, samples it for 3s when CPU > 30%.
# Output: bench/profile-seq.txt
before=$(pgrep -f 'Harf.app/Contents/MacOS/Harf$' | sort)
open -n -a Harf
while :; do pid=$(comm -13 <(echo $before) <(pgrep -f 'Harf.app/Contents/MacOS/Harf$' | sort) | head -1); [ -n "$pid" ] && break; sleep 0.2; done
echo "fresh Harf pid $pid: now run  seq 1 2000000  in it"
sleep 8   # let startup CPU settle so it does not trigger the sampler
echo "armed: run  seq 1 2000000  now"
until [ "$(ps -o %cpu= -p $pid | cut -d. -f1 | tr -d ' ')" -ge 30 ] 2>/dev/null; do sleep 0.1; done
sample $pid 2 -file ${0:A:h}/profile-seq.txt >/dev/null && echo "sampled -> bench/profile-seq.txt"
