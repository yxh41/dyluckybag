#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A real on-screen control found by walking the view tree (no screen capture
/// needed). `view` is a weak reference to the live UIView, so the caller can
/// trigger it directly instead of synthesising a touch at guessed coordinates.
@interface DYViewHit : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) CGRect screenRect;   // screen space, matches OCR rects
@property (nonatomic, weak) UIView *view;
@property (nonatomic, assign) BOOL isControl;
@end

/// Detects 福袋 / 参与 / 已参与 by reading the actual view hierarchy rather than
/// a screenshot. This is what lets the tweak act inside a live room even when
/// drawViewHierarchyInRect / renderInContext return a blank image (the Metal
/// video layer has no CPU backing store, so OCR sees nothing there).
@interface DYViewDetector : NSObject

/// Every visible view whose readable text contains one of `keywords`.
+ (NSArray<DYViewHit *> *)findViewsWithTextContaining:(NSArray<NSString *> *)keywords;

/// First hit for a single keyword (case-insensitive, whitespace-collapsed).
+ (nullable DYViewHit *)firstViewWithTextContaining:(NSString *)keyword;

/// First editable text field / view in the front window (prefers the current
/// first responder). Used to fill the comment box a 口令 福袋 opens on tap.
+ (nullable DYViewHit *)firstInputField;

/// First UIControl (usually a button) whose title contains `keyword`.
/// Differs from -firstViewWithTextContaining: by requiring a tappable control,
/// so a "发送" label is never mistaken for a non-interactive title.
+ (nullable DYViewHit *)firstControlWithTextContaining:(NSString *)keyword;

/// First UIControl whose title contains any of `keywords`.
+ (nullable DYViewHit *)firstControlWithTextContainingAny:(NSArray<NSString *> *)keywords;

/// The front-most application window. Exposed as a class method so other
/// modules (e.g. the engine's fill/send path) can sanity-check that a view is
/// still on screen before acting on it. Returns nil if no window is available.
+ (nullable UIWindow *)frontWindow;

@end

NS_ASSUME_NONNULL_END
