# Setting up Decanter — runbook for a helper (or Claude Code)

You're helping someone get **Decanter** (a Wine bottle manager for gaming on Apple Silicon) working.
This is the fast path. Follow it top to bottom; each step says how to verify it before moving on.

**Golden rules**
1. **Run `bash Scripts/doctor.sh` first.** It prints exactly what's present, what's missing, and the
   next action. Re-run it after each step. If you only have the app (no repo), the same script ships
   in the shared zip.
2. **Never delete a user's bottle prefix, `bottles.json`, or a game save** without backing it up
   first (`cp -Rc` is an instant APFS clone). Prefixes hold 10–100 GB of games and irreplaceable saves.
3. **Don't re-litigate the Wine choice.** Decanter uses **WhiskyWine 11** on purpose — it's the only
   free build that can log into modern Steam *and* ship DXMT. See `docs/GAMING-STACK.md §2` before
   even thinking about swapping it.

---

## The 4 things a working setup needs

| # | Thing | How the app gets it | Verify |
|---|---|---|---|
| 1 | **Rosetta 2** | `softwareupdate --install-rosetta --agree-to-license` (no admin needed on macOS 26) | `ls /Library/Apple/usr/libexec/oah/libRosettaRuntime` |
| 2 | **Wine engine** | Downloads WhiskyWine 11 (~317 MB) to `~/Library/Application Support/Decanter/Wine/` | `"~/Library/Application Support/Decanter/Wine/Libraries/Wine/bin/wine" --version` → `wine-11.0` |
| 3 | **A bottle** | `wineboot` a fresh prefix under `.../Decanter/Bottles/<name>` | `bottles.json` lists it, `isInitialized: true` |
| 4 | **Steam** | Silently installs `SteamSetup.exe` into the bottle | `steam.exe` exists in the bottle's `drive_c/Program Files (x86)/Steam/` |

The normal way to get all four is: **open Decanter → press "Set everything up for me."** The wizard does
1→2→3→4 with progress shown inline. Everything below is for when you're driving it yourself or something
went wrong.

---

## Path A — the user just has the app (shared zip)

1. **Unzip → drag `Decanter.app` to `/Applications`.**
2. **First open must be right-click ▸ Open** (it's ad-hoc signed, not notarized). If they double-clicked
   and got *"Decanter is damaged"*, clear quarantine:
   ```bash
   xattr -cr /Applications/Decanter.app
   ```
3. In the app, press **"Set everything up for me"** and wait (a few minutes; mostly the 317 MB engine).
4. Sign into Steam, install games, play.

## Path B — building from the repo (this folder)

```bash
swift build                       # Command Line Tools is enough; there is NO xcodeproj
./Scripts/make_app.sh             # -> build/Decanter.app
open build/Decanter.app           # then press the setup button
```

Headless equivalents (handy for driving from a terminal / verifying automation):
```bash
build/Decanter.app/Contents/MacOS/Decanter --install-engine   # just download+install the engine
build/Decanter.app/Contents/MacOS/Decanter --run-setup        # full Rosetta→engine→bottle→Steam
```
Both write into the user's real Decanter data. Watch progress on the filesystem (the app has no console
when run this way):
```bash
# engine arriving:
ls -la "$HOME/Library/Application Support/Decanter/Wine/Libraries/Wine/bin/wine"
# bottle + Steam arriving:
python3 -c 'import json;print(json.load(open("'"$HOME"'/Library/Application Support/Decanter/bottles.json")))'
```

---

## Troubleshooting (most-common first)

**"Decanter is damaged and can't be opened."**
Double-clicked an ad-hoc-signed app. `xattr -cr /Applications/Decanter.app`, then right-click ▸ Open.

**Engine download fails / stalls.**
Network. The installer cleans up a half-download so a retry is clean — just press the button again.
Verify connectivity to `github.com`. The file comes from
`https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz`.

**"The engine unpacked but wouldn't run."**
Rosetta isn't installed (the engine is x86-64). Run
`softwareupdate --install-rosetta --agree-to-license`, then retry setup.

**Steam window is black.**
Almost always the *wrong Wine build*, not a flag. Confirm the bottle uses the Decanter/WhiskyWine 11
engine (`bottles.json` → `wineBinDirectory` under `.../Decanter/Wine/...`). Quitting and reopening Steam
also clears a transient black CEF window. Do **not** add a prefix-wide DXVK/DXMT override to "fix" it —
that *causes* the black screen (see GAMING-STACK.md §6).

**Steam reopens on every click / two Dock icons / a Steam icon in the top menu bar.**
Already handled in code (idempotent launch, `-skipinitialbootstrap`, and killing Wine's `explorer.exe`
after launch). If you see it, the user is on an old build — rebuild and repackage.

**A game runs but is very slow.**
Expected for demanding 3D titles: a fresh bottle is Steam-ready but does **not** auto-install per-game
DXMT. To fix a specific game (this is exactly what was done for Sekiro):
1. Copy `~/Library/Application Support/Decanter/Wine/Libraries/DXMT/x64/{d3d11,dxgi,d3d10core}.dll`
   into the game's own folder (`steamapps/common/<game>/`).
2. Set per-exe overrides (leave the global ones empty):
   ```
   wine reg add 'HKCU\Software\Wine\AppDefaults\<game>.exe\DllOverrides' /v d3d11 /t REG_SZ /d native,builtin /f
   #  … repeat for dxgi and d3d10core
   ```
3. Lower the game's internal resolution and turn on MetalFX in Decanter's Configuration (MetalFX only
   helps if the game renders *below* the display — see GAMING-STACK.md §5).
Reference implementation: `Scripts/sekiro/sekiro-metalfx.sh`.

**A competitive game won't launch at all.**
Kernel anti-cheat (Valorant, most competitive shooters). No Mac tool can run these. Not fixable.

**Frame spikes even after DXMT.**
Known and structural: WhiskyWine 11 has no fast thread-sync (msync). The only build with both Steam
login *and* msync is CrossOver (paid). Full analysis in GAMING-STACK.md §2–3. Don't chase it with flags.

---

## Things NOT to do

- Don't swap the Wine engine to "something newer" hoping to fix spikes. The matrix is settled (§2).
- Don't set a **global** `WINEDLLOVERRIDES` / `HKCU\Software\Wine\DllOverrides` for d3d — it black-screens
  Steam. DXMT/DXVK must be per-executable.
- Don't trust `WINEMSYNC=1`. Verify: `strings <wine>/lib/wine/x86_64-unix/ntdll.so | grep -ic msync`
  (0 = the build ignores it). Decanter already strips it on unsupported builds.
- Don't delete `Steam-*` prefixes or `*.sl2` saves to "clean up." Back up first, always.

## When you're done, confirm

```bash
bash Scripts/doctor.sh   # should be all ✓ through Bottles & Steam
```
Then: open Decanter, launch Steam from the bottle (one click), the store renders, games install and run.
