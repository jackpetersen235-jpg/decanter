import Foundation

/// A live text log for one long-running operation (bottle boot, Steam install, a game
/// launch). Presented in a sheet; owns the process handle so it can be cancelled.
@MainActor
final class TaskConsole: ObservableObject, Identifiable {
    let id = UUID()
    let title: String

    @Published var text: String = ""
    @Published var isRunning: Bool = true

    /// Handle to the underlying process, when there is a single long-lived one.
    var handle: ProcessHandle?

    init(title: String) { self.title = title }

    /// Hard cap on retained log text. Without this, `text` grows without bound: a long-lived
    /// wine process with "Verbose Wine logging" on (`WINEDEBUG=warn+all,fixme-all`) emits a
    /// torrent of lines, and every append re-renders the SwiftUI view over an ever-larger string.
    /// Keeping the tail is what anyone actually reads — errors surface at the end.
    private static let maxCharacters = 200_000

    func append(_ chunk: String) {
        let trimmed = chunk.hasSuffix("\n") ? String(chunk.dropLast()) : chunk
        guard !trimmed.isEmpty else { return }
        text += trimmed + "\n"
        // Persist to disk too — see ConsoleLog's doc comment for why. Every line this app's
        // consoles ever show goes through here, so this is the one place to hook it.
        ConsoleLog.append(trimmed, from: title)
        if text.count > Self.maxCharacters {
            // Drop the oldest ~25% and resync to a line boundary so the view never shows a
            // half-line at the top.
            let cut = text.index(text.startIndex, offsetBy: text.count - (Self.maxCharacters * 3 / 4))
            let tail = text[cut...]
            let start = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
            text = "… earlier output trimmed …\n" + String(tail[start...])
        }
    }

    func finish(_ code: Int32? = nil) {
        isRunning = false
        if let code { append("— finished (exit \(code)) —") }
        else { append("— finished —") }
    }

    func cancel() {
        handle?.terminate()
        isRunning = false
        append("— cancelled —")
    }
}
