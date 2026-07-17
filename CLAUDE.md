# Decanter — context for future sessions

**Read this first.** Decanter is a SwiftUI macOS app that manages Wine "bottles" for gaming
(the Whisky/CrossOver idea, rebuilt). It was built alongside a real goal: getting
**Sekiro: Shadows Die Twice** running on an **M5 MacBook Air (macOS Tahoe 26.5.2)**.

Two separate things live here, and they are **not currently in sync**:
1. **The Decanter app** (this repo) — the bottle-manager GUI.
2. **A working Sekiro setup** (outside this repo) — `~/Applications/Sekiro.app`, hand-tuned.
   This is what actually runs the game. Decanter's bottle metadata is **stale** relative to it.

> Deep technical findings: [`docs/GAMING-STACK.md`](docs/GAMING-STACK.md) ← **read before touching
> anything Wine-related; it documents dead ends that cost hours.**
> Every file/download/path: [`docs/INVENTORY.md`](docs/INVENTORY.md)

---

## Build & run

```bash
swift build                  # Command Line Tools only — there is NO full Xcode on this machine
./Scripts/make_app.sh        # -> build/Decanter.app (also copies Assets/AppIcon.icns + wallpaper.png)
open build/Decanter.app
```

- Pure SwiftPM. **No `.xcodeproj`** — `xcodebuild` is unavailable (CLT-only install).
- `Package.swift` targets macOS 14; toolchain is Swift 6.3.3, `swift-tools-version:5.9`
  (deliberate: keeps Swift 5 language mode and avoids strict-concurrency errors).
- `@main struct DecanterApp` — do **not** add a `main.swift`, it conflicts.

## Layout

```
Sources/Decanter/
  Support/   Shell (Process runner), Paths, SystemChecks, Panels
  Models/    Bottle, BottleSettings (WindowsVersion / SyncMode / GraphicsBackend)
  Wine/      WineInstallation (discovery), Wine (env + registry + tools)
  Managers/  AppModel (all state + actions), Steam, TaskConsole
  Views/     ContentView, SetupView, BottleDetailView, ConfigurationView, …
Scripts/
  make_app.sh          bundles the binary into build/Decanter.app
  sekiro/              rescued launch scripts for the real Sekiro setup
Assets/                AppIcon.icns (wizard), wallpaper.png, wizard sources
docs/                  GAMING-STACK.md, INVENTORY.md
```

Data at runtime: `~/Library/Application Support/Decanter/`
(`bottles.json`, `Bottles/`, `ShaderCache/`, `Backups/`)

---

## ⚠️ Known-stale / TODO

- **Decanter's bottles point at the wrong engine.** `bottles.json` says the Steam + Sekiro
  bottles use **Mythic (GPTk / D3DMetal) wine-7.7**, graphics **DXVK**, sync **ESync**.
  Reality: the working setup uses **WhiskyWine 11.0 + DXMT**, prefix `Steam-Wine11`.
  ⇒ Decanter's **Launch Steam** button does NOT reproduce what `Sekiro.app` does.
  Fix = repoint both bottles to `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin`
  and set `graphics = .dxmt`-equivalent. **`GraphicsBackend` has no `.dxmt` case yet — it needs one.**
- `BottleSettings.syncMode` (msync/esync) is **meaningless on wine 11** — it has neither.
  See GAMING-STACK.md; consider showing sync support per-build instead of a free-choice picker.
- `Steam-Mythic` prefix (~435 MB) is a leftover experiment — safe to delete.
- CrossOver bottle `~/Library/Application Support/CrossOver/Bottles/Steam` (~2.8 GB) is a
  leftover client install; Sekiro was **moved out** of it. Safe to delete if CrossOver is gone.

## Gotchas that already bit us (don't rediscover these)

- **`sips` writes JPEG data into `.png` filenames** unless you pass `-s format png`.
  `iconutil` then fails with a useless "Failed to generate ICNS". This silently broke the icon twice.
- **Whisky.app is sandboxed** → its Wine lives under
  `~/Library/Containers/com.isaacmarovitz.Whisky/Data/Library/Application Support/...`.
  The non-sandboxed path is still used by the manually-installed WhiskyWine (see INVENTORY).
- **CrossOver's wine ignores `WINEPREFIX`** — it finds bottles by name via `CX_BOTTLE`
  (+ `CX_ROOT`). `Wine.swift` handles this via `WineInstallation.isCrossOver`.
- **`open(1)` does not forward environment variables** to the launched app. To pass env to a
  bundle, bake it into the launcher script inside `Contents/MacOS/`.
- **Deep-signing a bundle containing a Wine tree fails** ("code object is not signed at all").
  An *invalid* signature is worse than none — `codesign --remove-signature` is fine for local apps.
- **`grep -rl` silently fails on these Mach-O trees.** Use `strings <file> | grep`. A tree-wide
  grep returned 0 hits for a term that `strings` found 27 times — nearly caused a wrong conclusion.
- Backups/snapshots: use **`cp -Rc`** (APFS clone). 16 GB cloned in 1.4 s with ~0 disk used.

## Verification habits that mattered

- **Screenshots beat logs.** `screencapture -x` + Read. Logs said "0 errors" while the screen was
  a black rectangle. Terminal has Screen Recording permission; it does **not** have Accessibility,
  so `System Events` reports **0 windows** for wine processes and cannot click/fullscreen them.
- Wine windows are their own macOS Space in fullscreen — a plain screenshot catches the wrong Space.
  Raise the wine process first (`System Events` → `set frontmost`), then capture.
- Long-running launches must use `run_in_background: true`. A foreground command's timeout
  **SIGTERMs the whole process group** and killed a Steam download at 90%.

