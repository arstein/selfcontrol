#import <XCTest/XCTest.h>
#import "SCOverrideDecision.h"

@interface SCOverrideDecisionTests : XCTestCase
@end

@implementation SCOverrideDecisionTests

#pragma mark overrideActive (fail-closed)

- (void)testOverrideActiveNilTrustedNowIsNo {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:600];
    XCTAssertFalse([SCOverrideDecision overrideActiveWithTrustedNow:nil overrideEndDate:end]);
}
- (void)testOverrideActiveNilEndDateIsNo {
    XCTAssertFalse([SCOverrideDecision overrideActiveWithTrustedNow:[NSDate date] overrideEndDate:nil]);
}
- (void)testOverrideActiveNowBeforeEndIsYes {
    NSDate* now = [NSDate date];
    NSDate* end = [now dateByAddingTimeInterval:60];
    XCTAssertTrue([SCOverrideDecision overrideActiveWithTrustedNow:now overrideEndDate:end]);
}
- (void)testOverrideActiveNowAtOrAfterEndIsNo {
    NSDate* now = [NSDate date];
    XCTAssertFalse([SCOverrideDecision overrideActiveWithTrustedNow:now overrideEndDate:now]);
    XCTAssertFalse([SCOverrideDecision overrideActiveWithTrustedNow:now overrideEndDate:[now dateByAddingTimeInterval:-1]]);
}

#pragma mark midnight reset

- (void)testResetSameDayNoReset {
    NSInteger out = -1;
    XCTAssertFalse([SCOverrideDecision resetForVerifiedDay:@"2026-09-30" lastResetDay:@"2026-09-30" perDay:3 outNewRemaining:&out]);
}
- (void)testResetDayChangeResetsToPerDay {
    NSInteger out = -1;
    XCTAssertTrue([SCOverrideDecision resetForVerifiedDay:@"2026-10-01" lastResetDay:@"2026-09-30" perDay:3 outNewRemaining:&out]);
    XCTAssertEqual(out, 3);
}
- (void)testResetNilLastResetDayResets {
    NSInteger out = -1;
    XCTAssertTrue([SCOverrideDecision resetForVerifiedDay:@"2026-09-30" lastResetDay:nil perDay:5 outNewRemaining:&out]);
    XCTAssertEqual(out, 5);
}

#pragma mark invoke gate

- (void)testInvokeAllowed {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:YES deepActive:NO alreadyActive:NO policyPerDay:3 remainingToday:2], SCOverrideInvokeAllowed);
}
- (void)testInvokeDenyNoActiveBlock {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:NO deepActive:NO alreadyActive:NO policyPerDay:3 remainingToday:2], SCOverrideInvokeDenyNoActiveBlock);
}
- (void)testInvokeDenyAlreadyActive {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:YES deepActive:NO alreadyActive:YES policyPerDay:3 remainingToday:2], SCOverrideInvokeDenyAlreadyActive);
}
- (void)testInvokeDenyDuringDeepBlock {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:YES deepActive:YES alreadyActive:NO policyPerDay:3 remainingToday:2], SCOverrideInvokeDenyDuringDeepBlock);
}
- (void)testInvokeDenyNotAllowedWhenPerDayZero {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:YES deepActive:NO alreadyActive:NO policyPerDay:0 remainingToday:0], SCOverrideInvokeDenyNotAllowed);
}
- (void)testInvokeDenyExhausted {
    XCTAssertEqual([SCOverrideDecision invokeAllowedWithBaseEnforcing:YES deepActive:NO alreadyActive:NO policyPerDay:3 remainingToday:0], SCOverrideInvokeDenyExhausted);
}

#pragma mark lift remaining (fail-closed)

- (void)testLiftRemainingNilTrustedNowIsZero {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:600];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:nil
                                                                    overrideEndDate:end
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 0, 0.001);
}
- (void)testLiftRemainingNilEndDateIsZero {
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:[NSDate date]
                                                                    overrideEndDate:nil
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 0, 0.001);
}
- (void)testLiftRemainingUnanchoredIsZero {
    NSDate* now = [NSDate date];
    NSDate* end = [now dateByAddingTimeInterval:600];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:now
                                                                    overrideEndDate:end
                                                                      clockAnchored:NO
                                                                        maxLiftSecs:7200], 0, 0.001);
}
- (void)testLiftRemainingExceedsMaxIsZero {
    NSDate* now = [NSDate date];
    NSDate* end = [now dateByAddingTimeInterval:7201];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:now
                                                                    overrideEndDate:end
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 0, 0.001);
}
- (void)testLiftRemainingEndAtOrBeforeNowIsZero {
    NSDate* now = [NSDate date];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:now
                                                                    overrideEndDate:now
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 0, 0.001);
    NSDate* past = [now dateByAddingTimeInterval:-1];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:now
                                                                    overrideEndDate:past
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 0, 0.001);
}
- (void)testLiftRemainingNormalCase {
    NSDate* now = [NSDate date];
    NSDate* end = [now dateByAddingTimeInterval:600];
    XCTAssertEqualWithAccuracy([SCOverrideDecision liftRemainingSecsWithTrustedNow:now
                                                                    overrideEndDate:end
                                                                      clockAnchored:YES
                                                                        maxLiftSecs:7200], 600, 0.001);
}

#pragma mark day string

- (void)testDayStringDiffersAcrossMidnightInZone {
    NSTimeZone* la = [NSTimeZone timeZoneWithName:@"America/Los_Angeles"];
    // 2026-09-30 06:30 UTC = 2026-09-29 23:30 LA ; 2026-09-30 07:30 UTC = 2026-09-30 00:30 LA
    NSDate* before = [NSDate dateWithTimeIntervalSince1970:1790749800]; // 2026-09-30T06:30:00Z
    NSDate* after  = [NSDate dateWithTimeIntervalSince1970:1790753400]; // 2026-09-30T07:30:00Z
    NSString* d1 = [SCOverrideDecision dayStringForDate:before timeZone:la];
    NSString* d2 = [SCOverrideDecision dayStringForDate:after timeZone:la];
    XCTAssertNotEqualObjects(d1, d2);
    XCTAssertEqualObjects(d1, @"2026-09-29");
    XCTAssertEqualObjects(d2, @"2026-09-30");
}

@end
