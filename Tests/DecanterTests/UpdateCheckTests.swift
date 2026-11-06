import XCTest
@testable import Decanter

/// Decanter → Check for Updates reads GitHub's "latest release" JSON and offers the zip only when
/// its version is newer than the running app's.
final class UpdateCheckTests: XCTestCase {

    private func json(tag: String, assets: [(String, String)], body: String = "Fixes.") -> Data {
        let list = assets.map { #"{"name": "\#($0.0)", "browser_download_url": "\#($0.1)"}"# }
            .joined(separator: ",")
        return Data(#"{"tag_name": "\#(tag)", "body": "\#(body)", "assets": [\#(list)]}"#.utf8)
    }

    func testParsesTheVersionNotesAndZipFromARelease() throws {
        let data = json(tag: "v1.1", assets: [("Decanter-1.1.zip", "https://example.com/Decanter-1.1.zip")])

        let release = try XCTUnwrap(UpdateCheck.parse(data))

        XCTAssertEqual(release.version, "1.1")
        XCTAssertEqual(release.notes, "Fixes.")
        XCTAssertEqual(release.zipURL.absoluteString, "https://example.com/Decanter-1.1.zip")
    }

    /// A release with no zip attached (or only other files) has nothing to install.
    func testAReleaseWithoutAZipIsIgnored() {
        let data = json(tag: "v1.1", assets: [("notes.md", "https://example.com/notes.md")])

        XCTAssertNil(UpdateCheck.parse(data))
    }

    func testGarbageIsIgnoredNotACrash() {
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
    }

    func testNewerVersionsAreOffered() {
        XCTAssertTrue(UpdateCheck.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0", than: "1.9"))
    }

    /// Compared as numbers, not text: "1.10" is newer than "1.9".
    func testVersionsCompareNumericallyNotAlphabetically() {
        XCTAssertTrue(UpdateCheck.isNewer("1.10", than: "1.9"))
    }

    func testTheSameOrAnOlderVersionIsNotOffered() {
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9", than: "1.0"))
    }

    // MARK: What the update alert shows

    /// The 1.1 alert showed the notes' raw Markdown, starting with the by-hand steps for 1.0 users —
    /// instructions to do the very thing the alert's own button does. Only "What's new" belongs there.
    func testTheAlertShowsOnlyWhatsNewWithoutMarkdown() {
        let notes = """
        Play Windows games from Steam on an Apple silicon Mac.

        ## Already have Decanter 1.0?

        1. Download **Decanter-1.1.zip** below and open it.

        ## What's new in 1.1

        - **Games appear by themselves.** Install a game in Steam and it's in the sidebar.
        - **Decanter updates itself.** Choose **Decanter → Check for Updates…**.

        ## Requirements

        - A Mac with Apple silicon.
        """

        let summary = UpdateCheck.summary(ofNotes: notes)

        XCTAssertEqual(summary, """
        • Games appear by themselves. Install a game in Steam and it's in the sidebar.
        • Decanter updates itself. Choose Decanter → Check for Updates….
        """)
    }

    func testNotesWithoutAWhatsNewSectionAreShownWhole() {
        let notes = "Fixes a **crash** when [Steam](https://example.com/steam) quits.\n\n\n`--verify` is quieter."

        XCTAssertEqual(UpdateCheck.summary(ofNotes: notes),
                       "Fixes a crash when Steam quits.\n\n--verify is quieter.")
    }

    func testLongNotesAreCutAtALineWithAnEllipsis() {
        let notes = (1...100).map { "- Fix number \($0) of many." }.joined(separator: "\n")

        let summary = UpdateCheck.summary(ofNotes: notes, limit: 200)

        XCTAssertLessThanOrEqual(summary.count, 201)
        XCTAssertTrue(summary.hasPrefix("• Fix number 1 of many.\n• Fix number 2"))
        XCTAssertTrue(summary.hasSuffix("of many.\n…"))
    }
}
