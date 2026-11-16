import XCTest
@testable import Decanter

/// Reading the environment a running process started with, the way `ps -E` does — how Play finds
/// out which settings an already-running Steam would hand the game.
final class ProcessEnvironmentTests: XCTestCase {

    func testReadsTheEnvironmentOfARunningChildProcess() throws {
        // Arrange: macOS hides the environment of its own system programs (/bin/sleep reads as
        // empty), not of ordinary ones like Wine's processes, so run an ad-hoc-signed copy.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("procenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sleeper = dir.appendingPathComponent("sleeper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", sleeper.path]
        try sign.run()
        sign.waitUntilExit()
        let child = Process()
        child.executableURL = sleeper
        child.arguments = ["5"]
        child.environment = ["DECANTER_TEST_FLAG": "on", "MTL_HUD_ENABLED": "0"]
        try child.run()
        defer { child.terminate() }

        // Act
        let env = ProcessEnvironment.of(pid: child.processIdentifier)

        // Assert
        XCTAssertEqual(env?["DECANTER_TEST_FLAG"], "on")
        XCTAssertEqual(env?["MTL_HUD_ENABLED"], "0")
    }

    func testArgumentsAreNotMistakenForVariables() {
        // Arrange: argc 2, exec path, padding, argv (a Windows path and a flag), then two variables
        var bytes: [UInt8] = [2, 0, 0, 0]
        for part in ["/opt/wine/bin/wine64-preloader", "", "C:\\Steam\\steam.exe", "-silent",
                     "WINEMSYNC=1", "DXMT_CONFIG=d3d11.a=1;d3d11.b=2"] {
            bytes += Array(part.utf8) + [0]
        }

        // Act
        let env = ProcessEnvironment.parse(bytes)

        // Assert
        XCTAssertEqual(env, ["WINEMSYNC": "1", "DXMT_CONFIG": "d3d11.a=1;d3d11.b=2"])
    }

    func testAProcessThatDoesNotExistGivesNothing() {
        XCTAssertNil(ProcessEnvironment.of(pid: -1))
    }
}
