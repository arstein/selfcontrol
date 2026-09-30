#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCOverrideInvokeResult) {
    SCOverrideInvokeAllowed = 0,
    SCOverrideInvokeDenyNoActiveBlock,
    SCOverrideInvokeDenyAlreadyActive,
    SCOverrideInvokeDenyDuringDeepBlock,
    SCOverrideInvokeDenyNotAllowed,
    SCOverrideInvokeDenyExhausted,
};

@interface SCOverrideDecision : NSObject

// Whether an override is currently active. Fail-closed: nil trustedNow or nil
// endDate => NO (base enforces).
+ (BOOL)overrideActiveWithTrustedNow:(nullable NSDate*)trustedNow
                     overrideEndDate:(nullable NSDate*)overrideEndDate;

// Midnight reset (pure). Returns YES and fills outNewRemaining=perDay when the
// verified day differs from lastResetDay (or lastResetDay is nil). Otherwise NO.
+ (BOOL)resetForVerifiedDay:(NSString*)verifiedDay
               lastResetDay:(nullable NSString*)lastResetDay
                     perDay:(NSInteger)perDay
            outNewRemaining:(NSInteger*)outNewRemaining;

// Invoke gate (pure). remainingToday is the value AFTER any midnight reset.
+ (SCOverrideInvokeResult)invokeAllowedWithBaseEnforcing:(BOOL)baseEnforcing
                                              deepActive:(BOOL)deepActive
                                           alreadyActive:(BOOL)alreadyActive
                                            policyPerDay:(NSInteger)policyPerDay
                                          remainingToday:(NSInteger)remainingToday;

// yyyy-MM-dd for `date` evaluated in `tz` (POSIX/en_US_POSIX, gregorian).
+ (NSString*)dayStringForDate:(NSDate*)date timeZone:(NSTimeZone*)tz;

@end

NS_ASSUME_NONNULL_END
