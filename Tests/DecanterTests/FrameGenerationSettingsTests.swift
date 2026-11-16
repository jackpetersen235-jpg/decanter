import XCTest
@testable import Decanter

/// Frame generation (Inbetween): the per-bottle setting, that it needs no environment flag, and the guard that
/// keeps it out of a game folder another launcher also runs (Sekiro.app runs Sekiro's).
final class FrameGenerationSettingsTests: XCTestCase {

    func testFrameGenerationIsOffByDefaultAndForOlderSavedSettings() throws {
        // Arrange: settings saved before the field existed
        let old = Data(#"{"graphics":"dxmt"}"#.utf8)

        // Act
        let decoded = try JSONDecoder().decode(BottleSettings.self, from: old)

        // Assert
        XCTAssertFalse(BottleSettings().frameGeneration)
        XCTAssertFalse(decoded.frameGeneration)
        XCTAssertNil(decoded.derivedEnvironment["DXMT_FRAMEGEN"])
    }

    func testFrameGenerationNeedsNoEnvironmentFlag() {
        // Arrange: the DLLs are the switch. A flag in the bottle's environment only ever reached a
        // game when Decanter itself started Steam (measured 2026-11-16), and DXMT_FRAMEGEN=0 would
        // turn the self-enabling DLLs off.
        var settings = BottleSettings()
        settings.graphics = .dxmt
        settings.frameGeneration = true

        // Act
        let env = settings.derivedEnvironment

        // Assert
        XCTAssertNil(env["DXMT_FRAMEGEN"])
    }

    func testARebuiltDLLOfTheSameSizeStillCountsAsDifferent() throws {
        // Arrange: the self-enabling frame-generation d3d11.dll is exactly as long as the build it
        // replaced, so a size-only check skipped installing it (found 2026-11-16).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fg-dlls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game"), source = root.appendingPathComponent("source")
        for dir in [game, source] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dll in Paths.dxmtDLLs {
            try Data("old build".utf8).write(to: game.appendingPathComponent(dll))
            try Data("new build".utf8).write(to: source.appendingPathComponent(dll))
        }

        // Act
        let differentContents = AppModel.dxmtDLLsMatch(in: game, source: source)
        for dll in Paths.dxmtDLLs {
            try FileManager.default.removeItem(at: game.appendingPathComponent(dll))
            try FileManager.default.copyItem(at: source.appendingPathComponent(dll), to: game.appendingPathComponent(dll))
        }
        let sameContents = AppModel.dxmtDLLsMatch(in: game, source: source)

        // Assert
        XCTAssertFalse(differentContents)
        XCTAssertTrue(sameContents)
    }

    func testAnotherLauncherRunningTheSameFolderBlocksIt() throws {
        // Arrange: a Sekiro.app-like script for common/Sekiro and a clone's for common/Sekiro-Inbetween
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent("fg-launchers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: apps) }
        func launcher(_ name: String, runs game: String) throws {
            let macOS = apps.appendingPathComponent("\(name).app/Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let script = "#!/bin/bash\nGAME_EXE=\"$PREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/\(game)\"\n"
            try script.write(to: macOS.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try launcher("Sekiro", runs: "Sekiro/sekiro.exe")
        try launcher("Sekiro (Inbetween)", runs: "Sekiro-Inbetween/sekiro.exe")
        let common = URL(fileURLWithPath: "/Users/x/Bottles/Steam-Wine11/drive_c/Program Files (x86)/Steam/steamapps/common")

        // Act
        let sekiro = AppModel.externalLaunchers(using: common.appendingPathComponent("Sekiro"), applications: apps)
        let clone = AppModel.externalLaunchers(using: common.appendingPathComponent("Sekiro-Inbetween"), applications: apps)
        let other = AppModel.externalLaunchers(using: common.appendingPathComponent("Half Sword Demo"), applications: apps)

        // Assert
        XCTAssertEqual(sekiro, ["Sekiro"])
        XCTAssertEqual(clone, ["Sekiro (Inbetween)"])
        XCTAssertEqual(other, [])
    }
}
