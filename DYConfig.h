#ifndef DYLUCKYBAG_DYCONFIG_H
#define DYLUCKYBAG_DYCONFIG_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DYPatrolMode) {
    DYPatrolModeDetectOnly = 0,  // detect + log only, never tap
    DYPatrolModeAutoJoin   = 1,  // join bags in the current room
    DYPatrolModeFullAuto   = 2,  // join bags and move on to the next room
};

@interface DYConfig : NSObject

@property (class, nonatomic, readonly) DYConfig *shared;

// Switches
@property (nonatomic) BOOL masterEnabled;
@property (nonatomic) DYPatrolMode patrolMode;
@property (nonatomic) BOOL superBagAutoJoin;
@property (nonatomic) BOOL normalBagAutoJoin;
@property (nonatomic) BOOL commentKeywordAutoSend;
@property (nonatomic) BOOL autoPatrol;
@property (nonatomic) BOOL winBannerAlert;

// Tunables
@property (nonatomic) NSTimeInterval scanInterval;   // seconds between OCR passes
@property (nonatomic) NSTimeInterval patrolDwellTime; // seconds to linger in a room

// Daily statistics
@property (nonatomic, readonly) NSInteger todayJoinCount;
@property (nonatomic, readonly) NSInteger todayWinCount;
@property (nonatomic, readonly) NSInteger todayRoomCount;

- (void)incrementJoinCount;
- (void)incrementWinCount;
- (void)incrementRoomCount;
- (void)resetTodayStats;

- (void)synchronize;

@end

#endif /* DYLUCKYBAG_DYCONFIG_H */
