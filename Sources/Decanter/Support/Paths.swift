import Foundation

/// Well-known on-disk locations used by the app.
enum Paths {
    static let appName = "Decanter"
    static let bundleIdentifier = "com.decanter.app"

    static var appSupport: URL {
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
