import Foundation
import AppKit

/// Builds a shareable diagnostics bundle and reveals it on the Desktop.
///
/// Phase 4 of the pre-release debug plan: after release, every bug happens on a machine nobody
/// here will ever touch, reported by someone who cannot describe it. `--diagnose` and `--verify`
/// already ask the right questions, but both are unreachable without a terminal. This is what
/// makes them reachable: one menu item, one zip, ready to attach to an email or a message.
///
/// Bundles, all sanitized of the real home-directory path:
///   - `verify.txt`      — the same health check `--verify` prints (engine, msync, every bottle)
///   - `system.txt`       — chip, macOS version, Rosetta, free disk space
///   - `bottles.json`     — the bottle index, so a shape mismatch is visible without asking
///   - `console.log`      — the tail of every console this session has shown (`ConsoleLog`)
///   - `CrashReports/`    — any Decanter/wine crash report from the last 14 days
enum DiagnosticsExporter {
    enum ExportError: LocalizedError {
        case zipFailed(String)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let detail): return "Couldn't create the diagnostics archive: \(detail)"
            }
        }
    }

    /// Builds the bundle, writes the zip to the Desktop, and reveals it in Finder. Returns the
    /// zip's location so a caller can also report it in a console or a toast.
    @MainActor
    @discardableResult
    static func exportAndReveal(model: AppModel) async throws -> URL {
        let zipURL = try await export(model: model)
        NSWorkspace.shared.activateFileViewerSelecting([zipURL])
        return zipURL
    }

    static func export(model: AppModel) async throws -> URL {
        let fm = FileManager.default
        let stamp = stampFormatter.string(from: Date())
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Decanter-Diagnostics-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }   // the zip is the deliverable, not this folder

        let (verifyText, _) = await model.verifyReport()
        try write(sanitize(verifyText), to: staging.appendingPathComponent("verify.txt"))
        try write(sanitize(await systemInfoText()), to: staging.appendingPathComponent("system.txt"))

        if let data = try? Data(contentsOf: Paths.bottlesIndex),
           let text = String(data: data, encoding: .utf8) {
            try write(sanitize(text), to: staging.appendingPathComponent("bottles.json"))
        }

        if let logText = try? String(contentsOf: Paths.consoleLog, encoding: .utf8) {
            // The tail is what anyone actually reads — same reasoning as TaskConsole's own
            // in-memory cap. 100 KB is generous for a support session without shipping a whole
            // session's history unasked.
            try write(sanitize(String(logText.suffix(100_000))),
                     to: staging.appendingPathComponent("console.log"))
        }

        try attachRecentCrashReports(to: staging, fm: fm)

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zipURL = desktop.appendingPathComponent("Decanter-Diagnostics-\(stamp).zip")
        try await zip(staging, to: zipURL)
        return zipURL
    }

    // MARK: System info

    private static func systemInfoText() async -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let chip = (try? await Shell.run(URL(fileURLWithPath: "/usr/sbin/sysctl"),
                                         arguments: ["-n", "machdep.cpu.brand_string"]))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let arch: String
        #if arch(arm64)
        arch = "arm64 (Apple Silicon)"
        #else
        arch = "x86_64"
        #endif

        var free = "unknown"
        if let values = try? Paths.appSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            free = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        return """
            macOS: \(os)
            Chip:  \(chip) (\(arch))
            Rosetta 2 installed: \(SystemChecks.isRosettaInstalled)
            Free disk space (Application Support volume): \(free)
            """
    }

    // MARK: Crash reports

    /// Only Decanter- or wine-named `.ips` reports from the last 14 days — anything older is
    /// unlikely to be about whatever the user is currently reporting, and this is meant to be a
    /// quick attachment, not a full log trawl.
    private static func attachRecentCrashReports(to staging: URL, fm: FileManager) throws {
        let reportsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: reportsDir,
                                                         includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }   // no crash reports at all is a fine, common outcome — not an error

        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let relevant = entries.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".ips"), name.contains("decanter") || name.contains("wine") else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return modified > cutoff
        }
        guard !relevant.isEmpty else { return }

        let dest = staging.appendingPathComponent("CrashReports", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for url in relevant {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? write(sanitize(text), to: dest.appendingPathComponent(url.lastPathComponent))
        }
    }

    // MARK: Sanitizing

    /// Replaces the real home directory with `~` throughout — the one thing every file in this
    /// bundle is guaranteed to contain, and the one thing a diagnostics export should not leak
    /// (a full path reveals the macOS account name).
    ///
    /// `bottles.json` is written by `JSONEncoder`, which escapes every `/` as `\/` — so the home
    /// path appears in it as `\/Users\/name`, not `/Users/name`, and a plain replace silently
    /// missed it (checked: `grep -c '/Users/…'` on a "sanitized" export came back 0, and so did
    /// `~`, not because there was nothing to redact but because the match never fired). Both
    /// spellings are replaced now, escaped form first, so a plain-text file with real slashes
    /// isn't corrupted by chasing the JSON one.
    static func sanitize(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let jsonEscapedHome = home.replacingOccurrences(of: "/", with: "\\/")
        return text
            .replacingOccurrences(of: jsonEscapedHome, with: "~")
            .replacingOccurrences(of: home, with: "~")
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Zipping

    /// Shells out to `ditto`, the same tool Finder's own "Compress" uses — no third-party
    /// dependency for something this ordinary. `-c -k` makes a zip; `--keepParent` means the
    /// archive opens to one named folder instead of scattering files loose. `--norsrc` skips
    /// AppleDouble (`._*`) resource-fork shadow files — without it, every plain-text file in
    /// here (staged fresh, no real resource forks) still gets one, roughly doubling the entry
    /// count in a bundle that's supposed to be quick to skim.
    private static func zip(_ source: URL, to destination: URL) async throws {
        let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                         arguments: ["-c", "-k", "--norsrc", "--keepParent",
                                                    source.path, destination.path],
                                         timeout: 30)
        guard result.succeeded else { throw ExportError.zipFailed(result.stderr) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
