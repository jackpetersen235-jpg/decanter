import Foundation

/// How far Steam's first-launch self-download has got, so Decanter can say "Steam is downloading
/// itself — 240 of 450 MB" instead of showing nothing for several minutes.
///
/// Steam never reports a percentage, but its `logs/bootstrap_log.txt` lists every package it
/// queues as `Add pending download: …/<name>_<bytes>`, and each package lands in `package/` under
/// that exact name. Done = what's on disk for those names; total = the sum of the listed sizes.
/// Only the latest startup counts: the log keeps every earlier run, and `package/` keeps old
/// versions too. Pure, so it's testable without Steam.
enum SteamBootstrapProgress {

    struct Package: Equatable {
        let name: String
        let bytes: Int64
    }

    static func pendingPackages(inLog log: String) -> [Package] {
        // `isNewline`, not "\n": Swift treats "\r\n" as ONE Character, so splitting on "\n" never
        // split Steam's (Windows) log at all and the whole file read as a single line.
        let lines = log.split(whereSeparator: \.isNewline)
        let start = (lines.lastIndex { $0.contains("Startup - ") }).map { $0 + 1 } ?? 0
        let marker = "Add pending download: "
        return lines[start...].compactMap { rawLine in
            // Steam writes Windows line endings; a stray \r on the size broke every package.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = line.range(of: marker) else { return nil }
            let name = String(line[range.upperBound...].split(separator: "/").last ?? "")
            guard let size = name.split(separator: "_").last.flatMap({ Int64($0) }) else { return nil }
            return Package(name: name, bytes: size)
        }
    }

    static func progress(of packages: [Package], sizeOnDisk: (String) -> Int64) -> (done: Int64, total: Int64) {
        packages.reduce((done: 0, total: 0)) { sum, package in
            (sum.done + min(sizeOnDisk(package.name), package.bytes), sum.total + package.bytes)
        }
    }
}
