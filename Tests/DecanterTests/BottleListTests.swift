import XCTest
@testable import Decanter

/// Undo of "Delete Bottle (keep files)" puts the bottle back exactly where it was. The deletion
/// only drops the list entry (the prefix stays on disk), so restoring the entry IS the full undo —
/// these pin that the order survives and that a repeated undo can never duplicate a bottle.
final class BottleListTests: XCTestCase {

    private func bottle(_ name: String) -> Bottle {
        Bottle(name: name, url: URL(fileURLWithPath: "/tmp/BottleListTests/\(name)", isDirectory: true))
    }

    func testRestoringPutsTheBottleBackAtItsOriginalPosition() {
        let steam = bottle("Steam"), sekiro = bottle("Sekiro"), peggle = bottle("Peggle")
        let afterDelete = [steam, peggle]                       // Sekiro was at index 1

        let restored = BottleList.restoring(sekiro, at: 1, in: afterDelete)

        XCTAssertEqual(restored.map(\.name), ["Steam", "Sekiro", "Peggle"])
        XCTAssertEqual(restored[1], sekiro, "the restored entry keeps its id and settings")
    }

    func testRestoringTwiceNeverDuplicatesTheBottle() {
        let steam = bottle("Steam"), sekiro = bottle("Sekiro")

        let once = BottleList.restoring(sekiro, at: 1, in: [steam])
        let twice = BottleList.restoring(sekiro, at: 1, in: once)

        XCTAssertEqual(twice.map(\.name), ["Steam", "Sekiro"])
    }

    /// The list can shrink between the delete and the undo (another bottle deleted meanwhile), so
    /// the remembered index may be past the end. It must clamp, not crash.
    func testAnIndexPastTheEndIsClampedToTheEnd() {
        let steam = bottle("Steam"), sekiro = bottle("Sekiro")

        let restored = BottleList.restoring(sekiro, at: 5, in: [steam])

        XCTAssertEqual(restored.map(\.name), ["Steam", "Sekiro"])
    }

    func testRestoringDoesNotChangeTheInputList() {
        let steam = bottle("Steam"), sekiro = bottle("Sekiro")
        let original = [steam]

        _ = BottleList.restoring(sekiro, at: 0, in: original)

        XCTAssertEqual(original.map(\.name), ["Steam"])
    }
}
