import Metal
import Foundation

// Prevents the GPU firmware from dropping to power state 0, where this Mac's
// firmware intermittently fails to resume ("progress timeout", 25/25 reports show
// power_state=0 + command_buffer_trace_id=-1 -> GPU idle, nothing executing).
// Submits a tiny blit every few ms: enough to hold a non-idle power state,
// far too small to contend with the game for GPU time.

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    FileHandle.standardError.write("no metal device\n".data(using: .utf8)!)
    exit(1)
}

let bytes = 256
guard let src = device.makeBuffer(length: bytes, options: .storageModePrivate),
      let dst = device.makeBuffer(length: bytes, options: .storageModePrivate) else {
    FileHandle.standardError.write("buffer alloc failed\n".data(using: .utf8)!)
    exit(1)
}

// Interval: short enough to stay ahead of the idle transition, long enough to be free.
let intervalUs: UInt32 = UInt32(CommandLine.arguments.count > 1 ? (UInt32(CommandLine.arguments[1]) ?? 3000) : 3000)

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }

print("gpu keepalive: \(device.name), every \(intervalUs)us")
fflush(stdout)

var n: UInt64 = 0
while true {
    autoreleasepool {
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: src, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes)
            blit.endEncoding()
            cb.commit()
            // Do NOT wait: committing is what holds the power state. Waiting would
            // serialise this against the game's own submissions.
        }
    }
    n &+= 1
    usleep(intervalUs)
}
