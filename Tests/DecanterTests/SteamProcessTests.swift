import XCTest
@testable import Decanter

/// Telling a RUNNING Steam client apart from a Wine launch that never became one. Found live
/// 2026-10-21: Quit Steam, then selecting Peggle three seconds later — the warm-start's
/// `wine steam.exe` started while the quit was still tearing the prefix down, its wineserver was
/// killed under it, and the loader hung for good. Its command line still mentions
/// `…/Steam/steam.exe`, so the old `pgrep -f /steam\.exe` check called it a running Steam: Quit
/// Steam reported "[DEC-E09] Steam is still running", and Play skipped the sign-in wait. Fixtures
/// are that morning's real `ps` values.
final class SteamProcessTests: XCTestCase {

    private let client = "/Users/me/Library/Application Support/Decanter/Bottles/"
        + "Steam-Wine11/drive_c/Program Files (x86)/Steam/steam.exe"
    private let loader = "/Users/me/Library/Application Support/Decanter/Wine/"
        + "Libraries/Wine/bin/wine"

    // MARK: - comm

    func testTheClientItselfCounts() {
        XCTAssertTrue(Steam.isClient(comm: client))
    }

    /// The hung launch: its executable is Wine's loader, whatever its arguments say.
    func testAWineLoaderStillStartingSteamDoesNotCount() {
        XCTAssertFalse(Steam.isClient(comm: loader))
    }

    /// Webhelpers name `\steam.exe` in their arguments and outlive Steam for hours.
    func testAWebhelperDoesNotCount() {
        XCTAssertFalse(Steam.isClient(comm: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#))
    }

    func testTheNativeMacSteamDoesNotCount() {
        XCTAssertFalse(Steam.isClient(comm: "/Applications/Steam.app/Contents/MacOS/steam_osx"))
    }

    func testAWindowsPathClientCounts() {
        XCTAssertTrue(Steam.isClient(comm: #"C:\Program Files (x86)\Steam\steam.exe"#))
    }

    // MARK: - start time

    private func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)!
    }

    /// `ps -Ao lstart=,command=` with the hung loader listed first: the start time must be the
    /// client's, not the loader's — `isSteamLoggedOn` ignores every log line older than it.
    func testStartTimeIsTheClientsNotAHungLoaders() {
        let ps = """
            Wed Oct 21 10:05:26 2026     \(loader) \(client) -silent -no-cef-sandbox -skipinitialbootstrap
            Wed Oct 21 10:08:02 2026     \(client) -silent -no-cef-sandbox -skipinitialbootstrap -applaunch 3480
            """
        XCTAssertEqual(Steam.clientStartDate(ps: ps, steamExecutable: client), date("2026-10-21 10:08:02"))
    }

    func testNoStartTimeWhenOnlyAHungLoaderExists() {
        let ps = "Wed Oct 21 10:05:26 2026     \(loader) \(client) -silent"
        XCTAssertNil(Steam.clientStartDate(ps: ps, steamExecutable: client))
    }
}
