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
# VALIDATE the match. A bare `pgrep -f` picked up an unrelated process on the first run and
# logged 590 Dropbox/AirPlay endpoints as though they were the game's — worse than no data,
# because it looked like a result. Confirm the command line really is the game before trusting it.
# Match on the EXECUTABLE NAME, never the command line. Two runs already attached to the wrong
# process: first an unrelated daemon, then the very shell that had just launched the game - its
# argv contains the ASBR path, so even a "*ASBR.exe*" cmdline check matched it. `ps -o comm=`
# reports the running binary, which a shell can never fake.
find_game() {
  # -x matches the executable NAME exactly, so a shell whose argv merely mentions the game
  # cannot match. No basename/xargs: the wine path contains spaces and quotes.
  pgrep -x 'ASBR.exe' 2>/dev/null | head -1 | grep . 
}
echo "waiting for the game…"
PID=""
until PID=$(find_game); do sleep 2; done
echo "watching pid $PID"
echo "  cmdline: $(ps -o command= -p "$PID" 2>/dev/null | cut -c1-100)"
echo "  -> $OUT"
echo "NOW: go into Online in the game. Ctrl-C here when you're done."
echo

: > "$OUT"
seen=""
while find_game >/dev/null 2>&1; do
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
