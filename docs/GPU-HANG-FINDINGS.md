# GPU hangs & performance — findings (2026-07-18 evening → 07-19)

Supersedes the GPU sections of `OVERNIGHT-FINDINGS.md`. Read this before touching
the Sekiro launcher, DXMT config, or the shader cache.

---

## Symptom 1 — ~7s whole-Mac freeze during play

**Symptom reproduced:** Display and input freeze ~7s. Whole system, not just the game.
Clusters on area load and on death/respawn, also occurs mid-gameplay.
Rate before any change: **20–36/hour** (one every 2–3 min).

**Root cause: CONFIRMED — GPU firmware fails to resume from its lowest power state.**
Not fixable from user space.

**Evidence** — all 25 `/Library/Logs/DiagnosticReports/gpuEvent-*.ips`, byte-identical:

```
restart_reason_desc      "progress timeout"
fw_power_state           0     GPU in LOWEST power state
fw_3d_state.slot0/1/2    0     all render slots IDLE
fw_ta_state.slot0/1      0     all tiler slots IDLE
fw_cl_state.slot0/1/2    0     all compute slots IDLE
command_buffer_trace_id  -1    NO command buffer existed
guilty_dm                0
signature                544
```

A runaway shader would show a **busy** slot and a **valid** command buffer id. Every slot
is empty and there is no command buffer: nothing was executing. "Progress timeout" here
means the firmware could not resume, not that a draw ran forever.

This is why **no** graphics setting, engine, DXMT build, or shader-cache change ever moved
the rate — they all change what the GPU *renders*, and this happens when it renders nothing.

**It predates all Decanter/msync work** — do not blame the engine:

```
2026-07-17 23:29:37   (night before any engine change)
2026-07-17 23:30:57
2026-07-18 12:12:12   ← engine promoted at 12:15:18, three minutes LATER
```

**Environment:** M5 MacBook Air, macOS 26.5.2 (25F84). `softwareupdate -l` → no update
available, so there is no vendor fix to install yet. Not thermal (`pmset -g therm`: no
warning ever recorded; `fw_perf_state` 12 = max in every report). Not memory (38% free).

### Workaround — `gpukeepalive`

If the GPU never reaches power state 0, it never has to resume from it. A tiny Metal
process submits a 256-byte blit on an interval, holding a non-idle power state.

- Source: `Scripts/sekiro/gpukeepalive.swift`
- Installed: `~/Applications/Sekiro.app/Contents/MacOS/gpukeepalive`
- Launcher starts it with the game, reaps it when `sekiro.exe` exits, guards against duplicates.

| interval | GPU hangs | play time | cost | note |
|---|---|---|---|---|
| 3 ms (~330/s) | 0 | 17 min | GPU util capped **68–86%** (vs 95–100% without) | **confounded** — Metal validation was also active |
| 50 ms (~20/s) | 0 | **9 min** | 0.2% of one core, no measurable GPU cost | current setting |

**Confidence: promising, NOT proven.** 9 minutes of real gameplay where the old rate
predicts 3–5 hangs. Underpowered. The 3 ms run is confounded. A ~45–60 min clean session
is the test that would settle it.

> A "10 hours, zero hangs" figure from the overnight monitor is **meaningless** — mean
> `gpu_util` over that span was 2%. The machine was idle; the game ran ~9 min.

---

## Symptom 2 — long stall on load / respawn (distinct from Symptom 1)

**Root cause: CONFIRMED — DXMT compiles pipelines synchronously; there is no async option.**

Complete list of config keys in the shipped `d3d11.dll` (`strings … | grep -oE '(d3d11|dxgi)\.'`):

```
d3d11.defuseFma          d3d11.metalSpatialUpscaleFactor   dxgi.customDeviceDesc
d3d11.ignoreMapFlagNoWait d3d11.preferredMaxFrameRate      dxgi.customDeviceId
d3d11.log                 d3d11.sampleNaNToZero            dxgi.customVendorId
                                                            dxgi.forceSDR
                                                            dxgi.handleAltTab
```

No async/background/deferred shader-compilation knob exists. When a frame needs an
uncached pipeline it **waits**. Distinguishing it from Symptom 1: `recoveryCount` does
**not** move and no `gpuEvent` report appears.

**Only mitigation is a warm cache.** Currently 1,179 pipelines in
`ShaderCache/Sekiro/shaders_320.db` (table `cache_18`).

⚠️ This was made worse during this session: the cache was cleared at 20:36 chasing a wrong
theory, then restored from a 20:19 clone — discarding everything compiled in between.
Re-warming costs one stutter per new effect. **Do not clear this cache again.**

---

## Symptom 3 — 8–11 fps (SELF-INFLICTED; the trap to remember)

**Root cause: CONFIRMED — `MTL_SHADER_VALIDATION=1` persisted through Steam's environment.**

Metal shader validation costs 10–50×. It was enabled at 20:30 as a diagnostic and removed
from the launcher minutes later — but:

```
steam.exe  started 20:30:32   ← launched WITH validation
sekiro.exe started 21:18:29   ← child of Steam, INHERITS its environment
```

Restarting **the game** could never clear it. Only killing **Steam** could. Detection:

```bash
lsof -p $(pgrep -f 'sekiro\.exe') | grep _ShaderValidation
find /private/var/folders/*/*/C/dxmt /private/var/folders/*/*/C/org.winehq.wine \
     -maxdepth 3 -name '*_ShaderValidation' -type d
```

A `com.apple.metal/<n>_ShaderValidation/` path means validation is **live** in that process.

**Fix:** kill game + `wineserver -k` + Steam + webhelper, delete the `*_ShaderValidation`
dirs, cold launch. GPU utilisation went 100% (pinned, CPU blocked at 9.5%) → **21–37%**.

**Also: validation cannot capture this game's output.** Steam spawns `sekiro.exe` as its own
process, so the game's stderr never reaches a redirect on the launcher. Validation was
structurally incapable of producing the data it was enabled for.

---

## Launcher bugs found and fixed

`~/Applications/Sekiro.app/Contents/MacOS/Sekiro` (synced to `Scripts/sekiro/sekiro-launcher.sh`)

1. **Warm start.** Phase 1 counted existing `Logged On,` lines and waited for a *new* one.
   With Steam already logged in none ever appears → burned the full ~150s before the
   applaunch. Presented as "Steam/wine opened but the game never launched."
   Now: already-logged-in → applaunch immediately. Cold path unchanged.
2. **Re-open guard.** Opening the app while the game runs sent a duplicate applaunch and
   left a stray `wine steam.exe`. Now exits immediately.
3. ⚠️ **Do NOT add window-raising via AppleScript.**
   `System Events … first process whose unix id is N` **blocks indefinitely** (measured
   >2 min) because the parent lacks Accessibility permission — it waits instead of failing.
   It hung a launch during testing, and the foreground timeout SIGTERMed the process group.

---

## Dead ends — do not re-litigate

| Hypothesis | Result |
|---|---|
| Stale/corrupt shader cache | Cleared it → hangs continued. Not the cause. |
| Reflections/Water HIGH→LOW | No effect on hangs, and **caused 9,273 `Invalid texture type` errors** (1D/invalid bound where 2D expected, 8 pixel shaders) → made it far worse. Reverted to HIGH. |
| msync / engine version / DXMT build / `winemetal` graft | Hangs predate all of it (Jul 17). |
| Thermal throttling | No warning ever recorded; perf state 12 (max). |
| Time Machine / Spotlight / Dropbox | All idle during stalls. |
| Memory pressure / paging | 38% free, swap 391 MB of 1 GB. |
| Metal validation as a diagnostic | Cannot see the game's stderr; poisons performance for hours. |
| MetalFX, frame cap, NaN guards, `ignoreMapFlagNoWait`, explorer kill | No effect on hang rate. |

---

## System state — as left

```
launcher            warm-start + re-open guard, keepalive @50ms, no MTL_ validation
DXMT_LOG_LEVEL      warn
graphics settings   RESTORED to original (Reflection HIGH, Water HIGH, Quality MEDIUM)
shader cache        1,179 pipelines, warm, do not clear
ShaderValidation    0 stale dirs
long-running procs  none (monitor + manual keepalive stopped)
protected           Sekiro.app + Steam-Wine11 (16G) untouched; wine11 fallback intact
msync               working — wineserver 39.9% → 1.4–2.5% under load
```

---

## Next candidates, ranked

1. **Settle the keep-alive.** 45–60 min clean session at 50 ms, then compare `recoveryCount`
   against the 20–36/hour baseline. If hangs return, step 50 → 20 → 10 ms. This is the only
   open question about the workaround.
2. **Report to Apple.** 25 identical reports with `fw_power_state=0` + `command_buffer_trace_id=-1`
   is unusually clean evidence for a firmware bug. Recheck `softwareupdate -l` periodically.
3. **Warm the shader cache** through normal play to reduce Symptom 2. Track
   `select count(*) from cache_18`; stalls fall as it grows.
4. **Untested DXMT knobs:** `dxgi.forceSDR`, `dxgi.handleAltTab`. Low expected value —
   neither touches power management or compilation — but they are the only unexplored config.
5. **Unexplained, low priority:** wine was flagged dirtying 2.1 GB of file-backed memory.
   No stall was ever correlated with it. Probably the SQLite WAL.
