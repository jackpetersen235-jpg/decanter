import Metal
import Foundation

// GPU keep-alive.
//
// This Mac's GPU firmware intermittently fails to resume from its lowest power state: every
// gpuEvent-*.ips report shows restart_reason "progress timeout" with fw_power_state=0, all
// 3d/tiler/compute slots idle, and command_buffer_trace_id=-1 — nothing was executing.
// Submitting a tiny blit on an interval holds the GPU above that state.
//
// LIFETIME IS SELF-MANAGED ON PURPOSE. The launcher used to supervise this with a background
// reaper subshell. It failed twice on 2026-07-19 and silently invalidated two validation
// sessions — the game ran completely unprotected and it only surfaced after the numbers were
// already contaminated. A subshell that can kill the process it exists to protect, while
// leaving no log, is not debuggable. This binary now owns its exit condition and logs it.
//
// Rules: exit once the game has been seen and has then gone away; exit if the game never
// appears within the grace period; NEVER exit while the game is running.

let interval: UInt32 = CommandLine.arguments.count > 1
    ? (UInt32(CommandLine.arguments[1]) ?? 50_000) : 50_000
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

func gameIsRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", #"sekiro\.exe"#]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
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

log("START pid=\(ProcessInfo.processInfo.processIdentifier) device=\(device.name) interval=\(interval)us")

let started = Date()
var sawGame = false
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
        let running = gameIsRunning()
        if running && !sawGame {
            sawGame = true
            log("game detected after \(Int(Date().timeIntervalSince(started)))s — protecting")
        } else if !running && sawGame {
            log("game exited — stopping after \(submissions) submissions")
            exit(0)
        } else if !running && !sawGame,
                  Date().timeIntervalSince(started) > graceSeconds {
            log("game never appeared within \(Int(graceSeconds))s — stopping")
            exit(0)
        }
    }

    usleep(interval)
}
