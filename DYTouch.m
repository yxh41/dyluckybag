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
- (BOOL)fireTapGesture:(UITapGestureRecognizer *)recognizer;
- (BOOL)fireTapGestureAtPoint:(CGPoint)point;
- (BOOL)tapView:(UIView *)view;
- (BOOL)synthesizeTouchAtPoint:(CGPoint)point;
- (UIView *)deepTappableInTree:(UIView *)root
                   screenPoint:(CGPoint)screenPoint
                        depth:(NSUInteger)depth;
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
    // Four strategies, cheapest and most faithful first. Douyin mixes plain
    // buttons with self-drawn views driven by gesture recognisers, and Lynx-
    // rendered controls bury their real tap target inside a non-tappable outer
    // container, so no single delivery mechanism covers all of them — fall
    // through until one lands.

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

    // 3. Lynx-rendered controls (`UILynxView` / `BDImageView` / outer `UIView`)
    // bury their real tap target a few subviews down. hitTest returns the outer
    // container, and the UP-walks above never find a control/gesture — so
    // search the hit view's SUBTREE for a tappable at the same screen point.
    UIWindow *window = [self frontWindow];
    if (window) {
        UIView *hitView = [window hitTest:[window convertPoint:point fromWindow:nil]
                                withEvent:nil];
        UIView *deep = hitView ? [self deepTappableInTree:hitView
                                              screenPoint:point
                                                   depth:0] : nil;
        if (deep && deep.window != nil) {
            DYLog(@"tap: deep tappable %@ under hit %@ at %@",
                  NSStringFromClass(deep.class), NSStringFromClass(hitView.class),
                  NSStringFromCGPoint(point));
            if ([deep isKindOfClass:UIControl.class]) {
                UIControl *c = (UIControl *)deep;
                if (c.enabled && c.userInteractionEnabled && c.allTargets.count > 0) {
                    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                    return YES;
                }
            }
            for (UIGestureRecognizer *rec in [deep.gestureRecognizers copy]) {
                if ([rec isKindOfClass:UITapGestureRecognizer.class] && [self fireTapGesture:(UITapGestureRecognizer *)rec]) {
                    return YES;
                }
            }
        }
    }

    // 4. Last resort: push a real touch through the responder chain.
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

/// Directly invokes the targets of a single UITapGestureRecognizer. Douyin's
/// live-room controls are usually plain views with a tap gesture on a container,
/// which no amount of synthesised UITouch will wake up on iOS 13+.
- (BOOL)fireTapGesture:(UITapGestureRecognizer *)recognizer {
    if (![recognizer isKindOfClass:UITapGestureRecognizer.class] ||
        !recognizer.enabled || !recognizer.view) {
        return NO;
    }

    @try {
        // UIGestureRecognizer keeps its targets in a private array of
        // UIGestureRecognizerTarget wrappers (_target / _action). KVC resolves
        // "targets" to _targets. Everything below is guarded and returns NO if
        // it does not hold, so the caller can fall back to another strategy.
        NSArray *wrappers = [recognizer valueForKey:@"targets"];
        if (![wrappers isKindOfClass:NSArray.class] || wrappers.count == 0) {
            return NO;
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
        return fired;
    } @catch (NSException *exception) {
        DYLog(@"tap: gesture invocation failed: %@", exception.reason);
        return NO;
    }
}

/// Locates the tappable control behind `view` (a UIControl with targets, or the
/// nearest ancestor carrying a tap gesture) and fires it directly. This is the
/// most faithful tap we have — it calls the handler Douyin actually registered,
/// with no coordinate guessing. Falls back to the point-based path if nothing
/// tappable is found.
///
/// Ancestors are NOT enough for Lynx-rendered controls (UILynxView /
/// BDImageView / plain UIView containers): the real tap target is buried a few
/// layers DOWN in the subtree, and the outer container has neither a UIControl
/// nor a tap gesture of its own. Phase 2 below searches that subtree. Without
/// it, every such entry degrades to a synthesised UITouch sent straight to the
/// Lynx container, which Lynx ignores — that is the "panel never opens on
/// super-bag entries" bug from dyluckybag(18).log
/// (tapView: no direct target; point-tap fallback → synthesising touch on
/// UILynxView at {70,160}, three times in a row).
- (BOOL)tapView:(UIView *)view {
    if (!view) {
        return NO;
    }

    // Phase 1: ancestor walk. Each level independently, so a gesture on a
    // swipe-only ancestor cannot mask a working tap gesture further up.
    UIView *candidate = view;
    while (candidate) {
        if ([candidate isKindOfClass:UIControl.class]) {
            UIControl *c = (UIControl *)candidate;
            if (c.enabled && c.userInteractionEnabled && c.allTargets.count > 0) {
                DYLog(@"tapView: firing actions on %@ (%lu targets)",
                      NSStringFromClass(c.class), (unsigned long)c.allTargets.count);
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
        for (UIGestureRecognizer *rec in [candidate.gestureRecognizers copy]) {
            if ([rec isKindOfClass:UITapGestureRecognizer.class] && [self fireTapGesture:(UITapGestureRecognizer *)rec]) {
                return YES;
            }
        }
        candidate = candidate.superview;
    }

    // Phase 2: subtree walk. Lynx-rendered controls bury their real tap target
    // inside the container; find it and fire it directly so we never depend on
    // Lynx's IOHID hookup (which UIKit's synthesised UITouch cannot satisfy).
    CGPoint center = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds),
                                                     CGRectGetMidY(view.bounds))
                                 toView:nil];
    UIView *deep = [self deepTappableInTree:view screenPoint:center depth:0];
    if (deep && deep != view && deep.window != nil) {
        DYLog(@"tapView: deep tappable %@ found in %@'s subtree at %@",
              NSStringFromClass(deep.class), NSStringFromClass(view.class),
              NSStringFromCGPoint(center));
        if ([deep isKindOfClass:UIControl.class]) {
            UIControl *c = (UIControl *)deep;
            if (c.enabled && c.userInteractionEnabled && c.allTargets.count > 0) {
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
        for (UIGestureRecognizer *rec in [deep.gestureRecognizers copy]) {
            if ([rec isKindOfClass:UITapGestureRecognizer.class] && [self fireTapGesture:(UITapGestureRecognizer *)rec]) {
                return YES;
            }
        }
    }

    // Phase 3: coordinate fallback (existing behaviour).
    DYLog(@"tapView: no direct target; point-tap fallback at %@", NSStringFromCGPoint(center));
    return [self tapAtPoint:center];
}

/// Finds the tap gesture on the hit view or one of its ancestors and fires it.
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
        for (UIGestureRecognizer *rec in [candidate.gestureRecognizers copy]) {
            if ([rec isKindOfClass:UITapGestureRecognizer.class] && [self fireTapGesture:(UITapGestureRecognizer *)rec]) {
                return YES;
            }
        }
        candidate = candidate.superview;
    }

    return NO;
}

/// Depth-first search under `root` for a tappable view whose frame contains
/// `screenPoint`. Returns the deepest UIView that is either a `UIControl` with
/// live target-action pairs, or a view carrying a `UITapGestureRecognizer` with
/// live targets. Caller is responsible for firing the result.
///
/// Why ancestors alone miss the target on super-bag entries: TikTok's Lynx
/// engine renders many live-room controls inside a `UILynxView` (or
/// `BDImageView` / plain `UIView`) container. The OUTER container has no
/// `UIControl` or tap gesture of its own, and `hitTest:` returns it as the
/// deepest view at the touch point — so the up-walks in `-controlAtPoint:` and
/// `-fireTapGestureAtPoint:` never find anything. The real tap target (often a
/// `UIControl` carrying Lynx's `LynxGestureHandler`) sits 1–3 layers below and
/// is non-opaque, so a normal `hitTest:` skips it on Lynx containers. Without
/// this fallback every such control degrades to a synthesised UITouch that Lynx
/// ignores, which is why the super-bag floating entry on this build opened
/// the panel 0/3 times (see dyluckybag(18).log, 10:07–10:08).
///
/// Safety: bounded to depth 8 (Lynx trees are shallow), every candidate frame
/// is checked to contain the screen point (no cross-talk between disjoint
/// overlays), and the search is skipped entirely when `root` is offscreen.
/// `UIControl` with targets is preferred over a tap-gesture view at the same
/// depth, because the former delivers through public API and is the most
/// faithful tap we have.
- (UIView *)deepTappableInTree:(UIView *)root
                   screenPoint:(CGPoint)screenPoint
                        depth:(NSUInteger)depth {
    if (!root || depth > 8) {
        return nil;
    }
    if (root.window == nil) {
        return nil;
    }

    // Stay inside the subtree's screen rect — Lynx containers are small but
    // some live overlays stack a full-width subview on top, and we must not let
    // a stray match from one leak into another's tap.
    if (root.superview) {
        CGRect rootScreenRect = [root.superview convertRect:root.bounds toView:nil];
        if (!CGRectIsEmpty(rootScreenRect) &&
            !CGRectContainsPoint(rootScreenRect, screenPoint)) {
            return nil;
        }
    }

    // Recurse first (depth-first): a deeper working target beats a shallower one.
    for (UIView *sub in [root.subviews copy]) {
        UIView *found = [self deepTappableInTree:sub
                                     screenPoint:screenPoint
                                          depth:depth + 1];
        if (found) {
            return found;
        }
    }

    // Is `root` itself tappable? Prefer UIControl (public API, deterministic),
    // then a tap-gesture view (private target/action KVC, still far more
    // reliable than synthesising a touch on Lynx).
    if ([root isKindOfClass:UIControl.class]) {
        UIControl *c = (UIControl *)root;
        if (c.enabled && c.userInteractionEnabled && c.allTargets.count > 0) {
            return c;
        }
    }
    for (UIGestureRecognizer *rec in [root.gestureRecognizers copy]) {
        if ([rec isKindOfClass:UITapGestureRecognizer.class]) {
            // Use the same live-targets check as -fireTapGesture: so an empty
            // recogniser does not short-circuit a deeper match.
            NSArray *wrappers = [rec valueForKey:@"targets"];
            if ([wrappers isKindOfClass:NSArray.class] && wrappers.count > 0) {
                return root;
            }
        }
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
