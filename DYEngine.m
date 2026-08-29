#import "DYEngine.h"
#import "DYConfig.h"
#import "DYOCRDetector.h"
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

@interface DYEngine ()
@property (nonatomic) NSTimer *timer;
@property (nonatomic) BOOL scanning;
@property (nonatomic, readwrite) DYEngineState state;
@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, copy, readwrite) NSString *lastStatus;
@property (nonatomic) CGPoint lastTapPoint;
@property (nonatomic) CFTimeInterval lastTapTime;
@property (nonatomic) NSString *lastKeyword;
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
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil
                                                 repeats:YES];
    // Common modes so scrolling the feed does not stall the timer.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

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
    if (hits.count == 0) {
        return;
    }

    // 1. A win banner outranks everything else — stop tapping and report it.
    DYTextHit *winHit = [hits dy_firstHitContaining:kWordCongrats];
    if (!winHit) {
        winHit = [hits dy_firstHitContaining:kWordWon];
    }
    if (winHit) {
        [self handleWin:winHit];
        return;
    }

    // 2. Is there a lucky bag on screen at all?
    DYTextHit *bagHit = [hits dy_firstHitContaining:kWordBag];
    if (!bagHit) {
        if (self.state != DYEngineStateIdle) {
            self.state = DYEngineStateIdle;
            [self updateStatus:@"当前直播间没有福袋"];
        }
        return;
    }

    DYLog(@"bag detected: '%@' at %@", bagHit.text, NSStringFromCGRect(bagHit.rect));

    // 3. Extract the keyword (口令) if the bag requires a comment to enter.
    [self captureKeywordFromHits:hits];

    // 4. Already joined? Then we are waiting for the draw, not tapping again.
    if ([hits dy_firstHitContaining:@"已参与"]) {
        self.state = DYEngineStateWaitingResult;
        [self updateStatus:@"已参与，等待开奖"];
        return;
    }

    // 5. Find the join button.
    DYTextHit *joinHit = [self joinButtonHitFromHits:hits];
    if (!joinHit) {
        self.state = DYEngineStateBagDetected;
        [self updateStatus:@"检测到福袋，未找到参与按钮"];
        return;
    }

    self.state = DYEngineStateBagDetected;

    // 6. Detect-only mode deliberately stops here — it is the safe way to
    // verify OCR is seeing the right thing before letting the tweak tap.
    if ([DYConfig shared].patrolMode == DYPatrolModeDetectOnly) {
        [self updateStatus:[NSString stringWithFormat:@"[仅检测] 发现参与按钮 '%@'", joinHit.text]];
        return;
    }

    // 7. Debounce: do not re-tap the same button inside the cooldown window.
    CGPoint center = CGPointMake(CGRectGetMidX(joinHit.rect), CGRectGetMidY(joinHit.rect));
    if ([self isDuplicateTapAtPoint:center]) {
        DYLog(@"tap skipped: same button as last time (cooldown %.0fs)", kTapCooldown);
        return;
    }

    // 8. Tap it.
    DYLog(@"tapping join button '%@' at %@", joinHit.text, NSStringFromCGPoint(center));
    BOOL dispatched = [[DYTouch shared] tapInRect:joinHit.rect];

    if (dispatched) {
        self.lastTapPoint = center;
        self.lastTapTime = CACurrentMediaTime();
        self.state = DYEngineStateJoined;
        [[DYConfig shared] incrementJoinCount];
        [[DYConfig shared] synchronize];
        [self updateStatus:@"已点击参与"];
        DYLog(@"join dispatched; today joins=%ld",
              (long)[DYConfig shared].todayJoinCount);
    } else {
        [self updateStatus:@"点击失败：未找到可响应的控件"];
    }
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onUpdate) {
            self.onUpdate(self.state, status);
        }
    });
}

@end
