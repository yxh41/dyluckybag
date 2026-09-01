#import "DYViewDetector.h"
#import "DYLog.h"

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

    for (UIView *sub in view.subviews) {
        [self walk:sub keywords:keywords into:out depth:depth + 1];
    }
}

+ (NSArray<DYViewHit *> *)findViewsWithTextContaining:(NSArray<NSString *> *)keywords {
    UIWindow *window = [self frontWindow];
    if (!window) {
        return @[];
    }
    NSMutableArray<DYViewHit *> *out = [NSMutableArray array];
    @try {
        [self walk:window keywords:keywords into:out depth:0];
    } @catch (NSException *exception) {
        DYLog(@"viewdetect: traversal threw: %@", exception.reason);
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
        for (UIView *sub in view.subviews) {
            walk(sub, depth + 1);
        }
    };
    @try {
        walk(window, 0);
    } @catch (NSException *exception) {
        DYLog(@"viewdetect: input traversal threw: %@", exception.reason);
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
