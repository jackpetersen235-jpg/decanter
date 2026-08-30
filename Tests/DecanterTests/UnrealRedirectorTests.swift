import XCTest
@testable import Decanter

/// Covers `AppModel.unrealRedirectorTarget`, found during a settings-parity audit (2026-08-29):
/// standard Unreal Engine packaging ALWAYS creates both a tiny top-level `<Module>.exe`
/// redirector (what Steam actually launches) and the real, huge engine binary nested at
/// `<Module>/Binaries/Win64/<Module>-Win64-Shipping.exe`. `GameScanner.largestExecutable`
/// correctly finds the nested binary for game identification, but a per-exe graphics fix (DXMT
/// DLLs, registry overrides) has to target the redirector instead — confirmed live against Half
/// Sword, where the working DXMT install existed ONLY at the redirector, put there by hand.
///
/// Builds a real directory tree per test (no mocking `FileManager` — the function's only
/// dependency is real file existence, which is cheap and unambiguous to set up for real).
final class UnrealRedirectorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnrealRedirectorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// The exact shape found live: `Half Sword Demo/HalfSwordUE5.exe` (redirector) +
    /// `Half Sword Demo/HalfSwordUE5/Binaries/Win64/HalfSwordUE5-Win64-Shipping.exe` (real binary).
    func testFindsTheRedirectorForAStandardWin64Layout() throws {
        let gameRoot = root.appendingPathComponent("Half Sword Demo", isDirectory: true)
        let binariesDir = gameRoot.appendingPathComponent("HalfSwordUE5/Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: binariesDir, withIntermediateDirectories: true)
        try "redirector".write(to: gameRoot.appendingPathComponent("HalfSwordUE5.exe"),
                               atomically: true, encoding: .utf8)

        let result = AppModel.unrealRedirectorTarget(
            for: (folder: binariesDir, exe: "HalfSwordUE5-Win64-Shipping.exe"))

        XCTAssertEqual(result?.exe, "HalfSwordUE5.exe")
        XCTAssertEqual(result?.folder.standardizedFileURL, gameRoot.standardizedFileURL)
    }

    func testAlsoMatchesWin32() throws {
        let gameRoot = root.appendingPathComponent("Some Game", isDirectory: true)
        let binariesDir = gameRoot.appendingPathComponent("SomeGame/Binaries/Win32", isDirectory: true)
        try FileManager.default.createDirectory(at: binariesDir, withIntermediateDirectories: true)
        try "redirector".write(to: gameRoot.appendingPathComponent("SomeGame.exe"),
                               atomically: true, encoding: .utf8)

        let result = AppModel.unrealRedirectorTarget(
            for: (folder: binariesDir, exe: "SomeGame-Win32-Shipping.exe"))

        XCTAssertEqual(result?.exe, "SomeGame.exe")
    }

    /// The redirector must actually EXIST — a game that merely happens to share the folder
    /// shape (unlikely, but not impossible) must not get a fabricated install target.
    func testReturnsNilWhenTheRedirectorDoesNotExist() throws {
        let gameRoot = root.appendingPathComponent("Half Sword Demo", isDirectory: true)
        let binariesDir = gameRoot.appendingPathComponent("HalfSwordUE5/Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: binariesDir, withIntermediateDirectories: true)
        // Deliberately NOT creating HalfSwordUE5.exe at gameRoot.

        let result = AppModel.unrealRedirectorTarget(
            for: (folder: binariesDir, exe: "HalfSwordUE5-Win64-Shipping.exe"))

        XCTAssertNil(result)
    }

    /// A game that isn't packaged this way (Sekiro: sekiro.exe sits directly in its own folder,
    /// no Binaries/Win64 nesting) must not match at all.
    func testReturnsNilForANonUnrealLayout() throws {
        let gameRoot = root.appendingPathComponent("Sekiro", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)

        let result = AppModel.unrealRedirectorTarget(for: (folder: gameRoot, exe: "sekiro.exe"))

        XCTAssertNil(result)
    }

    /// A folder literally named "win64" that isn't inside a "Binaries" folder must not match —
    /// the check requires BOTH path segments, not just the platform name.
    func testRequiresTheBinariesParentFolderToo() throws {
        let gameRoot = root.appendingPathComponent("Some Game", isDirectory: true)
        let notBinaries = gameRoot.appendingPathComponent("SomeGame/NotBinaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: notBinaries, withIntermediateDirectories: true)
        try "redirector".write(to: gameRoot.appendingPathComponent("SomeGame.exe"),
                               atomically: true, encoding: .utf8)

        let result = AppModel.unrealRedirectorTarget(
            for: (folder: notBinaries, exe: "SomeGame-Win64-Shipping.exe"))

        XCTAssertNil(result)
    }
}
