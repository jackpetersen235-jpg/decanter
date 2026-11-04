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
                                  .steamInstall, .launch, .save, .salvage, .quit, .unsupportedMac]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }

    #if arch(arm64)
    /// The check asks the hardware, so on the Apple silicon machine these tests build on it must
    /// say yes. (An Intel Mac has no `hw.optional.arm64` at all, which reads as no.)
    func testThisAppleSiliconMacIsRecognised() {
        XCTAssertTrue(SystemChecks.isAppleSilicon)
    }
    #endif
}
