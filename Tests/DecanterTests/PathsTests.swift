import XCTest
@testable import Decanter

/// Covers the `DECANTER_HOME` override added for the pre-release debug plan's Phase 1 (Tier A):
/// a fresh-Mac harness. Every first-run and gameplay bug that cost this project real time shared
/// one property — it couldn't fire on a machine already in the state the buggy code was trying to
/// reach — and there was no seam to be a clean machine without risking the real 25 GB install.
///
/// Mutates and restores the real process environment (`setenv`/`unsetenv`), so these tests run
/// serially against shared global state, same constraint as any `ProcessInfo.environment` read —
/// there's no dependency-injection seam here, deliberately: it's a ten-line override, not a new
/// abstraction (YAGNI).
final class PathsTests: XCTestCase {

    override func tearDown() {
        unsetenv("DECANTER_HOME")
        super.tearDown()
    }

    func testAppSupportUsesTheOverrideWhenSet() {
        setenv("DECANTER_HOME", "/tmp/decanter-paths-test-override", 1)
        XCTAssertEqual(Paths.appSupport.path, "/tmp/decanter-paths-test-override")
    }

    /// The override IS the app-support root directly — no "Decanter" subfolder appended — so a
    /// scratch directory a caller names is exactly what gets populated and exactly what a plain
    /// `rm -rf` clears between runs.
    func testOverrideIsUsedAsIsNotAsAParent() {
        setenv("DECANTER_HOME", "/tmp/decanter-paths-test-override", 1)
        XCTAssertFalse(Paths.appSupport.path.hasSuffix("/Decanter"))
    }

    func testDownstreamPathsDeriveFromTheOverride() {
        setenv("DECANTER_HOME", "/tmp/decanter-paths-test-override", 1)
        XCTAssertEqual(Paths.bottlesRoot.path, "/tmp/decanter-paths-test-override/Bottles")
        XCTAssertEqual(Paths.bottlesIndex.path, "/tmp/decanter-paths-test-override/bottles.json")
        XCTAssertEqual(Paths.wineEngineRoot.path, "/tmp/decanter-paths-test-override/Wine")
    }

    func testEmptyOverrideFallsBackToTheRealLocation() {
        setenv("DECANTER_HOME", "", 1)
        XCTAssertTrue(Paths.appSupport.path.hasSuffix("/Application Support/Decanter"))
    }

    func testUnsetFallsBackToTheRealLocation() {
        unsetenv("DECANTER_HOME")
        XCTAssertTrue(Paths.appSupport.path.hasSuffix("/Application Support/Decanter"))
    }
}
