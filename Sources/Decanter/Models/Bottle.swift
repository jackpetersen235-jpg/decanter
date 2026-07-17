import Foundation

/// A single Wine prefix plus its configuration — the "bottle".
struct Bottle: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String

    /// The WINEPREFIX directory (contains `drive_c`, `system.reg`, …).
    var url: URL

    /// `bin` directory of the Wine build used to create/run this bottle.
    var wineBinDirectory: URL?

    var settings: BottleSettings = BottleSettings()
    var createdAt: Date = Date()

    /// Set once `wineboot` has successfully initialized the prefix.
    var isInitialized: Bool = false

    // MARK: Derived paths

    var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }

    /// Conventional Steam install location inside the prefix.
    var steamExecutable: URL {
        driveC
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steam.exe")
    }

    var isSteamInstalled: Bool {
        FileManager.default.fileExists(atPath: steamExecutable.path)
    }

    // MARK: Hashable / Equatable by identity

    static func == (lhs: Bottle, rhs: Bottle) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
