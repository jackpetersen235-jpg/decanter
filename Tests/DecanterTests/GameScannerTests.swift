import XCTest
@testable import Decanter

/// `GameScanner` walks game folders under a budget. Found live 2026-10-27: Resident Evil HD
/// REMASTER (app 304240) never showed up in New Bottle. Its folder holds `bhd.exe` at the top and
/// 5,339 entries in `nativePC/`, which the directory listing returns FIRST, so a depth-first walk
/// spent its 4,000-entry budget inside `nativePC/`, never reached `bhd.exe`, found no executable,
/// and skipped the game without a word. The layouts below are that folder's and Half Sword's.
final class GameScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ relative: String, bytes: Int = 1, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// Resident Evil HD REMASTER's top level, real names, plus `count` data files in `nativePC/`.
    private func residentEvil(in base: URL, dataFiles count: Int) throws -> URL {
        let game = base.appendingPathComponent("Resident Evil Biohazard HD REMASTER")
        try file("bhd.exe", bytes: 9_000, in: game)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "steam_api.dll"] {
            try file(dll, bytes: 2_000, in: game)
        }
        for i in 0..<count { try file("nativePC/arc/data\(i).arc", in: game) }
        return game
    }

    func testFindsATopLevelExeBesideADataFolderBiggerThanTheBudget() throws {
        let game = try residentEvil(in: root, dataFiles: 150)
        XCTAssertEqual(GameScanner.largestExecutable(in: game, fileLimit: 100)?.lastPathComponent,
                       "bhd.exe")
    }

    /// Half Sword: a tiny shim at the top, the real binary four levels down. Must still win.
    func testUnrealShippingExeStillBeatsTheTopLevelShim() throws {
        let game = root.appendingPathComponent("Half Sword Demo")
        try file("HalfSwordUE5.exe", bytes: 300, in: game)
        try file("HalfSwordUE5/Binaries/Win64/HalfSwordUE5-Win64-Shipping.exe", bytes: 30_000, in: game)
        try file("Engine/Binaries/ThirdParty/DbgHelp/dbghelp.dll", bytes: 500, in: game)
        for i in 0..<40 { try file("HalfSwordUE5/Content/Paks/pak\(i).pak", in: game) }
        XCTAssertEqual(GameScanner.largestExecutable(in: game)?.lastPathComponent,
                       "HalfSwordUE5-Win64-Shipping.exe")
    }

    func testAnUninstallerIsNeverTheGameEvenWhenBigger() throws {
        let game = root.appendingPathComponent("Some Game")
        try file("game.exe", bytes: 1_000, in: game)
        try file("unins000.exe", bytes: 50_000, in: game)
        XCTAssertEqual(GameScanner.largestExecutable(in: game)?.lastPathComponent, "game.exe")
    }

    /// The user-facing failure: the whole New Bottle scan, real budget, real manifest.
    func testScanListsTheGameWhoseDataFolderExceedsTheDefaultBudget() throws {
        let prefix = root.appendingPathComponent("Steam-Wine11")
        let steamApps = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        _ = try residentEvil(in: steamApps.appendingPathComponent("common"), dataFiles: 4_100)
        try """
            "AppState"
            {
            \t"appid"\t\t"304240"
            \t"name"\t\t"Resident Evil"
            \t"StateFlags"\t\t"4"
            \t"installdir"\t\t"Resident Evil Biohazard HD REMASTER"
            }
            """.write(to: steamApps.appendingPathComponent("appmanifest_304240.acf"),
                      atomically: true, encoding: .utf8)

        let found = GameScanner.scan(prefix: prefix)
        let re = try XCTUnwrap(found.first { $0.appID == "304240" }, "Resident Evil not listed")
        XCTAssertEqual(re.name, "Resident Evil")
        XCTAssertEqual(re.executable.lastPathComponent, "bhd.exe")
    }
}
