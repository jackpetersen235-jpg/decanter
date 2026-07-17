#!/bin/bash
MY="$HOME/Library/Application Support/Mythic/Engine/wine"
WB="$MY/bin"
PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Msync"
LOG="/private/tmp/claude-501/-Users-me-coding/7ca41e9c-8f88-4cdc-9bc5-e9e54fb1c4d4/scratchpad/msync-test.log"
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
export WINEMSYNC=1          # THIS one actually does something on Mythic's build
export ROSETTA_ADVERTISE_AVX=1
export MTL_HUD_ENABLED=1
export WINELOADER="$WB/wine64" WINESERVER="$WB/wineserver" PATH="$WB:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$MY/lib:/usr/local/lib:/usr/lib"
exec "$WB/wine64" "$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe" -silent -no-cef-sandbox -applaunch 814380 >> "$LOG" 2>&1
