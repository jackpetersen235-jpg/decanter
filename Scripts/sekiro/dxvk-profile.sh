#!/bin/bash
# Measure DXVK's command-buffer shape, to test whether "DXVK never stalls" is structural or just
# an artifact of it being too slow to build a big buffer.
#
# THE COMPARISON. DXMT on this exact setup builds command buffers up to ~233 encoders and stalls.
# DXVK on the SAME wine 10 + msync, same prefix, same Steam, same GPU, same game does not stall --
# but runs at ~13 fps, so "too slow to ever get there" is a live alternative explanation.
#
#   DXVK max encoders/cb stays low (~<=50)  -> structural. Real support for the batching lead.
#   DXVK ALSO builds 100+ encoder buffers   -> and still never stalls -> batching lead is in
#                                              serious trouble and should be dropped.
#
# Either result is informative, which is more than the cap experiment managed.
#
# HOW THE SWAP WORKS. The DllOverrides are "native,builtin" and this prefix has DXVK in system32.
# Moving only the GAME FOLDER's DXMT DLLs aside makes `native` resolve to system32's DXVK instead.
# system32 is deliberately left alone -- that is the whole mechanism.
#
# The profiler is layer-agnostic: it swizzles Metal's own command-buffer classes, and DXVK reaches
# Metal through MoltenVK, so encoders are counted the same way for both.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/Library/Application Support/Decanter"
GAME="$D/Bottles/Steam-Wine11/drive_c/Program Files (x86)/Steam/steamapps/common/Sekiro"
STAMP="dxvk-$(date +%Y%m%d-%H%M%S)"

pgrep -f 'sekiro\.exe' >/dev/null && { echo "sekiro is running - quit it first" >&2; exit 1; }

restore_dxmt() {
  for n in d3d11.dll dxgi.dll d3d10core.dll; do
    [ -f "$GAME/.dxmt-off/$n" ] && mv -f "$GAME/.dxmt-off/$n" "$GAME/$n"
  done
  rmdir "$GAME/.dxmt-off" 2>/dev/null
  echo "DXMT restored."
}
# Runs on normal exit, Ctrl-C, or kill. Leaving the game on DXVK by accident would be a nasty
# surprise the next time the user just wants to play.
trap restore_dxmt EXIT INT TERM

mkdir -p "$GAME/.dxmt-off"
for n in d3d11.dll dxgi.dll d3d10core.dll; do
  [ -f "$GAME/$n" ] && mv "$GAME/$n" "$GAME/.dxmt-off/$n"
done
echo "=============================================="
echo " DXVK profiling run"
echo "=============================================="
echo " Expect ~13 fps. It will feel bad; that is the point."
echo " Play about 7 minutes. Load an area or die once if you can -- those are the"
echo " moments DXMT builds its biggest buffers, so they are what needs comparing."
echo " Stalls are NOT expected here; if you get one, that is a major finding - say so."
echo "=============================================="
echo

bash "$HERE/gpuprof-direct.sh" --stamp "$STAMP"

echo
echo "=============================================="
LOG="$D/gpustall-$STAMP.log"
if [ -f "$LOG" ]; then
  awk '{for(i=1;i<=NF;i++) if($i~/^encoders=/){e=$i;sub(/encoders=/,"",e);e=e+0;
        c++; s+=e; if(e>mx)mx=e; if(e>=100)big++; if(e>=50)mid++}}
      END{printf " DXVK : buffers=%d avg=%.1f MAX=%d >=50enc=%d >=100enc=%d\n",c,(c?s/c:0),mx,mid+0,big+0}' "$LOG"
fi
for a in 1 2; do
  S=$(cat "$D/stall-experiment/arm$a.stamp" 2>/dev/null)
  AL="$D/gpustall-$S.log"
  [ -f "$AL" ] && awk -v a="$a" '{for(i=1;i<=NF;i++) if($i~/^encoders=/){e=$i;sub(/encoders=/,"",e);e=e+0;
        c++; s+=e; if(e>mx)mx=e; if(e>=100)big++; if(e>=50)mid++}}
      END{printf " DXMT%s: buffers=%d avg=%.1f MAX=%d >=50enc=%d >=100enc=%d\n",a,c,(c?s/c:0),mx,mid+0,big+0}' "$AL"
done
echo "=============================================="
