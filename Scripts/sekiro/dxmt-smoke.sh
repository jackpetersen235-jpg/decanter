#!/bin/bash
# Does the currently-installed DXMT actually initialize? No playing required.
#
# The 2026-07-27 build's failure mode was specifically: sekiro.exe starts, sits at 0% CPU, and
# never loads d3d11. That is invisible from the build logs and cost two play sessions to notice,
# so it gets its own check that a person does not have to sit through.
#
# PASS  = DXMT logs its version banner AND the process is burning CPU (it got into the engine)
# FAIL  = process alive at ~0% CPU, or no DXMT log at all
#
# Steam must be running: Sekiro is Steamworks-DRM and exits immediately without it. That is why
# this cannot be reduced to "run the exe".
set -uo pipefail

D="$HOME/Library/Application Support/Decanter"
CONTENTS="$HOME/Applications/Sekiro.app/Contents"
WB="$CONTENTS/Frameworks/Wine/bin"
PREFIX="$D/Bottles/Steam-Wine11"
GAME="$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro/sekiro.exe"
LOG="$D/dxmt-smoke-$(date +%H%M%S)"
mkdir -p "$LOG"

export WINEPREFIX="$PREFIX"
# Reuse the real launcher's tuned environment rather than re-deriving it. Its export lines
# reference plain assignments made earlier in that file, so those must exist here too or `set -u`
# aborts on the first one.
WINEROOT="$CONTENTS/Frameworks/Wine"
CACHE="$D/ShaderCache/Sekiro"
mkdir -p "$CACHE"
eval "$(grep -E '^export ' "$CONTENTS/MacOS/Sekiro")"
export DXMT_LOG_PATH="$LOG" DXMT_LOG_LEVEL=info
# The launcher exports WINEDEBUG=-all, which hides exactly the dll-load diagnostics needed when
# DXMT does not come up. Must be re-exported AFTER the eval above or it gets overwritten.
export WINEDEBUG="${SMOKE_WINEDEBUG:--all}"
# Append extra DXMT config (e.g. the batch cap) to the launcher's tuned string rather than
# replacing it -- the other five options are what makes this a like-for-like comparison.
[ -n "${SMOKE_DXMT_EXTRA:-}" ] && export DXMT_CONFIG="$DXMT_CONFIG;$SMOKE_DXMT_EXTRA"

# Optional: inject the encoder-counting profiler, to check that a config change actually altered
# command-buffer shape rather than merely failing to crash.
if [ -n "${SMOKE_PROFILE:-}" ]; then
  export DYLD_INSERT_LIBRARIES="$(cd "$(dirname "$0")" && pwd)/libgpustall.dylib"
  export GPUSTALL_LOG="$LOG/gpustall.log" GPUSTALL_VERBOSE=1 GPUSTALL_SLOW_MS=250
fi
export SteamAppId=814380 SteamGameId=814380

cleanup() {
  pkill -9 -f 'sekiro\.exe' 2>/dev/null
  "$WB/wineserver" -k 2>/dev/null
}
trap cleanup EXIT

echo "==> clearing any stale prefix state"
cleanup; sleep 3

echo "==> starting Steam (needed for DRM)"
( "$WB/wine" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" \
    -silent -no-cef-sandbox -skipinitialbootstrap >/dev/null 2>&1 ) &
CONNLOG="$PREFIX/drive_c/Program Files (x86)/Steam/logs/connection_log.txt"
BASE=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)
for _ in $(seq 1 60); do
  [ "$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)" -gt "$BASE" ] && break
  sleep 2
done
sleep 12
pgrep -f '/steam\.exe' >/dev/null || { echo "FAIL: Steam never started"; exit 1; }
echo "    Steam up"

echo "==> launching sekiro.exe"
cd "$(dirname "$GAME")" || exit 1
"$WB/wine" "$GAME" >"$LOG/wine.txt" 2>&1 &

for _ in $(seq 1 45); do pgrep -f 'sekiro\.exe' >/dev/null && break; sleep 2; done
PID=$(pgrep -f 'sekiro\.exe' | head -1)
[ -n "$PID" ] || { echo "FAIL: sekiro.exe never appeared"; exit 1; }
echo "    pid $PID — sampling CPU for 60s"

PEAK=0
for _ in $(seq 1 12); do
  sleep 5
  pgrep -f 'sekiro\.exe' >/dev/null || break
  C=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' | cut -d. -f1)
  [ -n "$C" ] && [ "$C" -gt "$PEAK" ] 2>/dev/null && PEAK=$C
done

echo
echo "=============================================="
DLOG=$(ls "$LOG"/*.log 2>/dev/null | head -1)
if [ -n "$DLOG" ]; then
  echo "DXMT log: $(basename "$DLOG")"
  head -12 "$DLOG" | sed 's/^/  /'
else
  echo "NO DXMT LOG WRITTEN — d3d11 was never loaded"
fi
echo "----------------------------------------------"
echo "peak CPU: ${PEAK}%"
if [ -n "$DLOG" ] && [ "$PEAK" -gt 20 ] 2>/dev/null; then
  echo "RESULT: PASS — DXMT initialized and the game is doing work"
else
  echo "RESULT: FAIL — this is the 2026-07-27 signature (loads nothing / 0% CPU)"
fi
echo "=============================================="
