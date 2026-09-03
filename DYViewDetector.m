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
// v2 (2026-09-03): v1 installed and restored its handlers around every single
// walk, and on device it never caught anything — the 11:34 report shows
// DYGuardedWalk on the stack while the fault went straight to DYCrashLog's
// DYSignalHandler, so the per-call sigaction window was not in effect at fault
// time. This version installs ONCE (lazily, on the first walk, so DYCrashLog is
// already in place and becomes our chain target) and then never touches the
// disposition again, removing the whole install/restore window. State lives in
// thread-local storage so nesting and other threads both behave, and every step
// is written to the crash log so the next report says exactly what the guard did
// and whether the kernel accepted it.
//
// v3 (2026-09-03): v2 proved the kernel DOES accept our handler (verified=1) and
// still caught nothing, because the disposition is contested at runtime — the
// captured chain target was an address outside our own dylib, and by fault time
// DYCrashLog's handler was back in place. Three changes: (1) re-assert our
// handler immediately before every walk instead of once; (2) hook DYCrashLog's
// handler as a last-resort recovery point, since it sits at the bottom of the
// chain and always gets consulted; (3) log whoever we find in our way so the
// next report names the party we are fighting.

typedef struct {
    int depth;        // >0 while this thread is inside a guarded walk
    sigjmp_buf jmp;   // where a fault on this thread jumps back to
} DYWalkState;

static pthread_key_t gDYWalkKey;
static volatile int gDYWalkKeyReady = 0;
static pthread_once_t gDYWalkKeyOnce = PTHREAD_ONCE_INIT;
static pthread_once_t gDYGuardInstallOnce = PTHREAD_ONCE_INIT;

// Dispositions captured at install time (normally DYCrashLog's handler), so a
// fault outside a walk still produces the full DYCrashLog report.
static struct sigaction gPrevSeg, gPrevBus;
static int gGuardInstalled = 0;

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

static void DYGuardHandler(int sig) {
    DYWalkState *st = DYWalkStateNoAlloc();
    if (st && st->depth > 0) {
        // A fault inside a walk we are guarding. Disarm first so a repeat fault
        // at the same spot chains out instead of looping forever.
        st->depth = 0;
        DYCrashLogWriteLine("guard: caught fault inside walk — recovering via siglongjmp");
        siglongjmp(st->jmp, 1);
    }

    // Fault outside any walk: hand it to whoever was installed before us
    // (DYCrashLog) so genuine crashes are still reported in full.
    DYCrashLogWriteLine("guard: fault outside a walk — chaining to previous handler");
    struct sigaction *prev = (sig == SIGSEGV) ? &gPrevSeg : &gPrevBus;
    sigaction(sig, prev, NULL);
    raise(sig);
}

// Last line of defence. Installed as DYCrashLog's pre-handler: when a third
// party owns SIGSEGV at fault time our own handler never runs, but they chain
// down to DYCrashLog (every report so far shows DYSignalHandler at frame 0), so
// we still get asked. Returns 1 if we recovered — which in practice means we
// siglongjmp'd away and never returned at all.
static int DYGuardPreHandler(int sig) {
    (void)sig;
    DYWalkState *st = DYWalkStateNoAlloc();
    if (st && st->depth > 0) {
        st->depth = 0;
        DYCrashLogWriteLine("guard: recovered via DYCrashLog hook — our own signal handler was not in place");
        siglongjmp(st->jmp, 1);
    }
    return 0;
}

static void DYGuardInstall(void) {
    struct sigaction sa, check;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = DYGuardHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    int installed = 0;
    if (sigaction(SIGSEGV, &sa, &gPrevSeg) == 0 && sigaction(SIGBUS, &sa, &gPrevBus) == 0) {
        // Verify the kernel actually accepted our handler — the question the
        // previous build left unanswered.
        memset(&check, 0, sizeof(check));
        sigaction(SIGSEGV, NULL, &check);
        installed = (check.sa_handler == DYGuardHandler);
    }

    char line[256];
    snprintf(line, sizeof(line),
             "guard: install segv_prev=%p bus_prev=%p verified=%d errno=%d",
             (void *)gPrevSeg.sa_handler, (void *)gPrevBus.sa_handler, installed, errno);
    DYCrashLogWriteLine(line);

    gGuardInstalled = installed;

    // Safety net: even if we lose the disposition, DYCrashLog's handler sits at
    // the bottom of the chain on device and will consult us.
    DYCrashLogSetPreHandler(DYGuardPreHandler);
}

// v3 (2026-09-03): v2 answered "did the kernel accept our handler?" (yes,
// verified=1) but still caught nothing, because installing once is not enough —
// the 12:02 report captured segv_prev=0x13a5e1d34, an address outside our own
// dylib, proving the disposition is contested at runtime and gets taken back
// after we install. So we re-take it immediately before every walk: whatever we
// find in our way becomes the new chain target, so a genuine crash outside a
// walk is still reported in full.
#define DY_GUARD_MAX_ASSERT_LOGS 8
static int gGuardAssertLogs = 0;

static void DYGuardReassert(const char *when) {
    for (int i = 0; i < 2; i++) {
        int sig = (i == 0) ? SIGSEGV : SIGBUS;
        struct sigaction *prev = (i == 0) ? &gPrevSeg : &gPrevBus;
        struct sigaction cur;

        memset(&cur, 0, sizeof(cur));
        if (sigaction(sig, NULL, &cur) != 0) {
            continue;                       // cannot query — leave it alone
        }
        if (cur.sa_handler == DYGuardHandler) {
            continue;                       // still ours, nothing to do
        }

        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = DYGuardHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;

        // Remember who we displaced so non-walk faults still chain to them.
        *prev = cur;
        sigaction(sig, &sa, NULL);

        if (gGuardAssertLogs < DY_GUARD_MAX_ASSERT_LOGS) {
            gGuardAssertLogs++;
            char line[256];
            snprintf(line, sizeof(line),
                     "guard: re-assert %s %s: found %p, retook signal (#%d)",
                     when, (i == 0) ? "SIGSEGV" : "SIGBUS",
                     (void *)cur.sa_handler, gGuardAssertLogs);
            DYCrashLogWriteLine(line);
        }
    }
}

// Runs body(); returns NO if a fault aborted it, YES otherwise.
static BOOL DYGuardedWalk(void (^body)(void)) {
    if (!body) {
        return YES;
    }
    // Lazy install: running on the first walk (not in %ctor) means DYCrashLog
    // is already installed, so gPrevSeg/gPrevBus start out as *somebody's*
    // handler — on device that is not always DYCrashLog's, see DYGuardReassert.
    pthread_once(&gDYGuardInstallOnce, DYGuardInstall);

    // Re-take the signal right before the dangerous code, every single time —
    // installing once (v2) was not enough, see DYGuardReassert.
    if (gGuardInstalled) {
        DYGuardReassert("pre-walk");
    }

    DYWalkState *st = DYWalkStateForCurrentThread();
    if (!st || !gGuardInstalled) {
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
