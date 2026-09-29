#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCEnforcementAction) {
    SCEnforcementActionStopNoBlock = 0,     // nothing installed & no block -> stop checkups
    SCEnforcementActionLegacyExpireCheck,   // genuine pre-fork block -> caller checks LOCAL expiry, remove if expired
    SCEnforcementActionReArm,               // rules up, trusted end known, but BlockIsRunning off -> re-assert flag (no network)
    SCEnforcementActionHeal,                // rules up, trusted end NOT determinable -> verified heal (now+N) / hold offline
    SCEnforcementActionInstall,             // should enforce but rules missing -> install (tighten, no network)
    SCEnforcementActionSeekVerifiedExpiry,  // trusted-expired -> handleVerifiedTime (sole removal site)
    SCEnforcementActionSeekVerifiedStart,   // start not yet verified / re-verify flagged -> handleVerifiedTime
    SCEnforcementActionSteady               // enforced+installed+verified -> integrity only
};

@interface SCEnforcementDecision : NSObject
/// Pure, side-effect-free. `expired` is trusted-expiry and is only consulted when
/// `trustedRemainingKnown` is YES. `hasModernPedigree` = the block has any fork-era
/// trusted-timing footprint (BlockDurationSecs>0, non-empty TrustedClockState, or a
/// valid BlockStartWall) — it distinguishes a tampered modern block from a genuine
/// legacy one.
+ (SCEnforcementAction)actionForRulesInstalled:(BOOL)rulesInstalled
                                 modernRunning:(BOOL)modernRunning
                                 legacyRunning:(BOOL)legacyRunning
                             hasModernPedigree:(BOOL)hasModernPedigree
                         trustedRemainingKnown:(BOOL)trustedRemainingKnown
                                       expired:(BOOL)expired
                               startIsVerified:(BOOL)startIsVerified
                           needsReVerification:(BOOL)needsReVerification;

/// Duration (seconds) to heal a tamper-recovered block to. Never shorter than
/// SC_SELFHEAL_BLOCK_SECS, and never shorter than the block's own stored
/// duration when that is still known — so tampering can only ever extend the
/// block, never shorten it (fail-closed). `existingDuration` is the stored
/// BlockDurationSecs (nil/<=0 when unknown).
+ (NSTimeInterval)healDurationSecsForExistingDuration:(nullable NSNumber*)existingDuration;
@end
NS_ASSUME_NONNULL_END
