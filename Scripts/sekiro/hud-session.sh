#!/bin/bash
# ⚠️ THE HUD PART OF THIS DOES NOT WORK ON A STOCK BUILD. Kept because the A/B below is the point.
#
# DXMT computes commit_interval / sync_count / sync_interval / event_stall /
# present_latency_interval / drawable_blocking_interval every frame — but HUDState::begin(),
# printLine() and end() are ALL `#ifndef DXMT_DEBUG return;` (dxmt_hud_state.cpp). In a release
# build they are no-ops. Only initialize() runs, which is why the on-screen HUD shows just
# "DXMT D3D11 FL_11_0  v0.80" and no statistics lines.
#
# The format strings ARE present in the shipped d3d11.dll — dead data from std::format literals —
# so `strings | grep 'Sync:'` FALSELY suggests the feature works. It does not. Reading these
# counters needs DXMT rebuilt from source with DXMT_DEBUG defined.
#
# WHAT THIS SCRIPT IS ACTUALLY FOR: the ignoreMapFlagNoWait A/B, scored by perception.
#
# Lines to watch (docs/DXMT-SOURCE-DIG.md has the field mapping):
#   Commit: N -avg -max      the 32-chunk ring wait                (ELIMINATED already: outstanding=1)
#   Sync:   N avg S lat L    sync_count / sync_interval = the Map CPU-wait   <-- PRIMARY TARGET
#                            S = event_stall (query GetData flush), L = frame latency
#   Encode: p+f+d=t          d = drawable_blocking_interval
#   Render:/Clear:           pass counts
#
# WHY --map-wait MATTERS. `d3d11.ignoreMapFlagNoWait=True` makes DXMT strip DO_NOT_WAIT off every
# staging Map (d3d11_context_imm.cpp:238), turning a non-blocking map into
# `Flush(); WaitCPUFence(...)` on the GAME THREAD. That is a per-game workaround DXMT applies only
# to SONIC_X_SHADOW_GENERATIONS.exe — it is not a general setting, and it is enabled in Sekiro.app.
# Blocking there is counted in sync_count/sync_interval, which nothing in this project has ever
# read. Run BOTH arms and compare those two numbers.
#
# Usage:
#   bash hud-session.sh on     # ignoreMapFlagNoWait=True  (current shipped config)
#   bash hud-session.sh off    # ignoreMapFlagNoWait=False (maps stay non-blocking)
set -uo pipefail

ARM="${1:?usage: hud-session.sh on|off}"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/Library/Application Support/Decanter"
SHOTS="$D/hud-$ARM-$(date +%H%M%S)"
mkdir -p "$SHOTS"

case "$ARM" in
  on)  MAPWAIT=True ;;
  off) MAPWAIT=False ;;
  *) echo "arm must be on|off" >&2; exit 2 ;;
esac

export WINEPREFIX="$D/Bottles/Steam-Wine11"
pkill -9 -f 'sekiro\.exe' 2>/dev/null; pkill -9 -f 'wineserver' 2>/dev/null
pkill -9 -f 'steam\.exe' 2>/dev/null; pkill -f 'MacOS/gpukeepalive' 2>/dev/null
sleep 3

# These names must match the ones the bundle launcher's own export lines reference, because we
# eval those lines verbatim below rather than duplicating the tuned values.
CONTENTS="$HOME/Applications/Sekiro.app/Contents"
WINEROOT="$CONTENTS/Frameworks/Wine"
WB="$WINEROOT/bin"
PREFIX="$D/Bottles/Steam-Wine11"
CACHE="$D/ShaderCache/Sekiro"
mkdir -p "$CACHE"
GAME="$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro/sekiro.exe"

# take the tuned env from the real launcher, then override the two things this test controls
eval "$(grep -E '^export ' "$CONTENTS/MacOS/Sekiro")"
export MTL_HUD_ENABLED=1   # gives fps/GPU-ms/MetalFX info; DXMT stat lines will NOT appear
export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=60;d3d11.ignoreMapFlagNoWait=$MAPWAIT;d3d11.sampleNaNToZero=True;d3d11.defuseFma=True"
export SteamAppId=814380 SteamGameId=814380

echo "=============================================="
echo " HUD SESSION — ignoreMapFlagNoWait = $MAPWAIT"
echo " screenshots -> $SHOTS"
echo "=============================================="

if ! pgrep -f '/steam\.exe' >/dev/null 2>&1; then
  echo "starting Steam..."
  ( "$WB/wine" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" \
      -silent -no-cef-sandbox -skipinitialbootstrap >/dev/null 2>&1 ) &
  CONNLOG="$PREFIX/drive_c/Program Files (x86)/Steam/logs/connection_log.txt"
  BASE=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)
  for _ in $(seq 1 90); do
    [ "$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)" -gt "$BASE" ] && break
    sleep 2
  done
  sleep 15
fi

cd "$(dirname "$GAME")"
"$WB/wine" "$GAME" >/dev/null 2>&1 &

echo "waiting for the game..."
for _ in $(seq 1 90); do pgrep -f 'sekiro\.exe' >/dev/null 2>&1 && break; sleep 2; done
pgrep -f 'sekiro\.exe' >/dev/null 2>&1 || { echo "game did not start" >&2; exit 1; }
echo "game up. capturing the HUD every 2s."
echo
echo "PLAY NORMALLY. Say when you feel a pause — the capture nearest that time is the evidence."
echo

# NO SCREENSHOT LOOP. A fullscreen wine window is its own macOS Space, so `screencapture` grabs
# the desktop instead — 210 MB of useless desktop shots were produced this way on 2026-07-25
# before it was noticed. And with the HUD stat lines compiled out there would be nothing to read
# anyway. This arm is scored by the player's perception, which is the instrument that has actually
# held up in this investigation.
START=$(date +%s)
while pgrep -f 'sekiro\.exe' >/dev/null 2>&1; do sleep 10; done
MINS=$(( ($(date +%s) - START) / 60 ))

echo
echo "=============================================="
echo " ARM COMPLETE — ignoreMapFlagNoWait = $MAPWAIT"
echo " played $MINS min"
echo " record: how many LONG pauses (not the ~7s whole-Mac freezes)?"
echo "=============================================="
rmdir "$SHOTS" 2>/dev/null || true
