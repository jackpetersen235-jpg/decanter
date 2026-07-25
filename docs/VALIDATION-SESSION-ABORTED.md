# Validation session — NOT RUN (2026-07-19)

**Permissions unapplied — `deny` rules count is 0 in `~/coding/.claude/settings.local.json`.
Session aborted before starting, per its own precondition.**

---

## Second blocker — fixes the first one and this session still cannot run

The pass/fail criteria require **45–60 minutes of active play (`gpu_util >40%`)**, and the
known state correctly notes GPU hangs occur *only* during active gameplay.

Nobody is playing. Jack is asleep, and I cannot play Sekiro. An unattended session cannot
generate the load the hypothesis needs, so it would measure an idle machine — exactly the
confound the pre-registered criteria were written to exclude. Applying the deny rules and
re-running tonight would produce another empty result.

**This test has to run while Jack is at the keyboard.** It needs no autonomy at all — just
45–60 minutes of normal play with the keep-alive active, which is already wired into
`Sekiro.app`. The measurement is passive:

```bash
# before playing
ioreg -r -d 1 -c IOAccelerator | tr ',' '\n' | grep -oE '"recoveryCount"=[0-9]+' | head -1

# after playing — plus active-play duration
```

Mechanism confirmation (`fw_power_state` floor during play) can be sampled by a background
logger started at the same time. `fw_power_state` is only exposed in `gpuEvent-*.ips`
crash reports, not in live `ioreg` output — so if **zero hangs occur, zero reports are
generated, and the mechanism cannot be confirmed from this data source at all.** That is a
design flaw in the mechanism check worth knowing before relying on it: a clean PASS
produces no mechanism evidence by construction.

> **CORRECTION 2026-07-21 — the paragraph above is wrong, and the "design flaw" does not exist.**
> `ioreg -r -d 1 -c IOAccelerator` exposes **`CurrentPowerState`** and **`DriverPowerState`** live,
> no crash report needed. The keep-alive's mechanism (holding the GPU above power state 0) is
> directly observable during a clean session. `Scripts/sekiro/gpusample.sh` logs it at 1 Hz.
> A clean PASS *does* produce mechanism evidence — earlier sessions simply never sampled the key.

## To proceed

1. Apply the `allow` + `deny` rules from `proposed-permissions.md` (deny half matters most —
   `Bash(rm *)` is broad, and those rules protect `Steam-Wine11`, which holds the save).
2. Run the validation attended, during a normal 45–60 min play session.
3. For the mechanism question, a live sampler of GPU power state would need a different
   source than `gpuEvent` reports — unresolved, see above.

Nothing was changed. No processes were started. Current state is as left in
`GPU-HANG-FINDINGS.md`.
