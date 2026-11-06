import AppKit

/// Decanter updates itself: one click downloads the newest release from GitHub, checks it really
/// is a newer Decanter, swaps it in and reopens. No zip to unpack, no script, no second "Open
/// Anyway" — the in-app version of the zip's `UPDATE Decanter.command`, and the same steps.
/// Bottles, games and saves live in Application Support and are never touched.
@MainActor
enum Updater {

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest release when it's newer than this app; nil when up to date. Throws when the
    /// release can't be fetched or read, so a failed check never looks like "up to date".
    static func check() async throws -> UpdateCheck.Release? {
        let (data, response) = try await URLSession.shared.data(from: UpdateCheck.latestReleaseAPI)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError(message: "GitHub answered with error \(http.statusCode).")
        }
        guard let release = UpdateCheck.parse(data) else {
            throw UpdateError(message: "The release information couldn't be read.")
        }
        return UpdateCheck.isNewer(release.version, than: currentVersion) ? release : nil
    }

    /// Download and verify `release`, then hand the swap to a helper script and quit. The swap
    /// can't happen in-process: a running app can't replace its own bundle cleanly.
    static func install(_ release: UpdateCheck.Release, console: TaskConsole,
                        quit: () -> Void = { NSApp.terminate(nil) }) async throws {
        let fm = FileManager.default
        let installed = Bundle.main.bundleURL
        guard fm.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            throw UpdateError(message: "Decanter can't replace itself in "
                + "\(installed.deletingLastPathComponent().path). Download the new version from "
                + "GitHub and drag it into Applications instead.")
        }

        console.append("Downloading Decanter \(release.version)…")
        let (zip, _) = try await URLSession.shared.download(from: release.zipURL)
        let work = fm.temporaryDirectory.appendingPathComponent("decanter-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                        arguments: ["-x", "-k", zip.path, work.path], timeout: 120)
        guard unzip.exitCode == 0, let fresh = findApp(in: work) else {
            throw UpdateError(message: "The download didn't contain Decanter.")
        }

        // Only ever swap in a real, newer Decanter — never whatever happens to be in the zip.
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))
        let freshVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              UpdateCheck.isNewer(freshVersion, than: currentVersion),
              fm.isExecutableFile(atPath: fresh.appendingPathComponent("Contents/MacOS/Decanter").path)
        else { throw UpdateError(message: "The download isn't a newer Decanter, so nothing was changed.") }

        // The same two steps the zip's UPDATE script does, so the new copy opens without another
        // "Open Anyway": clear the download flag, then re-sign.
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-cr", fresh.path])
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                 arguments: ["--force", "--deep", "--sign", "-", fresh.path], timeout: 120)

        let script = work.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        // A scratch DECANTER_HOME is passed on, so a test copy reopens on its own scratch data
        // rather than on the real install.
        swap.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                          installed.path, fresh.path,
                          ProcessInfo.processInfo.environment["DECANTER_HOME"] ?? ""]
        try swap.run()
        console.append("Installing — Decanter will reopen in a moment.")
        quit()
    }

    private static func findApp(in folder: URL) -> URL? {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = items?.nextObject() as? URL {
            if url.lastPathComponent == "Decanter.app" { return url }
        }
        return nil
    }

    /// Waits for Decanter to quit, then swaps the new bundle in. Copies first and keeps the old one
    /// until the new one is in place, so a failure anywhere leaves a working Decanter. Gives up and
    /// changes nothing if Decanter is still running after two minutes (e.g. the user chose Keep
    /// Waiting in the quit guard).
    private static let swapScript = #"""
        #!/bin/bash
        pid="$1"; old="$2"; new="$3"; home="$4"
        for _ in $(seq 1 240); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$pid" 2>/dev/null && exit 1
        stage="${old%.app}.updating.app"; backup="${old%.app}.previous.app"
        rm -rf "$stage" "$backup"
        cp -R "$new" "$stage" || exit 1
        mv "$old" "$backup" || { rm -rf "$stage"; exit 1; }
        if mv "$stage" "$old"; then rm -rf "$backup"; else mv "$backup" "$old"; fi
        xattr -cr "$old" 2>/dev/null
        if [ -n "$home" ]; then open -n --env DECANTER_HOME="$home" "$old"; else open "$old"; fi
        """#
}
