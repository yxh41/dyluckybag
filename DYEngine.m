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

// 超级福袋 (super lucky bag): requires joining the shopping fan club (购物粉丝团)
// AND posting a fixed, card-specified comment (shown as "发送评论：<text>"), unlike
// a 口令 bag whose comment is a secret keyword revealed only after 参与.
static NSString *const kWordSuperBag    = @"超级福袋";
static NSString *const kWordSendComment = @"发送评论";
static NSString *const kWordFanClubTask = @"福袋任务";
// 超级福袋 puts a one-tap button on the bag panel that posts the card-specified
// comment for you. There is NO comment input box on these panels, so a flow that
// waits for -firstInputField will never find one and degrades to a plain join
// (see dyluckybag(16).log: 6x "input not ready" -> "no comment box").
static NSString *const kWordOneClickComment = @"一键发表评论";

// While a bag is counting down, Douyin labels the floating room entry with the
// remaining time ("距开抢 04:32") and only flips it to 待参与 / 参与 once the draw
// window opens. Waiting for that flip is why the tweak looked dead during the
// countdown ("只要福袋是显示倒计时的就识别不到"): the 参与 button does not exist
// outside the panel. The entry itself is tappable the whole time, so we open the
// panel ourselves and read the real button from inside it.
static NSArray<NSString *> *const kCountdownWords = @[
    @"距开抢", @"开抢", @"倒计时", @"即将开始", @"未开始", @"后开奖"
];
// Text that only exists once the bag panel is ON SCREEN. Tapping the entry again
// while the panel is up would toggle it shut, so the entry tap is suppressed
// whenever one of these is visible. Deliberately excludes 距开抢 (that also sits
// on the collapsed entry) and 说点什么 (the room's own chat box uses it too).
static NSArray<NSString *> *const kBagPanelWords = @[
    @"参与条件", @"福袋任务", @"中奖名单", @"一键发表评论", @"发送评论",
    @"参与人数", @"人已参与", @"奖品"
];
// The floating entry lives in the upper-left of the live room (device log:
// join='待参与' at y≈160 on an 812pt screen). The bag panel is a bottom sheet.
// So when the panel is up, the join candidate to act on is the LOWER one — this
// keeps us from tapping the entry (which would dismiss the panel) instead of the
// panel's own button.
static const CGFloat kPanelTopFraction = 0.45;

// A tap landing within this radius of the previous tap is treated as the same
// button, so we do not hammer "join" on every scan pass.
static const CGFloat kTapProximity = 44.0;
static const NSTimeInterval kTapCooldown = 6.0;
// The entry tap opens a panel, so it needs a much longer window than a button
// tap: re-tapping would close the panel we just opened and start a flicker loop.
static const NSTimeInterval kBagEntryCooldown = 12.0;

// Scan cadence adapts to whether a lucky bag is actually on screen. Fast while
// one is present (we want to catch the "参与" button immediately); slow when the
// user is just scrolling the feed / watching short videos, so the periodic OCR
// pass never competes with video playback for the main thread.
static const NSTimeInterval kFastInterval = 1.5;
static const NSTimeInterval kSlowInterval = 6.0;
static const NSInteger kQuietThreshold = 10;

// How many times -attemptCommentSend: probes for the comment box / follow-confirm
// dialog before giving up and counting the bag as a plain join. Bumped above the
// old 2 because the fan-club confirmation flow consumes a pass or two while the
// dialog animates in and out.
static const NSInteger kCommentMaxAttempts = 6;

@interface DYEngine ()
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL scanning;
@property (nonatomic, readwrite) DYEngineState state;
@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, copy, readwrite) NSString *lastStatus;
@property (nonatomic) CGPoint lastTapPoint;
@property (nonatomic) CFTimeInterval lastTapTime;
@property (nonatomic) NSString *lastKeyword;
@property (nonatomic, copy) NSString *superBagComment;   // fixed comment a 超级福袋 prints on its card
@property (nonatomic) BOOL superBagActive;               // re-detected every scan; NOT cleared at end of handleHits
@property (nonatomic) BOOL isTrueSuperBag;               // card literally says 超级福袋 (OCR or view tree) — drives the bitmap OCR one-tap
@property (nonatomic) BOOL ocrBusy;                      // guards re-entrant async OCR one-tap calls
// Follow-gate debounce: -attemptCommentSend: runs up to 6 passes and tapped the
// SAME gate on every pass on device (7x '粉丝团' in a row), which kept popping the
// 购物粉丝团 panel and covered the bag panel so 一键发表评论 disappeared.
@property (nonatomic) CFTimeInterval lastGateTapTime;
@property (nonatomic, copy) NSString *lastGateLabel;
// Set when the comment was posted via a 超级福袋's 「一键发表评论」 button. The
// post-send check must NOT then look for a generic 发送/发表/发布 control: that
// very button contains 发表, so it would always look "still present" and report a
// false failure.
@property (nonatomic) BOOL lastCommentWasOneClick;
@property (nonatomic) NSInteger quietPasses;
@property (nonatomic) NSTimeInterval currentInterval;
// Bag-entry (collapsed floating entry) tap bookkeeping. Opening the panel is a
// different action from joining, so it gets its own, much longer cooldown: a
// second tap would close the panel we just opened.
@property (nonatomic) CFTimeInterval lastEntryTapTime;
@property (nonatomic) BOOL panelOpenedByUs;
@property (nonatomic) NSInteger bagEntryOpenAttempts;
// Rate-limits -runCommentFlowOnOpenPanel: handleHits fires every 1.5s while a
// comment chain runs for ~5s, so without this the chains would overlap.
@property (nonatomic) CFTimeInterval lastCommentChainTime;

// Declared up front so -Werror never trips on a forward reference.
- (DYTextHit *)joinButtonHitFromHits:(NSArray<DYTextHit *> *)hits;
- (DYViewHit *)validJoinView:(DYViewHit *)candidate;
- (void)verifyTapAtPoint:(CGPoint)point;
// Countdown / collapsed-entry handling.
- (BOOL)bagPanelVisibleInHits:(NSArray<DYTextHit *> *)hits;
- (BOOL)countdownVisibleInHits:(NSArray<DYTextHit *> *)hits;
- (DYViewHit *)bagEntryView;
- (DYTextHit *)bagEntryHitFromHits:(NSArray<DYTextHit *> *)hits;
- (DYTextHit *)countdownEntryHitFromHits:(NSArray<DYTextHit *> *)hits;
- (NSArray<DYViewHit *> *)joinCandidates;
- (DYViewHit *)joinViewWithPanelUp:(BOOL)panelUp;
- (DYTextHit *)panelJoinHitFromHits:(NSArray<DYTextHit *> *)hits;
- (DYViewHit *)joinedIndicatorView;
- (BOOL)joinedIndicatorInHits:(NSArray<DYTextHit *> *)hits;
- (void)openBagPanelFromHits:(NSArray<DYTextHit *> *)hits
                      bagHit:(DYTextHit *)bagHit
                   countdown:(BOOL)countdown
                       entry:(DYViewHit *)entryFromJoinScan;
- (void)runCommentFlowOnOpenPanelDuringCountdown:(BOOL)countdown;
// Comment / 口令 bag participation (Option B).
- (void)sendCommentWithKeyword:(NSString *)keyword tapPoint:(CGPoint)pt;
- (void)attemptCommentSend:(NSString *)keyword attempt:(NSInteger)attempt;
- (void)fillInput:(UIView *)view withText:(NSString *)text;
- (void)handleFollowGate;
- (void)verifyCommentSent;
// 超级福袋 one-tap comment.
- (void)tapOneClickCommentByOCR:(NSString *)keyword attempt:(NSInteger)attempt;
- (void)finishOneClickComment;
- (void)fillAndSend:(NSString *)comment
              input:(DYViewHit *)input
            prefill:(NSString *)prefill
            attempt:(NSInteger)attempt;
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
        // This completion runs on a LATER call stack (OCR dispatches its result to
        // the main queue), so it is OUTSIDE the @try of any caller. Guard it
        // directly so an exception cannot escape and crash Douyin.
        @try {
            strongSelf.scanning = NO;
            if (error) {
                [strongSelf updateStatus:[NSString stringWithFormat:@"OCR 失败: %@",
                                          error.localizedDescription]];
                return;
            }
            [strongSelf handleHits:hits];
        } @catch (NSException *exception) {
            DYLog(@"scanOnce completion: caught exception (%@): %@",
                  exception.name, exception.reason);
            strongSelf.scanning = NO;
        }
    }];
}

#pragma mark - Decision making

- (void)handleHits:(NSArray<DYTextHit *> *)hits {
    // The whole scan→decision→tap pipeline runs on the main run loop (it is
    // invoked directly from the OCR completion block). Any exception that escapes
    // here would crash Douyin, so guard the entire handler and degrade to a logged
    // skip instead of taking down the host.
    @try {
    // Fresh per-scan super-bag state; re-detected just below. (Do NOT clear at the
    // end of handleHits — the async comment flow reads superBagComment later.)
    self.superBagComment = nil;
    self.superBagActive = NO;

    // Decide whether a lucky bag is on screen. OCR covers the case where the
    // screen capture succeeded; the view-tree scan needs no capture at all, so
    // it still finds the 福袋 / 参与 controls when drawViewHierarchyInRect
    // fails inside a live room (the Metal video layer has no CPU backing).
    DYTextHit *bagHit = [hits dy_firstHitContaining:kWordBag];
    BOOL bagByOCR = (bagHit != nil);

    DYViewHit *bagView    = [DYViewDetector firstViewWithTextContaining:kWordBag];
    // "已参与" must come from the button/badge, never from a counter such as
    // "1234人已参与" or "参与人数 9" — those are always on the panel, so matching
    // them would make the engine believe the bag was joined and skip the tap.
    DYViewHit *joinedView = [self joinedIndicatorView];

    // A countdown entry shows ONLY "距开抢 mm:ss" with no 福袋 word for OCR, so
    // neither bagByOCR nor bagView fires — that is the "识别不到" case. Catch it by
    // the countdown text alone (upper-area only, so a feed flash-sale card can't
    // fake it). We do NOT need the exact text as a target; opening the panel reads
    // the real button from inside.
    DYTextHit *countdownEntry = [self countdownEntryHitFromHits:hits];

    BOOL sawBag = bagByOCR || (bagView != nil) || (countdownEntry != nil);
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

    // 2. No bag anywhere (neither OCR nor view tree)? A countdown entry counts as a
    //    bag (it is the floating entry with no 福袋 word for OCR — see above).
    if (!bagByOCR && !bagView && !countdownEntry) {
        if (self.state != DYEngineStateIdle) {
            self.state = DYEngineStateIdle;
            [self updateStatus:@"当前直播间没有福袋"];
        }
        // No bag on screen — forget the entry/panel bookkeeping so the next room
        // starts clean (and the open-attempt cap is not carried across rooms).
        self.panelOpenedByUs = NO;
        self.bagEntryOpenAttempts = 0;
        return;
    }

    // Panel vs collapsed entry. This distinction is the core of both reported
    // bugs and must be known BEFORE we decide what a 参与 hit means:
    //   - panel closed => any 参与/待参与 text belongs to the floating entry, and
    //     tapping it merely OPENS the panel (it is not a join);
    //   - panel open   => a 参与 hit is the real join button.
    BOOL panelUp   = [self bagPanelVisibleInHits:hits];
    BOOL countdown = [self countdownVisibleInHits:hits];
    if (panelUp) {
        // The entry tap did its job (or the user opened the panel by hand). Clear
        // the flag so a later 未打开 state is diagnosed as a fresh failure rather
        // than blamed on this success.
        self.panelOpenedByUs = NO;
        self.bagEntryOpenAttempts = 0;
    }

    // Scan EVERY 参与 hit rather than just the first: once the panel is open the
    // first match in tree order is usually the "参与条件" label, and taking only
    // -firstViewWithTextContaining: hid the real button behind it. With the panel
    // up we also prefer the LOWER candidate (bottom sheet) over the floating entry.
    DYViewHit *joinView = joinedView ? nil : [self joinViewWithPanelUp:panelUp];

    DYLog(@"bag detected (ocr=%d viewTree=%d panel=%d countdown=%d)%@",
          bagByOCR, bagView != nil, panelUp, countdown,
          joinView ? [NSString stringWithFormat:@" join='%@'", joinView.text] : @"");

    // 3. Extract the keyword (口令) if the bag requires a comment to enter.
    [self captureKeywordFromHits:hits];

    // 3b. 超级福袋 detection: it needs the shopping fan-club join (购物粉丝团) AND a
    // fixed, card-specified comment ("发送评论：<text>"), unlike a 口令 bag whose
    // comment is a secret keyword. Capture that comment so the comment flow can post
    // it. Re-detected every scan (cleared at the top of handleHits).
    BOOL superBag = [hits dy_firstHitContaining:kWordSuperBag] != nil
                 || [DYViewDetector firstViewWithTextContaining:kWordSuperBag] != nil
                 || [DYViewDetector firstViewWithTextContaining:kWordSendComment] != nil
                 || [DYViewDetector firstViewWithTextContaining:kWordFanClubTask] != nil;
    self.superBagActive = superBag;
    // TRUE super bag = the card literally says 超级福袋. A plain 评论福袋 also shows
    // 发送评论： but is NOT a 超级福袋 and has no 一键发表评论 button, so it must go
    // through the comment-box flow, never the OCR one-tap. This flag drives the
    // bitmap-button OCR fallback (a 超级福袋 whose 一键发表评论 is a Lynx bitmap has
    // no view-tree node — see dyluckybag(16): OCR read [一键发表评论 @195,747]).
    self.isTrueSuperBag = [hits dy_firstHitContaining:kWordSuperBag] != nil
                       || [DYViewDetector firstViewWithTextContaining:kWordSuperBag] != nil;
    if (superBag) {
        NSString *c = [self captureSpecifiedCommentFromHits:hits];
        if (c.length) {
            self.superBagComment = c;
            DYLog(@"super bag: captured specified comment '%@'", c);
            [self updateStatus:[NSString stringWithFormat:@"超级福袋：已捕获评论「%@」", c]];
        } else {
            DYLog(@"super bag detected (comment not yet visible in OCR)");
        }
    }

    // 4. Already joined? Then we are waiting for the draw, not tapping again.
    //    OCR side must also ignore counters ("1234人已参与") — see -joinedIndicatorView.
    if ([self joinedIndicatorInHits:hits] || joinedView) {
        self.state = DYEngineStateWaitingResult;
        [self updateStatus:@"已参与，等待开奖"];
        return;
    }

    // 4b. Panel vs entry was resolved above (panelUp / countdown).
    // 5. Classify the target. The collapsed floating entry and the panel's own
    //    join button BOTH match 参与 / 待参与, but they mean completely different
    //    things and conflating them is the second reported bug ("福袋并未成功参与"):
    //      - entry tap  -> merely OPENS the bag panel. It is NOT a join. Old builds
    //        counted it as one and then ran the comment flow against a panel that
    //        has no comment box, producing a phantom "已参与（无评论框）" for a bag
    //        the tweak had never actually entered (see dyluckybag(10/17).log:
    //        join='待参与' at y≈160 — that y is the floating entry, not the panel).
    //      - panel button tap -> the real join; the comment flow belongs here.
    //    panelUp is the discriminator: no panel on screen => whatever we tap can
    //    only be the entry.
    if (!panelUp) {
        [self openBagPanelFromHits:hits
                            bagHit:bagHit
                         countdown:countdown
                             entry:joinView];
        return;
    }

    // 5b. Panel is up: find the real join control inside it.
    UIView *joinTargetView = nil;
    CGPoint center;
    NSString *joinLabel;
    if (joinView) {
        joinLabel = joinView.text;
        center = CGPointMake(CGRectGetMidX(joinView.screenRect),
                              CGRectGetMidY(joinView.screenRect));
        joinTargetView = joinView.view;
    } else {
        DYTextHit *joinOCR = [self panelJoinHitFromHits:hits];
        if (!joinOCR) {
            // Panel up, no 参与 button on it. For a 评论福袋 that is expected:
            // participation IS posting the comment. Hand over to the comment flow
            // (guarded against overlapping chains) instead of reporting nothing.
            [self runCommentFlowOnOpenPanelDuringCountdown:countdown];
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
        // The join view came from a view-tree scan; if Douyin has already torn it
        // down (sheet dismissed / row scrolled away) tapping it faults on a stale
        // control. Skip honestly instead of touching a dead view.
        if (joinTargetView.window == nil) {
            DYLog(@"join view no longer on screen — skipping tap");
            dispatched = NO;
        } else {
            DYLog(@"tapping join (view-tree) '%@' at %@", joinLabel, NSStringFromCGPoint(center));
            dispatched = [[DYTouch shared] tapView:joinTargetView];
        }
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
    } @catch (NSException *exception) {
        DYLog(@"handleHits: caught exception (%@): %@", exception.name, exception.reason);
        [self updateStatus:@"检测/参与异常，已跳过"];
    }
}

#pragma mark - Countdown / collapsed entry

/// YES when the bag PANEL (the sheet with the join button) is on screen, as
/// opposed to the collapsed floating entry. Used to decide whether tapping the
/// entry would open the panel or close the one we just opened.
- (BOOL)bagPanelVisibleInHits:(NSArray<DYTextHit *> *)hits {
    for (NSString *w in kBagPanelWords) {
        if ([hits dy_firstHitContaining:w]) {
            return YES;
        }
        if ([DYViewDetector firstViewWithTextContaining:w]) {
            return YES;
        }
    }
    return NO;
}

/// YES when a countdown is visible ("距开抢 04:32" / "开抢倒计时"). Both the
/// collapsed entry and the open panel show it, so this alone does not tell us
/// which is up — pair it with -bagPanelVisibleInHits:.
- (BOOL)countdownVisibleInHits:(NSArray<DYTextHit *> *)hits {
    for (NSString *w in kCountdownWords) {
        if ([hits dy_firstHitContaining:w]) {
            return YES;
        }
        if ([DYViewDetector firstViewWithTextContaining:w]) {
            return YES;
        }
    }
    return NO;
}

/// The collapsed floating bag entry in the live room, from the view tree. This is
/// the thing that shows "福袋 距开抢 mm:ss" while the draw has not opened; tapping
/// it presents the bag panel that actually carries the 参与 button.
///
/// Deliberately excludes the panel-only strings and the chat-message noise: a
/// viewer typing "福袋" in chat must never be treated as the entry — tapping a chat
/// row opens that viewer's profile and covers the whole room.
- (DYViewHit *)bagEntryView {
    NSArray<DYViewHit *> *hits = [DYViewDetector findViewsWithTextContaining:@[ kWordBag ]];
    CGFloat cutoff = UIScreen.mainScreen.bounds.size.height * kPanelTopFraction;
    DYViewHit *best = nil;
    for (DYViewHit *hit in hits) {
        NSString *t = hit.text ?: @"";
        if (t.length == 0 || t.length > 24) {
            continue;   // long strings are chat lines / descriptions, not the entry
        }
        // Panel headers also contain 福袋 ("福袋任务", "超级福袋" title). Tapping
        // those does nothing useful and may dismiss the panel.
        if ([t rangeOfString:@"任务"].location != NSNotFound) continue;
        if ([t rangeOfString:@"名单"].location != NSNotFound) continue;
        if ([t rangeOfString:@"说点"].location != NSNotFound) continue;
        if ([t rangeOfString:@"条件"].location != NSNotFound) continue;
        if (CGRectIsEmpty(hit.screenRect)) {
            continue;
        }
        // The entry floats in the UPPER part of the room (device log: y≈160 on an
        // 812pt screen). The chat stream and the bottom toolbar live below the
        // cutoff, so anything down there is not the entry.
        if (CGRectGetMidY(hit.screenRect) >= cutoff) {
            continue;
        }
        // Prefer whatever is tappable; otherwise keep the first plausible node so
        // DYTouch's coordinate fallback still has a target.
        if (hit.isControl) {
            return hit;
        }
        if (!best) {
            best = hit;
        }
    }
    return best;
}

/// OCR counterpart of -bagEntryView, used when the entry is a Lynx bitmap with no
/// readable text node. Same reasoning: upper area only, and never a chat line.
- (DYTextHit *)bagEntryHitFromHits:(NSArray<DYTextHit *> *)hits {
    CGFloat cutoff = UIScreen.mainScreen.bounds.size.height * kPanelTopFraction;
    for (DYTextHit *h in [hits dy_hitsContaining:kWordBag]) {
        NSString *t = h.text ?: @"";
        if (t.length == 0 || t.length > 24) continue;
        if ([t rangeOfString:@"任务"].location != NSNotFound) continue;
        if ([t rangeOfString:@"名单"].location != NSNotFound) continue;
        if ([t rangeOfString:@"条件"].location != NSNotFound) continue;
        if (CGRectIsEmpty(h.rect)) continue;
        if (CGRectGetMidY(h.rect) >= cutoff) continue;
        return h;
    }
    return nil;
}

/// During a countdown the collapsed entry often shows ONLY the remaining time
/// ("距开抢 mm:ss" / "开抢倒计时") and the word 福袋 never reaches OCR, so the
/// generic "no 福袋 text" exit would wrongly report "当前直播间没有福袋" — that is
/// exactly the "识别不到" complaint. This catches that entry by its countdown text
/// alone, constrained to the upper area so a 商品 flash-sale "距开抢" card (which
/// sits lower in the feed) cannot masquerade as the bag.
- (DYTextHit *)countdownEntryHitFromHits:(NSArray<DYTextHit *> *)hits {
    CGFloat cutoff = UIScreen.mainScreen.bounds.size.height * kPanelTopFraction;
    for (NSString *kw in kCountdownWords) {
        for (DYTextHit *h in [hits dy_hitsContaining:kw]) {
            if (CGRectIsEmpty(h.rect)) continue;
            if (CGRectGetMidY(h.rect) >= cutoff) continue;   // not the floating entry
            return h;
        }
    }
    return nil;
}

/// Every plausible 参与 / 待参与 control on screen, in tree order. Scanning ALL of
/// them (instead of -firstViewWithTextContaining:) matters because in tree order
/// "参与条件" and "1234人已参与" usually come before the real button and used to
/// mask it entirely.
- (NSArray<DYViewHit *> *)joinCandidates {
    NSArray<DYViewHit *> *hits =
        [DYViewDetector findViewsWithTextContaining:@[ kWordJoin, @"待参与", @"立即参与" ]];
    NSMutableArray<DYViewHit *> *out = [NSMutableArray array];
    for (DYViewHit *hit in hits) {
        DYViewHit *valid = [self validJoinView:hit];
        if (valid) {
            [out addObject:valid];
        }
    }
    return out;
}

/// Picks the join control to act on.
///
/// `panelUp == YES`: only accept a candidate in the LOWER part of the screen — the
/// bag panel is a bottom sheet, while the collapsed entry floats near the top
/// (device log: join='待参与' at y≈160). Tapping the entry with the panel open would
/// dismiss the panel, which is how earlier builds "参与" without ever joining.
///
/// `panelUp == NO`: only accept an UPPER candidate — that is the entry, returned so
/// the caller can tap it to OPEN the panel (not to join).
- (DYViewHit *)joinViewWithPanelUp:(BOOL)panelUp {
    NSArray<DYViewHit *> *candidates = [self joinCandidates];
    if (candidates.count == 0) {
        return nil;
    }
    CGFloat cutoff = UIScreen.mainScreen.bounds.size.height * kPanelTopFraction;
    if (!panelUp) {
        // Entry only: it floats in the UPPER area. A 参与 hit below the cutoff with
        // no panel on screen is a chat row ("小明参与了福袋") — tapping it opens that
        // viewer's profile. Prefer a tappable upper node, else any upper node.
        DYViewHit *upperAny = nil;
        for (DYViewHit *hit in candidates) {
            if (CGRectGetMidY(hit.screenRect) >= cutoff) {
                continue;
            }
            if (hit.isControl) {
                return hit;
            }
            if (!upperAny) {
                upperAny = hit;
            }
        }
        return upperAny;
    }

    DYViewHit *lowerControl = nil, *lowerAny = nil;
    for (DYViewHit *hit in candidates) {
        if (CGRectGetMidY(hit.screenRect) < cutoff) {
            continue;   // upper area => the floating entry, NOT the panel button
        }
        if (hit.isControl && !lowerControl) lowerControl = hit;
        if (!lowerAny)                      lowerAny = hit;
    }
    // Deliberately returns nil when every candidate sits in the upper area: with
    // the panel open, the only 参与-ish text up there is the floating entry, and
    // tapping that DISMISSES the panel we just opened. nil sends the caller to the
    // OCR pick (also panel-filtered) and then to the comment flow, which is the
    // correct handling for a panel whose button is a Lynx bitmap.
    return lowerControl ?: lowerAny;
}

/// OCR counterpart of the panel filter above. -joinButtonHitFromHits: has no idea
/// whether a rect belongs to the panel or to the floating entry, so with the panel
/// open it would happily hand back the entry's 待参与 at y≈160 and we would tap the
/// panel shut. Restrict it to the bottom-sheet area.
- (DYTextHit *)panelJoinHitFromHits:(NSArray<DYTextHit *> *)hits {
    CGFloat cutoff = UIScreen.mainScreen.bounds.size.height * kPanelTopFraction;
    NSMutableArray<DYTextHit *> *lower = [NSMutableArray array];
    for (DYTextHit *h in hits) {
        if (CGRectGetMidY(h.rect) >= cutoff) {
            [lower addObject:h];
        }
    }
    return [self joinButtonHitFromHits:lower];
}

/// "已参与" that is really the joined badge, not a participant counter. The old
/// -firstViewWithTextContaining:@"已参与" matched "1234人已参与" on the panel and
/// made the engine report 已参与，等待开奖 for a bag it had never joined.
- (DYViewHit *)joinedIndicatorView {
    NSArray<DYViewHit *> *hits = [DYViewDetector findViewsWithTextContaining:@[ @"已参与" ]];
    for (DYViewHit *hit in hits) {
        NSString *t = hit.text ?: @"";
        if ([t rangeOfString:@"人已参与"].location != NSNotFound) continue;
        if ([t rangeOfString:@"参与人数"].location != NSNotFound) continue;
        if (t.length > 12) continue;   // "已有 1234 人已参与" style lines
        return hit;
    }
    return nil;
}

/// Same counter filtering for the OCR side.
- (BOOL)joinedIndicatorInHits:(NSArray<DYTextHit *> *)hits {
    for (DYTextHit *h in [hits dy_hitsContaining:@"已参与"]) {
        NSString *t = h.text ?: @"";
        if ([t rangeOfString:@"人已参与"].location != NSNotFound) continue;
        if ([t rangeOfString:@"参与人数"].location != NSNotFound) continue;
        if (t.length > 12) continue;
        return YES;
    }
    return NO;
}

/// Opens the bag panel by tapping the collapsed floating entry. This fixes BOTH
/// reported symptoms:
///
///  1. "只要福袋是显示倒计时的就识别不到" — during the countdown the entry reads
///     "距开抢 mm:ss" and there is no 参与 text anywhere, so the engine had nothing
///     to act on and just logged 未找到参与按钮 until the user opened the panel by
///     hand. Now we open it ourselves and the next pass reads the real button.
///
///  2. "福袋并未成功参与" — the entry ALSO cycles through 待参与, and older builds
///     tapped that, counted a join, and immediately ran the comment flow against a
///     screen with no comment box (=> phantom 已参与（无评论框）). Tapping the entry
///     is now classified for what it is: opening the panel, not joining.
///
/// The tap has its own 12s cooldown (kBagEntryCooldown): the entry TOGGLES the
/// panel, so re-tapping on every 1.5s pass would flicker it open and shut.
- (void)openBagPanelFromHits:(NSArray<DYTextHit *> *)hits
                      bagHit:(DYTextHit *)bagHit
                   countdown:(BOOL)countdown
                       entry:(DYViewHit *)entryFromJoinScan {
    self.state = DYEngineStateBagDetected;

    if ([DYConfig shared].patrolMode == DYPatrolModeDetectOnly) {
        NSString *s = countdown ? @"[仅检测] 福袋倒计时中（未打开面板）"
                                : @"[仅检测] 检测到福袋入口（未打开面板）";
        [self updateStatus:s];
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastEntryTapTime < kBagEntryCooldown) {
        NSString *s = countdown ? @"福袋倒计时中，等待开抢" : @"正在打开福袋面板…";
        [self updateStatus:s];
        DYLog(@"bag entry: tapped %.1fs ago — waiting (cooldown %.0fs, countdown=%d)",
              now - self.lastEntryTapTime, kBagEntryCooldown, countdown);
        return;
    }
    // Give up auto-opening after a few taps. The entry is a toggle, so a tap that
    // the panel has since masked (or one whose success OCR cannot confirm) would
    // otherwise re-fire every 12s and flicker the panel open/closed forever. Past
    // the cap we surface it and let the user open it by hand.
    if (self.bagEntryOpenAttempts >= 3) {
        [self updateStatus:@"福袋入口点击多次未打开面板，请手动打开面板参与"];
        DYLog(@"bag entry: %ld open attempts exhausted — leaving panel to the user "
              @"(countdown=%d)", (long)self.bagEntryOpenAttempts, countdown);
        return;
    }
    if (self.panelOpenedByUs) {
        // We tapped the entry a full cooldown ago and the panel still is not up.
        DYLog(@"bag entry: previous tap did not open the panel — retrying");
    }

    // -joinViewWithPanelUp:NO already restricted the candidate to the upper area
    // where the entry floats, so it is safe to tap directly. Fall back to the 福袋
    // text node, then to the OCR rect for a Lynx bitmap entry with no text node.
    DYViewHit *entry = entryFromJoinScan ?: [self bagEntryView];
    DYTextHit *entryOCR = [self bagEntryHitFromHits:hits] ?: [self countdownEntryHitFromHits:hits];
    BOOL dispatched = NO;
    if (entry && entry.view && entry.view.window != nil) {
        DYLog(@"bag entry: opening panel via view tree '%@' (countdown=%d)",
              entry.text, countdown);
        dispatched = [[DYTouch shared] tapView:entry.view];
    } else if (entryOCR) {
        DYLog(@"bag entry: opening panel via OCR rect '%@' at (%.0f,%.0f) (countdown=%d)",
              entryOCR.text, CGRectGetMidX(entryOCR.rect), CGRectGetMidY(entryOCR.rect), countdown);
        dispatched = [[DYTouch shared] tapInRect:entryOCR.rect];
    } else {
        DYLog(@"bag entry: no tappable entry found (neither view tree nor OCR; "
              @"ocrBag='%@')", bagHit.text ?: @"(none)");
    }

    if (dispatched) {
        self.lastEntryTapTime = now;
        self.panelOpenedByUs = YES;
        self.bagEntryOpenAttempts += 1;
        NSString *s = countdown ? @"福袋倒计时中，已打开面板待开抢"
                                : @"已打开福袋面板，寻找参与按钮";
        [self updateStatus:s];
    } else {
        NSString *s = countdown ? @"福袋倒计时中，入口点击失败"
                                : @"检测到福袋，入口点击失败";
        [self updateStatus:s];
    }
}

/// The panel is open but has no 参与 button. For a 评论福袋 / 超级福袋 that is the
/// normal shape: participation IS posting the comment, and the panel only offers
/// the comment box or the 一键发表评论 button. Older builds returned
/// 检测到福袋，未找到参与按钮 here and never posted anything.
///
/// `countdown` matters: while the panel still reads 距开抢 mm:ss the bag has not
/// opened yet and nothing can be posted, so a comment chain fired now would burn
/// its 6 attempts against a dead panel and log a phantom result. During a countdown
/// we therefore require a REAL affordance (the one-tap button or an actual input
/// field) and otherwise just wait for the flip.
///
/// Rate-limited either way: -handleHits runs every 1.5s while -attemptCommentSend:
/// retries for ~5s, so an unguarded call would stack overlapping chains.
- (void)runCommentFlowOnOpenPanelDuringCountdown:(BOOL)countdown {
    self.state = DYEngineStateBagDetected;

    if ([DYConfig shared].patrolMode == DYPatrolModeDetectOnly) {
        [self updateStatus:@"[仅检测] 福袋面板已打开（无参与按钮）"];
        return;
    }
    if (![DYConfig shared].commentKeywordAutoSend) {
        [self updateStatus:@"福袋面板已打开，未开启自动评论"];
        return;
    }

    // A button/box we can actually act on right now. The room's own "说点什么"
    // placeholder is NOT a real, focused input — qualifying it would let the
    // comment flow fire into the live-room chat during a countdown. Require either
    // the one-tap button or an input that is genuinely live (focused, or already
    // holding text from a popped 口令 sheet).
    BOOL oneClick = [DYViewDetector firstViewWithTextContaining:kWordOneClickComment] != nil;
    DYViewHit *input = [DYViewDetector firstInputField];
    BOOL realInput = (input != nil) && (input.view.isFirstResponder || input.text.length > 0);
    BOOL actionable = oneClick || realInput;
    if (countdown && !actionable) {
        // Pre-open bag: panel is up, participation is not live yet. Sit on it —
        // the next pass will see the 参与 button the moment Douyin enables it.
        [self updateStatus:@"福袋面板已打开，倒计时中待开抢"];
        DYLog(@"panel open during countdown with no actionable comment affordance "
              @"— waiting for the bag to open");
        return;
    }

    BOOL hasCommentContext = actionable
                          || self.superBagActive
                          || self.superBagComment.length > 0
                          || self.lastKeyword.length > 0;
    if (!hasCommentContext) {
        [self updateStatus:@"检测到福袋，未找到参与按钮"];
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    // One chain per bag-panel window. kCommentMaxAttempts x 0.8s = 4.8s, so 8s
    // guarantees the previous chain has finished before a new one may start.
    if (now - self.lastCommentChainTime < 8.0) {
        DYLog(@"panel comment flow: chain started %.1fs ago — skipping",
              now - self.lastCommentChainTime);
        return;
    }
    self.lastCommentChainTime = now;
    DYLog(@"panel open with no 参与 button — running the comment flow directly "
          @"(superBag=%d countdown=%d comment='%@')",
          self.superBagActive, countdown, self.superBagComment);
    [self updateStatus:@"福袋面板已打开，正在发送评论参与"];
    // lastTapPoint is only used by the fallback verify; point it at the panel so a
    // stale coordinate from a previous bag cannot be re-verified.
    [self sendCommentWithKeyword:self.lastKeyword tapPoint:self.lastTapPoint];
    self.lastKeyword = nil;
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
        // The whole block runs on a later call stack, outside any caller's @try.
        // Guard it so a verify failure can never crash the host.
        @try {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }

        [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits, NSError *error) {
            @try {
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
            } @catch (NSException *exception) {
                DYLog(@"verifyTapAtPoint OCR: caught exception (%@): %@",
                      exception.name, exception.reason);
            }
        }];
        } @catch (NSException *exception) {
            DYLog(@"verifyTapAtPoint: caught exception (%@): %@",
                  exception.name, exception.reason);
        }
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
    // Fresh bag, fresh budget: the follow-gate debounce and the one-click flag
    // are per-participation, so a previous bag's gate taps cannot suppress this
    // one's (and a stale one-click flag cannot hijack this bag's verify).
    self.lastGateLabel = nil;
    self.lastGateTapTime = 0;
    self.lastCommentWasOneClick = NO;
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

        // The whole comment-resolution path runs on the main run loop; any
        // exception that escapes here would take down Douyin. Guard it so a
        // failure degrades to a logged skip instead of a host crash.
        @try {
        // A confirmation dialog (关注 / 加入粉丝团 confirm) blocks the comment
        // box. If one is up, tap 确定/确认 and wait for the next pass to resolve.
        DYViewHit *confirmDialog = [DYViewDetector firstControlWithTextContainingAny:@[ @"确定", @"确认" ]];
        if (confirmDialog) {
            if (attempt < kCommentMaxAttempts) {
                DYLog(@"follow gate: confirming join ('%@')", confirmDialog.text);
                [[DYTouch shared] tapView:confirmDialog.view];
                DYLog(@"comment send: confirmation dialog up, retrying (attempt %ld)", (long)attempt);
                [strongSelf attemptCommentSend:keyword attempt:attempt + 1];
                return;
            }
            DYLog(@"comment flow: confirmation never dismissed — plain bag, counting join");
            [[DYConfig shared] incrementJoinCount];
            [[DYConfig shared] synchronize];
            [strongSelf updateStatus:@"已参与（关注确认未完成）"];
            [strongSelf verifyTapAtPoint:strongSelf.lastTapPoint];
            return;
        }

        // --- 超级福袋: capture the card-specified comment -------------------
        // A 超级福袋 prints the fixed comment on the card ("发送评论：<text>")
        // instead of asking for one. Capture it whenever we see it, so the
        // one-tap path below can log what is about to be posted.
        if (strongSelf.superBagComment.length == 0) {
            NSString *c = [strongSelf captureSpecifiedCommentFromSheet];
            if (c.length > 0) {
                strongSelf.superBagComment = c;
                DYLog(@"super bag: captured specified comment from sheet '%@'", c);
            }
        }

        // No blocking dialog — tap any follow / fan-club gate that isn't already
        // resolved. The user must have autoFollowForBags on; otherwise this is a
        // no-op and a gated bag will simply fail to comment (reported honestly).
        //
        // GATE FIRST, then the one-tap comment: a 超级福袋 can require the
        // shopping fan-club join BEFORE 「一键发表评论」 does anything. Tapping that
        // button first would no-op and return, leaving the gate permanently
        // untapped — i.e. the same "comment never posted" bug all over again.
        // The gate tap is debounced (once per label per participation), so it
        // cannot re-pop the fan-club panel over the bag panel as it used to.
        [strongSelf handleFollowGate];

        // --- 超级福袋: one-tap comment (view tree, then OCR for bitmaps) ----
        // A 超级福袋 is identified by its 「一键发表评论」 button. Plain 评论福袋
        // ALSO show 发送评论： but have NO such button — they must type the
        // comment into a 说点什么 box (the input flow below). So:
        //   - if the button is in the view tree, tap it (posts the card comment);
        //   - else if this is a TRUE 超级福袋 (OCR saw 超级福袋; isTrueSuperBag),
        //     the button is a Lynx bitmap with no view-tree node — tap it via OCR
        //     and return (a true super bag has no comment box to fall through to);
        //   - else it is a plain 评论福袋 — FALL THROUGH to the input flow so
        //     superBagComment is typed and posted there.
        // This makes 普通 评论福袋 post their comment (Build #53 wrongly returned
        // from this block on ANY 发送评论： match and swallowed them — see
        // dyluckybag(17).log), while still covering a 超级福袋 whose one-tap button
        // is a bitmap (the dyluckybag(16) case: OCR read [一键发表评论 @195,747]).
        if (strongSelf.superBagActive || strongSelf.superBagComment.length > 0) {
            // Match ANY view, not just UIControl: Lynx renders many live-room
            // controls (the join button logs as LynxTextView), and those are not
            // UIControl subclasses, so -firstControlWithTextContainingAny: would
            // find nothing. DYTouch falls back to a coordinate tap for non-controls.
            DYViewHit *oneClick = nil;
            for (NSString *kw in @[ kWordOneClickComment, @"一键发送", @"一键评论" ]) {
                oneClick = [DYViewDetector firstViewWithTextContaining:kw];
                if (oneClick) {
                    break;
                }
            }
            if (oneClick) {
                // Tapping this posts the card-specified comment for us.
                DYLog(@"super bag: tapping '%@' (comment='%@')",
                      oneClick.text, strongSelf.superBagComment ?: @"(posted by Douyin)");
                [[DYTouch shared] tapView:oneClick.view];
                [strongSelf finishOneClickComment];
                return;
            }
            // No 一键发表评论 node in the view tree. Two cases:
            //  (a) TRUE 超级福袋 whose button is a Lynx bitmap — OCR saw 超级福袋
            //      (isTrueSuperBag=YES). Tap the bitmap button via OCR and return;
            //      a true super bag has NO comment box, so never fall through.
            //  (b) Plain 评论福袋 — has a 说点什么 box, no one-tap button. Fall
            //      through to the input flow below and type+send superBagComment.
            if (strongSelf.isTrueSuperBag) {
                if (!strongSelf.ocrBusy) {
                    strongSelf.ocrBusy = YES;
                    DYLog(@"super bag: 一键发表评论 not in view tree (bitmap?) — "
                          @"trying OCR one-tap (comment='%@')", strongSelf.superBagComment);
                    [strongSelf tapOneClickCommentByOCR:keyword attempt:attempt];
                }
                return;
            }
            DYLog(@"super bag: no 一键发表评论 in view tree — using comment-box flow "
                  @"(comment='%@')", strongSelf.superBagComment);
        }
        // --- end 超级福袋 one-tap comment ----------------------------------

        // Resolve what to post. Priority:
        //   1. super-bag specified comment (captured from card/sheet) — wins for 超级福袋
        //   2. 口令 captured pre-tap / from sheet (普通口令袋)
        //   3. Douyin-prefilled box text (handled once the input is found)
        //   4. OCR of the screen (handles 口令 rendered as image, or 发送评论 text)
        NSString *comment = nil;
        if (strongSelf.superBagComment.length > 0) {
            comment = strongSelf.superBagComment;
        } else if (keyword.length > 0) {
            comment = keyword;
        } else {
            comment = [strongSelf captureKeywordFromSheet];
        }
        if (comment.length == 0) {
            // super-bag comment may only be revealed once the sheet is open
            comment = [strongSelf captureSpecifiedCommentFromSheet];
        }
        NSString *prefill = nil;

        DYViewHit *input = [DYViewDetector firstInputField];
        if (!input) {
            // No comment box appeared. Two cases:
            //  - a plain bag that joins straight on 参与 (no sheet) -> count it;
            //  - a 口令 bag whose sheet is still animating in -> retry.
            if (attempt < kCommentMaxAttempts) {
                DYLog(@"comment send: input not ready (attempt %ld), retrying", (long)attempt);
                [strongSelf attemptCommentSend:keyword attempt:attempt + 1];
                return;
            }
            // Genuinely no comment box: treat as a plain join (参与 already joined).
            // For a 超级福袋 this is NOT the expected outcome — the one-tap button
            // above should have posted. Say so, so the log is not read as success.
            if (strongSelf.superBagActive || strongSelf.superBagComment.length > 0) {
                DYLog(@"comment flow: 超级福袋 - neither 一键发表评论 nor a comment "
                      @"box appeared after %ld attempts — joined WITHOUT the comment",
                      (long)kCommentMaxAttempts);
                [[DYConfig shared] incrementJoinCount];
                [[DYConfig shared] synchronize];
                [strongSelf updateStatus:@"已参与（超级福袋评论未发出）"];
            } else {
                DYLog(@"comment flow: no comment box — plain bag, counting join");
                [[DYConfig shared] incrementJoinCount];
                [[DYConfig shared] synchronize];
                [strongSelf updateStatus:@"已参与（无评论框）"];
            }
            [strongSelf verifyTapAtPoint:strongSelf.lastTapPoint];
            return;   // real join — count it
        }

        prefill = [strongSelf textOfInput:input.view];
        if (comment.length == 0) {
            comment = prefill;   // Douyin prefilled the box with the 口令
        }
        if (comment.length == 0) {
            // View tree + prefill found nothing. Last resort: OCR the screen —
            // Douyin sometimes renders the 口令 as an image, which the view tree
            // cannot read but Vision can. If OCR also fails, dump and bail.
            [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits, NSError *error) {
                @try {
                // This completion runs on a LATER call stack than the @try that
                // wrapped the dispatch to OCR, so it is NOT under that guard.
                // Guard it here. Also re-resolve the live input field: the sheet
                // may have changed while OCR ran, and acting on the captured
                // (possibly torn-down) input.view can fault with EXC_BAD_ACCESS.
                DYViewHit *liveInput = [DYViewDetector firstInputField];
                if (!liveInput) {
                    DYLog(@"comment send: input gone during OCR — cannot post 口令");
                    [strongSelf updateStatus:@"评论框已消失，参与未完成"];
                    return;
                }
                NSString *ocrKw = [strongSelf resolveCommentFromHits:hits];
                if (ocrKw.length) {
                    // A super-bag comment captured earlier from the card wins over
                    // whatever OCR re-derives here.
                    NSString *toSend = (strongSelf.superBagComment.length > 0)
                                       ? strongSelf.superBagComment : ocrKw;
                    DYLog(@"captured comment via OCR: '%@' (superBag active=%d)", ocrKw, strongSelf.superBagActive);
                    [strongSelf fillAndSend:toSend
                                      input:liveInput
                                   prefill:[strongSelf textOfInput:liveInput.view]
                                   attempt:attempt];
                } else {
                    [strongSelf dumpCommentSheet];
                    [strongSelf updateStatus:@"未捕获口令/评论，无法发评论"];
                }
                } @catch (NSException *exception) {
                    DYLog(@"attemptCommentSend OCR: caught exception (%@): %@",
                          exception.name, exception.reason);
                    [strongSelf updateStatus:@"评论发送异常，已跳过"];
                }
            }];
            return;   // wait for OCR completion before deciding
        }

        [strongSelf fillAndSend:comment input:input prefill:prefill attempt:attempt];
        } @catch (NSException *exception) {
            DYLog(@"attemptCommentSend: caught exception (%@): %@", exception.name, exception.reason);
            [strongSelf updateStatus:@"评论发送异常，已跳过"];
        }
    });
}

/// Shared fill-and-send tail for the comment flow. Used both when the 口令 is
/// resolved from the view tree / prefill and when it is recovered via OCR.
- (void)fillAndSend:(NSString *)comment
              input:(DYViewHit *)input
           prefill:(NSString *)prefill
           attempt:(NSInteger)attempt {
    UIView *inputView = input.view;
    // The comment sheet is animated/popped by Douyin; if the field we captured
    // is no longer attached to a live window, acting on a torn-down control can
    // crash the host. Skip honestly instead of touching a stale view.
    // (Douyin often presents the sheet in its own window, so we test the view's
    // own window rather than comparing against the front window — the latter
    // would false-skip a send whose control lives in a non-key window.)
    if (!inputView || inputView.window == nil) {
        DYLog(@"fillAndSend: comment input no longer on screen — skipping");
        [self updateStatus:@"评论框已消失，参与未完成"];
        return;
    }

    @try {
        // Only overwrite the box when it is empty; a prefilled 口令 must be kept.
        if (prefill.length == 0) {
            [self fillInput:inputView withText:comment];
        } else {
            DYLog(@"comment box prefilled with '%@' — sending as-is", prefill);
        }

        DYViewHit *send = [DYViewDetector firstControlWithTextContainingAny:@[ @"发送", @"发表", @"发布" ]];
        if (!send) {
            if (attempt < kCommentMaxAttempts) {
                DYLog(@"comment send: 发送 button not ready (attempt %ld), retrying", (long)attempt);
                [self attemptCommentSend:comment attempt:attempt + 1];
                return;
            }
            DYLog(@"comment send: no 发送/发表/发布 button found");
            [self updateStatus:@"发送按钮未找到，参与未完成"];
            return;
        }

        UIView *sendView = send.view;
        if (sendView.window == nil) {
            DYLog(@"fillAndSend: 发送 button no longer on screen — skipping");
            [self updateStatus:@"发送按钮已消失，参与未完成"];
            return;
        }

        BOOL ok = [[DYTouch shared] tapView:sendView];
        if (ok) {
            DYLog(@"comment sent: '%@'", comment);
            [[DYConfig shared] incrementJoinCount];
            [[DYConfig shared] synchronize];
            [self updateStatus:[NSString stringWithFormat:@"已发评论：%@", comment]];
            [self verifyCommentSent];
        } else {
            DYLog(@"comment send: tap on 发送 failed");
            [self updateStatus:@"发送点击失败"];
            // Tap failed — incomplete, do not count.
        }
    } @catch (NSException *exception) {
        DYLog(@"fillAndSend: caught exception (%@): %@", exception.name, exception.reason);
        [self updateStatus:@"评论发送异常，已跳过"];
        // An exception means the send did not complete — do not inflate the counter.
    }
}

/// OCR fallback for the 超级福袋 one-tap button. A TRUE 超级福袋 (isTrueSuperBag)
/// whose 一键发表评论 is rendered as a Lynx bitmap has no view-tree text node, so
/// -firstViewWithTextContaining: finds nothing. OCR reads pixels, so it still sees
/// it; tap the recognised rect. Only ever called for true super bags (the caller
/// checks isTrueSuperBag), so there is NO plain-bag input fallback here — a true
/// super bag has no comment box. ocrBusy guards against re-entrant async calls.
- (void)tapOneClickCommentByOCR:(NSString *)keyword attempt:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits, NSError *error) {
        // This completion runs on a LATER call stack than the @try in
        // -attemptCommentSend:, so it is NOT under that guard. Guard it here.
        @try {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }
        strongSelf.ocrBusy = NO;   // released; a later attempt may re-trigger OCR
        DYTextHit *btn = nil;
        for (NSString *kw in @[ kWordOneClickComment, @"一键发送", @"一键评论" ]) {
            btn = [hits dy_firstHitContaining:kw];
            if (btn) {
                break;
            }
        }
        if (btn) {
            DYLog(@"super bag: tapping '%@' via OCR at (%.0f,%.0f) (comment='%@')",
                  btn.text, CGRectGetMidX(btn.rect), CGRectGetMidY(btn.rect),
                  strongSelf.superBagComment ?: @"(posted by Douyin)");
            [[DYTouch shared] tapInRect:btn.rect];
            [strongSelf finishOneClickComment];
            return;
        }
        if (error) {
            DYLog(@"super bag: OCR failed for the one-tap button (%@)",
                  error.localizedDescription);
        } else {
            DYLog(@"super bag: '%@' not found by OCR either (attempt %ld)",
                  kWordOneClickComment, (long)attempt);
        }
        // Button not visible yet (panel animating in) or OCR missed it. A true
        // super bag has no comment box, so the only way forward is to retry the
        // whole attempt — which re-enters -attemptCommentSend: and may OCR again.
        if (attempt < kCommentMaxAttempts) {
            [strongSelf attemptCommentSend:keyword attempt:attempt + 1];
            return;
        }
        // Out of attempts and the one-tap button never appeared.
        DYLog(@"comment flow: 超级福袋 - 一键发表评论 never appeared (view tree nor "
              @"OCR) after %ld attempts — joined WITHOUT the comment",
              (long)kCommentMaxAttempts);
        [[DYConfig shared] incrementJoinCount];
        [[DYConfig shared] synchronize];
        [strongSelf updateStatus:@"已参与（超级福袋评论未发出）"];
        [strongSelf verifyTapAtPoint:strongSelf.lastTapPoint];
        } @catch (NSException *exception) {
            DYLog(@"tapOneClickCommentByOCR: caught exception (%@): %@",
                  exception.name, exception.reason);
        }
    }];
}

/// Shared tail for both one-tap paths (view-tree tap and OCR tap): count the
/// join, report, and verify. The caller has already logged where it tapped.
- (void)finishOneClickComment {
    self.lastCommentWasOneClick = YES;
    [[DYConfig shared] incrementJoinCount];
    [[DYConfig shared] synchronize];
    // NOTE: no square brackets around this ternary — [a ? b : c] would parse as a
    // message send, not as grouping ("expected identifier").
    NSString *status = self.superBagComment.length > 0
        ? [NSString stringWithFormat:@"超级福袋：已一键发表评论 %@", self.superBagComment]
        : @"超级福袋：已一键发表评论";
    [self updateStatus:status];
    [self verifyCommentSent];
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

/// Extracts the fixed comment a 超级福袋 prints on its card, e.g.
/// "发送评论：华为暑促季，用"新"享一夏" -> "华为暑促季，用"新"享一夏". Returns nil
/// if `text` does not contain a 发送评论 / 评论： marker.
- (NSString *)specifiedCommentFromText:(NSString *)text {
    if (text.length == 0) {
        return nil;
    }
    NSArray<NSString *> *markers = @[ @"发送评论：", @"发送评论:", @"评论：", @"评论:" ];
    for (NSString *marker in markers) {
        NSRange r = [text rangeOfString:marker];
        if (r.location != NSNotFound) {
            NSString *tail = [text substringFromIndex:NSMaxRange(r)];
            tail = [tail stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // Super-bag comments can be long (may include quoted phrases like "新").
            if (tail.length > 0 && tail.length <= 60) {
                return tail;
            }
        }
    }
    return nil;
}

/// Captures a 超级福袋's fixed comment from the OCR hits (the card text).
- (NSString *)captureSpecifiedCommentFromHits:(NSArray<DYTextHit *> *)hits {
    if (![DYConfig shared].commentKeywordAutoSend) {
        return nil;
    }
    for (DYTextHit *h in hits) {
        NSString *c = [self specifiedCommentFromText:h.text];
        if (c.length) {
            return c;
        }
    }
    return nil;
}

/// Captures a 超级福袋's fixed comment from the live view tree (revealed once the
/// 参与 sheet is open). Returns nil if no 发送评论 marker is currently visible.
- (NSString *)captureSpecifiedCommentFromSheet {
    NSArray<DYViewHit *> *hits =
        [DYViewDetector findViewsWithTextContaining:@[ kWordSendComment, @"评论：" ]];
    for (DYViewHit *hit in hits) {
        NSString *c = [self specifiedCommentFromText:hit.text];
        if (c.length) {
            return c;
        }
    }
    return nil;
}

/// Resolves the comment to post from OCR hits: a 口令 first, otherwise (for a
/// 超级福袋) the card-specified comment. Used by the OCR fallback inside the comment
/// flow when the view tree + prefill found nothing.
- (NSString *)resolveCommentFromHits:(NSArray<DYTextHit *> *)hits {
    for (DYTextHit *h in hits) {
        if ([h.text rangeOfString:kWordKeyword].location != NSNotFound) {
            NSString *kw = [self keywordFromText:h.text];
            if (kw.length) {
                return kw;
            }
        }
    }
    for (DYTextHit *h in hits) {
        NSString *c = [self specifiedCommentFromText:h.text];
        if (c.length) {
            return c;
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

/// Taps a 关注 / 加入粉丝团 gate when present and the user opted in. Some 口令
/// bags require joining the fan club (or following the host) before the comment
/// box will accept input; tapping the gate here lets the comment flow proceed.
/// The matching confirmation dialog ("确定加入粉丝团？") is handled separately in
/// -attemptCommentSend:, which defers the send until 确定/确认 is tapped.
- (void)handleFollowGate {
    if (![DYConfig shared].autoFollowForBags) {
        return;
    }
    // A 超级福袋 needs the *shopping* fan-club join (加入购物粉丝团), which is a
    // different control from the broadcaster's 关注 button. When a super bag is on
    // screen, prefer the fan-club gate so we don't tap the wrong one. Detect it
    // live from the view tree each call, because the card (and thus the marker)
    // may only be visible after 参与 opened the sheet.
    // Use the OCR+view-tree decision already made in -handleHits. A 超级福袋
    // recognised only by Vision (viewTree=0 for its markers) would be misjudged
    // as a plain bag here and we'd tap the broadcaster's header 关注 关注 instead
    // of the bag's own fan-club gate — see dyluckybag(17).log:
    // "follow gate: tapping '关注 关注'". self.superBagActive is re-detected every
    // scan and stays NO for a plain 评论福袋 whose 发送评论： is OCR-only, so this
    // does not regress plain bags (they still reach the 关注/加入粉丝团 branch).
    BOOL superBag = self.superBagActive;
    NSArray<NSString *> *primary;
    NSArray<NSString *> *secondary;
    if (superBag) {
        // 购物粉丝团 / 粉丝团 first. "粉丝团" subsumes both "加入粉丝团" and
        // "加入购物粉丝团" (the "购物" in the middle breaks the "加入粉丝团"
        // substring, so a bare "粉丝团" match is what actually catches the
        // shopping fan club).
        //
        // 关注 is deliberately REMOVED from the super-bag secondary list: on
        // device it matched the BROADCASTER's follow button up in the room header
        // ("关注 关注" at y≈69), which is not a bag task at all — tapping it did
        // nothing for the bag and burned a pass.
        primary   = @[ @"购物粉丝团", @"粉丝团" ];
        secondary = @[ @"立即加入" ];
    } else {
        primary   = @[ @"关注", @"加入粉丝团", @"加入团", @"立即加入" ];
        secondary = @[ @"粉丝团" ];
    }
    DYViewHit *gate = [DYViewDetector firstControlWithTextContainingAny:primary];
    if (!gate) {
        gate = [DYViewDetector firstControlWithTextContainingAny:secondary];
    }
    if (!gate) {
        return;
    }
    NSString *label = gate.text ?: @"";
    if ([label containsString:@"已"]) {
        // Already following / already in the fan club (e.g. "已关注",
        // "已加入粉丝团") — nothing to tap, and re-tapping would be wrong.
        return;
    }
    // Debounce: -attemptCommentSend: runs up to 6 passes, and on device it tapped
    // the SAME gate every pass (7x '粉丝团'), endlessly re-popping the 购物粉丝团
    // panel — which covered the bag panel and made 一键发表评论 disappear, so the
    // comment could never be posted. One tap per gate per window.
    // 8s > one full retry cycle (6 attempts x 0.8s = 4.8s), so a gate is tapped
    // at most once per bag participation instead of once per pass.
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastGateLabel.length > 0 &&
        [label isEqualToString:self.lastGateLabel] &&
        (now - self.lastGateTapTime) < 8.0) {
        DYLog(@"follow gate: '%@' already tapped %.1fs ago — skipping",
              label, now - self.lastGateTapTime);
        return;
    }
    DYLog(@"follow gate: tapping '%@'%@", gate.text, superBag ? @" (super bag)" : @"");
    [[DYTouch shared] tapView:gate.view];
    self.lastGateLabel = label;
    self.lastGateTapTime = now;
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
        @try {
        if (strongSelf.lastCommentWasOneClick) {
            // A 超级福袋's own button contains 发表, so the generic check below
            // would report "still present" even on success. For this path, success
            // = 「一键发表评论」 is gone (the task row flips to (1/1)).
            strongSelf.lastCommentWasOneClick = NO;
            DYViewHit *inTree = [DYViewDetector
                                 firstViewWithTextContaining:kWordOneClickComment];
            if (inTree) {
                DYLog(@"comment verify: 一键发表评论 still present - send may not have landed");
                [strongSelf updateStatus:@"超级福袋评论可能未发出"];
                return;
            }
            // Lynx can render the button as a bitmap, in which case the view tree
            // never had a node for it — "absent from the tree" would then be a
            // false success. Confirm with OCR before declaring victory.
            [[DYOCRDetector shared] detectWithCompletion:^(NSArray<DYTextHit *> *hits,
                                                           NSError *err) {
                // Later call stack than the @try above — guard it here.
                @try {
                if (!strongSelf.running) {
                    return;
                }
                DYTextHit *ocr = [hits dy_firstHitContaining:kWordOneClickComment];
                if (ocr) {
                    DYLog(@"comment verify: 一键发表评论 still on screen per OCR - "
                          @"send may not have landed");
                    [strongSelf updateStatus:@"超级福袋评论可能未发出"];
                } else if (err) {
                    DYLog(@"comment verify: inconclusive - OCR failed (%@)",
                          err.localizedDescription);
                } else {
                    DYLog(@"comment verify: OK - 一键发表评论 gone (super bag comment posted)");
                }
                } @catch (NSException *exception) {
                    DYLog(@"verifyCommentSent OCR: caught exception (%@): %@",
                          exception.name, exception.reason);
                }
            }];
            return;
        }
        DYViewHit *send = [DYViewDetector firstControlWithTextContainingAny:@[ @"发送", @"发表", @"发布" ]];
        if (!send) {
            DYLog(@"comment verify: OK - 发送 button gone (comment posted)");
        } else {
            DYLog(@"comment verify: 发送 button still present - send may not have landed");
            [strongSelf updateStatus:@"评论可能未发出"];
        }
        } @catch (NSException *exception) {
            DYLog(@"verifyCommentSent: caught exception (%@): %@", exception.name, exception.reason);
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
