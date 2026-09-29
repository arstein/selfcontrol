//  SCEnforcementDecision.h
//  Pure, side-effect-free enforcement decision layer (parallels
//  SCBlockUtilities.trustedTimingDecisionForSettings:...). Foundation-only so
//  the app, the daemon, and the tests can all link it.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCSelfHealAction) {
    SCSelfHealActionNone = 0, // nothing to recover
    SCSelfHealActionHeal,     // write verified-now + SC_SELFHEAL_BLOCK_SECS
    SCSelfHealActionHold      // keep enforcing, wait for verified time
};

/// What the daemon should be enforcing this tick. Phase 2 populates only the
/// base-block term; the reserved fields keep the loop's call site stable for
/// Phases 3–5 (schedules, overrides, deep blocks).
@interface SCDesiredEnforcement : NSObject
@property (nonatomic, readonly) BOOL baseEnforced;      // rules should be installed now
@property (nonatomic, readonly) BOOL needsVerifiedTime; // a relaxing change is pending verification
@property (nonatomic, readonly) BOOL recoveryNeeded;    // rules present but end-date undeterminable
// Reserved (always NO in Phase 2): @property BOOL deepEnforced;  // Phase 5
@end

@interface SCEnforcementDecision : NSObject

/// `expiryKnown` = the daemon can determine whether the block has ended (it has
/// a trusted remaining-duration or a parseable BlockEndDate). `expired` is only
/// meaningful when `expiryKnown`. `rulesInstalled` = SelfControl rules are on
/// the system right now.
+ (SCDesiredEnforcement*)decisionForExpiryKnown:(BOOL)expiryKnown
                                        expired:(BOOL)expired
                                 rulesInstalled:(BOOL)rulesInstalled;

+ (SCSelfHealAction)selfHealActionForRecoveryNeeded:(BOOL)recoveryNeeded
                              verifiedTimeAvailable:(BOOL)verifiedTimeAvailable;

@end

NS_ASSUME_NONNULL_END
