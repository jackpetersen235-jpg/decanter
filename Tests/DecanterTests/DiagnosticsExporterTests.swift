import XCTest
@testable import Decanter

/// Covers `DiagnosticsExporter.sanitize`, the one thing every file in an exported diagnostics
/// bundle passes through before it's written. Pins the bug found live during the pre-release
/// debug plan's Phase 4: `bottles.json` is written by `JSONEncoder`, which escapes every `/` as
/// `\/`, so the home directory appears in it as `\/Users\/name`, not `/Users/name`. A sanitizer
/// that only replaced the plain form silently redacted nothing there — confirmed live by
/// exporting a real bundle and finding the real account name still in it, then fixed. Both
/// spellings are tested here so this can't regress silently again.
final class DiagnosticsExporterTests: XCTestCase {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func testRedactsThePlainFormOfTheHomePath() {
        let text = "engine at \(home)/Library/Application Support/Decanter/Wine"
        let out = DiagnosticsExporter.sanitize(text)
        XCTAssertFalse(out.contains(home))
        XCTAssertTrue(out.contains("~/Library/Application Support/Decanter/Wine"))
    }

    /// The exact regression: JSONEncoder's escaped-slash form of the home path.
    func testRedactsTheJSONEscapedFormOfTheHomePath() {
        let escapedHome = home.replacingOccurrences(of: "/", with: "\\/")
        let text = "\"url\" : \"file:\\/\\/\(escapedHome)\\/Library\\/…\""
        let out = DiagnosticsExporter.sanitize(text)
        XCTAssertFalse(out.contains(escapedHome), "the JSON-escaped home path must not survive")
        XCTAssertTrue(out.contains("~"))
    }

    func testLeavesUnrelatedTextAlone() {
        let text = "Fast sync (msync) present  —  this is the tuned build"
        XCTAssertEqual(DiagnosticsExporter.sanitize(text), text)
    }

    func testRedactsEveryOccurrenceNotJustTheFirst() {
        let text = "\(home)/Bottles and also \(home)/ShaderCache"
        let out = DiagnosticsExporter.sanitize(text)
        XCTAssertFalse(out.contains(home))
        XCTAssertEqual(out.components(separatedBy: "~").count - 1, 2)
    }
}
