#import <XCTest/XCTest.h>
#import "SCEnforcementDecision.h"

@interface SCEnforcementDecisionTests : XCTestCase
@end

@implementation SCEnforcementDecisionTests

// --- desired enforcement ---
- (void)testEnforcedWhenNotExpired {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:YES expired:NO rulesInstalled:YES];
    XCTAssertTrue(d.baseEnforced);
    XCTAssertFalse(d.needsVerifiedTime);
    XCTAssertFalse(d.recoveryNeeded);
}
- (void)testRelaxNeedsVerifiedTimeWhenExpiredAndInstalled {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:YES expired:YES rulesInstalled:YES];
    XCTAssertFalse(d.baseEnforced);
    XCTAssertTrue(d.needsVerifiedTime);
    XCTAssertFalse(d.recoveryNeeded);
}
- (void)testExpiredButNotInstalledIsNoop {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:YES expired:YES rulesInstalled:NO];
    XCTAssertFalse(d.baseEnforced);
    XCTAssertFalse(d.needsVerifiedTime);
    XCTAssertFalse(d.recoveryNeeded);
}
- (void)testTightenWhenNotExpiredAndNotInstalled {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:YES expired:NO rulesInstalled:NO];
    XCTAssertTrue(d.baseEnforced);      // should be enforcing -> loop installs
    XCTAssertFalse(d.needsVerifiedTime);
}
- (void)testUnknownExpiryWithRulesHoldsAndFlagsRecovery {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:NO expired:NO rulesInstalled:YES];
    XCTAssertTrue(d.baseEnforced);      // hold (fail-closed)
    XCTAssertTrue(d.recoveryNeeded);    // but state needs healing
    XCTAssertFalse(d.needsVerifiedTime);// recovery path, not the expiry path
}
- (void)testUnknownExpiryWithoutRulesIsNoop {
    SCDesiredEnforcement* d = [SCEnforcementDecision decisionForExpiryKnown:NO expired:NO rulesInstalled:NO];
    XCTAssertFalse(d.baseEnforced);
    XCTAssertFalse(d.recoveryNeeded);
}

// --- self-heal action ---
- (void)testSelfHealOnlineHeals {
    XCTAssertEqual([SCEnforcementDecision selfHealActionForRecoveryNeeded:YES verifiedTimeAvailable:YES], SCSelfHealActionHeal);
}
- (void)testSelfHealOfflineHolds {
    XCTAssertEqual([SCEnforcementDecision selfHealActionForRecoveryNeeded:YES verifiedTimeAvailable:NO], SCSelfHealActionHold);
}
- (void)testSelfHealNotNeededIsNone {
    XCTAssertEqual([SCEnforcementDecision selfHealActionForRecoveryNeeded:NO verifiedTimeAvailable:YES], SCSelfHealActionNone);
    XCTAssertEqual([SCEnforcementDecision selfHealActionForRecoveryNeeded:NO verifiedTimeAvailable:NO], SCSelfHealActionNone);
}

@end
