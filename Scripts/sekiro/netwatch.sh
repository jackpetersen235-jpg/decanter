#!/bin/bash
# Watch what a Wine game actually talks to, to tell "refused at authentication" apart from
# "networking is broken".
#
# WHY. JJBA All-Star Battle R fails online with "transmission error". The game ships Epic Online
# Services (EOSSDK-Win64-Shipping.dll) plus Easy Anti-Cheat integrated through it
# (EasyAntiCheat_EOS_Setup.exe), and our bottle only runs at all because it bypasses EAC by
# launching ASBR.exe directly. So the error has two very different possible causes:
#
#   NO outbound traffic at all      -> the client never gets past auth. EAC/EOS is refusing it,
#                                      and no amount of network tuning will help.
#   Traffic that never completes    -> a real networking problem (NAT, ports, IPv6, relay),
#                                      which might be fixable.
#
# Records every distinct remote endpoint the game opens, so the answer is a list rather than an
# impression.
#
# Usage:  bash netwatch.sh            # start it, then try Online in the game
#         Ctrl-C when done
set -uo pipefail

D="$HOME/Library/Application Support/Decanter"
OUT="$D/netwatch-$(date +%Y%m%d-%H%M%S).log"
echo "waiting for the game…"
until pgrep -f 'ASBR\.exe' >/dev/null 2>&1; do sleep 2; done
PID=$(pgrep -f 'ASBR\.exe' | head -1)
echo "watching pid $PID  ->  $OUT"
echo "NOW: go into Online in the game. Ctrl-C here when you're done."
echo

: > "$OUT"
seen=""
while pgrep -f 'ASBR\.exe' >/dev/null 2>&1; do
  # -n/-P keep it fast (no DNS/port name lookups); we resolve interesting hosts afterwards.
  while read -r line; do
    ep=$(echo "$line" | awk '{print $(NF-1), $NF}')
    case "$seen" in *"|$ep|"*) continue ;; esac
    seen="$seen|$ep|"
    printf '%s  %s\n' "$(date +%H:%M:%S)" "$ep" | tee -a "$OUT"
  done < <(lsof -nP -p "$PID" -i 2>/dev/null | tail -n +2)
  sleep 1
done

echo
echo "=============================================="
echo " game exited. endpoints contacted: $(wc -l < "$OUT" | tr -d ' ')"
echo " log: $OUT"
echo "=============================================="
if [ ! -s "$OUT" ]; then
  echo " NOTHING was contacted -> the client is being refused before it reaches the network."
  echo " That points at EAC/EOS authentication, which cannot be fixed on macOS."
else
  echo " It DID reach the network. Endpoints above; anything epicgames/eos = matchmaking."
fi
