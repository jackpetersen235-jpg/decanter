# Debugging Decanter on someone else's Mac

**Audience: an AI assistant with shell access, sitting in front of a machine that is not the one
Decanter was developed on.** The user in front of you may not code. Assume nothing about their
setup and verify everything you assert.

Read [`../CLAUDE.md`](../CLAUDE.md) first — its "Gotchas" section is a list of failures that already
cost hours, and most bug reports you receive will be one of them wearing a different hat.

---

## 0. Ground rules

These are not negotiable, and following them is more important than solving the problem fast.

**Never do these, even if asked directly:**

- Enter a password, Steam login, or any credential. Hand the keyboard back instead.
- Delete a Wine prefix, a bottle's files, or anything under `steamapps/common` without explicit,
  specific confirmation. A prefix holds the game install **and its saves**, which exist nowhere
  else. 10–100 GB and irreplaceable.
- Change System Settings, including Accessibility toggles. Ask the user to change them.
- Run `rm -rf` against a path you have not just listed and read back.

**Always do these:**

- Back up `bottles.json` before touching it: it is the only record of what bottles exist.
  ```bash
  cp ~/Library/Application\ Support/Decanter/bottles.json /tmp/bottles.backup.json
  ```
- Prefer read-only investigation until you can state the cause in one sentence.
- Say "I don't know yet" rather than presenting a guess as a finding.

**Destructive-sounding but safe:** `wineserver -k` (kills a prefix's processes, not its files),
`--quit-steam`, deleting generated `.app` launchers in `~/Applications` (they rebuild in seconds).

---

## 1. Sixty-second triage

Run these three before forming any theory.

```bash
bash ~/coding/Decanter/Scripts/doctor.sh
```

```bash
/Applications/Decanter.app/Contents/MacOS/Decanter --diagnose
```

```bash
ps -Ao pid,lstart,comm= | grep -Ei "steam|wine|\.exe" | grep -v grep
```

`--diagnose` prints, per bottle: engine name and version, whether the engine can run Steam, whether
the prefix is initialised, whether `steam.exe` exists, and whether Steam has **bootstrapped**. That
last line resolves the single most common support case on its own (see §3.1).

The `ps` line matters more than it looks. Note the **start times**. A `steam.exe` whose PID has not
changed across the user's "I quit it three times" is not a Steam that keeps reopening — it is a
Steam that never quit.

---

## 2. Your diagnostic toolkit

### Headless hooks

The app is its own diagnostic tool. All of these run without the GUI and print to stderr.

| Command | What it answers |
|---|---|
| `--diagnose` | Per-bottle engine, Steam presence, bootstrap state |
| `--scan-games` | What the New Bottle picker will offer, with sizes and app ids |
| `--verify` | Per-bottle: prefix present, Steam state, and which executable it resolves to |
| `--quit-steam` | Escape hatch for a Steam that will not quit; reports success per bottle |
| `--install-steam "<bottle>"` | Provision Steam into one named bottle |
| `--install-engine` / `--run-setup` | Re-run first-run setup steps |
| `--bootstrap-steam-test "<bottle>" [timeoutS]` | Launch Steam and wait for `steamui.dll` to land (no login touched); reports `bootstrapped=true\|false`, quits Steam after |
| `--play-test "<bottle>" [ceilingS]` | Press Play on a bottle exactly as a real click would, and reports whether it actually launched — `stillOpening`/`failure`, mirroring what the UI shows. Leaves the launched process running for you to inspect/stop |
| `--export-diagnostics` | Builds the same zip Help ▸ Export Diagnostics does (engine/bottle health, system info, console log tail, recent crash reports — home path redacted) and prints where it landed, without opening Finder |
| `--selftest` | The regression net: full first run (setup → Steam bootstrap → verify → idempotent re-run), end to end, against a throwaway scratch install. Run this before every release build — "does first run still work" in one command instead of a manual DECANTER_HOME choreography |
| `--engine offline\|online`, `--reset-online` | Engine profile switching |
| `--install-gfx` | Per-game DXMT install, with detection output |

Path on a user's machine is usually `/Applications/Decanter.app/Contents/MacOS/Decanter`. Ask; do
not assume they installed it there.

### Testing any of the above against a scratch install, not a user's real one

Every headless flag above reads and writes `~/Library/Application Support/Decanter` by default —
the user's real bottles, real 25+ GB prefixes, real `bottles.json`. Set `DECANTER_HOME` to redirect
all of it to a scratch directory instead, so a first-run test can't touch anything real:

```bash
rm -rf /tmp/decanter-scratch
DECANTER_HOME=/tmp/decanter-scratch build/Decanter.app/Contents/MacOS/Decanter --run-setup
```

The override IS the app-support root directly (no `Decanter` subfolder appended), so the directory
you name is exactly what gets populated and exactly what a plain `rm -rf` clears between runs.
Every path in `Paths.swift` derives from `appSupport`, so this one variable redirects
`bottles.json`, `Bottles/`, the engine roots, shader caches — everything. It does **not** redirect
discovery of things actually installed on the Mac (Whisky, CrossOver, `~/Applications` launchers) —
those still read the real home on purpose, so a scratch run still reports what's really there.

### Where the evidence lives

```
~/Library/Application Support/Decanter/
  bottles.json                     the bottle index — read this early
  Bottles/<name>/                  the Wine prefixes
  Wine/ , WineOnline/              the engines
  ShaderCache/                     per-bottle DXMT shader caches
  dxmt-log/                        DXMT's own log, if enabled
```

Steam's logs, inside a prefix — often more informative than anything Decanter writes:

```
Bottles/<name>/drive_c/Program Files (x86)/Steam/logs/
  bootstrap_log.txt      start/restart decisions, update checks
  connection_log.txt     "Logged On," lines — the ground truth for "did Steam log in"
  content_log.txt        downloads and installs
  console_log.txt        general client log
```

### Reading the registry inside a prefix

`user.reg` and `system.reg` are plain text. Grep them directly rather than booting Wine:

```bash
grep -a -A6 'CurrentVersion\\\\Run' "…/Bottles/<name>/user.reg"
```

---

## 3. Symptom → cause

### 3.1 "Steam - Fatal Error: Failed to load steamui.dll"

**This message has two completely unrelated causes and identical text.** Never guess between them.

Run `--diagnose` and read two lines:

- `steam-capable engine: false` → the Wine build is too old for modern Steam. Fix: Setup Assistant,
  install the Decanter engine, make a new bottle.
- `bootstrapped: false` → Steam has never finished downloading itself. `SteamSetup.exe` only drops
  `steam.exe` (~5 MB); the real client (`SteamUI.dll` ~18 MB, `steamclient64.dll` ~25 MB) is
  downloaded on first launch. Fix: launch Steam and **leave it alone** for several minutes — no
  window, no progress bar, looks frozen, isn't.

Historically this was caused by Decanter itself passing `-skipinitialbootstrap` to a Steam that had
never bootstrapped. That is fixed, but if you see it on an old build, that is why.

### 3.2 "Steam reopens every time I quit it"

Two independent mechanisms, and both are usually present:

1. **It never quit.** `-silent` starts Steam in the tray; closing the window re-hides it. Check
   `ps -Ao pid,lstart` — an unchanged PID across quit attempts proves it.
2. **The prefix's `Run` key restarts it.** Steam writes
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` → `steam.exe -silent`. A prefix has no boot,
   so this fires whenever *anything* brings the prefix up — a bare `wine wineboot` starts Steam
   unprompted.

Fix: `--quit-steam`, which deletes the Run value *then* shuts the prefix down. Steam rewrites the
value whenever it runs, so this is re-applied every time by design.

### 3.3 Game stutters, freezes, or "lags"

**Establish what "lag" means before measuring anything.** Frame drops, input delay, and audio delay
produce the same word and have unrelated causes. Ask.

Then rule out the cheap things, in this order, and record the numbers:

```bash
pmset -g therm                    # thermal throttling — "no warning" means not heat
sysctl vm.swapusage               # swap growing = memory pressure; flat = not it
tmutil status | grep Running      # Time Machine competing for disk
system_profiler SPAudioDataType | grep -A4 "Default Output Device"
```

That last one matters more than it looks. **`Transport: AirPlay` on the default output explains
"lag" that no CPU or GPU metric accounts for** — AirPlay audio buffers by a second or more, and in a
game everything then *feels* delayed while rendering fine. This was a real, confirmed cause on the
development machine.

If the machine genuinely is loaded, sample over time rather than taking one reading:

```bash
ps -Ao pcpu,comm= | sort -rn | head -12
ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*'
```

Healthy reference numbers from a working setup: `wineserver` at **6–8%** is correct; ~40% means
fast-sync (msync) is not active. GPU at 80% during a match is loaded but fine.

### 3.4 A game will not launch

Check in this order:

1. `--diagnose` → is the bottle initialised, is Steam bootstrapped?
2. `--verify` → does the bottle resolve to a game, and to **which executable**? UE titles ship a
   small shim beside the real binary; if it resolved to a 0.3 MB `.exe`, that is the bug.
   (`--build-game-apps` no longer exists — the generated-launcher feature it served was removed
   2026-08-12. Don't chase it if an older guide mentions it.)
3. `connection_log.txt` → did Steam actually log in? A game started before `steam_api64` can reach
   the client dies silently with nothing in any log.
4. Anti-cheat. If the game uses Easy Anti-Cheat / EOS, **stop**. There is no path on macOS — Epic
   supports compatibility layers on Linux only. Do not spend hours here; say so plainly.

### 3.5 The UI looks wrong

Switch to the **Standard** theme first (Settings ▸ Appearance). It is deliberately unthemed, so it
answers "is this a theme bug or an app bug" in one step.

Theme-specific traps are documented in `CLAUDE.md` under the Liquid Glass sections. The two most
likely to recur: a region that holds text needs a *surface* in Liquid Glass and needs `aeroInk()` in
Aero — the themes have mirror-image requirements, and satisfying one while forgetting the other has
caused this twice.

---

## 4. How to investigate without fooling yourself

This project has a documented history of confident wrong answers. These are the specific habits
that caught them.

### Measure the thing the user described

If the user says "pauses of about two seconds," a metric reporting 26-second stalls is measuring
something else — do not report it as the finding. Their observation is data; a metric that
contradicts it is a metric to re-examine.

### Never match a command line when you mean to identify a program

This is the single most repeated bug in this codebase. `pgrep -f`, `pkill -f`, and
`ps -Ao command=` match the **whole command line**, which includes your own shell's arguments and
any process that merely mentions the name.

- `pgrep -f 'steam\.exe'` from a shell self-matches.
- A bare `steam.exe` pattern also matches every `steamwebhelper`, which outlives Steam by hours.
- `pkill -f 'steam.exe'` does **not** kill a Wine prefix — `explorer.exe`, `services.exe`,
  `winedevice.exe` survive.

Use `pgrep -x` (exact process name). To shut a prefix down, use `wineserver -k` **per prefix**, then
sweep stragglers.

### Wine reports Windows paths in `comm`

`ps -Ao comm=` shows `C:\windows\system32\services.exe` — backslashes. Any parsing that splits on
`/` alone leaves the whole string intact and every comparison fails silently. Split on both.

### `du` double-counts APFS clones and hardlinks

Summing file sizes over-reports badly wherever `cp -Rc` has been used, which is everywhere in this
project. The `Backups/` folder reported 36 GB and was really ~2.4 GB.

**To measure real recovery, measure free space before and after** — `df -k /` — never `du`.

### Screenshots beat logs

Logs have said "0 errors" while the screen was a black rectangle. If the complaint is visual, look
at the screen. `screencapture -x /tmp/shot.png` then read the image.

Two caveats: a Wine game in fullscreen occupies its own Space and a plain capture catches the wrong
one; and `screencapture` may raise a screen-recording permission prompt — **do not click Allow on
the user's behalf**, ask them.

### Long-running commands must run in the background

A foreground command that times out **SIGTERMs its whole process group**. This killed a Steam
download at 90% once. Anything that downloads, installs, or launches a game goes in the background.

### Check whether a helper is dead or merely unwired

A function with zero call sites is either dead code or a feature that was never connected. Those
look identical. `grep -c` the call sites and decide which before deleting anything — a focus-ring
helper was deleted as "dead" when its emptiness *was* the bug.

---

## 5. Documenting what you find

A finding that isn't written down will be rediscovered at the same cost. Write it into
[`../CLAUDE.md`](../CLAUDE.md) under "Gotchas", in this shape:

- **What is true**, stated as a rule, not as a story.
- **How it was measured** — the command and the number. "wineserver 39.9% → 7.9% avg" is useful;
  "much better" is not.
- **What the wrong theory was**, if you held one. The next reader will form the same theory.
- **The trap in testing it.** Several findings here look confirmed under a test that is subtly
  wrong — e.g. testing `isAnyGameRunning` with `wine cmd /c …` returns true legitimately, because
  `cmd.exe` and `ping.exe` are not helpers, so the bug appears absent.

For measurement runs, save the raw data under `docs/measurements/` alongside a short write-up.
Include what you **ruled out** and with what evidence, not only the conclusion — most of the value
is in the elimination.

### Reporting to the user

- Lead with the answer, then the evidence.
- Distinguish **measured** from **inferred**. Say which.
- If you were wrong earlier, correct it plainly in one sentence and move on.
- Name what you did *not* verify. "The code handles Reduce Transparency" and "I watched it handle
  Reduce Transparency" are different claims.

---

## 6. When to stop

Some things are genuinely impossible, and the useful answer is saying so early:

- **Kernel anti-cheat games** (EAC/EOS) under Wine on macOS. No engine work changes this.
- **Verifying accessibility settings by injection.** `\.accessibilityReduceTransparency` and
  `\.accessibilityReduceMotion` are read-only environment keys. Only the real System Settings
  toggles work, and those are the user's to change.
- **Recovering data from an encrypted Android adoptable-storage card** without the device that
  adopted it. The key is in the tablet, not the card.

Say it plainly, explain why in one or two sentences, and offer the nearest thing that *is* possible.
Do not spend an hour proving a wall is a wall.

---

## 7. Quick reference

```bash
# triage
bash Scripts/doctor.sh
/Applications/Decanter.app/Contents/MacOS/Decanter --diagnose
ps -Ao pid,lstart,comm= | grep -Ei "steam|wine|\.exe" | grep -v grep

# what does this machine think it has?
python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/Decanter/bottles.json')))"

# Steam really logged in?
grep -c 'Logged On,' "…/Steam/logs/connection_log.txt"

# is the client actually downloaded?
ls -l "…/Steam/SteamUI.dll" "…/Steam/steamclient64.dll"

# shut a prefix down properly
WINEPREFIX="…/Bottles/<name>" "…/Wine/Libraries/Wine/bin/wineserver" -k

# real disk recovery (never du)
df -k / | awk 'NR==2{print $4}'
```
