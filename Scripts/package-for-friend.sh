#!/bin/bash
# Build a clean, shareable Decanter.app + plain-language READ ME, zipped to the Desktop.
# The zip is tiny (~2 MB) because the 317 MB Wine engine self-downloads on first run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building the app…"
./Scripts/make_app.sh release >/dev/null

STAGE="$(mktemp -d)/Decanter-for-friend"
mkdir -p "$STAGE"
cp -R build/Decanter.app "$STAGE/Decanter.app"

# Strip quarantine so their Gatekeeper prompt is the milder "unidentified developer"
# (right-click ▸ Open) rather than "damaged and can't be opened".
xattr -cr "$STAGE/Decanter.app" 2>/dev/null || true
# Re-apply the ad-hoc signature after stripping xattrs.
codesign --force --sign - "$STAGE/Decanter.app" >/dev/null 2>&1 || true

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
DECANTER — play Windows games on your Mac
==========================================

WHAT TO DO (3 steps, ~10 minutes)
---------------------------------

1. Drag "Decanter" into your Applications folder.

2. RIGHT-CLICK Decanter and choose "Open".
   (Do NOT double-click the first time.)
   A warning appears saying the app is from an unidentified developer.
   Click "Open".

   Why: this app wasn't bought from Apple's App Store, so macOS asks once.
   You only have to do this the very first time.

3. Click the big button: "Set everything up for me".

   Decanter downloads and configures everything itself:
     • Apple's translation layer  (macOS may ask for your password — that's normal)
     • The Windows engine         (about 317 MB — takes a minute)
     • A private space for games
     • Steam

   Then sign in to Steam and install your games. That's it.


WHAT YOU NEED
-------------
  • A Mac with Apple silicon (M1/M2/M3/M4/M5) — yours qualifies
  • macOS 14 or newer
  • About 2 GB free, plus space for whatever games you install
  • An internet connection

You do NOT need to buy anything, install Homebrew, or use the Terminal.


GOOD TO KNOW
------------
  • Not every Windows game works. Single-player games generally do.
    Games with kernel anti-cheat (Valorant, most competitive shooters) do not,
    and no Mac tool can fix that.

  • Games run through two translation layers, so expect fewer frames than the
    same game on a real gaming PC. Some games run great; some stutter.

  • KEEP YOUR MAC PLUGGED IN while gaming. On battery, macOS deliberately
    throttles performance — this makes a bigger difference than any setting.

  • Performance varies a lot by game. "DXMT (DirectX -> Metal)" is the default
    and fastest graphics mode, and MetalFX upscaling (in Configuration) can add
    frames. Some demanding 3D games need extra per-game setup to run their best
    — ask whoever sent you this if a specific game feels slow.


IF SOMETHING GOES WRONG
-----------------------
  • "Decanter is damaged / can't be opened"
      -> You double-clicked instead of right-click -> Open. See step 2.
      -> Or open Terminal and run:  xattr -cr /Applications/Decanter.app

  • Setup fails partway
      -> Just press the button again. It skips whatever already finished.

  • Steam window is black
      -> Quit Steam and open it again from Decanter.

Enjoy.
TXT

OUT="$HOME/Desktop/Decanter-for-friend.zip"
rm -f "$OUT"
# ditto with no resource forks / no extended attrs => a clean zip with no "._" clutter.
( cd "$(dirname "$STAGE")" && ditto -c -k --sequesterRsrc --keepParent \
    "$(basename "$STAGE")" "$OUT" )

echo "▸ Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  Send that one file. They unzip, right-click ▸ Open, press the button."
