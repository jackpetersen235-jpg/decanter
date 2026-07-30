# Three bugs in `gs_/ts_draw_arguments_marshal` (v0.80) — one causes multi-second GPU stalls

> hello, I am sending this report as a person who does not know how to code but I'm decent at using
> claude code so take this whole report with a grain of salt because I don't know what I'm doing.
> With that said there was a problem with these stall and the ai was able to track it down.
>
> -I hope this helps

**Suggested route: a GitHub issue on `3Shain/DXMT`, not email.** It contains a patch and code
references, which are far easier to act on in an issue thread. The text below works either way —
if emailing, the subject line is the heading above.

---

Hi,

I've been running Sekiro under DXMT 0.80 on an M5 MacBook Air (macOS 26.5, wine 10.0 + msync) and
tracked down a reproducible ~26 second freeze to `gs_draw_arguments_marshal` in
`src/dxmt/dxmt_command.metal`. While reading that shader I found three separate problems. One of
them explains the stall; the other two are latent but look serious.

Patch at the end. Happy to open a PR if that's easier.

## 1. `index` is never incremented — infinite loop on any multi-task batch

```metal
uint index = 0;
for(;;) {
  constant DXMTGSDispatchMarshal& task = tasks[index];
  ...
  if (task.end_of_command)
    break;
};                       // index stays 0 forever
```

The host sets `end_of_command = 1` on the **last** task only
(`dxmt_context.cpp:942` for GS, `:969` for TS):

```cpp
for (unsigned i = 0; i < task_count; i++) { ...; tasks_data[i].end_of_command = 0; }
tasks_data[task_count - 1].end_of_command = 1;
```

So with `task_count == 1` the loop terminates by luck. With `task_count > 1`, `tasks[0]`'s
`end_of_command` is 0 and the shader spins until the driver's shader timeout fires. Tasks `1..n`
also never get their `dispatch_arguments_out` written.

`ts_draw_arguments_marshal` has the identical defect.

**Note:** fixing only this did *not* fix my stall, which implies `task_count == 1` throughout the
content I tested. So this one is latent here — but it looks like a hard GPU hang for any title that
does batch multiple GS/TS draws.

## 2. Unsigned underflow on a degenerate draw

```metal
uint x = (task.draw_arguments.x - 1) / task.vertex_count_per_warp + 1;
```

With `draw_arguments.x == 0`, `(0 - 1)` wraps to `0xFFFFFFFF`, so `x` comes out enormous instead of
zero. The TS path has the same shape via `patch_count_per_instance`, and additionally divides by
`control_point_count` without checking it for zero (as the GS path divides by
`vertex_count_per_warp`).

## 3. The dispatch-size guard is a 32-bit multiply against a 64-bit limit

```metal
if (x * task.draw_arguments.y > task.max_object_threadgroups) {
```

`x` and `draw_arguments.y` are both `uint`; `max_object_threadgroups` is `ulong`. The product is
evaluated in **32 bits** and only then widened, so a large `x * y` **wraps** and slips under the
very guard that exists to reject it — and the oversized dispatch goes through.

Combined with (2), this is what I believe produces the stall: a degenerate draw inflates `x` via
underflow, the wrapped product passes the guard, and the GPU is handed a gigantic indirect dispatch.

## Evidence

Per-encoder GPU timestamps (`MTLCounterSamplingPointAtStageBoundary`), two separate stalls in
different command buffers:

| | encoders in buffer | worst encoder | share of buffer |
|---|---|---|---|
| `cb#6217` | 125 | **26,299.3 ms** | 100% |
| `cb#5728` | 136 | **26,300.7 ms** | 100% |

The two agree to **1.4 ms (0.005%)**. Variable work cannot do that — it is the same draw executing
the same arguments, which is what points at a *constant* bad value like an underflow result rather
than something data-dependent.

The slow encoder is the draw immediately following `gs_draw_arguments_marshal`, i.e. the emulated GS
draw consuming the marshalled indirect arguments. Supporting measurements:

- Wall-clock confirmed on every stall (commit → completion), so it is not a timestamp artifact.
- `Device Utilization` **98.8%** during a stall vs 75.0% in normal play — the GPU is genuinely busy.
- `dxmt-finish-thr` spends 91% of the stall in `waitUntilCompleted` → `pthread_cond_wait`. No
  CPU-side blocking: `[queue commandBuffer]` never blocks >100 ms, `IOConnectTrap4` appears in 1 of
  1303 samples, mutex contention is 26 samples across all threads.
- `IOAccelerator recoveryCount` does not change, so it is a shader timeout rather than a GPU reset.
- Encoder-time *coverage* (sum of encoder durations ÷ timeline span, raw ticks) is **1.002** during a
  stall vs a median of **6.50** in healthy buffers — one encoder spans the whole buffer.
- **Cross-layer control:** the same game on the same wine/prefix/Steam/GPU never stalls under DXVK,
  and DXVK builds *larger* command buffers (max 393 encoders vs 233). So buffer size is not the
  factor; the geometry-shader path is.
- Stalls cluster at area loads and death reloads, which is when GS-using effects are drawn.

After applying the patch below, the stalls stopped.

## What I have *not* confirmed

- I did not dump the actual `draw_arguments` values at the moment of the slow draw, so I cannot say
  for certain whether it is the underflow (2), the 32-bit wrap (3), or both together. Empirically,
  fixing (2)+(3) stopped the stalls and fixing (1) alone did not.
- The attribution is n=2 stalls. One had an exact index mapping (136/136 render encoders sampled);
  the other was uncertain by ±2 and initially led me to blame the marshal pass itself rather than
  the draw after it.
- "Stalls stopped" is from normal play, not an exhaustive soak test.

## Patch

```diff
--- a/src/dxmt/dxmt_command.metal
+++ b/src/dxmt/dxmt_command.metal
@@ ts_draw_arguments_marshal
-    uint patch_count_per_instance = task.draw_arguments.x / (uint)task.control_point_count;
-    uint x = (patch_count_per_instance - 1) / task.patch_per_group + 1;
-    if (x * task.draw_arguments.y > task.max_object_threadgroups) {
+    uint patch_count_per_instance = task.control_point_count
+        ? task.draw_arguments.x / (uint)task.control_point_count : 0;
+    uint x = (patch_count_per_instance && task.patch_per_group)
+        ? (patch_count_per_instance - 1) / task.patch_per_group + 1 : 0;
+    if (!x || (ulong)x * (ulong)task.draw_arguments.y > task.max_object_threadgroups) {
@@ (end of the ts loop)
     if (task.end_of_command)
       break;
+    index++;
   };
@@ gs_draw_arguments_marshal
-    uint x = (task.draw_arguments.x - 1) / task.vertex_count_per_warp + 1;
-    if (x * task.draw_arguments.y > task.max_object_threadgroups) {
+    uint vertex_count = task.draw_arguments.x;
+    uint x = (vertex_count && task.vertex_count_per_warp)
+        ? (vertex_count - 1) / task.vertex_count_per_warp + 1 : 0;
+    if (!x || (ulong)x * (ulong)task.draw_arguments.y > task.max_object_threadgroups) {
@@ (end of the gs loop)
     if (task.end_of_command)
       break;
+    index++;
   };
```

`!x` treats "nothing to dispatch" the same way the existing guard treats "too large", writing
`(0,0,0)`.

**One caveat on `index++` worth flagging:** it is clearly the intended behaviour, but it means tasks
`1..n` now get their dispatch arguments computed where previously they were left untouched — so it
can legitimately *increase* GPU work in titles that batch. I mention it only so it is not a surprise
in a performance regression report.

## Environment

- M5 MacBook Air, macOS 26.5.2
- DXMT v0.80 (`589adb7`), built from source with
  `-Dwine_builtin_dll=false -Denable_nvapi=true -Denable_nvngx=true`, release
- wine 10.0 + msync (Sikarugir `WS11Wine10.0_3`), Rosetta 2
- Sekiro: Shadows Die Twice (Steam 814380), DXMT installed per-game with
  `AppDefaults\sekiro.exe\DllOverrides` = `native,builtin`
- Also observed the same GS marshal pipeline in JoJo's Bizarre Adventure: ASBR, which did **not**
  stall

Thanks for DXMT — it is the difference between this game being playable and not on this machine.
