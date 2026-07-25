#!/bin/bash
# ⚠️ THIS SCRIPT DOES NOT WORK FOR PROFILING. USE gpuprof-direct.sh INSTEAD.
#
# It launches the game through Steam's `-applaunch`, and **Steam builds its own environment block
# for the games it spawns**, so unix-only vars — DYLD_INSERT_LIBRARIES among them — are dropped on
# the way. The profiler therefore never loads into sekiro.exe and the log file is never even
# created. Two full play sessions (2026-07-21, 2026-07-22) recorded nothing before this was found.
# Proof: the same env reaches a directly wine-spawned process fine (`wine notepad` logs "loaded"),
# but never a Steam-spawned sekiro.exe.
#
# It also inherits the applaunch-drop bug: on a cold start Steam silently discards the request if
# it arrives while the client is still bringing up its UI.
#
# Kept only as the record of a dead end. Do not resurrect without solving env propagation.
#
# ---------------------------------------------------------------------------------------------
# Launch Sekiro with the Metal stall profiler attached, plus the correlating 1 Hz GPU sampler.
#
# DOES NOT MODIFY Sekiro.app. It sets env and execs the bundle's existing launcher directly,
# which inherits env normally — `open(1)` would NOT forward it (see Decanter/CLAUDE.md).
# The known-good setup stays byte-identical; stop using this script and everything is as before.
#
# Usage:  bash gpuprof-run.sh [--force] [--slow-ms N]
#           --force     quit a running Steam first (see the cold-Steam requirement below)
#           --slow-ms   dump threshold in ms, default 250
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DYL="$HERE/libgpustall.dylib"
APP="$HOME/Applications/Sekiro.app"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
DATA="$HOME/Library/Application Support/Decanter"
STAMP="$(date +%Y%m%d-%H%M%S)"
STAMP_OVERRIDE=""

FORCE=0
ATTACH=0
SLOW_MS=250
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --attach)  ATTACH=1; shift ;;
    # With --attach the game inherits the RUNNING Steam's env, including the GPUSTALL_LOG path
    # from that earlier run — so anything we export now is ignored and the profiler keeps writing
    # to the original file. Reuse the original stamp or the log and CSV land under different names
    # and gpustall-report.sh cannot correlate them.
    --stamp)   STAMP_OVERRIDE="$2"; shift 2 ;;
    --slow-ms) SLOW_MS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$DYL" ] || { echo "missing $DYL — run: bash $HERE/build-gpustall.sh" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/Sekiro" ] || { echo "missing $APP" >&2; exit 1; }

# COLD STEAM IS MANDATORY. Sekiro is started via `steam.exe -applaunch`, and Steam hands the game
# the environment of the ALREADY-RUNNING client (GAMING-STACK.md 4b — the same trap that made
# MTL_SHADER_VALIDATION stick around for an entire session). Against a warm Steam,
# DYLD_INSERT_LIBRARIES never reaches sekiro.exe and this run silently profiles nothing.
if pgrep -f '/steam\.exe' >/dev/null 2>&1; then
  if [ "$ATTACH" = 1 ]; then
    # Only valid when THIS script started the running Steam — then it already carries the profiler
    # env and the game it spawns will inherit it. macOS will not let us read another process's
    # environment to confirm (`ps -E` returns nothing for wine processes), so the real check is
    # the "armed" line appearing in the profiler log once the game is up. Watch for it.
    echo "attaching to the running Steam (assumed started by a previous gpuprof-run)."
    echo "VERIFY: an 'armed on' line must appear in the profiler log once the game starts."
  elif [ "$FORCE" = 1 ]; then
    echo "quitting running Steam so the game inherits the profiler env..."
    "$APP/Contents/Frameworks/Wine/bin/wineserver" -k -w 2>/dev/null || true
    pkill -f 'steam\.exe' 2>/dev/null || true
    pkill -f 'explorer\.exe' 2>/dev/null || true
    sleep 3
  else
    echo "Steam is already running. It would hand sekiro.exe its own (un-profiled) environment," >&2
    echo "so this run would collect nothing. Re-run with --force to quit Steam first," >&2
    echo "or --attach if THIS script started that Steam (then it already has the env)." >&2
    exit 1
  fi
fi

[ -n "$STAMP_OVERRIDE" ] && STAMP="$STAMP_OVERRIDE"
export GPUSTALL_LOG="$DATA/gpustall-$STAMP.log"
export GPUSTALL_SLOW_MS="$SLOW_MS"
export DYLD_INSERT_LIBRARIES="$DYL"
# Default arming match is "sekiro", so steam.exe / services.exe / explorer.exe stay uninstrumented.

CSV="$DATA/gpusample-$STAMP.csv"
bash "$HERE/gpusample.sh" "$CSV" >/dev/null 2>&1 &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT INT TERM

echo "profiler log : $GPUSTALL_LOG"
echo "sampler csv  : $CSV"
echo "slow threshold: ${SLOW_MS}ms"
echo
echo "Play normally, hitting the areas that stall. Quit the game when done —"
echo "the sampler stops and the report prints automatically."
echo

# NOT `exec`. Two reasons:
#  1. exec replaces this shell, discarding the EXIT trap, so the sampler would run forever.
#  2. Sekiro.app's launcher ends in `wine steam.exe -applaunch`, which RETURNS as soon as Steam
#     has been told to start the game — it is not alive for the play session. So the thing to
#     wait on is sekiro.exe itself, not the launcher.
#
# RETRY THE APPLAUNCH. Observed 2026-07-21: on a cold start the bundle launcher sends
# `-applaunch` as soon as a new "Logged On," line lands in connection_log.txt, but the client is
# still bringing up its CEF UI at that point and silently DROPS the request — Steam sat logged in
# for 5 minutes with no "App Running" transition in content_log.txt and the game never appeared.
# Re-invoking the launcher takes its warm-start path (Steam up + already logged on) and re-sends
# the applaunch to a now-settled client, which does take.
launch_attempt() { "$APP/Contents/MacOS/Sekiro" >/dev/null 2>&1 || true; }

echo "launching..."
launch_attempt
GAME_UP=0
for attempt in 1 2 3 4; do
  for _ in $(seq 1 20); do          # ~40 s per attempt
    if pgrep -f 'sekiro\.exe' >/dev/null 2>&1; then GAME_UP=1; break; fi
    sleep 2
  done
  [ "$GAME_UP" = 1 ] && break
  echo "no game after attempt $attempt — re-sending applaunch"
  launch_attempt
done

if [ "$GAME_UP" != 1 ]; then
  echo "sekiro.exe never started after 4 attempts. Check Steam's window for a dialog." >&2
  exit 1
fi
echo "game is up. profiling until it exits."

# The one thing that can still silently fail: env not reaching the game. Say so early.
sleep 20
if [ -s "$GPUSTALL_LOG" ]; then
  echo "PROFILER ARMED — $(grep -c 'armed on' "$GPUSTALL_LOG" 2>/dev/null) device(s). Collecting."
else
  echo "WARNING: profiler log still empty — the injection may not have reached sekiro.exe." >&2
  echo "         If it stays empty, quit and re-run with --force (cold Steam)." >&2
fi

while pgrep -f 'sekiro\.exe' >/dev/null 2>&1; do sleep 5; done
echo "game exited."
kill $SAMPLER 2>/dev/null || true
sleep 1

echo
bash "$HERE/gpustall-report.sh" "$STAMP"
