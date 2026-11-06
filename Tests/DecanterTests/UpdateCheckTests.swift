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
}
