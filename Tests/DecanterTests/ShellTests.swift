import XCTest
@testable import Decanter

/// Covers F16 (bug-sweep): `Shell.run` used to have no timeout at all — its only resume path was
/// `process.terminationHandler`, so a process that never exits hung the awaiting `Task` forever.
/// None of this touches Wine or any bottle; `/bin/sleep` and `/bin/sh` are enough to reproduce a
/// hung/unkillable process safely.
final class ShellTests: XCTestCase {

    func testRunReturnsNormallyForAQuickProcess() async throws {
        let result = try await Shell.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    /// `killGrace` is overridden short here — production uses `Shell.defaultKillGrace` (3s), but
    /// these tests only need to prove the mechanism fires, not spend real wall-clock time on it.
    private let testGrace: TimeInterval = 0.05

    func testRunTimesOutOnAProcessThatNeverExits() async {
        let start = Date()
        do {
            _ = try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["99999"],
                                    timeout: 0.2, killGrace: testGrace)
            XCTFail("expected a timeout error")
        } catch is ShellTimeoutError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        } catch {
            XCTFail("expected ShellTimeoutError, got \(error)")
        }
    }

    func testRunSigkillsAProcessThatIgnoresSigterm() async {
        let start = Date()
        do {
            _ = try await Shell.run(URL(fileURLWithPath: "/bin/sh"),
                                    arguments: ["-c", "trap '' TERM; sleep 99999"],
                                    timeout: 0.2, killGrace: testGrace)
            XCTFail("expected a timeout error")
        } catch is ShellTimeoutError {
            // Proves the SIGKILL escalation actually ran: a plain SIGTERM would never have
            // stopped this process, so completing at all (let alone within the grace window)
            // means the fallback fired.
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        } catch {
            XCTFail("expected ShellTimeoutError, got \(error)")
        }
    }

    /// The race that finds a double-resume: a process that exits at almost exactly the deadline,
    /// so the natural `terminationHandler` and the deadline task both have a real chance to reach
    /// the continuation first. Which one wins is genuinely nondeterministic — that's the point —
    /// so this does NOT assert success vs. timeout, only that every run resolves to exactly one
    /// definite outcome. Resuming a checked continuation twice is a hard crash: if `ResumeGuard`
    /// didn't work, this test wouldn't fail, it would crash the whole test process.
    func testRunDoesNotDoubleResumeWhenProcessExitsNearTheDeadline() async {
        for _ in 0..<20 {
            do {
                _ = try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.2"],
                                        timeout: 0.2, killGrace: testGrace)
                // Natural exit won the race — fine.
            } catch is ShellTimeoutError {
                // Deadline task won the race — also fine.
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Phase 2 gaps (hardening plan)

    /// Classic pipe-buffer deadlock shape: a process that writes far more than the pipe's kernel
    /// buffer (64 KB on macOS) before it exits. `Shell.run` drains both pipes with an async
    /// `readabilityHandler` rather than a blocking read specifically so this can't wedge — a naive
    /// "read everything, then wait for exit" implementation hangs forever here, because the child
    /// blocks on a full pipe while nothing is reading it. Not previously tested: the mechanism
    /// existed but nothing proved it against output actually large enough to hit the buffer limit.
    func testRunDoesNotDeadlockOnOutputLargerThanThePipeBuffer() async throws {
        let byteCount = 5_000_000   // ~76x the 64 KB pipe buffer
        let result = try await Shell.run(URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "yes | head -c \(byteCount)"], timeout: 15)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.utf8.count, byteCount,
                       "output was truncated or the run deadlocked/timed out short of completion")
    }

    /// `Process.run()` throws synchronously when the executable doesn't exist — this must surface
    /// to the caller as a normal Swift error, not silently hang until the timeout task fires. A
    /// regression here would turn every typo'd or missing Wine binary path into a 30s (production
    /// default) stall instead of an immediate, actionable error.
    func testRunThrowsPromptlyForANonExistentExecutable() async {
        let start = Date()
        do {
            _ = try await Shell.run(URL(fileURLWithPath: "/no/such/binary-does-not-exist-really"),
                                    arguments: [], timeout: 10)
            XCTFail("expected launch to throw")
        } catch is ShellTimeoutError {
            XCTFail("a missing executable must fail immediately, not fall through to the timeout")
        } catch {
            // Process.run()'s own throw — exactly what should happen.
            XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                              "should fail immediately, not wait anywhere near the 10s timeout")
        }
    }

    /// `currentDirectory` is new (added to fix a real bug: a direct-exe game with no explicit
    /// working directory inherited DECANTER'S OWN cwd and wrote a save/config file into whatever
    /// directory happened to be current when Decanter itself launched — see AppModel's direct-exe
    /// launch site). Never had a test proving the parameter actually reaches the child process.
    func testRunHonoursCurrentDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellTests-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await Shell.run(URL(fileURLWithPath: "/bin/pwd"), arguments: [],
                                         currentDirectory: dir, timeout: 5)

        // Standardize both sides — /tmp is itself a symlink to /private/tmp on macOS, and `pwd`
        // reports the resolved path.
        let reported = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(reported.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    /// Same proof as above, but for `Shell.stream` — the function `launchQuietly` actually calls
    /// for every real game/Steam launch, including the direct-exe path the bug above was found in.
    /// `Shell.run` and `Shell.stream` build the `Process` independently; a fix or regression in one
    /// says nothing about the other.
    func testStreamHonoursCurrentDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellTests-stream-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exited = expectation(description: "process exited")
        var output = ""
        var exitCode: Int32?
        let handle = try Shell.stream(URL(fileURLWithPath: "/bin/pwd"), arguments: [],
                                      currentDirectory: dir,
                                      onOutput: { output += $0 },
                                      onExit: { code in exitCode = code; exited.fulfill() })
        wait(for: [exited], timeout: 5)
        _ = handle

        XCTAssertEqual(exitCode, 0)
        let reported = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(reported.standardizedFileURL.path, dir.standardizedFileURL.path)
    }
}
