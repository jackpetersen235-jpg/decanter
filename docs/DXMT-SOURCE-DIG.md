# DXMT 0.80 source analysis (MIT-licensed, cloned at v0.80 / 589adb7)

Read the code instead of inferring from black-box measurement. Two candidate mechanisms were
ELIMINATED and one concrete blocking path was found.

## Architecture

D3D11 calls accumulate into a `CommandChunk`. A chunk becomes exactly one `MTLCommandBuffer`,
encoded and committed on a dedicated `dxmt-encode-thread`; a `dxmt-finish-thread` calls
`waitUntilCompleted` and recycles the slot. Chunks live in a ring of **`kCommandChunkCount = 32`**,
and the main queue is created with `newCommandQueue(32)` (Metal `maxCommandBufferCount`).

## Batching: there is NO size bound

`InvalidateCurrentPass()` ends a Metal pass but only commits when `promote_flush` is set
(`d3d11_context_impl.cpp:4281`). Every assignment of `promote_flush = true`:

- **queries** — `D3D11_QUERY_EVENT`, `TIMESTAMP`, `TIMESTAMP_DISJOINT`, occlusion
- **readback copies** into staging (`:3790 :3806 :3895 :3907 :3930`)
- **Present** (swapchain calls `Commit()` directly)

No encoder-count, memory, or time trigger exists. A title that runs many passes without a query or
readback accumulates every encoder into one command buffer until Present — which explains the
measured distribution (Sekiro 100–175 encoders, 24.6% >=100; JJBA max 48).

## ELIMINATED by combining source with captured stacks

1. **32-chunk backpressure.** The producer blocks in `chunk_ongoing.wait(kCommandChunkCount - 1)`
   when 32 chunks are in flight. Not it: the profiler recorded `outstanding@commit=1` on every
   stall, and in the stall stacks `dxmt-encode-thread` is *idle* waiting on `ready_for_encode`.
   The ring is nearly empty, not full.
2. **Slow execution of large buffers.** If large buffers were merely slow, work would queue behind
   them. Nothing is backed up — the encode thread has nothing to do.

Thread states during one captured stall:

| thread | state |
|---|---|
| `com.Metal.CommandQueueDispatch` | blocked in `IOConnectTrap4` (submitting) |
| `dxmt-finish-thr` | `waitUntilCompleted` → `pthread_cond_wait` |
| `dxmt-encode-thr` | idle, blocked on its own `ready_for_encode` wait |
| main thread | `mach_msg` (normal loop) |

## CANDIDATE FOUND: the resource-initializer upload queue is only 2 deep

```
game D3D11 thread
  → CommitCurrentChunk()                    dxmt_command_queue.cpp:80
    → initializer.flushToWait()             takes std::lock_guard(mutex_)
      → flushInternal()                     dxmt_resource_initializer.cpp:293
        → upload_queue_.commandBuffer()     ← BLOCKS when 2 are in flight
```

`upload_queue_ = device.newCommandQueue(kResourceInitializerChunks)` with
**`kResourceInitializerChunks = 2`** (`dxmt_resource_initializer.hpp:13`). Metal blocks in
`commandBuffer` once `maxCommandBufferCount` are in flight, so the **game thread** stalls there —
while holding `mutex_`.

Fits the evidence: the initializer is the asset-upload path (busiest at area loads and
death-reloads, where stalls cluster); depth 2 is very shallow versus the main queue's 32; and JJBA
— small reused stages, little streaming — would rarely saturate it.

**Critically, this is invisible to our profiler.** `gpustall.m` hooks `[queue commandBuffer]` but
timestamps *after* the call returns, so time blocked inside it is never attributed. That matches
the open contradiction: the user perceives pauses the profiler does not record, and vice versa.

## NOT a conclusion

Unverified. To test it, hook `[queue commandBuffer]` to measure time spent *inside* the call, and
label which queue (main vs upload) it belongs to. Six causal claims were made and falsified earlier
in this investigation; this one has a mechanism, a workload match, and an explanation for a known
blind spot — but it has not been measured.

Also still open: whether `gpuMS` (`GPUEndTime - GPUStartTime`) is valid at all.

## ⭐ DXMT ALREADY INSTRUMENTS ITS OWN BLOCKING — do not rebuild it

`d3d11_swapchain.cpp:814-891` draws a diagnostic overlay via `HUDState`, which wraps Apple's
`MTLDeveloperHUDProperties` — i.e. it is driven by **`MTL_HUD_ENABLED=1`**, already the default in
`Sekiro.app` (`MTL_HUD_ENABLED="${SEKIRO_HUD:-1}"`). No rebuild, no hooks, no code changes.

Lines it prints, and what each one settles:

| HUD line | fields | answers |
|---|---|---|
| `Commit: N -avg -max` | `command_buffer_count`, `commit_interval` avg/max | the 32-chunk ring wait — how long the game thread blocks for a free chunk |
| `Sync: N avg  S lat L` | `sync_count`, `sync_interval`, `event_stall`, `present_latency_interval`, `latency` | event stalls **and** the `PresentBoundary` frame-latency block |
| `Encode: p+f+d=t` | `encode_prepare_interval`, `encode_flush_interval`, `drawable_blocking_interval` | encode cost and **blocking on drawable acquisition** |
| `Render:/Clear:` | pass counts + how many were optimized away | pass structure per frame |

This covers every blocking point found in this document, measured by DXMT itself, in milliseconds,
per frame — including `drawable_blocking_interval`, which nothing in our own profiler measures.

### Game-thread blocking points, complete list

1. `PresentBoundary()` → `frame_latency_fence_.wait(frame_count - max_latency_)`, **default
   `max_latency_ = 3`** (`dxmt_command_queue.hpp:153`) — blocks EVERY present until frame N-3
   finishes. Timed as `present_latency_interval`.
2. `CommitCurrentChunk()` → `chunk_ongoing.wait(31)` — ELIMINATED (outstanding was 1).
   Timed as `commit_interval`.
3. `flushToWait()` → `flushInternal()` → `upload_queue_.commandBuffer()` with
   **`maxCommandBufferCount = 2`** — blocks while holding `mutex_`. **NOT timed by the HUD**; this
   remains the one candidate the built-in instrumentation does not cover.
4. `WaitUntilGPUIdle()` → `WaitCPUFence` — swapchain resize / colorspace change / destruction only.
5. `dxmt_presenter.cpp:123` `frame_presented_.wait(frame_requested_)` — presenter sync.

### Plan (revised — build far less)

1. **Turn the HUD on and read it during a stall.** Zero code. Settles points 1, 2 and the encode
   path immediately, and `drawable_blocking_interval` is a candidate nothing else measures.
2. Only if the HUD exonerates all of those, instrument point 3 (time spent *inside*
   `[queue commandBuffer]`, tagged by queue) — the one gap in both DXMT's instrumentation and ours.
3. Separately, the `gpuMS` validity check (wall clock commit→completion) still gates everything.


## 🔬 ignoreMapFlagNoWait A/B — first arm result (2026-07-25)

**`d3d11.ignoreMapFlagNoWait=False`: 14.6 min of normal play, ZERO long pauses.**
P(0 by chance) = 3.0% at the pooled all-night rate (0.24/min), 0.07% at the factorial-cell rate
(0.5/min). Short ~7 s firmware freezes occurred throughout as expected (keep-alive off,
recoveryCount 12→26) and are unrelated.

The mechanism is source-confirmed, unlike every earlier candidate:

```cpp
// d3d11_context_imm.cpp:238
if (ignore_map_flag_no_wait_)
    MapFlags &= ~D3D11_MAP_FLAG_DO_NOT_WAIT;
```

With the flag TRUE the game's non-blocking Map request is stripped, so instead of returning
`DXGI_ERROR_WAS_STILL_DRAWING` and letting the game continue, control falls through to
`Flush(); cmd_queue.WaitCPUFence(...)` — **blocking the GAME thread** until the GPU catches up.
That blocking is counted in `sync_count`/`sync_interval`, which nothing in this project ever read,
and it would NOT appear in our `gpuMS` metric at all.

DXMT applies this workaround to exactly one title in its built-in config
(`SONIC_X_SHADOW_GENERATIONS.exe`, `config.cpp:50`). It is not a general setting and was never
intended for Sekiro.

**NOT YET CONFIRMED.** This is one arm. The control arm (flag TRUE, same session length, same
play pattern) has not been run, and tonight produced several promising clean runs that later
collapsed. Do not promote the setting until the TRUE arm reproduces the pauses.

Also unresolved: the flag may exist in Sekiro.app for a *rendering* reason, not a performance one.
Watch for visual artifacts with it off before making it permanent.


### Both arms, as run (2026-07-25, investigation stopped here)

| arm | flag | played | long pauses |
|---|---|---|---|
| 1 | `ignoreMapFlagNoWait=False` | 14.6 min | 0 |
| 2 | `ignoreMapFlagNoWait=True` | 6.2 min | 0 |

Arm 2 was stopped early by request, so it is **not** a valid control — 6.2 min is below the
threshold and cannot distinguish "flag is harmless" from "not enough time". **The flag is neither
confirmed nor cleared.**

What IS notable: ~21 min of play across both arms with zero long pauses, on a config of
**MetalFX ON + keep-alive OFF** — the same combination that earlier went 30.9 min clean. Whatever
else is true, that config has now accumulated ~52 min of long-pause-free play.

Investigation stopped here. If resumed, arm 2 needs a full ~15 min run.
