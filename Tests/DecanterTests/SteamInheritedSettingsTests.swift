import XCTest
@testable import Decanter

/// A game Steam starts (`-applaunch`) takes these settings from the RUNNING Steam's environment, not
/// from its own bottle. When they differ, Play restarts Steam rather than run the game with another
/// bottle's settings without saying so.
final class SteamInheritedSettingsTests: XCTestCase {

    private func dxmtSettings() -> BottleSettings {
        var settings = BottleSettings()
        settings.graphics = .dxmt
        return settings
    }

    func testMatchingSteamNeedsNoRestart() {
        // Arrange
        let game = dxmtSettings()
        let steam = SteamInheritedSettings.expected(for: game)

        // Act
        let differing = SteamInheritedSettings.differing(game: game, steamEnvironment: steam)

        // Assert
        XCTAssertEqual(differing, [])
    }

    func testMetalFXTurnedOnAfterSteamStartedIsCaught() {
        // Arrange: Steam started while MetalFX was off; the switch was turned on afterwards
        let before = dxmtSettings()
        var game = before
        game.metalFX = true

        // Act
        let differing = SteamInheritedSettings.differing(
            game: game, steamEnvironment: SteamInheritedSettings.expected(for: before))

        // Assert
        XCTAssertEqual(differing, ["MetalFX upscaling"])
    }

    func testOnlyKeysThatMatterToTheGamesGraphicsAreCompared() {
        // Arrange: a DXMT game, and a Steam started by a DXVK bottle with its HUD on and other
        // incidental differences (its own shader cache folder, Steam app id)
        let game = dxmtSettings()
        var steam = SteamInheritedSettings.expected(for: game)
        steam["DXVK_HUD"] = "fps,frametimes,gpuload"
        steam["DXMT_SHADER_CACHE_PATH"] = "/somewhere/else"
        steam["SteamAppId"] = "1"

        // Act
        let differing = SteamInheritedSettings.differing(game: game, steamEnvironment: steam)

        // Assert
        XCTAssertEqual(differing, [])
    }

    func testEnvSettingsAndCustomVariablesAreNamedReadably() {
        // Arrange
        var game = dxmtSettings()
        game.metalHUD = true
        game.verboseLogging = true
        game.syncMode = .esync
        game.environment = ["MY_GAME_FLAG": "1"]
        let steam = SteamInheritedSettings.expected(for: dxmtSettings())

        // Act
        let differing = SteamInheritedSettings.differing(game: game, steamEnvironment: steam)

        // Assert
        XCTAssertEqual(Set(differing), ["Metal performance HUD", "Verbose Wine logging", "Thread sync",
                                        "MY_GAME_FLAG"])
    }
}
