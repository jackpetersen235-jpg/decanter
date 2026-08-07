import Foundation

/// Builds a double-clickable `.app` that launches one game in one bottle.
///
/// Why generate these at all: the tuned launchers under `~/Applications` (`Sekiro.app`, the JJBA
/// one) were written by hand, and every setting in them — msync, the DXMT config string, the
/// shader-cache path, the wait for Steam to finish logging on — had to be rediscovered per game.
/// This produces the same launcher from the bottle's own settings, so a new game costs one press
/// of a button instead of an afternoon.
///
/// The generated bundle **references** Decanter's shared engine instead of embedding a copy of
/// Wine. The hand-made bundles embed one at ~696 MB each; doing that per game would spend ~700 MB
/// apiece on bytes already sitting in Application Support. The trade-off is that these bundles are
/// not portable to another Mac — which is correct, because the prefix they point at isn't either.
enum GameAppBuilder {

    struct Game {
        let name: String
        let folder: URL
        let executable: URL
        /// Steam's numeric app id. `steam_api64.dll` needs it in the environment because Steam is
        /// not the one spawning the process on this path.
        let appID: String?
    }

    enum BuildError: LocalizedError {
        case noGame
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noGame: return "No installed game was found in this bottle."
            case .writeFailed(let s): return "Could not write the launcher: \(s)"
            }
        }
    }

    // MARK: Paths

    static var applicationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    /// Where a bottle's generated launcher lives. Derived, never stored — a stored path would go
    /// stale the moment the user renamed or moved the bundle in Finder.
    static func destination(for bottle: Bottle) -> URL {
        applicationsDirectory.appendingPathComponent("\(safeName(bottle.name)).app", isDirectory: true)
    }

    /// `/` and `:` both break a bundle name on macOS (`:` is the legacy path separator and Finder
    /// renders it as `/`). Trademark glyphs in Steam titles — "Sekiro™" — are left alone; they are
    /// legal in a filename and stripping them would stop the name matching the library.
    static func safeName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Game" : cleaned
    }

    // MARK: Shell quoting

    /// POSIX single-quote.
    ///
    /// NOT optional here: one of the two games this was built against lives in
    /// `steamapps/common/JoJo's Bizarre Adventure All-Star Battle R`. Interpolating that path raw
    /// closes the quote at the apostrophe, and the launcher would run something else entirely — or
    /// nothing — with a shell error nobody reads. Every path below goes through this.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Build

    /// Write (or overwrite) the launcher bundle. Returns the bundle URL.
    @discardableResult
    static func build(game: Game,
                      bottle: Bottle,
                      wineBin: URL,
                      wineLib: URL?,
                      environment: [String: String],
                      steamExecutable: URL,
                      skipInitialBootstrap: Bool) throws -> URL {
        let app = destination(for: bottle)
        let fm = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)

        do {
            // Replace wholesale rather than patching in place: a half-updated launcher that still
            // runs is worse than one that is obviously absent.
            if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

            let exec = macOS.appendingPathComponent("launch")
            let script = launcherScript(game: game, bottle: bottle, wineBin: wineBin,
                                        wineLib: wineLib, environment: environment,
                                        steamExecutable: steamExecutable,
                                        skipInitialBootstrap: skipInitialBootstrap)
            try script.write(to: exec, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)

            try infoPlist(for: game, bottle: bottle)
                .write(to: app.appendingPathComponent("Contents/Info.plist"),
                       atomically: true, encoding: .utf8)
        } catch {
            throw BuildError.writeFailed(error.localizedDescription)
        }
        return app
    }

    // MARK: Script

    static func launcherScript(game: Game,
                               bottle: Bottle,
                               wineBin: URL,
                               wineLib: URL?,
                               environment: [String: String],
                               steamExecutable: URL,
                               skipInitialBootstrap: Bool) -> String {
        let q = shellQuote
        let wine = wineBin.appendingPathComponent("wine").path
        let exeName = game.executable.lastPathComponent

        var env = environment
        // The engine is resolved here rather than inherited, so the bundle keeps working when
        // launched from Finder, where none of Decanter's environment exists.
        env["WINEPREFIX"] = bottle.url.path
        env["WINELOADER"] = wine
        env["WINESERVER"] = wineBin.appendingPathComponent("wineserver").path
        if let id = game.appID, !id.isEmpty {
            env["SteamAppId"] = id
            env["SteamGameId"] = id
        }
        // Inherited junk would otherwise be baked into a file that outlives this process.
        for key in ["PATH", "DYLD_FALLBACK_LIBRARY_PATH", "HOME", "PWD", "SHLVL", "_", "TMPDIR"] {
            env.removeValue(forKey: key)
        }

        var lines = [
            "#!/bin/bash",
            "#",
            "# \(game.name) — launcher for the \"\(bottle.name)\" bottle.",
            "#",
            "# GENERATED BY DECANTER. Edits are lost the next time it is rebuilt; change the",
            "# bottle's settings and press \"Rebuild Game App\" instead.",
            "#",
            "# Uses Decanter's shared Wine engine rather than embedding one, so this bundle is a",
            "# few KB. It is therefore tied to this Mac — as is the prefix it launches.",
            "set -u",
            "",
            "WINE=\(q(wine))",
            "GAME_DIR=\(q(game.folder.path))",
            "GAME_EXE=\(q(game.executable.path))",
            "",
            "# Already running? Do nothing rather than start a second copy.",
            "#",
            "# `pgrep -x` matches the process NAME. The -f form used by the hand-written launchers",
            "# matches the whole command line, which is the bug this project has hit repeatedly:",
            "# it also matches any shell whose arguments merely mention the exe, including this",
            "# script's own.",
            "#",
            "# No attempt is made to raise the window. A Wine game's window belongs to winemac.drv,",
            "# not to any bundle `open -a` can name, and driving it needs Accessibility permission",
            "# this script does not have. Exiting quietly beats a command that always fails.",
            "if pgrep -x \(q(exeName)) >/dev/null 2>&1; then",
            "  exit 0",
            "fi",
            "",
        ]

        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(k)=\(q(v))")
        }
        var path = wineBin.path
        if let lib = wineLib { path += ":" + lib.path }
        lines += [
            "export PATH=\(q(wineBin.path)):\"$PATH\"",
            "export DYLD_FALLBACK_LIBRARY_PATH=\(q(wineLib?.path ?? ""))\":/usr/local/lib:/usr/lib\"",
            "",
        ]
        _ = path

        // START STEAM FOR ANY GAME LIVING IN A STEAM LIBRARY, not only ones whose app id we know.
        //
        // This was gated on `game.appID != nil`, which conflated two different needs. The app id is
        // required for the `SteamAppId` ENV VAR; it has nothing to do with whether the client must
        // be running. Steam-DRM'd titles ship their own `Steam.dll` beside the executable and that
        // DLL fails without a live client — Peggle Deluxe died with "Unable to load Steam.dll" on a
        // launcher that, verified, contained zero references to steam.exe.
        //
        // Keyed on the path rather than the id: anything under `steamapps` came from Steam and may
        // carry its DRM, whether or not the manifest resolved. A game chosen by hand from outside a
        // Steam library still skips this, which is right — it has no reason to want Steam at all.
        let livesInSteamLibrary = game.executable.path.contains("/steamapps/")
        if game.appID != nil || livesInSteamLibrary {
            let steamDir = steamExecutable.deletingLastPathComponent()
            let connLog = steamDir.appendingPathComponent("logs/connection_log.txt")
            // -silent is right HERE and nowhere else: Steam is only a DRM host for this launch, so
            // its window is unwanted. The bootstrap flag is conditional because skipping the
            // first-run client download on a Steam that has never done one leaves it unable to
            // start at all ("Failed to load steamui.dll").
            let flags = skipInitialBootstrap
                ? "-silent -no-cef-sandbox -skipinitialbootstrap"
                : "-no-cef-sandbox"
            lines += [
                "# steam_api64 needs a running client. Match on '/steam.exe' with the leading",
                "# slash — Steam's webhelpers carry -steampath=C:\\...\\steam.exe in their argv and",
                "# a bare match hits those orphans, which outlive Steam by hours.",
                "if ! pgrep -f '/steam\\.exe' >/dev/null 2>&1; then",
                "  \"$WINE\" \(q(steamExecutable.path)) \(flags) >/dev/null 2>&1 &",
                "  CONNLOG=\(q(connLog.path))",
                "  # Count NEW logons. The log is cumulative, so 'any logon present' would be",
                "  # satisfied by yesterday's and the game would start before Steam is ready.",
                "  BASE=$(grep -c 'Logged On,' \"$CONNLOG\" 2>/dev/null || echo 0)",
                "  for _ in $(seq 1 75); do",
                "    NOW=$(grep -c 'Logged On,' \"$CONNLOG\" 2>/dev/null || echo 0)",
                "    [ \"$NOW\" -gt \"$BASE\" ] && break",
                "    sleep 2",
                "  done",
                "  sleep 10",
                "fi",
                "",
            ]
        }

        lines += [
            "cd \"$GAME_DIR\" || exit 1",
            "exec \"$WINE\" \"$GAME_EXE\"",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: Info.plist

    static func infoPlist(for game: Game, bottle: Bottle) -> String {
        let name = safeName(bottle.name)
        // Bundle ids must be unique per app or LaunchServices treats two launchers as the same
        // application and activates the wrong window.
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>            <string>\(name)</string>
            <key>CFBundleDisplayName</key>     <string>\(name)</string>
            <key>CFBundleIdentifier</key>      <string>com.decanter.game.\(slug.isEmpty ? "game" : slug)</string>
            <key>CFBundleExecutable</key>      <string>launch</string>
            <key>CFBundlePackageType</key>     <string>APPL</string>
            <key>CFBundleShortVersionString</key> <string>1.0</string>
            <key>CFBundleVersion</key>         <string>1</string>
            <key>LSMinimumSystemVersion</key>  <string>14.0</string>
            <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
            <key>NSHighResolutionCapable</key> <true/>
            <key>NSHumanReadableCopyright</key> <string>Generated by Decanter for \(game.name).</string>
        </dict>
        </plist>
        """
    }
}
