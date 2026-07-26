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
