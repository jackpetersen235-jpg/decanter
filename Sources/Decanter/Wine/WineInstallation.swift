import Foundation

/// A discovered Wine toolset (a `bin` directory containing `wine`/`wine64`/`wineserver`).
struct WineInstallation: Codable, Equatable, Identifiable, Hashable {
    /// The `bin` directory. Doubles as a stable identifier.
    var binDirectory: URL
    var name: String
    var version: String?

    var id: String { binDirectory.path }

    var wine: URL { binDirectory.appendingPathComponent("wine") }
    var wine64: URL { binDirectory.appendingPathComponent("wine64") }
    var wineserver: URL { binDirectory.appendingPathComponent("wineserver") }

    /// Prefer the 64-bit loader when present (it can still launch 32-bit apps).
    var loader: URL {
        FileManager.default.isExecutableFile(atPath: wine64.path) ? wine64 : wine
    }

    /// `.../lib` sits next to `.../bin` in every standard Wine layout.
    var libDirectory: URL {
        binDirectory.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
    }

    /// True when at least one loader binary is actually executable.
    var isValid: Bool {
        FileManager.default.isExecutableFile(atPath: wine.path) ||
        FileManager.default.isExecutableFile(atPath: wine64.path)
    }

    /// CrossOver's wine is a wrapper that resolves bottles by name (CX_BOTTLE) rather
    /// than by WINEPREFIX, so it needs special environment handling.
    var isCrossOver: Bool {
        binDirectory.path.contains("CrossOver.app")
    }
}
