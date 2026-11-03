import XCTest
@testable import Decanter

/// Right-clicking Decanter's Dock icon lists "Launch <bottle>" for every bottle that can launch,
/// in sidebar order, greyed out while that bottle is already launching.
final class DockMenuEntriesTests: XCTestCase {

    private func bottle(_ name: String) -> Bottle {
        Bottle(name: name, url: URL(fileURLWithPath: "/tmp/DockMenuEntriesTests/\(name)", isDirectory: true))
    }

    func testListsOnlyBottlesWithSteamInSidebarOrder() {
        let steam = bottle("Steam"), empty = bottle("Empty"), sekiro = bottle("Sekiro")

        let entries = DockMenuEntries.make(for: [steam, empty, sekiro],
                                           hasSteam: { $0.name != "Empty" }, launching: [])

        XCTAssertEqual(entries.map(\.title), ["Launch Steam", "Launch Sekiro"])
        XCTAssertEqual(entries.map(\.bottleID), [steam.id, sekiro.id])
    }

    func testABottleAlreadyLaunchingIsListedButDisabled() {
        let steam = bottle("Steam"), sekiro = bottle("Sekiro")

        let entries = DockMenuEntries.make(for: [steam, sekiro], hasSteam: { _ in true },
                                           launching: [sekiro.id])

        XCTAssertEqual(entries.map(\.isEnabled), [true, false])
    }

    func testNoLaunchableBottlesMeansAnEmptyMenu() {
        let entries = DockMenuEntries.make(for: [bottle("Empty")], hasSteam: { _ in false }, launching: [])

        XCTAssertTrue(entries.isEmpty)
    }
}
