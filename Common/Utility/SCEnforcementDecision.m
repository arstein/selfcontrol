#import "SCEnforcementDecision.h"

@interface SCDesiredEnforcement ()
@property (nonatomic, readwrite) BOOL baseEnforced;
@property (nonatomic, readwrite) BOOL needsVerifiedTime;
@property (nonatomic, readwrite) BOOL recoveryNeeded;
@end
@implementation SCDesiredEnforcement
@end

@implementation SCEnforcementDecision

+ (SCDesiredEnforcement*)decisionForExpiryKnown:(BOOL)expiryKnown
                                        expired:(BOOL)expired
                                 rulesInstalled:(BOOL)rulesInstalled {
    SCDesiredEnforcement* d = [SCDesiredEnforcement new];
    if (!expiryKnown) {
        // Can't tell if the block has ended. Fail-closed: hold whatever is
        // installed, and flag recovery so the loop can heal the state.
        d.baseEnforced = rulesInstalled;
        d.recoveryNeeded = rulesInstalled;
        d.needsVerifiedTime = NO;
        return d;
    }
    d.baseEnforced = !expired;
    d.recoveryNeeded = NO;
    // A relaxing transition (rules are up but the block has ended) must be
    // confirmed by verified network time before anything is removed.
    d.needsVerifiedTime = rulesInstalled && expired;
    return d;
}

+ (SCSelfHealAction)selfHealActionForRecoveryNeeded:(BOOL)recoveryNeeded
                              verifiedTimeAvailable:(BOOL)verifiedTimeAvailable {
    if (!recoveryNeeded) return SCSelfHealActionNone;
    return verifiedTimeAvailable ? SCSelfHealActionHeal : SCSelfHealActionHold;
}

@end
