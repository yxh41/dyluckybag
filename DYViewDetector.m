#import "DYViewDetector.h"
#import "DYLog.h"
#import <setjmp.h>
#import <signal.h>
#import <pthread.h>

#pragma mark - Crash-safe view-tree traversal

// A view-injection tweak cannot avoid walking UIKit's live view tree, and during
// Douyin's sheet present/dismiss transitions a subview in the hierarchy can be
// freed while we enumerate it. Touching that freed view faults with
// EXC_BAD_ACCESS / SIGSEGV — which @try/@catch CANNOT intercept (it is a signal,
// not an Objective-C throw). So we wrap each traversal in a scoped
// SIGSEGV/SIGBUS guard: if a fault fires mid-walk we siglongjmp out and return
// an empty result, turning a host crash into a graceful skip. The
// previously-installed handler (DYCrashLog) is saved and restored, so genuine
// crashes elsewhere still go to it and produce a full report.
static sigjmp_buf gDYWalkJmp;
static volatile sig_atomic_t gDYWalkArmed = 0;
static pthread_t gDYWalkThread;
static struct sigaction gDYWalkPrevSeg, gDYWalkPrevBus;

static void DYWalkFaultHandler(int sig) {
    if (gDYWalkArmed && pthread_self() == gDYWalkThread) {
        gDYWalkArmed = 0;
        siglongjmp(gDYWalkJmp, 1);
    }
    // Fault on another thread, or not during a walk: defer to the real handler
    // (DYCrashLog). Restore its disposition and re-raise so it runs as normal.
    struct sigaction *prev = (sig == SIGSEGV) ? &gDYWalkPrevSeg : &gDYWalkPrevBus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

// Runs body(); returns NO if a fault aborted the walk, YES otherwise.
static BOOL DYGuardedWalk(void (^body)(void)) {
    if (!body) {
        return YES;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = DYWalkFaultHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &gDYWalkPrevSeg);
    sigaction(SIGBUS, &sa, &gDYWalkPrevBus);

    gDYWalkThread = pthread_self();
    gDYWalkArmed = 1;
    int faulted = sigsetjmp(gDYWalkJmp, 1);
    if (faulted) {
        gDYWalkArmed = 0;
        sigaction(SIGSEGV, &gDYWalkPrevSeg, NULL);
        sigaction(SIGBUS, &gDYWalkPrevBus, NULL);
        return NO;
    }
    body();
    gDYWalkArmed = 0;
    sigaction(SIGSEGV, &gDYWalkPrevSeg, NULL);
    sigaction(SIGBUS, &gDYWalkPrevBus, NULL);
    return YES;
}

@implementation DYViewHit
@end

@implementation DYViewDetector

#pragma mark - Window

+ (UIWindow *)frontWindow {
    UIApplication *app = UIApplication.sharedApplication;

    // Never scan our own overlay: it floats above Douyin at alert level and
    // holds only the 福 button and the panel.
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

#pragma mark - Text extraction

+ (NSString *)readableTextOfView:(UIView *)view {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if ([view isKindOfClass:UILabel.class]) {
        NSString *t = ((UILabel *)view).text;
        if (t.length) [parts addObject:t];
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)view;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) [parts addObject:t];
        NSString *ct = b.currentTitle;
        if (ct.length && ![ct isEqualToString:t]) [parts addObject:ct];
    } else if ([view isKindOfClass:UITextField.class]) {
        NSString *t = ((UITextField *)view).text;
        if (t.length) [parts addObject:t];
        NSString *ph = ((UITextField *)view).placeholder;
        if (ph.length) [parts addObject:ph];
    } else if ([view isKindOfClass:UITextView.class]) {
        NSString *t = ((UITextView *)view).text;
        if (t.length) [parts addObject:t];
    }

    NSString *a11y = view.accessibilityLabel;
    if (a11y.length) [parts addObject:a11y];
    NSString *a11yV = view.accessibilityValue;
    if (a11yV.length) [parts addObject:a11yV];

    return [parts componentsJoinedByString:@" "];
}

#pragma mark - Traversal

+ (void)walk:(UIView *)view
    keywords:(NSArray<NSString *> *)keywords
    into:(NSMutableArray<DYViewHit *> *)out
    depth:(NSUInteger)depth {
    if (depth > 40) {
        return;   // guard against pathological view hierarchies
    }
    if (view.hidden || view.alpha < 0.01) {
        return;
    }

    NSString *text = [self readableTextOfView:view];
    if (text.length) {
        NSString *compact = [text stringByReplacingOccurrencesOfString:@" " withString:@""];
        for (NSString *kw in keywords) {
            NSString *ckw = [kw stringByReplacingOccurrencesOfString:@" " withString:@""];
            if ([compact rangeOfString:ckw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                DYViewHit *hit = [[DYViewHit alloc] init];
                hit.text = text;
                hit.view = view;
                hit.isControl = [view isKindOfClass:UIControl.class] || view.gestureRecognizers.count > 0;
                UIWindow *win = view.window ?: [self frontWindow];
                if (win) {
                    hit.screenRect = [view convertRect:view.bounds toView:nil];
                } else {
                    hit.screenRect = view.frame;
                }
                [out addObject:hit];
                break;   // one keyword hit per view is enough
            }
        }
    }

    for (UIView *sub in view.subviews) {
        [self walk:sub keywords:keywords into:out depth:depth + 1];
    }
}

+ (NSArray<DYViewHit *> *)findViewsWithTextContaining:(NSArray<NSString *> *)keywords {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return @[];
    }
    NSMutableArray<DYViewHit *> *out = [NSMutableArray array];
    BOOL ok = DYGuardedWalk(^{
        @try {
            [self walk:window keywords:keywords into:out depth:0];
        } @catch (NSException *exception) {
            DYLog(@"viewdetect: traversal threw: %@", exception.reason);
        }
    });
    if (!ok) {
        // A freed view was hit mid-walk (EXC_BAD_ACCESS). Abort this pass rather
        // than crash the host; the next scan re-detects on a stable tree.
        DYLog(@"viewdetect: traversal hit a freed view (EXC_BAD_ACCESS) — aborted defensively; returning no hits this pass");
        return @[];
    }
    return out;
}

+ (DYViewHit *)firstViewWithTextContaining:(NSString *)keyword {
    NSArray *all = [self findViewsWithTextContaining:@[ keyword ]];
    return all.firstObject;
}

#pragma mark - Input fields & controls

+ (NSArray<DYViewHit *> *)findInputFields {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return @[];
    }
    NSMutableArray<DYViewHit *> *out = [NSMutableArray array];
    void (^walk)(UIView *, NSUInteger) = nil;
    walk = ^(UIView *view, NSUInteger depth) {
        if (depth > 40) {
            return;
        }
        if (view.hidden || view.alpha < 0.01) {
            return;
        }
        if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) {
            DYViewHit *hit = [[DYViewHit alloc] init];
            hit.text = [self readableTextOfView:view];
            hit.view = view;
            hit.isControl = YES;
            hit.screenRect = [view convertRect:view.bounds toView:nil];
            [out addObject:hit];
        }
        for (UIView *sub in view.subviews) {
            walk(sub, depth + 1);
        }
    };
    BOOL ok = DYGuardedWalk(^{
        @try {
            walk(window, 0);
        } @catch (NSException *exception) {
            DYLog(@"viewdetect: input traversal threw: %@", exception.reason);
        }
    });
    if (!ok) {
        // A freed view was hit mid-walk (EXC_BAD_ACCESS) — this is the exact crash
        // from the 2026-09-02 report. Return empty so attemptCommentSend retries
        // (attempt<2) on a stable tree instead of touching a dead view.
        DYLog(@"viewdetect: input traversal hit a freed view (EXC_BAD_ACCESS) — aborted defensively; returning no inputs");
        return @[];
    }
    return out;
}

+ (DYViewHit *)firstInputField {
    NSArray<DYViewHit *> *all = [self findInputFields];
    // The comment box auto-focuses when the 口令 sheet opens, so the first
    // responder is almost always the field we want.
    for (DYViewHit *hit in all) {
        if ([hit.view isFirstResponder]) {
            return hit;
        }
    }
    return all.firstObject;
}

+ (DYViewHit *)firstControlWithTextContaining:(NSString *)keyword {
    NSArray<DYViewHit *> *all = [self findViewsWithTextContaining:@[ keyword ]];
    for (DYViewHit *hit in all) {
        if ([hit.view isKindOfClass:UIControl.class]) {
            return hit;
        }
    }
    return nil;
}

+ (DYViewHit *)firstControlWithTextContainingAny:(NSArray<NSString *> *)keywords {
    for (NSString *kw in keywords) {
        DYViewHit *hit = [self firstControlWithTextContaining:kw];
        if (hit) {
            return hit;
        }
    }
    return nil;
}

@end
