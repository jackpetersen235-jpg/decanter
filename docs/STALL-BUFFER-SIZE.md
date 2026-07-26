# The 26 s stalls occur only in LARGE command buffers (>=106 encoders)

**2026-07-25.** Derived from data already collected — no new play session was required.
This supersedes the config-space search (`STALL-FACTORIAL.md`) as the leading line of enquiry.

## The observation

All **21** genuine stalls (>20 000 ms) across every Sekiro session occurred in command buffers
with **106–138 encoders**. Not one below 106.

| | encoders/cb avg | largest seen | share >=100 encoders |
|---|---|---|---|
| Sekiro | 33.1 | 146 | 24.6% |
| **JJBA ASBR** | 16.5 | **48** | **0 of 2681** |

JJBA — measured clean for 15 min on the same machine, prefix, engine, DXMT and MetalFX setting —
**never builds a command buffer large enough to be in the stall range.**

## Why this is not a sampling artifact

The two logging paths have different, and conveniently complementary, biases:

- `BASE` buffers are sampled **every 120th, uniformly and independently of size**, so the BASE set
  is an unbiased estimate of the population's encoder-count distribution.
- `SLOW` buffers are logged **exhaustively**, so every stall is captured regardless of its size.

From 12 566 uniformly-sampled BASE buffers: **P(a buffer has >=100 encoders) = 0.246**.
All 21 exhaustively-captured stalls had >=100 encoders.

If stall and size were independent:

```
P = 0.246 ^ 21 = 1.7e-13
```

## What this does NOT establish

**Association, not causation.** Three specific reasons to withhold judgement:

1. **Large buffers do not reliably stall.** ~24.6% of Sekiro's buffers exceed 100 encoders, while
   stalls run ~0.2–0.5/min. Large size is at most *necessary*, clearly not *sufficient* —
   something else must co-occur.
2. **Confounding is wide open.** Sekiro builds its largest buffers during area loads and
   death-reloads, which is also when stalls cluster. Buffer size may simply be a marker for
   "heavy streaming moment" rather than the mechanism.
3. **Pooled across configurations.** The 21 stalls span different MetalFX / keep-alive / engine
   settings. Pooling is defensible because the association holds within every one of them, but it
   is not a controlled comparison.

**Six causes were confidently asserted and falsified earlier in this investigation** (shader,
MTLFence, MTLEvent, CPU encoding, msync, wine build, keep-alive). This is recorded as the
strongest *lead*, not as the answer.

## Why this points at DXMT rather than Apple, msync, or wine

**DXMT decides how many encoders go into one `MTLCommandBuffer`** — that batching is its choice,
not the game's and not the driver's. If stalls require large buffers, the batching policy is the
lever, and it sits in DXMT.

That also explains the cross-title contrast without invoking anything machine-specific: JJBA's
render pattern simply never causes DXMT to accumulate 100+ encoders before committing.

## What would actually test it

Locally, the honest answer is **not much** — DXMT exposes no knob to cap encoders per command
buffer (`d3d11.*` options are: `metalSpatialUpscaleFactor`, `preferredMaxFrameRate`,
`ignoreMapFlagNoWait`, `sampleNaNToZero`, `defuseFma`). Without a way to force smaller buffers,
the causal claim cannot be tested from user space.

So the useful next step is **upstream to DXMT**, with the association and the cross-title control,
asking whether a batching cap is feasible. That is a legitimate DXMT question in a way that the
earlier msync report was not.

A third D3D11 title would also sharpen it cheaply: one that builds 100+ encoder buffers and
stalls, or never exceeds ~50 and stays clean, would both fit; a title that builds large buffers and
stays clean would weaken it considerably.

## Reproducing this analysis

```bash
# encoder counts of all genuine stalls
grep -h 'SLOW cb#' ~/Library/Application\ Support/Decanter/gpustall-*.log \
  | awk '{for(i=1;i<=NF;i++){if($i~/^gpu=/){t=$i;sub(/gpu=/,"",t);sub(/ms/,"",t)}
          if($i~/^encoders=/){e=$i;sub(/encoders=/,"",e)}} if(t+0>20000) print e}'
```
