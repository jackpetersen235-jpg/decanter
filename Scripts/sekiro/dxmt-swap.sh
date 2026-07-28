#!/bin/bash
# Install / restore a locally-built DXMT, so a batching change can be A/B'd against stock.
#
# DXMT is FIVE files across TWO trees, and getting a partial set installed is the fastest way to
# waste a play session:
#
#   d3d11.dll, dxgi.dll, d3d10core.dll   -> the GAME folder (per-game override; a prefix-wide
#                                          override black-screens Steam's CEF, GAMING-STACK.md §6)
#   winemetal.dll                        -> engine  lib/wine/x86_64-windows/
#   winemetal.so                         -> engine  lib/wine/x86_64-unix/    <-- the unix side
#
# The .so is the one that is easy to forget and the one that silently decides whether the build
# works at all: a 2026-07-27 build produced a 27.7 MB .so against the official 31.8 MB and the game
# started but never loaded d3d11.
#
# Usage:
#   bash dxmt-swap.sh install <dxmt-install-prefix>   # e.g. ~/src/dxmt/install
#   bash dxmt-swap.sh restore                         # back to the shipped official 0.80
#   bash dxmt-swap.sh status
set -uo pipefail

D="$HOME/Library/Application Support/Decanter"
ENGINE="$D/Wine/Libraries/Wine/lib/wine"
OFFICIAL="$D/Wine/Libraries/DXMT/x64"
GAME="$D/Bottles/Steam-Wine11/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro"
STASH="$D/Backups/dxmt-official-0.80"

# One-time pristine copy, taken from the shipped tree BEFORE anything is overwritten. Without this
# there is no way back to a known-good DXMT except re-downloading the whole 317 MB engine.
if [ ! -d "$STASH" ]; then
  mkdir -p "$STASH"
  cp "$OFFICIAL"/*.dll "$STASH/" 2>/dev/null
  cp "$ENGINE/x86_64-unix/winemetal.so" "$STASH/" 2>/dev/null
  echo "stashed pristine official DXMT -> $STASH"
fi

fingerprint() {
  for f in "$GAME/d3d11.dll" "$ENGINE/x86_64-unix/winemetal.so"; do
    [ -f "$f" ] && printf '  %-14s %9d bytes  %s\n' "$(basename "$f")" "$(stat -f%z "$f")" \
      "$(shasum -a1 "$f" | cut -c1-12)"
  done
}

case "${1:-status}" in
  install)
    SRC="${2:?usage: dxmt-swap.sh install <dxmt-install-prefix>}"
    # meson install lays out bin/ and lib/; accept either that or a flat directory.
    find_one() { find "$SRC" -name "$1" -type f 2>/dev/null | head -1; }
    for n in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll winemetal.so; do
      [ -n "$(find_one $n)" ] || { echo "MISSING in $SRC: $n" >&2; exit 1; }
    done
    pgrep -f 'sekiro\.exe' >/dev/null && { echo "sekiro is running - quit it first" >&2; exit 1; }

    for n in d3d11.dll dxgi.dll d3d10core.dll; do cp "$(find_one $n)" "$GAME/$n"; done
    cp "$(find_one winemetal.dll)" "$ENGINE/x86_64-windows/winemetal.dll"
    cp "$(find_one winemetal.so)"  "$ENGINE/x86_64-unix/winemetal.so"
    echo "installed LOCAL build from $SRC"; fingerprint
    ;;
  restore)
    pgrep -f 'sekiro\.exe' >/dev/null && { echo "sekiro is running - quit it first" >&2; exit 1; }
    for n in d3d11.dll dxgi.dll d3d10core.dll; do cp "$STASH/$n" "$GAME/$n"; done
    cp "$STASH/winemetal.dll" "$ENGINE/x86_64-windows/winemetal.dll"
    cp "$STASH/winemetal.so"  "$ENGINE/x86_64-unix/winemetal.so"
    echo "restored official 0.80"; fingerprint
    ;;
  status)
    echo "official reference: winemetal.so should be 31805040 bytes"
    fingerprint
    ;;
  *) echo "usage: dxmt-swap.sh install <prefix> | restore | status" >&2; exit 2 ;;
esac
