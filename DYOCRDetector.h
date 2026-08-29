#ifndef DYLUCKYBAG_DYOCRDETECTOR_H
#define DYLUCKYBAG_DYOCRDETECTOR_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// A single OCR hit: the recognised string plus where it sits on screen.
/// `rect` is in UIKit screen coordinates (points, origin at top-left), already
/// converted from Vision's bottom-left normalised space.
@interface DYTextHit : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGRect rect;
@property (nonatomic) CGFloat confidence;
@end

typedef void (^DYDetectionCompletion)(NSArray<DYTextHit *> *hits, NSError *error);

@interface DYOCRDetector : NSObject

+ (instancetype)shared;

/// Captures the current screen and runs text recognition on it.
/// `completion` is always invoked on the main queue.
- (void)detectWithCompletion:(DYDetectionCompletion)completion;

@end

/// Helpers for filtering OCR output.
@interface NSArray (DYTextHits)
/// First hit whose text contains `keyword` (case-insensitive), or nil.
- (DYTextHit *)dy_firstHitContaining:(NSString *)keyword;
/// All hits whose text contains `keyword`.
- (NSArray<DYTextHit *> *)dy_hitsContaining:(NSString *)keyword;
@end

#endif /* DYLUCKYBAG_DYOCRDETECTOR_H */
