import XCTest
@testable import Decanter

/// Characterization tests for `Wine.environment(for:using:)` — Phase 2 of the hardening plan
/// ("Prove the chokepoints"). Every launch and every registry write in the app draws its
/// environment from this one function (12 call sites at the time this was written), and Steam's
/// own environment is inherited by every `-applaunch` game after it — that inheritance is exactly
/// how F14 leaked a prefix-wide `WINEDLLOVERRIDES` onto a sibling bottle's game. Before this, it
/// had zero direct tests.
///
/// Purely value-type input (`Bottle`, `WineInstallation`) plus one real side effect — it creates
/// the bottle's shader-cache directory — so every test here runs against a scratch `DECANTER_HOME`,
/// same pattern as `PathsTests`: mutate/restore the real process environment, never touch the real
/// ~68–98 GB install.
final class WineEnvironmentTests: XCTestCase {
    private var scratchHome: URL!

    override func setUp() {
        super.setUp()
        scratchHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("WineEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        setenv("DECANTER_HOME", scratchHome.path, 1)
    }

    override func tearDown() {
        unsetenv("DECANTER_HOME")
        try? FileManager.default.removeItem(at: scratchHome)
        scratchHome = nil
        super.tearDown()
    }

    private func makeBottle(settings: BottleSettings = BottleSettings()) -> Bottle {
        Bottle(name: "Test Bottle",
               url: scratchHome.appendingPathComponent("Bottles/Test", isDirectory: true),
               settings: settings)
    }

    private func makeInstallation(bin: URL, supportsFastSync: Bool = true) -> WineInstallation {
        var install = WineInstallation(binDirectory: bin, name: "Test Wine")
        install.supportsFastSync = supportsFastSync
        return install
    }

    // MARK: - Prefix identity

    func testSetsWineprefixLoaderAndWineserverForANonCrossOverBuild() {
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let bottle = makeBottle()
        let install = makeInstallation(bin: bin)

        let env = Wine.environment(for: bottle, using: install)

        XCTAssertEqual(env["WINEPREFIX"], bottle.url.path)
        XCTAssertEqual(env["WINELOADER"], install.loader.path)
        XCTAssertEqual(env["WINESERVER"], install.wineserver.path)
        XCTAssertNil(env["CX_ROOT"])
        XCTAssertNil(env["CX_BOTTLE"])
    }

    /// CrossOver's wine resolves bottles by NAME (`CX_BOTTLE`) rather than `WINEPREFIX` — it's a
    /// wrapper binary, not a plain wine loader. `WINEPREFIX` is still set as a harmless fallback,
    /// but `WINELOADER`/`WINESERVER` are deliberately NOT — CrossOver's wrapper resolves those
    /// itself and doesn't want them pinned to a specific loader path.
    func testCrossOverBuildsUseCXBottleInsteadOfWineloader() {
        let bin = URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin")
        let bottle = makeBottle()
        let install = makeInstallation(bin: bin)
        XCTAssertTrue(install.isCrossOver, "fixture must actually exercise the CrossOver branch")

        let env = Wine.environment(for: bottle, using: install)

        XCTAssertEqual(env["CX_ROOT"], bin.deletingLastPathComponent().path)
        XCTAssertEqual(env["CX_BOTTLE"], bottle.url.lastPathComponent)
        XCTAssertEqual(env["WINEPREFIX"], bottle.url.path)
        XCTAssertNil(env["WINELOADER"])
        XCTAssertNil(env["WINESERVER"])
    }

    // MARK: - PATH / DYLD

    func testPathPrependsTheInstallationsBinDirectory() {
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let env = Wine.environment(for: makeBottle(), using: makeInstallation(bin: bin))

        XCTAssertTrue(env["PATH"]?.hasPrefix(bin.path + ":") ?? false,
                      "PATH was: \(env["PATH"] ?? "nil")")
    }

    func testDyldFallbackLibraryPathIncludesLibDirectoryWhenItExists() throws {
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let lib = scratchHome.appendingPathComponent("Wine/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let env = Wine.environment(for: makeBottle(), using: makeInstallation(bin: bin))

        XCTAssertTrue(env["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix(lib.path + ":") ?? false,
                      "DYLD_FALLBACK_LIBRARY_PATH was: \(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "nil")")
    }

    func testDyldFallbackLibraryPathUntouchedWhenLibDirectoryIsMissing() {
        // No lib/ directory created alongside this bin/ — the installation is incomplete/bogus.
        let bin = scratchHome.appendingPathComponent("NoLib/bin", isDirectory: true)

        let env = Wine.environment(for: makeBottle(), using: makeInstallation(bin: bin))

        let value = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        XCTAssertFalse(value.contains(bin.deletingLastPathComponent().appendingPathComponent("lib").path))
    }

    // MARK: - Shader cache

    func testShaderCachePathIsSetAndTheDirectoryIsActuallyCreated() {
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let bottle = makeBottle()

        let env = Wine.environment(for: bottle, using: makeInstallation(bin: bin))

        let expected = Paths.shaderCache(for: bottle)
        XCTAssertEqual(env["DXMT_SHADER_CACHE_PATH"], expected.path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Verbose logging

    func testVerboseLoggingOffSuppressesWinedebug() {
        var settings = BottleSettings()
        settings.verboseLogging = false
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)

        let env = Wine.environment(for: makeBottle(settings: settings), using: makeInstallation(bin: bin))

        XCTAssertEqual(env["WINEDEBUG"], "-all")
    }

    func testVerboseLoggingOnEnablesWarningsAndFixmes() {
        var settings = BottleSettings()
        settings.verboseLogging = true
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)

        let env = Wine.environment(for: makeBottle(settings: settings), using: makeInstallation(bin: bin))

        XCTAssertEqual(env["WINEDEBUG"], "warn+all,fixme-all")
    }

    // MARK: - Fast-sync stripping

    /// `WineInstallation.supportsFastSync` is a probed, per-BUILD property (see its own doc
    /// comment: msync depends on the source tree, not the wine version). A build without the
    /// feature silently ignores `WINEMSYNC`/`WINEESYNC` at the Wine layer — this strips them
    /// entirely here instead, so they don't sit in the environment implying a guarantee the build
    /// can't keep.
    func testFastSyncVarsAreStrippedWhenTheBuildDoesNotSupportThem() {
        var settings = BottleSettings()
        settings.syncMode = .msync
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let install = makeInstallation(bin: bin, supportsFastSync: false)

        let env = Wine.environment(for: makeBottle(settings: settings), using: install)

        XCTAssertNil(env["WINEMSYNC"])
        XCTAssertNil(env["WINEESYNC"])
    }

    func testFastSyncVarsAreKeptWhenTheBuildSupportsThem() {
        var settings = BottleSettings()
        settings.syncMode = .msync
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let install = makeInstallation(bin: bin, supportsFastSync: true)

        let env = Wine.environment(for: makeBottle(settings: settings), using: install)

        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEESYNC"], "1")
    }

    /// Stripping happens AFTER `derivedEnvironment` is merged in — so even a user-supplied
    /// `WINEMSYNC` override (via `BottleSettings.environment`) gets removed on a build that can't
    /// honour it. Pinned because it's the kind of ordering detail nobody would guess from reading
    /// the two functions in isolation.
    func testFastSyncStrippingAlsoRemovesAUserSuppliedOverride() {
        var settings = BottleSettings()
        settings.syncMode = .msync
        settings.environment = ["WINEMSYNC": "user-forced-on"]
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)
        let install = makeInstallation(bin: bin, supportsFastSync: false)

        let env = Wine.environment(for: makeBottle(settings: settings), using: install)

        XCTAssertNil(env["WINEMSYNC"])
    }

    // MARK: - derivedEnvironment actually flows through

    /// Proves the merge point itself, not just `derivedEnvironment` in isolation (covered
    /// separately in `BottleSettingsEnvironmentTests`) — a graphics-backend setting must be
    /// visible in the FINAL environment `Wine.environment` hands back.
    func testGraphicsBackendSettingsFlowThroughIntoTheFinalEnvironment() {
        var settings = BottleSettings()
        settings.graphics = .dxvk
        settings.dxvkHUD = true
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)

        let env = Wine.environment(for: makeBottle(settings: settings), using: makeInstallation(bin: bin))

        XCTAssertEqual(env["DXVK_HUD"], "fps,frametimes,gpuload")
    }

    // MARK: - User overrides

    /// The user's own `environment` dictionary is merged in via `derivedEnvironment`'s own
    /// last-line override — which runs AFTER `Wine.environment` has already set `WINEPREFIX`,
    /// `PATH`, etc. above. That means a user override can clobber even those, not just the
    /// settings-derived keys. Documented here as existing behaviour, not proposed as correct.
    func testUserEnvironmentOverrideCanClobberEvenWineprefix() {
        var settings = BottleSettings()
        settings.environment = ["WINEPREFIX": "/not/the/real/prefix"]
        let bin = scratchHome.appendingPathComponent("Wine/bin", isDirectory: true)

        let env = Wine.environment(for: makeBottle(settings: settings), using: makeInstallation(bin: bin))

        XCTAssertEqual(env["WINEPREFIX"], "/not/the/real/prefix")
    }
}
