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

    /// Fetch SteamSetup.exe if it isn't already cached. Reports 0...1 progress.
    static func downloadInstaller(progress: @escaping (Double) -> Void) async throws -> URL {
        let destination = installerDestination
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        Paths.ensureDirectories()
        let (bytes, response) = try await URLSession.shared.bytes(from: installerURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SteamError.badResponse(http.statusCode)
        }

        let total = response.expectedContentLength
        var data = Data()
        if total > 0 { data.reserveCapacity(Int(total)) }
        var received: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            received += 1
            if total > 0, received % 65_536 == 0 {
                let fraction = Double(received) / Double(total)
                await MainActor.run { progress(fraction) }
            }
        }
        try data.write(to: destination)
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
