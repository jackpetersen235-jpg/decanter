#!/bin/bash
# Launch sekiro.exe DIRECTLY under wine, bypassing Steam's game-spawn, with the profiler attached.
#
# WHY. Steam builds an explicit environment block for the games it launches, so unix-only vars —
# including DYLD_INSERT_LIBRARIES — do not survive `-applaunch`. Measured 2026-07-22: the dylib
# loads fine into a wine-spawned Windows process (`wine notepad` logs "loaded"), but never into a
# sekiro.exe that Steam spawned. Two full play sessions recorded nothing because of this.
# Launching the exe ourselves keeps our environment, and also avoids the applaunch-drop bug that
# cost two more launches.
#
# Steam must still be RUNNING and logged in: steam_api64.dll connects to the live client, and
# SteamAppId is what tells it which app this process is.
#
# Usage: bash gpuprof-direct.sh [--slow-ms N] [--stamp NAME]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DYL="$HERE/libgpustall.dylib"

NO_KA=0
NO_METALFX=0
SYNC_MODE=
KA_US=50000
SLOW_MS=250
STAMP="$(date +%Y%m%d-%H%M%S)"
# --app points at an alternative bundle so a different ENGINE (e.g. a DXMT downgrade) can be
# A/B tested on an APFS clone without touching the known-good ~/Applications/Sekiro.app.
APP_BUNDLE="$HOME/Applications/Sekiro.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --slow-ms) SLOW_MS="$2"; shift 2 ;;
    --stamp)   STAMP="$2"; shift 2 ;;
    --app)     APP_BUNDLE="$2"; shift 2 ;;
    # Run WITHOUT the GPU keep-alive. The stalls are a block inside IOGPU's submit trap, and the
    # keep-alive is a second process submitting to the same GPU 20x/sec — a variable WE added, so
    # it must be ruled in or out before blaming Apple's driver. Costs temporary exposure to the
    # firmware idle-wake hang (the other, unrelated bug) for the duration of the test.
    --no-keepalive) NO_KA=1; shift ;;
    # Disable MetalFX. Must be applied AFTER the launcher's exports are eval'd below, or they
    # overwrite it. NOTE this also RAISES GPU load: with spatial upscaling the game renders at a
    # lower internal resolution and MetalFX scales it up, so turning it off means rendering at
    # full resolution. The test is whether removing MetalFX's own submissions helps more than the
    # extra pixels hurt.
    --no-metalfx) NO_METALFX=1; shift ;;
    # Sync mode override, applied AFTER the launcher's exports (which hardcode msync) or they win.
    # msync and esync are BOTH compiled into the current wine-10 engine. Both are fast userspace
    # paths that skip the wineserver round-trip; they differ in implementation and therefore in
    # timing. msync is implicated in the 26 s IOGPU submit stalls (wine 11, no msync = 0 stalls).
    --sync) SYNC_MODE="$2"; shift 2 ;;
    # Keep-alive interval in microseconds. Default 50000 (20/s) is the shipped value. Wake-latency
    # measurement (gpuwake.m, 2026-07-24) shows 200000-600000 hold the GPU awake just as well
    # (p99 ~1.2-1.8 ms) while degradation only starts at 800000 (p99 7.8 ms) — so 200000 gives 4x
    # fewer trips through the IOGPU submit trap with margin to spare.
    --keepalive-us) KA_US="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CONTENTS="$APP_BUNDLE/Contents"
WINEROOT="$CONTENTS/Frameworks/Wine"
WB="$WINEROOT/bin"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
CACHE="$HOME/Library/Application Support/Decanter/ShaderCache/Sekiro"
DATA="$HOME/Library/Application Support/Decanter"
GAME="$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro/sekiro.exe"
[ -x "$CONTENTS/MacOS/Sekiro" ] || { echo "no launcher in $APP_BUNDLE" >&2; exit 1; }
echo "engine: $APP_BUNDLE"

[ -f "$DYL" ]  || { echo "missing $DYL — run build-gpustall.sh" >&2; exit 1; }
[ -f "$GAME" ] || { echo "missing $GAME" >&2; exit 1; }
mkdir -p "$CACHE"

# Steam has to be up first — the game's steam_api64.dll talks to the running client.
if ! pgrep -f '/steam\.exe' >/dev/null 2>&1; then
  echo "Steam is not running. Starting it (this does NOT need the profiler env)..."
  ( export WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEMSYNC=1 WINEESYNC=1
    "$WB/wine" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" \
       -silent -no-cef-sandbox -skipinitialbootstrap >/dev/null 2>&1 ) &
  CONNLOG="$PREFIX/drive_c/Program Files (x86)/Steam/logs/connection_log.txt"
  BASE=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)
  echo "waiting for Steam to log on..."
  for _ in $(seq 1 90); do
    NOW=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)
    [ "$NOW" -gt "$BASE" ] && break
    sleep 2
  done
  # Let the client settle. Sending work at the instant the logon line lands is exactly what the
  # bundle launcher does, and it is why -applaunch gets dropped on a cold start.
  sleep 15
fi

# Take the tuned environment from the bundle launcher itself rather than restating it here.
# Those values (DXMT_CONFIG, MetalFX factor, msync, shader cache, fullscreen) are the result of a
# lot of measurement; a hand-copied duplicate would silently drift from the real setup.
eval "$(grep -E '^export ' "$CONTENTS/MacOS/Sekiro")"

case "$SYNC_MODE" in
  esync)  export WINEMSYNC=0 WINEESYNC=1; echo "sync mode: ESYNC (msync off)" ;;
  msync)  export WINEMSYNC=1 WINEESYNC=0; echo "sync mode: MSYNC" ;;
  server) export WINEMSYNC=0 WINEESYNC=0; echo "sync mode: SERVER-SIDE (slow path)" ;;
  "")     : ;;
  *) echo "unknown --sync: $SYNC_MODE" >&2; exit 2 ;;
esac

if [ "$NO_METALFX" = 1 ]; then
  export DXMT_METALFX_SPATIAL_SWAPCHAIN=0
  export DXMT_CONFIG="d3d11.preferredMaxFrameRate=60;d3d11.ignoreMapFlagNoWait=True;d3d11.sampleNaNToZero=True;d3d11.defuseFma=True"
  echo "MetalFX DISABLED (no spatial upscale, full-res render)"
fi

# Tell steam_api64 which app this is, since Steam is not the one launching us.
export SteamAppId=814380 SteamGameId=814380

export DYLD_INSERT_LIBRARIES="$DYL"
export GPUSTALL_LOG="$DATA/gpustall-$STAMP.log"
export GPUSTALL_SLOW_MS="$SLOW_MS"
export GPUSTALL_VERBOSE=1

# Run the GPU keep-alive exactly as the bundle launcher does. The stalls we are chasing occur
# WITH it running (it is part of Jack's accepted config), so omitting it here would change the
# conditions being measured. It is excluded from profiling by name — see GPUSTALL_EXCLUDE — so
# its 20 blits/sec never reach the baseline.
#
# `env -u DYLD_INSERT_LIBRARIES` IS REQUIRED, not tidiness. gpukeepalive is a native **arm64**
# binary while the profiler dylib is x86_64 (it has to be, to match the Rosetta wine tree). dyld
# does not warn and continue on an architecture mismatch for an inserted library — it TERMINATES
# the process:
#   dyld[...]: terminating because inserted dylib ... incompatible architecture
#             (have 'x86_64', need 'arm64')
# So exporting the injection env and then starting the keep-alive silently kills it, leaving the
# session with no firmware-hang protection. Verified 2026-07-24.
KA="$CONTENTS/MacOS/gpukeepalive"
if [ "$NO_KA" = 1 ]; then
  echo "keep-alive DISABLED for this run (--no-keepalive)"
  pkill -f gpukeepalive 2>/dev/null || true
elif [ -x "$KA" ] && ! pgrep -f gpukeepalive >/dev/null 2>&1; then
  echo "keep-alive interval: ${KA_US}us ($(echo "scale=1; 1000000/$KA_US" | bc)/s)"
  env -u DYLD_INSERT_LIBRARIES "$KA" "$KA_US" >/dev/null 2>&1 &
fi

CSV="$DATA/gpusample-$STAMP.csv"
bash "$HERE/gpusample.sh" "$CSV" >/dev/null 2>&1 &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT INT TERM

echo "profiler log : $GPUSTALL_LOG"
echo "sampler csv  : $CSV"
echo
cd "$(dirname "$GAME")"
"$WB/wine" "$GAME" >/dev/null 2>&1 &
GAMEPID=$!

for _ in $(seq 1 60); do
  [ -s "$GPUSTALL_LOG" ] && break
  sleep 2
done
if grep -q 'armed on' "$GPUSTALL_LOG" 2>/dev/null; then
  echo "PROFILER ARMED:"; grep 'armed on' "$GPUSTALL_LOG" | head -2
elif [ -s "$GPUSTALL_LOG" ]; then
  echo "dylib loaded but Metal not yet initialised:"; head -3 "$GPUSTALL_LOG"
else
  echo "WARNING: still no profiler log — injection did not reach the game." >&2
fi

wait $GAMEPID 2>/dev/null || true
while pgrep -f 'sekiro\.exe' >/dev/null 2>&1; do sleep 5; done
kill $SAMPLER 2>/dev/null || true
sleep 1
echo
bash "$HERE/gpustall-report.sh" "$STAMP"
