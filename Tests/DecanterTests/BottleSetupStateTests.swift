import XCTest
@testable import Decanter

/// A bottle is saved BEFORE its wineboot runs, so quitting Decanter mid-setup leaves one marked
/// not-initialized with nothing booting it. The UI used to show "Setting up…" with a spinner for
/// it forever. These pin the rule that tells that case apart from a setup really in progress.
final class BottleSetupStateTests: XCTestCase {

    func testAnInitializedBottleIsReadyWhateverElseIsGoingOn() {
        XCTAssertEqual(BottleSetupState.of(isInitialized: true, isBooting: false), .ready)
        XCTAssertEqual(BottleSetupState.of(isInitialized: true, isBooting: true), .ready)
    }

    func testABottleBeingBootedRightNowIsInProgress() {
        XCTAssertEqual(BottleSetupState.of(isInitialized: false, isBooting: true), .inProgress)
    }

    /// The case that used to spin forever: not initialized, and nothing is booting it.
    func testNotInitializedWithNothingBootingIsInterrupted() {
        XCTAssertEqual(BottleSetupState.of(isInitialized: false, isBooting: false), .interrupted)
    }
}
