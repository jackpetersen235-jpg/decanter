# Decanter 🥃

A native SwiftUI **Wine bottle manager for gaming** on Apple Silicon Macs — the same
"bottles" idea as [Whisky](https://github.com/Whisky-App/Whisky) (now sunset), rebuilt
for **macOS Tahoe (26)** and focused on running **Steam and games**.

Decanter is the *front end*. It creates and configures isolated Windows environments
("bottles" = Wine prefixes), installs Steam into them, tunes the graphics/perf knobs that
matter for gaming, and launches everything with the right environment. The actual Windows
API translation is done by a Wine build you supply (see **Requirements**).

---

## How the stack works

Running a Windows game on an M-series Mac is a chain of translators. Decanter orchestrates it:

```
Windows game (x86-64)
      │
      ▼  Wine          Win32/Win64 API  → macOS system calls
      ▼  Rosetta 2     x86-64 instructions → Apple Silicon (arm64)
      ▼  D3DMetal /    DirectX 11/12    → Metal            (Game Porting Toolkit)
         DXVK          DirectX 9–11 → Vulkan → Metal
```

Each bottle stores its own choice of Windows version, graphics backend, thread-sync mode,
Retina/DPI, AVX advertising, and Steam launch flags.

## Requirements

Decanter **does not ship or download Wine** — you point it at a build you have the right
to use. It auto-detects, in order:

| Source | Where Decanter looks |
| --- | --- |
| **Whisky** (its bundled Wine) | `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin` |
| **Apple Game Porting Toolkit** | `/opt/homebrew/opt/game-porting-toolkit/bin`, `/usr/local/opt/...` |
| **CrossOver** | `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin` |
| **Wine Stable/Staging / Homebrew** | app bundles + `/opt/homebrew/bin`, `/usr/local/bin` |

You can also **Add Wine Bin Folder…** in Setup (or Settings) and pick any Wine `bin` folder.

Also required:
- **Rosetta 2** — Decanter checks for it and offers to install it (`softwareupdate --install-rosetta`).
- **Apple Silicon Mac** on macOS 14+ (built and tested against Tahoe 26.5.2).

## Build & run

```bash
# Dev run (opens the window directly)
swift run

# Or build a real double-clickable .app bundle
Scripts/make_app.sh          # produces build/Decanter.app
open build/Decanter.app
```

> Only Command Line Tools are needed — no full Xcode. The project is pure Swift Package Manager.

## Using it

1. **Setup** — confirm Rosetta is installed and a Wine build is detected (or add one).
2. **New Bottle** (⌘N) — names a bottle and runs `wineboot` to initialize the prefix.
3. **Overview ▸ Install Steam** — downloads the official `SteamSetup.exe` from Valve and
   installs it silently into the bottle.
4. **Configuration** — pick the graphics backend (D3DMetal / DXVK / WineD3D), sync mode,
   Windows version, Retina, DPI, AVX, etc. Press **Apply to Prefix** to write the
   registry-backed ones.
5. **Overview ▸ Launch Steam** — starts Steam with your configured launch flags.

## Project layout

```
Sources/Decanter/
  Support/     Shell (Process runner), Paths, SystemChecks, Panels
  Models/      Bottle, BottleSettings (Windows version, graphics, sync, …)
  Wine/        WineInstallation (discovery), Wine (env + commands + registry)
  Managers/    AppModel (state + actions), Steam (download/install), TaskConsole
  Views/       ContentView, SetupView, BottleDetailView, ConfigurationView,
               ProgramsView, ConsoleView, SettingsView, CreateBottleSheet
```

## Notes & limitations

- **Graphics DLLs.** D3DMetal ships inside GPTk/CrossOver Wine builds; DXVK needs its DLLs
  present in the prefix. Decanter sets the correct `WINEDLLOVERRIDES` / env for each backend
  but doesn't bundle third-party DLLs. WineD3D always works as a fallback.
- **Windows version** is applied via the standard `CurrentVersion` registry keys — good for
  most launchers; a few installers check additional keys.
- Bottles live in `~/Library/Application Support/Decanter/Bottles/` with an index at
  `bottles.json`.
- This is a starting point, not a shipping product — no notarization, sandbox, or auto-update.

## Legal

Wine, DXVK, and Apple's Game Porting Toolkit are separate projects under their own licenses.
Decanter only manages builds you install yourself. Steam is downloaded from Valve's official CDN.
