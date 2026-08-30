import Foundation

/// Outcome of running a command to completion.
struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

/// A live, cancellable handle to a running process.
final class ProcessHandle {
    private let process: Process
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Thread-safe byte accumulator used while draining pipes.
private final class OutputCollector {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
}

/// Thread-safe "resume this continuation exactly once" gate, same shape as `OutputCollector`.
///
/// The deadline task and the natural `terminationHandler` in `Shell.run` can BOTH try to resume
/// the same checked continuation — killing a process still ends in a real exit, which fires
/// `terminationHandler` after the deadline task has already resumed with a timeout error.
/// Resuming a checked continuation twice is a crash, not a warning. A plain captured `var` here
/// would also trip Swift 6's strict-concurrency check, since it'd be mutated from two concurrent
/// closures — wrapping it in a class with its own lock, like `OutputCollector` above, sidesteps
/// both problems at once.
private final class ResumeGuard {
    private let lock = NSLock()
    private var done = false
    /// True the first time this is called; false on every call after.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Thrown by `Shell.run` when a process outlives its deadline.
struct ShellTimeoutError: LocalizedError {
    let command: String
    let seconds: TimeInterval
    var errorDescription: String? {
        "\(command) didn't exit within \(Int(seconds))s and was killed."
    }
}

/// Thin wrapper around `Process` for launching Wine and related tools.
enum Shell {

    /// Default grace period between SIGTERM and SIGKILL once a command outlives `timeout`.
    static let defaultKillGrace: TimeInterval = 3

    /// Run a command to completion, capturing all output. Suitable for short commands.
    ///
    /// F16 (bug-sweep): this used to have no timeout at all — its only resume path was
    /// `process.terminationHandler`, so a process that never exits hung the awaiting `Task`
    /// forever. Wedged Wine processes are a documented, recurring condition in this project (see
    /// F7), not a hypothetical: with 23 call sites across the app, one wedged `wine reg query`
    /// could freeze whatever UI action triggered it, indefinitely, with no way out but a force-quit.
    /// `timeout` defaults to something generous for a quick wine subprocess; call sites that
    /// legitimately run longer (tar extraction, the Steam installer) pass an explicit override.
    /// `killGrace` is injectable purely so tests can exercise the SIGKILL path and the near-deadline
    /// race without actually waiting out the production grace period — production call sites should
    /// never need to pass it.
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        killGrace: TimeInterval = defaultKillGrace
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let out = OutputCollector()
            let err = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

            let resumeGuard = ResumeGuard()

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // The termination handler can fire before the readability handlers have drained
                // everything, which truncates output. The write ends are closed now (process
                // exited), so read whatever remains — this can't block.
                if let rest = try? outPipe.fileHandleForReading.readToEnd() { out.append(rest) }
                if let rest = try? errPipe.fileHandleForReading.readToEnd() { err.append(rest) }
                guard resumeGuard.claim() else { return }
                continuation.resume(returning: CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: out.string,
                    stderr: err.string
                ))
            }

            do {
                try process.run()
            } catch {
                guard resumeGuard.claim() else { return }
                continuation.resume(throwing: error)
                return
            }

            let pid = process.processIdentifier
            let commandName = executable.lastPathComponent
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return }
                // Claim the continuation BEFORE sending any signal, not after killing. A process
                // that dies promptly from SIGTERM (plain `sleep`, unlike something that traps it)
                // can otherwise let the natural `terminationHandler` race ahead of this task's own
                // grace-period sleep and resolve the continuation as a "successful" signal-killed
                // CommandResult instead of a clear timeout error — found by the near-deadline test
                // in ShellTests.swift, not assumed.
                guard resumeGuard.claim() else { return }
                process.terminate()                              // SIGTERM — ask nicely first
                try? await Task.sleep(nanoseconds: UInt64(killGrace * 1_000_000_000))
                if process.isRunning { kill(pid, SIGKILL) }       // it didn't listen
                continuation.resume(throwing: ShellTimeoutError(command: commandName, seconds: timeout))
            }
        }
    }

    /// Launch a long-running command, streaming combined output line-chunks back on the
    /// main queue. Returns immediately with a handle you can use to terminate the process.
    @discardableResult
    static func stream(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { onOutput(text) }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            DispatchQueue.main.async { onExit(code) }
        }

        try process.run()
        return ProcessHandle(process)
    }
}
