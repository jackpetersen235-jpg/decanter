import XCTest
@testable import Decanter

/// The words for a game launch Decanter is HOLDING until Steam signs in. Found live 2026-10-21:
/// Play on Peggle joined a warm-start, nothing on screen changed but "Opening…", and Decanter was
/// quit from the Dock 44 s in — 22 s before Steam signed in. The launch lived only in Decanter's
/// memory, so it died with the app and Peggle never started.
final class LaunchWaitTests: XCTestCase {

    func testNoWarningWhenNothingIsHeld() {
        XCTAssertNil(LaunchWait.quitWarning(gameNames: []))
    }

    /// One game: name it, and say plainly that quitting means it won't start.
    func testWarningNamesTheOneHeldGame() throws {
        let warning = try XCTUnwrap(LaunchWait.quitWarning(gameNames: ["Peggle Deluxe"]))
        XCTAssertTrue(warning.title.contains("Peggle Deluxe"))
        XCTAssertTrue(warning.message.contains("won't start"))
    }

    func testWarningCountsSeveralHeldGames() throws {
        let warning = try XCTUnwrap(LaunchWait.quitWarning(gameNames: ["Peggle Deluxe", "Half Sword"]))
        XCTAssertTrue(warning.title.contains("2 games"))
        XCTAssertTrue(warning.message.contains("Peggle Deluxe"))
        XCTAssertTrue(warning.message.contains("Half Sword"))
    }

    /// The caption must tell the user the two things that would have saved the 2026-10-21 launch:
    /// the game starts BY ITSELF, and Decanter has to stay open until it does.
    func testCaptionSaysItStartsByItselfAndToKeepDecanterOpen() {
        let caption = LaunchWait.caption(gameName: "Peggle Deluxe")
        XCTAssertTrue(caption.contains("Peggle Deluxe"))
        XCTAssertTrue(caption.contains("by itself"))
        XCTAssertTrue(caption.contains("keep Decanter open"))
    }

    /// The old caption promised "a few seconds"; a cold Steam sign-in measured 67 s that day.
    func testCaptionDoesNotPromiseSeconds() {
        XCTAssertFalse(LaunchWait.caption(gameName: "Peggle Deluxe").contains("few seconds"))
        XCTAssertFalse(LaunchWait.openingCaption.contains("few seconds"))
    }
}
