import XCTest
@testable import Decanter

/// Help ▸ Report a Problem… opens GitHub's bug form already filled in. GitHub issues are public,
/// so the report must not carry the home folder (it names the person), and the link has to stay
/// short enough for GitHub to accept it.
final class ProblemReportTests: XCTestCase {

    private func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    func testTheHomeFolderBecomesATilde() {
        let report = "wine binary  —  /Users/sam/Library/Application Support/Decanter/Wine/bin/wine"

        let redacted = ProblemReport.redactingHome(report, home: "/Users/sam")

        XCTAssertEqual(redacted, "wine binary  —  ~/Library/Application Support/Decanter/Wine/bin/wine")
    }

    /// "/Users/sam" must not eat the front of "/Users/samantha" and leave "~antha" behind — nor of
    /// "/Users/sam.smith", since account names can contain dots.
    func testAFolderThatOnlyStartsWithTheSameNameIsLeftAlone() {
        let report = "/Users/samantha/x, /Users/sam.smith/y, /Users/sam, /Users/sam."

        let redacted = ProblemReport.redactingHome(report, home: "/Users/sam/")

        XCTAssertEqual(redacted, "/Users/samantha/x, /Users/sam.smith/y, ~, ~.")
    }

    func testTheLinkOpensTheBugFormWithEveryFieldFilledIn() {
        let url = ProblemReport.issueURL(version: "1.1 (35)", mac: "Apple M5 (Mac16,13), macOS 27.2.0",
                                         report: "\n  OK   Rosetta 2 installed\n")

        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/jackpetersen235-jpg/decanter/issues/new?"))
        XCTAssertEqual(value("template", in: url), "bug_report.yml")
        XCTAssertEqual(value("version", in: url), "1.1 (35)")
        XCTAssertEqual(value("mac", in: url), "Apple M5 (Mac16,13), macOS 27.2.0")
        XCTAssertEqual(value("diagnostics", in: url), "  OK   Rosetta 2 installed")
    }

    /// A query reads "+" as a space and "&" as the start of the next field; both must arrive intact.
    func testPlusAndAmpersandArriveIntact() {
        let url = ProblemReport.issueURL(version: "1.1", mac: "Mac", report: "C++ & friends = 100%")

        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(value("diagnostics", in: url), "C++ & friends = 100%")
    }

    func testALongReportIsTrimmedSoTheLinkStillWorks() throws {
        let report = (1...2_000).map { "  OK     line \($0) of a very long report" }.joined(separator: "\n")

        let url = ProblemReport.issueURL(version: "1.1", mac: "Mac", report: report)

        XCTAssertLessThanOrEqual(url.absoluteString.count, ProblemReport.maxURLLength)
        let sent = try XCTUnwrap(value("diagnostics", in: url))
        XCTAssertTrue(sent.hasPrefix("  OK     line 1 of a very long report\n  OK     line 2 of"))
        XCTAssertTrue(sent.hasSuffix(ProblemReport.trimmedNote))
        XCTAssertGreaterThan(sent.count, 3_000, "trimmed to fit, not emptied")
    }
}
