#import "DYConfig.h"
#import "DYLog.h"

// The C preprocessor cannot capitalise a token, and Objective-C setter names
// require a capital first letter ("setMasterEnabled:", not "setmasterEnabled:").
// So each macro takes the property name twice: lowercase for the ivar/key and
// capitalised for the setter.
#define DYBoolKey(LOWER, UPPER, DEFAULT)                              \
    - (BOOL)LOWER {                                                   \
        id value = [self.defaults objectForKey:@(#LOWER)];            \
        return value ? [value boolValue] : (DEFAULT);                 \
    }                                                                 \
    - (void)set##UPPER : (BOOL)value {                                \
        [self.defaults setBool:value forKey:@(#LOWER)];               \
    }

#define DYDoubleKey(LOWER, UPPER, DEFAULT)                            \
    - (NSTimeInterval)LOWER {                                         \
        id value = [self.defaults objectForKey:@(#LOWER)];            \
        return value ? [value doubleValue] : (DEFAULT);               \
    }                                                                 \
    - (void)set##UPPER : (NSTimeInterval)value {                      \
        [self.defaults setDouble:value forKey:@(#LOWER)];             \
    }

@implementation DYConfig {
    NSUserDefaults *_defaults;
}

+ (DYConfig *)shared {
    static DYConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DYConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        // A tweak injected into a sandboxed App Store binary cannot register
        // its own defaults suite, so settings live in the host app's defaults.
        _defaults = [NSUserDefaults standardUserDefaults];
        [self rollStatsIfDayChanged];
    }
    return self;
}

- (NSUserDefaults *)defaults {
    return _defaults;
}

#pragma mark - Switches

// Defaults are on so the tweak does something immediately after install; a
// silent no-op on first run is indistinguishable from a broken tweak.
DYBoolKey(masterEnabled, MasterEnabled, YES)
DYBoolKey(superBagAutoJoin, SuperBagAutoJoin, YES)
DYBoolKey(normalBagAutoJoin, NormalBagAutoJoin, YES)
DYBoolKey(commentKeywordAutoSend, CommentKeywordAutoSend, YES)
DYBoolKey(autoPatrol, AutoPatrol, YES)
DYBoolKey(winBannerAlert, WinBannerAlert, YES)

#pragma mark - Tunables

DYDoubleKey(scanInterval, ScanInterval, 1.5)
DYDoubleKey(patrolDwellTime, PatrolDwellTime, 30.0)

#pragma mark - Patrol mode

- (DYPatrolMode)patrolMode {
    id value = [self.defaults objectForKey:@"patrolMode"];
    if (!value) {
        return DYPatrolModeAutoJoin;
    }
    NSInteger raw = [value integerValue];
    if (raw < DYPatrolModeDetectOnly || raw > DYPatrolModeFullAuto) {
        return DYPatrolModeAutoJoin;
    }
    return (DYPatrolMode)raw;
}

- (void)setPatrolMode:(DYPatrolMode)patrolMode {
    [self.defaults setInteger:patrolMode forKey:@"patrolMode"];
}

#pragma mark - Statistics

- (void)rollStatsIfDayChanged {
    NSString *today = [self currentDayString];
    NSString *stored = [self.defaults stringForKey:@"statsDay"];
    if (stored && [stored isEqualToString:today]) {
        return;
    }
    [self.defaults setInteger:0 forKey:@"todayJoinCount"];
    [self.defaults setInteger:0 forKey:@"todayWinCount"];
    [self.defaults setInteger:0 forKey:@"todayRoomCount"];
    [self.defaults setObject:today forKey:@"statsDay"];
    DYLog(@"statistics rolled over to %@", today);
}

- (NSString *)currentDayString {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

- (NSInteger)todayJoinCount {
    return [self.defaults integerForKey:@"todayJoinCount"];
}

- (NSInteger)todayWinCount {
    return [self.defaults integerForKey:@"todayWinCount"];
}

- (NSInteger)todayRoomCount {
    return [self.defaults integerForKey:@"todayRoomCount"];
}

- (void)incrementJoinCount {
    [self rollStatsIfDayChanged];
    [self.defaults setInteger:self.todayJoinCount + 1 forKey:@"todayJoinCount"];
}

- (void)incrementWinCount {
    [self rollStatsIfDayChanged];
    [self.defaults setInteger:self.todayWinCount + 1 forKey:@"todayWinCount"];
}

- (void)incrementRoomCount {
    [self rollStatsIfDayChanged];
    [self.defaults setInteger:self.todayRoomCount + 1 forKey:@"todayRoomCount"];
}

- (void)resetTodayStats {
    [self.defaults setInteger:0 forKey:@"todayJoinCount"];
    [self.defaults setInteger:0 forKey:@"todayWinCount"];
    [self.defaults setInteger:0 forKey:@"todayRoomCount"];
}

#pragma mark - Persistence

- (void)synchronize {
    [self.defaults synchronize];
}

@end
