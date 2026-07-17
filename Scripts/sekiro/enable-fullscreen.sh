#!/bin/bash
# Make Sekiro run true borderless fullscreen (fills the screen, Direct rendering, ~60fps,
# and Cmd+Tab STILL works — it's a window, not a display capture).
#
# Mechanism: a PER-APP Wine virtual desktop for sekiro.exe only, sized to the screen's *point*
# resolution. Per-app (not global) so Steam and everything else stay rootless/normal.
#
# Run once. The setting lives in the prefix registry and persists. Sekiro.app's launcher then
# removes the Steam menu-bar icon after the game window is up (see the launcher).
set -euo pipefail

PREFIX="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
WB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"
export WINEPREFIX="$PREFIX" WINEDEBUG=-all

# Screen point ("looks like") resolution — a full-screen borderless window must match this.
read -r PW PH < <(swift - <<'SWIFT'
import CoreGraphics
let m = CGDisplayCopyDisplayMode(CGMainDisplayID())!
print(m.width, m.height)
SWIFT
)
echo "▸ screen point resolution: ${PW}x${PH}"

"$WB/wine" reg delete 'HKCU\Software\Wine\Explorer' /v Desktop /f >/dev/null 2>&1 || true   # ensure NOT global
"$WB/wine" reg add   'HKCU\Software\Wine\AppDefaults\sekiro.exe\Explorer' /v Desktop /t REG_SZ /d Default /f >/dev/null 2>&1
"$WB/wine" reg add   'HKCU\Software\Wine\Explorer\Desktops' /v Default /t REG_SZ /d "${PW}x${PH}" /f >/dev/null 2>&1
"$WB/wineserver" -k 2>/dev/null || true

# Sekiro's own config: fullscreen at the same size, auto-detect OFF so it isn't reset.
CFG="$PREFIX/drive_c/users/$USER/AppData/Roaming/Sekiro/GraphicsConfig.xml"
if [ -f "$CFG" ]; then
python3 - "$CFG" "$PW" "$PH" <<'PY'
import re,sys
p,pw,ph=sys.argv[1],sys.argv[2],sys.argv[3]
t=open(p,'rb').read().decode('utf-16-le')
for tag,val in {'ScreenMode':'FULLSCREEN','Auto-detectBestRenderingSettings':'OFF',
                'Resolution-FullScreenWidth':pw,'Resolution-FullScreenHeight':ph}.items():
    t,_=re.subn(rf'<{tag}>[^<]*</{tag}>',f'<{tag}>{val}</{tag}>',t)
open(p,'wb').write(t.encode('utf-16-le'))
PY
fi
echo "▸ Done. Launch Sekiro.app — it fills the screen and Cmd+Tab still works."
