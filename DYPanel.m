#import "DYPanel.h"
#import "DYConfig.h"
#import "DYEngine.h"
#import "DYLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat kFloatSize   = 44.0;
static const CGFloat kPanelMargin = 14.0;
static const CGFloat kGrabberH    = 22.0;   // drag handle strip
static const CGFloat kHeaderH     = 46.0;   // title + 收起 / 隐藏
static const CGFloat kCorner      = 22.0;
static const CGFloat kRowH        = 44.0;

// Festive palette: red -> deep red gradient with a gold rim.
#define DY_RED1  [UIColor colorWithRed:1.00 green:0.36 blue:0.36 alpha:1.0]
#define DY_RED2  [UIColor colorWithRed:0.85 green:0.12 blue:0.18 alpha:1.0]
#define DY_GOLD  [UIColor colorWithRed:1.00 green:0.84 blue:0.42 alpha:1.0]
#define DY_CARD  [UIColor colorWithWhite:1.0 alpha:0.08]
#define DY_SEP   [UIColor colorWithWhite:1.0 alpha:0.10]

@interface DYPanel () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UIButton *hideButton;
@property (nonatomic, readwrite) BOOL visible;
@property (nonatomic) BOOL panelExpanded;

// Panel subviews we refresh in place.
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *joinLabel;
@property (nonatomic, strong) UILabel *winLabel;
@property (nonatomic, strong) UILabel *roomLabel;

// Private layout helpers, declared up front so -Werror never trips on a
// forward reference inside the @implementation.
- (UIWindowScene *)activeWindowScene;
- (UIEdgeInsets)hostSafeAreaInsets;
- (void)clampOverlayToScreen;
- (CGPoint)clampPanelCenter:(CGPoint)center;
- (CGFloat)buildPanelContentInView:(UIView *)content width:(CGFloat)width;
- (UILabel *)addStatAtX:(CGFloat)x
                      y:(CGFloat)y
                  width:(CGFloat)width
               caption:(NSString *)caption
               toPanel:(UIView *)panel;
- (CGFloat)addToggleWithTitle:(NSString *)title
                            y:(CGFloat)y
                       toView:(UIView *)container
                       getter:(SEL)getter
                       setter:(SEL)setter;
- (void)handlePanelPan:(UIPanGestureRecognizer *)pan;
- (void)installHostGesture;
- (void)handleHostLongPress:(UILongPressGestureRecognizer *)recognizer;
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

#pragma mark - Overlay window

// THE reason the overlay still blocked Douyin: a root view that returns nil from
// hitTest: is not enough. UIView's hitTest: walks its subviews and, when none of
// them claims the point, **falls back to returning self**. Applied to a window,
// that means the UIWindow itself became the hit view for every transparent pixel
// and swallowed the touch — the pass-through root view never got a say.
//
// Overriding hitTest: on the window itself is what actually releases those
// touches: returning nil here makes UIKit deliver them to the host app's own
// window underneath, so scrolling / tapping / the video player keep working.
@interface DYOverlayWindow : UIWindow
@end

@implementation DYOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;   // transparent area -> let Douyin handle it
    }
    return hit;       // the 福 button, the panel or one of its controls
}
@end

// Marker subclass so we can de-duplicate the re-show gesture we attach to the
// host app's window (see -installHostGesture).
@interface DYReshowLongPress : UILongPressGestureRecognizer
@end
@implementation DYReshowLongPress
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
    [self clampOverlayToScreen];
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
    if (!self.panelView || self.panelView.hidden) {
        self.panelExpanded = NO;
        return;
    }
    self.panelExpanded = NO;

    CGRect resting = self.panelView.frame;
    [UIView animateWithDuration:0.22
                     animations:^{
        self.panelView.alpha = 0.0;
        CGRect f = resting;
        f.origin.y += 24.0;
        self.panelView.frame = f;
    }
                     completion:^(BOOL finished) {
        self.panelView.hidden = YES;
        self.panelView.alpha = 1.0;
        // Restore the resting frame: the slide-down is only an animation, so
        // repeated collapses must not walk the panel off the bottom of the screen.
        self.panelView.frame = resting;
    }];
}

- (void)handleAppBecameActive {
    // The host app's window can be recreated across launches; make sure the
    // re-show gesture is attached to the live window.
    [self installHostGesture];
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

    DYOverlayWindow *window = nil;
    UIWindowScene *scene = [self activeWindowScene];
    if (scene) {
        window = [[DYOverlayWindow alloc] initWithWindowScene:scene];
    }
    if (!window) {
        window = [[DYOverlayWindow alloc] initWithFrame:screen];
    }

    window.frame = screen;
    // Above alert level so Douyin's own sheets never cover it.
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = YES;

    UIViewController *root = [[UIViewController alloc] init];
    DYPassThroughView *rootView = [[DYPassThroughView alloc] initWithFrame:screen];
    rootView.backgroundColor = [UIColor clearColor];
    rootView.userInteractionEnabled = YES;
    root.view = rootView;
    window.rootViewController = root;

    self.window = window;

    [self buildFloatButtonInView:root.view];
    [self buildPanelInView:root.view];

    // Attach the host-side re-show gesture (three-finger long press) so a fully
    // hidden overlay can still be brought back without leaving the app.
    [self installHostGesture];

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

    // Keep the button and the panel inside the visible area after a rotation.
    // Orientation notifications are opt-in: without this call the observer below
    // would simply never fire.
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(clampOverlayToScreen)
     name:UIDeviceOrientationDidChangeNotification
     object:nil];
}

- (UIWindowScene *)activeWindowScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

/// Safe area of the host app's own window — used to keep the panel clear of the
/// notch / home indicator instead of guessing with hardcoded insets.
- (UIEdgeInsets)hostSafeAreaInsets {
    UIWindowScene *scene = [self activeWindowScene];
    for (UIWindow *candidate in scene.windows) {
        if (candidate.isKeyWindow) {
            return candidate.safeAreaInsets;
        }
    }
    return UIEdgeInsetsZero;
}

/// Attaches a three-finger long press to Douyin's own window. Once the overlay
/// is fully hidden there is no on-screen control left to bring it back, and the
/// only other way out was backgrounding the app. The recogniser is deliberately
/// passive: cancelsTouchesInView = NO means it never eats a touch, so the host
/// app's own gestures keep working exactly as before.
- (void)installHostGesture {
    UIWindowScene *scene = [self activeWindowScene];
    if (!scene) {
        return;
    }

    for (UIWindow *window in scene.windows) {
        // Skip our own overlay: the gesture belongs on the app underneath.
        if (window == self.window || window.windowLevel >= UIWindowLevelAlert) {
            continue;
        }

        // De-duplicate: buildIfNeeded and handleAppBecameActive both call in,
        // and stacking recognisers would fire the handler N times per press.
        // Copy before iterating: removing while enumerating a collection the
        // view may still own is a mutation-during-enumeration crash waiting to
        // happen inside somebody else's process.
        for (UIGestureRecognizer *existing in [window.gestureRecognizers copy]) {
            if ([existing isKindOfClass:DYReshowLongPress.class]) {
                [window removeGestureRecognizer:existing];
            }
        }

        DYReshowLongPress *press =
            [[DYReshowLongPress alloc] initWithTarget:self
                                              action:@selector(handleHostLongPress:)];
        press.numberOfTouchesRequired = 3;
        press.minimumPressDuration = 0.6;
        press.cancelsTouchesInView = NO;
        press.delaysTouchesEnded = NO;
        [window addGestureRecognizer:press];
    }
}

- (void)handleHostLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (self.visible) {
        return;
    }
    DYLog(@"host three-finger press -> re-show overlay");
    [self show];
}

/// Keeps both overlay elements fully on screen (called on show and on rotation).
- (void)clampOverlayToScreen {
    if (!self.window) {
        return;
    }

    CGRect bounds = UIScreen.mainScreen.bounds;
    UIEdgeInsets insets = [self hostSafeAreaInsets];

    self.window.frame = bounds;
    self.window.rootViewController.view.frame = bounds;

    if (self.floatButton) {
        CGPoint center = self.floatButton.center;
        CGFloat half = kFloatSize / 2.0;
        center.x = MIN(MAX(center.x, half + 4.0), bounds.size.width - half - 4.0);
        center.y = MIN(MAX(center.y, insets.top + half), bounds.size.height - insets.bottom - half);
        self.floatButton.center = center;
    }

    if (self.panelView && !self.panelView.hidden) {
        self.panelView.center = [self clampPanelCenter:self.panelView.center];
    }
}

- (CGPoint)clampPanelCenter:(CGPoint)center {
    CGRect bounds = UIScreen.mainScreen.bounds;
    UIEdgeInsets insets = [self hostSafeAreaInsets];
    CGSize size = self.panelView.bounds.size;

    CGFloat minX = kPanelMargin + size.width / 2.0;
    CGFloat maxX = bounds.size.width - kPanelMargin - size.width / 2.0;
    CGFloat minY = insets.top + 12.0 + size.height / 2.0;
    CGFloat maxY = bounds.size.height - insets.bottom - 12.0 - size.height / 2.0;
    // On very small screens the panel can be taller than the usable area; keep
    // its top edge reachable rather than letting the clamp invert.
    if (minY > maxY) {
        minY = maxY;
    }

    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    return center;
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
    button.titleLabel.font = [UIFont boldSystemFontOfSize:kFloatSize * 0.5];
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
        CGRect resting = self.panelView.frame;
        CGRect from = resting;
        from.origin.y += 24.0;
        self.panelView.frame = from;
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.6
                            options:0
                         animations:^{
            self.panelView.alpha = 1.0;
            self.panelView.frame = resting;
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
    UIEdgeInsets insets = [self hostSafeAreaInsets];
    CGFloat half = kFloatSize / 2.0;
    center.x = MIN(MAX(center.x, half + 4.0), bounds.size.width - half - 4.0);
    center.y = MIN(MAX(center.y, insets.top + half), bounds.size.height - insets.bottom - half);

    pan.view.center = center;
    [pan setTranslation:CGPointZero inView:pan.view.superview];
}

#pragma mark - Panel

- (void)buildPanelInView:(UIView *)superview {
    CGRect screen = UIScreen.mainScreen.bounds;
    UIEdgeInsets insets = [self hostSafeAreaInsets];

    CGFloat width = screen.size.width - kPanelMargin * 2.0;
    CGFloat chromeH = kGrabberH + kHeaderH;
    CGFloat topLimit = insets.top + 12.0;
    CGFloat bottomLimit = screen.size.height - insets.bottom - 12.0;

    // Build the scrolling content first so the panel can size itself to it
    // instead of clipping whatever does not fit (the old fixed 452pt frame cut
    // off the last two switches).
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 0.0)];
    CGFloat contentH = [self buildPanelContentInView:content width:width];
    content.frame = CGRectMake(0.0, 0.0, width, contentH);

    CGFloat maxScrollH = MAX(140.0, (bottomLimit - topLimit) - chromeH);
    CGFloat scrollH = MIN(contentH, maxScrollH);
    CGFloat height = chromeH + scrollH;
    CGFloat y = bottomLimit - height;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(kPanelMargin, y, width, height)];
    panel.backgroundColor = [UIColor clearColor];
    panel.layer.cornerRadius = kCorner;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    panel.layer.masksToBounds = YES;
    panel.hidden = YES;

    // Frosted dark gradient background.
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.frame = panel.bounds;
    bg.cornerRadius = kCorner;
    bg.colors = @[ (__bridge id)[UIColor colorWithRed:0.13 green:0.13 blue:0.17 alpha:0.97].CGColor,
                   (__bridge id)[UIColor colorWithRed:0.07 green:0.07 blue:0.11 alpha:0.98].CGColor ];
    bg.startPoint = CGPointMake(0.0, 0.0);
    bg.endPoint = CGPointMake(0.0, 1.0);
    [panel.layer insertSublayer:bg atIndex:0];

    // Drag handle: a grabber pill that signals "this panel moves".
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, kGrabberH)];
    grabber.backgroundColor = [UIColor clearColor];
    [panel addSubview:grabber];

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(width / 2.0 - 20.0, 7.0, 40.0, 4.0)];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    pill.layer.cornerRadius = 2.0;
    [grabber addSubview:pill];

    // Header stays pinned above the scroll view so 收起 / 隐藏 are always reachable.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0.0, kGrabberH, width, kHeaderH)];
    header.backgroundColor = [UIColor clearColor];
    [panel addSubview:header];

    CGFloat innerWidth = width - 28.0;

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(16.0, 7.0, 9.0, 9.0)];
    dot.backgroundColor = DY_RED1;
    dot.layer.cornerRadius = 4.5;
    [header addSubview:dot];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(32.0, 2.0, innerWidth - 120.0, 20.0)];
    title.text = @"抖音福袋助手";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:17.0];
    [header addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(32.0, 21.0, innerWidth - 120.0, 16.0)];
    subtitle.text = @"OCR 自动参与福袋";
    subtitle.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:11.0];
    [header addSubview:subtitle];

    UIButton *collapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    collapseButton.frame = CGRectMake(width - 104.0, 7.0, 46.0, 30.0);
    [collapseButton setTitle:@"收起" forState:UIControlStateNormal];
    [collapseButton setTitleColor:DY_GOLD forState:UIControlStateNormal];
    collapseButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [collapseButton addTarget:self
                       action:@selector(collapse)
             forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:collapseButton];
    self.collapseButton = collapseButton;

    UIButton *hideButton = [UIButton buttonWithType:UIButtonTypeSystem];
    hideButton.frame = CGRectMake(width - 56.0, 7.0, 46.0, 30.0);
    [hideButton setTitle:@"隐藏" forState:UIControlStateNormal];
    [hideButton setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0]
                     forState:UIControlStateNormal];
    hideButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [hideButton addTarget:self
                   action:@selector(hide)
         forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:hideButton];
    self.hideButton = hideButton;

    UIView *headerLine = [[UIView alloc] initWithFrame:CGRectMake(0.0, chromeH - 1.0, width, 1.0)];
    headerLine.backgroundColor = DY_SEP;
    [panel addSubview:headerLine];

    UIScrollView *scroll =
        [[UIScrollView alloc] initWithFrame:CGRectMake(0.0, chromeH, width, scrollH)];
    scroll.contentSize = CGSizeMake(width, contentH);
    scroll.backgroundColor = [UIColor clearColor];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    scroll.alwaysBounceVertical = NO;
    [scroll addSubview:content];
    [panel addSubview:scroll];
    self.scrollView = scroll;

    // Drag the panel by its grabber / header only, so the switches, the
    // segmented control and the scroll view keep their own gestures.
    UIPanGestureRecognizer *panelPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    panelPan.delegate = self;
    [panel addGestureRecognizer:panelPan];

    [superview addSubview:panel];
    self.panelView = panel;
}

/// Lays out the scrollable body of the panel and returns its full height.
- (CGFloat)buildPanelContentInView:(UIView *)content width:(CGFloat)width {
    CGFloat innerWidth = width - 28.0;
    CGFloat cursor = 6.0;

    // Status pill.
    UIView *statusCard = [[UIView alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 40.0)];
    statusCard.backgroundColor = DY_CARD;
    statusCard.layer.cornerRadius = 12.0;
    [content addSubview:statusCard];

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
                             toPanel:content];
    self.winLabel = [self addStatAtX:16.0 + statWidth + 8.0
                                    y:cursor
                                width:statWidth
                              caption:@"今日中奖"
                             toPanel:content];
    self.roomLabel = [self addStatAtX:16.0 + (statWidth + 8.0) * 2.0
                                     y:cursor
                                 width:statWidth
                               caption:@"巡逻房间"
                              toPanel:content];

    cursor += 64.0;

    // Master switch row.
    UIView *masterRow = [[UIView alloc] initWithFrame:CGRectMake(0.0, cursor, width, kRowH)];
    [content addSubview:masterRow];

    UILabel *masterLabel = [[UILabel alloc]
        initWithFrame:CGRectMake(16.0, 0.0, innerWidth - 70.0, kRowH)];
    masterLabel.text = @"总开关";
    masterLabel.textColor = [UIColor whiteColor];
    masterLabel.font = [UIFont systemFontOfSize:15.0];
    [masterRow addSubview:masterLabel];

    UISwitch *masterSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    masterSwitch.center = CGPointMake(width - 16.0 - masterSwitch.frame.size.width / 2.0,
                                      kRowH / 2.0);
    masterSwitch.onTintColor = DY_RED2;
    masterSwitch.on = [DYConfig shared].masterEnabled;
    [masterSwitch addTarget:self
                     action:@selector(masterSwitchChanged:)
           forControlEvents:UIControlEventValueChanged];
    [masterRow addSubview:masterSwitch];

    cursor += kRowH;

    // Section separator.
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 1.0)];
    sep1.backgroundColor = DY_SEP;
    [content addSubview:sep1];
    cursor += 10.0;

    // Patrol mode label.
    UILabel *modeLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0, cursor, innerWidth, 18.0)];
    modeLabel.text = @"巡逻模式";
    modeLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    modeLabel.font = [UIFont systemFontOfSize:12.0];
    [content addSubview:modeLabel];
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
    [content addSubview:segmented];
    cursor += 44.0;

    // Feature switches.
    cursor = [self addToggleWithTitle:@"超级福袋 · 自动参与"
                                    y:cursor
                               toView:content
                              getter:@selector(superBagAutoJoin)
                              setter:@selector(setSuperBagAutoJoin:)];
    cursor = [self addToggleWithTitle:@"普通福袋 · 自动参与"
                                    y:cursor
                               toView:content
                              getter:@selector(normalBagAutoJoin)
                              setter:@selector(setNormalBagAutoJoin:)];
    cursor = [self addToggleWithTitle:@"评论口令自动发送"
                                    y:cursor
                               toView:content
                              getter:@selector(commentKeywordAutoSend)
                              setter:@selector(setCommentKeywordAutoSend:)];
    cursor = [self addToggleWithTitle:@"口令袋·需关注时自动关注"
                                    y:cursor
                               toView:content
                              getter:@selector(autoFollowForBags)
                              setter:@selector(setAutoFollowForBags:)];
    cursor = [self addToggleWithTitle:@"直播间自动巡逻"
                                    y:cursor
                               toView:content
                              getter:@selector(autoPatrol)
                              setter:@selector(setAutoPatrol:)];
    cursor = [self addToggleWithTitle:@"中奖横幅提醒"
                                    y:cursor
                               toView:content
                              getter:@selector(winBannerAlert)
                              setter:@selector(setWinBannerAlert:)];

    cursor += 10.0;   // breathing room below the last row
    return cursor;
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

    return y + kRowH;
}

#pragma mark - Panel dragging

// Only let a drag start on the grabber / header strip, and never on top of the
// 收起 / 隐藏 buttons — otherwise the pan would swallow their taps.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!self.panelView) {
        return YES;
    }

    CGPoint point = [gesture locationInView:self.panelView];
    if (point.y > kGrabberH + kHeaderH) {
        return NO;   // content area: switches / segmented / scroll keep the touch
    }

    if (self.collapseButton) {
        CGRect rect = [self.panelView convertRect:self.collapseButton.bounds
                                         fromView:self.collapseButton];
        if (CGRectContainsPoint(rect, point)) {
            return NO;
        }
    }
    if (self.hideButton) {
        CGRect rect = [self.panelView convertRect:self.hideButton.bounds
                                         fromView:self.hideButton];
        if (CGRectContainsPoint(rect, point)) {
            return NO;
        }
    }
    return YES;
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.panelView.superview];
    CGPoint center = self.panelView.center;
    center.x += translation.x;
    center.y += translation.y;
    self.panelView.center = [self clampPanelCenter:center];
    [pan setTranslation:CGPointZero inView:self.panelView.superview];
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

    // The banner is a plain container that hosts the gradient; the text lives in
    // a child UILabel. A UILabel rasterizes its glyphs into its own layer.contents,
    // and Core Animation always paints sublayers ON TOP of a layer's contents — so
    // putting the gradient directly on the label's layer (insertSublayer:atIndex:0)
    // would paint red over the white text. Splitting them keeps the text readable.
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(16.0, -80.0, width, 56.0)];
    banner.layer.cornerRadius = 14.0;
    banner.clipsToBounds = YES;
    banner.alpha = 0.0;

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = banner.bounds;
    g.cornerRadius = 14.0;
    g.colors = @[ (__bridge id)[UIColor colorWithRed:0.98 green:0.30 blue:0.42 alpha:1.0].CGColor,
                   (__bridge id)[UIColor colorWithRed:0.86 green:0.13 blue:0.18 alpha:1.0].CGColor ];
    [banner.layer addSublayer:g];

    UILabel *textLabel = [[UILabel alloc] initWithFrame:banner.bounds];
    textLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textLabel.text = [NSString stringWithFormat:@"🎉 %@", text];
    textLabel.textColor = [UIColor whiteColor];
    textLabel.font = [UIFont boldSystemFontOfSize:15.0];
    textLabel.textAlignment = NSTextAlignmentCenter;
    textLabel.numberOfLines = 0;
    [banner addSubview:textLabel];

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
