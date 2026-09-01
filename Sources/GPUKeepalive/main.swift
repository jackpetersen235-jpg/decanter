import Metal
import Foundation

// GPU keep-alive — bundled helper, built from the same source shape as the hand-tuned
// `Scripts/sekiro/gpukeepalive.swift` that has shipped inside `Sekiro.app` since 2026-07-19, with
// one change: the target executable is a COMMAND-LINE ARGUMENT instead of a hardcoded
// `sekiro\.exe`, so any bottle can opt in via `BottleSettings.gpuKeepAlive` — see
// `AppModel.launchGPUKeepAliveIfNeeded`. Wired into the app itself during the second
// settings-parity audit (2026-09-01): the workaround existed only in the external launcher, so
// Decanter's own Play button gave zero protection against the same firmware fault.
//
// WHY THIS EXISTS: this Mac's GPU firmware intermittently fails to resume from its lowest power
// state — every `gpuEvent-*.ips` report shows `restart_reason "progress timeout"` with
// `fw_power_state=0`, every 3d/tiler/compute slot idle, and `command_buffer_trace_id=-1` (nothing
// was executing). It is below Wine, below DXMT, below anything patchable from user space.
// Submitting a tiny blit on an interval holds the GPU above that state. See
// `docs/GPU-HANG-FINDINGS.md` for the full investigation.
//
// LIFETIME IS SELF-MANAGED ON PURPOSE — carried over unchanged from the original. A supervising
// reaper subshell failed twice on 2026-07-19 and silently invalidated two validation sessions: the
// game ran completely unprotected and it only surfaced after the numbers were already
// contaminated. This binary owns its own exit condition and logs it; nothing external should try
// to babysit it beyond a plain spawn-and-forget.
//
// Rules: exit once the watched exe has been seen and has then gone away; exit if it never appears
// within the grace period; NEVER exit while it's running.

let arguments = CommandLine.arguments
let interval: UInt32 = arguments.count > 1 ? (UInt32(arguments[1]) ?? 50_000) : 50_000
// Defaults to sekiro.exe purely so the binary still does something sane invoked bare (matches the
// original single-purpose script's behavior) — every real caller passes this explicitly.
let targetExe: String = arguments.count > 2 ? arguments[2] : "sekiro.exe"

let graceSeconds = 600.0          // 10 min — a cold Steam login plus update check is slow
let pollSeconds  = 5.0

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Decanter/gpukeepalive.log")

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// `pgrep -f <exe>` — what the original single-purpose script used — matches against every
/// process's FULL COMMAND LINE, not just its own name. That's exactly what broke this once
/// generalized: `AppModel.installGraphicsDriver` runs `wine reg add
/// HKCU\Software\Wine\AppDefaults\sekiro.exe\DllOverrides …` for every resolved game in a shared
/// prefix as part of a normal launch, and that registry-editing process's own argv literally
/// contains the string "sekiro.exe" as a path component — so `pgrep -f` reported the target
/// "detected", then "exited" a few seconds later when that unrelated `wine reg add` call finished,
/// stopping the keep-alive LONG before the real game ever started. Found live, 2026-09-01, on the
/// very first end-to-end test after wiring this into Decanter's own launch path (the original
/// hand-tuned launcher never hit this because it launches exactly one game directly, with no
/// registry sweep across a shared prefix first).
///
/// Matches `AppModel.isProcessRunning(named:)`'s own approach instead: `ps -Ao comm=`, which is
/// the process's OWN name/path, not its arguments — a shell running `wine reg add …sekiro.exe…`
/// reports `comm` as `/bin/sh` (or similar), never as `sekiro.exe`, so it can't spoof this. Wine
/// reports `comm` as a full WINDOWS path (`C:\...\sekiro.exe`), hence the split on both `/` and
/// `\` before comparing — same gotcha documented at `isAnyGameRunning` and `windowsPathLastComponent`.
func targetIsRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let target = targetExe.lowercased()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
        let comm = line.trimmingCharacters(in: .whitespaces)
        let last = comm.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? comm
        return last.lowercased() == target
    }
}

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    log("FATAL: no Metal device"); exit(1)
}
let bytes = 256
guard let src = device.makeBuffer(length: bytes, options: .storageModePrivate),
      let dst = device.makeBuffer(length: bytes, options: .storageModePrivate) else {
    log("FATAL: buffer allocation failed"); exit(1)
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }

log("START pid=\(ProcessInfo.processInfo.processIdentifier) device=\(device.name) "
    + "interval=\(interval)us target=\(targetExe)")

let started = Date()
var sawTarget = false
var lastPoll = Date.distantPast
var submissions: UInt64 = 0

while true {
    autoreleasepool {
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: src, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes)
            blit.endEncoding()
            cb.commit()   // committing is what holds the power state; do NOT wait on it
            submissions &+= 1
        }
    }

    if Date().timeIntervalSince(lastPoll) >= pollSeconds {
        lastPoll = Date()
        let running = targetIsRunning()
        if running && !sawTarget {
            sawTarget = true
            log("\(targetExe) detected after \(Int(Date().timeIntervalSince(started)))s — protecting")
        } else if !running && sawTarget {
            log("\(targetExe) exited — stopping after \(submissions) submissions")
            exit(0)
        } else if !running && !sawTarget,
                  Date().timeIntervalSince(started) > graceSeconds {
            log("\(targetExe) never appeared within \(Int(graceSeconds))s — stopping")
            exit(0)
        }
    }

    usleep(interval)
}
