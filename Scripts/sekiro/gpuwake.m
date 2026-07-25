// gpuwake — measure GPU submit/complete latency at a given idle interval.
//
// WHY THIS EXISTS. Tuning gpukeepalive needs an answer to "at interval X, does the GPU fall
// asleep between submissions?" The obvious live metric cannot answer it: `CurrentPowerState` in
// ioreg is a coarse 0/1 flag that an active display holds at 1, so a sweep against it reports
// HELD AWAKE even with NO keep-alive running (measured 2026-07-24 — the control passed, which
// invalidated the whole sweep). The fine-grained `fw_power_state` only appears in gpuEvent crash
// reports, i.e. only when the thing we are trying to prevent has already happened.
//
// So measure the CONSEQUENCE instead of the state. A GPU that has powered down has to wake up
// before it can execute, and that wake shows up as latency on the next submission. Submit a tiny
// blit every INTERVAL ms and record commit->completed. If long intervals show a fat tail that
// short intervals do not, the GPU was sleeping in the gaps.
//
// Build: clang -arch arm64 -fobjc-arc -O2 -framework Foundation -framework Metal -o gpuwake gpuwake.m
// Run:   ./gpuwake <interval_ms> <seconds>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

int main(int argc, char **argv) { @autoreleasepool {
    double intervalMS = argc > 1 ? atof(argv[1]) : 50.0;
    double runSec     = argc > 2 ? atof(argv[2]) : 30.0;

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "no metal device\n"); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> src = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> dst = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];

    NSMutableArray<NSNumber *> *lat = [NSMutableArray array];
    double end = CACurrentMediaTime() + runSec;

    while (CACurrentMediaTime() < end) {
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0 size:256];
            [b endEncoding];
            double t0 = CACurrentMediaTime();
            [cb commit];
            [cb waitUntilCompleted];          // the wake, if any, lands inside this wait
            [lat addObject:@((CACurrentMediaTime() - t0) * 1000.0)];
        }
        usleep((useconds_t)(intervalMS * 1000.0));
    }

    NSArray<NSNumber *> *s = [lat sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger n = s.count;
    if (n < 5) { printf("too few samples\n"); return 1; }
    double sum = 0, mx = 0;
    for (NSNumber *v in s) { sum += v.doubleValue; if (v.doubleValue > mx) mx = v.doubleValue; }
    // p99 is the interesting one: a wake is rare per-sample but should be visible in the tail.
    printf("  %7.0f ms interval  n=%-4lu  mean %6.3f ms  p50 %6.3f  p99 %7.3f  max %7.3f\n",
           intervalMS, (unsigned long)n, sum/n,
           s[n/2].doubleValue, s[(NSUInteger)(n*0.99)].doubleValue, mx);
    return 0;
}}
