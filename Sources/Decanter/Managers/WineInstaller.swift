import Foundation

/// Downloads and installs the Wine engine Decanter needs, with no user knowledge required.
///
/// We install an **upstream wine 11.0** bundle (frankea/Whisky) because it runs Steam + DXMT
/// standalone with zero glue. Its one downside: **no msync**, so thread-heavy games spike
/// (GAMING-STACK.md §2/§3). It is NOT "the only free build that can log into Steam" — that older
/// claim was wrong. A free CrossOver-sourced build (WS12WineCX24, wine 9) HAS msync but is not
/// standalone-ready (needs a Sikarugir/Kegworks wrapper for Steam networking, §2b). Read §2
/// before changing the URL.
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

    /// Set when the engine installed but the msync overlay did NOT.
    ///
    /// The overlay is deliberately non-fatal — a working wine 11 engine beats no engine — but it
    /// used to be `try?` followed straight by `.done`, so a failed second download reported
    /// SUCCESS and the user silently got the frame-spike engine that this overlay exists to avoid.
    /// Only `--verify` could tell. Non-fatal must still mean *reported*.
    @Published var warning: String?

    /// Base bundle: Wine 11 + DXVK + DXMT + the ~94 support dylibs (gnutls/freetype/MoltenVK/…),
    /// ~317 MB. We keep using this for everything EXCEPT the wine binaries themselves, because it
    /// is the only bundle that ships a complete, self-contained macOS support environment.
    static let releaseURL = URL(string:
        "https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz")!
    static let approximateBytes: Int64 = 317_000_000

    /// Overlay: **upstream wine 10.0 with msync** (free, from the Sikarugir/Kegworks engine
    /// mirror; 0 CrossOver markers). Verified 2026-07-18 on an M5 Air: msync activates, Steam
    /// logs in, DXMT renders, and `wineserver` under Sekiro drops from **39.9% → ~7.9% avg**.
    ///
    /// Why an overlay instead of just switching the URL: this tarball is *only* the wine tree —
    /// no support dylibs, no DXMT/DXVK, and its `winemetal` is a 36 KB stub with no unix-side
    /// `winemetal.so`, so DXMT cannot load on it alone. `installMsyncEngine()` grafts the base
    /// bundle's `winemetal.so` + DXMT's real `winemetal.dll` back on top.
    ///
    /// NOTE: that graft runs a wine-11 unixlib inside a wine-10 engine. It works, but it is an
    /// unsupported ABI mix — if graphics misbehave, this is the first thing to suspect.
    static let msyncEngineURL = URL(string:
        "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS11Wine10.0_3.tar.xz")!

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

    /// Process-wide guard. Must be `static`: `AppModel.installEngine()` constructs a NEW
    /// `WineInstaller` per call, so an instance-level check (`phase.isBusy`) would always be
    /// false and guard nothing.
    private static var isInstalling = false

    func install() async {
        // `install()` deletes and re-extracts the engine directory, so two overlapping runs race
        // on the same paths and can leave a half-written, unusable engine. Reachable in practice:
        // the wizard button, the menu item and `--install-engine` all reach here, and a ~480 MB
        // download leaves a wide window. (Hit while testing — two installs extracted over each
        // other.) NOTE: this guards one process only; two app launches installing at once would
        // still collide, which would need an on-disk lock.
        guard !Self.isInstalling else { return }
        Self.isInstalling = true
        defer { Self.isInstalling = false }
        do {
            Paths.ensureDirectories()
            let tarball = try await download()
            phase = .extracting
            try await extract(tarball)
            try? FileManager.default.removeItem(at: tarball)   // reclaim ~317 MB
            // Swap the wine tree for upstream-wine-10-with-msync (keeps DXMT/DXVK + support libs).
            // Non-fatal: if this fails we still have a working wine 11 engine, just with the
            // frame spikes. A broken-but-present engine would be worse than a slower one — but the
            // user has to be TOLD, or "setup complete" is a lie about which engine they now have.
            do {
                try await installMsyncEngine()
                // F17 (bug-sweep): don't just trust that nothing threw. Assert the actual result
                // with the same probe bottles are checked with (`probeFastSync` scans the freshly
                // installed ntdll for WINEMSYNC/WINEESYNC) — the graft is now a checked fact, not
                // an inference from "installMsyncEngine didn't throw."
                if WineInstallation.probeFastSync(binDirectory: Self.binDirectory) {
                    warning = nil
                } else {
                    warning = "The engine installed, but fast-sync (msync) isn't present in the "
                        + "result. Games will run, but demanding ones may stutter. Re-run Setup "
                        + "Assistant to retry."
                }
            } catch {
                warning = "The engine installed, but the fast-sync (msync) update didn't: "
                    + error.localizedDescription
                    + " Games will run, but demanding ones may stutter. Re-run Setup Assistant to retry."
            }
            phase = .verifying
            let version = try await verify()
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

        // Explicit longer timeout: this is unpacking ~480 MB, which can genuinely exceed the
        // 30s default on a slow disk. See Shell.run's F16 doc comment.
        let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                         arguments: ["-xzf", tarball.path, "-C", Self.installRoot.path],
                                         timeout: 180)
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

    /// Overlay upstream-wine-10-with-msync onto the extracted base bundle.
    ///
    /// Layout differs between the two: the overlay is `wswine.bundle/{bin,lib,share}` while our
    /// engine lives at `Libraries/Wine/{bin,lib,share}`. Only `bin`, `lib/wine` and `share` are
    /// taken from the overlay — `lib/*.dylib` (gnutls, freetype, MoltenVK, …) must survive, since
    /// the overlay ships none of them and wine would not run without them.
    ///
    /// Two files are then grafted back so DXMT still works: the base bundle's unix-side
    /// `winemetal.so` (the overlay has no equivalent) and DXMT's real `winemetal.dll` (the overlay
    /// ships a 36 KB stub). See `msyncEngineURL` for the ABI caveat.
    private func installMsyncEngine() async throws {
        let fm = FileManager.default
        let wineRoot = Self.librariesRoot.appendingPathComponent("Wine", isDirectory: true)
        let unixDir = wineRoot.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let winemetalSO = unixDir.appendingPathComponent("winemetal.so")
        let dxmtDLL = Self.librariesRoot.appendingPathComponent("DXMT/x64/winemetal.dll")

        // F17 (bug-sweep): this used to be a bare `return`, not a `throw`. The caller's `catch`
        // block is what turns a failure into the user-visible "fast-sync didn't install" warning
        // (review-finding-5's fix); a bare return skipped that entirely, so `warning = nil` ran
        // regardless and setup reported success while the user silently got the frame-spike
        // engine the overlay exists to replace. Same "non-fatal must still mean reported" rule,
        // just bypassed by a different exit path than the one already covered.
        guard fm.fileExists(atPath: winemetalSO.path) else {
            throw InstallError.step("The base engine bundle is missing winemetal.so, so fast-sync "
                + "could not be installed.")
        }

        phase = .downloading(0)
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in self?.phase = .downloading(fraction) }
        }
        let (tempURL, response) = try await URLSession.shared.download(from: Self.msyncEngineURL,
                                                                       delegate: progress)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.step("msync engine download failed (HTTP \(http.statusCode)).")
        }
        phase = .extracting
        let work = Paths.downloads.appendingPathComponent("msync-engine", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: tempURL) }

        let untar = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                        arguments: ["-xJf", tempURL.path, "-C", work.path],
                                        timeout: 180)
        guard untar.succeeded else { throw InstallError.step("Could not unpack the msync engine.") }

        let bundle = work.appendingPathComponent("wswine.bundle", isDirectory: true)
        guard fm.isExecutableFile(atPath: bundle.appendingPathComponent("bin/wine").path) else {
            throw InstallError.step("msync engine layout unexpected.")
        }

        // Stash the DXMT unix backend, swap the wine tree, then graft it back.
        let stash = work.appendingPathComponent("winemetal.so")
        try? fm.removeItem(at: stash)
        try fm.copyItem(at: winemetalSO, to: stash)

        // AND stash share/wine/wine.inf, for the same reason.
        //
        // The loop below deletes `share` wholesale before copying the overlay's version, and the
        // msync overlay does not ship a wine.inf. Without it `wineboot --init` cannot populate a
        // prefix at all:
        //     wine: failed to update ... with ...share\wine\wine.inf: No such file or directory
        //     wine: could not load kernel32.dll, status c0000135
        // Existing prefixes keep working, which is why this went unnoticed: it only breaks the
        // creation of NEW bottles, and the wizard was last verified end-to-end the day before this
        // overlay was introduced. Found 2026-07-30 while building the online-play feature.
        let infStash = work.appendingPathComponent("wine.inf")
        let baseInf = wineRoot.appendingPathComponent("share/wine/wine.inf")
        if fm.fileExists(atPath: baseInf.path) {
            try? fm.removeItem(at: infStash)
            try? fm.copyItem(at: baseInf, to: infStash)
        }

        for part in ["bin", "share", "lib/wine"] {
            let dst = wineRoot.appendingPathComponent(part)
            let src = bundle.appendingPathComponent(part)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }
        // Put wine.inf back if the overlay did not supply one. Without this, every new bottle fails
        // to initialise — see the stash comment above.
        let newInf = wineRoot.appendingPathComponent("share/wine/wine.inf")
        if !fm.fileExists(atPath: newInf.path), fm.fileExists(atPath: infStash.path) {
            try? fm.createDirectory(at: newInf.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.copyItem(at: infStash, to: newInf)
        }

        try? fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: winemetalSO)
        try fm.copyItem(at: stash, to: winemetalSO)
        if fm.fileExists(atPath: dxmtDLL.path) {
            let pe = wineRoot.appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll")
            try? fm.removeItem(at: pe)
            try? fm.copyItem(at: dxmtDLL, to: pe)
        }

        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                 arguments: ["-dr", "com.apple.quarantine", Self.installRoot.path])
        if let bins = try? fm.contentsOfDirectory(atPath: Self.binDirectory.path) {
            for b in bins {
                try? fm.setAttributes([.posixPermissions: 0o755],
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
