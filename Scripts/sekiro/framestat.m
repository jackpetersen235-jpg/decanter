// framestat — frame-pacing probe. Injected next to a game (DYLD_INSERT_LIBRARIES), it times every
// -[CAMetalLayer nextDrawable] — one per presented frame under DXMT — and every few seconds logs:
//
//   frames  fps  interval ms (mean/p50/p95/p99/max)  hitches>25ms  wait p95  drawable WxH scale
//
// WHY A NEW PROBE. gpustall counts command buffers per window ("cb/5s"), a proxy whose ratio to
// frames varies with the scene, and its gpuMS is documented as producing false positives
// (memory: decanter-dxmt-stall-profiler). Frame pacing — the thing a player feels — is the
// interval between presents, so this measures exactly that and nothing else.
//
// "wait" is how long nextDrawable itself blocked: the game asking for a new frame buffer before
// the compositor has handed one back. Near zero = never backpressured; climbing = presentation
// can't keep up (the classic symptom of a Composited path).
//
// No-op unless $FRAMESTAT_LOG is set. $FRAMESTAT_WINDOW_SEC (default 5) sets the report window.
// MUST BE x86_64 (Rosetta wine tree). Build: Scripts/sekiro/build-framestat.sh.
// Never launch the injected process through nohup/env/bash -c — SIP strips DYLD_* (see
// memory dyld-injection-sip-trap).

#include <objc/runtime.h>
#include <objc/message.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct { double width, height; } SizeT;

#define RING            8192
#define HITCH_MS        25.0
#define POLL_NS         (250ull * NSEC_PER_MSEC)
#define GIVE_UP_NS      (300ull * NSEC_PER_SEC)

static char gLogPath[1024];
static double gWindowSec = 5.0;
static double gTicksToMs;
static IMP gOrigNextDrawable;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static double gIntervals[RING];   // ms between consecutive nextDrawable calls
static double gWaits[RING];       // ms nextDrawable itself blocked
static size_t gCount;             // samples in the current window (capped at RING)
static uint64_t gLastCall;
static SizeT gDrawable;
static double gScale;

static void logline(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logline(const char *fmt, ...) {
    FILE *f = fopen(gLogPath, "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char stamp[16];
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tmv);
    fprintf(f, "[%s] ", stamp);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static id hook_nextDrawable(id self, SEL _cmd) {
    uint64_t start = mach_absolute_time();
    id drawable = ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
    uint64_t end = mach_absolute_time();

    os_unfair_lock_lock(&gLock);
    if (gLastCall != 0 && gCount < RING) {
        gIntervals[gCount] = (double)(start - gLastCall) * gTicksToMs;
        gWaits[gCount] = (double)(end - start) * gTicksToMs;
        gCount++;
    }
    gLastCall = start;
    os_unfair_lock_unlock(&gLock);

    // Cheap enough to sample every frame; read outside the lock (benign race on two doubles).
    gDrawable = ((SizeT (*)(id, SEL))objc_msgSend)(self, sel_registerName("drawableSize"));
    gScale = ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("contentsScale"));
    return drawable;
}

static int cmpDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double percentile(const double *sorted, size_t n, double p) {
    if (n == 0) return 0;
    size_t idx = (size_t)(p * (double)(n - 1) + 0.5);
    return sorted[idx < n ? idx : n - 1];
}

static void report(void) {
    static double intervals[RING], waits[RING];
    os_unfair_lock_lock(&gLock);
    size_t n = gCount;
    memcpy(intervals, gIntervals, n * sizeof *intervals);
    memcpy(waits, gWaits, n * sizeof *waits);
    gCount = 0;
    os_unfair_lock_unlock(&gLock);

    if (n == 0) {
        logline("frames=0 (nothing presented this window)");
        return;
    }
    double sum = 0;
    size_t hitches = 0;
    for (size_t i = 0; i < n; i++) {
        sum += intervals[i];
        if (intervals[i] > HITCH_MS) hitches++;
    }
    qsort(intervals, n, sizeof *intervals, cmpDouble);
    qsort(waits, n, sizeof *waits, cmpDouble);
    logline("frames=%zu fps=%.1f interval_ms mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f "
            "hitches>25ms=%zu wait_ms p50=%.2f p95=%.2f max=%.2f drawable=%.0fx%.0f scale=%.1f",
            n, (double)n / gWindowSec, sum / (double)n,
            percentile(intervals, n, 0.50), percentile(intervals, n, 0.95),
            percentile(intervals, n, 0.99), intervals[n - 1], hitches,
            percentile(waits, n, 0.50), percentile(waits, n, 0.95), waits[n - 1],
            gDrawable.width, gDrawable.height, gScale);
}

static void tryInstall(uint64_t waitedNs) {
    Class cls = objc_getClass("CAMetalLayer");
    if (cls) {
        SEL sel = sel_registerName("nextDrawable");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            logline("CAMetalLayer has no nextDrawable?! not installed");
            return;
        }
        gOrigNextDrawable = class_getMethodImplementation(cls, sel);
        class_replaceMethod(cls, sel, (IMP)hook_nextDrawable, method_getTypeEncoding(m));
        logline("installed on CAMetalLayer after %.1fs; reporting every %.0fs", waitedNs / 1e9, gWindowSec);

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        uint64_t period = (uint64_t)(gWindowSec * NSEC_PER_SEC);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)period), period,
                                  period / 20);
        dispatch_source_set_event_handler(timer, ^{ report(); });
        dispatch_resume(timer);
        return;
    }
    if (waitedNs >= GIVE_UP_NS) {
        logline("CAMetalLayer never appeared — not a Metal process, giving up");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)POLL_NS),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ tryInstall(waitedNs + POLL_NS); });
}

__attribute__((constructor))
static void framestat_load(void) {
    const char *path = getenv("FRAMESTAT_LOG");
    if (!path || !*path) return;
    snprintf(gLogPath, sizeof gLogPath, "%s", path);
    const char *win = getenv("FRAMESTAT_WINDOW_SEC");
    if (win && atof(win) > 0) gWindowSec = atof(win);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksToMs = (double)tb.numer / (double)tb.denom / 1e6;
    logline("loaded into pid %d", getpid());
    tryInstall(0);
}
