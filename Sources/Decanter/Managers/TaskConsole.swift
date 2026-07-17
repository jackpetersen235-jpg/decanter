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

    func append(_ chunk: String) {
        let trimmed = chunk.hasSuffix("\n") ? String(chunk.dropLast()) : chunk
        guard !trimmed.isEmpty else { return }
        text += trimmed + "\n"
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
