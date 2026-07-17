import Foundation

/// Stateless helpers for discovering Wine builds and constructing the commands +
/// environment needed to drive a bottle. All heavy lifting shells out through `Shell`.
enum Wine {

    // MARK: - Discovery

    /// Common locations for gaming-oriented Wine builds on Apple Silicon.
    private static var candidateBinDirectories: [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // Mythic ships a GPTk-based Wine (D3DMetal) — great for gaming, no extra download.
            ("Mythic (GPTk / D3DMetal)", "\(home)/Library/Application Support/Mythic/Engine/wine/bin"),
            // Whisky is sandboxed: its Wine lives inside the app container.
            ("Whisky", "\(home)/Library/Containers/com.isaacmarovitz.Whisky/Data/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"),
            // Older (non-sandboxed) Whisky layout.
            ("Whisky", "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"),
            ("Game Porting Toolkit", "/usr/local/opt/game-porting-toolkit/bin"),
            ("Game Porting Toolkit", "/opt/homebrew/opt/game-porting-toolkit/bin"),
            ("CrossOver", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"),
            ("CrossOver", "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"),
            ("Wine Stable", "/Applications/Wine Stable.app/Contents/Resources/wine/bin"),
            ("Wine Staging", "/Applications/Wine Staging.app/Contents/Resources/wine/bin"),
            ("Wine Staging 11 (Steam-capable)", "\(home)/Applications/Wine Staging.app/Contents/Resources/wine/bin"),
            ("Homebrew Wine", "/opt/homebrew/bin"),
            ("Homebrew Wine", "/usr/local/bin"),
        ]
    }

    /// Scan the well-known locations plus any paths the user added manually.
    static func discover(extraDirectories: [URL] = []) -> [WineInstallation] {
        var results: [WineInstallation] = []
        var seen = Set<String>()

        func consider(name: String, dir: URL) {
            let candidate = WineInstallation(binDirectory: dir, name: name)
            guard candidate.isValid, !seen.contains(candidate.id) else { return }
            seen.insert(candidate.id)
            results.append(candidate)
        }

        for entry in candidateBinDirectories {
            consider(name: entry.name, dir: URL(fileURLWithPath: entry.path))
        }
        for dir in extraDirectories {
            consider(name: dir.deletingLastPathComponent().lastPathComponent, dir: dir)
        }
        return results
    }

    /// Ask a Wine build for its version string (best effort).
    static func version(of installation: WineInstallation) async -> String? {
        guard let result = try? await Shell.run(installation.loader, arguments: ["--version"]),
              result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Environment

    /// Full environment for launching anything inside `bottle`.
    static func environment(for bottle: Bottle, using installation: WineInstallation) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["WINEDEBUG"] = bottle.settings.verboseLogging ? "warn+all,fixme-all" : "-all"

        if installation.isCrossOver {
            // CrossOver's wine locates bottles by *name* under its own Bottles dir via
            // CX_BOTTLE — it ignores WINEPREFIX. CX_ROOT points at the CrossOver payload.
            env["CX_ROOT"] = installation.binDirectory.deletingLastPathComponent().path
            env["CX_BOTTLE"] = bottle.url.lastPathComponent
            env["WINEPREFIX"] = bottle.url.path   // harmless fallback
        } else {
            env["WINEPREFIX"] = bottle.url.path
            env["WINELOADER"] = installation.loader.path
            env["WINESERVER"] = installation.wineserver.path
        }

        // Make sure wineserver and helpers resolve.
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(installation.binDirectory.path):\(existingPath)"

        // GPTk / CrossOver builds ship dylibs alongside the loader.
        if FileManager.default.fileExists(atPath: installation.libDirectory.path) {
            let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/local/lib:/usr/lib"
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(installation.libDirectory.path):\(existing)"
        }

        // Layer on the settings-derived flags (sync mode, graphics backend, HUDs, …).
        for (key, value) in bottle.settings.derivedEnvironment { env[key] = value }
        return env
    }

    // MARK: - Prefix lifecycle

    /// Initialize a fresh prefix with `wineboot`. Streams progress into `console`.
    /// The completion fires with the exit code once the boot finishes.
    @MainActor
    @discardableResult
    static func bootPrefix(
        _ bottle: Bottle,
        using installation: WineInstallation,
        console: TaskConsole,
        onExit: @escaping (Int32) -> Void
    ) -> ProcessHandle? {
        try? FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        let env = environment(for: bottle, using: installation)
        console.append("$ wineboot --init   (WINEPREFIX=\(bottle.url.path))")
        return try? Shell.stream(
            installation.loader,
            arguments: ["wineboot", "--init"],
            environment: env,
            onOutput: { console.append($0) },
            onExit: { code in console.append("wineboot exited \(code)"); onExit(code) }
        )
    }

    // MARK: - Registry-backed settings

    /// The sequence of `wine reg add` invocations that apply a bottle's settings to its prefix.
    static func registrySteps(for bottle: Bottle, using installation: WineInstallation) -> [(URL, [String])] {
        let loader = installation.loader
        var steps: [(URL, [String])] = []

        // Windows version.
        let reg = bottle.settings.windowsVersion.registry
        let ntKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#
        steps.append((loader, ["reg", "add", ntKey, "/v", "CurrentVersion", "/t", "REG_SZ", "/d", reg.currentVersion, "/f"]))
        steps.append((loader, ["reg", "add", ntKey, "/v", "CurrentBuild", "/t", "REG_SZ", "/d", reg.build, "/f"]))
        steps.append((loader, ["reg", "add", ntKey, "/v", "CurrentBuildNumber", "/t", "REG_SZ", "/d", reg.build, "/f"]))
        steps.append((loader, ["reg", "add", ntKey, "/v", "ProductName", "/t", "REG_SZ", "/d", reg.productName, "/f"]))

        // Retina / HiDPI mode via the Mac driver.
        let macDriver = #"HKCU\Software\Wine\Mac Driver"#
        steps.append((loader, ["reg", "add", macDriver, "/v", "RetinaMode", "/t", "REG_SZ",
                               "/d", bottle.settings.retinaMode ? "y" : "n", "/f"]))

        // Screen DPI.
        let desktop = #"HKCU\Control Panel\Desktop"#
        steps.append((loader, ["reg", "add", desktop, "/v", "LogPixels", "/t", "REG_DWORD",
                               "/d", String(bottle.settings.dpi), "/f"]))

        return steps
    }

    // MARK: - Built-in tools

    /// Standard Wine utilities, keyed by the argument passed to the loader.
    enum Tool: String, CaseIterable, Identifiable {
        case winecfg, regedit, taskmgr, control, cmd, explorer

        var id: String { rawValue }
        var title: String {
            switch self {
            case .winecfg:  return "Wine Configuration"
            case .regedit:  return "Registry Editor"
            case .taskmgr:  return "Task Manager"
            case .control:  return "Control Panel"
            case .cmd:      return "Command Prompt"
            case .explorer: return "File Explorer"
            }
        }
        var arguments: [String] {
            self == .explorer ? ["explorer"] : [rawValue]
        }
    }
}
