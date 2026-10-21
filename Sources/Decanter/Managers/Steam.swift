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
    /// Split a user-entered argument string into argv entries, honouring quotes.
    ///
    /// A plain `split(separator: " ")` breaks any argument containing a space — e.g.
    /// `-foo "C:\Program Files\thing.exe"` became `-foo`, `"C:\Program`, `Files\thing.exe"`,
    /// which Steam then rejects. Quoted runs (single or double) are kept intact, the quotes are
    /// stripped, and runs of any whitespace (not just literal spaces) separate arguments.
    static func launchArguments(from raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var started = false          // distinguishes an empty quoted arg ("") from no arg at all
        var quote: Character?

        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                started = true
            } else if ch.isWhitespace {
                if started { args.append(current); current = ""; started = false }
            } else {
                current.append(ch)
                started = true
            }
        }
        if started { args.append(current) }
        return args
    }

    // MARK: - Logon state

    /// The connection state Steam most recently recorded in `logs/connection_log.txt`, considering
    /// only lines stamped at or after `since` (nil = all lines): "Logged On", "Logging On",
    /// "Connecting", "Logged Off", …
    ///
    /// Every state-bearing line has the shape `[2026-10-21 09:10:25] [Logged On, 4, 7] …`; lines
    /// without the bracketed state (connectivity tests, update checks) are skipped. Timestamps are
    /// local time. `since` exists because a client killed with `wineserver -k` never writes a
    /// logoff line: the previous session's last word is often "Logged On", and for the first few
    /// seconds after a fresh start that stale line would otherwise read as "already logged in".
    static func latestLogonState(connectionLog: String, since: Date?) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for line in connectionLog.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix("["),
                  let close = line.firstIndex(of: "]"),
                  case let rest = line[line.index(after: close)...],
                  rest.hasPrefix(" ["),
                  let comma = rest.firstIndex(of: ",")
            else { continue }
            let state = rest[rest.index(rest.startIndex, offsetBy: 2)..<comma]
            guard !state.isEmpty, state.allSatisfy({ $0.isLetter || $0 == " " }) else { continue }
            if let since {
                guard let stamp = formatter.date(from: String(line[line.index(after: line.startIndex)..<close])),
                      stamp >= since
                else { return nil }   // reached lines older than `since` — nothing newer exists
            }
            return String(state)
        }
        return nil
    }

    /// True when Steam's latest recorded state (since `since`) is "Logged On".
    static func isLoggedOn(connectionLog: String, since: Date?) -> Bool {
        latestLogonState(connectionLog: connectionLog, since: since) == "Logged On"
    }

    /// The start time from a `ps -o lstart=` field, e.g. "Wed Oct 21 09:09:16 2026" (single-digit
    /// days are space-padded: "Wed Oct  1 …"). Expects the C locale — callers run `ps` with
    /// `LC_ALL=C` so a non-English Mac doesn't localize the day and month names.
    static func processStartDate(lstart: String) -> Date? {
        let collapsed = lstart.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: collapsed)
    }

    /// True when a process's `ps -o comm=` (its executable, not its arguments) is a Steam client.
    ///
    /// The EXECUTABLE, because arguments lie in both directions: webhelpers carry
    /// `-steampath=…\steam.exe`, and a Wine launch of Steam that hung before it became Steam is
    /// `…/bin/wine …/Steam/steam.exe` — found live 2026-10-21, where counting it as a running Steam
    /// produced a false "[DEC-E09] Steam is still running" and skipped Play's sign-in wait. Split
    /// on both separators: Wine reports some executables as Windows paths.
    static func isClient(comm: String) -> Bool {
        let name = comm.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(comm)
        return name.lowercased() == "steam.exe"
    }

    /// When the Steam client at `steamExecutable` started, from `ps -Ao lstart=,command=` output
    /// (run with `LC_ALL=C`), or nil if it isn't running. Only a line whose command BEGINS with
    /// that path is the client — a hung `…/bin/wine <path>` launch merely mentions it.
    static func clientStartDate(ps: String, steamExecutable: String) -> Date? {
        for line in ps.split(separator: "\n") {
            // lstart is a fixed 24-character field: "Wed Oct 21 09:09:16 2026".
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.count > 24 else { continue }
            let command = trimmed.dropFirst(24).drop(while: { $0 == " " })
            if command.hasPrefix(steamExecutable),
               let date = processStartDate(lstart: String(trimmed.prefix(24))) {
                return date
            }
        }
        return nil
    }
}
