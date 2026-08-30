import XCTest
@testable import Decanter

/// `probeFastSync` became load-bearing a third time when `hasUsableEngine` started using it to
/// decide whether Decanter's own engine is genuinely the tuned msync build, not just present (see
/// the fix in `AppModel.hasUsableEngine`, found during the pre-release debug plan's Phase 2: an
/// install interrupted between the base-bundle extraction and the msync overlay left a real,
/// working, but untuned engine that every later setup re-run silently accepted as done, forever).
/// No unit test existed for the probe itself before this — these pin its two documented properties
/// directly, without touching Wine or the network: it finds the right file at the right relative
/// path, and it matches the marker strings the msync/esync FEATURE actually reads, not the bare
/// `msync` substring every ntdll's symbol table happens to contain (the false-positive trap
/// recorded in CLAUDE.md's gotchas).
final class WineInstallationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WineInstallationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    /// Lays out `<root>/bin` (returned, matching `WineInstallation.binDirectory`'s shape) and
    /// `<root>/lib/wine/x86_64-unix/ntdll.so` containing `contents`, mirroring the real engine
    /// tree's layout that `probeFastSync` navigates via `deletingLastPathComponent()`.
    private func makeFakeEngine(ntdll contents: String?) throws -> URL {
        let bin = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        guard let contents else { return bin }   // no ntdll.so at all
        let unixDir = tempRoot.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try contents.write(to: unixDir.appendingPathComponent("ntdll.so"), atomically: true, encoding: .utf8)
        return bin
    }

    func testTrueWhenNtdllContainsWinemsync() throws {
        let bin = try makeFakeEngine(ntdll: "junk...WINEMSYNC...more junk")
        XCTAssertTrue(WineInstallation.probeFastSync(binDirectory: bin))
    }

    func testTrueWhenNtdllContainsWineesync() throws {
        let bin = try makeFakeEngine(ntdll: "junk...WINEESYNC...more junk")
        XCTAssertTrue(WineInstallation.probeFastSync(binDirectory: bin))
    }

    /// The exact false-positive this probe exists to avoid: every ntdll carries the POSIX
    /// `_msync()` syscall symbol in its symbol table, so matching the bare substring would say
    /// "fast sync" for a plain wine-11 engine that has no msync feature at all.
    func testFalseForTheBareMsyncSubstringWithoutTheEnvVarNames() throws {
        let bin = try makeFakeEngine(ntdll: "junk..._msync...more junk")
        XCTAssertFalse(WineInstallation.probeFastSync(binDirectory: bin))
    }

    func testFalseWhenNtdllHasNeitherMarker() throws {
        let bin = try makeFakeEngine(ntdll: "an entirely unrelated stock ntdll, no fast sync at all")
        XCTAssertFalse(WineInstallation.probeFastSync(binDirectory: bin))
    }

    /// The exact shape of an interrupted Decanter engine install: the base bundle's `bin/`
    /// extracted fine (a real, executable wine), but the msync overlay never grafted its ntdll.so
    /// on top, so the file the probe looks for is simply missing — not corrupt, absent.
    func testFalseWhenNtdllIsMissingEntirely() throws {
        let bin = try makeFakeEngine(ntdll: nil)
        XCTAssertFalse(WineInstallation.probeFastSync(binDirectory: bin))
    }
}
