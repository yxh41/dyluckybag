#ifndef DYLUCKYBAG_DYCRASHLOG_H
#define DYLUCKYBAG_DYCRASHLOG_H

#ifdef __cplusplus
extern "C" {
#endif

// Last-resort crash diagnostics for the auto-comment / join pipeline.
//
// @try/@catch only catches Objective-C *throws*. View-injection tweaks are far
// more likely to die from a low-level fault — EXC_BAD_ACCESS on a stale/torn-down
// view, a zombie delegate, an over-release — which no @try/@catch can intercept.
// A signal handler catches that class too, and writes a breadcrumb (plus a native
// backtrace when the SDK exposes execinfo) to dyluckybag_crash.log before letting
// the OS produce its own full crash report.
//
// Install exactly once, from the tweak %ctor, as early as possible.
void DYCrashLogInstall(void);

// Async-signal-safe line writer into the same log. Use this from signal
// handlers and guarded-recovery paths: it touches only open(2)/write(2)/close(2),
// so it is safe inside a SIGSEGV context where NSLog and Foundation are not.
// `line` must be a plain C string.
void DYCrashLogWriteLine(const char *line);

// Optional hook consulted at the very top of the signal handler, before any
// breadcrumb is written. Return 1 to say "this fault was recovered from — do
// not report it"; return 0 to let DYCrashLog report it as usual.
//
// Why this exists: on a jailbroken device several parties fight over SIGSEGV /
// SIGBUS (the host app's own crash reporter, other tweaks). Whoever owns the
// disposition at fault time is whoever installed LAST, so a guard that merely
// calls sigaction() once can silently lose it — the 2026-09-03 12:02 report
// logged verified=1 and still faulted into this handler. DYCrashLog's handler
// is the one that ends up at the bottom of the chain on device (every report so
// far shows it at frame 0), so hooking here is the reliable way to be consulted
// no matter who currently owns the signal.
//
// Called from a signal handler: async-signal-safe only. Return 1 ONLY if you
// have actually recovered by siglongjmp-ing away — returning 1 without
// recovering would resume the faulting instruction forever.
typedef int (*DYCrashLogPreHandler)(int sig);
void DYCrashLogSetPreHandler(DYCrashLogPreHandler handler);

// Re-installs DYCrashLog's signal handler as the LAST disposition for the fault
// signals, chaining whatever handler was there before (another tweak / the app's
// own reporter). Call this immediately before a vulnerable operation (e.g. a view
// tree walk): on a jailbroken device several parties fight over SIGSEGV/SIGBUS and
// whoever installed LAST wins, so re-taking right before we need it defeats that
// displacement and makes the recovery pre-handler reachable regardless of order.
void DYCrashLogRetakeSignals(void);

#ifdef __cplusplus
}
#endif

#endif /* DYLUCKYBAG_DYCRASHLOG_H */
