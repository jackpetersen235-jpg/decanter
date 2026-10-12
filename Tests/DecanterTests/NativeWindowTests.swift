import XCTest
@testable import Decanter

/// The pure pieces of "Real game window" (`BottleSettings.nativeWindow`): the size Sekiro must
/// render at so native fullscreen has no black bars, the Sekiro config rewrite, and the
/// environment handed to "Decanter Game.app". The launch itself (LaunchServices, Wine) is
/// verified live — see GAMING-STACK.md §7b.
final class NativeWindowTests: XCTestCase {

    // MARK: - fullscreenContentSize

    /// Measured on this MacBook Air: a 1470×956-point screen whose native-fullscreen windows are
    /// 1470×923 — the notch's height comes off the top.
    func testNotchedScreenLosesTheNotchHeight() {
        let size = NativeWindow.fullscreenContentSize(screenSize: CGSize(width: 1470, height: 956),
                                                      topInset: 33)
        XCTAssertEqual(size, CGSize(width: 1470, height: 923))
    }

    func testScreenWithoutANotchUsesTheWholeScreen() {
        let size = NativeWindow.fullscreenContentSize(screenSize: CGSize(width: 1920, height: 1080),
                                                      topInset: 0)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
    }

    /// Sekiro takes integer pixel sizes; a fractional height must round DOWN so the rendered frame
    /// never exceeds the space it has to fit in.
    func testFractionalSizesRoundDown() {
        let size = NativeWindow.fullscreenContentSize(screenSize: CGSize(width: 1512.5, height: 982.9),
                                                      topInset: 32.4)
        XCTAssertEqual(size, CGSize(width: 1512, height: 950))
    }

    /// Measured: notch reported as 32, menu-bar strip 33, fullscreen windows start at y = 33.
    func testNotchedScreenUsesTheMenuBarHeightNotTheNotchHeight() {
        XCTAssertEqual(NativeWindow.fullscreenTopInset(notchHeight: 32, menuBarHeight: 33), 33)
    }

    /// With the menu bar set to auto-hide, visibleFrame no longer shows it — fall back to the notch.
    func testAutoHiddenMenuBarFallsBackToTheNotchHeight() {
        XCTAssertEqual(NativeWindow.fullscreenTopInset(notchHeight: 32, menuBarHeight: 0), 32)
    }

    /// Without a notch, fullscreen covers the menu bar entirely.
    func testNoNotchMeansNoInsetEvenWithAMenuBar() {
        XCTAssertEqual(NativeWindow.fullscreenTopInset(notchHeight: 0, menuBarHeight: 24), 0)
    }

    func testNegativeInsetIsIgnored() {
        let size = NativeWindow.fullscreenContentSize(screenSize: CGSize(width: 1470, height: 956),
                                                      topInset: -5)
        XCTAssertEqual(size.height, 956)
    }

    // MARK: - SekiroGraphicsConfig

    private let sampleConfig = """
        <?xml version="1.0" encoding="UTF-16"?>
        <config>
        <ScreenMode>FULLSCREEN</ScreenMode>
        <Resolution-WindowScreenWidth>1280</Resolution-WindowScreenWidth>
        <Resolution-WindowScreenHeight>720</Resolution-WindowScreenHeight>
        <Resolution-FullScreenWidth>1470</Resolution-FullScreenWidth>
        <Resolution-FullScreenHeight>956</Resolution-FullScreenHeight>
        <Auto-detectBestRenderingSettings>ON</Auto-detectBestRenderingSettings>
        <QualitySetting>MAX</QualitySetting>
        </config>
        """

    func testWindowedValuesSwitchModeAndSizeAndDisableAutoDetect() throws {
        let patched = try XCTUnwrap(SekiroGraphicsConfig.patched(
            sampleConfig, values: SekiroGraphicsConfig.windowedValues(width: 1470, height: 923)))

        XCTAssertTrue(patched.contains("<ScreenMode>WINDOW</ScreenMode>"))
        XCTAssertTrue(patched.contains("<Resolution-WindowScreenWidth>1470</Resolution-WindowScreenWidth>"))
        XCTAssertTrue(patched.contains("<Resolution-WindowScreenHeight>923</Resolution-WindowScreenHeight>"))
        XCTAssertTrue(patched.contains("<Auto-detectBestRenderingSettings>OFF</Auto-detectBestRenderingSettings>"))
    }

    /// Switching to windowed must leave the fullscreen values alone, so switching back to
    /// borderless later finds them as they were.
    func testWindowedPatchLeavesFullscreenValuesAndOtherSettingsAlone() throws {
        let patched = try XCTUnwrap(SekiroGraphicsConfig.patched(
            sampleConfig, values: SekiroGraphicsConfig.windowedValues(width: 1470, height: 923)))

        XCTAssertTrue(patched.contains("<Resolution-FullScreenWidth>1470</Resolution-FullScreenWidth>"))
        XCTAssertTrue(patched.contains("<Resolution-FullScreenHeight>956</Resolution-FullScreenHeight>"))
        XCTAssertTrue(patched.contains("<QualitySetting>MAX</QualitySetting>"))
    }

    /// nil means "already correct" — the caller skips the write entirely.
    func testReturnsNilWhenNothingWouldChange() throws {
        let values = SekiroGraphicsConfig.windowedValues(width: 1470, height: 923)
        let once = try XCTUnwrap(SekiroGraphicsConfig.patched(sampleConfig, values: values))
        XCTAssertNil(SekiroGraphicsConfig.patched(once, values: values))
    }

    /// The game decides the schema; a tag this version of the file doesn't have is not invented.
    func testMissingTagIsNotInvented() {
        let values = ["NotARealSekiroTag": "1"]
        XCTAssertNil(SekiroGraphicsConfig.patched(sampleConfig, values: values))
    }

    func testFullscreenValuesStillWorkForTheBorderlessMode() throws {
        let windowed = try XCTUnwrap(SekiroGraphicsConfig.patched(
            sampleConfig, values: SekiroGraphicsConfig.windowedValues(width: 1470, height: 923)))
        let back = try XCTUnwrap(SekiroGraphicsConfig.patched(
            windowed, values: SekiroGraphicsConfig.fullscreenValues(width: 1470, height: 956)))
        XCTAssertTrue(back.contains("<ScreenMode>FULLSCREEN</ScreenMode>"))
    }

    /// The real file is UTF-16LE with no BOM; a patch must survive that encoding unchanged.
    func testSurvivesAUTF16LittleEndianRoundTrip() throws {
        let data = try XCTUnwrap(sampleConfig.data(using: .utf16LittleEndian))
        let decoded = try XCTUnwrap(String(data: data, encoding: .utf16LittleEndian))
        let patched = try XCTUnwrap(SekiroGraphicsConfig.patched(
            decoded, values: SekiroGraphicsConfig.windowedValues(width: 1470, height: 923)))
        let reencoded = try XCTUnwrap(patched.data(using: .utf16LittleEndian))
        XCTAssertEqual(String(data: reencoded, encoding: .utf16LittleEndian), patched)
        XCTAssertNotEqual(reencoded.prefix(2), Data([0xFF, 0xFE]), "must not gain a BOM")
    }

    // MARK: - hostEnvironment

    private let base = [
        "WINEPREFIX": "/prefix",
        "DYLD_FALLBACK_LIBRARY_PATH": "/wine/lib:/usr/lib",
        "SteamAppId": "814380",
    ]

    func testDyldVariablesTravelRenamedAndTheHookIsInserted() {
        let env = NativeWindow.hostEnvironment(base: base, loader: "/wine/bin/wine",
                                               workingDirectory: "/games/Sekiro",
                                               windowHook: "/hook.dylib")

        XCTAssertEqual(env["DECANTER_HOST_DYLD_INSERT_LIBRARIES"], "/hook.dylib")
        XCTAssertEqual(env["DECANTER_HOST_DYLD_FALLBACK_LIBRARY_PATH"], "/wine/lib:/usr/lib")
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("DYLD_") }.isEmpty,
                      "no DYLD_* may travel under its real name")
    }

    func testLoaderWorkingDirectoryAndTheRestOfTheEnvironmentPassThrough() {
        let env = NativeWindow.hostEnvironment(base: base, loader: "/wine/bin/wine",
                                               workingDirectory: "/games/Sekiro",
                                               windowHook: "/hook.dylib")

        XCTAssertEqual(env["DECANTER_HOST_EXEC"], "/wine/bin/wine")
        XCTAssertEqual(env["DECANTER_HOST_CWD"], "/games/Sekiro")
        XCTAssertEqual(env["WINEPREFIX"], "/prefix")
        XCTAssertEqual(env["SteamAppId"], "814380")
    }

    func testDiagnosticExtraLibraryIsAppendedAfterTheHookAndNotForwarded() {
        var withExtra = base
        withExtra[NativeWindow.extraInsertVariable] = "/framestat.dylib"
        let env = NativeWindow.hostEnvironment(base: withExtra, loader: "/wine", workingDirectory: nil,
                                               windowHook: "/hook.dylib")

        XCTAssertEqual(env["DECANTER_HOST_DYLD_INSERT_LIBRARIES"], "/hook.dylib:/framestat.dylib")
        XCTAssertNil(env[NativeWindow.extraInsertVariable])
    }

    func testNoHookAndNoExtraMeansNothingInserted() {
        let env = NativeWindow.hostEnvironment(base: base, loader: "/wine", workingDirectory: nil,
                                               windowHook: nil)
        XCTAssertNil(env["DECANTER_HOST_DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["DECANTER_HOST_CWD"])
    }

    // MARK: - installGameHost

    /// Builds a fake game-host bundle with the two files that define its identity.
    private func makeHostBundle(at url: URL, executable: String, plist: String = "<plist/>") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"),
                               withIntermediateDirectories: true)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try executable.write(to: url.appendingPathComponent("Contents/MacOS/decanter-game-host"),
                             atomically: true, encoding: .utf8)
    }

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInstallsTheHostWhenItIsMissing() throws {
        let dir = try scratchDirectory()
        let template = dir.appendingPathComponent("Template/Decanter Game.app")
        let destination = dir.appendingPathComponent("Support/Decanter Game.app")
        try makeHostBundle(at: template, executable: "v1")

        try NativeWindow.installGameHost(template: template, destination: destination)

        XCTAssertFalse(NativeWindow.gameHostNeedsInstall(template: template, destination: destination))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(
            "Contents/MacOS/decanter-game-host"), encoding: .utf8), "v1")
    }

    /// A Decanter update ships a new host; the installed copy must not keep running the old one.
    func testReplacesAnOutdatedInstall() throws {
        let dir = try scratchDirectory()
        let template = dir.appendingPathComponent("Template/Decanter Game.app")
        let destination = dir.appendingPathComponent("Support/Decanter Game.app")
        try makeHostBundle(at: destination, executable: "old")
        try makeHostBundle(at: template, executable: "new")

        XCTAssertTrue(NativeWindow.gameHostNeedsInstall(template: template, destination: destination))
        try NativeWindow.installGameHost(template: template, destination: destination)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(
            "Contents/MacOS/decanter-game-host"), encoding: .utf8), "new")
    }

    /// Up to date means untouched — no copy on every launch.
    func testLeavesAnUpToDateInstallAlone() throws {
        let dir = try scratchDirectory()
        let template = dir.appendingPathComponent("Template/Decanter Game.app")
        let destination = dir.appendingPathComponent("Support/Decanter Game.app")
        try makeHostBundle(at: template, executable: "same")
        try makeHostBundle(at: destination, executable: "same")
        let marker = destination.appendingPathComponent("Contents/marker")
        try "kept".write(to: marker, atomically: true, encoding: .utf8)

        try NativeWindow.installGameHost(template: template, destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "an up-to-date install was recopied")
    }

    func testNoStagingCopyIsLeftBehind() throws {
        let dir = try scratchDirectory()
        let template = dir.appendingPathComponent("Template/Decanter Game.app")
        let destination = dir.appendingPathComponent("Support/Decanter Game.app")
        try makeHostBundle(at: template, executable: "v1")
        try makeHostBundle(at: destination, executable: "v0")

        try NativeWindow.installGameHost(template: template, destination: destination)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Support").path)
        XCTAssertEqual(leftovers, ["Decanter Game.app"])
    }

    // MARK: - BottleSettings

    /// A bottles.json written before this setting existed must still decode — the custom
    /// decoder exists precisely because missing keys broke bottle loading twice before.
    func testOlderBottleWithoutTheKeyDecodesWithItOff() throws {
        let json = #"{"graphics":"dxmt","borderlessFullscreen":true}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(BottleSettings.self, from: json)
        XCTAssertFalse(settings.nativeWindow)
        XCTAssertTrue(settings.borderlessFullscreen)
    }

    func testNativeWindowRoundTripsThroughJSON() throws {
        var settings = BottleSettings()
        settings.nativeWindow = true
        let decoded = try JSONDecoder().decode(BottleSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.nativeWindow)
    }
}
