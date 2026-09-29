#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pure trusted-clock arithmetic plus a thin adapter for live system readings.
/// Within a boot, elapsed time comes from mach_continuous_time and is immune to
/// wall-clock changes. Across boots, elapsed time is conservatively accumulated.
@interface SCTrustedClock : NSObject

+ (NSDictionary*)freshStateWithReading:(NSDictionary*)reading;
+ (NSDictionary*)checkpointState:(NSDictionary*)state reading:(NSDictionary*)reading;
+ (NSDictionary*)reanchoredStateAfterBootChange:(NSDictionary*)state reading:(NSDictionary*)reading;
+ (NSTimeInterval)elapsedSecsForState:(NSDictionary*)state reading:(NSDictionary*)reading;
+ (NSDate*)trustedNowForState:(NSDictionary*)state reading:(NSDictionary*)reading;
+ (NSDate*)correctedStartForState:(NSDictionary*)state
                      verifiedNow:(NSDate*)verifiedNow
                          reading:(NSDictionary*)reading;
+ (NSDictionary*)currentReading;

/// A monotonic uptime source, in seconds, that keeps advancing across sleep
/// (backed by mach_continuous_time, unlike NSProcessInfo.systemUptime which
/// pauses while the machine is asleep). Callers that need "how much real time
/// has elapsed" across a possible lid-close - e.g. the tedium override's idle
/// expiry - should use this instead of systemUptime.
+ (NSTimeInterval)continuousUptimeSecs;

@end

NS_ASSUME_NONNULL_END
