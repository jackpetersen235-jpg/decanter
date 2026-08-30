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

    /// Persistent shader caches (DXMT), one per bottle. Survives launches so repeat
    /// shader-compilation stutter fades the more a game is played.
    static var shaderCacheRoot: URL { appSupport.appendingPathComponent("ShaderCache", isDirectory: true) }

    static func shaderCache(for bottle: Bottle) -> URL {
        shaderCacheRoot.appendingPathComponent(bottle.url.lastPathComponent, isDirectory: true)
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

    /// Create the directory skeleton if it does not yet exist.
    static func ensureDirectories() {
        for dir in [appSupport, bottlesRoot, downloads] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
