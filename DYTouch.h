#ifndef DYLUCKYBAG_DYTOUCH_H
#define DYLUCKYBAG_DYTOUCH_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DYTouch : NSObject

+ (instancetype)shared;

/// Taps `point`, expressed in UIKit screen coordinates (origin top-left).
///
/// Strategy order:
///   1. hit-test to a view, walk up to the nearest UIControl, fire its
///      target-action pairs (public API, no private symbols involved).
///   2. If that dispatches nothing, synthesise a real UITouch and post it
///      through the responder chain (private API, guarded by respondsToSelector).
///
/// Returns YES when a tap was actually dispatched.
- (BOOL)tapAtPoint:(CGPoint)point;

/// Taps the centre of `rect` (UIKit screen coordinates).
- (BOOL)tapInRect:(CGRect)rect;

/// Nearest UIControl at or above the view that occupies `point`, if any.
- (UIControl *)controlAtPoint:(CGPoint)point;

@end

#endif /* DYLUCKYBAG_DYTOUCH_H */
