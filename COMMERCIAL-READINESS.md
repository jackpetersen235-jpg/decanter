# Decanter — commercial readiness assessment

Written against the goal of **selling Decanter as a streamlined, user-friendly product**.
That changes the severity calculus: a bug that needs an unusual local state matters less
than one that fires on a clean, unfamiliar Mac — because the second one hits every
customer in their first five minutes and generates every support email.

Ranked by what would actually cost you money or reputation. **Updated 2026-08-29** after
the pre-release debug plan's five phases and a pass on this document's own §99 items —
see each section below for current status.

---

## 1. Engine hosting — checksummed now, still on GitHub

**Partially closed.** The checksum half is done: both downloads are now verified against a
pinned SHA-256 before anything is extracted or grafted (`WineInstaller.swift`, computed
2026-08-29 by downloading each file fresh and hashing it directly). A mismatch is now a
loud, named failure instead of a silently corrupted engine — that closes the "unverified
executable payload" concern and the "corrupted download" failure mode both.

**Still open — and still the bigger of the two risks:**

```
https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz     (317 MB)
https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS11Wine10.0_3.tar.xz
```

Every new install still depends on **two GitHub accounts you don't control** continuing to
host these files. If either repo is deleted, renamed, or the release replaced entirely
(not just its bytes changed — a checksum pin only protects against silent byte-swaps of
the SAME release, not the asset disappearing outright), every new customer's first run
breaks permanently and you cannot fix it without shipping an update that also changes the
URL.

**Recommendation, unchanged:** host both payloads yourself (any static host / S3 / R2 is
fine at this size). This is real infrastructure and an account decision — not something to
stand up unilaterally in a coding pass.

---

## 2. Licensing and attribution — done

> **Superseded 2026-11-05:** Jack open-sourced Decanter — `LICENSE` is now GPL-3.0, and the
> bundled DXMT DLLs carry their MIT license (`Assets/DXMT/LICENSE`). What follows is the
> original note.

**Closed.** `LICENSE` (proprietary, all rights reserved — Jack's explicit choice) and
`THIRD-PARTY-NOTICES.md` (what's installed, each component's real license, and how each
entry was confirmed — DXMT's MIT license was read directly out of its bundled LICENSE
file, not assumed) both now exist at the repo root.

**Still open:**
- A full per-dylib audit of the ~90 unlisted support libraries in the base bundle —
  flagged explicitly in `THIRD-PARTY-NOTICES.md` as not yet done, rather than silently
  skipped.
- An in-app "Acknowledgements" screen surfacing the notices file's content. Low effort,
  worth doing before a public release, but a UI addition beyond a docs pass.
- **I am not a lawyer.** Both files are written from what's verifiably true about the
  packages involved, not as legal advice — get real advice on this before shipping.

---

## 3. No uninstall path — done

**Closed.** Settings → Danger Zone → "Uninstall Decanter…" itemises everything with real
sizes (engine profiles, bottles, shader cache, downloads, backups, the bottle index) before
a single confirm removes it all. On this machine that's **72.66 GB** — bottles alone are
31 GB, Backups another 38 GB, three engine profiles at ~888 MB each.

`Uninstaller.plan()`/`execute()` (list vs. act, same split as `OrphanReclaim`) are covered
by 6 isolated tests against a scratch `DECANTER_HOME` — never real data. Deliberately no
headless CLI flag that executes an uninstall (`--uninstall-plan` is list-only, matching
`--reclaim`); a hidden flag that can erase 70+ GB on a mistyped command was judged a worse
risk than the inconvenience of testing only against scratch fixtures.

---

## 4. Customer-facing text that references things a customer doesn't have — done

**Closed**, and reswept. `AppModel.swift`'s bottle-creation-failure message now names
`doctor.command` (what a customer actually receives) rather than `Scripts/doctor.sh` (F23).
A repo-wide sweep for the same class of leak (`Scripts/`, `~/coding`, hardcoded personal
paths) during the debug plan's Phase 2 found no further instances.

---

## 5. First-run failures that are silent — done

**Closed.** All three were fixed during the debug plan:

- **F22** *(fixed)* — Rosetta install timeout.
- **F15** *(fixed)* — `--run-setup` / `--install-engine` now print a result and set a real
  exit code, like every other headless flag.
- **F17** *(fixed)* — the msync overlay's success is now verified with `probeFastSync`
  rather than inferred from "nothing threw"; a failed graft reports as a real warning.

Beyond this document's original three, the debug plan also found and fixed a fourth,
more serious instance of the same failure class that wasn't on this list yet:
**`hasUsableEngine`** used to treat any wine binary at Decanter's engine path as proof
setup had fully succeeded — true the instant the base bundle finished extracting, a full
minute before the msync overlay even started. An install interrupted between those two
steps left every later setup re-run silently skipping the engine step forever, with
`--run-setup` reporting "complete" over a permanently untuned, frame-spike engine.
Fixed by checking the tuned build's actual msync signature, not mere presence.

---

## What is genuinely in good shape

Worth saying, because it's most of the surface:

- **The setup wizard's error handling is good**, and now carries stable failure codes
  (`DEC-E01`–`DEC-E08`) so a support conversation can start from "it stopped with DEC-E04"
  instead of only "it failed."
- **No hardcoded personal paths** anywhere in `Sources/` or the shipping scripts.
- **The shareable zip leaks nothing** — no `bottles.json`, no user data, no paths.
- **`package-for-friend.sh` rebuilds before packaging**, so it can't ship a stale binary.
- **Zero force unwraps** in the entire codebase.
- **A regression net exists** — `--selftest` runs a full first-run (setup → Steam bootstrap
  → verify → idempotent re-run) against a throwaway scratch install in one command, meant
  to run before every release build.
- **Diagnostics are exportable** — "Export Diagnostics…" builds a redacted zip (health
  check, system info, console log, recent crash reports) for a customer who can't describe
  what went wrong.
- Icon-only controls carry real accessibility labels (F9), not just tooltips.

---

## What's actually left

1. **Host the engine yourself.** The one item here that's genuine infrastructure work, not
   a coding pass — still the single biggest business risk on this list.
2. **In-app Acknowledgements screen** and the **per-dylib license audit** underneath it.
3. **Get real legal advice** on the LICENSE/THIRD-PARTY-NOTICES content before shipping.
