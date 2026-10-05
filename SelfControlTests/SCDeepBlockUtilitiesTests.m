#import <XCTest/XCTest.h>
#import "SCBlockUtilities.h"
#import "SCTrustedClock.h"
#import "SCDeepBlockDecision.h"

@interface SCDeepBlockUtilitiesTests : XCTestCase
@end

@implementation SCDeepBlockUtilitiesTests

static NSDictionary* R(NSTimeInterval wall, NSTimeInterval mach) {
    return @{@"wall": [NSDate dateWithTimeIntervalSince1970:wall], @"mach": @(mach), @"boot": @"A"};
}

- (void)testRemainingFromUnverifiedSnapshotUsesMonotonicElapsed {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:R(1000, 50)];
    NSDictionary* snap = @{@"BlockDurationSecs": @600, @"TrustedClockState": state, @"BlockStartIsVerified": @NO};
    // 100 s of monotonic time passed; the wall clock jumped a year (ignored).
    NSNumber* remaining = [SCBlockUtilities trustedRemainingSecsForTimingSnapshot:snap reading:R(31537000, 150)];
    XCTAssertEqualWithAccuracy(remaining.doubleValue, 500, 0.001);
}

- (void)testRemainingFromVerifiedSnapshotUsesStart {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:R(1000, 50)];
    NSDictionary* snap = @{@"BlockDurationSecs": @600, @"TrustedClockState": state, @"BlockStartIsVerified": @YES,
                           @"BlockStartWall": [NSDate dateWithTimeIntervalSince1970:900]};
    NSNumber* remaining = [SCBlockUtilities trustedRemainingSecsForTimingSnapshot:snap reading:R(1000, 150)];
    XCTAssertEqualWithAccuracy(remaining.doubleValue, 400, 0.001);   // end 1500, trusted now 1100
}

- (void)testRemainingNilWhenIncomplete {
    XCTAssertNil([SCBlockUtilities trustedRemainingSecsForTimingSnapshot:@{@"BlockDurationSecs": @600} reading:R(1000, 50)]);
    XCTAssertNil([SCBlockUtilities trustedRemainingSecsForTimingSnapshot:@{} reading:R(1000, 50)]);
}

- (void)testEmergencyUnlockGatingPrefersRegularBlock {
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:NO deepPayload:nil]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:YES baseValue:@NO deepRecord:(@{@"emergencyUnlockEnabled": @YES}) deepLayerInstalled:NO deepPayload:nil]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:YES baseValue:@YES deepRecord:(@{@"emergencyUnlockEnabled": @NO}) deepLayerInstalled:NO deepPayload:nil]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:(@{@"emergencyUnlockEnabled": @NO}) deepLayerInstalled:NO deepPayload:nil]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:(@{}) deepLayerInstalled:NO deepPayload:nil]);
}

- (void)testInstalledLayersFromAnchorState {
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:NO hostsPresent:NO anchorText:nil deepRecordPresent:NO], (@[]));
    // Pre-Phase-5 anchor (no marker) belongs to the regular block.
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:YES anchorText:@"# Options\n" deepRecordPresent:NO], (@[@"base"]));
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:NO anchorText:@"# sc-layers: deep\n" deepRecordPresent:YES], (@[@"deep"]));
    // Hosts-only remnant: the regular block's, unless a deep block owns it.
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:NO hostsPresent:YES anchorText:nil deepRecordPresent:NO], (@[@"base"]));
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:NO hostsPresent:YES anchorText:nil deepRecordPresent:YES], (@[]));
}

static NSDate* D(NSTimeInterval t) { return [NSDate dateWithTimeIntervalSince1970:t]; }

static NSDictionary* UnverifiedDeepRecord(void) {
    return @{@"durationSecs": @600, @"clockState": [SCTrustedClock freshStateWithReading:R(1000, 50)],
             @"startWall": D(1000), @"startIsVerified": @NO, @"needsVerification": @YES};
}

- (void)testDeepRecordVerificationThroughRegularTimingDecision {
    NSDictionary* record = UnverifiedDeepRecord();
    NSDictionary* decision = [SCBlockUtilities trustedTimingDecisionForSettings:[SCDeepBlockDecision timingSnapshotForRecord:record]
                                                                    verifiedNow:D(1100) reading:R(1100, 150)];
    XCTAssertNotNil(decision);
    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    NSDictionary* updated = [SCDeepBlockDecision record:record byApplyingTimingWrites:writes];
    XCTAssertEqualObjects(updated[@"startIsVerified"], @YES);
    XCTAssertEqualObjects(updated[@"needsVerification"], @NO);
    XCTAssertNotEqualObjects(updated[@"clockState"], record[@"clockState"]);
    XCTAssertNotNil(updated[@"startWall"]);
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);

    // Every write key must be mapped (or the known-ignored BlockEndDate); a new key must fail here.
    NSSet* allowed = [NSSet setWithArray:(@[@"BlockStartWall", @"BlockStartIsVerified", @"BlockDurationSecs",
                                            @"TrustedClockState", @"TrustedClockNeedsVerification", @"BlockEndDate"])];
    for (NSString* key in writes) XCTAssertTrue([allowed containsObject:key], @"unmapped write key %@", key);
}

- (void)testDeepRecordExpiryThroughRegularTimingDecision {
    NSDictionary* decision = [SCBlockUtilities trustedTimingDecisionForSettings:[SCDeepBlockDecision timingSnapshotForRecord:UnverifiedDeepRecord()]
                                                                    verifiedNow:D(1700) reading:R(1700, 750)];
    XCTAssertNotNil(decision);
    XCTAssertTrue([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testEmergencyUnlockRecordlessDeepLayer {
    NSDictionary* yes = @{@"emergencyUnlockEnabled": @YES};
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:YES deepPayload:nil]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:YES deepPayload:yes]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:YES deepPayload:(@{@"blocklist": @[]})]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:YES deepPayload:(@{@"emergencyUnlockEnabled": @NO})]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil deepLayerInstalled:NO deepPayload:nil]);
}

- (void)testInstalledLayersPureEdgeCases {
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:NO anchorText:nil deepRecordPresent:NO], (@[@"base"]));
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:NO anchorText:@"# sc-layers: base,deep\n" deepRecordPresent:NO], (@[@"base", @"deep"]));
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:NO anchorText:@"# sc-layers: \n" deepRecordPresent:NO], (@[]));
    XCTAssertEqualObjects([SCBlockUtilities installedLayerNamesForAnchorPresent:YES hostsPresent:NO anchorText:@"# Options\n" deepRecordPresent:YES], (@[@"base"]));
}

- (void)testRemainingVerifiedWithMissingStartFallsBackToElapsed {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:R(1000, 50)];
    NSDictionary* verified = @{@"BlockDurationSecs": @600, @"TrustedClockState": state, @"BlockStartIsVerified": @YES};
    NSDictionary* unverified = @{@"BlockDurationSecs": @600, @"TrustedClockState": state, @"BlockStartIsVerified": @NO};
    NSNumber* a = [SCBlockUtilities trustedRemainingSecsForTimingSnapshot:verified reading:R(1000, 150)];
    NSNumber* b = [SCBlockUtilities trustedRemainingSecsForTimingSnapshot:unverified reading:R(1000, 150)];
    XCTAssertEqualWithAccuracy(a.doubleValue, 500, 0.001);
    XCTAssertEqualObjects(a, b);
}

- (void)testRemainingNilForZeroDurationAndEmptyClockState {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:R(1000, 50)];
    XCTAssertNil([SCBlockUtilities trustedRemainingSecsForTimingSnapshot:(@{@"BlockDurationSecs": @0, @"TrustedClockState": state}) reading:R(1000, 150)]);
    XCTAssertNil([SCBlockUtilities trustedRemainingSecsForTimingSnapshot:(@{@"BlockDurationSecs": @600, @"TrustedClockState": @{}}) reading:R(1000, 150)]);
}

@end
