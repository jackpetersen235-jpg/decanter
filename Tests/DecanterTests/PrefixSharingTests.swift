import XCTest
@testable import Decanter

/// Pins `PrefixSharing`'s answer to "which bottles share this prefix" — the model behind bug-sweep
/// findings F1/F2/F8 (shared registry, shared process tree, shared per-exe override, all presented
/// as though bottles were isolated).
final class PrefixSharingTests: XCTestCase {

    private func bottle(_ name: String, _ prefixPath: String) -> Bottle {
        Bottle(name: name, url: URL(fileURLWithPath: prefixPath, isDirectory: true))
    }

    // MARK: key(for:) — the normalization bugs

    func testIdenticalURLsShareAKey() {
        let a = URL(fileURLWithPath: "/Bottles/Steam-Wine11", isDirectory: true)
        let b = URL(fileURLWithPath: "/Bottles/Steam-Wine11", isDirectory: true)
        XCTAssertEqual(PrefixSharing.key(for: a), PrefixSharing.key(for: b))
    }

    /// Does NOT fail before the fix — `URL.path` already decodes percent-encoding on its own, so
    /// even a naive `url.path` key passes this. Verified directly: reverted `key(for:)` to bare
    /// `url.path` and re-ran the suite; only the case-folding test below failed. Kept as a
    /// regression guard for behavior the code correctly relies on, not relabelled as something it
    /// is not — an earlier draft of this test's doc comment claimed the opposite and was wrong.
    func testPercentEncodedAndPlainPathAreTheSamePrefix() {
        let encoded = URL(string: "file:///Users/j/Library/Application%20Support/"
                                 + "Decanter/Bottles/Half%20Sword/")!
        let plain = URL(fileURLWithPath: "/Users/j/Library/Application Support/"
                                       + "Decanter/Bottles/Half Sword", isDirectory: true)
        XCTAssertEqual(PrefixSharing.key(for: encoded), PrefixSharing.key(for: plain))
    }

    /// Also does not fail before the fix, same reason as the percent-encoding test above: `.path`
    /// already drops the trailing slash for both URL construction paths exercised here.
    func testTrailingSlashDoesNotAffectIdentity() {
        let a = URL(fileURLWithPath: "/Bottles/Steam-Wine11/", isDirectory: true)
        let b = URL(fileURLWithPath: "/Bottles/Steam-Wine11", isDirectory: true)
        XCTAssertEqual(PrefixSharing.key(for: a), PrefixSharing.key(for: b))
    }

    /// THE ONE THAT ACTUALLY FAILS BEFORE THE FIX. Verified: reverting `key(for:)` to bare
    /// `url.path` made this the only failure in the suite (10 passed, 1 failed). Also documents the
    /// deliberate trade-off: correct on the default case-insensitive APFS volume, wrong on a
    /// case-sensitive one — pinned so changing the folding behaviour is a conscious decision.
    func testCaseIsFoldedForTheDefaultCaseInsensitiveVolume() {
        let a = URL(fileURLWithPath: "/Bottles/Steam-Wine11", isDirectory: true)
        let b = URL(fileURLWithPath: "/Bottles/steam-wine11", isDirectory: true)
        XCTAssertEqual(PrefixSharing.key(for: a), PrefixSharing.key(for: b))
    }

    // MARK: group(of:in:) / others(of:in:)

    func testBottlesInDifferentPrefixesAreNotGrouped() {
        let a = bottle("A", "/Bottles/One")
        let b = bottle("B", "/Bottles/Two")
        XCTAssertEqual(PrefixSharing.group(of: a, in: [a, b]).map(\.id), [a.id])
        XCTAssertFalse(PrefixSharing.isShared(a, in: [a, b]))
    }

    func testOthersExcludesSelfByIDNotName() {
        // Two bottles legitimately share a name (the picker allows a second "Peggle Deluxe").
        var a = bottle("Peggle Deluxe", "/Bottles/Shared")
        var b = bottle("Peggle Deluxe", "/Bottles/Shared")
        a.id = UUID(); b.id = UUID()
        let others = PrefixSharing.others(of: a, in: [a, b])
        XCTAssertEqual(others.map(\.id), [b.id])
    }

    func testSingleBottleGroupIsJustItself() {
        let a = bottle("Solo", "/Bottles/Solo")
        XCTAssertEqual(PrefixSharing.group(of: a, in: [a]).map(\.id), [a.id])
        XCTAssertTrue(PrefixSharing.others(of: a, in: [a]).isEmpty)
    }

    func testEmptyBottleListDoesNotCrash() {
        let a = bottle("Orphan", "/Bottles/Orphan")
        XCTAssertTrue(PrefixSharing.group(of: a, in: []).isEmpty)
    }

    func testGroupOrderMatchesInputOrder() {
        let a = bottle("A", "/Bottles/Shared")
        let b = bottle("B", "/Bottles/Shared")
        let c = bottle("C", "/Bottles/Shared")
        XCTAssertEqual(PrefixSharing.group(of: b, in: [c, a, b]).map(\.name), ["C", "A", "B"])
    }

    // MARK: software2DWanted — F8

    /// FAILS before the fix in the naive "clear on OFF, no matter who else wants it" version:
    /// bottle B turning software-2D off must not silently undo bottle A's ON, when both resolve the
    /// same executable in the same prefix.
    func testSoftware2DIsWantedIfAnyBottleResolvingThatExeWantsIt() {
        var a = bottle("Peggle A", "/Bottles/Shared")
        var b = bottle("Peggle B", "/Bottles/Shared")
        a.settings.software2D = true
        b.settings.software2D = false
        let group = [a, b]
        let resolve: (Bottle) -> String? = { _ in "popcapgame1.exe" }
        XCTAssertTrue(PrefixSharing.software2DWanted(forExe: "popcapgame1.exe",
                                                      in: group, resolve: resolve))
    }

    func testSoftware2DNotWantedWhenNoBottleResolvesToThatExe() {
        var a = bottle("Sekiro", "/Bottles/Shared")
        a.settings.software2D = true
        let resolve: (Bottle) -> String? = { _ in "sekiro.exe" }   // never "popcapgame1.exe"
        XCTAssertFalse(PrefixSharing.software2DWanted(forExe: "popcapgame1.exe",
                                                       in: [a], resolve: resolve))
    }
}
