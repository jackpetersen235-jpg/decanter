// window-hook — makes a Wine game window eligible for native macOS fullscreen (the green button).
// Shipped as Decanter.app/Contents/Resources/WindowHook/libwindowhook.dylib and injected into
// games launched with BottleSettings.nativeWindow ("Real game window"); built by make_app.sh.
// Started life as Scripts/sekiro/fsforce.m, the experiment that proved it (2026-10-12).
//
// WHY. -[WineWindow adjustFullScreenBehavior:] in the shipped winemac.so (disassembled 2026-09-01,
// imp 0x163c0) only grants NSWindowCollectionBehaviorFullScreenPrimary — the live green button —
// when the window's styleMask is exactly Resizable-and-not-Utility, it is not maximized, and it has
// no parent window. Sekiro in its own windowed mode gets a normal titled window but, like most
// games, no resize border (no WS_THICKFRAME): measured styleMask 0x7, so macdrv builds a
// non-resizable NSWindow and the button stays dead. No Wine registry value controls this.
//
// WHAT. Two hooks on WineWindow, applied only to top-level TITLED windows (the game window; Wine's
// borderless helper windows are left alone):
//   setStyleMask:          OR in NSWindowStyleMaskResizable
//   setCollectionBehavior: swap FullScreenAuxiliary for FullScreenPrimary
// With Resizable set, Wine's own gate computes Primary by itself; the second hook is a backstop.
//
// TIMING — the bug the first version had. A DYLD_INSERT_LIBRARIES constructor runs before main,
// but WineWindow lives in winemac.so, which Wine dlopens much later (when user32 starts the display
// driver). Looking the class up in the constructor returns nil and hooks nothing. So the
// constructor only starts a background poll; hooks install the moment the class exists.
//
// LOG + TEST CHANNEL — both OFF unless $DECANTER_WINDOWHOOK_DIR is set, so an ordinary play
// session does no file I/O at all. With it set, the hook logs to <dir>/windowhook-<pid>.log
// (only when it actually changes a window) and polls <dir>/windowhook-<pid>.cmd; write a word
// into that file and it runs on the Cocoa main thread:
//   dump    — log every WineWindow: title, styleMask, collectionBehavior, zoom-button enabled
//   enter   — activate the app, bring the game window forward, and put it into native fullscreen
//             (no-op if already fullscreen), then dump 3 s later
//   exit    — leave native fullscreen (no-op if already windowed), then dump 3 s later
//   toggle  — dump, then toggleFullScreen: the visible titled top-level window (what the green
//             button does), then dump again 3 s later. Prefer enter/exit: toggle flips blindly.
//   size W H — setContentSize: the game window to W×H points, then dump 3 s later: shows whether
//             the game re-renders at a new window size (works with the screen locked)
// Signals are NOT used for this: Wine uses SIGUSR1 itself (thread suspend), so a file is the safe
// channel. A background app also cannot activate itself on macOS 14+ (cooperative activation —
// activateIgnoringOtherApps: is ignored), so `enter` on a game that isn't already frontmost puts
// the window into a fullscreen Space nobody is looking at; activate it first through
// LaunchServices (`open` its bundle) or a click.
//
// DELIBERATELY NO AppKit/Foundation LINK. Everything goes through the objc runtime by name, so
// injecting this does not load AppKit early and perturb Wine's own Cocoa start-up ordering.
//
// LAUNCH TRAP. Never start the injected process through an Apple system binary (nohup, env, bash
// -c, …): SIP strips every DYLD_* variable when it execs one, and the library silently never
// loads. That exact mistake cost the first test run. Exec wine directly.
//
// MUST BE x86_64 (the wine tree runs under Rosetta; dyld refuses a mismatched inserted library).
//
// OPT-IN, NOT DEFAULT. This overrides a third-party runtime's own window-management decision, so
// it only ever runs for a bottle that turned "Real game window" on.

#include <objc/runtime.h>
#include <objc/message.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <time.h>

typedef unsigned long NSUIntegerT;
typedef signed char   BOOLT;

#define STYLE_TITLED       (1UL << 0)
#define STYLE_RESIZABLE    (1UL << 3)
#define STYLE_FULLSCREEN   (1UL << 14)
#define CB_FS_PRIMARY      (1UL << 7)
#define CB_FS_AUXILIARY    (1UL << 8)
#define ZOOM_BUTTON        2         /* NSWindowZoomButton */

#define POLL_INTERVAL_NS   (250ull * NSEC_PER_MSEC)
#define POLL_GIVE_UP_NS    (300ull * NSEC_PER_SEC)
#define CMD_INTERVAL_NS    (500ull * NSEC_PER_MSEC)

static char gLogPath[1024];   // empty = logging and the command channel are off
static char gCmdPath[1024];
static Class gWineWindow;
static IMP gOrigSetStyleMask;
static IMP gOrigSetCollectionBehavior;

static void flog(const char *fmt, ...) {
    if (!gLogPath[0]) return;
    FILE *f = fopen(gLogPath, "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tmv);
    fprintf(f, "[%s] ", stamp);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// ── tiny typed wrappers over objc_msgSend ────────────────────────────────────

static id msg_id(id obj, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static NSUIntegerT msg_uint(id obj, const char *sel) {
    return ((NSUIntegerT (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static BOOLT msg_bool(id obj, const char *sel) {
    return ((BOOLT (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static const char *msg_title(id window) {
    id title = msg_id(window, "title");
    if (!title) return "";
    const char *s = ((const char *(*)(id, SEL))objc_msgSend)(title, sel_registerName("UTF8String"));
    return s ? s : "";
}

// Struct returns. A two-double NSSize comes back in registers; a four-double NSRect is returned
// through memory on x86_64, which needs objc_msgSend_stret. This file only ever builds x86_64.
typedef struct { double width, height; } SizeT;
typedef struct { double x, y, width, height; } RectT;
static SizeT msg_size(id obj, const char *sel) {
    return ((SizeT (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static RectT msg_rect(id obj, const char *sel) {
    return ((RectT (*)(id, SEL))objc_msgSend_stret)(obj, sel_registerName(sel));
}

static bool isTopLevel(id window) {
    return msg_id(window, "parentWindow") == nil;
}

// ── the two hooks ────────────────────────────────────────────────────────────

static void hook_setStyleMask(id self, SEL _cmd, NSUIntegerT mask) {
    NSUIntegerT forced = mask;
    if ((mask & STYLE_TITLED) && isTopLevel(self)) {
        forced |= STYLE_RESIZABLE;
    }
    if (forced != mask) {
        flog("styleMask 0x%lx -> 0x%lx on \"%s\"", mask, forced, msg_title(self));
    }
    ((void (*)(id, SEL, NSUIntegerT))gOrigSetStyleMask)(self, _cmd, forced);
}

static void hook_setCollectionBehavior(id self, SEL _cmd, NSUIntegerT behavior) {
    NSUIntegerT forced = behavior;
    NSUIntegerT mask = msg_uint(self, "styleMask");
    if ((mask & STYLE_TITLED) && isTopLevel(self)) {
        forced = (forced & ~CB_FS_AUXILIARY) | CB_FS_PRIMARY;
    }
    if (forced != behavior) {
        flog("collectionBehavior 0x%lx -> 0x%lx on \"%s\"", behavior, forced, msg_title(self));
    }
    ((void (*)(id, SEL, NSUIntegerT))gOrigSetCollectionBehavior)(self, _cmd, forced);
}

static bool replace(Class cls, const char *selName, IMP newImp, IMP *orig) {
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return false;
    *orig = class_getMethodImplementation(cls, sel);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    return true;
}

// ── window inspection / the test command channel (main thread only) ─────────

static id appWindows(void) {
    Class app = objc_getClass("NSApplication");
    if (!app) return nil;
    id shared = msg_id((id)app, "sharedApplication");
    return shared ? msg_id(shared, "windows") : nil;
}

static void dumpWindows(const char *label) {
    id windows = appWindows();
    NSUIntegerT count = windows ? msg_uint(windows, "count") : 0;
    flog("--- %s: %lu window(s) ---", label, count);
    for (NSUIntegerT i = 0; i < count; i++) {
        id w = ((id (*)(id, SEL, NSUIntegerT))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), i);
        BOOLT isWine = ((BOOLT (*)(id, SEL, Class))objc_msgSend)(w, sel_registerName("isKindOfClass:"), gWineWindow);
        if (!isWine) continue;
        id zoom = ((id (*)(id, SEL, NSUIntegerT))objc_msgSend)(w, sel_registerName("standardWindowButton:"), ZOOM_BUTTON);
        flog("  \"%s\" visible=%d topLevel=%d styleMask=0x%lx resizable=%d fullscreen=%d "
             "behavior=0x%lx primary=%d auxiliary=%d zoomButton=%s",
             msg_title(w), msg_bool(w, "isVisible"), isTopLevel(w),
             msg_uint(w, "styleMask"),
             (msg_uint(w, "styleMask") & STYLE_RESIZABLE) != 0,
             (msg_uint(w, "styleMask") & STYLE_FULLSCREEN) != 0,
             msg_uint(w, "collectionBehavior"),
             (msg_uint(w, "collectionBehavior") & CB_FS_PRIMARY) != 0,
             (msg_uint(w, "collectionBehavior") & CB_FS_AUXILIARY) != 0,
             zoom ? (msg_bool(zoom, "isEnabled") ? "ENABLED" : "disabled") : "absent");
        RectT frame = msg_rect(w, "frame");
        RectT content = msg_rect(msg_id(w, "contentView"), "frame");
        SizeT maxSize = msg_size(w, "contentMaxSize");
        SizeT minSize = msg_size(w, "contentMinSize");
        flog("    frame=%.0fx%.0f content=%.0fx%.0f contentMin=%.0fx%.0f contentMax=%.0fx%.0f",
             frame.width, frame.height, content.width, content.height,
             minSize.width, minSize.height, maxSize.width, maxSize.height);
    }
}

static id gameWindow(void);

// Resize the game window's content area the way entering fullscreen would. Answers "does the game
// re-render at the new size, or keep its own fixed size?" without a visible screen.
static void resizeContent(double width, double height) {
    id w = gameWindow();
    if (!w) {
        flog("size: no visible titled top-level WineWindow found");
        return;
    }
    flog("size: setContentSize %.0fx%.0f on \"%s\"", width, height, msg_title(w));
    SizeT size = { width, height };
    ((void (*)(id, SEL, SizeT))objc_msgSend)(w, sel_registerName("setContentSize:"), size);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        dumpWindows("3s after size");
    });
}

static id gameWindow(void) {
    id windows = appWindows();
    NSUIntegerT count = windows ? msg_uint(windows, "count") : 0;
    for (NSUIntegerT i = 0; i < count; i++) {
        id w = ((id (*)(id, SEL, NSUIntegerT))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), i);
        BOOLT isWine = ((BOOLT (*)(id, SEL, Class))objc_msgSend)(w, sel_registerName("isKindOfClass:"), gWineWindow);
        if (isWine && msg_bool(w, "isVisible") && isTopLevel(w)
            && (msg_uint(w, "styleMask") & STYLE_TITLED) && msg_title(w)[0] != '\0') {
            return w;
        }
    }
    return nil;
}

static void activateApp(void) {
    Class app = objc_getClass("NSApplication");
    id shared = app ? msg_id((id)app, "sharedApplication") : nil;
    if (shared) {
        ((void (*)(id, SEL, BOOLT))objc_msgSend)(shared, sel_registerName("activateIgnoringOtherApps:"), 1);
    }
}

static bool isFullscreen(id w) {
    return (msg_uint(w, "styleMask") & STYLE_FULLSCREEN) != 0;
}

static void setFullscreen(bool wanted) {
    id w = gameWindow();
    if (!w) {
        flog("%s: no visible titled top-level WineWindow found", wanted ? "enter" : "exit");
        return;
    }
    if (isFullscreen(w) == wanted) {
        flog("%s: \"%s\" already %s — nothing to do", wanted ? "enter" : "exit", msg_title(w),
             wanted ? "fullscreen" : "windowed");
        return;
    }
    if (wanted) {
        activateApp();
        ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("makeKeyAndOrderFront:"), nil);
    }
    flog("%s: toggleFullScreen: on \"%s\"", wanted ? "enter" : "exit", msg_title(w));
    ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("toggleFullScreen:"), nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        dumpWindows(wanted ? "3s after enter" : "3s after exit");
    });
}

// Experiment: lift Wine's content min/max pin on the live game window only (no hook), so a
// following `size` shows whether the game re-renders at a bigger window size.
static void unpinContent(void) {
    id w = gameWindow();
    if (!w) {
        flog("unpin: no visible titled top-level WineWindow found");
        return;
    }
    SizeT small = { 320, 180 }, huge = { 100000, 100000 };
    ((void (*)(id, SEL, SizeT))objc_msgSend)(w, sel_registerName("setContentMinSize:"), small);
    ((void (*)(id, SEL, SizeT))objc_msgSend)(w, sel_registerName("setContentMaxSize:"), huge);
    flog("unpin: content min/max lifted on \"%s\"", msg_title(w));
    dumpWindows("after unpin");
}

static void runCommand(const char *cmd) {
    double width = 0, height = 0;
    if (sscanf(cmd, "size %lf %lf", &width, &height) == 2) {
        resizeContent(width, height);
    } else if (strcmp(cmd, "unpin") == 0) {
        unpinContent();
    } else if (strcmp(cmd, "dump") == 0) {
        dumpWindows("dump");
    } else if (strcmp(cmd, "enter") == 0) {
        setFullscreen(true);
    } else if (strcmp(cmd, "exit") == 0) {
        setFullscreen(false);
    } else if (strcmp(cmd, "toggle") == 0) {
        dumpWindows("before toggle");
        id w = gameWindow();
        if (!w) {
            flog("toggle: no visible titled top-level WineWindow found");
            return;
        }
        flog("toggle: toggleFullScreen: on \"%s\"", msg_title(w));
        ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("toggleFullScreen:"), nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            dumpWindows("3s after toggle");
        });
    } else {
        flog("unknown command \"%s\" (expected dump|enter|exit|toggle|size W H)", cmd);
    }
}

static void pollCommands(void) {
    FILE *f = fopen(gCmdPath, "r");
    if (f) {
        char buf[64] = {0};
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        unlink(gCmdPath);
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) buf[--n] = '\0';
        char *cmd = strdup(buf);
        dispatch_async(dispatch_get_main_queue(), ^{
            runCommand(cmd);
            free(cmd);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CMD_INTERVAL_NS),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ pollCommands(); });
}

// ── install, once WineWindow exists ──────────────────────────────────────────

static void tryInstall(uint64_t waitedNs) {
    Class cls = objc_getClass("WineWindow");
    if (cls) {
        gWineWindow = cls;
        bool style = replace(cls, "setStyleMask:", (IMP)hook_setStyleMask, &gOrigSetStyleMask);
        bool behavior = replace(cls, "setCollectionBehavior:", (IMP)hook_setCollectionBehavior,
                                &gOrigSetCollectionBehavior);
        flog("installed on WineWindow after %.1fs (setStyleMask hook=%d, setCollectionBehavior hook=%d)",
             waitedNs / 1e9, style, behavior);
        if (gCmdPath[0]) pollCommands();
        return;
    }
    if (waitedNs >= POLL_GIVE_UP_NS) {
        flog("WineWindow never appeared within %llus — not a Cocoa-windowed process, giving up",
             POLL_GIVE_UP_NS / NSEC_PER_SEC);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, POLL_INTERVAL_NS),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                   ^{ tryInstall(waitedNs + POLL_INTERVAL_NS); });
}

__attribute__((constructor))
static void windowhook_load(void) {
    const char *dir = getenv("DECANTER_WINDOWHOOK_DIR");
    if (dir && *dir) {
        snprintf(gLogPath, sizeof gLogPath, "%s/windowhook-%d.log", dir, getpid());
        snprintf(gCmdPath, sizeof gCmdPath, "%s/windowhook-%d.cmd", dir, getpid());
    }
    flog("loaded into pid %d — waiting for WineWindow", getpid());
    tryInstall(0);
}
