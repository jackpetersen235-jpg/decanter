import XCTest
@testable import Decanter

/// Characterization tests for `BottleSettings.derivedEnvironment` — Phase 2 of the hardening plan
/// ("Prove the chokepoints"). This one function decides the sync primitive, the graphics backend
/// config, and every HUD/AVX flag for EVERY launch in the app, and until now it had zero direct
/// tests. Two of its keys (`sampleNaNToZero`, `defuseFma`) were missing for weeks before the
/// 2026-08-29 settings-parity audit caught it by hand — a pinned-output test on the DXMT config
/// string would have caught that the same day it regressed.
///
/// These are CHARACTERIZATION tests, not behavior specs: the goal is to freeze what this function
/// already does (expensively learned, in several cases from a live game) so the next change that
/// alters it has to do so on purpose. Purely value-type input/output — no Bottle, no
/// WineInstallation, no filesystem — so nothing here needs a scratch DECANTER_HOME.
final class BottleSettingsEnvironmentTests: XCTestCase {

    // MARK: - Sync mode

    func testMsyncSetsBothMsyncAndEsyncFlags() {
        var settings = BottleSettings()
        settings.syncMode = .msync

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEESYNC"], "1")
    }

    func testEsyncSetsOnlyTheEsyncFlag() {
        var settings = BottleSettings()
        settings.syncMode = .esync

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["WINEMSYNC"], "0")
        XCTAssertEqual(env["WINEESYNC"], "1")
    }

    func testSyncModeNoneClearsBothFlags() {
        var settings = BottleSettings()
        settings.syncMode = .none

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["WINEMSYNC"], "0")
        XCTAssertEqual(env["WINEESYNC"], "0")
    }

    // MARK: - DXMT

    /// F14 (bug-sweep) encoded as a permanent guard: a prefix-wide `WINEDLLOVERRIDES` here used to
    /// leak Steam's own launch environment onto every `-applaunch` game after it — including onto
    /// bottles it doesn't even own, since Steam's environment is inherited wholesale. DXMT is
    /// applied per-executable elsewhere (`AppModel.installGraphicsDriver`); this function must
    /// never reintroduce a global override no matter what else changes.
    func testDxmtNeverSetsAPrefixWideDllOverride() {
        for backend in GraphicsBackend.allCases {
            var settings = BottleSettings()
            settings.graphics = backend

            let env = settings.derivedEnvironment

            XCTAssertNil(env["WINEDLLOVERRIDES"], "\(backend) must not set a prefix-wide override")
        }
    }

    func testDxmtBaselineConfigWithMetalFXOff() {
        var settings = BottleSettings()
        settings.graphics = .dxmt
        settings.metalFX = false

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["DXMT_SHADER_CACHE"], "1")
        XCTAssertNil(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"])
        // Pinned key-by-key, not just "contains" — a key silently dropped from this list is
        // exactly the class of regression that shipped for three weeks (sampleNaNToZero,
        // defuseFma) before anyone noticed.
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60;"
                       + "d3d11.ignoreMapFlagNoWait=True;d3d11.sampleNaNToZero=True;"
                       + "d3d11.defuseFma=True")
    }

    func testDxmtWithMetalFXOnAppendsTheUpscaleFactor() {
        var settings = BottleSettings()
        settings.graphics = .dxmt
        settings.metalFX = true
        settings.metalFXFactor = 1.5

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60;"
                       + "d3d11.ignoreMapFlagNoWait=True;d3d11.sampleNaNToZero=True;"
                       + "d3d11.defuseFma=True;d3d11.metalSpatialUpscaleFactor=1.5")
    }

    func testDxmtMetalFXFactorIsFormattedToOneDecimalPlace() {
        var settings = BottleSettings()
        settings.graphics = .dxmt
        settings.metalFX = true
        settings.metalFXFactor = 2.0

        let env = settings.derivedEnvironment

        XCTAssertTrue(env["DXMT_CONFIG"]!.hasSuffix("d3d11.metalSpatialUpscaleFactor=2.0"))
    }

    // MARK: - DXVK

    func testDxvkHudOffSetsNothing() {
        var settings = BottleSettings()
        settings.graphics = .dxvk
        settings.dxvkHUD = false

        let env = settings.derivedEnvironment

        XCTAssertNil(env["DXVK_HUD"])
    }

    func testDxvkHudOnSetsTheFullOverlay() {
        var settings = BottleSettings()
        settings.graphics = .dxvk
        settings.dxvkHUD = true

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["DXVK_HUD"], "fps,frametimes,gpuload")
    }

    // MARK: - D3DMetal

    func testD3DMetalWithMetalFXOff() {
        var settings = BottleSettings()
        settings.graphics = .d3dmetal
        settings.metalFX = false

        let env = settings.derivedEnvironment

        XCTAssertNil(env["D3DM_ENABLE_METALFX"])
    }

    func testD3DMetalWithMetalFXOn() {
        var settings = BottleSettings()
        settings.graphics = .d3dmetal
        settings.metalFX = true

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["D3DM_ENABLE_METALFX"], "1")
    }

    // MARK: - WineD3D

    /// F14's fix for this specific backend: no per-prefix override lever at all any more —
    /// `installGraphicsDriver` writes a per-exe "builtin" registry override instead. This function
    /// must contribute nothing here.
    func testWineD3DAddsNoExtraKeys() {
        var settings = BottleSettings()
        settings.graphics = .wined3d
        settings.metalFX = true      // irrelevant to this backend — must not leak in either
        settings.dxvkHUD = true

        let env = settings.derivedEnvironment

        XCTAssertNil(env["D3DM_ENABLE_METALFX"])
        XCTAssertNil(env["DXVK_HUD"])
        XCTAssertNil(env["DXMT_SHADER_CACHE"])
        XCTAssertNil(env["DXMT_CONFIG"])
    }

    // MARK: - HUD / AVX flags (backend-independent)

    func testMetalHUDAndAdvertiseAVXAreAlwaysSetRegardlessOfBackend() {
        var settings = BottleSettings()
        settings.graphics = .wined3d   // the backend with no other env contribution
        settings.metalHUD = true
        settings.advertiseAVX = false

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "0")
    }

    // MARK: - User overrides

    /// The last line of `derivedEnvironment` layers the user's own `environment` dictionary on
    /// top of everything computed above. Must win even against a key this function derives itself.
    func testUserEnvironmentOverridesWinOverDerivedKeys() {
        var settings = BottleSettings()
        settings.syncMode = .msync
        settings.environment = ["WINEMSYNC": "custom-override"]

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["WINEMSYNC"], "custom-override")
    }

    func testUserEnvironmentAddsNewKeysNotDerivedAtAll() {
        var settings = BottleSettings()
        settings.environment = ["MY_CUSTOM_VAR": "hello"]

        let env = settings.derivedEnvironment

        XCTAssertEqual(env["MY_CUSTOM_VAR"], "hello")
    }
}
