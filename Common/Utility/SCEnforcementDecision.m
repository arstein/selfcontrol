#import "SCEnforcementDecision.h"
#import "SCEnforcementConfig.h"
@implementation SCEnforcementDecision
+ (SCEnforcementAction)actionForRulesInstalled:(BOOL)rulesInstalled
                                 modernRunning:(BOOL)modernRunning
                                 legacyRunning:(BOOL)legacyRunning
                             hasModernPedigree:(BOOL)hasModernPedigree
                         trustedRemainingKnown:(BOOL)trustedRemainingKnown
                                       expired:(BOOL)expired
                               startIsVerified:(BOOL)startIsVerified
                           needsReVerification:(BOOL)needsReVerification {
    if (!rulesInstalled && !modernRunning && !legacyRunning) {
        return SCEnforcementActionStopNoBlock;
    }
    // Genuine legacy (pre-fork) block only: legacy detection, no modern footprint.
    if (!modernRunning && legacyRunning && !hasModernPedigree) {
        return SCEnforcementActionLegacyExpireCheck;
    }
    // Modern / rules-present from here: NEVER local-remove.
    if (!trustedRemainingKnown) {
        // Trusted clock can't yield an end (wiped/corrupt, or orphaned rules).
        return rulesInstalled ? SCEnforcementActionHeal : SCEnforcementActionInstall;
    }
    // Trusted end is known & trustworthy from here.
    if (rulesInstalled && !modernRunning) {
        return SCEnforcementActionReArm;           // flag off but block real -> re-arm
    }
    if (expired) {
        return SCEnforcementActionSeekVerifiedExpiry;  // sole verified removal path
    }
    if (!rulesInstalled) {
        return SCEnforcementActionInstall;         // tighten
    }
    if (!startIsVerified || needsReVerification) {
        return SCEnforcementActionSeekVerifiedStart;
    }
    return SCEnforcementActionSteady;
}

+ (NSTimeInterval)healDurationSecsForExistingDuration:(NSNumber*)existingDuration {
    NSTimeInterval healSecs = SC_SELFHEAL_BLOCK_SECS;
    if ([existingDuration isKindOfClass:[NSNumber class]] && existingDuration.doubleValue > healSecs) {
        healSecs = existingDuration.doubleValue;
    }
    return healSecs;
}
@end
