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
(2026-07-18):** measured under real Sekiro gameplay over 108 samples — `wineserver` **avg 7.9 %,
median 6.3 %, p95 18 %**, with only 2.8 % of samples above 20 %. A ~5× reduction versus 39.9 %.
Note this is NOT the ~400× the old Mythic 0.1 % figure implied; that figure was likely taken under
much lighter load. Spike relief is substantial but not proven total.

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
- `-applaunch <id>` on a **cold** Steam gets consumed before login completes. Launch Steam first,
  then send applaunch — or accept a slow first attempt.


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

## 7. Fullscreen & macOS Game Mode — both impossible with Wine

| Approach | Result |
|---|---|
| Wine exclusive fullscreen | **Traps you** — captures the display, Cmd+Tab dead |
| `CaptureDisplaysForFullscreen=n` | **Zoomed + still traps** — Wine can't switch display res without capture, so a low-res buffer renders 1:1 into a full-panel window |
| Borderless at native res | 4× the pixels — destroys the perf gained |
| Native macOS fullscreen (⌃⌘F) | **Wine doesn't implement it** — the green zoom button is greyed out |
| **Game Mode** | Requires native fullscreen → **unreachable** |

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
