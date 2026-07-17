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

    /// Create the directory skeleton if it does not yet exist.
    static func ensureDirectories() {
        for dir in [appSupport, bottlesRoot, downloads] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
