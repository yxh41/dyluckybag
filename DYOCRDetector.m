#import "DYOCRDetector.h"
#import "DYLog.h"
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>

/// Vision frequently splits CJK runs into separate glyphs ("福 袋"). Compare on
/// a whitespace-stripped copy so a single stray space cannot hide the bag.
static NSString *DYCompactText(NSString *text) {
    if (text.length == 0) {
        return @"";
    }
    NSArray<NSString *> *parts =
        [text componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [parts componentsJoinedByString:@""];
}

@implementation DYTextHit

- (NSString *)description {
    return [NSString stringWithFormat:@"<DYTextHit %@ conf=%.2f rect=%@>",
            self.text, self.confidence, NSStringFromCGRect(self.rect)];
}

@end

@implementation DYOCRDetector

// OCR (Vision) is the expensive part of a scan pass (~50-100 ms). Run it on a
// dedicated serial queue so the main thread — and therefore Douyin's UI and
// video playback — is never stalled by our periodic screen analysis.
static dispatch_queue_t DYOCRQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.dyluckybag.ocr", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

+ (instancetype)shared {
    static DYOCRDetector *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DYOCRDetector alloc] init];
    });
    return instance;
}

#pragma mark - Window lookup

- (UIWindow *)frontWindow {
    UIApplication *app = UIApplication.sharedApplication;

    // Never capture our own overlay. It floats above Douyin at alert level and
    // holds nothing but the 福 button and the panel, so pointing the OCR at it
    // would silently produce a near-empty screen.
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

#pragma mark - Screen capture

- (UIImage *)captureScreen {
    UIWindow *window = [self frontWindow];
    if (!window) {
        DYLog(@"capture skipped: no front window");
        return nil;
    }

    CGSize size = window.bounds.size;
    if (size.width <= 0 || size.height <= 0) {
        DYLog(@"capture skipped: zero-sized window");
        return nil;
    }

    // scale = 2 hands Vision roughly twice the pixels per glyph. The 福袋
    // capsule is only about 12pt tall; at scale 1 that is so few pixels that the
    // recogniser either skips it or reads it as noise. Coordinates are returned
    // normalised by Vision, so raising the scale does not shift any hit rects.
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 2.0;
    format.opaque = YES;

    __block BOOL hierarchyOK = NO;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        hierarchyOK = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        if (hierarchyOK) {
            return;
        }

        // Live rooms are the problem case: Douyin renders video through
        // Metal / AV layers that have no CPU backing store, and
        // drawViewHierarchyInRect refuses those outright (returns NO). That is
        // why every capture taken inside a live room came back with zero hits
        // while captures in the feed worked fine.
        //
        // renderInContext: walks the layer tree instead. The video surface comes
        // out blank, but every UILabel and UIButton — including the 福袋 capsule
        // and the 参与 button — is Quartz-drawn and renders perfectly. Blank
        // video costs us nothing because we only ever read text.
        @try {
            [window.layer renderInContext:context.CGContext];
        } @catch (NSException *exception) {
            DYLog(@"layer render failed: %@", exception.reason);
        }
    }];

    if (!hierarchyOK) {
        DYLog(@"hierarchy capture failed -> used layer render fallback");
        [self logWindowDiagnostics:window];
    }

    return image;
}

/// Emitted (rate limited) whenever the fast capture path fails, so a log from a
/// live room explains itself instead of just reporting zero hits.
- (void)logWindowDiagnostics:(UIWindow *)window {
    // DYLog expands to ((void)0) in release builds, which would leave every
    // variable below "set but not used" and fail the -Werror build. Keep the
    // method itself defined in both configurations so the call sites compile;
    // only its body is debug-only.
#ifdef DEBUG
    static CFTimeInterval lastDiagnostic = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastDiagnostic < 30.0) {
        return;
    }
    lastDiagnostic = now;

    UIApplicationState state = UIApplication.sharedApplication.applicationState;
    NSString *stateName = @[ @"active", @"inactive", @"background" ][MIN((int)state, 2)];

    NSInteger windowCount = 0;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                windowCount += ((UIWindowScene *)scene).windows.count;
            }
        }
    }

    DYLog(@"capture diag: appState=%@ window=%@ key=%d hidden=%d alpha=%.2f "
          @"level=%.0f bounds=%@ windows=%ld screen=%@",
          stateName, NSStringFromClass(window.class), window.isKeyWindow, window.hidden,
          window.alpha, window.windowLevel, NSStringFromCGRect(window.bounds),
          (long)windowCount, NSStringFromCGSize(UIScreen.mainScreen.bounds.size));
#endif
}

#pragma mark - OCR

- (void)detectWithCompletion:(DYDetectionCompletion)completion {
    // Screen capture must happen on the main thread (it reads UIKit layer
    // content), but it is only a few milliseconds. The OCR below is the costly
    // part and is dispatched to a background queue.
    UIImage *image = [self captureScreen];
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        DYLog(@"OCR skipped: capture produced no CGImage");
        if (completion) {
            completion(@[], nil);
        }
        return;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;

    VNRecognizeTextRequest *request =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *error) {
            NSMutableArray<DYTextHit *> *hits = [NSMutableArray array];

            for (VNRecognizedTextObservation *observation in req.results) {
                if (![observation isKindOfClass:VNRecognizedTextObservation.class]) {
                    continue;
                }
                NSArray<VNRecognizedText *> *candidates = [observation topCandidates:1];
                if (candidates.count == 0) {
                    continue;
                }
                VNRecognizedText *best = candidates.firstObject;

                DYTextHit *hit = [[DYTextHit alloc] init];
                hit.text = best.string ?: @"";
                hit.confidence = best.confidence;
                hit.rect = [self uiKitRectFromNormalized:observation.boundingBox
                                              screenSize:screenSize];
                [hits addObject:hit];
            }

            if (error) {
                DYLog(@"OCR error: %@", error.localizedDescription);
            } else {
                DYLog(@"OCR produced %lu hits", (unsigned long)hits.count);
                [self logHits:hits];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(hits, error);
                }
            });
        }];

    // Accurate instead of fast, and a much lower minimum glyph height: the 福袋
    // capsule sits far below Vision's default minimum (roughly 1/32 of the image
    // height), so on the fast path it was being skipped entirely — the OCR was
    // reporting hits from the big UI text while never once seeing the bag. The
    // scan runs on a background queue every few seconds, so the extra cost is
    // invisible to the user.
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    // zh-Hans covers Douyin's Chinese UI chrome, en-US the numeric countdowns.
    // recognitionLanguages exists since iOS 13, so no availability guard is
    // needed against this project's iOS 15 deployment target — guarding it at
    // iOS 16 would have silently left the recogniser on the default locale.
    request.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];
    // Note: the header documents this as pixels while the default (0) is known
    // to scale with image size, i.e. it behaves like a fraction of image height.
    // Measured against our capture: at scale 2 a 12pt glyph is ~24px tall in a
    // ~1688px image, while the default threshold is ~1/32 of the height (~52px)
    // — the capsule was invisible to Vision. 0.005 clears that bar under either
    // reading of the unit.
    request.minimumTextHeight = 0.005;

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];

    dispatch_async(DYOCRQueue(), ^{
        NSError *error = nil;
        [handler performRequests:@[ request ] error:&error];
        if (error) {
            DYLog(@"performRequests failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(@[], error);
                }
            });
        }
    });
}

#pragma mark - Diagnostics

/// Dump what the recogniser actually read. Without this a log can only ever say
/// "N hits", which never explains why 福袋 was not among them.
- (void)logHits:(NSArray<DYTextHit *> *)hits {
    // Debug-only body for the same reason as logWindowDiagnostics: (see above).
#ifdef DEBUG
    if (hits.count == 0) {
        return;
    }
    NSMutableString *line = [NSMutableString stringWithString:@"OCR text:"];
    NSUInteger limit = MIN(hits.count, (NSUInteger)30);
    for (NSUInteger i = 0; i < limit; i++) {
        DYTextHit *hit = hits[i];
        [line appendFormat:@" [%@ @%d,%d c=%.2f]",
            hit.text ?: @"",
            (int)CGRectGetMidX(hit.rect), (int)CGRectGetMidY(hit.rect),
            hit.confidence];
    }
    DYLog(@"%@", line);
#endif
}

#pragma mark - Coordinate conversion

- (CGRect)uiKitRectFromNormalized:(CGRect)normalized screenSize:(CGSize)screenSize {
    // Vision reports normalised coordinates with the origin at the BOTTOM-left
    // and y increasing upward. UIKit wants the origin at the top-left with y
    // increasing downward, so flip and rescale in one step.
    CGFloat x = normalized.origin.x * screenSize.width;
    CGFloat width = normalized.size.width * screenSize.width;
    CGFloat height = normalized.size.height * screenSize.height;
    CGFloat y = (1.0 - normalized.origin.y - normalized.size.height) * screenSize.height;
    return CGRectMake(x, y, width, height);
}

@end

@implementation NSArray (DYTextHits)

- (DYTextHit *)dy_firstHitContaining:(NSString *)keyword {
    if (keyword.length == 0) {
        return nil;
    }
    for (id object in self) {
        if (![object isKindOfClass:DYTextHit.class]) {
            continue;
        }
        DYTextHit *hit = (DYTextHit *)object;
        if ([DYCompactText(hit.text) rangeOfString:DYCompactText(keyword)
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return hit;
        }
    }
    return nil;
}

- (NSArray<DYTextHit *> *)dy_hitsContaining:(NSString *)keyword {
    if (keyword.length == 0) {
        return @[];
    }
    NSMutableArray<DYTextHit *> *matches = [NSMutableArray array];
    for (id object in self) {
        if (![object isKindOfClass:DYTextHit.class]) {
            continue;
        }
        DYTextHit *hit = (DYTextHit *)object;
        if ([DYCompactText(hit.text) rangeOfString:DYCompactText(keyword)
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [matches addObject:hit];
        }
    }
    return matches;
}

@end
