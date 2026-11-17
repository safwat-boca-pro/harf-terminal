#!/bin/zsh
zmodload zsh/datetime
# Run INSIDE the terminal you want to measure. Auto-detects the hosting .app process.
# Usage: bench.sh <label> [outfile]
label=${1:-term}; out=${2:-/tmp/bench-$label.txt}
cpu_s() { ps -o time= -p $1 | awk -F'[:.]' '{n=NF; s=$(n-1)+$n/100; if(n>=3)s+=$(n-2)*60; if(n>=4)s+=$(n-3)*3600; print s}'; }
fp_mb() { footprint $1 2>/dev/null | awk '/Footprint:/{for(i=1;i<=NF;i++)if($i=="Footprint:"){v=$(i+1);u=$(i+2)}; if(u=="KB")v/=1024; if(u=="GB")v*=1024; printf "%.0f",v; exit}'; }
# walk up to the .app process
pid=$$; while [ $pid -gt 1 ]; do
  c=$(ps -o comm= -p $pid); [[ $c == *.app/Contents/MacOS/* ]] && break; pid=$(ps -o ppid= -p $pid | tr -d ' ')
done
app=$pid; echo "app: $(ps -o comm= -p $app) pid=$app" | tee $out
f=/tmp/bench-data.txt; [ -f $f ] || { yes "The quick brown fox jumps over the lazy dog 0123456789" | head -c 50000000 > $f; }
sleep 3
echo "idle_footprint_MB: $(fp_mb $app)" | tee -a $out
c0=$(cpu_s $app)
t() { local s=$EPOCHREALTIME; eval "$1" >/dev/tty; printf "%s: %.2fs\n" "$2" $(( EPOCHREALTIME - s )) >&2; }
{ t "seq 1 2000000" "seq_2M_lines"
  t "cat $f" "cat_50MB"
  t "for i in {1..20000}; do printf '\e[3%dmcolor %d\e[0m\n' \$((i%8)) \$i; done" "ansi_colors_20k" } 2>&1 | tee -a $out
c1=$(cpu_s $app)
echo "app_cpu_seconds_during_load: $(echo "$c1 $c0" | awk '{printf "%.2f",$1-$2}')" | tee -a $out
echo "loaded_footprint_MB: $(fp_mb $app)" | tee -a $out
clear; sleep 2; ci=$(cpu_s $app); sleep 20; cj=$(cpu_s $app)
echo "idle_cpu_pct_20s: $(echo "$cj $ci" | awk '{printf "%.2f",($1-$2)/20*100}')" | tee -a $out
echo "final_footprint_MB: $(fp_mb $app)" | tee -a $out
