# Debug session findings — 2026-07-18

**Read this first:** the scheduled 2:30am session **did not run**. Your Mac stayed awake
(caffeinate held `PreventSystemSleep` all night, only 1 sleep/wake since boot) — the app-side
scheduler simply never fired the job. Not a machine problem. The work below was done live
starting ~10:00am instead, so it's a shorter pass than planned.

**Your working setup was never touched:** `~/Applications/Sekiro.app` and
`Bottles/Steam-Wine11` are byte-for-byte as they were. Nothing was promoted onto them.

---

## The Steam-launch problem: found and fixed

You reported Decanter "wasn't working well" launching Steam. **Root cause found — the Launch
button silently did nothing.**

`AppModel.isSteamRunning()` tested `pgrep -f "steam\.exe"`. Steam's *webhelper* processes carry
`-steampath=C:\Program Files (x86)\Steam\steam.exe` in their argv, so that pattern matched them
too. Those webhelper orphans survive for hours after Steam exits (your own GAMING-STACK.md §10
documents this; we found some from the *previous day* still alive). So:

> orphan webhelper alive → `isSteamRunning()` returns true → `launchSteam` short-circuits to
> `activateRunningGame()` → nothing to activate → **button appears dead.**

**Fix** (`e1c41b9`): match `/steam\.exe` (leading forward slash). The real client's `argv[0]` is a
unix path (`…/winetemp-…/steam.exe`); the webhelper only ever has the Windows form `\steam.exe`.
Verified against both real argv strings: real → still detected, webhelper → correctly ignored.

**End-to-end verified, twice:**
1. Launched Steam through Decanter's exact path/env into the real bottle — logged on in ~8s.
2. **GUI cold-launch test (the real proof):** tore Steam fully down (0 processes), clicked
   **Launch Steam** in the rebuilt Decanter.app — Steam launched and logged on at 10:17:32.
   Note the logon itself proves the UI is fine: Steam cannot complete login unless its internal
   CEF UI websocket works, which is exactly what failed on CX24. (The Steam window doesn't appear
   in screenshots because Wine windows belong to the `wine` process, which isn't screenshot-allowlisted.)

## Two more real bugs fixed

**`908304e` — explorer.exe was killed for game bottles, breaking fullscreen.**
`suppressWineSystray()` ran after *every* launch and blind-swept `pkill -f explorer.exe` 12× over
~48s starting 15s in. For `-applaunch` (game) bottles `explorer.exe` **is** the per-app virtual
desktop that produces the borderless-fullscreen window — GAMING-STACK.md §7 says killing it early
prevents that window from ever being created. Your `sekiro-launcher.sh` gets this right (waits for
`sekiro.exe`, *then* sweeps); Decanter raced it on a blind timer. Now skipped for game bottles.
Also documented that this `pkill` is process-wide and can hit *other* running bottles — Wine gives
no way to scope it from argv, since the prefix lives in the env.

**`d826193` — Steam launch arguments shattered on quotes.**
`launchArguments` did `split(separator: " ")`, so `-foo "C:\Program Files\thing.exe"` became three
broken tokens. Replaced with a quote-aware tokenizer. Verified: normal args, `-applaunch`, quoted
paths with spaces, repeated/leading/trailing whitespace, and empty string (no spurious empty arg).

## Code health

- Full clean rebuild: **no warnings**.
- No `try!` / `as!` / force-unwrapped collection access anywhere in `Sources/`.
- Only force-unwrap is `URL(string: "https://…SteamSetup.exe")!` — a compile-time constant, fine.

## Open / not fixed (my judgement, your call)

1. **`Shell.run` latent hang.** Its `terminationHandler` calls `readToEnd()`, assuming the pipe's
   write end is closed once the process exits. Wine children *inherit* those pipes, so a
   grandchild outliving the parent could block it forever and hang the async call. Today `run` is
   only used for short commands (`pgrep`, `wine --version`), so it's not biting — I left it alone
   rather than risk destabilising working code without evidence. Worth fixing if you ever route a
   wine launch through `run`.
2. **msync / frame spikes — still unsolved, and I'd stop chasing the free path.** Recap from last
   night: msync-for-free is *proven* (free `WS12WineCX24`, wine 9, activates), but **both** free
   CrossOver-sourced engines (wine 8 *and* wine 9) fail Steam login — Steam's internal loopback UI
   websocket never ESTABLISHes (server LISTENs on `127.0.0.1:54327`, client connect never
   completes). Ruled out: msync itself (fails with fast-sync off), libraries, wrapper packaging,
   prefix version, wine version. **IPv6 hypothesis now TESTED and DEAD (2026-07-18):** measured on
   this Mac — `::1` is configured on `lo0` and a connect to a dead `::1` port is **refused in
   0.000s**, so Steam would fall back to IPv4 instantly; it cannot be stalling there. Only
   *external* IPv6 is broken (no default route), which is not the path the internal UI websocket
   uses. **Do NOT bother disabling IPv6 — it would change nothing.** Since OS-level loopback
   demonstrably works and the server genuinely LISTENs, the fault is inside the CrossOver-sourced
   engine's socket layer (async connect completion never fires) — a wine bug, unreachable from any
   macOS setting. **CrossOver (~$74) remains the one guaranteed fix.**
### Correction + rigorous retest (2026-07-18, later)

Two of my earlier supporting arguments were **wrong**, found by finally running the control:

- The CEF errors I cited (`WSALookupServiceBegin failed`, `WSAEOPNOTSUPP 10045`) are **noise**.
  The engine that WORKS logs *more* of them (422 vs 241, and 115 vs 81). They prove nothing.
- One CX run was **confounded**: a second Steam client (from the good engine) was still running,
  and Steam allows only one client per machine. Also, your IPv6 came up during the session
  (external IPv6 now SUCCEEDS, where this morning there was no route at all).

**Clean retest under proper conditions** — CX engine alone (0 steam.exe / 0 webhelper /
0 wineserver beforehand), single instance, IPv6 functional: **still no logon after 180s, and 0
ESTABLISHED loopback connections.** The UI websocket never connects.

So the conclusion is unchanged but now properly evidenced: the failure is real, reproducible, and
independent of IPv6, instance count, msync, libraries, packaging, prefix version and wine version.
The one differentiator that holds is that `steam.exe` LISTENs on 127.0.0.1 and nothing ever
connects, only on CrossOver-sourced engines. That is inside the engine binary.

3. **Per-game DXMT auto-install** is still the documented gap in the setup wizard (CLAUDE.md).
   Genuine missing feature, not a bug.

## What to do next

- **Test it:** `open ~/coding/Decanter/build/Decanter.app` and hit Launch Steam. It's rebuilt with
  all three fixes. (Quit the Steam I started first, so you're testing a cold launch.)
- If you want the frame spikes gone, buy CrossOver — the free path is exhausted and I'd stop
  spending time on it.
- `pkill caffeinate` when you're done — it's still holding your Mac awake (PID 2685).

All three fixes are committed and pushed to `jackpetersen235-jpg/decanter`.

---

# ★ RESOLVED (2026-07-18 ~12:20) — the free msync path WORKS

**The "you must buy CrossOver" conclusion was WRONG.** Root cause of the free-path failure was
never the wine version, msync, packaging, libraries, IPv6 or the prefix — it was **CrossOver's own
patches**. Upstream wine + msync has no such problem.

**The winning engine:** `WS11Wine10.0_3` from the Sikarugir/Kegworks `Engines` mirror — free,
**upstream wine 10.0 with msync already applied** (0 CrossOver markers, `WINEMSYNC` in ntdll).

Verified on this Mac:
- `msync: up and running` (Mach port bootstrapped)
- Steam **logged on in ~24s**, and the loopback UI websocket **ESTABLISHED (8 conns)** — the exact
  thing that never connected on CrossOver-sourced wine 8/9
- DXMT active on Metal 3 (MSL 3.2), MetalFX config applied, rendered past frame 1732
- Sekiro runs, 98-101 threads

**DXMT graft required:** the engine ships a 36878-byte `winemetal.dll` and NO unix
`winemetal.so`. Grafted the wine-11 `winemetal.so` + DXMT's 73478 `winemetal.dll` into it. This is
an unsupported ABI mix (wine11 unixlib in a wine10 engine) — it works, but one GPU
error/recovery (`kIOGPUCommandBufferCallbackErrorInnocentVictim`) was observed. **First suspect if
graphics get unstable.**

**Measured result:** `wineserver` under real gameplay **39.9% -> ~7.5% avg** (samples 2.3-13.5%).
A real ~5x reduction, but NOT the ~400x (0.1%) the old Mythic figure implied. Spike relief should
be substantial but is not proven total — subjective play test is the real judge.

**Promoted to the live setup** (Sekiro.app engine, Decanter engine, syncMode=msync on both bottles).
**Full wine-11 fallback** cloned at `Backups/wine11-20260718-121514/` (Sekiro.app, DecanterWine,
Steam-Wine11 + saves, bottles.json).

Open: the `wineboot -u` prefix reconcile did not report completion; re-run if oddities appear.
