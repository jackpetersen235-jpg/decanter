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
    /// msync is a CodeWeavers/CrossOver source patch — it depends on the **source tree, not the
    /// wine version**. Upstream wine (any version, incl. the 11.0 we currently ship from
    /// frankea/Whisky) never had it; CrossOver-sourced builds have it at modern versions too.
    /// Verified 2026-07-17: the free `WS12WineCX24.0.7` (CrossOver 24 = wine 9.0) has msync and it
    /// activates. So this being false is a property of the *current* engine, not of "wine 11."
    /// See docs/GAMING-STACK.md §2.
    var supportsFastSync: Bool = false

    /// Cheap probe for the msync/esync *feature* in the build's unix-side ntdll.
    ///
    /// We look for `WINEMSYNC` / `WINEESYNC` — the env-var names the feature's code reads. Do NOT
    /// search for bare "msync"/"esync": every ntdll contains the POSIX `_msync()` syscall *symbol*
    /// in its symbol table, which made this return a false positive for wine 11 (verified: fresh
    /// WhiskyWine 11 ntdll has `_msync` but no `WINEMSYNC`; Mythic's has `WINEMSYNC`). `strings`
    /// misses `_msync` because it skips the symbol table, but a raw byte scan does not.
    static func probeFastSync(binDirectory: URL) -> Bool {
        let ntdll = binDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        guard let data = try? Data(contentsOf: ntdll, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("WINEMSYNC".utf8)) != nil
            || data.range(of: Data("WINEESYNC".utf8)) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case binDirectory, name, version   // supportsFastSync is probed, never persisted
    }
}
