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

## 2. ⚠️ The Wine build matrix — THE central constraint

**No free Wine build has both things needed.** This is structural, not bad luck:

| Build | Version | Steam login (TLS) | msync/esync | Verdict |
|---|---|---|---|---|
| Mythic (GPTk) | 7.7 | ❌ too old for modern Steam | ✅ 59/77 hits in ntdll | can't launch Steam games |
| Whisky 2.5 (CrossOver 22) | 7.7 | ❌ same | ✅ 27/28 hits | can't launch Steam games |
| **WhiskyWine 11.0** | 11.0 | ✅ works | ❌ **none at all** | **current setup — spikes** |
| Gcenx Wine Staging | 11.10 | ✅ downloads | ❌ none | Steam UI renders **black** |
| CrossOver (paid) | 7.7+patched | ✅ | ✅ | **only build with both** |

**Why:** `msync` is a **CodeWeavers patch** existing only in wine-7.7-era CrossOver forks.
Upstream wine 11 replaced it with `ntsync`, which **requires a Linux kernel driver** — so
**wine 11 on macOS has no fast sync whatsoever**. Meanwhile Steam's client TLS has moved past
what wine 7.7 can speak. The free builds are frozen on opposite sides of that split.

Verify sync support before trusting any `WINEMSYNC=1`:
```bash
strings <wine>/lib/wine/x86_64-unix/ntdll.so | grep -ic msync   # 0 = NOT supported
```
> We exported `WINEMSYNC=1` for hours on wine 11 where it **did nothing**. Assumption, not measured.

## 3. The frame spikes — diagnosed, not fixed

**Cause:** wine 11 has no fast sync, so Sekiro's **103 threads** round-trip every mutex/event
through `wineserver` over IPC.

**Evidence (measured):**

| | wineserver CPU |
|---|---|
| WhiskyWine 11 (no msync) | **39.9 %** |
| Mythic/Whisky2.5 + `WINEMSYNC=1` | **0.1 %** |

That ~400× drop proves the mechanism. But msync only exists on wine 7.7, which can't log Steam
in → can't launch a Steam-DRM game. **Dead end without CrossOver.**

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

Windowed **1280×832 + MetalFX 2×** is the optimum, not a consolation prize.

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

The current free setup is **playable with periodic spikes**. The only known fix is **CrossOver**
(~$74) — the sole build with msync *and* current TLS. That is exactly why the expired CrossOver
trial ran Sekiro smoothly and nothing free since has.

If the Whisky fork ever ports msync/ntsync to its wine 11 build, this resolves itself — re-check
with the `strings ... | grep -ic msync` test above.

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
