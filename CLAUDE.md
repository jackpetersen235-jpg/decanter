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

## Generated game launchers (`GameAppBuilder`)

Decanter writes a `.app` per game into `~/Applications`, and each game bottle shows **Launch
Steam** and **Launch Game App**. Regenerate headlessly with `--build-game-apps`.

- **They reference the shared engine, they do not embed Wine.** The hand-made `Sekiro.app` /
  JJBA bundles embed one at ~696 MB each; generated ones are **8 KB**. The cost is that they only
  work on this Mac — as does the prefix they point at, so nothing is lost.
- **Shell-quote every path.** One of the two games is `JoJo's Bizarre Adventure…`. A raw
  `"\(path)"` closes the quote at the apostrophe and the launcher runs the wrong thing.
  `GameAppBuilder.shellQuote` emits `'JoJo'\''s …'`; verified in the generated output.
- **`pgrep -x`, never `-f`, for the already-running check.** Same recurring bug class as
  everywhere else in this file — `-f` matches the script's own argv.
- **Do not try to raise a running Wine game from the script.** Its window belongs to
  `winemac.drv`, no bundle `open -a` can name it, and driving it needs Accessibility. The first
  draft shipped an `open -a <game folder>` that could only ever fail. It now exits quietly.
- **Resolution order:** `directExecutable` → `steamAppID`/`-applaunch` → *exactly one* game
  manifest in the prefix. That last fallback is what makes a plain new bottle work.
- **Filter 228980 out of the manifest count.** "Steamworks Common Redistributables" is installed
  beside almost every game, so a one-game prefix reports two manifests and looked ambiguous —
  Half Sword produced no launcher until this was excluded (`AppModel.nonGameAppIDs`).
- **Search one level deep for the exe.** UE titles ship a small top-level shim next to the real
  binary: Half Sword's is `HalfSwordUE5/Binaries/Win64/…-Shipping.exe` (300 MB) beside a 0.3 MB
  stub, so a top-level-only "biggest .exe" picks the stub.
- Generated launchers take their DXMT settings from the BOTTLE, so they will not match the
  hand-tuned bundles byte for byte (those used `metalSpatialUpscaleFactor=1.5` plus
  `sampleNaNToZero`/`defuseFma`, and a per-game shader cache). The bottle is the source of truth
  now; port anything worth keeping into the bottle's settings.

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

## Verification habits that mattered

- **Screenshots beat logs.** `screencapture -x` + Read. Logs said "0 errors" while the screen was
  a black rectangle. Terminal has Screen Recording permission; it does **not** have Accessibility,
  so `System Events` reports **0 windows** for wine processes and cannot click/fullscreen them.
- Wine windows are their own macOS Space in fullscreen — a plain screenshot catches the wrong Space.
  Raise the wine process first (`System Events` → `set frontmost`), then capture.
- Long-running launches must use `run_in_background: true`. A foreground command's timeout
  **SIGTERMs the whole process group** and killed a Steam download at 90%.

