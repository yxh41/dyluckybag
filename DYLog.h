#ifndef DYLUCKYBAG_DYLOG_H
#define DYLUCKYBAG_DYLOG_H

#import <Foundation/Foundation.h>

// Logging is compiled out of release builds (FINALPACKAGE=1 undefines DEBUG).
// The debug .deb is the one to install when chasing "why did it not fire" —
// the release build is completely silent by design.
#ifdef DEBUG
void DYLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define DYLog(...) DYLogWrite(__VA_ARGS__)
#else
#define DYLog(...) ((void)0)
#endif

#endif /* DYLUCKYBAG_DYLOG_H */
