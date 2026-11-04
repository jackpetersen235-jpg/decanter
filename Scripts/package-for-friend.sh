#!/bin/bash
# Build a clean, shareable Decanter.app + plain-language READ ME, zipped to the Desktop.
# The zip is tiny (~2 MB) because the Wine engine self-downloads on first run (~500 MB in two
# parts: the base bundle, then the upstream-wine-10-with-msync overlay that avoids frame spikes).
# This is also the GitHub release asset: written to ~/Desktop/Decanter-<version>.zip.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building the app…"
./Scripts/make_app.sh release >/dev/null

STAGE="$(mktemp -d)/Decanter"
mkdir -p "$STAGE"
cp -R build/Decanter.app "$STAGE/Decanter.app"

# Clear this Mac's own attributes so the zip carries none. It does NOT spare the recipient
# Gatekeeper: a browser re-quarantines everything in a downloaded zip (measured 2026-11-03,
# `spctl` → rejected), which is why the READ ME walks through Open Anyway.
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
2. **Install the app**: drag `Decanter.app` to `/Applications`. It's ad-hoc signed, not
   notarized, so a downloaded copy is quarantined and Gatekeeper refuses it ("could not verify").
   On macOS 15+ Control-click ▸ Open no longer gets past that: use System Settings ▸ Privacy &
   Security ▸ **Open Anyway**, or clear the quarantine:
   ```bash
   xattr -cr /Applications/Decanter.app
   ```
   The `.command` helpers in this folder are quarantined the same way.
3. **Press "Set everything up for me"** in the app. It installs, in order and on its own:
   Rosetta 2 → the Windows engine (~500 MB: base bundle + upstream wine 10 + msync overlay,
   which is what avoids the frame-spike stutter) → a game bottle → Steam.
   Progress shows inline. It self-skips anything already done, so it's safe to re-press.
4. Sign into Steam, install games, play.

## Verify (the 4 things a working setup needs)
```bash
ls /Library/Apple/usr/libexec/oah/libRosettaRuntime                                   # 1. Rosetta
"$HOME/Library/Application Support/Decanter/Wine/Libraries/Wine/bin/wine" --version    # 2. engine -> wine-10.0
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

# The updater. Replacing an app in place is a two-click job for someone who knows the trick and a
# delete-and-reinstall for everyone else — and reinstalling re-triggers the Gatekeeper dance every
# time. This does the swap, clears the download quarantine and re-signs, so the updated app opens
# normally afterwards. It never touches Application Support, where the bottles and saves live.
cp "$ROOT/Scripts/updater-template.command" "$STAGE/UPDATE Decanter.command"
chmod +x "$STAGE/UPDATE Decanter.command"

# Optional helper for OLD 32-bit games only. Not wired into the app: it needs an admin password
# and a third-party binary the user must fetch themselves, so it stays an explicit, opt-in step.
cp "$ROOT/Scripts/x87-launch.command" "$STAGE/OPTIONAL - speed up old games.command"
chmod +x "$STAGE/OPTIONAL - speed up old games.command"

# The "why is this game slow" profiler. Peggle was guessed at twice — first the graphics backend,
# then the Wine engine — and both guesses were wrong. This produces evidence instead.
cp "$ROOT/Scripts/profile-slow-game.command" "$STAGE/WHY IS MY GAME SLOW - run while playing.command"
chmod +x "$STAGE/WHY IS MY GAME SLOW - run while playing.command"

# Ship the debugging guide alongside the app. If the friend asks an AI for help, that assistant
# lands in a machine it has never seen; the guide is written for exactly that situation.
[ -f "$ROOT/docs/DEBUGGING-GUIDE.md" ] && \
  cp "$ROOT/docs/DEBUGGING-GUIDE.md" "$STAGE/DEBUGGING GUIDE (for an AI helper).md"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
DECANTER — play Windows games on your Mac
==========================================

Everything is built in. You do not need to download anything separately,
use the Terminal, or install Homebrew. Follow steps 1-4 in order.


STEP 1 — Put the app where it belongs
-------------------------------------
Open a new Finder window. In the sidebar on the left, click "Applications".
Drag the file called "Decanter" from THIS folder into that Applications window.


STEP 2 — Open it the first time (this part is fussy, once)
----------------------------------------------------------
In your Applications folder, double-click "Decanter".

macOS shows a warning that it could not verify Decanter.
Click "Done" (NOT "Move to Trash"). Then:

  1. Open System Settings (Apple menu > System Settings).
  2. Click "Privacy & Security" in the sidebar.
  3. Scroll down to "Security". It says Decanter was blocked.
     Click "Open Anyway", and confirm with your password or Touch ID.
  4. Decanter opens. If one more warning appears, click "Open Anyway".

  WHY: Decanter isn't from the App Store and isn't registered with Apple,
  so macOS makes you approve it once. After this it opens normally.

  ON macOS 14 (Sonoma) it's simpler: Control-click Decanter, choose "Open",
  then click "Open" in the warning.


STEP 3 — Press the one button
-----------------------------
A window appears with a button reading "Set everything up for me".
Click it, then leave it alone for about ten minutes.

It does all of this by itself, in order:
  • Apple's translation layer (Rosetta) — if your Mac doesn't have it yet,
    Decanter installs it. It's free and made by Apple.
  • The Windows engine — about 500 MB. This is the slow part.
  • A private folder for your games
  • Steam

You will see each line get a checkmark as it finishes.

  IF IT STOPS OR SHOWS AN ERROR: click the same button again. It skips
  whatever already finished, so pressing it twice is safe and is usually
  all that is needed.


STEP 4 — Start Steam and add a game
-----------------------------------
When every line has a checkmark, click "Start using Decanter", then click
"Launch Steam".

The FIRST time, Steam downloads itself (a few hundred MB) before any window
appears, so it can look stuck for several minutes. Leave it alone until the
Steam sign-in window shows up. Sign in and install a game like you would on
a PC.

To play it: click + at the top of Decanter's sidebar, pick the game from the
list, then press Play. Decanter sets up a game's graphics fixes each time it
starts Steam, so start your games from Decanter. A game started from Steam's
own window right after installing it can run slowly the first time.

That's it. You're done.


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
    — the "WHY IS MY GAME SLOW" tool in this folder can tell you why one is.

  • OLD 2D GAMES (Peggle, Bejeweled, Zuma, anything pre-2010) — if one feels
    slow, open Configuration and turn ON "Old 2D game - software rendering".
    Measured on Peggle Deluxe: 18 fps before, 90 fps after.

    Why: these games draw every single sprite as a separate instruction to the
    graphics card - thousands per frame. On Windows that is cheap. On a Mac,
    each one costs about 30 times more, because Apple's OpenGL is too old for
    the shortcut that would make it cheap. Drawing in software skips all of
    that. It sounds backwards and it is genuinely faster.

    Leave it OFF for 3D games - it would slow those down.

  • WANT A NORMAL WINDOW? Open a game's Configuration and set Window mode
    to "Real game window". The game then opens in an ordinary Mac window you
    can move and minimize, the green button makes it fullscreen, and macOS
    Game Mode switches on while it's fullscreen. New and experimental — if
    anything looks wrong, set it back to "Game's own setting".


IF SOMETHING GOES WRONG
-----------------------
  • "Decanter could not be verified" / "Decanter is damaged"
      -> Approve it as in step 2: System Settings > Privacy & Security >
         "Open Anyway".
      -> Or open Terminal and run:  xattr -cr /Applications/Decanter.app

  • The icon bounces in the Dock and then nothing happens
      -> RESTART YOUR MAC, then open it again. This is the usual fix.

      Why: the first time you open an app that didn't come from the App Store,
      macOS runs a one-time security check on it. That check occasionally gets
      stuck, and when it does the app bounces and quits with no message. A
      restart clears it. Nothing is wrong with the app or your Mac, and you
      won't have to do this again.

  • Setup fails partway
      -> Just press the button again. It skips whatever already finished.

  • Steam window is black
      -> Quit Steam and open it again from Decanter.

  • "Steam - Fatal Error: Failed to load steamui.dll"
      -> Make sure you have THIS version of Decanter (older ones caused it),
         then press "Launch Steam" and WAIT. Leave it alone.

      Why: installing Steam only puts a small 5 MB launcher on your Mac. The
      actual Steam program is a few hundred MB that Steam downloads by itself
      the very first time it opens. Until that finishes there is no window and
      no progress bar, so it looks frozen. Give it several minutes on a slow
      connection. Decanter's Steam panel will tell you when it's still setting
      itself up.

      If it still fails, open Terminal and paste this, then include what it
      prints when you report it (see GETTING HELP below):

        /Applications/Decanter.app/Contents/MacOS/Decanter --diagnose


THE EXTRA TOOLS IN THIS FOLDER
------------------------------
The files ending in ".command" (doctor, UPDATE Decanter, WHY IS MY GAME
SLOW, OPTIONAL - speed up old games) are small helpers you only need if
something goes wrong. macOS blocks each one the first time, just like
Decanter in step 2: double-click it, click "Done", then System Settings >
Privacy & Security > "Open Anyway".


UPDATING TO A NEW VERSION
-------------------------
Download the new zip, open it, and drag the new "Decanter" into your
Applications folder. Choose "Replace". Your games, saves and Steam login
are kept: they live elsewhere on your Mac, not inside the app.
Then approve the new version once, as in step 2.


GETTING HELP
------------
Report problems on Decanter's GitHub page:
  https://github.com/jackpetersen235-jpg/decanter/issues


KNOWN ISSUES (honest heads-up)

Tested on an M5 MacBook Air running macOS 26.5. Your Mac may differ.

  • FIXED — long freezes in-game (~26 seconds).
      Earlier versions of this package froze for about 26 seconds at a time,
      usually when loading an area or after dying. That is fixed in this
      version. The cause was a bug in the graphics translation layer: one of
      its internal shaders never advanced through its work list, so the GPU
      span in place until the driver gave up. This build carries the fix, and
      Decanter applies it to your games automatically.

      If you somehow still get a long freeze, that is worth reporting back —
      it would mean something different is going on.

  • Short freezes (~7 seconds) where the WHOLE Mac locks up.
      Not fixed and not fixable here. This is a fault in Apple's GPU
      firmware: the chip fails to wake from its deepest sleep state and gets
      reset. If it happens to you, open the game's Configuration and turn on
      "GPU keep-alive" (under Performance) — a small helper that keeps the GPU
      busy enough to avoid most of them. It's off by default because not every
      Mac has this fault. Nothing you did wrong, and reinstalling will not help.

  • Games with kernel anti-cheat (Valorant, most competitive shooters) do
      not work. No Mac tool can run them — this is not a Decanter limitation.

  • KEEP YOUR MAC PLUGGED IN while gaming. On battery, macOS throttles
      performance deliberately, and it makes a bigger difference than any
      setting in this app.

  • If a game feels slow, turn its in-game graphics settings DOWN first.
      Running everything on maximum is the most common cause of poor
      performance, and it is easy to mistake for something being broken.

Enjoy.
TXT

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Decanter.app/Contents/Info.plist)"
OUT="$HOME/Desktop/Decanter-$VERSION.zip"
rm -f "$OUT"
# ditto with no resource forks / no extended attrs => a clean zip with no "._" clutter.
( cd "$(dirname "$STAGE")" && ditto -c -k --sequesterRsrc --keepParent \
    "$(basename "$STAGE")" "$OUT" )

echo "▸ Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  Upload that one file as the release asset. People unzip, drag Decanter to Applications,"
echo "  approve it once (READ ME step 2), and press the button."
