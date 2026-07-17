import Foundation

/// Downloads and installs the official Steam client into a bottle.
enum Steam {
    /// Valve's official Windows client installer.
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Where the downloaded installer is cached.
    static var installerDestination: URL {
        Paths.downloads.appendingPathComponent("SteamSetup.exe")
    }

    enum SteamError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Steam download failed (HTTP \(code))."
            }
        }
    }

    /// Fetch SteamSetup.exe if it isn't already cached.
    ///
    /// Uses a download task, not `URLSession.bytes`. Iterating an async byte sequence costs
    /// roughly 25x throughput (measured on a large file: 0.12 MB/s vs 3 MB/s) — see the note in
    /// WineInstaller.download.
    static func downloadInstaller(progress: @escaping (Double) -> Void) async throws -> URL {
        let destination = installerDestination
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        Paths.ensureDirectories()
        let (tempURL, response) = try await URLSession.shared.download(from: installerURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SteamError.badResponse(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        await MainActor.run { progress(1.0) }
        return destination
    }

    /// Arguments to run the installer silently inside a bottle.
    static func installArguments(installerPath: URL) -> [String] {
        [installerPath.path, "/S"]
    }

    /// Split a user-provided argument string into an argv array.
    static func launchArguments(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " }).map(String.init)
    }
}
