# Sekiro on DXMT 0.80 — long GPU-side stalls during gameplay

Upstream-ready bug report + isolation attempt record. **2026-07-19.**

---

## PART 1 — Isolation result: FAILED. What blocked it.

**Objective:** identify the pipeline hash executing during stalls.
**Outcome:** not obtained. The blocker is a tooling limit, not a measurement mistake.

### What blocked it

`DXMT_LOG_LEVEL=debug` **does not emit per-draw or per-pipeline-execution records.**
A bounded debug window covering **10 stalls / 133 s of blocked time / 9.3 min of play**
produced **41 log lines, 8 KB total**:

| count | line |
|---|---|
| 30 | `warn: CreateInputLayout: Vertex shader expects TANGENT_2 …` |
| 4 | `warn: CreateInputLayout: Vertex shader expects POSITION_1 …` |
| 3 | `info: Setting display mode: 1470x956@60` |
| 1 each | `Found config env`, feature level ×2, `CreateSamplerState` border colour |

Verbosity **was** applied — `Found config env` is an `info`-level line, so the setting took
effect. DXMT 0.80 simply logs API validation, startup state, and error conditions. It has no
frame/draw/pipeline trace. Pipeline hashes appear in its output **only inside error messages**
(e.g. an earlier session's `pipeline: "(null)", UID: 2A5CF0D659CD…`). This session produced
zero errors, so nothing named an executing pipeline.

Correlation was not the limiting factor: DXMT writes no timestamps, so every log line was
stamped with wall-clock time on arrival and intersected against the 1 Hz stall windows. The
timeline worked. **There was simply nothing in the log to correlate against.**

### What would be needed

1. **Full Xcode** (not Command Line Tools) → `xctrace` / **Metal System Trace** / GPU frame
   capture. This is the direct path: a Metal System Trace shows per-command-buffer GPU timing
   and would name the long-running encoder. Verified unavailable here:
   ```
   xctrace version
     → error: tool 'xctrace' requires Xcode, but active developer directory
       '/Library/Developer/CommandLineTools' is a command line tools instance
   xcode-select -p → /Library/Developer/CommandLineTools
   /Applications/Xcode.app → not installed
   ```
   `MTL_CAPTURE_ENABLED` can write a `.gputrace`, but **opening one also requires Xcode**.
2. **A DXMT build with draw-level instrumentation** — needs building from source, or a debug
   build from upstream.
3. **Upstream guidance** on what diagnostic they want; DXMT does not use GitHub Issues
   (Discord only), so the report below is written for that channel.

---

## PART 2 — The bug report

### Summary

Sekiro: Shadows Die Twice stalls for **2–25 s at a time, repeatedly**, on Apple M5 / macOS 26.5.2
under wine 10 + DXMT 0.80. During a stall the GPU is pinned at 100% utilisation while the game
process sits in uninterruptible kernel wait at ~2% CPU. **23% of measured playtime is spent
blocked.** This is not a GPU hang — no reset occurs and the firmware watchdog never fires.

### Environment

```
Hardware      Apple M5 MacBook Air, 16 GB unified memory
OS            macOS 26.5.2 (25F84) — no update available
Wine          upstream 10.0 + msync (Sikarugir WS11Wine10.0_3)
DXMT          0.80 (latest release), d3d11.dll 5,350,886 bytes
              winemetal.so 31,805,040 / winemetal.dll 73,478
Game          Sekiro: Shadows Die Twice, Steam build, 14 GB install
DXMT_CONFIG   metalSpatialUpscaleFactor=1.5; preferredMaxFrameRate=60;
              ignoreMapFlagNoWait=True; sampleNaNToZero=True; defuseFma=True
              DXMT_METALFX_SPATIAL_SWAPCHAIN=1
Settings      Quality MEDIUM, Reflection HIGH, Water HIGH, 1470x956 fullscreen
```

### Stall signature — 22 stalls captured across two sessions, 1 Hz sampling, 100% consistent

```
ts        gpu_util recov  cpu   state  free%
11:12:16    80      49   461.7   Rs     38     ← normal gameplay
11:12:17    84      49   482.1   Us     38     ← transition
11:12:18   100      49    11.7   Us     38
11:12:19   100      49     2.2   Us     42
  ...      100      49     2.0   Us     42     ← 24 seconds
11:12:43   100      49     1.8   Us     42
11:12:44    86      49   298.3   Rs     38     ← recovers on its own
```

| property | value |
|---|---|
| process state | `U` — uninterruptible kernel wait |
| game CPU | ~2% (blocked, not spinning) |
| GPU utilisation | **exactly 100%, pinned, never fluctuating** |
| `recoveryCount` | **unchanged** — no GPU reset |
| duration | 2–25 s, median 17 s |
| frequency | 10 stalls in 9.3 min (23% of playtime blocked) |
| trigger | area load **and** mid-gameplay; not tied to loading screens |
| recovery | always self-recovers |

The GPU **is executing** — which is why no `progress timeout` fires (that requires progress to
*stop*). Something is taking tens of seconds to complete on the GPU.

### Ruled out, each with evidence

| Hypothesis | Evidence against |
|---|---|
| GPU firmware hang | `recoveryCount` never moves during stalls; zero `gpuEvent` reports. (This machine *also* has a separate, unrelated firmware idle-wake bug — distinct signature: power state 0, all slots idle, `command_buffer_trace_id=-1`.) |
| Shader compilation | Pipeline cache frozen at **1,189** rows across stalls; `MTLCompilerService` at 0.0% CPU; cache WAL untouched for 10 min around a stall |
| Memory pressure | **Disproved by inversion** — freeing ~2 GB made it *worse*: 3 stalls/10 min at 88 MB free vs **9 stalls/4 min at 4.1 GB free**, free memory flat at 53–58% throughout |
| `ignoreMapFlagNoWait` | Identical 24 s stall with it set `False` |
| Disk I/O | 158 GB free, 21 GB/s reads, 0 local snapshots |
| Metal shader validation | 0 `*_ShaderValidation` dirs, 0 open handles |
| DXMT render errors | 0 `Invalid texture type`, 0 device errors in the affected session |
| Thermal | No thermal warning ever recorded; `fw_perf_state` 12 (max) |

### Only shader-adjacent signal available

```
30 x  CreateInputLayout: Vertex shader expects TANGENT_2 but it's not in input layout descriptors
 4 x  CreateInputLayout: Vertex shader expects POSITION_1 but it's not in input layout descriptors
```

Unbound vertex attributes are undefined in Metal. Whether this relates to the stalls is
**unverified** — noted because it is the only shader-level anomaly the logs expose, not because
there is evidence connecting it.

### Why this looks like a known DXMT class

The DXMT changelog documents this failure mode being fixed per-title:

- **v0.70** — Elite Dangerous hang, "unoptimized compute shader with thousands of branches";
  also hang conditions in Shadow of the Tomb Raider and Genshin Impact from shader sync
- **v0.80** — resource synchronisation via `MTLFence` + intrapass barriers; fixed infinite
  hangs on launch in Shadow of War

A pathological shader taking tens of seconds fits every observation here.

### What we can provide on request

- 1 Hz CSV of all 22 stalls (gpu_util, recoveryCount, cpu, state, rss, pageins, free%)
- The debug-level log for the window covering 10 stalls
- Any additional capture, given instructions for a diagnostic that works **without full Xcode**

### The ask

What diagnostic will name the executing pipeline on a Command-Line-Tools-only machine? If the
answer is "none — install Xcode," that is an acceptable answer and we will install it.

---

## Appendix — reproduction reliability

Stalls occur within minutes of starting play, on area load and during ordinary combat and
traversal. Not tied to a single area or effect. Across two sessions: **22 stalls**, longest 25 s,
median 17 s, ~23% of playtime blocked. No configuration change tested has altered the rate.
