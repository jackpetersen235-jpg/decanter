# Decanter — context for future sessions

**Read this first.** Decanter is a SwiftUI macOS app that manages Wine "bottles" for gaming
(the Whisky/CrossOver idea, rebuilt). It was built alongside a real goal: getting
**Sekiro: Shadows Die Twice** running on an **M5 MacBook Air (macOS Tahoe 26.5.2)**.

Two separate things live here, and they are **not currently in sync**:
1. **The Decanter app** (this repo) — the bottle-manager GUI.
2. **A working Sekiro setup** (outside this repo) — `~/Applications/Sekiro.app`, hand-tuned.
   This is what actually runs the game. Decanter's bottle metadata is **stale** relative to it.

> **Debugging this on someone else's Mac?** Start at
> [`docs/DEBUGGING-GUIDE.md`](docs/DEBUGGING-GUIDE.md) — triage commands, symptom→cause tables, the
> investigation habits that caught this project's wrong answers, and what to do when the answer is
> "that is impossible".
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
- Headless test hooks: `Decanter --install-engine` and `Decanter --run-setup`. The 2026-07-17
  end-to-end check (engine downloads at ~2 MB/s; bottle + Steam auto-created) observed SIDE
  EFFECTS, not a reported result — until F15 (bug-sweep, 2026-08-23), neither flag ever printed
  anything or set an exit code, success or failure, so a failed run would have looked identical.
  Both now `exit(0)` on success and `exit(1)` with a reason on stderr, like every other headless
  flag in this dispatch.
- **These headless hooks can now target a scratch install instead of the real one.**
  `Paths.appSupport` reads `DECANTER_HOME` when set and uses it AS the app-support root directly
  (no `Decanter` subfolder appended) — every other path in `Paths.swift` derives from it, so this
  one env var redirects `bottles.json`, `Bottles/`, the engine roots, everything:
  `DECANTER_HOME=/tmp/scratch Decanter --run-setup`. Added for the pre-release debug plan's Phase 1
  — every expensive bug in the F-numbered history above shared one property, it couldn't fire on a
  machine already in the state the buggy code was trying to reach, and there was previously no way
  to BE a fresh Mac without risking the real 25 GB `Steam-Wine11` install.
  `homeDirectoryForCurrentUser` ignoring `$HOME` (gotcha below) is exactly why this needed its own
  variable rather than reusing `$HOME`. Deliberately narrow: it does not redirect discovery of
  things actually installed on the Mac (`Wine.swift`'s Whisky/CrossOver scan,
  `importCrossOverBottles`, the `~/Applications` launcher scan in `reclaimReport`) — those still
  read the real home on purpose, so a scratch run still reports what's really on the machine. See
  `docs/DEBUGGING-GUIDE.md`'s "Testing any of the above against a scratch install" and
  `Tests/DecanterTests/PathsTests.swift`.
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

### A third profile: `legacy`, for old 32-bit games

`Configuration → Engine → Play mode` now offers **Legacy** alongside Offline and Online. Same
mechanism: an APFS clone of the tuned engine (measured again here — **0.00 GB consumed** for a
719 MB tree), selected per bottle. Create or restore it with `--reset-engine legacy`.

It exists because old 32-bit titles hit a wall the tuned engine cannot help with, and every
candidate fix threatens the setup that already works:

- **Rosetta 2 emulates x87 floating point in software — MEASURED at ~10x on this M5**, not the
  "~100x" this file used to quote from hearsay. Benchmark (same loop, `long double` forces x87,
  `double` uses SSE; `Scripts/../scratchpad x87bench.c`):

  | | SSE (double) | x87 (long double) | ratio |
  |---|---|---|---|
  | native arm64 | 0.147 s | 0.122 s | 0.8x |
  | x86_64 under Rosetta | 0.123 s | 1.248 s | **10.1x** |

  **Rosetta's SSE path is free** (0.123 s translated vs 0.147 s native) — translation itself is not
  slow. x87 is the only penalty, and it is ~10x vs native. Pre-2010 games do their maths on the x87
  FPU, so they fall off a cliff while modern 64-bit titles (SSE) are unaffected.
  ⚠️ For Peggle this was asserted long before it was measured, and it cost two wrong fixes (a DXVK
  switch, then a byte-identical engine clone). It is now **supported by measurement but still not
  causally proven** — see §"Peggle Deluxe — what the measurements actually showed". **Treat it as a
  hypothesis for any given game until that game has been disassembled and sampled.**
- The known fixes ([x87sidecar](https://github.com/athei/x87sidecar),
  [rosettax87](https://github.com/Lifeisawful/rosettax87)) hook Rosetta's `translate_insn`. The
  no-root "cooperative" mode needs a **patched Wine**; our engine has no such handshake (verified:
  zero hits for the symbols), so it would otherwise need `sudo`.
- **`athei/wine-build` is NOT a safe swap.** It is CrossOver-based, and CrossOver's patches are
  exactly what broke Steam's loopback UI websocket — the finding that cost an overnight session
  (see §Recently FIXED). It also does not mention msync and is x86_64-only. Adopting it would trade
  a working setup for a broken one to fix one 2007 game.

So the legacy profile is a **container for that experimentation**, not a fix in itself. What goes
in it is a separate decision; what matters is that it cannot reach the engine Sekiro depends on.

**A profile that cannot CREATE its engine is not a profile — it is an error message.**

`setEngineProfile` auto-created the engine only for `.online`, hardcoded. `.legacy` was therefore
usable exactly on the one Mac where the clone had been made by hand, and nowhere else: selecting
Legacy fell through to the `installations` check and returned *"That engine isn't available"*.
Pressing **Rescan** could not help either — discovery lists the legacy path, but there was nothing
on disk to find, and Rescan reported nothing at all, so it read as a broken button.

Reported as "even when I click rescan it doesn't show anything new". The screenshot settled it in
one detail: the paths read `/Users/<friend>/...`, so it was the FRIEND's Mac, where **only**
`Wine` and `Whisky` exist. Check the username in a screenshot before assuming whose machine it is —
the entire diagnosis turned on it.

Fixed by generalising: any non-offline profile clones on demand, then rescans. Verified by moving
`WineLegacy` aside to reproduce his state exactly, then `--engine legacy` (created it, 719 MB tree,
~0 disk) and `--engine offline` to restore. **Restore the bottles afterwards** — that test leaves
Sekiro and JJBA pointing at the legacy engine; confirm from `bottles.json`, not the command output.

`--reset-engine` reported a bare `FAILED` during this because Steam was running and the guard
correctly refused. The guard is right; the silence is not — a headless failure with no reason
printed sends you looking for a bug that isn't there.

**Rescan now says what it found.** A control that does real work silently is one users conclude is
dead, and this one had no output whatsoever.

**Two things that bit during implementation:**

- **A new engine must be added to `Wine.swift`'s discovery list.** Creating the directory is not
  enough: `setEngineProfile` resolves a profile through `installations`, so the clone succeeded and
  switching still failed with "That engine isn't available".
- `clone`/`reset` are now **parameterised over the profile** rather than copied a third time. Three
  near-identical functions is precisely how the game picker and the launcher resolver drifted apart
  earlier in this file.

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
- **Testing a fix through `build/Decanter.app` after only running `swift build` tests the
  PREVIOUS build.** `swift build` updates `.build/debug/Decanter` only; the `.app` bundle is a
  separate copy that only `Scripts/make_app.sh` (or `package-for-friend.sh`, which calls it)
  refreshes. Same shape as the `generatorVersion` trap above — a file that outlives the app that
  wrote it goes stale. Bit a live F14 verification during the F11-F16 bug-sweep pass (2026-08-23):
  a `.wined3d` fix looked broken (registry key present, values empty; a run that should've been
  capped at 30s by F16 instead ran ~90s) purely because the `.app` being exercised was still the
  pre-fix, pre-F16 build. `strings build/Decanter.app/Contents/MacOS/Decanter | grep <a string
  only the new code contains>` is the fast way to check which build you're actually running.
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
  ⚠️ **`-silent` also makes Steam unquittable, and the app used to have no cure.** `-silent` starts
  Steam *in the tray*, so closing its window re-hides it instead of exiting; the client stays up and
  respawns its webhelper UI, which reads as "Steam reopens every time I quit it". Measured
  2026-08-02: a steam.exe started by the DIRECT-EXE path (which hardcodes `-silent` with **no**
  `-applaunch`, violating the rule above) had been resident **7h37m** across four quit attempts —
  the same PID throughout, only the webhelpers restarted. Nothing reaps Steam after a direct-exe
  game exits, and the only shutdown path in the app (`shutdownPrefix` via `launchSteam`) is
  unreachable for a game bottle because `isGameLauncher` skips that branch. Fixed by adding
  `quitSteam(in:)` + a **Quit Steam** button + `--quit-steam`. When debugging "Steam won't quit",
  check `ps -Ao pid,lstart` for steam.exe FIRST: if the PID is unchanged, it was never quit.
- **Steam auto-starts itself from the prefix's `Run` key — windowless.** Steam writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` → `"Steam"="steam.exe -silent"` (its
  "run Steam when my computer starts" setting, ON by default). A prefix has no boot, so this fires
  whenever *anything* brings the prefix up: a bare `wine wineboot` starts Steam with no other
  prompting — verified twice, before and after the fix. This is the other half of "Steam reopens
  every time I quit it", and it makes quitting Steam pointless on its own. `quitSteam` now deletes
  the value first (Steam rewrites it whenever it runs, so it must be re-applied every quit).
- **`isAnyGameRunning` must split `comm` on BOTH `/` and `\`.** Wine reports `comm` as a Windows
  path (`C:\windows\system32\services.exe`), so splitting on `/` alone leaves the string intact,
  the helper allowlist never matches, and **every Wine helper counts as a running game** — 6 of 7
  misclassified in a live check. It then returned true for hours after any Wine use, silently
  disabling everything gated on it (the stale menu-bar sweep, and the engine switch, which always
  refused with "Quit Steam and any running game first"). Test it with helpers ONLY: `wine cmd /c …`
  also runs `cmd.exe` and `ping.exe`, which are NOT helpers, so it returns true legitimately and
  looks like the bug. Use `wine wineboot`.
- **`shutdownPrefix`'s straggler sweep cannot see steamwebhelper.** It matches the macOS prefix
  path in argv; the webhelpers carry only Windows paths (`C:\Program Files (x86)\Steam\...`), so
  0 of 6 matched in a live check. `wineserver -k` is what actually reaps them — do not "optimize"
  it away or reorder it after the sweep.
- **Steam re-execs itself** for a startup update check and both processes stay resident → **two
  Dock tiles for one Steam**. `-skipinitialbootstrap` avoids it. Don't also add
  `-nobootstrapperupdate` — that blocks bootstrapper updates.
  ⚠️ **BUT NEVER PASS IT TO A STEAM THAT HAS NOT BOOTSTRAPPED YET.** `SteamSetup.exe` only drops
  `steam.exe` (~5 MB); the client itself — `steamui.dll` (18 MB), `steamclient64.dll` (25 MB) —
  is downloaded by Steam on FIRST LAUNCH, and that download *is* the "initial bootstrap" this flag
  skips. On a fresh install the flag therefore guarantees **"Failed to load steamui.dll"**, which
  is identical to the too-old-engine symptom and sent us chasing the wrong cause. The original
  "verified: still logs in" note was only ever tested against an already-bootstrapped Steam — the
  one state where the flag cannot do harm. `Bottle.isSteamBootstrapped` now gates it, and
  `isSteamInstalled` (steam.exe exists) must not be mistaken for "Steam can run".
- **`pkill -f 'steam.exe'` does not kill a Wine prefix.** `explorer.exe`, `services.exe`,
  `winedevice.exe` etc. survive for hours and leave stale Dock registrations. Use
  `wineserver -k` **per prefix**, then pkill the stragglers.
- **`homeDirectoryForCurrentUser` ignores `$HOME`** (reads the passwd entry), so you cannot fake a
  fresh-Mac test by overriding HOME. Use `--install-engine` / Setup Assistant instead.

## Generated game launchers — REMOVED (2026-08-12)

Decanter used to write a `.app` per game into `~/Applications`, and **Play opened that bundle**
instead of launching anything itself. The whole generator is gone: script emission, Info.plist, the
`generatorVersion` stamp, `buildGameApp`, `launchGameApp`, `hasGameApp`, `--build-game-apps`, and
the Rebuild Launcher / Show in Finder buttons. `GameAppBuilder` now holds only the `Game` struct
that `resolvedGame` returns.

Removed at the user's request — "a useless extra step that just gets in the way". It was: creating
a bottle produced a second artifact to keep track of, and Play went through it rather than starting
the game. **Play now calls `launchSteam` directly**, which already did everything the script did —
waits for Steam to log in, runs `steam.exe -applaunch <id>` or the binary directly for anti-cheat
shim bottles, and installs the per-game graphics DLLs first. Verified after removal: pressing Play
on the Peggle bottle started `popcapgame1.exe` (134% CPU) with no bundle involved.

Existing generated bundles were moved to the Trash; the hand-made `Sekiro.app` / `JJBA All-Star
Battle.app` (696 MB each, they embed their own Wine) are unrelated and were left alone.

**What was learned here is worth keeping even though the code is gone:**

- **Shell-quote every path.** `steamapps/common/JoJo's Bizarre Adventure…` — a raw interpolation
  closes the quote at the apostrophe and runs something else entirely.
- **`pgrep -x`, never `-f`,** for an already-running check: `-f` matches the script's own argv.
- **Steam-DRM games must be launched BY Steam**, not merely with Steam running. Older Steamworks
  titles ship `Steam.dll` and check they were started by the client; running the `.exe` directly
  fails the handshake even with Steam up. `launchSteam` keeps this behaviour.
- **A file that outlives the app that wrote it will go stale**, and shipping a fix to the generator
  never reached bundles already on disk. That trap is why the version stamp existed, and removing
  the generator removes the trap with it.

## New-bottle game picker (`GameScanner`)

**New Bottle** scans every known prefix's `drive_c` and lists what it finds; clicking a game
creates a bottle already configured for it (app id or direct exe) and generates its launcher.
**Choose a Program…** is the deliberate bypass for anything the scan misses. Headless:
`--scan-games`.

- **It scans PREFIXES, not bottles.** Three bottles here share `Steam-Wine11`; scanning per-bottle
  listed every game three times.
- **It reuses the game's existing prefix** rather than booting a new one — a fresh prefix would
  mean reinstalling Steam and re-downloading the game for nothing.
- **228980 must be filtered here too.** "Steamworks Common Redistributables" has its own folder
  and a 187 MB `VC_redist.x64.exe`, so the >64 MB size filter does NOT catch it — it listed as a
  game, twice, until excluded. The list now lives in `GameScanner.nonGameAppIDs` and `AppModel`
  refers to it, because the picker and the launcher resolver disagreeing about what counts as a
  game is exactly how this bug got in twice.
- **The same game can legitimately appear twice** (Half Sword is in both `Steam-Wine11` and its
  own prefix, sharing APFS blocks). Rows therefore name the prefix; without it the picker showed
  two identical entries.
- **Every walk is bounded** (`fileLimit`, >64 MB folder threshold, fixed roots two deep). An
  unbounded walk of a 24 GB Steam library per candidate would hang the sheet. The scan runs off
  the main actor in `.task` for the same reason.
- `GameScanner.largestExecutable` is shared with `AppModel.resolvedGame` so the binary shown in
  the picker is always the one the launcher will run.
- **That walk is BREADTH-FIRST, and must stay that way (2026-10-27).** It used to be a depth-first
  `FileManager.enumerator` under the 4,000-entry budget, and APFS lists a directory in hash
  order, not alphabetically. Resident Evil HD REMASTER lists its 5,339-entry `nativePC/` before
  the top-level `bhd.exe`, so the budget ran out inside the data folder, no executable was found,
  and the game was silently missing from New Bottle (and would have failed `resolvedGame` too).
  `detectedSteamGames` only looks one level deep, which is why the DXMT DLLs still landed beside
  `bhd.exe` and made it look like Decanter "knew" the game. Pinned by `GameScannerTests`.
- **`Task.detached { await model.someMethod() }` does NOT get you off the main actor.** `AppModel`
  is `@MainActor`, so the detached task hops straight back and the work runs on the main actor
  anyway. The first version of the scan claimed to be off-thread and was not. The fix is a
  `nonisolated static` that takes plain values (`AppModel.scanForGames(in: [URL])`) — read the
  actor state first, then hand the pure data to the detached task.
- **A bottle NAME is a filesystem path.** `GameAppBuilder.destination` derives
  `~/Applications/<name>.app` from it, and `build` deletes before it writes — so two bottles
  sharing a name means the second silently replaces the first's launcher. `uniqueBottleName`
  numbers duplicates ("Half Sword 2"). Verified by creating a second JJBA bottle: the original
  launcher's hash was unchanged afterwards.
- **Ask `resolvedGame` what a bottle plays; never re-derive it.** The "Added" badge originally
  checked `steamAppID`/`directExecutable` directly and missed the Half Sword bottle entirely,
  because a bottle made from "New Bottle" has NEITHER field and resolves via the single-manifest
  fallback. Any second opinion about "which game is this" will drift from the Play button.
- **Do not gate a control on a bare filesystem check.** "Show in Finder" was hidden behind
  `hasGameApp(for:)`, which touches disk and has nothing observable behind it: the launcher is
  written asynchronously after a bottle is created, so SwiftUI never re-rendered and the button
  stayed hidden for a launcher that existed. It now always shows and builds on demand.

## Liquid Glass — what the research actually said

Four rounds of "that doesn't look like Liquid Glass" all traced to the same mistake:
reimplementing things Apple already ships.

- **Use Apple's button styles, not `.glassEffect` on a padded label.** `.buttonStyle(.glass)` and
  `.buttonStyle(.glassProminent)` exist on macOS 26 and were what was missing the whole time.
  Hand-rolling a `ButtonStyle` that pads a label and calls `.glassEffect(…, in: .capsule)` gets the
  material and *none of the rest*: real control metrics, concentric corner radius, press/hover
  behaviour, the system's control-specific tuning of the material, automatic light/dark adaptation.
  `.glassEffect` is for applying glass to CUSTOM views — a button is not a custom view.
- **It is only for the navigation layer that floats ABOVE content.** Apple names content layers,
  full-screen backgrounds and scrollable content as things it must not be applied to. A sidebar
  holding a scrollable list is all three, which is why glassing it read as a tinted panel no matter
  which variant was used.
- **Glass cannot sample other glass.** `GlassEffectContainer(spacing:)` gives adjacent glass
  elements one shared sampling region; without it each samples independently and they render as
  flat capsules.
- **The effect lives in the EDGES.** The rim bends and magnifies what is behind it. A full-bleed
  pane has no visible rim, so the whole effect is clipped away — float and inset anything that must
  read as glass.
- **Refraction is only visible where there is detail to bend.** Over a flat fill or a smooth
  gradient even a correct implementation reads as a tint. This is a property of the material, not a
  bug to tune out.
- Variants: `.regular` (default, for controls that must stay legible against anything), `.clear`
  (high transparency, wants busy content behind it), `.identity` (off). `.interactive()` adds the
  press response.
- Third-party lensing libraries exist (BarredEwe/LiquidGlass, DnV1eX/LiquidGlassKit) but the ones
  checked are **iOS-only** — no help here.

### Getting a CLEAR window, not a grey one

Two separate problems, solved in order:

1. **Opaque window** — a SwiftUI window is opaque by default, so glass inside it samples the
   window's own flat backing. Sampling a flat fill gives a flat tint.
2. **Grey cast** — backing the window with an `NSVisualEffectView` fixes the sampling but every
   `NSVisualEffectView.Material` *tints*. There is no clear material; `.underWindowBackground` and
   the rest all add grey. `containerBackground(_:for: .window)` cannot help either — it takes a
   `ShapeStyle`, so it always paints something.

**Only AppKit gives a genuinely clear window:** `window.isOpaque = false` and
`window.backgroundColor = .clear`, reached from SwiftUI via an `NSViewRepresentable` that reads
`view.window` — inside a `DispatchQueue.main.async`, because `view.window` is nil while the view is
still being inserted.

**Consequence: every region holding content needs its own surface.** With the window clear, a pane
with no background sits its text directly on the wallpaper. Both the sidebar and the detail column
therefore carry `glassPane`. Anything added later that holds text needs one too.

Trade-off worth knowing: `.clear` glass over a busy wallpaper is beautiful and hard to read. If
legibility matters more than transparency for a given pane, `.regular` is the variant to switch to
— it is still glass, just less transparent.

### The window must be non-opaque or glass has nothing to sample

**This was the missing piece behind every failed attempt.** A SwiftUI window is opaque by default,
so a glass effect inside it can only sample the window's own flat backing — and sampling a flat
fill produces a flat tint. The material was never the problem; there was nothing behind it.

`DesktopBackdrop` fixes it with an `NSVisualEffectView`:

- `blendingMode = .behindWindow` — the actual switch. It pulls pixels from the desktop wallpaper
  and any windows underneath. The default (`.withinWindow`) blends only against the app's own
  content, which is why the window looked like a solid slab.
- `state = .active` — not optional. Without it the effect reverts to a solid system colour the
  moment the window loses focus, so the app would only look right while frontmost.
- Both are re-asserted in `updateNSView`: SwiftUI can recreate the backing view, and a reverted
  blending mode silently restores the flat-tint behaviour.

Applied in Liquid Glass only. Aero paints its own opaque sky, and letting the desktop through
underneath would put a photograph behind a 2006 pastel gradient.

Also on macOS 26: `NSGlassEffectView` is the AppKit first-class glass container, with a real
`cornerRadius` instead of the old mask-image approach — worth knowing if the SwiftUI modifier ever
proves too limited.

### The sidebar's grey needed dropping NavigationSplitView entirely

A `NavigationSplitView` sidebar column is an `NSSplitViewItem` with sidebar behaviour, and that
installs a vibrancy backdrop **below anything SwiftUI can reach**. It kept the left column grey
while the detail pane was clear. Two fixes were tried and both failed:

1. `.containerBackground(.clear, for: .navigationSplitView)` — compiles, but is **iOS-only**.
2. Finding the `NSVisualEffectView` and hiding it, walking UP from a `.background` placeholder and
   searching DOWN from `window.contentView`. Neither changed the rendering.

A glass pane placed on top sits *above* that backdrop, so tuning the pane can never reach it.

**The fix was to lay the two columns out with an `HStack`** and give up the split view. Its
backdrop goes with it, and the clear window shows through. Also use `.listStyle(.plain)` — the
`.sidebar` list style reintroduces its own vibrancy, which is the very thing being removed.

Cost: the system sidebar behaviour. The collapse animation and its toggle button are gone, and the
column width is now set explicitly (264pt) rather than managed.

### Custom ButtonStyles get no focus ring — FIXED, and the shape of the fix matters

`ButtonStyleConfiguration` exposes `isPressed`, **not focus**, so a custom `ButtonStyle` cannot draw
a focus ring from inside itself. macOS draws one automatically for SYSTEM styles, so every button on
`.glass`, `.glassProminent` or `.bordered` was always fine. `AeroButtonStyle` is custom, so Play and
Launch Steam in Aero had none under Full Keyboard Access.

The fix has to live **outside** the style: `@FocusState` on the view, `.focused(_:equals:)` on each
button, and `aeroFocusRing(_:)` reading that. 2pt `#FFF9C4` at 2pt offset.

Two things to keep right:

- **It draws in Aero only.** System styles already have a ring; a second one over it is wrong.
  `AeroFocusRing` checks the theme itself so a call site cannot get this wrong.
- **The gloss is not a focus indicator.** It is present whether or not a control has focus.

A first pass deleted the helper as "dead code" — it was dead because it had never been *applied*,
which is the bug rather than evidence there wasn't one. When a helper exists and has zero call
sites, check which of the two it is before removing it. `grep -c` on the call sites is the check.

### Window state is sticky — whatever sets it must be able to UNSET it

`ClearWindowBacking` set `window.isOpaque = false` for Liquid Glass, and the modifier only
INSTALLED that view when the theme wanted a clear window. Switching to another theme removed the
view instead of updating it, so `updateNSView` never ran again and nothing restored `isOpaque`. The
window stayed transparent until relaunch.

The symptom was confusing and worth recognising: **the right half looked like Liquid Glass while the
left half looked correct.** The sidebar has an opaque fill in Standard so it rendered right; the
detail pane deliberately has none, so the still-clear window showed the desktop through it.
Relaunching "fixed" it because a fresh window starts opaque.

The fix is to keep the view installed always and pass the desired state as a parameter, driving the
property in both directions. Any `NSViewRepresentable` that mutates window- or app-level state has
this shape — conditionally inserting it means the "off" path never runs.

### `aeroInk()` must reach EVERY column, not just the detail pane

The Aero sidebar rendered very dark against a light sky. `aeroInk()` was applied to the detail
column and the wizard but never to the sidebar, which caused two faults at once:

1. The sidebar stayed in the **dark colour scheme** (`aeroLightChrome` sets `colorScheme` to
   `.light`), so every system-drawn control in it was coloured for dark chrome.
2. Its `List` kept painting an **opaque dark backdrop**, because
   `scrollContentBackground(.hidden)` ships inside `GlassPane` — which is a no-op in Aero, so
   nothing was hiding it.

Anything that holds content needs `aeroInk()` in Aero, the same way it needs a surface in Liquid
Glass. The two themes have mirror-image requirements and it is easy to satisfy one and forget the
other.

### Accessibility cannot be verified by injecting the environment

`\.accessibilityReduceTransparency` and `\.accessibilityReduceMotion` are **read-only**
`KeyPath`s, not `WritableKeyPath`s — `.environment(...)` will not compile against them. A launch
flag that forces one on for verification is therefore impossible; the attempt was removed rather
than left as dead scaffolding.

Two consequences:

1. **These settings can only be checked by toggling them for real** in System Settings ▸
   Accessibility ▸ Display. Restart the app afterwards.
2. **Never set those keys unconditionally.** The first draft applied all three every launch, so
   with no flag they were forced to `false`/`.standard` — a machine with Reduce Transparency
   genuinely on would have had the app switch it off. An accessibility aid that disables
   accessibility is worse than none.

Reduce Motion has nothing to switch off here by design: bubbles come from a fixed table and never
animate, and the pressed state is a flat darkening rather than a transition.

What to look for when checking by hand:
- **Reduce transparency** — gloss flattens to a wash, bubbles disappear, glass controls turn
  opaque, the sidebar loses its material.
- **Increase contrast** — Aero button fills darken by 18% (`AeroButtonStyle`).

### HIG foundations pass (2026-11-02) — four rules for every new view

1. **Never tint caption TEXT with a system colour — use `StatusNote`.** Measured against the
   light window background: system orange **2.31:1**, yellow **1.51:1**, red **3.57:1**, green
   **2.22:1** — all under the 4.5:1 small text needs (orange drops to 1.86:1 with Increase
   Contrast). They pass only in dark mode, which is why they looked fine on this Mac.
   `StatusNote` puts the tint on the symbol, tells warning (orange triangle) from failure
   (`StatusNote.failure`, red octagon) by SHAPE, and leaves the text unstyled so Aero's ink and the
   text-tone override still reach it. Ten call sites were converted.
2. **Anything clickable is a `Button`, never `.onTapGesture`.** A tap gesture is invisible to
   VoiceOver and unreachable from the keyboard; adding `.accessibilityAddTraits(.isButton)` (F9's
   first fix) only CLAIMS interactivity. Use `.buttonStyle(.plain)` to keep a custom look, and
   `.accessibilityAddTraits(.isSelected)` for selection. The New Bottle picker was pointer-only
   until this pass. Checked by pressing a row through `AXPress` (what VoiceOver's activate sends).
3. **State shown only visually needs an accessibility value** — the wizard's step badges now
   read "Done" / "In progress" / "Not started". Decorative icons get `.accessibilityHidden(true)`.
4. **No animation on something that fires per log line** — the console used to animate a scroll
   for every line of a long install.

Capitalization follows the macOS convention the app already mostly used: title case for buttons and
menu items, sentence case for toggles, pickers and section headings — and proper names keep their
capitals in either ("Liquid Glass", "Frutiger Aero"). The wizard's "Set everything up for me" and
"Start using Decanter" were left as they are because the friend READ ME and FOR-CLAUDE-CODE.md quote
them.

Verifying a view change without touching the real app: copy `build/Decanter.app`, change its
`CFBundleIdentifier`, re-sign ad hoc, and `open -n --env DECANTER_HOME=<scratch> <copy>`. Own
preferences, own data, no click can land in the real instance. ⚠️ The computer-use tools lost
accessibility access to such a copy twice: once after a relaunch (window on screen, AX listed
nothing), once mid-run in a copy that was never re-signed (window moved to another Space). The
screen was not locked either time, and the cause is not isolated. Do the critical clicks first,
in the first run. Force light mode per app with
`defaults write <test bundle id> NSRequiresAquaSystemAppearance -bool true`
(`-AppleInterfaceStyle Light` as a launch argument does nothing). Rendering one view with
`ImageRenderer` under `NSAppearance(named: .aqua)` is the quickest light/dark before-and-after.

### HIG patterns pass (2026-11-02)

- **"Delete Bottle (keep files)" is undoable** (Edit ▸ Undo, ⌘Z / ⇧⌘Z) instead of confirmed: it
  only drops the list entry, so `AppModel.removeBottleKeepingFiles` / `restoreBottle` put it back
  exactly (`BottleList.restoring`, `BottleListTests`). Delete-WITH-files keeps its confirmation —
  undo can't bring back erased saves.
- **Setup Assistant has a "Not Now"** when opened from the View menu with a step unfinished. It
  replaces the main window, and its only exit used to be finishing setup. Hidden on first run and
  while setup runs (`dismiss` is nil then).
- **Esc cancels the Uninstall sheet** (Remove Everything stays click-only), matching New Bottle.
- **One name for one action:** Setup's "Add Manually…" is now "Add Wine Bin Folder…", as in Settings.

Found and deliberately NOT changed — each needs Jack's call:
- **Launch doesn't restore the selected bottle** (always the first). HIG says restore state, but a
  restored game bottle would never be "selected", so it would never warm-start Steam — and
  warm-start was scoped to user selection only, never at launch.
- **The gear sheet duplicates Settings** (Rosetta, Wine builds, default build, Rescan, add folder).
  HIG wants settings in the Settings window; two copies is how the rescan messages drifted (see
  review findings 4–6). Consolidating means retiring `SetupSheet`.
- **Help ▸ Decanter Help** is the system default, which says help isn't available. Pointing it at
  the troubleshooting guide needs that guide shipped inside the app (today it's only in the zip).

### HIG inputs pass (2026-11-02) — keyboard

- **Bottle menu** (`BottleCommands`): Launch ‹bottle› (⌘↩), Quit Steam…, Open C: Drive, both
  deletes. Items needing a confirmation or the undo manager are posted to the window
  (`.deleteBottleRequested`, `.quitSteamRequested`), like New Bottle…. Quit Steam's refuse-or-
  confirm logic is one function (`requestQuit`) shared by the button and the menu.
- **Shortcut choices:** Launch is ⌘↩, not ⌘R — ⌘R beside Rescan's ⇧⌘R is "a modifier added to an
  existing shortcut for an unrelated command", which the HIG rules out. **No ⌘⌫ for Delete:**
  menu key equivalents fire while a text field has focus, so it would delete the bottle mid-edit.
  The sidebar takes the plain Delete key via `onDeleteCommand` instead (focus-scoped, undoable).
- The menu item is named after the bottle ("Launch Steam", "Launch Peggle Deluxe") instead of
  asking `resolvedGame`, which walks the game folder — too heavy for a menu that re-renders on
  every model change.

Verified in a test copy through the menu bar alone (`app_menu`, which works even when the test
window is unreachable): the Bottle menu lists and tracks the selection, and Delete Bottle (keep
files) removed only the entry, prefix still on disk. **Not verified live: Edit ▸ Undo** — it is
disabled unless the window is key, and the test window sat on another Space. Two traps from
this: a copy launched from the scratchpad is unknown to Launch Services (`open_application` can't
find it), and with the user in a full-screen app, full-screen control shows only black.

### HIG layout pass (2026-11-02)

- **Configuration's grouped `Form` sits inside the detail pane's `ScrollView`** — two vertical
  scrollers in the code, which the HIG says to avoid. **Checked live and left alone:** the
  accessibility tree has ONE scroll bar spanning the pane, because SwiftUI lays a grouped Form
  out at full height inside an outer ScrollView. Don't "fix" it without a screenshot showing a
  second scroller.
- **Sidebar rows carry `.help(bottle.name)`** — the 264pt column cuts long game names, and a
  SwiftUI `Text` gets no automatic expansion tooltip the way an AppKit table cell does.
- **Open decision: the sidebar can't be hidden.** The HIG suggests letting people hide it (View ▸
  Hide Sidebar, ⌃⌘S). It went away with `NavigationSplitView` (see "The sidebar's grey needed dropping
  NavigationSplitView entirely"). Bringing it back by hand means a toggle plus moving the detail
  header clear of the floating traffic lights when the sidebar is gone.

### HIG menus pass (2026-11-02) — where commands live

| Menu | Holds |
|---|---|
| File | New Bottle… (⌘N), Import CrossOver Bottles |
| View | Overview / Configuration / Programs (⌘1–⌘3, `DetailTabCommands`), Rescan Wine Installations (⇧⌘R), Setup Assistant… |
| Bottle | Launch ‹bottle› (⌘↩), Quit Steam…, Open C: Drive, Apply Settings to Prefix, both deletes |
| Help | Export Diagnostics |

- Import and Export Diagnostics used to sit in View, which is for ways of looking at the window.
  Export lost its ellipsis: it asks nothing, it saves straight to the Desktop (HIG: an ellipsis
  means the command needs more input before it completes).
- Every context-menu command is also in the menu bar (Apply Settings to Prefix was not).
- One name per action: "Apply Settings to Prefix" everywhere (the Overview button said "Apply
  Settings"); "Reinstall" is "Reinstall Steam".
- `NSWindow.allowsAutomaticWindowTabbing = false` in `DecanterApp.init`: the system's Show Tab
  Bar / Show All Tabs could only ever offer a second copy of the one window.
- Verified by listing each menu in a test copy (`app_menu`). View ▸ Configuration was pressed but
  the tab change itself was not seen — the window was unreachable again.

## "Why is this game slow" — measure it (`Scripts/profile-slow-game.command`)

Peggle Deluxe was guessed at **twice** — first the graphics backend (DXVK), then the Wine engine
(the legacy profile). Both were plausible, both were wrong, and each cost a round trip with someone
else's Mac in the loop. The script reports the three facts that separate the real causes:

1. **Is the .exe 32-bit or 64-bit?** (`file` on the resolved path.) This is the discriminator. A
   64-bit game uses SSE and is NOT subject to Rosetta's software x87 emulation, which would kill
   the whole x87 theory outright. Guessing at the cause without this is guessing twice.
2. **Is Rosetta actually translating it?**
3. **Where did the time go?** (`sample`, aggregated by symbol.)

**Both of the profiler's readouts were wrong the first time it met a real game.** Fixed and
regression-tested against Peggle's own sample; the lesson in each is general:

- **Rosetta detection swung from false positive to false NEGATIVE.** After narrowing the match to
  `/usr/libexec/rosetta`, it reported "no Rosetta frames" for a process whose header literally says
  `Code Type: X86-64 (translated)` — the frames are labelled *"Rosetta Runtime Routines"*. Read the
  `Code Type:` header; it is authoritative and needs no guessing.
- **The symbol tally counted every tree line.** `sample` prints a call TREE and repeats a frame's
  count at every nesting level, so summing all lines multiplies each frame by its depth. It
  reported **24 million samples from an 8-second capture** — a number that cannot exist and should
  have been caught on sight. Count LEAVES only: a frame is a leaf when the next line is not deeper.

**`sample` cannot tell you which threads are burning CPU.** It ticks every thread each interval
whether running or blocked, so all threads show near-identical counts (they looked like "49.2% of a
core" each — meaningless). Worse, under Rosetta a blocked thread's leaf is `???` just like a running
one, so the symbol cannot classify it either. **Use `ps -M <pid>`** for real per-thread CPU and
state. That is what showed Peggle's shape: 2 threads at 99.5%/99.4% in state `R`, 28 threads idle.

**`pgrep -x` does not match a Wine process.** Its `comm` is a full Windows path
(`C:\ProgramData\...\popcapgame1.exe`), so exact-name matching finds nothing. Get the pid from
`ps -Ao pid,comm= | awk '/name\.exe/{print $1}'`.

**A CPU-drop "stall" detector cannot distinguish a hitch from the player alt-tabbing.** Peggle went
to ~0% for 16 s and it was simply someone switching to Steam — `wineserver` spiked to 81% for the
window teardown, then everything settled. Screenshot every stall before believing it.

**⚠️ `grep -i rosetta` on a sample is ALWAYS a false positive.** `libRosetta.dylib` is loaded into
every process on Apple silicon, *including native arm64 ones* — verified against a native arm64
test binary, which reported "Rosetta IS translating this process". Match the translator itself:
`/usr/libexec/rosetta` or `libRosettaRuntime`. Same bug class as `pgrep -f` matching its own argv:
**a substring that happens to be present is not evidence of the thing you are looking for.**

Also drop `start`, `main` and `Thread_N` from a symbol tally — they hold every thread's full weight
by definition, so they always top the list and say nothing. Validated end-to-end against a spinner
that calls `sin()` in a loop: `sin` came out top at 687 samples.

**The legacy engine is a byte-identical clone and cannot change performance.** Verified with
`diff -rq`: **0 differing files** against the tuned engine. Switching to it is expected to change
nothing — it is isolation for experiments, not a fix. Say that out loud before suggesting it.

## Peggle Deluxe — what the measurements actually showed (2026-08-08)

Installed the WINDOWS build into the `Steam-Wine11` bottle and profiled it live. Everything below
is measured on an M5 Air; the earlier x87 story was reasoning and was wrong.

**How it runs:** Steam launches `peggle.exe`, a DRM shell that unpacks and runs
`C:\ProgramData\PopCap Games\Peggle\popcapgame1.exe`. **Anything aimed at `Peggle.exe` — a DLL
override, a launch option, an x87 hook — lands on the wrapper and misses the game.**

**The numbers:**

| config | CPU | hot threads | fps (active) |
|---|---|---|---|
| stock | 207% | 98.6% + 96.4% | 12.7 avg, 32 max |
| `csmt=0` | 109% | 97.2% | ~15 |
| `csmt=0` + `VideoMemorySize=4096` | 110% | 97.5% | ~14 — **no effect** |
| `renderer=vulkan` | 102% | 59% + 43% | **BROKEN — hangs on the loading screen** |

- **`csmt=0` is a genuine win: a whole core back, no frame-rate cost.** WineD3D's command-stream
  thread busy-polls; under Rosetta that costs a full core. Frame rate is unchanged, so it is a
  power/heat fix, not a speed fix.
- **`renderer=vulkan` looked like a 2.5× win and was an artifact.** It reported 60 fps because the
  game was animating its LOADING BAR and never finished loading. Six presented frames in 120 s
  while burning 102% CPU. **A frame-rate win with an implausibly low sample count means the game is
  not running — screenshot before believing any number.**
- **`renderer=gdi` is not a valid value on this build** (`strings wined3d.dll` → only `no3d`,
  `vulkan`). Wine responds by *disabling 3D entirely* and the game will not open.
- **DXMT and DXVK are irrelevant here.** Peggle is DirectDraw; the process loads `opengl32.so` and
  Apple's `AppleMetalOpenGLRenderer`, never a DXMT/DXVK `d3d9.dll`. Every backend experiment aimed
  at this game was aimed at a layer it does not use.

**The real bottleneck: the GAME'S OWN CODE, translated.** Two independent samples caught during
the Extreme Fever collapse (auto-triggered when fps dropped below 4) agree closely:

| | Fever #1 | Fever #2 |
|---|---|---|
| game's own translated code (`???`, `<unknown binary>`) | 93.7% | 91.1% |
| Rosetta Runtime Routines | 4.3% | 4.2% |
| OpenGL / ddraw / wined3d | ~0% | 0.4% |

**`ddraw_surface_update_frontbuffer` was a red herring, and the direction of causation was
backwards.** That counter measures the PRESENTATION RATE. It reads low because the game takes ~1 s
to produce a frame — it is the symptom, not the mechanism. A counter that goes down when things get
slow is not automatically where the time goes.

**The binary is overwhelmingly x87** (`objdump -d --triple=i386-pc-windows`):

```
total instructions : 661,894
x87 FP             :  29,944  (4.52%)   fdivrp, fabs, fstl, fsqrt, frndint …
SSE/MMX            :     411  (0.06%)
```

73x more x87 than SSE — the signature of a 2007 32-bit binary, and Rosetta emulates x87 in
software. Combined with ~92% of Fever time sitting in that translated code, x87 emulation is the
leading explanation. **It is still not causally proven**: proving it requires running the same
scene under an x87 acceleration hook (`x87sidecar` / `rosettax87`) and comparing fps. Until that
test is run, this is a well-evidenced hypothesis, not a finding.

⚠️ **Beware disassembly-counting scripts.** A first pass reported "0 x87 instructions" because it
took "the first alphabetic token" as the mnemonic — and hex byte pairs (`de`, `fa`, `ff`) match
that. objdump's format is `addr: bytes<TAB>mnemonic<TAB>operands`; split on TAB and read field 2.

**`MTL_HUD_ENABLED=1` draws nothing in a `winemac.drv` window.** Its absence was read as "the game
does not use Metal", which was wrong — the loaded binary images (`com.apple.Metal`, `AGXMetalG17G`)
prove otherwise. Check loaded images, not an overlay.

## ✅ Peggle SOLVED — old 2D games need the SOFTWARE renderer (2026-08-08)

**Measured: 17.8 fps → 90.1 fps mean** (max 100.5, n=363 during real play). Ship it via
**Configuration → "Old 2D game — software rendering"** (`BottleSettings.software2D`).

**Why it works, and why it is counter-intuitive.** Peggle issues **3,567 draw calls per frame** —
one 4-vertex quad per sprite, from a user-memory pointer, all sharing ONE vertex format and 92
textures. Each costs **~62,300 cycles** (a native draw is 1,000–3,000, so ~31x). The reason is
specific to macOS: wined3d must map a GL buffer per user-pointer draw, upstream fixed that with
persistent buffers (`ARB_buffer_storage`), and that extension needs **GL 4.4** while **Apple caps
OpenGL at 4.1** — verified here: `GL_VERSION: 4.1 Metal`, extension absent from all 43.

So the per-draw tax is unavoidable on a Mac. Software rendering does MORE pixel work but presents
**one surface per frame instead of 3,567 draws**, so it skips the tax entirely. At 10,000 cycles per
draw the game would have hit 112 fps; it never exceeded 30 in hardware mode.

**This is why old games suffer and modern ones do not.** Draw calls were cheap in 2007, so engines
spent them freely; modern engines batch because driver overhead became the limit. Translation
layers tax per-call overhead — punishing exactly what old games do most. Sekiro is smooth because
it makes hundreds of calls, not thousands.

### Implementation traps, all of which bit

- **Wine's per-app key is the right lever**: `HKCU\Software\Wine\AppDefaults\<exe>\Direct3D`
  → `renderer=no3d`. **NEVER prefix-wide** — Steam, Sekiro and JJBA share `Steam-Wine11`.
- **The resolved exe is a DRM WRAPPER.** Steam launches `Peggle.exe`, which unpacks and runs
  `C:\ProgramData\PopCap Games\Peggle\popcapgame1.exe` — and **the unpacked process is the one
  that renders**. An override on the wrapper does nothing. Worse, the wrapper DELETES the unpacked
  binary on exit, so a filesystem sweep finds it only while the game runs — i.e. never, when
  settings are applied. `popcapgame1.exe` is therefore added by name.
- **Bottles sharing a prefix fight over per-exe keys.** The first version swept for extra targets on
  BOTH the on and off paths, so a bottle with the setting OFF deleted the override another bottle
  had just written. Symptom: the key existed but was empty, with a newer timestamp than the write.
  Turning the setting off now touches only the executable that bottle itself resolves to.
- **A launcher bottle resolves no game** ("Steam: no game (launcher bottle)") — but that is exactly
  where an old 2D title gets launched from, so the logic must not be gated on resolving one.
- **`Is3D=0` in `HKCU\Software\Steam\Peggle` works identically** (it is the game's own setting)
  and logs cleaner — no `ddraw_texture_init` warnings. It is PopCap-specific, so the shipped fix
  uses the game-agnostic wine key. Both measured at ~100 fps on the menu.

### The setting must be applied ON LAUNCH — a button nobody presses is not a fix

Reported as *"he turned the 2D game thing on and it's still slow"*, and it was three faults, none
of them the user's:

1. **`applySoftware2D` was reachable only from `applyRegistry`** — i.e. only when you press
   **"Apply to Prefix"**. Toggle on, press Play, nothing written. Nothing in the UI says otherwise.
   Now `ensureSoftware2D` runs at the top of `launchGameApp` AND `launchSteam`.
2. **The generated `.app` bypasses Decanter entirely**, so no setting the app writes can reach it —
   and it is the obvious way to launch a game. The launcher now writes the key itself, every time.
   That also covers the shared-prefix hazard: another bottle turning the setting off clears the
   same key, and the next launch simply puts it back.
3. **`generatorVersion` must be bumped** (4 → 5) or every existing launcher stays stale and the
   fix reaches nobody who already has one. Same lesson as the Steam.dll fix.

⚠️ **Anything invoking `wine` in the generated script MUST come below the `export` lines.** The
first attempt put the `reg add` above them, so it ran with no `WINEPREFIX` and wrote into the
DEFAULT prefix — silently creating a **332 MB stray `~/.wine`** while the game's prefix was never
touched. The launcher logged *"software rendering applied"* and had changed nothing. Verified the
fix by wiping both keys, launching from the `.app` alone, and reading `user.reg` after the server
flushed: both targets `no3d`, Sekiro and JJBA untouched.

⚠️ **`reg query` lies while wineserver is running.** It reported both keys ABSENT immediately after
the launcher wrote them; they were present in `user.reg` once the server exited. Four wrong
readings in one session came from this. Kill the server, sleep, read the FILE.

### Play LAUNCHES; it does not build (removed at the user's request)

`launchGameApp` used to rebuild the bundle whenever it was missing **or stale**, so pressing Play
sometimes started the game and sometimes silently regenerated the launcher first — the click looked
like it did nothing. Reported as "it works very poorly" and removed. The launcher is created when
the BOTTLE is created; **Rebuild Launcher** on the Overview tab is the explicit refresh.

⚠️ **Trade-off, accepted deliberately after being raised twice:** a generated `.app` outlives the
Decanter that wrote it, so a future change to `launcherScript` will NOT reach a launcher that
already exists — the user must press Rebuild Launcher. That is precisely how the Steam.dll fix once
shipped and reached nobody, and how the `generatorVersion` stamp came to exist. **If launcher bugs
reappear right after an update, suspect a stale bundle first.**

Play now reports "No launcher app for this bottle yet" rather than opening a path that isn't there.

### A `@discardableResult` that is ALWAYS discarded is a swallowed error

Reported as "the auto app build doesn't seem to be working". Bottle creation did call
`buildGameApp`, but as `Task { await buildGameApp(for: bottle) }` — **the Result thrown away**. Every
failure (no engine, no resolvable game, unwritable `~/Applications`) produced a bottle with no
launcher and not one word anywhere, which is indistinguishable from the feature not existing.

`createBottle(named:for:)` now switches on the Result, sets `lastLauncherMessage`, and opens a
console on failure; `BottleDetailView` shows that message when there is no fresher one. The likely
real cause on someone else's Mac is `BuildError.noGame` — a bottle whose game cannot be resolved —
and that now says so instead of failing silently.

### Liquid Glass transparency: `.clear` + a scrim, not a variant swap

Apple ships `.clear` and `.regular` and **nothing in between**, so tuning by swapping variants
overshoots in whichever direction you move: `.clear` is unreadable over a busy wallpaper,
`.regular` is readable and too solid. Both were rejected in turn ("make it less see-through",
then "it needs to be a little more see-through").

`GlassPane` now uses `.clear` for its transparency and puts a faint adaptive fill under the
CONTENT — `scrim`, default **0.14**, where 0 is pure `.clear` and ~0.30 approaches `.regular`.
`windowBackgroundColor` so it follows light/dark. **Turn the dial; do not swap the variant.**

### ⚠️ Adding a field to `BottleSettings` USED to corrupt every existing install

Swift's **synthesized** decoder throws `keyNotFound` for a missing key on a non-optional property
**even when it has a default**. Adding `software2D` made 3 of 4 bottles undecodable instantly —
Decanter salvaged 1 and backed the rest up. The file was intact; the decoder was the problem. The
old workaround ("make new fields Optional") relied on every future author remembering.

`BottleSettings` now has a hand-written `init(from:)` using `decodeIfPresent` with defaults for
every field. **Add new fields freely — give them a default and decode them there.**

### Tooling notes from this hunt

- **Registry reads are stale until wineserver flushes.** `reg query` and `user.reg` both lied
  repeatedly right after a write, and a concurrently-running wineserver silently reverted a delete
  by flushing its own copy on exit. Kill the server, sleep, THEN read the file.
- **`reg delete /v` empties a key but leaves it present** — check for the VALUE, not the key.
- **`sample` cannot attribute per-thread CPU** (it ticks every thread, running or blocked) and under
  Rosetta a blocked thread's leaf is `???` like a busy one. Use `ps -M <pid>`.
- **Count draw calls with `WINEDEBUG=+ddraw`**, not a profiler: the sampler could not distinguish
  the game's code from wine's `ddraw.dll` (both are PE modules in the same JIT buffer, unsymbolized).
  The API trace settled in one command what sampling could not.

## Quitting the game now quits Steam — with a window for cloud saves (2026-08-12)

Quit the game and Decanter waits, lets Steam finish syncing, then shuts Steam and the whole prefix
down. **Measured end to end from the Play button: game quit 21:28:31 → Steam quit 21:29:10, 39 s
later, ending at `steam=0 game=0 wineserver=0`.** That is ~15 s confirming the game is really gone
plus a 25 s `cloudSyncGrace`.

**Why the grace period is not optional.** Steam Cloud uploads a game's saves when the game exits,
and `quitSteam` finishes with `wineserver -k` — not a polite request, it takes the prefix down.
Killing Steam early loses the sync silently, which is far worse than leaving Steam running. Steam
stays alive for the whole window, which is what makes the sync possible.

**`reapSteamAfterGame` already existed and was wired to ONE branch.** Only the direct-exe path
(JJBA) called it, so every game launched the normal way — `steam.exe -applaunch <id>`, i.e. Peggle,
Sekiro, Half Sword — left Steam running forever. That is the documented "Steam reopens / won't
quit" complaint, still half-unfixed. Now called from both paths.

Guards worth keeping: it only quits a Steam that **Decanter** started (checked BEFORE launching, or
the answer is always "yes" a moment later), and it backs off if the user starts using Steam during
the wait.

⚠️ **A stale reaper from an earlier launch will confuse timing measurements.** A first run showed
20 s, which does not match the design; the cause was a pending reaper from a previous launch in the
same session, not a logic error. Restart cleanly before timing this.

⚠️ **`isAnyGameRunning`'s allowlist gates all of this** (plus the engine switch and the systray
sweep). `steamservice.exe`, `gameoverlayui64.exe` and friends run ALONGSIDE a game and were absent
from it. Verified separately that Steam *alone* was already reported correctly — so this was not
the cause of the timing above, and the claim that it was should not have been made before testing.

## Review findings 1–3 (2026-08-12) — a label, a guard, and a picker that did nothing

**1. "Create & Play" never played.** `create()` called `createBottle(named:for:)` and returned; the
button's own label promised an action the code did not contain. Confirmed by creating a bottle and
counting processes: 0 game, 0 steam.exe. Now launches the bottle it just made. The same function
silently dismissed when a hand-picked exe sat outside any prefix — it says so instead.

**2. The double-click guard was defeated by its own preamble.** `launchSteam` opened with
`await ensureSoftware2D(…)` — a Wine subprocess, ~1 s — BEFORE the `launchingBottleIDs.contains`
check. Two clicks inside that window both saw an empty set and both launched. **Nothing may await
between the check and the `insert` that claims it**; on `@MainActor` that pair is then atomic.
Regression introduced by me when adding the software-2D call.

Play also never showed launching state: it was `.disabled(buildingApp)`, and `buildingApp` died
with the launcher generator and is never set true. It now reads `launchingBottleIDs` and says
"Opening…", which is what Launch Steam always did.

**3. The Graphics ▸ Backend picker was inert for 3 of its 4 options.** `settings.graphics` was read
only by the picker that set it and the label that echoed it; `installGraphicsDriver` installed DXMT
unconditionally. Picking DXVK installed DXMT. `BottleSettings` even claimed DXVK "is scoped
per-executable via AppDefaults" — **no such code ever existed**, a description of an intention left
reading as a description of behaviour.

Now: DXMT installs, **WineD3D removes** the per-game overrides (the absence IS the setting), and
DXVK/D3DMetal refuse with a reason — DXVK because the engine ships `d3d11`+`d3d10core` and **no
`dxgi.dll`**, and DXVK will not create a device without it ("Adapter is not a DXVK adapter",
observed here); D3DMetal because it belongs to CrossOver/GPTk, not Decanter's engine.

⚠️ **Per-bottle graphics settings must be SCOPED TO THE BOTTLE'S GAME.** `detectedSteamGames` lists
the whole PREFIX, and three bottles share `Steam-Wine11`. First cut had the Peggle bottle (WineD3D)
clearing all 4 games' overrides and the DXMT bottles re-adding all 4 on the next pass — the setting
appeared to do nothing while quietly fighting its neighbours. A bottle that resolves a game touches
only that game; a launcher bottle keeps prefix-wide behaviour.

⚠️ **`#"…\AppDefaults"# + exe` — MIND THE TRAILING BACKSLASH.** Written without it the key becomes
`…\AppDefaultsPeggle.exe\DllOverrides`, which does not exist, so every `reg delete` "succeeds"
against nothing. **This exact typo has now shipped twice**, both times introduced by a heredoc
eating the final backslash, both times invisible in review. Check the VALUES in `user.reg` after a
flush; never trust the command's exit status.

**Found while fixing 3, not yet fixed:** the DXMT path skips a game whose DLLs already match, and
that `continue` skips the override write too — so a game with patched DLLs but missing overrides
never gets them back.

## Review findings 4–6 (2026-08-12) — three swallowed results

**4. The setup wizard swallowed a Steam-install failure.** Steps 1–3 all set `failureMessage`;
step 4 was `_ = await model.performSteamInstall(…)`. A failed install ended the run with the step
simply unchecked and no reason anywhere — the user stares at a tick that never appears. Now checked
and reported, with "press the button again, anything already finished is skipped".

**5. A failed msync overlay reported SUCCESS.** `try? await installMsyncEngine()` then `phase =
.done`. The non-fatal choice is right — a working wine 11 engine beats no engine — but the user
silently received the **frame-spike engine that the overlay exists to avoid**, and only `--verify`
could tell. `WineInstaller` now publishes a `warning`, and the wizard shows it as an orange warning
triangle, distinct from the red failure octagon (it was yellow text until the 2026-11-02 HIG pass —
1.51:1, unreadable): the run finished, the result is just worse than intended. **Non-fatal must
still mean reported.**

**6. Rescan was silent in 2 of the 3 places it exists.** `rescanSummary()` had ONE caller
(Settings); the sidebar gear sheet and View ▸ Rescan (⇧⌘R) said nothing — the "users conclude the
button is dead" bug, fixed in a third of the places it occurs.

The fix is structural: **`rescanInstallations()` now publishes `lastRescanMessage` itself**, so no
call site — present or future — can forget to report. Settings reads that instead of keeping a
private copy, which is exactly how the three drifted apart. Verified live: the gear sheet now shows
"Found 5 Wine builds."

Menu commands have nowhere inline to put a result, so ⇧⌘R and **Import CrossOver Bottles** (which
threw away its `Int`, making it a total no-op on a Mac without CrossOver) now report through the
console sheet. `openConsole` had to stop being `private` for that — a detail worth keeping, since
"private" was quietly the reason menu actions could not talk to the user at all.

## Bug-sweep fix F4 — DXMT's "already installed" skip also skipped the override (2026-08-22)

**Invariant restored: I6 — a setting the UI reports as active IS active on disk.** Configuration
said "DXMT" for Peggle while the registry override was empty; the game was silently on WineD3D.

**Root cause:** `installGraphicsDriver`'s `if already { continue }` treated "DLLs already match"
and "override already correct" as one fact. They are two: WineD3D's branch (Configuration ▸
Graphics ▸ Backend) clears the registry override but never touches the DLL files, so switching a
bottle to WineD3D and back left DLLs matching (skip the copy — correct) while the override stayed
cleared (also skipped — wrong, and nothing else in the codebase ever re-asserts it).

**Reproduced live before fixing, not inferred:** ran `installGraphicsDriver` once to normalize
Peggle's DLLs to the bundled DXMT payload, ccleared its `AppDefaults\Peggle.exe\DllOverrides` key
by hand, re-ran the installer — DLLs matched (`already == true`), override stayed **absent**.

**Fix:** DLL-copying and override-writing are now independent steps inside the loop; skipping one
never skips the other. **Verified live after the fix**, override restored to
`['d3d10core', 'd3d11', 'dxgi']`, DLLs left untouched (copy still correctly skipped), and Sekiro/
JJBA's own overrides unchanged throughout — the per-bottle scoping from item 1 still holds.

**Cost trade-off, accepted deliberately:** the override is now unconditionally re-asserted
(`reg add`, a few subprocess spawns) on every call, even when nothing changed — this runs on every
Steam launch. Deliberately NOT guarded behind a `reg query` check: this project already learned
that `reg query` lies while wineserver is running (see "Peggle SOLVED" above), so an idempotent
unconditional re-assert is the established safer pattern (`disableSteamAutoStart` does the same).

**Not unit-tested — said plainly, not skipped quietly.** `installGraphicsDriver` does live
filesystem I/O and shells out to `wine reg add`; there is no dependency-injection seam for
`FileManager`/`Shell` in this codebase to mock against, so the fix is proven by the live
before/after reproduction above rather than a `PrefixSharingTests`-style pure test.

## Bug-sweep fix F6 — Play re-enabled after a flat 30s no matter what happened (2026-08-22)

**Invariant restored: `launchingBottleIDs` means "we don't yet know if this launch worked."** It
should clear the moment there's real evidence either way, and the user should be told when nothing
ever showed up. You can tell it holds by: a normal launch re-enabling Play well under 30s (the
first poll usually lands within a couple seconds), and a deliberately broken launch (bad
direct-exe path, or a Steam that never comes up) leaving Play disabled until the ceiling, then
showing a visible alert instead of silently re-enabling.

**Root cause:** both launch paths (direct-exe and `steam.exe -applaunch`) held the guard behind an
unconditional `Task.sleep(30s)` then cleared it — no early exit on success, no failure reported on
timeout. A launch that failed instantly and one that worked instantly looked identical: Play just
came back after 30s either way.

**Fix:** added `clearLaunchGuard(for:ceiling:success:)`, which polls `success()` immediately, then
every 2s up to the ceiling, clearing the guard the moment it returns true and publishing
`lastLaunchFailure` (surfaced via a new alert in `ContentView.swift`, same binding idiom as
`bottleSalvageWarning`) if the ceiling passes with nothing. Same poll-then-sleep shape as
`waitForSteamLogon`. Success signal per path: the direct-exe path checks for a process named after
the launched binary (`isProcessRunning(named:)`, same `comm=`-based match `isAnyGameRunning`
already uses — not the buggy `command=` form this codebase fixed once already); the applaunch path
checks `isSteamRunning()`. If Steam was already running before the call, that check is true on the
very first poll and the guard clears near-instantly — correct, not a regression: an already-running
Steam handles `-applaunch` almost immediately, and per-game process attribution through Steam isn't
built here (see `isAnyGameRunning`'s known imprecision below), so "Steam is up" is the best cheap
signal available for that path.

**Verified, with an honest limit on how:** the poll loop's own mechanics (early-exit on success,
ceiling on failure, no early exit before the ceiling) were verified by timing a standalone
transcription of the exact same loop shape, run outside the app: already-true → 0.00s,
true-after-~5s → 6.19s (next poll boundary, not the full 30s), never-true → 30.72s then stops. The
`ps`/`pgrep` process-detection calls were sanity-checked against live system state (no Wine
process running, native macOS Steam correctly does NOT false-positive `isSteamRunning()`'s
`/steam\.exe` pattern, since it has no `.exe` in its path). **Not live-tested end-to-end through an
actual bottle launch** — the direct-exe path's Steam-bootstrap branch alone waits up to 150s
(`waitForSteamLogon`), and exercising it needs a bottle with Steam not already running; doing that
against any of the real bottles risked exactly the kind of live-prefix disruption ruled out for
this pass. Left unproven rather than forced.

## Bug-sweep fix F7 — the auto-quit reaper could wait forever (2026-08-22)

**Invariant restored: the reaper always eventually finishes and releases its guard**, and if it
gives up, that's recorded somewhere instead of silently leaving Steam open forever with no trace.
You can tell it holds by: the reaper task actually completing — not leaking — even when another
bottle's game runs indefinitely, and a console line naming why it stopped without quitting Steam.

**Root cause:** `reapSteamAfterGame`'s phase 2 (`while clearStreak < 3`) had no ceiling.
`isAnyGameRunning()` is global, not per-prefix (same limitation flagged in the F1+F2+F8 write-up
below), so a game running indefinitely in an unrelated bottle held this loop open forever. Because
the whole `Task` never returned, the `defer { reapingBottleIDs.remove(bottle.id) }` at the top
never ran either — `reapingBottleIDs` for that bottle stayed set for the rest of the session, and
a launch of that same bottle that legitimately started Steam again (`weStartedSteam`) would find
`reapingBottleIDs.contains(bottle.id)` already true and skip starting a fresh reaper for it.

**Fix:** the loop now also exits once `elapsed >= giveUpAfter` (3600s / 1h — generous, so a
genuinely long session in another bottle isn't cut short). On give-up it logs which bottle, how
long it waited, and why (another game still reported running elsewhere), then returns without
calling `quitSteam` — giving up must not risk killing something that might still matter, same
"over-cautious is the safe direction" rule item 1 established for `quitSteamBlockReason`.
`reapingBottleIDs` clearing is not a separate fix: it was always driven by the `defer`, and now
that the `Task` is guaranteed to return, the `defer` is guaranteed to run.

**Does this let `isAnyGameRunning()` be tightened?** No — checked directly. F7 only bounds how
long phase 2 waits; it does nothing to give the check per-prefix attribution, which still needs a
PID→WINEPREFIX mapping this codebase deliberately does not build (see the F1+F2+F8 write-up).
Saying so plainly rather than implying otherwise: the existing "spotted, not fixed" entry for
`isAnyGameRunning()`'s imprecision stands unchanged.

**Verified via a standalone timing transcription of the same loop shape** (parameterized to run in
seconds instead of an hour, same reasoning as F6's poll-loop check): a normal 3-consecutive-clear
convergence lands at ~3s; a poll that never goes clear correctly gives up at the ceiling instead of
spinning forever (8.37s against an 8s test ceiling — this is the exact case that hung before the
fix); a flaky poll (running twice, then clear) correctly resets the streak rather than just
counting total clear polls, converging at ~5s as expected. **Not exercised through an actual
reaper run against a real bottle** — doing that means either waiting out the real hour-long
ceiling or actually running a game to reap, and the loop-mechanics check above already proves the
part that changed; the parts that didn't change (phase 1, phase 3's cloud-sync grace, phase 4) are
untouched by this fix.

## Bug-sweep fix F18 — the delete guard used the comparator PrefixSharing exists to replace (2026-08-23)

**Invariant restored: deleting a bottle's files never touches a prefix another bottle still
uses**, on this filesystem's actual case rules, not an idealized case-sensitive one.

**Root cause:** `deleteBottle`'s "is this prefix still referenced by another bottle" check compared
`.standardizedFileURL ==` directly — case-SENSITIVE. APFS is case-insensitive by default, so two
bottles whose stored `url` differed only in case (plausible for an imported CrossOver bottle) would
both resolve to the SAME real directory while comparing as unequal. The guard would then delete a
prefix a sibling bottle still used — on this machine, `Steam-Wine11`, 25 GB, four bottles, real save
data, via `try?`, which wouldn't even report what happened. `PrefixSharing` exists specifically to
be the one place that answers "which bottles share this prefix" (see F1+F2+F8 above); this was a
second, less correct opinion answering the same question.

**Fix:** `stillReferenced` now uses `!PrefixSharing.group(of: bottle, in: bottles).isEmpty`. `bottle`
is already removed from `bottles` by this point in the function, so `group` (not `others`) is
correct — anything it still finds is necessarily a different bottle. A lesser instance of the same
gap, `addImportedBottle`'s duplicate-import check (raw `URL ==`, not even standardized), got the
same comparator — lower stakes there (a spurious duplicate bottle, not data loss).

**Verified via a unit test, deliberately not a live bottle** — the failure mode being fixed is
deleting a real, possibly multi-GB prefix, which is not something to reproduce for real.
`testDeleteGuardCatchesACaseDifferingSiblingOnTheSamePrefix` pins the exact expression the guard now
uses against two bottles differing only by case; `testDeleteGuardAllowsDeletionWhenNoSiblingRemains`
pins the negative case. Both pass. The underlying case-folding mechanism itself was already proven
in `testCaseIsFoldedForTheDefaultCaseInsensitiveVolume` (F1+F2+F8, above) — reverting `key(for:)` to
bare `url.path` was shown to make that the one test that fails.

**This bug class shipped a THIRD time (F24, 2026-08-25), in code written the same day as F18** —
`OrphanReclaim`'s reclaim-candidate filter, the one function whose entire output is a delete list.
Same root cause each time: `PrefixSharing.key(for:)` takes a full `URL`, so a call site holding a
bare directory NAME (not a URL) doesn't look like it applies, and reaches for raw string equality
instead. Closed by adding `PrefixSharing.nameKey(_:)` — the name-level counterpart, literally
`.lowercased()` — so a bare-name call site has an obvious canonical form to reach for instead of
rolling its own. If a fourth instance shows up, it should mean someone skipped `nameKey`, not that
another one needs writing.

## F10 — closed as WONTFIX (2026-08-23)

F10 (low severity): `installGraphicsDriver` unconditionally re-asserts the DXMT registry override
on every Steam launch, even when nothing changed — a few subprocess spawns' worth of cost per
launch. The obvious-looking optimization is "skip the write when the current registry state
already matches." **Deliberately not built.** Checking "does it already match" means reading the
registry via `reg query`, and this project already proved `reg query` lies while wineserver is
running (see the DXMT/Peggle history above). A stale "already matches" read would skip the write,
leaving the override absent on disk while the UI still reports DXMT active — that is F4, the bug
this same fix pass already found and fixed, reintroduced by the optimization meant to speed it up.

The few seconds per launch buy a real guarantee: the override the UI claims is active IS active on
disk, every time, without depending on a `reg query` this project can't trust. Not worth trading
away for a launch-time saving nobody has measured as a problem.

## Spotted, not fixed — running list from the bug-sweep fix pass (2026-08-22)

Things noticed while fixing an item on the list, deliberately NOT fixed because they weren't the
item asked for. Add to this list rather than fixing inline; work them only when asked.

- ✅ **FIXED (2026-08-29, pre-release debug plan Phase 5 re-triage).** ~~Software-2D's OFF path
  never targets `popcapgame1.exe`.~~ This list was stale — the fix had already landed during the
  same debug plan's Phase 0 bug-sweep pass and was never removed here. `applySoftware2D`'s OFF
  branch now handles `popcapgame1.exe` symmetrically with the ON path, conservatively: it clears
  the override only when no OTHER bottle sharing the prefix still has software2D on. See the doc
  comment at the call site in `AppModel.swift` for the full reasoning.
- **`quitSteamBlockReason` over-blocks on unrelated-prefix activity.** It can only ask "is ANY game
  running on the whole machine" (`isAnyGameRunning()` — `ps -Ao comm=`, no WINEPREFIX attribution
  anywhere in this codebase), not "is a game running in a bottle that shares THIS prefix". Concrete
  case: Half Sword (its own separate prefix) is playing, `Steam-Wine11` is idle — Quit Steam on the
  Peggle bottle still refuses, naming Sekiro/JJBA/Steam as at risk when none of them are doing
  anything. Deliberately left as the safe direction (over-block, never under-block) rather than
  built around — real per-prefix attribution needs mapping a PID to its WINEPREFIX, which nothing
  here does and `ps` alone can't give without walking process environments, the exact class of
  guess that has bitten this project three times already (comm-path splitting, the systray sweep,
  the helper allowlist). See the comment at the `isAnyGameRunning()` call site in
  `quitSteamBlockReason` for the same note in context.

  **Re-investigated, not just re-stated, 2026-08-23** when this item was released from the
  deferred list: tried `lsof +D <prefix path>` as a legitimate, non-guessing alternative to
  walking process environments — directory-scoped open-file-handle enumeration, not comm-path
  parsing. Result: unreliable even for a KNOWN currently-running Decanter process (22.5h uptime,
  confirmed alive via `ps`) — `lsof +D` scoped to the whole Application Support tree found zero
  open handles for it. Building safety-critical "is it safe to kill this" logic on a technique
  that misses a process known to be running would be worse than the current over-block. The
  constraint is confirmed unchanged, not assumed unchanged — still closed as WONTFIX, same
  reasoning as F10.

## Bug-sweep fix F27 — cold-boot Play looked broken because the guard released too early, not
because the launch failed (2026-08-25)

**Invariant restored: `launchingBottleIDs` reflects reality** — Play re-enables when Steam is
actually ready to receive input, not the instant its process merely exists.

Reported directly by Jack, in his own words: *"when I try and play peggle I'll click play and it
won't work and then when the button turns blue again when I click it peggle loads."* Peggle carries
`-applaunch`, so it takes the game-launcher branch (`AppModel.swift`, the `steamArgs`/`args` block).

**This item went through two diagnoses. The first one was wrong, shipped a regression Jack hit
directly, and is recorded below deliberately — not edited away — because the failure mode is worth
keeping.**

### First diagnosis (WRONG) — "the cold-boot applaunch gets dropped"

The claim: `-applaunch` fired once during Steam's cold bootstrap is consumed/lost before the client
is ready, so the game never starts on click 1; click 2 works because it re-delivers the command to
a now-logged-in Steam. The "fix": wait for logon, then re-issue the identical `launchQuietly` call.

This looked well-supported. Steam's own `console_log.txt` was checked directly (not taken on
faith) and showed a real, total correlation: every historical applaunch-bearing `ExecCommandLine`
in the log was immediately followed by `GameAction LaunchApp`, including two click-pairs seconds
apart. That is real data. **The causal story built on top of it was wrong anyway** — a plausible
narrative fitted to genuine data is still not verified, and this project has hit that exact trap
before (the Aug-8 corrupt-file provenance error earlier in this file is the same shape). The
correlation was consistent with "cold boot silently drops the applaunch, second click delivers it"
AND equally consistent with "cold boot delivers the applaunch fine on its own, second click just
landed during the ~35s window and the log shows two deliveries" — the log alone could not
distinguish these, and the first explanation was accepted without ruling out the second.

**Jack ran the fix cold and hit a new failure**: Peggle opened "missing its steam interface."
`console_log.txt` from that run showed why — the FIRST `ExecCommandLine` (Steam processing its own
command line ~2s after logon) drove the complete `GameAction` sequence through `CreatingProcess` on
its own. The applaunch was never dropped. Then, ~4 seconds later, mid-`CreatingProcess`, the
re-issued `launchQuietly` call landed — and instead of forwarding to the running client the way a
click against an IDLE client does, it started a SECOND FULL Steam client (`Client version` /
`Loaded SDL` / `ComputeStartupMode` appear again in the log) that collided with the in-flight
launch. The sequence never reached `Completed`.

### Second diagnosis (verified against the collision log) — "the guard released before Steam was
ready, so Jack clicked again mid-boot, and now the fix's own retry can land mid-launch and break it"

The applaunch is not dropped, only *delayed* — a cold boot takes ~30-40s to reach the point where
Steam processes its own command line and starts the game unassisted. The only real bug was ever
`clearLaunchGuard`, which checked `isSteamRunning()` — true the instant the process exists, long
before logon — so Play re-enabled after ~2s and told Jack the launch was done while Steam was still
deep in a cold boot. Clicking again during that window is what looked like "needed two clicks";
the original click was already going to work on its own, given time. The 17 historical successful
re-deliveries cited as evidence the retry was "safe" were ALL against an idle, already-started
client — landing mid-launch, as the collision proved, is a different situation entirely, and citing
them as proof of safety was itself part of the same over-fitted narrative.

**Fix, corrected: wait for logon, and do nothing else.**

```swift
if isGameLauncher, startedSteamForGame {
    _ = await waitForSteamLogon(in: bottle, timeout: 150)
}
```

No re-issue. Steam handles the actual launch once it's logged in; the guard now simply holds until
that point instead of releasing early and inviting a second click that can land at the worst
possible moment.

**Status:** the corrected fix is code-verified (build clean, 27/27 tests) and grounded in the
collision log from Jack's own failed test — but the post-fix behavior (does a single cold-boot
click now work end to end) still needs Jack's own retest, same as before. Nothing from the prefix
was left running after his test.

**The lesson, stated plainly rather than just fixed and moved past**: a total correlation in real
log data is not the same as a verified causal mechanism. The first diagnosis was falsifiable — "does
Steam drive its own command line to completion after logon, or not" — and that question was never
actually asked before a fix shipped on top of it. Ask the falsifying question before writing the
fix, not after a live regression forces it.

### "Had to click twice" — four separate causes, so far

Same visible symptom, four unrelated root causes found across this project's history. Worth reading
this list before re-diagnosing one that's already been found:

1. **The console sheet popped over Decanter** on every launch, making the first click look like a
   no-op even though it worked (see "Verification habits" era fix — game/Steam launches run quiet now).
2. **Steam's `-silent` flag hides its own window** on a launcher bottle, same "looks like nothing
   happened" effect — restricted to per-game bottles that also pass `-applaunch`.
3. **Play used to rebuild the (now-removed) generated launcher** whenever it was missing or stale,
   so a click sometimes launched the game and sometimes silently regenerated a bundle first — see
   "Play LAUNCHES; it does not build" above. Historical: the whole generator is gone.
4. **F27, above** — a cold Steam eats the first `-applaunch` before it can be serviced, and the
   guard cleared on process-existence rather than logon, so the button looked ready before Steam was.

## Verification habits that mattered

- **Screenshots beat logs.** `screencapture -x` + Read. Logs said "0 errors" while the screen was
  a black rectangle. Terminal has Screen Recording permission; it does **not** have Accessibility,
  so `System Events` reports **0 windows** for wine processes and cannot click/fullscreen them.
- Wine windows are their own macOS Space in fullscreen — a plain screenshot catches the wrong Space.
  Raise the wine process first (`System Events` → `set frontmost`), then capture.
- Long-running launches must use `run_in_background: true`. A foreground command's timeout
  **SIGTERMs the whole process group** and killed a Steam download at 90%.

## Warm-start Steam on bottle selection (2026-08-26)

**Product fix, not a bug fix**: cold Steam login on this machine measures ~30-40s (see the "cold
launch" investigation below); a WARM launch — Steam already up and logged in — measures ~3s
(`console_log.txt`: applaunch at 21:15:07-ish → `GameAction ... Completed` within seconds). Rather
than make the cold path faster, Steam now starts in the background the moment the user SELECTS a
game-launcher bottle in the sidebar, so by the time they actually press Play it's usually already
warm.

**`selectedBottleID` is not a safe trigger on its own.** It's `@Published` and reassigned
programmatically in several places that are not user intent — after a bottle is deleted, after one
is created, after a CrossOver import. A naive `.onChange(of: selectedBottleID)` would warm-start
Steam right after a delete reassigns selection to whatever bottle is now first in the list. Fixed
by routing the sidebar's `List(selection:)` binding through a new `userSelectedBottle(_:)` entry
point (`ContentView.swift`) instead of binding directly to the property — the programmatic
assignments elsewhere are untouched and never call it.

**Design, each point answering a specific failure mode:**
- Scoped to `isGameLauncher` bottles only (`steamArguments` contains `-applaunch`) — a plain
  launcher bottle or a direct-exe bottle gets nothing warmed.
- No-op if Steam is already running. Never starts a second client — see F27 below for exactly what
  that collision looks like.
- Keyed on the PREFIX (`PrefixSharing.key(for:)`), not the bottle — four bottles share
  `Steam-Wine11` here, and one warm Steam serves all of them.
- Debounced 400ms before committing to a boot, and the debounce timer is cancelled outright by the
  next selection — arrow-keying through the sidebar must not spawn a warm-start per row.
- `launchSteam` JOINS an in-flight warm-start for the same prefix (`await warmStartTasks[key]?.value`)
  rather than independently sampling `isSteamRunning()`, which could catch Steam mid-launch and
  start a second client on top of it — the exact F27 regression, by a different trigger.
- Reaping ownership transfers correctly: a warm-start that successfully logs on marks the prefix in
  `warmStartedPrefixKeys`, and the first real `launchSteam` call for that prefix consumes
  (removes) it, folding it into `startedSteamForGame` so `reapSteamAfterGame` still runs once the
  game actually exits. Kept deliberately SEPARATE from the cold-boot logon-wait condition — a
  warm-started Steam is already logged on, so re-running `waitForSteamLogon` for it would wait out
  the full 150s timeout for a "Logged On," line that will never come again, since Steam only logs
  on once.
- No auto-warm on app launch — selection-triggered only, exactly as scoped.

**Verified `observed`, fully automated, no manual steps** (Jack is hands-off; three earlier "still
slow" reports elsewhere turned out to be measuring an unchanged config because a manual step never
actually ran, so this was not repeated). Added `--warm-start-test "<bottle name>"`, a headless flag
that calls the SAME `userSelectedBottle` entry point the sidebar calls, then polls for completion —
same pattern as every other headless hook in this dispatch. Run cold, from a verified-empty prefix
(`ps` showed zero wine/steam processes beforehand): `warmed=true steamRunning=true` in 43.97s.
Independently confirmed against `connection_log.txt` (not just the tool's own self-report) — a
genuine new `LogOn() called` → `Logged On` sequence appears exactly inside that window, and
`console_log.txt` shows Steam running with the warm-start's own flags (`-silent -no-cef-sandbox
-skipinitialbootstrap`, no `-applaunch`) and no `GameAction`/`LaunchApp` anywhere — confirming the
warm-start brings Steam up WITHOUT launching the game, as designed. Cleaned up afterward via the
app's own `--quit-steam`; confirmed zero wine/steam processes remained. `bottles.json` untouched
(still the same 5 bottles). Build clean, 27/27 tests throughout.

**Not yet observed**: whether pressing Play *after* a completed warm-start actually launches in
~3s rather than ~30s end-to-end through the real GUI — the automated test above proves the
warm-start mechanism itself works, not the full selection-then-Play sequence a real user
experiences. No UI automation was available to drive that last step.

## Investigation — the cold-boot 20.0s stall (2026-08-26, findings only, nothing changed)

Cold Steam login on this machine measures ~30-40s; warm (already logged on) measures ~3s. The gap
sits in a specific, exactly-repeating stall between two `CCMInterface::SetSteamID` lines in
`connection_log.txt`, immediately before `LogOn() called`. **Measured at exactly 20.0s across
FIVE separate cold-boot runs** (independently reproduced during this investigation, on top of the
runs already on record before it):

```
[…20:57:03] SetSteamID […]
[…20:57:23] SetSteamID […]     <- 20.0s, every time
[…20:57:23] LogOn() called; not connected yet, scheduling connection.
[…20:57:25] Logged On
```

A delay identical to the second across independent runs is a **timeout**, not variable work — that
much was already established before this pass. What this pass adds:

**LEAD RULED OUT, with direct evidence, not just re-tested:** `cef_log.txt` shows
`WSALookupServiceBegin failed with: 8` / error 10045 (`WSAEOPNOTSUPP`) near the same time window,
and `GAMING-STACK.md` independently documents `WSAEOPNOTSUPP` sockets in this prefix — a plausible
lead. Traced the REAL `steam.exe` launch (bottle's actual `Wine.environment`, not a scratch prefix)
with `WINEDEBUG=+winsock`, output timestamped on arrival so a stall would show as a gap in when
trace chunks arrive. Result: **no gap anywhere** — 20,563 chunks over 54s, largest inter-chunk gap
4.78s. `WSALookupServiceBeginW` does appear, but at only 3-4s into the run (nowhere near the stall
window) and is logged `fixme:winsock:WSALookupServiceBeginW (...) Stub!` — Wine's implementation is
an unimplemented stub that fails INSTANTLY, not a call that blocks for 20s. The correlation in
`cef_log.txt` was real; the causal story built on it was not — same shape of mistake as F27's first
diagnosis above, caught this time before anything was built on it rather than after.

**Escalated to `+ntdll` per the original plan** (winsock was inconclusive, not confirmatory).
Same result: no gap — 10,300 chunks over 55s, largest gap 1.0s. **Steam is actively making syscalls
throughout the entire 20-second window, in both traced subsystems.** This is itself a finding: the
stall is not a blocked/silent wait on anything winsock- or ntdll-level exposes — something is
actively running (or spinning) for 20 seconds, not waiting on a timer.

**New candidate, not confirmed**: the dominant pattern in the stall window (33-53s into the traced
run) is several hundred `RtlRbInsertNodeEx` calls (building an ordered tree) interleaved with
dozens of `RtlGUIDFromString` calls, `RtlCreateAcl`, and `NtQuerySystemInformation` — immediately
preceded by a `wined3d_guess_card_vendor` line. This shape (GUID-keyed entries being inserted into
a tree, at volume) is characteristic of enumerating a registry-based device/driver list — plausibly
DirectInput/XInput controller enumeration, though **this is inferred from the call pattern, not
confirmed against Steam's or Wine's source** — `WINEDEBUG` traces carry no symbols or call stack,
so the exact high-level Windows API responsible cannot be named with certainty from this alone.
`find_reg_tz_info`/`get_timezone_info` also appear heavily (438 calls) in the same window, a second
candidate not yet distinguished from the first.

**Nothing changed based on any of this**, per the investigation's own scope. Both traces (`+winsock`
raw dump, `+ntdll` raw dump, plus a timestamped variant of each) were captured to scratch files
during this session; the temporary `--trace-steam-launch` diagnostic used to produce them has been
removed from `AppModel.swift` as originally scoped — investigate-only, not a permanent hook. Steam
was quit cleanly (`--quit-steam`) after every run; `bottles.json` and the prefix were left exactly
as found each time.


## Settings-parity audit — external fixes brought into the app (2026-08-29)

Jack asked directly: are the individual settings that make his games actually work captured in
Decanter itself, or only in external fixes/shells applied to the game files? Worth asking — the
answer was **mostly yes, with four real exceptions**, all now fixed.

**Method**: compared what the two hand-tuned external launchers (`~/Applications/Sekiro.app`,
`JJBA All-Star Battle.app`) actually set/write against what Decanter's own Play button does for
the same bottles, line by line — not from memory, by reading both directly and diffing.

**Already fully correct, confirmed not assumed**: the patched DXMT DLLs that fix the 26s stall
(`docs/GAMING-STACK.md`'s "Sekiro stall cause SOLVED") are **byte-identical** (SHA-256) between
the real game folder and Decanter's own bundled `Resources/DXMT` — the actual root-cause fix was
never external, only its supporting config was.

**Four real gaps found and fixed:**

1. **`DXMT_CONFIG` was missing two validated keys** — `sampleNaNToZero`, `defuseFma` — present in
   both external launchers, absent from `BottleSettings.derivedEnvironment`. Added unconditionally.
2. **`metalFXFactor` defaulted to 2.0**; both external launchers use 1.5, arrived at through real
   measurement in `sekiro-launcher.sh`'s own history (2.0 tested and reverted — 100% GPU load
   pegged vs 36% at 1.5, similar frame rate; 1.5 is the only config ever observed completely
   stall-free, 0/30.9 min). Fixed the default AND migrated the real `bottles.json` (all 5 bottles).
3. **Borderless-fullscreen had NO code path at all.** Sekiro's actual display depends on a per-app
   Wine virtual desktop (`HKCU\...\AppDefaults\sekiro.exe\Explorer`,
   `HKCU\...\Explorer\Desktops`) that only existed because a one-time external script left it in
   the shared prefix's registry — confirmed by reading `user.reg` directly before touching
   anything. New `borderlessFullscreen` setting + `AppModel.applyBorderlessFullscreen`, applied
   fresh on every launch (same "apply on launch, not a button nobody presses" pattern as
   `applySoftware2D`). Deliberately skips the external launcher's `wineserver -k` — that kills
   every wine process in the shared `Steam-Wine11` prefix, which three other bottles depend on.
4. **Sekiro's OWN `GraphicsConfig.xml` (in `AppData/Roaming/Sekiro/`) can silently reset the fix
   above** if its `Auto-detectBestRenderingSettings` is left on — also only ever patched by hand.
   `patchSekiroGraphicsConfig`, Sekiro-specific on purpose (that game's own config path/schema,
   not a generic Wine mechanism). UTF-16LE, no BOM — verified with a standalone round-trip
   decode/re-encode (byte-identical) against the REAL file before writing any code against it.

**Not changed, and why**: the external launchers `exec` the game binary directly for a single,
correctly-iconed Dock tile; Decanter's Sekiro bottle still goes through `steam.exe -applaunch`.
Cosmetic (generic Dock icon vs Sekiro's own), not functional — confirmed live in Phase 3 that the
game launches correctly either way. Switching to direct-exe would change Sekiro's Steam
integration (achievements, overlay) for a Dock-icon fix; left as a known, minor difference.

**Verified live, every fix, against the real install** — not just built and assumed: `--play-test`
against the real Sekiro bottle after each change, `sekiro.exe` confirmed genuinely running via
`ps`, `user.reg` and `GraphicsConfig.xml` read directly afterward to confirm the actual on-disk
state, not inferred from exit codes alone.

JJBA was NOT given `borderlessFullscreen` — its own external launcher never sets that registry,
meaning it doesn't need it; enabling it there would be an unvalidated change, unlike the other
three fixes which all trace to something a real, working external setup already proved.

### Fifth gap, found checking the remaining games (2026-08-29) — Half Sword had no external
launcher, so this one was found by reading Decanter's own code against the real prefix directly,
not by diffing against a working reference. Worse than "wrong exe targeted": `installGraphicsDriver`
was a complete NO-OP for this bottle, silently, on every single launch. Root cause:
`detectedSteamGames` scans ONE level deep; `resolvedGame` (GameScanner's `largestExecutable`)
searches several levels down. Half Sword is Unreal Engine — real binary nested at
`HalfSwordUE5/Binaries/Win64/HalfSwordUE5-Win64-Shipping.exe`, a tiny `HalfSwordUE5.exe` redirector
at the top (what Steam actually launches) — so the two functions report different exe names for
the same game, and `installGraphicsDriver`'s scoping filter silently returned an EMPTY set. Fixed
with a fallback (use `resolvedGame`'s own folder+exe when the filter finds nothing) plus
`AppModel.unrealRedirectorTarget`, a general (not Half-Sword-specific) helper that finds the
top-level redirector for any game following this extremely common Unreal packaging layout, so
DXMT's DLLs/override land beside the process that actually makes the Direct3D calls.

Verification itself hit a real gotcha worth keeping: the first live test showed no change at all,
which looked like the fix hadn't worked. It had — a Steam session left running from EARLIER,
UNRELATED testing (a different bottle) made the already-known-global `isSteamRunning()` short-
circuit Half Sword's launch before it ever reached `installGraphicsDriver`. Stopping that Steam
session and re-testing clean showed the real effect: fresh DXMT DLLs in the nested folder, a new
registry entry for the real binary, and the already-correct redirector entry left untouched.

Peggle and Sekiro/JJBA were checked too and don't have this bug — all three have their real exe
directly in the game's top-level folder, no nested Unreal-style Win64 folder to mismatch against.
Half Sword is the one Unreal Engine title in the library; this fix generalizes to any future one.

## "Windows Steam isn't closing" — cross-generation orphans, and `quitSteam` finally says why (2026-09-01)

Reported directly, live: **"windows steam isn't closing"**. `--quit-steam` stopped the main
`steam.exe` process but left `winedevice.exe` and `steamservice.exe` behind — one of which ignored
`SIGTERM` outright. `shutdownPrefix`'s straggler sweep was `argv`-matching against `ps` output,
which only ever worked for processes whose command line happened to contain the macOS prefix
path. Most Wine helper processes (`winedevice.exe`, `explorer.exe`, `steamservice.exe`, an orphaned
`steamwebhelper.exe`) report only their **Windows** command line, so `argv` never contains the
macOS path an `argv`-matching sweep needs — invisible to the old sweep by construction, not by bad
luck.

Worse than a blind spot in the sweep: `wineserver -k` only reaps processes tracked by the
**current** wineserver generation. A straggler left behind by an **earlier** wineserver (already
exited) is invisible to a fresh `wineserver -k` too, and outlives every "shut this prefix down"
attempt that assumes one live wineserver is the whole story. That is the actual mechanism behind
"Steam won't quit" — not a failure of `wineserver -k` itself (confirmed live: called with the
correct `WINEPREFIX`, it DOES fully reap its own generation's children), but same-prefix stragglers
from a wineserver generation that no longer exists to own them.

Root-caused with `lsof -p <pid>`, which asks a SPECIFIC process what files it has open rather than
guessing from `argv` — a different, more reliable operation than `lsof +D <prefix>` (tried once
before, in the investigation that closed `quitSteamBlockReason`'s over-block as WONTFIX, and found
to miss a process known to be running: scanning a directory for open handles is not the same
operation as interrogating a process directly). Before writing anything that kills a process based
on this, verified `lsof -p` attribution against 11 real processes across TWO SIMULTANEOUSLY running
prefixes: zero misses, zero false matches, including every class the old sweep couldn't see.

**The fix** — `processesBelongingToPrefix(_:)` (`AppModel.swift`) replaces the `argv`-matching
sweep: scopes to Wine-shaped candidates first (a Windows-style command line, or a known Wine binary
name) so it never runs `lsof` against every process on the Mac, then confirms each candidate via
`lsof -p` against the prefix path. `terminateThenKillIfNeeded(_:)` sends `SIGTERM`, waits a 2s grace
period, then `SIGKILL`s whatever ignored it — the same escalation shape `Shell.run`'s own timeout
handling already used, and directly informed by `steamservice.exe` ignoring `SIGTERM` in the
original live report.

`quitSteam(in:)` used to return a bare `Bool` — a failure said nothing about what was still alive,
so the user's only recourse was "try again, or restart your Mac" regardless of cause. It now
populates `@Published var lastQuitSteamFailure: String?` (`[DEC-E09]`-tagged) on failure, reusing
`processesBelongingToPrefix` a second time, scoped to the bottle's own prefix, to name exactly what
survived — or, if nothing survived locally, to note that Steam is running in a *different* bottle's
prefix, since `isSteamRunning()` is a global `ps` check (see `quitSteamBlockReason`'s doc comment).
Surfaced in `BottleDetailView`'s Quit Steam confirmation result and in `--quit-steam`'s per-bottle
CLI output.

**Live-verified end to end**, not just built: launched Steam for real in the `Steam-Wine11` prefix
via `--play-test`, confirmed `lsof -p` scoping against both `steam.exe` and `wineserver` before
touching anything, ran `--quit-steam`, and confirmed every bottle reported `stopped` with a clean
`ps` sweep afterward — zero Wine/Steam processes left running, zero stragglers. Full 54-test suite
passes; app bundle rebuilt via `Scripts/make_app.sh`.

## Hardening plan Phase 2 — characterization tests for the chokepoints (2026-09-01)

`Wine.environment` (12 call sites — every launch, every registry write) and `BottleSettings.derivedEnvironment`
had **zero** direct tests before this, despite being the exact function whose missing keys
(`sampleNaNToZero`, `defuseFma`) went unnoticed for weeks until the 2026-08-29 settings-parity
audit caught them by hand, and the exact function whose F14 regression (a prefix-wide
`WINEDLLOVERRIDES` leaking onto sibling bottles through Steam's inherited environment) shipped
unnoticed too. These are **characterization tests**, not new behavior specs — the goal is pinning
what these functions already do (each line expensively learned, several from a live game session)
so the next change that alters output has to do so on purpose, not by accident.

- [`BottleSettingsEnvironmentTests.swift`](Tests/DecanterTests/BottleSettingsEnvironmentTests.swift)
  (15 tests) — pins `derivedEnvironment` key-by-key for every `SyncMode` and every
  `GraphicsBackend`, including the exact `DXMT_CONFIG` string, and asserts `WINEDLLOVERRIDES` is
  never set for ANY backend (F14 as a permanent guard, not just a comment). Pure value type, no I/O.
- [`WineEnvironmentTests.swift`](Tests/DecanterTests/WineEnvironmentTests.swift) (13 tests) — pins
  `Wine.environment`'s own contribution: `WINEPREFIX`/`WINELOADER`/`WINESERVER` vs. the CrossOver
  `CX_ROOT`/`CX_BOTTLE` branch, `PATH` prepending, the conditional `DYLD_FALLBACK_LIBRARY_PATH`,
  the shader-cache directory actually getting created on disk, `WINEDEBUG` toggling, and the
  fast-sync stripping that runs — found worth pinning explicitly — **after** `derivedEnvironment`
  is merged in, so it can strip even a user-supplied override. Runs against a scratch
  `DECANTER_HOME` per test (`PathsTests`' pattern), never the real install.
- [`ShellTests.swift`](Tests/DecanterTests/ShellTests.swift) gained the three gaps the plan called
  out: a pipe-buffer deadlock proof (5 MB through a 64 KB kernel pipe buffer, confirming the
  async-`readabilityHandler` drain doesn't wedge the way a naive blocking read would), a
  non-existent-executable case (must fail immediately, not silently fall through to the 30s
  timeout), and `currentDirectory` actually reaching the child process — for both `Shell.run` AND
  `Shell.stream` separately, since they build their own `Process` independently and a fix to one
  proves nothing about the other. `currentDirectory` was new as of the pre-release debug plan's
  Phase 3 (the JJBA config-file-in-the-wrong-place bug) and had never been tested at all.

All 32 new tests passed on the first run — the point of a characterization test is that it should,
if it's actually describing what the code already does. 86/86 total, full suite. No production
code changed in this phase; `Shell.run`, `Shell.stream`, `Wine.environment` and
`BottleSettings.derivedEnvironment` are unmodified from before.

## Second settings-parity audit — three features ported from Sekiro.app/JJBA into Decanter itself (2026-09-01)

Re-ran the settings-parity audit against `Sekiro.app` and `JJBA All-Star Battle.app`'s actual
launcher scripts (not just their env-var values, which the first audit already covered). Found
three pieces of real, load-bearing logic that existed ONLY in the hand-tuned external launchers —
Decanter's own Play button gave every one of these zero coverage. All three are now generic,
per-bottle features, not Sekiro/JJBA special cases.

**1. Per-game shader cache**, not per-prefix. `Wine.environment` keyed `DXMT_SHADER_CACHE_PATH` off
the bottle's PREFIX name — Sekiro, JJBA and Peggle all share `Steam-Wine11`, so Decanter's Play
button was funneling all three games' shader caches into one shared directory, never touching the
already-warm `ShaderCache/Sekiro` / `ShaderCache/ASBR` the external launchers had been building for
months. Fixed generically: `AppModel.shaderCacheGameKey(for:)` derives a per-game key from the
resolved game's own exe name (`sekiro.exe` → `sekiro`, `ASBR.exe` → `ASBR`) — reusing the exe-name
convention the external launchers already use means this lands on the SAME directories on a
default case-insensitive APFS volume, no migration needed. `Paths.shaderCache(for:gameKey:)` takes
the optional override; `AppModel.shaderCacheOverride(for:)` builds it and is merged into
`launchQuietly`'s `extraEnvironment` at both real per-game launch call sites (direct-exe and
`-applaunch`) — never at a bare Steam warm-start, where nothing is rendering yet.
`reclaimReport()`'s `referencedByBottles` set was extended to include each bottle's own game key
too, so a per-game cache dir with no external launcher pointing at it (Half Sword, Peggle, any
future game) doesn't get flagged reclaimable the first time `--reclaim` runs post-fix. **Live
verified**: launched Sekiro via `--play-test`; `ShaderCache/Sekiro/shaders_320.db-shm` picked up a
fresh mtime from that exact session, `ShaderCache/Steam-Wine11` did not.

**2. GPU firmware keep-alive**, wired into the app for the first time. `Sekiro.app` ships and runs
`gpukeepalive` (see [[decanter-gpu-firmware-hang]]) — a small helper that submits a Metal blit
every 50ms to hold this Mac's GPU out of a firmware power state it intermittently fails to resume
from. `grep -r keepalive Sources/` turned up nothing: the workaround existed only in the external
app, never in Decanter's own launch path. Added a second SwiftPM executable target
(`Sources/GPUKeepalive/main.swift`, `Package.swift`), generalized to take its target exe name as a
CLI argument instead of a hardcoded `sekiro.exe`; `Scripts/make_app.sh` now copies it to
`Contents/MacOS/gpukeepalive` (same location the external app uses) and it rides the existing
`--deep` codesign. New opt-in setting `BottleSettings.gpuKeepAlive` (default off — this works
around a fault specific to this Mac's GPU firmware, not something to assume universal) surfaced in
`ConfigurationView`'s Performance section; `AppModel.launchGPUKeepAliveIfNeeded` spawns it
alongside `ensureBorderlessFullscreen`/`installGraphicsDriver` on every launch when the setting is
on, gated by its own `isProcessRunning(named: "gpukeepalive")` check since the binary itself never
guards against being started twice — that check lived in the external launcher's shell script
(`pgrep -f gpukeepalive`) and had to move here. The real Sekiro bottle's stored setting was flipped
to `true` to match the proven-safe external config; JJBA's was left off, matching its own external
launcher (which never uses this — and per [[decanter-dxmt-stall-profiler]], ASBR never builds the
large command buffers Sekiro's stalls are associated with anyway).

⚠️ **Found and fixed a NEW bug during live verification, not present in the original hand-tuned
launcher**: the helper's original `pgrep -f <exe>` detection matches a process's FULL COMMAND
LINE. The original single-game launcher never hit this, but Decanter's `installGraphicsDriver`
runs `wine reg add HKCU\...\sekiro.exe\...` for every resolved game sharing a prefix as part of a
normal launch — and that registry-editing process's own argv literally contains `sekiro.exe` as a
path component. First live test: `gpukeepalive` logged "sekiro.exe detected" within 0 seconds of
starting (the registry sweep, not the game), then "exited" a few seconds later when that unrelated
`wine reg add` call finished — stopping protection long before the real game ever started. Fixed
by matching the same way `AppModel.isProcessRunning`/`isAnyGameRunning` do: `ps -Ao comm=` (the
process's own name, which a `wine reg add` subprocess can't spoof) plus the established
split-on-both-`/`-and-`\`-separators rule, instead of `pgrep -f`. **Live verified end to end**
after the fix, via `open Decanter.app --args --play-test …` (needed instead of a plain backgrounded
CLI invocation — a `--play-test` process launched as a background job of an already-completed
shell command gets reaped along with it in this dev environment; Wine's own children survive that
because wine detaches into its own session, but a plain launched helper doesn't): binary started
correctly, gave no false positive through the registry sweep this time, correctly logged `sekiro.exe
detected after 50s` when the real game appeared, survived its own launching process exiting
normally (reparented to launchd, kept running), and left no orphaned process after `--quit-steam`.

**3. Systray sweep for game-launcher bottles.** `AppModel.suppressWineSystray` unconditionally
skipped ANY bottle with `isGameLauncher == true` — meaning Steam's stray menu-bar icon sat there
for the ENTIRE play session on every game launched from Decanter's own Play button. The
over-broad guard conflated "is this a game launcher" with the actual risk, which is narrower: only
a `borderlessFullscreen` bottle repurposes `explorer.exe` as a per-app virtual-desktop window host
while that window is forming, so only that specific case is unsafe to sweep early.
`Sekiro.app`'s own launcher already proved the real safe rule (wait for the game's exe, wait 18s
more for the window, THEN sweep — by then the window belongs to `winemac.drv`, not explorer, and
survives explorer being killed). Ported that exact sequence, gated on
`bottle.settings.borderlessFullscreen` specifically rather than `isGameLauncher` broadly — a
game-launcher bottle NOT using borderless fullscreen (JJBA/ASBR; its own external launcher never
sweeps explorer at all either) keeps the original, simpler immediate-ish timing. NOT independently
live-verified this pass: `--play-test`'s own process exits (and kills its own in-flight Swift
`Task`s, including this sweep) as soon as `isSteamRunning()` is true, which happens well before the
sweep's 18s+24s window can complete — a limitation of the headless test hook, not something a real,
persistently-running Decanter.app session would hit. Confidence here is by construction (identical
shape to the already-proven non-game-launcher sweep, reusing already-tested `isProcessRunning`) and
build-verified, not live-verified; worth a manual GUI check next time Sekiro is played normally.

All three: `swift build` clean, full 86-test suite green, app bundle rebuilt via
`Scripts/make_app.sh` (now building both the `Decanter` and `GPUKeepalive` targets, universal
arm64+x86_64, both signed).

## Second settings-parity audit — three more external-launcher features ported in (2026-09-01)

Re-ran the settings-parity audit from 2026-08-29 specifically against `Sekiro.app` and
`JJBA All-Star Battle.app`'s launcher scripts (`Contents/MacOS/Sekiro`, `Contents/MacOS/JJBA`),
line by line, against `Wine.environment`/`AppModel`. Three real gaps found and fixed; a fourth
thing noticed but deliberately not silently copied.

### 1. Shader cache was scoped per-PREFIX, not per-GAME

`Paths.shaderCache(for:)` keyed on `bottle.url.lastPathComponent` — the prefix name
(`Steam-Wine11`) — so Sekiro, JJBA and Peggle (all three sharing that prefix) funneled their DXMT
shader caches into ONE shared directory via Decanter's own Play button, never touching the
separate `ShaderCache/Sekiro` / `ShaderCache/ASBR` directories the hand-tuned launchers had been
building up over months of real play (and which `reclaimReport()` already special-cased as
"launcher-referenced" — the asymmetry was already half-visible in that code, just never closed).

Fixed generically, not Sekiro/JJBA-specific: `Paths.shaderCache(for:gameKey:)` now takes an
optional per-game key; `AppModel.shaderCacheGameKey(for:)` derives it from the resolved game's own
exe filename (extension stripped) via the SAME `resolvedGame(for:)` resolver everything else uses
— no second source of truth for "what game is this." `shaderCacheOverride(for:)` builds the
`DXMT_SHADER_CACHE_PATH` override and is merged into `launchQuietly`'s `extraEnvironment` at both
real game-launch call sites (direct-exe and `-applaunch`). On a default (case-insensitive) APFS
volume `"sekiro"` and the existing `"Sekiro"` directory are the same folder, so nothing had to
migrate — confirmed live: launched Sekiro through Decanter, `ShaderCache/Sekiro/shaders_320.db-shm`
picked up a fresh mtime, `ShaderCache/Steam-Wine11` did not move.

Also fixed `reclaimReport()`'s `referencedByBottles` set to include each bottle's resolved
per-game key alongside its prefix name — otherwise a per-game cache dir for a title with NO
external launcher (Half Sword, Peggle, any future game) would have been reported reclaimable the
first time `--reclaim` ran after this shipped.

### 2. GPU firmware keep-alive existed only in the external launcher — now a real bundled feature

`Sekiro.app` ships and runs `gpukeepalive` (was: `Scripts/sekiro/gpukeepalive.swift`, hardcoded to
watch `sekiro\.exe`) — the fix for the ~7s whole-Mac GPU firmware freezes
(`docs/GPU-HANG-FINDINGS.md`). Decanter's own Play button had zero code referencing it at all.

Ported in as a real feature, not a Sekiro-only hack:
- New SwiftPM executable target `GPUKeepalive` (`Sources/GPUKeepalive/main.swift`) — same source
  shape as the original, generalized to take its target exe name as a CLI argument instead of a
  hardcoded string, so any bottle can use it.
- `Scripts/make_app.sh` builds and bundles it at `Contents/MacOS/gpukeepalive`, same location the
  external launcher uses, universal (arm64 + x86_64) alongside the main binary.
- `Paths.bundledGPUKeepalive` — nil-when-absent lookup, same shape as `bundledDXMT`, so a dev build
  via `swift run` degrades to doing nothing instead of crashing.
- `BottleSettings.gpuKeepAlive: Bool` (default `false`, decoded via the hand-written decoder like
  every other field) — exposed as a "GPU keep-alive" toggle in `ConfigurationView`'s Performance
  section. Opt-in per bottle: the fault is specific to this Mac's GPU firmware and the fix costs a
  continuous small GPU load, so it isn't assumed universal.
- `AppModel.launchGPUKeepAliveIfNeeded(for:)` spawns it alongside `ensureSoftware2D`/
  `ensureBorderlessFullscreen` on every launch, guarded against double-spawning (the binary itself
  has no such guard — that lived in the external launcher's own `pgrep` check before spawning, and
  had to move here). Fire-and-forget, matching the binary's own "NO REAPER HERE" design — it exits
  on its own once the watched exe has come and gone.
- Enabled on the real `Sekiro` bottle's stored settings (`gpuKeepAlive: true`), matching the
  external launcher's actual behavior. NOT enabled for JJBA — its own launcher never used this, and
  the DXMT stall investigation measured JJBA never building the large command buffers Sekiro does
  (`docs/DXMT-STALL-REPORT.md`), so there's no evidence it needs it.

**Bug found and fixed during live verification, not just built:** the original script's own
detection (`pgrep -f 'sekiro\.exe'`) matches a process's FULL COMMAND LINE. The very first
end-to-end test showed it firing instantly, then stopping ~10s later — `installGraphicsDriver`
runs `wine reg add HKCU\Software\Wine\AppDefaults\sekiro.exe\DllOverrides …` for every resolved
game in the shared prefix as a normal part of every launch, and THAT process's own argv literally
contains the string `sekiro.exe`. The external launcher never hit this because it launches exactly
one game directly with no registry sweep first — a failure mode unique to Decanter's own
multi-game-prefix architecture. Fixed to match `AppModel.isProcessRunning(named:)`'s approach
instead: `ps -Ao comm=` (the process's own name, which a `wine reg add` shell can't spoof) with the
same Windows-path-split-on-both-separators handling `isAnyGameRunning` already documents.

**Live-verified, full lifecycle:** isolated test (fake target process) confirmed detect → protect →
self-exit-on-target-gone. Real end-to-end test through `--play-test` (launched via `open`, fully
detached, so it isn't torn down by this session's own shell job-control the way a backgrounded CLI
invocation was — that earlier false negative was a testing-methodology artifact, not a product
bug) confirmed: correct binary + args spawned automatically, no false "detected" from the registry
sweep, real `sekiro.exe` correctly detected 50s later, and zero leftover `gpukeepalive` process
after `--quit-steam` shut everything down.

### 3. Systray sweep never ran at all for game-launcher bottles

`suppressWineSystray` guarded with `guard !isGameLauncher else { return }` — Sekiro and JJBA both
have `-applaunch` in `steamArguments`, so `isGameLauncher` is true for both and the sweep NEVER
fired, full stop. The comment there treated "is this a game launcher" as the unsafe condition, but
`Sekiro.app`'s own launcher proves the actual risky condition is narrower: only a bottle using
`borderlessFullscreen` ever repurposes `explorer.exe` as a window host (the per-app virtual desktop
trick), and even then only until the window finishes forming — wait for the exe, wait 18s more,
THEN sweep, because by then the window is owned by `winemac.drv` and survives explorer dying
(verified live in the external launcher, 2026-07-19).

Generalized rather than special-cased: `suppressWineSystray(bottle:isGameLauncher:)` now checks
`bottle.settings.borderlessFullscreen` specifically. True → the proven-safe delayed sweep (wait for
`resolvedGame`'s exe via `isProcessRunning`, wait 18s, sweep 6× over 24s). False → unchanged,
original simpler timing. JJBA (no borderless fullscreen) is unaffected either way — its own
external launcher never swept at all, so nothing regresses for it.

**Not fully live-verified**: confirming the actual `pkill` firing requires the sweep's Task to
survive ~40-190s inside a live launch, and `--play-test`'s own headless mode exits (killing all its
own in-flight Tasks, `Process`-spawned children like `gpukeepalive` excepted since those are
separate OS processes) as soon as `isSteamRunning()` goes true — which happens well before the
sweep can complete. Verified by code inspection and reuse of two already-proven mechanisms
(`isProcessRunning`, the `pkill -f explorer.exe` step from the existing non-game-launcher sweep)
rather than a full live run; flagging this explicitly rather than claiming more than was checked.

### Noticed, not silently copied: a contradiction in Sekiro.app's own comments

Its GPU-keep-alive section is headed "GPU KEEP-ALIVE DISABLED 2026-07-25 — it CAUSES the 26s
stalls... to re-enable, uncomment the two lines below" — but those two lines are NOT commented out;
the keep-alive is live in the shipped script. Cross-checked against
[[decanter-sekiro-stall-cause]]: the 26s stalls were later (2026-07-28) root-caused to an unrelated
DXMT geometry-shader bug, so re-enabling the keep-alive was very likely correct — the header
comment just never got updated to say so. Surfaced to Jack rather than assumed; not something to
silently trust either way.

Build/tests after all three fixes: 86/86 passing, full suite; `Scripts/make_app.sh` produces a
universal `Decanter.app` with both `Decanter` and `gpukeepalive` present and code-signed.

## "Real game window" — native fullscreen + macOS Game Mode (2026-10-12)

New opt-in bottle setting `BottleSettings.nativeWindow` (Configuration → Graphics, mutually
exclusive with Borderless fullscreen): the game runs in an ordinary macOS window, the green button
takes it into native fullscreen, and Game Mode turns on. Full write-up with every measurement:
**GAMING-STACK.md §7b/§7c** — read that before touching any of this.

**Moving parts:**
- `Helpers/WindowHook/window-hook.m` → `Contents/Resources/WindowHook/libwindowhook.dylib`
  (x86_64). Adds the resize bit Wine's fullscreen gate needs. Silent unless
  `DECANTER_WINDOWHOOK_DIR` is set, which also enables a test-command channel
  (`dump`/`enter`/`exit`/`toggle`/`size W H`/`unpin`) — that's how fullscreen and Game Mode were
  driven without clicking.
- `Helpers/GameHost/` → "Decanter Game.app", a games-category bundle that `exec`s Wine so the game
  gets an app identity. Ships as a template in `Contents/Resources/GameHost/`, **installed to and
  launched from** `Application Support/Decanter/Decanter Game.app` — nested inside Decanter.app,
  Game Mode never engages (`gamepolicyd` treats it as an app extension). Uninstaller removes it.
- `NativeWindow.swift` / `SekiroGraphicsConfig.swift` — the pure parts (tested in
  `NativeWindowTests`). `AppModel.ensureNativeWindow` / `launchNativeWindowGame` /
  `directLaunchTarget` — the I/O. A "Real game window" bottle launches its exe directly (Steam's
  `-applaunch` would strip both the hook and the identity), with graceful fallback to a plain
  direct launch (window works, no Game Mode) if the host can't be installed or opened.
- `Scripts/sekiro/framestat.m` — frame-pacing probe used for the A/B; not shipped.
- `DECANTER_EXTRA_INSERT` (diagnostic): one more x86_64 library to inject into a "Real game
  window" game, e.g. framestat. Never set `DYLD_INSERT_LIBRARIES` on Decanter itself — it's arm64
  and dyld kills it for an x86_64 insert.

**Measured, not assumed:** Game Mode on through Decanter's own Play path; frame pacing
equivalent to the borderless desktop (both locked 60 fps, p99 ≈17 ms); black bars reduced but not
eliminable — Sekiro is 16:9-locked, snaps to 1440×810 on this screen, and never re-renders on
resize. All live runs used an APFS clone of `Steam-Wine11` in a scratch `DECANTER_HOME`; the live
prefix was never touched. Title screen only — re-measure in real play before defaulting it on.

**Build note:** `NATIVE_ONLY=1 bash Scripts/make_app.sh` builds this Mac's architecture only, for
when universal builds are unavailable (Command Line Tools only, or Xcode's license not yet
accepted — universal needs Xcode's xcbuild). Never distribute a NATIVE_ONLY build.

### 2026-10-21 — "decanter isn't working": Peggle + Real game window, three faults

Full write-up: **GAMING-STACK.md §7d**. In short:
1. **PopCap DRM (`drm/common/drm.xml`) refuses a direct launch** ("STEAM ERROR"), so Real game
   window can't apply to Peggle and its siblings. Detected by `NativeWindow.requiresSteamToLaunch`;
   such a bottle launches through `-applaunch` as usual and says why. SteamStub games are fine.
2. **The direct-launch branch launched into a Steam still signing in.** It now joins the
   warm-start and waits on `Steam.isLoggedOn(connectionLog:since:)` (`SteamLogonTests`).
3. **Quitting Decanter while it held a launch silently dropped it.** When Play joins a warm-start,
   the `-applaunch` is sent only after Steam signs in (~70 s cold), so until then it exists only in
   Decanter's memory. Proven from the unified log: a Dock quit 22 s before sign-in, and Peggle
   never started. `launchesWaitingForSteam` now drives a "starts by itself — keep Decanter open"
   caption and a Keep Waiting / Quit Anyway alert (`QuitGuard`, `LaunchWait`, `LaunchWaitTests`).

⚠️ **`--play-test` can't verify this path.** It calls `launchSteam` without selecting the bottle,
so it never joins a warm-start (the path that failed), and it reports only that Steam came up, not
that the game did. And `isSteamRunning()` is global: any other Steam (a clone's included) changes
which launch path a test takes.

### 2026-10-21 (later) — Quit Steam, then Play: four minutes to a game

GAMING-STACK.md §7e. Pressing **Quit Steam** and then selecting the bottle started Steam inside
the quit's own teardown, and the quit's straggler sweep killed the new wineserver. The Wine loader
hung forever, and Play waited out the warm-start's 150 s, then a 66 s cold start. Fixes:
- `quitSteam` runs once per prefix; the warm-start and `launchSteam` wait for it
  (`waitForSteamQuit`).
- `isSteamRunning()` matches the executable (`ps -o comm=`, `Steam.isClient`), not the command
  line. `pgrep -f /steam\.exe` counted the hung `…/bin/wine …/steam.exe` loader as Steam, which
  produced a false "[DEC-E09] Steam is still running" and a skipped sign-in wait
  (`SteamProcessTests`).

`--quit-then-play-test "<bottle>"` replays the sequence and waits for the game itself. Verified
live: 74 s from Play to Peggle, all of it Steam's cold sign-in.
