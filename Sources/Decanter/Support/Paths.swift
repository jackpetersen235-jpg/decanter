import Foundation

/// Well-known on-disk locations used by the app.
enum Paths {
    static let appName = "Decanter"
    static let bundleIdentifier = "com.decanter.app"

    /// `appSupport`, but redirectable via `DECANTER_HOME` for headless testing.
    ///
    /// Every first-run and gameplay bug that has cost this project real time (see the
    /// pre-release debug plan) shared one property: it couldn't fire on a machine already in the
    /// state the buggy code was trying to reach. There was no way to be a fresh Mac without
    /// risking the real 25 GB `Steam-Wine11` install — `homeDirectoryForCurrentUser` reads the
    /// passwd entry and ignores `$HOME`, so faking a clean-home test by overriding `$HOME` alone
    /// does not work (already documented in CLAUDE.md).
    ///
    /// `DECANTER_HOME`, when set, IS the app-support root directly — no "Decanter" subfolder is
    /// appended, so the caller's scratch directory is exactly what gets populated and exactly
    /// what a plain `rm -rf` clears between runs:
    ///
    ///   rm -rf /tmp/decanter-scratch
    ///   DECANTER_HOME=/tmp/decanter-scratch build/Decanter.app/Contents/MacOS/Decanter --run-setup
    ///
    /// Every other path in this file derives from `appSupport`, so this one override is
    /// sufficient — nothing else needed its own env check. Never read outside DEBUG/testing
    /// contexts by intent; there is no separate production/debug gate because an unset env var
    /// is already a no-op, and a real user's environment will never have this variable set.
    static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["DECANTER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// Parent folder that holds every bottle's WINEPREFIX.
    static var bottlesRoot: URL { appSupport.appendingPathComponent("Bottles", isDirectory: true) }

    /// JSON index describing all known bottles.
    static var bottlesIndex: URL { appSupport.appendingPathComponent("bottles.json") }

    /// Scratch space for installer downloads (SteamSetup.exe, etc.).
    static var downloads: URL { appSupport.appendingPathComponent("Downloads", isDirectory: true) }

    /// Decanter's own Wine engine, installed by the setup wizard. Owning this ourselves means
    /// the app never depends on Whisky/Mythic/CrossOver being present.
    static var wineEngineRoot: URL { appSupport.appendingPathComponent("Wine", isDirectory: true) }
    static var wineEngineLibraries: URL { wineEngineRoot.appendingPathComponent("Libraries", isDirectory: true) }
    static var wineEngineBin: URL { wineEngineLibraries.appendingPathComponent("Wine/bin", isDirectory: true) }

    /// A SECOND, fully independent copy of the engine, used only by online-play bottles.
    ///
    /// The point is blast radius. The single-player setup is hand-tuned and was expensive to get
    /// right, so online work must not be able to touch its engine files, DLL overrides or registry.
    /// A separate prefix alone would not achieve that - graphics DLLs and `winemetal` live in the
    /// ENGINE tree, so a change there is felt by every bottle pointing at it.
    ///
    /// This is nearly free: it is created with `cp -Rc` (APFS clone), which shares blocks until a
    /// file is modified. Measured 2026-07-30: 1.0 s, 2 MB actually consumed for a 719 MB tree.
    /// A third, independent engine for LEGACY titles.
    ///
    /// Old 32-bit games hit constraints the tuned engine cannot help with — Rosetta's x87 handling
    /// above all — and every candidate fix (a CrossOver-based build, a Rosetta hook, a rebuilt
    /// wine) risks the setup that already works. This gives that experimentation somewhere to live
    /// where it cannot reach the engine Sekiro and JJBA depend on.
    static var legacyEngineRoot: URL { appSupport.appendingPathComponent("WineLegacy", isDirectory: true) }
    static var legacyEngineLibraries: URL { legacyEngineRoot.appendingPathComponent("Libraries", isDirectory: true) }
    static var legacyEngineBin: URL { legacyEngineLibraries.appendingPathComponent("Wine/bin", isDirectory: true) }

    static var onlineEngineRoot: URL { appSupport.appendingPathComponent("WineOnline", isDirectory: true) }
    static var onlineEngineLibraries: URL { onlineEngineRoot.appendingPathComponent("Libraries", isDirectory: true) }
    static var onlineEngineBin: URL { onlineEngineLibraries.appendingPathComponent("Wine/bin", isDirectory: true) }

    /// Persistent shader caches (DXMT). Survives launches so repeat shader-compilation stutter
    /// fades the more a game is played.
    static var shaderCacheRoot: URL { appSupport.appendingPathComponent("ShaderCache", isDirectory: true) }

    /// `gameKey` scopes the cache to one GAME rather than one prefix — pass the resolved game's
    /// own key (see `AppModel.shaderCacheGameKey`) whenever a specific game is actually being
    /// launched. Several games can share one Wine prefix (Steam-Wine11 holds three on this
    /// machine), and until this existed every one of them funneled into a single directory keyed
    /// by the PREFIX's name, colliding their shader caches together and missing the warm,
    /// already-built caches the hand-tuned external launchers (Sekiro.app, JJBA All-Star
    /// Battle.app) had been keeping in `ShaderCache/Sekiro` / `ShaderCache/ASBR` — found during
    /// the second settings-parity audit (2026-09-01). Falls back to the prefix name when no
    /// specific game applies (a plain Steam launch, wineboot, a registry-only operation) — nothing
    /// user-facing is rendering there, so prefix-level scoping is fine.
    static func shaderCache(for bottle: Bottle, gameKey: String? = nil) -> URL {
        shaderCacheRoot.appendingPathComponent(gameKey ?? bottle.url.lastPathComponent, isDirectory: true)
    }

    /// Patched DXMT DLLs shipped inside the app bundle (Resources/DXMT).
    ///
    /// Upstream DXMT 0.80 freezes for ~26 s whenever its geometry-shader argument-marshal shader
    /// gets a multi-task batch, because the shader never advances its task index. These rebuilt
    /// DLLs fix that. Only the three game-folder DLLs need replacing - verified against a
    /// completely stock engine - so nothing in the Wine tree is touched.
    static var bundledDXMT: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DXMT", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("d3d11.dll").path)
        else { return nil }
        return dir
    }

    /// The DLLs that make up the per-game graphics override.
    static let dxmtDLLs = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    /// The bundled `gpukeepalive` helper (Contents/MacOS/gpukeepalive) — see
    /// `Sources/GPUKeepalive/main.swift` and `BottleSettings.gpuKeepAlive`. Same nil-when-absent
    /// shape as `bundledDXMT`: a dev build run via `swift run` (no `make_app.sh` pass) has no
    /// `Bundle.main.executableURL` sibling to find, and the feature should degrade to doing
    /// nothing rather than crash looking for it.
    static var bundledGPUKeepalive: URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let bin = dir.appendingPathComponent("gpukeepalive")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// The TEMPLATE of "Decanter Game.app" shipped inside this bundle — the games-category app a
    /// "Real game window" game is launched through so macOS Game Mode will engage for it (see
    /// Helpers/GameHost/game-host.c). Never launched from here: see `installedGameHost`. Nil in a
    /// `swift run` dev build, which has no bundle; the caller falls back to a plain launch.
    static var bundledGameHostTemplate: URL? {
        guard let app = Bundle.main.resourceURL?
            .appendingPathComponent("GameHost/Decanter Game.app", isDirectory: true) else { return nil }
        let exe = app.appendingPathComponent("Contents/MacOS/decanter-game-host")
        return FileManager.default.isExecutableFile(atPath: exe.path) ? app : nil
    }

    /// Where "Decanter Game.app" is installed and launched from: top level in Decanter's own data
    /// folder, NOT nested inside Decanter.app. Measured 2026-10-12 — launched from inside another
    /// app's bundle, `gamepolicyd` treats it as an app extension ("No appex record… Finding
    /// containing app") and never opens a gaming session; the identical bundle at a top-level path
    /// turned Game Mode on the instant the game went fullscreen. Removed by the uninstaller.
    static var installedGameHost: URL {
        appSupport.appendingPathComponent("Decanter Game.app", isDirectory: true)
    }

    /// The x86_64 window hook injected into a "Real game window" game — makes its window
    /// resizable so the green button / native fullscreen works (Helpers/WindowHook/window-hook.m).
    static var bundledWindowHook: URL? {
        guard let dylib = Bundle.main.resourceURL?
            .appendingPathComponent("WindowHook/libwindowhook.dylib") else { return nil }
        return FileManager.default.fileExists(atPath: dylib.path) ? dylib : nil
    }

    /// Where the window hook is copied to and injected from. Out of the bundle for the same reason
    /// the host's copy is cleared: a downloaded Decanter's files are quarantined (see `Quarantine`).
    static var installedWindowHook: URL {
        appSupport.appendingPathComponent("WindowHook/libwindowhook.dylib")
    }

    /// Rolling console history, so a crash or a force-quit doesn't take the only record of what
    /// just happened with it. Part of the pre-release debug plan's Phase 4 — before this, every
    /// `TaskConsole`'s text lived only in memory and died with the sheet that showed it, so a
    /// remote bug report was always "it failed" with nothing behind it.
    static var logsRoot: URL { appSupport.appendingPathComponent("Logs", isDirectory: true) }
    static var consoleLog: URL { logsRoot.appendingPathComponent("console.log") }

    /// Create the directory skeleton if it does not yet exist.
    static func ensureDirectories() {
        for dir in [appSupport, bottlesRoot, downloads, logsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
