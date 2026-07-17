import Foundation

/// Downloads and installs the Wine engine Decanter needs, with no user knowledge required.
///
/// We install **WhiskyWine 11.0** specifically. That choice is not arbitrary — it is the only
/// free build that can complete a modern Steam login *and* ship DXMT (DirectX → Metal).
/// See docs/GAMING-STACK.md §2 before changing the URL.
@MainActor
final class WineInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(Double)      // 0...1
        case extracting
        case verifying
        case done(version: String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .extracting, .verifying: return true
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle

    /// WhiskyWine 11.0 — Wine 11 + DXVK + DXMT, ~317 MB.
    static let releaseURL = URL(string:
        "https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz")!
    static let approximateBytes: Int64 = 317_000_000

    /// Decanter-owned install location (see Paths.wineEngine*), so we never depend on
    /// Whisky/Mythic/CrossOver being installed. Non-isolated: Wine.discover reads these.
    nonisolated static var installRoot: URL { Paths.wineEngineRoot }
    nonisolated static var librariesRoot: URL { Paths.wineEngineLibraries }
    nonisolated static var binDirectory: URL { Paths.wineEngineBin }

    /// True once a usable engine is on disk.
    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.wineEngineBin.appendingPathComponent("wine").path)
    }

    // MARK: Install

    func install() async {
        do {
            Paths.ensureDirectories()
            let tarball = try await download()
            phase = .extracting
            try await extract(tarball)
            phase = .verifying
            let version = try await verify()
            try? FileManager.default.removeItem(at: tarball)   // reclaim ~317 MB
            phase = .done(version: version)
        } catch {
            // Remove a half-extracted engine so a retry re-downloads cleanly instead of finding a
            // present-but-broken build (which discovery would treat as valid and never retry).
            try? FileManager.default.removeItem(at: Self.librariesRoot)
            phase = .failed(error.localizedDescription)
        }
    }

    private func download() async throws -> URL {
        phase = .downloading(0)
        let destination = Paths.downloads.appendingPathComponent("WhiskyWine.tar.gz")
        try? FileManager.default.removeItem(at: destination)

        // NOTE: do NOT use `for try await byte in URLSession.bytes(...)`. Iterating an async
        // sequence one byte at a time costs ~25x throughput here (measured: 0.12 MB/s vs 3 MB/s
        // for the same file) — a 317 MB download would take ~45 minutes. A download task streams
        // to disk natively and reports progress via its delegate.
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in self?.phase = .downloading(fraction) }
        }
        let (tempURL, response) = try await URLSession.shared.download(from: Self.releaseURL,
                                                                       delegate: progress)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.step("Download failed (HTTP \(http.statusCode)).")
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func extract(_ tarball: URL) async throws {
        try? FileManager.default.removeItem(at: Self.librariesRoot)
        try FileManager.default.createDirectory(at: Self.installRoot, withIntermediateDirectories: true)

        let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                         arguments: ["-xzf", tarball.path, "-C", Self.installRoot.path])
        guard result.succeeded else {
            throw InstallError.step("Could not unpack the engine.\n\(result.stderr)")
        }

        // Downloaded => quarantined. Wine's dylibs get killed by Gatekeeper unless cleared.
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                 arguments: ["-dr", "com.apple.quarantine", Self.installRoot.path])
        // Tarball perms can arrive without +x on the loaders.
        if let bins = try? FileManager.default.contentsOfDirectory(atPath: Self.binDirectory.path) {
            for b in bins {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: Self.binDirectory.appendingPathComponent(b).path)
            }
        }
    }

    private func verify() async throws -> String {
        let wine = Self.binDirectory.appendingPathComponent("wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw InstallError.step("The engine unpacked but no runnable `wine` was found.")
        }
        guard let result = try? await Shell.run(wine, arguments: ["--version"]), result.succeeded else {
            let hint = SystemChecks.isRosettaInstalled
                ? "" : " Rosetta 2 doesn't appear to be installed yet — it's needed to run the engine."
            throw InstallError.step("The engine unpacked but wouldn't run.\(hint)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum InstallError: LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let m) = self { return m }; return nil }
    }
}

/// Progress reporter for a `URLSession.download`. Lives outside the actor so the delegate
/// callbacks (which arrive on a session queue) stay cheap.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.999))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The async `download(from:delegate:)` hands us the file; nothing to do here.
    }
}
