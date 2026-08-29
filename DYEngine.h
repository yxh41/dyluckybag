#ifndef DYLUCKYBAG_DYENGINE_H
#define DYLUCKYBAG_DYENGINE_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DYEngineState) {
    DYEngineStateIdle = 0,        // nothing interesting on screen
    DYEngineStateBagDetected,     // a lucky bag is on screen
    DYEngineStateJoined,          // we just tapped join
    DYEngineStateWaitingResult,   // joined, waiting for the draw
    DYEngineStateWon,             // win detected
};

@interface DYEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) DYEngineState state;
@property (nonatomic, readonly) BOOL running;

/// Human-readable one-liner about the last decision, for the panel/log.
@property (nonatomic, copy, readonly) NSString *lastStatus;

/// Invoked on the main queue whenever `state` or `lastStatus` changes.
@property (nonatomic, copy) void (^onUpdate)(DYEngineState state, NSString *status);

- (void)start;
- (void)stop;

/// Forces one detection pass right now (used by the panel's "scan now" button).
- (void)scanOnce;

@end

#endif /* DYLUCKYBAG_DYENGINE_H */
