import XCTest
@testable import Decanter

/// Covers `Uninstaller` entirely against a scratch `DECANTER_HOME` (Phase 1) — never touches real
/// data, so a mistake here costs nothing, which is exactly why there is no headless CLI flag that
/// actually executes an uninstall (see the dispatch comment at `--uninstall-plan`).
final class UninstallerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("UninstallerTests-\(UUID().uuidString)", isDirectory: true)
        setenv("DECANTER_HOME", scratch.path, 1)
    }

    override func tearDown() {
        unsetenv("DECANTER_HOME")
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        super.tearDown()
    }

    func testPlanIsEmptyWhenNothingExists() {
        XCTAssertTrue(Uninstaller.plan().isEmpty)
    }

    func testPlanListsOnlyWhatExistsWithARealSize() throws {
        try FileManager.default.createDirectory(at: Paths.bottlesRoot, withIntermediateDirectories: true)
        try "save data".write(to: Paths.bottlesRoot.appendingPathComponent("save.dat"),
                              atomically: true, encoding: .utf8)

        let plan = Uninstaller.plan()
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.label, "Bottles (installed games, saves, settings)")
        XCTAssertGreaterThan(plan.first?.bytes ?? 0, 0)
    }

    /// "Real game window" installs Decanter Game.app into Decanter's data folder (it can't run from
    /// inside the bundle — Game Mode ignores it there). An uninstall that left it behind would not
    /// be a true uninstall.
    func testInstalledGameHostIsRemovedByUninstall() throws {
        let exe = Paths.installedGameHost.appendingPathComponent("Contents/MacOS/decanter-game-host")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "host".write(to: exe, atomically: true, encoding: .utf8)

        XCTAssertTrue(Uninstaller.plan().contains { $0.url == Paths.installedGameHost })
        XCTAssertTrue(Uninstaller.execute().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.installedGameHost.path))
    }

    /// The one deliberate difference from `OrphanReclaim`, which never scans `Backups/` at all
    /// (F21: it holds `RESTORE-*.sh`'s rollback material, live for as long as the app is in use).
    /// An uninstall is the one context where removing it too is exactly the point.
    func testBackupsAreIncludedUnlikeOrphanReclaim() throws {
        let backups = Paths.appSupport.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try "old bottles.json".write(to: backups.appendingPathComponent("bottles-2026.json.bak"),
                                     atomically: true, encoding: .utf8)

        XCTAssertTrue(Uninstaller.plan().contains { $0.label == "Backups" })
    }

    func testExecuteRemovesEverythingInThePlan() throws {
        try FileManager.default.createDirectory(at: Paths.bottlesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.shaderCacheRoot, withIntermediateDirectories: true)
        try "[]".write(to: Paths.bottlesIndex, atomically: true, encoding: .utf8)
        // Real content, not empty directories — `plan()` deliberately skips an empty skeleton
        // dir (see its doc comment), so an empty `bottlesRoot`/`shaderCacheRoot` here wouldn't be
        // in the plan at all and this test would be asserting execute() removed something it was
        // never going to touch.
        try "save data".write(to: Paths.bottlesRoot.appendingPathComponent("save.dat"),
                              atomically: true, encoding: .utf8)
        try "shader".write(to: Paths.shaderCacheRoot.appendingPathComponent("cache.bin"),
                           atomically: true, encoding: .utf8)

        let failed = Uninstaller.execute()

        XCTAssertTrue(failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.bottlesRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.shaderCacheRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.bottlesIndex.path))
    }

    func testExecuteOnAnEmptyScratchHomeIsANoOpNotAFailure() {
        XCTAssertTrue(Uninstaller.execute().isEmpty)
    }

    func testTotalBytesMatchesTheSumOfThePlan() throws {
        try FileManager.default.createDirectory(at: Paths.bottlesRoot, withIntermediateDirectories: true)
        try "abcdefghij".write(to: Paths.bottlesRoot.appendingPathComponent("f.dat"),
                               atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: Paths.shaderCacheRoot, withIntermediateDirectories: true)
        try "0123456789".write(to: Paths.shaderCacheRoot.appendingPathComponent("f.dat"),
                               atomically: true, encoding: .utf8)

        let plan = Uninstaller.plan()
        XCTAssertEqual(Uninstaller.totalBytes(), plan.reduce(0) { $0 + $1.bytes })
        XCTAssertGreaterThanOrEqual(Uninstaller.totalBytes(), 20)
    }
}
