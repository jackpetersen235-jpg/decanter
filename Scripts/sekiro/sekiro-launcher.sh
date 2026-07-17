#!/bin/bash
# Sekiro launcher — runs the Wine tree EMBEDDED in this bundle so every process
# registers to macOS as "Sekiro" (games category) → Game Mode can engage in fullscreen.
CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
WINEROOT="$CONTENTS/Frameworks/Wine"
WB="$WINEROOT/bin"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
CACHE="$HOME/Library/Application Support/Decanter/ShaderCache/Sekiro"
mkdir -p "$CACHE"

export WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEMSYNC=1 WINEESYNC=1 ROSETTA_ADVERTISE_AVX=1
export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2.0;d3d11.preferredMaxFrameRate=60;d3d11.ignoreMapFlagNoWait=True"
export DXMT_SHADER_CACHE=1 DXMT_SHADER_CACHE_PATH="$CACHE"
export DXMT_LOG_LEVEL=info DXMT_LOG_PATH="/private/tmp/claude-501/-Users-me-coding/7ca41e9c-8f88-4cdc-9bc5-e9e54fb1c4d4/scratchpad/dxmt-live"
export MTL_HUD_ENABLED=1   # on while we verify Game Mode; will default off after
export WINELOADER="$WB/wine" WINESERVER="$WB/wineserver" PATH="$WB:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$WINEROOT/lib:/usr/local/lib:/usr/lib"

exec "$WB/wine" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" -silent -no-cef-sandbox -applaunch 814380
