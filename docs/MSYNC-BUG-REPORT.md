# msync provokes a fixed ~26.4 s block in Apple's IOGPU submit path (M5 / macOS 26.5.2)

**For:** `marzent/wine-msync` (msync patches for upstream wine)
**Reporter environment:** Apple M5 MacBook Air, 16 GB, macOS 26.5.2 (25F84), Rosetta 2
**Date:** 2026-07-25

> ⚠️ **This report was written by an AI assistant (Claude), working with me on my machine.**
> Every measurement in it was taken on that machine — the stacks, timings and A/B are real, not
> generated prose. But the analysis and wording are the model's, so please treat the *conclusions*
> with appropriate scepticism and ask me for any raw data you want to check. I can re-run anything.

---

## Summary

With msync enabled, a Direct3D 11 game (Sekiro, via DXMT 0.80) intermittently freezes for
**~26.4 seconds**. During the freeze the Metal command-queue thread is blocked in the kernel inside
`IOConnectTrap4`, reached via Metal's command-buffer submission path.

**The same game, same GPU stack, on a wine build without msync does not stall at all.** The
graphics components are byte-identical between the two engines, so synchronisation is the only
variable.

I am not claiming msync is buggy. It changes *when* and *from what scheduling state* the render
thread reaches the GPU submit syscall, and that appears to be enough to hit a race in Apple's
driver that the server-side sync path never times into. Reporting it here because the trigger is
specific to msync and the maintainer will recognise the interaction far faster than I can.

## The stall

Captured with `sample(1)` **during** four separate stalls. Identical every time, and accounting for
~100% of every sample window (1748–1786 of ~1786 samples):

```
Thread com.Metal.CommandQueueDispatch
  start_wqthread → _pthread_wqthread → _dispatch_workloop_worker_thread
    → _dispatch_lane_invoke → _dispatch_source_invoke → _dispatch_client_callout
      -[_MTLCommandQueue _submitAvailableCommandBuffers]      (Metal)
        -[IOGPUMetalCommandQueue submitCommandBuffers:count:]  (IOGPU)
          -[IOGPUMetalCommandQueue _submitCommandBuffers:count:]
            IOGPUCommandQueueSubmitCommandBuffers              (IOGPU)
              IOConnectTrap4                                   (IOKit)  ← blocked in kernel
```

Duration across 7 captured stalls: **26368, 26377, 26388, 26389, 26403, 26743, 26859 ms**
(mean 26 447 ms, spread 0.07–1.8%). A fixed interval, i.e. a **timeout**, not computation.

Other properties, all measured:

| property | value |
|---|---|
| process state | `U` (uninterruptible kernel wait), ~2% CPU |
| GPU `recoveryCount` | **unchanged** — no GPU reset |
| `gpuEvent` crash report | none generated |
| system log during stall | **completely empty** |
| CPU-side encode time | `encode=6.7 ms` — the buffer is built and committed normally |
| `GPUEndTime - kernelEndTime` | ≈ +0.2 ms — the GPU finishes as soon as submission returns |

## The A/B that isolates msync

Same machine, same prefix, same game, same DXMT 0.80, same MetalFX setting.
**`winemetal.so` (31 805 040 bytes) and `winemetal.dll` (73 478 bytes) are byte-identical between
the two engines** — the entire Metal path is unchanged.

| engine | msync | wineserver CPU | frames | 26 s stalls |
|---|---|---|---|---|
| upstream wine 10.0 + msync (Sikarugir `WS11Wine10.0_3`) | yes | ~0% | ~900 cb / 5 s | **~0.14/min** |
| upstream wine 11.0 (no msync) | no | **16%** | ~300 cb / 5 s | **zero** (profiler: 0 buffers >250 ms) |

The no-msync run showed the expected wineserver cost (single-threaded broker, ~100 game threads)
and **zero** submit stalls. Timeline agrees: the msync engine was promoted 2026-07-18; the stalls
were first characterised 2026-07-19.

## Ruled out by direct measurement

Each of these was tested and eliminated, not assumed:

- **Shader cost** — the pipelines inside stalled command buffers also run in *normal* buffers at
  identical thread counts in 5–12 ms (e.g. `cs_f4330ff8` @ work=262144: 5.4/5.8/7.7/8.5/9.7/11.9 ms
  normally vs 26 392 ms in a stall).
- **`MTLFence` synchronisation** — normal buffers with **236 encoders / 1183 fence waits complete
  in 15.2 ms**; the stalls had *fewer* (111 encoders / 681 waits).
- **`MTLEvent` waits** — `encodeWaitForEvent:` count is **0** in every stall.
- **CPU-side encoding** — `encode=6.7 ms`; submission blocks, not encoding.
- **Memory pressure** — stalls averaged **more** free RAM than normal play (190 MB vs 105 MB).
- **DXMT version / MetalFX** — MetalFX off does not change it; DXMT 0.74 is unusable here
  (see below).
- **GPU keep-alive process** — a separate helper that periodically submits to keep the GPU awake
  correlated at first, but the correlation disappears once msync is removed; it is downstream of
  this, not the cause.

## Reproduction

Not a minimal repro — it needs the game — but it is reliable: stalls appear within minutes of
play, on area load, on death-reload, and during ordinary combat, at ~0.14/min.

```
Game     Sekiro: Shadows Die Twice (Steam, app 814380), D3D11
DXMT     0.80 (d3d11.dll 5 350 886; winemetal.so 31 805 040 / winemetal.dll 73 478)
wine     upstream 10.0 + msync — Sikarugir-App/Engines WS11Wine10.0_3
env      WINEMSYNC=1 WINEESYNC=1 ROSETTA_ADVERTISE_AVX=1
DXMT_CONFIG  d3d11.preferredMaxFrameRate=60;d3d11.ignoreMapFlagNoWait=True;
             d3d11.sampleNaNToZero=True;d3d11.defuseFma=True
```

## Notes that may be relevant

- **esync is not an option on macOS** — `eventfd` is absent from ntdll; the `WINEESYNC` string is
  vestigial. Confirmed: the game will not start with `WINEMSYNC=0 WINEESYNC=1`.
- **CrossOver-sourced wine 9 (`WS12WineCX24.0.7_7`) could not be tested** — it has `WINEMSYNC`,
  shows 0 CrossOver markers, and Steam logs in fine under it, but DXMT requires wine 10+: the game
  dies before Metal init with both a wine-11 `winemetal.so` graft and DXMT 0.74's own matched set.
  So I could not compare a second, independent msync implementation.

## What would help

1. Is there a known interaction between msync's wait/wake path and long-blocking `IOConnectTrap4`
   submissions on Apple Silicon?
2. Is there a build-time or runtime knob to make msync fall back to server-side sync **only** for
   the threads that submit GPU work, keeping the fast path for everything else?
3. Any diagnostic you would like captured? I have a `DYLD_INSERT_LIBRARIES` Metal profiler that
   records per-command-buffer GPU time, pipelines, fence/event counts and encode duration, plus a
   stall-triggered `sample(1)` capture. Happy to run anything.

Tooling and full evidence: `Decanter/Scripts/sekiro/gpustall.m`, `docs/DXMT-STALL-REPORT.md`.
