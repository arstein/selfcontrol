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

    NSNumber* checkpointMach = state[@"lastCheckpointMachSecs"];
    NSTimeInterval completedBootSecs;
    if (checkpointMach != nil) {
        completedBootSecs = checkpointMach.doubleValue - [state[@"machAnchorSecs"] doubleValue];
    } else {
        // Compatibility with an early state schema that did not save mach time.
        NSDate* estimatedSegmentStart = [state[@"wallAnchor"] dateByAddingTimeInterval:
            [state[@"accumulatedPriorSecs"] doubleValue]];
        completedBootSecs = [state[@"lastCheckpointWall"] timeIntervalSinceDate:estimatedSegmentStart];
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

+ (BOOL)stateIsSingleBootSession:(NSDictionary*)state reading:(NSDictionary*)reading {
    return ![state[@"didCrossBoot"] boolValue] &&
           [state[@"bootSessionID"] isEqualToString:reading[@"boot"]];
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

    struct timeval bootTime = {0};
    size_t size = sizeof(bootTime);
    NSString* bootID = @"unknown";
    if (sysctlbyname("kern.boottime", &bootTime, &size, NULL, 0) == 0) {
        bootID = [NSString stringWithFormat:@"%ld.%d", (long)bootTime.tv_sec, bootTime.tv_usec];
    }
    return @{@"wall": [NSDate date], @"mach": @(machSeconds), @"boot": bootID};
}

@end
