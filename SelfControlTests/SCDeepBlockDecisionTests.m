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

- (void)testStartRefusalCodes {
    // Order: already enforced (325) > duration (326) > empty blocklist (302) > no clock (327).
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:600 entryCount:1 isAllowlist:NO clockReadable:YES], 0);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:YES durationSecs:600 entryCount:1 isAllowlist:NO clockReadable:YES], 325);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:YES durationSecs:NAN entryCount:0 isAllowlist:NO clockReadable:NO], 325);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:299 entryCount:1 isAllowlist:NO clockReadable:YES], 326);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:SC_DEEP_MAX_SECS + 1 entryCount:0 isAllowlist:NO clockReadable:NO], 326);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:600 entryCount:0 isAllowlist:NO clockReadable:YES], 302);
    // An empty allowlist is accepted (blocks everything but infrastructure).
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:600 entryCount:0 isAllowlist:YES clockReadable:YES], 0);
    XCTAssertEqual([SCDeepBlockDecision startRefusalCodeWithDeepEnforced:NO durationSecs:600 entryCount:1 isAllowlist:NO clockReadable:NO], 327);
}

- (void)testDesiredLayers {
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:NO overrideActive:NO deepShouldEnforce:NO], @[]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:NO deepShouldEnforce:NO], @[SCLayerBase]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:YES deepShouldEnforce:NO], @[]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:NO overrideActive:NO deepShouldEnforce:YES], @[SCLayerDeep]);
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:NO deepShouldEnforce:YES], (@[SCLayerBase, SCLayerDeep]));
    // An override never lifts the regular block while a deep block exists.
    XCTAssertEqualObjects([SCDeepBlockDecision desiredLayersWithBaseRunning:YES overrideActive:YES deepShouldEnforce:YES], (@[SCLayerBase, SCLayerDeep]));
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
    XCTAssertEqual(Act(YES, NO, NO, NO, NO, NO, NO), SCDeepActionInstall);         // incomplete + not installed: tighten first
    XCTAssertEqual(Act(YES, YES, NO, NO, YES, NO, NO), SCDeepActionInstall);       // end unknown + not installed
    XCTAssertEqual(Act(YES, YES, YES, YES, YES, YES, YES), SCDeepActionSeekVerifiedExpiry); // expired + needsVerification
    XCTAssertEqual(Act(YES, YES, NO, YES, YES, NO, YES), SCDeepActionHeal);        // remaining unknown beats expired
    XCTAssertEqual(Act(NO, YES, YES, NO, YES, NO, NO), SCDeepActionNone);          // record absent, nothing installed
}

- (void)testTimingCompleteness {
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:nil]);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:@{@"durationSecs": @600}]);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:(@{@"durationSecs": @0, @"clockState": @{@"a": @1}})]);
    XCTAssertTrue([SCDeepBlockDecision recordTimingIsComplete:(@{@"durationSecs": @600, @"clockState": @{@"a": @1}})]);
}

static NSMutableDictionary* CompleteRecord(void) {
    return [@{@"durationSecs": @600, @"clockState": @{@"a": @1}} mutableCopy];
}

- (void)testTimingCompletenessHardening {
    NSMutableDictionary* r = CompleteRecord();
    r[@"durationSecs"] = @(NAN);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r[@"durationSecs"] = @(INFINITY);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r[@"durationSecs"] = @(SC_DEEP_MAX_SECS + 1);
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r = CompleteRecord();
    r[@"clockState"] = @{};
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r[@"clockState"] = @"not a dict";
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r = CompleteRecord();
    r[@"startIsVerified"] = @YES;
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);   // verified, no startWall
    r[@"startWall"] = [NSDate distantPast];
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r[@"startWall"] = @"not a date";
    XCTAssertFalse([SCDeepBlockDecision recordTimingIsComplete:r]);
    r[@"startWall"] = [NSDate dateWithTimeIntervalSince1970:1000];
    XCTAssertTrue([SCDeepBlockDecision recordTimingIsComplete:r]);
    r = CompleteRecord();
    r[@"startIsVerified"] = @NO;   // unverified needs no startWall
    XCTAssertTrue([SCDeepBlockDecision recordTimingIsComplete:r]);
}

- (void)testSnapshotNeedsVerificationAndNonDict {
    NSDictionary* snap = [SCDeepBlockDecision timingSnapshotForRecord:(@{@"needsVerification": @YES})];
    XCTAssertEqualObjects(snap[@"TrustedClockNeedsVerification"], @YES);
    XCTAssertEqualObjects([SCDeepBlockDecision timingSnapshotForRecord:(id)@"junk"], (@{}));
    XCTAssertEqualObjects([SCDeepBlockDecision timingSnapshotForRecord:(id)[NSNull null]], (@{}));
    NSDictionary* updated = [SCDeepBlockDecision record:(id)[NSNull null] byApplyingTimingWrites:(@{@"BlockStartIsVerified": @YES})];
    XCTAssertEqualObjects(updated, (@{@"startIsVerified": @YES}));
    XCTAssertEqualObjects([SCDeepBlockDecision record:nil byApplyingTimingWrites:(@{})], (@{}));
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

- (void)testHealNeeded {
    NSDictionary* good = @{@"durationSecs": @600, @"clockState": @{@"x": @1}, @"startIsVerified": @NO};
    XCTAssertFalse([SCDeepBlockDecision healNeededForRecord:nil remainingKnown:NO layerInstalled:NO]);
    XCTAssertTrue([SCDeepBlockDecision healNeededForRecord:nil remainingKnown:NO layerInstalled:YES]);
    XCTAssertFalse([SCDeepBlockDecision healNeededForRecord:good remainingKnown:YES layerInstalled:YES]);
    XCTAssertTrue([SCDeepBlockDecision healNeededForRecord:good remainingKnown:NO layerInstalled:YES]);
    NSDictionary* tooLong = @{@"durationSecs": @99999, @"clockState": @{@"x": @1}};
    XCTAssertTrue([SCDeepBlockDecision healNeededForRecord:tooLong remainingKnown:YES layerInstalled:NO]);
}

- (void)testHealedRecordFromPayloadOnly {
    NSDate* now = [NSDate dateWithTimeIntervalSince1970:5000];
    XCTAssertNil([SCDeepBlockDecision healedRecordFromRecord:nil payload:nil verifiedNow:now clockState:@{@"c": @1}]);
    NSDictionary* healed = [SCDeepBlockDecision healedRecordFromRecord:nil
                                                               payload:@{@"blocklist": @[@"a.com"], @"isAllowlist": @YES,
                                                                         @"allowLocal": @YES, @"evaluateCommonSubdomains": @NO,
                                                                         @"includeLinkedDomains": @NO}
                                                           verifiedNow:now clockState:@{@"c": @1}];
    XCTAssertEqualObjects(healed[@"blocklist"], @[@"a.com"]);
    XCTAssertEqualObjects(healed[@"isAllowlist"], @YES);
    XCTAssertEqualObjects(healed[@"allowLocal"], @YES);
    XCTAssertEqualObjects(healed[@"evaluateCommonSubdomains"], @NO);
    XCTAssertEqualObjects(healed[@"includeLinkedDomains"], @NO);
    XCTAssertEqualObjects(healed[@"emergencyUnlockEnabled"], @NO);   // unknown => off
    XCTAssertEqualObjects(healed[@"durationSecs"], @(SC_DEEP_HEAL_SECS));
    XCTAssertEqualObjects(healed[@"startWall"], now);
    XCTAssertEqualObjects(healed[@"startIsVerified"], @YES);
    XCTAssertEqualObjects(healed[@"needsVerification"], @NO);
    XCTAssertEqualObjects(healed[@"clockState"], @{@"c": @1});
    XCTAssertTrue([SCDeepBlockDecision recordTimingIsComplete:healed]);

    NSDictionary* allowed = [SCDeepBlockDecision healedRecordFromRecord:nil
                                                                payload:@{@"blocklist": @[], @"isAllowlist": @NO, @"emergencyUnlockEnabled": @YES}
                                                            verifiedNow:now clockState:@{@"c": @1}];
    XCTAssertEqualObjects(allowed[@"emergencyUnlockEnabled"], @YES);
}

- (void)testHealedRecordKeepsRecordAndFillsGaps {
    NSDate* now = [NSDate dateWithTimeIntervalSince1970:5000];
    NSDictionary* record = @{@"blocklist": @[@"r.com"], @"isAllowlist": @NO, @"durationSecs": @99999,
                             @"emergencyUnlockEnabled": @YES};
    NSDictionary* payload = @{@"blocklist": @[@"p.com"], @"isAllowlist": @YES, @"allowLocal": @YES,
                              @"emergencyUnlockEnabled": @NO};
    NSDictionary* healed = [SCDeepBlockDecision healedRecordFromRecord:record payload:payload verifiedNow:now clockState:@{@"c": @1}];
    XCTAssertEqualObjects(healed[@"blocklist"], @[@"r.com"]);
    XCTAssertEqualObjects(healed[@"isAllowlist"], @NO);
    XCTAssertEqualObjects(healed[@"allowLocal"], @YES);              // gap filled from payload
    XCTAssertEqualObjects(healed[@"emergencyUnlockEnabled"], @NO);   // payload turns it off
    XCTAssertEqualObjects(healed[@"durationSecs"], @(SC_DEEP_HEAL_SECS));

    // A broken record with no payload still heals (timing), unlock unknown => off.
    NSDictionary* noPayload = [SCDeepBlockDecision healedRecordFromRecord:@{@"blocklist": @[@"r.com"]} payload:nil
                                                              verifiedNow:now clockState:@{@"c": @1}];
    XCTAssertEqualObjects(noPayload[@"blocklist"], @[@"r.com"]);
    XCTAssertEqualObjects(noPayload[@"emergencyUnlockEnabled"], @NO);
    // Record says on, payload silent: stays on.
    NSDictionary* on = [SCDeepBlockDecision healedRecordFromRecord:@{@"emergencyUnlockEnabled": @YES} payload:@{}
                                                       verifiedNow:now clockState:@{@"c": @1}];
    XCTAssertEqualObjects(on[@"emergencyUnlockEnabled"], @YES);
}

- (void)testRecordListIsUsable {
    XCTAssertTrue([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[@"a.com"], @"isAllowlist": @NO})]);
    XCTAssertTrue([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[], @"isAllowlist": @YES})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:nil]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(id)@"x"]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"isAllowlist": @NO})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @"a.com", @"isAllowlist": @NO})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[@"a.com", @3], @"isAllowlist": @NO})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[@"a.com"]})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[@"a.com"], @"isAllowlist": @"NO"})]);
    XCTAssertFalse([SCDeepBlockDecision recordListIsUsable:(@{@"blocklist": @[@"a.com"], @"isAllowlist": @[]})]);
}

@end
