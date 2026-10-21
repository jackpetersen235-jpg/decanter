# Windows gaming on Apple Silicon — findings

Hard-won notes from getting **Sekiro** running on an **M5 MacBook Air / macOS Tahoe 26.5.2**.
Written so a future session doesn't repeat multi-hour dead ends. **Claims here are backed by
measurements taken on this machine**, not by general knowledge.

---

## 1. The stack

```
Windows game (x86-64)
  ↓ Wine        Win32/64 API      → macOS
  ↓ Rosetta 2   x86-64            → arm64          (unavoidable; no ARM build of the game exists)
  ↓ DXMT        DirectX 11        → Metal          (1 hop)   ← use this
    DXVK        DirectX 11 → Vulkan → MoltenVK → Metal (3 hops) ← avoid on Apple Silicon
```

**DXVK → DXMT was the single biggest win.** Sekiro was "extremely laggy" on DXVK; DXMT made it
playable. DXVK drags in MoltenVK and an entire Vulkan emulation layer for no benefit here.

## 2. ⚠️ The Wine build matrix — the REAL constraint (corrected 2026-07-17)

**An earlier version of this doc said "no free build has both msync and modern Steam, it's
structural." That is WRONG — and it was wrong because it varied the wrong axis.** It treated
this as *wine version* (7.7 = msync, 11 = none). The axis that actually matters is the **source
tree**:

- **Upstream** wine (any version, 7.x→11) — **never had msync.** msync is a CodeWeavers/CrossOver
  patch that was never upstreamed; upstream's replacement (`ntsync`) needs a Linux kernel driver.
- **CrossOver-sourced** wine — **has msync, at modern versions too** (CrossOver 24 = wine 9,
  CrossOver 25 = wine 10). Not tied to being old.

| Build | Source | Version | msync | Steam login | Notes |
|---|---|---|---|---|---|
| Mythic (GPTk) | CrossOver | 7.7 | ✅ (`WINEMSYNC` in ntdll) | ❌ too old | good sync, can't launch Steam |
| frankea "WhiskyWine 11" | upstream | 11.0 | ❌ none | ✅ | base bundle (DXMT/DXVK + 94 dylibs); spikes |
| **`WS11Wine10.0_3`** (free) | **upstream** | **10.0** | ✅ **msync** | ✅ | **CURRENT ENGINE — spikes fixed** |
| Gcenx Wine Staging | upstream | 11.10 | ❌ none | ✅ | Steam UI black (GLES) |
| **`WS12WineCX24.0.7`** (free) | **CrossOver 24** | **9.0** | ✅ **PROVEN ACTIVE** | ⚠️ see below | free, from Sikarugir/Kegworks `Engines` |
| CrossOver (paid) | CrossOver | 9/10 | ✅ | ✅ | full wrapper — just works |

**What was actually proven (measured on this M5 Air, 2026-07-17):** the FREE `WS12WineCX24.0.7`
(wine 9.0) has msync and it **activates** — booted a prefix with `WINEMSYNC=1` and got
`msync: up and running` + shared-memory sync traces. So "no free build has msync" is **false**.

**The real remaining blocker is PACKAGING, not the engine.** The Kegworks/Sikarugir CX engines
are built to run *inside their wrapper app*, which supplies a support environment. Extracted bare
into Decanter's layout, the engine needs backfilled dylibs (`libinotify`, then the full 94-lib
set: gnutls/freetype/MoltenVK/… — all copyable from the frankea bundle) — and *even then*
**Steam's CM login won't complete**: the connectivity test (TCP:80) passes but the client never
opens the CM connection (sockets close immediately, `WSAEOPNOTSUPP`). Inside a proper
Kegworks/Sikarugir wrapper (or CrossOver) that networking works. See §2b.

Verify msync support of any build (the feature, not the POSIX `_msync` syscall symbol):
```bash
# raw byte scan — `strings` misses the symbol table, so it can false-NEGATIVE; grep -a does not
grep -ac WINEMSYNC <wine>/lib/wine/x86_64-unix/ntdll.so   # >0 = feature present
```
> We once exported `WINEMSYNC=1` for hours on the upstream-11 engine where it did nothing (no
> feature to read it). On CX24 the same flag is consumed — `msync: up and running`.

## 2b. The free msync path — SOLVED (2026-07-18)

**Resolved.** The blocker was never packaging — it was **CrossOver's own patches**, which break
Steam's internal client↔UI loopback websocket (`steam.exe` LISTENs on 127.0.0.1 but nothing ever
connects). Upstream wine has no such problem.

The engine now installed is **`WS11Wine10.0_3`** — free, upstream wine 10.0 **with msync**. On this
Mac: `msync: up and running`, Steam logs on in ~24 s, loopback websocket ESTABLISHED, DXMT renders.

Ruled out along the way (all measured, none were the cause): msync itself (fails with fast-sync
OFF too), support libraries, wrapper packaging, prefix version, wine version (CX 8 and 9 fail
identically), and IPv6 (`::1` is configured and dead-port connects refuse in 0.000 s).

**DXMT graft required:** the overlay ships no unix `winemetal.so` and only a 36 KB stub
`winemetal.dll`. `WineInstaller.installMsyncEngine()` grafts back the base bundle's `winemetal.so`
plus DXMT's real 73478-byte `winemetal.dll`. ⚠️ That runs a wine-11 unixlib inside a wine-10
engine — unsupported ABI mix, and one GPU error/recovery was observed. Suspect it first if
graphics get unstable; fallback lives in `Backups/wine11-*/`.

## 3. The frame spikes — FIXED


**Cause (now fixed):** an engine without fast sync makes Sekiro's **103 threads** round-trip every
mutex/event through `wineserver` over IPC, which serialises them and produces the spikes.

**Evidence (measured):**

| | wineserver CPU |
|---|---|
| upstream wine 11 (no msync) | **39.9 %** |
| Mythic/Whisky2.5 + `WINEMSYNC=1` | **0.1 %** |

That drop proves the mechanism. **Result after switching to upstream wine 10 + msync
(2026-07-18):**

| launch | wineserver CPU |
|---|---|
| baseline, upstream wine 11 (no msync) | **39.9 %** |
| wine 10 + msync, but game inherited the WRONG env (see §4b) | ~6-8 % avg |
| **wine 10 + msync, cold `Sekiro.app` launch (correct env)** | **~3.2 % avg** (2.3-5.7 %) |

**~12× reduction**, and confirmed subjectively — "running smooth again". Note the middle row: an
earlier 547-sample run averaged 7.9 % because the game had inherited a Decanter-started Steam's
environment (stale shader cache, missing DXMT tuning). Always measure a cold launch.

This is still not the ~400× the old Mythic 0.1 % figure implied; that figure was likely taken under
much lighter load.

Also measured: `GPU 3.04 ms` vs `Frame Interval 19.72 ms` → **the GPU is idle ~84 % of each
frame**. Graphics settings are NOT the bottleneck. Lowering quality won't fix the spikes; it's
CPU-side (Rosetta translation + wineserver sync).

## 4. Steam

- **Black client UI** — Steam's CEF UI needs GLES 3.0; Wine's GL path offers 2.0
  (`eglCreateContext: Requested GLES version (3.0) is greater than max supported (2, 0)`).
  Fixes that **did not work**: `-cef-disable-gpu`, `libglesv2=d`, clearing htmlcache.
  **What fixed it: switching Wine build** (Gcenx 11.10 → WhiskyWine 11.0). It was never a flag.
- **Login uses JWT, not `ssfn` files.** Don't test login state by looking for `ssfn*` — modern
  Steam stores a JWT (ours: `persistence: 1`, expires **Feb 2027**). Check
  `logs/connection_log.txt` for `RecvMsgClientLogOnResponse() : 'OK'` / `[Logged On]`.
  We wrongly declared a *successful* login a failure because `ssfn` count was 0.
- **Offline Mode won't engage while online.** Setting `WantsOfflineMode 1` in `loginusers.vdf`
  is ignored if Steam's connectivity test (plain HTTP:80) passes — even when the TLS login on
  :443 fails. Steam sits at `[Logged Off]` forever and never offers offline.
- Steam re-execs itself and the real client runs as `C:\Program Files (x86)\Steam\steam.exe`.
  **`pgrep -f <unix path>` misses it.** Two Dock tiles = one Steam — **but see §10, this is
  avoidable with `-skipinitialbootstrap`** (an earlier version of this doc wrongly called it
  inherent).
- `-silent` hides the window but **still spawns ~6 steamwebhelper processes** — a negligible win,
  and actively wrong on a launcher bottle (§10).
- `-applaunch <id>` on a **cold** Steam gets consumed before login completes. **This bit us for
  real (2026-07-18):** `Sekiro.app` sent `-silent … -applaunch 814380` in ONE shot, so Steam opened
  and the game never started. Fixed with a **two-phase launch** in `Scripts/sekiro/sekiro-launcher.sh`:
  start `steam.exe`, poll `logs/connection_log.txt` until a new `Logged On,` line appears, THEN
  `exec wine steam.exe -applaunch <id>`. Verified: game up in 37 s.
- **Launch-order trap — this one silently ruins your tuning.** `-applaunch` hands the game to the
  ALREADY-RUNNING Steam, so the game inherits *that* client's environment. If Steam was started by
  Decanter, the game runs with Decanter's settings (e.g. MetalFX 2.0x) and the launcher's tuned env
  (msync, MetalFX 1.5x, fps cap) is silently discarded — measurably more GPU load and more hangs.
  **Always quit Steam fully before launching `Sekiro.app`.** Verify with:
  `ps -Ao command | grep wineserver` — it must say `Sekiro.app/Contents/Frameworks/Wine`, not `Decanter/Wine`.


## 4b. ⚠️ Launch order changes performance (diagnosed 2026-07-18)

`steam.exe -applaunch <id>` does not start a fresh Steam — it tells an **already-running** Steam to
start the game. The game therefore inherits **that Steam's environment**, not the environment of
whatever launcher you just double-clicked.

Consequence: launching `Sekiro.app` while a **Decanter-started Steam** is already open silently
discards Sekiro.app's tuning — its `DXMT_CONFIG` (MetalFX 2x, `ignoreMapFlagNoWait`) and its
`DXMT_SHADER_CACHE_PATH`. The game then runs on Decanter's bottle cache
(`ShaderCache/Steam-Wine11`) instead of `ShaderCache/Sekiro`.

Symptom: **~10 s freeze on load and stutter during play**, while a cold launch of the same build is
smooth. Measured the same session: wrong-env run `wineserver` ~6-8 %; cold `Sekiro.app` launch
**~3.2 % avg** (2.3-5.7 %) against a 39.9 % baseline.

**Rule: quit Steam completely before launching a per-game app**, or start the game from that app
rather than opening Steam separately. `BottleSettings.derivedEnvironment` now also emits
`d3d11.ignoreMapFlagNoWait=True` so the two paths at least agree on DXMT config.

**Also:** a shader cache is engine-specific. After an engine swap, an old cache forces a full
recompile (long first-load freeze). Caches live in `~/Library/Application Support/Decanter/ShaderCache/`.


## 4c. GPU hangs on level load — diagnosed, NOT fixed (2026-07-18)

**Symptom:** a 4-10 s freeze when loading a save or respawning after death. The **entire Mac**
locks (can't switch windows); ordinary gameplay is unaffected and smooth.

**Root cause: the GPU hangs and macOS force-resets it.** Confirmed with a hard counter — no sudo
needed:
```bash
ioreg -r -d 1 -c IOAccelerator | tr ',' '\n' | grep -E 'recoveryCount|Device Utilization'
```
`recoveryCount` increments at the exact second of each freeze. Measured rate during play: **~20
hangs/hour**, stable across every configuration tried.

**Fingerprint** (why it looks like nothing else): Sekiro ~2 % CPU, `wineserver` ~0.6 %, disk
*quieter* than normal play, memory fine, **every process on the machine idle**, yet the desktop is
frozen. Nothing is computing — everything is blocked on the GPU. GPU work never shows up in CPU %.

**Eliminated by measurement — do NOT re-litigate these:**

| Suspect | Killed by |
|---|---|
| Shader compilation | CPU *collapses* to 2 %; compiling would be high-CPU, and the cache doesn't grow |
| `winemetal.so` graft | byte-identical (`3d50d7f3…`) to DXMT's official v0.80 backend |
| msync | froze with `WINEMSYNC=0` too (and msync-off is far worse: wineserver peaked 54 %) |
| MetalFX | froze with `DXMT_METALFX_SPATIAL_SWAPCHAIN=0` too |
| Disk I/O | during stall 183 MB/s avg vs **523 MB/s during normal play** |
| `ignoreMapFlagNoWait` | 20.0 hangs/hour with AND without it |
| Official DXMT 0.80 build | **errors — reverted.** frankea ships the "native per-prefix" variant paired with the builtin `winemetal`; the official tarball is the "builtin" variant. They are NOT interchangeable. |

**Not caused by the wine 10 + msync swap:** every component that generates Metal commands
(`winemetal.so`, `winemetal.dll`, the DXMT DLLs) is byte-identical before and after. The swap
changed thread sync, not graphics.

**What DID help:** in-game settings to Medium + MetalFX 2.0x -> 1.5x. Hang *rate* unchanged, but
freezes are noticeably **shorter** and the game holds a **steady 60 fps**. Note this reverses the
CPU-spike guidance in section 3 — lowering quality does nothing for CPU spikes, but does reduce GPU
work at the hang point.

**Accepted trade (user's choice):** a pause on load, smooth 60 fps afterwards.

**Untested:** whether wine 11 hangs at the same rate. `recoveryCount` now makes that an objective
per-hour comparison rather than anecdote. Fallback: `Backups/wine11-*/`.

## 5. MetalFX — semantics people get wrong

`DXMT_METALFX_SPATIAL_SWAPCHAIN=1` + `d3d11.metalSpatialUpscaleFactor=N` upscales
**from the game's render resolution × N**. It does **not** reduce what the game renders.

> Enabling it alone is a **quality** feature that *adds* an upscale pass — it buys **zero** frames.
> To gain performance you must **lower the game's internal resolution** and let MetalFX rebuild it.

Current: game renders **1280×832**, MetalFX 2.0× → **2560×1664** (native panel). Verify in the
Metal HUD: `Scaling: Spatial`, `Scaling Input Res`, `Scaling Target Res`.

Real DXMT config keys (from `strings d3d11.dll` — these are the only ones):
```
d3d11.metalSpatialUpscaleFactor    d3d11.preferredMaxFrameRate
d3d11.ignoreMapFlagNoWait          d3d11.defuseFma        d3d11.sampleNaNToZero
dxgi.customVendorId/DeviceId/customDeviceDesc            dxgi.forceSDR
DXMT_METALFX_SPATIAL_SWAPCHAIN  DXMT_SHADER_CACHE(_PATH)  DXMT_LOG_LEVEL/PATH
```

## 6. DLL overrides must be **per-executable**

A prefix-wide DXVK/DXMT override routes **Steam's own CEF UI** through it → black window.

```
HKCU\Software\Wine\AppDefaults\sekiro.exe\DllOverrides   d3d11, dxgi, d3d10core = native,builtin
HKCU\Software\Wine\DllOverrides                          ← keep CLEAN
```
Even better: drop the DXMT DLLs **in the game's own folder** — Wine's loader prefers the app
directory, so only that exe gets them. That's what the current setup does.

> `BottleSettings.derivedEnvironment` deliberately does **not** emit `WINEDLLOVERRIDES` for
> `.dxvk` — see the comment there. Don't "fix" it back.

## 7. Fullscreen & macOS Game Mode

> **CORRECTED 2026-10-12** — this section used to be titled "both impossible with Wine". Both
> halves are reachable; see **7b** below. The two rows marked ⚠️ were wrong.

| Approach | Result |
|---|---|
| Wine exclusive fullscreen | **Traps you** — captures the display, Cmd+Tab dead |
| `CaptureDisplaysForFullscreen=n` | **Zoomed + still traps** — Wine can't switch display res without capture, so a low-res buffer renders 1:1 into a full-panel window |
| Borderless at native res | 4× the pixels — destroys the perf gained |
| ⚠️ Native macOS fullscreen (⌃⌘F) | ~~Wine doesn't implement it~~ — it does; the button is greyed because the game's window isn't **resizable** (7b) |
| ⚠️ **Game Mode** | ~~unreachable~~ — needs native fullscreen **and** a games-category app identity on the game process itself (7b) |

**UPDATE — borderless fullscreen IS achievable** (a per-app Wine virtual desktop):

- Set a **per-app** virtual desktop for the game exe only, sized to the screen's *point*
  resolution (this Air = **1470×956**):
  ```
  HKCU\Software\Wine\AppDefaults\<game>.exe\Explorer   Desktop = Default
  HKCU\Software\Wine\Explorer\Desktops                  Default = 1470x956
  ```
  (Per-app, NOT global `HKCU\Software\Wine\Explorer\Desktop` — global forces Steam's own
  window into the desktop too.)
- Result (verified with Sekiro): fills the screen, **`Direct`** presentation (not Composited),
  **60fps locked** (16.67ms frame interval), MetalFX still upscales 1470×956 → 2944×1912, and
  **Cmd+Tab still works** (it's a window, not a display capture — `CGDisplayIsCaptured` = false).
- The virtual desktop is an `explorer.exe`, which also bridges Steam's systray to the menu bar.
  Kill explorer **after** the game window exists (`Scripts/sekiro/*` waits ~18s): the window is
  owned by winemac.drv and **survives**, so you lose the menu-bar icon but keep fullscreen.
  Killing it too early prevents the fullscreen window from being created.
- Game Mode still won't engage (needs true native fullscreen), but the frame pacing is already
  perfect, so it doesn't matter here.

Setup script: `Scripts/sekiro/enable-fullscreen.sh`. Windowed 1280×832 + MetalFX remains a fine
fallback, but per-app-desktop fullscreen is better (Direct path, locked 60fps).

Game Mode also needs the app to be a **games-category bundle**. We fixed the identity by cloning
the Wine tree *inside* `Sekiro.app` (`Contents/Frameworks/Wine`, APFS clone) — `lsappinfo` now
reports `bundleID="com.decanter.sekiro"`. **Identity was necessary but not sufficient**; Wine
still can't produce the fullscreen state. Kept because it costs nothing.

### 7b. Native fullscreen + Game Mode — measured working (2026-10-12)

The missing half of the paragraph above. Identity was never the whole problem; the fullscreen
state was blocked by one bit.

**Why the green button is dead.** `-[WineWindow adjustFullScreenBehavior:]` in the shipped
`winemac.so` (imp `0x163c0`, disassembled 2026-09-01) grants `FullScreenPrimary` — the live green
button — only when **all** of: `styleMask & (Resizable|Utility) == Resizable`, not maximized, no
parent/latent-parent window. Anything else → `FullScreenAuxiliary`, button greyed. No registry
value touches this (every value `winemac.drv` reads was enumerated); it is driven purely by the
Win32 window style. Sekiro's own windowed mode comes up as `styleMask 0x7` — titled, closable,
miniaturizable, **no resize border** (games rarely set `WS_THICKFRAME`). That one missing bit is
the entire reason.

**The fix — the window hook.** `Helpers/WindowHook/window-hook.m` → `libwindowhook.dylib`
(began as the experiment `Scripts/sekiro/fsforce.m`), injected with `DYLD_INSERT_LIBRARIES`, ORs
`NSWindowStyleMaskResizable` into top-level titled WineWindows. Wine's own gate then computes
`FullScreenPrimary` by itself (`collectionBehavior 0xa4`, `zoomButton=ENABLED`). Measured: Sekiro
windowed → native fullscreen works.

**Game Mode then needs identity on the GAME process.** Measured with `gamepolicyd`'s own log:

| Game process identity | Native fullscreen | Result |
|---|---|---|
| `anon<wine>` (plain `wine sekiro.exe`) | yes | `gameDidLaunch:` fires, **no** gaming session, Game Mode never on |
| `app<com.decanter.gmtest>` (wine `exec`'d from a games-category bundle) | yes, frontmost | `Full screen gaming session is now active` → **`Game mode status is now on`** |

A games-category app merely *running* alongside (Decanter.app) does not count — the fullscreen
frontmost process itself must be the game. `exec`ing wine from inside a bundle's
`Contents/MacOS` is enough to give it that identity (same mechanism as `Sekiro.app`).

### 7c. Shipped as "Real game window" (`BottleSettings.nativeWindow`, 2026-10-12)

Opt-in per bottle (Configuration → Graphics); mutually exclusive with Borderless fullscreen.
Verified end to end through Decanter's own Play path on an APFS clone of `Steam-Wine11`: game
launched as `com.decanter.app.gamehost`, frontmost, green button live, and on fullscreen
`Full screen gaming session is now active` → **`Game mode status is now on`**.

**Launch path.** Steam's `-applaunch` spawns the game itself and rebuilds its environment, so
neither the hook nor an app identity can reach it. A "Real game window" bottle therefore launches
its game exe directly (the JJBA `directExecutable` path, Steam running alongside for DRM),
through **"Decanter Game.app"** (`Helpers/GameHost/`): a games-category bundle opened via
`NSWorkspace` that `exec`s Wine, so the game inherits its LaunchServices identity. `DYLD_*`
travels renamed (`DECANTER_HOST_DYLD_*`) and the host restores it right before exec.

**⚠️ The helper must NOT run from inside Decanter.app.** Launched from `Decanter.app/Contents/…`,
`gamepolicyd` treats it as an app extension ("No appex record… Finding containing app") and
never opens a gaming session — measured: nested = no Game Mode; the byte-identical bundle at a
top-level path = Game Mode on at the instant of fullscreen. So the bundle ships as a TEMPLATE in
`Contents/Resources/GameHost/` and Decanter installs it to
`~/Library/Application Support/Decanter/Decanter Game.app` before launching (replaced when a new
Decanter ships a different build; removed by the uninstaller).

**Black bars — what's fixable and what isn't (measured).**
- Sekiro is **locked to 16:9** and this screen (1470×956 points, notched) isn't, so *some* bars
  exist in every mode — including the borderless desktop, where the game draws them itself.
- In windowed mode Sekiro **snaps to its own resolution list**: asked for 1470×923 or 1470×827, it
  takes **1440×810**, the largest 16:9 size it offers that fits the width. The old 1280×720 is
  what made the bars big (≈95 pt per side → ≈15 pt).
- Wine pins a non-resizable window's content min = max = its current size, and its
  `window:willUseFullScreenContentSize:` returns `min(proposed, contentMaxSize)` — so native
  fullscreen is exactly as big as the windowed window. Lifting the pin (`unpin` + `size` test
  commands in the hook) does grow the window, but **Sekiro never re-renders on resize** — the
  drawable stayed 2160×1218 — so a bigger window would only stretch the picture. Not done.
- Net: Decanter asks Sekiro for the fullscreen content size and Sekiro picks its largest fit.
  Fullscreen content on a notched Mac = screen height minus the menu-bar strip (33 here — one
  point more than the 32 `safeAreaInsets.top` reports; `NativeWindow.fullscreenTopInset`).

**Frame pacing — measured A/B, no regression.** `Scripts/sekiro/framestat.m` (times every
`-[CAMetalLayer nextDrawable]`), title screen, screen unlocked and untouched, APFS clone:

| Mode | fps (5 s windows) | interval p99 | worst frame | hitches >25 ms | drawable wait | render size |
|---|---|---|---|---|---|---|
| Borderless desktop (today's default) | 60.0 | ≈16.85 ms | 17–20 ms (one 38 ms) | 1 in 45 s | ≈0 ms | 1472×956 |
| Real game window, native fullscreen | 59.4–61.8 | ≈17.1 ms | 17–24 ms | 0 in 40 s | ≈11.5 ms | 1440×812 |

Both locked at 60. The ≈11.5 ms drawable wait in native fullscreen is the game finishing early
and waiting for the display's refresh (vsync-locked), not a stall. Title screen, not combat —
re-measure in real play before making this anything but opt-in.

**Traps hit on the way, so nobody repeats them:**
- **SIP strips `DYLD_*`** whenever an Apple system binary is exec'd — `nohup`, `env`, `bash -c`
  and friends. Launching the injected game through `nohup` silently dropped the library, and
  probing with `env`/`bash -c` then "proved" the variable was gone. Exec wine directly; to check
  injection, look for the dylib's own log, not `env`.
- A `DYLD_INSERT_LIBRARIES` constructor runs **before** `winemac.so` is loaded, so `WineWindow`
  doesn't exist yet — the hook polls for the class instead of looking it up once.
- **Two different `gamepolicyd` sessions on macOS 26.6.** Launching a games-category app logs
  `Gaming session is now active` with status `paused`; going fullscreen logs `Full screen gaming
  session is now active` (lowercase *gaming*) and then `on`. A case-sensitive
  `CONTAINS "Gaming session"` filter misses the one that matters — use `CONTAINS[c]`.
- **A locked screen invalidates frame-pacing and Game Mode runs.** The game keeps presenting at
  60 fps to a screen nobody sees, and `loginwindow` is frontmost. Check
  `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked` before trusting a run.
- **Cooperative activation**: a background process can't make itself frontmost
  (`activateIgnoringOtherApps:` is ignored), and Game Mode keys off the frontmost app. Activate
  through LaunchServices (`open <bundle>`) or a real click.
- Don't reach for the Accessibility API on Wine windows: their menu bar and window objects
  aren't exposed (`missing value`), so System Events can't drive them.

### 7d. "Decanter isn't working" — Peggle with Real game window on (2026-10-21)

Reported as three Play clicks that each said "Started Peggle.exe as its own app", after which
the game died about 2 seconds later. **Three separate faults**, found one after the other:

1. **PopCap's DRM can't be launched directly.** Its wrapper (`drm/common/drm.xml` in the game
   folder — the whole PopCap Steam catalogue) opens a "STEAM ERROR" window instead of the game
   whenever Steam didn't start it, even with Steam running, signed in, and `SteamAppId` set.
   Real game window depends on a direct launch, so it can't apply to these games.
   `NativeWindow.requiresSteamToLaunch` detects the marker; Decanter then launches through
   `-applaunch` as usual and says why (under the toggle, and in the console at launch). Steam's
   own SteamStub wrapper (a `.bind` PE section — Sekiro, JJBA) is fine with direct launches.
2. **The direct-launch branch never waited for sign-in.** Selecting a bottle warm-starts Steam;
   Play seconds later found the process running and launched straight into a 69-second cold
   sign-in. It now joins the warm-start the way the `-applaunch` branch always has, and otherwise
   waits for `Steam.isLoggedOn(connectionLog:since:)` — `since` is steam.exe's own start time
   (`ps -o lstart`, `LC_ALL=C`), because a client killed by `wineserver -k` never logs off and
   leaves a stale `Logged On` as the last state line.
3. **Quitting Decanter while it held the launch lost it.** Measured from the unified log after
   fixes 1–2 shipped: Play at 09:20:03 joined a warm-start, the panel showed only "Opening…" and
   promised "a few seconds", and Decanter received a **Quit Apple Event from the Dock at
   09:20:47** — 22 s before Steam signed in (09:21:09). The `-applaunch` is sent only after the
   warm-start finishes, so it lived only in Decanter's memory and died with it; Steam came up
   alone and never heard about Peggle. Fixed with `AppModel.launchesWaitingForSteam`: while a
   launch is held, the panel says the game starts by itself and to keep Decanter open
   (`LaunchWait.caption`), and any quit (⌘Q, Dock, app switcher) asks **Keep Waiting / Quit
   Anyway** (`QuitGuard`). A cold `-applaunch` start is NOT held — the request is in Steam's own
   command line and survives Decanter quitting.

**Traps from this hunt:**
- **`--play-test` can't reproduce this.** It calls `launchSteam` without selecting the bottle, so
  no warm-start runs and nothing is ever held; and it reports only that Steam came up, not that
  the game did. Watch Steam's `console_log.txt` for `GameAction [AppID <id>` and `ps` for the
  game process instead.
- **`isSteamRunning()` is global.** A Steam in ANY prefix — including a test clone's — changes
  the warm-start and launch path of every other prefix, so a clone test is only valid with no
  other Steam up. And a clone's Steam signs in to the same account as the live one.
- **A missing `ExecCommandLine … -applaunch` line is not proof nothing was sent.** On 2026-10-14
  a launch reached `GameAction` with no such line. What settled this one was the unified log:
  `/usr/bin/log show … --predicate 'process == "Decanter"'` → `Handling Quit AppleEvent`, with
  a `Dock` event 1 ms earlier. (In zsh, bare `log` is a builtin, and macOS has no `timeout` — both
  make searches return nothing and look like "no matches".)

### 7e. Quit Steam, then Play: a four-minute launch (2026-10-21, same day)

Reported as "it still isn't opening when I click play", after §7d shipped. Peggle did open, but
**3 min 45 s** after the click. From the unified log, Steam's logs, and `ps`:

| time | event |
|---|---|
| 10:05:22.6 | **Quit Steam** on the Peggle bottle: `wine reg delete` (auto-start), then `wineserver -k` |
| 10:05:23.5 | Steam dies |
| 10:05:26.1 | Peggle selected → warm-start runs `wine steam.exe` **while the quit is still in its 3 s pause** |
| ~10:05:27 | the quit's straggler sweep kills the new wineserver; the Wine loader is left connected to nothing (`lsof`: unix socket `->(none)`), at 0.03 s CPU, forever |
| ~10:05:30 | Play joins the warm-start, which waits its full 150 s for a sign-in that can't come |
| 10:08:02 | timeout → `-applaunch` goes out to no Steam, so it becomes a fresh cold start |
| 10:09:15 | Peggle — after Steam's own 66 s cold sign-in |

The quit also showed **"[DEC-E09] Steam is still running, but not in Peggle Deluxe's prefix"** —
false: `isSteamRunning()` was `pgrep -f /steam\.exe`, and the hung loader's command line
(`…/bin/wine …/Steam/steam.exe`) matches it. The same false positive made Play believe Steam was
already up and skip its sign-in wait.

**Fixes.** `quitSteam` is now one task per prefix, and the warm-start and `launchSteam` wait for
it (`waitForSteamQuit`) before touching the prefix. `isSteamRunning()` matches the process's
EXECUTABLE (`ps -o comm=`, `Steam.isClient`), and the start time `isSteamLoggedOn` filters on
comes only from a command line that BEGINS with steam.exe (`Steam.clientStartDate`) — both tested
against that morning's `ps` values (`SteamProcessTests`).

**Verified live** with `--quit-then-play-test "Peggle Deluxe"`, which replays the logged sequence
(quit; select at +3 s; Play at +7 s) and waits for the game process itself: quit finished +7 s
with "stopped: true"; the warm-start's Steam started **after** it (10:19:18); signed in 10:20:25;
the held `-applaunch` went out 10:20:31; `popcapgame1.exe` at 10:20:33 — **74 s from Play**, all
of it Steam's own cold sign-in. No hung loader left behind.

**Still true:** a Steam start that hangs for any OTHER reason is still waited on for the full
150 s. `waitForSteamLogon` could stop early once no client process exists, but a first-run
bootstrap legitimately restarts steam.exe, so that check needs care; not done.

## 8. Things that are simply true and can't be engineered away

- **Rosetta** translates the x86-64 game. Not fixable — no ARM build exists. CrossOver pays the
  same tax; it just has better patches around it.
- **Shader compilation** stutters once per new effect, then never again. `DXMT_SHADER_CACHE`
  persists it across launches. **Judge performance on a second pass through an area.**
- **Battery throttling** is significant on a fanless Air — plugged in is meaningfully faster.
  (Thermal throttling was checked via `pmset -g therm` and was **not** occurring.)

## 9. Honest bottom line

The current free setup is **playable with periodic spikes**. Two fixes exist, and **both are now
proven to be about msync, which is available free** (§2 corrected the old "only CrossOver has it"
claim):

1. **CrossOver (~$74)** — the same CrossOver wine + a complete wrapper. Guaranteed to fix the
   spikes; that's why the trial ran Sekiro smoothly. The sure thing.
2. **Free path (in progress)** — the free `WS12WineCX24` (wine 9) has msync active; it just needs
   to run inside a proper Sikarugir/Kegworks wrapper for Steam networking (§2b). A Decanter *copy*
   built around that wrapper is the tracked plan.

Re-check any candidate build with `grep -ac WINEMSYNC <wine>/lib/wine/x86_64-unix/ntdll.so`.

---

## 10. Steam process/window behaviour (learned the hard way)

- **`-silent` = no window.** On a launcher bottle this makes "Launch Steam" look like it did
  nothing; the user clicks again and the *second* click surfaces the already-running instance.
  Only correct on a per-game bottle that also passes `-applaunch` (Steam is a DRM host there).
- **Two Dock tiles for one Steam** is avoidable, despite appearances. Steam re-execs itself for a
  startup update check and *both* processes stay resident; Wine gives each a tile.
  **`-skipinitialbootstrap`** → 2 processes become 1. Verified: still logs in, UI renders, and
  Steam still resolves its `client-update` hosts, so self-updating is intact.
  Do **not** add `-nobootstrapperupdate` as well — it blocks bootstrapper updates and risks
  breaking Steam months later for a cosmetic gain.
- **Killing Steam does not kill the prefix.** `explorer.exe /desktop`, `services.exe`,
  `winedevice.exe`, `rpcss.exe` survive `pkill -f steam.exe` — we found them still running hours
  later, holding stale Dock registrations that pointed at Wine builds already deleted. Correct
  teardown: `wineserver -k` for **each prefix**, then pkill stragglers.
- Steam's log line `Background command completed exit 0` for the launcher is **normal** — the
  bootstrapper hands off and exits; the client keeps running.

## 11. Networking in Swift — a 25x mistake worth not repeating

`for try await byte in URLSession.shared.bytes(from:)` iterates **one byte per await**. Measured
on the 317 MB engine download:

| approach | throughput | 317 MB takes |
|---|---|---|
| `URLSession.bytes` byte loop | **0.12 MB/s** | ~45 minutes |
| `URLSession.download(from:delegate:)` | **~3 MB/s** | **57 s** (incl. unpack + verify) |

Use a download task and report progress from `didWriteData`. This bug would have made a new
user's very first experience look like a hang.

## 12. Testing notes

- **`homeDirectoryForCurrentUser` ignores `$HOME`** — it reads the passwd entry. You cannot
  simulate a fresh Mac by overriding HOME; the app will happily read the real home. Use the
  `--install-engine` flag or **View → Setup Assistant…** to exercise first-run paths instead.
- Terminal has **Screen Recording** (screenshots work) and now **Accessibility** (System Events
  can click menu items — that's how the wizard was verified). Neither is guaranteed on another
  machine.


## 10. Removing Steam's menu-bar (systray) icon

Wine's `explorer.exe` bridges a Windows systray icon to a macOS `NSStatusItem` (top-right menu
bar). Steam always adds one. To suppress it:

```bash
pkill -f explorer.exe     # after Steam is up
```

Measured facts: explorer does **not** respawn once killed; Steam keeps running fine without it
(its windows are managed by `winemac.drv`, not explorer). The tray icon is only created after
Steam's UI loads, so Decanter sweeps `pkill` for ~60s post-launch (`suppressWineSystray`). No
Wine registry toggle exists (checked `NoTrayItemsDisplay` / policies — not honoured).
