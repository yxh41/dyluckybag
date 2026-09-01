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
static NSString *const kWordCongrats   = @"恭喜";
static NSString *const kWordWon        = @"中奖";

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
        DYTextHit *winHit = [hits dy_firstHitContaining:kWordCongrats];
        if (!winHit) {
            winHit = [hits dy_firstHitContaining:kWordWon];
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
        [[DYConfig shared] incrementJoinCount];
        [[DYConfig shared] synchronize];
        [self updateStatus:@"已点击参与"];
        DYLog(@"join dispatched; today joins=%ld",
              (long)[DYConfig shared].todayJoinCount);
        [self verifyTapAtPoint:center];
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

        // v0.1: log only. Sending the comment needs a reliable way to reach the
        // live room's input field, which is the next milestone.
        DYLog(@"keyword send not implemented yet in v0.1");
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
