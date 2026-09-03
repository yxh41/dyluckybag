#import "DYViewDetector.h"
#import "DYLog.h"
#import "DYCrashLog.h"
#import <setjmp.h>
#import <signal.h>
#import <pthread.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Crash-safe view-tree traversal

// A view-injection tweak cannot avoid walking UIKit's live view tree, and during
// Douyin's sheet present/dismiss transitions a subview can be freed while we
// enumerate it. Touching that freed view faults with EXC_BAD_ACCESS / SIGSEGV —
// a *signal*, which @try/@catch cannot intercept. We recover by siglongjmp-ing
// out of the handler and returning an empty result for that pass.
//
// Recovery design (final, 2026-09-03): we do NOT install our own SIGSEGV/SIGBUS
// handler. On a jailbroken device several parties fight over those dispositions
// (the host app's crash reporter, other tweaks); whoever installed LAST wins, so a
// guard that sigactions once can silently lose the signal and the host's handler
// reports the crash instead — exactly what happened with the 12:02 report
// (verified=1 yet the fault still landed in DYCrashLog's DYSignalHandler).
//
// Instead we hook DYCrashLog's *pre-handler*: DYSignalHandler sits at the bottom
// of the chain on device (every report so far shows it at frame 0), so it is the
// stable handler we can always rely on being consulted. The pre-handler checks a
// thread-local "are we mid-walk" flag (depth); if so it siglongjmp-outs of the
// fault. No disposition contest, so it cannot be displaced. Genuine crashes
// outside a walk return 0 and are reported in full as before.

typedef struct {
    int depth;        // >0 while this thread is inside a guarded walk
    sigjmp_buf jmp;   // where a fault on this thread jumps back to
} DYWalkState;

static pthread_key_t gDYWalkKey;
static volatile int gDYWalkKeyReady = 0;
static pthread_once_t gDYWalkKeyOnce = PTHREAD_ONCE_INIT;
static pthread_once_t gDYGuardArmOnce = PTHREAD_ONCE_INIT;

static void DYMakeWalkKey(void) {
    if (pthread_key_create(&gDYWalkKey, free) == 0) {
        gDYWalkKeyReady = 1;
    }
}

// Normal context: may allocate.
static DYWalkState *DYWalkStateForCurrentThread(void) {
    pthread_once(&gDYWalkKeyOnce, DYMakeWalkKey);
    if (!gDYWalkKeyReady) {
        return NULL;
    }
    DYWalkState *st = (DYWalkState *)pthread_getspecific(gDYWalkKey);
    if (!st) {
        st = (DYWalkState *)calloc(1, sizeof(DYWalkState));
        pthread_setspecific(gDYWalkKey, st);
    }
    return st;
}

// Signal context: never allocates and never calls pthread_once — neither is safe
// inside a SIGSEGV handler.
static DYWalkState *DYWalkStateNoAlloc(void) {
    if (!gDYWalkKeyReady) {
        return NULL;
    }
    return (DYWalkState *)pthread_getspecific(gDYWalkKey);
}

// Called from the very top of DYCrashLog's signal handler, before any breadcrumb
// is written. Returns 1 to indicate the fault was recovered (do not report it);
// 0 to let DYCrashLog report it normally. DYSignalHandler is the always-present
// handler on device, so this hook is the reliable recovery point regardless of who
// currently owns SIGSEGV. Must stay async-signal-safe: no Foundation, no alloc.
static int DYGuardPreHandler(int sig) {
    (void)sig;
    DYWalkState *st = DYWalkStateNoAlloc();
    if (st && st->depth > 0) {
        // A fault inside a walk we are guarding. Disarm first so a repeat fault
        // at the same spot chains out instead of looping forever.
        st->depth = 0;
        DYCrashLogWriteLine("guard: recovered via DYCrashLog pre-handler — walk aborted, no crash");
        siglongjmp(st->jmp, 1);
        // siglongjmp never returns.
    }
    return 0;
}

// Arms the recovery hook exactly once, on the first guarded walk (by which point
// DYCrashLogInstall() has already run in %ctor, so DYSignalHandler is in place
// and will consult us for every fault from now on). No sigaction, no contest.
static void DYGuardArm(void) {
    DYCrashLogSetPreHandler(DYGuardPreHandler);
    DYCrashLogWriteLine("guard: pre-handler armed (recovery via DYCrashLog chain, no sigaction contest)");
}

// Runs body(); returns NO if a fault aborted it, YES otherwise.
static BOOL DYGuardedWalk(void (^body)(void)) {
    if (!body) {
        return YES;
    }
    // Arm the recovery hook once (on the first walk). It hooks DYCrashLog's
    // signal handler, which is the always-present bottom of the chain, so we are
    // guaranteed to be consulted for every fault — no sigaction disposition contest.
    pthread_once(&gDYGuardArmOnce, DYGuardArm);

    DYWalkState *st = DYWalkStateForCurrentThread();
    if (!st) {
        body();
        return YES;
    }
    if (st->depth > 0) {
        // Nested walk — the outer guard already covers this thread.
        body();
        return YES;
    }
    if (sigsetjmp(st->jmp, 1) != 0) {
        // Re-fetch rather than trust `st` across the longjmp.
        DYWalkState *again = DYWalkStateNoAlloc();
        if (again) {
            again->depth = 0;
        }
        DYLog(@"viewdetect: traversal hit a freed view (EXC_BAD_ACCESS) — aborted defensively");
        return NO;
    }
    st->depth = 1;
    body();
    st->depth = 0;
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

    // Hold the subview list strongly for the duration of the recursion. Douyin
    // tears down parts of the 口令 sheet while we walk it; UIKit then releases
    // those views and any pointer we already grabbed becomes dangling, and the
    // next message to it faults with EXC_BAD_ACCESS. Retaining our own copy
    // keeps every child alive until we are done with it, which removes the
    // use-after-free without needing the signal guard at all.
    NSArray<UIView *> *subs = [view.subviews copy];
    for (UIView *sub in subs) {
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
        // Same reasoning as +walk:...: retain the children before recursing so a
        // concurrent sheet teardown cannot leave us messaging a dead view.
        NSArray<UIView *> *subs = [view.subviews copy];
        for (UIView *sub in subs) {
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
