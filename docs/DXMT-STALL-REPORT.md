# Sekiro on DXMT 0.80 — long GPU-side stalls during gameplay

Upstream-ready bug report + isolation attempt record. **2026-07-19.**

> # ⛔ 2026-07-24 — THE CENTRAL CONCLUSION OF THIS REPORT IS WRONG.
>
> The stalls are **not** a pathological shader. Measured directly, in-game, with the profiler in
> PART 3. Two independent lines of evidence, from 3 captured stalls:
>
> **1. The duration is FIXED.** 26402.6 / 26388.8 / 26384.5 ms — mean 26392 ms, **spread 18 ms
> (0.07%)**, across three unrelated moments (area load, death-reload, ordinary combat). Scene-
> dependent GPU work cannot reproduce to 0.07%. That is a **timeout / fixed-length wait**.
>
> **2. Every suspect shader has an alibi.** The pipelines inside the slow command buffers also run
> in *normal* buffers, at identical thread counts, in **13–15 ms**. `cs_f4330ff8` at `work=262144`:
> 5.4 / 5.8 / 7.7 / 8.5 / 9.7 / 11.9 ms normally, versus 26 392 ms inside a stall. Same shader, same
> work, ~3000x the time. The shaders are bystanders, not the cause.
>
> **3. The Metal timestamps are inverted.** `sched` (`GPUStartTime - kernelEndTime`) is **negative
> by exactly the stall duration**, so `GPUEndTime - kernelEndTime ≈ +0.2 ms`. The GPU work
> completed essentially instantly once submission finished; the 26.4 s sits *before* that, which is
> what a **wait** looks like, not execution.
>
> **UPDATE 2026-07-24, later the same day — the `MTLFence` hypothesis is ALSO refuted.** It was
> measured directly (encoder-level `updateFence:`/`waitForFence:` and command-buffer
> `encodeWaitForEvent:`), and fence volume does not predict stalls — if anything it anticorrelates:
>
> | | encoders | fenceWait | GPU time |
> |---|---|---|---|
> | normal | 236 | 1183 | **15.2 ms** |
> | normal | 145 | ~900 | ~13 ms |
> | **stall** | **111** | **681** | **26 859 ms** |
> | **stall** | **111** | **685** | **26 378 ms** |
>
> Buffers with 2x the encoders and 1.7x the fence waits complete in 15 ms. `eventWait=0` in both
> stalls, so `MTLEvent` is out too. **DXMT's synchronisation is not the cause.** The downgrade path
> is also closed: official DXMT ships only the *builtin* variant (tested — white screen + wine
> debugger, reverted), and frankea/Whisky never shipped a pre-0.80 DXMT (v3.0.0 is Wine 11 + DXVK
> only; DXMT arrives in v3.1.0, already 0.80).
>
> # ✅ 2026-07-24 — ROOT CAUSE FOUND. It is not DXMT at all.
>
> Thread stacks captured **during** four stalls (`Scripts/sekiro/stallstack.sh`) are identical, and
> account for ~100% of every sample window (1748–1786 of ~1786 samples each):
>
> ```
> Thread com.Metal.CommandQueueDispatch
>   -[_MTLCommandQueue _submitAvailableCommandBuffers]   (Metal)
>     -[IOGPUMetalCommandQueue submitCommandBuffers:count:]  (IOGPU)
>       IOGPUCommandQueueSubmitCommandBuffers             (IOGPU)
>         IOConnectTrap4                                  (IOKit)  ← blocked in the kernel
> ```
>
> **The stall is Metal's command-buffer SUBMIT syscall blocking inside Apple's IOGPU kernel
> driver** for a fixed ~26.4 s. This is below DXMT, below wine, below anything user space can patch.
> It explains every observation at once: state `U` (literally an uninterruptible kernel trap), ~2%
> CPU, device reported busy while nothing progresses, no firmware watchdog, and the fixed duration
> (a driver timeout, not computation).
>
> Ruled out **by direct measurement**, in order: shader cost (alibis), `MTLFence` (fence-count
> alibis), `MTLEvent` (`eventWait=0`), CPU-side encoding (`encode=6.7 ms` — the buffer is built and
> committed normally; the block is in *submission*), and memory pressure (stalls averaged **more**
> free RAM than normal play: 190 MB vs 105 MB). The system log emits **nothing** during a stall.
>
> **Remaining local variable: `gpukeepalive`** — a second process submitting to the same GPU 20x/s,
> which *we* added for the unrelated firmware bug. It must be ruled in or out before this is filed
> as an Apple driver bug: `gpuprof-direct.sh --no-keepalive`. If stalls persist without it, the
> only realistic paths are an Apple bug report or a macOS update.
>
> ---
>
> **Superseded intermediate hypothesis (kept for the record): a CPU-side stall.** `GPUEndTime - kernelEndTime`
> is ~+0.2 ms while `GPUStartTime` is ~26 s earlier — i.e. the GPU finished the moment the CPU
> stopped feeding it, and the 26 s was spent with the command buffer **open on the CPU**. That fits
> the process sitting in state `U` at ~2% CPU (blocked in a syscall, not computing) and the device
> reading "busy" because a buffer is occupying the queue. Two instruments now test this:
> `encode=` (time from `[queue commandBuffer]` to `commit`) in the profiler, and
> `Scripts/sekiro/stallstack.sh`, which runs `sample` **during** a stall to name the blocking call.
>
> Everything below PART 2 predates this measurement. The "Why this looks like a known DXMT class"
> section reasoned from a changelog to a conclusion that direct measurement has now falsified —
> left in place as a record of how a plausible inference survived seven rounds of elimination
> without ever being tested.

> **2026-07-21 — PART 1 IS OBSOLETE. The isolation is no longer blocked, and Xcode is not needed.**
> "The ask" at the end of this report has been answered locally: `Scripts/sekiro/gpustall.m`, a
> `DYLD_INSERT_LIBRARIES` dylib that swizzles Metal directly, records per-command-buffer GPU time
> and names the pipelines inside the slow ones. Built and verified end-to-end on this machine
> (x86_64 under Rosetta, `AGXG17GFamilyCommandBuffer`). **Do not install Xcode for this.**
> Run it: `bash Scripts/sekiro/gpuprof-run.sh --force`. See PART 3.

---

## PART 1 — Isolation result: FAILED. What blocked it. *(superseded — see PART 3)*

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

**Answered 2026-07-21 — see PART 3. No Xcode required; upstream does not need to advise on this.**

---

## PART 3 — The diagnostic, built locally (2026-07-21)

`Scripts/sekiro/gpustall.m` → `libgpustall.dylib`. Injected with `DYLD_INSERT_LIBRARIES`, it
swizzles the Metal command-buffer and encoder classes and logs, for every command buffer whose
**GPU** execution exceeds a threshold, the encoders it held and the pipeline bound to each.

**Why this is possible at all:** `wine` here is ad-hoc signed with **no hardened runtime and no
library validation** (`codesign -dvvv` → `flags=0x2(adhoc)`), so dyld does not strip the insertion;
and env is inherited down the whole launcher → `steam.exe` → `sekiro.exe` chain — the same property
that made the `MTL_SHADER_VALIDATION` trap so sticky, used deliberately this time.

```bash
bash Scripts/sekiro/build-gpustall.sh      # x86_64 — MUST match the Rosetta wine tree
bash Scripts/sekiro/gpuprof-run.sh --force # plays the game with profiler + 1 Hz sampler attached
bash Scripts/sekiro/gpustall-report.sh <STAMP>
```

`gpuprof-run.sh` **does not modify `Sekiro.app`** — it sets env and execs the bundle's existing
launcher. Stop using it and nothing has changed.

### What the report decides

1. **Prime suspect** — pipelines ranked by *enrichment*: how much more often a pipeline appears in
   slow command buffers than in normal ones. Raw frequency is useless on its own, because a
   pipeline that runs every frame is inside 100% of slow buffers whether or not it is the cause.
   The tool therefore also samples every Nth normal buffer as a baseline.
2. **One fat encoder, or a backlog?** — the report's central premise is that a *single* encoder
   runs for seconds. The competing explanation, a queue of ordinary work the render thread is
   waiting behind, produces an identical outward signature (100% GPU, thread in `U`, no watchdog).
   Queue depth at commit separates them: shallow ⇒ one runaway encoder, deep ⇒ backlog. **This
   premise has not yet been tested against real gameplay — it is an inference, not a measurement.**
3. **Renderer vs tiler split**, from the new sampler columns.

### Verified before first use

Built an x86_64 harness with a deliberately pathological compute kernel. The profiler armed under
Rosetta, named the pipeline (`slow_kernel`, 64.9 ms GPU, queue depth 1), correctly ignored 20 cheap
dispatches, named a render pipeline (`vs:vmain/fs:fmain`), and its arming gate refused a non-Sekiro
process. Report ranking was checked against a synthetic session where a ubiquitous pipeline and a
rare heavy one both appear in every stall — it ranked the heavy one 50× and the ubiquitous one 1.0×.

**One bug found this way, worth remembering:** the swizzles of `new*PipelineState*` and the
interposes of `MTLCopyAllDevices` / `MTLCreateSystemDefaultDevice` all return **+1 retained**
objects (`NS_RETURNS_RETAINED` in `MTLDevice.h`). Wrapping them under ARC without
`__attribute__((ns_returns_retained))` returns +0 instead, and the caller's release lands on an
object nobody retained → `SIGSEGV` in `objc_autoreleasePoolPop`. Every run crashed at exit while
the same binary without the dylib exited 0. **Injected into the game instead of a harness, this
would have looked exactly like a DXMT crash and cost a whole session.** Check exit codes, not just
log output — piping through `tail` hides them.

### Sampler additions

`Scripts/sekiro/gpusample.sh` captures `Renderer Utilization %`, `Tiler Utilization %`,
`CurrentPowerState` and submission rate, none of which earlier sessions recorded — they only took
`Device Utilization %`, which is the max of renderer and tiler and cannot distinguish them.

⚠️ This partly corrects `VALIDATION-SESSION-ABORTED.md`, which states GPU power state is visible
only in `gpuEvent-*.ips` crash reports. `CurrentPowerState` / `DriverPowerState` **are** live in
`ioreg -r -d 1 -c IOAccelerator`. **But measured 2026-07-22: `MaxPowerState` on this GPU is 1**, so
the live field is a coarse 0/1 flag, not the multi-level `fw_power_state` from the crash reports.
It answers "is the GPU at its lowest state" — which is the keep-alive's actual question — and
nothing finer. Don't read it as a DVFS/clock level.

⚠️ **The `submits` column does not work.** `fSubmissionsSinceLastCheck` reads 0 in every sample,
blocked and active alike, so its delta is always 0. It is kept in the CSV but no conclusion may be
drawn from it until the field is validated. An earlier version of the report inferred "no new
submissions while blocked" from it — that conclusion fired unconditionally and meant nothing.

---

## Appendix — reproduction reliability

Stalls occur within minutes of starting play, on area load and during ordinary combat and
traversal. Not tied to a single area or effect. Across two sessions: **22 stalls**, longest 25 s,
median 17 s, ~23% of playtime blocked. No configuration change tested has altered the rate.
