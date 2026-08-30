#import "DYPanel.h"
#import "DYConfig.h"
#import "DYEngine.h"
#import "DYLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kFloatSize = 60.0;
static const CGFloat kPanelHeight = 452.0;

// Festive palette: red -> deep red gradient with a gold rim.
#define DY_RED1  [UIColor colorWithRed:1.00 green:0.36 blue:0.36 alpha:1.0]
#define DY_RED2  [UIColor colorWithRed:0.85 green:0.12 blue:0.18 alpha:1.0]
#define DY_GOLD  [UIColor colorWithRed:1.00 green:0.84 blue:0.42 alpha:1.0]
#define DY_CARD  [UIColor colorWithWhite:1.0 alpha:0.08]
#define DY_SEP   [UIColor colorWithWhite:1.0 alpha:0.10]

@interface DYPanel ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, readwrite) BOOL visible;
@property (nonatomic) BOOL panelExpanded;

// Panel subviews we refresh in place.
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *joinLabel;
@property (nonatomic, strong) UILabel *winLabel;
@property (nonatomic, strong) UILabel *roomLabel;
@end

@interface DYPassThroughView : UIView
@end
@implementation DYPassThroughView
// Let touches fall through to Douyin's own views in the transparent areas, so
// the floating overlay never steals scroll / tap gestures from the feed or the
// video player. Only real subviews (the 福 button, the panel) stay interactive.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@implementation DYPanel

+ (instancetype)shared {
    static DYPanel *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DYPanel alloc] init];
    });
    return instance;
}

#pragma mark - Public

- (void)show {
    if (self.visible) {
        return;
    }
    [self buildIfNeeded];
    self.window.hidden = NO;
    self.visible = YES;
    DYLog(@"panel shown");
}

- (void)hide {
    self.window.hidden = YES;
    self.visible = NO;
    self.panelExpanded = NO;
    self.panelView.hidden = YES;
}

/// "收起": collapse the panel but keep the floating 福 button on screen, so the
/// user can bring the panel back with a single tap — no app restart needed.
- (void)collapse {
    self.panelExpanded = NO;
    [UIView animateWithDuration:0.22
                     animations:^{
        self.panelView.alpha = 0.0;
        CGRect f = self.panelView.frame;
        f.origin.y += 24.0;
        self.panelView.frame = f;
    }
                     completion:^(BOOL finished) {
        self.panelView.hidden = YES;
    }];
}

- (void)handleAppBecameActive {
    if (!self.visible) {
        [self show];
    }
}

- (void)toggle {
    if (self.visible) {
        [self hide];
    } else {
        [self show];
    }
}

- (void)showWinBanner:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentBannerWithText:text];
    });
}

- (void)refresh {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        DYConfig *config = [DYConfig shared];
        strongSelf.statusLabel.text = [DYEngine shared].lastStatus ?: @"—";
        strongSelf.joinLabel.text = @(config.todayJoinCount).stringValue;
        strongSelf.winLabel.text = @(config.todayWinCount).stringValue;
        strongSelf.roomLabel.text = @(config.todayRoomCount).stringValue;
    });
}

#pragma mark - Window

- (void)buildIfNeeded {
    if (self.window) {
        return;
    }

    CGRect screen = UIScreen.mainScreen.bounds;

    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene) {
            window = [[UIWindow alloc] initWithWindowScene:scene];
        }
    }
    if (!window) {
        window = [[UIWindow alloc] initWithFrame:screen];
    }

    window.frame = screen;
    // Above alert level so Douyin's own sheets never cover it, but below the
    // status bar so it does not look like a system overlay.
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = YES;

    UIViewController *root = [[UIViewController alloc] init];
    // A pass-through root view so the transparent overlay does not swallow
    // Douyin's gestures; only the floating button and panel are interactive.
    DYPassThroughView *rootView = [[DYPassThroughView alloc] initWithFrame:screen];
    rootView.backgroundColor = [UIColor clearColor];
    rootView.userInteractionEnabled = YES;
    root.view = rootView;
    window.rootViewController = root;

    self.window = window;

    [self buildFloatButtonInView:root.view];
    [self buildPanelInView:root.view];

    // The engine drives the status line; keep it in sync without polling.
    __weak typeof(self) weakSelf = self;
    [DYEngine shared].onUpdate = ^(DYEngineState state, NSString *status) {
        [weakSelf refresh];
    };

    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(handleWinNotification:)
     name:@"DYLuckyBagWinNotification"
     object:nil];

    // Re-surface the panel automatically when Douyin returns to the foreground,
    // so a full hide never requires restarting the app to bring it back.
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(handleAppBecameActive)
     name:UIApplicationDidBecomeActiveNotification
     object:nil];
}

// No availability attribute needed: the deployment target is iOS 15, so
// UIWindowScene and -initWithWindowScene: are always present.
- (UIWindowScene *)activeWindowScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

#pragma mark - Floating button

- (void)buildFloatButtonInView:(UIView *)superview {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat x = screen.size.width - kFloatSize - 14.0;
    CGFloat y = screen.size.height * 0.34;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(x, y, kFloatSize, kFloatSize);
    button.backgroundColor = [UIColor clearColor];
    button.layer.cornerRadius = kFloatSize / 2.0;

    // Festive red->deep-red gradient fill.
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = button.bounds;
    grad.cornerRadius = kFloatSize / 2.0;
    grad.colors = @[ (__bridge id)DY_RED1.CGColor, (__bridge id)DY_RED2.CGColor ];
    grad.startPoint = CGPointMake(0.0, 0.0);
    grad.endPoint = CGPointMake(1.0, 1.0);
    [button.layer insertSublayer:grad atIndex:0];

    // Gold rim + soft drop shadow for depth.
    button.layer.borderWidth = 2.0;
    button.layer.borderColor = DY_GOLD.CGColor;
    button.layer.shadowColor = [UIColor colorWithRed:0.8 green:0.1 blue:0.15 alpha:1.0].CGColor;
    button.layer.shadowOpacity = 0.5;
    button.layer.shadowRadius = 8.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 4.0);

    [button setTitle:@"福" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    [button setTitleColor:DY_GOLD forState:UIControlStateNormal];

    // Gentle attention pulse on the shadow.
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    pulse.fromValue = @(0.35);
    pulse.toValue = @(0.75);
    pulse.duration = 1.3;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [button.layer addAnimation:pulse forKey:@"dyPulse"];

    [button addTarget:self
               action:@selector(floatButtonTapped)
     forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [button addGestureRecognizer:pan];

    [superview addSubview:button];
    self.floatButton = button;
}

- (void)floatButtonTapped {
    // Springy tap feedback.
    [UIView animateWithDuration:0.12
                     animations:^{
        self.floatButton.transform = CGAffineTransformMakeScale(0.88, 0.88);
    }
                     completion:^(BOOL finished) {
        [UIView animateWithDuration:0.22
                              delay:0.0
             usingSpringWithDamping:0.5
              initialSpringVelocity:0.7
                            options:0
                         animations:^{
            self.floatButton.transform = CGAffineTransformIdentity;
        }
                         completion:nil];
    }];

    self.panelExpanded = !self.panelExpanded;
    if (self.panelExpanded) {
        self.panelView.hidden = NO;
        self.panelView.alpha = 0.0;
        CGRect f = self.panelView.frame;
        CGFloat finalY = f.origin.y;
        f.origin.y += 24.0;
        self.panelView.frame = f;
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.6
                            options:0
                         animations:^{
            self.panelView.alpha = 1.0;
            self.panelView.frame = CGRectMake(f.origin.x, finalY, f.size.width, f.size.height);
        }
                         completion:nil];
        [self refresh];
        [self.panelView.superview bringSubviewToFront:self.panelView];
    } else {
        [self collapse];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:pan.view.superview];
    CGPoint center = pan.view.center;
    center.x += translation.x;
    center.y += translation.y;

    // Keep the button fully on screen.
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat half = kFloatSize / 2.0;
    center.x = MIN(MAX(center.x, half), bounds.size.width - half);
    center.y = MIN(MAX(center.y, half), bounds.size.height - half);

    pan.view.center = center;
    [pan setTranslation:CGPointZero inView:pan.view.superview];
}

#pragma mark - Panel

- (void)buildPanelInView:(UIView *)superview {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat width = screen.size.width - 28.0;
    CGFloat x = 14.0;
    CGFloat y = screen.size.height - kPanelHeight - 24.0;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, kPanelHeight)];
    panel.backgroundColor = [UIColor clearColor];
    panel.layer.cornerRadius = 22.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    panel.layer.masksToBounds = YES;
    panel.hidden = YES;

    // Frosted dark gradient background.
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.frame = panel.bounds;
    bg.cornerRadius = 22.0;
    bg.colors = @[ (__bridge id)[UIColor colorWithRed:0.13 green:0.13 blue:0.17 alpha:0.97].CGColor,
                   (__bridge id)[UIColor colorWithRed:0.07 green:0.07 blue:0.11 alpha:0.98].CGColor ];
    bg.startPoint = CGPointMake(0.0, 0.0);
    bg.endPoint = CGPointMake(0.0, 1.0);
    [panel.layer insertSublayer:bg atIndex:0];

    CGFloat cursor = 16.0;
    CGFloat innerWidth = width - 28.0;

    // Header: title + small red badge dot + subtitle.
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(16.0, cursor + 5.0, 9.0, 9.0)];
    dot.backgroundColor = DY_RED1;
    dot.layer.cornerRadius = 4.5;
    [panel addSubview:dot];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(32.0, cursor, innerWidth - 100.0, 20.0)];
    title.text = @"抖音福袋助手";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17.0];
    [panel addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(32.0, cursor + 20.0, innerWidth - 100.0, 16.0)];
    subtitle.text = @"OCR 自动参与福袋";
    subtitle.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:11.0];
    [panel addSubview:subtitle];

    UIButton *collapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    collapseButton.frame = CGRectMake(width - 100.0, cursor, 44.0, 28.0);
    [collapseButton setTitle:@"收起" forState:UIControlStateNormal];
    [collapseButton setTitleColor:DY_GOLD forState:UIControlStateNormal];
    collapseButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [collapseButton addTarget:self
                       action:@selector(collapse)
             forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:collapseButton];

    UIButton *hideButton = [UIButton buttonWithType:UIButtonTypeSystem];
    hideButton.frame = CGRectMake(width - 54.0, cursor, 44.0, 28.0);
    [hideButton setTitle:@"隐藏" forState:UIControlStateNormal];
    [hideButton setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0]
                     forState:UIControlStateNormal];
    hideButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [hideButton addTarget:self
                   action:@selector(hide)
         forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:hideButton];

    cursor += 46.0;

    // Status pill.
    UIView *statusCard = [[UIView alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 40.0)];
    statusCard.backgroundColor = DY_CARD;
    statusCard.layer.cornerRadius = 12.0;
    [panel addSubview:statusCard];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(14.0, 0.0, innerWidth - 28.0, 40.0)];
    status.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    status.font = [UIFont systemFontOfSize:13.0];
    status.text = @"—";
    [statusCard addSubview:status];
    self.statusLabel = status;

    cursor += 52.0;

    // Stats: three cards in a row.
    CGFloat statWidth = (innerWidth - 16.0) / 3.0;
    self.joinLabel = [self addStatAtX:16.0
                                    y:cursor
                                width:statWidth
                              caption:@"今日参与"
                             toPanel:panel];
    self.winLabel = [self addStatAtX:16.0 + statWidth + 8.0
                                    y:cursor
                                width:statWidth
                              caption:@"今日中奖"
                             toPanel:panel];
    self.roomLabel = [self addStatAtX:16.0 + (statWidth + 8.0) * 2.0
                                     y:cursor
                                 width:statWidth
                               caption:@"巡逻房间"
                              toPanel:panel];

    cursor += 64.0;

    // Master switch row.
    UIView *masterRow = [[UIView alloc] initWithFrame:CGRectMake(0.0, cursor, width, 44.0)];
    [panel addSubview:masterRow];

    UILabel *masterLabel = [[UILabel alloc]
        initWithFrame:CGRectMake(16.0, 0.0, innerWidth - 70.0, 44.0)];
    masterLabel.text = @"总开关";
    masterLabel.textColor = [UIColor whiteColor];
    masterLabel.font = [UIFont systemFontOfSize:15.0];
    [masterRow addSubview:masterLabel];

    UISwitch *masterSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    masterSwitch.center = CGPointMake(width - 16.0 - masterSwitch.frame.size.width / 2.0,
                                      22.0);
    masterSwitch.onTintColor = DY_RED2;
    masterSwitch.on = [DYConfig shared].masterEnabled;
    [masterSwitch addTarget:self
                     action:@selector(masterSwitchChanged:)
           forControlEvents:UIControlEventValueChanged];
    [masterRow addSubview:masterSwitch];

    cursor += 44.0;

    // Section separator.
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 1.0)];
    sep1.backgroundColor = DY_SEP;
    [panel addSubview:sep1];
    cursor += 10.0;

    // Patrol mode label.
    UILabel *modeLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 18.0)];
    modeLabel.text = @"巡逻模式";
    modeLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    modeLabel.font = [UIFont systemFontOfSize:12.0];
    [panel addSubview:modeLabel];
    cursor += 24.0;

    UISegmentedControl *segmented =
        [[UISegmentedControl alloc] initWithItems:@[ @"仅检测", @"自动参与", @"全自动巡逻" ]];
    segmented.frame = CGRectMake(16.0, cursor, innerWidth, 32.0);
    segmented.selectedSegmentIndex = (NSInteger)[DYConfig shared].patrolMode;
    segmented.tintColor = DY_RED2;
    segmented.selectedSegmentTintColor = DY_RED2;
    [segmented setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor whiteColor] }
                             forState:UIControlStateSelected];
    [segmented addTarget:self
                  action:@selector(patrolModeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:segmented];
    cursor += 44.0;

    // Feature switches.
    cursor = [self addToggleWithTitle:@"超级福袋 · 自动参与"
                                    y:cursor
                               toView:panel
                              getter:@selector(superBagAutoJoin)
                              setter:@selector(setSuperBagAutoJoin:)];
    cursor = [self addToggleWithTitle:@"普通福袋 · 自动参与"
                                    y:cursor
                               toView:panel
                              getter:@selector(normalBagAutoJoin)
                              setter:@selector(setNormalBagAutoJoin:)];
    cursor = [self addToggleWithTitle:@"评论口令自动发送"
                                    y:cursor
                               toView:panel
                              getter:@selector(commentKeywordAutoSend)
                              setter:@selector(setCommentKeywordAutoSend:)];
    cursor = [self addToggleWithTitle:@"直播间自动巡逻"
                                    y:cursor
                               toView:panel
                              getter:@selector(autoPatrol)
                              setter:@selector(setAutoPatrol:)];
    cursor = [self addToggleWithTitle:@"中奖横幅提醒"
                                    y:cursor
                               toView:panel
                              getter:@selector(winBannerAlert)
                              setter:@selector(setWinBannerAlert:)];

    [superview addSubview:panel];
    self.panelView = panel;
}

- (UILabel *)addStatAtX:(CGFloat)x
                      y:(CGFloat)y
                  width:(CGFloat)width
               caption:(NSString *)caption
               toPanel:(UIView *)panel {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, 52.0)];
    card.backgroundColor = DY_CARD;
    card.layer.cornerRadius = 14.0;
    [panel addSubview:card];

    UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 8.0, width, 14.0)];
    cap.text = caption;
    cap.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    cap.font = [UIFont systemFontOfSize:10.0];
    cap.textAlignment = NSTextAlignmentCenter;
    [card addSubview:cap];

    UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 22.0, width, 24.0)];
    value.text = @"0";
    value.textColor = DY_GOLD;
    value.font = [UIFont boldSystemFontOfSize:19.0];
    value.textAlignment = NSTextAlignmentCenter;
    [card addSubview:value];

    return value;
}

/// Adds one labelled switch row and returns the y coordinate below it.
- (CGFloat)addToggleWithTitle:(NSString *)title
                            y:(CGFloat)y
                       toView:(UIView *)container
                       getter:(SEL)getter
                       setter:(SEL)setter {
    CGFloat width = container.frame.size.width;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = DY_RED2;
    CGFloat toggleWidth = toggle.frame.size.width;
    toggle.frame = CGRectMake(width - 16.0 - toggleWidth, y + 6.0, toggleWidth, toggle.frame.size.height);

    NSMethodSignature *signature = [DYConfig instanceMethodSignatureForSelector:getter];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = getter;
    invocation.target = [DYConfig shared];
    [invocation invoke];
    BOOL current = NO;
    [invocation getReturnValue:&current];
    toggle.on = current;

    // Associate the setter so one action method can serve every row.
    objc_setAssociatedObject(toggle, @selector(handleToggle:),
                             NSStringFromSelector(setter),
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(handleToggle:)
     forControlEvents:UIControlEventValueChanged];

    [container addSubview:toggle];

    UILabel *label = [[UILabel alloc]
        initWithFrame:CGRectMake(16.0, y + 6.0, width - toggleWidth - 36.0, 28.0)];
    label.text = title;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14.0];
    [container addSubview:label];

    return y + 44.0;
}

#pragma mark - Actions

- (void)masterSwitchChanged:(UISwitch *)sender {
    [DYConfig shared].masterEnabled = sender.on;
    [[DYConfig shared] synchronize];
    DYLog(@"master switch -> %@", sender.on ? @"ON" : @"OFF");
}

- (void)patrolModeChanged:(UISegmentedControl *)sender {
    DYPatrolMode mode = (DYPatrolMode)sender.selectedSegmentIndex;
    [DYConfig shared].patrolMode = mode;
    [[DYConfig shared] synchronize];
    DYLog(@"patrol mode -> %ld", (long)mode);
}

- (void)handleToggle:(UISwitch *)sender {
    NSString *setterName = objc_getAssociatedObject(sender, @selector(handleToggle:));
    if (setterName.length == 0) {
        return;
    }
    SEL setter = NSSelectorFromString(setterName);
    DYConfig *config = [DYConfig shared];
    if (![config respondsToSelector:setter]) {
        return;
    }

    // NSInvocation rather than performSelector:withObject: — the latter boxes
    // the BOOL into an NSNumber, but a BOOL setter reads the raw argument
    // register, so it would see the pointer's low byte and treat every OFF
    // as ON. NSInvocation passes the scalar by value.
    NSMethodSignature *signature = [DYConfig instanceMethodSignatureForSelector:setter];
    if (!signature) {
        DYLog(@"toggle %@: no method signature", setterName);
        return;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = setter;
    invocation.target = config;
    BOOL value = sender.on;
    [invocation setArgument:&value atIndex:2];
    [invocation invoke];

    [config synchronize];
    DYLog(@"toggle %@ -> %@", setterName, sender.on ? @"ON" : @"OFF");
}

- (void)handleWinNotification:(NSNotification *)note {
    NSString *text = note.userInfo[@"text"];
    [self showWinBanner:text.length ? text : @"中奖了！"];
}

#pragma mark - Banner

- (void)presentBannerWithText:(NSString *)text {
    if (!self.window) {
        return;
    }

    UIView *host = self.window.rootViewController.view;
    CGFloat width = UIScreen.mainScreen.bounds.size.width - 32.0;

    UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(16.0, -80.0, width, 56.0)];
    banner.text = [NSString stringWithFormat:@"🎉 %@", text];
    banner.textColor = [UIColor whiteColor];
    banner.font = [UIFont boldSystemFontOfSize:15.0];
    banner.textAlignment = NSTextAlignmentCenter;
    banner.numberOfLines = 0;
    banner.layer.cornerRadius = 14.0;
    banner.clipsToBounds = YES;
    banner.alpha = 0.0;

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = banner.bounds;
    g.cornerRadius = 14.0;
    g.colors = @[ (__bridge id)[UIColor colorWithRed:0.98 green:0.30 blue:0.42 alpha:1.0].CGColor,
                   (__bridge id)[UIColor colorWithRed:0.86 green:0.13 blue:0.18 alpha:1.0].CGColor ];
    [banner.layer insertSublayer:g atIndex:0];

    [host addSubview:banner];

    CGFloat top = 64.0;
    [UIView animateWithDuration:0.32
                     animations:^{
        banner.alpha = 1.0;
        banner.frame = CGRectMake(16.0, top, width, 56.0);
    }
                     completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.28
                             animations:^{
                banner.alpha = 0.0;
                banner.frame = CGRectMake(16.0, -80.0, width, 56.0);
            }
                             completion:^(BOOL done) {
                [banner removeFromSuperview];
            }];
        });
    }];
}

@end
