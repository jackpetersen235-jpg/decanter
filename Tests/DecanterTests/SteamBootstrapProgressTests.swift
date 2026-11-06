import XCTest
@testable import Decanter

/// Steam's first launch downloads its own client with no window, which looks frozen. Its
/// bootstrap log lists every package it queues (`…_<bytes>`), and each lands in `package/` under
/// that same name, so "X of Y MB" is measurable without Steam ever reporting a percentage.
final class SteamBootstrapProgressTests: XCTestCase {

    private let log = """
        [2026-07-16 07:00:00] Startup - updater built May 20 2024 14:26:54
        [2026-07-16 07:00:01] Add pending download: https://cdn.steamstatic.com/client/old_all.zip.vz.aaa_999
        [2026-07-16 07:09:02] Startup - updater built May 20 2024 14:26:54
        [2026-07-16 07:09:03] Add pending download: https://cdn.steamstatic.com/client/steamui_websrc_all.zip.vz.3454_25053126
        [2026-07-16 07:09:03] Manifest download: send request
        [2026-07-16 07:09:04] Add pending download: https://cdn.steamstatic.com/client/public_all.zip.vz.48a9_23753492
        [2026-07-16 07:09:04] Add pending download: https://cdn.steamstatic.com/client/strings_en_all.zip.8eef
        """

    /// Only the most recent startup counts — the log keeps every earlier run too.
    func testReadsOnlyThePackagesQueuedByTheLatestStartup() {
        let packages = SteamBootstrapProgress.pendingPackages(inLog: log)

        XCTAssertEqual(packages.map(\.name), ["steamui_websrc_all.zip.vz.3454_25053126",
                                              "public_all.zip.vz.48a9_23753492"])
        XCTAssertEqual(packages.map(\.bytes), [25_053_126, 23_753_492])
    }

    func testProgressCountsWhatsOnDiskAgainstTheTotal() {
        let packages = SteamBootstrapProgress.pendingPackages(inLog: log)
        let onDisk = ["steamui_websrc_all.zip.vz.3454_25053126": Int64(25_053_126),
                      "public_all.zip.vz.48a9_23753492": Int64(10_000_000)]

        let progress = SteamBootstrapProgress.progress(of: packages, sizeOnDisk: { onDisk[$0] ?? 0 })

        XCTAssertEqual(progress.done, 35_053_126)
        XCTAssertEqual(progress.total, 48_806_618)
    }

    /// A file can't count for more than its listed size, so the bar never passes 100%.
    func testAFileLargerThanListedCountsOnlyItsListedSize() {
        let packages = [SteamBootstrapProgress.Package(name: "a_100", bytes: 100)]

        let progress = SteamBootstrapProgress.progress(of: packages, sizeOnDisk: { _ in 500 })

        XCTAssertEqual(progress.done, 100)
    }

    /// Steam is a Windows program: its log ends lines with \r\n. A stray \r on the size made every
    /// package fail to parse, so the real log showed nothing at all (caught on this Mac's log).
    func testWindowsLineEndingsAreHandled() {
        let crlf = log.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

        XCTAssertEqual(SteamBootstrapProgress.pendingPackages(inLog: crlf).map(\.bytes),
                       [25_053_126, 23_753_492])
    }

    func testALogWithNoDownloadsHasNothingToShow() {
        XCTAssertTrue(SteamBootstrapProgress.pendingPackages(inLog: "[t] Startup - x\n[t] Verification complete").isEmpty)
    }
}
