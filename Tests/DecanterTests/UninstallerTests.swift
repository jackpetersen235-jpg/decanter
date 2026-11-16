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

    /// Decanter's own files in ~/Library (settings, caches, the update check's network cache,
    /// window state) used to survive an uninstall. Created here under the scratch home's Library.
    private func makeLibraryLeftovers() throws -> [URL] {
        let lib = Paths.userLibrary, id = Paths.bundleIdentifier
        let files = [lib.appendingPathComponent("Preferences/\(id).plist"),
                     lib.appendingPathComponent("Caches/\(id)/Cache.db"),
                     lib.appendingPathComponent("HTTPStorages/\(id)/httpstorages.sqlite"),
                     lib.appendingPathComponent("Saved Application State/\(id).savedState/windows.plist")]
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "leftover".write(to: file, atomically: true, encoding: .utf8)
        }
        return files
    }

    func testLibraryLeftoversAreListedAndRemoved() throws {
        // Arrange
        let files = try makeLibraryLeftovers()

        // Act
        let labels = Uninstaller.plan().map(\.label)
        let failed = Uninstaller.execute()

        // Assert
        XCTAssertEqual(Set(labels), ["Settings (theme and preferences)", "Caches", "Network cache",
                                     "Window state"])
        XCTAssertTrue(failed.isEmpty)
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testTheAfterQuitScriptWaitsThenRemovesEverythingAndTheEmptyDataFolder() throws {
        // Arrange: leftovers with an apostrophe in the path (quoting), an empty data folder, and a
        // process that has already exited standing in for Decanter.
        let library = scratch.appendingPathComponent("Jack's Library", isDirectory: true)
        let leftovers = [library.appendingPathComponent("Caches/x/Cache.db"),
                         library.appendingPathComponent("Preferences/x.plist")]
        for file in leftovers {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "leftover".write(to: file, atomically: true, encoding: .utf8)
        }
        let dataFolder = scratch.appendingPathComponent("Decanter", isDirectory: true)
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        // Act
        let script = Uninstaller.afterQuitScript(
            waitingFor: exited.processIdentifier, domain: "com.decanter.uninstall-test",
            paths: [library.appendingPathComponent("Caches/x").path, leftovers[1].path],
            appSupport: dataFolder.path)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        try shell.run()
        shell.waitUntilExit()

        // Assert
        XCTAssertEqual(shell.terminationStatus, 0)
        for file in leftovers { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path))
    }

    func testAScratchHomeKeepsEveryPlannedPathInsideIt() throws {
        // Arrange: the real ~/Library must be out of reach whenever DECANTER_HOME is set, or these
        // tests would delete the developer's own Decanter settings.
        _ = try makeLibraryLeftovers()
        try FileManager.default.createDirectory(at: Paths.bottlesRoot, withIntermediateDirectories: true)
        try "save data".write(to: Paths.bottlesRoot.appendingPathComponent("save.dat"),
                              atomically: true, encoding: .utf8)

        // Act
        let paths = Uninstaller.plan().map { $0.url.standardizedFileURL.path }

        // Assert
        XCTAssertTrue(Paths.userLibrary.path.hasPrefix(scratch.path))
        XCTAssertFalse(paths.isEmpty)
        for path in paths { XCTAssertTrue(path.hasPrefix(scratch.standardizedFileURL.path), path) }
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

    /// The window hook is copied out next to the host for the same reason, and goes with it.
    func testInstalledWindowHookIsRemovedByUninstall() throws {
        let hook = Paths.installedWindowHook
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "hook".write(to: hook, atomically: true, encoding: .utf8)

        XCTAssertTrue(Uninstaller.plan().contains { $0.url == hook.deletingLastPathComponent() })
        XCTAssertTrue(Uninstaller.execute().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
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
