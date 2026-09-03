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
// out of the handler, but only for the single node (subtree) being walked; the
// rest of the tree keeps being searched, so a transient fault never blanks the
// whole scan (that all-or-nothing behaviour is exactly what made auto-comment
// silently degrade to a plain join on every animated sheet).
//
// Recovery design (final 2026-09-03, hardened same day): we do NOT install our
// own SIGSEGV/SIGBUS handler. On a jailbroken device several parties fight over
// those dispositions (the host app's crash reporter, other tweaks); whoever
// installed LAST wins, so a guard that sigactions once can silently lose the
// signal and the host's handler reports the crash instead — exactly what happened
// with the 12:02 report (verified=1 yet the fault still landed in DYCrashLog's
// DYSignalHandler).
//
// Instead we hook DYCrashLog's *pre-handler*: DYSignalHandler sits at the bottom
// of the chain on device (every report so far shows it at frame 0), so it is the
// stable handler we can always rely on being consulted. The pre-handler checks a
// thread-local guard stack (jmpTop); if a guarded scope is active it siglongjmp-s
// out of the fault to the *innermost* scope, which then skips only that node's
// subtree. No disposition contest, so it cannot be displaced. Genuine crashes
// outside any guarded scope return 0 and are reported in full as before.

// How deep the guard stack can nest. The view tree is shallow in practice; this
// ceiling is a safety stop so a pathological hierarchy can never overflow the
// jmp buffer array.
#define DY_WALK_GUARD_DEPTH 16

typedef struct {
    // jmpTop is the index of the currently-active (innermost) guard. >= 0 means
    // we are inside at least one guarded scope and a fault should be recovered.
    // -1 means no guard is active. We no longer use a single `depth` flag: a
    // fault anywhere must longjmp to the *innermost* guard so only the offending
    // subtree is skipped, never the whole walk.
    int jmpTop;
    sigjmp_buf jmp[DY_WALK_GUARD_DEPTH];
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
        st->jmpTop = -1;
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
//
// A fault inside any guarded scope longjmps to the innermost guard's jmp buffer.
// That scope then skips its subtree and the walk continues from the parent —
// so one freed view costs only its own branch, never the whole traversal.
static int DYGuardPreHandler(int sig) {
    (void)sig;
    DYWalkState *st = DYWalkStateNoAlloc();
    if (st && st->jmpTop >= 0) {
        DYCrashLogWriteLine("guard: recovered via DYCrashLog pre-handler — subtree skipped, no crash");
        siglongjmp(st->jmp[st->jmpTop], 1);
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

static void DYGuardArmIfNeeded(void) {
    pthread_once(&gDYGuardArmOnce, DYGuardArm);
}

// Enters a guarded scope around one view-tree node (and its subtree). Returns
// YES to run the node's body; returns NO when called after a fault longjmp'd
// back here, meaning the node's subtree was skipped. The caller MUST pair a YES
// return with DYGuardExit() (in @finally) once the node is processed.
//
// Nesting: each active scope pushes its own jmp buffer, so a fault longjmps to
// exactly the scope that owns the offending node — siblings and ancestors keep
// being searched. The stack is capped at DY_WALK_GUARD_DEPTH; deeper nodes run
// unguarded (a fault there aborts the walk, which is safer than overflowing).
static BOOL DYGuardEnter(void) {
    DYGuardArmIfNeeded();
    DYWalkState *st = DYWalkStateForCurrentThread();
    if (!st) {
        return YES;   // no per-thread state: walk unprotected
    }
    if (st->jmpTop + 1 >= DY_WALK_GUARD_DEPTH) {
        return YES;   // guard stack full: walk this node unprotected
    }
    st->jmpTop += 1;
    if (sigsetjmp(st->jmp[st->jmpTop], 1) != 0) {
        // Arrived here via a fault longjmp: this node (and its subtree) is
        // being skipped. Restore the stack top and tell the caller to skip.
        st->jmpTop -= 1;
        return NO;
    }
    return YES;
}

// Pops the innermost guard scope. Call from @finally after a DYGuardEnter()==YES.
static void DYGuardExit(void) {
    DYWalkState *st = DYWalkStateNoAlloc();
    if (!st) {
        return;
    }
    if (st->jmpTop >= 0) {
        st->jmpTop -= 1;
    }
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

    // Guard this single node (and its subtree) as one unit. If the view is freed
    // mid-traversal (Douyin tearing down the 口令 sheet), the signal pre-handler
    // longjmps back here and we skip ONLY this node's subtree — every sibling and
    // the rest of the tree keep being searched, so a transient fault can no longer
    // blank out the entire scan the way the old whole-walk abort did.
    if (!DYGuardEnter()) {
        return;   // this node faulted earlier and was skipped
    }
    @try {
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
        // keeps every child alive until we are done with it.
        NSArray<UIView *> *subs = [view.subviews copy];
        for (UIView *sub in subs) {
            [self walk:sub keywords:keywords into:out depth:depth + 1];
        }
    } @catch (NSException *exception) {
        DYLog(@"viewdetect: traversal threw: %@", exception.reason);
    } @finally {
        DYGuardExit();
    }
}

+ (NSArray<DYViewHit *> *)findViewsWithTextContaining:(NSArray<NSString *> *)keywords {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return @[];
    }
    NSMutableArray<DYViewHit *> *out = [NSMutableArray array];
    // Per-node guarding (inside -walk:) contains any freed-view fault to its own
    // subtree, so the search always returns whatever it managed to collect —
    // never an all-or-nothing empty result like the old whole-walk abort.
    [self walk:window keywords:keywords into:out depth:0];
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
    [self walkInputs:window into:out depth:0];
    return out;
}

+ (void)walkInputs:(UIView *)view
              into:(NSMutableArray<DYViewHit *> *)out
             depth:(NSUInteger)depth {
    if (depth > 40) {
        return;
    }
    if (view.hidden || view.alpha < 0.01) {
        return;
    }
    // Per-node guard, same as -walk:. A freed view anywhere in the sheet is
    // skipped as just its own subtree; the comment box (which lives in a
    // different branch) is still found, so attemptCommentSend no longer degrades
    // to a plain join just because the sheet was mid-animation.
    if (!DYGuardEnter()) {
        return;
    }
    @try {
        if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) {
            DYViewHit *hit = [[DYViewHit alloc] init];
            hit.text = [self readableTextOfView:view];
            hit.view = view;
            hit.isControl = YES;
            hit.screenRect = [view convertRect:view.bounds toView:nil];
            [out addObject:hit];
        }
        NSArray<UIView *> *subs = [view.subviews copy];
        for (UIView *sub in subs) {
            [self walkInputs:sub into:out depth:depth + 1];
        }
    } @catch (NSException *exception) {
        DYLog(@"viewdetect: input traversal threw: %@", exception.reason);
    } @finally {
        DYGuardExit();
    }
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
