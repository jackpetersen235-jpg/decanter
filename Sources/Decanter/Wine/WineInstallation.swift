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

    /// Whether this build implements msync/esync (fast synchronization).
    ///
    /// This matters more than it looks. Without it, every Windows mutex/event round-trips
    /// through `wineserver` over IPC — measured on this machine at **39.9% wineserver CPU vs
    /// 0.1% with msync** — which surfaces as frame spikes in thread-heavy games (Sekiro runs
    /// ~103 threads). `WINEMSYNC=1` is silently ignored by builds that lack it.
    ///
    /// msync is a CodeWeavers patch, so it exists only in wine-7.7-era CrossOver forks.
    /// Upstream wine 11 replaced it with `ntsync`, which needs a **Linux kernel driver** —
    /// so wine 11 on macOS has no fast sync at all. See docs/GAMING-STACK.md §2.
    var supportsFastSync: Bool = false

    /// Cheap probe: look for the msync/esync symbols in the build's unix-side ntdll.
    static func probeFastSync(binDirectory: URL) -> Bool {
        let ntdll = binDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        guard let data = try? Data(contentsOf: ntdll, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("msync".utf8)) != nil
            || data.range(of: Data("esync".utf8)) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case binDirectory, name, version   // supportsFastSync is probed, never persisted
    }
}
