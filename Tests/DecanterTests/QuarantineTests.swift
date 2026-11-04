import XCTest
@testable import Decanter

/// `Quarantine` clears the attribute a browser puts on everything in a downloaded zip. Gatekeeper
/// refuses a quarantined app that isn't notarized, and Decanter isn't, so anything Decanter copies
/// out of its own downloaded bundle has to lose the attribute first (measured 2026-11-03: a copy of
/// "Decanter Game.app" made from the friend zip kept it, and `spctl` rejected the copy).
final class QuarantineTests: XCTestCase {

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarantineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAQuarantinedFileIsReportedAsSo() throws {
        let file = try scratchDirectory().appendingPathComponent("tool")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(Quarantine.isQuarantined(file))

        try QuarantineFixture.quarantine(file)

        XCTAssertTrue(Quarantine.isQuarantined(file))
    }

    /// The attribute sits on every file of a downloaded bundle, not just its top folder, so clearing
    /// only the top would leave the executable inside still refused.
    func testStripClearsEveryItemInATree() throws {
        let app = try scratchDirectory().appendingPathComponent("Helper.app")
        let exe = app.appendingPathComponent("Contents/MacOS/helper")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "binary".write(to: exe, atomically: true, encoding: .utf8)
        try QuarantineFixture.quarantineTree(app)

        try Quarantine.strip(app)

        XCTAssertFalse(Quarantine.isQuarantined(app))
        XCTAssertFalse(Quarantine.isQuarantined(app.appendingPathComponent("Contents")))
        XCTAssertFalse(Quarantine.isQuarantined(exe))
    }

    /// Most installs were never quarantined (built locally, or cleared already). That must be a
    /// quiet no-op, not an error from removing an attribute that isn't there.
    func testStripOnAnUnquarantinedTreeIsANoOp() throws {
        let file = try scratchDirectory().appendingPathComponent("plain")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try Quarantine.strip(file))
        XCTAssertFalse(Quarantine.isQuarantined(file))
    }
}

/// Sets the quarantine attribute the way a browser download does.
enum QuarantineFixture {
    static func quarantine(_ url: URL) throws {
        let value = "0081;6727a5f0;Safari;"
        let result = value.withCString { setxattr(url.path, Quarantine.attribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func quarantineTree(_ root: URL) throws {
        try quarantine(root)
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL { try quarantine(item) }
    }
}
