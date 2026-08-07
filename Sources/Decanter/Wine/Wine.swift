import Foundation

/// Stateless helpers for discovering Wine builds and constructing the commands +
/// environment needed to drive a bottle. All heavy lifting shells out through `Shell`.
enum Wine {

    // MARK: - Discovery

    /// Common locations for gaming-oriented Wine builds on Apple Silicon.
    private static var candidateBinDirectories: [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // ORDER MATTERS: the first hit becomes the default for new bottles.
        // The Decanter engine (upstream wine 11, frankea) is first because it runs Steam +
        // DXMT standalone today — but it has NO msync, so thread-heavy games spike. A free
        // CrossOver-sourced build (e.g. WS12WineCX24, wine 9) HAS msync but needs a proper
        // wrapper for Steam networking; see docs/GAMING-STACK.md §2/§2b. Don't repeat the old
        // "wine 7.7 is the only msync option" mistake — the axis is source tree, not version.
        return [
            // Decanter's own engine (installed by the setup wizard) — always preferred.
            ("Decanter Engine", Paths.wineEngineBin.path),
            // The isolated online-play engine. Listed AFTER the main one so it never becomes the
            // default for ordinary new bottles - online bottles select it explicitly.
            ("Decanter Engine (Online)", Paths.onlineEngineBin.path),
            // Must be listed here or the engine is invisible to `setEngineProfile`, which resolves
            // a profile through `installations`. Creating the directory is not enough — the clone
            // succeeded and switching to it still failed with "That engine isn't available".
            ("Decanter Engine (Legacy)", Paths.legacyEngineBin.path),
            // Non-sandboxed WhiskyWine (manual install of Libraries.tar.gz) — the working build.
            ("Whisky", "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"),
            // Whisky.app is sandboxed: its Wine lives inside the app container.
            ("Whisky", "\(home)/Library/Containers/com.isaacmarovitz.Whisky/Data/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"),
            // Mythic ships a GPTk wine-7.7 (D3DMetal + msync) — good sync, but no modern Steam login.
            ("Mythic (GPTk / D3DMetal)", "\(home)/Library/Application Support/Mythic/Engine/wine/bin"),
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
            var candidate = WineInstallation(binDirectory: dir, name: name)
            guard candidate.isValid, !seen.contains(candidate.id) else { return }
            // Probe once at discovery — msync/esync support decides whether this build will
            // spike in thread-heavy games. See WineInstallation.supportsFastSync.
            candidate.supportsFastSync = WineInstallation.probeFastSync(binDirectory: dir)
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

        // Persistent DXMT shader cache, per bottle — reduces repeat stutter across launches.
        let cache = Paths.shaderCache(for: bottle)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["DXMT_SHADER_CACHE_PATH"] = cache.path

        // Layer on the settings-derived flags (sync mode, graphics backend, HUDs, …).
        for (key, value) in bottle.settings.derivedEnvironment { env[key] = value }

        // …then strip fast-sync vars if this build can't honour them. Must come AFTER the
        // settings merge above, which is what sets them. On a build without the msync feature
        // (e.g. the current upstream-11 engine) these are a silent no-op and only mislead; on a
        // CrossOver-sourced build they're consumed (see WineInstallation.supportsFastSync).
        if !installation.supportsFastSync {
            env.removeValue(forKey: "WINEMSYNC")
            env.removeValue(forKey: "WINEESYNC")
        }
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
