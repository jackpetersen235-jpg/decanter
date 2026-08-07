import Foundation

/// Finds installed Windows games inside a Wine prefix's `drive_c`.
///
/// Exists so that turning an installed game into its own bottle is a click rather than a research
/// task. Before this, a per-game bottle meant knowing the Steam app id or the exact path to the
/// shipping binary and typing one of them into Configuration by hand.
///
/// Scanning is deliberately shallow and bounded. A `drive_c` with a Steam library in it holds
/// hundreds of thousands of files, so this walks a fixed set of roots two levels deep rather than
/// enumerating the tree.
enum GameScanner {

    struct FoundGame: Identifiable, Hashable {
        /// The executable path — unique per game and stable across scans.
        var id: String { executable.path }
        let name: String
        let folder: URL
        let executable: URL
        let sizeBytes: Int
        /// Present only for Steam titles, read from the appmanifest.
        let appID: String?
        /// The prefix this game lives in, so a new bottle can point at the right one.
        let prefix: URL

        var displaySize: String {
            ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        }
    }

    // MARK: Exclusions

    /// Steam app ids that appear in `steamapps` but are not games.
    ///
    /// 228980 is "Steamworks Common Redistributables", installed beside almost every title. It has
    /// its own folder and a 187 MB `VC_redist.x64.exe`, so a size-based filter does not catch it —
    /// it listed as a game in the picker, twice, until named here. Shared with
    /// `AppModel.resolvedGame`, where the same id made a one-game prefix look ambiguous.
    static let nonGameAppIDs: Set<String> = [
        "228980",                                    // Steamworks Common Redistributables
        "1070560", "1391110", "1628350",             // Steam Linux Runtime
        "858280", "961940",                          // Proton
    ]

    /// Folders under `Program Files*` that are Windows itself, not games.
    private static let systemFolders: Set<String> = [
        "windows", "windows nt", "common files", "internet explorer", "windows defender",
        "windows mail", "windows media player", "windows photo viewer", "windows portable devices",
        "windowspowershell", "modifiablewindowsapps", "uninstall information", "msbuild",
        "reference assemblies", "microsoft", "microsoft.net", "dotnet", "application verifier",
        "steam",            // the CLIENT dir; steamapps/common is scanned separately
    ]

    /// Executables that ship beside games but are not the game.
    private static let noiseExecutables: [String] = [
        "unins", "setup", "vcredist", "dxsetup", "prereq", "redist", "dotnet", "oalinst",
        "crashreport", "crashpad", "launcher_installer", "directx", "installer", "uninstall",
        "reporter", "helper", "handler", "vc_redist", "ueprereqsetup", "easyanticheat",
    ]

    private static func isNoise(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return noiseExecutables.contains { n.contains($0) }
    }

    // MARK: Executable selection

    /// The largest `.exe` in a game folder, searched a bounded distance down.
    ///
    /// Shared with `AppModel.resolvedGame` so the picker and the launcher builder can never
    /// disagree about which binary a game means. Unreal titles ship a small shim at the top level
    /// beside the real one — Half Sword's is a 0.3 MB stub next to a 300 MB
    /// `Binaries/Win64/…-Shipping.exe` — so a top-level-only search picks wrong.
    static func largestExecutable(in folder: URL, fileLimit: Int = 4000) -> URL? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: keys).fileSize) ?? 0 }

        var candidates: [URL] = []
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var scanned = 0
            for case let u as URL in e {
                scanned += 1
                if scanned > fileLimit { break }
                if u.pathExtension.lowercased() == "exe" { candidates.append(u) }
            }
        }
        let real = candidates.filter { !isNoise($0) }
        return (real.isEmpty ? candidates : real).max(by: { size($0) < size($1) })
    }

    // MARK: Scanning

    /// Every game found in one prefix.
    static func scan(prefix: URL, steamAppIDs: [String: String] = [:]) -> [FoundGame] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var results: [FoundGame] = []
        var seenFolders = Set<String>()

        // 1. Steam libraries — these carry real titles and app ids in their manifests.
        let steamApps = driveC
            .appendingPathComponent("Program Files (x86)/Steam/steamapps", isDirectory: true)
        let manifestNames = manifestIndex(at: steamApps)
        let common = steamApps.appendingPathComponent("common", isDirectory: true)
        for folder in subdirectories(of: common) {
            guard seenFolders.insert(folder.path).inserted else { continue }
            guard let exe = largestExecutable(in: folder) else { continue }
            let installDir = folder.lastPathComponent
            let match = manifestNames.first { $0.value.installDir == installDir }
            if let id = match?.key, nonGameAppIDs.contains(id) { continue }
            results.append(FoundGame(name: match?.value.name ?? installDir,
                                     folder: folder, executable: exe,
                                     sizeBytes: folderSize(folder),
                                     appID: match?.key, prefix: prefix))
        }

        // 2. Everything else a Windows installer might have used.
        let otherRoots = ["Program Files", "Program Files (x86)", "GOG Games", "Games",
                          "Epic Games", "Riot Games"]
        for root in otherRoots {
            let dir = driveC.appendingPathComponent(root, isDirectory: true)
            for folder in subdirectories(of: dir) {
                let lower = folder.lastPathComponent.lowercased()
                guard !systemFolders.contains(lower) else { continue }
                guard seenFolders.insert(folder.path).inserted else { continue }
                guard let exe = largestExecutable(in: folder, fileLimit: 1500) else { continue }
                // A game is not 2 MB. This is the main filter that keeps utilities and bundled
                // runtimes out of the list without needing to name every one of them.
                let bytes = folderSize(folder)
                guard bytes > 64 * 1024 * 1024 else { continue }
                results.append(FoundGame(name: folder.lastPathComponent, folder: folder,
                                         executable: exe, sizeBytes: bytes,
                                         appID: nil, prefix: prefix))
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helpers

    private static func subdirectories(of url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: keys))?.isDirectory == true }
    }

    /// appid -> (installdir, name), read from every `appmanifest_*.acf` in a steamapps folder.
    private static func manifestIndex(at steamApps: URL) -> [String: (installDir: String, name: String)] {
        var out: [String: (String, String)] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: steamApps.path)) ?? []
        for file in names where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
            let id = file.replacingOccurrences(of: "appmanifest_", with: "")
                .replacingOccurrences(of: ".acf", with: "")
            guard let text = try? String(contentsOf: steamApps.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            let installDir = value("installdir", in: text) ?? ""
            let name = value("name", in: text) ?? installDir
            if !installDir.isEmpty { out[id] = (installDir, name) }
        }
        return out
    }

    private static func value(_ key: String, in text: String) -> String? {
        let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Approximate folder size. Bounded like everything else here — a full walk of a 24 GB Steam
    /// library per candidate would make the picker unusable.
    private static func folderSize(_ url: URL, fileLimit: Int = 3000) -> Int {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total = 0, scanned = 0
        for case let u as URL in e {
            scanned += 1
            if scanned > fileLimit { break }
            total += (try? u.resourceValues(forKeys: keys).fileSize) ?? 0
        }
        return total
    }
}
