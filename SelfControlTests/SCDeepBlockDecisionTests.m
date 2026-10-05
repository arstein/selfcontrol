#import <XCTest/XCTest.h>
#import "SCDeepBlockDecision.h"
#import "SCDeepBlockConfig.h"

@interface SCDeepBlockDecisionTests : XCTestCase
@end

@implementation SCDeepBlockDecisionTests

- (void)testDurationBounds {
    XCTAssertFalse([SCDeepBlockDecision durationSecsIsValid:299]);
    XCTAssertTrue([SCDeepBlockDecision durationSecsIsValid:SC_DEEP_MIN_SECS]);
    XCTAssertTrue([SCDeepBlockDecision durationSecsIsValid:SC_DEEP_MAX_SECS]);
    XCTAssertFalse([SCDeepBlockDecision durationSecsIsValid:SC_DEEP_MAX_SECS + 1]);
    XCTAssertFalse([SCDeepBlockDecision durationSecsIsValid:NAN]);
}

- (void)testDesiredLayers {
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:NO overrideActive:NO deepPresent:NO], @[]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:NO deepPresent:NO], @[SCLayerBase]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:YES deepPresent:NO], @[]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:NO overrideActive:NO deepPresent:YES], @[SCLayerDeep]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:NO deepPresent:YES], (@[SCLayerBase, SCLayerDeep]));
    // An override never lifts the regular block while a deep block exists.
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:YES deepPresent:YES], (@[SCLayerBase, SCLayerDeep]));
}

static SCDeepAction Act(BOOL present, BOOL complete, BOOL known, BOOL expired, BOOL verified, BOOL needs, BOOL installed) {
    return [SCDeepBlockDecision actionForRecordPresent:present timingComplete:complete remainingKnown:known
                                               expired:expired startIsVerified:verified needsVerification:needs
                                        layerInstalled:installed];
}

- (void)testActionTable {
    XCTAssertEqual(Act(NO, NO, NO, NO, NO, NO, NO), SCDeepActionNone);
    XCTAssertEqual(Act(NO, NO, NO, NO, NO, NO, YES), SCDeepActionHeal);            // record tampered away
    XCTAssertEqual(Act(YES, NO, NO, NO, NO, NO, YES), SCDeepActionHeal);           // timing incomplete
    XCTAssertEqual(Act(YES, YES, NO, NO, YES, NO, YES), SCDeepActionHeal);         // end undeterminable
    XCTAssertEqual(Act(YES, YES, YES, YES, YES, NO, YES), SCDeepActionSeekVerifiedExpiry);
    XCTAssertEqual(Act(YES, YES, YES, YES, NO, NO, NO), SCDeepActionSeekVerifiedExpiry); // expiry beats install
    XCTAssertEqual(Act(YES, YES, YES, NO, YES, NO, NO), SCDeepActionInstall);
    XCTAssertEqual(Act(YES, YES, YES, NO, NO, NO, YES), SCDeepActionSeekVerifiedStart);
    XCTAssertEqual(Act(YES, YES, YES, NO, YES, YES, YES), SCDeepActionSeekVerifiedStart);
    XCTAssertEqual(Act(YES, YES, YES, NO, YES, NO, YES), SCDeepActionSteady);
}

- (void)testTimingCompleteness {
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:nil]);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:@{@"durationSecs": @600}]);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:(@{@"durationSecs": @0, @"clockState": @{@"a": @1}})]);
    XCTAssertTrue([SCDeepBlockDecision recordTimingIsComplete:(@{@"durationSecs": @600, @"clockState": @{@"a": @1}})]);
}

- (void)testSnapshotRoundTrip {
    NSDate* start = [NSDate dateWithTimeIntervalSince1970:1000];
    NSDictionary* record = @{@"blocklist": @[@"a.com"], @"isAllowlist": @YES, @"durationSecs": @600,
                             @"startWall": start, @"startIsVerified": @NO, @"clockState": @{@"x": @1},
                             @"needsVerification": @YES};
    NSDictionary* snap = [SCDeepBlockDecision timingSnapshotForRecord:record];
    XCTAssertEqualObjects(snap[@"BlockStartWall"], start);
    XCTAssertEqualObjects(snap[@"BlockStartIsVerified"], @NO);
    XCTAssertEqualObjects(snap[@"BlockDurationSecs"], @600);
    XCTAssertEqualObjects(snap[@"TrustedClockState"], @{@"x": @1});

    NSDate* corrected = [NSDate dateWithTimeIntervalSince1970:1200];
    NSDictionary* updated = [SCDeepBlockDecision record:record byApplyingTimingWrites:@{
        @"BlockStartWall": corrected, @"BlockEndDate": [NSDate date], @"BlockStartIsVerified": @YES,
        @"TrustedClockState": @{@"y": @2}, @"TrustedClockNeedsVerification": @NO}];
    XCTAssertEqualObjects(updated[@"startWall"], corrected);
    XCTAssertEqualObjects(updated[@"startIsVerified"], @YES);
    XCTAssertEqualObjects(updated[@"clockState"], @{@"y": @2});
    XCTAssertEqualObjects(updated[@"needsVerification"], @NO);
    XCTAssertNil(updated[@"BlockEndDate"]);
    XCTAssertEqualObjects(updated[@"blocklist"], @[@"a.com"]);   // untouched fields survive
}

@end
