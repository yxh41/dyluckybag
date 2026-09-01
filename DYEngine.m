#import "DYEngine.h"
#import "DYConfig.h"
#import "DYOCRDetector.h"
#import "DYViewDetector.h"
#import "DYTouch.h"
#import "DYLog.h"
#import <QuartzCore/QuartzCore.h>

// Screen-text vocabulary. Douyin's live room is entirely Chinese, and these
// strings have been stable across versions for a long time — much more stable
// than class names, which is precisely why this tweak OCRs instead of hooking.
static NSString *const kWordBag        = @"福袋";
static NSString *const kWordJoin       = @"参与";
static NSString *const kWordKeyword    = @"口令";
// A real win shows a dedicated popup ("恭喜你获得…", "你已中奖…"), not the
// "恭喜主播 / 恭喜发财" people spam in chat. Match only win-modal phrases so the
// win counter is not inflated by congratulatory chatter.
static NSArray<NSString *> *const kWinPhrases = @[
    @"你已中奖", @"恭喜你获得", @"恭喜你中奖", @"中奖通知",
    @"中奖啦", @"获得¥", @"奖品已发放", @"中奖记录"
];

// A tap landing within this radius of the previous tap is treated as the same
// button, so we do not hammer "join" on every scan pass.
static const CGFloat kTapProximity = 44.0;
static const NSTimeInterval kTapCooldown = 6.0;

// Scan cadence adapts to whether a lucky bag is actually on screen. Fast while
// one is present (we want to catch the "参与" button immediately); slow when the
// user is just scrolling the feed / watching short videos, so the periodic OCR
// pass never competes with video playback for the main thread.
static const NSTimeInterval kFastInterval = 1.5;
static const NSTimeInterval kSlowInterval = 6.0;
static const NSInteger kQuietThreshold = 10;

@interface DYEngine ()
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL scanning;
@property (nonatomic, readwrite) DYEngineState state;
@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, copy, readwrite) NSString *lastStatus;
@property (nonatomic) CGPoint lastTapPoint;
@property (nonatomic) CFTimeInterval lastTapTime;
@property (nonatomic) NSString *lastKeyword;
@property (nonatomic) NSInteger quietPasses;
@property (nonatomic) NSTimeInterval currentInterval;

// Declared up front so -Werror never trips on a forward reference.
- (DYTextHit *)joinButtonHitFromHits:(NSArray<DYTextHit *> *)hits;
- (DYViewHit *)validJoinView:(DYViewHit *)candidate;
- (void)verifyTapAtPoint:(CGPoint)point;
// Comment / 口令 bag participation (Option B).
- (void)sendCommentWithKeyword:(NSString *)keyword tapPoint:(CGPoint)pt;
- (void)attemptCommentSend:(NSString *)keyword attempt:(NSInteger)attempt;
- (void)fillInput:(UIView *)view withText:(NSString *)text;
- (void)handleFollowGate;
- (void)verifyCommentSent;
@end

@implementation DYEngine

+ (instancetype)shared {
    static DYEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DYEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = DYEngineStateIdle;
        _lastStatus = @"未启动";
        _lastTapTime = -kTapCooldown;
        _quietPasses = 0;
        _currentInterval = kFastInterval;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;

    NSTimeInterval interval = MAX(0.5, [DYConfig shared].scanInterval);
    [self restartTimerWithInterval:interval];

    DYLog(@"engine started, interval=%.1fs", interval);
    [self updateStatus:@"已启动，等待福袋"];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.running = NO;
    DYLog(@"engine stopped");
    [self updateStatus:@"已停止"];
}

- (void)restartTimerWithInterval:(NSTimeInterval)interval {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil
                                                 repeats:YES];
    // Common modes so scrolling the feed does not stall the timer.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)adaptScanRate {
    NSTimeInterval target = (self.quietPasses > kQuietThreshold) ? kSlowInterval : kFastInterval;
    if (fabs(target - self.currentInterval) < 0.01) {
        return;
    }
    self.currentInterval = target;
    [self restartTimerWithInterval:target];
    DYLog(@"scan rate -> %.1fs (quiet passes=%ld)", target, (long)self.quietPasses);
}

- (void)timerFired:(NSTimer *)timer {
    [self scanOnce];
}

- (void)scanOnce {
    if (self.scanning) {
        return;  // a pass is already in flight; never overlap OCR work
    }
    if (![DYConfig shared].masterEnabled) {
        return;
    }

    self.scanning = YES;

    __weak typeof(self) weakSelf = self;
    [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.scanning = NO;
        if (error) {
            [strongSelf updateStatus:[NSString stringWithFormat:@"OCR 失败: %@",
                                      error.localizedDescription]];
            return;
        }
        [strongSelf handleHits:hits];
    }];
}

#pragma mark - Decision making

- (void)handleHits:(NSArray<DYTextHit *> *)hits {
    // Decide whether a lucky bag is on screen. OCR covers the case where the
    // screen capture succeeded; the view-tree scan needs no capture at all, so
    // it still finds the 福袋 / 参与 controls when drawViewHierarchyInRect
    // fails inside a live room (the Metal video layer has no CPU backing).
    DYTextHit *bagHit = [hits dy_firstHitContaining:kWordBag];
    BOOL bagByOCR = (bagHit != nil);

    DYViewHit *bagView    = [DYViewDetector firstViewWithTextContaining:kWordBag];
    DYViewHit *joinedView = [DYViewDetector firstViewWithTextContaining:@"已参与"];
    DYViewHit *rawJoin = joinedView ? nil : [DYViewDetector firstViewWithTextContaining:kWordJoin];
    DYViewHit *joinView = [self validJoinView:rawJoin];

    BOOL sawBag = bagByOCR || (bagView != nil);
    self.quietPasses = sawBag ? 0 : (self.quietPasses + 1);
    [self adaptScanRate];

    if (hits.count > 0) {
        // 1. A win banner outranks everything else — stop tapping and report it.
        //    Only fire on a dedicated win-modal phrase, never on chat "恭喜".
        DYTextHit *winHit = nil;
        for (NSString *phrase in kWinPhrases) {
            winHit = [hits dy_firstHitContaining:phrase];
            if (winHit) {
                break;
            }
        }
        if (winHit) {
            [self handleWin:winHit];
            return;
        }
    }

    // 2. No bag anywhere (neither OCR nor view tree)?
    if (!bagByOCR && !bagView) {
        if (self.state != DYEngineStateIdle) {
            self.state = DYEngineStateIdle;
            [self updateStatus:@"当前直播间没有福袋"];
        }
        return;
    }

    DYLog(@"bag detected (ocr=%d viewTree=%d)%@",
          bagByOCR, bagView != nil,
          joinView ? [NSString stringWithFormat:@" join='%@'", joinView.text] : @"");

    // 3. Extract the keyword (口令) if the bag requires a comment to enter.
    [self captureKeywordFromHits:hits];

    // 4. Already joined? Then we are waiting for the draw, not tapping again.
    if ((bagByOCR && [hits dy_firstHitContaining:@"已参与"]) || joinedView) {
        self.state = DYEngineStateWaitingResult;
        [self updateStatus:@"已参与，等待开奖"];
        return;
    }

    // 5. Locate the join button. Prefer the real UIView from the view tree so
    //    we can fire its handler directly; fall back to the OCR rect.
    UIView *joinTargetView = nil;
    CGPoint center;
    NSString *joinLabel;
    if (joinView) {
        joinLabel = joinView.text;
        center = CGPointMake(CGRectGetMidX(joinView.screenRect),
                              CGRectGetMidY(joinView.screenRect));
        joinTargetView = joinView.view;
    } else {
        DYTextHit *joinOCR = [self joinButtonHitFromHits:hits];
        if (!joinOCR) {
            self.state = DYEngineStateBagDetected;
            [self updateStatus:@"检测到福袋，未找到参与按钮"];
            return;
        }
        joinLabel = joinOCR.text;
        center = CGPointMake(CGRectGetMidX(joinOCR.rect), CGRectGetMidY(joinOCR.rect));
    }

    self.state = DYEngineStateBagDetected;

    // 6. Detect-only mode deliberately stops here — it is the safe way to
    //    verify detection before letting the tweak tap.
    if ([DYConfig shared].patrolMode == DYPatrolModeDetectOnly) {
        [self updateStatus:[NSString stringWithFormat:@"[仅检测] 发现参与按钮 '%@'", joinLabel]];
        return;
    }

    // 7. Debounce: do not re-tap the same button inside the cooldown window.
    if ([self isDuplicateTapAtPoint:center]) {
        DYLog(@"tap skipped: same button as last time (cooldown %.0fs)", kTapCooldown);
        return;
    }

    // 8. Tap it — through the real view when we have one, else by coordinate.
    BOOL dispatched;
    if (joinTargetView) {
        DYLog(@"tapping join (view-tree) '%@' at %@", joinLabel, NSStringFromCGPoint(center));
        dispatched = [[DYTouch shared] tapView:joinTargetView];
    } else {
        DYLog(@"tapping join (ocr-rect) '%@' at %@", joinLabel, NSStringFromCGPoint(center));
        dispatched = [[DYTouch shared] tapInRect:CGRectMake(center.x - 1.0, center.y - 1.0, 2.0, 2.0)];
    }

    if (dispatched) {
        self.lastTapPoint = center;
        self.lastTapTime = CACurrentMediaTime();
        self.state = DYEngineStateJoined;
        DYLog(@"join dispatched; today joins=%ld",
              (long)[DYConfig shared].todayJoinCount);
        // When comment auto-send is on, route every join through the comment
        // flow: tap 参与, open the sheet, capture the 口令 from inside it
        // (Douyin reveals the 口令 only after 参与 opens the sheet — it is never
        // on the bag card at detection time), then post. For bags that join
        // straight on 参与 with no comment box, the flow detects "no input
        // field" and falls back to a plain join, so normal bags are unaffected.
        if ([DYConfig shared].commentKeywordAutoSend) {
            [self sendCommentWithKeyword:self.lastKeyword tapPoint:center];
        } else {
            [[DYConfig shared] incrementJoinCount];
            [[DYConfig shared] synchronize];
            [self updateStatus:@"已点击参与"];
            [self verifyTapAtPoint:center];
        }
        // Consumed for this bag — prevents a stale 口令 leaking onto the next bag.
        self.lastKeyword = nil;
    } else {
        [self updateStatus:@"点击失败：未找到可响应的控件"];
    }
}

/// Filters the view-tree 参与 hit the same way joinButtonHitFromHits filters
/// OCR hits: counters ("1234人参与"), countdowns (":") and over-long labels are
/// not buttons.
- (DYViewHit *)validJoinView:(DYViewHit *)candidate {
    if (!candidate) {
        return nil;
    }
    NSString *t = candidate.text ?: @"";
    if ([t rangeOfString:@"人参与"].location != NSNotFound) return nil;
    if ([t rangeOfString:@"人已参与"].location != NSNotFound) return nil;
    if ([t rangeOfString:@"参与人数"].location != NSNotFound) return nil; // participant count, not a button
    if ([t rangeOfString:@"条件"].location != NSNotFound) return nil;     // "参与条件" label, not a button
    if ([t rangeOfString:@":"].location != NSNotFound) return nil;
    if (t.length > 30) return nil;
    return candidate;
}

/// From inside the tweak a tap Douyin ignored looks exactly like one it honoured
/// — all three delivery mechanisms return success regardless. So go back and
/// look: if the join button is still sitting where we tapped it, the tap did not
/// land, and the log should say so instead of reporting another phantom join.
- (void)verifyTapAtPoint:(CGPoint)point {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }

        [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits, NSError *error) {
            if (error || hits.count == 0) {
                DYLog(@"tap verify: inconclusive (no OCR result)");
                return;
            }
            if ([hits dy_firstHitContaining:@"已参与"]) {
                DYLog(@"tap verify: OK - screen now shows 已参与");
                return;
            }

            DYTextHit *still = [strongSelf joinButtonHitFromHits:hits];
            if (still) {
                CGPoint current = CGPointMake(CGRectGetMidX(still.rect), CGRectGetMidY(still.rect));
                CGFloat distance = hypot(current.x - point.x, current.y - point.y);
                if (distance < kTapProximity) {
                    DYLog(@"tap verify: FAILED - join button still on screen %.0fpt from "
                          @"the tap. Douyin did not respond to any delivery mechanism.",
                          distance);
                    [strongSelf updateStatus:@"点击未生效：抖音无响应"];
                    return;
                }
            }
            DYLog(@"tap verify: OK - join button gone from the tapped spot");
        }];
    });
}

#pragma mark - Comment / 口令 bag participation (Option B)

/// A 口令 福袋 only counts as joined once the comment is actually posted. The
/// 参与 tap opened the comment sheet; this posts the captured 口令 into it.
- (void)sendCommentWithKeyword:(NSString *)keyword tapPoint:(CGPoint)pt {
    // keyword may be empty here: the 口令 is usually revealed only after 参与
    // opens the comment sheet, so -attemptCommentSend: re-scans the sheet (and
    // checks for a Douyin-prefilled box) before deciding what to post.
    DYLog(@"comment flow: 参与 tapped, resolving 口令 from sheet (pre-tap='%@')", keyword);
    [self attemptCommentSend:keyword attempt:0];
}

/// Probes for the comment input a few times, because the sheet animates in and
/// the first scan after the tap may run before it is on screen.
- (void)attemptCommentSend:(NSString *)keyword attempt:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }

        // Some bags gate commenting behind 关注 / 加入粉丝团. Tap it first when
        // the user opted in; otherwise just note it (the send will likely fail,
        // which we report honestly instead of faking a join).
        [strongSelf handleFollowGate];

        // Resolve the 口令 to post. The card never shows it at detection time;
        // Douyin reveals it only inside the comment sheet after 参与 opens it,
        // and sometimes even prefills the box with it. Priority:
        //   1. captured pre-tap (keyword arg / self.lastKeyword)
        //   2. re-scanned from the now-open sheet
        //   3. already typed into the box by Douyin (prefill) — send as-is
        NSString *comment = (keyword.length > 0) ? keyword : [strongSelf captureKeywordFromSheet];
        NSString *prefill = nil;

        DYViewHit *input = [DYViewDetector firstInputField];
        if (!input) {
            // No comment box appeared. Two cases:
            //  - a plain bag that joins straight on 参与 (no sheet) -> count it;
            //  - a 口令 bag whose sheet is still animating in -> retry.
            if (attempt < 2) {
                DYLog(@"comment send: input not ready (attempt %ld), retrying", (long)attempt);
                [strongSelf attemptCommentSend:keyword attempt:attempt + 1];
                return;
            }
            // Genuinely no comment box: treat as a plain join (参与 already joined).
            DYLog(@"comment flow: no comment box — plain bag, counting join");
            [[DYConfig shared] incrementJoinCount];
            [[DYConfig shared] synchronize];
            [strongSelf updateStatus:@"已参与（无评论框）"];
            [strongSelf verifyTapAtPoint:strongSelf.lastTapPoint];
            return;   // real join — count it
        }

        prefill = [strongSelf textOfInput:input.view];
        if (comment.length == 0) {
            comment = prefill;   // Douyin prefilled the box with the 口令
        }
        if (comment.length == 0) {
            // No 口令 anywhere we can read. Dump the sheet so the next log shows
            // exactly what Douyin displays (it may render the 口令 as an image),
            // and bail honestly instead of posting an empty comment.
            [strongSelf dumpCommentSheet];
            [strongSelf updateStatus:@"未捕获口令，无法发评论"];
            return;   // not a real join — do not inflate the counter
        }

        // Only overwrite the box when it is empty; a prefilled 口令 must be kept.
        if (prefill.length == 0) {
            [strongSelf fillInput:input.view withText:comment];
        } else {
            DYLog(@"comment box prefilled with '%@' — sending as-is", prefill);
        }

        DYViewHit *send = [DYViewDetector firstControlWithTextContainingAny:@[ @"发送", @"发表", @"发布" ]];
        if (!send) {
            if (attempt < 2) {
                DYLog(@"comment send: 发送 button not ready (attempt %ld), retrying", (long)attempt);
                [strongSelf attemptCommentSend:keyword attempt:attempt + 1];
                return;
            }
            DYLog(@"comment send: no 发送/发表/发布 button found");
            [strongSelf updateStatus:@"发送按钮未找到，参与未完成"];
            return;
        }

        BOOL ok = [[DYTouch shared] tapView:send.view];
        if (ok) {
            DYLog(@"comment sent: '%@'", comment);
            [[DYConfig shared] incrementJoinCount];
            [[DYConfig shared] synchronize];
            [strongSelf updateStatus:[NSString stringWithFormat:@"已发评论：%@", comment]];
            [strongSelf verifyCommentSent];
        } else {
            DYLog(@"comment send: tap on 发送 failed");
            [strongSelf updateStatus:@"发送点击失败"];
            // Tap failed — incomplete, do not count.
        }
    });
}

/// Re-scans the live view tree for the 口令, in case it is only revealed after
/// 参与 opens the comment sheet. Returns the extracted keyword, or nil.
- (NSString *)captureKeywordFromSheet {
    NSArray<DYViewHit *> *hits = [DYViewDetector findViewsWithTextContaining:@[ kWordKeyword ]];
    for (DYViewHit *hit in hits) {
        NSString *kw = [self keywordFromText:hit.text];
        if (kw.length > 0) {
            DYLog(@"captured 口令 from sheet: '%@'", kw);
            return kw;
        }
    }
    return nil;
}

/// Current editable text of an input field (to detect a Douyin-prefilled 口令).
- (NSString *)textOfInput:(UIView *)view {
    if ([view isKindOfClass:UITextField.class]) {
        return ((UITextField *)view).text ?: @"";
    }
    if ([view isKindOfClass:UITextView.class]) {
        return ((UITextView *)view).text ?: @"";
    }
    return @"";
}

/// Diagnostic: dump any comment-related text visible in the front window so the
/// next log reveals what Douyin actually shows (e.g. 口令 rendered as an image).
- (void)dumpCommentSheet {
    NSArray<DYViewHit *> *hits =
        [DYViewDetector findViewsWithTextContaining:@[ kWordKeyword, @"说点", @"评论", @"发送", @"发表", @"口令" ]];
    if (hits.count == 0) {
        DYLog(@"comment sheet dump: no comment-related text visible");
        return;
    }
    for (DYViewHit *hit in hits) {
        DYLog(@"comment sheet text: '%@' (%@)", hit.text, NSStringFromClass(hit.view.class));
    }
}

/// Writes `text` into a UITextField / UITextView and notifies the host app's
/// change handlers so the 发送 button enables. Setting .text alone is not
/// enough: Douyin may key off either the control's editing-changed action OR
/// the delegate callback, so we fire both. The delegate call goes through
/// performSelector: because -Werror rejects a direct -textFieldDidChange:
/// (the selector is not visible on this SDK's delegate protocol type).
- (void)fillInput:(UIView *)view withText:(NSString *)text {
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *tf = (UITextField *)view;
        tf.text = text;
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        id delegate = tf.delegate;
        if ([delegate respondsToSelector:@selector(textFieldDidChange:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:@selector(textFieldDidChange:) withObject:tf];
            #pragma clang diagnostic pop
        }
    } else if ([view isKindOfClass:UITextView.class]) {
        // UITextView is NOT a UIControl, so it has no sendActionsForControlEvents:.
        // Notify via the delegate callback (and the change notification) instead.
        UITextView *tv = (UITextView *)view;
        tv.text = text;
        id delegate = tv.delegate;
        if ([delegate respondsToSelector:@selector(textViewDidChange:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:@selector(textViewDidChange:) withObject:tv];
            #pragma clang diagnostic pop
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification
                                                            object:tv];
    }
    DYLog(@"filled comment input with %lu chars", (unsigned long)text.length);
}

/// Taps a 关注 / 加入粉丝团 gate when present and the user opted in.
- (void)handleFollowGate {
    DYViewHit *gate = [DYViewDetector firstControlWithTextContainingAny:@[ @"关注", @"加入粉丝团", @"加入团" ]];
    if (!gate) {
        return;
    }
    if (![DYConfig shared].autoFollowForBags) {
        DYLog(@"follow gate detected ('%@') but autoFollowForBags is OFF — comment may be blocked",
              gate.text);
        return;
    }
    DYLog(@"follow gate: tapping '%@'", gate.text);
    [[DYTouch shared] tapView:gate.view];
}

/// Light post-send check: the 发送 button should be gone once the comment posts.
- (void)verifyCommentSent {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }
        DYViewHit *send = [DYViewDetector firstControlWithTextContainingAny:@[ @"发送", @"发表", @"发布" ]];
        if (!send) {
            DYLog(@"comment verify: OK - 发送 button gone (comment posted)");
        } else {
            DYLog(@"comment verify: 发送 button still present - send may not have landed");
            [strongSelf updateStatus:@"评论可能未发出"];
        }
    });
}

- (void)handleWin:(DYTextHit *)hit {
    if (self.state == DYEngineStateWon) {
        return;  // already reported this win; do not inflate the counter
    }
    self.state = DYEngineStateWon;
    [[DYConfig shared] incrementWinCount];
    [[DYConfig shared] synchronize];
    [self updateStatus:[NSString stringWithFormat:@"中奖：%@", hit.text]];
    DYLog(@"WIN detected: '%@' (today wins=%ld)",
          hit.text, (long)[DYConfig shared].todayWinCount);

    if ([DYConfig shared].winBannerAlert) {
        // The panel owns the banner so the engine stays UI-free.
        [[NSNotificationCenter defaultCenter]
         postNotificationName:@"DYLuckyBagWinNotification"
         object:nil
         userInfo:@{ @"text" : hit.text ?: @"" }];
    }
}

#pragma mark - Helper extraction

/// Picks the "join" text that is actually a button, not a participant count.
- (DYTextHit *)joinButtonHitFromHits:(NSArray<DYTextHit *> *)hits {
    NSArray<DYTextHit *> *candidates = [hits dy_hitsContaining:kWordJoin];

    for (DYTextHit *hit in candidates) {
        NSString *text = hit.text ?: @"";

        // "1234人参与" and "1234人已参与" are counters, not buttons.
        if ([text rangeOfString:@"人参与"].location != NSNotFound) {
            continue;
        }
        if ([text rangeOfString:@"人已参与"].location != NSNotFound) {
            continue;
        }
        // "参与人数9" is a participant-count label; "参与条件" is the conditions
        // text. Both contain "参与" but neither is the join button.
        if ([text rangeOfString:@"参与人数"].location != NSNotFound) {
            continue;
        }
        if ([text rangeOfString:@"条件"].location != NSNotFound) {
            continue;
        }
        // Countdown-ish strings are not buttons either.
        if ([text rangeOfString:@":"].location != NSNotFound) {
            continue;
        }
        // A bare count such as "参与 12" is a label.
        if (text.length > 12) {
            continue;
        }

        return hit;
    }
    return nil;
}

/// Pulls the keyword out of strings like "口令: 主播最棒" or "口令：ABC".
- (void)captureKeywordFromHits:(NSArray<DYTextHit *> *)hits {
    if (![DYConfig shared].commentKeywordAutoSend) {
        return;
    }

    NSArray<DYTextHit *> *keywordHits = [hits dy_hitsContaining:kWordKeyword];
    for (DYTextHit *hit in keywordHits) {
        NSString *keyword = [self keywordFromText:hit.text];
        if (keyword.length == 0) {
            continue;
        }
        if ([keyword isEqualToString:self.lastKeyword]) {
            return;  // already seen this one
        }
        self.lastKeyword = keyword;
        DYLog(@"captured keyword: '%@'", keyword);
        [self updateStatus:[NSString stringWithFormat:@"已捕获口令：%@", keyword]];

        // The actual post happens in -sendCommentWithKeyword: once we tap 参与
        // and the comment sheet opens; we just remember the 口令 here.
        DYLog(@"keyword captured, will post on join");
        return;
    }
}

- (NSString *)keywordFromText:(NSString *)text {
    if (text.length == 0) {
        return nil;
    }
    NSArray<NSString *> *separators = @[ @"：", @":", @" " ];
    for (NSString *separator in separators) {
        NSRange range = [text rangeOfString:separator];
        if (range.location == NSNotFound) {
            continue;
        }
        NSString *tail = [text substringFromIndex:NSMaxRange(range)];
        tail = [tail stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tail.length > 0 && tail.length <= 30) {
            return tail;
        }
    }
    return nil;
}

- (BOOL)isDuplicateTapAtPoint:(CGPoint)point {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastTapTime > kTapCooldown) {
        return NO;
    }
    CGFloat dx = point.x - self.lastTapPoint.x;
    CGFloat dy = point.y - self.lastTapPoint.y;
    return (dx * dx + dy * dy) < (kTapProximity * kTapProximity);
}

#pragma mark - State reporting

- (void)updateStatus:(NSString *)status {
    self.lastStatus = status;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.onUpdate) {
            strongSelf.onUpdate(strongSelf.state, status);
        }
    });
}

@end
