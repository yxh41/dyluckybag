#import "DYPanel.h"
#import "DYConfig.h"
#import "DYEngine.h"
#import "DYLog.h"
#import <objc/runtime.h>

static const CGFloat kFloatSize = 56.0;
static const CGFloat kPanelHeight = 420.0;

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
    self.panelView.hidden = YES;
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
    CGFloat x = screen.size.width - kFloatSize - 12.0;
    CGFloat y = screen.size.height * 0.35;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(x, y, kFloatSize, kFloatSize);
    button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
    button.layer.cornerRadius = kFloatSize / 2.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    [button setTitle:@"福" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

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
    self.panelExpanded = !self.panelExpanded;
    self.panelView.hidden = !self.panelExpanded;
    if (self.panelExpanded) {
        [self refresh];
        [self.panelView.superview bringSubviewToFront:self.panelView];
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
    CGFloat width = screen.size.width - 24.0;
    CGFloat x = 12.0;
    CGFloat y = screen.size.height - kPanelHeight - 24.0;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, kPanelHeight)];
    panel.backgroundColor = [[UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.96] colorWithAlphaComponent:0.96];
    panel.layer.cornerRadius = 16.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    panel.hidden = YES;

    CGFloat cursor = 12.0;
    CGFloat innerWidth = width - 24.0;

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12.0, cursor, innerWidth, 26.0)];
    title.text = @"抖音福袋助手";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17.0];
    [panel addSubview:title];

    UIButton *collapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    collapseButton.frame = CGRectMake(width - 56.0, cursor, 44.0, 26.0);
    [collapseButton setTitle:@"收起" forState:UIControlStateNormal];
    [collapseButton setTitleColor:[UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0]
                         forState:UIControlStateNormal];
    collapseButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [collapseButton addTarget:self
                       action:@selector(collapse)
             forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:collapseButton];

    // Full hide (window removed). Unlike "收起", this also stops the floating
    // 福 button. Bring it back by sending Douyin to the background and
    // re-opening it (or restart the app).
    UIButton *hideButton = [UIButton buttonWithType:UIButtonTypeSystem];
    hideButton.frame = CGRectMake(width - 104.0, cursor, 44.0, 26.0);
    [hideButton setTitle:@"隐藏" forState:UIControlStateNormal];
    [hideButton setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0]
                     forState:UIControlStateNormal];
    hideButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [hideButton addTarget:self
                   action:@selector(hide)
         forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:hideButton];

    cursor += 32.0;

    // Status
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(12.0, cursor, innerWidth, 20.0)];
    status.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    status.font = [UIFont systemFontOfSize:13.0];
    status.text = @"—";
    [panel addSubview:status];
    self.statusLabel = status;

    cursor += 26.0;

    // Stats row
    CGFloat statWidth = innerWidth / 3.0;
    self.joinLabel = [self addStatAtX:12.0
                                    y:cursor
                                width:statWidth
                                title:@"今日参与"
                              toPanel:panel];
    self.winLabel = [self addStatAtX:12.0 + statWidth
                                   y:cursor
                               width:statWidth
                               title:@"今日中奖"
                             toPanel:panel];
    self.roomLabel = [self addStatAtX:12.0 + statWidth * 2.0
                                    y:cursor
                                width:statWidth
                                title:@"巡逻房间"
                              toPanel:panel];

    cursor += 52.0;

    // Master switch
    UISwitch *masterSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    masterSwitch.center = CGPointMake(width - 12.0 - masterSwitch.frame.size.width / 2.0,
                                      cursor + 15.0);
    masterSwitch.on = [DYConfig shared].masterEnabled;
    [masterSwitch addTarget:self
                     action:@selector(masterSwitchChanged:)
           forControlEvents:UIControlEventValueChanged];
    [panel addSubview:masterSwitch];

    UILabel *masterLabel = [[UILabel alloc]
        initWithFrame:CGRectMake(12.0, cursor, innerWidth - 60.0, 30.0)];
    masterLabel.text = @"总开关";
    masterLabel.textColor = [UIColor whiteColor];
    masterLabel.font = [UIFont systemFontOfSize:15.0];
    [panel addSubview:masterLabel];

    cursor += 40.0;

    // Patrol mode
    UILabel *modeLabel = [[UILabel alloc] initWithFrame:CGRectMake(12.0, cursor, innerWidth, 20.0)];
    modeLabel.text = @"巡逻模式";
    modeLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    modeLabel.font = [UIFont systemFontOfSize:13.0];
    [panel addSubview:modeLabel];

    cursor += 24.0;

    UISegmentedControl *segmented =
        [[UISegmentedControl alloc] initWithItems:@[ @"仅检测", @"自动参与", @"全自动巡逻" ]];
    segmented.frame = CGRectMake(12.0, cursor, innerWidth, 30.0);
    segmented.selectedSegmentIndex = (NSInteger)[DYConfig shared].patrolMode;
    segmented.tintColor = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
    [segmented addTarget:self
                  action:@selector(patrolModeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:segmented];

    cursor += 42.0;

    // Feature switches
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
                  title:(NSString *)title
                toPanel:(UIView *)panel {
    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(x, y, width, 16.0)];
    caption.text = title;
    caption.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    caption.font = [UIFont systemFontOfSize:11.0];
    caption.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:caption];

    UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(x, y + 18.0, width, 24.0)];
    value.text = @"0";
    value.textColor = [UIColor whiteColor];
    value.font = [UIFont boldSystemFontOfSize:18.0];
    value.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:value];

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
    toggle.transform = CGAffineTransformMakeScale(0.85, 0.85);
    CGFloat toggleWidth = toggle.frame.size.width;
    toggle.frame = CGRectMake(width - 12.0 - toggleWidth, y, toggleWidth, toggle.frame.size.height);

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
        initWithFrame:CGRectMake(12.0, y + 4.0, width - toggleWidth - 28.0, 24.0)];
    label.text = title;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14.0];
    [container addSubview:label];

    return y + 38.0;
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

    UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(16.0, -70.0, width, 56.0)];
    banner.text = [NSString stringWithFormat:@"🎉 %@", text];
    banner.textColor = [UIColor whiteColor];
    banner.backgroundColor = [[UIColor colorWithRed:0.98 green:0.20 blue:0.35 alpha:1.0] colorWithAlphaComponent:0.96];
    banner.font = [UIFont boldSystemFontOfSize:15.0];
    banner.textAlignment = NSTextAlignmentCenter;
    banner.numberOfLines = 0;
    banner.layer.cornerRadius = 12.0;
    banner.clipsToBounds = YES;
    banner.alpha = 0.0;

    [host addSubview:banner];

    CGFloat top = 60.0;
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
                banner.frame = CGRectMake(16.0, -70.0, width, 56.0);
            }
                             completion:^(BOOL done) {
                [banner removeFromSuperview];
            }];
        });
    }];
}

@end
