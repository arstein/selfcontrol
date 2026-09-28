#import <XCTest/XCTest.h>

#import "SCTrustedClock.h"

@interface SCTrustedClockTests : XCTestCase
@end

@implementation SCTrustedClockTests

static NSDictionary* SCReading(NSTimeInterval wall, NSTimeInterval mach, NSString* boot) {
    return @{@"wall": [NSDate dateWithTimeIntervalSince1970:wall],
             @"mach": @(mach),
             @"boot": boot};
}

- (void)testTrustedNowIgnoresWallClockJumps {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCReading(1000, 50, @"A")];
    XCTAssertEqualWithAccuracy(
        [SCTrustedClock trustedNowForState:state reading:SCReading(31537000, 110, @"A")].timeIntervalSince1970,
        1060, 0.001);
    XCTAssertEqualWithAccuracy(
        [SCTrustedClock trustedNowForState:state reading:SCReading(500, 110, @"A")].timeIntervalSince1970,
        1060, 0.001);
}

- (void)testRebootUsesMonotonicCheckpointAndClampsNegativeGap {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCReading(1000, 50, @"A")];
    // The wall value is dishonest; the monotonic checkpoint still proves 100 seconds.
    state = [SCTrustedClock checkpointState:state reading:SCReading(900, 150, @"A")];
    state = [SCTrustedClock reanchoredStateAfterBootChange:state reading:SCReading(800, 5, @"B")];
    NSDate* now = [SCTrustedClock trustedNowForState:state reading:SCReading(820, 25, @"B")];
    XCTAssertEqualWithAccuracy(now.timeIntervalSince1970, 1120, 0.001);
}

- (void)testRebootDoesNotTrustPositiveWallClockGap {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCReading(1000, 50, @"A")];
    state = [SCTrustedClock checkpointState:state reading:SCReading(1100, 150, @"A")];
    state = [SCTrustedClock reanchoredStateAfterBootChange:state reading:SCReading(1400, 8, @"B")];
    XCTAssertEqualWithAccuracy(
        [SCTrustedClock trustedNowForState:state reading:SCReading(1400, 8, @"B")].timeIntervalSince1970,
        1100, 0.001);
}

- (void)testVerifiedStartCorrectionAndElapsedTime {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCReading(1000, 50, @"A")];
    NSDictionary* later = SCReading(9999, 170, @"A");
    XCTAssertEqualWithAccuracy([SCTrustedClock elapsedSecsForState:state reading:later], 120, 0.001);
    XCTAssertEqualWithAccuracy(
        [SCTrustedClock correctedStartForState:state
                                   verifiedNow:[NSDate dateWithTimeIntervalSince1970:4720]
                                       reading:later].timeIntervalSince1970,
        4600, 0.001);
}

- (void)testSingleBootSessionFlag {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCReading(1000, 50, @"A")];
    XCTAssertTrue([SCTrustedClock stateIsSingleBootSession:state reading:SCReading(2000, 60, @"A")]);
    state = [SCTrustedClock reanchoredStateAfterBootChange:state reading:SCReading(2000, 5, @"B")];
    XCTAssertFalse([SCTrustedClock stateIsSingleBootSession:state reading:SCReading(2001, 6, @"B")]);
}

@end
