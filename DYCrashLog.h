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

#ifdef __cplusplus
}
#endif

#endif /* DYLUCKYBAG_DYCRASHLOG_H */
