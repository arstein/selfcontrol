#import <XCTest/XCTest.h>
#import "SCEnforcementDecision.h"

@interface SCEnforcementDecisionTests : XCTestCase
@end

@implementation SCEnforcementDecisionTests

// stop when nothing installed & no block.
- (void)testStopWhenNothingInstalledAndNoBlock {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:NO
                                         modernRunning:NO
                                         legacyRunning:NO
                                     hasModernPedigree:NO
                                 trustedRemainingKnown:NO
                                               expired:NO
                                       startIsVerified:NO
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionStopNoBlock);
}

// genuine legacy (legacyRunning=YES, modernRunning=NO, hasModernPedigree=NO) -> LegacyExpireCheck.
- (void)testGenuineLegacyBlockIsLegacyExpireCheck {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:NO
                                         legacyRunning:YES
                                     hasModernPedigree:NO
                                 trustedRemainingKnown:NO
                                               expired:NO
                                       startIsVerified:NO
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionLegacyExpireCheck);
}

// C1(a): tampered modern block (TrustedClockState wiped) must Heal, NOT be treated as legacy.
- (void)testC1a_TamperedModernWithNoTrustedEndHeals {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:NO
                                               expired:NO
                                       startIsVerified:NO
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionHeal);
}

// C1(b): rules up, trusted end known, flag off -> ReArm (fixes fail-closed permablock).
- (void)testC1b_FlagOffButTrustedEndKnownReArms {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:NO
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:NO
                                       startIsVerified:YES
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionReArm);
}

// steady: all-on, verified, not expired -> Steady.
- (void)testSteadyWhenAllOnVerifiedNotExpired {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:NO
                                       startIsVerified:YES
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionSteady);
}

// install: modernRunning=YES, rulesInstalled=NO, trustedRemainingKnown=YES, expired=NO -> Install.
- (void)testInstallWhenRulesMissingButShouldEnforce {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:NO
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:NO
                                       startIsVerified:YES
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionInstall);
}

// expiry: rulesInstalled=YES, modernRunning=YES, trustedRemainingKnown=YES, expired=YES -> SeekVerifiedExpiry.
- (void)testSeekVerifiedExpiryWhenTrustedExpired {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:YES
                                       startIsVerified:YES
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionSeekVerifiedExpiry);
}

// start-not-verified: enforcing, not expired, startIsVerified=NO -> SeekVerifiedStart.
- (void)testSeekVerifiedStartWhenStartNotVerified {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:NO
                                       startIsVerified:NO
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionSeekVerifiedStart);
}

// start-not-verified: needsReVerification=YES -> SeekVerifiedStart.
- (void)testSeekVerifiedStartWhenReVerificationFlagged {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:YES
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:NO
                                       startIsVerified:YES
                                   needsReVerification:YES];
    XCTAssertEqual(action, SCEnforcementActionSeekVerifiedStart);
}

// heal when no rules but modern flagged & no trusted end -> Install (per rulesInstalled?Heal:Install).
- (void)testNoRulesModernFlaggedNoTrustedEndInstalls {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:NO
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:NO
                                               expired:NO
                                       startIsVerified:NO
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionInstall);
}

// expired takes precedence over install when rules missing: modernRunning=YES so not ReArm;
// trustedRemainingKnown=YES, expired=YES -> SeekVerifiedExpiry.
- (void)testExpiredTakesPrecedenceOverInstallWhenRulesMissing {
    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:NO
                                         modernRunning:YES
                                         legacyRunning:NO
                                     hasModernPedigree:YES
                                 trustedRemainingKnown:YES
                                               expired:YES
                                       startIsVerified:YES
                                   needsReVerification:NO];
    XCTAssertEqual(action, SCEnforcementActionSeekVerifiedExpiry);
}

// --- heal duration: never shorter than the floor, never shorter than the block's own duration ---
- (void)testHealDurationUnknownDurationUsesFloor {
    XCTAssertEqual([SCEnforcementDecision healDurationSecsForExistingDuration:nil], 86400.0);
}
- (void)testHealDurationShortDurationUsesFloor {
    XCTAssertEqual([SCEnforcementDecision healDurationSecsForExistingDuration:@3600], 86400.0);
}
- (void)testHealDurationZeroUsesFloor {
    XCTAssertEqual([SCEnforcementDecision healDurationSecsForExistingDuration:@0], 86400.0);
}
- (void)testHealDurationLongerDurationIsPreserved {
    // a 14-day block whose trusted state was wiped heals to the full 14 days, not 24h
    XCTAssertEqual([SCEnforcementDecision healDurationSecsForExistingDuration:@(14 * 86400)], 14 * 86400.0);
}

@end
