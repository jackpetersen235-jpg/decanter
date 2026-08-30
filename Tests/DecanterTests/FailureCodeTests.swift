import XCTest
@testable import Decanter

/// `tag(_:)` is the one place every failure-code prefix is formatted — pinned here so the shape
/// (`[DEC-Enn] message`) can't drift accidentally, since every call site across AppModel and
/// SetupWizard depends on it looking the same.
final class FailureCodeTests: XCTestCase {
    func testTagPrependsTheCodeInBrackets() {
        XCTAssertEqual(FailureCode.launch.tag("Sekiro didn't start."),
                       "[DEC-E06] Sekiro didn't start.")
    }

    /// Every case gets a distinct, stable string — a support conversation depends on these never
    /// silently colliding or being renumbered.
    func testEveryCodeIsUnique() {
        let all: [FailureCode] = [.rosetta, .engineInstall, .engineMissing, .bottleCreate,
                                  .steamInstall, .launch, .save, .salvage]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }
}
