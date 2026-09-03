#import "DYCrashLog.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import <fcntl.h>

// execinfo.h (backtrace/backtrace_symbols) is present in some iOS SDKs and absent
// in others. Guard on it so the module compiles either way; without it we still
// capture the signal number and let the OS crash report carry the native trace.
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define DY_HAVE_BACKTRACE 1
#endif

// Resolved at install time and stored as a plain C string so the handlers (which
// may run inside a signal context) can use it without touching Foundation.
static char gCrashPath[1024];
static int gInstalled = 0;
// Saved previous dispositions so we can chain to whatever was there before us
// (the app's own crash reporter, other tweaks) instead of swallowing their handler.
static void (*gPrevSig[32])(int);

static void DYWriteRaw(const char *data, size_t len) {
    if (gCrashPath[0] == '\0' || len == 0) return;
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n <= 0) break;
        written += (size_t)n;
    }
    close(fd);
}

static void DYWriteLine(const char *line) {
    if (!line) return;
    DYWriteRaw(line, strlen(line));
    DYWriteRaw("\n", 1);
}

static void DYWriteBanner(const char *kind) {
    time_t t = time(NULL);
    struct tm tmBuf;
    localtime_r(&t, &tmBuf);
    char stamp[64];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tmBuf);
    char header[320];
    snprintf(header, sizeof(header),
             "=== DYLuckyBag crash breadcrumb (%s) %s ===", kind, stamp);
    DYWriteLine(header);
}

static void DYWriteBacktrace(void **frames, int count) {
#ifdef DY_HAVE_BACKTRACE
    if (count <= 0) return;
    char **syms = backtrace_symbols(frames, count);
    for (int i = 0; i < count; i++) {
        if (syms && syms[i]) DYWriteLine(syms[i]);
        else { char b[32]; snprintf(b, sizeof(b), "#%d <unknown>", i); DYWriteLine(b); }
    }
    if (syms) free(syms);
#else
    (void)frames; (void)count;
    DYWriteLine("(native backtrace unavailable: execinfo.h absent from this SDK)");
#endif
}

static const char *DYSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        default:      return "?";
    }
}

static void DYSignalHandler(int sig) {
    DYWriteBanner("signal");
    char line[160];
    snprintf(line, sizeof(line), "signal = %d (%s)  pid=%d",
             sig, DYSignalName(sig), (int)getpid());
    DYWriteLine(line);
    DYWriteLine("Low-level fault class — @try/@catch cannot catch this (e.g. EXC_BAD_ACCESS"
                " on a stale/torn-down view or a zombie delegate).");
    DYWriteLine("The OS crash report for this process also holds the full native backtrace.");
#ifdef DY_HAVE_BACKTRACE
    void *frames[64];
    int n = backtrace(frames, 64);
    DYWriteBacktrace(frames, n);
#endif
    DYWriteLine("=== end breadcrumb ===");

    // Chain to whatever was installed before us (app reporter / other tweak),
    // otherwise restore the default disposition and re-raise so the OS still
    // produces its own full crash report.
    void (*prev)(int) = (sig >= 0 && sig < 32) ? gPrevSig[sig] : NULL;
    if (prev && prev != SIG_DFL && prev != SIG_IGN) {
        prev(sig);
    } else {
        signal(sig, SIG_DFL);
        raise(sig);
    }
}

static void DYUncaughtHandler(NSException *exception) {
    DYWriteBanner("NSException");
    DYWriteLine([[exception name] UTF8String] ?: "?");
    DYWriteLine([[exception reason] UTF8String] ?: "?");
    NSArray<NSString *> *syms = [exception callStackSymbols];
    if (syms.count) {
        DYWriteLine("call stack:");
        for (NSString *s in syms) DYWriteLine([s UTF8String]);
    } else {
        DYWriteLine("(no call stack symbols available)");
    }
    DYWriteLine("=== end breadcrumb ===");
}

static void DYResolvePath(void) {
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/dyluckybag_crash.log",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dyluckybag_crash.log"],
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"dyluckybag_crash.log"],
    ];
    for (NSString *path in candidates) {
        const char *fs = [path fileSystemRepresentation];
        if (!fs) continue;
        int fd = open(fs, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            close(fd);
            strncpy(gCrashPath, fs, sizeof(gCrashPath) - 1);
            gCrashPath[sizeof(gCrashPath) - 1] = '\0';
            return;
        }
    }
    // Unresolved: handlers become no-ops, which is safe.
}

void DYCrashLogInstall(void) {
    if (gInstalled) return;
    gInstalled = 1;

    DYResolvePath();

    NSSetUncaughtExceptionHandler(DYUncaughtHandler);

    int signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(signals) / sizeof(int); i++) {
        int sig = signals[i];
        if (sig >= 0 && sig < 32) {
            void (*prev)(int) = signal(sig, DYSignalHandler);
            gPrevSig[sig] = prev;
        }
    }

    DYWriteLine("DYCrashLog installed (pid captured at crash time). "
                "If a crash occurs, send dyluckybag_crash.log alongside the OS report.");
}
