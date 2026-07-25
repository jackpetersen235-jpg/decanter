#!/bin/bash
# Find the LONGEST gpukeepalive interval that still holds the GPU above its lowest power state.
#
# WHY. 50 ms (20 submissions/sec) was picked in one step from 3 ms and the range above it was
# never tested. Every one of those submissions is a trip through the same
# IOGPUCommandQueueSubmitCommandBuffers -> IOConnectTrap4 path that the 26 s stalls block inside,
# so the fewer we make, the better — as long as the GPU still never reaches power state 0, which
# is what triggers the separate ~7 s firmware idle-wake freeze.
#
# The measurement is `CurrentPowerState` from ioreg. On this M5 `MaxPowerState` is 1, so this is a
# coarse awake/asleep flag, not a DVFS level — which is exactly the question being asked here.
#
# REQUIRES THE GAME TO BE CLOSED. With Sekiro running the GPU never idles, every interval passes,
# and the sweep tells you nothing. No playing needed — this is a pure idle test.
set -uo pipefail

DUR="${DUR:-25}"          # seconds per interval
HZ="${HZ:-5}"             # power-state samples per second
KA="$HOME/Applications/Sekiro.app/Contents/MacOS/gpukeepalive"

if pgrep -f 'sekiro\.exe' >/dev/null 2>&1; then
  echo "Sekiro is running — close it first, or this sweep measures nothing." >&2
  exit 1
fi
[ -x "$KA" ] || { echo "missing $KA" >&2; exit 1; }

powerstate() {
  ioreg -r -d 1 -c IOAccelerator 2>/dev/null \
    | tr ',' '\n' | grep -oE '"CurrentPowerState"=[0-9]+' | head -1 | cut -d= -f2
}

measure() {           # $1 = human label
  local n=0 zero=0 s
  local end=$(( $(date +%s) + DUR ))
  while [ "$(date +%s)" -lt "$end" ]; do
    s=$(powerstate)
    [ -n "$s" ] && { n=$((n+1)); [ "$s" = "0" ] && zero=$((zero+1)); }
    perl -e "select(undef,undef,undef,1/$HZ)" 2>/dev/null || sleep 1
  done
  if [ "$n" -eq 0 ]; then
    printf "  %-22s no samples\n" "$1"
  else
    printf "  %-22s %3d samples, %3d at state 0  (%5.1f%% asleep)  %s\n" \
      "$1" "$n" "$zero" "$(echo "scale=2; 100*$zero/$n" | bc)" \
      "$([ "$zero" -eq 0 ] && echo "HELD AWAKE" || echo "dropped to 0")"
  fi
}

echo "keepalive interval sweep — ${DUR}s per setting, ${HZ} Hz sampling"
echo

pkill -f gpukeepalive 2>/dev/null; sleep 3
echo "CONTROL (no keep-alive) — establishes that the metric can even detect sleep:"
measure "none"
echo

for us in 50000 100000 200000 400000 800000 1600000; do
  pkill -f gpukeepalive 2>/dev/null; sleep 2
  # Grace period means it stays alive while no game is present, which is what we want here.
  env -u DYLD_INSERT_LIBRARIES "$KA" "$us" >/dev/null 2>&1 &
  sleep 3
  measure "$((us/1000)) ms ($(echo "scale=1; 1000000/$us" | bc)/s)"
done

pkill -f gpukeepalive 2>/dev/null
echo
echo "Pick the LONGEST interval still showing HELD AWAKE, then confirm it in one play session."
echo "If CONTROL also shows HELD AWAKE, the metric cannot detect idle sleep here and this"
echo "sweep is inconclusive — do not read anything into the rest of the table."
