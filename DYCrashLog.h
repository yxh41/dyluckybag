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

#ifdef __cplusplus
}
#endif

#endif /* DYLUCKYBAG_DYCRASHLOG_H */
