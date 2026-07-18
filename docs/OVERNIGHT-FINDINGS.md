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
   prefix version, wine version. Untested hypothesis: IPv6 is broken on your network (162 IPv6-fail
   lines) and Steam tries `::1` first. **CrossOver (~$74) remains the one guaranteed fix.**
3. **Per-game DXMT auto-install** is still the documented gap in the setup wizard (CLAUDE.md).
   Genuine missing feature, not a bug.

## What to do next

- **Test it:** `open ~/coding/Decanter/build/Decanter.app` and hit Launch Steam. It's rebuilt with
  all three fixes. (Quit the Steam I started first, so you're testing a cold launch.)
- If you want the frame spikes gone, buy CrossOver — the free path is exhausted and I'd stop
  spending time on it.
- `pkill caffeinate` when you're done — it's still holding your Mac awake (PID 2685).

All three fixes are committed and pushed to `jackpetersen235-jpg/decanter`.
