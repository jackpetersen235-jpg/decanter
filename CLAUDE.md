# Decanter — context for future sessions

**Read this first.** Decanter is a SwiftUI macOS app that manages Wine "bottles" for gaming
(the Whisky/CrossOver idea, rebuilt). It was built alongside a real goal: getting
**Sekiro: Shadows Die Twice** running on an **M5 MacBook Air (macOS Tahoe 26.5.2)**.

Two separate things live here, and they are **not currently in sync**:
1. **The Decanter app** (this repo) — the bottle-manager GUI.
2. **A working Sekiro setup** (outside this repo) — `~/Applications/Sekiro.app`, hand-tuned.
   This is what actually runs the game. Decanter's bottle metadata is **stale** relative to it.

> Deep technical findings: [`docs/GAMING-STACK.md`](docs/GAMING-STACK.md) ← **read before touching
> anything Wine-related; it documents dead ends that cost hours.**
> Every file/download/path: [`docs/INVENTORY.md`](docs/INVENTORY.md)

---

## Build & run

```bash
swift build                  # Command Line Tools only — there is NO full Xcode on this machine
./Scripts/make_app.sh        # -> build/Decanter.app (also copies Assets/AppIcon.icns + wallpaper.png)
open build/Decanter.app
```

- Pure SwiftPM. **No `.xcodeproj`** — `xcodebuild` is unavailable (CLT-only install).
- `Package.swift` targets macOS 14; toolchain is Swift 6.3.3, `swift-tools-version:5.9`
  (deliberate: keeps Swift 5 language mode and avoids strict-concurrency errors).
- `@main struct DecanterApp` — do **not** add a `main.swift`, it conflicts.

## Layout

```
Sources/Decanter/
  Support/   Shell (Process runner), Paths, SystemChecks, Panels
  Models/    Bottle, BottleSettings (WindowsVersion / SyncMode / GraphicsBackend)
  Wine/      WineInstallation (discovery), Wine (env + registry + tools)
  Managers/  AppModel (all state + actions), WineInstaller, Steam, TaskConsole
  Views/     ContentView, SetupWizard, SetupView, BottleDetailView, ConfigurationView, …
Scripts/
  make_app.sh            bundles the binary into build/Decanter.app
  doctor.sh              health check — run FIRST when setting up / troubleshooting
  package-for-friend.sh  builds the shareable zip (app + READ ME + doctor + helper note)
  sekiro/                rescued launch scripts for the real Sekiro setup
Assets/                  AppIcon.icns (wizard), wallpaper.png, wizard sources
docs/                    SETUP-WITH-CLAUDE.md (helper runbook), GAMING-STACK.md, INVENTORY.md
```

**Helping someone (or an agent) set this up?** Start at [`docs/SETUP-WITH-CLAUDE.md`](docs/SETUP-WITH-CLAUDE.md)
and run `bash Scripts/doctor.sh`.

Data at runtime: `~/Library/Application Support/Decanter/`
(`bottles.json`, `Bottles/`, `ShaderCache/`, `Backups/`)

---

## Current state (2026-07-18)

- **First run is fully automated.** `SetupWizard` + `WineInstaller` download and configure
  everything (Rosetta → engine → bottle → Steam) with one button. No terminal, no Wine knowledge.
  Re-openable any time via **View → Setup Assistant…**.
- **Decanter owns its engine**: `~/Library/Application Support/Decanter/Wine/` — a base bundle
  (DXMT/DXVK + 94 support dylibs) with **upstream wine 10 + msync** overlaid on top, installed by
  the wizard. No dependency on Whisky/Mythic/CrossOver being present.
  `Paths.wineEngine*` — first in discovery order, so it's the default.
- Bottles are synced to reality: **wine 10 + msync + DXMT + MetalFX 2x**, prefix `Steam-Wine11`,
  `syncMode: msync`.
- Shareable build: `~/Desktop/Decanter-for-friend.zip` (2.1 MB — the engine self-downloads).

### Recently FIXED
- **Frame spikes — SOLVED for free (2026-07-18).** Every earlier claim that this needed CrossOver
  was wrong. Cause of the free-path failure was **CrossOver's own patches** (they break Steam's
  internal loopback UI websocket), not the wine version or msync. The engine now shipped is
  **upstream wine 10.0 with msync** (`WS11Wine10.0_3`, free) overlaid on the base bundle.
  Measured under real gameplay: `wineserver` **39.9% → ~7.9% avg** (median 6.3%, only 2.8% of
  samples >20%). See GAMING-STACK.md §2/§2b and docs/OVERNIGHT-FINDINGS.md.
  ⚠️ The DXMT `winemetal.so` graft is a wine-11 unixlib inside a wine-10 engine — unsupported ABI
  mix; suspect it first if graphics get unstable. Fallback: `Backups/wine11-20260718-121514/`.

### Still open
- `Steam-Mythic` prefix + the CrossOver bottle (~3.2 GB total) are leftovers, safe to delete.

## First-run automation (SetupWizard) — how it works

A newcomer with **no Wine and no Rosetta** can press one button and end up at Steam. The wizard
(`Views/SetupWizard.swift`) shows 4 self-checking steps and calls one model routine:

- `AppModel.runGuidedSetup()` — the whole flow, factored OUT of the view so it survives view
  lifecycle and is testable headlessly. Steps: `ensureRosetta()` → `installEngine()` (downloads
  the base bundle ~317 MB **then overlays upstream wine 10 + msync** ~160 MB, via `WineInstaller`,
  into `~/Library/Application Support/Decanter/Wine/`)
  → `createBottleForSetup()` (quiet, no console) → `performSteamInstall(console:nil)`.
- Headless test hooks: `Decanter --install-engine` and `Decanter --run-setup`. Both verified
  end-to-end on 2026-07-17 (engine downloads at ~2 MB/s; bottle + Steam auto-created).
- The app owns its own engine (`Paths.wineEngine*`, discovered first in `Wine.swift`), so it does
  **not** depend on Whisky/Mythic/CrossOver being installed. That's what makes the friend build work.

**Known limitation (documented, not a bug):** the wizard gets a bottle to *Steam-ready*, but does
**not** auto-install per-game DXMT DLLs (copy `Libraries/DXMT/x64/*.dll` into the game folder +
`AppDefaults\<game>.exe\DllOverrides`). Without that a demanding game falls back to slow WineD3D.
Global DXMT overrides can't be used (they black-screen Steam's CEF — see GAMING-STACK.md §6).
Per-game auto-DXMT is the obvious next feature.

## Online play: the engine toggle

**Configuration → Engine → Play mode** switches a bottle between two independent engines:

- **Offline** — `Wine/`, the tuned single-player engine (DXMT fixes, msync, MetalFX)
- **Online** — `WineOnline/`, a separate copy so online experimentation cannot touch the above

Same bottle either way: same prefix, saves, Steam login and games. Only the engine differs.
Created with `cp -Rc` (APFS clone) — measured 1.0 s and 2 MB consumed for a 719 MB tree, so
isolation is effectively free. **Reset Online Engine** re-clones it from the offline one in about
a second, which is the point: break it freely, restore instantly, never re-download 480 MB.

Switching is refused while Steam or a game is running (Wine holds the engine tree open).
Headless: `--engine offline|online`, `--reset-online`.

**⚠️ Anti-cheat is the limit, and no engine work changes it.** Per
[Epic's own announcement](https://onlineservices.epicgames.com/news/epic-online-services-launches-anti-cheat-support-for-linux-mac-and-steam-deck),
EOS anti-cheat supports compatibility layers on **Linux only**; macOS support exists solely for
**native Mac builds**. A Windows game under Wine on macOS has no anti-cheat path at all. Confirmed
against JJBA All-Star Battle R: it reaches its online service over HTTPS, never opens a single UDP
socket, and reports "transmission error" — rejected before a peer session exists. Games without
kernel anti-cheat (VAC-only, or none) are unaffected and work normally.

## Sharing with someone else

`Scripts/package-for-friend.sh` → `~/Desktop/Decanter-for-friend.zip` (~2 MB; engine self-downloads).
Strips quarantine + AppleDouble clutter, re-signs ad-hoc, writes a plain-language READ ME.

## Gotchas that already bit us (don't rediscover these)

- **`sips` writes JPEG data into `.png` filenames** unless you pass `-s format png`.
  `iconutil` then fails with a useless "Failed to generate ICNS". This silently broke the icon twice.
- **Whisky.app is sandboxed** → its Wine lives under
  `~/Library/Containers/com.isaacmarovitz.Whisky/Data/Library/Application Support/...`.
  The non-sandboxed path is still used by the manually-installed WhiskyWine (see INVENTORY).
- **CrossOver's wine ignores `WINEPREFIX`** — it finds bottles by name via `CX_BOTTLE`
  (+ `CX_ROOT`). `Wine.swift` handles this via `WineInstallation.isCrossOver`.
- **`open(1)` does not forward environment variables** to the launched app. To pass env to a
  bundle, bake it into the launcher script inside `Contents/MacOS/`.
- **Deep-signing a bundle containing a Wine tree fails** ("code object is not signed at all").
  An *invalid* signature is worse than none — `codesign --remove-signature` is fine for local apps.
- **`grep -rl` silently fails on these Mach-O trees.** Use `strings <file> | grep`. A tree-wide
  grep returned 0 hits for a term that `strings` found 27 times — nearly caused a wrong conclusion.
- Backups/snapshots: use **`cp -Rc`** (APFS clone). 16 GB cloned in 1.4 s with ~0 disk used.
- **`probeFastSync` must match `WINEMSYNC`, not bare `msync`.** Every ntdll has the POSIX
  `_msync()` *syscall symbol* in its symbol table, so a raw-byte scan for `msync` false-positives
  on wine 11 (which has no msync *feature*) → new bottles wrongly got `sync=msync`. `strings` hides
  this (it skips the symbol table); a `Data.range(of:)` scan does not. Fixed to search `WINEMSYNC`
  /`WINEESYNC` (the env vars only the feature reads). Verified: upstream wine 11 → false;
  wine 10 + msync (current engine) and Mythic → true.
- **Steam adds a macOS menu-bar (top-right) icon** via Wine's `explorer.exe`, which bridges the
  Windows systray to an `NSStatusItem`. To remove it: `pkill -f explorer.exe` after launch.
  Verified: explorer does NOT respawn, and Steam keeps working without it (windows are managed by
  `winemac.drv`, not explorer). `AppModel.suppressWineSystray()` sweeps for 60s after every launch.
- **`launchSteam` must be idempotent.** Spawning `wine steam.exe` on every click made Steam
  "reopen" each time. Now: a plain Steam bottle short-circuits to activate-existing if Steam is
  already up; a bottle with `-applaunch` (a game) always runs, because the running Steam forwards
  the applaunch to launch the game. See the `isGameLauncher` split.
- **Game/Steam launches run QUIET** (no console sheet). The console popping over Decanter made the
  first click look like a no-op ("had to click twice"). Setup ops (create/install/apply) still show it.
- `pgrep -f 'steam\.exe'` from a shell can self-match (the pattern is in the shell's own argv);
  from the app via Process it's correct (Decanter's argv has no "steam.exe").
- **Never `for try await byte in URLSession.bytes(...)`.** Iterating an async sequence one byte at
  a time cost **25x throughput** here (0.12 MB/s vs 3 MB/s) — a 317 MB download went from ~45 min
  to **57 s** once switched to `URLSession.download(from:delegate:)`. Both WineInstaller and
  Steam.downloadInstaller hit this; comments there record it.
- **Steam `-silent` hides the window.** On a launcher bottle it makes "Launch Steam" look broken
  (user must click twice). Only use it on a per-game bottle that also passes `-applaunch`.
- **Steam re-execs itself** for a startup update check and both processes stay resident → **two
  Dock tiles for one Steam**. `-skipinitialbootstrap` avoids it (verified: still logs in, still
  self-updates). Don't also add `-nobootstrapperupdate` — that blocks bootstrapper updates.
- **`pkill -f 'steam.exe'` does not kill a Wine prefix.** `explorer.exe`, `services.exe`,
  `winedevice.exe` etc. survive for hours and leave stale Dock registrations. Use
  `wineserver -k` **per prefix**, then pkill the stragglers.
- **`homeDirectoryForCurrentUser` ignores `$HOME`** (reads the passwd entry), so you cannot fake a
  fresh-Mac test by overriding HOME. Use `--install-engine` / Setup Assistant instead.

## Verification habits that mattered

- **Screenshots beat logs.** `screencapture -x` + Read. Logs said "0 errors" while the screen was
  a black rectangle. Terminal has Screen Recording permission; it does **not** have Accessibility,
  so `System Events` reports **0 windows** for wine processes and cannot click/fullscreen them.
- Wine windows are their own macOS Space in fullscreen — a plain screenshot catches the wrong Space.
  Raise the wine process first (`System Events` → `set frontmost`), then capture.
- Long-running launches must use `run_in_background: true`. A foreground command's timeout
  **SIGTERMs the whole process group** and killed a Steam download at 90%.

