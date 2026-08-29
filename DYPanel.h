#ifndef DYLUCKYBAG_DYPANEL_H
#define DYLUCKYBAG_DYPANEL_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DYPanel : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL visible;

/// Installs the floating entry button. Safe to call more than once.
- (void)show;
- (void)hide;
- (void)toggle;

/// Slides a banner in from the top, auto-dismissing after a few seconds.
- (void)showWinBanner:(NSString *)text;

/// Re-reads counters and status from the engine/config.
- (void)refresh;

@end

#endif /* DYLUCKYBAG_DYPANEL_H */
