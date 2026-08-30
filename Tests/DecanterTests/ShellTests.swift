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
}
