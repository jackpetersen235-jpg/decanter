# 26 s stall — 2x2 factorial test (PRE-REGISTERED)

**Written 2026-07-25, BEFORE any data was collected.** The point of writing the analysis down
first is that this investigation already produced six confident, wrong causes. Every one came from
forming a hypothesis after seeing a short run, then defending it. The rules below are fixed in
advance so that cannot happen again.

## Why a factorial

Prior evidence came from sessions of **1.8 to 22.5 minutes**. At ~0.2 stalls/min a 2-minute clean
run means almost nothing (expected count 0.4), yet short runs were repeatedly treated as evidence.
The two factors that have never been varied independently at adequate duration:

- **MetalFX** — on (1.5x spatial upscale) / off
- **gpukeepalive** — on (50 ms) / off

## Cells — each **15 minutes MINIMUM of active play**

| # | MetalFX | keep-alive | stamp |
|---|---|---|---|
| 1 | ON | OFF | `FACT-FXON-KAOFF` |
| 2 | ON | ON | `FACT-FXON-KAON` |
| 3 | OFF | OFF | `FACT-FXOFF-KAOFF` |
| 4 | OFF | ON | `FACT-FXOFF-KAON` |

Order is fixed as 1,2,3,4 — **not** randomised, which is a known weakness: thermal state and
save-file location drift over an hour. Noted rather than hidden.

Engine held constant: wine 10 + msync. It reproduces with msync on and off, wine 10 and 11, so it
is not a factor.

## Play protocol — identical in every cell

Each 15-minute block must include: **at least one area load, at least two death-reloads, and
continuous combat/traversal otherwise.** Stalls concentrate on loads and reloads; a cell spent
standing still is not comparable to one spent loading.

## Analysis, fixed in advance

1. Primary metric: **stalls per minute of active play**, from `SLOW cb#` lines >250 ms.
2. A cell is **clean** only with 0 stalls in >=15 min. At 0.2/min that is an expected count of 3,
   so P(0 | no effect) ~= 5%.
3. **Both cells** of a factor level must agree before that factor is called causal. If MetalFX ON
   is clean at both keep-alive settings and MetalFX OFF stalls at both, MetalFX is implicated.
   A single clean cell implicates nothing.
4. If exactly one cell is clean, the conclusion is **interaction, or noise** — explicitly NOT a
   main effect for either factor.
5. If all four cells stall, the conclusion is **neither factor matters** and both are dropped.
6. **No hypothesis is formed until all four cells are complete.** No interim explanations.

## Stopping rule — AMENDED 2026-07-25, still BEFORE any data was collected

Amending a pre-registration before data is legitimate; amending it after seeing results is not.
This change is recorded with that distinction explicit, and the git history timestamps it.

**Sequential rule:** stop a cell **at the first stall**. Otherwise run the full 15 minutes.

Justification — the two outcomes are not symmetric:
- **Presence** of stalls is established by a single event. The question per cell is "does this
  configuration prevent stalls?", and one stall answers it: no. The rate is not needed.
- **Absence** cannot be shortcut. A clean cell still needs >=15 min, or it carries the same
  near-zero information as the 2-minute runs that produced three wrong conclusions.

Consequence to keep in mind when reading the results: a stalling cell records only "stalled at
T minutes", not a rate, so stalling cells are NOT comparable to each other by severity. They are
comparable only as stalled / did-not-stall. Analysis rules 2-6 are unchanged and still binary.

A cell may still not be extended to chase a clean result.

## Cross-title control (added 2026-07-25, outside the 2x2)

**JoJo's Bizarre Adventure: All-Star Battle R — 15.0 min, 0 stalls, MEASURED with the profiler.**
Meets the same >=15 min bar the factorial uses for "clean". P(0) = 2.7% at Sekiro's pooled rate
(0.24/min), 0.06% at the recent-cells rate (0.5/min). Worst command buffer 23.5 ms.

Held constant vs Sekiro: same Mac, same `Steam-Wine11` prefix, same wine 10 + msync, same DXMT
0.80, same MetalFX ON, same launch method (`gpuprof-direct.sh --game asbr`), keep-alive OFF.
**Only the title differs.**

And it is not a lighter workload — JJBA submits **~1502 cb/5 s at 77% GPU busy** versus Sekiro's
~900 cb/5 s at ~33%. It works the GPU roughly twice as hard and stays clean, which argues against
submission volume or GPU pressure as the driver.

**What this supports:** the stall is not simply "Apple's driver misbehaves on this M5" — it needs
something Sekiro's workload specifically does. **What it does NOT identify:** what that something
is. No hypothesis offered; this session already produced six wrong ones.

## Deviations from protocol (recorded as they happen)

- **Cell 3: INVALID.** Stopped by request at 9.1 min with 0 stalls (needs >=15). Suggestive but
  below the pre-registered bar, so it is NOT counted as evidence — the same mistake that produced
  three wrong conclusions earlier.
- **Cell 1, attempt 1: INVALID.** Ended at 2.8 min with no 26 s stall (needs >=15). Not counted.
- **Order changed** from 1,2,3,4 to **2,4,1,3** — the keep-alive-OFF cells (1 and 3) suffer the
  unrelated ~7 s firmware freezes (3 GPU resets in 2.8 min), which makes them unpleasant to play.
  Doing the keep-alive-ON cells first. This weakens the design further: cell order is already
  confounded with thermal drift, and now the two levels of the keep-alive factor are no longer
  interleaved in time. Recorded rather than hidden.

## Results

_(filled in as cells complete — numbers only until all four are done)_

| # | MetalFX | keep-alive | stalls | min | rate |
|---|---|---|---|---|---|
| 1 | ON | OFF | 0 | 2.8 | **INVALID — must re-run** |
| 2 | ON | ON | 1 | 2.2 | **STALLED** (valid — sequential stop) |
| 3 | OFF | OFF | 0 | 9.1 | **INVALID — stopped early, no stall** |
| 4 | OFF | ON | 1 | 1.4 | **STALLED** (valid — sequential stop) |
