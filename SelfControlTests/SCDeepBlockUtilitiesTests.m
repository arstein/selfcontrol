#import <XCTest/XCTest.h>
#import "SCBlockUtilities.h"
#import "SCTrustedClock.h"

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
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:nil]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:YES baseValue:@NO deepRecord:(@{@"emergencyUnlockEnabled": @YES})]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:YES baseValue:@YES deepRecord:(@{@"emergencyUnlockEnabled": @NO})]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:(@{@"emergencyUnlockEnabled": @NO})]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedWithBaseRunning:NO baseValue:nil deepRecord:(@{})]);
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

@end
