import XCTest
@testable import Decanter

/// Steam's own sign-in state, read from `logs/connection_log.txt` — what lets a direct launch wait
/// for a Steam that is RUNNING but not yet LOGGED ON. Found live 2026-10-21: Play pressed seconds
/// after a warm-start launched three Peggle copies into a 69-second cold login, and each died to
/// its DRM. The fixture below is that day's real log, trimmed.
final class SteamLogonTests: XCTestCase {

    private let coldLogin = """
        [2026-10-14 13:20:44] [Logged On, 4, 7] [U:1:766493812] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-21 09:09:22] Connectivity test: Starting test, fetching 'http://steamconnecttest.com/204'
        [2026-10-21 09:09:22] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )
        [2026-10-21 09:09:46] [Logged Off, 4, 0] [U:1:766493812] LogOn() called; not connected yet, scheduling connection. Schedule init returned 1
        [2026-10-21 09:10:24] [Connecting, 4, 7] [U:1:766493812] Connect() starting connection
        [2026-10-21 09:10:24] [Logging On, 4, 7] [U:1:766493812] Using JWT 6342095424908801, persistence: 1
        [2026-10-21 09:10:25] [Logged On, 4, 7] [U:1:766493812] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-21 09:10:26] CClientJobGetClientUpdateHosts: cached copy new expiration: Fri Oct 23 06:53:28 2026
        """

    private func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)!
    }

    /// The last line has no state bracket; the one before it is the answer.
    func testLatestStateSkipsLinesWithoutAState() {
        XCTAssertEqual(Steam.latestLogonState(connectionLog: coldLogin, since: nil), "Logged On")
        XCTAssertTrue(Steam.isLoggedOn(connectionLog: coldLogin, since: nil))
    }

    /// Mid-login — what all three failed clicks saw. Must read as NOT logged on.
    func testMidLoginIsNotLoggedOn() {
        let midLogin = coldLogin.split(separator: "\n").prefix(4).joined(separator: "\n")
        XCTAssertEqual(Steam.latestLogonState(connectionLog: midLogin, since: nil), "Logged Off")
        XCTAssertFalse(Steam.isLoggedOn(connectionLog: midLogin, since: nil))
    }

    /// The trap `since` exists for: Steam killed with `wineserver -k` never logs off, so the
    /// previous session's last line is "Logged On". A client started at 09:09:16 that hasn't
    /// written anything yet must not inherit that.
    func testStaleLogonFromAnEarlierSessionDoesNotCount() {
        let staleOnly = coldLogin.split(separator: "\n").prefix(1).joined(separator: "\n")
        XCTAssertTrue(Steam.isLoggedOn(connectionLog: staleOnly, since: nil))
        XCTAssertFalse(Steam.isLoggedOn(connectionLog: staleOnly, since: date("2026-10-21 09:09:16")))
    }

    func testSinceStillFindsALogonThatLandedAfterStart() {
        XCTAssertTrue(Steam.isLoggedOn(connectionLog: coldLogin, since: date("2026-10-21 09:09:16")))
    }

    func testEmptyLogMeansNotLoggedOn() {
        XCTAssertNil(Steam.latestLogonState(connectionLog: "", since: nil))
        XCTAssertFalse(Steam.isLoggedOn(connectionLog: "", since: nil))
    }

    // MARK: - ps lstart

    func testParsesPsStartTime() {
        XCTAssertEqual(Steam.processStartDate(lstart: "Wed Oct 21 09:09:16 2026"), date("2026-10-21 09:09:16"))
    }

    /// `ps` pads single-digit days with a space: "Thu Oct  1 …".
    func testParsesASpacePaddedSingleDigitDay() {
        XCTAssertEqual(Steam.processStartDate(lstart: "Thu Oct  1 07:05:03 2026"), date("2026-10-01 07:05:03"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(Steam.processStartDate(lstart: "not a date at all"))
    }
}
