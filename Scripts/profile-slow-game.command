#!/bin/bash
# Why is this game slow? — measure it instead of guessing.
#
# Written after two wrong guesses about Peggle Deluxe (first the graphics backend, then the Wine
# engine). Both were plausible and both were wrong, and each cost a round trip. This script
# produces the evidence that distinguishes the real causes from each other.
#
# START THE GAME FIRST, get it to the slow part, THEN double-click this. No password needed.
set -uo pipefail

OUT="$HOME/Desktop/decanter-slow-game-report.txt"
SECONDS_TO_SAMPLE=8

exec > >(tee "$OUT") 2>&1
echo "Decanter — slow game report"
echo "$(date)"
echo "Mac: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)  |  macOS $(sw_vers -productVersion)"
echo "=================================================================="

# ---------------------------------------------------------------- find the game
# `comm` for a Wine process is a WINDOWS path (C:\...\game.exe), so split on both separators.
# Matching on the command line instead of the program is the recurring bug in this project.
CANDIDATES=$(ps -Ao pid,pcpu,comm= | grep -iE '\.exe$' | grep -viE 'steam(webhelper|service)?\.exe|explorer\.exe|services\.exe|winedevice\.exe|plugplay\.exe|rpcss\.exe|svchost\.exe|conhost\.exe|wineboot\.exe|start\.exe|cmd\.exe|tabtip\.exe')

if [ -z "$CANDIDATES" ]; then
  echo
  echo "No game appears to be running."
  echo "Start the game, get it to the slow part, then run this again."
  exit 0
fi

# Busiest .exe = the game. Sorting on CPU beats guessing by name.
LINE=$(echo "$CANDIDATES" | sort -k2 -nr | head -1)
PID=$(echo "$LINE" | awk '{print $1}')
CPU=$(echo "$LINE" | awk '{print $2}')
EXE=$(echo "$LINE" | cut -d' ' -f3-)
NAME=$(echo "$EXE" | tr '\\' '/' | awk -F/ '{print $NF}')

echo
echo "GAME"
echo "  process : $NAME  (pid $PID)"
echo "  cpu now : ${CPU}%"

# ---------------------------------------------------------------- 32-bit or 64-bit?
# The single most important fact. Rosetta emulates x87 floating point IN SOFTWARE, and pre-2010
# 32-bit games do their maths on the x87 FPU — that is a cliff no graphics setting can climb.
# A 64-bit game uses SSE and is NOT subject to it, which would rule the whole theory out.
WINPATH=$(echo "$EXE" | sed 's|^[A-Za-z]:||' | tr '\\' '/')
MACPATH=""
for P in "$HOME/Library/Application Support/Decanter/Bottles"/*/drive_c; do
  [ -f "$P$WINPATH" ] && MACPATH="$P$WINPATH" && break
done

echo
echo "EXECUTABLE"
if [ -n "$MACPATH" ]; then
  DESC=$(file -b "$MACPATH" 2>/dev/null)
  echo "  $MACPATH"
  echo "  $DESC"
  case "$DESC" in
    *80386*|*PE32\ *) echo "  -> 32-BIT. Subject to Rosetta's software x87 emulation." ; BITS=32 ;;
    *x86-64*|*PE32+*) echo "  -> 64-bit. NOT subject to the x87 problem — look elsewhere." ; BITS=64 ;;
    *)                echo "  -> could not classify." ; BITS=0 ;;
  esac
else
  echo "  (could not locate the .exe on disk to check its architecture)"
  BITS=0
fi

# ---------------------------------------------------------------- where is the time going?
echo
echo "SAMPLING ${SECONDS_TO_SAMPLE}s — leave the game in the slow part…"
TMP=$(mktemp)
sample "$PID" "$SECONDS_TO_SAMPLE" -f "$TMP" >/dev/null 2>&1

if [ ! -s "$TMP" ]; then
  echo "  sample failed (the game may have exited)."
  exit 0
fi

# Is Rosetta in the picture at all, and how much of the time is spent inside it?
# `grep -c` prints 0 AND exits 1 when a file has no matches, so `|| echo 0` would produce TWO
# lines. Sanitise instead — this exact idiom caused a 160-second hang elsewhere in this project.
count() { grep -ci "$1" "$TMP" 2>/dev/null | head -1 | tr -dc '0-9'; }
TOTAL=$(count "Thread_"); TOTAL=${TOTAL:-0}
# Match the TRANSLATOR, not the string "rosetta". libRosetta.dylib is loaded into EVERY process on
# Apple silicon, including native arm64 ones, so a bare grep for "rosetta" reports translation on
# a process that is not being translated — verified against a native arm64 test binary. The actual
# translator is /usr/libexec/rosetta/... or libRosettaRuntime, and neither appears unless it is real.
ROSETTA=$(count "/usr/libexec/rosetta\|libRosettaRuntime"); ROSETTA=${ROSETTA:-0}

echo
echo "TRANSLATION"
if [ "$ROSETTA" -gt 0 ]; then
  echo "  Rosetta 2 IS translating this process ($ROSETTA references)."
  [ "${BITS:-0}" = "32" ] && echo "  Combined with a 32-bit binary, x87 emulation is the prime suspect."
else
  echo "  No Rosetta frames seen — this is running natively or the sample missed it."
fi

echo
echo "TOP FRAMES (where the time actually went)"
# Leading integers in a sample file are sample counts; the heaviest lines are the hot paths.
# Drop the frame-tree ROOTS: start/main/Thread_N carry the entire weight of every thread by
# definition, so they always top the list and say nothing about where the time went.
grep -oE '[0-9]+ [A-Za-z_][A-Za-z0-9_:.$<>-]+' "$TMP" \
  | awk '{c[$2]+=$1} END {for (k in c) printf "%8d  %s\n", c[k], k}' \
  | grep -vE ' (start|main|start_wqthread|_pthread_[a-z_]+|Thread_[0-9]+)$' \
  | sort -nr | head -15 | sed 's/^/ /'

cp "$TMP" "$HOME/Desktop/decanter-sample-raw.txt" 2>/dev/null
rm -f "$TMP"

echo
echo "=================================================================="
echo "Saved: $OUT"
echo "       $HOME/Desktop/decanter-sample-raw.txt"
echo "Send BOTH files back."
