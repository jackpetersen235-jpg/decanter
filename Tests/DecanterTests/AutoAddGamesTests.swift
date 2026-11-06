import XCTest
@testable import Decanter

/// A game installed in Steam shows up in Decanter by itself — no "+" step — but only when it's
/// really a finished Steam game, and never again once the user has deleted it.
final class AutoAddGamesTests: XCTestCase {

    private let prefix = URL(fileURLWithPath: "/tmp/AutoAddGamesTests/Steam-Wine11", isDirectory: true)

    private func game(_ name: String, appID: String?, installed: Bool = true) -> GameScanner.FoundGame {
        GameScanner.FoundGame(name: name, folder: prefix.appendingPathComponent(name),
                              executable: prefix.appendingPathComponent("\(name)/\(name).exe"),
                              sizeBytes: 1, appID: appID, prefix: prefix, isFullyInstalled: installed)
    }

    func testANewFullyInstalledSteamGameIsAdded() {
        let hades = game("Hades", appID: "1145360")

        let added = AutoAddGames.gamesToAdd([hades], alreadyHasBottle: { _ in false }, dismissed: [])

        XCTAssertEqual(added.map(\.name), ["Hades"])
    }

    func testAGameThatAlreadyHasABottleIsNotAddedAgain() {
        let sekiro = game("Sekiro", appID: "814380")

        let added = AutoAddGames.gamesToAdd([sekiro], alreadyHasBottle: { $0.appID == "814380" },
                                            dismissed: [])

        XCTAssertTrue(added.isEmpty)
    }

    /// The same game can be installed in two Windows setups (Half Sword in Steam-Wine11 AND in its
    /// own prefix). If a bottle already plays it, adding the second copy reads as a duplicate.
    func testAGameAlreadyPlayedFromAnotherSetupIsNotAddedAgain() {
        let halfSword = game("Half Sword Demo", appID: "2642680")

        let added = AutoAddGames.gamesToAdd([halfSword], alreadyHasBottle: { _ in false },
                                            appIDsWithBottles: ["2642680"], dismissed: [])

        XCTAssertTrue(added.isEmpty)
    }

    /// Deleting a game's bottle must stick — otherwise it reappears every time Decanter looks.
    func testAGameTheUserDeletedStaysDeleted() {
        let peggle = game("Peggle", appID: "3480")
        let dismissed: Set<String> = [AutoAddGames.key(appID: "3480", prefix: prefix)]

        let added = AutoAddGames.gamesToAdd([peggle], alreadyHasBottle: { _ in false },
                                            dismissed: dismissed)

        XCTAssertTrue(added.isEmpty)
    }

    /// A game still downloading has its folder and often its .exe already — adding it then would
    /// put a Play button on something Steam can't start yet.
    func testAGameStillDownloadingWaitsUntilItsDone() {
        let downloading = game("Elden Ring", appID: "1245620", installed: false)

        let added = AutoAddGames.gamesToAdd([downloading], alreadyHasBottle: { _ in false },
                                            dismissed: [])

        XCTAssertTrue(added.isEmpty)
    }

    /// Only Steam games are added on their own. Anything else found in Program Files could be a
    /// utility or an installer; those stay behind "+".
    func testNonSteamProgramsAreNeverAddedAutomatically() {
        let tool = game("SomeTool", appID: nil)

        let added = AutoAddGames.gamesToAdd([tool], alreadyHasBottle: { _ in false }, dismissed: [])

        XCTAssertTrue(added.isEmpty)
    }

    /// APFS is case-insensitive, so a dismissal recorded under one spelling of the prefix path must
    /// still match another.
    func testTheDismissalKeyIgnoresHowThePrefixPathIsCapitalised() {
        let upper = URL(fileURLWithPath: "/tmp/AutoAddGamesTests/STEAM-WINE11", isDirectory: true)

        XCTAssertEqual(AutoAddGames.key(appID: "3480", prefix: prefix),
                       AutoAddGames.key(appID: "3480", prefix: upper))
    }
}
