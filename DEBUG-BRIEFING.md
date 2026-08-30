# Decanter — bug-fix briefing

You are picking up a bug-fix pass on **Decanter** (`~/coding/Decanter`), a SwiftUI macOS
app that manages Wine "bottles" for gaming. **Read `CLAUDE.md` first** — it is long, it
is accurate, and it documents dead ends that have already cost this project hours.

## Where things stand

- Items 1–4 of an earlier bug sweep are **done and committed** as `1db2fd3`.
- Tree is clean. `swift test` → **11/11 pass** (`Tests/DecanterTests/PrefixSharingTests.swift`).
- Build: `swift build`. No Xcode on this machine, no `.xcodeproj` — SwiftPM only.
- Six findings below (F11–F16) are **verified but unfixed**. They came from an
  independent reviewing pass; every one was checked against the working tree, but the
  consequences are marked `inferred` where nothing was actually executed.

**Verify each finding yourself before fixing it.** The reviewer that produced these was
wrong twice and self-corrected both times. Read the cited lines; don't take the writeup
on faith. If one is wrong, say so — that is a useful outcome, not a failure.

---

## Rules that do not move

- **Delete nothing.** Not backups, not caches, not "clutter". If something looks
  reclaimable, list it for Jack. Before removing *any* file, `stat -f '%SB'` its birth
  time and confirm it is inside your own session. This rule exists because it was
  broken twice.
- **No commits, no staging, no pushes.** Branch is `main`. Jack commits.
- **Never touch `~/Applications/Sekiro.app`.** It is outside this repo and it is how the
  game actually launches.
- **Nothing destructive against `Bottles/Steam-Wine11`** — 25 GB, four bottles, real save
  data. No `wineserver -k`, no `pkill` against it. **Scratch prefixes are fine and
  encouraged** for experiments.
- **Escalate genuine UX trade-offs to Jack.** Defect fixes are yours; design calls are his.
- **Tag every claim `observed` or `inferred`.** State what you could not verify. An
  honest gap always beats a confident overclaim.

---

## Priority 1 — Persistence & feedback bundle (F12 + F13 + F11)

These are one defect in three places: **a failure the user never sees.** The
`@Published` + `.alert` plumbing already exists in `ContentView.swift`.

### F12 (high) — salvage returns silently on invalid JSON
`AppModel.swift:2138`
```swift
guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
```
If `bottles.json` isn't valid JSON at all (truncated — the force-quit/disk-full case),
the backup *is* written first (good), then this bare `return` skips both the NSLog and
the `bottleSalvageWarning` set below. Result: zero bottles, first-run setup, no warning
— and the next `saveBottles()` (`:2187`, unconditional) writes `[]` over the file.

That is verbatim the scenario `loadBottles`'s own doc comment says it exists to prevent.
**Fix:** set `bottleSalvageWarning` before returning. Same for the non-array cast.

### F13 (medium) — a failed save is NSLog-only
`AppModel.swift:2189`. Its own doc comment three lines above says *"silently not saving
looks identical to saving, and the user only discovers it after losing work"* — then
logs to NSLog, invisible outside Console.app. **Fix:** publish it like the others.

*(Audit already done: only three real NSLog sites exist. `:2148` is fixed, `:2189` is
this, and `:1757` — the reaper giving up — is deliberately NOT a bug, because auto-quit
is automatic and "Steam is still open" is visible on screen.)*

### F11 (medium) — `-applaunch` launches can't report failure
`AppModel.swift:1631` uses `isSteamRunning()` as the success signal. When Steam is
already up it's true on the first check, so `launched` is true immediately and
`lastLaunchFailure` (`:1961`) never fires. A game that fails to start on the path the
code itself calls *"how nearly every game starts"* reports nothing.

⚠️ **DO NOT "fix" this by polling the game's exe.** For Peggle the resolved exe is
`Peggle.exe`, a DRM wrapper that unpacks `popcapgame1.exe` and exits — you would report
"Peggle didn't start" *while Peggle is running*. A false error on a working launch is
worse than the silence.

**Fix:** document the limitation at the call site, and say *why* (DRM wrapper, see
Peggle) so nobody tries the exe-polling "fix" later.

---

## Priority 2 — F16 (high): `Shell.run` has no timeout

`Shell.swift:31-70`. `Shell.run` is a `withCheckedThrowingContinuation` whose only
resume path is `process.terminationHandler`. No timeout, no cancellation. A process that
never exits hangs the awaiting task forever. **17 call sites in `AppModel.swift` alone.**

Wedged Wine processes are a *documented, recurring* condition here (CLAUDE.md: "stuck
Wine processes appeared repeatedly today"; F7 exists because of one).

**Failing case** — `AppModel.swift:1525-1551`:
```
1548  launchingBottleIDs.insert(bottle.id)     <- launch claimed
1551  await ensureSoftware2D(for: bottle)      <- wine subprocess, no timeout
```
Wedged wineserver → stuck at 1551 forever → `clearLaunchGuard` (`:1592`/`:1631`) is
**below the hang and never runs** → Play reads "Opening…" and is dead for that bottle
until app restart. A second click hits `:1533` and silently calls
`activateRunningGame()`, so there is no feedback at all.

Also: `shutdownPrefix` runs `wineserver -k` through `Shell.run`, so **`quitSteam` can
hang on the very wedged prefix it exists to clear.**

**Fix:** add a timeout — a deadline Task that calls `process.terminate()`, SIGKILLs
after a grace, and resumes the continuation with a thrown error. Sane default; let long
operations (Steam install, engine download) opt into longer explicitly.

⚠️ **TRAP:** with a timeout racing `terminationHandler`, **double-resuming a checked
continuation is a hard crash**, not a warning. Guard with an `NSLock`'d `hasResumed`
flag — same shape as the existing `OutputCollector` in that file. Get this wrong and you
have traded a hang for a crash.

Prove it safely on a **scratch prefix with a deliberately hung process** — never on
`Steam-Wine11`.

---

## Priority 3 — F14 (high): settings leak between bottles via Steam's environment

Four bottles share `Steam-Wine11` and they do **not** agree: Peggle has `metalFX: false`,
the other three have `true`.

`Wine.swift:113` merges `derivedEnvironment` into the base env; `AppModel.swift:1888`
(`launchQuietly`) uses that for **every** launch — including the one that starts Steam.
And `BottleSettings.swift:~288` documents the consequence: *"a game launched via
`steam.exe -applaunch` inherits the environment of the ALREADY-RUNNING Steam"*
(diagnosed live 2026-07-18, caused Sekiro load freezes).

**Failing case:** Play Peggle (metalFX off) → Steam starts with Peggle's env → Play
Sekiro without quitting Steam → **Sekiro runs with MetalFX off** while its Configuration
tab says it's on. Reverse order leaks the other way. Affects `metalFX`, `metalFXFactor`,
`syncMode`, `metalHUD`, `advertiseAVX`, and the user's own `environment` dict.

**Also fix, same item:** `BottleSettings.swift:313`
```swift
case .wined3d: env["WINEDLLOVERRIDES"] = "d3d9,d3d10core,d3d11,dxgi=b"
```
This is the only backend reaching for a global lever; the other three are per-exe. It was
**proven redundant for its own bottle** by experiment (scratch prefix, no overrides,
`WINEDEBUG=+loaddll` → `d3d11`/`dxgi` both loaded `builtin`; a native DLL sitting beside
the exe was ignored). So scoping it per-exe costs nothing and removes the leak.

**UI half:** `ConfigurationView.swift` — `sharedCaption()` sits at `:122`, the bottom of
the Graphics section, so it's ambiguous whether it covers MetalFX (`:95`) or only
Retina/DPI (`:119-121`). Its intent (see the doc at `:12`) is DPI/Retina only. Meanwhile
`syncMode` in the Performance section (`:146`) is shared by the identical mechanism and
has no caption at all. That section mixes **three** different scopes; make it honest.

---

## Priority 4 — F15 (medium): headless setup can't report failure

`--run-setup` and `--install-engine` (`AppModel.swift:61`, `:66`) **never print, never
exit, never set a status.** `runGuidedSetup()` (`:311-333`) has four silent failure
exits — two bare `return`s and two discarded results — and step 4 passes `console: nil`,
so every message inside `performSteamInstall` is a no-op.

Every *other* headless flag does `exit(ok ? 0 : 1)` (`:85`, `:97`, `:116`, `:220`, `:257`).

This invalidates CLAUDE.md's claim that both flags were "verified end-to-end" — neither
can report an outcome.

**Also:** `runGuidedSetup`'s doc says it was *"factored out of the wizard view."* Its only
caller is `:66`. **`SetupWizard.swift` does not call it** — the wizard reimplements the
same four steps with its own error reporting, and the two have already drifted. Either
make the wizard call it, or drop the claim. Not neither.

---

## Priority 5 — F5: orphan reclaim. **LIST ONLY.**

Build the detection and UI. **Print** what is reclaimable with sizes and a reason per
item. **Delete nothing** — Jack runs any `rm` himself.

⚠️ **LANDMINE:** an orphan cannot be defined as "unreferenced by `bottles.json`".
`ShaderCache/Sekiro` (13 MB) and `ShaderCache/ASBR` (1.1 MB) are **live** — used by
`~/Applications/Sekiro.app` and `JJBA All-Star Battle.app`, which set
`DXMT_SHADER_CACHE_PATH` directly and are invisible to Decanter's model. Deleting them
costs shader-recompile stutter on the flagship game. The reclaim path must scan
`~/Applications/*.app/Contents/MacOS/` too.

Genuinely safe: `Bottles/Bottle-F99703` (332 MB, unreferenced) and four 0-byte cache dirs.

---

## Priority 6 — remainder

- **F9** — accessibility. Zero `accessibilityLabel` in the whole Views layer; `.help()`
  sets tooltip text, not a label. Label what the control *does* ("Create a new bottle"),
  not the glyph ("plus").
- **F10** — **close as WONTFIX** and write the reasoning into CLAUDE.md. Its fix sketch
  ("skip when the registry already matches") requires reading state via `reg query`,
  which **lies while wineserver is running** — a stale "matches" skips the write and
  **reintroduces F4**, the bug just fixed. A few seconds per launch buys the guarantee
  that the UI tells the truth.
- **Deferred list** (already in CLAUDE.md): software-2D's OFF path never targets
  `popcapgame1.exe`; `quitSteamBlockReason` over-blocks on unrelated-prefix activity.

---

## Reporting

One item at a time. For each: the invariant restored, what you verified and how,
`observed` vs `inferred` per claim, `git diff --numstat` (not `--stat` — its middle
column is total changed lines, not insertions), and test results. Say what you could not
check. Then move to the next item without waiting.
