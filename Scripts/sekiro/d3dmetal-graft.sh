#!/bin/bash
# Swap the D3D11->Metal translation layer, holding EVERYTHING else fixed.
#
# THE QUESTION. Sekiro on CrossOver (D3DMetal) had no long stalls but a less steady framerate; on
# this engine (DXMT) it holds 60 fps and stalls. CrossOver differs in two ways at once -- the
# translation layer AND wine itself -- so it cannot say which one matters. Grafting Apple's
# D3DMetal into THIS engine changes only the translation layer: same wine 10 + msync, same prefix,
# same Steam, same game, same GPU. If the stalls follow DXMT, that is the cleanest evidence
# available that they are DXMT's and not the platform's.
#
# WHY IT MAY SIMPLY NOT WORK. D3DMetal's unix libs come from Mythic's Game Porting Toolkit engine,
# which is wine 7.7; this engine is wine 10. A wine unixlib is compiled against wine's internal
# ABI, and three major versions is a much wider gap than the winemetal.so graft already documented
# as an "unsupported ABI mix" (that one is 11-into-10). D3DMetal may also depend on Apple's
# wine patches that upstream wine does not have. A clean failure here is a real answer, cheaply:
# dxmt-smoke.sh settles it in five minutes instead of a play session.
#
# LICENSING: D3DMetal ships under Apple's Game Porting Toolkit terms, for evaluation/development.
# This is a local diagnostic experiment on a machine that already has it installed via Mythic --
# nothing is redistributed.
#
# Usage:
#   bash d3dmetal-graft.sh install
#   bash d3dmetal-graft.sh restore
set -uo pipefail

D="$HOME/Library/Application Support/Decanter"
M="$HOME/Library/Application Support/Mythic/Engine/wine"
W="$D/Wine/Libraries/Wine"
E="$W/lib/wine"
GAME="$D/Bottles/Steam-Wine11/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro"
SYS32="$D/Bottles/Steam-Wine11/drive_c/windows/system32"
BK="$D/Backups/pre-d3dmetal"

[ -d "$M" ] || { echo "Mythic's GPTk engine is not installed - nothing to graft from." >&2; exit 1; }
pgrep -f 'sekiro\.exe' >/dev/null && { echo "sekiro is running - quit it first" >&2; exit 1; }

case "${1:?usage: d3dmetal-graft.sh install|restore}" in
  install)
    # Back up every file this will overwrite, once, BEFORE the first write.
    if [ ! -d "$BK" ]; then
      mkdir -p "$BK/x86_64-windows"
      cp "$E/x86_64-windows/d3d11.dll" "$BK/x86_64-windows/" 2>/dev/null
      cp "$E/x86_64-windows/dxgi.dll"  "$BK/x86_64-windows/" 2>/dev/null
      echo "backed up wine's own builtins -> $BK"
    fi

    # 1. unix side. libd3dshared.dylib sits beside them because d3d11.so asks for it via
    #    @rpath with an rpath of @loader_path; Mythic keeps it in lib/external and relies on
    #    fallback paths, which this engine's launcher does not replicate.
    cp "$M"/lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so "$E/x86_64-unix/" 2>/dev/null
    cp "$M/lib/external/libd3dshared.dylib" "$E/x86_64-unix/"

    # 2. PE side (wine builtins)
    cp "$M"/lib/wine/x86_64-windows/{d3d11,dxgi}.dll "$E/x86_64-windows/"

    # 3. framework + a copy on the launcher's DYLD_FALLBACK_LIBRARY_PATH ($WINEROOT/lib)
    cp -R "$M/lib/external/D3DMetal.framework" "$W/lib/" 2>/dev/null
    cp "$M/lib/external/libd3dshared.dylib" "$W/lib/"

    # 4. Take DXMT out of the way. The override is "native,builtin", so with no native DLL present
    #    wine falls through to the builtin -- which is now D3DMetal. No registry edit needed.
    mkdir -p "$GAME/.dxmt-disabled"
    for n in d3d11.dll dxgi.dll d3d10core.dll; do
      [ -f "$GAME/$n" ] && mv "$GAME/$n" "$GAME/.dxmt-disabled/$n"
    done
    # AND system32, or the graft is silently bypassed. "native,builtin" resolves native FIRST, and
    # this prefix has DXVK installed into system32 -- so emptying only the game folder hands the
    # game to DXVK rather than falling through to the builtin. Measured: a run intended to test
    # D3DMetal actually ran DXVK at ~13 fps, and looked superficially like a working graft.
    mkdir -p "$SYS32/.dxvk-disabled"
    for n in d3d11.dll dxgi.dll d3d10core.dll; do
      [ -f "$SYS32/$n" ] && mv "$SYS32/$n" "$SYS32/.dxvk-disabled/$n"
    done
    echo "D3DMetal grafted; DXMT moved to $GAME/.dxmt-disabled"
    ;;

  restore)
    for n in d3d10 d3d11 d3d12 dxgi; do rm -f "$E/x86_64-unix/$n.so"; done
    rm -f "$E/x86_64-unix/libd3dshared.dylib" "$W/lib/libd3dshared.dylib"
    rm -rf "$W/lib/D3DMetal.framework"
    [ -d "$BK/x86_64-windows" ] && cp "$BK/x86_64-windows/"*.dll "$E/x86_64-windows/"
    for n in d3d11.dll dxgi.dll d3d10core.dll; do
      [ -f "$GAME/.dxmt-disabled/$n" ] && mv "$GAME/.dxmt-disabled/$n" "$GAME/$n"
      [ -f "$SYS32/.dxvk-disabled/$n" ] && mv "$SYS32/.dxvk-disabled/$n" "$SYS32/$n"
    done
    rmdir "$GAME/.dxmt-disabled" "$SYS32/.dxvk-disabled" 2>/dev/null
    echo "restored: DXMT back in place, wine builtins restored, D3DMetal removed"
    ;;
  *) echo "usage: d3dmetal-graft.sh install|restore" >&2; exit 2 ;;
esac
