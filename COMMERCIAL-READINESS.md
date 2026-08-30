# Decanter — commercial readiness assessment

Written against the goal of **selling Decanter as a streamlined, user-friendly product**.
That changes the severity calculus: a bug that needs an unusual local state matters less
than one that fires on a clean, unfamiliar Mac — because the second one hits every
customer in their first five minutes and generates every support email.

Ranked by what would actually cost you money or reputation.

---

## 1. Engine hosting — two third-party GitHub releases, no mirror, no checksum

**The single biggest business risk, and it isn't a code bug.**

`WineInstaller.swift:43` and `:58`:
```
https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz     (317 MB)
https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS11Wine10.0_3.tar.xz
```

Every new install depends on **two GitHub accounts you don't control** continuing to host
these files. If either repo is deleted, renamed, or the release asset replaced:

- **every new customer's first run breaks permanently**, and you cannot fix it without
  shipping an update
- GitHub release assets are **mutable by the publisher** — the bytes at that URL are not
  guaranteed to be the bytes you tested
- there is **no checksum pin and no fallback mirror**

For a hobby project this is fine. For a paid product it is an outage you cannot prevent
and cannot repair quickly.

**Recommendation:** host both payloads yourself (any static host / S3 / R2 is fine at this
size), pin a SHA-256 for each, and verify after download. That also removes the
"unverified executable payload" issue entirely.

---

## 2. Licensing and attribution — no LICENSE, no NOTICE, no third-party file

**I am not a lawyer. Treat this as "get advice", not as advice.**

The repo has **no LICENSE file** and **no third-party attribution** anywhere. What
Decanter installs on the user's behalf includes:

| Component | Typical license |
|---|---|
| Wine | LGPL 2.1 |
| gnutls | LGPL 2.1 |
| freetype | FTL / GPL 2 |
| MoltenVK | Apache 2.0 |
| SDL2 | zlib |
| DXVK | zlib |
| DXMT | (the **only** LICENSE file present in the payload) |
| ~94 further dylibs | mixed |

Selling the product makes attribution and license-text obligations real. Two mitigating
facts worth knowing: the engine is **downloaded, not bundled** in the app you ship, and
Wine is used as separate executables rather than linked — both help materially. But you
still need your own LICENSE, and an in-app "Acknowledgements" surfacing the third-party
licenses.

Cheap now. Expensive after launch.

---

## 3. No uninstall path

Zero results for any uninstall/remove-everything routine. Dragging the app to Trash
leaves behind:

- the engine (~480 MB across `Wine/`, `WineOnline/`, `WineLegacy/`)
- every bottle prefix (**25 GB** on this machine)
- shader caches, downloads, backups

A paid Mac app with no clean removal is a predictable review complaint, and for some
distribution channels a rejection. A "Remove Decanter and its data" flow that itemises
sizes before confirming would also reuse most of what F5 is already building.

---

## 4. Customer-facing text that references things a customer doesn't have

`AppModel.swift:602` — shown in the console after a failed bottle creation:

> "If this keeps happening, run **Scripts/doctor.sh** — a missing engine file is the usual cause."

A customer has no `Scripts/` directory. They received `doctor.command` in the zip. The
app's own remediation points at a path that exists only in your repo. Worth a sweep of
every user-visible string for the same class.

---

## 5. First-run failures that are silent — already on the board, now re-ranked

These were logged as ordinary bugs. Under a commercial goal they are the **top tier**,
because each one produces a customer who paid and got nothing, with no explanation:

- **F22** *(fixed)* — Rosetta install killed at 30s on every clean Apple Silicon Mac,
  with a Terminal command as the offered remedy. Could not reproduce on any machine here,
  because we all already have Rosetta.
- **F15** — `--run-setup` / `--install-engine` never print, never exit, never set a
  status. Your only end-to-end test of first run cannot report failure.
- **F17** — the msync overlay can silently no-op while setup reports success. The customer
  gets the frame-spike engine, blames the product, and asks for a refund about
  performance you already solved.

---

## What is genuinely in good shape

Worth saying, because it's most of the surface:

- **The setup wizard's error handling is good.** Real messages at each step, non-fatal
  warnings surfaced separately from failures, no swallowed results.
- **No hardcoded personal paths** anywhere in `Sources/` or the shipping scripts.
- **The shareable zip leaks nothing** — no `bottles.json`, no user data, no paths.
- **`package-for-friend.sh` rebuilds before packaging**, so it can't ship a stale binary.
- **Zero force unwraps** in the entire codebase.
- Rosetta installation is **attempted automatically**; the Terminal instruction is only a
  fallback.

---

## Suggested order

1. **F22 audit follow-through** — done, verified: `bootPrefix` uses `Shell.stream` so
   prefix creation is unbounded and safe; every other `Shell.run` is a fast `reg`/`ps` call.
2. **Host the engine yourself + checksum it.** Biggest risk, entirely in your control.
3. **LICENSE + acknowledgements.** Cheap, and blocking for sale.
4. **F15 and F17.** First-run silence.
5. **Uninstall flow.** Reuses F5's work.
6. **String sweep** for repo-only references.
7. **F9 accessibility** — table stakes for a paid Mac app, not just a nicety.
