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
    // First try: legitimate UIKit control activation.
    UIControl *control = [self controlAtPoint:point];
    if (control) {
        NSSet *targets = control.allTargets;
        // A UIControl with zero registered targets will not do anything when
        // asked to send actions, so fall through to the synthesised touch.
        if (control.enabled && control.userInteractionEnabled && targets.count > 0) {
            DYLog(@"tap: firing actions on %@ (%lu targets)",
                  NSStringFromClass(control.class), (unsigned long)targets.count);
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        DYLog(@"tap: found %@ but it has %lu targets; using synthesised touch",
              NSStringFromClass(control.class), (unsigned long)targets.count);
    }

    // Second try: synthesise a real touch so gesture recognisers and
    // touchesBegan:withEvent: handlers see it.
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

    // Some Douyin buttons are plain views with a tap gesture attached. Walk a
    // few levels up looking for one, since the gesture is usually on the
    // container rather than the innermost label view.
    candidate = hitView;
    for (NSUInteger level = 0; level < 5 && candidate; level++) {
        for (UIGestureRecognizer *recognizer in candidate.gestureRecognizers) {
            if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) {
                return nil;  // gestures are handled by the synthesised touch path
            }
        }
        candidate = candidate.superview;
    }

    return nil;
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

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && window.bounds.size.width > 0) {
                    return window;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

@end
