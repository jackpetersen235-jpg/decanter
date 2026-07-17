#!/bin/bash
# Sekiro, tuned entirely outside the game — in-game settings stay on MEDIUM.
#   MetalFX spatial upscaling: renders internally at a lower res, then upscales
#   in hardware on the M5's Metal 4 pipeline. Same settings, more frames.
#
# Usage: sekiro-metalfx.sh [factor]     factor 1.3 = mild ... 2.0 = max perf
FACTOR="${1:-1.5}"

# Prefer the wine EMBEDDED in Sekiro.app (self-contained); fall back to the shared install.
if [ -x "$HOME/Applications/Sekiro.app/Contents/Frameworks/Wine/bin/wine" ]; then
  WINEROOT="$HOME/Applications/Sekiro.app/Contents/Frameworks/Wine"
else
  WINEROOT="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
fi
WB="$WINEROOT/bin"
LIB="$(dirname "$WINEROOT")"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
CACHE="$HOME/Library/Application Support/Decanter/ShaderCache/Sekiro"
mkdir -p "$CACHE"

export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
export WINEMSYNC=1 WINEESYNC=1          # macOS-native thread sync (fastest path)
export ROSETTA_ADVERTISE_AVX=1          # let the x86-64 game use AVX under Rosetta

# --- the win: hardware upscaling, invisible to the game ---
export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
export DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=$FACTOR;d3d11.preferredMaxFrameRate=60"

# --- persistent shader cache: stutter keeps dropping the more you play ---
export DXMT_SHADER_CACHE=1
export DXMT_SHADER_CACHE_PATH="$CACHE"

# Metal HUD off by default (it costs a little). Pass HUD=1 to see fps.
export MTL_HUD_ENABLED="${HUD:-0}"

export WINELOADER="$WB/wine" WINESERVER="$WB/wineserver" PATH="$WB:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB/Wine/lib:/usr/local/lib:/usr/lib"

echo "▸ MetalFX upscale factor: $FACTOR   (HUD=${HUD:-0})"
exec "$WB/wine" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" \
     -no-cef-sandbox -applaunch 814380
