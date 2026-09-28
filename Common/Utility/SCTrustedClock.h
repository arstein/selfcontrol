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
+ (BOOL)stateIsSingleBootSession:(NSDictionary*)state reading:(NSDictionary*)reading;
+ (NSDictionary*)currentReading;

@end

NS_ASSUME_NONNULL_END
