import Foundation

/// One command instead of the manual Bash choreography every phase of the pre-release debug plan
/// actually used by hand: re-invokes THIS SAME BINARY as fresh child processes against a
/// guaranteed-fresh scratch `DECANTER_HOME`, so "does first run still work" can run before every
/// release build rather than only when someone remembers to check.
///
/// Deliberately does NOT call `AppModel.runGuidedSetup()` on the running process's own model —
/// that model already loaded the REAL `bottles.json` at `init()`, so reusing it against a scratch
/// env would conflate real and test state, the exact trap `DECANTER_HOME` (Phase 1) exists to
/// avoid. Spawning genuinely separate processes, each with its own fresh `AppModel.init()` reading
/// the scratch home from the start, is exactly how every other headless flag in this project was
/// actually exercised throughout Phases 1–4 — this just automates the choreography instead of
/// requiring someone to type it.
enum SelfTest {
    struct StepResult {
        let name: String
        let ok: Bool
        let detail: String
    }

    /// Runs the full sequence and returns whether everything passed, the per-step results, and
    /// where the scratch install lives. The scratch install is removed on success; left in place
    /// on failure, since a failing regression run should leave something to inspect rather than
    /// destroy the evidence.
    static func run() async -> (ok: Bool, results: [StepResult], scratchDir: URL) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("decanter-selftest-\(UUID().uuidString)", isDirectory: true)
        var results: [StepResult] = []

        // 1. --run-setup — the full first-run automation: Rosetta check, engine download + msync
        // graft, bottle creation, Steam install. The one thing this whole flag exists to prove
        // still works end to end.
        let setup = await runSelf(["--run-setup"], scratch: scratch, timeout: 400)
        results.append(StepResult(name: "run-setup", ok: setup.exitCode == 0,
                                  detail: setup.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard setup.exitCode == 0 else { return (false, results, scratch) }

        // 2. --bootstrap-steam-test — --run-setup deliberately stops at "Steam installed," not
        // "Steam has downloaded its client" (confirmed directly against the GUI wizard during
        // Phase 1: SetupWizard.swift has zero references to bootstrap either — this is the
        // app's real, consistent definition of "setup done," not a gap in --run-setup alone).
        // A self-test that stopped there would either have to special-case away a "failure" that
        // isn't one, or genuinely not exercise the one part of first run that takes real user-
        // visible time. Chain in the Phase 2 hook instead and go all the way to a real bootstrapped
        // client, exactly like a first-time customer's first few minutes.
        //
        // 480s, not 240: measured this step directly during Phase 5 and saw real variance in
        // Steam's own CDN — one run downloaded its ~330 MB client in under 20s, another stalled
        // at ~7 MB after 240s with no code difference at all (confirmed by hand: launching the
        // exact same steam.exe manually against the exact same prefix right afterward download
        // at full speed). A tight timeout here would make this step FLAKY — failing on Steam's
        // bad day, not on a Decanter regression — which is worse than a slow but reliable check
        // for something meant to run before every release.
        let bottleName = "Games"   // createBottleForSetup's setup-flow name — see runGuidedSetup
        let bootstrap = await runSelf(["--bootstrap-steam-test", bottleName, "480"],
                                      scratch: scratch, timeout: 500)
        results.append(StepResult(name: "bootstrap-steam-test", ok: bootstrap.exitCode == 0,
                                  detail: bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))

        // 3. --verify — now genuinely everything should be clean, with ONE known exception:
        // "DXMT graphics payload bundled" reads `Bundle.main.resourceURL`, which is empty for a
        // raw (non-.app) binary — confirmed harmless during Phase 3's testing methodology notes,
        // not a real gap. Anything else failing here is a genuine regression.
        let verify = await runSelf(["--verify"], scratch: scratch, timeout: 30)
        let unexpectedFailures = verify.stderr
            .components(separatedBy: "\n")
            .filter { $0.contains("FAIL") && !$0.contains("DXMT graphics payload bundled") }
        results.append(StepResult(name: "verify", ok: unexpectedFailures.isEmpty,
                                  detail: unexpectedFailures.isEmpty
                                    ? "clean"
                                    : unexpectedFailures.joined(separator: " / ")))

        // 4. --run-setup AGAIN — idempotency (F17/hasUsableEngine's msync-probe fix exists
        // precisely because a re-run used to silently skip a step that hadn't actually finished).
        // Must exit 0, and must be fast — a slow re-run means it's redoing real network work
        // instead of correctly recognising everything is already done.
        let start = Date()
        let rerun = await runSelf(["--run-setup"], scratch: scratch, timeout: 60)
        let elapsed = Date().timeIntervalSince(start)
        results.append(StepResult(
            name: "run-setup (idempotent re-run)",
            ok: rerun.exitCode == 0 && elapsed < 30,
            detail: "exit=\(rerun.exitCode) elapsed=\(String(format: "%.1f", elapsed))s"
                + (elapsed >= 30 ? " — TOO SLOW, likely redid real work instead of skipping" : "")))

        let allOK = results.allSatisfy(\.ok)
        if allOK { try? fm.removeItem(at: scratch) }
        return (allOK, results, scratch)
    }

    private struct ChildResult { let exitCode: Int32; let stderr: String }

    private static func runSelf(_ args: [String], scratch: URL, timeout: TimeInterval) async -> ChildResult {
        guard let selfURL = Bundle.main.executableURL else {
            return ChildResult(exitCode: -1, stderr: "couldn't determine this binary's own path")
        }
        var env = ProcessInfo.processInfo.environment
        env["DECANTER_HOME"] = scratch.path
        do {
            let result = try await Shell.run(selfURL, arguments: args, environment: env, timeout: timeout)
            return ChildResult(exitCode: result.exitCode, stderr: result.stderr)
        } catch {
            return ChildResult(exitCode: -1, stderr: "\(error)")
        }
    }
}
