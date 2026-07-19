#!/bin/bash
# Sekiro launcher — runs the Wine tree EMBEDDED in this bundle so every process
# registers to macOS as "Sekiro" (games category).
CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
WINEROOT="$CONTENTS/Frameworks/Wine"
WB="$WINEROOT/bin"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
CACHE="$HOME/Library/Application Support/Decanter/ShaderCache/Sekiro"
mkdir -p "$CACHE"

# ALREADY RUNNING? Then this is a re-open (Dock click, double-launch), not a start. Without this
# guard we hand Steam a duplicate -applaunch and leave a short-lived `wine steam.exe` process
# behind — which looks like "it opened the Sekiro wine thing again but not the game". Just exit.
#
# Do NOT try to raise the window from here. `System Events ... first process whose unix id is N`
# BLOCKS INDEFINITELY on this Mac (measured: >2 min) because the parent process has no
# Accessibility permission, so the call waits rather than failing — it hung a launch during
# testing. The game is fullscreen in its own Space; Cmd-Tab and the Dock icon already raise it.
if pgrep -f 'sekiro\.exe' >/dev/null 2>&1; then
  # ...but do not leak the keep-alive. If the game is up without it (e.g. the reaper
  # raced, or the game was started outside this bundle), re-opening the app is the
  # natural moment to repair that. Verified 2026-07-19: a session ran 3 GPU hangs deep
  # with no keep-alive because this path exited without checking.
  KA="$CONTENTS/MacOS/gpukeepalive"
  if [ -x "$KA" ] && ! pgrep -f gpukeepalive >/dev/null 2>&1; then
    "$KA" 50000 >/dev/null 2>&1 &
  fi
  exit 0
fi

export WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEMSYNC=1 WINEESYNC=1 ROSETTA_ADVERTISE_AVX=1
export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
# ignoreMapFlagNoWait: TESTED AND REVERTED to True on 2026-07-19. Do not retry it for stalls.
# Hypothesis was that True made DXMT ignore MAP_FLAG_DO_NOT_WAIT and block until a resource
# freed, causing the long pauses. DISPROVED: with it False, an identical 24s stall recurred
# (11:12:18-11:12:43) — same `U` state, same ~2% cpu, same gpu_util pinned at 100%, same
# recoveryCount unchanged. An apparent 23s->6s improvement beforehand was small-sample noise.
#
# MEMORY PRESSURE WAS ALSO TESTED AND DISPROVED (2026-07-19). Freeing ~2 GB (quitting the
# Claude desktop app + Dropbox) made stalls WORSE, not better: 3 stalls in ~10 min at 88 MB
# free, versus 9 stalls in ~4 min at 4.1 GB free, with free memory flat at 53-58% throughout.
# Do not retry this either.
#
# Current cause class: a pathological shader. Across 12 captured stalls the signature is
# identical — state U, cpu ~2%, gpu_util pinned at EXACTLY 100%, recoveryCount unchanged,
# 2-25s. The GPU is executing, not hung (which is why the firmware watchdog never fires;
# it only trips when progress STOPS). DXMT's changelog documents this exact class, fixed
# case-by-case: Elite Dangerous (v0.70, "unoptimized compute shader with thousands of
# branches"), Shadow of the Tomb Raider, Genshin Impact. Already on 0.80, the latest.
export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=60;d3d11.ignoreMapFlagNoWait=True;d3d11.sampleNaNToZero=True;d3d11.defuseFma=True"
export DXMT_LOG_LEVEL=warn DXMT_LOG_PATH="$HOME/Library/Application Support/Decanter/dxmt-log"
export DXMT_SHADER_CACHE=1 DXMT_SHADER_CACHE_PATH="$CACHE"
export MTL_HUD_ENABLED="${SEKIRO_HUD:-1}"   # set SEKIRO_HUD=1 to show the fps overlay
export WINELOADER="$WB/wine" WINESERVER="$WB/wineserver" PATH="$WB:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$WINEROOT/lib:/usr/local/lib:/usr/lib"

# Fullscreen: sekiro.exe runs in a per-app Wine virtual desktop sized to the screen's point
# resolution (set once in the prefix registry — HKCU\Software\Wine\AppDefaults\sekiro.exe\Explorer
# Desktop=Default, HKCU\Software\Wine\Explorer\Desktops\Default=1470x956). That gives a borderless
# window filling the screen with the fast "Direct" presentation path — and Cmd+Tab still works
# (it's a window, not a display capture). Steam itself stays rootless/normal (per-app, not global).

# Remove the Steam menu-bar (systray) icon once the game window is up. Wine's explorer bridges
# Steam's tray icon to the macOS menu bar. The fullscreen window is created via the per-app desktop
# but is then owned by winemac.drv, so it SURVIVES explorer being killed (verified). We wait for the
# window to exist first (killing explorer too early would prevent the fullscreen window), then sweep
# a few times because Steam only adds its tray icon after its client finishes loading.
(
  until pgrep -f 'sekiro.exe' >/dev/null 2>&1; do sleep 2; done
  sleep 18
  for _ in 1 2 3 4 5 6; do pkill -f 'explorer.exe' 2>/dev/null; sleep 4; done
) >/dev/null 2>&1 &

# GPU KEEP-ALIVE. This Mac's GPU firmware intermittently fails to resume from its lowest power
# state: all 25 gpuEvent-*.ips reports show restart_reason "progress timeout" with
# fw_power_state=0, every 3d/ta/cl slot idle, and command_buffer_trace_id=-1 — i.e. NOTHING was
# executing. It is NOT a runaway shader (that would name a busy slot and a real command buffer),
# which is why no graphics setting, engine, DXMT build or shader-cache change ever moved the rate.
# Submitting a 256-byte blit every 50ms holds the GPU above that state. 3ms also worked but cost
# 20-30% of GPU headroom via per-submission context switches; 50ms is the tuned value.
# Guarded so a manually-started instance isn't duplicated; reaped when the game exits.
KA="$CONTENTS/MacOS/gpukeepalive"
if [ -x "$KA" ] && ! pgrep -f gpukeepalive >/dev/null 2>&1; then
  "$KA" 50000 >/dev/null 2>&1 &
  # NO REAPER HERE. The binary manages its own lifetime and logs to
  # ~/Library/Application Support/Decanter/gpukeepalive.log — check that file first if the
  # keep-alive is ever missing. Two reaper subshells written on 2026-07-19 both silently
  # killed it mid-launch and invalidated two validation sessions before anyone noticed.
fi

STEAM_EXE="$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe"
CONNLOG="$PREFIX/drive_c/Program Files (x86)/Steam/logs/connection_log.txt"

# TWO-PHASE LAUNCH. Sending -applaunch to a COLD Steam does not work: the client consumes the
# argument before it finishes logging in, so Steam opens and the game never starts
# (GAMING-STACK.md §4). Start the client first, wait for the logon to land in connection_log.txt,
# and only then send the applaunch to the now-running client.
BASE=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)

# WARM START. If a client is already up AND already logged in, phase 1 has nothing to do: no NEW
# 'Logged On,' line will ever appear, so the wait below burns its full ~150s before the game
# starts — which looks like "Steam/wine opened but the app never launched". Hand the applaunch
# straight to the running client instead.
if [ "$BASE" -gt 0 ] && pgrep -f '/steam\.exe' >/dev/null 2>&1; then
  exec "$WB/wine" "$STEAM_EXE" -applaunch 814380
fi

"$WB/wine" "$STEAM_EXE" -silent -no-cef-sandbox -skipinitialbootstrap >/dev/null 2>&1 &

for _ in $(seq 1 75); do                       # up to ~150s; a cold login is usually <30s
  NOW=$(grep -c 'Logged On,' "$CONNLOG" 2>/dev/null || echo 0)
  [ "$NOW" -gt "$BASE" ] && break
  sleep 2
done

# Hand the game to the running client. If the logon timed out we still try — a slow first
# attempt beats not launching at all.
exec "$WB/wine" "$STEAM_EXE" -applaunch 814380
