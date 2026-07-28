#!/bin/bash
# BLINDED A/B: does bounding DXMT's command-buffer batching remove the long stalls?
#
#   control     d3d11.maxPassesPerCommandBuffer unset  (upstream batching, unbounded)
#   capped      d3d11.maxPassesPerCommandBuffer=32
#
# SAME BINARY IN BOTH ARMS. Only the config string differs, so the comparison cannot be confounded
# by the build. That is why both arms need the locally-built `capped` DXMT installed -- on stock
# DXMT the option does not exist and the experimental arm silently becomes a second control.
#
# WHY BLINDED. Earlier in this investigation Claude repeatedly told the user the stalls were
# "26 seconds" *before* asking him to report them, so those early confirmations are not independent
# evidence (recorded in STALL-BUFFER-SIZE.md). The player's perception is the instrument that has
# actually held up here -- twelve instrumented causes were falsified, and one unprompted count of
# zero stalls was the observation that broke a false lead. An instrument that good deserves not to
# be contaminated a second time. So the arm order is drawn at random, written to a file the player
# does not read, and only revealed once both arms are in.
#
# Usage:
#   bash stall-arms.sh run          # runs the next unplayed arm; play ~15 min, then quit the game
#   bash stall-arms.sh log <count>  # record how many LONG stalls that session had
#   bash stall-arms.sh unblind      # reveal the assignment + the encoder data (after BOTH arms)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/Library/Application Support/Decanter"
EXP="$D/stall-experiment"
CAPVAL=32
mkdir -p "$EXP"

# ---- one-time randomised assignment -------------------------------------------------
if [ ! -f "$EXP/assignment" ]; then
  if [ $((RANDOM % 2)) -eq 0 ]; then echo "1=control 2=capped" > "$EXP/assignment"
  else                               echo "1=capped 2=control" > "$EXP/assignment"; fi
  chmod 600 "$EXP/assignment"
fi
ORDER=$(cat "$EXP/assignment")
arm_kind() {  # 1|2 -> control|capped
  case "$ORDER" in
    "1=control 2=capped") [ "$1" = 1 ] && echo control || echo capped ;;
    *)                    [ "$1" = 1 ] && echo capped  || echo control ;;
  esac
}

case "${1:-run}" in
  run)
    # Refuse to run the experiment against a DXMT that has no cap option at all.
    if ! strings -n 6 "$D/Bottles/Steam-Wine11/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro/d3d11.dll" \
         2>/dev/null | grep -q maxPassesPerCommandBuffer; then
      echo "The installed DXMT has no maxPassesPerCommandBuffer option." >&2
      echo "  bash $HERE/dxmt-swap.sh install ~/src/dxmt/install-capped" >&2
      exit 1
    fi
    N=1; [ -f "$EXP/arm1.count" ] && N=2
    [ -f "$EXP/arm2.count" ] && { echo "Both arms already played. Run: bash $0 unblind"; exit 0; }
    KIND=$(arm_kind $N)
    STAMP="arm$N-$(date +%Y%m%d-%H%M%S)"
    echo "$STAMP" > "$EXP/arm$N.stamp"

    echo "=============================================="
    echo " ARM $N of 2"
    echo "=============================================="
    echo " Play NORMALLY for about 15 minutes."
    echo " Go somewhere that has stalled before - an area load, a death reload."
    echo " Count only LONG stalls (the multi-second freezes), NOT the brief hitches."
    echo " Then quit the game and run:   bash $0 log <number>"
    echo
    echo " Which arm this is will not be shown until both are done."
    echo "=============================================="
    echo

    if [ "$KIND" = capped ]; then
      bash "$HERE/gpuprof-direct.sh" --cap "$CAPVAL" --stamp "$STAMP"
    else
      bash "$HERE/gpuprof-direct.sh" --stamp "$STAMP"
    fi
    ;;

  log)
    C="${2:?usage: stall-arms.sh log <stall-count>}"
    N=1; [ -f "$EXP/arm1.count" ] && N=2
    echo "$C" > "$EXP/arm$N.count"
    echo "arm $N recorded: $C long stalls"
    [ "$N" = 1 ] && echo "Now run:  bash $0 run     (second arm)" \
                 || echo "Both arms in. Run:  bash $0 unblind"
    ;;

  unblind)
    [ -f "$EXP/arm2.count" ] || { echo "Both arms must be played first." >&2; exit 1; }
    echo "=============================================="
    echo " UNBLINDED  (cap value: $CAPVAL)"
    echo "=============================================="
    for N in 1 2; do
      KIND=$(arm_kind $N)
      STAMP=$(cat "$EXP/arm$N.stamp" 2>/dev/null)
      LOG="$D/gpustall-$STAMP.log"
      MINS="?"; ENC="no profiler data"
      if [ -f "$LOG" ]; then
        ENC=$(awk '{for(i=1;i<=NF;i++) if($i~/^encoders=/){e=$i;sub(/encoders=/,"",e);e=e+0;
              c++; s+=e; if(e>mx)mx=e; if(e>=100)big++}}
              END{printf "buffers=%d avg=%.1f max=%d >=100enc=%d", c, (c?s/c:0), mx, big+0}' "$LOG")
      fi
      printf "  arm %s  %-8s  stalls=%-4s  %s\n" "$N" "$KIND" "$(cat "$EXP/arm$N.count")" "$ENC"
    done
    echo "=============================================="
    echo "Read it with the sample size in mind: at the historical ~0.2-0.5 stalls/min,"
    echo "15 min is a handful of events. A clean capped arm is suggestive, not proof --"
    echo "a 14.6 min zero-stall run has already happened by luck once (STALL-BUFFER-SIZE.md)."
    ;;
  *) echo "usage: stall-arms.sh run | log <count> | unblind" >&2; exit 2 ;;
esac
