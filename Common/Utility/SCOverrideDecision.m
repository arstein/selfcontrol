#import "SCOverrideDecision.h"

@implementation SCOverrideDecision

+ (BOOL)overrideActiveWithTrustedNow:(NSDate*)trustedNow
                     overrideEndDate:(NSDate*)overrideEndDate {
    if (trustedNow == nil || overrideEndDate == nil) return NO;
    return [trustedNow compare:overrideEndDate] == NSOrderedAscending;
}

+ (BOOL)resetForVerifiedDay:(NSString*)verifiedDay
               lastResetDay:(NSString*)lastResetDay
                     perDay:(NSInteger)perDay
            outNewRemaining:(NSInteger*)outNewRemaining {
    // Days are yyyy-MM-dd, so lexicographic order == chronological order. Reset
    // only on a strictly LATER day: a stale verified instant (earlier day) must
    // never move the reset day backwards and refund the ration.
    if (verifiedDay != nil &&
        (lastResetDay == nil || [verifiedDay compare:lastResetDay] == NSOrderedDescending)) {
        if (outNewRemaining != NULL) *outNewRemaining = perDay;
        return YES;
    }
    return NO;
}

+ (SCOverrideInvokeResult)invokeAllowedWithBaseEnforcing:(BOOL)baseEnforcing
                                              deepActive:(BOOL)deepActive
                                           alreadyActive:(BOOL)alreadyActive
                                            policyPerDay:(NSInteger)policyPerDay
                                          remainingToday:(NSInteger)remainingToday {
    if (!baseEnforcing) return SCOverrideInvokeDenyNoActiveBlock;
    if (alreadyActive)  return SCOverrideInvokeDenyAlreadyActive;
    if (deepActive)     return SCOverrideInvokeDenyDuringDeepBlock;
    if (policyPerDay <= 0) return SCOverrideInvokeDenyNotAllowed;
    if (remainingToday <= 0) return SCOverrideInvokeDenyExhausted;
    return SCOverrideInvokeAllowed;
}

+ (NSTimeInterval)liftRemainingSecsWithTrustedNow:(NSDate*)trustedNow
                                   overrideEndDate:(NSDate*)overrideEndDate
                                     clockAnchored:(BOOL)clockAnchored
                                       maxLiftSecs:(NSTimeInterval)maxLiftSecs {
    if (trustedNow == nil || overrideEndDate == nil || !clockAnchored) return 0;
    NSTimeInterval remaining = [overrideEndDate timeIntervalSinceDate:trustedNow];
    if (remaining <= 0 || remaining > maxLiftSecs) return 0;
    return remaining;
}

+ (NSString*)dayStringForDate:(NSDate*)date timeZone:(NSTimeZone*)tz {
    static NSDateFormatter* fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        fmt.dateFormat = @"yyyy-MM-dd";
    });
    @synchronized (fmt) {
        fmt.timeZone = (tz != nil) ? tz : [NSTimeZone systemTimeZone];
        return [fmt stringFromDate:date];
    }
}

@end
