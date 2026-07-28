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


### ❌ FALSIFIED 2026-07-25: ignoreMapFlagNoWait is NOT the cause

With `ignoreMapFlagNoWait=False` **and** the keep-alive ON — the never-before-tested combination
of both candidate fixes — a **23 s stall occurred**, timed by the user.

So the 14.6 min clean arm was luck, exactly as the 3% figure allowed. The flag joins the list.

Also settled: **the long stalls are real and perceptible.** The user timed this one at 23 s
unprompted, which retrospectively confirms that the earlier session where he counted zero was a
true absence rather than inattention — and that the `gpuMS` metric's false positives are a
separate problem from the stalls themselves.

**Twelve eliminated causes:** pathological shader, MTLFence, MTLEvent, CPU-side encoding, memory
pressure, DXMT version, MetalFX, msync, the wine 10 build, gpukeepalive, DXMT chunk backpressure,
ignoreMapFlagNoWait.

No candidate remains. The stall is real, reproducible, blocks in Apple's IOGPU submit path, and
resists every user-space variable tested.

## Building DXMT from source with DXMT_DEBUG (recipe — toolchain was deleted)

Done 2026-07-27. The build **compiles cleanly but does not run** (see below), so the 4.1 GB
toolchain was deleted afterwards. This is the exact recipe to recreate it; `DEVELOPMENT.md`
overstates the work — Wine and llvm-mingw are prebuilt downloads, not source builds.

**Prerequisites that needed the user:** full Xcode (App Store), then `sudo xcodebuild -license`
and `sudo xcodebuild -downloadComponent MetalToolchain`. The Metal Toolchain is a SEPARATE
component in Xcode 26 — `xcrun -f metal` returns a path even when it is missing, and only fails at
first use, so check by actually compiling a `.metal` file. It also mounts as a cryptex a few
seconds after download; an immediate re-test can still fail.

```sh
python3 -m pip install --user meson ninja cmake     # no Homebrew needed
export PATH="$HOME/Library/Python/3.14/bin:$PATH"

git clone --depth 1 --branch v0.80 https://github.com/3Shain/DXMT.git dxmt && cd dxmt
git submodule update --init --recursive             # REQUIRED; meson errors out without it
mkdir -p toolchains && cd toolchains
curl -L -o wine.tar.gz       https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
curl -L -o llvm-mingw.tar.xz https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/llvm-mingw-20251216-ucrt-macos-universal.tar.xz
mkdir -p wine llvm-mingw
tar xzf wine.tar.gz -C wine
tar xJf llvm-mingw.tar.xz -C llvm-mingw --strip-components=1
git clone --depth 1 --branch llvmorg-15.0.7 https://github.com/llvm/llvm-project.git llvm-project
cd ..

cmake -B toolchains/llvm-build -S toolchains/llvm-project/llvm -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PWD/toolchains/llvm" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DLLVM_HOST_TRIPLE=x86_64-apple-darwin -DLLVM_ENABLE_ASSERTIONS=Off -DLLVM_ENABLE_ZSTD=Off \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off \
  -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off
ninja -C toolchains/llvm-build install               # ~1-3 h; llvm-config is intentionally absent

export PATH="$PWD/toolchains/llvm-mingw/bin:$PATH"
meson setup build-debug --cross-file build-win64.txt --buildtype release \
  -Ddxmt_debug=true -Dnative_llvm_path="toolchains/llvm" \
  -Dwine_install_path="$PWD/toolchains/wine"
ninja -C build-debug                                 # check $? — do NOT pipe through tail
```

Two meson traps: `native_llvm_path` defaults to a Homebrew path (`/usr/local/opt/llvm@15`) and
must be pointed at the local build; and pass **only** `wine_install_path` — passing
`wine_build_path` too selects a source-tree layout (`libs/winecrt0`, `tools/winebuild`) that a
release tarball does not have.

**RESULT: the build does not work.** `d3d11.dll`/`dxgi.dll`/`d3d10core.dll`/`winemetal.{dll,so}`
all link, but with them installed the game process starts and sits at 0% CPU without ever loading
d3d11 — twice, including with Steam bypassed entirely, so it is not the launcher. The `winemetal.so`
is **27 757 256 bytes vs the official 31 805 040** — ~4 MB smaller, so something is not being
compiled in. NOT an 8.16-vs-wine-10 ABI mismatch: official DXMT 0.80 is itself built against wine
8.16 and runs fine on this engine. Before retrying, diff this meson configuration against
`.github/workflows/ci.yml` (upstream uses Xcode 16.1, not 26.6).

## ✅ SOLVED 2026-07-28: why a local build "compiles but never loads d3d11"

**`wine_builtin_dll`, a meson option that defaults to TRUE.** It stamps `Wine builtin DLL` into
each DLL's DOS stub. Sekiro's DllOverrides ask for **native** d3d11; wine will not accept a
builtin-marked file in that role, so it silently falls back to its own d3d11 → **wined3d → OpenGL**.
The game still launches, which is exactly why this reads as a DXMT bug rather than a build flag.

Diagnosed by diffing `wine --debugmsg +loaddll` between the shipped DLLs and a local build:

| | official | default-configured local build |
|---|---|---|
| `d3d11.dll` | **native** | **builtin** |

Build with `-Dwine_builtin_dll=false`; the D3D DLLs then install to `system32/` instead of
`x86_64-windows/`, and `winemetal.dll` correctly stays a builtin.

**None of the previously-suspected causes were involved** — not LLVM assertions, not the wine 8.16
vs wine 10 ABI, not the Xcode/AIR version, not `dxmt_debug`. Two of those were still worth fixing
and are now handled in `Scripts/sekiro/dxmt-build.sh`, but neither was the fault.

Two genuine upstream-source problems found on the way:
- **v0.80 does not compile with GCC 16** (what Homebrew now ships): `com_guid.cpp` uses
  `std::setfill`/`std::setw` without including `<iomanip>`.
- **`dxmt_command.metal` has no pinned target**, so the AIR version baked into the shipped DLL
  depends on the host Xcode (16.1 → `air64`; Xcode 26 → `air64_v28`).

Tooling: `dxmt-build.sh` (reproducible, refuses wrong toolchains), `dxmt-swap.sh` (install/restore
across both trees, pristine stash), `dxmt-smoke.sh` (**5-minute pass/fail for "did DXMT actually
initialise", replacing a play session as the way to find out**).

## ❌ FAILED 2026-07-28: `d3d11.maxPassesPerCommandBuffer` does not bound anything

Added a pass counter next to `promote_flush` in the D3D11 layer, exposed as a config option, and
ran a **blinded** A/B at cap=32. Result:

| | arm 1 (capped, 32) | arm 2 (control) |
|---|---|---|
| long stalls | 4 in 8m55s | 4 in 6m |
| avg encoders/cb | **47.5** | 38.1 |
| **max encoders/cb** | **233** | 250 |
| buffers ≥100 enc | 170 | 78 |

**A cap of 32 producing 233-encoder buffers is not a cap.** The intervention never engaged, so
this is NOT a falsification of the batching hypothesis and must not be counted as a thirteenth
eliminated cause.

**Why it cannot work from there.** The real count, `ArgumentEncodingContext::encoder_count_`, is
incremented inside `endPass()` (`dxmt_context.cpp:666`). The D3D11 layer emits `enc.endPass()` as a
**deferred lambda** that runs later on the encode thread — after the chunk boundary is already
fixed — and the encoding layer calls `endPass()` at a dozen of its own sites the D3D11 layer never
sees. A recording-side counter is structurally incapable of bounding the buffer. Doing this
properly means splitting a chunk at encode time, which breaks the 1-chunk-1-`MTLCommandBuffer`
invariant this document opens with. That is an upstream design decision, not a patch.

**Also learned:** a 60 s smoke run is worthless for judging this. It showed avg 6.9 encoders where
real gameplay averages ~44, and the apparent improvement in it was noise on a menu screen.

**New evidence worth more than the experiment:** the user played Sekiro on **CrossOver** (D3DMetal,
not DXMT) on this same Mac — **no long stalls, but a less steady framerate**. Same machine, same
GPU firmware, same Rosetta, same game, msync in both; the translation layer is the differentiator.
That is the first evidence implicating DXMT that does not come from this project's own
instrumentation, which matters because `gpuMS` produced false positives. Confound: CrossOver also
swaps wine.

## ❌ 2026-07-28: D3DMetal cannot be grafted into the wine-10 engine

Attempted the clean single-variable test — same wine 10 + msync, same prefix, same Steam, same
game, swap only the translation layer. **Wine 10 refuses D3DMetal's builtin**: `err:module:import_dll
Library d3d11.dll ... not found`, then `loader_init ... status c0000135`.

Not a missing dependency — D3DMetal's PE imports only `kernel32/kernelbase/ntdll/user32`, all
present. Its unixlib exports `__wine_unix_call_funcs` like the engine's own, though it lacks
`__wine_unix_call_wow64_funcs`. The components come from Mythic's GPTk engine (**wine 7.7**) and
wine 10 will not load them as builtins. Three major versions is far wider than the winemetal.so
graft (11-into-10) already flagged as an unsupported ABI mix.

Note for anyone retrying: D3DMetal's four `x86_64-unix/*.so` files are **33-byte symlinks** all
pointing at one `lib/external/libd3dshared.dylib`.

### ✅ But the accident was worth more than the experiment: a DXVK datapoint

The first graft attempt silently ran **DXVK** instead — `native,builtin` resolves native first, and
this prefix has DXVK in `system32`, so emptying only the game folder handed the game to DXVK rather
than falling through to the builtin. The user played it:

| translation layer | long stalls | framerate | wine |
|---|---|---|---|
| **DXMT** | **yes** | steady 60 | 10 + msync |
| **DXVK** | **no** | ~13 fps | **10 + msync (identical)** |
| D3DMetal (CrossOver) | no | worse than DXMT | CrossOver's |

DXVK is the strongest control yet: it holds wine, prefix, Steam, GPU and game **all** fixed, where
the CrossOver observation also swapped wine. Only DXMT stalls.

**Confound, and it is not small:** at ~13 fps DXVK may simply never build a command buffer big
enough to trigger the fault. "Too slow to stall" and "structurally immune" are indistinguishable
from the couch. Testable without any new build — the gpustall profiler hooks Metal generically, so
it will measure DXVK's encoders-per-command-buffer too (DXVK reaches Metal via MoltenVK). If DXVK
also builds 100+ encoder buffers and still never stalls, the batching hypothesis is in serious
trouble; if it never exceeds ~50, that is real support.

## 📌 Unexplored lead (user observation, 2026-07-28): Direct ↔ Composited flipping

The Metal HUD keeps flipping between **Direct** and **Composited** presentation during play.
Observed on a DXVK run; **not yet established whether it also happens under DXMT**, which is the
first thing to check.

Why it may matter: switching presentation mode makes WindowServer reconfigure how the layer reaches
the display, and the drawable the app renders into is re-created around that. DXMT already computes
**`drawable_blocking_interval`** — time blocked acquiring a drawable (`dxmt_hud_state.cpp`) — and
this project has **never read that number**, because the HUD statistics are `#ifndef DXMT_DEBUG`
no-ops in release builds. It is one of the few blocking paths never ruled out.

It also fits the stall's signature better than most falsified candidates: a stall shows
`com.Metal.CommandQueueDispatch` blocked in `IOConnectTrap4` with the encode thread idle and the
chunk ring nearly empty — i.e. not a queue backup but a single submit waiting on something external.
A display-side reconfiguration is exactly the kind of external thing that would do that.

How to check cheaply, in order:
1. Watch the HUD under DXMT and see whether the flipping happens there too, and whether flips
   coincide with stalls. Zero code.
2. Force one mode and see if stalls change — full-screen vs windowed changes whether macOS can use
   direct presentation at all.
3. Only then consider reading `drawable_blocking_interval`, which needs the DXMT_DEBUG build
   (now buildable — see the wine_builtin_dll finding above).

## ❌❌ FALSIFIED 2026-07-28: command-buffer SIZE is not the cause

**DXVK builds BIGGER command buffers than DXMT and never stalls.** Measured on the same machine,
same wine 10 + msync, same prefix, same Steam, same game, same GPU — only the translation layer
differs.

| layer | buffers | avg enc | **MAX enc** | >=50 enc | >=100 enc | long stalls |
|---|---|---|---|---|---|---|
| **DXVK** (7 min) | 821 | 34.7 | **393** | 110 | **107** | **0** |
| DXMT arm 1 (8m55) | 654 | 47.5 | 233 | 256 | 170 | 4 |
| DXMT arm 2 (6m) | 607 | 40.0 | 250 | 231 | 91 | 4 |

This also **resolves the "too slow to stall" confound**, and in the direction that kills the
hypothesis: DXVK is not failing to reach the dangerous size, it **exceeds** it — 393 encoders in a
single command buffer, 107 buffers over 100 encoders — with zero stalls.

**Therefore the `>=106 encoders` correlation reported in STALL-BUFFER-SIZE.md is a MARKER, not a
mechanism.** All 21 stalls landing in that range remains true; it just is not what causes them.
Sekiro's heavy moments produce both big buffers and stalls, and the buffers are the innocent
correlate. The p = 1.7e-13 figure quoted there measures association only, and the composition
analysis that found stalled buffers structurally indistinguishable from healthy large ones was
already pointing this way.

**Thirteenth eliminated cause, and the first eliminated by a cross-layer control rather than by
this project's own instrumentation.** It also retires the whole batching line of enquiry: no reason
remains to cap batching, split chunks at encode time, or ask upstream to.

**What survives.** Whatever is DXMT-specific and NOT buffer size. The strongest remaining lead is
the one recorded above from the same session: **Direct <-> Composited presentation flipping** and
DXMT's never-read `drawable_blocking_interval`. That fits the stall signature — one submit blocked
in `IOConnectTrap4`, encode thread idle, chunk ring nearly empty, i.e. waiting on something
external to DXMT rather than on queued work.
