#import "DYOCRDetector.h"
#import "DYLog.h"
#import <Vision/Vision.h>

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

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && window.bounds.size.width > 0) {
                    return window;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
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

    // scale = 1 keeps the OCR pass cheap; we only need text positions, and the
    // Vision request is the bottleneck, not the rasterisation.
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        BOOL ok = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        if (!ok) {
            DYLog(@"drawViewHierarchyInRect returned NO (no backing layer?)");
        }
    }];

    return image;
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
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(hits, error);
                }
            });
        }];

    // Fast level + no language correction keeps a full-screen pass well under
    // 100 ms, which matters because we scan roughly once a second.
    request.recognitionLevel = VNRequestTextRecognitionLevelFast;
    request.usesLanguageCorrection = NO;
    // zh-Hans covers Douyin's Chinese UI chrome, en-US the numeric countdowns.
    // recognitionLanguages exists since iOS 13, so no availability guard is
    // needed against this project's iOS 15 deployment target — guarding it at
    // iOS 16 would have silently left the recogniser on the default locale.
    request.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];

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
        if ([hit.text rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
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
        if ([hit.text rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [matches addObject:hit];
        }
    }
    return matches;
}

@end
