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

/// Thin wrapper around `Process` for launching Wine and related tools.
enum Shell {

    /// Run a command to completion, capturing all output. Suitable for short commands.
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
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

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: out.string,
                    stderr: err.string
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
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
