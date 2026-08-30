#ifndef DYLUCKYBAG_DYLOG_H
#define DYLUCKYBAG_DYLOG_H

#import <Foundation/Foundation.h>

// Logging is compiled out of release builds (FINALPACKAGE=1 undefines DEBUG).
// The debug .deb is the one to install when chasing "why did it not fire" —
// the release build is completely silent by design.
#ifdef DEBUG
// DYLogWrite is defined in DYLog.m (Objective-C → C linkage). This header is
// also included from DYLuckyBag.xm, which Theos compiles as Objective-C++, so
// without an extern "C" guard the declaration gets C++ name-mangled and the
// debug link step fails with "Undefined symbols: DYLogWrite". The release build
// is unaffected because DYLog(...) expands to ((void)0) and never references it.
#ifdef __cplusplus
extern "C" {
#endif
void DYLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#ifdef __cplusplus
}
#endif
#define DYLog(...) DYLogWrite(__VA_ARGS__)
#else
#define DYLog(...) ((void)0)
#endif

#endif /* DYLUCKYBAG_DYLOG_H */
