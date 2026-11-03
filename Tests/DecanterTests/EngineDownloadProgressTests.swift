import XCTest
@testable import Decanter

/// The engine is two downloads (base bundle, then the msync overlay). Each used to drive the
/// setup wizard's bar from 0 to 100% on its own, so the bar filled, vanished while unpacking,
/// and started over. These pin ONE bar for the whole engine, weighted by size.
final class EngineDownloadProgressTests: XCTestCase {

    func testTheBaseDownloadStartsAtZero() {
        XCTAssertEqual(EngineDownloadProgress.overall(.base, 0), 0, accuracy: 0.0001)
    }

    func testTheOverlayFinishesAtOneHundredPercent() {
        XCTAssertEqual(EngineDownloadProgress.overall(.overlay, 1), 1, accuracy: 0.0001)
    }

    /// The bar must never move backwards between the two parts.
    func testTheOverlayStartsExactlyWhereTheBaseEnded() {
        XCTAssertEqual(EngineDownloadProgress.overall(.base, 1),
                       EngineDownloadProgress.overall(.overlay, 0), accuracy: 0.0001)
    }

    /// Weighted by size: the base is ~317 of ~480 MB, so it fills about two thirds of the bar.
    func testTheBaseFillsAboutTwoThirdsOfTheBar() {
        let end = EngineDownloadProgress.overall(.base, 1)
        XCTAssertGreaterThan(end, 0.6)
        XCTAssertLessThan(end, 0.7)
    }

    func testOutOfRangeFractionsAreClamped() {
        XCTAssertEqual(EngineDownloadProgress.overall(.base, -0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(EngineDownloadProgress.overall(.overlay, 1.5), 1, accuracy: 0.0001)
    }
}
