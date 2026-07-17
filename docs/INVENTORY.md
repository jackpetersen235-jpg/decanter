# Inventory — everything created, downloaded, or modified

State as of **2026-07-16**. Machine: M5 MacBook Air, macOS Tahoe 26.5.2, 10 GPU cores, Metal 4.
`~` = `/Users/me`. Sizes are as measured.

---

## 1. Created by us — this repo

| Path | What |
|---|---|
| `~/coding/Decanter/` | The Decanter app (SwiftPM, no xcodeproj) |
| `└ Sources/Decanter/` | Swift source (see CLAUDE.md for layout) |
| `└ Scripts/make_app.sh` | Builds `build/Decanter.app`; copies `Assets/AppIcon.icns` + `wallpaper.png` |
| `└ Scripts/sekiro/` | **Rescued** launch scripts (originals were in a temp dir that gets wiped) |
| `└ Assets/AppIcon.icns` | Wizard icon (1.2 MB) — built from `wizard-source.png` |
| `└ Assets/wallpaper.png` | Same wizard image, used by `ContentView.wallpaper()` |
| `└ Assets/wizard-source.png` | ⚠️ Original clipboard grab — **has the transparency checkerboard baked into pixels** (`hasAlpha: no`) |
| `└ Assets/wizard-clean.png` | Checkerboard flood-filled to white (usable master) |
| `└ Assets/icon-1024.png` | Final 1024² icon master, wizard at 96 % height on white |
| `└ docs/` | `GAMING-STACK.md`, `INVENTORY.md` |
| `~/Applications/Sekiro.app` | **809 MB** — the thing that actually launches Sekiro. Contains a **cloned Wine tree** at `Contents/Frameworks/Wine` (APFS clone, ~0 real disk). Icon from Steam box art. Unsigned (deliberate). |

> To rebuild the icon: master is `Assets/icon-1024.png` → iconset → `iconutil`.
> **Must pass `sips -s format png`** or iconutil fails cryptically.

## 2. Downloaded (all free, from official sources)

| What | Version | Source | Landed at |
|---|---|---|---|
| **WhiskyWine** ← *in use* | wine **11.0** + DXVK + DXMT | `github.com/frankea/Whisky` release **v3.1.1** → `Libraries.tar.gz` (317 MB) | `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/` |
| Whisky app | 2.3.5 | `github.com/Whisky-App/Whisky` (archived) | `/Applications/Whisky.app` — **redundant, never used** |
| Whisky 2.5 libs | wine **7.7** (CrossOver 22, has msync) | `frankea/Whisky` release **v2.5.0** → `Libraries.tar.gz` (270 MB) | `~/Library/Application Support/WhiskyWine25/` — experiment only |
| Gcenx Wine Staging | wine **11.10** | `github.com/Gcenx/macOS_Wine_builds` **11.10** (181 MB) | `~/Applications/Wine Staging.app` — Steam UI went black; superseded |
| Steam client | current | `SteamSetup.exe` (already in `~/Downloads`) | installed into the prefix |

**Pre-existing (NOT installed by us):** `/Applications/Mythic.app` (64 MB) with its GPTk
wine-7.7 engine at `~/Library/Application Support/Mythic/Engine/wine`, and
`~/Applications/CrossOver.app` (trial, **expired**).

## 3. Runtime data

| Path | Size | Notes |
|---|---|---|
| `~/Library/Application Support/Decanter/Bottles/Steam-Wine11` | **16 GB** | ⭐ **The live prefix.** Steam + Sekiro (14 GB) + login + saves |
| `└ .../Sekiro/S0000.sl2` | 11 MB | ⚠️ **Your save file — irreplaceable** |
| `└ .../AppData/Roaming/Sekiro/GraphicsConfig.xml` | — | ⚠️ **UTF-16LE, no BOM.** Sekiro **rewrites it on exit** — edit only while the game is closed |
| `~/Library/Application Support/Decanter/ShaderCache/Sekiro` | ~5 MB | DXMT shader cache; grows as you play, reduces stutter |
| `~/Library/Application Support/Decanter/bottles.json` | — | ⚠️ **STALE** — see CLAUDE.md TODO |
| `~/Library/Application Support/Decanter/Bottles/Steam-Mythic` | 435 MB | Leftover experiment — **safe to delete** |
| `~/Library/Application Support/CrossOver/Bottles/Steam` | 2.8 GB | Old CrossOver bottle. **Sekiro was MOVED OUT of it** (not copied). Safe to delete |

## 4. Backups — one-command rollback

`~/Library/Application Support/Decanter/Backups/`

| Item | What |
|---|---|
| **`RESTORE-20260716-220653.sh`** | 🔑 **Run this to roll everything back** |
| `Steam-Wine11-20260716-220653/` | Full 16 GB prefix snapshot (APFS clone) |
| `sekiro-saves-20260716-220653/` | `S0000.sl2` — **real copy**, not a clone |
| `Sekiro.app-20260716-220653/` | App + launcher |
| `GraphicsConfig-…xml`, `bottles-….json`, `ShaderCache-…/`, `launcher-….sh` | Config snapshots |

Snapshots use `cp -Rc` (APFS clone): 16 GB in **1.4 s**, ~0 extra disk.

## 5. Modified on the system (outside this repo)

- **Sekiro `GraphicsConfig.xml`** — `Auto-detectBestRenderingSettings` forced **OFF** (it kept
  resetting everything to HIGH), `LodQuality LOW`, `ReflectionQuality MEDIUM`, `ScreenMode WINDOW`,
  window 1280×832. Backup of the original exists.
- **Prefix registry** — `AppDefaults\sekiro.exe\DllOverrides` = d3d11/dxgi/d3d10core → `native,builtin`.
  Global `DllOverrides` deliberately **left clean**.
  `Mac Driver\CaptureDisplaysForFullscreen` was set then **removed** (caused zoom + trap).
- **DXMT DLLs copied into the game folder** — `steamapps/common/Sekiro/{d3d11,dxgi,d3d10core}.dll`
  so only the game uses DXMT.
- **Steam config** — `loginusers.vdf`/`config.vdf` originally copied from the CrossOver bottle
  (account name only); `WantsOfflineMode`/`SkipOfflineModeWarning` set to 1 in the **deleted**
  test prefix only.

## 6. How to launch (current, working)

```bash
open ~/Applications/Sekiro.app            # icon is in the Dock
# or, with tunable upscaling + fps HUD:
HUD=1 ~/coding/Decanter/Scripts/sekiro/sekiro-metalfx.sh 1.5    # 1.3 mild · 1.5 balanced · 2.0 max
```

---

# 8. 🚨 Disaster recovery — read if something is lost

## What is genuinely irreplaceable

| Thing | Replaceable? |
|---|---|
| **`S0000.sl2`** (Sekiro save, 11 MB) | ❌ **NO — your actual progress.** Nothing can regenerate it |
| Decanter source (`~/coding/Decanter`) | ❌ no version control — see §9 |
| These docs | ❌ hand-written from a chat that may be gone |
| Sekiro game files (14 GB) | ✅ re-downloadable from Steam (slow) |
| Wine builds | ✅ re-downloadable (URLs below) |
| Shader cache | ✅ rebuilds itself as you play |

## ⚠️ The backups are on the SAME DISK as the originals

`cp -Rc` APFS clones are **logically independent copies**, so they survive accidental deletion —
but **not** a drive failure. Both live on this one internal volume.

**Copy these off-disk (iCloud / external / anywhere else):**
```
~/Library/Application Support/Decanter/Backups/sekiro-saves-*/S0000.sl2   ← 11 MB, irreplaceable
~/coding/Decanter/                                                        ← source + these docs
```
Everything else is bulk that can be rebuilt.

## Exact re-download URLs (if a Wine build is lost)

```
WhiskyWine 11.0  (IN USE — DXVK + DXMT included)
  https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz     (317 MB)
  → extract to ~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/
  → xattr -dr com.apple.quarantine <that dir>   &&   chmod +x .../Wine/bin/*

Whisky 2.5 libs (wine 7.7, HAS msync — experiments only)
  https://github.com/frankea/Whisky/releases/download/v2.5.0/Libraries.tar.gz     (270 MB)

Gcenx Wine Staging 11.10 (Steam UI goes BLACK — do not use for Steam)
  https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/wine-staging-11.10-osx64.tar.xz
```

## Good news: `Sekiro.app` is self-contained

Its launcher uses `WINEROOT="$CONTENTS/Frameworks/Wine"` — an **embedded clone** of WhiskyWine 11.
So `~/Applications/Sekiro.app` keeps working even if `~/Library/.../Whisky/Libraries` is deleted.
(`Scripts/sekiro/sekiro-metalfx.sh` now prefers that embedded copy too, with a fallback.)

## Rebuild-from-scratch order (worst case)

1. Restore/reinstall **WhiskyWine 11.0** (URL above) — **not** wine 7.7, it can't log Steam in.
2. Create a prefix, install `SteamSetup.exe`, log in (QR via Steam Mobile App is easiest).
3. Install Sekiro via Steam (14 GB) — or drop old `steamapps/` back in; the `appmanifest_814380.acf`
   with `StateFlags "4"` makes Steam see it as already installed, no re-download.
4. Copy `d3d11.dll`, `dxgi.dll`, `d3d10core.dll` from `Libraries/DXMT/x64/` **into the game folder**.
5. Set `HKCU\Software\Wine\AppDefaults\sekiro.exe\DllOverrides` → those three = `native,builtin`.
   Leave global `DllOverrides` **empty**.
6. Restore `S0000.sl2` to `drive_c/users/<you>/AppData/Roaming/Sekiro/<steamid>/`.
7. Launch via `Sekiro.app` or `Scripts/sekiro/sekiro-metalfx.sh 1.5`.

## Facts you'd otherwise have to rediscover the hard way

- **Steam JWT expires Feb 11 2027.** After that you must log in again — which only works on
  **wine 11**, not 7.7. Keep WhiskyWine 11 around.
- Sekiro **rewrites `GraphicsConfig.xml` on exit** — edit it only while the game is closed, and
  keep `Auto-detectBestRenderingSettings` = `OFF` or it resets everything to HIGH.
- The file is **UTF-16LE with no BOM**. `open(p, encoding='utf-16')` **fails**; use `utf-16-le`.
- `Steam-Mythic` (435 MB) and the CrossOver bottle (2.8 GB) are leftovers — deletable.

# 9. ⚠️ No version control

`~/coding/Decanter` is **not a git repo**. There is no history and no undo — a bad edit or `rm`
loses the source and these docs permanently. Recommended:

```bash
cd ~/coding/Decanter && git init && git add -A && git commit -m "Decanter + gaming stack docs"
```
Suggested `.gitignore`: `build/`, `.build/`, `Assets/wizard-source.png` (large intermediate).
