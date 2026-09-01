#import "DYTouch.h"
#import "DYLog.h"

// Private UITouch/UIEvent plumbing. Douyin rarely wires its live-room buttons
// through plain target-action, so the public path below often finds a UIControl
// with no targets — in that case we have to push a real touch through the
// responder chain instead. Every selector is guarded before use.
@interface UITouch (DYSynthesize)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
@end

@interface UIEvent (DYSynthesize)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
@end

@interface UIApplication (DYSynthesize)
- (UIEvent *)_touchesEvent;
@end

@interface DYTouch ()
- (UIWindow *)frontWindow;
- (BOOL)fireTapGestureAtPoint:(CGPoint)point;
- (BOOL)synthesizeTouchAtPoint:(CGPoint)point;
@end

@implementation DYTouch

+ (instancetype)shared {
    static DYTouch *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DYTouch alloc] init];
    });
    return instance;
}

#pragma mark - Public

- (BOOL)tapInRect:(CGRect)rect {
    if (CGRectIsEmpty(rect)) {
        return NO;
    }
    return [self tapAtPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect))];
}

- (BOOL)tapAtPoint:(CGPoint)point {
    // Three strategies, cheapest and most faithful first. Douyin mixes plain
    // buttons with self-drawn views driven by gesture recognisers, and no single
    // delivery mechanism covers both, so fall through until one lands.

    // 1. A real UIControl with registered targets: just ask UIKit to fire it.
    UIControl *control = [self controlAtPoint:point];
    if (control) {
        NSSet *targets = control.allTargets;
        // A UIControl with zero registered targets will not do anything when
        // asked to send actions, so fall through to the next strategy.
        if (control.enabled && control.userInteractionEnabled && targets.count > 0) {
            DYLog(@"tap: firing actions on %@ (%lu targets)",
                  NSStringFromClass(control.class), (unsigned long)targets.count);
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        DYLog(@"tap: found %@ but it has %lu targets; trying gestures",
              NSStringFromClass(control.class), (unsigned long)targets.count);
    }

    // 2. The join button is very often a plain view with a tap gesture on one of
    // its containers. Invoke the recogniser's own targets directly — far more
    // reliable than a synthesised touch, which modern gesture recognisers tend
    // to ignore outright.
    if ([self fireTapGestureAtPoint:point]) {
        return YES;
    }

    // 3. Last resort: push a real touch through the responder chain.
    return [self synthesizeTouchAtPoint:point];
}

- (UIControl *)controlAtPoint:(CGPoint)point {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return nil;
    }

    // hitTest: expects coordinates in the receiver's space. The OCR rects are
    // in screen space, so convert (fromWindow:nil means "from the screen").
    CGPoint windowPoint = [window convertPoint:point fromWindow:nil];
    UIView *hitView = [window hitTest:windowPoint withEvent:nil];
    if (!hitView) {
        return nil;
    }

    UIView *candidate = hitView;
    while (candidate) {
        if ([candidate isKindOfClass:UIControl.class]) {
            return (UIControl *)candidate;
        }
        candidate = candidate.superview;
    }

    return nil;
}

/// Directly invokes the targets of a UITapGestureRecognizer found on the hit
/// view or one of its ancestors. Douyin's live-room controls are usually plain
/// views with a tap gesture on a container, which no amount of synthesised
/// UITouch will wake up on iOS 13+.
- (BOOL)fireTapGestureAtPoint:(CGPoint)point {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return NO;
    }

    CGPoint windowPoint = [window convertPoint:point fromWindow:nil];
    UIView *hitView = [window hitTest:windowPoint withEvent:nil];
    if (!hitView) {
        return NO;
    }

    UIView *candidate = hitView;
    for (NSUInteger level = 0; level < 8 && candidate; level++) {
        // Copy: Douyin can mutate its recogniser list while we walk it.
        for (UIGestureRecognizer *recognizer in [candidate.gestureRecognizers copy]) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class] ||
                !recognizer.enabled || !recognizer.view) {
                continue;
            }

            @try {
                // UIGestureRecognizer keeps its targets in a private array of
                // UIGestureRecognizerTarget wrappers (_target / _action). KVC
                // resolves "targets" to _targets. Everything below is guarded
                // and falls back to the synthesised touch if it does not hold.
                NSArray *wrappers = [recognizer valueForKey:@"targets"];
                if (![wrappers isKindOfClass:NSArray.class] || wrappers.count == 0) {
                    continue;
                }

                BOOL fired = NO;
                for (id wrapper in wrappers) {
                    id target = [wrapper valueForKey:@"target"];
                    id actionValue = [wrapper valueForKey:@"action"];
                    if (!target || !actionValue) {
                        continue;
                    }

                    SEL action = NULL;
                    if ([actionValue isKindOfClass:NSValue.class]) {
                        action = (SEL)[(NSValue *)actionValue pointerValue];
                    } else if ([actionValue isKindOfClass:NSString.class]) {
                        action = NSSelectorFromString((NSString *)actionValue);
                    }
                    if (!action || ![target respondsToSelector:action]) {
                        continue;
                    }

                    DYLog(@"tap: firing %@ gesture action on %@",
                          NSStringFromClass(recognizer.class),
                          NSStringFromClass([target class]));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [target performSelector:action withObject:recognizer];
#pragma clang diagnostic pop
                    fired = YES;
                }

                if (fired) {
                    return YES;
                }
            } @catch (NSException *exception) {
                DYLog(@"tap: gesture invocation failed: %@", exception.reason);
            }
        }
        candidate = candidate.superview;
    }

    return NO;
}

#pragma mark - Synthesised touch

- (BOOL)synthesizeTouchAtPoint:(CGPoint)point {
    UIApplication *app = UIApplication.sharedApplication;

    if (![app respondsToSelector:@selector(_touchesEvent)]) {
        DYLog(@"tap: UIApplication has no _touchesEvent; cannot synthesise");
        return NO;
    }

    UIWindow *window = [self frontWindow];
    if (!window) {
        return NO;
    }

    CGPoint windowPoint = [window convertPoint:point fromWindow:nil];
    UIView *targetView = [window hitTest:windowPoint withEvent:nil];
    if (!targetView) {
        DYLog(@"tap: hitTest found no view at %@", NSStringFromCGPoint(point));
        return NO;
    }

    UITouch *touch = [[UITouch alloc] init];
    if (!touch) {
        DYLog(@"tap: could not allocate UITouch");
        return NO;
    }

    NSTimeInterval timestamp = [NSProcessInfo processInfo].systemUptime;

    if ([touch respondsToSelector:@selector(setWindow:)]) {
        [touch setWindow:window];
    }
    if ([touch respondsToSelector:@selector(setView:)]) {
        [touch setView:targetView];
    }
    if ([touch respondsToSelector:@selector(setTapCount:)]) {
        [touch setTapCount:1];
    }
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        [touch setTimestamp:timestamp];
    }
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]) {
        [touch _setLocationInWindow:windowPoint resetPrevious:YES];
    }
    if ([touch respondsToSelector:@selector(setPhase:)]) {
        [touch setPhase:UITouchPhaseBegan];
    }

    UIEvent *event = [app _touchesEvent];
    if (!event) {
        DYLog(@"tap: _touchesEvent returned nil");
        return NO;
    }

    if ([event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) {
        [event _addTouch:touch forDelayedDelivery:NO];
    } else {
        DYLog(@"tap: UIEvent has no _addTouch:forDelayedDelivery:");
        return NO;
    }

    DYLog(@"tap: synthesising touch on %@ at %@",
          NSStringFromClass(targetView.class), NSStringFromCGPoint(point));

    [app sendEvent:event];

    // Deliver the matching end event on the next runloop turn; delivering both
    // synchronously can be dropped by gesture recognisers that expect a gap.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([touch respondsToSelector:@selector(setPhase:)]) {
            [touch setPhase:UITouchPhaseEnded];
        }
        if ([touch respondsToSelector:@selector(setTimestamp:)]) {
            [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
        }
        [app sendEvent:event];
    });

    return YES;
}

#pragma mark - Window

- (UIWindow *)frontWindow {
    UIApplication *app = UIApplication.sharedApplication;

    // Skip our own overlay. It floats above Douyin at alert level, so hit-testing
    // against it would resolve to the 福 button / panel and the tap would go
    // nowhere near Douyin's join button.
    BOOL (^isOverlay)(UIWindow *) = ^BOOL(UIWindow *window) {
        return window.windowLevel >= UIWindowLevelAlert;
    };

    if (@available(iOS 13.0, *)) {
        UIWindow *fallback = nil;
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.bounds.size.width <= 0) {
                    continue;
                }
                if (isOverlay(window)) {
                    continue;
                }
                if (window.isKeyWindow) {
                    return window;
                }
                if (!fallback) {
                    fallback = window;
                }
            }
        }
        if (fallback) {
            return fallback;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *legacy = app.keyWindow;
#pragma clang diagnostic pop
    if (legacy && !legacy.hidden && !isOverlay(legacy)) {
        return legacy;
    }
    return nil;
}

@end
