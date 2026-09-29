#import "SCTrustedClock.h"

#import <mach/mach_time.h>
#import <sys/sysctl.h>

@implementation SCTrustedClock

+ (NSDictionary*)freshStateWithReading:(NSDictionary*)reading {
    return @{
        @"bootSessionID": reading[@"boot"],
        @"machAnchorSecs": reading[@"mach"],
        @"wallAnchor": reading[@"wall"],
        @"accumulatedPriorSecs": @0.0,
        @"lastCheckpointMachSecs": reading[@"mach"],
        @"lastCheckpointWall": reading[@"wall"],
        @"didCrossBoot": @NO,
    };
}

+ (NSTimeInterval)elapsedSecsForState:(NSDictionary*)state reading:(NSDictionary*)reading {
    if (state.count == 0) return 0;
    NSTimeInterval machDelta = [reading[@"mach"] doubleValue] - [state[@"machAnchorSecs"] doubleValue];
    if (machDelta < 0) machDelta = 0;
    return [state[@"accumulatedPriorSecs"] doubleValue] + machDelta;
}

+ (NSDate*)trustedNowForState:(NSDictionary*)state reading:(NSDictionary*)reading {
    NSDate* wallAnchor = state[@"wallAnchor"];
    if (wallAnchor == nil) return reading[@"wall"];
    return [wallAnchor dateByAddingTimeInterval:[self elapsedSecsForState:state reading:reading]];
}

+ (NSDictionary*)checkpointState:(NSDictionary*)state reading:(NSDictionary*)reading {
    if (state.count == 0) return state;
    NSMutableDictionary* checkpoint = [state mutableCopy];
    checkpoint[@"lastCheckpointMachSecs"] = reading[@"mach"];
    checkpoint[@"lastCheckpointWall"] = reading[@"wall"];
    return checkpoint;
}

+ (NSDictionary*)reanchoredStateAfterBootChange:(NSDictionary*)state reading:(NSDictionary*)reading {
    if (state.count == 0) return state;

    // Only monotonic time observed in the previous boot is credited. Every state
    // this fork writes carries lastCheckpointMachSecs; if it is somehow missing
    // or malformed, credit nothing for the completed boot (fail closed: an
    // unverified block only gets longer) rather than falling back to the
    // user-controllable wall clock.
    NSNumber* checkpointMach = state[@"lastCheckpointMachSecs"];
    NSNumber* anchorMach = state[@"machAnchorSecs"];
    NSTimeInterval completedBootSecs = 0;
    if ([checkpointMach isKindOfClass:[NSNumber class]] && [anchorMach isKindOfClass:[NSNumber class]]) {
        completedBootSecs = checkpointMach.doubleValue - anchorMach.doubleValue;
    }
    if (completedBootSecs < 0) completedBootSecs = 0;

    // No monotonic source spans a power-off. Crediting a positive wall-clock
    // gap would let a user roll the clock forward during reboot and shorten an
    // unverified block. Treat the gap as zero; the daemon refreshes from SNTP
    // immediately after restart, which restores the absolute timeline once the
    // original start has been verified.
    NSTimeInterval gapSecs = 0;

    NSMutableDictionary* reanchored = [state mutableCopy];
    reanchored[@"accumulatedPriorSecs"] = @([state[@"accumulatedPriorSecs"] doubleValue] +
                                             completedBootSecs + gapSecs);
    reanchored[@"bootSessionID"] = reading[@"boot"];
    reanchored[@"machAnchorSecs"] = reading[@"mach"];
    reanchored[@"lastCheckpointMachSecs"] = reading[@"mach"];
    reanchored[@"lastCheckpointWall"] = reading[@"wall"];
    reanchored[@"didCrossBoot"] = @YES;
    return reanchored;
}

+ (NSDate*)correctedStartForState:(NSDictionary*)state
                      verifiedNow:(NSDate*)verifiedNow
                          reading:(NSDictionary*)reading {
    return [verifiedNow dateByAddingTimeInterval:
        -[self elapsedSecsForState:state reading:reading]];
}

+ (NSDictionary*)currentReading {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    NSTimeInterval machSeconds = (NSTimeInterval)mach_continuous_time() *
                                 (NSTimeInterval)timebase.numer /
                                 (NSTimeInterval)timebase.denom / 1e9;

    // kern.bootsessionuuid is stable for the life of a boot. kern.boottime is
    // only a fallback: it shifts when the calendar clock is stepped, which
    // would make a same-boot daemon relaunch look like a reboot.
    NSString* bootID = @"unknown";
    char bootUUID[64] = {0};
    size_t uuidSize = sizeof(bootUUID) - 1;
    if (sysctlbyname("kern.bootsessionuuid", bootUUID, &uuidSize, NULL, 0) == 0 && bootUUID[0] != '\0') {
        bootID = [NSString stringWithUTF8String:bootUUID] ?: bootID;
    } else {
        struct timeval bootTime = {0};
        size_t size = sizeof(bootTime);
        if (sysctlbyname("kern.boottime", &bootTime, &size, NULL, 0) == 0) {
            bootID = [NSString stringWithFormat:@"%ld.%d", (long)bootTime.tv_sec, bootTime.tv_usec];
        }
    }
    return @{@"wall": [NSDate date], @"mach": @(machSeconds), @"boot": bootID};
}

@end
