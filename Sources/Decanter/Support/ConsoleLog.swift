import Foundation

/// Appends console output to a rolling log file on disk (`Paths.consoleLog`), so a crash or a
/// force-quit doesn't take the only record of what just happened with it.
///
/// Part of the pre-release debug plan's Phase 4 — every `TaskConsole` this app opens streamed
/// its text into memory only, and that text died with the window. A remote bug report was always
/// "it failed" with nothing behind it; this is what "Export Diagnostics" (AppModel) actually has
/// to attach. Called from `TaskConsole.append`, which is `@MainActor`, so calls here are already
/// serialized — no locking of our own needed.
enum ConsoleLog {
    /// Hard cap on the log file's size. Same shape as `TaskConsole`'s own in-memory trim
    /// (`maxCharacters`) — drop the oldest ~25% once exceeded, resynced to a line boundary so the
    /// file never starts mid-line.
    private static let maxBytes = 2_000_000

    /// Best-effort by design: a logging failure (disk full, permissions) must never interrupt the
    /// console operation that triggered it. Losing a log line is fine; blocking a launch over one
    /// is not.
    static func append(_ line: String, from title: String) {
        try? FileManager.default.createDirectory(at: Paths.logsRoot, withIntermediateDirectories: true)
        let timestamp = Self.formatter.string(from: Date())
        guard let data = "[\(timestamp)] [\(title)] \(line)\n".data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: Paths.consoleLog) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: Paths.consoleLog)
        }
        trimIfNeeded()
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: Paths.consoleLog.path)[.size] as? Int,
              size > maxBytes,
              let text = try? String(contentsOf: Paths.consoleLog, encoding: .utf8)
        else { return }
        let keepFrom = text.index(text.startIndex, offsetBy: max(0, text.count - (maxBytes * 3 / 4)))
        let tail = text[keepFrom...]
        let lineStart = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
        let trimmed = "… earlier log entries trimmed …\n" + String(tail[lineStart...])
        try? trimmed.write(to: Paths.consoleLog, atomically: true, encoding: .utf8)
    }
}
