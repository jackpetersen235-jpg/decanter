#!/bin/bash
# Build a clean, shareable Decanter.app + plain-language READ ME, zipped to the Desktop.
# The zip is tiny (~2 MB) because the Wine engine self-downloads on first run (~480 MB in two
# parts: the base bundle, then the upstream-wine-10-with-msync overlay that avoids frame spikes).
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

# Self-contained diagnostic (works with no repo) + a note for a helper / Claude Code.
cp "$ROOT/Scripts/doctor.sh" "$STAGE/doctor.command"     # .command so it's double-clickable too
chmod +x "$STAGE/doctor.command"

cat > "$STAGE/FOR-CLAUDE-CODE.md" <<'MD'
# Helping set up Decanter (read this first if you're Claude Code or a technical helper)

Decanter runs Windows Steam games on Apple silicon Macs via Wine. The person you're helping just
has the app — no repo. Getting them going is short:

## Do this
1. **Run the diagnostic** — it prints exactly what's present/missing and the next step:
   ```bash
   bash "$(dirname "$0")/doctor.command"      # or just: bash doctor.command  (in this folder)
   ```
2. **Install the app**: drag `Decanter.app` to `/Applications`. If double-clicking gives
   *"Decanter is damaged"*, it's just the unsigned-app gate — clear it:
   ```bash
   xattr -cr /Applications/Decanter.app
   ```
   then right-click ▸ Open.
3. **Press "Set everything up for me"** in the app. It installs, in order and on its own:
   Rosetta 2 → the Windows engine (~480 MB: base bundle + upstream wine 10 + msync overlay,
   which is what avoids the frame-spike stutter) → a game bottle → Steam.
   Progress shows inline. It self-skips anything already done, so it's safe to re-press.
4. Sign into Steam, install games, play.

## Verify (the 4 things a working setup needs)
```bash
ls /Library/Apple/usr/libexec/oah/libRosettaRuntime                                   # 1. Rosetta
"$HOME/Library/Application Support/Decanter/Wine/Libraries/Wine/bin/wine" --version    # 2. engine -> wine-11.0
cat "$HOME/Library/Application Support/Decanter/bottles.json"                          # 3. a bottle, isInitialized:true
# 4. Steam = steam.exe inside that bottle's drive_c/Program Files (x86)/Steam/
```

## Honest expectations (tell them up front)
- Single-player games generally work. **Kernel anti-cheat games (Valorant, most competitive
  shooters) do NOT** — no Mac tool can run them.
- Keep the Mac **plugged in** while gaming; on battery macOS throttles hard.
- Some demanding 3D games need per-game graphics setup to run their best; a fresh bottle is
  Steam-ready but games default to a slower renderer until tuned.

## Don't
- Don't delete a bottle or a save file to "clean up" — back up first (`cp -Rc` is instant).
- Don't swap the Wine engine or add a global d3d DLL override (it black-screens Steam).
MD

# Keep the diagnostic runnable when double-clicked from Finder as well as `bash doctor.command`.

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
     • The Windows engine         (about 480 MB — takes a few minutes)
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


KNOWN ISSUES (honest heads-up)

These were seen on the Mac this was built and tested on — an M5 MacBook Air running
macOS 26.5. Your Mac may be completely unaffected. Both are BELOW Decanter: they are
in Apple's GPU driver / firmware, not in this app or in Wine, so there is nothing in
Decanter to switch off to avoid them.

  • Long freezes in-game (~26 seconds), game only, Mac stays usable.
      Traced to the GPU command-submission system call blocking inside Apple's driver.
      Cause NOT identified, despite a lot of investigation. Not reliably fixable today.
      It did not stop the game being played and finished — it is an interruption, not
      a crash. Nothing is lost; the game resumes on its own.

  • Short freezes (~7 seconds) where the WHOLE Mac locks up.
      A GPU firmware fault: the chip fails to wake from its deepest sleep state and
      gets reset. Also Apple-side.

If you hit either, it is not something you did wrong and not worth reinstalling over.
If you DON'T hit them, great — that is useful information in itself, and worth telling
whoever gave you this.

Everything else in this README is unaffected: setup, Steam, and installing games all
work normally.

Enjoy.
TXT

OUT="$HOME/Desktop/Decanter-for-friend.zip"
rm -f "$OUT"
# ditto with no resource forks / no extended attrs => a clean zip with no "._" clutter.
( cd "$(dirname "$STAGE")" && ditto -c -k --sequesterRsrc --keepParent \
    "$(basename "$STAGE")" "$OUT" )

echo "▸ Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  Send that one file. They unzip, right-click ▸ Open, press the button."
