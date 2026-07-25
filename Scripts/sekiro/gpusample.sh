#!/bin/bash
# 1 Hz GPU sampler — CSV, designed to be read alongside gpustall.log by wall-clock time.
#
# Supersedes the ad-hoc samplers used in the earlier stall sessions, which only captured
# "Device Utilization %". Three of these columns are new and each one independently discriminates
# between the competing explanations for a stall:
#
#   renderer/tiler  A stall that is one fat compute/fragment encoder pins RENDERER while TILER
#                   sits at 0. Geometry-side trouble would show the opposite. Device Utilization
#                   alone cannot tell these apart — it is the max of the two.
#   submits         Submissions since last sample. ~0 through a stall means nothing new is being
#                   queued, i.e. the GPU is chewing one long unit of work. A steady non-zero rate
#                   means a BACKLOG of normal work and the "one pathological shader" model is wrong.
#   power           CurrentPowerState is live here. docs/VALIDATION-SESSION-ABORTED.md claims GPU
#                   power state is only visible in gpuEvent-*.ips crash reports and therefore that
#                   a clean keep-alive run can never confirm its own mechanism. That is not true —
#                   this column confirms it live, with no hang required.
#
# Usage: bash gpusample.sh [outfile.csv]
set -uo pipefail

OUT="${1:-$HOME/Library/Application Support/Decanter/gpusample-$(date +%Y%m%d-%H%M%S).csv}"
echo "ts,wall,device_util,renderer_util,tiler_util,power,driver_power,submits,recovery,pid,cpu,state,freemb" > "$OUT"
echo "sampling to $OUT — Ctrl-C to stop"

prev_sub=""
while true; do
  now=$(date +%s)
  wall=$(date +%H:%M:%S)

  # One ioreg call per sample; splitting on commas turns the flattened dict into greppable lines.
  io=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | tr ',' '\n')
  get() { echo "$io" | grep -oE "\"$1\"=[0-9]+" | head -1 | cut -d= -f2; }

  dev=$(get 'Device Utilization %')
  ren=$(get 'Renderer Utilization %')
  til=$(get 'Tiler Utilization %')
  pwr=$(get 'CurrentPowerState')
  dpw=$(get 'DriverPowerState')
  sub=$(get 'fSubmissionsSinceLastCheck')
  rec=$(get 'recoveryCount')

  # Report submissions as a delta; the raw counter is meaningless on its own.
  if [ -n "$prev_sub" ] && [ -n "$sub" ]; then d_sub=$((sub - prev_sub)); else d_sub=""; fi
  prev_sub="$sub"

  pid=$(pgrep -f 'sekiro\.exe' | head -1)
  if [ -n "$pid" ]; then
    read -r cpu state <<< "$(ps -o pcpu=,state= -p "$pid" 2>/dev/null | tr -s ' ')"
  else
    cpu=""; state=""
  fi

  free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); printf "%d", $3*16384/1048576}')

  echo "$now,$wall,${dev:-},${ren:-},${til:-},${pwr:-},${dpw:-},${d_sub:-},${rec:-},${pid:-},${cpu:-},${state:-},${free:-}" >> "$OUT"
  sleep 1
done
