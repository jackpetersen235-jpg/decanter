// gpustall — name the Metal pipeline that is eating the 2–25 s Sekiro stalls.
//
// WHY THIS EXISTS. DXMT 0.80 has no per-draw trace, and the direct tool (Metal System Trace /
// .gputrace) needs full Xcode, which this machine does not have (CLT only). See
// docs/DXMT-STALL-REPORT.md Part 1 — the isolation attempt failed on exactly this.
//
// This gets the same answer without Xcode. It is a DYLD_INSERT_LIBRARIES dylib that swizzles
// Metal and records, per MTLCommandBuffer, the GPU-side execution time plus every pipeline that
// was bound inside it. Any command buffer whose GPU time exceeds a threshold dumps its full
// contents. Viable because wine here is ad-hoc signed with NO hardened runtime and NO library
// validation (`codesign -dvvv` -> flags=0x2(adhoc)), so the insertion is not stripped, and env
// is inherited all the way down the launcher -> steam.exe -> sekiro.exe chain.
//
// Must be built x86_64: the whole wine tree is x86_64 under Rosetta, including winemetal.so.
//
// Build:  bash Scripts/sekiro/build-gpustall.sh
// Run:    bash Scripts/sekiro/gpuprof-run.sh
//
// IT ALSO TESTS THE PREMISE. The report concludes "one command buffer contains one pathologically
// long encoder". The competing explanation — a backlog of many normal command buffers, where the
// render thread is simply waiting its turn — produces the identical outward signature (100% GPU,
// thread in U, no watchdog). g_outstanding distinguishes them: a single fat encoder stalls with a
// SHALLOW queue, a backlog stalls with a deep one. Read that field first.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <unistd.h>
#import <fcntl.h>
#import <crt_externs.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/time.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                                       \
    __attribute__((used)) static struct {                                             \
        const void *replacement;                                                      \
        const void *replacee;                                                         \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {        \
        (const void *)(unsigned long)&_replacement,                                   \
        (const void *)(unsigned long)&_replacee                                       \
    };

// ---------------------------------------------------------------------------- config + logging

static int      g_fd          = -1;
static double   g_slowMS      = 250.0;   // dump any command buffer slower than this

// Per-encoder GPU timestamp sampling (see the counter-sampling section below). Declared up here
// because the command-buffer completion handler rewinds g_tsNext and runs earlier in the file.
#define TS_SLOTS 4096
static id<MTLCounterSampleBuffer> g_tsBuf = nil;
static _Atomic(uint32_t) g_tsNext = 0;
static uint32_t g_tsCap = 0;
static double   g_summarySec  = 5.0;
static BOOL     g_armed       = NO;

// Dump every Nth *normal* command buffer as well. Without this the log only says what was inside
// slow buffers — but a pipeline that runs every frame is inside every slow buffer too, culprit or
// not. The baseline turns "present during stalls" into "enriched during stalls", which is the
// difference between a suspect and a coincidence. Cheap: one dump per ~2 s of play.
static uint64_t g_baselineEvery = 120;

static NSString *g_argvDesc = @"?";   // real exec argv, for diagnosing what actually got injected

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static double nowWall(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

// write(2) directly: stdio buffering is unreliable across a wine process tree, and a stall that
// ends in a hard kill must not lose the lines that explain it.
static void logline(NSString *fmt, ...) {
    if (g_fd < 0) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    double  w = nowWall();
    time_t  t = (time_t)w;
    struct tm tmv;
    localtime_r(&t, &tmv);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &tmv);

    NSString *line = [NSString stringWithFormat:@"%s.%03d [%d] %@\n", stamp,
                      (int)((w - floor(w)) * 1000), getpid(), msg];
    const char *utf8 = line.UTF8String;
    write(g_fd, utf8, strlen(utf8));
}

static __thread int t_inKeepalive;   // set while the in-process keep-alive submits
static _Atomic double g_lastGameCommit;   // wall time of the last GAME commit (keep-alive idle gate)

// ---------------------------------------------------------------------------- records

@interface EncRec : NSObject
@property (nonatomic, copy)   NSString *kind;      // compute | render | blit
@property (nonatomic, copy)   NSString *curPipe;   // currently-bound pipeline
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *stats;
@end

@implementation EncRec
- (instancetype)init {
    if ((self = [super init])) {
        _stats   = [NSMutableDictionary dictionary];
        _curPipe = @"<none>";
    }
    return self;
}
// stats[pipe] = @[ invocationCount, totalWork ]  (work = threads for compute, indices for draws)
- (void)tally:(uint64_t)work {
    NSMutableArray<NSNumber *> *e = self.stats[self.curPipe];
    if (!e) {
        e = [@[@0, @0] mutableCopy];
        self.stats[self.curPipe] = e;
    }
    e[0] = @([e[0] unsignedLongLongValue] + 1);
    e[1] = @([e[1] unsignedLongLongValue] + work);
}
@end

@interface CBRec : NSObject
@property (nonatomic)         uint64_t seq;
@property (nonatomic)         double   commitWall;
@property (nonatomic)         int64_t  outstandingAtCommit;
@property (nonatomic, strong) NSMutableArray<EncRec *> *encoders;
// GPU-side synchronisation recorded per command buffer. This is the direct test of the
// fence/event hypothesis: if a stalled buffer is waiting rather than computing, the wait has to
// be encoded here as an MTLFence wait or an MTLEvent wait. A buffer that stalls 26 s with ZERO
// waits recorded would refute the hypothesis outright.
// Wall-clock at [queue commandBuffer]. commit-minus-this is how long the CPU spent ENCODING.
// This separates the two remaining stories: if encodeMS ~= 26 s the render thread was blocked
// while holding an open buffer (a CPU-side stall), if encodeMS ~= 0 the buffer was built fast
// and the delay is genuinely after commit.
@property (nonatomic) double createWall;
@property (nonatomic) int fenceWaits;
@property (nonatomic) int fenceUpdates;
@property (nonatomic) int eventWaits;
@property (nonatomic) int eventSignals;
@property (nonatomic, copy) NSString *firstEventWait;   // "label:value" of the first wait
@end

@implementation CBRec
- (instancetype)init {
    if ((self = [super init])) _encoders = [NSMutableArray array];
    return self;
}
@end

// Opaque (non-retaining) keys so we never extend a command buffer's lifetime.
static NSMapTable *g_cbRecs;    // MTLCommandBuffer*  -> CBRec
static NSMapTable *g_encRecs;   // MTLCommandEncoder* -> EncRec
static NSMapTable *g_pipeNames; // MTLxPipelineState* -> NSString

static atomic_llong g_outstanding  = 0;   // committed but not yet completed
static atomic_llong g_maxOut       = 0;
static atomic_ullong g_seq         = 0;
static atomic_ullong g_cbCount     = 0;   // reset every summary window
static atomic_ullong g_cbTotal     = 0;   // never reset — drives baseline sampling
static atomic_ullong g_slowCount   = 0;
static double        g_gpuTimeAcc  = 0.0;
static double        g_worstMS     = 0.0;
static double        g_lastSummary = 0.0;

static NSMapTable *mkTable(void) {
    return [[NSMapTable alloc]
        initWithKeyOptions:(NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality)
              valueOptions:NSPointerFunctionsStrongMemory
                  capacity:256];
}

static NSString *pipeName(id pso) {
    if (!pso) return @"<nil>";
    NSString *n = nil;
    pthread_mutex_lock(&g_lock);
    n = [g_pipeNames objectForKey:pso];
    pthread_mutex_unlock(&g_lock);
    if (n) return n;
    NSString *lbl = [pso respondsToSelector:@selector(label)] ? [pso label] : nil;
    return lbl.length ? lbl : [NSString stringWithFormat:@"pso@%p", pso];
}

static void notePipe(id pso, NSString *name) {
    if (!pso || !name.length) return;
    pthread_mutex_lock(&g_lock);
    [g_pipeNames setObject:name forKey:pso];
    pthread_mutex_unlock(&g_lock);
}

// ---------------------------------------------------------------------------- swizzle helper

// class_addMethod first: if the selector is inherited rather than implemented here, overriding it
// on this class alone avoids patching the shared superclass implementation out from under
// everything else in the process.
static BOOL swizzle(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, newImp, types)) {
        *origOut = method_getImplementation(m);          // inherited: original lives upstream
    } else {
        *origOut = method_setImplementation(class_getInstanceMethod(cls, sel), newImp);
    }
    return YES;
}

// ---------------------------------------------------------------------------- originals

static void (*orig_commit)(id, SEL);
static id   (*orig_computeEnc)(id, SEL);
static id   (*orig_computeEncDT)(id, SEL, MTLDispatchType);
static id   (*orig_computeEncDesc)(id, SEL, id);
static id   (*orig_renderEnc)(id, SEL, id);
static id   (*orig_blitEnc)(id, SEL);

static void (*orig_setCompPSO)(id, SEL, id);
static void (*orig_dispatchTG)(id, SEL, MTLSize, MTLSize);
static void (*orig_dispatchThreads)(id, SEL, MTLSize, MTLSize);
static void (*orig_dispatchIndirect)(id, SEL, id, NSUInteger, MTLSize);
static void (*orig_compEndEnc)(id, SEL);

static void (*orig_setRendPSO)(id, SEL, id);
// The BASE variants below are not enough on their own. A modern engine overwhelmingly uses the
// baseVertex:baseInstance: form, and if it is not hooked the render encoders record no work, get
// skipped by dumpCB, and the log looks like the game is 100% compute. That is exactly what
// happened on 2026-07-25 and it made the encoder-composition analysis useless.
static void (*orig_drawPrim)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
static void (*orig_drawPrimBase)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger);
static void (*orig_drawIndexedBase)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id,
                                    NSUInteger, NSUInteger, NSInteger, NSUInteger);
static void (*orig_drawPrimIndirect)(id, SEL, MTLPrimitiveType, id, NSUInteger);
static void (*orig_drawIndexedIndirect)(id, SEL, MTLPrimitiveType, MTLIndexType, id, NSUInteger, id, NSUInteger);
static void (*orig_drawIndexed)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id,
                                NSUInteger, NSUInteger);
static void (*orig_rendEndEnc)(id, SEL);

// NOTE THE `void *`. These selectors start with "new", so by ObjC convention they return a +1
// RETAINED object that the caller owns and will release. Typing them as `id` under ARC makes the
// wrapper hand back a +0 autoreleased object instead; Metal's matching release then falls on an
// object nobody retained, and the process segfaults in objc_autoreleasePoolPop. (Observed: every
// selftest run crashed at exit until this was fixed.) Keeping them unmanaged passes the +1
// straight through untouched.
static void *(*orig_newCompPSO_fn_err)(id, SEL, id, NSError **);
static void *(*orig_newCompPSO_fn_opt)(id, SEL, id, MTLPipelineOption, id *, NSError **);
static void *(*orig_newCompPSO_desc)(id, SEL, id, MTLPipelineOption, id *, NSError **);
static void *(*orig_newRendPSO_desc_err)(id, SEL, id, NSError **);
static void *(*orig_newRendPSO_desc_opt)(id, SEL, id, MTLPipelineOption, id *, NSError **);

// ---------------------------------------------------------------------------- encoder hooks

static EncRec *encRecFor(id enc) {
    pthread_mutex_lock(&g_lock);
    EncRec *r = [g_encRecs objectForKey:enc];
    pthread_mutex_unlock(&g_lock);
    return r;
}

static void my_setCompPSO(id self, SEL _cmd, id pso) {
    EncRec *r = encRecFor(self);
    if (r) r.curPipe = pipeName(pso);
    orig_setCompPSO(self, _cmd, pso);
}

static uint64_t threadCount(MTLSize a, MTLSize b) {
    return (uint64_t)a.width * a.height * a.depth * (uint64_t)b.width * b.height * b.depth;
}

static void my_dispatchTG(id self, SEL _cmd, MTLSize tg, MTLSize tpt) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:threadCount(tg, tpt)];
    orig_dispatchTG(self, _cmd, tg, tpt);
}

static void my_dispatchThreads(id self, SEL _cmd, MTLSize th, MTLSize tpt) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:(uint64_t)th.width * th.height * th.depth];
    orig_dispatchThreads(self, _cmd, th, tpt);
}

static void my_dispatchIndirect(id self, SEL _cmd, id buf, NSUInteger off, MTLSize tpt) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:0];   // indirect: thread count lives on the GPU, unknowable here
    orig_dispatchIndirect(self, _cmd, buf, off, tpt);
}

static void my_setRendPSO(id self, SEL _cmd, id pso) {
    EncRec *r = encRecFor(self);
    if (r) r.curPipe = pipeName(pso);
    orig_setRendPSO(self, _cmd, pso);
}

static void my_drawPrim(id self, SEL _cmd, MTLPrimitiveType t, NSUInteger start,
                        NSUInteger count, NSUInteger inst) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:(uint64_t)count * (inst ?: 1)];
    orig_drawPrim(self, _cmd, t, start, count, inst);
}

static void my_drawIndexed(id self, SEL _cmd, MTLPrimitiveType t, NSUInteger idxCount,
                           MTLIndexType it, id buf, NSUInteger off, NSUInteger inst) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:(uint64_t)idxCount * (inst ?: 1)];
    orig_drawIndexed(self, _cmd, t, idxCount, it, buf, off, inst);
}

// ---------------------------------------------------------------------------- fence / event

// Encoders own no back-pointer to their command buffer, so keep one so a fence call can be
// attributed to the buffer that will later report a 26 s duration.
static NSMapTable *g_encToCB;
static CBRec *cbRecFor(id cb, BOOL create);   // defined with the command-buffer hooks below

static CBRec *cbForEncoder(id enc) {
    pthread_mutex_lock(&g_lock);
    CBRec *r = [g_encToCB objectForKey:enc];
    pthread_mutex_unlock(&g_lock);
    return r;
}

static void (*orig_updFenceC)(id, SEL, id);
static void (*orig_waitFenceC)(id, SEL, id);
static void (*orig_updFenceR)(id, SEL, id, MTLRenderStages);
static void (*orig_waitFenceR)(id, SEL, id, MTLRenderStages);
static void (*orig_updFenceB)(id, SEL, id);
static void (*orig_waitFenceB)(id, SEL, id);
static void (*orig_encWaitEvent)(id, SEL, id, uint64_t);
static void (*orig_encSignalEvent)(id, SEL, id, uint64_t);

static void my_updFenceC(id s, SEL c, id f)  { CBRec *r=cbForEncoder(s); if(r) r.fenceUpdates++; orig_updFenceC(s,c,f); }
static void my_waitFenceC(id s, SEL c, id f) { CBRec *r=cbForEncoder(s); if(r) r.fenceWaits++;   orig_waitFenceC(s,c,f); }
static void my_updFenceB(id s, SEL c, id f)  { CBRec *r=cbForEncoder(s); if(r) r.fenceUpdates++; orig_updFenceB(s,c,f); }
static void my_waitFenceB(id s, SEL c, id f) { CBRec *r=cbForEncoder(s); if(r) r.fenceWaits++;   orig_waitFenceB(s,c,f); }
static void my_updFenceR(id s, SEL c, id f, MTLRenderStages st)  { CBRec *r=cbForEncoder(s); if(r) r.fenceUpdates++; orig_updFenceR(s,c,f,st); }
static void my_waitFenceR(id s, SEL c, id f, MTLRenderStages st) { CBRec *r=cbForEncoder(s); if(r) r.fenceWaits++;   orig_waitFenceR(s,c,f,st); }

// Command-buffer level. `encodeWaitForEvent:` makes the GPU block until another queue signals the
// value — the single most plausible way to burn a fixed 26 s with the device pinned and no work
// progressing. If the stalls carry one of these, that is the answer.
static void my_encWaitEvent(id self, SEL _cmd, id ev, uint64_t val) {
    CBRec *r = cbRecFor(self, YES);
    if (r) {
        r.eventWaits++;
        if (!r.firstEventWait) {
            NSString *lbl = [ev respondsToSelector:@selector(label)] ? [ev label] : nil;
            r.firstEventWait = [NSString stringWithFormat:@"%@:%llu", lbl.length ? lbl : @"<unlabelled>", val];
        }
    }
    orig_encWaitEvent(self, _cmd, ev, val);
}
static void my_encSignalEvent(id self, SEL _cmd, id ev, uint64_t val) {
    CBRec *r = cbRecFor(self, YES);
    if (r) r.eventSignals++;
    orig_encSignalEvent(self, _cmd, ev, val);
}

static void my_drawPrimBase(id self, SEL _cmd, MTLPrimitiveType t, NSUInteger start,
                            NSUInteger count, NSUInteger inst, NSUInteger baseInst) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:(uint64_t)count * (inst ?: 1)];
    orig_drawPrimBase(self, _cmd, t, start, count, inst, baseInst);
}

static void my_drawIndexedBase(id self, SEL _cmd, MTLPrimitiveType t, NSUInteger idxCount,
                               MTLIndexType it, id buf, NSUInteger off, NSUInteger inst,
                               NSInteger baseVtx, NSUInteger baseInst) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:(uint64_t)idxCount * (inst ?: 1)];
    orig_drawIndexedBase(self, _cmd, t, idxCount, it, buf, off, inst, baseVtx, baseInst);
}

// Indirect draws: the counts live in a GPU buffer, so work is unknowable here. Tally 0 — the
// encoder still gets recorded, which is what the composition analysis needs.
static void my_drawPrimIndirect(id self, SEL _cmd, MTLPrimitiveType t, id buf, NSUInteger off) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:0];
    orig_drawPrimIndirect(self, _cmd, t, buf, off);
}

static void my_drawIndexedIndirect(id self, SEL _cmd, MTLPrimitiveType t, MTLIndexType it,
                                   id ibuf, NSUInteger ioff, id abuf, NSUInteger aoff) {
    EncRec *r = encRecFor(self);
    if (r) [r tally:0];
    orig_drawIndexedIndirect(self, _cmd, t, it, ibuf, ioff, abuf, aoff);
}

static void my_compEndEnc(id self, SEL _cmd) {
    pthread_mutex_lock(&g_lock);
    [g_encRecs removeObjectForKey:self];
    pthread_mutex_unlock(&g_lock);
    orig_compEndEnc(self, _cmd);
}

static void my_rendEndEnc(id self, SEL _cmd) {
    pthread_mutex_lock(&g_lock);
    [g_encRecs removeObjectForKey:self];
    pthread_mutex_unlock(&g_lock);
    orig_rendEndEnc(self, _cmd);
}

// ---------------------------------------------------------------------------- pipeline naming

static NSString *fnName(id fn) {
    if (!fn) return nil;
    NSString *n = [fn respondsToSelector:@selector(name)] ? [fn name] : nil;
    return n.length ? n : nil;
}

static void *my_newCompPSO_fn_err(id self, SEL _cmd, id fn, NSError **err) {
    void *pso = orig_newCompPSO_fn_err(self, _cmd, fn, err);
    notePipe((__bridge id)pso, fnName(fn));
    return pso;
}

static void *my_newCompPSO_fn_opt(id self, SEL _cmd, id fn, MTLPipelineOption opt,
                                  id *refl, NSError **err) {
    void *pso = orig_newCompPSO_fn_opt(self, _cmd, fn, opt, refl, err);
    notePipe((__bridge id)pso, fnName(fn));
    return pso;
}

static void *my_newCompPSO_desc(id self, SEL _cmd, id desc, MTLPipelineOption opt,
                                id *refl, NSError **err) {
    void *pso = orig_newCompPSO_desc(self, _cmd, desc, opt, refl, err);
    NSString *n = fnName([desc respondsToSelector:@selector(computeFunction)]
                         ? [desc computeFunction] : nil);
    if (!n) n = [desc respondsToSelector:@selector(label)] ? [desc label] : nil;
    notePipe((__bridge id)pso, n);
    return pso;
}

static NSString *rendName(id desc) {
    NSString *v = fnName([desc respondsToSelector:@selector(vertexFunction)]
                         ? [desc vertexFunction] : nil);
    NSString *f = fnName([desc respondsToSelector:@selector(fragmentFunction)]
                         ? [desc fragmentFunction] : nil);
    if (v || f) return [NSString stringWithFormat:@"vs:%@/fs:%@", v ?: @"-", f ?: @"-"];
    return [desc respondsToSelector:@selector(label)] ? [desc label] : nil;
}

static void *my_newRendPSO_desc_err(id self, SEL _cmd, id desc, NSError **err) {
    void *pso = orig_newRendPSO_desc_err(self, _cmd, desc, err);
    notePipe((__bridge id)pso, rendName(desc));
    return pso;
}

static void *my_newRendPSO_desc_opt(id self, SEL _cmd, id desc, MTLPipelineOption opt,
                                    id *refl, NSError **err) {
    void *pso = orig_newRendPSO_desc_opt(self, _cmd, desc, opt, refl, err);
    notePipe((__bridge id)pso, rendName(desc));
    return pso;
}

// ---------------------------------------------------------------------------- command buffer

static Class g_compEncCls, g_rendEncCls;
static void bindEncoderClass(id enc, BOOL compute);

static CBRec *cbRecFor(id cb, BOOL create) {
    pthread_mutex_lock(&g_lock);
    CBRec *r = [g_cbRecs objectForKey:cb];
    if (!r && create) {
        r = [CBRec new];
        r.seq = atomic_fetch_add(&g_seq, 1);
        [g_cbRecs setObject:r forKey:cb];
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

static void bindFenceHooks(id enc, NSString *kind);

static void attachEncoder(id cb, id enc, NSString *kind) {
    if (!enc) return;
    CBRec *cr = cbRecFor(cb, YES);
    EncRec *er = [EncRec new];
    er.kind = kind;
    pthread_mutex_lock(&g_lock);
    [cr.encoders addObject:er];
    [g_encRecs setObject:er forKey:enc];
    [g_encToCB setObject:cr forKey:enc];
    pthread_mutex_unlock(&g_lock);
    if ([kind isEqualToString:@"compute"]) bindEncoderClass(enc, YES);
    else if ([kind isEqualToString:@"render"]) bindEncoderClass(enc, NO);
    bindFenceHooks(enc, kind);
}

static id my_computeEnc(id self, SEL _cmd) {
    id e = orig_computeEnc(self, _cmd);
    attachEncoder(self, e, @"compute");
    return e;
}
static id my_computeEncDT(id self, SEL _cmd, MTLDispatchType dt) {
    id e = orig_computeEncDT(self, _cmd, dt);
    attachEncoder(self, e, @"compute");
    return e;
}
static id my_computeEncDesc(id self, SEL _cmd, id desc) {
    id e = orig_computeEncDesc(self, _cmd, desc);
    attachEncoder(self, e, @"compute");
    return e;
}
// Defined further down, next to the rest of the counter-sampling machinery.
static uint32_t attachTimestamps(MTLRenderPassDescriptor *desc);
static void     reportEncoderTimes(uint64_t cbSeq, double cbGpuMS);

static id my_renderEnc(id self, SEL _cmd, id desc) {
    attachTimestamps((MTLRenderPassDescriptor *)desc);   // must happen BEFORE the encoder is made
    id e = orig_renderEnc(self, _cmd, desc);
    attachEncoder(self, e, @"render");
    return e;
}
static id my_blitEnc(id self, SEL _cmd) {
    id e = orig_blitEnc(self, _cmd);
    if (t_inKeepalive) return e;
    attachEncoder(self, e, @"blit");
    return e;
}

static void dumpCB(NSString *tag, CBRec *r, double gpuMS, double schedMS, int64_t outNow) {
    logline(@"%@ cb#%llu  gpu=%.1fms sched=%.1fms  outstanding@commit=%lld now=%lld  encoders=%lu  "
             "encode=%.1fms fenceWait=%d fenceUpd=%d eventWait=%d eventSig=%d%@",
            tag, r.seq, gpuMS, schedMS, r.outstandingAtCommit, outNow,
            (unsigned long)r.encoders.count,
            r.createWall > 0 ? (r.commitWall - r.createWall) * 1000.0 : -1.0,
            r.fenceWaits, r.fenceUpdates, r.eventWaits, r.eventSignals,
            r.firstEventWait ? [NSString stringWithFormat:@" firstEventWait=%@", r.firstEventWait] : @"");
    // Compact kind sequence for EVERY encoder, in order, whether or not it recorded work:
    // R=render C=compute B=blit. Needed for composition analysis — the per-pipeline lines below
    // only appear for encoders that recorded a draw/dispatch, so on their own they misrepresent
    // the buffer (they made Sekiro look 100% compute when ~90% of its encoders are render).
    if (r.encoders.count) {
        NSMutableString *seq = [NSMutableString string];
        for (EncRec *e in r.encoders) {
            unichar c = [e.kind isEqualToString:@"render"] ? 'R'
                      : [e.kind isEqualToString:@"compute"] ? 'C' : 'B';
            [seq appendFormat:@"%C", c];
        }
        logline(@"    seq %@", seq);
    }

    NSUInteger i = 0;
    for (EncRec *e in r.encoders) {
        if (e.stats.count == 0) { i++; continue; }
        // Heaviest pipeline first — the answer is almost always the top line.
        NSArray *keys = [e.stats keysSortedByValueUsingComparator:^(NSArray *a, NSArray *b) {
            return [b[1] compare:a[1]];
        }];
        for (NSString *k in keys) {
            NSArray *v = e.stats[k];
            logline(@"    enc[%lu] %@  %@  n=%@ work=%@",
                    (unsigned long)i, e.kind, k, v[0], v[1]);
        }
        i++;
    }
}

// Queue-level hook so we know when the buffer was born, not just when it was committed.
static id (*orig_queueCB)(id, SEL);
// How long [queue commandBuffer] BLOCKS, per queue.
//
// This is the one candidate DXMT-SOURCE-DIG.md flagged and never measured: the resource
// initializer's upload queue is created with maxCommandBufferCount = 2 (kResourceInitializerChunks,
// dxmt_resource_initializer.hpp:13) against the main queue's 32. Metal blocks in `commandBuffer`
// once that many are in flight, so the GAME THREAD stalls there -- while holding mutex_.
//
// It predicts what is actually observed: stalls cluster at area loads and death reloads, which is
// exactly when the asset-upload path is busiest, and the GPU is saturated during a stall because
// the outstanding upload buffers really are executing.
//
// Queues are reported by pointer. The main queue is whichever accumulates the most buffers; a
// long block on any OTHER queue is the upload queue and would settle this.
static double g_qbWarnMS = 100.0;

static id my_queueCB(id self, SEL _cmd) {
    double t0 = nowWall();
    id cb = orig_queueCB(self, _cmd);
    double dtMS = (nowWall() - t0) * 1000.0;
    if (dtMS >= g_qbWarnMS)
        logline(@"QUEUE-BLOCK %.1fms  queue=%p", dtMS, (__bridge void *)self);
    if (cb) {
        CBRec *r = cbRecFor(cb, YES);
        if (r) r.createWall = nowWall();
    }
    return cb;
}

static void my_commit(id self, SEL _cmd) {
    // Our own keep-alive buffers must never enter the statistics.
    if (t_inKeepalive) { orig_commit(self, _cmd); return; }
    atomic_store(&g_lastGameCommit, nowWall());   // feeds the keep-alive idle gate
    CBRec *r = cbRecFor(self, YES);
    int64_t out = atomic_fetch_add(&g_outstanding, 1) + 1;
    int64_t mx  = atomic_load(&g_maxOut);
    while (out > mx && !atomic_compare_exchange_weak(&g_maxOut, &mx, out)) { }
    r.commitWall = nowWall();
    r.outstandingAtCommit = out;

    // Unretained: the command buffer owns the handler block, so capturing `self` strongly here
    // would be a cycle and leak every command buffer the game ever submits.
    void *cbKey = (__bridge void *)self;
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        int64_t outNow = atomic_fetch_sub(&g_outstanding, 1) - 1;
        double gpuMS   = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        double schedMS = (cb.GPUStartTime - cb.kernelEndTime) * 1000.0;
        // RAW timestamps. Added 2026-07-25 because the user reports NO perceptible freeze while
        // this code logs gpu=26000ms+. If GPUStartTime is invalid/stale rather than real, gpuMS is
        // an artifact and the whole "26.4 s stall" is a measurement bug, not an event. Also record
        // wall time either side of the completion handler: a real 26 s GPU wait must show up as
        // ~26 s of wall-clock between commit and completion, and nothing can fake that.
        double rawStart = cb.GPUStartTime, rawEnd = cb.GPUEndTime;
        double rawKern  = cb.kernelEndTime;
        double wallSinceCommit = (nowWall() - r.commitWall) * 1000.0;

        pthread_mutex_lock(&g_lock);
        g_gpuTimeAcc += gpuMS;
        if (gpuMS > g_worstMS) g_worstMS = gpuMS;
        double last = g_lastSummary;
        pthread_mutex_unlock(&g_lock);

        atomic_fetch_add(&g_cbCount, 1);
        unsigned long long seen = atomic_fetch_add(&g_cbTotal, 1);
        if (gpuMS >= g_slowMS) {
            atomic_fetch_add(&g_slowCount, 1);
            logline(@"  RAW cb#%llu gpuStart=%.6f gpuEnd=%.6f kernelEnd=%.6f "
                     "| gpuMS=%.1f  WALL commit->complete=%.1fms",
                    r.seq, rawStart, rawEnd, rawKern, gpuMS, wallSinceCommit);
            dumpCB(@"SLOW", r, gpuMS, schedMS, outNow);
            reportEncoderTimes(r.seq, gpuMS);
        } else if (g_baselineEvery && (seen % g_baselineEvery) == 0) {
            dumpCB(@"BASE", r, gpuMS, schedMS, outNow);
        }

        // Rewind the timestamp slots for the next command buffer. MUST be unconditional: doing it
        // only for slow buffers exhausted all 4096 slots within seconds and silently disabled
        // sampling long before any stall happened.
        if (g_tsBuf && atomic_load(&g_outstanding) <= 1) atomic_store(&g_tsNext, 0);

        double t = nowWall();
        if (t - last >= g_summarySec) {
            pthread_mutex_lock(&g_lock);
            if (nowWall() - g_lastSummary >= g_summarySec) {
                g_lastSummary = t;
                double acc = g_gpuTimeAcc, worst = g_worstMS;
                g_gpuTimeAcc = 0; g_worstMS = 0;
                unsigned long long n = atomic_exchange(&g_cbCount, 0);
                unsigned long long s = atomic_exchange(&g_slowCount, 0);
                int64_t mo = atomic_exchange(&g_maxOut, atomic_load(&g_outstanding));
                pthread_mutex_unlock(&g_lock);
                logline(@"-- %llu cb, %llu slow, gpu %.0fms total, worst %.1fms, maxOutstanding %lld",
                        n, s, acc, worst, mo);
            } else {
                pthread_mutex_unlock(&g_lock);
            }
        }

        pthread_mutex_lock(&g_lock);
        [g_cbRecs removeObjectForKey:(__bridge id)cbKey];
        pthread_mutex_unlock(&g_lock);
    }];

    orig_commit(self, _cmd);
}

// ---------------------------------------------------------------------------- bootstrap

static void bindFenceHooks(id enc, NSString *kind) {
    static dispatch_once_t onceC, onceR, onceB;
    Class cls = object_getClass(enc);
    if ([kind isEqualToString:@"compute"]) {
        dispatch_once(&onceC, ^{
            swizzle(cls, @selector(updateFence:),  (IMP)my_updFenceC,  (IMP *)&orig_updFenceC);
            swizzle(cls, @selector(waitForFence:), (IMP)my_waitFenceC, (IMP *)&orig_waitFenceC);
        });
    } else if ([kind isEqualToString:@"render"]) {
        dispatch_once(&onceR, ^{
            swizzle(cls, @selector(updateFence:afterStages:),   (IMP)my_updFenceR,  (IMP *)&orig_updFenceR);
            swizzle(cls, @selector(waitForFence:beforeStages:), (IMP)my_waitFenceR, (IMP *)&orig_waitFenceR);
        });
    } else {
        dispatch_once(&onceB, ^{
            swizzle(cls, @selector(updateFence:),  (IMP)my_updFenceB,  (IMP *)&orig_updFenceB);
            swizzle(cls, @selector(waitForFence:), (IMP)my_waitFenceB, (IMP *)&orig_waitFenceB);
        });
    }
}

static void bindEncoderClass(id enc, BOOL compute) {
    static dispatch_once_t onceC, onceR;
    if (compute) {
        dispatch_once(&onceC, ^{
            g_compEncCls = object_getClass(enc);
            swizzle(g_compEncCls, @selector(setComputePipelineState:), (IMP)my_setCompPSO,
                    (IMP *)&orig_setCompPSO);
            swizzle(g_compEncCls, @selector(dispatchThreadgroups:threadsPerThreadgroup:),
                    (IMP)my_dispatchTG, (IMP *)&orig_dispatchTG);
            swizzle(g_compEncCls, @selector(dispatchThreads:threadsPerThreadgroup:),
                    (IMP)my_dispatchThreads, (IMP *)&orig_dispatchThreads);
            swizzle(g_compEncCls,
                    @selector(dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:),
                    (IMP)my_dispatchIndirect, (IMP *)&orig_dispatchIndirect);
            swizzle(g_compEncCls, @selector(endEncoding), (IMP)my_compEndEnc,
                    (IMP *)&orig_compEndEnc);
            logline(@"bound compute encoder class %s", class_getName(g_compEncCls));
        });
    } else {
        dispatch_once(&onceR, ^{
            g_rendEncCls = object_getClass(enc);
            swizzle(g_rendEncCls, @selector(setRenderPipelineState:), (IMP)my_setRendPSO,
                    (IMP *)&orig_setRendPSO);
            swizzle(g_rendEncCls, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),
                    (IMP)my_drawPrim, (IMP *)&orig_drawPrim);
            swizzle(g_rendEncCls,
                    @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:),
                    (IMP)my_drawPrimBase, (IMP *)&orig_drawPrimBase);
            swizzle(g_rendEncCls,
                    @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:),
                    (IMP)my_drawIndexedBase, (IMP *)&orig_drawIndexedBase);
            swizzle(g_rendEncCls, @selector(drawPrimitives:indirectBuffer:indirectBufferOffset:),
                    (IMP)my_drawPrimIndirect, (IMP *)&orig_drawPrimIndirect);
            swizzle(g_rendEncCls,
                    @selector(drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:),
                    (IMP)my_drawIndexedIndirect, (IMP *)&orig_drawIndexedIndirect);
            swizzle(g_rendEncCls,
                    @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:),
                    (IMP)my_drawIndexed, (IMP *)&orig_drawIndexed);
            swizzle(g_rendEncCls, @selector(endEncoding), (IMP)my_rendEndEnc,
                    (IMP *)&orig_rendEndEnc);
            logline(@"bound render encoder class %s", class_getName(g_rendEncCls));
        });
    }
}

// ---------------------------------------------------------------------------- in-process keep-alive
//
// WHY IN-PROCESS. The external `gpukeepalive` holds the GPU awake (fixing the ~7 s firmware
// idle-wake freeze) but its PRESENCE correlates with the 26 s submit stalls — and changing its
// interval does not help (50 ms: 0.26 stalls/min, 200 ms: 0.17, off: 0). That points at a second
// PROCESS submitting into the same IOGPU submit path, not at submission volume. This does the
// same job from a thread inside the game, so there is no second process.
//
// Its own submissions are excluded from the profiler via a thread-local, so the baseline and the
// enrichment maths stay honest.
static double g_kaIntervalUS = 0;   // 0 = disabled (default)

// IDLE GATE. The firmware idle-wake freeze needs the GPU to actually go idle, which during
// gameplay only happens in the GAPS — load screens, respawns, menus (exactly where the freezes
// were observed). While the game is rendering it submits ~180 command buffers/sec and the GPU is
// nowhere near idle, so a keep-alive submission then buys nothing and costs a trip through the
// same IOGPU submit path the 26 s stalls block inside.
//
// So: only submit when the GAME has not submitted for a while. We hook every commit, so "when did
// the game last submit" is known exactly — no polling, no utilisation heuristics (which were
// checked and are useless here: the GPU reads <20% util only 4% of play).
// Result: silent during rendering, active only in the gaps. 0 = gate disabled (submit always).
static double g_kaIdleGateMS = 0;

// PERSISTENT OCCUPANCY MODE (GPUSTALL_KEEPALIVE_SPIN_MS).
//
// Every keep-alive variant tried so far POKES the GPU on an interval — and between pokes the GPU
// is free to begin its power-down transition. Measured: 50 ms, 200 ms, in-process, and even a
// 3 ms cadence gated to idle gaps all still stall, while running NO keep-alive for 22.5 min
// produced zero stalls (p=0.04). The common factor is not the rate, it is that a submission keeps
// arriving while the GPU is transitioning.
//
// So instead of poking, OCCUPY: dispatch a compute kernel that deliberately spins for ~spinMS, and
// keep one always in flight. The GPU is then continuously executing, never begins the transition,
// and needs only ~1000/spinMS submissions per second instead of 20+.
static double g_kaSpinMS = 0;

static NSString *kSpinSrc =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void ka_spin(device uint *out [[buffer(0)]],\n"
     "                    constant uint &iters [[buffer(1)]],\n"
     "                    uint tid [[thread_position_in_grid]]) {\n"
     "  uint acc = tid;\n"
     "  for (uint i = 0; i < iters; ++i) { acc = acc * 1664525u + 1013904223u; }\n"
     "  if (acc == 0xFFFFFFFFu) out[0] = acc;   // never true; defeats dead-code elimination\n"
     "}\n";

static void *keepaliveThread(void *ctx) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ctx;
    @autoreleasepool {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        q.label = @"gpustall.keepalive";

        // --- persistent occupancy mode ---------------------------------------------------
        if (g_kaSpinMS > 0) {
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:kSpinSrc options:nil error:&err];
            id<MTLFunction> fn = [lib newFunctionWithName:@"ka_spin"];
            id<MTLComputePipelineState> pso = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
            id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModePrivate];
            if (!pso) { logline(@"keep-alive: spin pipeline failed: %@", err); return NULL; }

            // Calibrate iteration count to the requested duration: run once, measure, scale.
            uint32_t iters = 200000;
            for (int cal = 0; cal < 3; cal++) {
                t_inKeepalive = 1;
                double t0 = nowWall();
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:pso];
                [e setBuffer:out offset:0 atIndex:0];
                [e setBytes:&iters length:sizeof(iters) atIndex:1];
                [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                t_inKeepalive = 0;
                double ms = (nowWall() - t0) * 1000.0;
                if (ms > 0.5) iters = (uint32_t)(iters * (g_kaSpinMS / ms));
                if (iters < 1000) iters = 1000;
            }
            logline(@"keep-alive: PERSISTENT OCCUPANCY — spin %.0f ms/dispatch, iters=%u (~%.1f submits/s)",
                    g_kaSpinMS, iters, 1000.0 / g_kaSpinMS);

            uint64_t n = 0; double lastReport = nowWall(); uint64_t lastN = 0;
            while (1) {
                @autoreleasepool {
                    // Two in flight so the GPU never has an empty moment between dispatches.
                    t_inKeepalive = 1;
                    for (int k = 0; k < 2; k++) {
                        id<MTLCommandBuffer> cb = [q commandBuffer];
                        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                        [e setComputePipelineState:pso];
                        [e setBuffer:out offset:0 atIndex:0];
                        [e setBytes:&iters length:sizeof(iters) atIndex:1];
                        [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
                        [e endEncoding];
                        if (k == 1) [cb addCompletedHandler:^(id<MTLCommandBuffer> c){ (void)c; }];
                        [cb commit];
                        if (k == 1) [cb waitUntilCompleted];   // pace: one spin-length per loop
                        n++;
                    }
                    t_inKeepalive = 0;
                }
                if (nowWall() - lastReport >= 10.0) {
                    lastReport = nowWall();
                    logline(@"keep-alive(spin): %llu dispatches (+%llu in last 10s)", n, n - lastN);
                    lastN = n;
                }
            }
        }
        // --- end persistent occupancy ----------------------------------------------------

        id<MTLBuffer> src = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> dst = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        if (!q || !src || !dst) { logline(@"keepalive: alloc failed"); return NULL; }
        logline(@"in-process keep-alive: interval %.0f us (%.1f/s), idle gate %.0f ms%@",
                g_kaIntervalUS, 1e6 / g_kaIntervalUS, g_kaIdleGateMS,
                g_kaIdleGateMS > 0 ? @" — SILENT while the game is rendering" : @" (always submit)");
        uint64_t n = 0, lastN = 0;
        double lastReport = nowWall();
        while (1) {
            if (g_kaIdleGateMS > 0) {
                double since = (nowWall() - atomic_load(&g_lastGameCommit)) * 1000.0;
                if (since < g_kaIdleGateMS) { usleep((useconds_t)g_kaIntervalUS); continue; }
            }
            @autoreleasepool {
                t_inKeepalive = 1;
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0 size:256];
                [b endEncoding];
                [cb commit];          // committing is what holds the power state; never wait
                t_inKeepalive = 0;
                n++;
            }
            // Time-based, not count-based: with the idle gate on, long stretches produce ZERO
            // submissions, and a count-based log would then never fire — leaving no way to tell
            // "gate working perfectly" apart from "keep-alive thread died".
            if (nowWall() - lastReport >= 10.0) {
                lastReport = nowWall();
                logline(@"keep-alive: %llu submissions total (+%llu in last 10s)", n, n - lastN);
                lastN = n;
            }
            usleep((useconds_t)g_kaIntervalUS);
        }
    }
    return NULL;
}



// ---------------------------------------------------------------------------- per-encoder GPU time
//
// THE QUESTION THIS ANSWERS. As of 2026-07-28 the stall is established as real GPU execution:
// dxmt-finish-thr sleeps in waitUntilCompleted for 91% of it while device_util sits at 98.8%, and
// every CPU-side path (upload queue, drawable, submit, mutex, paging) has been measured and
// cleared. What is still unknown is WHICH of the ~80-130 encoders in the buffer eats the 26.5 s.
//
// MTLCounterSamplingPointAtStageBoundary is supported on this M5 (probed), so a timestamp can be
// taken either side of each render encoder. That turns "this buffer took 26.5 s" into "encoder #37
// running pipeline X took 26.4 s of it" -- which is one shader to look at instead of a hundred.
//
// RENDER ENCODERS ONLY, deliberately. Stalled buffers measure ~94% render, and compute would need
// the descriptor-taking variant of computeCommandEncoder, which DXMT does not always use. Scope
// kept small so this cannot change what the game renders.

typedef struct { uint32_t idx; uint64_t cbSeq; uint32_t ord; } TSRec;
static TSRec  g_tsRecs[TS_SLOTS/2];
static _Atomic(uint32_t) g_tsRecN = 0;

static void setupCounterBuffer(id<MTLDevice> dev) {
    if (!getenv("GPUSTALL_ENCODER_TIMING")) return;      // opt-in: it mutates the game's descriptors
    id<MTLCounterSet> ts = nil;
    for (id<MTLCounterSet> cs in dev.counterSets)
        if ([cs.name isEqualToString:@"timestamp"]) { ts = cs; break; }
    if (!ts) { logline(@"encoder timing: no timestamp counter set"); return; }
    if (![dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
        logline(@"encoder timing: stage-boundary sampling unsupported"); return;
    }
    MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = ts; d.sampleCount = TS_SLOTS; d.storageMode = MTLStorageModeShared;
    NSError *err = nil;
    g_tsBuf = [dev newCounterSampleBufferWithDescriptor:d error:&err];
    if (!g_tsBuf) { logline(@"encoder timing: buffer failed: %@", err); return; }
    g_tsCap = TS_SLOTS;
    logline(@"encoder timing ARMED (%u slots)", g_tsCap);
}

// Returns the base index used, or UINT32_MAX if not sampling this encoder.
static _Atomic(uint32_t) g_tsAttached = 0, g_tsBailNoBuf = 0, g_tsBailInUse = 0, g_tsBailFull = 0;

static uint32_t attachTimestamps(MTLRenderPassDescriptor *desc) {
    if (!g_tsBuf || !desc) { atomic_fetch_add(&g_tsBailNoBuf, 1); return UINT32_MAX; }
    // Never clobber a sample buffer the app set up itself.
    if (desc.sampleBufferAttachments[0].sampleBuffer != nil) { atomic_fetch_add(&g_tsBailInUse, 1); return UINT32_MAX; }
    uint32_t i = atomic_fetch_add(&g_tsNext, 2);
    if (i + 1 >= g_tsCap) { atomic_fetch_add(&g_tsBailFull, 1); return UINT32_MAX; }
    atomic_fetch_add(&g_tsAttached, 1);
    desc.sampleBufferAttachments[0].sampleBuffer = g_tsBuf;
    desc.sampleBufferAttachments[0].startOfVertexSampleIndex   = i;
    desc.sampleBufferAttachments[0].endOfVertexSampleIndex     = MTLCounterDontSample;
    desc.sampleBufferAttachments[0].startOfFragmentSampleIndex = MTLCounterDontSample;
    desc.sampleBufferAttachments[0].endOfFragmentSampleIndex   = i + 1;
    return i;
}

// Called from the completion handler. Deltas are raw GPU ticks; they are calibrated against the
// command buffer's own GPUStartTime/GPUEndTime rather than assumed to be nanoseconds.
static void reportEncoderTimes(uint64_t cbSeq, double cbGpuMS) {
    if (!g_tsBuf) return;
    uint32_t n = atomic_load(&g_tsNext);
    if (n < 2) { logline(@"  ENCDIAG nothing sampled (n=%u attached=%u bailInUse=%u bailFull=%u)",
                          n, atomic_load(&g_tsAttached), atomic_load(&g_tsBailInUse),
                          atomic_load(&g_tsBailFull)); return; }
    NSData *raw = [g_tsBuf resolveCounterRange:NSMakeRange(0, n)];
    logline(@"  ENCDIAG attached=%u bailNoBuf=%u bailInUse=%u bailFull=%u n=%u rawLen=%lu",
            atomic_load(&g_tsAttached), atomic_load(&g_tsBailNoBuf),
            atomic_load(&g_tsBailInUse), atomic_load(&g_tsBailFull), n,
            (unsigned long)(raw ? raw.length : 0));
    if (!raw) return;
    const MTLCounterResultTimestamp *t = (const MTLCounterResultTimestamp *)raw.bytes;
    uint32_t pairs = (uint32_t)(raw.length / sizeof(MTLCounterResultTimestamp)) / 2;
    uint64_t span = 0, worst = 0; uint32_t worstIdx = 0;
    for (uint32_t k = 0; k < pairs; k++) {
        uint64_t a = t[2*k].timestamp, b = t[2*k+1].timestamp;
        if (!a || !b || b <= a) continue;                // unresolved slots read back as 0
        uint64_t d = b - a;
        span += d;
        if (d > worst) { worst = d; worstIdx = k; }
    }
    if (!span) { logline(@"  ENCDIAG all %u pairs unresolved (span=0)", pairs); return; }
    double ticksPerMS = (double)span / (cbGpuMS > 0 ? cbGpuMS : 1.0);
    logline(@"  ENCTIME cb#%llu worst=enc[%u] %.1fms of %.1fms (%.0f%%)  pairs=%u",
            cbSeq, worstIdx, worst / ticksPerMS, cbGpuMS,
            100.0 * (double)worst / (double)span, pairs);
}

// ---------------------------------------------------------------------------- drawable blocking
//
// WHY THIS EXISTS. Command-buffer SIZE was falsified on 2026-07-28: DXVK builds bigger buffers than
// DXMT (max 393 vs 233) on identical wine/prefix/Steam/GPU/game and never stalls. So the stall is
// not about how much work is batched. What survives is the shape of the stall itself -- one submit
// blocked in IOConnectTrap4 with the encode thread idle and the chunk ring nearly empty, i.e.
// waiting on something EXTERNAL to DXMT.
//
// Drawable acquisition is exactly such a thing, and it is the one blocking path this project has
// never measured. DXMT computes `drawable_blocking_interval` itself but the HUD counters are
// `#ifndef DXMT_DEBUG` no-ops in release builds. Hooking CAMetalLayer directly gets the same number
// out of a stock DXMT, and works for DXVK and D3DMetal too, so layers stay comparable.
//
// The user also observed the Metal HUD flipping Direct <-> Composited during play, and the HUD
// freezing. Both are display-side reconfigurations, and both would show up here as a long
// nextDrawable.
static IMP    g_origNextDrawable = NULL;
static double g_drawableWarnMS   = 100.0;
static _Atomic(uint64_t) g_drawableBlocks = 0;
static _Atomic(uint64_t) g_drawableWorstUS = 0;

// NOT ns_returns_retained: -[CAMetalLayer nextDrawable] returns an autoreleased +0 object, unlike
// the MTLDevice creators above. Returning void* keeps ARC out of the ownership decision entirely.
static void *my_nextDrawable(id self, SEL _cmd) {
    double t0 = nowWall();
    void *d = ((void *(*)(id, SEL))g_origNextDrawable)(self, _cmd);
    double dtMS = (nowWall() - t0) * 1000.0;
    if (dtMS >= g_drawableWarnMS) {
        atomic_fetch_add(&g_drawableBlocks, 1);
        uint64_t us = (uint64_t)(dtMS * 1000.0), prev = atomic_load(&g_drawableWorstUS);
        while (us > prev && !atomic_compare_exchange_weak(&g_drawableWorstUS, &prev, us)) {}
        logline(@"DRAWABLE-BLOCK %.1fms   drawable=%s", dtMS, d ? "ok" : "NIL");
    }
    return d;
}

static void installDrawableHook(void) {
    Class cls = objc_getClass("CAMetalLayer");
    if (!cls) { logline(@"drawable hook: CAMetalLayer not found"); return; }
    if (getenv("GPUSTALL_DRAWABLE_MS")) g_drawableWarnMS = atof(getenv("GPUSTALL_DRAWABLE_MS"));
    if (getenv("GPUSTALL_QUEUE_MS")) g_qbWarnMS = atof(getenv("GPUSTALL_QUEUE_MS"));
    if (swizzle(cls, @selector(nextDrawable), (IMP)my_nextDrawable, &g_origNextDrawable))
        logline(@"drawable hook armed (warn >= %.0fms)", g_drawableWarnMS);
    else
        logline(@"drawable hook FAILED to install");
}

static void bootstrap(id<MTLDevice> dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_cbRecs    = mkTable();
        g_encRecs   = mkTable();
        g_encToCB   = mkTable();
        g_pipeNames = mkTable();

        // Display-side blocking. Installed here rather than at load time because CAMetalLayer is
        // only guaranteed to be present once something has actually touched Metal.
        installDrawableHook();
        setupCounterBuffer(dev);

        Class devCls = object_getClass(dev);
        swizzle(devCls, @selector(newComputePipelineStateWithFunction:error:),
                (IMP)my_newCompPSO_fn_err, (IMP *)&orig_newCompPSO_fn_err);
        swizzle(devCls, @selector(newComputePipelineStateWithFunction:options:reflection:error:),
                (IMP)my_newCompPSO_fn_opt, (IMP *)&orig_newCompPSO_fn_opt);
        swizzle(devCls, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:),
                (IMP)my_newCompPSO_desc, (IMP *)&orig_newCompPSO_desc);
        swizzle(devCls, @selector(newRenderPipelineStateWithDescriptor:error:),
                (IMP)my_newRendPSO_desc_err, (IMP *)&orig_newRendPSO_desc_err);
        swizzle(devCls, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:),
                (IMP)my_newRendPSO_desc_opt, (IMP *)&orig_newRendPSO_desc_opt);

        // The concrete command-buffer class is private (AGXG*FamilyCommandBuffer) and cannot be
        // named at compile time — make one throwaway buffer and read its class off the instance.
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        Class cbCls = object_getClass(cb);

        swizzle(object_getClass(q), @selector(commandBuffer), (IMP)my_queueCB, (IMP *)&orig_queueCB);
        swizzle(cbCls, @selector(commit), (IMP)my_commit, (IMP *)&orig_commit);
        swizzle(cbCls, @selector(computeCommandEncoder), (IMP)my_computeEnc,
                (IMP *)&orig_computeEnc);
        swizzle(cbCls, @selector(computeCommandEncoderWithDispatchType:), (IMP)my_computeEncDT,
                (IMP *)&orig_computeEncDT);
        swizzle(cbCls, @selector(computeCommandEncoderWithDescriptor:), (IMP)my_computeEncDesc,
                (IMP *)&orig_computeEncDesc);
        swizzle(cbCls, @selector(renderCommandEncoderWithDescriptor:), (IMP)my_renderEnc,
                (IMP *)&orig_renderEnc);
        swizzle(cbCls, @selector(blitCommandEncoder), (IMP)my_blitEnc, (IMP *)&orig_blitEnc);
        swizzle(cbCls, @selector(encodeWaitForEvent:value:),  (IMP)my_encWaitEvent,   (IMP *)&orig_encWaitEvent);
        swizzle(cbCls, @selector(encodeSignalEvent:value:),   (IMP)my_encSignalEvent, (IMP *)&orig_encSignalEvent);

        if (g_kaIntervalUS > 0) {
            pthread_t th;
            pthread_create(&th, NULL, keepaliveThread, (__bridge void *)dev);
            pthread_detach(th);
        }

        g_lastSummary = nowWall();
        logline(@"armed on %@ — cb class %s, slow threshold %.0fms, argv=%@",
                dev.name, class_getName(cbCls), g_slowMS, g_argvDesc);
    });
}

// ---------------------------------------------------------------------------- entry

static void captureArgv(void) {
    NSMutableString *s = [NSMutableString string];
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 0; i < argc && i < 6; i++) {
        if (argv[i]) [s appendFormat:@"%s ", argv[i]];
    }
    g_argvDesc = s.length ? [s copy] : @"<empty>";
}

// DO NOT GATE ON argv. The first version matched _NSGetArgv() against "sekiro.exe" and never
// armed in the real game: wine rewrites the *displayed* command line, so what `ps`/`pgrep -f`
// show is not what the process sees at dyld-constructor time. A whole play session was recorded
// as nothing because of that assumption.
//
// Instead, arm on the thing we actually care about — the process creating a Metal device. Only a
// real renderer does that, so the wine helpers (services.exe, winedevice.exe, explorer.exe) never
// arm no matter what their argv looks like. gpukeepalive DOES use Metal and would otherwise bury
// the baseline in 20 trivial blits/sec, so it stays excluded, by argv, as a narrow special case.
static BOOL excluded(void) {
    const char *skip = getenv("GPUSTALL_EXCLUDE");
    if (!skip) skip = "gpukeepalive";
    if (!*skip) return NO;
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 0; i < argc; i++) {
        if (argv[i] && strcasestr(argv[i], skip)) return YES;
    }
    return NO;
}

__attribute__((constructor)) static void gpustall_init(void) {
    captureArgv();
    if (excluded()) return;

    const char *lp = getenv("GPUSTALL_LOG");
    NSString *path = lp ? @(lp)
        : [NSHomeDirectory() stringByAppendingPathComponent:
           @"Library/Application Support/Decanter/gpustall.log"];
    g_fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);

    if (getenv("GPUSTALL_SLOW_MS")) g_slowMS = atof(getenv("GPUSTALL_SLOW_MS"));
    if (getenv("GPUSTALL_SUMMARY_SEC")) g_summarySec = atof(getenv("GPUSTALL_SUMMARY_SEC"));
    if (getenv("GPUSTALL_KEEPALIVE_US")) g_kaIntervalUS = atof(getenv("GPUSTALL_KEEPALIVE_US"));
    if (getenv("GPUSTALL_KEEPALIVE_IDLE_MS")) g_kaIdleGateMS = atof(getenv("GPUSTALL_KEEPALIVE_IDLE_MS"));
    if (getenv("GPUSTALL_KEEPALIVE_SPIN_MS")) g_kaSpinMS = atof(getenv("GPUSTALL_KEEPALIVE_SPIN_MS"));
    if (getenv("GPUSTALL_BASELINE_EVERY")) g_baselineEvery = strtoull(getenv("GPUSTALL_BASELINE_EVERY"), NULL, 10);

    g_armed = YES;
    // Proves the dylib actually loaded into this process, and shows the REAL argv — the thing the
    // old gate got wrong. Off by default (every wine helper would write one); turn on with
    // GPUSTALL_VERBOSE=1 when verifying that injection reached the game.
    if (getenv("GPUSTALL_VERBOSE")) logline(@"loaded argv=%@", g_argvDesc);
}

// MTLCopyAllDevices is what winemetal.so imports (verified with nm -u), so it is the one call
// guaranteed to happen before any DXMT rendering.
//
// ns_returns_retained IS LOAD-BEARING. Both of these are declared NS_RETURNS_RETAINED in
// MTLDevice.h — the caller owns the result and will release it. Without the attribute ARC hands
// back a +0 autoreleased object, the caller's release lands on an object nobody retained, and the
// process dies in objc_autoreleasePoolPop. Every selftest run segfaulted at exit until this was
// added, while the same binary with no dylib injected exited 0.
__attribute__((ns_returns_retained))
static NSArray *my_MTLCopyAllDevices(void) {
    NSArray *devs = MTLCopyAllDevices();
    if (g_armed && devs.count) bootstrap(devs[0]);
    return devs;
}
DYLD_INTERPOSE(my_MTLCopyAllDevices, MTLCopyAllDevices)

// Belt and braces: if a future DXMT switches to the system-default path, still arm.
__attribute__((ns_returns_retained))
static id my_MTLCreateSystemDefaultDevice(void) {
    id dev = MTLCreateSystemDefaultDevice();
    if (g_armed && dev) bootstrap(dev);
    return dev;
}
DYLD_INTERPOSE(my_MTLCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice)
