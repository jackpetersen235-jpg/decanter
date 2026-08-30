import XCTest
@testable import Decanter

/// Pins F5's "what's safe to reclaim" logic. The one case worth over-testing: a directory
/// unreferenced by any bottle can still be genuinely live via an external launcher — that's the
/// exact trap `ShaderCache/Sekiro` and `/ASBR` represent on the real machine this was built for.
final class OrphanReclaimTests: XCTestCase {

    // MARK: orphanedBottleDirs

    func testBottleDirWithNoMatchingBottleIsOrphaned() {
        let result = OrphanReclaim.orphanedBottleDirs(present: ["Bottle-F99703", "Steam-Wine11"],
                                                       referencedByBottles: ["Steam-Wine11"])
        XCTAssertEqual(result.map(\.name), ["Bottle-F99703"])
    }

    func testBottleDirReferencedByABottleIsNotOrphaned() {
        let result = OrphanReclaim.orphanedBottleDirs(present: ["Steam-Wine11"],
                                                       referencedByBottles: ["Steam-Wine11"])
        XCTAssertTrue(result.isEmpty)
    }

    func testNoBottleDirsMeansNoOrphans() {
        let result = OrphanReclaim.orphanedBottleDirs(present: [], referencedByBottles: ["Steam-Wine11"])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: orphanedShaderCacheDirs — the launcher-visibility trap specifically

    func testShaderCacheDirReferencedOnlyByExternalLauncherIsNotOrphaned() {
        // This is ShaderCache/Sekiro and /ASBR on the real machine: no bottle names it, but a
        // hand-made launcher's DXMT_SHADER_CACHE_PATH does. Must NOT be reported reclaimable.
        let result = OrphanReclaim.orphanedShaderCacheDirs(present: ["Sekiro"],
                                                            referencedByBottles: [],
                                                            referencedByLaunchers: ["Sekiro"])
        XCTAssertTrue(result.isEmpty)
    }

    func testShaderCacheDirWithNeitherReferenceIsOrphaned() {
        let result = OrphanReclaim.orphanedShaderCacheDirs(present: ["StressTest"],
                                                            referencedByBottles: [],
                                                            referencedByLaunchers: [])
        XCTAssertEqual(result.map(\.name), ["StressTest"])
    }

    func testShaderCacheDirReferencedByABottleIsNotOrphaned() {
        let result = OrphanReclaim.orphanedShaderCacheDirs(present: ["Steam-Wine11"],
                                                            referencedByBottles: ["Steam-Wine11"],
                                                            referencedByLaunchers: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testShaderCacheDirNeedsOnlyOneOfTheTwoReferencesToSurvive() {
        // Referenced by neither bottles nor THIS particular launcher set, but present in both
        // reference sets overall — covers a dir that could plausibly appear in either list.
        let result = OrphanReclaim.orphanedShaderCacheDirs(present: ["Half Sword", "ASBR"],
                                                            referencedByBottles: ["Half Sword"],
                                                            referencedByLaunchers: ["ASBR"])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: F24 — case folding, the gap PrefixSharingTests already covers for URLs

    /// This is the exact failure case F24 reported: a bottle's stored `url.lastPathComponent`
    /// differs only in case from the real on-disk directory. Before the fix, this reported the
    /// directory reclaimable — on the machine this was built for, that directory is the live
    /// 25 GB `Steam-Wine11` prefix. Fails today without `PrefixSharing.nameKey` in the filter.
    func testBottleDirIsNotOrphanedWhenReferencedNameDiffersOnlyByCase() {
        let result = OrphanReclaim.orphanedBottleDirs(present: ["Steam-Wine11"],
                                                       referencedByBottles: ["steam-wine11"])
        XCTAssertTrue(result.isEmpty, "a case-differing reference must still count as a match — "
                     + "APFS is case-insensitive by default, so these are the same directory")
    }

    func testShaderCacheDirIsNotOrphanedWhenLauncherReferenceDiffersOnlyByCase() {
        // The launcher-side equivalent — a live, launcher-consumed shader cache must not be
        // reported reclaimable just because the launcher script's casing differs from the
        // on-disk directory's.
        let result = OrphanReclaim.orphanedShaderCacheDirs(present: ["Sekiro"],
                                                            referencedByBottles: [],
                                                            referencedByLaunchers: ["sekiro"])
        XCTAssertTrue(result.isEmpty)
    }

    func testOrphanedItemNamePreservesOnDiskSpellingNotTheFoldedKey() {
        // The report prints `Item.name` and a person may paste it into a command — it must stay
        // exactly what's on disk, not the lowercased comparison key.
        let result = OrphanReclaim.orphanedBottleDirs(present: ["Bottle-F99703"],
                                                       referencedByBottles: ["Steam-Wine11"])
        XCTAssertEqual(result.map(\.name), ["Bottle-F99703"])
    }
}
