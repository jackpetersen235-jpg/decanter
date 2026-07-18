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

## Current state (2026-07-17)

- **First run is fully automated.** `SetupWizard` + `WineInstaller` download and configure
  everything (Rosetta → engine → bottle → Steam) with one button. No terminal, no Wine knowledge.
  Re-openable any time via **View → Setup Assistant…**.
- **Decanter owns its engine**: `~/Library/Application Support/Decanter/Wine/` (WhiskyWine 11.0,
  installed by the wizard). No dependency on Whisky/Mythic/CrossOver being present.
  `Paths.wineEngine*` — first in discovery order, so it's the default.
- Bottles are synced to reality: **WhiskyWine 11 + DXMT + MetalFX 2x**, prefix `Steam-Wine11`.
- Shareable build: `~/Desktop/Decanter-for-friend.zip` (2.1 MB — the engine self-downloads).

### Still open
- Frame spikes in thread-heavy games: **fixable, not "unfixable for free"** (old claim corrected
  2026-07-17). The current upstream-wine-11 engine has no msync; the FREE CrossOver-24-sourced
  `WS12WineCX24` (wine 9) **does**, and it activates (proven). Remaining blocker is standalone
  Steam networking — the free engine wants a Sikarugir/Kegworks *wrapper*. See GAMING-STACK.md
  §2/§2b/§3. In progress: a Decanter copy that drives games through such a wrapper. CrossOver
  (~$74) is the guaranteed shortcut.
- `Steam-Mythic` prefix + the CrossOver bottle (~3.2 GB total) are leftovers, safe to delete.

## First-run automation (SetupWizard) — how it works

A newcomer with **no Wine and no Rosetta** can press one button and end up at Steam. The wizard
(`Views/SetupWizard.swift`) shows 4 self-checking steps and calls one model routine:

- `AppModel.runGuidedSetup()` — the whole flow, factored OUT of the view so it survives view
  lifecycle and is testable headlessly. Steps: `ensureRosetta()` → `installEngine()` (downloads
  **WhiskyWine 11** via `WineInstaller`, ~317 MB, to `~/Library/Application Support/Decanter/Wine/`)
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
  /`WINEESYNC` (the env vars only the feature reads). Verified: WhiskyWine 11 → false, Mythic → true.
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

