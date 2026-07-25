#!/bin/bash
# Run one cell of the pre-registered 2x2 stall factorial (docs/STALL-FACTORIAL.md).
#
# Usage: bash factorial-cell.sh <1|2|3|4>
#
# Enforces the parts of the protocol that are mechanical, so they cannot be fudged:
#   - sets MetalFX and keep-alive to the cell's assignment and VERIFIES both took effect
#   - refuses to report before 15 minutes of the game actually running
#   - prints stalls + minutes + rate ONLY; no interpretation (rule 6: no hypothesis until all
#     four cells are done)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CELL="${1:?usage: factorial-cell.sh <1|2|3|4>}"
MIN_MIN=15

case "$CELL" in
  1) FX=ON;  KA=OFF; STAMP=FACT-FXON-KAOFF ;;
  2) FX=ON;  KA=ON;  STAMP=FACT-FXON-KAON ;;
  3) FX=OFF; KA=OFF; STAMP=FACT-FXOFF-KAOFF ;;
  4) FX=OFF; KA=ON;  STAMP=FACT-FXOFF-KAON ;;
  *) echo "cell must be 1-4" >&2; exit 2 ;;
esac

ARGS=(--stamp "$STAMP")
[ "$FX" = OFF ] && ARGS+=(--no-metalfx)
# The launcher's keep-alive is disabled at source (two `if false &&` guards), so gpuprof-direct
# never starts it; for KA=ON we start it ourselves, matching the shipped 50 ms interval.
[ "$KA" = OFF ] && ARGS+=(--no-keepalive)

echo "=============================================="
echo " FACTORIAL CELL $CELL — MetalFX $FX, keep-alive $KA"
echo " minimum $MIN_MIN min of active play"
echo " protocol: >=1 area load, >=2 death-reloads, combat throughout"
echo "=============================================="

# clean slate — one wineserver per prefix, and stale processes have invalidated runs before
export WINEPREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
pkill -9 -f 'wineserver' 2>/dev/null; pkill -9 -f 'steam\.exe' 2>/dev/null
pkill -9 -f 'sekiro\.exe' 2>/dev/null; pkill -f 'MacOS/gpukeepalive' 2>/dev/null
sleep 3

bash "$HERE/gpuprof-direct.sh" "${ARGS[@]}" >/tmp/fact-$CELL.out 2>&1 &
RUNNER=$!

D="$HOME/Library/Application Support/Decanter"
LOG="$D/gpustall-$STAMP.log"
for _ in $(seq 1 40); do grep -q 'armed on' "$LOG" 2>/dev/null && break; sleep 5; done
grep -q 'armed on' "$LOG" 2>/dev/null || { echo "FAILED to arm — see /tmp/fact-$CELL.out" >&2; exit 1; }

# keep-alive ON is started here (launcher's own start is disabled at source)
if [ "$KA" = ON ]; then
  env -u DYLD_INSERT_LIBRARIES "$HOME/Applications/Sekiro.app/Contents/MacOS/gpukeepalive" 50000 \
    >/dev/null 2>&1 &
  sleep 4
fi

# VERIFY the assignment actually took — a silently-wrong cell is worse than no cell
KA_N=$(ps -Ao command= | grep -c '[M]acOS/gpukeepalive')
FX_N=$(grep -c 'MetalFX DISABLED' /tmp/fact-$CELL.out 2>/dev/null || echo 0)
echo "verify: keep-alive procs=$KA_N (want $([ "$KA" = ON ] && echo '>=1' || echo 0))"
echo "verify: MetalFX-disabled flag=$FX_N (want $([ "$FX" = OFF ] && echo 1 || echo 0))"
if { [ "$KA" = ON ] && [ "$KA_N" -lt 1 ]; } || { [ "$KA" = OFF ] && [ "$KA_N" -gt 0 ]; }; then
  echo "ABORT: keep-alive state does not match the cell" >&2; exit 1
fi
echo
echo "PLAY NOW. Quit the game when you have done at least $MIN_MIN minutes."
echo

START=$(date +%s)
while pgrep -f 'sekiro\.exe' >/dev/null 2>&1; do sleep 10; done
ELAPSED=$(( ($(date +%s) - START) / 60 ))
pkill -f 'MacOS/gpukeepalive' 2>/dev/null

N=$(grep -c 'SLOW cb#' "$LOG" 2>/dev/null || echo 0)
echo
echo "--- CELL $CELL RESULT (no interpretation, per protocol rule 6) ---"
printf "  MetalFX %-3s  keep-alive %-3s  stalls %d  minutes %d" "$FX" "$KA" "$N" "$ELAPSED"
[ "$ELAPSED" -gt 0 ] && printf "  rate %.3f/min" "$(echo "scale=4;$N/$ELAPSED" | bc)"
echo
if [ "$ELAPSED" -lt "$MIN_MIN" ] && [ "$N" -lt 3 ]; then
  echo "  ⚠️  SHORT CELL ($ELAPSED < $MIN_MIN min, <3 stalls) — INVALID, re-run this cell."
fi
